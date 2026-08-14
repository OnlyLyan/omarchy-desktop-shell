#!/usr/bin/env bash
# A gaveta nao roda sozinha: e instanciada pelo shell.qml da pasta 06
# (GavetaPanel {}) e o gatilho e um botao do hyprbars da pasta 05. Por isso os
# arquivos vao pros mesmos caminhos que a barra usa. Rode este install ANTES de
# subir o qsbar, senao o shell.qml falha ao carregar por tipo desconhecido.
#
# Este install NAO mexe no hyprbars.conf nem no shell.qml: os dois sao das pastas
# 05 e 06 e tem install proprio. Ele so avisa se o botao azul nao estiver la.
set -euo pipefail
cd "$(dirname "$0")/files"

mkdir -p ~/.config/quickshell/scripts
install -Dm644 GavetaPanel.qml ~/.config/quickshell/GavetaPanel.qml
install -Dm755 scripts/gaveta.sh -t ~/.config/quickshell/scripts/

echo "gaveta -> ~/.config/quickshell/ (GavetaPanel.qml, scripts/gaveta.sh)"

# aviso, nao erro: da pra instalar em qualquer ordem, mas sem o botao nao ha
# como guardar janela pela interface
if ! grep -q "gaveta.sh botao" ~/.config/hypr/hyprbars.conf 2>/dev/null; then
  echo
  echo "AVISO: o botao azul da gaveta nao esta no seu ~/.config/hypr/hyprbars.conf."
  echo "       Rode o install da pasta 05, ou adicione a mao como PRIMEIRA linha de"
  echo "       botao (primeira linha = mais a direita na barra de titulo):"
  echo
  echo '  hyprbars-button = rgb(5c8fe0), 17, \U000f01da, ~/.config/quickshell/scripts/gaveta.sh botao, rgb(0d1b33)'
  echo
  echo "       Sem ele ainda da pra usar por terminal: gaveta.sh guardar <addr>."
fi
