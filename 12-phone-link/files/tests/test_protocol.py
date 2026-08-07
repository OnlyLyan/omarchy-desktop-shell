import json

import pytest

from phoned import protocol


def test_make_packet_preenche_campos_obrigatorios():
    packet = protocol.make_packet("phone.ping")
    assert set(packet) == {"id", "type", "ts", "body"}
    assert packet["type"] == "phone.ping"
    assert packet["body"] == {}
    assert isinstance(packet["ts"], int)
    assert len(packet["id"]) == 36


def test_make_packet_aceita_id_e_ts_explicitos():
    packet = protocol.make_packet("phone.pong", {"echo_id": "x"}, packet_id="fixo", ts=42)
    assert packet == {"id": "fixo", "type": "phone.pong", "ts": 42, "body": {"echo_id": "x"}}


def test_encode_produz_uma_linha_terminada_em_newline():
    raw = protocol.encode(protocol.make_packet("phone.ping", packet_id="a", ts=1))
    assert raw.endswith(b"\n")
    assert raw.count(b"\n") == 1
    assert json.loads(raw)["type"] == "phone.ping"


def test_encode_e_decode_sao_reciprocos():
    packet = protocol.make_packet("identity", {"name": "acentuação"}, packet_id="a", ts=1)
    assert protocol.decode(protocol.encode(packet)) == packet


def test_decode_aceita_linha_sem_newline():
    assert protocol.decode(b'{"id":"a","type":"t","ts":1,"body":{}}')["id"] == "a"


@pytest.mark.parametrize(
    "linha",
    [
        b"",
        b"nao e json\n",
        b"[1,2,3]\n",
        b'"uma string"\n',
        b'{"type":"t","ts":1,"body":{}}\n',
        b'{"id":"a","ts":1,"body":{}}\n',
        b'{"id":"a","type":"t","body":{}}\n',
        b'{"id":"a","type":"t","ts":1}\n',
        b'{"id":1,"type":"t","ts":1,"body":{}}\n',
        b'{"id":"a","type":"t","ts":"agora","body":{}}\n',
        b'{"id":"a","type":"t","ts":1,"body":[]}\n',
    ],
)
def test_decode_rejeita_pacote_invalido(linha):
    with pytest.raises(protocol.ProtocolError):
        protocol.decode(linha)


def test_decode_rejeita_linha_acima_do_limite():
    gigante = b'{"id":"a","type":"t","ts":1,"body":{"x":"' + b"z" * protocol.MAX_LINE_BYTES + b'"}}'
    with pytest.raises(protocol.ProtocolError):
        protocol.decode(gigante)


def test_decode_ignora_campo_extra():
    packet = protocol.decode(b'{"id":"a","type":"t","ts":1,"body":{},"futuro":true}')
    assert "futuro" not in packet
