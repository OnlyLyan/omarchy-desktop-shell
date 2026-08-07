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
    d = await sobe(tmp_path, "a", 21301, [])
    try:
        assert await d.handle_command("list", {}) == {"devices": []}
    finally:
        await d.stop()


async def test_comando_desconhecido_levanta_erro(tmp_path):
    d = await sobe(tmp_path, "a", 21302, [])
    try:
        with pytest.raises(ValueError):
            await d.handle_command("inventado", {})
    finally:
        await d.stop()


async def test_descoberta_leva_a_conexao_automatica(tmp_path):
    a = await sobe(tmp_path, "a", 21303, [("127.0.0.1", 21304)])
    b = await sobe(tmp_path, "b", 21304, [("127.0.0.1", 21303)])
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
    d = await sobe(tmp_path, "a", 21305, [])
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
    a = await sobe(tmp_path, "a", 21306, [("127.0.0.1", 21307)])
    try:
        reader, writer = await asyncio.open_unix_connection(str(a.cfg.ipc_path))
        b = await sobe(tmp_path, "b", 21307, [("127.0.0.1", 21306)])
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
    d = await sobe(tmp_path, "a", 21308, [])
    caminho = d.cfg.ipc_path
    assert caminho.exists()
    await d.stop()
    assert not caminho.exists()


async def test_porta_ocupada_falha_sem_deixar_socket(tmp_path):
    primeiro = await sobe(tmp_path, "a", 21309, [])
    try:
        cfg = config.load_config(
            state_dir=tmp_path / "b" / "state", runtime_dir=tmp_path / "b" / "run",
            name="b", tcp_port=21309, discovery_port=21310, announce_targets=[],
        )
        segundo = daemon.Daemon(cfg)
        with pytest.raises(OSError):
            try:
                await segundo.start()
            finally:
                await segundo.stop()
        assert not cfg.ipc_path.exists(), "socket do IPC ficou para tras"
    finally:
        await primeiro.stop()
