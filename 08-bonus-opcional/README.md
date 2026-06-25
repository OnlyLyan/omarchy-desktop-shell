# 08 | Bonus opcional (nao obrigatorio)

Ferramentas extras que a barra (pasta 06) chama em DOIS botoes da central de acoes, mas que
pertencem a outras features e tem dependencias proprias. **A barra funciona 100% sem elas** | so
esses dois botoes ficam inertes ate as ferramentas existirem. Instale apenas se quiser.

O `install.sh` desta pasta e interativo: pergunta, um por um, se voce quer instalar cada extra.

## O que tem aqui

| Arquivo | Botao na barra | Para que serve | Dependencias proprias |
|---------|----------------|----------------|-----------------------|
| `files/wallpaper-engine` | Grade de wallpaper (central de acoes) | Liga/desliga wallpaper animado e abre o navegador de wallpapers | `linux-wallpaperengine` (AUR) e, pra baixar mais, o Wallpaper Engine do Steam (app 431960). Estado em `~/.local/state/wallpaper-engine` |
| `files/tts-read` | Botao de TTS (ler selecao em voz) | Le o texto selecionado em voz alta, offline (pt-BR) | Binario `piper` + voz em `~/.local/share/piper/`, `pw-cat` (PipeWire) e o hook de limpeza `~/.claude/hooks/tts-clean.py` |

Ambos os scripts usam `$HOME` (sem usuario hardcoded) e sao instalados em `~/.local/bin/`.

## Como a barra usa

No `shell.qml` (pasta 06), a central de acoes chama:
- `~/.local/bin/wallpaper-engine list|on|off|browse` na view de wallpaper.
- `~/.local/bin/tts-read` no botao de leitura por voz.

Sem os binarios no PATH, esses comandos simplesmente nao fazem nada (o resto da barra | audio, wifi,
weather, taskbar, Alt+Tab | continua normal).

## Instalar

```bash
./install.sh
```

Responda `s` apenas para os extras que quiser. Depois instale as dependencias proprias de cada um
(listadas acima e ecoadas pelo instalador).
