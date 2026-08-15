"""Junta descoberta, transporte e IPC num processo so."""

import asyncio
import base64
import binascii
import logging
import os
import subprocess
from pathlib import Path

from . import config, discovery, ipc, pairing, transport

log = logging.getLogger(__name__)


class Daemon:
    def __init__(self, cfg):
        self.cfg = cfg
        self._trust = pairing.TrustStore(cfg.devices_path)
        self._trust.load()
        self._identity = discovery.Identity(
            device_id=cfg.device_id,
            name=cfg.name,
            device_type="desktop",
            port=cfg.tcp_port,
            protocol_version=config.PROTOCOL_VERSION,
            capabilities=["ping"],
        )
        self._ipc = ipc.IpcServer(cfg.ipc_path, self.handle_command)
        self._transport = transport.Transport(
            cfg, self._trust, self._identity, self._on_event
        )
        self._discovery = discovery.Discovery(cfg, self._identity, self._on_identity)
        self._vistos = {}
        self._tarefas = set()

    async def start(self):
        await self._ipc.start()
        await self._transport.start()
        await self._discovery.start()
        log.info(
            "phoned no ar como %s (%s), porta %s",
            self.cfg.name, self.cfg.device_id, self.cfg.tcp_port,
        )

    async def stop(self):
        # A descoberta para primeiro, de proposito. Ela e a unica fonte de
        # tarefas novas aqui: um datagrama que chegue durante o proprio stop
        # ainda passaria por _on_identity e criaria um ensure_connected orfao,
        # depois de _tarefas ja ter sido esvaziado.
        await self._discovery.stop()
        for tarefa in list(self._tarefas):
            tarefa.cancel()
        self._tarefas.clear()
        await self._transport.stop()
        await self._ipc.stop()

    # ---------- ligacoes ----------

    def _on_identity(self, identity, source_ip):
        self._vistos[identity.device_id] = (identity, source_ip)
        tarefa = asyncio.create_task(self._transport.ensure_connected(identity, source_ip))
        self._tarefas.add(tarefa)
        tarefa.add_done_callback(self._tarefas.discard)

    def _on_event(self, kind, payload):
        self._ipc.broadcast(kind, payload)
        if kind == "notif.post":
            self._mostra_notificacao(payload)

    def _unico_pareado(self):
        """device_id quando ha exatamente um aparelho conectado e pareado.

        Com um celular so, que e o caso dele, exigir o id em toda linha de
        comando seria burocracia pura.
        """
        pareadas = [s for s in self._transport.sessions() if s.paired]
        return pareadas[0].device_id if len(pareadas) == 1 else None

    def _mostra_notificacao(self, payload):
        """Repassa a notificacao do celular para o desktop.

        Vai por `notify-send` e nao por D-Bus direto: o daemon nao carrega
        dependencia de bindings de D-Bus, e `notify-send` ja existe em qualquer
        sistema que tenha um servidor de notificacao rodando. Do outro lado quem
        recebe e o painel do Quickshell, que renderiza igual a qualquer outra.

        Falha aqui NAO pode derrubar a sessao: se o servidor de notificacao
        estiver fora do ar, o certo e perder a notificacao e seguir conectado.
        """
        titulo = str(payload.get("title") or payload.get("app") or "Celular")
        texto = str(payload.get("text") or "")
        app = str(payload.get("app") or "Celular")
        # O sufixo e o que permite o painel do Quickshell distinguir o que veio
        # do celular do que nasceu no proprio PC, e trocar o icone generico por
        # um de celular. Vai no nome do aplicativo, e nao no titulo, para nao
        # sujar o texto que ele le. O painel remove o sufixo antes de mostrar.
        app_marcado = f"{app} \u00b7 celular"
        cmd = ["notify-send", "-a", app_marcado, "-u", "normal"]
        # A chave viaja como hint porque o protocolo freedesktop nao tem campo
        # para isso, e sem ela o painel nao teria como dizer QUAL notificacao
        # responder depois, la no historico. O Quickshell expoe hints ao QML.
        chave = str(payload.get("key") or "")
        if chave:
            cmd += ["-h", f"string:x-phonelink-key:{chave}"]
        if payload.get("can_reply"):
            cmd += ["-h", "string:x-phonelink-reply:1"]
        icone = self._grava_icone(payload)
        if icone:
            cmd += ["-i", icone]
        cmd += [titulo, texto]
        try:
            subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        except (OSError, ValueError) as exc:
            log.warning("nao consegui exibir a notificacao: %s", exc)

    def _grava_icone(self, payload):
        """Salva o icone do app do celular em cache e devolve o caminho.

        O celular manda um PNG em base64 no corpo. Guardar em arquivo por
        PACOTE, e nao por notificacao, e o que evita encher o disco: dez
        mensagens do mesmo aplicativo reescrevem o mesmo arquivo.

        Qualquer falha aqui devolve None e a notificacao sai sem icone. Icone
        ausente e um detalhe visual; deixar de mostrar a mensagem por causa
        dele seria trocar um problema pequeno por um grande.
        """
        b64 = payload.get("icon")
        pacote = str(payload.get("package") or "").strip()
        if not b64 or not pacote:
            return None
        # nome de pacote e [a-z0-9_.], mas veio da rede: sanear antes de virar
        # caminho de arquivo, senao um "../.." escreveria fora do cache
        seguro = "".join(c for c in pacote if c.isalnum() or c in "._-")
        if not seguro:
            return None
        try:
            dados = base64.b64decode(b64, validate=True)
        except (binascii.Error, ValueError):
            log.warning("icone invalido de %s", pacote)
            return None
        if not dados.startswith(b"\x89PNG"):
            log.warning("icone de %s nao e PNG", pacote)
            return None
        # Dentro do state dir, e NAO em ~/.cache. A unit roda com
        # ProtectHome=read-only e ProtectSystem=strict, e so
        # ~/.local/state/phone e o runtime dir estao em ReadWritePaths. Escrever
        # em ~/.cache falha com "Read-only file system", que foi exatamente o
        # que aconteceu na primeira tentativa.
        destino = Path(self.cfg.state_dir) / "icones"
        try:
            destino.mkdir(parents=True, exist_ok=True)
            alvo = destino / f"{seguro}.png"
            tmp = alvo.with_suffix(".png.tmp")
            tmp.write_bytes(dados)
            tmp.replace(alvo)   # atomico: o notify-send pode ler no meio
            return str(alvo)
        except OSError as exc:
            log.warning("nao consegui gravar o icone de %s: %s", pacote, exc)
            return None

    # ---------- comandos ----------

    async def handle_command(self, command, body):
        match command:
            case "list":
                return {"devices": self._listagem()}
            case "fs.list" | "fs.read":
                alvo = body.get("device_id") or self._unico_pareado()
                if alvo is None:
                    return {"error": "informe device_id: nao ha exatamente um aparelho conectado"}
                if command == "fs.list":
                    return await self._transport.listar_arquivos(alvo, body.get("path", ""))
                return await self._transport.ler_arquivo(
                    alvo, body.get("path", ""),
                    int(body.get("offset", 0)), int(body.get("size", 0)) or 196608,
                )
            case "reply":
                # device_id opcional: com um celular so, que e o caso dele,
                # exigir o id na linha de comando so daria trabalho a toa.
                alvo = body.get("device_id") or self._unico_pareado()
                if alvo is None:
                    return {"ok": False, "error": "informe device_id"}
                ok = await self._transport.responder_notificacao(
                    alvo, body.get("key", ""), body.get("text", "")
                )
                return {"ok": ok}
            case "pair":
                ok = await self._transport.request_pair(body["device_id"])
                return {"ok": ok}
            case "confirm":
                ok = await self._transport.confirm_pair(
                    body["device_id"], bool(body.get("accept", False))
                )
                return {"ok": ok}
            case "unpair":
                return {"ok": await self._transport.unpair(body["device_id"])}
            case "ping":
                return {"latency_ms": await self._transport.ping(body["device_id"])}
            case "connect":
                sessao = await self._transport.connect(
                    body["host"], int(body.get("port", self.cfg.tcp_port))
                )
                return {"ok": sessao is not None}
            case _:
                raise ValueError(f"comando desconhecido: {command}")

    def _listagem(self):
        conectados = {s.device_id: s for s in self._transport.sessions()}
        ids = set(conectados) | {d.device_id for d in self._trust.all()} | set(self._vistos)
        resultado = []
        for device_id in sorted(ids):
            sessao = conectados.get(device_id)
            confiavel = self._trust.get(device_id)
            visto = self._vistos.get(device_id)
            nome = (
                (sessao.name if sessao else None)
                or (confiavel.name if confiavel else None)
                or (visto[0].name if visto else device_id)
            )
            resultado.append({
                "device_id": device_id,
                "name": nome,
                "paired": confiavel is not None,
                "connected": sessao is not None,
                "address": sessao.address if sessao else (visto[1] if visto else None),
            })
        return resultado
