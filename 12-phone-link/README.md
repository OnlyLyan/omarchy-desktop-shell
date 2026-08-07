# 12 | Phone Link | daemon proprio de conexao com o celular

Daemon (`phoned`) e CLI (`phonectl`) que conectam o PC ao celular Android pela rede local:
descoberta por broadcast UDP, canal TCP com TLS 1.3 e pareamento por comparacao visual de
um codigo de 6 caracteres. Esta e a **fatia 1**: entrega so o transporte. Sem notificacao,
sem transferencia de arquivo, sem UI em QML, e o app Android ainda nao existe. A fatia 2
consome o contrato de IPC documentado aqui para desenhar o painel na barra (pasta 06).

## Por que nao KDE Connect

O KDE Connect resolve o mesmo problema, mas acopla a stack a bibliotecas do KDE (kdeconnectd,
kpeople, o plugin do Plasma) que nao tem lugar natural numa shell Quickshell/Hyprland. A fatia
seguinte, transferencia de arquivo com progresso e cancelamento, precisa de controle fino sobre
o canal e o protocolo, algo mais simples de manter num daemon proprio pequeno do que de dobrar
por cima de um protocolo de terceiro. `phoned` fala um protocolo de linha JSON desenhado para
isto, sem dependencia alem da stdlib do Python e do binario `openssl`.

## Por que o daemon e um processo separado do `qsbar`

A barra (pasta 06) roda dentro do Quickshell, e a tentacao natural seria fazer tudo em QML. Nao
da: `Quickshell.Io` so oferece `Socket` (unix, local) e `Process` (subprocesso), sem `UDP` e sem
`TLS`. Descoberta na rede precisa de broadcast UDP, e o canal com o celular precisa de TLS. Sem
os dois, o pareamento seguro e a descoberta automatica simplesmente nao existem em QML puro.
Verificado direto na documentacao do Quickshell em 2026-08-07. Por isso o transporte vive num
processo Python separado, e o QML da fatia 2 fala com ele por um unix socket local (`Socket` do
Quickshell.Io serve bem para isso).

## Como funciona

- **Descoberta**: `phoned` faz broadcast UDP na porta `1739` a cada 60s (`identity`, com
  `device_id`, nome, porta TCP e versao do protocolo) e escuta a mesma porta. Broadcast em vez de
  mDNS: uma dependencia a menos, funciona em rede domestica sem avahi configurado.
- **Canal**: TCP com TLS 1.3 (`ssl.PROTOCOL_TLS_SERVER`/`CLIENT`, `minimum_version` travado em
  `TLSv1_3`). A confianca e por *fingerprint* do certificado (SHA-256 do DER), nao por cadeia nem
  por nome de host: cada aparelho gera seu proprio certificado autoassinado com `openssl req -x509`
  na primeira subida.
- **Pareamento**: quando os dois lados trocam certificado, calculam o mesmo `pair_code`, um hash
  de 6 caracteres derivado dos dois fingerprints ordenados (por isso da o mesmo codigo nos dois
  aparelhos, nao importa quem iniciou). O usuario confere visualmente que os dois mostram o mesmo
  codigo e confirma dos dois lados. So depois disso o aparelho vira confiavel e o gate de
  pareamento libera qualquer pacote que nao seja `pair.*`. Quando quem pede o pareamento e o lado
  que **recebeu** a conexao, o codigo desse lado so aparece depois que o outro aceita: e o
  `pair.accept` que traz o certificado dele. Nesse sentido o `pair.prompt` chega mais tarde de um
  lado que do outro, e confirmar antes de ver o codigo e recusado de proposito.
- **Protocolo de linha**: cada pacote e uma linha JSON UTF-8 com `id`, `type`, `ts` e `body`,
  terminada em `\n`, com limite de 1 MiB por linha. Mesmo formato no socket TCP (rede) e no unix
  socket (IPC local): um serializador so, `phoned/protocol.py`.

## O handshake e a assimetria do certificado

Verificado com o proprio modulo `ssl` da stdlib: um servidor que ainda nao confia em ninguem nao
pode **exigir** certificado de cliente, entao no primeiro contato ele simplesmente nao recebe
nenhum (`ssl.CERT_NONE`). Por isso o `pair.request` carrega o certificado do requisitante *dentro
do corpo do pacote JSON*, em vez de depender do handshake TLS para entrega-lo: e o unico jeito de
o outro lado enxergar o certificado antes de existir qualquer razao para confiar nele. A seguranca
do pareamento nao vem do TLS nessa etapa, vem da comparacao visual do codigo de 6 caracteres pelo
usuario. So depois que os dois aceitam e que o certificado entra para a lista de confiaveis
(`devices.json`).

A partir dai o certificado de cliente passa a ser pedido (`ssl.CERT_OPTIONAL`) **na mesma hora**,
sem esperar reinicio: o contexto TLS do listener e atualizado toda vez que o `devices.json` muda,
no pareamento e no `unpair`. Mutar o `SSLContext` que ja esta servindo vale para as conexoes
seguintes, medido nesta maquina com Python 3.14.6. Sem isso o listener ficava com a foto tirada
na subida, e o aparelho recem pareado que reconectasse de fora era recusado com `consta pareado
mas nao apresentou certificado` em toda tentativa, ate o daemon reiniciar.

Mesmo sentido do outro lado: **o certificado so e apresentado a um par que ja esta no
`devices.json`**. `load_cert_chain` nao envia nada sozinho, o certificado so sai se o servidor
pedir, entao carregar a cadeia e decidir apresenta-la. Apresentar a quem ainda nao te conhece
derruba o handshake dentro do OpenSSL, sem log em nenhum dos dois lados, e era assim que um
aparelho ja pareado com outra maquina ficava impedido de parear aqui. **Esta e uma regra do
protocolo, e o app Android da fatia 2 precisa segui-la tambem.**

Limitacao conhecida: o `phonectl connect <ip>` manual nao sabe com quem esta falando antes de
conectar, entao usa o palpite "havendo algum pareamento, provavelmente estou rediscando para
ele", e apresenta o certificado. Parear um aparelho *novo* numa rede que bloqueia broadcast,
tendo ja outro aparelho pareado, nao funciona por esse caminho. Pela descoberta funciona, porque
ai o `device_id` do outro lado e conhecido antes do handshake.

## Arquivos

- `files/phoned/` -> `~/.local/lib/phone/phoned` (o pacote Python: `config`, `protocol`,
  `discovery`, `pairing`, `transport`, `ipc`, `daemon`, `__main__`).
- `files/phonectl` -> `~/.local/bin/phonectl` (CLI; fala o mesmo protocolo de linha do QML da
  fatia 2, sem importar o pacote `phoned`, de proposito, para manter o contrato de IPC honesto).
- `files/phoned.service` -> `~/.config/systemd/user/phoned.service` (unit systemd, com
  endurecimento: `ProtectSystem=strict`, `ProtectHome=read-only`, `NoNewPrivileges`, etc.)
- `files/tests/` -> suite de 112 testes (`pytest` + `pytest-asyncio`), inclusive um teste de
  integracao ponta a ponta com dois daemons completos em loopback (`test_integracao_loopback.py`),
  que faz o papel do celular real enquanto o app Android nao existe.

## Instalar

```bash
cd 12-phone-link && ./install.sh
```

O instalador e idempotente: reescreve o pacote inteiro em `~/.local/lib/phone/phoned` (sem deixar
sobra de versao antiga), reescreve a unit do zero a cada execucao (nunca anexa linha) e usa
`systemctl --user enable --now`, que tambem e idempotente. Rodar de novo nao duplica nada.

Antes de habilitar a unit, o instalador cria `~/.local/state/phone` e
`$XDG_RUNTIME_DIR/phone` (ambos listados em `ReadWritePaths` da unit). Isso e necessario porque
`ReadWritePaths` do systemd exige que o caminho ja exista no host antes do primeiro start: se nao
existir, o `systemctl start` falha na hora com "Failed to set up mount namespacing", antes mesmo de
o processo Python rodar (confirmado empiricamente com `systemd-run --user` de teste). O proprio
`phoned` tambem cria os dois diretorios ao subir, mas essa criacao acontece de dentro do processo,
tarde demais para a montagem do namespace.

## `phonectl`

```bash
$ phonectl list
Nenhum aparelho conhecido ainda.

$ phonectl list        # com um aparelho pareado e conectado
celular  a1b2c3d4-e5f6-47a8-9b0c-111111111111  conectado  pareado  192.168.0.42

$ phonectl pair a1b2c3d4-e5f6-47a8-9b0c-111111111111
ok

$ phonectl confirm a1b2c3d4-e5f6-47a8-9b0c-111111111111
ok

$ phonectl confirm a1b2c3d4-e5f6-47a8-9b0c-111111111111 --reject
ok

$ phonectl unpair a1b2c3d4-e5f6-47a8-9b0c-111111111111
ok

$ phonectl ping a1b2c3d4-e5f6-47a8-9b0c-111111111111
pong em 12.5 ms

$ phonectl ping a1b2c3d4-e5f6-47a8-9b0c-111111111111   # aparelho offline
phonectl: sem resposta do aparelho          # sai com codigo 1

$ phonectl connect 192.168.0.42 --port 1739    # conexao manual, para rede sem broadcast
ok

$ phonectl watch    # acompanha os eventos do daemon em tempo real
device.state: {"device_id": "a1b2...", "state": "connected", "paired": true, ...}

$ phonectl list      # com o daemon parado
phonectl: nao consegui falar com o phoned. Ele esta rodando? Tente: systemctl --user status phoned
# sai com codigo 1
```

## O contrato do IPC (unix socket)

Esta secao e o que a fatia 2 (painel QML na barra) vai consumir. O socket fica em
`$XDG_RUNTIME_DIR/phone/ipc.sock`, permissao `0600`. Cada linha e um pacote JSON completo,
`{"id", "type", "ts", "body"}` (mesmo formato de `phoned/protocol.py`).

### Comandos (cliente envia, daemon responde no mesmo tipo + `.result`)

| Comando | Corpo do pedido | Tipo da resposta | Corpo da resposta |
|---------|------------------|-------------------|---------------------|
| `list` | `{}` | `list.result` | `{"devices": [...], "request_id": "..."}` |
| `pair` | `{"device_id": "..."}` | `pair.result` | `{"ok": true, "request_id": "..."}` |
| `confirm` | `{"device_id": "...", "accept": true}` | `confirm.result` | `{"ok": true, "request_id": "..."}` |
| `unpair` | `{"device_id": "..."}` | `unpair.result` | `{"ok": true, "request_id": "..."}` |
| `ping` | `{"device_id": "..."}` | `ping.result` | `{"latency_ms": 12.5, "request_id": "..."}` |
| `connect` | `{"host": "...", "port": 1739}` | `connect.result` | `{"ok": true, "request_id": "..."}` |

Uma linha de pedido e resposta por comando, para copiar direto:

`list`:
```json
{"id":"1f0a...","type":"list","ts":1754591000,"body":{}}
{"id":"...","type":"list.result","ts":1754591000,"body":{"devices":[{"device_id":"a1b2c3d4-e5f6-47a8-9b0c-111111111111","name":"Pixel do Lucas","paired":true,"connected":true,"address":"192.168.0.42"}],"request_id":"1f0a..."}}
```

`pair`:
```json
{"id":"3f1e6c02-8b1a-4b1e-9c3a-000000000001","type":"pair","ts":1754591000,"body":{"device_id":"a1b2c3d4-e5f6-47a8-9b0c-111111111111"}}
{"id":"7d2a9e10-...","type":"pair.result","ts":1754591000,"body":{"ok":true,"request_id":"3f1e6c02-8b1a-4b1e-9c3a-000000000001"}}
```

`confirm`:
```json
{"id":"2b3c...","type":"confirm","ts":1754591020,"body":{"device_id":"a1b2c3d4-e5f6-47a8-9b0c-111111111111","accept":true}}
{"id":"...","type":"confirm.result","ts":1754591020,"body":{"ok":true,"request_id":"2b3c..."}}
```

`unpair`:
```json
{"id":"9a1d...","type":"unpair","ts":1754591030,"body":{"device_id":"a1b2c3d4-e5f6-47a8-9b0c-111111111111"}}
{"id":"...","type":"unpair.result","ts":1754591030,"body":{"ok":true,"request_id":"9a1d..."}}
```

`ping`:
```json
{"id":"5e6f...","type":"ping","ts":1754591040,"body":{"device_id":"a1b2c3d4-e5f6-47a8-9b0c-111111111111"}}
{"id":"...","type":"ping.result","ts":1754591040,"body":{"latency_ms":12.5,"request_id":"5e6f..."}}
```

`connect`:
```json
{"id":"7c8d...","type":"connect","ts":1754591050,"body":{"host":"192.168.0.42","port":1739}}
{"id":"...","type":"connect.result","ts":1754591050,"body":{"ok":true,"request_id":"7c8d..."}}
```

Pedido malformado ou comando que estourou excecao vira `error`:
```json
{"id":"...","type":"error","ts":1754591000,"body":{"message":"comando desconhecido: xyz","request_id":"3f1e6c02-..."}}
```

### Eventos (daemon empurra sem pedido, para todo cliente conectado)

| Tipo | Quando | Corpo |
|------|--------|-------|
| `device.state` | Aparelho conecta ou desconecta | `{"device_id", "state": "connected" ou "disconnected", "name"?, "address"?, "paired"?}` |
| `pair.prompt` | Pareamento comecou, codigo pronto para exibir | `{"device_id", "name", "code": "4F0C2A"}` |
| `pair.result` | Pareamento terminou (aceito, recusado ou expirou) | `{"device_id", "accepted": true ou false, "reason"?}` |
| `pong` | Daemon recebeu `PONG` do aparelho (inclusive do heartbeat periodico, nao so de `phonectl ping`) | `{"device_id", "echo_id"}` |

Uma linha de exemplo por evento:

`device.state`:
```json
{"id":"...","type":"device.state","ts":1754591005,"body":{"device_id":"a1b2c3d4-e5f6-47a8-9b0c-111111111111","name":"Pixel do Lucas","address":"192.168.0.42","paired":false,"state":"connected"}}
```

`pair.prompt`:
```json
{"id":"...","type":"pair.prompt","ts":1754591010,"body":{"device_id":"a1b2c3d4-...","name":"Pixel do Lucas","code":"4F0C2A"}}
```

`pair.result` (evento, nao a resposta do comando; note a ausencia de `request_id`, ver a secao
seguinte):
```json
{"id":"...","type":"pair.result","ts":1754591015,"body":{"device_id":"a1b2c3d4-e5f6-47a8-9b0c-111111111111","accepted":true}}
```

`pong`:
```json
{"id":"...","type":"pong","ts":1754591045,"body":{"device_id":"a1b2c3d4-e5f6-47a8-9b0c-111111111111","echo_id":"5e6f..."}}
```

### A armadilha do `pair.result`: correlacione por `request_id`, nunca so pelo `type`

`pair.result` e ao mesmo tempo **a resposta direta** do comando `pair` (com `request_id` igual ao
`id` do pedido) e **um evento de broadcast**, empurrado para *todos* os clientes conectados quando
qualquer pareamento em andamento no daemon termina, o meu ou o de outro cliente. Os dois usam o
mesmo `type`. Um cliente que filtrar so por `resposta["type"] == "pair.result"` pode ler o
pareamento alheio expirando como se fosse a resposta do seu proprio pedido: os corpos ate parecem
compativeis (`accepted` versus `ok`), o que torna o erro silencioso em vez de uma excecao.

Isto foi um bug real desta fatia, encontrado em revisao e corrigido antes do fechamento (fatia 1,
Task 11). A correcao, em `phonectl.pergunta()`:

```python
if resposta["body"].get("request_id") == meu_id:
    return resposta
```

Todo cliente do IPC, inclusive o QML da fatia 2, precisa fazer a mesma correlacao: ignore
qualquer pacote cujo `body.request_id` nao seja o `id` que voce mesmo gerou, exceto `error` sem
`request_id` nenhum (esse so acontece quando o daemon nao conseguiu nem ler o seu pacote, e nunca
vem por broadcast).

## Testes

```bash
cd files && python -m pytest tests/ -v
```

112 testes, incluindo `test_integracao_loopback.py`, que sobe dois daemons completos no mesmo
host (dois `state_dir`/`runtime_dir` distintos) e faz descoberta, pareamento e canal TLS ponta a
ponta por loopback. E o substituto do celular real enquanto o app Android nao existe: cobre
exatamente os mesmos caminhos de codigo que uma conexao de verdade exerceria.

## Onde fica o estado, e como resetar tudo

- `~/.local/state/phone/` | certificado (`cert.pem`, `key.pem`), `device_id` e a lista de
  aparelhos confiaveis (`devices.json`). Diretorio `0700`, chave privada `0600`.
- `$XDG_RUNTIME_DIR/phone/ipc.sock` | o socket do IPC, recriado a cada subida.

Para resetar tudo (esquecer todos os pareamentos e gerar identidade nova):
```bash
systemctl --user stop phoned && rm -rf ~/.local/state/phone
```
Na proxima subida o daemon gera `device_id`, certificado e chave novos, e a lista de aparelhos
confiaveis comeca vazia de novo.

## Dependencias

- **Runtime**: `python3` (stdlib basta: `asyncio`, `ssl`, `json`, `hashlib`, `uuid`) e o binario
  `openssl` (usado via `subprocess` para gerar o certificado; nao ha dependencia de biblioteca de
  criptografia em Python, de proposito, para manter o daemon com dependencia zero fora da stdlib).
- **So para desenvolver**: `python-pytest` e `python-pytest-asyncio`, para rodar a suite. Nenhum
  dos dois entra no que o `install.sh` copia para `~/.local/lib/phone`.

## Depende de

Nada da pasta 06 nesta fatia. `phoned` e `phonectl` sao standalone: descoberta, pareamento e canal
TLS funcionam sem a barra rodando. A integracao visual (icone de status, painel de pareamento,
notificacao de codigo) chega na fatia 2, quando o QML da barra passa a falar com o unix socket
documentado acima.
