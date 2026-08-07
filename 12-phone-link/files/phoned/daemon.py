"""Junta descoberta, transporte e IPC num processo so."""

import asyncio
import logging

from . import config, discovery, ipc, pairing, transport

log = logging.getLogger(__name__)


class Daemon:
    def __init__(self, cfg):
        self.cfg = cfg
        self._trust = pairing.TrustStore(cfg.devices_path)
        self._trust.load()
        self._identity = discovery.Identity(
            device_id=cfg.device_id,
            name=cfg.name,
            device_type="desktop",
            port=cfg.tcp_port,
            protocol_version=config.PROTOCOL_VERSION,
            capabilities=["ping"],
        )
        self._ipc = ipc.IpcServer(cfg.ipc_path, self.handle_command)
        self._transport = transport.Transport(
            cfg, self._trust, self._identity, self._on_event
        )
        self._discovery = discovery.Discovery(cfg, self._identity, self._on_identity)
        self._vistos = {}
        self._tarefas = set()

    async def start(self):
        await self._ipc.start()
        await self._transport.start()
        await self._discovery.start()
        log.info(
            "phoned no ar como %s (%s), porta %s",
            self.cfg.name, self.cfg.device_id, self.cfg.tcp_port,
        )

    async def stop(self):
        # A descoberta para primeiro, de proposito. Ela e a unica fonte de
        # tarefas novas aqui: um datagrama que chegue durante o proprio stop
        # ainda passaria por _on_identity e criaria um ensure_connected orfao,
        # depois de _tarefas ja ter sido esvaziado.
        await self._discovery.stop()
        for tarefa in list(self._tarefas):
            tarefa.cancel()
        self._tarefas.clear()
        await self._transport.stop()
        await self._ipc.stop()

    # ---------- ligacoes ----------

    def _on_identity(self, identity, source_ip):
        self._vistos[identity.device_id] = (identity, source_ip)
        tarefa = asyncio.create_task(self._transport.ensure_connected(identity, source_ip))
        self._tarefas.add(tarefa)
        tarefa.add_done_callback(self._tarefas.discard)

    def _on_event(self, kind, payload):
        self._ipc.broadcast(kind, payload)

    # ---------- comandos ----------

    async def handle_command(self, command, body):
        match command:
            case "list":
                return {"devices": self._listagem()}
            case "pair":
                ok = await self._transport.request_pair(body["device_id"])
                return {"ok": ok}
            case "confirm":
                ok = await self._transport.confirm_pair(
                    body["device_id"], bool(body.get("accept", False))
                )
                return {"ok": ok}
            case "unpair":
                return {"ok": await self._transport.unpair(body["device_id"])}
            case "ping":
                return {"latency_ms": await self._transport.ping(body["device_id"])}
            case "connect":
                sessao = await self._transport.connect(
                    body["host"], int(body.get("port", self.cfg.tcp_port))
                )
                return {"ok": sessao is not None}
            case _:
                raise ValueError(f"comando desconhecido: {command}")

    def _listagem(self):
        conectados = {s.device_id: s for s in self._transport.sessions()}
        ids = set(conectados) | {d.device_id for d in self._trust.all()} | set(self._vistos)
        resultado = []
        for device_id in sorted(ids):
            sessao = conectados.get(device_id)
            confiavel = self._trust.get(device_id)
            visto = self._vistos.get(device_id)
            nome = (
                (sessao.name if sessao else None)
                or (confiavel.name if confiavel else None)
                or (visto[0].name if visto else device_id)
            )
            resultado.append({
                "device_id": device_id,
                "name": nome,
                "paired": confiavel is not None,
                "connected": sessao is not None,
                "address": sessao.address if sessao else (visto[1] if visto else None),
            })
        return resultado
