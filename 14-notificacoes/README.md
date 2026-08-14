# 14 | Notificações no Quickshell

Substitui o `mako` por notificações desenhadas na própria barra. Pílula compacta
no canto, no mesmo desenho da taskbar: ícone do app, título curto, e um chevron
que abre o corpo inteiro da mensagem. Clicar na pílula leva pra janela de origem.

Três modos, ciclados pelo sino da barra ou por `SUPER+CTRL+vírgula`:

| Modo | O que faz |
|---|---|
| normal | pílula + som |
| discreto | só o ícone do app pisca na taskbar, sem pílula e sem som |
| não perturbe | nada aparece; tudo vai pro histórico |

![Notificacao em pilula](../docs/img/04-notificacao.png)


## Como funciona

`NotificationServer` do Quickshell registra o serviço
`org.freedesktop.Notifications` no D-Bus e recebe as notificações direto, sem
daemon externo. As pílulas ficam em duas pilhas separadas, normais e críticas,
cada uma numa `PanelWindow` de camada FIXA.

O histórico fica na central de ações, com hora e um X por item.

## Armadilhas

### O mako volta sozinho, mesmo depois de morto

Ele é ativado por D-Bus. `pkill mako` resolve por um minuto e ele reaparece na
primeira notificação. Precisa de `systemctl --user mask mako.service`, e o hook
de boot aqui garante que ele não suba junto com a sessão.

Dois servidores registrados ao mesmo tempo = notificação dobrada ou nenhuma.

### `ListModel`, nunca array trocado

A primeira versão guardava as pílulas num array e reatribuía o array a cada
mudança. Isso **recria todos os delegates**, e o resultado foi uma sequência de
falhas que pareciam não ter relação entre si:

- `RangeError: Maximum call stack size exceeded` em rajada de notificações
- pílula que nunca expirava, porque cada delegate tinha seu `Timer` e ele
  reiniciava a cada troca de array
- pílula que não desenhava
- botão X morto

Com `ListModel` e mutação item a item (`append`, `remove`, `setProperty`), os
delegates sobrevivem e nada disso acontece. **Não troque o array.**

### `required property` dentro de `component` inline não propaga

Num `component PilhaNotif: PanelWindow`, declarar `required property var modelo`
faz a atualização do binding não chegar: a lista chega vazia e nada desenha. Use
`property var modelo: null` normal.

### Um relógio só, com timestamp absoluto

`Timer` por delegate não sobrevive a rajada. Um `Timer` de 500ms na raiz mais um
`expiraEm` absoluto por item resolve, e o custo não cresce com a quantidade.

### O objeto da notificação morre antes da UI

Chamar `dismiss()` num objeto já destruído dá `dismiss is not a function` e o X
fica morto. A lista da UI é a autoridade: remove do modelo **primeiro**, depois
tenta `dismiss()` dentro de `try/catch`.

As ações vêm congeladas na chegada (`acoesTxt`/`acoesId` juntadas com separador
``), porque o objeto pode sumir antes de você clicar.

### `Region { item: X }` exige item com tamanho explícito

Apontar a máscara pro `ColumnLayout` devolve região vazia, e aí **nada** recebe
clique: o X e o chevron ficam mortos. Máscara por coordenada.

### A máscara come clique no que está atrás

A janela da pílula é maior que a pílula. Se a máscara cobrir a janela inteira, a
faixa vazia de cima engole clique nos botões da barra de título que estão atrás
dela. Descer a pílula com `topMargin` resolve só o visual: a máscara tem que
começar onde a pílula começa.

### Pílula com largura fixa fica centralizada, não à direita

Filho de `ColumnLayout` sem `fillWidth` é **centralizado** por padrão. Com
`Layout.preferredWidth` fixo, mexer na margem direita só desloca a pílula pela
metade. Precisa de `Layout.alignment: Qt.AlignRight`.

### Ícone: `image-path` antes de `app_icon`

Muito app manda o ícone real no hint `image-path` e deixa `app_icon` vazio ou com
um nome genérico. Ler só `app_icon` deixa metade das notificações sem ícone.

## Arquivos

| Arquivo | Vai pra | O que é |
|---|---|---|
| `files/NotificationPanel.qml` | `~/.config/quickshell/` | Servidor, pilhas, histórico e modos. Instanciado pelo `shell.qml` da pasta 06 |
| `files/notif-toggle-dnd` | `~/.local/bin/` | Cicla os três modos; é o que o bind e o sino chamam |
| `files/10-stop-mako` | `~/.config/omarchy/hooks/post-boot.d/` | Garante que o mako não suba junto com a sessão |

## Depende de

- Pasta **06** (o `shell.qml` instancia `NotificationPanel {}`, desenha o sino, o
  badge por app na taskbar e o histórico na central).
- `systemctl --user mask mako.service`, feito pelo `install.sh`.

## Testar

```bash
notify-send -a "Teste" "Título" "corpo da mensagem"      # pílula aparece e some sozinha
notify-send -a "Teste" -u critical "Crítica" "não expira"

~/.local/bin/notif-toggle-dnd                            # cicla o modo
notify-send -a "Teste" "Deve sumir no modo dnd" "..."

# nenhum outro servidor registrado?
busctl --user list | grep -i notification    # so pode aparecer o quickshell
systemctl --user is-enabled mako.service     # tem que dizer masked
```
