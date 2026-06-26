# 10 | Monitor do Claude Code + "Salas do Claude"

Um indicador opcional pra barra Quickshell que mostra se o Claude Code esta trabalhando e
quantos agentes/subagentes rodam:
- robo `󰚩` (cinza ocioso / azul trabalhando / roxo workflow) + spinner braille de "carregando"
  + uma bolinha por agente indo de um lado pro outro;
- clique abre o popup **"Salas do Claude"**: uma SALA DE AULA por sessao | a Claude na mesa do
  professor + os agentes como ALUNOS em cadeiras (sessao sem agentes = cadeiras vazias).

Detecta tudo por mtime dos transcripts em `~/.claude/projects/<proj>/<uuid>.jsonl` e dos
subagentes em `<uuid>/subagents/agent-*.jsonl`.

Componente OPCIONAL: nao vem ativo na barra da pasta 06. Aqui esta empacotado pra quem quiser
plugar.

## Arquivos
- `files/claude-status.sh` | o coletor. Subcomandos: (sem arg) -> `state nagents kind nsessions`;
  `rooms` -> `nome|working|nagents` por sessao recente. Simulacao: arquivos em
  `~/.local/state/claude-monitor/{sim,rooms-sim}`.
- `files/shell-qml-snippet.qml` | os DOIS blocos QML pra colar no `shell.qml`:
  - BLOCO A: estado (`QtObject id: claude`) + Processes (`claudeProc`, `roomsProc`) + `refreshRooms`.
  - BLOCO B: o icone (`Item id: claudeBtn`) + o popup das Salas.

## Instalar
1. `install -Dm755 files/claude-status.sh ~/.config/quickshell/scripts/claude-status.sh`
2. No `~/.config/quickshell/shell.qml`: colar o BLOCO A perto dos outros pollers (ex: depois do
   bloco da GPU) e o BLOCO B dentro da `RowLayout` do cluster direito (antes do icone de midia).
   Ajustar o caminho do `claude-status.sh` se necessario.
3. `systemctl --user restart qsbar`

## Observacao sobre cores
O snippet foi extraido antes do sistema de tema da barra (pasta 06), entao usa cores Tokyo
Night fixas (`#a9b1d6`, `#7aa2f7`, etc). Se voce ja roda a barra theme-aware, troque esses hex
por referencias ao objeto `theme` (ex: `theme.fg`, `theme.accent`, `theme.purple`) pra ele
acompanhar o tema ativo do Omarchy.

## Ideias pra incrementar
Lousa atras da Claude, fileiras de carteiras, nome da sessao na placa, o "chicote" no popup.
