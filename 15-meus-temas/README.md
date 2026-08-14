# 15 | Temas: coleção, consertos e marca

Três coisas separadas, de propósito:

1. **`corrige-temas.sh`** — conserta temas do Omarchy que quebram em Hyprland
   recente. É o que tem valor de verdade aqui, e serve pra qualquer coleção, não
   só a minha.
2. **`temas.tsv`** — a lista dos 113 temas instalados aqui, com a URL de origem
   de cada um, e um `install.sh` que reinstala tudo.
3. **`files/`** — o que é meu: o tema `stellarum` e o wordmark da tela de descanso.

## Por que a lista e não os temas

112 dos 113 são clone de repositório de outra pessoa. Copiar o conteúdo pra cá
seria redistribuir trabalho alheio sem licença nem crédito, e ainda incharia o
repo com centenas de imagens de fundo. A lista com a origem faz o mesmo serviço:
`install.sh` reinstala a coleção inteira, e cada autor continua dono do que fez.

Os consertos que eu fiz nesses temas **não se perdem**, porque viraram script em
vez de arquivo copiado. Depois de reinstalar, `corrige-temas.sh` reaplica tudo.

## Os dois defeitos que o corretor conserta

Nenhum dos dois é gosto. São temas que **erram ao carregar**.

### Sintaxe morta do Hyprland

```
windowrulev2 = bordercolor $love,fullscreen:1        # removido do Hyprland
windowrule = border_color $love, match:fullscreen 1  # forma viva
```

Achei em 9 dos 113. Tema com a linha velha cospe erro toda vez que é aplicado.

O corretor **ancora no início da linha**: linha comentada (`#windowrulev2 = ...`)
não conta como defeito. Sem essa âncora ele relatava conserto pra sempre em tema
que só tinha a linha comentada, e deixava de ser idempotente. E ele só converte a
forma exata acima; outras variantes de `bordercolor` (duas cores, `class:`) ficam
intocadas de propósito, porque converter no escuro faria estrago maior que o
defeito.

### Chaves de cor faltando no `colors.toml`

O template `kitty.conf.tpl` do Omarchy espera `color0` até `color15`, `cursor`,
`selection_background` e `selection_foreground`. Faltando qualquer uma, o template
gera `{{ }}` sem substituir e **o kitty falha ao carregar**. Aconteceu no
`midnight`.

O corretor preenche essas chaves como alias das cores que o tema já define —
mesmos valores, só renomeados. Se o tema não tiver nem o conjunto básico
(`black` a `white`), ele não inventa nada e passa reto.

## Patches de gosto (opcionais)

`patches/harbor.patch` e `patches/lakes-and-light.patch` são ajuste de contraste
meu, não conserto. Ficam separados e o `install.sh` só aplica com `--patches`.

## Arquivos

| Arquivo | O que é |
|---|---|
| `corrige-temas.sh` | O corretor. Idempotente, tem `-n` pra dry run, aceita uma pasta só |
| `temas.tsv` | 113 linhas: `slug` + URL de origem (`(local)` no que é meu) |
| `patches/*.patch` | Ajuste de contraste meu em dois temas, opcional |
| `files/stellarum/` | Tema meu, feito aqui |
| `files/branding/screensaver.txt` | Wordmark que a tela de descanso desenha, na fonte figlet `Delta Corps Priest 1`, a mesma do logo do Omarchy |

## Depende de

- `omarchy-theme-install` e `omarchy-theme-set`, que vêm do Omarchy.
- `git`, pra clonar os temas.

## Testar

```bash
./corrige-temas.sh -n            # lista o que mudaria, sem tocar em nada
./corrige-temas.sh               # aplica
./corrige-temas.sh -n            # tem que dizer "Nada a corrigir"

# num tema só
./corrige-temas.sh ~/.config/omarchy/themes/night-owl
```

Teste do defeito de verdade, num tema de mentira:

```bash
mkdir -p /tmp/t/fake
printf 'windowrulev2 = bordercolor $love,fullscreen:1\n' > /tmp/t/fake/hyprland.conf
./corrige-temas.sh /tmp/t/fake
cat /tmp/t/fake/hyprland.conf   # windowrule = border_color $love, match:fullscreen 1
./corrige-temas.sh /tmp/t/fake  # Nada a corrigir
```
