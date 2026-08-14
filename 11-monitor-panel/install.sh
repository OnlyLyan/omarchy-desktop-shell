#!/usr/bin/env bash
# O painel de monitores nao roda sozinho: e instanciado pelo shell.qml da pasta 06
# (MonitorPanel {}) e chamado via scripts/monitors.sh. Por isso os arquivos vao pros
# mesmos caminhos que a barra usa. Rode este install ANTES de subir o qsbar, senao o
# shell.qml falha ao carregar por tipo desconhecido.
set -euo pipefail
cd "$(dirname "$0")/files"

mkdir -p ~/.config/quickshell/scripts
install -Dm644 MonitorPanel.qml ~/.config/quickshell/MonitorPanel.qml
install -Dm644 MonitorStep.qml  ~/.config/quickshell/MonitorStep.qml
install -Dm755 scripts/monitors.sh scripts/test-monitors.sh -t ~/.config/quickshell/scripts/

echo "painel de monitores -> ~/.config/quickshell/ (MonitorPanel.qml, MonitorStep.qml, scripts/monitors.sh)"
