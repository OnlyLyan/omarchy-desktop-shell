#!/bin/bash
# Clima pra barra Quickshell. Saida: ICON \t TEMP \t PLACE (uma linha).
# Campos vazios se offline. Reusa omarchy-weather-icon (dia/noite via wttr j1).
export PATH="$HOME/.local/share/omarchy/bin:$PATH"

icon=$(omarchy-weather-icon 2>/dev/null)

data=$(curl -fsS --max-time 6 "https://wttr.in/?format=%t|%l|%w" 2>/dev/null | tr -d '\n')
IFS='|' read -r temp place wind <<<"$data"
temp=${temp#+}        # "+21C" -> "21C"
place=${place%%,*}    # "Cidade, Pais" -> "Cidade"

printf '%s\t%s\t%s\t%s\n' "$icon" "$temp" "$place" "$wind"
