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
