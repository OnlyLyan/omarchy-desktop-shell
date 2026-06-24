#!/bin/bash
# lista redes wifi do iwd como: conectado|sinal(1-4)|nome
dev=""
for i in /sys/class/net/*/wireless; do dev=$(basename "$(dirname "$i")"); break; done
[ -z "$dev" ] && exit 0
# escaneia pra trazer redes novas antes de listar (iwd faz scan assincrono)
iwctl station "$dev" scan 2>/dev/null
sleep 2
iwctl station "$dev" get-networks 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '
  /^-+$/ { sep++; next }
  sep>=2 && NF>0 {
    conn=0; if($1==">"){conn=1; $1=""}
    sig=$NF; name="";
    for(i=1;i<=NF-2;i++){ if($i!=""){ name=name (name==""?"":" ") $i } }
    if(name!="") print conn "|" length(sig) "|" name
  }'
