#!/bin/bash
mon=$(hyprctl monitors -j 2>/dev/null | jq -r '.[]|select(.focused)|.name' | head -1)
exec quickshell ipc call alttab prev "$mon"
