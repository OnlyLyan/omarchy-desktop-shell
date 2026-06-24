# 07 | Alt+Tab custom em Quickshell (estilo Windows)

Substitui o hyprshell (que so mostrava icone, sem preview, e tinha bugs de clique/mouse). Agora e
um overlay no proprio `shell.qml` da barra (pasta 06): faixa horizontal de MINIATURAS AO VIVO das
janelas (`ScreencopyView` do `Quickshell.Wayland._Screencopy`), ordem MRU, janela anterior
pre-selecionada. Segura Alt, Tab cicla, solta Alt escolhe; clique foca.

## Como foi feito
- Binds em `bindings.conf`: `unbind ALT,TAB` + `bind = ALT, TAB, exec, alttab-next.sh` (prev no Shift).
  Os scripts chamam `quickshell ipc call alttab next/prev`; o overlay (IpcHandler target "alttab")
  pega o teclado (`WlrKeyboardFocus.Exclusive`).
- hyprshell DESATIVADO: linha comentada em `autostart.conf` (ver pasta original). Reverter:
  descomentar `exec-once = hyprshell run` e remover os `bind = ALT, TAB` do bindings.conf.

## Arquivos
- `files/alttab-next.sh`, `files/alttab-prev.sh` -> `~/.config/quickshell/scripts/`
- `files/bindings.snippet.conf` -> trecho pro `~/.config/hypr/bindings.conf`

## Depende de
A barra Quickshell (pasta 06) rodando, pois o overlay vive no mesmo processo (qsbar).

## Instalar
`./install.sh`
