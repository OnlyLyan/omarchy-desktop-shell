"""Canal TCP com TLS, sessoes e o ciclo de vida da conexao.

Assimetria importante, verificada com o modulo ssl da stdlib: um servidor que
ainda nao confia em ninguem nao pode exigir certificado do cliente, entao nao
recebe nenhum. Por isso o primeiro pareamento carrega o certificado dentro do
pacote pair.request, e a seguranca vem da comparacao visual do codigo.
"""

import asyncio
import logging
import ssl

from . import pairing, protocol

log = logging.getLogger(__name__)


def build_server_context(cert_path, key_path, ca_data):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(str(cert_path), str(key_path))
    if ca_data:
        # Ha aparelhos pareados: exige e valida o certificado do cliente.
        ctx.verify_mode = ssl.CERT_OPTIONAL
        ctx.load_verify_locations(cadata=ca_data)
    else:
        # Nenhum aparelho confiavel ainda: aceita sem certificado de cliente,
        # e o gate de pareamento em Transport limita o que pode trafegar.
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def build_client_context(cert_path, key_path, present_cert):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    # A confianca e por fingerprint, nao por cadeia nem por nome de host.
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    if present_cert:
        ctx.load_cert_chain(str(cert_path), str(key_path))
    return ctx


def peer_fingerprint(writer):
    objeto = writer.get_extra_info("ssl_object")
    if objeto is None:
        return None
    der = objeto.getpeercert(binary_form=True)
    return pairing.fingerprint_from_der(der) if der else None


class Session:
    """Uma conexao viva com um aparelho. Fala pacotes, nao bytes."""

    def __init__(self, reader, writer, address, identity=None, peer_fingerprint=None):
        self._reader = reader
        self._writer = writer
        self.address = address
        self.identity = identity
        self.peer_fingerprint = peer_fingerprint
        self.paired = False
        self._lock = asyncio.Lock()

    @property
    def device_id(self):
        return self.identity.device_id if self.identity else None

    @property
    def name(self):
        return self.identity.name if self.identity else None

    async def send(self, packet):
        async with self._lock:
            self._writer.write(protocol.encode(packet))
            await self._writer.drain()

    async def read_packet(self):
        linha = await self._reader.readline()
        if not linha:
            return None
        if len(linha) >= protocol.MAX_LINE_BYTES:
            raise protocol.ProtocolError("linha acima do limite")
        return protocol.decode(linha)

    async def close(self):
        if self._writer.is_closing():
            return
        self._writer.close()
        try:
            await self._writer.wait_closed()
        except (ConnectionError, ssl.SSLError) as exc:
            log.debug("erro ao fechar sessao com %s: %s", self.address, exc)
