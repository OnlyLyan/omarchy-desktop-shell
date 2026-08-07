# Phone Link, fatia 1, lado PC: plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar o daemon `phoned` e a CLI `phonectl` que descobrem, pareiam e mantêm sessão TLS com outro par na mesma rede, verificados por um teste de integração em loopback com duas instâncias completas.

**Architecture:** Daemon Python asyncio com módulos de responsabilidade única: `protocol` (pacotes, puro), `pairing` (certificados e confiança), `discovery` (UDP), `transport` (TCP, TLS, sessão), `ipc` (unix socket local). A CLI é um cliente burro do unix socket, sem lógica de rede. Nada de UI: a fatia 1 é invisível para o desktop.

**Tech Stack:** Python 3.14 apenas com stdlib (`asyncio`, `ssl`, `json`, `socket`, `hashlib`, `subprocess`, `dataclasses`, `pathlib`). Certificado gerado pelo binário `openssl` 3.6. Testes com `pytest` e `pytest-asyncio`.

**Spec:** `docs/superpowers/specs/2026-08-07-phone-link-transporte-design.md`

**Escopo deste plano:** somente o lado PC. O app Android é o plano seguinte, escrito depois que este rodar.

## Global Constraints

- Runtime do daemon: **stdlib apenas**. Nenhuma dependência de terceiros pode entrar em `files/phoned/`. `pytest` e `pytest-asyncio` são dependências só de desenvolvimento.
- Python alvo: **3.14.6** (o instalado). Sintaxe moderna liberada: `match`, `X | None`, `dataclass(slots=True)`.
- Porta: **1739** TCP e UDP. Nunca cair para porta alternativa.
- Limite de linha do protocolo: **1048576 bytes** (`MAX_LINE_BYTES`).
- Fingerprint: SHA-256 do DER, **hexadecimal maiúsculo sem separadores**, 64 caracteres.
- Código de pareamento: **6 caracteres hexadecimais maiúsculos**.
- Todo pacote tem exatamente os campos `id`, `type`, `ts`, `body`.
- Tipo de pacote desconhecido: logar e ignorar. **Nunca** derrubar a conexão por isso.
- Estado em `~/.local/state/phone/`, socket em `$XDG_RUNTIME_DIR/phone/ipc.sock`. Nenhum caminho hardcoded em módulo que não seja `config.py`.
- Nenhum módulo além de `discovery.py` e `transport.py` pode importar `socket` ou `ssl`.
- **Regra de escrita do repositório: nada de emoji e nada de travessão (`—`) em código, comentário, mensagem de commit, README ou docstring.** Use vírgula ou dois pontos.
- Commits em português, formato `tipo(escopo): descrição`, escopo `phone-link`.
- Todo comando `git add` lista arquivos explicitamente. O repositório tem alterações não relacionadas em andamento e `git add -A` as arrastaria junto.

## Divergência deliberada do spec

O spec lista os módulos do `phoned` sem um `daemon.py`, deixando implícito que
`__main__.py` faria a montagem. Este plano separa os dois: `daemon.py` contém a classe
`Daemon`, que amarra descoberta, transporte e IPC, e `__main__.py` fica só com argumentos,
log e sinais. A razão é testabilidade: `Daemon` é instanciável dentro do pytest, enquanto
`__main__` não é sem subir processo. O teste de integração da Task 12 depende dessa
separação.

---

### Task 1: Esqueleto do componente e módulo `protocol`

**Files:**
- Create: `12-phone-link/files/phoned/__init__.py`
- Create: `12-phone-link/files/phoned/protocol.py`
- Create: `12-phone-link/files/tests/__init__.py`
- Create: `12-phone-link/files/tests/test_protocol.py`
- Create: `12-phone-link/files/pytest.ini`

**Interfaces:**
- Consumes: nada.
- Produces: `MAX_LINE_BYTES: int`, `ProtocolError(Exception)`, `make_packet(type_: str, body: dict | None = None, *, packet_id: str | None = None, ts: int | None = None) -> dict`, `encode(packet: dict) -> bytes`, `decode(line: bytes) -> dict`.

- [ ] **Step 1: Instalar as dependências de desenvolvimento**

```bash
sudo pacman -S --needed python-pytest python-pytest-asyncio
```

- [ ] **Step 2: Criar a estrutura e o `pytest.ini`**

```bash
mkdir -p 12-phone-link/files/phoned 12-phone-link/files/tests
touch 12-phone-link/files/phoned/__init__.py 12-phone-link/files/tests/__init__.py
```

`12-phone-link/files/pytest.ini`:

```ini
[pytest]
testpaths = tests
asyncio_mode = auto
```

- [ ] **Step 3: Escrever os testes que falham**

`12-phone-link/files/tests/test_protocol.py`:

```python
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
```

- [ ] **Step 4: Rodar e confirmar que falha**

Run: `cd 12-phone-link/files && python -m pytest tests/test_protocol.py -v`
Expected: FAIL com `ModuleNotFoundError: No module named 'phoned.protocol'`

- [ ] **Step 5: Implementar `protocol.py`**

```python
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
```

- [ ] **Step 6: Rodar e confirmar que passa**

Run: `cd 12-phone-link/files && python -m pytest tests/test_protocol.py -v`
Expected: PASS, 17 testes.

- [ ] **Step 7: Commit**

```bash
git add 12-phone-link/files/pytest.ini 12-phone-link/files/phoned/__init__.py \
        12-phone-link/files/phoned/protocol.py \
        12-phone-link/files/tests/__init__.py 12-phone-link/files/tests/test_protocol.py
git commit -m "feat(phone-link): modulo protocol com encode, decode e validacao"
```

---

### Task 2: Módulo `config`

**Files:**
- Create: `12-phone-link/files/phoned/config.py`
- Create: `12-phone-link/files/tests/test_config.py`

**Interfaces:**
- Consumes: nada.
- Produces: `DEFAULT_PORT: int`, `PROTOCOL_VERSION: int`, `Config` (dataclass com `state_dir`, `runtime_dir`, `name`, `device_id`, `tcp_port`, `discovery_port`, `announce_targets`, `announce_interval`, `ping_interval`, `session_timeout`, `pair_timeout`, e as propriedades `cert_path`, `key_path`, `devices_path`, `ipc_path`), `load_config(*, state_dir=None, runtime_dir=None, **overrides) -> Config`, `load_or_create_device_id(state_dir: Path) -> str`.

- [ ] **Step 1: Escrever os testes que falham**

`12-phone-link/files/tests/test_config.py`:

```python
from phoned import config


def test_device_id_e_criado_e_persistido(tmp_path):
    primeiro = config.load_or_create_device_id(tmp_path)
    segundo = config.load_or_create_device_id(tmp_path)
    assert primeiro == segundo
    assert len(primeiro) == 36
    assert (tmp_path / "device_id").read_text().strip() == primeiro


def test_device_id_ignora_espaco_em_branco_no_arquivo(tmp_path):
    (tmp_path / "device_id").write_text("  abc-123  \n")
    assert config.load_or_create_device_id(tmp_path) == "abc-123"


def test_load_config_usa_valores_padrao(tmp_path):
    cfg = config.load_config(state_dir=tmp_path / "state", runtime_dir=tmp_path / "run")
    assert cfg.tcp_port == config.DEFAULT_PORT == 1739
    assert cfg.discovery_port == config.DEFAULT_PORT
    assert cfg.announce_targets == [("255.255.255.255", config.DEFAULT_PORT)]
    assert cfg.name


def test_load_config_cria_os_diretorios(tmp_path):
    cfg = config.load_config(state_dir=tmp_path / "state", runtime_dir=tmp_path / "run")
    assert cfg.state_dir.is_dir()
    assert cfg.runtime_dir.is_dir()


def test_load_config_aceita_overrides(tmp_path):
    cfg = config.load_config(
        state_dir=tmp_path / "state",
        runtime_dir=tmp_path / "run",
        tcp_port=1,
        discovery_port=2,
        announce_targets=[("127.0.0.1", 2)],
        name="teste",
    )
    assert (cfg.tcp_port, cfg.discovery_port, cfg.name) == (1, 2, "teste")
    assert cfg.announce_targets == [("127.0.0.1", 2)]


def test_caminhos_derivam_dos_diretorios(tmp_path):
    cfg = config.load_config(state_dir=tmp_path / "state", runtime_dir=tmp_path / "run")
    assert cfg.cert_path == cfg.state_dir / "cert.pem"
    assert cfg.key_path == cfg.state_dir / "key.pem"
    assert cfg.devices_path == cfg.state_dir / "devices.json"
    assert cfg.ipc_path == cfg.runtime_dir / "ipc.sock"


def test_state_dir_tem_permissao_restrita(tmp_path):
    cfg = config.load_config(state_dir=tmp_path / "state", runtime_dir=tmp_path / "run")
    assert cfg.state_dir.stat().st_mode & 0o777 == 0o700
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `cd 12-phone-link/files && python -m pytest tests/test_config.py -v`
Expected: FAIL com `ModuleNotFoundError`

- [ ] **Step 3: Implementar `config.py`**

```python
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

    if "name" not in overrides:
        overrides["name"] = socket.gethostname()
    # Guarda explicita em vez de setdefault: o argumento de setdefault e avaliado
    # sempre, e load_or_create_device_id escreve no disco. Com setdefault, passar
    # device_id explicito ainda gravaria um UUID fantasma que ninguem usa, bem no
    # caso de duas instancias no mesmo host durante os testes.
    if "device_id" not in overrides:
        overrides["device_id"] = load_or_create_device_id(state_dir)
    return Config(state_dir=state_dir, runtime_dir=runtime_dir, **overrides)
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `cd 12-phone-link/files && python -m pytest tests/test_config.py -v`
Expected: PASS, 7 testes.

- [ ] **Step 5: Commit**

```bash
git add 12-phone-link/files/phoned/config.py 12-phone-link/files/tests/test_config.py
git commit -m "feat(phone-link): modulo config com caminhos XDG e device_id persistente"
```

---

### Task 3: Certificado e fingerprint

**Files:**
- Create: `12-phone-link/files/phoned/pairing.py`
- Create: `12-phone-link/files/tests/test_pairing_cert.py`

**Interfaces:**
- Consumes: nada.
- Produces: `CertificateError(Exception)`, `ensure_certificate(cert_path: Path, key_path: Path, common_name: str) -> None`, `fingerprint_from_der(der: bytes) -> str`, `fingerprint_from_pem(pem: str) -> str`, `fingerprint_of_file(cert_path: Path) -> str`.

**Nota de fundo:** o comando abaixo foi validado no sistema em 2026-08-07 com OpenSSL 3.6.3. Ele gera curva P-256 e produz `basicConstraints: critical, CA:TRUE`, o que é o que permite o certificado servir de âncora de confiança de si mesmo em `load_verify_locations`.

- [ ] **Step 1: Escrever os testes que falham**

`12-phone-link/files/tests/test_pairing_cert.py`:

```python
import ssl
import subprocess

import pytest

from phoned import pairing


def test_ensure_certificate_gera_par_de_arquivos(tmp_path):
    cert, key = tmp_path / "cert.pem", tmp_path / "key.pem"
    pairing.ensure_certificate(cert, key, "meu-id")
    assert cert.exists() and key.exists()
    assert cert.read_text().startswith("-----BEGIN CERTIFICATE-----")


def test_ensure_certificate_e_idempotente(tmp_path):
    cert, key = tmp_path / "cert.pem", tmp_path / "key.pem"
    pairing.ensure_certificate(cert, key, "meu-id")
    original = cert.read_bytes()
    pairing.ensure_certificate(cert, key, "meu-id")
    assert cert.read_bytes() == original


def test_ensure_certificate_regenera_se_a_chave_sumiu(tmp_path):
    cert, key = tmp_path / "cert.pem", tmp_path / "key.pem"
    pairing.ensure_certificate(cert, key, "meu-id")
    original = cert.read_bytes()
    key.unlink()
    pairing.ensure_certificate(cert, key, "meu-id")
    assert key.exists()
    assert cert.read_bytes() != original


def test_chave_privada_nao_e_legivel_por_outros(tmp_path):
    cert, key = tmp_path / "cert.pem", tmp_path / "key.pem"
    pairing.ensure_certificate(cert, key, "meu-id")
    assert key.stat().st_mode & 0o077 == 0


def test_certificado_e_ca_para_servir_de_ancora(tmp_path):
    cert, key = tmp_path / "cert.pem", tmp_path / "key.pem"
    pairing.ensure_certificate(cert, key, "meu-id")
    texto = subprocess.run(
        ["openssl", "x509", "-in", str(cert), "-noout", "-text"],
        capture_output=True, text=True, check=True,
    ).stdout
    assert "CA:TRUE" in texto
    assert "meu-id" in texto


def test_fingerprint_tem_64_hex_maiusculos():
    fp = pairing.fingerprint_from_der(b"conteudo qualquer")
    assert len(fp) == 64
    assert fp == fp.upper()
    assert all(c in "0123456789ABCDEF" for c in fp)


def test_fingerprint_de_pem_e_de_der_coincidem(tmp_path):
    cert, key = tmp_path / "cert.pem", tmp_path / "key.pem"
    pairing.ensure_certificate(cert, key, "meu-id")
    pem = cert.read_text()
    der = ssl.PEM_cert_to_DER_cert(pem)
    assert pairing.fingerprint_from_pem(pem) == pairing.fingerprint_from_der(der)
    assert pairing.fingerprint_of_file(cert) == pairing.fingerprint_from_der(der)


def test_fingerprint_de_pem_invalido_levanta_erro():
    with pytest.raises(pairing.CertificateError):
        pairing.fingerprint_from_pem("isso nao e um certificado")
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `cd 12-phone-link/files && python -m pytest tests/test_pairing_cert.py -v`
Expected: FAIL com `ModuleNotFoundError`

- [ ] **Step 3: Implementar a primeira metade de `pairing.py`**

```python
"""Certificados, fingerprints e a lista de aparelhos confiaveis.

O certificado e gerado pelo binario openssl, e nao por uma biblioteca, para
manter o runtime do daemon com dependencia zero fora da stdlib.
"""

import hashlib
import ssl
import subprocess
from pathlib import Path


class CertificateError(Exception):
    """Falha ao gerar ou ler um certificado."""


def ensure_certificate(cert_path, key_path, common_name):
    cert_path, key_path = Path(cert_path), Path(key_path)
    if cert_path.exists() and key_path.exists():
        return
    cert_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        resultado = subprocess.run(
            [
                "openssl", "req", "-x509",
                "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                "-sha256", "-days", "3650", "-nodes",
                "-keyout", str(key_path), "-out", str(cert_path),
                "-subj", f"/CN={common_name}/O=phone-link",
                # Explicito de proposito: sem isso o CA:TRUE viria do openssl.cnf
                # da maquina, e uma configuracao diferente geraria um certificado
                # que nao serve de ancora de confianca, quebrando o pareamento
                # so la na frente e em silencio.
                "-addext", "basicConstraints=critical,CA:TRUE",
            ],
            capture_output=True, text=True, timeout=30,
        )
    except OSError as exc:
        raise CertificateError(f"nao consegui executar o openssl: {exc}") from exc
    except subprocess.TimeoutExpired as exc:
        raise CertificateError("openssl travou ao gerar o certificado") from exc
    if resultado.returncode != 0:
        raise CertificateError(f"openssl falhou: {resultado.stderr.strip()}")
    key_path.chmod(0o600)


def fingerprint_from_der(der):
    return hashlib.sha256(der).hexdigest().upper()


def fingerprint_from_pem(pem):
    try:
        return fingerprint_from_der(ssl.PEM_cert_to_DER_cert(pem))
    except (ValueError, TypeError) as exc:
        raise CertificateError(f"PEM invalido: {exc}") from exc


def fingerprint_of_file(cert_path):
    return fingerprint_from_pem(Path(cert_path).read_text())
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `cd 12-phone-link/files && python -m pytest tests/test_pairing_cert.py -v`
Expected: PASS, 8 testes.

- [ ] **Step 5: Commit**

```bash
git add 12-phone-link/files/phoned/pairing.py 12-phone-link/files/tests/test_pairing_cert.py
git commit -m "feat(phone-link): geracao de certificado EC e calculo de fingerprint"
```

---

### Task 4: Código de pareamento e `TrustStore`

**Files:**
- Modify: `12-phone-link/files/phoned/pairing.py` (acrescentar ao final)
- Create: `12-phone-link/files/tests/test_pairing_store.py`

**Interfaces:**
- Consumes: `pairing.fingerprint_from_pem` da Task 3.
- Produces: `pair_code(fp_a: str, fp_b: str) -> str`, `Device` (dataclass com `device_id`, `name`, `fingerprint`, `certificate`), `TrustStoreError(Exception)`, `TrustStore(path)` com `load()`, `save()`, `all() -> list[Device]`, `get(device_id) -> Device | None`, `is_trusted(device_id, fingerprint) -> bool`, `add(device)`, `remove(device_id) -> bool`, `ca_data() -> str | None`.

- [ ] **Step 1: Escrever os testes que falham**

`12-phone-link/files/tests/test_pairing_store.py`:

```python
import json

import pytest

from phoned import pairing

FP_A = "A" * 64
FP_B = "B" * 64


def dispositivo(device_id="cel-1", fingerprint=FP_A):
    return pairing.Device(
        device_id=device_id, name="celular", fingerprint=fingerprint, certificate="PEM FALSO"
    )


def test_pair_code_tem_6_hex_maiusculos():
    codigo = pairing.pair_code(FP_A, FP_B)
    assert len(codigo) == 6
    assert all(c in "0123456789ABCDEF" for c in codigo)


def test_pair_code_independe_da_ordem_dos_argumentos():
    assert pairing.pair_code(FP_A, FP_B) == pairing.pair_code(FP_B, FP_A)


def test_pair_code_muda_se_um_fingerprint_muda():
    assert pairing.pair_code(FP_A, FP_B) != pairing.pair_code(FP_A, "C" * 64)


def test_store_vazio_quando_arquivo_nao_existe(tmp_path):
    store = pairing.TrustStore(tmp_path / "devices.json")
    store.load()
    assert store.all() == []
    assert store.ca_data() is None


def test_add_e_persistencia(tmp_path):
    caminho = tmp_path / "devices.json"
    store = pairing.TrustStore(caminho)
    store.load()
    store.add(dispositivo())
    store.save()

    outro = pairing.TrustStore(caminho)
    outro.load()
    assert [d.device_id for d in outro.all()] == ["cel-1"]
    assert outro.get("cel-1").fingerprint == FP_A


def test_add_substitui_aparelho_com_mesmo_id(tmp_path):
    store = pairing.TrustStore(tmp_path / "devices.json")
    store.load()
    store.add(dispositivo())
    store.add(dispositivo(fingerprint=FP_B))
    assert len(store.all()) == 1
    assert store.get("cel-1").fingerprint == FP_B


def test_is_trusted_exige_id_e_fingerprint(tmp_path):
    store = pairing.TrustStore(tmp_path / "devices.json")
    store.load()
    store.add(dispositivo())
    assert store.is_trusted("cel-1", FP_A) is True
    assert store.is_trusted("cel-1", FP_B) is False
    assert store.is_trusted("outro", FP_A) is False


def test_remove_retorna_se_removeu(tmp_path):
    store = pairing.TrustStore(tmp_path / "devices.json")
    store.load()
    store.add(dispositivo())
    assert store.remove("cel-1") is True
    assert store.remove("cel-1") is False
    assert store.all() == []


def test_ca_data_concatena_os_pems(tmp_path):
    store = pairing.TrustStore(tmp_path / "devices.json")
    store.load()
    store.add(pairing.Device("a", "a", FP_A, "PEM-A"))
    store.add(pairing.Device("b", "b", FP_B, "PEM-B"))
    dados = store.ca_data()
    assert "PEM-A" in dados and "PEM-B" in dados


def test_arquivo_corrompido_levanta_erro_explicito(tmp_path):
    caminho = tmp_path / "devices.json"
    caminho.write_text("{isso nao e json")
    store = pairing.TrustStore(caminho)
    with pytest.raises(pairing.TrustStoreError) as erro:
        store.load()
    assert str(caminho) in str(erro.value)


def test_arquivo_com_formato_inesperado_levanta_erro(tmp_path):
    caminho = tmp_path / "devices.json"
    caminho.write_text(json.dumps({"devices": "deveria ser lista"}))
    store = pairing.TrustStore(caminho)
    with pytest.raises(pairing.TrustStoreError):
        store.load()


def test_save_e_atomico_e_deixa_permissao_restrita(tmp_path):
    caminho = tmp_path / "devices.json"
    store = pairing.TrustStore(caminho)
    store.load()
    store.add(dispositivo())
    store.save()
    assert caminho.stat().st_mode & 0o077 == 0
    assert not list(tmp_path.glob("*.tmp"))
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `cd 12-phone-link/files && python -m pytest tests/test_pairing_store.py -v`
Expected: FAIL com `AttributeError: module 'phoned.pairing' has no attribute 'pair_code'`

- [ ] **Step 3: Acrescentar ao final de `pairing.py`**

Primeiro acrescente os imports que esta metade precisa, junto dos que já existem no topo
do arquivo. A Task 3 deliberadamente não os trouxe, para não deixar import ocioso:

```python
import json
from dataclasses import dataclass, asdict
```

Depois, ao final do arquivo:

```python
def pair_code(fp_a, fp_b):
    """Codigo que os dois aparelhos exibem para comparacao visual.

    A ordenacao dos fingerprints garante o mesmo resultado nos dois lados,
    independentemente de quem iniciou o pareamento.
    """
    menor, maior = sorted([fp_a, fp_b])
    return hashlib.sha256((menor + maior).encode("utf-8")).hexdigest()[:6].upper()


@dataclass(slots=True)
class Device:
    device_id: str
    name: str
    fingerprint: str
    certificate: str


class TrustStoreError(Exception):
    """devices.json ausente de sentido: corrompido ou com formato inesperado."""


class TrustStore:
    def __init__(self, path):
        self.path = Path(path)
        self._devices = {}

    def load(self):
        if not self.path.exists():
            self._devices = {}
            return
        try:
            dados = json.loads(self.path.read_text())
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise TrustStoreError(f"{self.path} esta corrompido: {exc}") from exc
        if not isinstance(dados, dict) or not isinstance(dados.get("devices"), list):
            raise TrustStoreError(f"{self.path} nao tem o formato esperado")
        try:
            self._devices = {
                item["device_id"]: Device(
                    device_id=item["device_id"],
                    name=item["name"],
                    fingerprint=item["fingerprint"],
                    certificate=item["certificate"],
                )
                for item in dados["devices"]
            }
        except (KeyError, TypeError) as exc:
            raise TrustStoreError(f"{self.path} tem entrada invalida: {exc}") from exc

    def save(self):
        conteudo = json.dumps(
            {"version": 1, "devices": [asdict(d) for d in self._devices.values()]},
            ensure_ascii=False, indent=2,
        )
        temporario = self.path.with_suffix(".tmp")
        temporario.write_text(conteudo + "\n")
        temporario.chmod(0o600)
        temporario.replace(self.path)

    def all(self):
        return list(self._devices.values())

    def get(self, device_id):
        return self._devices.get(device_id)

    def is_trusted(self, device_id, fingerprint):
        conhecido = self._devices.get(device_id)
        return conhecido is not None and conhecido.fingerprint == fingerprint

    def add(self, device):
        self._devices[device.device_id] = device

    def remove(self, device_id):
        return self._devices.pop(device_id, None) is not None

    def ca_data(self):
        if not self._devices:
            return None
        return "\n".join(d.certificate.strip() for d in self._devices.values()) + "\n"
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `cd 12-phone-link/files && python -m pytest tests/ -v`
Expected: PASS, todos os testes das tasks 1 a 4.

- [ ] **Step 5: Commit**

```bash
git add 12-phone-link/files/phoned/pairing.py 12-phone-link/files/tests/test_pairing_store.py
git commit -m "feat(phone-link): codigo de pareamento e lista de aparelhos confiaveis"
```

---

### Task 5: Descoberta por UDP

**Files:**
- Create: `12-phone-link/files/phoned/discovery.py`
- Create: `12-phone-link/files/tests/test_discovery.py`

**Interfaces:**
- Consumes: `protocol.make_packet`, `protocol.encode`, `protocol.decode`, `protocol.ProtocolError`, `config.PROTOCOL_VERSION`.
- Produces: `Identity` (dataclass `device_id`, `name`, `device_type`, `port`, `protocol_version`, `capabilities`) com `to_body() -> dict` e `from_body(body: dict) -> Identity`, `IdentityError(Exception)`, `Discovery(config, identity, on_identity)` com `async start()`, `async stop()`, `announce()`. O callback tem assinatura `on_identity(identity: Identity, source_ip: str) -> None`.

**Nota de projeto:** `announce_targets` existe justamente para o teste. Em produção é `[("255.255.255.255", 1739)]`; no teste, duas instâncias em portas diferentes apontam uma para a outra em `127.0.0.1`, o que exercita o caminho real sem depender de broadcast na máquina de CI.

- [ ] **Step 1: Escrever os testes que falham**

`12-phone-link/files/tests/test_discovery.py`:

```python
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
    _, a = await sobe(tmp_path, "a", 45001, [("127.0.0.1", 45002)], recebidos_a)
    _, b = await sobe(tmp_path, "b", 45002, [("127.0.0.1", 45001)], recebidos_b)
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
    _, a = await sobe(tmp_path, "a", 45003, [("127.0.0.1", 45003)], recebidos)
    try:
        a.announce()
        await asyncio.sleep(0.2)
    finally:
        await a.stop()
    assert recebidos == []


async def test_datagrama_invalido_nao_derruba_o_servico(tmp_path):
    recebidos = []
    _, a = await sobe(tmp_path, "a", 45004, [("127.0.0.1", 45005)], recebidos)
    _, b = await sobe(tmp_path, "b", 45005, [("127.0.0.1", 45004)], recebidos)
    try:
        lixo = asyncio.get_running_loop()
        transporte, _ = await lixo.create_datagram_endpoint(
            asyncio.DatagramProtocol, remote_addr=("127.0.0.1", 45004)
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
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `cd 12-phone-link/files && python -m pytest tests/test_discovery.py -v`
Expected: FAIL com `ModuleNotFoundError: No module named 'phoned.discovery'`

- [ ] **Step 3: Implementar `discovery.py`**

```python
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
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `cd 12-phone-link/files && python -m pytest tests/test_discovery.py -v`
Expected: PASS, 8 testes.

- [ ] **Step 5: Commit**

```bash
git add 12-phone-link/files/phoned/discovery.py 12-phone-link/files/tests/test_discovery.py
git commit -m "feat(phone-link): descoberta por broadcast UDP com identidade validada"
```

---

### Task 6: Contextos TLS e sessão

**Files:**
- Create: `12-phone-link/files/phoned/transport.py`
- Create: `12-phone-link/files/tests/test_transport_tls.py`

**Interfaces:**
- Consumes: `protocol`, `pairing`, `discovery.Identity`.
- Produces: `build_server_context(cert_path, key_path, ca_data: str | None) -> ssl.SSLContext`, `build_client_context(cert_path, key_path, present_cert: bool) -> ssl.SSLContext`, `peer_fingerprint(writer) -> str | None`, `Session` com atributos `device_id`, `name`, `identity`, `peer_fingerprint`, `paired`, `address` e métodos `async send(packet)`, `async close()`, `async read_packet() -> dict | None`.

**Nota de fundo, verificada no sistema em 2026-08-07:** com `CERT_NONE` no servidor, `getpeercert(binary_form=True)` retorna `None` porque o cliente não é sequer solicitado a apresentar certificado. Com `CERT_OPTIONAL` mais `load_verify_locations(cadata=...)`, retorna o DER do cliente e a validação é real. O cliente sempre enxerga o certificado do servidor, mesmo com `CERT_NONE`, porque `binary_form=True` devolve o certificado independentemente de validação. É essa assimetria que o modelo de pareamento contorna.

**Segunda nota, também verificada nesta máquina:** quando o servidor recusa o certificado do
cliente, o lado cliente **não** recebe exceção. Em TLS 1.3 o handshake do cliente termina antes
de ele saber o veredito, o `write` seguinte ainda passa, e a recusa aparece só como EOF limpo na
primeira leitura. Do lado do servidor, o handler de conexão nunca chega a ser invocado.

A consequência prática, que a fatia 2 vai querer melhorar: um aparelho recusado é
indistinguível de um aparelho que saiu do WiFi, porque os dois viram "conexão encerrada". O
backoff da Task 8 evita reconexão em loop apertado, mas o motivo real não aparece no log.

- [ ] **Step 1: Escrever os testes que falham**

`12-phone-link/files/tests/test_transport_tls.py`:

```python
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


async def test_session_aceita_linha_grande_quando_o_limite_e_configurado():
    """Prova que o limite de 1MB do protocolo vale de ponta a ponta.

    O StreamReader do asyncio tem buffer default de 64KB. Sem passar limit,
    uma linha entre 64KB e 1MB estoura ValueError dentro do readline, antes de
    qualquer validacao do protocolo. Importa porque a fatia 2 manda notificacao
    com icone, e um PNG em base64 passa de 64KB sem esforco.
    """
    grande = "z" * 200_000

    async def handler(reader, writer):
        sessao = transport.Session(reader, writer, address="127.0.0.1")
        packet = await sessao.read_packet()
        await sessao.send(
            protocol.make_packet("phone.pong", {"tamanho": len(packet["body"]["dados"])})
        )
        await sessao.close()

    srv = await asyncio.start_server(
        handler, "127.0.0.1", 0, limit=protocol.MAX_LINE_BYTES
    )
    porta = srv.sockets[0].getsockname()[1]
    reader, writer = await asyncio.open_connection(
        "127.0.0.1", porta, limit=protocol.MAX_LINE_BYTES
    )
    cliente = transport.Session(reader, writer, address="127.0.0.1")
    await cliente.send(protocol.make_packet("teste.grande", {"dados": grande}))
    resposta = await cliente.read_packet()
    await cliente.close()
    srv.close()
    await srv.wait_closed()

    assert resposta["body"]["tamanho"] == len(grande)


async def test_session_traduz_estouro_de_buffer_em_erro_de_protocolo():
    """Linha acima do buffer vira ProtocolError, nunca ValueError cru.

    O laco de leitura da Task 7 so sabe tratar ProtocolError e fim de stream.
    """

    async def handler(reader, writer):
        writer.write(b"y" * 100_000)  # sem newline, estoura o buffer pequeno
        await writer.drain()
        await asyncio.sleep(0.05)
        writer.close()

    srv = await asyncio.start_server(handler, "127.0.0.1", 0, limit=4096)
    porta = srv.sockets[0].getsockname()[1]
    reader, writer = await asyncio.open_connection("127.0.0.1", porta, limit=4096)
    sessao = transport.Session(reader, writer, address="127.0.0.1")
    with pytest.raises(protocol.ProtocolError):
        await sessao.read_packet()
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
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `cd 12-phone-link/files && python -m pytest tests/test_transport_tls.py -v`
Expected: FAIL com `ModuleNotFoundError: No module named 'phoned.transport'`

- [ ] **Step 3: Implementar a primeira parte de `transport.py`**

```python
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
        try:
            linha = await self._reader.readline()
        except ValueError as exc:
            # StreamReader estoura ValueError quando a linha passa do limite do
            # buffer. Sem esta traducao vazaria um tipo que o laco de leitura nao
            # espera. Defesa em profundidade: quem abre a conexao ja passa
            # limit=MAX_LINE_BYTES, entao chegar aqui significa linha alem do
            # que o protocolo admite.
            raise protocol.ProtocolError(f"linha acima do limite do buffer: {exc}") from exc
        if not linha:
            return None
        # O tamanho e validado uma vez so, dentro de decode. Repetir a checagem
        # aqui ja custou uma divergencia de um byte entre os dois lugares.
        return protocol.decode(linha)

    async def close(self):
        if self._writer.is_closing():
            return
        self._writer.close()
        try:
            await self._writer.wait_closed()
        except (ConnectionError, ssl.SSLError) as exc:
            log.debug("erro ao fechar sessao com %s: %s", self.address, exc)
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `cd 12-phone-link/files && python -m pytest tests/test_transport_tls.py -v`
Expected: PASS, 7 testes.

- [ ] **Step 5: Commit**

```bash
git add 12-phone-link/files/phoned/transport.py 12-phone-link/files/tests/test_transport_tls.py
git commit -m "feat(phone-link): contextos TLS e sessao que fala pacotes"
```

---

### Task 7: `Transport` com gate de pareamento

**Files:**
- Modify: `12-phone-link/files/phoned/transport.py` (acrescentar ao final)
- Create: `12-phone-link/files/tests/test_transport_pairing.py`

**Interfaces:**
- Consumes: tudo da Task 6, mais `pairing.TrustStore`, `pairing.Device`, `pairing.pair_code`, `discovery.Identity`.
- Produces: `Transport(cfg, trust, identity, on_event)` com `async start()`, `async stop()`, `async connect(host, port) -> Session | None`, `sessions() -> list[Session]`, `async request_pair(device_id) -> bool`, `async confirm_pair(device_id, accept: bool) -> bool`, `async unpair(device_id) -> bool`. O callback é `on_event(kind: str, payload: dict) -> None`, com `kind` em `{"device.state", "pair.prompt", "pair.result", "pong"}`.

**Regra central desta task:** sessão não pareada só aceita pacotes cujo `type` começa com `pair.`. Qualquer outro derruba a conexão. Tipo desconhecido que não seja `pair.` em sessão **pareada** é apenas logado.

- [ ] **Step 1: Escrever os testes que falham**

`12-phone-link/files/tests/test_transport_pairing.py`:

```python
import asyncio

import pytest

from phoned import config, discovery, pairing, protocol, transport


class Par:
    """Um daemon de mentira: config, truststore, identity e transport."""

    def __init__(self, cfg, trust, identity, tr, eventos):
        self.cfg, self.trust, self.identity, self.tr, self.eventos = (
            cfg, trust, identity, tr, eventos
        )

    def evento(self, kind):
        return [p for k, p in self.eventos if k == kind]


async def monta(tmp_path, nome, porta, **overrides):
    """Sobe um Transport isolado.

    Os overrides existem porque mudar cfg depois de start() nao adianta para
    intervalos: o laco de heartbeat ja entrou no primeiro sleep com o valor
    antigo. Quem testa temporizacao precisa configurar antes de subir.
    """
    parametros = {
        "name": nome, "tcp_port": porta, "discovery_port": porta,
        "announce_targets": [], "pair_timeout": 1.0,
    }
    parametros.update(overrides)
    cfg = config.load_config(
        state_dir=tmp_path / nome / "state", runtime_dir=tmp_path / nome / "run",
        **parametros,
    )
    pairing.ensure_certificate(cfg.cert_path, cfg.key_path, cfg.device_id)
    trust = pairing.TrustStore(cfg.devices_path)
    trust.load()
    identity = discovery.Identity(
        device_id=cfg.device_id, name=nome, device_type="desktop",
        port=porta, protocol_version=config.PROTOCOL_VERSION, capabilities=["ping"],
    )
    eventos = []
    tr = transport.Transport(cfg, trust, identity, lambda k, p: eventos.append((k, p)))
    await tr.start()
    return Par(cfg, trust, identity, tr, eventos)


async def parear(a, b):
    """Faz a parear com b, com confirmacao dos dois lados."""
    await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
    await asyncio.sleep(0.1)
    await a.tr.request_pair(b.cfg.device_id)
    await asyncio.sleep(0.1)
    await b.tr.confirm_pair(a.cfg.device_id, True)
    await a.tr.confirm_pair(b.cfg.device_id, True)
    await asyncio.sleep(0.1)


async def test_pareamento_gera_o_mesmo_codigo_nos_dois_lados(tmp_path):
    a = await monta(tmp_path, "a", 45101)
    b = await monta(tmp_path, "b", 45102)
    try:
        await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.1)
        await a.tr.request_pair(b.cfg.device_id)
        await asyncio.sleep(0.1)

        codigo_a = a.evento("pair.prompt")[0]["code"]
        codigo_b = b.evento("pair.prompt")[0]["code"]
        assert codigo_a == codigo_b
        assert len(codigo_a) == 6
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_pareamento_confirmado_grava_nos_dois_truststores(tmp_path):
    a = await monta(tmp_path, "a", 45103)
    b = await monta(tmp_path, "b", 45104)
    try:
        await parear(a, b)
        assert a.trust.get(b.cfg.device_id) is not None
        assert b.trust.get(a.cfg.device_id) is not None
        assert a.trust.get(b.cfg.device_id).fingerprint == pairing.fingerprint_of_file(
            b.cfg.cert_path
        )
        assert a.cfg.devices_path.exists()
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_recusa_de_um_lado_nao_pareia_ninguem(tmp_path):
    a = await monta(tmp_path, "a", 45105)
    b = await monta(tmp_path, "b", 45106)
    try:
        await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.1)
        await a.tr.request_pair(b.cfg.device_id)
        await asyncio.sleep(0.1)
        await b.tr.confirm_pair(a.cfg.device_id, False)
        await asyncio.sleep(0.1)

        assert a.trust.get(b.cfg.device_id) is None
        assert b.trust.get(a.cfg.device_id) is None
        assert a.evento("pair.result")[0]["accepted"] is False
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_sessao_nao_pareada_e_derrubada_ao_enviar_tipo_comum(tmp_path):
    a = await monta(tmp_path, "a", 45107)
    b = await monta(tmp_path, "b", 45108)
    try:
        sessao = await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.1)
        await sessao.send(protocol.make_packet("phone.ping"))
        await asyncio.sleep(0.2)
        assert b.tr.sessions() == []
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_pareamento_expira_pelo_timeout(tmp_path):
    a = await monta(tmp_path, "a", 45109)
    b = await monta(tmp_path, "b", 45110)
    try:
        await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.1)
        await a.tr.request_pair(b.cfg.device_id)
        await asyncio.sleep(1.4)

        assert a.trust.get(b.cfg.device_id) is None
        assert a.evento("pair.result")[-1]["reason"] == "timeout"
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_unpair_remove_dos_dois_lados_do_ponto_de_vista_local(tmp_path):
    a = await monta(tmp_path, "a", 45111)
    b = await monta(tmp_path, "b", 45112)
    try:
        await parear(a, b)
        assert await a.tr.unpair(b.cfg.device_id) is True
        assert a.trust.get(b.cfg.device_id) is None
        assert await a.tr.unpair(b.cfg.device_id) is False
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_identity_repetido_derruba_a_sessao(tmp_path):
    """Sessao pareada nao pode se re-rotular como outro aparelho.

    Sem a guarda, quem pareou como A mandaria um segundo identity dizendo ser X,
    o bloco de confianca seria pulado por X ser desconhecido, mas paired
    continuaria True e o gate deixaria passar qualquer tipo.
    """
    a = await monta(tmp_path, "a", 45115)
    b = await monta(tmp_path, "b", 45116)
    try:
        await parear(a, b)
        sessao = a.tr.sessions()[0]
        assert sessao.paired is True

        falsa = discovery.Identity(
            device_id="nunca-pareado", name="intruso", device_type="phone",
            port=1, protocol_version=config.PROTOCOL_VERSION, capabilities=[],
        )
        await sessao.send(protocol.make_packet("identity", falsa.to_body()))
        await asyncio.sleep(0.3)

        assert b.tr.sessions() == [], "a sessao deveria ter sido derrubada"
        assert b.trust.get("nunca-pareado") is None
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_fingerprint_diferente_recusa_aparelho_conhecido(tmp_path):
    """Aparelho no truststore com outro certificado nao entra.

    E o caso do app reinstalado. Aceitar em silencio anularia o pareamento.
    """
    a = await monta(tmp_path, "a", 45117)
    b = await monta(tmp_path, "b", 45118)
    try:
        await parear(a, b)
        # b passa a conhecer a com um fingerprint que nao e o dele.
        conhecido = b.trust.get(a.cfg.device_id)
        b.trust.add(pairing.Device(
            device_id=conhecido.device_id, name=conhecido.name,
            fingerprint="F" * 64, certificate=conhecido.certificate,
        ))
        for sessao in list(a.tr.sessions()) + list(b.tr.sessions()):
            await sessao.close()
        await asyncio.sleep(0.2)

        await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.3)
        assert b.tr.sessions() == [], "fingerprint divergente deveria recusar"
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_pair_request_com_pem_divergente_e_recusado(tmp_path):
    """O certificado do corpo tem que ser o mesmo do canal TLS.

    Divergencia significa alguem tentando parear com credencial de terceiro.
    """
    a = await monta(tmp_path, "a", 45119)
    b = await monta(tmp_path, "b", 45120)
    terceiro_cert = tmp_path / "terceiro-cert.pem"
    terceiro_key = tmp_path / "terceiro-key.pem"
    pairing.ensure_certificate(terceiro_cert, terceiro_key, "terceiro")
    try:
        sessao = await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.2)
        await sessao.send(protocol.make_packet(
            "pair.request", {"certificate": terceiro_cert.read_text()}
        ))
        await asyncio.sleep(0.3)

        assert b.trust.get(a.cfg.device_id) is None
        assert b.cfg.device_id not in b.tr._pending
    finally:
        await a.tr.stop()
        await b.tr.stop()


async def test_conexao_duplicada_para_o_mesmo_aparelho_e_fechada(tmp_path):
    a = await monta(tmp_path, "a", 45113)
    b = await monta(tmp_path, "b", 45114)
    try:
        await parear(a, b)
        await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.2)
        ids = [s.device_id for s in b.tr.sessions()]
        assert ids.count(a.cfg.device_id) == 1
    finally:
        await a.tr.stop()
        await b.tr.stop()
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `cd 12-phone-link/files && python -m pytest tests/test_transport_pairing.py -v`
Expected: FAIL com `AttributeError: module 'phoned.transport' has no attribute 'Transport'`

- [ ] **Step 3: Acrescentar `Transport` ao final de `transport.py`**

```python
PAIR_REQUEST = "pair.request"
PAIR_ACCEPT = "pair.accept"
PAIR_REJECT = "pair.reject"
PING = "phone.ping"
PONG = "phone.pong"


class _PendingPair:
    """Pareamento em andamento: guarda o que cada lado ja decidiu."""

    def __init__(self, session, peer_fingerprint, code, iniciado_por_nos):
        self.session = session
        self.peer_fingerprint = peer_fingerprint
        self.code = code
        self.iniciado_por_nos = iniciado_por_nos
        self.local_ok = False
        self.remoto_ok = False
        self.timer = None


class Transport:
    def __init__(self, cfg, trust, identity, on_event):
        self._cfg = cfg
        self._trust = trust
        self._identity = identity
        self._on_event = on_event
        self._server = None
        self._sessions = {}
        self._pending = {}
        self._tarefas = set()
        self._cert_pem = None

    # ---------- ciclo de vida ----------

    async def start(self):
        pairing.ensure_certificate(
            self._cfg.cert_path, self._cfg.key_path, self._cfg.device_id
        )
        self._cert_pem = self._cfg.cert_path.read_text()
        ctx = build_server_context(
            self._cfg.cert_path, self._cfg.key_path, self._trust.ca_data()
        )
        self._server = await asyncio.start_server(
            self._on_inbound, "0.0.0.0", self._cfg.tcp_port, ssl=ctx,
            # Sem isto o buffer do StreamReader seria o default de 64KB, e o
            # limite de 1MB do protocolo nao valeria de verdade: linhas entre os
            # dois estourariam ValueError no readline.
            limit=protocol.MAX_LINE_BYTES,
        )

    async def stop(self):
        for pendente in list(self._pending.values()):
            if pendente.timer:
                pendente.timer.cancel()
        self._pending.clear()
        for sessao in list(self._sessions.values()):
            await sessao.close()
        self._sessions.clear()
        for tarefa in list(self._tarefas):
            tarefa.cancel()
        self._tarefas.clear()
        if self._server:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    def sessions(self):
        return list(self._sessions.values())

    # ---------- conexao ----------

    async def connect(self, host, port):
        conhecido_pem = None
        for device in self._trust.all():
            conhecido_pem = device.certificate
            break
        ctx = build_client_context(
            self._cfg.cert_path, self._cfg.key_path, present_cert=bool(conhecido_pem)
        )
        try:
            reader, writer = await asyncio.open_connection(
                host, port, ssl=ctx, limit=protocol.MAX_LINE_BYTES
            )
        except (OSError, ssl.SSLError) as exc:
            log.warning("falha ao conectar em %s:%s: %s", host, port, exc)
            return None
        sessao = Session(reader, writer, address=host, peer_fingerprint=peer_fingerprint(writer))
        await sessao.send(
            protocol.make_packet("identity", self._identity.to_body())
        )
        self._spawn(self._laco_de_leitura(sessao))
        return sessao

    async def _on_inbound(self, reader, writer):
        endereco = writer.get_extra_info("peername")
        sessao = Session(
            reader, writer,
            address=endereco[0] if endereco else "?",
            peer_fingerprint=peer_fingerprint(writer),
        )
        # A troca de identidade e mutua. Sem isto, quem abriu a conexao nunca
        # descobre nosso device_id, sua tabela de sessoes fica vazia e o
        # request_pair falha em silencio por nao achar a sessao.
        await sessao.send(protocol.make_packet("identity", self._identity.to_body()))
        await self._laco_de_leitura(sessao)

    def _spawn(self, corotina):
        tarefa = asyncio.create_task(corotina)
        self._tarefas.add(tarefa)
        tarefa.add_done_callback(self._tarefas.discard)
        return tarefa

    # ---------- leitura ----------

    async def _laco_de_leitura(self, sessao):
        try:
            while True:
                try:
                    packet = await sessao.read_packet()
                except protocol.ProtocolError as exc:
                    log.warning("pacote invalido de %s: %s", sessao.address, exc)
                    break
                if packet is None:
                    break
                if not await self._despacha(sessao, packet):
                    break
        except (ConnectionError, ssl.SSLError) as exc:
            log.info("conexao com %s encerrada: %s", sessao.address, exc)
        finally:
            await self._encerra(sessao)

    async def _encerra(self, sessao):
        await sessao.close()
        # Sem isto o mapa cresce uma entrada por sessao que ja existiu, e ainda
        # abre espaco para colisao: o CPython reaproveita o id de objeto morto.
        self._ultimo_pacote.pop(id(sessao), None)
        if sessao.device_id and self._sessions.get(sessao.device_id) is sessao:
            del self._sessions[sessao.device_id]
            self._emit("device.state", {
                "device_id": sessao.device_id, "state": "disconnected",
            })
        pendente = self._pending.get(sessao.device_id)
        if pendente and pendente.session is sessao:
            self._cancela_pendente(sessao.device_id, "desconectado")

    async def _despacha(self, sessao, packet):
        """Retorna False para encerrar a conexao."""
        tipo = packet["type"]

        if tipo == "identity":
            return self._registra_identidade(sessao, packet)

        if sessao.identity is None:
            log.warning("pacote %s antes de identity, de %s", tipo, sessao.address)
            return False

        if not sessao.paired and not tipo.startswith("pair."):
            log.warning(
                "aparelho nao pareado %s tentou enviar %s", sessao.device_id, tipo
            )
            return False

        match tipo:
            case _ if tipo == PAIR_REQUEST:
                await self._on_pair_request(sessao, packet)
            case _ if tipo == PAIR_ACCEPT:
                await self._on_pair_accept(sessao)
            case _ if tipo == PAIR_REJECT:
                self._cancela_pendente(sessao.device_id, packet["body"].get("reason", "recusado"))
            case _ if tipo == PING:
                await sessao.send(protocol.make_packet(PONG, {"echo_id": packet["id"]}))
            case _ if tipo == PONG:
                self._emit("pong", {
                    "device_id": sessao.device_id, "echo_id": packet["body"].get("echo_id"),
                })
            case _:
                log.debug("tipo desconhecido de %s: %s", sessao.device_id, tipo)
        return True

    def _registra_identidade(self, sessao, packet):
        from . import discovery as _discovery

        if sessao.identity is not None:
            # Cada lado se identifica uma unica vez. Sem esta guarda, uma sessao
            # que ja pareou como A poderia se re-rotular como um device_id
            # qualquer: o bloco de confianca abaixo seria pulado por ser
            # desconhecido, mas sessao.paired continuaria True de antes, e o gate
            # de pareamento deixaria passar qualquer tipo. Ainda por cima a
            # entrada antiga em _sessions ficaria apontando para uma sessao
            # morta, e a reconexao legitima de A seria recusada como duplicada.
            log.warning(
                "sessao de %s tentou se identificar de novo, derrubando",
                sessao.device_id,
            )
            return False
        try:
            identidade = _discovery.Identity.from_body(packet["body"])
        except _discovery.IdentityError as exc:
            log.warning("identity invalida de %s: %s", sessao.address, exc)
            return False
        if identidade.device_id == self._identity.device_id:
            log.warning("conexao consigo mesmo, descartando")
            return False

        anterior = self._sessions.get(identidade.device_id)
        if anterior is not None and anterior is not sessao:
            log.info("conexao duplicada para %s, fechando a nova", identidade.device_id)
            return False

        sessao.identity = identidade
        conhecido = self._trust.get(identidade.device_id)
        if conhecido is not None:
            if sessao.peer_fingerprint is None:
                # Nos somos o servidor e o cliente nao apresentou certificado,
                # apesar de constar como pareado. Estado assimetrico.
                log.warning(
                    "aparelho %s consta pareado mas nao apresentou certificado",
                    identidade.device_id,
                )
                return False
            if sessao.peer_fingerprint != conhecido.fingerprint:
                log.warning(
                    "fingerprint de %s mudou, conexao recusada. Rode phonectl unpair %s",
                    identidade.device_id, identidade.device_id,
                )
                return False
            sessao.paired = True

        self._sessions[identidade.device_id] = sessao
        self._emit("device.state", {
            "device_id": identidade.device_id,
            "name": identidade.name,
            "address": sessao.address,
            "paired": sessao.paired,
            "state": "connected",
        })
        return True

    # ---------- pareamento ----------

    async def request_pair(self, device_id):
        sessao = self._sessions.get(device_id)
        if sessao is None or sessao.paired:
            return False
        await sessao.send(
            protocol.make_packet(PAIR_REQUEST, {"certificate": self._cert_pem})
        )
        # O certificado do outro lado veio pelo proprio handshake TLS, ja que
        # aqui nos somos o cliente.
        self._abre_pendente(sessao, sessao.peer_fingerprint, iniciado_por_nos=True)
        return True

    async def _on_pair_request(self, sessao, packet):
        pem = packet["body"].get("certificate")
        if not isinstance(pem, str):
            await sessao.send(
                protocol.make_packet(PAIR_REJECT, {"reason": "certificado ausente"})
            )
            return
        try:
            fingerprint = pairing.fingerprint_from_pem(pem)
        except pairing.CertificateError as exc:
            await sessao.send(
                protocol.make_packet(PAIR_REJECT, {"reason": f"certificado invalido: {exc}"})
            )
            return
        if sessao.peer_fingerprint is not None and sessao.peer_fingerprint != fingerprint:
            # O certificado do TLS e o do pacote precisam ser o mesmo, senao
            # alguem esta tentando parear com credencial de terceiro.
            await sessao.send(
                protocol.make_packet(PAIR_REJECT, {"reason": "certificado divergente"})
            )
            return
        sessao.peer_certificate = pem
        self._abre_pendente(sessao, fingerprint, iniciado_por_nos=False, pem=pem)

    def _abre_pendente(self, sessao, fingerprint, iniciado_por_nos, pem=None):
        anterior = self._pending.get(sessao.device_id)
        if anterior is not None and anterior.timer:
            # Sem cancelar, o timer velho dispara depois e derruba o pareamento
            # novo, que ainda estava dentro do proprio prazo. Acontece com dois
            # request_pair seguidos, um duplo clique na UI da fatia 2 basta.
            anterior.timer.cancel()
        codigo = pairing.pair_code(
            pairing.fingerprint_of_file(self._cfg.cert_path), fingerprint
        )
        pendente = _PendingPair(sessao, fingerprint, codigo, iniciado_por_nos)
        pendente.pem = pem
        pendente.timer = asyncio.get_running_loop().call_later(
            self._cfg.pair_timeout,
            lambda: self._cancela_pendente(sessao.device_id, "timeout"),
        )
        self._pending[sessao.device_id] = pendente
        self._emit("pair.prompt", {
            "device_id": sessao.device_id,
            "name": sessao.name,
            "code": codigo,
        })

    async def confirm_pair(self, device_id, accept):
        pendente = self._pending.get(device_id)
        if pendente is None:
            return False
        if not accept:
            await pendente.session.send(
                protocol.make_packet(PAIR_REJECT, {"reason": "recusado pelo usuario"})
            )
            self._cancela_pendente(device_id, "recusado pelo usuario")
            return True
        pendente.local_ok = True
        await pendente.session.send(
            protocol.make_packet(PAIR_ACCEPT, {"certificate": self._cert_pem})
        )
        self._talvez_conclui(device_id)
        return True

    async def _on_pair_accept(self, sessao):
        pendente = self._pending.get(sessao.device_id)
        if pendente is None:
            return
        pendente.remoto_ok = True
        self._talvez_conclui(sessao.device_id)

    def _talvez_conclui(self, device_id):
        pendente = self._pending.get(device_id)
        if pendente is None or not (pendente.local_ok and pendente.remoto_ok):
            return
        pem = getattr(pendente, "pem", None) or self._pem_do_handshake(pendente.session)
        self._trust.add(pairing.Device(
            device_id=device_id,
            name=pendente.session.name or device_id,
            fingerprint=pendente.peer_fingerprint,
            certificate=pem,
        ))
        self._trust.save()
        pendente.session.paired = True
        if pendente.timer:
            pendente.timer.cancel()
        del self._pending[device_id]
        self._emit("pair.result", {"device_id": device_id, "accepted": True})
        self._emit("device.state", {
            "device_id": device_id, "state": "connected", "paired": True,
        })

    def _pem_do_handshake(self, sessao):
        objeto_pem = getattr(sessao, "peer_certificate", None)
        if objeto_pem:
            return objeto_pem
        writer_ssl = sessao._writer.get_extra_info("ssl_object")
        der = writer_ssl.getpeercert(binary_form=True) if writer_ssl else None
        return ssl.DER_cert_to_PEM_cert(der) if der else ""

    def _cancela_pendente(self, device_id, reason):
        pendente = self._pending.pop(device_id, None)
        if pendente is None:
            return
        if pendente.timer:
            pendente.timer.cancel()
        self._emit("pair.result", {
            "device_id": device_id, "accepted": False, "reason": reason,
        })

    async def unpair(self, device_id):
        removido = self._trust.remove(device_id)
        if removido:
            self._trust.save()
            sessao = self._sessions.get(device_id)
            if sessao:
                await sessao.close()
        return removido

    def _emit(self, kind, payload):
        try:
            self._on_event(kind, payload)
        except Exception:
            log.exception("handler de evento falhou para %s", kind)
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `cd 12-phone-link/files && python -m pytest tests/test_transport_pairing.py -v`
Expected: PASS, 7 testes.

- [ ] **Step 5: Rodar a suíte inteira, para garantir que nada regrediu**

Run: `cd 12-phone-link/files && python -m pytest tests/ -v`
Expected: PASS, todos.

- [ ] **Step 6: Commit**

```bash
git add 12-phone-link/files/phoned/transport.py 12-phone-link/files/tests/test_transport_pairing.py
git commit -m "feat(phone-link): pareamento com codigo confirmado e gate de sessao nao pareada"
```

---

### Task 8: Heartbeat, reconexão e ping medido

**Files:**
- Modify: `12-phone-link/files/phoned/transport.py`
- Create: `12-phone-link/files/tests/test_transport_heartbeat.py`

**Interfaces:**
- Consumes: tudo da Task 7.
- Produces: `Transport.ping(device_id) -> float | None` (latência em milissegundos, `None` se não houver sessão ou se estourar), `Transport.ensure_connected(identity, host)` (chamado pela descoberta, respeita backoff), e o laço interno de heartbeat que emite `device.state` com `state="disconnected"` após `session_timeout`.

- [ ] **Step 1: Escrever os testes que falham**

`12-phone-link/files/tests/test_transport_heartbeat.py`:

```python
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


async def test_sessao_nao_pareada_e_muda_tambem_e_reapada(tmp_path):
    """Quem se identifica e nunca pede pareamento nao fica pendurado.

    Essa sessao nao tem pair_timeout cuidando dela, porque o prazo so nasce
    quando alguem pede o pareamento. Se o heartbeat pulasse a checagem de
    sessao morta para nao pareadas, ela viveria para sempre.
    """
    a = await monta(tmp_path, "a", 45213, ping_interval=0.1, session_timeout=0.3)
    b = await monta(tmp_path, "b", 45214, ping_interval=0.1, session_timeout=0.3)
    try:
        await a.tr.connect("127.0.0.1", b.cfg.tcp_port)
        await asyncio.sleep(0.15)
        assert a.tr.sessions(), "a sessao deveria ter subido"
        sessao = a.tr.sessions()[0]
        assert sessao.paired is False

        agora = asyncio.get_running_loop().time()
        a.tr._ultimo_pacote[id(sessao)] = agora - 999
        await asyncio.sleep(0.5)

        assert a.tr.sessions() == [], "sessao nao pareada e muda deveria cair"
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
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `cd 12-phone-link/files && python -m pytest tests/test_transport_heartbeat.py -v`
Expected: FAIL com `AttributeError: 'Transport' object has no attribute 'ping'`

- [ ] **Step 3: Acrescentar o heartbeat ao `Transport`**

No `__init__` de `Transport`, acrescente:

```python
        self._pending_pings = {}
        self._backoff = {}
        self._ultimo_pacote = {}
        self._heartbeat = None
```

No `start()`, depois de criar o servidor:

```python
        self._heartbeat = asyncio.create_task(self._laco_heartbeat())
```

No `stop()`, antes de fechar as sessões:

```python
        if self._heartbeat:
            self._heartbeat.cancel()
            try:
                await self._heartbeat
            except asyncio.CancelledError:
                pass
            self._heartbeat = None
```

Em `_despacha`, no caso `PONG`, resolva o futuro pendente antes de emitir:

```python
            case _ if tipo == PONG:
                echo = packet["body"].get("echo_id")
                futuro = self._pending_pings.pop(echo, None)
                if futuro and not futuro.done():
                    futuro.set_result(asyncio.get_running_loop().time())
                self._emit("pong", {"device_id": sessao.device_id, "echo_id": echo})
```

No início de `_despacha`, registre a atividade da sessão:

```python
        self._ultimo_pacote[id(sessao)] = asyncio.get_running_loop().time()
```

E acrescente ao final da classe:

```python
    MAX_BACKOFF = 60.0

    async def ping(self, device_id):
        sessao = self._sessions.get(device_id)
        if sessao is None:
            return None
        loop = asyncio.get_running_loop()
        packet = protocol.make_packet(PING)
        futuro = loop.create_future()
        self._pending_pings[packet["id"]] = futuro
        comeco = loop.time()
        try:
            await sessao.send(packet)
            fim = await asyncio.wait_for(futuro, timeout=self._cfg.session_timeout)
        except (asyncio.TimeoutError, ConnectionError, ssl.SSLError):
            self._pending_pings.pop(packet["id"], None)
            return None
        return (fim - comeco) * 1000.0

    async def ensure_connected(self, identity, host):
        """Chamado pela descoberta. Nao abre segunda conexao nem fura o backoff."""
        if identity.device_id in self._sessions:
            return
        agora = asyncio.get_running_loop().time()
        proibido_ate = self._backoff.get(identity.device_id, (0.0, 0.0))[1]
        if agora < proibido_ate:
            return
        sessao = await self.connect(host, identity.port)
        if sessao is None:
            self._proximo_backoff(identity.device_id)
        else:
            self._zera_backoff(identity.device_id)

    def _proximo_backoff(self, device_id):
        atual, _ = self._backoff.get(device_id, (0.0, 0.0))
        proximo = 1.0 if atual == 0.0 else min(atual * 2, self.MAX_BACKOFF)
        agora = asyncio.get_running_loop().time()
        self._backoff[device_id] = (proximo, agora + proximo)
        return proximo

    def _zera_backoff(self, device_id):
        self._backoff.pop(device_id, None)

    async def _laco_heartbeat(self):
        while True:
            await asyncio.sleep(self._cfg.ping_interval)
            agora = asyncio.get_running_loop().time()
            for sessao in list(self._sessions.values()):
                # A checagem de sessao morta vale para todas, pareadas ou nao.
                # Uma sessao que se identificou e nunca pediu pareamento nao tem
                # pair_timeout para cuidar dela, e ficaria pendurada para sempre
                # se so as pareadas fossem verificadas aqui.
                visto = self._ultimo_pacote.get(id(sessao), agora)
                if agora - visto > self._cfg.session_timeout:
                    log.info("sessao com %s sem resposta, encerrando", sessao.device_id)
                    await self._encerra(sessao)
                    continue
                if not sessao.paired:
                    # O que a sessao em pareamento nao pode receber e o ping:
                    # phone.ping nao comeca com pair., entao o gate do outro lado
                    # derrubaria a conexao antes de o usuario confirmar o codigo.
                    continue
                try:
                    await sessao.send(protocol.make_packet(PING))
                except (ConnectionError, ssl.SSLError):
                    await self._encerra(sessao)
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `cd 12-phone-link/files && python -m pytest tests/test_transport_heartbeat.py -v`
Expected: PASS, 5 testes.

- [ ] **Step 5: Rodar a suíte inteira**

Run: `cd 12-phone-link/files && python -m pytest tests/ -v`
Expected: PASS, todos.

- [ ] **Step 6: Commit**

```bash
git add 12-phone-link/files/phoned/transport.py 12-phone-link/files/tests/test_transport_heartbeat.py
git commit -m "feat(phone-link): heartbeat, deteccao de sessao morta e backoff de reconexao"
```

---

### Task 9: Servidor IPC por unix socket

**Files:**
- Create: `12-phone-link/files/phoned/ipc.py`
- Create: `12-phone-link/files/tests/test_ipc.py`

**Interfaces:**
- Consumes: `protocol`.
- Produces: `IpcServer(path, handler)` com `async start()`, `async stop()`, `broadcast(kind: str, payload: dict) -> None`. `handler` é `async handler(command: str, body: dict) -> dict`.

**Formato:** o cliente envia um pacote normal cujo `type` é o comando (`list`, `pair`, `unpair`, `ping`, `connect`). O daemon responde com um pacote de `type` igual a `<comando>.result` e o mesmo `id` no campo `body["request_id"]`. Eventos empurrados chegam a todos os clientes com o `type` do evento.

- [ ] **Step 1: Escrever os testes que falham**

`12-phone-link/files/tests/test_ipc.py`:

```python
import asyncio

import pytest

from phoned import ipc, protocol


async def cliente(caminho):
    return await asyncio.open_unix_connection(str(caminho))


async def test_comando_recebe_resposta(tmp_path):
    async def handler(command, body):
        return {"eco": command, "recebido": body}

    servidor = ipc.IpcServer(tmp_path / "ipc.sock", handler)
    await servidor.start()
    try:
        reader, writer = await cliente(tmp_path / "ipc.sock")
        writer.write(protocol.encode(protocol.make_packet("list", {"x": 1}, packet_id="req-1")))
        await writer.drain()
        resposta = protocol.decode(await reader.readline())
        writer.close()
    finally:
        await servidor.stop()

    assert resposta["type"] == "list.result"
    assert resposta["body"]["request_id"] == "req-1"
    assert resposta["body"]["eco"] == "list"
    assert resposta["body"]["recebido"] == {"x": 1}


async def test_broadcast_chega_a_todos_os_clientes(tmp_path):
    async def handler(command, body):
        return {}

    servidor = ipc.IpcServer(tmp_path / "ipc.sock", handler)
    await servidor.start()
    try:
        r1, w1 = await cliente(tmp_path / "ipc.sock")
        r2, w2 = await cliente(tmp_path / "ipc.sock")
        await asyncio.sleep(0.05)
        servidor.broadcast("device.state", {"device_id": "a", "state": "connected"})
        await asyncio.sleep(0.05)
        p1 = protocol.decode(await r1.readline())
        p2 = protocol.decode(await r2.readline())
        w1.close()
        w2.close()
    finally:
        await servidor.stop()

    assert p1["type"] == p2["type"] == "device.state"
    assert p1["body"]["device_id"] == "a"


async def test_linha_invalida_gera_erro_e_nao_derruba_o_servidor(tmp_path):
    async def handler(command, body):
        return {"ok": True}

    servidor = ipc.IpcServer(tmp_path / "ipc.sock", handler)
    await servidor.start()
    try:
        reader, writer = await cliente(tmp_path / "ipc.sock")
        writer.write(b"nao e json\n")
        await writer.drain()
        erro = protocol.decode(await reader.readline())
        writer.write(protocol.encode(protocol.make_packet("list", packet_id="req-2")))
        await writer.drain()
        ok = protocol.decode(await reader.readline())
        writer.close()
    finally:
        await servidor.stop()

    assert erro["type"] == "error"
    assert ok["type"] == "list.result"


async def test_handler_que_levanta_excecao_vira_pacote_de_erro(tmp_path):
    async def handler(command, body):
        raise RuntimeError("estourou")

    servidor = ipc.IpcServer(tmp_path / "ipc.sock", handler)
    await servidor.start()
    try:
        reader, writer = await cliente(tmp_path / "ipc.sock")
        writer.write(protocol.encode(protocol.make_packet("list", packet_id="req-3")))
        await writer.drain()
        resposta = protocol.decode(await reader.readline())
        writer.close()
    finally:
        await servidor.stop()

    assert resposta["type"] == "error"
    assert "estourou" in resposta["body"]["message"]


async def test_socket_orfao_e_removido_na_subida(tmp_path):
    caminho = tmp_path / "ipc.sock"
    caminho.write_text("resto de um daemon morto")

    async def handler(command, body):
        return {}

    servidor = ipc.IpcServer(caminho, handler)
    await servidor.start()
    try:
        reader, writer = await cliente(caminho)
        writer.close()
    finally:
        await servidor.stop()
    assert not caminho.exists()


async def test_socket_tem_permissao_restrita(tmp_path):
    async def handler(command, body):
        return {}

    caminho = tmp_path / "ipc.sock"
    servidor = ipc.IpcServer(caminho, handler)
    await servidor.start()
    try:
        assert caminho.stat().st_mode & 0o077 == 0
    finally:
        await servidor.stop()
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `cd 12-phone-link/files && python -m pytest tests/test_ipc.py -v`
Expected: FAIL com `ModuleNotFoundError: No module named 'phoned.ipc'`

- [ ] **Step 3: Implementar `ipc.py`**

```python
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
        self._server = await asyncio.start_unix_server(
            self._atende, path=str(self.path),
            # Mesmo motivo do transport: sem isto o buffer seria o default de
            # 64KB e o limite de 1MB do protocolo nao valeria aqui. E por este
            # socket que a fatia 2 vai mandar notificacao com icone.
            limit=protocol.MAX_LINE_BYTES,
        )
        os.chmod(self.path, 0o600)

    async def stop(self):
        # Cede o controle uma vez antes de fechar. Sem isto, uma conexao ja
        # aceita pelo sistema mas ainda nao despachada pelo asyncio faz o
        # Server acordar duas vezes durante o close, e a excecao resultante
        # aparece como PytestUnraisableExceptionWarning na saida dos testes.
        await asyncio.sleep(0)
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
                try:
                    linha = await reader.readline()
                except ValueError as exc:
                    # Linha acima do buffer. Sem esta traducao a tarefa do
                    # cliente morreria por excecao nao tratada, e do outro lado
                    # isso apareceria como EOF silencioso em vez de erro.
                    await self._responde(writer, protocol.make_packet(
                        "error", {"message": f"linha acima do limite: {exc}"}
                    ))
                    break
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
```

- [ ] **Step 4: Rodar e confirmar que passa**

Run: `cd 12-phone-link/files && python -m pytest tests/test_ipc.py -v`
Expected: PASS, 6 testes.

- [ ] **Step 5: Commit**

```bash
git add 12-phone-link/files/phoned/ipc.py 12-phone-link/files/tests/test_ipc.py
git commit -m "feat(phone-link): servidor IPC por unix socket com comandos e eventos"
```

---

### Task 10: O daemon montado

**Files:**
- Create: `12-phone-link/files/phoned/daemon.py`
- Create: `12-phone-link/files/phoned/__main__.py`
- Create: `12-phone-link/files/tests/test_daemon.py`

**Interfaces:**
- Consumes: `config`, `pairing`, `discovery`, `transport`, `ipc`.
- Produces: `Daemon(cfg)` com `async start()`, `async stop()`, `async handle_command(command, body) -> dict`. `main(argv=None) -> int` em `__main__.py`.

**Comandos do IPC e o que devolvem:**

| Comando | Body de entrada | Body da resposta |
|---------|-----------------|------------------|
| `list` | `{}` | `{"devices": [{"device_id", "name", "paired", "connected", "address"}]}` |
| `pair` | `{"device_id": "..."}` | `{"ok": bool, "error": str opcional}` |
| `confirm` | `{"device_id": "...", "accept": bool}` | `{"ok": bool}` |
| `unpair` | `{"device_id": "..."}` | `{"ok": bool}` |
| `ping` | `{"device_id": "..."}` | `{"latency_ms": float ou null}` |
| `connect` | `{"host": "...", "port": int opcional}` | `{"ok": bool}` |

- [ ] **Step 1: Escrever os testes que falham**

`12-phone-link/files/tests/test_daemon.py`:

```python
import asyncio

import pytest

from phoned import config, daemon, protocol


async def sobe(tmp_path, nome, porta, alvos):
    cfg = config.load_config(
        state_dir=tmp_path / nome / "state", runtime_dir=tmp_path / nome / "run",
        name=nome, tcp_port=porta, discovery_port=porta,
        announce_targets=alvos, announce_interval=0.2, pair_timeout=5.0,
    )
    d = daemon.Daemon(cfg)
    await d.start()
    return d


async def test_list_comeca_vazio(tmp_path):
    d = await sobe(tmp_path, "a", 45301, [])
    try:
        assert await d.handle_command("list", {}) == {"devices": []}
    finally:
        await d.stop()


async def test_comando_desconhecido_levanta_erro(tmp_path):
    d = await sobe(tmp_path, "a", 45302, [])
    try:
        with pytest.raises(ValueError):
            await d.handle_command("inventado", {})
    finally:
        await d.stop()


async def test_descoberta_leva_a_conexao_automatica(tmp_path):
    a = await sobe(tmp_path, "a", 45303, [("127.0.0.1", 45304)])
    b = await sobe(tmp_path, "b", 45304, [("127.0.0.1", 45303)])
    try:
        await asyncio.sleep(1.0)
        listagem = await a.handle_command("list", {})
        assert [d["name"] for d in listagem["devices"]] == ["b"]
        assert listagem["devices"][0]["connected"] is True
        assert listagem["devices"][0]["paired"] is False
    finally:
        await a.stop()
        await b.stop()


async def test_ipc_responde_ao_comando_list(tmp_path):
    d = await sobe(tmp_path, "a", 45305, [])
    try:
        reader, writer = await asyncio.open_unix_connection(str(d.cfg.ipc_path))
        writer.write(protocol.encode(protocol.make_packet("list", packet_id="r1")))
        await writer.drain()
        resposta = protocol.decode(await reader.readline())
        writer.close()
        assert resposta["type"] == "list.result"
        assert resposta["body"]["devices"] == []
    finally:
        await d.stop()


async def test_eventos_do_transport_sao_empurrados_pelo_ipc(tmp_path):
    a = await sobe(tmp_path, "a", 45306, [("127.0.0.1", 45307)])
    try:
        reader, writer = await asyncio.open_unix_connection(str(a.cfg.ipc_path))
        b = await sobe(tmp_path, "b", 45307, [("127.0.0.1", 45306)])
        try:
            evento = protocol.decode(await asyncio.wait_for(reader.readline(), timeout=5))
        finally:
            await b.stop()
        writer.close()
        assert evento["type"] == "device.state"
        assert evento["body"]["state"] == "connected"
    finally:
        await a.stop()


async def test_stop_remove_o_socket(tmp_path):
    d = await sobe(tmp_path, "a", 45308, [])
    caminho = d.cfg.ipc_path
    assert caminho.exists()
    await d.stop()
    assert not caminho.exists()
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `cd 12-phone-link/files && python -m pytest tests/test_daemon.py -v`
Expected: FAIL com `ModuleNotFoundError: No module named 'phoned.daemon'`

- [ ] **Step 3: Implementar `daemon.py`**

```python
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
```

- [ ] **Step 4: Implementar `__main__.py`**

```python
"""Ponto de entrada do phoned."""

import argparse
import asyncio
import logging
import signal
import sys

from . import config, daemon


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="phoned", description="Daemon do Phone Link")
    parser.add_argument("--state-dir", default=None)
    parser.add_argument("--runtime-dir", default=None)
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--name", default=None)
    parser.add_argument("--log-level", default="INFO")
    return parser.parse_args(argv)


async def _executa(cfg):
    servico = daemon.Daemon(cfg)
    # O start entra no try: ele sobe IPC, transporte e descoberta nessa ordem,
    # entao uma porta ocupada estoura depois de o socket do IPC ja existir. Sem
    # o stop, o arquivo ficaria para tras e faria a proxima subida legitima
    # falhar por um motivo que nao tem nada a ver com a causa real.
    try:
        await servico.start()
        parada = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sinal in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sinal, parada.set)
        await parada.wait()
    finally:
        await servico.stop()


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    overrides = {}
    if args.port is not None:
        overrides["tcp_port"] = args.port
        overrides["discovery_port"] = args.port
        overrides["announce_targets"] = [("255.255.255.255", args.port)]
    if args.name is not None:
        overrides["name"] = args.name

    try:
        cfg = config.load_config(
            state_dir=args.state_dir, runtime_dir=args.runtime_dir, **overrides
        )
    except OSError as exc:
        print(f"phoned: nao consegui preparar os diretorios: {exc}", file=sys.stderr)
        return 1

    try:
        asyncio.run(_executa(cfg))
    except OSError as exc:
        # Porta ocupada cai aqui. Falhar claro e melhor que trocar de porta,
        # porque porta variavel quebraria a descoberta.
        print(f"phoned: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Rodar e confirmar que passa**

Run: `cd 12-phone-link/files && python -m pytest tests/test_daemon.py -v`
Expected: PASS, 6 testes.

- [ ] **Step 6: Conferir que o daemon sobe de verdade e morre limpo**

Run:
```bash
cd 12-phone-link/files && timeout 3 python -m phoned \
  --state-dir /tmp/phone-manual/state --runtime-dir /tmp/phone-manual/run \
  --port 45999 --log-level DEBUG; echo "saida: $?"
```
Expected: log `phoned no ar como ...`, encerra pelo timeout, e `/tmp/phone-manual/run/ipc.sock` não fica para trás.

- [ ] **Step 7: Commit**

```bash
git add 12-phone-link/files/phoned/daemon.py 12-phone-link/files/phoned/__main__.py \
        12-phone-link/files/tests/test_daemon.py
git commit -m "feat(phone-link): daemon que integra descoberta, transporte e IPC"
```

---

### Task 11: CLI `phonectl`

**Files:**
- Create: `12-phone-link/files/phonectl`
- Create: `12-phone-link/files/tests/test_phonectl.py`

**Interfaces:**
- Consumes: o contrato de IPC da Task 9 e os comandos da Task 10.
- Produces: executável `phonectl` com os subcomandos `list`, `pair <device_id>`, `confirm <device_id> [--reject]`, `unpair <device_id>`, `ping <device_id>`, `connect <host> [--port N]`, `watch`.

**Nota:** a CLI não importa `phoned`. Ela fala o protocolo de linha JSON direto, o que a mantém como cliente burro e prova que o contrato de IPC é suficiente para o QML da fatia 2.

- [ ] **Step 1: Escrever os testes que falham**

`12-phone-link/files/tests/test_phonectl.py`:

```python
import asyncio
import json
import subprocess
import sys
from pathlib import Path

import pytest

RAIZ = Path(__file__).resolve().parent.parent
PHONECTL = RAIZ / "phonectl"


async def servidor_falso(caminho, respostas):
    """Unix socket que responde a qualquer comando com um pacote fixo."""

    async def atende(reader, writer):
        while True:
            linha = await reader.readline()
            if not linha:
                break
            pedido = json.loads(linha)
            corpo = dict(respostas.get(pedido["type"], {}))
            corpo["request_id"] = pedido["id"]
            writer.write(json.dumps({
                "id": "resp", "type": f"{pedido['type']}.result",
                "ts": 1, "body": corpo,
            }).encode() + b"\n")
            await writer.drain()

    return await asyncio.start_unix_server(atende, path=str(caminho))


def roda(caminho, *args):
    return subprocess.run(
        [sys.executable, str(PHONECTL), "--socket", str(caminho), *args],
        capture_output=True, text=True, timeout=10,
    )


async def test_list_imprime_tabela(tmp_path):
    caminho = tmp_path / "ipc.sock"
    srv = await servidor_falso(caminho, {"list": {"devices": [
        {"device_id": "cel-1", "name": "celular", "paired": True,
         "connected": True, "address": "192.168.0.5"},
    ]}})
    try:
        resultado = await asyncio.to_thread(roda, caminho, "list")
    finally:
        srv.close()
    assert resultado.returncode == 0
    assert "celular" in resultado.stdout
    assert "cel-1" in resultado.stdout
    assert "192.168.0.5" in resultado.stdout


async def test_list_sem_aparelhos_avisa(tmp_path):
    caminho = tmp_path / "ipc.sock"
    srv = await servidor_falso(caminho, {"list": {"devices": []}})
    try:
        resultado = await asyncio.to_thread(roda, caminho, "list")
    finally:
        srv.close()
    assert resultado.returncode == 0
    assert "nenhum aparelho" in resultado.stdout.lower()


async def test_ping_mostra_latencia(tmp_path):
    caminho = tmp_path / "ipc.sock"
    srv = await servidor_falso(caminho, {"ping": {"latency_ms": 12.5}})
    try:
        resultado = await asyncio.to_thread(roda, caminho, "ping", "cel-1")
    finally:
        srv.close()
    assert resultado.returncode == 0
    assert "12.5" in resultado.stdout


async def test_ping_sem_resposta_sai_com_erro(tmp_path):
    caminho = tmp_path / "ipc.sock"
    srv = await servidor_falso(caminho, {"ping": {"latency_ms": None}})
    try:
        resultado = await asyncio.to_thread(roda, caminho, "ping", "cel-1")
    finally:
        srv.close()
    assert resultado.returncode == 1
    assert "sem resposta" in resultado.stderr.lower()


async def test_confirm_com_reject_envia_accept_false(tmp_path):
    caminho = tmp_path / "ipc.sock"
    recebidos = []

    async def atende(reader, writer):
        linha = await reader.readline()
        pedido = json.loads(linha)
        recebidos.append(pedido)
        writer.write(json.dumps({
            "id": "r", "type": "confirm.result", "ts": 1,
            "body": {"ok": True, "request_id": pedido["id"]},
        }).encode() + b"\n")
        await writer.drain()

    srv = await asyncio.start_unix_server(atende, path=str(caminho))
    try:
        resultado = await asyncio.to_thread(roda, caminho, "confirm", "cel-1", "--reject")
    finally:
        srv.close()
    assert resultado.returncode == 0
    assert recebidos[0]["body"] == {"device_id": "cel-1", "accept": False}


def test_daemon_desligado_da_mensagem_util(tmp_path):
    resultado = roda(tmp_path / "nao-existe.sock", "list")
    assert resultado.returncode == 1
    assert "phoned" in resultado.stderr.lower()
```

- [ ] **Step 2: Rodar e confirmar que falha**

Run: `cd 12-phone-link/files && python -m pytest tests/test_phonectl.py -v`
Expected: FAIL, o arquivo `phonectl` não existe.

- [ ] **Step 3: Implementar `phonectl`**

```python
#!/usr/bin/env python3
"""Cliente de linha de comando do phoned.

Nao importa o pacote phoned de proposito: fala o mesmo protocolo de linha
JSON que o QML vai falar, o que mantem o contrato de IPC honesto.
"""

import argparse
import asyncio
import json
import os
import sys
import uuid
from pathlib import Path


def caminho_padrao():
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    return Path(base) / "phone" / "ipc.sock"


def pacote(tipo, corpo=None):
    packet_id = str(uuid.uuid4())
    linha = json.dumps({
        "id": packet_id, "type": tipo, "ts": 0, "body": corpo or {},
    }, ensure_ascii=False) + "\n"
    return linha, packet_id


async def pergunta(caminho, tipo, corpo=None):
    reader, writer = await asyncio.open_unix_connection(str(caminho))
    try:
        linha_pedido, meu_id = pacote(tipo, corpo)
        writer.write(linha_pedido.encode("utf-8"))
        await writer.drain()
        while True:
            linha = await reader.readline()
            if not linha:
                raise ConnectionError("phoned fechou a conexao sem responder")
            resposta = json.loads(linha)

            # O tipo sozinho nao basta. O daemon empurra um evento pair.result
            # para todos os clientes conectados, com exatamente o mesmo nome da
            # resposta direta ao comando pair. Um pareamento alheio expirando
            # seria lido como resposta nossa. E para isso que o request_id
            # existe.
            if resposta["body"].get("request_id") == meu_id:
                return resposta

            # Erro sem correlacao so chega quando o daemon nao conseguiu sequer
            # ler o nosso pacote, e nunca vem por broadcast, entao e nosso.
            if resposta["type"] == "error" and "request_id" not in resposta["body"]:
                return resposta
    finally:
        writer.close()


async def observa(caminho):
    reader, writer = await asyncio.open_unix_connection(str(caminho))
    try:
        while True:
            linha = await reader.readline()
            if not linha:
                return
            evento = json.loads(linha)
            print(f"{evento['type']}: {json.dumps(evento['body'], ensure_ascii=False)}")
    finally:
        writer.close()


def imprime_lista(devices):
    if not devices:
        print("Nenhum aparelho conhecido ainda.")
        return
    largura = max(len(d["name"]) for d in devices)
    for d in devices:
        estado = "conectado" if d["connected"] else "offline"
        confianca = "pareado" if d["paired"] else "nao pareado"
        endereco = d.get("address") or "-"
        print(f"{d['name']:<{largura}}  {d['device_id']}  {estado}  {confianca}  {endereco}")


async def executa(args):
    caminho = Path(args.socket) if args.socket else caminho_padrao()

    if args.comando == "watch":
        await observa(caminho)
        return 0

    pedidos = {
        "list": ("list", {}),
        "pair": ("pair", {"device_id": getattr(args, "device_id", None)}),
        "confirm": ("confirm", {
            "device_id": getattr(args, "device_id", None), "accept": not args.reject,
        }),
        "unpair": ("unpair", {"device_id": getattr(args, "device_id", None)}),
        "ping": ("ping", {"device_id": getattr(args, "device_id", None)}),
        "connect": ("connect", {"host": getattr(args, "host", None), "port": args.port}),
    }
    tipo, corpo = pedidos[args.comando]
    resposta = await pergunta(caminho, tipo, corpo)

    if resposta["type"] == "error":
        print(f"phonectl: {resposta['body'].get('message')}", file=sys.stderr)
        return 1

    corpo = resposta["body"]
    match args.comando:
        case "list":
            imprime_lista(corpo["devices"])
        case "ping":
            latencia = corpo.get("latency_ms")
            if latencia is None:
                print("phonectl: sem resposta do aparelho", file=sys.stderr)
                return 1
            print(f"pong em {latencia:.1f} ms")
        case _:
            if not corpo.get("ok", False):
                print(f"phonectl: {args.comando} nao teve efeito", file=sys.stderr)
                return 1
            print("ok")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="phonectl", description="Controle do Phone Link")
    parser.add_argument("--socket", default=None, help="caminho do ipc.sock")
    sub = parser.add_subparsers(dest="comando", required=True)

    sub.add_parser("list", help="lista aparelhos conhecidos")
    sub.add_parser("watch", help="acompanha os eventos do daemon")

    for nome, ajuda in [
        ("pair", "pede pareamento"),
        ("unpair", "esquece um aparelho"),
        ("ping", "mede a latencia ate o aparelho"),
    ]:
        p = sub.add_parser(nome, help=ajuda)
        p.add_argument("device_id")

    p = sub.add_parser("confirm", help="confirma ou recusa um pareamento pendente")
    p.add_argument("device_id")
    p.add_argument("--reject", action="store_true", help="recusa em vez de aceitar")

    p = sub.add_parser("connect", help="conecta manualmente, para redes sem broadcast")
    p.add_argument("host")
    p.add_argument("--port", type=int, default=1739)

    args = parser.parse_args(argv if argv is not None else sys.argv[1:])
    if not hasattr(args, "reject"):
        args.reject = False
    if not hasattr(args, "port"):
        args.port = 1739

    try:
        return asyncio.run(executa(args))
    # ConnectionError cobre tanto a recusa do sistema quanto o caso de o daemon
    # cair no meio do pedido, que a propria pergunta levanta. Sem isso o segundo
    # apareceria como traceback cru.
    except (FileNotFoundError, ConnectionError):
        print(
            "phonectl: nao consegui falar com o phoned. Ele esta rodando? "
            "Tente: systemctl --user status phoned",
            file=sys.stderr,
        )
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Marcar como executável e rodar os testes**

Run:
```bash
chmod +x 12-phone-link/files/phonectl
cd 12-phone-link/files && python -m pytest tests/test_phonectl.py -v
```
Expected: PASS, 6 testes.

- [ ] **Step 5: Commit**

```bash
git add 12-phone-link/files/phonectl 12-phone-link/files/tests/test_phonectl.py
git commit -m "feat(phone-link): CLI phonectl como cliente do unix socket"
```

---

### Task 12: Teste de integração ponta a ponta

**Files:**
- Create: `12-phone-link/files/tests/test_integracao_loopback.py`

**Interfaces:**
- Consumes: `daemon.Daemon`, `config.load_config`.
- Produces: nada de novo. Este é o teste que prova o critério de sucesso da fatia.

**Por que existe:** os testes anteriores exercitam módulos. Este exercita o fluxo real do spec, do jeito que vai acontecer com o celular: dois processos completos, descoberta automática, pareamento com confirmação nos dois lados, ping, queda e reconexão.

- [ ] **Step 1: Escrever o teste**

`12-phone-link/files/tests/test_integracao_loopback.py`:

```python
"""Duas instancias completas do phoned no mesmo host, por loopback.

Substitui o celular durante o desenvolvimento e cobre o caminho inteiro do
spec: descoberta, pareamento, sessao, ping, queda e volta.
"""

import asyncio

import pytest

from phoned import config, daemon, protocol


async def sobe(tmp_path, nome, porta, porta_do_outro):
    cfg = config.load_config(
        state_dir=tmp_path / nome / "state",
        runtime_dir=tmp_path / nome / "run",
        name=nome,
        tcp_port=porta,
        discovery_port=porta,
        announce_targets=[("127.0.0.1", porta_do_outro)],
        announce_interval=0.3,
        ping_interval=0.3,
        session_timeout=1.5,
        pair_timeout=10.0,
    )
    servico = daemon.Daemon(cfg)
    await servico.start()
    return servico


async def espera(condicao, timeout=8.0, intervalo=0.1):
    limite = asyncio.get_running_loop().time() + timeout
    while asyncio.get_running_loop().time() < limite:
        if await condicao():
            return True
        await asyncio.sleep(intervalo)
    return False


async def test_fluxo_completo_descobrir_parear_pingar_e_reconectar(tmp_path):
    a = await sobe(tmp_path, "pc", 45401, 45402)
    b = await sobe(tmp_path, "celular", 45402, 45401)
    try:
        # 1. Descoberta automatica.
        async def conectaram():
            listagem = await a.handle_command("list", {})
            return any(d["connected"] for d in listagem["devices"])

        assert await espera(conectaram), "os dois nao se descobriram"

        # 2. Pareamento com confirmacao nos dois lados.
        assert (await a.handle_command("pair", {"device_id": b.cfg.device_id}))["ok"]

        async def pendente():
            return b.cfg.device_id in a._transport._pending

        assert await espera(pendente), "o pareamento nao ficou pendente"
        await b.handle_command("confirm", {"device_id": a.cfg.device_id, "accept": True})
        await a.handle_command("confirm", {"device_id": b.cfg.device_id, "accept": True})

        async def parearam():
            listagem = await a.handle_command("list", {})
            return all(d["paired"] for d in listagem["devices"])

        assert await espera(parearam), "o pareamento nao concluiu"
        assert a.cfg.devices_path.exists()
        assert b.cfg.devices_path.exists()

        # 3. Ping medido.
        resposta = await a.handle_command("ping", {"device_id": b.cfg.device_id})
        assert resposta["latency_ms"] is not None

        # 4. Queda e volta, sem reparear.
        await b.stop()

        async def caiu():
            listagem = await a.handle_command("list", {})
            return not any(d["connected"] for d in listagem["devices"])

        assert await espera(caiu), "a queda nao foi detectada"

        b = await sobe(tmp_path, "celular", 45402, 45401)

        async def voltou():
            listagem = await a.handle_command("list", {})
            return any(d["connected"] and d["paired"] for d in listagem["devices"])

        assert await espera(voltou), "nao reconectou sozinho"

        # 5. Continua funcionando sem novo pareamento.
        resposta = await a.handle_command("ping", {"device_id": b.cfg.device_id})
        assert resposta["latency_ms"] is not None
    finally:
        await a.stop()
        await b.stop()


async def test_terceiro_nao_pareado_nao_consegue_enviar_ping(tmp_path):
    a = await sobe(tmp_path, "pc", 45403, 45404)
    intruso = await sobe(tmp_path, "intruso", 45404, 45403)
    try:
        async def conectaram():
            return len(a._transport.sessions()) == 1

        assert await espera(conectaram)
        sessao = a._transport.sessions()[0]
        assert sessao.paired is False

        # O intruso tenta trafegar sem parear.
        sessao_do_intruso = intruso._transport.sessions()
        if sessao_do_intruso:
            await sessao_do_intruso[0].send(protocol.make_packet("phone.ping"))

        async def derrubou():
            return a._transport.sessions() == [] or intruso._transport.sessions() == []

        assert await espera(derrubou, timeout=4.0), "a sessao nao pareada nao foi cortada"
    finally:
        await a.stop()
        await intruso.stop()
```

- [ ] **Step 2: Rodar e observar**

Run: `cd 12-phone-link/files && python -m pytest tests/test_integracao_loopback.py -v -x`
Expected: PASS, 2 testes. Se falhar, o ponto de falha aponta direto para qual etapa do spec não está fechada. Corrija na task de origem, não neste arquivo.

- [ ] **Step 3: Rodar a suíte inteira e medir o tempo**

Run: `cd 12-phone-link/files && python -m pytest tests/ -v --durations=5`
Expected: PASS em tudo. A suíte inteira deve terminar em menos de 60 segundos.

- [ ] **Step 4: Commit**

```bash
git add 12-phone-link/files/tests/test_integracao_loopback.py
git commit -m "test(phone-link): integracao ponta a ponta com duas instancias em loopback"
```

---

### Task 13: Instalação, serviço systemd e README

**Files:**
- Create: `12-phone-link/files/phoned.service`
- Create: `12-phone-link/install.sh`
- Create: `12-phone-link/README.md`
- Modify: `README.md` (tabela de componentes na raiz)

**Interfaces:**
- Consumes: tudo.
- Produces: `~/.local/lib/phone/` com o pacote, `~/.local/bin/phonectl`, unit `phoned.service` em `~/.config/systemd/user/`.

- [ ] **Step 1: Escrever `phoned.service`**

`12-phone-link/files/phoned.service`:

```ini
[Unit]
Description=Phone Link, daemon de conexao com o celular
Documentation=https://github.com/OnlyLyan/omarchy-desktop-shell
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/.local/lib/phone/run-phoned
Restart=always
RestartSec=5
# O daemon guarda chave privada, entao o diretorio de estado fica so para o dono.
UMask=0077
# Endurecimento: o daemon so precisa de rede e do proprio estado.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=%h/.local/state/phone
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=default.target
```

- [ ] **Step 2: Escrever `install.sh`**

`12-phone-link/install.sh`:

```bash
#!/usr/bin/env bash
# Instala o Phone Link (fatia 1: transporte). Idempotente.
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HOME/.local/lib/phone"
BIN="$HOME/.local/bin"
UNIDADES="$HOME/.config/systemd/user"

echo ">> conferindo dependencias"
command -v python3 >/dev/null || { echo "faltou python3"; exit 1; }
command -v openssl >/dev/null || { echo "faltou openssl"; exit 1; }

echo ">> instalando o pacote em $LIB"
mkdir -p "$LIB" "$BIN" "$UNIDADES"
rm -rf "$LIB/phoned"
cp -r "$AQUI/files/phoned" "$LIB/phoned"

# Lancador com o PYTHONPATH embutido, para a unit nao depender do ambiente herdado.
cat > "$LIB/run-phoned" <<EOF
#!/usr/bin/env bash
export PYTHONPATH="$LIB"
exec python3 -m phoned "\$@"
EOF
chmod +x "$LIB/run-phoned"

echo ">> instalando o phonectl em $BIN"
install -m 755 "$AQUI/files/phonectl" "$BIN/phonectl"

echo ">> instalando a unit do systemd"
# Reescreve por completo em vez de anexar, entao rodar de novo nao duplica nada.
sed -e "s|^ExecStart=.*|ExecStart=$LIB/run-phoned|" \
    -e "s|^ReadWritePaths=.*|ReadWritePaths=$HOME/.local/state/phone|" \
    "$AQUI/files/phoned.service" > "$UNIDADES/phoned.service"

systemctl --user daemon-reload
systemctl --user enable --now phoned.service

echo
echo "pronto. Verifique com:"
echo "  systemctl --user status phoned"
echo "  phonectl list"
echo
echo "Se o PATH nao tiver ~/.local/bin, acrescente ao seu shell:"
echo '  export PATH="$HOME/.local/bin:$PATH"'
```

Marque como executável: `chmod +x 12-phone-link/install.sh`

- [ ] **Step 3: Rodar o instalador de verdade e verificar**

Run:
```bash
cd 12-phone-link && ./install.sh
systemctl --user status phoned --no-pager
phonectl list
```
Expected: serviço `active (running)`, e `phonectl list` imprime "Nenhum aparelho conhecido ainda."

- [ ] **Step 4: Rodar o instalador uma segunda vez, para provar a idempotência**

Run:
```bash
cd 12-phone-link && cp ~/.config/systemd/user/phoned.service /tmp/unit-antes
./install.sh
diff /tmp/unit-antes ~/.config/systemd/user/phoned.service && echo "unit identica"
systemctl --user status phoned --no-pager
```
Expected: `unit identica`, serviço `active (running)`, nenhum erro. A unit é reescrita inteira a cada execução, então não há como duplicar linha.

- [ ] **Step 5: Escrever `12-phone-link/README.md`**

Deve conter, seguindo o tom das outras pastas do repositório (o que faz, por que, como foi feito):

- O que é: daemon que conecta o PC ao celular pela rede local. Fatia 1 entrega só o transporte, sem notificação e sem UI.
- Por que não KDE Connect: acoplamento ao KDE e limitação para as fatias seguintes, principalmente transferência de arquivo.
- Por que o daemon é um processo separado do `qsbar`: `Quickshell.Io` só oferece `Socket` unix e `Process`, sem UDP e sem TLS. Verificado em 2026-08-07.
- Como funciona: broadcast UDP na 1739, TCP com TLS, pareamento por comparação de código de 6 caracteres, protocolo de linha JSON.
- A assimetria do handshake e por que o `pair.request` carrega o certificado.
- Comandos do `phonectl`, com exemplo de saída de cada um.
- O contrato do unix socket, tabela de comandos e de eventos, com um exemplo de linha de cada. Esta seção é o que a fatia 2 vai consumir.
- Como rodar os testes: `cd files && python -m pytest tests/ -v`.
- Onde fica o estado e como resetar tudo: `systemctl --user stop phoned && rm -rf ~/.local/state/phone`.
- Dependências: `python-pytest` e `python-pytest-asyncio` só para desenvolver, `openssl` em runtime.

- [ ] **Step 6: Acrescentar a linha na tabela do `README.md` da raiz**

Na tabela de componentes, após a linha do `11-monitor-panel`:

```markdown
| `12-phone-link` | Conexao com o celular Android pela rede local: daemon proprio (`phoned`) com descoberta, pareamento e canal TLS, mais a CLI `phonectl`. Fatia 1: so transporte, sem UI |
```

Na seção de dependências entre componentes, registrar que `12` **não** depende de `06` na fatia 1, e que a integração com a barra chega na fatia 2.

- [ ] **Step 7: Rodar a suíte inteira uma última vez**

Run: `cd 12-phone-link/files && python -m pytest tests/ -v`
Expected: PASS em tudo.

- [ ] **Step 8: Commit**

```bash
git add 12-phone-link/README.md 12-phone-link/install.sh \
        12-phone-link/files/phoned.service README.md
git commit -m "feat(phone-link): instalador idempotente, unit do systemd e documentacao"
```

---

## Verificação final da fatia

Percorra os critérios de sucesso do spec, um a um, e confirme cada um com o comando indicado. Não marque nenhum como atendido sem ver a saída.

- [ ] `systemctl --user restart phoned && systemctl --user status phoned` mostra `active (running)`.
- [ ] `python -m pytest tests/ -v` passa inteiro, incluindo `test_integracao_loopback.py`.
- [ ] `phonectl list` responde com o daemon no ar.
- [ ] `phonectl list` com o daemon parado imprime a mensagem de erro útil e sai com código 1.
- [ ] `journalctl --user -u phoned -n 50` não mostra exceção não tratada.
- [ ] Com o serviço no ar, `cd 12-phone-link/files && python -m phoned --port 1739` falha na hora com mensagem sobre a porta e sai com código 1, em vez de escolher outra porta.
- [ ] Reboot do PC e o serviço volta sozinho.

Os critérios 2, 3, 4, 5 e 6 do spec, que envolvem o celular real, ficam pendentes até o plano do app Android. O teste de integração em loopback é o substituto verificável enquanto isso, e cobre exatamente os mesmos caminhos de código.
