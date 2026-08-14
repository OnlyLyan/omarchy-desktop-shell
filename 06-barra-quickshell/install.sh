#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/files"
append_once(){ local marker="$1" dest="$2" frag="$3"; mkdir -p "$(dirname "$dest")"; touch "$dest"; if grep -qF "$marker" "$dest"; then echo "ja existe em $dest (pulado)"; else printf "\n" >> "$dest"; cat "$frag" >> "$dest"; echo "snippet -> $dest"; fi; }

mkdir -p ~/.config/quickshell/scripts
install -Dm644 shell.qml ~/.config/quickshell/shell.qml
install -Dm755 scripts/*.sh -t ~/.config/quickshell/scripts/
# nightlight-toggle: dependencia do toggle "Noturno" da central (a query de temperatura do
# hyprsunset mente no modo identity; este wrapper guarda o estado real em ~/.local/state/nightlight)
install -Dm755 nightlight-toggle ~/.local/bin/nightlight-toggle
# KittyStrip: faixa clicavel no topo da janela do kitty, desenhada pela barra.
# Instanciada pelo shell.qml, entao tem que existir antes de o qsbar subir.
[ -f KittyStrip.qml ] && install -Dm644 KittyStrip.qml ~/.config/quickshell/KittyStrip.qml
# omarchy-theme-fav: favoritos de tema. A UI do seletor (card Personalizacao) ja
# chama este script; sem ele, favoritar nao faz nada e falha CALADO.
[ -f omarchy-theme-fav ] && install -Dm755 omarchy-theme-fav ~/.local/bin/omarchy-theme-fav
# show-desktop: esconde/restaura tudo do workspace ativo (SUPER+D)
[ -f show-desktop ] && install -Dm755 show-desktop ~/.local/bin/show-desktop
# claude-janela: alimenta a KittyStrip com a janela do kitty em foco
[ -f claude-janela ] && install -Dm755 claude-janela ~/.local/bin/claude-janela
append_once "unit=qsbar" ~/.config/hypr/autostart.conf autostart.snippet.conf
echo "Pacote: quickshell-git (AUR). Desligar waybar: touch ~/.local/state/omarchy/toggles/waybar-off"
echo "Subir agora: systemctl --user restart qsbar  (ou relogar)"
echo
echo "A barra instancia GavetaPanel {} e NotificationPanel {}: rode os installs das"
echo "pastas 13 e 14 ANTES de subir o qsbar, senao o shell.qml falha por tipo desconhecido."
