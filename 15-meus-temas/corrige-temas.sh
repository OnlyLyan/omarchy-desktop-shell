#!/usr/bin/env bash
# corrige-temas.sh | conserta temas do Omarchy que quebram em Hyprland recente.
#
# Dois defeitos reais, achados em 12 dos 113 temas instalados. Nenhum e questao
# de gosto: sao temas que ERRAM AO CARREGAR.
#
#   1. Sintaxe morta do Hyprland. `windowrulev2 = bordercolor $cor,fullscreen:1`
#      foi removido; a forma viva e `windowrule = border_color $cor, match:fullscreen 1`.
#      Tema com a linha velha cospe erro toda vez que o tema e aplicado.
#
#   2. Chaves de cor faltando no colors.toml. O template `kitty.conf.tpl` do
#      Omarchy espera `color0` ate `color15`, `cursor`, `selection_background` e
#      `selection_foreground`. Faltando qualquer uma, o template gera `{{ }}` sem
#      substituir e o kitty FALHA AO CARREGAR. Os valores sao alias das cores que
#      o tema ja define, so renomeados.
#
# Idempotente: rodar de novo em tema ja corrigido nao faz nada. Vale pra tema que
# voce instalar no futuro, e nao so pros que ja estao aqui.
#
# Uso:
#   ./corrige-temas.sh            corrige todos em ~/.config/omarchy/themes
#   ./corrige-temas.sh -n         dry run: so lista o que mudaria
#   ./corrige-temas.sh <pasta>    corrige um tema so
set -uo pipefail

DIR_TEMAS="${OMARCHY_THEMES_DIR:-$HOME/.config/omarchy/themes}"
dry=0
alvo=""
case "${1:-}" in
  -n|--dry) dry=1 ;;
  "") ;;
  *) alvo="$1" ;;
esac

mudou_total=0

# ---- 1. sintaxe morta do windowrulev2 ----
corrige_sintaxe() {
  local f="$1"
  [ -f "$f" ] || return 1
  # ANCORA NO INICIO DA LINHA: sem isso, linha COMENTADA (`#windowrulev2 = ...`)
  # contava como defeito, o sed nao mexia nela, e o script reportava conserto pra
  # sempre. Deixa de ser idempotente e mente no relatorio.
  grep -qE '^[[:space:]]*windowrulev2[[:space:]]*=[[:space:]]*bordercolor[^,]+,[[:space:]]*fullscreen:1' "$f" 2>/dev/null || return 1
  [ "$dry" -eq 1 ] && return 0
  # `bordercolor $cor,fullscreen:1` -> `border_color $cor, match:fullscreen 1`.
  # So esta forma. Outras variantes de `bordercolor` (duas cores, class:...) ficam
  # intocadas de proposito: converter no escuro faria estrago maior que o defeito.
  sed -i -E 's/^([[:space:]]*)windowrulev2([[:space:]]*)=([[:space:]]*)bordercolor([[:space:]]+)([^,]+),[[:space:]]*fullscreen:1/\1windowrule\2=\3border_color\4\5, match:fullscreen 1/' "$f"
  return 0
}

# ---- 2. chaves que o template kitty.conf.tpl exige ----
# le uma chave do colors.toml (formato `nome = "#rrggbb"`), sem toml parser
_cor() {
  sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"?([^\"[:space:]]+)\"?.*/\1/p" "$1" | head -1
}

corrige_cores() {
  local f="$1"
  [ -f "$f" ] || return 1
  # ja tem? nada a fazer
  grep -qE '^[[:space:]]*color0[[:space:]]*=' "$f" 2>/dev/null && return 1

  local bg fg preto verm verde amar azul mage ciano branco
  bg="$(_cor "$f" background)"; fg="$(_cor "$f" foreground)"
  preto="$(_cor "$f" black)";   verm="$(_cor "$f" red)"
  verde="$(_cor "$f" green)";   amar="$(_cor "$f" yellow)"
  azul="$(_cor "$f" blue)";     mage="$(_cor "$f" magenta)"
  ciano="$(_cor "$f" cyan)";    branco="$(_cor "$f" white)"
  # sem o conjunto basico nao da pra derivar nada com honestidade
  for v in "$preto" "$verm" "$verde" "$amar" "$azul" "$mage" "$ciano" "$branco"; do
    [ -n "$v" ] || return 1
  done
  [ -n "$bg" ] || bg="$preto"
  [ -n "$fg" ] || fg="$branco"

  [ "$dry" -eq 1 ] && return 0
  cat >> "$f" <<EOF

# Chaves color0-15/cursor/selection_* no esquema padrao do Omarchy, alias das
# cores acima. Sem isso o template kitty.conf.tpl gera placeholders {{ }} nao
# substituidos e o kitty falha ao carregar. Mesmos valores, so renomeados.
color0 = "$preto"
color1 = "$verm"
color2 = "$verde"
color3 = "$amar"
color4 = "$azul"
color5 = "$mage"
color6 = "$ciano"
color7 = "$branco"
color8 = "$preto"
color9 = "$verm"
color10 = "$verde"
color11 = "$amar"
color12 = "$azul"
color13 = "$mage"
color14 = "$ciano"
color15 = "$branco"
cursor = "$fg"
selection_background = "$bg"
selection_foreground = "$fg"
EOF
  return 0
}

processa() {
  local d="$1" nome mudou=0
  nome="$(basename "$d")"
  corrige_sintaxe "$d/hyprland.conf" && { echo "  $nome: sintaxe windowrulev2 -> windowrule"; mudou=1; }
  corrige_cores   "$d/colors.toml"   && { echo "  $nome: chaves color0-15/cursor/selection_*"; mudou=1; }
  [ "$mudou" -eq 1 ] && mudou_total=$((mudou_total+1))
  return 0
}

if [ -n "$alvo" ]; then
  [ -d "$alvo" ] || { echo "nao e pasta: $alvo" >&2; exit 1; }
  processa "$alvo"
else
  [ -d "$DIR_TEMAS" ] || { echo "sem temas em $DIR_TEMAS" >&2; exit 1; }
  for d in "$DIR_TEMAS"/*/; do [ -d "$d" ] && processa "${d%/}"; done
fi

if [ "$mudou_total" -eq 0 ]; then
  echo "Nada a corrigir."
elif [ "$dry" -eq 1 ]; then
  echo "(dry run) $mudou_total tema(s) seriam corrigidos. Rode sem -n para aplicar."
else
  echo "$mudou_total tema(s) corrigidos. Reaplique o tema atual: omarchy-theme-set <nome>"
fi
