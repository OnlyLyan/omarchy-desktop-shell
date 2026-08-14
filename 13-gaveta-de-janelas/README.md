# 13 | Gaveta de janelas

Guarda uma janela fora do caminho sem fechar ela. Diferente de minimizar: a janela
guardada **some da taskbar e do Alt+Tab**, e a gaveta vira o único caminho de volta
até ela. Serve pra limpar a área antes de jogar, ou pra tirar da frente uma janela
que você quer manter aberta mas não quer ver.

Guardar é um clique no botão azul da barra de título. Tirar é um clique na
miniatura, dentro da gaveta.

## Como funciona

Guardar move a janela pro workspace especial `special:gav-<endereço>`, um por
janela, e só isso. **Nada é feito com o processo.** Ver "A v1 hibernava processo"
abaixo.

A lista de guardadas é derivada de `Hyprland.toplevels`, filtrando quem está em
workspace `special:gav*`. É reativa: o Hyprland avisa, não há sondagem. O arquivo
`/tmp/gaveta-windows` guarda **só** o workspace de origem de cada endereço, pra
saber pra onde devolver; ele nunca é a fonte da verdade sobre o que está guardado.

A UI é uma janela layer-shell em tela cheia com o card à direita. O card cresce
com o conteúdo até 80% da tela e rola depois disso, e tem um modo compacto
(chevron no cabeçalho) que troca as miniaturas por linhas de ícone + título.

### Por que não tem atalho

Nesta máquina **nenhum bind de mouse do Hyprland dispara**, nem o
`bindm = SUPER, mouse:272, movewindow` que vem de fábrica no Omarchy. Medido:
bind de teclado com `exec` dispara, bind de mouse não, com o hyprbars como único
plugin carregado. O gatilho virou um quarto botão do hyprbars, que também é o que
o dono do repo queria de qualquer jeito ("odeio atalhos").

`gaveta.sh gesto` continua no script e volta a funcionar recolocando a linha em
`bindings.conf`, se o bug do compositor for resolvido um dia.

## Armadilhas

Todas custaram caro, estão comentadas no código, e estão aqui pra você não
repetir.

### A v1 hibernava processo, e isso destruiu uma sessão

A primeira versão mandava `SIGSTOP` nos descendentes da janela pra "hibernar" de
verdade. Ela congelou um `kitty` rodando uma sessão de agente de IA com conexão
de rede em voo, e a sessão voltou morta. **Conexão em voo não sobrevive a
SIGSTOP.**

Esta versão não manda sinal nenhum. E a economia existe assim mesmo: cliente
Wayland que não está sendo mostrado para de receber frame callback e para de
desenhar sozinho. Medido, 10 segundos: kitty guardado 0 ticks de CPU, kitty
visível 6 ticks. É hibernação de renderização, de graça e sem risco.

### `HyprlandToplevel.address` vem sem o `0x`

O `hyprctl clients -j` devolve `0x55d14e9508b0`. O `HyprlandToplevel` do
Quickshell devolve `55d14e9508b0`, sem prefixo. E o Hyprland **ignora em silêncio**
um `address:` sem prefixo: o dispatch retorna `ok` e a janela não se mexe.

Misturar os dois formatos deixou a gaveta com porta de mão única, guardava e não
devolvia, sem erro nenhum em lugar nenhum. Tudo que atravessa a fronteira
QML ↔ script passa por `_ende()`.

### Um special workspace por janela, nunca compartilhado

Focar qualquer janela de um workspace especial revela o workspace **inteiro** no
monitor em foco. Com todas as guardadas num `special:gaveta` único, tirar uma
despejaria todas de uma vez. Daí o `special:gav-<endereço>`.

### Duas janelas layer-shell na mesma camada brigam pelo z-order

O painel começou como duas janelas: um apanhador de clique em tela cheia e o card.
O apanhador ganha o z-order e engole **todos** os cliques do card: a gaveta abria
e nada mais respondia na tela inteira. É uma janela só, com o fundo e o card
dentro, e uma `MouseArea` no card que absorve o clique pra o fundo não fechar
antes da ação acontecer.

### Casar janela por título não funciona

A taskbar precisa esconder a janela guardada. Casar por `(classe, título)` tem
dois furos: duas janelas do mesmo app com o mesmo título somem juntas, e janela
que muda de título sozinha (terminal com agente de IA faz isso o tempo todo)
reaparece na barra segundos depois. `HyprlandToplevel` liga `address` a `wayland`,
então dá pra comparar por **identidade de objeto**.

### Janela guardada tem que sair do Alt+Tab e do clique da taskbar

Se não sair, focar ela traz o overlay do workspace especial e trava a tela com o
desktop apagado atrás. Vale pro `attBuildList` do `shell.qml` **e** pro
`taskbar-activate.sh` da pasta 06, que casa por classe sobre todos os clients.

### `ListModel.get()` invalida no `remove()`

Ler qualquer campo da referência depois de remover a linha devolve `undefined`.
Copie o que precisa pra variável antes.

### `ScreencopyView` leva o alfa da janela capturada pro painel

Janela com transparência (kitty com `background_opacity`) vira buraco, e a
miniatura mostra o que está **atrás** da gaveta. Fundo opaco atrás não resolve:
precisa de `layer.enabled: true` no retângulo que embrulha os dois, pra se
comporem num buffer próprio antes de ir pro painel. Efeito colateral: `layer`
desenha em textura própria sem recorte do pai, então o raio dos cantos tem que
ser do próprio retângulo.

## A gaveta não pode falhar em silêncio

Como a janela guardada some da taskbar, se a gaveta falhar a janela some do mundo.
Três garantias:

1. A verdade vem do Hyprland, nunca de arquivo. Janela morta não aparece, logo
   não vira slot fantasma.
2. Janela guardada que morre sozinha dispara `notify-send`. Silêncio ali é o pior
   caso possível.
3. Rede de segurança por terminal, sem UI nenhuma:
   `gaveta.sh listar`, `gaveta.sh tirar-tudo`, e as IPC
   `quickshell ipc call gaveta {abrir,fechar,tirarPrimeira,tudo,compactar}`.

## Arquivos

| Arquivo | Vai pra | O que é |
|---|---|---|
| `files/GavetaPanel.qml` | `~/.config/quickshell/` | UI e estado. Instanciado pelo `shell.qml` da pasta 06 |
| `files/scripts/gaveta.sh` | `~/.config/quickshell/scripts/` | Camada de sistema: mover de workspace, store, e o `botao` que o hyprbars chama |

## Depende de

- Pasta **06** (`shell.qml` instancia `GavetaPanel {}` e desenha o ícone da
  gaveta na taskbar). Sem ela isto não sobe.
- Pasta **05** (hyprbars), pro botão azul na barra de título.
- `jq`, `hyprctl`, e o binário `quickshell` no PATH.

## Testar

```bash
# sobe uma janela de teste e guarda por fora da UI
hyprctl dispatch exec "[float;size 600 350] kitty --title teste -- sleep 300"
A=$(hyprctl clients -j | jq -r '.[]|select(.title=="teste")|.address')
~/.config/quickshell/scripts/gaveta.sh guardar "$A"

~/.config/quickshell/scripts/gaveta.sh listar   # tem que listar o endereço
hyprctl clients -j | jq -r --arg a "$A" '.[]|select(.address==$a)|.workspace.name'
# esperado: special:gav-<endereço sem 0x>

# a janela sumiu da taskbar? e o ícone da gaveta ganhou uma bolinha?

# volta pelo caminho do MODELO, o mesmo do clique na miniatura
quickshell ipc call gaveta tirarPrimeira
hyprctl dispatch closewindow "address:$A"
```

Teste que importa, e que a v1 reprovava: guarde um terminal com uma sessão viva
de agente de IA, tire de volta, e mande uma mensagem. Tem que responder.
`ps -o stat= -p <pid>` não pode mostrar `T`.
