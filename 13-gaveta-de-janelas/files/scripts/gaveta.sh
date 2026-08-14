#!/usr/bin/env bash
# Camada de sistema da gaveta de janelas (v2). UI fica no GavetaPanel.qml.
#
# DIFERENCA CRITICA PRA V1: esta versao NAO hiberna processo. A v1 mandava
# SIGSTOP nos descendentes da janela e isso quebrou uma sessao viva do Claude
# Code dentro do kitty (conexao de rede em voo nao sobrevive a SIGSTOP).
# Guardar aqui e so mover de workspace, igual o window-minimize ja faz.
#
# A VERDADE DA LISTA VEM DO HYPRLAND, nunca do arquivo de estado: janela que
# morreu nao aparece em `hyprctl clients`, entao nao vira slot fantasma. O
# arquivo guarda so o workspace de origem, e e podado a cada leitura. Isso
# importa porque a janela guardada some da taskbar, e a gaveta vira o unico
# caminho de volta ate ela.
#
# Ver plano: /home/lucas/AWA/wiki/references/rework-desktop-gaveta-de-janelas-v2-2026-08-14.md
set -uo pipefail

PREFIX="special:gav"
STORE="/tmp/gaveta-windows"          # linhas "<addr> <ws_origem>"
BARRA=28                             # altura da barra do hyprbars

_clients() { hyprctl clients -j 2>/dev/null; }

# enderecos atualmente guardados, lidos do Hyprland
_guardadas() {
  _clients | jq -r --arg p "$PREFIX" '.[]|select(.workspace.name|startswith($p))|.address'
}

# remove do store quem nao esta mais guardado (janela fechada, restaurada por fora)
_podar() {
  [ -s "$STORE" ] || return 0
  local vivas tmp
  # se o hyprctl/jq falhar, `vivas` vem vazio e a poda apagaria o store INTEIRO,
  # perdendo o workspace de origem de todas as guardadas. Na duvida, nao poda.
  if ! vivas="$(_clients | jq -e -r --arg p "$PREFIX" \
      '[.[]|select(.workspace.name|startswith($p))|.address]|.[]?' )"; then
    case "$(_clients | jq -r 'length' 2>/dev/null)" in
      ""|null) return 0 ;;   # hyprctl mudo: preserva o store
    esac
  fi
  tmp="$(mktemp)"
  while read -r a w; do
    [ -n "$a" ] || continue
    printf '%s\n' "$vivas" | grep -qx "$a" && printf '%s %s\n' "$a" "$w"
  done < "$STORE" > "$tmp"
  mv "$tmp" "$STORE"
}

# tira uma linha do store. `grep -v` devolve 1 quando o resultado fica VAZIO,
# entao encadear com `&& mv` deixava a ultima entrada presa no arquivo e um
# .tmp orfao pra tras a cada remocao.
_esquecer() {
  local a="$1" tmp
  [ -f "$STORE" ] || return 0
  tmp="$(mktemp)"
  grep -v "^$a " "$STORE" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$STORE"
}

# ---- agarrar: decide se o cursor esta na barra de titulo de alguma janela ----
# ARMADILHA DE GEOMETRIA: o `at` que o Hyprland reporta aponta pro CONTEUDO, e o
# hyprbars desenha a barra 28px ACIMA disso. A faixa valida e [at.y-28, at.y),
# nunca [at.y, at.y+28), senao o gesto dispara dentro da janela.
cmd_agarrar() {
  local cp cx cy
  cp="$(hyprctl cursorpos 2>/dev/null)" || exit 0
  cx="${cp%%,*}"; cy="${cp##*,}"; cx="${cx// /}"; cy="${cy// /}"
  case "${cx}:${cy}" in *[!0-9-]*:*|*:*[!0-9-]*|:*|*:) exit 0 ;; esac

  _clients | BARRA="$BARRA" CX="$cx" CY="$cy" jq -r '
    ($ENV.CX|tonumber) as $cx | ($ENV.CY|tonumber) as $cy |
    ($ENV.BARRA|tonumber) as $b |
    .[] |
    select(.mapped and (.workspace.name|startswith("special")|not)) |
    select(.fullscreen != 2) |
    select($cx >= .at[0] and $cx < (.at[0] + .size[0])) |
    select($cy >= (.at[1] - $b) and $cy < .at[1]) |
    .address' | head -1
}

cmd_guardar() {
  local addr="$1" ws
  [ -n "$addr" ] || exit 0
  ws="$(_clients | jq -r --arg a "$addr" '.[]|select(.address==$a)|.workspace.id')"
  case "$ws" in ""|null) ws="$(hyprctl activeworkspace -j | jq -r '.id')" ;; esac
  _podar
  _esquecer "$addr"
  printf '%s %s\n' "$addr" "$ws" >> "$STORE"
  # special proprio por janela: um special compartilhado despeja TODAS as
  # guardadas no monitor ao focar qualquer uma (licao do window-minimize)
  hyprctl dispatch movetoworkspacesilent "${PREFIX}-${addr#0x},address:$addr" >/dev/null 2>&1
}

cmd_tirar() {
  local addr="$1" ws
  [ -n "$addr" ] || exit 0
  _podar
  ws="$(awk -v a="$addr" '$1==a{print $2}' "$STORE" 2>/dev/null | tail -1)"
  case "$ws" in ""|-*|0|null) ws="$(hyprctl activeworkspace -j | jq -r '.id')" ;; esac
  hyprctl dispatch movetoworkspacesilent "${ws},address:$addr" >/dev/null 2>&1
  hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1
  _esquecer "$addr"
}

cmd_tirar_tudo() {
  local a
  for a in $(_guardadas); do cmd_tirar "$a"; done
}

# ---- botao da barra de titulo (hyprbars) ----
# ESTE E O GATILHO DE VERDADE desde 2026-08-14. O gesto SUPER+CTRL+clique morreu
# porque NENHUM bind de mouse dispara neste Hyprland, nem o `bindm SUPER,
# mouse:272, movewindow` que vem de fabrica no Omarchy. Medido: bind de TECLADO
# com `exec` dispara, bind de MOUSE nao dispara nunca. Ou e o hyprbars hookando o
# ponteiro, ou regressao do Hyprland 0.56.
#
# O hyprbars foca a janela ao clicar na barra dela, entao `activewindow` E a
# janela do botao clicado. Mesmo contrato que o botao de minimizar ja usa.
cmd_botao() {
  local addr
  addr="$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')"
  [ -n "$addr" ] && [ "$addr" != "null" ] || exit 0
  quickshell ipc call gaveta agarrar "$addr" >/dev/null 2>&1
}

# gatilho antigo, por bind de mouse. Mantido porque funciona na hora que o bind
# de mouse voltar a disparar, e porque `agarrar` continua util por terminal.
cmd_gesto() {
  local addr
  addr="$(cmd_agarrar)"
  [ -n "$addr" ] || exit 0
  quickshell ipc call gaveta agarrar "$addr" >/dev/null 2>&1
}

# rede de seguranca: funciona por terminal, sem UI nenhuma
cmd_listar() { _podar; _guardadas; }

case "${1:-}" in
  botao)      cmd_botao ;;
  gesto)      cmd_gesto ;;
  agarrar)    cmd_agarrar ;;
  guardar)    cmd_guardar "${2:-}" ;;
  tirar)      cmd_tirar "${2:-}" ;;
  tirar-tudo) cmd_tirar_tudo ;;
  listar)     cmd_listar ;;
  *) echo "uso: gaveta.sh {botao|gesto|agarrar|guardar <addr>|tirar <addr>|tirar-tudo|listar}" >&2; exit 2 ;;
esac
