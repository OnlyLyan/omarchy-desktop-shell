import asyncio

import pytest

from phoned import config, discovery, protocol


def identidade(device_id="pc-1", porta=1739):
    return discovery.Identity(
        device_id=device_id, name="pc", device_type="desktop",
        port=porta, protocol_version=config.PROTOCOL_VERSION, capabilities=["ping"],
    )


def test_identity_ida_e_volta():
    original = identidade()
    assert discovery.Identity.from_body(original.to_body()) == original


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"device_id": "a"},
        {"device_id": "a", "name": "n", "device_type": "phone", "port": "nao numero",
         "protocol_version": 1, "capabilities": []},
        {"device_id": "a", "name": "n", "device_type": "phone", "port": 1,
         "protocol_version": 1, "capabilities": "nao lista"},
    ],
)
def test_identity_rejeita_body_invalido(body):
    with pytest.raises(discovery.IdentityError):
        discovery.Identity.from_body(body)


async def sobe(tmp_path, nome, porta, alvos, recebidos):
    cfg = config.load_config(
        state_dir=tmp_path / nome / "state", runtime_dir=tmp_path / nome / "run",
        name=nome, discovery_port=porta, tcp_port=porta, announce_targets=alvos,
    )
    servico = discovery.Discovery(
        cfg, identidade(device_id=nome, porta=porta),
        lambda ident, ip: recebidos.append((ident, ip)),
    )
    await servico.start()
    return cfg, servico


async def test_uma_instancia_recebe_o_anuncio_da_outra(tmp_path):
    recebidos_a, recebidos_b = [], []
    _, a = await sobe(tmp_path, "a", 21001, [("127.0.0.1", 21002)], recebidos_a)
    _, b = await sobe(tmp_path, "b", 21002, [("127.0.0.1", 21001)], recebidos_b)
    try:
        a.announce()
        b.announce()
        await asyncio.sleep(0.2)
    finally:
        await a.stop()
        await b.stop()

    # Sem contagem exata de proposito: o laco periodico anuncia assim que sobe,
    # como o spec exige, entao a mesma identidade pode chegar mais de uma vez
    # dentro da janela do teste. O que importa e quem foi visto, nao quantas vezes.
    assert "b" in [i.device_id for i, _ in recebidos_a]
    assert "a" in [i.device_id for i, _ in recebidos_b]
    assert all(ip == "127.0.0.1" for _, ip in recebidos_a)


async def test_ignora_o_proprio_anuncio(tmp_path):
    recebidos = []
    _, a = await sobe(tmp_path, "a", 21003, [("127.0.0.1", 21003)], recebidos)
    try:
        a.announce()
        await asyncio.sleep(0.2)
    finally:
        await a.stop()
    assert recebidos == []


async def test_datagrama_invalido_nao_derruba_o_servico(tmp_path):
    recebidos = []
    _, a = await sobe(tmp_path, "a", 21004, [("127.0.0.1", 21005)], recebidos)
    _, b = await sobe(tmp_path, "b", 21005, [("127.0.0.1", 21004)], recebidos)
    try:
        lixo = asyncio.get_running_loop()
        transporte, _ = await lixo.create_datagram_endpoint(
            asyncio.DatagramProtocol, remote_addr=("127.0.0.1", 21004)
        )
        transporte.sendto(b"nao e json\n")
        transporte.sendto(protocol.encode(protocol.make_packet("outro.tipo")))
        transporte.close()
        await asyncio.sleep(0.1)
        b.announce()
        await asyncio.sleep(0.2)
    finally:
        await a.stop()
        await b.stop()

    # O servico sobreviveu ao lixo e continua entregando identidade valida.
    assert "b" in [i.device_id for i, _ in recebidos]
