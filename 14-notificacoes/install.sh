#!/usr/bin/env bash
# As notificacoes nao rodam sozinhas: o NotificationPanel.qml e instanciado pelo
# shell.qml da pasta 06. Rode este install ANTES de subir o qsbar, senao o
# shell.qml falha ao carregar por tipo desconhecido.
#
# Este install MASCARA o mako. Ele e ativado por D-Bus, entao matar o processo nao
# adianta: ele volta na primeira notificacao. Dois servidores registrados ao mesmo
# tempo = notificacao dobrada ou nenhuma.
set -euo pipefail
cd "$(dirname "$0")/files"

install -Dm644 NotificationPanel.qml ~/.config/quickshell/NotificationPanel.qml
install -Dm755 notif-toggle-dnd      ~/.local/bin/notif-toggle-dnd
install -Dm755 10-stop-mako          ~/.config/omarchy/hooks/post-boot.d/10-stop-mako

echo "notificacoes -> ~/.config/quickshell/NotificationPanel.qml"
echo "               ~/.local/bin/notif-toggle-dnd"
echo "               ~/.config/omarchy/hooks/post-boot.d/10-stop-mako"

# mako fora do caminho
if systemctl --user list-unit-files mako.service >/dev/null 2>&1; then
  systemctl --user mask mako.service >/dev/null 2>&1 || true
  pkill -x mako >/dev/null 2>&1 || true
  echo "mako mascarado e encerrado"
else
  echo "mako nao instalado, nada a mascarar"
fi

# quem mais responde por notificacao?
outros="$(busctl --user list 2>/dev/null | grep -i "org.freedesktop.Notifications" || true)"
if [ -n "$outros" ]; then
  echo
  echo "AVISO: ja existe alguem registrado em org.freedesktop.Notifications:"
  printf '%s\n' "$outros" | sed 's/^/  /'
  echo "       Se nao for o quickshell, as notificacoes vao dobrar ou sumir."
fi

echo
echo "Falta o bind do modo (opcional), no seu ~/.config/hypr/bindings.conf:"
echo "  unbind = SUPER CTRL, COMMA"
echo "  bindd = SUPER CTRL, COMMA, Modo de notificacao, exec, ~/.local/bin/notif-toggle-dnd"
