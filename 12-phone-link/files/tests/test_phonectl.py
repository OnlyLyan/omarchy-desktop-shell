import asyncio
import json
import subprocess
import sys
from pathlib import Path

import pytest

RAIZ = Path(__file__).resolve().parent.parent
PHONECTL = RAIZ / "phonectl"


async def servidor_falso(caminho, respostas):
    """Unix socket que responde a qualquer comando com um pacote fixo."""

    async def atende(reader, writer):
        while True:
            linha = await reader.readline()
            if not linha:
                break
            pedido = json.loads(linha)
            corpo = dict(respostas.get(pedido["type"], {}))
            corpo["request_id"] = pedido["id"]
            writer.write(json.dumps({
                "id": "resp", "type": f"{pedido['type']}.result",
                "ts": 1, "body": corpo,
            }).encode() + b"\n")
            await writer.drain()

    return await asyncio.start_unix_server(atende, path=str(caminho))


def roda(caminho, *args):
    return subprocess.run(
        [sys.executable, str(PHONECTL), "--socket", str(caminho), *args],
        capture_output=True, text=True, timeout=10,
    )


async def test_list_imprime_tabela(tmp_path):
    caminho = tmp_path / "ipc.sock"
    srv = await servidor_falso(caminho, {"list": {"devices": [
        {"device_id": "cel-1", "name": "celular", "paired": True,
         "connected": True, "address": "192.168.0.5"},
    ]}})
    try:
        resultado = await asyncio.to_thread(roda, caminho, "list")
    finally:
        srv.close()
    assert resultado.returncode == 0
    assert "celular" in resultado.stdout
    assert "cel-1" in resultado.stdout
    assert "192.168.0.5" in resultado.stdout


async def test_list_sem_aparelhos_avisa(tmp_path):
    caminho = tmp_path / "ipc.sock"
    srv = await servidor_falso(caminho, {"list": {"devices": []}})
    try:
        resultado = await asyncio.to_thread(roda, caminho, "list")
    finally:
        srv.close()
    assert resultado.returncode == 0
    assert "nenhum aparelho" in resultado.stdout.lower()


async def test_ping_mostra_latencia(tmp_path):
    caminho = tmp_path / "ipc.sock"
    srv = await servidor_falso(caminho, {"ping": {"latency_ms": 12.5}})
    try:
        resultado = await asyncio.to_thread(roda, caminho, "ping", "cel-1")
    finally:
        srv.close()
    assert resultado.returncode == 0
    assert "12.5" in resultado.stdout


async def test_ping_sem_resposta_sai_com_erro(tmp_path):
    caminho = tmp_path / "ipc.sock"
    srv = await servidor_falso(caminho, {"ping": {"latency_ms": None}})
    try:
        resultado = await asyncio.to_thread(roda, caminho, "ping", "cel-1")
    finally:
        srv.close()
    assert resultado.returncode == 1
    assert "sem resposta" in resultado.stderr.lower()


async def test_confirm_com_reject_envia_accept_false(tmp_path):
    caminho = tmp_path / "ipc.sock"
    recebidos = []

    async def atende(reader, writer):
        linha = await reader.readline()
        pedido = json.loads(linha)
        recebidos.append(pedido)
        writer.write(json.dumps({
            "id": "r", "type": "confirm.result", "ts": 1,
            "body": {"ok": True, "request_id": pedido["id"]},
        }).encode() + b"\n")
        await writer.drain()

    srv = await asyncio.start_unix_server(atende, path=str(caminho))
    try:
        resultado = await asyncio.to_thread(roda, caminho, "confirm", "cel-1", "--reject")
    finally:
        srv.close()
    assert resultado.returncode == 0
    assert recebidos[0]["body"] == {"device_id": "cel-1", "accept": False}


def test_daemon_desligado_da_mensagem_util(tmp_path):
    resultado = roda(tmp_path / "nao-existe.sock", "list")
    assert resultado.returncode == 1
    assert "phoned" in resultado.stderr.lower()


async def test_evento_empurrado_nao_e_confundido_com_resposta(tmp_path):
    caminho = tmp_path / "ipc.sock"

    async def atende(reader, writer):
        pedido = json.loads(await reader.readline())
        # Evento de broadcast com o MESMO tipo da resposta, sem request_id.
        writer.write(json.dumps({
            "id": "evt", "type": "pair.result", "ts": 1,
            "body": {"device_id": "outro-aparelho", "accepted": False,
                     "reason": "timeout"},
        }).encode() + b"\n")
        await writer.drain()
        writer.write(json.dumps({
            "id": "resp", "type": "pair.result", "ts": 1,
            "body": {"ok": True, "request_id": pedido["id"]},
        }).encode() + b"\n")
        await writer.drain()

    srv = await asyncio.start_unix_server(atende, path=str(caminho))
    try:
        resultado = await asyncio.to_thread(roda, caminho, "pair", "cel-1")
    finally:
        srv.close()

    assert resultado.returncode == 0
    assert "ok" in resultado.stdout


async def test_resposta_acima_de_64k_nao_estoura_o_buffer(tmp_path):
    """O buffer default do StreamReader e 64KB e o daemon escreve ate 1MiB.

    Uma listagem grande, ou o `list` de uma casa com varios aparelhos, passa
    de 64KB sem esforco. Sem limit= no open_unix_connection isso vira
    LimitOverrunError cru na cara do usuario, antes de qualquer parse.
    """
    caminho = tmp_path / "ipc.sock"
    nome = "z" * 300_000
    srv = await servidor_falso(caminho, {"list": {"devices": [
        {"device_id": "cel-1", "name": nome, "paired": True,
         "connected": True, "address": "192.168.0.5"},
    ]}})
    try:
        resultado = await asyncio.to_thread(roda, caminho, "list")
    finally:
        srv.close()
    assert "Traceback" not in resultado.stderr
    assert resultado.returncode == 0, resultado.stderr[-400:]
    assert nome in resultado.stdout


async def test_daemon_que_cai_no_meio_nao_da_traceback(tmp_path):
    caminho = tmp_path / "ipc.sock"

    async def atende(reader, writer):
        await reader.readline()
        writer.close()  # fecha sem responder

    srv = await asyncio.start_unix_server(atende, path=str(caminho))
    try:
        resultado = await asyncio.to_thread(roda, caminho, "list")
    finally:
        srv.close()

    assert resultado.returncode == 1
    assert "Traceback" not in resultado.stderr
