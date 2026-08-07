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


async def monta(tmp_path, nome, porta):
    cfg = config.load_config(
        state_dir=tmp_path / nome / "state", runtime_dir=tmp_path / nome / "run",
        name=nome, tcp_port=porta, discovery_port=porta,
        announce_targets=[], pair_timeout=1.0,
    )
    pairing.ensure_certificate(cfg.cert_path, cfg.key_path, cfg.device_id)
    trust = pairing.TrustStore(cfg.devices_path)
    trust.load()
    identity = discovery.Identity(
        device_id=cfg.device_id, name=nome, device_type="desktop",
        port=porta, protocol_version=config.PROTOCOL_VERSION, capabilities=["ping"],
    )
    eventos = []
    tr = transport.Transport(cfg, trust, identity, lambda k, p: eventos.append((k, p)))
    await tr.start()
    return Par(cfg, trust, identity, tr, eventos)


async def parear(a, b):
    """Faz a parear com b, com confirmacao dos dois lados."""
    await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
    await asyncio.sleep(0.1)
    await a.tr.request_pair(b.cfg.device_id)
    await asyncio.sleep(0.1)
    await b.tr.confirm_pair(a.cfg.device_id, True)
    await a.tr.confirm_pair(b.cfg.device_id, True)
    await asyncio.sleep(0.1)


async def test_pareamento_gera_o_mesmo_codigo_nos_dois_lados(tmp_path):
    a = await monta(tmp_path, "a", 45101)
    b = await monta(tmp_path, "b", 45102)
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
    a = await monta(tmp_path, "a", 45103)
    b = await monta(tmp_path, "b", 45104)
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
    a = await monta(tmp_path, "a", 45105)
    b = await monta(tmp_path, "b", 45106)
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
    a = await monta(tmp_path, "a", 45107)
    b = await monta(tmp_path, "b", 45108)
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
    a = await monta(tmp_path, "a", 45109)
    b = await monta(tmp_path, "b", 45110)
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
    a = await monta(tmp_path, "a", 45111)
    b = await monta(tmp_path, "b", 45112)
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
    a = await monta(tmp_path, "a", 45115)
    b = await monta(tmp_path, "b", 45116)
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
    a = await monta(tmp_path, "a", 45117)
    b = await monta(tmp_path, "b", 45118)
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
    a = await monta(tmp_path, "a", 45119)
    b = await monta(tmp_path, "b", 45120)
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


async def test_conexao_duplicada_para_o_mesmo_aparelho_e_fechada(tmp_path):
    a = await monta(tmp_path, "a", 45113)
    b = await monta(tmp_path, "b", 45114)
    try:
        await parear(a, b)
        await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.2)
        ids = [s.device_id for s in b.tr.sessions()]
        assert ids.count(a.cfg.device_id) == 1
    finally:
        await a.tr.stop()
        await b.tr.stop()
