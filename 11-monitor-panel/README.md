# 11 | Painel de monitores no Quickshell

Configuracao de monitores nativa na central de acoes da barra (pasta 06), pra nao depender de TUI
de terceiro (hyprmon etc.): resolucao, escala, rotacao, on/off e posicao por um mapa arrastavel,
com preview seguro e perfis manuais. UI em QML; todo efeito de sistema mora no `monitors.sh`
(mesmo padrao de `audio.sh`/`wifi.sh`).

## Como funciona
- **Mapa arrastavel**: o principal e ancora fixa; os secundarios arrastam e grudam num dos quatro
  lados. Tamanho do tile pela resolucao NATIVA (quem tem mais pixels aparece maior). O offset
  perpendicular e livre, mas com snap magnetico pras bordas alinhadas (topo/centro/base) pra
  evitar zona morta onde o cursor trava ao cruzar entre telas.
- **Aplicar sem flash**: `Aplicar` aplica ao vivo e mostra um toast `Manter esta configuracao?`
  com Sim/Reverter. O reload da cena (que reposiciona os surfaces) so acontece no Confirmar ou
  Reverter, entao o momento do Aplicar fica liso.
- **Rede de seguranca**: `monitors.sh preview` arma um watchdog `setsid` INDEPENDENTE do quickshell.
  Se ninguem confirmar em 10s, ele reverte E recarrega a barra sozinho, sobrevivendo ate a barra
  cair. O toast e so a contagem na tela.
- **Reload dos surfaces**: o quickshell 0.3.0 nao reposiciona barra/wallpaper/overlay quando o
  output muda de lugar; sem recriar a cena a barra some e a overlay pode ficar presa (tela preta).
  Um `IpcHandler` target `shell` com `reload()` recria a cena apos a troca.
- **Cursor estavel**: ao normalizar o layout pra 0,0 o principal desloca; o `monitors.sh` captura
  o monitor sob o cursor + o offset relativo antes e recoloca o cursor no mesmo ponto depois, pra
  ele seguir o principal em vez de teleportar pro monitor movido.
- **Monitor desligado continua na lista** (`monitors.sh get` usa `monitors all -j`), com o toggle
  pra religar. O `monitors -j` puro omite os desligados.
- **Bloco gerenciado**: so o trecho entre `# >>> quickshell-monitors` e `# <<< quickshell-monitors`
  do `~/.config/hypr/monitors.conf` e reescrito (com `.bak` e escrita atomica); o resto fica intacto.
- **Perfis**: arquivos `.conf` em `~/.config/quickshell/monitor-profiles/` (sem dependencia de jq).

## Arquivos
- `files/MonitorPanel.qml` -> `~/.config/quickshell/` (o painel: mapa, controles, preview, perfis)
- `files/MonitorStep.qml` -> `~/.config/quickshell/` (botaozinho +/- reutilizavel)
- `files/scripts/monitors.sh` -> `~/.config/quickshell/scripts/` (camada de sistema, CLI)
- `files/scripts/test-monitors.sh` -> `~/.config/quickshell/scripts/` (24 testes com stub de hyprctl)

A integracao no `shell.qml` (card de entrada, view `card.view === "monitors"`, o `IpcHandler`
target `shell`, e o toast de confirmacao) ja vem no `shell.qml` da pasta 06.

## Depende de
A barra Quickshell (pasta 06) rodando: o painel e uma view dentro dela e o toast/IPC vivem no
mesmo processo (qsbar). Precisa de `python3` (usado pelo `monitors.sh` pra achar o monitor sob o
cursor) e do `hyprctl`.

## Testar
`bash ~/.config/quickshell/scripts/test-monitors.sh` (espera `PASS=24 FAIL=0`).
