#!/usr/bin/env bash
# publish.sh | sincroniza os arquivos vivos do sistema para as pastas files/
# deste repo (tutorial) e faz commit + push. Um comando pra publicar.
#
# Uso:
#   ./publish.sh                 usa mensagem padrao
#   ./publish.sh "sua mensagem"  usa a mensagem de commit dada
#   ./publish.sh -n              dry run: so mostra o que mudaria, sem tocar nada
#
# So mapeia os arquivos que sao copia 1:1 do sistema vivo. Arquivos que o repo
# reorganizou so pra publicacao NAO sao tocados aqui (edite-os a mao se precisar):
#   06 scripts wifi-list.sh / wifi-connect.sh (vivo tem um wifi.sh unico)
#   06 scripts weather.sh, hooks/, autostart.snippet.conf
#   05 snippets do hypr e window-minimize, 08 binarios, 09 pc-heartbeat
#
# NAO mapeado de proposito: 15-meus-temas/temas.tsv (regerado por
# `15-meus-temas/gera-lista.sh`, nao e copia 1:1 de um arquivo vivo) e os
# patches/, que sao diff de repositorio de terceiro.
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
QS="$HOME/.config/quickshell"
BIN="$HOME/.local/bin"

# manifest: "origem_viva::destino_no_repo" (destino relativo a raiz do repo)
MAP=(
  "$QS/shell.qml::06-barra-quickshell/files/shell.qml"
  "$QS/scripts/audio.sh::06-barra-quickshell/files/scripts/audio.sh"
  "$QS/scripts/taskbar-activate.sh::06-barra-quickshell/files/scripts/taskbar-activate.sh"
  "$BIN/nightlight-toggle::06-barra-quickshell/files/nightlight-toggle"
  "$QS/scripts/alttab-next.sh::07-alttab-quickshell/files/alttab-next.sh"
  "$QS/scripts/alttab-prev.sh::07-alttab-quickshell/files/alttab-prev.sh"
  "$QS/MonitorPanel.qml::11-monitor-panel/files/MonitorPanel.qml"
  "$QS/MonitorStep.qml::11-monitor-panel/files/MonitorStep.qml"
  "$QS/scripts/monitors.sh::11-monitor-panel/files/scripts/monitors.sh"
  "$QS/scripts/test-monitors.sh::11-monitor-panel/files/scripts/test-monitors.sh"
  "$QS/KittyStrip.qml::06-barra-quickshell/files/KittyStrip.qml"
  "$QS/scripts/taskbar-app.sh::06-barra-quickshell/files/scripts/taskbar-app.sh"
  "$QS/scripts/wifi.sh::06-barra-quickshell/files/scripts/wifi.sh"
  "$BIN/omarchy-theme-fav::06-barra-quickshell/files/omarchy-theme-fav"
  "$BIN/show-desktop::06-barra-quickshell/files/show-desktop"
  "$BIN/claude-janela::06-barra-quickshell/files/claude-janela"
  "$HOME/.config/hypr/hyprbars.conf::05-hyprbars-titlebar/files/hyprbars.conf"
  "$QS/GavetaPanel.qml::13-gaveta-de-janelas/files/GavetaPanel.qml"
  "$QS/scripts/gaveta.sh::13-gaveta-de-janelas/files/scripts/gaveta.sh"
  "$QS/NotificationPanel.qml::14-notificacoes/files/NotificationPanel.qml"
  "$BIN/notif-toggle-dnd::14-notificacoes/files/notif-toggle-dnd"
  "$HOME/.config/omarchy/hooks/post-boot.d/10-stop-mako::14-notificacoes/files/10-stop-mako"
  "$HOME/.config/omarchy/branding/screensaver.txt::15-meus-temas/files/branding/screensaver.txt"
)

dry=0
msg="sync: publica mudancas locais do shell"
case "${1:-}" in
  -n|--dry) dry=1 ;;
  "" ) ;;
  * ) msg="$*" ;;
esac

cd "$REPO"

# 1. detecta o que mudou (sem tocar em nada)
srcs=(); dsts=()
for pair in "${MAP[@]}"; do
  src="${pair%%::*}"; dst="${pair##*::}"
  [[ -f "$src" ]] || { echo "AVISO origem sumiu, pulando: $src"; continue; }
  [[ -f "$dst" ]] || { echo "AVISO destino nao existe no repo, pulando: $dst"; continue; }
  if ! cmp -s "$src" "$dst"; then srcs+=("$src"); dsts+=("$dst"); fi
done

if [[ ${#dsts[@]} -eq 0 ]]; then
  echo "Nada mudou. Repo ja esta em dia com o sistema vivo."
  exit 0
fi

# 2. previa: diff sem modificar o working tree
echo "Vai atualizar ${#dsts[@]} arquivo(s):"
for i in "${!dsts[@]}"; do
  echo "  ${dsts[$i]}"
  git --no-pager diff --no-index --stat -- "${dsts[$i]}" "${srcs[$i]}" 2>/dev/null | sed '$d' || true
done

if [[ $dry -eq 1 ]]; then
  echo
  echo "(dry run) nada foi tocado. Rode sem -n para publicar."
  exit 0
fi

# 3. aplica, commita e faz push
for i in "${!dsts[@]}"; do cp "${srcs[$i]}" "${dsts[$i]}"; done
git add -- "${dsts[@]}"
git commit -m "$msg"
git push origin main
echo "Publicado: $(git rev-parse --short HEAD) -> origin/main"
