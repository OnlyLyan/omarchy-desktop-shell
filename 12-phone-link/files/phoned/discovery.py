"""Anuncio e escuta de identidade por UDP.

Broadcast em vez de mDNS: uma dependencia a menos e funciona em rede
domestica sem avahi configurado.
"""

import asyncio
import logging
import socket
from dataclasses import dataclass, field

from . import protocol

log = logging.getLogger(__name__)

IDENTITY_TYPE = "identity"


class IdentityError(Exception):
    """Corpo de pacote identity malformado."""


@dataclass(slots=True)
class Identity:
    device_id: str
    name: str
    device_type: str
    port: int
    protocol_version: int
    capabilities: list = field(default_factory=list)

    def to_body(self):
        return {
            "device_id": self.device_id,
            "name": self.name,
            "device_type": self.device_type,
            "port": self.port,
            "protocol_version": self.protocol_version,
            "capabilities": list(self.capabilities),
        }

    @classmethod
    def from_body(cls, body):
        esperado = {
            "device_id": str, "name": str, "device_type": str,
            "port": int, "protocol_version": int, "capabilities": list,
        }
        valores = {}
        for campo, tipo in esperado.items():
            if campo not in body:
                raise IdentityError(f"campo ausente em identity: {campo}")
            valor = body[campo]
            if not isinstance(valor, tipo) or isinstance(valor, bool):
                raise IdentityError(f"campo {campo} deveria ser {tipo.__name__}")
            valores[campo] = valor
        return cls(**valores)


class _Receptor(asyncio.DatagramProtocol):
    def __init__(self, dono):
        self._dono = dono

    def datagram_received(self, data, addr):
        self._dono._on_datagram(data, addr[0])

    def error_received(self, exc):
        log.warning("erro no socket de descoberta: %s", exc)


class Discovery:
    def __init__(self, cfg, identity, on_identity):
        self._cfg = cfg
        self._identity = identity
        self._on_identity = on_identity
        self._transport = None
        self._tarefa = None

    async def start(self):
        loop = asyncio.get_running_loop()
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.bind(("", self._cfg.discovery_port))
        self._transport, _ = await loop.create_datagram_endpoint(
            lambda: _Receptor(self), sock=sock
        )
        self._tarefa = asyncio.create_task(self._laco())

    async def stop(self):
        if self._tarefa:
            self._tarefa.cancel()
            try:
                await self._tarefa
            except asyncio.CancelledError:
                pass
            self._tarefa = None
        if self._transport:
            self._transport.close()
            self._transport = None

    def announce(self):
        if self._transport is None:
            return
        raw = protocol.encode(
            protocol.make_packet(IDENTITY_TYPE, self._identity.to_body())
        )
        for host, porta in self._cfg.announce_targets:
            try:
                self._transport.sendto(raw, (host, porta))
            except OSError as exc:
                log.warning("falha ao anunciar para %s:%s: %s", host, porta, exc)

    async def _laco(self):
        # Anuncia na entrada, nao depois do sleep: o spec exige broadcast ao
        # iniciar, e ninguem mais chama announce() na subida do daemon. Dormir
        # primeiro deixaria o aparelho invisivel por announce_interval inteiro.
        while True:
            self.announce()
            await asyncio.sleep(self._cfg.announce_interval)

    def _on_datagram(self, data, source_ip):
        try:
            packet = protocol.decode(data)
        except protocol.ProtocolError as exc:
            log.debug("datagrama descartado de %s: %s", source_ip, exc)
            return
        if packet["type"] != IDENTITY_TYPE:
            log.debug("tipo inesperado em UDP de %s: %s", source_ip, packet["type"])
            return
        try:
            identity = Identity.from_body(packet["body"])
        except IdentityError as exc:
            log.debug("identity invalida de %s: %s", source_ip, exc)
            return
        if identity.device_id == self._identity.device_id:
            return
        self._on_identity(identity, source_ip)
