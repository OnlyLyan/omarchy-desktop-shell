#!/usr/bin/env bash
# Testes do monitors.sh. Usa stub de hyprctl e diretorios temporarios.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3"; echo "  esperado: $2"; echo "  obtido:   $1"; fi; }

# stub de hyprctl: registra args em $HYPRLOG e responde a 'monitors -j'
cat > "$TMP/hyprctl" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$HYPRLOG"
if [ "$1" = "monitors" ]; then   # responde a 'monitors -j' e 'monitors all -j'
  echo '[{"name":"eDP-1","width":1920,"height":1080}]'
fi
STUB
chmod +x "$TMP/hyprctl"
# stub de quickshell: evita recarregar a barra real do usuario ao testar o watchdog
cat > "$TMP/quickshell" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$HYPRLOG"
STUB
chmod +x "$TMP/quickshell"
export HYPRCTL="$TMP/hyprctl" HYPRLOG="$TMP/hyprctl.log" QUICKSHELL="$TMP/quickshell"
export MON_CONF="$TMP/monitors.conf" PROFILE_DIR="$TMP/profiles"

# get
out="$(bash "$HERE/monitors.sh" get)"
ok "$out" '[{"name":"eDP-1","width":1920,"height":1080}]' "get repassa JSON do hyprctl"

# apply: cada linha vira um 'keyword monitor Li'
: > "$HYPRLOG"
bash "$HERE/monitors.sh" apply "eDP-1,1920x1080@144,0x0,1" "HDMI-A-1,disable" >/dev/null
ok "$(grep -c 'keyword monitor' "$HYPRLOG")" "2" "apply emite um keyword monitor por linha"
ok "$(grep -q 'keyword monitor eDP-1,1920x1080@144,0x0,1' "$HYPRLOG" && echo y)" "y" "apply passa a linha 1 intacta"

# revert: chama reload
: > "$HYPRLOG"
bash "$HERE/monitors.sh" revert >/dev/null
ok "$(grep -q '^reload' "$HYPRLOG" && echo y)" "y" "revert chama hyprctl reload"

# persist: preserva conteudo do usuario e escreve o bloco uma vez
printf '%s\n' '# meu comentario' 'env = GDK_SCALE,2' > "$MON_CONF"
bash "$HERE/monitors.sh" persist "eDP-1,1920x1080@144,0x0,1"
ok "$(grep -c 'env = GDK_SCALE,2' "$MON_CONF")" "1" "persist preserva linha do usuario"
ok "$(grep -c '# >>> quickshell-monitors' "$MON_CONF")" "1" "persist escreve marcador de inicio"
ok "$(grep -c 'monitor=eDP-1,1920x1080@144,0x0,1' "$MON_CONF")" "1" "persist escreve a linha de monitor"

# persist de novo: substitui, nao duplica
bash "$HERE/monitors.sh" persist "eDP-1,1280x720@60,0x0,1"
ok "$(grep -c '# >>> quickshell-monitors' "$MON_CONF")" "1" "segundo persist nao duplica o bloco"
ok "$(grep -c 'monitor=eDP-1,1280x720@60,0x0,1' "$MON_CONF")" "1" "segundo persist usa a linha nova"
ok "$(grep -c 'monitor=eDP-1,1920x1080@144,0x0,1' "$MON_CONF")" "0" "segundo persist remove a linha antiga"
ok "$([ -f "$MON_CONF.bak" ] && echo y)" "y" "persist deixa um .bak"

# perfis: save -> list -> apply -> delete
: > "$HYPRLOG"; printf '%s\n' '# base' > "$MON_CONF"
bash "$HERE/monitors.sh" profile-save casa "eDP-1,1920x1080@144,0x0,1" "HDMI-A-1,1366x768@60,1920x0,1"
ok "$(bash "$HERE/monitors.sh" profiles-list)" "casa" "profiles-list mostra o perfil salvo"
bash "$HERE/monitors.sh" profile-apply casa >/dev/null
ok "$(grep -c 'keyword monitor' "$HYPRLOG")" "2" "profile-apply aplica as 2 linhas ao vivo"
ok "$(grep -c 'monitor=HDMI-A-1,1366x768@60,1920x0,1' "$MON_CONF")" "1" "profile-apply persiste o perfil"
bash "$HERE/monitors.sh" profile-delete casa
ok "$(bash "$HERE/monitors.sh" profiles-list)" "" "profile-delete remove o perfil"

# preview: aplica ao vivo, arma o watchdog e deixa um pending pra confirmar
export MON_STATE="$TMP/state"
: > "$HYPRLOG"; printf '%s\n' '# base preview' > "$MON_CONF"
PREVIEW_TIMEOUT=30 bash "$HERE/monitors.sh" preview "eDP-1,1920x1080@144,0x0,1" >/dev/null
ok "$(grep -c 'keyword monitor eDP-1,1920x1080@144,0x0,1' "$HYPRLOG")" "1" "preview aplica a linha ao vivo"
ok "$([ -f "$MON_STATE/watchdog.pid" ] && echo y)" "y" "preview arma o watchdog"
ok "$([ "$(bash "$HERE/monitors.sh" pending)" -gt 0 ] && echo y)" "y" "pending > 0 durante o preview nao confirmado"

# confirm: persiste as linhas, desarma o watchdog e limpa o pending
bash "$HERE/monitors.sh" confirm
ok "$([ -f "$MON_STATE/watchdog.pid" ] && echo y || echo n)" "n" "confirm desarma o watchdog"
ok "$(grep -c 'monitor=eDP-1,1920x1080@144,0x0,1' "$MON_CONF")" "1" "confirm persiste a linha do preview"
ok "$(bash "$HERE/monitors.sh" pending)" "0" "pending zera apos confirmar"

# cancel: limpa o pending e reverte
: > "$HYPRLOG"
PREVIEW_TIMEOUT=30 bash "$HERE/monitors.sh" preview "eDP-1,800x600@60,0x0,1" >/dev/null
bash "$HERE/monitors.sh" cancel
ok "$(bash "$HERE/monitors.sh" pending)" "0" "pending zera apos cancelar"
ok "$(grep -q '^reload' "$HYPRLOG" && echo y)" "y" "cancel reverte (reload)"

# auto-revert temporizado: sem confirmar, o watchdog reverte sozinho
: > "$HYPRLOG"
PREVIEW_TIMEOUT=1 bash "$HERE/monitors.sh" preview "eDP-1,800x600@144,0x0,1" >/dev/null
sleep 2
ok "$(grep -q '^reload' "$HYPRLOG" && echo y)" "y" "watchdog reverte (reload) apos timeout sem confirmar"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
