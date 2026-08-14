#!/usr/bin/env bash
# Clique na taskbar (icone ou item da lista de hover) OU Alt+Tab: foca-OU-restaura janela(s).
# Uso: taskbar-activate.sh <appId> [titulo]
#   - sem titulo: opera no app inteiro (restaura 1 minimizada do app, senao foca/cicla).
#   - com titulo: opera SO na janela daquele app+titulo (restaura se minimizada, senao foca).
# Restaurar = tirar do special:min-<addr> pro workspace de origem (store), focar, e
# reaplicar o fullscreen/maximizado que a janela tinha ANTES de minimizar. Nunca forca
# um estado que a janela nao tinha (igual ao KWin: Alt+Tab so troca o foco). Nunca usa
# activate() cru (que traz o overlay especial e "trava" a tela).
set -uo pipefail
STORE="/tmp/minimized-windows"
# Minimizadas vivem cada uma no seu special "special:min-<addr>" (pra focar uma nao
# revelar todas). Prefixo cobre o esquema novo e o antigo "special:minimized".
SPECIAL_PREFIX="special:min"
app="${1:-}"
want_title="${2:-}"
[ -n "$app" ] || exit 0
clients="$(hyprctl clients -j 2>/dev/null)"

# janela ativa ANTES de trocar o foco. Se ela estiver em fullscreen de
# verdade (2 = Fullscreen; 1 e so Maximized, comum e nao precisa disso),
# o Hyprland nao libera a tela sozinho ao focar outra janela: o estado
# INTERNO de fullscreen fica preso na janela antiga e ela continua
# cobrindo a saida, mesmo com o foco ja tendo mudado. fullscreenstate
# limpa so o estado interno (0) sem mexer no que o cliente/jogo enxerga
# (-1 = mantem), entao o jogo nao recebe evento de sair do fullscreen e
# fica pronto pra cobrir a tela de novo quando voltar o foco pra ele.
active="$(printf '%s' "$clients" | jq -r '.[]|select(.focusHistoryID==0)|.address')"
active_fs="$(printf '%s' "$clients" | jq -r --arg a "$active" '.[]|select(.address==$a)|.fullscreen')"
focus_addr() {
  if [ "$active_fs" = "2" ] && [ -n "$active" ] && [ "$active" != "$1" ]; then
    hyprctl dispatch fullscreenstate 0 -1 >/dev/null 2>&1
  fi
  hyprctl dispatch focuswindow "address:$1" >/dev/null 2>&1
}

# poda o store: mantem so as janelas atualmente minimizadas (em algum special:min*)
# Formato de cada linha: "<addr> <ws_origem> <monitor> <fullscreen_origem>"
if [ -s "$STORE" ]; then
  mins_all="$(printf '%s' "$clients" | jq -r --arg p "$SPECIAL_PREFIX" '.[]|select(.workspace.name|startswith($p))|.address')"
  ptmp="$(mktemp)"
  while read -r a w m f; do
    [ -n "$a" ] || continue
    if printf '%s\n' "$mins_all" | grep -qx "$a"; then printf '%s %s %s %s\n' "$a" "$w" "$m" "${f:-0}"; fi
  done < "$STORE" > "$ptmp"
  mv "$ptmp" "$STORE"
fi

# Reaplica o estado de fullscreen (0 normal, 1 maximizado, 2 fullscreen real) que a
# janela tinha ANTES de minimizar. So mexe se diverge do atual, pra nao desfazer com
# o dispatcher, que e um toggle.
apply_fullscreen() {
  local addr="$1" want="${2:-0}" cur
  [ "$want" = "0" ] && return 0
  cur="$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" '.[]|select(.address==$a)|.fullscreen // 0')"
  [ "$cur" = "$want" ] && return 0
  case "$want" in
    1) hyprctl dispatch fullscreen 1 >/dev/null 2>&1 ;;   # maximizado
    2) hyprctl dispatch fullscreen 0 >/dev/null 2>&1 ;;   # fullscreen real
  esac
}

# seletor jq: app (class/initialClass) e, se dado, titulo exato.
# EXCLUI a gaveta: janela guardada nao pode ser alvo de clique na taskbar nem de
# pilula de notificacao. Focar janela de workspace especial revela o overlay do
# special e trava a tela com o desktop apagado atras, a mesma armadilha que o
# cabecalho deste arquivo ja documenta pro minimizar. A gaveta e o unico caminho
# de volta ate a janela guardada, de proposito.
GAVETA_PREFIX="special:gav"
sel='(.class==$a or .initialClass==$a) and ((.workspace.name|startswith($g))|not)'
[ -n "$want_title" ] && sel="$sel and .title==\$t"

mapfile -t app_addrs < <(printf '%s' "$clients" | jq -r --arg a "$app" --arg t "$want_title" --arg g "$GAVETA_PREFIX" ".[]|select($sel)|.address")
[ "${#app_addrs[@]}" -gt 0 ] || exit 0

mapfile -t minz < <(printf '%s' "$clients" | jq -r --arg a "$app" --arg t "$want_title" --arg p "$SPECIAL_PREFIX" --arg g "$GAVETA_PREFIX" \
  ".[]|select(($sel) and (.workspace.name|startswith(\$p)))|.address")

restore_addr() {
  local target="$1" ws fs
  ws="$(grep "^$target " "$STORE" 2>/dev/null | tail -1 | awk '{print $2}')"
  fs="$(grep "^$target " "$STORE" 2>/dev/null | tail -1 | awk '{print $4}')"
  case "$ws" in ""|-*|0) ws="$(hyprctl activeworkspace -j | jq -r '.id')" ;; esac
  grep -v "^$target " "$STORE" > "$STORE.tmp" 2>/dev/null; mv "$STORE.tmp" "$STORE" 2>/dev/null || true
  hyprctl dispatch movetoworkspacesilent "${ws},address:$target" >/dev/null 2>&1
  focus_addr "$target"
  apply_fullscreen "$target" "${fs:-0}"
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
  exit 0
fi

# nenhuma minimizada: foca a janela (ou cicla se for o app inteiro)
target="${app_addrs[0]}"
n=${#app_addrs[@]}
for ((i=0; i<n; i++)); do
  if [ "${app_addrs[i]}" = "$active" ]; then target="${app_addrs[$(((i+1)%n))]}"; break; fi
done
focus_addr "$target"
