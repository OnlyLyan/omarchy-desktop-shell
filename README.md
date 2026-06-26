# omarchy-desktop-shell

Shell de desktop estilo Windows para Hyprland (Omarchy / Arch + Wayland): uma barra propria em
Quickshell que substitui a waybar, Alt+Tab com miniaturas ao vivo, e barra de titulo com botoes
de fechar/minimizar/maximizar. Os tres componentes integram entre si.

Ambiente: Omarchy (Arch + Hyprland), Wayland, PipeWire, Bash. Caminhos com `~` sao relativos
ao seu HOME. Cada pasta tem `README.md` (o que faz, por que, como foi feito), `files/` (os
arquivos reais) e `install.sh` idempotente.

## Componentes

| Pasta | O que e |
|-------|---------|
| `05-hyprbars-titlebar` | Barra de titulo com botoes semaforo + minimizar custom (plugin hyprbars + `window-minimize`) |
| `06-barra-quickshell` | Barra propria em Quickshell que substitui a waybar (taskbar agrupada, central de acoes) |
| `07-alttab-quickshell` | Alt+Tab estilo Windows com thumbnail ao vivo (overlay no mesmo processo da barra) |
| `08-bonus-opcional` | Extras OPCIONAIS (wallpaper-engine, tts-read) que a barra chama em dois botoes; instalador interativo, nao obrigatorio |
| `09-pc-heartbeat` | Os "batimentos" do PC: coracao + grafico de ECG + bpm que aceleram e ficam vermelhos sob estresse (CPU/RAM/temp). Componente reutilizavel + demo standalone; ja integrado na barra (06) |
| `10-claude-monitor` | OPCIONAL: indicador do Claude Code (robo + agentes) + popup "Salas do Claude" (uma sala de aula por sessao). Empacotado pra plugar, nao vem ativo |

A barra (06) e **theme-aware**: le o `colors.toml` do tema ativo do Omarchy e troca junto, com
seletor de tema na central de acoes (card Personalizacao). Detalhes no README da pasta 06.

## Dependencias

```
07-alttab  ──depende──>  06-barra-quickshell  <──integra──  05-hyprbars
                              (processo qsbar)              (store de minimizadas)
```

- **07 depende de 06**: o overlay do Alt+Tab vive no mesmo processo da barra (`qsbar`); os scripts
  chamam `quickshell ipc call alttab next/prev`. Sem a barra rodando, o Alt+Tab nao abre.
- **05 integra com 06**: o `window-minimize` (pasta 05) guarda as janelas minimizadas no workspace
  `special:minimized` e mantem um store em `/tmp/minimized-windows`. O clique no icone do app na
  taskbar da barra (pasta 06, `taskbar-activate.sh`) le esse mesmo store pra RESTAURAR a janela no
  workspace/monitor de origem. As duas pastas compartilham essa convencao.

### Versoes testadas
- Hyprland `0.55.2` (tag v0.55.2)
- Quickshell `0.3.0` (AUR `quickshell-git`, revision 68c2c85), compilado contra Qt `6.11.1`
- Omarchy (Arch + Hyprland), Wayland, PipeWire

### Dependencias externas (pacotes/plugins)
- `quickshell-git` (AUR), compilado contra Qt 6.11.1 (o oficial contra 6.11.0 quebra).
- Plugin `hyprbars` do repo `hyprland-plugins`, via `hyprpm`.
- Fonte `JetBrainsMono Nerd Font` (glifos dos botoes da barra de titulo).
- Hyprland com os snippets aplicados em `~/.config/hypr/{bindings,autostart,hyprland}.conf`
  (os `install.sh` anexam de forma idempotente).
- Waybar e desligada pela pasta 06 (flag `~/.local/state/omarchy/toggles/waybar-off`).

## Instalar

Ordem recomendada (respeita as dependencias):
```bash
cd 05-hyprbars-titlebar && ./install.sh && cd ..
cd 06-barra-quickshell  && ./install.sh && cd ..
cd 07-alttab-quickshell && ./install.sh && cd ..
hyprctl reload   # ou relogar
```
Os `install.sh` sao idempotentes (nao duplicam linhas em bindings/autostart). Veja o README de
cada pasta para os pacotes e os passos manuais (instalar o plugin hyprbars, o quickshell-git,
desligar a waybar).

## Origem
Recorte de um catalogo maior de customizacoes do meu Omarchy (mantido localmente). Aqui vao so os
tres componentes da shell de desktop.
