# 06 | Barra Quickshell (substitui a waybar) | N3X0-bar

A waybar do Omarchy foi substituida por uma barra propria em Quickshell (QML).

## Como foi feito
- Config principal em `shell.qml`, scripts auxiliares em `scripts/`.
- Pacote `quickshell-git` (AUR), compilado contra Qt 6.11.1 (o oficial contra 6.11.0 quebra).
- Autostart via `systemd-run --user --unit=qsbar quickshell` (unidade unica = UMA instancia,
  nunca duplica). Operar: `systemctl --user restart|stop|start qsbar`; log `journalctl --user -u qsbar`.
- Waybar desligada pelo toggle do Omarchy: flag `~/.local/state/omarchy/toggles/waybar-off`.
  Reverter: `rm` o flag ou `omarchy toggle waybar`. ATENCAO: `SUPER+SHIFT+SPACE` remove o flag
  E inicia a waybar por cima; reapertar tira.

## Conteudo da barra
- Menu Omarchy (esq), taskbar agrupada por app centralizada (bolinhas por janela, lista no hover;
  cada janela: clique foca/restaura via `taskbar-activate.sh`, e um **X** fecha a janela direto).
- Cluster CPU/RAM/bateria (dir) e central de acoes (chevron) estilo Windows, em secoes:
  Tocando agora (player MPRIS), volume master, Ajustes rapidos (Caffeine, Noturno via
  `nightlight-toggle`, Mic), Wi-Fi (dropdown iwd via `wifi-list.sh`/`wifi-connect.sh`), Bluetooth
  (QML puro, `Quickshell.Bluetooth`), card **Personalizacao** (tema + papel de parede),
  botoes Menu e Energia.
- **Painel de Som** (`audio.sh`): volume master + seletor de dispositivo de SAIDA + mixer por app
  (agrupa streams do mesmo app, com icone) + secao MICROFONE (volume + seletor de mic) + toggle de
  Bass boost (EasyEffects on-demand). Modelo "estilo Windows".
- **Previewer de wallpaper** (`wallpaper-engine`, pasta 08): grade de miniaturas, marca o ativo.
- Barra ~85% opaca.

## Tema (segue o Omarchy)
A barra nao tem mais cor fixa: um objeto `theme` no topo do `shell.qml` le
`~/.config/omarchy/current/theme/colors.toml` via `FileView` e acompanha o tema ativo do
Omarchy (papeis semanticos bg/fg/accent/ok/warn/danger/..., shades intermediarios derivados
com Qt.lighter/darker). Trocar pela central > **Personalizacao** mostra a grade de temas com
amostra de cor; clicar aplica via `omarchy-theme-set`. A recarga e reativa por IPC
(`qs ipc call theme reload`, disparado pelo hook `theme-set.d/10-reload-quickshell-bar`),
entao a cor muda sem reiniciar a barra nem fechar a central.

## Arquivos
- `files/shell.qml` -> `~/.config/quickshell/shell.qml`
- `files/scripts/*.sh` -> `~/.config/quickshell/scripts/` (wifi-list, wifi-connect, taskbar-activate, weather, **audio**)
- `files/nightlight-toggle` -> `~/.local/bin/nightlight-toggle` (dependencia do toggle Noturno)
- `files/autostart.snippet.conf` -> trecho pro `~/.config/hypr/autostart.conf`
- `files/hooks/10-reload-quickshell-bar` -> `~/.config/omarchy/hooks/theme-set.d/` (recarga reativa do tema)

Dependencias do painel de Som: `pactl`/`wpctl` (PipeWire); Bass boost usa `easyeffects` (opcional).
Obs: o Alt+Tab custom (`alttab-next.sh`/`alttab-prev.sh`) esta na pasta 07.

## Pacote
`quickshell-git` (AUR).

## Instalar
`./install.sh` (depois `touch ~/.local/state/omarchy/toggles/waybar-off` e relogar)
