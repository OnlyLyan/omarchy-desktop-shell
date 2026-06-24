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
- Menu Omarchy (esq), taskbar agrupada por app centralizada (bolinhas por janela, lista no hover,
  clique = `taskbar-activate.sh` que foca ou RESTAURA minimizada via store da pasta 05).
- Cluster CPU/RAM/bateria (dir) e central de acoes (chevron) estilo Windows: volume, Wi-Fi
  (dropdown que escaneia/conecta redes do iwd via `wifi-list.sh`/`wifi-connect.sh`), Bluetooth
  (QML puro via `Quickshell.Bluetooth`), clima (`weather.sh`), voxtype, botoes Menu e Energia.
- Tema Tokyo Night fixo, barra ~85% opaca.

## Arquivos
- `files/shell.qml` -> `~/.config/quickshell/shell.qml`
- `files/scripts/*.sh` -> `~/.config/quickshell/scripts/` (wifi-list, wifi-connect, taskbar-activate, weather)
- `files/autostart.snippet.conf` -> trecho pro `~/.config/hypr/autostart.conf`

Obs: o Alt+Tab custom (`alttab-next.sh`/`alttab-prev.sh`) esta na pasta 07.

## Pacote
`quickshell-git` (AUR).

## Instalar
`./install.sh` (depois `touch ~/.local/state/omarchy/toggles/waybar-off` e relogar)
