# Onde parou: Phone Link, fatia 1

Data da pausa: 2026-08-07
Branch: `phone-link-fatia1`
Worktree: `/home/lucas/omarchy-desktop-shell/.claude/worktrees/phone-link-fatia1`
HEAD na pausa: `94ad78f`

## Como retomar

Abra o Claude Code **dentro do worktree**, não na raiz do repositório:

```bash
cd /home/lucas/omarchy-desktop-shell/.claude/worktrees/phone-link-fatia1
```

E diga: "retoma o phone-link a partir de docs/superpowers/RETOMAR-phone-link.md".

O worktree fica em `.claude/worktrees/`, que está no `.gitignore` do repositório
principal, então ele não aparece no `git status` da sua `main`. Ele existe no disco e
sobrevive ao reboot. Confirme com `git worktree list` na raiz do repositório.

Suas alterações locais na `main` (shell.qml, install.sh, scripts de wifi) continuam
intocadas: nada deste trabalho encostou nelas.

## Estado

97 testes passando. Nenhum arquivo modificado sem commit.

| Tarefa | Estado |
|--------|--------|
| 1. `protocol` | completa, revisada |
| 2. `config` | completa, revisada |
| 3. certificado e fingerprint | completa, revisada |
| 4. `pair_code` e `TrustStore` | completa, revisada |
| 5. descoberta UDP | completa, revisada |
| 6. contextos TLS e `Session` | completa, revisada |
| 7. `Transport` e gate de pareamento | completa, revisada |
| 8. heartbeat e reconexão | completa, revisada |
| 9. IPC por unix socket | completa, revisada |
| 10. daemon montado | **implementada, 1 correção pendente** |
| 11. CLI `phonectl` | não iniciada |
| 12. integração ponta a ponta | não iniciada |
| 13. instalador e systemd | não iniciada |
| Revisão final da branch | não feita |

## A primeira coisa a fazer ao voltar

A Task 10 tem uma correção **já aprovada e escrita no plano, mas ainda não aplicada ao
código**. O commit `94ad78f` corrigiu o plano; `files/phoned/__main__.py` continua como
estava.

O defeito: em `__main__._executa`, o `await servico.start()` está fora do `try/finally`.
Como `Daemon.start()` sobe o IPC antes do transporte, uma porta ocupada estoura depois de
o socket do unix já existir, e o `stop()` nunca roda. Sobra um arquivo órfão que faz a
próxima subida legítima falhar por um motivo que não tem relação com a causa real. É
exatamente o cenário do critério de verificação de porta ocupada da fatia, e nunca foi
exercitado.

O código corrigido está no plano, em `docs/superpowers/plans/2026-08-07-phone-link-fatia1-daemon.md`,
Task 10, Step 4. Junto dele há um teste novo a acrescentar,
`test_porta_ocupada_falha_sem_deixar_socket`, com a instrução de confirmar que ele falha
sem a correção antes de aceitá-lo.

Depois disso: re-review escopada da Task 10, e seguir para as tarefas 11, 12 e 13.

## Onde está o resto do contexto

- **Plano**: `docs/superpowers/plans/2026-08-07-phone-link-fatia1-daemon.md`. Foi corrigido
  treze vezes durante a execução, sempre commitado. É a fonte da verdade, não a versão
  original.
- **Spec**: `docs/superpowers/specs/2026-08-07-phone-link-transporte-design.md`.
- **Ledger da execução**: `.superpowers/sdd/2026-08-07-phone-link-fatia1-daemon/progress.md`.
  Não está no git (o diretório é ignorado), mas está no disco. Tem uma linha por tarefa,
  os achados de cada revisão, e as decisões que você tomou.
- **Relatórios por tarefa**: mesma pasta, `task-N-report.md`, com evidência RED/GREEN.

## Pendências registradas para a revisão final

Vieram das revisões, foram classificadas como menores e ficaram para o fim:

- `test_sessao_pendurada_e_derrubada_pelo_heartbeat` é estruturalmente instável: ele
  envelhece a contabilidade de um lado enquanto o outro continua respondendo `PONG`, e cada
  resposta em voo restaura o carimbo. Falhou uma vez. A sugestão é silenciar o peer de
  verdade em vez de mexer só na contabilidade.
- `Session.close()` não tem timeout no `wait_closed`, então um peer que não encerra pode
  segurar a corrotina.
- `_pem_do_handshake` acessa `Session._writer`, atributo privado.
- Uma pendência de pareamento substituída por um segundo `_abre_pendente` não emite
  `pair.result` próprio, então quem esperava fica sem resposta.
- `save()` do `TrustStore` cria o arquivo temporário com a umask padrão e só depois faz
  `chmod`, deixando uma janela curta.
- Descoberta loga tipo desconhecido em `debug`, invisível com o daemon em `INFO`.

## O que a fatia 1 ainda não entrega

Nada de notificação, nada de arquivo, nada de UI em QML, e o app Android não existe. O
plano do lado Android é o próximo documento a escrever, e a decisão foi deliberada:
escrevê-lo antes de o daemon rodar seria planejar sobre um protocolo que ainda não passou
pelo contato com a realidade. Ele já passou, e mudou treze vezes no caminho.

O teste de integração da Task 12 é o que substitui o celular durante o desenvolvimento:
duas instâncias completas do daemon no mesmo host, por loopback.
