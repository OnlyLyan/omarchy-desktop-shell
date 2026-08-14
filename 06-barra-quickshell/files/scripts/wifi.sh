#!/bin/bash
# wifi.sh | backend de rede da central de acoes (iwd via iwctl)
#
# Contrato consumido por ~/.config/quickshell/shell.qml (bloco wifi):
#   list                   -> conn|sig|sec|known|nome     (uma linha por rede)
#                             conn 1/0, sig 1-4, sec psk|open|8021x|wep, known 1/0
#   state                  -> nome|sig da rede conectada (vazio se offline)
#   scan                   -> dispara scan; sem saida
#   details <ssid>         -> chave|valor (uma por linha)
#   connect <ssid> [senha] -> conecta; sem senha e rede desconhecida abre o impala
#   disconnect
#   forget <ssid>
#
# 'list' NAO escaneia de proposito: o shell.qml tem um botao separado que chama
# 'scan' e acende o indicador de busca. Misturar os dois deixava a lista 2s lenta.
set -uo pipefail

dev=""
for i in /sys/class/net/*/wireless; do dev=$(basename "$(dirname "$i")"); break; done
[ -z "$dev" ] && exit 0

# iwctl colore a saida mesmo sem tty; tira os escapes ANSI antes de parsear
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

known_raw() { iwctl known-networks list 2>/dev/null | strip; }

# Tabela do get-networks:
#       Network name                      Security            Signal
#   --------------------------------------------------------------------
#     >   Minha Rede                      psk                 ****
# O nome pode ter espacos, entao: ultimo campo = sinal, penultimo = seguranca,
# o resto (menos o '>' de conectado) = nome. O sinal vem como asteriscos.
list_nets() {
  local kn; kn=$(known_raw)
  iwctl station "$dev" get-networks 2>/dev/null | strip | awk -v kn="$kn" '
    /^-+$/ { sep++; next }
    sep >= 2 && NF > 0 {
      conn = 0
      if ($1 == ">") { conn = 1; $1 = "" }
      sig = $NF; sec = $(NF-1)
      name = ""
      for (i = 1; i <= NF-2; i++) if ($i != "") name = name (name == "" ? "" : " ") $i
      if (name == "") next
      known = index(kn, name) > 0 ? 1 : 0
      print conn "|" length(sig) "|" sec "|" known "|" name
    }'
}

case "${1:-}" in
  list)
    list_nets
    ;;

  state)
    # a linha com conn=1 vira "nome|sinal"; vazio se nao houver conectada.
    # o nome pode conter '|', entao remonta dos campos 5+ antes de imprimir.
    list_nets | awk -F'|' '$1 == "1" {
      name = $5; for (i = 6; i <= NF; i++) name = name "|" $i
      print name "|" $2; exit
    }'
    ;;

  scan)
    iwctl station "$dev" scan >/dev/null 2>&1
    ;;

  details)
    ssid="${2:-}"; [ -z "$ssid" ] && exit 0
    row=$(list_nets | awk -F'|' -v s="$ssid" '{ n=$0; sub(/^([^|]*\|){4}/,"",n); if (n == s) print }')
    conn=$(printf '%s' "$row" | cut -d'|' -f1)
    sig=$(printf '%s'  "$row" | cut -d'|' -f2)
    sec=$(printf '%s'  "$row" | cut -d'|' -f3)
    kno=$(printf '%s' "$row" | cut -d'|' -f4)

    if   [ "$conn" = "1" ]; then echo "Estado|Conectada"
    elif [ "$kno"  = "1" ]; then echo "Estado|Salva"
    else                         echo "Estado|Disponivel"
    fi
    [ -n "$sec" ] && echo "Seguranca|$sec"
    [ -n "$sig" ] && echo "Sinal|$sig/4"

    # ultima conexao sai da tabela de known-networks (ultima coluna)
    last=$(known_raw | grep -F "$ssid" | sed -E 's/.*(psk|open|8021x|wep)[[:space:]]+//' | sed 's/[[:space:]]*$//')
    [ -n "$last" ] && echo "Ultima conexao|$last"

    if [ "$conn" = "1" ]; then
      ip4=$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | head -1)
      ip6=$(ip -6 -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | head -1)
      gw=$(ip -4 route show default dev "$dev" 2>/dev/null | awk '{print $3}' | head -1)
      mac=$(cat "/sys/class/net/$dev/address" 2>/dev/null)
      [ -n "$ip4" ] && echo "IPv4|$ip4"
      [ -n "$ip6" ] && echo "IPv6|$ip6"
      [ -n "$gw"  ] && echo "Gateway|$gw"
      [ -n "$mac" ] && echo "MAC|$mac"
      echo "Interface|$dev"
    fi
    ;;

  connect)
    ssid="${2:-}"; pw="${3:-}"; [ -z "$ssid" ] && exit 1
    if [ -n "$pw" ]; then
      iwctl --passphrase "$pw" station "$dev" connect "$ssid" >/dev/null 2>&1
    elif known_raw | grep -qF "$ssid"; then
      iwctl station "$dev" connect "$ssid" >/dev/null 2>&1
    else
      # rede nova sem senha informada: delega pro fluxo grafico do Omarchy
      exec omarchy-launch-wifi
    fi
    ;;

  disconnect)
    iwctl station "$dev" disconnect >/dev/null 2>&1
    ;;

  forget)
    ssid="${2:-}"; [ -z "$ssid" ] && exit 1
    iwctl known-networks "$ssid" forget >/dev/null 2>&1
    ;;

  *)
    echo "uso: wifi.sh {list|state|scan|details <ssid>|connect <ssid> [senha]|disconnect|forget <ssid>}" >&2
    exit 2
    ;;
esac
