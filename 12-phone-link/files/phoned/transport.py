"""Canal TCP com TLS, sessoes e o ciclo de vida da conexao.

Assimetria importante, verificada com o modulo ssl da stdlib: um servidor que
ainda nao confia em ninguem nao pode exigir certificado do cliente, entao nao
recebe nenhum. Por isso o primeiro pareamento carrega o certificado dentro do
pacote pair.request, e a seguranca vem da comparacao visual do codigo.
"""

import asyncio
import logging
import ssl

from . import pairing, protocol

log = logging.getLogger(__name__)


def build_server_context(cert_path, key_path, ca_data):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(str(cert_path), str(key_path))
    if ca_data:
        # Ha aparelhos pareados: exige e valida o certificado do cliente.
        ctx.verify_mode = ssl.CERT_OPTIONAL
        ctx.load_verify_locations(cadata=ca_data)
    else:
        # Nenhum aparelho confiavel ainda: aceita sem certificado de cliente,
        # e o gate de pareamento em Transport limita o que pode trafegar.
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def build_client_context(cert_path, key_path, present_cert):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    # A confianca e por fingerprint, nao por cadeia nem por nome de host.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    if present_cert:
        ctx.load_cert_chain(str(cert_path), str(key_path))
    return ctx


def peer_fingerprint(writer):
    objeto = writer.get_extra_info("ssl_object")
    if objeto is None:
        return None
    der = objeto.getpeercert(binary_form=True)
    return pairing.fingerprint_from_der(der) if der else None


class Session:
    """Uma conexao viva com um aparelho. Fala pacotes, nao bytes."""

    def __init__(self, reader, writer, address, identity=None, peer_fingerprint=None):
        self._reader = reader
        self._writer = writer
        self.address = address
        self.identity = identity
        self.peer_fingerprint = peer_fingerprint
        self.paired = False
        self._lock = asyncio.Lock()

    @property
    def device_id(self):
        return self.identity.device_id if self.identity else None

    @property
    def name(self):
        return self.identity.name if self.identity else None

    async def send(self, packet):
        async with self._lock:
            self._writer.write(protocol.encode(packet))
            await self._writer.drain()

    async def read_packet(self):
        try:
            linha = await self._reader.readline()
        except ValueError as exc:
            # StreamReader estoura ValueError quando a linha passa do limite do
            # buffer. Sem esta traducao vazaria um tipo que o laco de leitura nao
            # espera. Defesa em profundidade: quem abre a conexao ja passa
            # limit=MAX_LINE_BYTES, entao chegar aqui significa linha alem do
            # que o protocolo admite.
            raise protocol.ProtocolError(f"linha acima do limite do buffer: {exc}") from exc
        if not linha:
            return None
        # O tamanho e validado uma vez so, dentro de decode. Repetir a checagem
        # aqui ja custou uma divergencia de um byte entre os dois lugares.
        return protocol.decode(linha)

    async def close(self):
        if self._writer.is_closing():
            return
        self._writer.close()
        try:
            await self._writer.wait_closed()
        except (ConnectionError, ssl.SSLError) as exc:
            log.debug("erro ao fechar sessao com %s: %s", self.address, exc)


PAIR_REQUEST = "pair.request"
PAIR_ACCEPT = "pair.accept"
PAIR_REJECT = "pair.reject"
PING = "phone.ping"
PONG = "phone.pong"


class _PendingPair:
    """Pareamento em andamento: guarda o que cada lado ja decidiu."""

    def __init__(self, session, peer_fingerprint, code, iniciado_por_nos):
        self.session = session
        self.peer_fingerprint = peer_fingerprint
        self.code = code
        self.iniciado_por_nos = iniciado_por_nos
        self.local_ok = False
        self.remoto_ok = False
        self.timer = None


class Transport:
    def __init__(self, cfg, trust, identity, on_event):
        self._cfg = cfg
        self._trust = trust
        self._identity = identity
        self._on_event = on_event
        self._server = None
        self._sessions = {}
        self._pending = {}
        self._tarefas = set()
        self._cert_pem = None
        self._pending_pings = {}
        self._backoff = {}
        self._ultimo_pacote = {}
        self._heartbeat = None

    # ---------- ciclo de vida ----------

    async def start(self):
        pairing.ensure_certificate(
            self._cfg.cert_path, self._cfg.key_path, self._cfg.device_id
        )
        self._cert_pem = self._cfg.cert_path.read_text()
        ctx = build_server_context(
            self._cfg.cert_path, self._cfg.key_path, self._trust.ca_data()
        )
        self._server = await asyncio.start_server(
            self._on_inbound, "0.0.0.0", self._cfg.tcp_port, ssl=ctx,
            # Sem isto o buffer do StreamReader seria o default de 64KB, e o
            # limite de 1MB do protocolo nao valeria de verdade: linhas entre os
            # dois estourariam ValueError no readline.
            limit=protocol.MAX_LINE_BYTES,
        )
        self._heartbeat = asyncio.create_task(self._laco_heartbeat())

    async def stop(self):
        if self._heartbeat:
            self._heartbeat.cancel()
            try:
                await self._heartbeat
            except asyncio.CancelledError:
                pass
            self._heartbeat = None
        for pendente in list(self._pending.values()):
            if pendente.timer:
                pendente.timer.cancel()
        self._pending.clear()
        for sessao in list(self._sessions.values()):
            await sessao.close()
        self._sessions.clear()
        for tarefa in list(self._tarefas):
            tarefa.cancel()
        self._tarefas.clear()
        if self._server:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    def sessions(self):
        return list(self._sessions.values())

    # ---------- conexao ----------

    async def connect(self, host, port):
        conhecido_pem = None
        for device in self._trust.all():
            conhecido_pem = device.certificate
            break
        ctx = build_client_context(
            self._cfg.cert_path, self._cfg.key_path, present_cert=bool(conhecido_pem)
        )
        try:
            reader, writer = await asyncio.open_connection(
                host, port, ssl=ctx, limit=protocol.MAX_LINE_BYTES
            )
        except (OSError, ssl.SSLError) as exc:
            log.warning("falha ao conectar em %s:%s: %s", host, port, exc)
            return None
        sessao = Session(reader, writer, address=host, peer_fingerprint=peer_fingerprint(writer))
        await sessao.send(
            protocol.make_packet("identity", self._identity.to_body())
        )
        self._spawn(self._laco_de_leitura(sessao))
        return sessao

    async def _on_inbound(self, reader, writer):
        endereco = writer.get_extra_info("peername")
        sessao = Session(
            reader, writer,
            address=endereco[0] if endereco else "?",
            peer_fingerprint=peer_fingerprint(writer),
        )
        # A troca de identidade e mutua. Sem isto, quem abriu a conexao nunca
        # descobre nosso device_id, sua tabela de sessoes fica vazia e o
        # request_pair falha em silencio por nao achar a sessao.
        await sessao.send(protocol.make_packet("identity", self._identity.to_body()))
        await self._laco_de_leitura(sessao)

    def _spawn(self, corotina):
        tarefa = asyncio.create_task(corotina)
        self._tarefas.add(tarefa)
        tarefa.add_done_callback(self._tarefas.discard)
        return tarefa

    # ---------- leitura ----------

    async def _laco_de_leitura(self, sessao):
        try:
            while True:
                try:
                    packet = await sessao.read_packet()
                except protocol.ProtocolError as exc:
                    log.warning("pacote invalido de %s: %s", sessao.address, exc)
                    break
                if packet is None:
                    break
                if not await self._despacha(sessao, packet):
                    break
        except (ConnectionError, ssl.SSLError) as exc:
            log.info("conexao com %s encerrada: %s", sessao.address, exc)
        finally:
            await self._encerra(sessao)

    async def _encerra(self, sessao):
        await sessao.close()
        if sessao.device_id and self._sessions.get(sessao.device_id) is sessao:
            del self._sessions[sessao.device_id]
            self._emit("device.state", {
                "device_id": sessao.device_id, "state": "disconnected",
            })
        pendente = self._pending.get(sessao.device_id)
        if pendente and pendente.session is sessao:
            self._cancela_pendente(sessao.device_id, "desconectado")

    async def _despacha(self, sessao, packet):
        """Retorna False para encerrar a conexao."""
        self._ultimo_pacote[id(sessao)] = asyncio.get_running_loop().time()
        tipo = packet["type"]

        if tipo == "identity":
            return self._registra_identidade(sessao, packet)

        if sessao.identity is None:
            log.warning("pacote %s antes de identity, de %s", tipo, sessao.address)
            return False

        if not sessao.paired and not tipo.startswith("pair."):
            log.warning(
                "aparelho nao pareado %s tentou enviar %s", sessao.device_id, tipo
            )
            return False

        match tipo:
            case _ if tipo == PAIR_REQUEST:
                await self._on_pair_request(sessao, packet)
            case _ if tipo == PAIR_ACCEPT:
                await self._on_pair_accept(sessao)
            case _ if tipo == PAIR_REJECT:
                self._cancela_pendente(sessao.device_id, packet["body"].get("reason", "recusado"))
            case _ if tipo == PING:
                await sessao.send(protocol.make_packet(PONG, {"echo_id": packet["id"]}))
            case _ if tipo == PONG:
                echo = packet["body"].get("echo_id")
                futuro = self._pending_pings.pop(echo, None)
                if futuro and not futuro.done():
                    futuro.set_result(asyncio.get_running_loop().time())
                self._emit("pong", {"device_id": sessao.device_id, "echo_id": echo})
            case _:
                log.debug("tipo desconhecido de %s: %s", sessao.device_id, tipo)
        return True

    def _registra_identidade(self, sessao, packet):
        from . import discovery as _discovery

        if sessao.identity is not None:
            # Cada lado se identifica uma unica vez. Sem esta guarda, uma sessao
            # que ja pareou como A poderia se re-rotular como um device_id
            # qualquer: o bloco de confianca abaixo seria pulado por ser
            # desconhecido, mas sessao.paired continuaria True de antes, e o gate
            # de pareamento deixaria passar qualquer tipo. Ainda por cima a
            # entrada antiga em _sessions ficaria apontando para uma sessao
            # morta, e a reconexao legitima de A seria recusada como duplicada.
            log.warning(
                "sessao de %s tentou se identificar de novo, derrubando",
                sessao.device_id,
            )
            return False
        try:
            identidade = _discovery.Identity.from_body(packet["body"])
        except _discovery.IdentityError as exc:
            log.warning("identity invalida de %s: %s", sessao.address, exc)
            return False
        if identidade.device_id == self._identity.device_id:
            log.warning("conexao consigo mesmo, descartando")
            return False

        anterior = self._sessions.get(identidade.device_id)
        if anterior is not None and anterior is not sessao:
            log.info("conexao duplicada para %s, fechando a nova", identidade.device_id)
            return False

        sessao.identity = identidade
        conhecido = self._trust.get(identidade.device_id)
        if conhecido is not None:
            if sessao.peer_fingerprint is None:
                # Nos somos o servidor e o cliente nao apresentou certificado,
                # apesar de constar como pareado. Estado assimetrico.
                log.warning(
                    "aparelho %s consta pareado mas nao apresentou certificado",
                    identidade.device_id,
                )
                return False
            if sessao.peer_fingerprint != conhecido.fingerprint:
                log.warning(
                    "fingerprint de %s mudou, conexao recusada. Rode phonectl unpair %s",
                    identidade.device_id, identidade.device_id,
                )
                return False
            sessao.paired = True

        self._sessions[identidade.device_id] = sessao
        self._emit("device.state", {
            "device_id": identidade.device_id,
            "name": identidade.name,
            "address": sessao.address,
            "paired": sessao.paired,
            "state": "connected",
        })
        return True

    # ---------- pareamento ----------

    async def request_pair(self, device_id):
        sessao = self._sessions.get(device_id)
        if sessao is None or sessao.paired:
            return False
        await sessao.send(
            protocol.make_packet(PAIR_REQUEST, {"certificate": self._cert_pem})
        )
        # O certificado do outro lado veio pelo proprio handshake TLS, ja que
        # aqui nos somos o cliente.
        self._abre_pendente(sessao, sessao.peer_fingerprint, iniciado_por_nos=True)
        return True

    async def _on_pair_request(self, sessao, packet):
        pem = packet["body"].get("certificate")
        if not isinstance(pem, str):
            await sessao.send(
                protocol.make_packet(PAIR_REJECT, {"reason": "certificado ausente"})
            )
            return
        try:
            fingerprint = pairing.fingerprint_from_pem(pem)
        except pairing.CertificateError as exc:
            await sessao.send(
                protocol.make_packet(PAIR_REJECT, {"reason": f"certificado invalido: {exc}"})
            )
            return
        if sessao.peer_fingerprint is not None and sessao.peer_fingerprint != fingerprint:
            # O certificado do TLS e o do pacote precisam ser o mesmo, senao
            # alguem esta tentando parear com credencial de terceiro.
            await sessao.send(
                protocol.make_packet(PAIR_REJECT, {"reason": "certificado divergente"})
            )
            return
        sessao.peer_certificate = pem
        self._abre_pendente(sessao, fingerprint, iniciado_por_nos=False, pem=pem)

    def _abre_pendente(self, sessao, fingerprint, iniciado_por_nos, pem=None):
        anterior = self._pending.get(sessao.device_id)
        if anterior is not None and anterior.timer:
            # Sem cancelar, o timer velho dispara depois e derruba o pareamento
            # novo, que ainda estava dentro do proprio prazo. Acontece com dois
            # request_pair seguidos, um duplo clique na UI da fatia 2 basta.
            anterior.timer.cancel()
        codigo = pairing.pair_code(
            pairing.fingerprint_of_file(self._cfg.cert_path), fingerprint
        )
        pendente = _PendingPair(sessao, fingerprint, codigo, iniciado_por_nos)
        pendente.pem = pem
        pendente.timer = asyncio.get_running_loop().call_later(
            self._cfg.pair_timeout,
            lambda: self._cancela_pendente(sessao.device_id, "timeout"),
        )
        self._pending[sessao.device_id] = pendente
        self._emit("pair.prompt", {
            "device_id": sessao.device_id,
            "name": sessao.name,
            "code": codigo,
        })

    async def confirm_pair(self, device_id, accept):
        pendente = self._pending.get(device_id)
        if pendente is None:
            return False
        if not accept:
            await pendente.session.send(
                protocol.make_packet(PAIR_REJECT, {"reason": "recusado pelo usuario"})
            )
            self._cancela_pendente(device_id, "recusado pelo usuario")
            return True
        pendente.local_ok = True
        await pendente.session.send(
            protocol.make_packet(PAIR_ACCEPT, {"certificate": self._cert_pem})
        )
        self._talvez_conclui(device_id)
        return True

    async def _on_pair_accept(self, sessao):
        pendente = self._pending.get(sessao.device_id)
        if pendente is None:
            return
        pendente.remoto_ok = True
        self._talvez_conclui(sessao.device_id)

    def _talvez_conclui(self, device_id):
        pendente = self._pending.get(device_id)
        if pendente is None or not (pendente.local_ok and pendente.remoto_ok):
            return
        pem = getattr(pendente, "pem", None) or self._pem_do_handshake(pendente.session)
        self._trust.add(pairing.Device(
            device_id=device_id,
            name=pendente.session.name or device_id,
            fingerprint=pendente.peer_fingerprint,
            certificate=pem,
        ))
        self._trust.save()
        pendente.session.paired = True
        if pendente.timer:
            pendente.timer.cancel()
        del self._pending[device_id]
        self._emit("pair.result", {"device_id": device_id, "accepted": True})
        self._emit("device.state", {
            "device_id": device_id, "state": "connected", "paired": True,
        })

    def _pem_do_handshake(self, sessao):
        objeto_pem = getattr(sessao, "peer_certificate", None)
        if objeto_pem:
            return objeto_pem
        writer_ssl = sessao._writer.get_extra_info("ssl_object")
        der = writer_ssl.getpeercert(binary_form=True) if writer_ssl else None
        return ssl.DER_cert_to_PEM_cert(der) if der else ""

    def _cancela_pendente(self, device_id, reason):
        pendente = self._pending.pop(device_id, None)
        if pendente is None:
            return
        if pendente.timer:
            pendente.timer.cancel()
        self._emit("pair.result", {
            "device_id": device_id, "accepted": False, "reason": reason,
        })

    async def unpair(self, device_id):
        removido = self._trust.remove(device_id)
        if removido:
            self._trust.save()
            sessao = self._sessions.get(device_id)
            if sessao:
                await sessao.close()
        return removido

    def _emit(self, kind, payload):
        try:
            self._on_event(kind, payload)
        except Exception:
            log.exception("handler de evento falhou para %s", kind)

    MAX_BACKOFF = 60.0

    async def ping(self, device_id):
        sessao = self._sessions.get(device_id)
        if sessao is None:
            return None
        loop = asyncio.get_running_loop()
        packet = protocol.make_packet(PING)
        futuro = loop.create_future()
        self._pending_pings[packet["id"]] = futuro
        comeco = loop.time()
        try:
            await sessao.send(packet)
            fim = await asyncio.wait_for(futuro, timeout=self._cfg.session_timeout)
        except (asyncio.TimeoutError, ConnectionError, ssl.SSLError):
            self._pending_pings.pop(packet["id"], None)
            return None
        return (fim - comeco) * 1000.0

    async def ensure_connected(self, identity, host):
        """Chamado pela descoberta. Nao abre segunda conexao nem fura o backoff."""
        if identity.device_id in self._sessions:
            return
        agora = asyncio.get_running_loop().time()
        proibido_ate = self._backoff.get(identity.device_id, (0.0, 0.0))[1]
        if agora < proibido_ate:
            return
        sessao = await self.connect(host, identity.port)
        if sessao is None:
            self._proximo_backoff(identity.device_id)
        else:
            self._zera_backoff(identity.device_id)

    def _proximo_backoff(self, device_id):
        atual, _ = self._backoff.get(device_id, (0.0, 0.0))
        proximo = 1.0 if atual == 0.0 else min(atual * 2, self.MAX_BACKOFF)
        agora = asyncio.get_running_loop().time()
        self._backoff[device_id] = (proximo, agora + proximo)
        return proximo

    def _zera_backoff(self, device_id):
        self._backoff.pop(device_id, None)

    async def _laco_heartbeat(self):
        while True:
            await asyncio.sleep(self._cfg.ping_interval)
            agora = asyncio.get_running_loop().time()
            for sessao in list(self._sessions.values()):
                if not sessao.paired:
                    # Sessao em pareamento nao leva ping: phone.ping nao comeca
                    # com pair., entao o gate do outro lado derrubaria a conexao
                    # antes de o usuario confirmar o codigo. Quem cuida do prazo
                    # dela e o pair_timeout.
                    continue
                visto = self._ultimo_pacote.get(id(sessao), agora)
                if agora - visto > self._cfg.session_timeout:
                    log.info("sessao com %s sem resposta, encerrando", sessao.device_id)
                    await self._encerra(sessao)
                    continue
                try:
                    await sessao.send(protocol.make_packet(PING))
                except (ConnectionError, ssl.SSLError):
                    await self._encerra(sessao)
