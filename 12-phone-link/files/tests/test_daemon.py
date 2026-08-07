import asyncio

import pytest

from phoned import config, daemon, protocol


async def sobe(tmp_path, nome, porta, alvos):
    cfg = config.load_config(
        state_dir=tmp_path / nome / "state", runtime_dir=tmp_path / nome / "run",
        name=nome, tcp_port=porta, discovery_port=porta,
        announce_targets=alvos, announce_interval=0.2, pair_timeout=5.0,
    )
    d = daemon.Daemon(cfg)
    await d.start()
    return d


async def test_list_comeca_vazio(tmp_path):
    d = await sobe(tmp_path, "a", 45301, [])
    try:
        assert await d.handle_command("list", {}) == {"devices": []}
    finally:
        await d.stop()


async def test_comando_desconhecido_levanta_erro(tmp_path):
    d = await sobe(tmp_path, "a", 45302, [])
    try:
        with pytest.raises(ValueError):
            await d.handle_command("inventado", {})
    finally:
        await d.stop()


async def test_descoberta_leva_a_conexao_automatica(tmp_path):
    a = await sobe(tmp_path, "a", 45303, [("127.0.0.1", 45304)])
    b = await sobe(tmp_path, "b", 45304, [("127.0.0.1", 45303)])
    try:
        await asyncio.sleep(1.0)
        listagem = await a.handle_command("list", {})
        assert [d["name"] for d in listagem["devices"]] == ["b"]
        assert listagem["devices"][0]["connected"] is True
        assert listagem["devices"][0]["paired"] is False
    finally:
        await a.stop()
        await b.stop()


async def test_ipc_responde_ao_comando_list(tmp_path):
    d = await sobe(tmp_path, "a", 45305, [])
    try:
        reader, writer = await asyncio.open_unix_connection(str(d.cfg.ipc_path))
        writer.write(protocol.encode(protocol.make_packet("list", packet_id="r1")))
        await writer.drain()
        resposta = protocol.decode(await reader.readline())
        writer.close()
        assert resposta["type"] == "list.result"
        assert resposta["body"]["devices"] == []
    finally:
        await d.stop()


async def test_eventos_do_transport_sao_empurrados_pelo_ipc(tmp_path):
    a = await sobe(tmp_path, "a", 45306, [("127.0.0.1", 45307)])
    try:
        reader, writer = await asyncio.open_unix_connection(str(a.cfg.ipc_path))
        b = await sobe(tmp_path, "b", 45307, [("127.0.0.1", 45306)])
        try:
            evento = protocol.decode(await asyncio.wait_for(reader.readline(), timeout=5))
        finally:
            await b.stop()
        writer.close()
        assert evento["type"] == "device.state"
        assert evento["body"]["state"] == "connected"
    finally:
        await a.stop()


async def test_stop_remove_o_socket(tmp_path):
    d = await sobe(tmp_path, "a", 45308, [])
    caminho = d.cfg.ipc_path
    assert caminho.exists()
    await d.stop()
    assert not caminho.exists()
