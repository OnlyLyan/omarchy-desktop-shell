"""Serializacao e validacao dos pacotes do Phone Link.

Modulo puro: nao conhece socket, arquivo nem estado. Um pacote e sempre uma
linha JSON UTF-8 com exatamente os campos id, type, ts e body.
"""

import json
import time
import uuid

MAX_LINE_BYTES = 1024 * 1024

_CAMPOS = {"id": str, "type": str, "ts": int, "body": dict}


class ProtocolError(Exception):
    """Pacote malformado, invalido ou grande demais."""


def make_packet(type_, body=None, *, packet_id=None, ts=None):
    return {
        "id": packet_id if packet_id is not None else str(uuid.uuid4()),
        "type": type_,
        "ts": ts if ts is not None else int(time.time()),
        "body": body if body is not None else {},
    }


def encode(packet):
    raw = json.dumps(packet, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(raw) + 1 > MAX_LINE_BYTES:
        raise ProtocolError(f"pacote com {len(raw)} bytes excede o limite de linha")
    return raw + b"\n"


def decode(line):
    if len(line) > MAX_LINE_BYTES:
        raise ProtocolError(f"linha com {len(line)} bytes excede o limite")
    try:
        parsed = json.loads(line)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ProtocolError(f"linha nao e JSON valido: {exc}") from exc
    if not isinstance(parsed, dict):
        raise ProtocolError(f"pacote deve ser objeto, veio {type(parsed).__name__}")
    packet = {}
    for campo, esperado in _CAMPOS.items():
        if campo not in parsed:
            raise ProtocolError(f"campo obrigatorio ausente: {campo}")
        valor = parsed[campo]
        # bool e subclasse de int em Python, e ts booleano nao faz sentido.
        if not isinstance(valor, esperado) or isinstance(valor, bool):
            raise ProtocolError(f"campo {campo} deveria ser {esperado.__name__}")
        packet[campo] = valor
    return packet
