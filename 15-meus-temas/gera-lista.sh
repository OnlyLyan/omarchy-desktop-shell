#!/usr/bin/env bash
# Regera o temas.tsv a partir dos temas instalados. Nao e copia 1:1 de um arquivo
# vivo, por isso fica fora do publish.sh: rode este script quando instalar ou
# remover tema, e commite o resultado.
set -euo pipefail
cd "$(dirname "$0")"
TEMAS="${OMARCHY_THEMES_DIR:-$HOME/.config/omarchy/themes}"
: > temas.tsv
for d in "$TEMAS"/*/; do
  t="$(basename "$d")"
  if [ -d "$d/.git" ]; then
    u="$(git -C "$d" remote get-url origin 2>/dev/null || true)"
    printf '%s\t%s\n' "$t" "${u:--}" >> temas.tsv
  else
    printf '%s\t(local)\n' "$t" >> temas.tsv
  fi
done
sort -o temas.tsv temas.tsv
echo "temas.tsv: $(wc -l < temas.tsv) temas, $(grep -c '(local)' temas.tsv || true) local(is)"
