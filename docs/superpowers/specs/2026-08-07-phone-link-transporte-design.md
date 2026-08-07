# Phone Link, fatia 1: transporte

Data: 2026-08-07
Status: aprovado, pronto para planejamento
Escopo: fatia 1 de 4

## Objetivo

Ligar o PC (Omarchy, Arch, Hyprland, Wayland) a um celular Android na mesma rede WiFi,
com descoberta automática, pareamento confirmado pelo usuário e canal seguro persistente.
Ao final da fatia, os dois aparelhos se enxergam, pareiam e trocam ping e pong de forma
estável, incluindo reconexão automática.

Inspiração de arquitetura: KDE Connect. Implementação: própria, sem reaproveitar código
nem protocolo dele. A razão é liberdade para as fatias seguintes (arquivos, clipboard,
mídia) sem ficar preso ao formato e às limitações de um projeto acoplado ao KDE.

## Decomposição do projeto

Este spec cobre apenas a fatia 1. As demais terão spec próprio.

| Fatia | Conteúdo |
|-------|----------|
| 1 | Transporte: descoberta, pareamento, TLS, protocolo de pacotes, IPC local |
| 2 | Notificações: `NotificationListenerService` no Android, entrega no PC, card no Quickshell, dispensa bidirecional |
| 3 | Arquivos: enviar e receber com progresso |
| 4 | Extras: clipboard compartilhado, bateria, achar o celular, controle de mídia |

## Restrições do ambiente

Verificadas no sistema em 2026-08-07:

- `Quickshell.Io` expõe apenas `Socket`, `SocketServer` (unix socket) e `Process`.
  Não há UDP nem TLS. Portanto a rede **não pode** viver dentro do processo `qsbar`.
- Padrão do repositório: cada componente é uma pasta numerada com `README.md`, `files/`
  e `install.sh` idempotente. A fatia 1 segue esse padrão.
- Notificações do desktop hoje passam por mako. Relevante só a partir da fatia 2.

## Arquitetura

Quatro unidades com fronteira explícita:

1. **`phoned`**: daemon Python com asyncio, rodando como systemd user service.
   Única unidade que fala rede.
2. **`phonectl`**: CLI. Conversa apenas pelo unix socket. Zero lógica de rede.
3. **App Android**: Kotlin, foreground service, mesmo protocolo do outro lado.
4. **Estado**: `~/.local/state/phone/` com `cert.pem`, `key.pem`, `devices.json`.

Nenhuma unidade consulta a rede para saber estado. Todo estado passa pelo daemon.

### Módulos internos do `phoned`

Cada um com uma responsabilidade e testável isoladamente:

| Módulo | Faz | Depende de |
|--------|-----|------------|
| `protocol` | Serializa, desserializa e valida pacote. Funções puras. | nada |
| `pairing` | Certificados, fingerprint, código de confirmação, `devices.json` | `protocol` |
| `discovery` | Broadcast e escuta UDP | `protocol` |
| `transport` | TCP, TLS, ciclo de vida da sessão, heartbeat, reconexão | `protocol`, `pairing` |
| `ipc` | Unix socket para `phonectl` e, na fatia 2, para o QML | `protocol` |
| `__main__` | Sobe tudo, carrega config, trata sinais | todos |

Critério de fronteira: `protocol` e `pairing` não sabem o que é socket. `transport` e
`discovery` não sabem o que é UI. `ipc` não sabe o que é rede remota.

## Descoberta

Porta **1739**, UDP e TCP. Escolhida para não colidir com a 1716 do KDE Connect, caso ele
seja instalado em paralelo para comparação.

Cada lado envia broadcast UDP para `255.255.255.255:1739` ao iniciar e a cada 60 segundos,
com o pacote de identidade:

```json
{
  "id": "<uuid>",
  "type": "identity",
  "ts": 1754500000,
  "body": {
    "device_id": "<uuid fixo, gerado uma vez>",
    "name": "lucas-pc",
    "device_type": "desktop",
    "port": 1739,
    "protocol_version": 1,
    "capabilities": ["ping"]
  }
}
```

Quem recebe identidade de um aparelho que não está conectado abre TCP para o IP de origem
na porta anunciada.

Broadcast em vez de mDNS por decisão explícita: uma dependência a menos e funciona em rede
doméstica sem avahi configurado. Para redes que bloqueiam broadcast, existe o escape manual
`phonectl connect <ip>`, que injeta o endereço direto no `transport` sem passar por
`discovery`.

## Canal seguro

Quem abre a conexão TCP é o cliente TLS. Ambos usam certificado auto-assinado gerado na
primeira execução, curva P-256, validade de 10 anos, com `CA:TRUE`, o que permite que o
certificado sirva de âncora de confiança de si mesmo.

A verificação de cadeia contra autoridade certificadora é substituída por comparação de
fingerprint SHA-256 contra `devices.json`. Esse é o modelo correto para confiança direta
entre dois aparelhos sem CA.

O modo do handshake depende de já haver pareamento, e a diferença foi verificada
experimentalmente com `ssl` da stdlib em 2026-08-07:

**Já pareado, autenticação mútua real.** O servidor usa `verify_mode = CERT_OPTIONAL` e
carrega os certificados pareados via `load_verify_locations(cadata=...)`. O cliente
apresenta seu certificado com `load_cert_chain`. Os dois lados obtêm o certificado do outro
por `getpeercert(binary_form=True)` e comparam o fingerprint com o armazenado. Divergência
derruba a conexão.

**Primeiro pareamento, comparação numérica.** O servidor ainda não confia em ninguém, então
usa `verify_mode = CERT_NONE` e **não** recebe certificado do cliente. O cliente, esse sim,
recebe o do servidor e já pode conferir. Para fechar o lado que falta, o cliente inclui o
próprio certificado em PEM no corpo do `pair.request`, e é dele que o servidor deriva o
código.

A segurança do primeiro pareamento vem da comparação numérica feita por você, o mesmo
princípio do numeric comparison do Bluetooth: um atacante no meio produz códigos diferentes
nos dois aparelhos, e a divergência fica visível antes de qualquer dado trafegar.

**Estado assimétrico** (um lado pareou, o outro não) faz a validação falhar e a conexão
cair, com log explícito. A saída é `phonectl unpair` e novo pareamento. É raro e preferível
a degradar silenciosamente para o modo sem autenticação.

Aparelho não pareado completa o handshake TLS, mas o daemon aceita dele **somente** pacotes
de tipo `pair.*`. Qualquer outro tipo derruba a conexão. É essa regra que impede alguém na
mesma rede de enviar dados antes da confirmação do usuário.

### Pareamento

1. Cliente envia `pair.request` com o próprio certificado em PEM no corpo. O servidor
   calcula o fingerprint do cliente a partir dele; o do servidor o cliente já obteve pelo
   próprio handshake TLS.
2. Ambos derivam o código de confirmação: os dois fingerprints são ordenados
   lexicograficamente, concatenados, passados por SHA-256, e os 6 primeiros caracteres
   hexadecimais em maiúsculo viram o código. A ordenação garante que os dois lados cheguem
   ao mesmo valor independentemente de quem iniciou.
3. Os dois aparelhos exibem o código. O usuário confirma nos dois.
4. Só então os fingerprints entram no `devices.json` e a sessão passa a aceitar todos os
   tipos de pacote.

`pair.reject` ou timeout de 60 segundos cancela o pareamento e fecha a conexão.

## Protocolo de pacotes

Uma linha JSON UTF-8 por pacote, terminada em `\n`. Limite de 1MB por linha nesta fatia.

```json
{"id":"<uuid>","type":"phone.ping","ts":1754500000,"body":{}}
```

Campos obrigatórios: `id`, `type`, `ts`, `body`. `ts` é epoch em segundos e é meramente
informativo: nenhuma decisão depende dele, o que evita quebrar quando o relógio do celular
está errado.

Tipos desta fatia:

| Tipo | Direção | Body |
|------|---------|------|
| `identity` | ambas | dados do aparelho (ver Descoberta) |
| `pair.request` | ambas | `{"certificate": "<PEM do remetente>"}` |
| `pair.accept` | ambas | `{"certificate": "<PEM do remetente>"}` |
| `pair.reject` | ambas | `{"reason": "<string>"}` |
| `phone.ping` | ambas | `{}` |
| `phone.pong` | ambas | `{"echo_id": "<id do ping>"}` |

Tipo desconhecido é ignorado e logado, nunca derruba a conexão. É essa regra que permite às
fatias seguintes adicionar tipos sem quebrar uma versão antiga do outro lado.

Heartbeat: ping a cada 30 segundos. Sessão considerada morta após 90 segundos sem resposta.
Reconexão com backoff exponencial de 1 segundo dobrando até o teto de 60 segundos.

## IPC local

Unix socket em `$XDG_RUNTIME_DIR/phone/ipc.sock`, mesmo formato de linha JSON do protocolo
de rede. Reaproveitar o formato mantém um único serializador para tudo.

Comandos aceitos: `list`, `pair <device_id>`, `unpair <device_id>`, `ping <device_id>`,
`connect <ip>`.

Eventos empurrados para todos os clientes conectados: `device.discovered`, `device.state`,
`pair.prompt`, `pair.result`, `pong`.

O card QML da fatia 2 consome exatamente esse contrato, sem exigir nada novo do daemon.

## Tratamento de erro

Princípio: o daemon nunca morre por causa de um aparelho. Falha de sessão vira log e
reconexão.

| Situação | Comportamento |
|----------|---------------|
| Aparelho sai do WiFi | Ping sem resposta em 90s, estado vira `disconnected`, broadcast continua, reconecta sozinho |
| Duas rotas para o mesmo aparelho | Dedup por `device_id`, nunca por IP. A segunda conexão para o mesmo id é fechada imediatamente |
| Fingerprint mudou (app reinstalado) | Conexão recusada com log explícito. Exige `phonectl unpair` e novo pareamento. Aceitar em silêncio anularia o propósito do pareamento |
| Linha JSON inválida ou acima de 1MB | Derruba a conexão. Sem tentativa de ressincronizar no meio do stream |
| Porta 1739 ocupada | Falha na subida com mensagem clara. Sem porta alternativa, que quebraria a descoberta |
| Socket IPC órfão de daemon morto | Removido na subida |
| `devices.json` corrompido | Falha na subida com mensagem clara indicando o arquivo. Sem recriar em silêncio, que desparearia tudo sem aviso |

## Estratégia de testes

O ponto central: o protocolo inteiro é testável sem o Android.

1. **Unitários** de `protocol` e `pairing`, que são funções puras. Cobrem serialização,
   pacote malformado, campo ausente, derivação do código de confirmação, estabilidade da
   ordenação dos fingerprints, `devices.json` ausente e corrompido.
2. **Integração loopback**: duas instâncias do `phoned` no mesmo host, em portas e
   diretórios de estado distintos, se descobrem, pareiam e trocam ping por loopback.
   Cobre descoberta, TLS, pareamento, heartbeat e reconexão em segundos, sem cabo e sem
   celular. É o que viabiliza TDD nesta fatia.
3. **Manual, uma vez ao final**: celular real no mesmo WiFi. Parear, ping, desligar o WiFi
   do celular, confirmar a reconexão automática ao religar.

O app Android desta fatia é deliberadamente mínimo: uma tela com a lista de aparelhos
descobertos, botão de parear, o código de confirmação e indicador de conectado. Nenhuma
funcionalidade de notificação.

## Entregáveis

```
12-phone-link/
  README.md              o que faz, por que, como foi feito
  install.sh             idempotente
  files/
    phoned/              pacote Python
      __main__.py
      config.py
      protocol.py
      pairing.py
      discovery.py
      transport.py
      ipc.py
    phonectl             CLI
    phoned.service       systemd user unit
    tests/
  android/               projeto Gradle, Kotlin
```

O `install.sh` instala o pacote em `~/.local/lib/phone`, o `phonectl` em `~/.local/bin`,
e habilita o systemd user service. Não toca em nada do Hyprland nem da barra: a fatia 1 é
invisível para o desktop por decisão. O acoplamento com o `qsbar` começa apenas na fatia 2.

## Ambiente de desenvolvimento

- PC: Python 3 da stdlib apenas (`asyncio`, `ssl`, `json`, `socket`, `hashlib`, `subprocess`).
  O certificado auto-assinado é gerado uma única vez, na primeira execução, chamando o
  binário `openssl` por subprocess. Decisão tomada por verificação do sistema: nem
  `python-cryptography` nem `python-pytest` estão instalados, e `openssl` está. Assim o
  runtime do daemon fica com dependência zero fora da stdlib.
- Dependência a instalar para desenvolvimento: `python-pytest`. Não é dependência de runtime.
- Android: Android Studio completo, com emulador. App instalado por sideload via `adb`,
  sem Play Store.

## Fora de escopo, explicitamente

Notificações, transferência de arquivos, clipboard, criptografia de payload além do TLS,
funcionamento fora da rede local, qualquer UI em QML, suporte a iOS.

Múltiplos aparelhos pareados **não** estão fora de escopo: `devices.json` e o dedup por
`device_id` já são plurais por construção, e restringir a um só custaria trabalho extra
em vez de economizar.

Se algum desses aparecer durante a implementação, vira fatia futura, não escopo desta.

## Critérios de sucesso

1. `phoned` sobe como systemd user service e sobrevive a reinício do PC.
2. `phonectl list` mostra o celular na mesma rede em até 60 segundos.
3. `phonectl pair <id>` exibe o mesmo código de 6 caracteres nos dois aparelhos, e a
   confirmação nos dois estabelece a sessão.
4. `phonectl ping <id>` retorna pong com latência medida.
5. Desligar e religar o WiFi do celular reconecta sozinho, sem reparear.
6. Aparelho não pareado na mesma rede não consegue enviar nada além de `pair.*`.
7. Suíte de testes verde, incluindo o teste de integração loopback.
