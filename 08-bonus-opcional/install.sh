#!/usr/bin/env bash
# Instalador INTERATIVO dos extras opcionais. Pergunta um por um.
# A barra (pasta 06) funciona sem nada disto; sao so dois botoes a mais.
set -uo pipefail
cd "$(dirname "$0")/files"

ask(){ local r; read -rp "$1 [s/N] " r; [[ "$r" =~ ^[sSyY]$ ]]; }

echo "Extras OPCIONAIS | a barra funciona sem eles. Responda so o que quiser."
echo

if ask "Instalar wallpaper-engine (grade de wallpaper)?"; then
  install -Dm755 wallpaper-engine ~/.local/bin/wallpaper-engine
  echo "  instalado -> ~/.local/bin/wallpaper-engine"
  echo "  precisa: linux-wallpaperengine (AUR); para baixar mais, Wallpaper Engine do Steam (app 431960)."
else
  echo "  pulado."
fi
echo

if ask "Instalar tts-read (botao de leitura por voz, TTS)?"; then
  install -Dm755 tts-read ~/.local/bin/tts-read
  echo "  instalado -> ~/.local/bin/tts-read"
  echo "  precisa: piper + voz em ~/.local/share/piper/, pw-cat (PipeWire) e ~/.claude/hooks/tts-clean.py."
else
  echo "  pulado."
fi
echo
echo "Pronto. Os botoes correspondentes na barra so funcionam depois das dependencias proprias instaladas."
