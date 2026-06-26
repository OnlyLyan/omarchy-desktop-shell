#!/bin/sh
# Status do Claude Code pra barra. Imprime: "state nagents kind nsessions"
#   state     = working | idle   (alguma sessao mexida nos ultimos WORK_WINDOW s)
#   nagents   = subagentes ativos (jsonl mexido nos ultimos AGENT_WINDOW s)
#   kind      = workflow (>1 agente) | single (1) | none (0)
#   nsessions = processos `claude` rodando (sessoes abertas)
#
# Detecta por mtime dos transcripts em ~/.claude/projects/<proj>/<uuid>.jsonl e dos
# subagentes em <uuid>/subagents/agent-*.jsonl (mexidos = rodando agora).
ROOT="$HOME/.claude/projects"
now=$(date +%s)

# Subcomando "rooms": uma linha por sessao recente (sala), pro modo "salas".
#   nome|working|nagents   (nome = projeto + inicio do uuid)
# Simulacao: ~/.local/state/claude-monitor/rooms-sim (uma linha "nome|w|n" por sala).
if [ "${1:-}" = rooms ]; then
  SIMR="$HOME/.local/state/claude-monitor/rooms-sim"
  [ -f "$SIMR" ] && { cat "$SIMR"; exit 0; }
  for f in "$ROOT"/*/*.jsonl; do
    [ -f "$f" ] || continue
    mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    [ $((now - mt)) -le 900 ] || continue   # sessoes mexidas nos ultimos 15 min
    w=0; [ $((now - mt)) -le 12 ] && w=1
    dir="${f%.jsonl}"; na=0
    for a in "$dir"/subagents/agent-*.jsonl; do
      [ -f "$a" ] || continue
      amt=$(stat -c %Y "$a" 2>/dev/null || echo 0)
      [ $((now - amt)) -le 20 ] && na=$((na + 1))
    done
    proj=$(basename "$(dirname "$f")" | sed 's/^-home-lucas//; s/^-/\//; s/-/./g'); [ -z "$proj" ] && proj="~"
    uuid=$(basename "$f" .jsonl)
    echo "${proj} ${uuid%%-*}|$w|$na"
  done
  exit 0
fi

WORK_WINDOW=12
AGENT_WINDOW=20

# modo de simulacao/demo: se existir o arquivo com um numero, forca N agentes
# (pra ver as animacoes sem precisar rodar agentes de verdade).
#   echo 3 > ~/.local/state/claude-monitor/sim   # simula 3 agentes (workflow)
#   rm     ~/.local/state/claude-monitor/sim      # volta ao real
SIM="$HOME/.local/state/claude-monitor/sim"
if [ -f "$SIM" ]; then
  n=$(tr -dc '0-9' < "$SIM" 2>/dev/null); n=${n:-0}
  if   [ "$n" -gt 1 ]; then k=workflow
  elif [ "$n" -eq 1 ]; then k=single
  else k=none; fi
  echo "working $n $k 2"
  exit 0
fi

state=idle
sess_m=0
for f in "$ROOT"/*/*.jsonl; do
  [ -f "$f" ] || continue
  t=$(stat -c %Y "$f" 2>/dev/null || echo 0)
  [ "$t" -gt "$sess_m" ] && sess_m=$t
done
[ "$sess_m" -gt 0 ] && [ $((now - sess_m)) -le "$WORK_WINDOW" ] && state=working

nag=0
for f in "$ROOT"/*/*/subagents/agent-*.jsonl; do
  [ -f "$f" ] || continue
  t=$(stat -c %Y "$f" 2>/dev/null || echo 0)
  [ $((now - t)) -le "$AGENT_WINDOW" ] && nag=$((nag + 1))
done
[ "$nag" -gt 0 ] && state=working

if   [ "$nag" -gt 1 ]; then kind=workflow
elif [ "$nag" -eq 1 ]; then kind=single
else kind=none
fi

nsess=$(pgrep -fc '/claude-code/bin/claude' 2>/dev/null || echo 0)

echo "$state $nag $kind ${nsess:-0}"
