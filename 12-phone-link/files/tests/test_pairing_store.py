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
