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
#   audio.sh apps                -> apps tocando: ids|mudo|vol|sink|nome
#   audio.sh app-output <ids> <sink> -> move os streams do app (csv de ids) pro sink
#   audio.sh app-vol <id> <0-100>
#   audio.sh app-mute <id>
#   audio.sh bass-get            -> 0|1
#   audio.sh bass-toggle
#   audio.sh mirror <csv>        -> espelha a saida em varios dispositivos (combine-sink)
#   audio.sh mirror-off          -> desfaz o espelho, volta pro 1o dispositivo
#   audio.sh mirror-get          -> csv dos dispositivos espelhados (vazio se off)
set -uo pipefail

STATE_DIR="$HOME/.local/state/audio"; mkdir -p "$STATE_DIR"
BASS_DEV_FILE="$STATE_DIR/bass-device"
COMBINE_NAME="qsbar_combine"
COMBINE_SLAVES_FILE="$STATE_DIR/combine-slaves"
have() { command -v "$1" >/dev/null 2>&1; }

# move todos os sink-inputs (apps) para o sink $1
move_all() {
  local s
  for s in $(pactl list short sink-inputs | awk '{print $1}'); do
    pactl move-sink-input "$s" "$1" 2>/dev/null
  done
  return 0
}

# descarrega qualquer combine-sink nosso (modo espelho), por id robusto (varre os modules)
mirror_unload() {
  local m
  for m in $(pactl list modules short 2>/dev/null | awk -v n="$COMBINE_NAME" '/module-combine-sink/ && $0 ~ n {print $1}'); do
    pactl unload-module "$m" 2>/dev/null
  done
  rm -f "$COMBINE_SLAVES_FILE"
}

# primeiro device real (nao-easyeffects, nao-combine); prefere o atual default, senao bluez, senao primeiro
real_default() {
  local d; d="$(pactl get-default-sink 2>/dev/null)"
  [ -n "$d" ] && [ "$d" != easyeffects_sink ] && [ "$d" != "$COMBINE_NAME" ] && { echo "$d"; return; }
  pactl list short sinks | awk '$2 ~ /bluez/{print $2; exit}' && return
  pactl list short sinks | awk -v n="$COMBINE_NAME" '$2!="easyeffects_sink" && $2!=n{print $2; exit}'
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
    pactl list sinks 2>/dev/null | awk -v def="$def" -v comb="$COMBINE_NAME" '
      /^[[:space:]]*Name:/ { name=$2 }
      /^[[:space:]]*Description:/ {
        d=$0; sub(/^[[:space:]]*Description:[[:space:]]*/,"",d)
        if (name!="easyeffects_sink" && name!=comb) {
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
    mirror_unload   # escolher um dispositivo unico desfaz o espelho
    if pgrep -x easyeffects >/dev/null 2>&1; then
      # bass ligado: troca o device POR BAIXO do EE (mantem o bass), nao deixa caminho morto
      bass_up "$dev"
    else
      pactl set-default-sink "$dev"
      move_all "$dev"
    fi
    ;;
  apps)
    # 1 linha por APP (junta streams do mesmo app): "ids|mute|vol|sink|nome".
    # mute=1 so se TODOS os streams do app estiverem mudos; vol = o maior dos streams.
    # sink = nome do sink do 1o stream do app (resolvido via index->nome).
    pactl list sink-inputs 2>/dev/null | awk '
      function flush() { if (id!="") { n=(app!=""?app:med); print id "|" mute "|" vol "|" sinkidx "|" n } }
      /^Sink Input #/ { flush(); id=substr($3,2); mute=0; vol=0; app=""; med=""; sinkidx="" }
      /^[[:space:]]*Sink:/ { sinkidx=$2 }
      /^[[:space:]]*Mute:/ { mute=($2=="yes")?1:0 }
      /^[[:space:]]*Volume:/ && vol==0 { if (match($0,/[0-9]+%/)) vol=substr($0,RSTART,RLENGTH-1) }
      /application.name = / { a=$0; sub(/.*application.name = "/,"",a); sub(/".*/,"",a); app=a }
      /media.name = / { m=$0; sub(/.*media.name = "/,"",m); sub(/".*/,"",m); med=m }
      END { flush() }' \
    | awk -F'|' -v sinks="$(pactl list short sinks | awk '{print $1":"$2}' | paste -sd,)" '
        BEGIN { ns=split(sinks, sa, ","); for (i=1;i<=ns;i++){ split(sa[i], kv, ":"); sm[kv[1]]=kv[2] } }
        { name=$5; sk=($4 in sm)?sm[$4]:""
          if (!(name in seen)) { seen[name]=1; order[++n]=name; ids[name]=$1; mut[name]=$2; vmax[name]=$3; snk[name]=sk }
          else { ids[name]=ids[name] "," $1; if ($2=="0") mut[name]="0"; if ($3+0>vmax[name]+0) vmax[name]=$3 } }
        END { for (i=1;i<=n;i++){ nm=order[i]; print ids[nm] "|" mut[nm] "|" vmax[nm] "|" snk[nm] "|" nm } }'
    ;;
  app-vol)
    # aceita lista de ids separada por virgula (todos os streams do app)
    p="${3:-0}"
    IFS=','; for sid in ${2:-}; do pactl set-sink-input-volume "$sid" "${p}%" 2>/dev/null; done
    ;;
  app-mute)
    IFS=','; for sid in ${2:-}; do pactl set-sink-input-mute "$sid" toggle 2>/dev/null; done
    ;;
  app-output)
    # move todos os streams do app (csv de ids) pro sink escolhido, na hora (sem persistencia)
    ids="${2:-}"; sink="${3:-}"
    [ -n "$ids" ] && [ -n "$sink" ] || { echo "audio.sh: app-output precisa de <ids> <sink>" >&2; exit 1; }
    pactl list short sinks | grep -Fq "$sink" || { echo "audio.sh: sink inexistente: $sink" >&2; exit 1; }
    IFS=','; for sid in $ids; do pactl move-sink-input "$sid" "$sink" 2>/dev/null; done
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
      # LIGA: bass e espelho sao incompativeis -> desfaz o espelho antes
      mirror_unload
      bass_up "$(real_default)"
    fi
    ;;
  mirror)
    # espelha a saida em varios dispositivos via combine-sink (slaves = csv de names)
    slaves="${2:-}"; [ -n "$slaves" ] || { echo "audio.sh: mirror precisa de slaves" >&2; exit 1; }
    # bass e espelho nao convivem: desliga o EE se estiver no caminho
    pgrep -x easyeffects >/dev/null 2>&1 && { pkill -x easyeffects 2>/dev/null; sleep 0.4; }
    mirror_unload   # limpa combine anterior
    mod="$(pactl load-module module-combine-sink \
            sink_name="$COMBINE_NAME" slaves="$slaves" \
            sink_properties=device.description="Espelhado_(varios)" 2>/dev/null)"
    case "$mod" in ''|*[!0-9]*) echo "audio.sh: falha ao criar combine-sink" >&2; exit 1;; esac
    echo "$slaves" > "$COMBINE_SLAVES_FILE"
    for i in $(seq 1 25); do pactl list short sinks | grep -Fq "$COMBINE_NAME" && break; sleep 0.2; done
    pactl set-default-sink "$COMBINE_NAME"
    move_all "$COMBINE_NAME"
    ;;
  mirror-off)
    first="$(cut -d, -f1 "$COMBINE_SLAVES_FILE" 2>/dev/null)"
    mirror_unload
    { [ -n "$first" ] && pactl list short sinks | grep -Fq "$first"; } || first="$(real_default)"
    pactl set-default-sink "$first"
    move_all "$first"
    ;;
  mirror-get)
    # csv dos dispositivos espelhados, so se o combine ainda existe de fato
    if pactl list short sinks | grep -Fq "$COMBINE_NAME"; then
      cat "$COMBINE_SLAVES_FILE" 2>/dev/null
    fi
    ;;
  *)
    echo "uso: audio.sh {get|set|toggle|sinks|output|apps|app-vol|app-mute|app-output|bass-get|bass-toggle|mirror|mirror-off|mirror-get|mic-get|mic-set|mic-toggle|sources|input|mic-apps|mic-app-vol|mic-app-mute}" >&2
    exit 1
    ;;
esac
