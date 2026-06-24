#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/files"
append_once(){ local marker="$1" dest="$2" frag="$3"; mkdir -p "$(dirname "$dest")"; touch "$dest"; if grep -qF "$marker" "$dest"; then echo "ja existe em $dest (pulado)"; else printf "\n" >> "$dest"; cat "$frag" >> "$dest"; echo "snippet -> $dest"; fi; }

install -Dm644 hyprbars.conf ~/.config/hypr/hyprbars.conf
install -Dm755 window-minimize ~/.local/bin/window-minimize
append_once "hyprbars.conf" ~/.config/hypr/hyprland.conf hyprland-source.snippet.conf
append_once "window-minimize restore" ~/.config/hypr/bindings.conf bindings.snippet.conf
append_once "hyprpm reload -n" ~/.config/hypr/autostart.conf autostart.snippet.conf
echo "Instale o plugin: hyprpm add https://github.com/hyprwm/hyprland-plugins && hyprpm enable hyprbars && hyprpm reload"
