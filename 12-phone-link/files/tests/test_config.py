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


def test_device_id_explicito_nao_cria_arquivo(tmp_path):
    cfg = config.load_config(
        state_dir=tmp_path / "state", runtime_dir=tmp_path / "run",
        device_id="meu-id-explicito",
    )
    assert cfg.device_id == "meu-id-explicito"
    assert not (cfg.state_dir / "device_id").exists()
