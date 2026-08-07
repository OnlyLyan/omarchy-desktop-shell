"""Duas instancias completas do phoned no mesmo host, por loopback.

Substitui o celular durante o desenvolvimento e cobre o caminho inteiro do
spec: descoberta, pareamento, sessao, ping, queda e volta.
"""

import asyncio

import pytest

from phoned import config, daemon, protocol


async def sobe(tmp_path, nome, porta, porta_do_outro):
    cfg = config.load_config(
        state_dir=tmp_path / nome / "state",
        runtime_dir=tmp_path / nome / "run",
        name=nome,
        tcp_port=porta,
        discovery_port=porta,
        announce_targets=[("127.0.0.1", porta_do_outro)],
        announce_interval=0.3,
        ping_interval=0.3,
        session_timeout=1.5,
        pair_timeout=10.0,
    )
    servico = daemon.Daemon(cfg)
    await servico.start()
    return servico


async def espera(condicao, timeout=8.0, intervalo=0.1):
    limite = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < limite:
        if await condicao():
            return True
        await asyncio.sleep(intervalo)
    return False


async def test_fluxo_completo_descobrir_parear_pingar_e_reconectar(tmp_path):
    a = await sobe(tmp_path, "pc", 45401, 45402)
    b = await sobe(tmp_path, "celular", 45402, 45401)
    try:
        # 1. Descoberta automatica.
        async def conectaram():
            listagem = await a.handle_command("list", {})
            return any(d["connected"] for d in listagem["devices"])

        assert await espera(conectaram), "os dois nao se descobriram"

        # 2. Pareamento com confirmacao nos dois lados.
        assert (await a.handle_command("pair", {"device_id": b.cfg.device_id}))["ok"]

        # Esperar so o lado de quem pediu nao serve: request_pair preenche
        # _pending localmente e de forma sincrona, antes de o pacote sair. E
        # preciso esperar o outro lado ter processado o pair.request, senao a
        # confirmacao chega antes de existir o que confirmar.
        async def pendente_nos_dois():
            return (
                b.cfg.device_id in a._transport._pending
                and a.cfg.device_id in b._transport._pending
            )

        assert await espera(pendente_nos_dois), "o pareamento nao ficou pendente nos dois lados"

        confirmou_b = await b.handle_command(
            "confirm", {"device_id": a.cfg.device_id, "accept": True}
        )
        confirmou_a = await a.handle_command(
            "confirm", {"device_id": b.cfg.device_id, "accept": True}
        )
        # Ignorar este retorno foi o que escondeu a corrida: confirm_pair
        # devolvia ok False por nao achar a pendencia, e o teste seguia adiante.
        assert confirmou_b["ok"], "b nao aceitou a confirmacao"
        assert confirmou_a["ok"], "a nao aceitou a confirmacao"

        async def parearam():
            listagem = await a.handle_command("list", {})
            return all(d["paired"] for d in listagem["devices"])

        assert await espera(parearam), "o pareamento nao concluiu"
        assert a.cfg.devices_path.exists()
        assert b.cfg.devices_path.exists()

        # 3. Ping medido.
        resposta = await a.handle_command("ping", {"device_id": b.cfg.device_id})
        assert resposta["latency_ms"] is not None

        # 4. Queda e volta, sem reparear.
        await b.stop()

        async def caiu():
            listagem = await a.handle_command("list", {})
            return not any(d["connected"] for d in listagem["devices"])

        assert await espera(caiu), "a queda nao foi detectada"

        b = await sobe(tmp_path, "celular", 45402, 45401)

        async def voltou():
            listagem = await a.handle_command("list", {})
            return any(d["connected"] and d["paired"] for d in listagem["devices"])

        assert await espera(voltou), "nao reconectou sozinho"

        # 5. Continua funcionando sem novo pareamento.
        resposta = await a.handle_command("ping", {"device_id": b.cfg.device_id})
        assert resposta["latency_ms"] is not None
    finally:
        await a.stop()
        await b.stop()


async def test_terceiro_nao_pareado_nao_consegue_enviar_ping(tmp_path):
    a = await sobe(tmp_path, "pc", 45403, 45404)
    intruso = await sobe(tmp_path, "intruso", 45404, 45403)
    try:
        async def conectaram():
            return len(a._transport.sessions()) == 1

        assert await espera(conectaram)
        sessao = a._transport.sessions()[0]
        assert sessao.paired is False

        # O intruso tenta trafegar sem parear.
        sessao_do_intruso = intruso._transport.sessions()
        assert sessao_do_intruso, "o intruso deveria ter uma sessao aberta para testar"
        await sessao_do_intruso[0].send(protocol.make_packet("phone.ping"))

        # Janela curta de proposito, bem abaixo do session_timeout de 1.5s.
        # O heartbeat tambem derruba sessao nao pareada por inatividade, e a
        # descoberta reconecta logo depois, entao uma janela larga flagra essa
        # oscilacao natural e conclui que o gate agiu. Foi medido: com o gate
        # completamente desligado, uma janela de 4s passava em 1 de 4 execucoes.
        # So a rejeicao imediata do gate cabe em 0.8s.
        async def derrubou():
            return a._transport.sessions() == [] or intruso._transport.sessions() == []

        assert await espera(derrubou, timeout=0.8), "a sessao nao pareada nao foi cortada pelo gate"
    finally:
        await a.stop()
        await intruso.stop()
