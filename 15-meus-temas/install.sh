#!/usr/bin/env bash
# Instala o que e MEU (tema stellarum, wordmark da tela de descanso) e, se pedido,
# reinstala a colecao inteira de temas a partir do temas.tsv.
#
# A colecao NAO esta neste repo de proposito: 112 dos 113 temas sao clone de
# repositorio de outra pessoa. O que esta aqui e a lista com a origem de cada um.
# Ver README.
#
# Uso:
#   ./install.sh                so o que e meu (stellarum + branding) + corretor
#   ./install.sh --colecao      tambem reinstala os 113 temas do temas.tsv
#   ./install.sh --patches      tambem aplica meus ajustes de contraste
set -euo pipefail
cd "$(dirname "$0")"

colecao=0; patches=0
for a in "$@"; do
  case "$a" in
    --colecao) colecao=1 ;;
    --patches) patches=1 ;;
    *) echo "opcao desconhecida: $a" >&2; exit 2 ;;
  esac
done

TEMAS="$HOME/.config/omarchy/themes"
mkdir -p "$TEMAS"

# ---- o que e meu ----
if [ -d files/stellarum ]; then
  mkdir -p "$TEMAS/stellarum"
  cp -r files/stellarum/. "$TEMAS/stellarum/"
  echo "tema stellarum -> $TEMAS/stellarum"
fi

if [ -f files/branding/screensaver.txt ]; then
  install -Dm644 files/branding/screensaver.txt \
    "$HOME/.config/omarchy/branding/screensaver.txt"
  echo "wordmark da tela de descanso -> ~/.config/omarchy/branding/screensaver.txt"
  echo "  (troque pelo seu: figlet -f 'Delta Corps Priest 1' SEUNOME)"
fi

# ---- colecao, opcional ----
if [ "$colecao" -eq 1 ]; then
  if ! command -v omarchy-theme-install >/dev/null 2>&1; then
    echo "AVISO: omarchy-theme-install nao encontrado, pulando a colecao" >&2
  else
    total=0; ok=0; pulados=0
    while IFS=$'\t' read -r slug url; do
      [ -n "${slug:-}" ] || continue
      total=$((total+1))
      case "$url" in
        ""|-|"(local)") pulados=$((pulados+1)); continue ;;
      esac
      if [ -d "$TEMAS/$slug" ]; then pulados=$((pulados+1)); continue; fi
      if omarchy-theme-install "$url" >/dev/null 2>&1; then
        ok=$((ok+1)); echo "  instalado: $slug"
      else
        echo "  FALHOU: $slug ($url)" >&2
      fi
    done < temas.tsv
    echo "colecao: $ok instalados, $pulados pulados (ja existiam ou sao locais), de $total"
  fi
fi

# ---- consertos, sempre ----
./corrige-temas.sh

# ---- patches de gosto, opcional ----
if [ "$patches" -eq 1 ]; then
  for p in patches/*.patch; do
    [ -f "$p" ] || continue
    t="$(basename "$p" .patch)"
    if [ ! -d "$TEMAS/$t" ]; then echo "  pulado (tema ausente): $t"; continue; fi
    if git -C "$TEMAS/$t" apply --check "$(realpath "$p")" 2>/dev/null; then
      git -C "$TEMAS/$t" apply "$(realpath "$p")" && echo "  patch aplicado: $t"
    else
      echo "  patch NAO aplica (ja aplicado ou tema mudou): $t"
    fi
  done
fi

echo
echo "Pronto. Reaplique o tema atual pra valer: omarchy-theme-set <nome>"
