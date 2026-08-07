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
