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


async def test_queda_limpa_emite_disconnected(tmp_path):
    """Fechamento educado do outro lado: o EOF do laco de leitura resolve.

    Este caminho nao passa pelo heartbeat, e o teste seguinte cobre o que passa.
    """
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


async def test_sessao_pendurada_e_derrubada_pelo_heartbeat(tmp_path):
    """Socket vivo e mudo, que e o que acontece de verdade quando o WiFi cai.

    Nao ha FIN nesse caso: o socket continua aberto e nunca chega EOF. Sem o
    heartbeat a sessao ficaria pendurada para sempre, e o aparelho apareceria
    como conectado sem estar. Por isso o teste envelhece o registro de
    atividade em vez de fechar a conexao: fechar exercitaria o EOF, nao o
    mecanismo de staleness.
    """
    a = await monta(tmp_path, "a", 45209, ping_interval=0.1, session_timeout=0.3)
    b = await monta(tmp_path, "b", 45210, ping_interval=0.1, session_timeout=0.3)
    try:
        await parear(a, b)
        sessao = a.tr.sessions()[0]
        agora = asyncio.get_running_loop().time()
        a.tr._ultimo_pacote[id(sessao)] = agora - 999

        await asyncio.sleep(0.6)

        assert a.tr.sessions() == [], "o heartbeat deveria ter derrubado a sessao"
        estados = [p for k, p in a.eventos if k == "device.state"]
        assert estados[-1]["state"] == "disconnected"
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


async def test_pareamento_sobrevive_ao_heartbeat(tmp_path):
    """O heartbeat nao pode matar uma sessao que ainda esta pareando.

    phone.ping nao comeca com pair., entao pingar uma sessao nao pareada faz o
    gate do outro lado derrubar a conexao. Em producao isso significava que o
    pareamento nunca fechava: o ping saia a cada 30s e o usuario tinha 60s para
    confirmar nos dois aparelhos. Com ping bem mais rapido que o prazo de
    pareamento, o teste reproduz a corrida.
    """
    a = await monta(tmp_path, "a", 45211, ping_interval=0.05, pair_timeout=5.0)
    b = await monta(tmp_path, "b", 45212, ping_interval=0.05, pair_timeout=5.0)
    try:
        await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.1)
        await a.tr.request_pair(b.cfg.device_id)
        # Bem mais que varios ping_interval, para o heartbeat ter chance de agir.
        await asyncio.sleep(0.6)

        assert a.tr.sessions(), "a sessao caiu antes de o usuario confirmar"
        assert b.tr.sessions(), "a sessao caiu antes de o usuario confirmar"

        await b.tr.confirm_pair(a.cfg.device_id, True)
        await a.tr.confirm_pair(b.cfg.device_id, True)
        await asyncio.sleep(0.2)
        assert a.trust.get(b.cfg.device_id) is not None
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
