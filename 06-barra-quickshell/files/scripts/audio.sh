#!/bin/bash
# Controle de audio estilo Windows para a barra Quickshell.
# Modelo: o DISPOSITIVO real (fone BT / alto-falante) e o sink padrao direto.
# O volume master e as teclas de volume miram @DEFAULT_SINK@ (unificado, sem split-brain).
# Bass boost (EasyEffects) virou toggle sob demanda: liga, poe o EE no caminho e
# roteia a saida processada pro dispositivo atual; desliga, volta ao padrao.
#
#   audio.sh get                 -> "<0-100> <0|1 mudo>" do sink padrao (master)
#   audio.sh set <0-100>         -> volume master (cap 100, sem distorcao digital)
#   audio.sh toggle              -> muta/desmuta master
#   audio.sh sinks               -> dispositivos de saida: name|ativo|icone|descricao
#   audio.sh output <name>       -> troca a saida e move todos os apps pra ela
#   audio.sh apps                -> apps tocando: id|mudo|vol|nome
#   audio.sh app-vol <id> <0-100>
#   audio.sh app-mute <id>
#   audio.sh bass-get            -> 0|1
#   audio.sh bass-toggle
set -uo pipefail

STATE_DIR="$HOME/.local/state/audio"; mkdir -p "$STATE_DIR"
BASS_DEV_FILE="$STATE_DIR/bass-device"
have() { command -v "$1" >/dev/null 2>&1; }

# move todos os sink-inputs (apps) para o sink $1
move_all() {
  local s
  for s in $(pactl list short sink-inputs | awk '{print $1}'); do
    pactl move-sink-input "$s" "$1" 2>/dev/null
  done
}

# primeiro device real (nao-easyeffects); prefere o atual default, senao bluez, senao primeiro
real_default() {
  local d; d="$(pactl get-default-sink 2>/dev/null)"
  [ -n "$d" ] && [ "$d" != easyeffects_sink ] && { echo "$d"; return; }
  pactl list short sinks | awk '$2 ~ /bluez/{print $2; exit}' && return
  pactl list short sinks | awk '$2!="easyeffects_sink"{print $2; exit}'
}

# liga (ou re-roteia) o bass boost apontando a saida do EE pro device $1.
# O EE conecta a saida no device que for o PADRAO no momento em que SOBE, entao
# reiniciamos o EE com o device certo como padrao (sem cirurgia de pw-link, que
# criava ciclo no grafo e travava o PipeWire). Depois o EE assume como sink
# padrao e movemos os apps pra ele.
bass_up() {
  local dev="$1" i
  echo "$dev" > "$BASS_DEV_FILE"
  pkill -x easyeffects 2>/dev/null
  sleep 0.5
  pactl set-default-sink "$dev"
  setsid -f easyeffects --hide-window >/dev/null 2>&1
  for i in $(seq 1 25); do pactl list short sinks | grep -Fq easyeffects_sink && break; sleep 0.2; done
  sleep 0.3
  pactl set-default-sink easyeffects_sink
  move_all easyeffects_sink
}

case "${1:-get}" in
  get)
    vol="$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oE '[0-9]+%' | head -1 | tr -d '%')"
    mute="$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | grep -q yes && echo 1 || echo 0)"
    echo "${vol:-0} ${mute:-0}"
    ;;
  set)
    p="${2:-}"
    case "$p" in ''|*[!0-9]*) echo "audio.sh: volume invalido (0-100): '${p}'" >&2; exit 1;; esac
    [ "$p" -gt 100 ] && p=100
    pactl set-sink-volume @DEFAULT_SINK@ "${p}%"
    ;;
  toggle)
    pactl set-sink-mute @DEFAULT_SINK@ toggle
    ;;
  sinks)
    def="$(pactl get-default-sink 2>/dev/null)"
    pactl list sinks 2>/dev/null | awk -v def="$def" '
      /^[[:space:]]*Name:/ { name=$2 }
      /^[[:space:]]*Description:/ {
        d=$0; sub(/^[[:space:]]*Description:[[:space:]]*/,"",d)
        if (name!="easyeffects_sink") {
          icon="speaker"
          if (name ~ /bluez/) icon="headphones"
          else if (name ~ /hdmi/) icon="tv"
          else if (name ~ /usb/) icon="usb"
          printf "%s|%s|%s|%s\n", name, (name==def?1:0), icon, d
        }
      }'
    ;;
  output)
    dev="${2:-}"; [ -n "$dev" ] || exit 1
    pactl list short sinks | grep -Fq "$dev" || { echo "audio.sh: sink inexistente: $dev" >&2; exit 1; }
    if pgrep -x easyeffects >/dev/null 2>&1; then
      # bass ligado: troca o device POR BAIXO do EE (mantem o bass), nao deixa caminho morto
      bass_up "$dev"
    else
      pactl set-default-sink "$dev"
      move_all "$dev"
    fi
    ;;
  apps)
    # 1 linha por APP (junta streams do mesmo app): "ids(virgula)|mute|vol|nome".
    # mute=1 so se TODOS os streams do app estiverem mudos; vol = o maior dos streams.
    pactl list sink-inputs 2>/dev/null | awk '
      function flush() { if (id!="") { n=(app!=""?app:med); print id "|" mute "|" vol "|" n } }
      /^Sink Input #/ { flush(); id=substr($3,2); mute=0; vol=0; app=""; med="" }
      /^[[:space:]]*Mute:/ { mute=($2=="yes")?1:0 }
      /^[[:space:]]*Volume:/ && vol==0 { if (match($0,/[0-9]+%/)) vol=substr($0,RSTART,RLENGTH-1) }
      /application.name = / { a=$0; sub(/.*application.name = "/,"",a); sub(/".*/,"",a); app=a }
      /media.name = / { m=$0; sub(/.*media.name = "/,"",m); sub(/".*/,"",m); med=m }
      END { flush() }' \
    | awk -F'|' '
      { name=$4
        if (!(name in seen)) { seen[name]=1; order[++n]=name; ids[name]=$1; mut[name]=$2; vmax[name]=$3 }
        else { ids[name]=ids[name] "," $1; if ($2=="0") mut[name]="0"; if ($3+0>vmax[name]+0) vmax[name]=$3 } }
      END { for (i=1;i<=n;i++){ nm=order[i]; print ids[nm] "|" mut[nm] "|" vmax[nm] "|" nm } }'
    ;;
  app-vol)
    # aceita lista de ids separada por virgula (todos os streams do app)
    p="${3:-0}"
    IFS=','; for sid in ${2:-}; do pactl set-sink-input-volume "$sid" "${p}%" 2>/dev/null; done
    ;;
  app-mute)
    IFS=','; for sid in ${2:-}; do pactl set-sink-input-mute "$sid" toggle 2>/dev/null; done
    ;;

  # ---- microfone (sources de entrada), mesmo modelo do output ----
  mic-get)
    vol="$(pactl get-source-volume @DEFAULT_SOURCE@ 2>/dev/null | grep -oE '[0-9]+%' | head -1 | tr -d '%')"
    mute="$(pactl get-source-mute @DEFAULT_SOURCE@ 2>/dev/null | grep -q yes && echo 1 || echo 0)"
    echo "${vol:-0} ${mute:-0}"
    ;;
  mic-set)
    p="${2:-}"
    case "$p" in ''|*[!0-9]*) echo "audio.sh: volume invalido (0-100): '${p}'" >&2; exit 1;; esac
    [ "$p" -gt 100 ] && p=100
    pactl set-source-volume @DEFAULT_SOURCE@ "${p}%"
    ;;
  mic-toggle)
    pactl set-source-mute @DEFAULT_SOURCE@ toggle
    ;;
  sources)
    # so mics reais: exclui os .monitor (loopback de saidas) e o easyeffects_source
    defsrc="$(pactl get-default-source 2>/dev/null)"
    pactl list sources 2>/dev/null | awk -v def="$defsrc" '
      /^[[:space:]]*Name:/ { name=$2 }
      /^[[:space:]]*Description:/ {
        d=$0; sub(/^[[:space:]]*Description:[[:space:]]*/,"",d)
        if (name !~ /\.monitor$/ && name != "easyeffects_source") {
          icon="mic"
          if (name ~ /bluez/) icon="btmic"
          else if (name ~ /usb/) icon="usbmic"
          printf "%s|%s|%s|%s\n", name, (name==def?1:0), icon, d
        }
      }'
    ;;
  input)
    src="${2:-}"; [ -n "$src" ] || exit 1
    pactl list short sources | grep -Fq "$src" || { echo "audio.sh: source inexistente: $src" >&2; exit 1; }
    pactl set-default-source "$src"
    # move os apps que estao gravando pro novo mic
    for so in $(pactl list short source-outputs | awk '{print $1}'); do
      pactl move-source-output "$so" "$src" 2>/dev/null
    done
    ;;
  mic-apps)
    pactl list source-outputs 2>/dev/null | awk '
      /^Source Output #/ { id=substr($3,2); mute=0; vol=0; app=""; med="" }
      /^[[:space:]]*Mute:/ { mute=($2=="yes")?1:0 }
      /^[[:space:]]*Volume:/ && vol==0 { if (match($0,/[0-9]+%/)) vol=substr($0,RSTART,RLENGTH-1) }
      /application.name = / { a=$0; sub(/.*application.name = "/,"",a); sub(/".*/,"",a); app=a }
      /media.name = / { m=$0; sub(/.*media.name = "/,"",m); sub(/".*/,"",m); med=m }
      /^$/ { if (id!="") { n=(app!=""?app:med); print id "|" mute "|" vol "|" n; id="" } }
      END { if (id!="") { n=(app!=""?app:med); print id "|" mute "|" vol "|" n } }'
    ;;
  mic-app-vol)
    pactl set-source-output-volume "${2}" "${3:-0}%" 2>/dev/null
    ;;
  mic-app-mute)
    pactl set-source-output-mute "${2}" toggle 2>/dev/null
    ;;
  bass-get)
    pgrep -x easyeffects >/dev/null 2>&1 && echo 1 || echo 0
    ;;
  bass-toggle)
    # SEM cirurgia de pw-link (isso criava ciclo no grafo e travava o PipeWire).
    # Truque seguro: o EasyEffects liga a saida dele no DISPOSITIVO QUE FOR O PADRAO
    # no momento em que ele sobe. Entao garantimos o device certo como padrao ANTES
    # de subir o EE; depois o EE assume como sink padrao e a gente move os apps pra ele.
    if pgrep -x easyeffects >/dev/null 2>&1; then
      # DESLIGA: mata o EE primeiro, depois volta o audio direto pro dispositivo
      dev="$(cat "$BASS_DEV_FILE" 2>/dev/null)"
      { [ -z "$dev" ] || ! pactl list short sinks | grep -Fq "$dev"; } && dev="$(real_default)"
      pkill -x easyeffects 2>/dev/null
      sleep 0.6
      pactl set-default-sink "$dev"
      move_all "$dev"
    else
      # LIGA: roteia o bass pro device atual (helper reinicia o EE com o device certo)
      bass_up "$(real_default)"
    fi
    ;;
  *)
    echo "uso: audio.sh {get|set|toggle|sinks|output|apps|app-vol|app-mute|bass-get|bass-toggle|mic-get|mic-set|mic-toggle|sources|input|mic-apps|mic-app-vol|mic-app-mute}" >&2
    exit 1
    ;;
esac
