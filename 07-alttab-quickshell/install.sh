#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/files"
append_once(){ local marker="$1" dest="$2" frag="$3"; mkdir -p "$(dirname "$dest")"; touch "$dest"; if grep -qF "$marker" "$dest"; then echo "ja existe em $dest (pulado)"; else printf "\n" >> "$dest"; cat "$frag" >> "$dest"; echo "snippet -> $dest"; fi; }

mkdir -p ~/.config/quickshell/scripts
install -Dm755 alttab-next.sh alttab-prev.sh -t ~/.config/quickshell/scripts/
append_once "alttab-next.sh" ~/.config/hypr/bindings.conf bindings.snippet.conf
echo "Depende da barra Quickshell (pasta 06) rodando."
