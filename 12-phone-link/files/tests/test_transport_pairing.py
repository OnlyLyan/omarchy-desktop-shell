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
