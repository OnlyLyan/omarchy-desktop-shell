#!/usr/bin/env bash
# Menu de contexto da taskbar (botao direito no icone): acao destrutiva por app.
# Uso: taskbar-app.sh kill <appId>
#   kill = SIGKILL no processo de cada janela do app E em todos os descendentes.
#          Electron/Chromium (Discord, Brave): a janela pertence ao processo
#          principal e os zygotes/renderers sao filhos dele; matando so o pai
#          sobra processo orfao segurando RAM e som.
# Encerrar normal e reiniciar ficam no QML (close() do toplevel + .desktop).
set -uo pipefail
action="${1:-}"
app="${2:-}"
[ -n "$action" ] && [ -n "$app" ] || exit 0
[ "$action" = "kill" ] || exit 0

mapfile -t roots < <(hyprctl clients -j 2>/dev/null \
  | jq -r --arg a "$app" '.[]|select(.class==$a or .initialClass==$a)|.pid' \
  | grep -E '^[0-9]+$' | sort -u)
[ "${#roots[@]}" -gt 0 ] || exit 0

# pid + descendentes, em largura pela tabela de processos
all=()
queue=("${roots[@]}")
while [ "${#queue[@]}" -gt 0 ]; do
  pid="${queue[0]}"
  queue=("${queue[@]:1}")
  case " ${all[*]-} " in *" $pid "*) continue ;; esac
  all+=("$pid")
  mapfile -t kids < <(ps -o pid= --ppid "$pid" 2>/dev/null | tr -d ' ')
  for k in "${kids[@]}"; do [ -n "$k" ] && queue+=("$k"); done
done

# trava de seguranca: nunca o init nem a propria barra
self="$(pgrep -x quickshell | head -1)"
for pid in "${all[@]}"; do
  [ "$pid" = "1" ] && continue
  [ -n "$self" ] && [ "$pid" = "$self" ] && continue
  kill -9 "$pid" 2>/dev/null
done
exit 0
