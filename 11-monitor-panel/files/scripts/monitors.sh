#!/usr/bin/env bash
# Camada de sistema do painel de monitores da shell Quickshell.
# Toda acao que toca o sistema (ler hyprctl, aplicar, persistir, perfis) mora aqui.
set -u
HYPRCTL="${HYPRCTL:-hyprctl}"
QUICKSHELL="${QUICKSHELL:-quickshell}"
MON_CONF="${MON_CONF:-$HOME/.config/hypr/monitors.conf}"
PROFILE_DIR="${PROFILE_DIR:-$HOME/.config/quickshell/monitor-profiles}"
STATE="${MON_STATE:-${XDG_RUNTIME_DIR:-/tmp}/quickshell-monitors}"
PREVIEW_TIMEOUT="${PREVIEW_TIMEOUT:-10}"
BEGIN="# >>> quickshell-monitors"
END="# <<< quickshell-monitors"

# 'all' inclui monitores DESLIGADOS (mas ainda conectados) com res/scale/modos validos,
# pra eles continuarem na lista do painel com o toggle de religar. O 'monitors -j' puro
# omite os desligados, e ai o monitor sumia e nao dava pra religar.
cmd_get() { "$HYPRCTL" monitors all -j; }
# Preservacao do cursor atraves de reconfiguracoes de output.
# Problema: ao mover um secundario pra esquerda/acima, normalizamos o layout pra min 0,0,
# o que DESLOCA o principal. O cursor mantem a coord ABSOLUTA, entao o principal sai de
# baixo dele e essa coord passa a cair no monitor movido: o cursor "teleporta" pra la.
# Solucao: guardar o monitor sob o cursor + o offset RELATIVO antes, e recolocar o cursor
# no mesmo ponto relativo desse monitor depois (ele segue o monitor pra nova posicao).
_cursor_snapshot() {
  local cp cx cy; cp="$("$HYPRCTL" cursorpos 2>/dev/null)"
  cx="${cp%%,*}"; cy="${cp##*,}"; cx="${cx// /}"; cy="${cy// /}"
  case "${cx}:${cy}" in *[!0-9-]*:*|*:*[!0-9-]*|:*|*:) return 0;; esac
  "$HYPRCTL" monitors -j 2>/dev/null | CX="$cx" CY="$cy" python3 -c '
import sys, json, os
try: mons = json.load(sys.stdin)
except Exception: sys.exit(0)
cx = int(os.environ["CX"]); cy = int(os.environ["CY"])
for m in mons:
    sc = m.get("scale", 1) or 1
    x = m.get("x", 0); y = m.get("y", 0)
    lw = round(m.get("width", 0) / sc); lh = round(m.get("height", 0) / sc)
    if x <= cx < x + lw and y <= cy < y + lh:
        print(m.get("name", ""), cx - x, cy - y); break
' 2>/dev/null
}
_cursor_restore() {
  local snap="$1"; [ -n "$snap" ] || return 0
  local name rx ry; read -r name rx ry <<< "$snap"
  [ -n "$name" ] || return 0
  local np nx ny; np="$("$HYPRCTL" monitors -j 2>/dev/null | NAME="$name" python3 -c '
import sys, json, os
try: mons = json.load(sys.stdin)
except Exception: sys.exit(0)
name = os.environ["NAME"]
for m in mons:
    if m.get("name") == name: print(m.get("x", 0), m.get("y", 0)); break
' 2>/dev/null)"
  [ -n "$np" ] || return 0
  read -r nx ny <<< "$np"
  "$HYPRCTL" dispatch movecursor "$((nx + rx))" "$((ny + ry))" >/dev/null 2>&1 || true
}
cmd_apply() {
  local snap; snap="$(_cursor_snapshot)"
  for line in "$@"; do "$HYPRCTL" keyword monitor "$line"; done
  _cursor_restore "$snap"
}
cmd_revert() {
  local snap; snap="$(_cursor_snapshot)"
  "$HYPRCTL" reload
  _cursor_restore "$snap"
}

# recarrega a cena do quickshell (best-effort). O quickshell 0.3.0 nao relayouta os
# surfaces (barra, wallpaper, overlay) quando o output muda de posicao ao vivo: sem
# recriar a cena a barra nao repinta e a overlay pode ficar presa cobrindo o monitor
# (tela preta). Chamado apos qualquer troca de output ao vivo.
_reload_shell() { command -v "$QUICKSHELL" >/dev/null 2>&1 && "$QUICKSHELL" ipc call shell reload >/dev/null 2>&1 || true; }
# reverte E recarrega a shell. Usado pelo watchdog, que roda FORA do quickshell.
cmd_revert_reload() { cmd_revert; _reload_shell; }

_kill_watchdog() { [ -f "$STATE/watchdog.pid" ] && kill "$(cat "$STATE/watchdog.pid")" 2>/dev/null; rm -f "$STATE/watchdog.pid"; }

# aplica ao vivo, guarda as linhas em pending (pra confirmar/persistir depois) E arma um
# watchdog INDEPENDENTE do quickshell: se nao houver confirmacao em PREVIEW_TIMEOUT s,
# reverte E recarrega a shell. Sobrevive a barra/overlay cair, que e onde a rede precisa
# existir. Quem aplicou (a shell) recarrega a cena logo apos, e o toast de confirmacao
# reaparece lendo este estado pending.
cmd_preview() {
  mkdir -p "$STATE"
  _kill_watchdog
  rm -f "$STATE/confirmed"
  printf '%s\n' "$@" > "$STATE/pending"
  echo $(( $(date +%s) + PREVIEW_TIMEOUT )) > "$STATE/deadline"
  cmd_apply "$@"
  setsid bash -c '
    sleep "$1"
    [ -f "$2/confirmed" ] || "$3" revert-reload
    rm -f "$2/watchdog.pid" "$2/confirmed" "$2/pending" "$2/deadline"
  ' _ "$PREVIEW_TIMEOUT" "$STATE" "$0" >/dev/null 2>&1 </dev/null &
  echo $! > "$STATE/watchdog.pid"
}
# segundos restantes de um preview pendente nao confirmado (0 se nao ha nada a confirmar).
# a shell le isto no startup pra decidir mostrar o toast de confirmacao.
cmd_pending() {
  { [ -f "$STATE/pending" ] && [ ! -f "$STATE/confirmed" ]; } || { echo 0; return; }
  local now dl rem
  now="$(date +%s)"; dl="$(cat "$STATE/deadline" 2>/dev/null || echo "$now")"
  rem=$(( dl - now )); [ "$rem" -lt 1 ] && rem=1
  echo "$rem"
}
# confirma: persiste as linhas aplicadas, desarma o watchdog e limpa o pending.
cmd_confirm() {
  mkdir -p "$STATE"; touch "$STATE/confirmed"; _kill_watchdog
  if [ -f "$STATE/pending" ]; then
    local lines=(); while IFS= read -r l; do [ -n "$l" ] && lines+=("$l"); done < "$STATE/pending"
    [ "${#lines[@]}" -gt 0 ] && cmd_persist "${lines[@]}"
  fi
  rm -f "$STATE/pending" "$STATE/deadline"
}
# cancela ja: desarma o watchdog, limpa o pending e reverte na hora (a shell recarrega depois)
cmd_cancel() { _kill_watchdog; rm -f "$STATE/confirmed" "$STATE/pending" "$STATE/deadline"; cmd_revert; }
cmd_persist() {
  local tmp; tmp="$(mktemp)"
  mkdir -p "$(dirname "$MON_CONF")"
  [ -f "$MON_CONF" ] && cp "$MON_CONF" "$MON_CONF.bak"
  # copia tudo do arquivo atual menos o bloco gerenciado antigo
  if [ -f "$MON_CONF" ]; then
    awk -v b="$BEGIN" -v e="$END" '
      $0==b {skip=1; next} $0==e {skip=0; next} skip!=1 {print}
    ' "$MON_CONF" > "$tmp"
  fi
  # garante uma linha em branco antes do bloco se o arquivo nao termina vazio
  [ -s "$tmp" ] && printf '\n' >> "$tmp"
  { echo "$BEGIN"; for line in "$@"; do echo "monitor=$line"; done; echo "$END"; } >> "$tmp"
  mv "$tmp" "$MON_CONF"
}
cmd_profiles_list() { [ -d "$PROFILE_DIR" ] || return 0; for f in "$PROFILE_DIR"/*.conf; do [ -e "$f" ] || continue; basename "$f" .conf; done | sort; }
cmd_profile_save() { local name="$1"; shift; mkdir -p "$PROFILE_DIR"; printf '%s\n' "$@" > "$PROFILE_DIR/$name.conf"; }
cmd_profile_apply() {
  local f="$PROFILE_DIR/$1.conf"; [ -f "$f" ] || { echo "perfil nao existe: $1" >&2; exit 1; }
  local lines=(); while IFS= read -r l; do [ -n "$l" ] && lines+=("$l"); done < "$f"
  cmd_apply "${lines[@]}"; cmd_persist "${lines[@]}"
}
cmd_profile_delete() { rm -f "$PROFILE_DIR/$1.conf"; }

case "${1:-}" in
  get) cmd_get ;;
  apply) shift; cmd_apply "$@" ;;
  revert) cmd_revert ;;
  revert-reload) cmd_revert_reload ;;
  preview) shift; cmd_preview "$@" ;;
  pending) cmd_pending ;;
  confirm) cmd_confirm ;;
  cancel) cmd_cancel ;;
  persist) shift; cmd_persist "$@" ;;
  profiles-list) cmd_profiles_list ;;
  profile-save) shift; name="$1"; shift; cmd_profile_save "$name" "$@" ;;
  profile-apply) cmd_profile_apply "$2" ;;
  profile-delete) cmd_profile_delete "$2" ;;
  *) echo "uso: monitors.sh {get|apply|revert|revert-reload|preview|pending|confirm|cancel|persist|profiles-list|profile-save|profile-apply|profile-delete}" >&2; exit 2 ;;
esac
