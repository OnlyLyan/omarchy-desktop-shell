"""Fronteira local entre o daemon e seus clientes.

Mesmo formato de linha JSON do protocolo de rede, para haver um serializador
so. O QML da fatia 2 consome exatamente este contrato.
"""

import asyncio
import logging
import os
from pathlib import Path

from . import protocol

log = logging.getLogger(__name__)


class IpcServer:
    def __init__(self, path, handler):
        self.path = Path(path)
        self._handler = handler
        self._server = None
        self._clientes = set()

    async def start(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.path.exists():
            # Sobra de um daemon que morreu sem limpar.
            self.path.unlink()
        self._server = await asyncio.start_unix_server(self._atende, path=str(self.path))
        os.chmod(self.path, 0o600)

    async def stop(self):
        for writer in list(self._clientes):
            writer.close()
        self._clientes.clear()
        if self._server:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        if self.path.exists():
            self.path.unlink()

    def broadcast(self, kind, payload):
        raw = protocol.encode(protocol.make_packet(kind, payload))
        for writer in list(self._clientes):
            if writer.is_closing():
                self._clientes.discard(writer)
                continue
            try:
                writer.write(raw)
            except (ConnectionError, RuntimeError) as exc:
                log.debug("cliente IPC caiu durante broadcast: %s", exc)
                self._clientes.discard(writer)

    async def _atende(self, reader, writer):
        self._clientes.add(writer)
        try:
            while True:
                linha = await reader.readline()
                if not linha:
                    break
                await self._processa(linha, writer)
        except ConnectionError as exc:
            log.debug("cliente IPC desconectou: %s", exc)
        finally:
            self._clientes.discard(writer)
            writer.close()

    async def _processa(self, linha, writer):
        try:
            packet = protocol.decode(linha)
        except protocol.ProtocolError as exc:
            await self._responde(writer, protocol.make_packet(
                "error", {"message": f"pacote invalido: {exc}"}
            ))
            return
        try:
            resultado = await self._handler(packet["type"], packet["body"])
        except Exception as exc:
            log.exception("comando %s falhou", packet["type"])
            await self._responde(writer, protocol.make_packet(
                "error", {"message": str(exc), "request_id": packet["id"]}
            ))
            return
        corpo = dict(resultado or {})
        corpo["request_id"] = packet["id"]
        await self._responde(
            writer, protocol.make_packet(f"{packet['type']}.result", corpo)
        )

    async def _responde(self, writer, packet):
        writer.write(protocol.encode(packet))
        await writer.drain()
