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
append_once "unit=qsbar" ~/.config/hypr/autostart.conf autostart.snippet.conf
echo "Pacote: quickshell-git (AUR). Desligar waybar: touch ~/.local/state/omarchy/toggles/waybar-off"
echo "Subir agora: systemctl --user restart qsbar  (ou relogar)"
