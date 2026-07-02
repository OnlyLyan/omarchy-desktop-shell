# 05 | Barra de titulo com botoes (hyprbars)

O Omarchy puro nao tem barra de titulo, entao nao ha botao de fechar clicavel. Foi adicionado o
plugin hyprbars com botoes tipo semaforo, mais um minimizar custom (o Hyprland nao tem nativo).

## Atalho
- `SUPER + ALT + M` restaura a ultima janela minimizada.
- Botoes na barra (esq->dir): `X` vermelho fecha, `v` amarelo minimiza, `o` verde maximiza/restaura.

## Como foi feito
- Plugin `hyprbars` (repo `hyprland-plugins`), instalado/habilitado via `hyprpm`, carregado no
  login por `exec-once = hyprpm reload -n`.
- `hyprbars.conf`: barra de 28px, `bar_text_font = JetBrainsMono Nerd Font` (OBRIGATORIO, a fonte
  padrao nao tem os glifos). Botoes: fechar=`killactive`, maximizar=`fullscreen 1`,
  minimizar=`~/.local/bin/window-minimize`.
- `window-minimize`: o Hyprland nao tem minimizar; o script manda a janela pro workspace ESPECIAL
  `special:minimized` (`movetoworkspacesilent`, oculto por design), lembrando workspace e monitor
  de origem (estado em `/tmp/minimized-windows`, LIFO). Restaura no ws/monitor certo.
- Correcao 2026-06-23: antes usava workspace NOMEADO (virava id negativo e aparecia no monitor
  secundario, prendendo janelas). Trocado pra `special:` + poda do store (`prune_store`) contra
  os clients a cada operacao. NUNCA usar `togglespecialworkspace` (tornaria visivel).
- Restaurar tambem pelo clique no icone do app na barra Quickshell (pasta 06).
- Fix do reflow (2026-07-02): no dwindle, minimizar uma janela fazia as OUTRAS tiladas da mesma
  tela se reorganizarem (a arvore inteira se rearranja pra preencher o buraco; nenhum layout de
  tiling mantem o buraco). Trocado pro layout `master` via `looknfeel.snippet.conf`: a janela
  master fica fixa de um lado e so a pilha se reajusta, deixando o reflow previsivel.

## Arquivos
- `files/hyprbars.conf` -> `~/.config/hypr/hyprbars.conf`
- `files/window-minimize` -> `~/.local/bin/window-minimize`
- `files/hyprland-source.snippet.conf` -> linha `source` no `~/.config/hypr/hyprland.conf`
- `files/looknfeel.snippet.conf` -> trecho pro `~/.config/hypr/looknfeel.conf` (layout master)
- `files/bindings.snippet.conf` -> trecho pro `~/.config/hypr/bindings.conf`
- `files/autostart.snippet.conf` -> trecho pro `~/.config/hypr/autostart.conf`

## Instalar plugin
`hyprpm add https://github.com/hyprwm/hyprland-plugins && hyprpm enable hyprbars && hyprpm reload`
depois `./install.sh`
