import asyncio
import ssl

import pytest

from phoned import pairing, protocol, transport


@pytest.fixture
def par_de_certificados(tmp_path):
    servidor = (tmp_path / "s-cert.pem", tmp_path / "s-key.pem")
    cliente = (tmp_path / "c-cert.pem", tmp_path / "c-key.pem")
    pairing.ensure_certificate(*servidor, "servidor")
    pairing.ensure_certificate(*cliente, "cliente")
    return servidor, cliente


async def conecta(servidor, cliente, ca_data, present_cert):
    (s_cert, s_key), (c_cert, c_key) = servidor, cliente
    visto = {}

    async def handler(reader, writer):
        visto["fp_do_cliente"] = transport.peer_fingerprint(writer)
        writer.close()

    sctx = transport.build_server_context(s_cert, s_key, ca_data)
    srv = await asyncio.start_server(handler, "127.0.0.1", 0, ssl=sctx)
    porta = srv.sockets[0].getsockname()[1]

    cctx = transport.build_client_context(c_cert, c_key, present_cert)
    reader, writer = await asyncio.open_connection("127.0.0.1", porta, ssl=cctx)
    visto["fp_do_servidor"] = transport.peer_fingerprint(writer)
    writer.close()
    srv.close()
    await srv.wait_closed()
    await asyncio.sleep(0.05)
    return visto


async def test_sem_pareamento_o_cliente_ve_o_servidor_e_o_servidor_nao_ve_o_cliente(
    par_de_certificados,
):
    servidor, cliente = par_de_certificados
    visto = await conecta(servidor, cliente, ca_data=None, present_cert=False)
    assert visto["fp_do_servidor"] == pairing.fingerprint_of_file(servidor[0])
    assert visto["fp_do_cliente"] is None


async def test_com_pareamento_a_autenticacao_e_mutua(par_de_certificados):
    servidor, cliente = par_de_certificados
    ca = cliente[0].read_text()
    visto = await conecta(servidor, cliente, ca_data=ca, present_cert=True)
    assert visto["fp_do_servidor"] == pairing.fingerprint_of_file(servidor[0])
    assert visto["fp_do_cliente"] == pairing.fingerprint_of_file(cliente[0])


async def test_cliente_desconhecido_e_recusado_quando_o_servidor_ja_confia_em_outro(
    par_de_certificados, tmp_path
):
    """O servidor confia so no terceiro, entao o cliente nao entra.

    Em TLS 1.3 o handshake do cliente termina ANTES de ele saber se o servidor
    aceitou seu certificado, e a recusa chega depois como EOF limpo, nao como
    excecao. Verificado nesta maquina com Python 3.14.6 e OpenSSL 3.6.3. Por
    isso o teste observa o efeito, conexao morta e handler nunca invocado, em
    vez de esperar um erro que nunca vem.
    """
    servidor, cliente = par_de_certificados
    terceiro = (tmp_path / "t-cert.pem", tmp_path / "t-key.pem")
    pairing.ensure_certificate(*terceiro, "terceiro")

    aceitou = []

    async def handler(reader, writer):
        aceitou.append(True)
        writer.close()

    sctx = transport.build_server_context(
        servidor[0], servidor[1], terceiro[0].read_text()
    )
    srv = await asyncio.start_server(handler, "127.0.0.1", 0, ssl=sctx)
    porta = srv.sockets[0].getsockname()[1]

    cctx = transport.build_client_context(cliente[0], cliente[1], present_cert=True)
    reader, writer = await asyncio.open_connection("127.0.0.1", porta, ssl=cctx)
    writer.write(b'{"id":"a","type":"phone.ping","ts":1,"body":{}}\n')
    try:
        await writer.drain()
    except (ssl.SSLError, ConnectionError):
        pass

    assert await reader.readline() == b"", "o servidor deveria ter derrubado a conexao"
    assert aceitou == [], "o handler nao deveria ter sido invocado"

    writer.close()
    srv.close()
    await srv.wait_closed()


async def test_contexto_exige_tls_1_3(par_de_certificados):
    servidor, _ = par_de_certificados
    ctx = transport.build_server_context(servidor[0], servidor[1], None)
    assert ctx.minimum_version == ssl.TLSVersion.TLSv1_3


async def test_session_envia_e_recebe_pacote():
    a_reader, a_writer = None, None
    recebido = {}

    async def handler(reader, writer):
        sessao = transport.Session(reader, writer, address="127.0.0.1")
        recebido["packet"] = await sessao.read_packet()
        await sessao.send(protocol.make_packet("phone.pong", {"echo_id": "x"}))
        await sessao.close()

    srv = await asyncio.start_server(handler, "127.0.0.1", 0)
    porta = srv.sockets[0].getsockname()[1]
    reader, writer = await asyncio.open_connection("127.0.0.1", porta)
    cliente = transport.Session(reader, writer, address="127.0.0.1")
    await cliente.send(protocol.make_packet("phone.ping", packet_id="x"))
    resposta = await cliente.read_packet()
    await cliente.close()
    srv.close()
    await srv.wait_closed()

    assert recebido["packet"]["type"] == "phone.ping"
    assert resposta["body"]["echo_id"] == "x"


async def test_session_read_packet_retorna_none_no_fim_do_stream():
    async def handler(reader, writer):
        writer.close()

    srv = await asyncio.start_server(handler, "127.0.0.1", 0)
    porta = srv.sockets[0].getsockname()[1]
    reader, writer = await asyncio.open_connection("127.0.0.1", porta)
    sessao = transport.Session(reader, writer, address="127.0.0.1")
    assert await sessao.read_packet() is None
    await sessao.close()
    srv.close()
    await srv.wait_closed()


async def test_session_propaga_erro_de_protocolo_em_linha_invalida():
    async def handler(reader, writer):
        writer.write(b"isso nao e json\n")
        await writer.drain()
        await asyncio.sleep(0.05)
        writer.close()

    srv = await asyncio.start_server(handler, "127.0.0.1", 0)
    porta = srv.sockets[0].getsockname()[1]
    reader, writer = await asyncio.open_connection("127.0.0.1", porta)
    sessao = transport.Session(reader, writer, address="127.0.0.1")
    with pytest.raises(protocol.ProtocolError):
        await sessao.read_packet()
    await sessao.close()
    srv.close()
    await srv.wait_closed()
