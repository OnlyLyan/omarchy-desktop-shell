#!/bin/sh
# Imprime "cpu mem temp" para o PcHeartbeat:
#   cpu  = uso de CPU 0-100 (delta de /proc/stat)
#   mem  = uso de RAM 0-100 (/proc/meminfo)
#   temp = maior temperatura em C: tenta nvidia-smi, senao /sys/class/thermal (0 se nada)
set -- $(awk '/^cpu /{for(i=2;i<=NF;i++)s+=$i; print s,$5}' /proc/stat); t1=$1; i1=$2
sleep 0.25
set -- $(awk '/^cpu /{for(i=2;i<=NF;i++)s+=$i; print s,$5}' /proc/stat); t2=$1; i2=$2
dt=$((t2 - t1)); di=$((i2 - i1))
if [ "$dt" -gt 0 ]; then cpu=$((100 * (dt - di) / dt)); else cpu=0; fi

mem=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{print int((t-a)*100/t)}' /proc/meminfo)

temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
if [ -z "$temp" ]; then
  temp=0
  for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$z" ] || continue
    v=$(cat "$z" 2>/dev/null); [ -n "$v" ] && v=$((v / 1000)) || v=0
    [ "$v" -gt "$temp" ] && temp=$v
  done
fi

echo "$cpu $mem ${temp:-0}"
