"""Caminhos, identidade local e parametros de operacao.

Unico modulo que conhece a arvore de diretorios. Todo o resto recebe um
Config pronto, o que torna possivel subir duas instancias no mesmo host
durante os testes.
"""

import os
import socket
import uuid
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_PORT = 1739
PROTOCOL_VERSION = 1


@dataclass(slots=True)
class Config:
    state_dir: Path
    runtime_dir: Path
    name: str
    device_id: str
    tcp_port: int = DEFAULT_PORT
    discovery_port: int = DEFAULT_PORT
    announce_targets: list = field(default_factory=lambda: [("255.255.255.255", DEFAULT_PORT)])
    announce_interval: float = 60.0
    ping_interval: float = 30.0
    session_timeout: float = 90.0
    pair_timeout: float = 60.0

    @property
    def cert_path(self):
        return self.state_dir / "cert.pem"

    @property
    def key_path(self):
        return self.state_dir / "key.pem"

    @property
    def devices_path(self):
        return self.state_dir / "devices.json"

    @property
    def ipc_path(self):
        return self.runtime_dir / "ipc.sock"


def default_state_dir():
    base = os.environ.get("XDG_STATE_HOME") or Path.home() / ".local" / "state"
    return Path(base) / "phone"


def default_runtime_dir():
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return Path(base) / "phone"


def load_or_create_device_id(state_dir):
    caminho = Path(state_dir) / "device_id"
    if caminho.exists():
        valor = caminho.read_text().strip()
        if valor:
            return valor
    valor = str(uuid.uuid4())
    caminho.write_text(valor + "\n")
    return valor


def load_config(*, state_dir=None, runtime_dir=None, **overrides):
    state_dir = Path(state_dir) if state_dir else default_state_dir()
    runtime_dir = Path(runtime_dir) if runtime_dir else default_runtime_dir()
    state_dir.mkdir(parents=True, exist_ok=True)
    runtime_dir.mkdir(parents=True, exist_ok=True)
    # A chave privada mora aqui, entao o diretorio nao pode ser legivel por outros.
    state_dir.chmod(0o700)

    overrides.setdefault("name", socket.gethostname())
    overrides.setdefault("device_id", load_or_create_device_id(state_dir))
    return Config(state_dir=state_dir, runtime_dir=runtime_dir, **overrides)
