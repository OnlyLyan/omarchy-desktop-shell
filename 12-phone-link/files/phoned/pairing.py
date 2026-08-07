"""Certificados, fingerprints e a lista de aparelhos confiaveis.

O certificado e gerado pelo binario openssl, e nao por uma biblioteca, para
manter o runtime do daemon com dependencia zero fora da stdlib.
"""

import hashlib
import json
import ssl
import subprocess
from dataclasses import asdict, dataclass
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
