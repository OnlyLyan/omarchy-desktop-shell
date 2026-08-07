import asyncio

import pytest

from phoned import config, discovery, pairing, protocol, transport

from .test_transport_pairing import monta, parear


async def test_ping_retorna_latencia_em_milissegundos(tmp_path):
    a = await monta(tmp_path, "a", 45201)
    b = await monta(tmp_path, "b", 45202)
    try:
        await parear(a, b)
        latencia = await a.tr.ping(b.cfg.device_id)
        assert latencia is not None
        assert 0 <= latencia < 5000
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_ping_para_aparelho_desconhecido_retorna_none(tmp_path):
    a = await monta(tmp_path, "a", 45203)
    try:
        assert await a.tr.ping("nao-existe") is None
    finally:
        await a.tr.stop()


async def test_sessao_morta_por_timeout_emite_disconnected(tmp_path):
    a = await monta(tmp_path, "a", 45204)
    b = await monta(tmp_path, "b", 45205)
    a.cfg.ping_interval = 0.1
    a.cfg.session_timeout = 0.3
    try:
        await parear(a, b)
        # Corta o outro lado sem avisar, simulando queda de WiFi.
        for sessao in b.tr.sessions():
            await sessao.close()
        await asyncio.sleep(1.0)
        estados = [p for k, p in a.eventos if k == "device.state"]
        assert estados[-1]["state"] == "disconnected"
        assert a.tr.sessions() == []
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_ensure_connected_nao_abre_segunda_conexao(tmp_path):
    a = await monta(tmp_path, "a", 45206)
    b = await monta(tmp_path, "b", 45207)
    try:
        await parear(a, b)
        identidade_b = discovery.Identity(
            device_id=b.cfg.device_id, name="b", device_type="desktop",
            port=b.cfg.tcp_port, protocol_version=config.PROTOCOL_VERSION,
            capabilities=["ping"],
        )
        await a.tr.ensure_connected(identidade_b, "127.0.0.1")
        await asyncio.sleep(0.2)
        assert len(a.tr.sessions()) == 1
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_backoff_dobra_e_respeita_o_teto(tmp_path):
    a = await monta(tmp_path, "a", 45208)
    try:
        assert a.tr._proximo_backoff("x") == 1.0
        assert a.tr._proximo_backoff("x") == 2.0
        assert a.tr._proximo_backoff("x") == 4.0
        for _ in range(20):
            valor = a.tr._proximo_backoff("x")
        assert valor == 60.0
        a.tr._zera_backoff("x")
        assert a.tr._proximo_backoff("x") == 1.0
    finally:
        await a.tr.stop()
