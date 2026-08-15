#!/bin/bash
# Medicao de internet para a barra do Quickshell.
#
# Por que existe, e nao um modulo pronto: em 2026-08-14 a internet ficou
# inutilizavel (live nao carregava, jogo lento) e TODOS os numeros classicos
# estavam perfeitos. Ping em 46ms com 0% de perda, download a 15 MB/s. Quem
# estava quebrado era o DNS do roteador, que trava na consulta combinada A+AAAA.
# Um indicador de download/upload/ping nao teria mostrado nada. Por isso aqui a
# medicao continua tem TRES pernas, e a do DNS e a mais importante das tres.
#
# Divisao de custo, que e o motivo dos comandos serem separados:
#   lat   -> 2 pings, roda a cada poucos segundos, custo desprezivel
#   dns   -> 1 consulta, roda com folga, custo baixo
#   speed -> baixa e envia dezenas de MB, SO sob demanda, nunca sozinho
#
# Toda saida e uma linha simples de numeros para o QML nao ter que parsear nada
# complicado. Falha vira -1, nunca string vazia nem texto de erro: no QML
# "vazio" e "zero" se confundem, -1 nao.

set -u

HIST="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell-net-historico.json"

# ---------- latencia ----------
# Roteador E internet, os dois. E o par que separa a culpa: roteador alto e
# problema do wifi da casa, roteador bom com internet alta e o provedor. Foi
# exatamente essa separacao que permitiu descartar o wifi em dois minutos no
# incidente de 14/08.
_ping1() {
    local alvo="$1" saida
    [ -n "$alvo" ] || { echo "-1"; return; }
    # -c1 -W1: uma sonda, desiste em 1s. Nao pode travar a barra.
    saida="$(ping -c1 -W1 -n "$alvo" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')"
    [ -n "$saida" ] && printf '%.0f\n' "$saida" || echo "-1"
}

cmd_lat() {
    local gw
    gw="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
    echo "$(_ping1 "$gw") $(_ping1 1.1.1.1)"
}

# ---------- dns ----------
# --cache=no e o ponto todo: sem ele o resolved responde do cache local em 0ms
# e o numero esconderia exatamente o problema de 14/08.
#
# Dominio REAL, sorteado de uma lista, e nao um nome inventado. Medido nesta
# maquina: nome inexistente custa ~155ms porque paga a recursao inteira ate o
# servidor autoritativo, enquanto dominio real responde em ~50ms. O que interessa
# e o caminho que o navegador percorre de verdade, e e o dominio real que reflete
# isso. Sortear entre varios evita medir sempre o mesmo servidor autoritativo.
cmd_dns() {
    local nome t0 t1
    local -a alvos=(twitch.tv discord.com steamcommunity.com youtube.com
                    github.com cloudflare.com wikipedia.org reddit.com)
    nome="${alvos[$((RANDOM % ${#alvos[@]}))]}"
    t0=$(date +%s%N)
    timeout 5 resolvectl query --cache=no "$nome" >/dev/null 2>&1
    t1=$(date +%s%N)
    local ms=$(( (t1 - t0) / 1000000 ))
    # 5000ms e o teto do timeout: acima disso considera falha, nao lentidao
    [ "$ms" -ge 5000 ] && echo "-1" || echo "$ms"
}

# ---------- teste de velocidade ----------
# Contra a Cloudflare, que responde de um ponto proximo e nao exige conta nem
# pacote instalado. Foi assim que os 15 MB/s foram medidos no dia do incidente.
# Roda SO quando ele clica: baixar 25 MB sozinho de tempos em tempos gasta a
# franquia dele e atrapalha jogo em andamento.
_mbps() {  # bytes/s -> Mbit/s com uma casa
    awk -v b="$1" 'BEGIN{ printf "%.1f", (b*8)/1000000 }'
}

cmd_speed() {
    local bd bu

    # download: 25 MB. Menos que isso nao satura a linha e o numero sai baixo.
    bd="$(timeout 60 curl -s -o /dev/null -w '%{speed_download}' \
          "https://speed.cloudflare.com/__down?bytes=25000000" 2>/dev/null)"

    # upload: 10 MB. Upload domestico costuma ser bem menor que o download,
    # entao mandar 25 MB so faria o teste demorar tres vezes mais pelo mesmo dado.
    #
    # `head -c` alimentando `-T -` de proposito. A forma obvia,
    # `--data-binary @/dev/zero`, carrega o "arquivo" INTEIRO na memoria antes de
    # enviar, e /dev/zero e infinito: sao alguns segundos ate o processo comer a
    # RAM da maquina. Com -T - o curl envia em fluxo, e o head poe o limite.
    bu="$(head -c 10000000 /dev/zero | timeout 60 curl -s -o /dev/null \
          -w '%{speed_upload}' -T - --max-time 30 \
          -H 'Content-Type: application/octet-stream' \
          "https://speed.cloudflare.com/__up" 2>/dev/null)"

    local d u
    d="$( [ -n "${bd:-}" ] && [ "${bd%%.*}" -gt 0 ] 2>/dev/null && _mbps "$bd" || echo "-1" )"
    u="$( [ -n "${bu:-}" ] && [ "${bu%%.*}" -gt 0 ] 2>/dev/null && _mbps "$bu" || echo "-1" )"

    _historico_add "$d" "$u"
    echo "$d $u"
}

# ---------- historico ----------
# Tres entradas, como ele pediu. Arquivo em ~/.local/state para sobreviver a
# reinicio do shell e do PC. Escrita atomica via mktemp+mv: o QML le esse arquivo
# em polling e nao pode pegar JSON pela metade.
_historico_add() {
    local d="$1" u="$2" tmp
    mkdir -p "$(dirname "$HIST")"
    tmp="$(mktemp "${HIST}.XXXXXX")" || return 0
    python3 - "$HIST" "$tmp" "$d" "$u" <<'PY' || { rm -f "$tmp"; return 0; }
import json, sys, time, os
hist_p, tmp_p, d, u = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    with open(hist_p) as f:
        h = json.load(f)
    if not isinstance(h, list): h = []
except Exception:
    h = []
h.insert(0, {"t": int(time.time()), "down": float(d), "up": float(u)})
with open(tmp_p, "w") as f:
    json.dump(h[:3], f)   # so os 3 ultimos, o resto e ruido
PY
    mv -f "$tmp" "$HIST"
}

cmd_historico() {
    [ -s "$HIST" ] && cat "$HIST" || echo "[]"
}

case "${1:-}" in
    lat)       cmd_lat ;;
    dns)       cmd_dns ;;
    speed)     cmd_speed ;;
    historico) cmd_historico ;;
    *) echo "uso: net-medir.sh <lat|dns|speed|historico>" >&2; exit 1 ;;
esac
