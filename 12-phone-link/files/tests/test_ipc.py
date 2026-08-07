import asyncio

import pytest

from phoned import ipc, protocol


async def cliente(caminho):
    return await asyncio.open_unix_connection(str(caminho))


async def test_comando_recebe_resposta(tmp_path):
    async def handler(command, body):
        return {"eco": command, "recebido": body}

    servidor = ipc.IpcServer(tmp_path / "ipc.sock", handler)
    await servidor.start()
    try:
        reader, writer = await cliente(tmp_path / "ipc.sock")
        writer.write(protocol.encode(protocol.make_packet("list", {"x": 1}, packet_id="req-1")))
        await writer.drain()
        resposta = protocol.decode(await reader.readline())
        writer.close()
    finally:
        await servidor.stop()

    assert resposta["type"] == "list.result"
    assert resposta["body"]["request_id"] == "req-1"
    assert resposta["body"]["eco"] == "list"
    assert resposta["body"]["recebido"] == {"x": 1}


async def test_broadcast_chega_a_todos_os_clientes(tmp_path):
    async def handler(command, body):
        return {}

    servidor = ipc.IpcServer(tmp_path / "ipc.sock", handler)
    await servidor.start()
    try:
        r1, w1 = await cliente(tmp_path / "ipc.sock")
        r2, w2 = await cliente(tmp_path / "ipc.sock")
        await asyncio.sleep(0.05)
        servidor.broadcast("device.state", {"device_id": "a", "state": "connected"})
        await asyncio.sleep(0.05)
        p1 = protocol.decode(await r1.readline())
        p2 = protocol.decode(await r2.readline())
        w1.close()
        w2.close()
    finally:
        await servidor.stop()

    assert p1["type"] == p2["type"] == "device.state"
    assert p1["body"]["device_id"] == "a"


async def test_linha_invalida_gera_erro_e_nao_derruba_o_servidor(tmp_path):
    async def handler(command, body):
        return {"ok": True}

    servidor = ipc.IpcServer(tmp_path / "ipc.sock", handler)
    await servidor.start()
    try:
        reader, writer = await cliente(tmp_path / "ipc.sock")
        writer.write(b"nao e json\n")
        await writer.drain()
        erro = protocol.decode(await reader.readline())
        writer.write(protocol.encode(protocol.make_packet("list", packet_id="req-2")))
        await writer.drain()
        ok = protocol.decode(await reader.readline())
        writer.close()
    finally:
        await servidor.stop()

    assert erro["type"] == "error"
    assert ok["type"] == "list.result"


async def test_handler_que_levanta_excecao_vira_pacote_de_erro(tmp_path):
    async def handler(command, body):
        raise RuntimeError("estourou")

    servidor = ipc.IpcServer(tmp_path / "ipc.sock", handler)
    await servidor.start()
    try:
        reader, writer = await cliente(tmp_path / "ipc.sock")
        writer.write(protocol.encode(protocol.make_packet("list", packet_id="req-3")))
        await writer.drain()
        resposta = protocol.decode(await reader.readline())
        writer.close()
    finally:
        await servidor.stop()

    assert resposta["type"] == "error"
    assert "estourou" in resposta["body"]["message"]


async def test_socket_orfao_e_removido_na_subida(tmp_path):
    caminho = tmp_path / "ipc.sock"
    caminho.write_text("resto de um daemon morto")

    async def handler(command, body):
        return {}

    servidor = ipc.IpcServer(caminho, handler)
    await servidor.start()
    try:
        reader, writer = await cliente(caminho)
        writer.close()
    finally:
        await servidor.stop()
    assert not caminho.exists()


async def test_socket_tem_permissao_restrita(tmp_path):
    async def handler(command, body):
        return {}

    caminho = tmp_path / "ipc.sock"
    servidor = ipc.IpcServer(caminho, handler)
    await servidor.start()
    try:
        assert caminho.stat().st_mode & 0o077 == 0
    finally:
        await servidor.stop()
