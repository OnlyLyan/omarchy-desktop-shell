import asyncio

import pytest

from phoned import config, discovery, pairing, protocol, transport


class Par:
    """Um daemon de mentira: config, truststore, identity e transport."""

    def __init__(self, cfg, trust, identity, tr, eventos):
        self.cfg, self.trust, self.identity, self.tr, self.eventos = (
            cfg, trust, identity, tr, eventos
        )

    def evento(self, kind):
        return [p for k, p in self.eventos if k == kind]


async def monta(tmp_path, nome, porta, confia=None, **overrides):
    """Sobe um Transport isolado.

    Os overrides existem porque mudar cfg depois de start() nao adianta para
    intervalos: o laco de heartbeat ja entrou no primeiro sleep com o valor
    antigo. Quem testa temporizacao precisa configurar antes de subir.

    confia recebe pares (device_id, caminho do certificado) gravados no
    truststore ANTES do start. Precisa ser antes porque o contexto TLS do
    servidor nasce em start(): so com truststore ja povoado o listener sobe
    exigindo certificado de cliente.
    """
    parametros = {
        "name": nome, "tcp_port": porta, "discovery_port": porta,
        "announce_targets": [], "pair_timeout": 1.0,
    }
    parametros.update(overrides)
    cfg = config.load_config(
        state_dir=tmp_path / nome / "state", runtime_dir=tmp_path / nome / "run",
        **parametros,
    )
    pairing.ensure_certificate(cfg.cert_path, cfg.key_path, cfg.device_id)
    trust = pairing.TrustStore(cfg.devices_path)
    trust.load()
    for device_id, caminho in confia or []:
        trust.add(pairing.Device(
            device_id=device_id, name=device_id,
            fingerprint=pairing.fingerprint_of_file(caminho),
            certificate=caminho.read_text(),
        ))
    if confia:
        trust.save()
    identity = discovery.Identity(
        device_id=cfg.device_id, name=nome, device_type="desktop",
        port=porta, protocol_version=config.PROTOCOL_VERSION, capabilities=["ping"],
    )
    eventos = []
    tr = transport.Transport(cfg, trust, identity, lambda k, p: eventos.append((k, p)))
    await tr.start()
    return Par(cfg, trust, identity, tr, eventos)


async def parear(a, b, conecta=None):
    """Faz a parear com b, com confirmacao dos dois lados.

    Quem pede o pareamento e sempre a. Quem abre o socket TCP e conecta, que
    por padrao tambem e a. Passando conecta=b o pedido passa a sair do lado
    que e servidor de TLS, metade da maquina de estados que so esse parametro
    exercita, e que e justamente a que um celular real usa: quem disca e o
    aparelho.
    """
    conecta = conecta if conecta is not None else a
    alvo = b if conecta is a else a
    await conecta.tr.connect("127.0.0.1", alvo.cfg.tcp_port)
    await asyncio.sleep(0.1)
    assert await a.tr.request_pair(b.cfg.device_id), "a nao conseguiu pedir o pareamento"
    await asyncio.sleep(0.1)
    assert await b.tr.confirm_pair(a.cfg.device_id, True), "b nao tinha o que confirmar"
    # Quando o pedido sai do lado servidor, o codigo so existe em a depois que
    # o pair.accept de b chega com o certificado dentro. Sem esta pausa a
    # confirmacao de a corre na frente do proprio codigo.
    await asyncio.sleep(0.1)
    assert await a.tr.confirm_pair(b.cfg.device_id, True), "a nao tinha o que confirmar"
    await asyncio.sleep(0.1)


async def test_pareamento_gera_o_mesmo_codigo_nos_dois_lados(tmp_path):
    a = await monta(tmp_path, "a", 21101)
    b = await monta(tmp_path, "b", 21102)
    try:
        await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.1)
        await a.tr.request_pair(b.cfg.device_id)
        await asyncio.sleep(0.1)

        codigo_a = a.evento("pair.prompt")[0]["code"]
        codigo_b = b.evento("pair.prompt")[0]["code"]
        assert codigo_a == codigo_b
        assert len(codigo_a) == 6
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_pareamento_confirmado_grava_nos_dois_truststores(tmp_path):
    a = await monta(tmp_path, "a", 21103)
    b = await monta(tmp_path, "b", 21104)
    try:
        await parear(a, b)
        assert a.trust.get(b.cfg.device_id) is not None
        assert b.trust.get(a.cfg.device_id) is not None
        assert a.trust.get(b.cfg.device_id).fingerprint == pairing.fingerprint_of_file(
            b.cfg.cert_path
        )
        assert a.cfg.devices_path.exists()
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_recusa_de_um_lado_nao_pareia_ninguem(tmp_path):
    a = await monta(tmp_path, "a", 21105)
    b = await monta(tmp_path, "b", 21106)
    try:
        await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.1)
        await a.tr.request_pair(b.cfg.device_id)
        await asyncio.sleep(0.1)
        await b.tr.confirm_pair(a.cfg.device_id, False)
        await asyncio.sleep(0.1)

        assert a.trust.get(b.cfg.device_id) is None
        assert b.trust.get(a.cfg.device_id) is None
        assert a.evento("pair.result")[0]["accepted"] is False
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_sessao_nao_pareada_e_derrubada_ao_enviar_tipo_comum(tmp_path):
    a = await monta(tmp_path, "a", 21107)
    b = await monta(tmp_path, "b", 21108)
    try:
        sessao = await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.1)
        await sessao.send(protocol.make_packet("phone.ping"))
        await asyncio.sleep(0.2)
        assert b.tr.sessions() == []
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_pareamento_expira_pelo_timeout(tmp_path):
    a = await monta(tmp_path, "a", 21109)
    b = await monta(tmp_path, "b", 21110)
    try:
        await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.1)
        await a.tr.request_pair(b.cfg.device_id)
        await asyncio.sleep(1.4)

        assert a.trust.get(b.cfg.device_id) is None
        assert a.evento("pair.result")[-1]["reason"] == "timeout"
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_unpair_remove_dos_dois_lados_do_ponto_de_vista_local(tmp_path):
    a = await monta(tmp_path, "a", 21111)
    b = await monta(tmp_path, "b", 21112)
    try:
        await parear(a, b)
        assert await a.tr.unpair(b.cfg.device_id) is True
        assert a.trust.get(b.cfg.device_id) is None
        assert await a.tr.unpair(b.cfg.device_id) is False
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_identity_repetido_derruba_a_sessao(tmp_path):
    """Sessao pareada nao pode se re-rotular como outro aparelho.

    Sem a guarda, quem pareou como A mandaria um segundo identity dizendo ser X,
    o bloco de confianca seria pulado por X ser desconhecido, mas paired
    continuaria True e o gate deixaria passar qualquer tipo.
    """
    a = await monta(tmp_path, "a", 21115)
    b = await monta(tmp_path, "b", 21116)
    try:
        await parear(a, b)
        sessao = a.tr.sessions()[0]
        assert sessao.paired is True

        falsa = discovery.Identity(
            device_id="nunca-pareado", name="intruso", device_type="phone",
            port=1, protocol_version=config.PROTOCOL_VERSION, capabilities=[],
        )
        await sessao.send(protocol.make_packet("identity", falsa.to_body()))
        await asyncio.sleep(0.3)

        assert b.tr.sessions() == [], "a sessao deveria ter sido derrubada"
        assert b.trust.get("nunca-pareado") is None
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_fingerprint_diferente_recusa_aparelho_conhecido(tmp_path):
    """Aparelho no truststore com outro certificado nao entra.

    E o caso do app reinstalado. Aceitar em silencio anularia o pareamento.
    """
    a = await monta(tmp_path, "a", 21117)
    b = await monta(tmp_path, "b", 21118)
    try:
        await parear(a, b)
        # b passa a conhecer a com um fingerprint que nao e o dele.
        conhecido = b.trust.get(a.cfg.device_id)
        b.trust.add(pairing.Device(
            device_id=conhecido.device_id, name=conhecido.name,
            fingerprint="F" * 64, certificate=conhecido.certificate,
        ))
        for sessao in list(a.tr.sessions()) + list(b.tr.sessions()):
            await sessao.close()
        await asyncio.sleep(0.2)

        await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.3)
        assert b.tr.sessions() == [], "fingerprint divergente deveria recusar"
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_pair_request_com_pem_divergente_e_recusado(tmp_path):
    """O certificado do corpo tem que ser o mesmo do canal TLS.

    Divergencia significa alguem tentando parear com credencial de terceiro.
    """
    a = await monta(tmp_path, "a", 21119)
    b = await monta(tmp_path, "b", 21120)
    terceiro_cert = tmp_path / "terceiro-cert.pem"
    terceiro_key = tmp_path / "terceiro-key.pem"
    pairing.ensure_certificate(terceiro_cert, terceiro_key, "terceiro")
    try:
        sessao = await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.2)
        await sessao.send(protocol.make_packet(
            "pair.request", {"certificate": terceiro_cert.read_text()}
        ))
        await asyncio.sleep(0.3)

        assert b.trust.get(a.cfg.device_id) is None
        assert b.cfg.device_id not in b.tr._pending
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_pareamento_no_sentido_servidor_para_cliente(tmp_path):
    """Quem pede o pareamento e o lado que NAO abriu a conexao.

    E o sentido que o celular real vai usar: quem disca e o aparelho, e o
    pedido pode sair do PC. Nesse sentido o canal TLS nao carrega certificado
    do outro lado (servidor sem truststore nao pede certificado de cliente),
    entao o fingerprint precisa vir do PEM que o pair.accept traz.
    """
    a = await monta(tmp_path, "a", 21121)
    b = await monta(tmp_path, "b", 21122)
    try:
        await parear(a, b, conecta=b)

        assert a.trust.get(b.cfg.device_id) is not None
        assert b.trust.get(a.cfg.device_id) is not None
        assert a.trust.get(b.cfg.device_id).fingerprint == pairing.fingerprint_of_file(
            b.cfg.cert_path
        )
        assert a.evento("pair.prompt")[0]["code"] == b.evento("pair.prompt")[0]["code"]
        assert a.tr.sessions()[0].paired is True
        assert b.tr.sessions()[0].paired is True
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_par_reconecta_de_fora_e_entra_como_pareado(tmp_path):
    """Depois de parear, o outro lado disca para nos e e aceito sem reparear.

    O contexto TLS do listener nasce em start(), quando o truststore ainda
    estava vazio. Se ele nao acompanhar o truststore, o servidor continua sem
    pedir certificado de cliente, o aparelho recem pareado chega sem
    fingerprint e e recusado a cada tentativa ate o daemon reiniciar.
    """
    a = await monta(tmp_path, "a", 21123)
    b = await monta(tmp_path, "b", 21124)
    try:
        await parear(a, b)
        for sessao in list(a.tr.sessions()) + list(b.tr.sessions()):
            await sessao.close()
        await asyncio.sleep(0.2)
        assert a.tr.sessions() == [] and b.tr.sessions() == []

        await b.tr.connect("127.0.0.1", a.cfg.tcp_port)
        await asyncio.sleep(0.3)

        assert [s.device_id for s in a.tr.sessions()] == [b.cfg.device_id]
        assert a.tr.sessions()[0].paired is True, "reconexao de entrada nao foi aceita"
        assert b.tr.sessions()[0].paired is True
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_segundo_aparelho_pareia_com_os_dois_truststores_cheios(tmp_path):
    """Aparelho que ja pareou com outra maquina ainda consegue parear aqui.

    Com truststore nao vazio dos dois lados, apresentar certificado a quem
    ainda nao te conhece derruba o handshake, e a recusa acontece abaixo do
    _on_inbound, sem log nenhum. E o bug do segundo aparelho.
    """
    outro_cert = tmp_path / "outro-cert.pem"
    outro_key = tmp_path / "outro-key.pem"
    pairing.ensure_certificate(outro_cert, outro_key, "outro")
    a = await monta(tmp_path, "a", 21125, confia=[("velho-do-a", outro_cert)])
    b = await monta(tmp_path, "b", 21126, confia=[("velho-do-b", outro_cert)])
    try:
        await a.tr.ensure_connected(b.identity, "127.0.0.1")
        await asyncio.sleep(0.2)
        assert a.tr.sessions(), "o handshake caiu antes de qualquer pareamento"

        assert await a.tr.request_pair(b.cfg.device_id)
        await asyncio.sleep(0.1)
        assert await b.tr.confirm_pair(a.cfg.device_id, True)
        await asyncio.sleep(0.1)
        assert await a.tr.confirm_pair(b.cfg.device_id, True)
        await asyncio.sleep(0.1)

        assert a.trust.get(b.cfg.device_id) is not None
        assert b.trust.get(a.cfg.device_id) is not None
        assert a.trust.get("velho-do-a") is not None, "o pareamento antigo sumiu"
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_conexao_duplicada_para_o_mesmo_aparelho_e_fechada(tmp_path):
    a = await monta(tmp_path, "a", 21113)
    b = await monta(tmp_path, "b", 21114)
    try:
        await parear(a, b)
        await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.2)
        ids = [s.device_id for s in b.tr.sessions()]
        assert ids.count(a.cfg.device_id) == 1
    finally:
        await a.tr.stop()
        await b.tr.stop()
