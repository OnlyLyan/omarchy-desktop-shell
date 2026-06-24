#!/bin/bash
# Abre o alt+tab no MONITOR FOCADO (passa o nome do monitor pra IPC da barra).
mon=$(hyprctl monitors -j 2>/dev/null | jq -r '.[]|select(.focused)|.name' | head -1)
exec quickshell ipc call alttab next "$mon"
