#!/bin/bash
# conecta a uma rede iwd; se nao for conhecida (pede senha), abre o impala
dev=""
for i in /sys/class/net/*/wireless; do dev=$(basename "$(dirname "$i")"); break; done
[ -z "$dev" ] && exit 1
if iwctl known-networks list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -qF "$1"; then
  iwctl station "$dev" connect "$1"
else
  exec omarchy-launch-wifi
fi
