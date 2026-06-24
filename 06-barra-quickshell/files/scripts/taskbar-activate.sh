#!/usr/bin/env bash
# Clique na taskbar (icone ou item da lista de hover): foca-OU-restaura janela(s).
# Uso: taskbar-activate.sh <appId> [titulo]
#   - sem titulo: opera no app inteiro (restaura 1 minimizada do app, senao foca/cicla).
#   - com titulo: opera SO na janela daquele app+titulo (restaura se minimizada, senao foca).
# Restaurar = tirar do special:minimized pro workspace de origem (store) e focar. Nunca usa
# activate() cru (que traz o overlay especial e "trava" a tela).
set -uo pipefail
STORE="/tmp/minimized-windows"
SPECIAL="special:minimized"
app="${1:-}"
want_title="${2:-}"
do_max=0; [ "${3:-}" = "max" ] && do_max=1   # 3o arg "max" = maximizar apos focar (alt+tab)
[ -n "$app" ] || exit 0
clients="$(hyprctl clients -j 2>/dev/null)"

# poda o store: mantem so as janelas atualmente em special:minimized (sem fantasmas)
if [ -s "$STORE" ]; then
  mins_all="$(printf '%s' "$clients" | jq -r --arg w "$SPECIAL" '.[]|select(.workspace.name==$w)|.address')"
  ptmp="$(mktemp)"
  while read -r a w m; do
    [ -n "$a" ] || continue
    if printf '%s\n' "$mins_all" | grep -qx "$a"; then printf '%s %s %s\n' "$a" "$w" "$m"; fi
  done < "$STORE" > "$ptmp"
  mv "$ptmp" "$STORE"
fi

# seletor jq: app (class/initialClass) e, se dado, titulo exato
sel='(.class==$a or .initialClass==$a)'
[ -n "$want_title" ] && sel="$sel and .title==\$t"

mapfile -t app_addrs < <(printf '%s' "$clients" | jq -r --arg a "$app" --arg t "$want_title" ".[]|select($sel)|.address")
[ "${#app_addrs[@]}" -gt 0 ] || exit 0

mapfile -t minz < <(printf '%s' "$clients" | jq -r --arg a "$app" --arg t "$want_title" \
  ".[]|select(($sel) and .workspace.name==\"$SPECIAL\")|.address")

restore_addr() {
  local target="$1" ws
  ws="$(grep "^$target " "$STORE" 2>/dev/null | tail -1 | awk '{print $2}')"
  case "$ws" in ""|-*|0) ws="$(hyprctl activeworkspace -j | jq -r '.id')" ;; esac
  grep -v "^$target " "$STORE" > "$STORE.tmp" 2>/dev/null; mv "$STORE.tmp" "$STORE" 2>/dev/null || true
  hyprctl dispatch movetoworkspacesilent "${ws},address:$target" >/dev/null 2>&1
  hyprctl dispatch focuswindow "address:$target" >/dev/null 2>&1
}

# maximiza a janela alvo (estilo Windows: 1 janela cheia, respeita a barra reservada).
# idempotente: so aplica se ainda nao estiver maximizada (fullscreen != 1). fullscreen 1 = maximize.
maximize_addr() {
  [ "$do_max" = "1" ] || return 0
  local addr="$1" st
  st="$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" '.[]|select(.address==$a)|.fullscreen')"
  [ "$st" = "1" ] && return 0
  hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1
  hyprctl dispatch fullscreen 1 >/dev/null 2>&1
}

if [ "${#minz[@]}" -gt 0 ]; then
  # restaura: prefere a mais recente no store (LIFO); senao a primeira minimizada
  target="${minz[0]}"
  if [ -s "$STORE" ]; then
    mapfile -t lines < "$STORE"
    for ((i=${#lines[@]}-1; i>=0; i--)); do
      a="$(awk '{print $1}' <<<"${lines[i]}")"
      for m in "${minz[@]}"; do [ "$m" = "$a" ] && { target="$a"; break 2; }; done
    done
  fi
  restore_addr "$target"
  maximize_addr "$target"
  exit 0
fi

# nenhuma minimizada: foca a janela (ou cicla se for o app inteiro)
active="$(printf '%s' "$clients" | jq -r '.[]|select(.focusHistoryID==0)|.address')"
target="${app_addrs[0]}"
n=${#app_addrs[@]}
for ((i=0; i<n; i++)); do
  if [ "${app_addrs[i]}" = "$active" ]; then target="${app_addrs[$(((i+1)%n))]}"; break; fi
done
hyprctl dispatch focuswindow "address:$target" >/dev/null 2>&1
maximize_addr "$target"
