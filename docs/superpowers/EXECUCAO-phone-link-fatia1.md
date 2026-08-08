# SDD ledger — plan: docs/superpowers/plans/2026-08-07-phone-link-fatia1-daemon.md

Worktree: .claude/worktrees/phone-link-fatia1 (branch phone-link-fatia1)
Base: 00b0776

Task 1: implementado (commit 45c32ea, 18/18 testes, saida limpa)
Task 1: review - spec compliant; 1 Important (teste perdeu o texto acentuado, zerando cobertura de round-trip UTF-8)
Task 1: minor (deferred): encode() nunca e exercitado no ramo de pacote acima do limite; so decode() tem teste de tamanho
Task 1: minor (deferred): encode() nao valida os campos do dict recebido, confia que veio de make_packet
Task 1: fix round 1/5 (1 addressed, 0 open; commits 45c32ea..cbf4fcb)
Task 1: complete (commits 00b0776..cbf4fcb, review clean)
Task 2: implementado (commit c982b1a, 25/25 testes)
Task 2: review - spec compliant; 1 Important plan-mandated (setdefault avalia eager, gravava device_id fantasma). Humano decidiu: corrigir codigo e plano. Plano corrigido em fdd5ba2.
Task 2: minor (deferred): runtime_dir nao recebe chmod 0o700, so state_dir; o ipc.sock vai morar la
Task 2: minor (deferred): assinaturas de config.py sem type hints, sendo contrato das tasks 5 a 12
Task 2: fix round 1/5 (1 addressed, 0 open; commits c982b1a..6c1365a)
Task 2: complete (commits cbf4fcb..6c1365a, review clean)
Task 3: implementado (commit 92382f6, 34/34 testes)
Task 3: review - spec compliant, transcricao verbatim ok; 3 Important todos plan-mandated (CA:TRUE implicito do openssl.cnf, subprocess sem try/except nem timeout, imports ociosos da Task 4). Humano decidiu: corrigir os tres, codigo e plano. Plano corrigido em 0e139cc.
Task 3: minor (deferred): report do implementer parafraseou a saida do RED em vez de citar verbatim
Task 3: fix round 1/5 (3 addressed, 0 open; commits 92382f6..11249a2)
Task 3: complete (commits 6c1365a..11249a2, review clean)
Task 4: implementado (commit a970358, 48/48 testes)
Task 4: review - Approved; 1 Important cosmetico (ordem dos nomes no import de dataclasses divergiu do plano)
Task 4: minor (deferred): save() cria o .tmp com umask padrao e so depois faz chmod 0o600, janela curta de permissao larga
Task 4: minor (deferred): ramo KeyError/TypeError de entrada malformada no devices.json nao tem teste dedicado
Task 4: fix round 1/5 (1 addressed, 0 open; commits a970358..c47d654). Sem auto-formatador no repo.
Task 4: complete (commits 11249a2..c47d654, review clean)
Task 5: implementado (commit 6416e01, 56/56 testes) DONE_WITH_CONCERNS
Task 5: implementer achou bug real no plano (primeiro announce do laco cai na janela de sleep do teste, duplicando identidade). Correcao dele (sleep antes de announce) sacrificava o anuncio de subida exigido pelo spec: daemon ficaria 60s invisivel. Humano decidiu corrigir as assercoes do teste e manter announce imediato. Plano corrigido em e62ee5a.
Task 5: fix round 1/5 (1 addressed, 0 open; commits 6416e01..9399f90)
Task 5: review - Approved, sem Critical nem Important. stop() confirmado sem vazar socket nem task.
Task 5: minor (deferred): unknown-type e body malformado logam em debug, invisiveis com daemon em INFO; unknown-type talvez merecesse warning por indicar peer de versao diferente
Task 5: minor (deferred): test_datagrama_invalido nao discrimina tratamento explicito de excecao engolida pelo asyncio; regressao que removesse o try/except passaria despercebida. Sugerido teste com caplog.
Task 5: complete (commits c47d654..9399f90, review clean)
Task 6: implementer escalou DONE_WITH_CONCERNS sem commitar. Teste do plano esperava ssl.SSLError na recusa do cliente, impossivel em TLS 1.3.
Task 6: controller confirmou de forma independente (scratchpad/tls13_reject.py): handshake nao levanta, write passa, read retorna EOF limpo, handler do servidor nunca invocado.
Task 6: humano decidiu testar o comportamento real. Plano corrigido em f4967ad, incluindo nota sobre recusa ser indistinguivel de queda de WiFi (candidato a melhoria na fatia 2).
Task 6: implementado apos correcao do teste (commit b524cbd, 63/63 testes, 10 rodadas estaveis)
Task 6: review - Needs fixes. 2 Important: buffer default do StreamReader e 64KB, entao MAX_LINE_BYTES de 1MB nunca valia (linha entre os dois estoura ValueError cru); guard duplicado no read_packet divergia do decode por um byte. Humano decidiu honrar 1MB de ponta a ponta. Plano corrigido em 3729be0 (Tasks 6 e 7).
Task 6: minor (deferred): Session.close() sem timeout no wait_closed, peer que nao encerra pode travar a corrotina
Task 6: minor (deferred): teste de recusa fecha writer sem await wait_closed, diferente do padrao do resto do arquivo
Task 6: fix round 1/5 (2 addressed, 0 open; commits b524cbd..cfa46af). Experimento drop-the-limit documentado: teste falha sem limit=, passa com.
Task 6: nota - re-reviewer leu o diff do documento do plano como codigo e atribuiu limit= a Transport.start(), que ainda nao existe. Controller verificou: transport.py tem so Session, 100 linhas, sem scope creep.
Task 6: complete (commits 9399f90..cfa46af, review clean, 65 testes)
Task 7: implementer escalou BLOCKED sem commitar. Bug estrutural do plano: _on_inbound nunca enviava a propria identidade, entao quem chamava connect() ficava sem o device_id do peer e request_pair falhava em silencio. 5 dos 7 testes falhavam, 2 passavam como falso positivo.
Task 7: controller aplicou correcao direta (troca de identidade mutua, sem trade-off a decidir). Plano corrigido em f8b349c.
Task 7: implementado apos correcao do handshake (commit 278c255, 72/72)
Task 7: review - CRITICAL: _registra_identidade sem guarda de re-identificacao. Sessao pareada como A podia se re-rotular como device_id desconhecido mantendo paired=True, furando o gate; e _sessions[A] ficava morto, recusando a reconexao legitima de A ate reiniciar. Important: _abre_pendente vazava timer que depois matava pareamento novo. Humano decidiu corrigir os dois mais tres testes de rejeicao. Plano corrigido em 8188344.
Task 7: fix round 1/5 por implementer NOVO (agente original nao era resumivel). Experimento confirmou RED antes da guarda e GREEN depois. Commits 278c255..471b636, 75/75 testes.
Task 7: minor (deferred): _pem_do_handshake acessa Session._writer, atributo privado
Task 7: minor (deferred): pendencia substituida por segundo _abre_pendente nao emite pair.result proprio, quem esperava fica sem resposta (predata o fix)
Task 7: complete (commits cfa46af..471b636, review clean)
Task 8: implementado (commit 5923c20, 80/80) DONE_WITH_CONCERNS
Task 8: implementer achou teste decorativo: test_sessao_morta_por_timeout ja passava antes do heartbeat existir, porque close() limpo dispara EOF no laco de leitura, nunca a deteccao de staleness. O caso real (WiFi cai sem FIN, socket vivo e mudo) estava sem cobertura. Controller aplicou correcao direta, sem trade-off. Plano corrigido em aecaf9b.
Task 8: BLOCKED round 2. Implementer achou BUG DE PRODUCAO: _laco_heartbeat pingava sessao nao pareada, e phone.ping nao comeca com pair., entao o gate do outro lado derrubava a conexao. Com ping 30s e pair_timeout 60s o pareamento NUNCA fecharia em uso real. Suite nao pegava porque nela o pareamento completa em menos de 1s.
Task 8: controller aplicou: heartbeat pula nao pareada; monta() aceita overrides (mudar cfg pos-start nao afeta laco ja dormindo); mais teste test_pareamento_sobrevive_ao_heartbeat. Plano corrigido em d858998.
Task 8: implementado com as 3 correcoes (commit f824654, 82/82, ambos experimentos confirmados nas duas direcoes)
Task 8: review - 2 Important. A correcao anterior DO CONTROLLER abriu buraco: pular a sessao nao pareada inteira tirava tambem a checagem de sessao morta, e quem se identifica sem pedir pareamento nao tem pair_timeout, ficando pendurado para sempre. Tambem _ultimo_pacote nunca era limpo (cresce sem limite, e id() reaproveitado pelo CPython). Controller corrigiu os dois. Plano em 1f5570e.
Task 8: fix round 2/5 em andamento
Task 8: agente travou sem commitar (213k tokens, devolveu texto fora do contrato). Controller matou processo orfao que segurava as portas 45209/45210 e despachou implementer fresco para validar e commitar.
Task 8: fix round 2/5 (2 addressed, 0 open; commits f824654..98eec93). Experimento confirmado nas duas direcoes.
Task 8: minor (deferred) IMPORTANTE PARA A REVISAO FINAL: test_sessao_pendurada_e_derrubada_pelo_heartbeat e estruturalmente racy, nao so apertado. O peer b continua respondendo PONG e cada resposta em voo refresca _ultimo_pacote, anulando a stalenesss artificial. Flake observado 1x. Sugestao do reviewer: silenciar b de verdade (pausar laco de leitura) em vez de so envelhecer a contabilidade de a.
Task 8: complete (commits 471b636..98eec93, review clean, 83 testes)
Task 9: implementado (commit c4e88a7, 89/89) DONE_WITH_CONCERNS
Task 9: implementer diagnosticou corrida no stop() do IpcServer gerando PytestUnraisableExceptionWarning, achou o fix e NAO aplicou por causa da regra de transcricao verbatim (postura correta). Controller aprovou. Plano em 63e30a3.
Task 9: fix round 1/5 (warning do stop resolvido, commits c4e88a7..ca48e81, experimento exit 1 -> exit 0)
Task 9: review - 2 Important. O MESMO bug de limite de linha ja corrigido no transport estava no ipc.py: start_unix_server sem limit, readline sem tratar ValueError, matando a tarefa do cliente e virando EOF silencioso. Falha de consistencia do controller ao corrigir so um lado. Tambem teste de erro sem assert de request_id. Plano corrigido em 5759034, mais dois testes de linha grande.
Task 9: fix round 2/5 em andamento
Task 9: fix round 2/5 (2 addressed, 0 open; commits ca48e81..57317b5). Experimento sem limit= falha com KeyError, confirmado diagnostico.
Task 9: nota - o snippet de teste do controller usava 200_000 bytes, ABAIXO do buffer de 1MB, entao readline nunca levantava e a suite inteira deadlockava (exit 124). Implementer diagnosticou a borda e usou MAX_LINE_BYTES + 1, acoplado a constante. Erro do controller, diagnostico correto do implementer.
Task 9: complete (commits 98eec93..57317b5, review clean, 91 testes)
Task 10: implementado (commit 665646e, 97/97, daemon real sobe e limpa o socket)
Task 10: implementer reportou corrida no stop(): ordem cancelava tarefas antes de parar a descoberta, entao datagrama em voo criava ensure_connected orfao. Controller corrigiu a ordem. Plano em 39ff85a. Sem teste de proposito: reproduzir a janela exigiria sleep cronometrado, e teste por sorte e pior que nenhum.
Task 10: fix round 1/5 (ordem do stop, commits 665646e..ef8c6a7)
Task 10: review - 1 Important: start() fora do try/finally em __main__, entao porta ocupada estourava com o socket do IPC ja criado e sem limpeza. E o cenario do proprio criterio de verificacao de porta ocupada, nunca exercitado. Plano corrigido em 94ad78f, mais teste test_porta_ocupada_falha_sem_deixar_socket.
Task 10: minor (deferred): report atribuiu o fix do stop ao commit do documento do plano, nao ao do codigo
Task 10: fix round 2/5 em andamento
Task 10: fix round 2/5 (1 addressed, 0 open; commits ef8c6a7..dbc79e8). Experimento confirmado: teste falha com socket para tras sem o stop no finally.
Task 10: complete (commits 57317b5..dbc79e8, review clean, 98 testes)
Task 11: implementado (commit a4f650a, 104/104)
Task 11: review - CRITICAL no contrato de IPC que o controller desenhou: pair.result e ao mesmo tempo resposta direta do comando pair e evento broadcast para todos os clientes. Filtrando so por tipo, pareamento alheio expirando vira resposta do comando local. Tambem except nao pegava ConnectionError da propria pergunta. Plano corrigido em 0a7b957, mais dois testes.
Task 11: minor (deferred): sem teste para watch e connect; import pytest ocioso no test_phonectl
Task 11: fix round 1/5 em andamento
Task 11: fix round 1/5 (2 addressed, 0 open; commits a4f650a..4ca744a). Experimento RED confirmou que o codigo antigo aceitava o evento broadcast.
Task 11: minor (deferred): pergunta() nao tem timeout do lado cliente, daemon que fica conectado sem responder bloqueia para sempre
Task 11: complete (commits dbc79e8..4ca744a, review clean, 106 testes)
Task 12: implementer escalou BLOCKED sem commitar. Corrida no teste E2E do controller: pendente() olhava so o _pending de quem pede, que request_pair preenche sincronamente antes de o pacote sair; a confirmacao chegava no outro lado antes dele processar o pair.request. O teste ainda ignorava o ok False de confirm_pair, que era a pista. Falha deterministica 4/4. Plano corrigido em 6a3dcab.
Task 12: implementado (commit df616d3, 108/108, 9 rodadas estaveis do E2E)
Task 12: review - CRITICAL medido empiricamente: reviewer desligou o gate de seguranca e o teste do intruso ainda passou 1 de 4 vezes. Causa: session_timeout reapa sessao nao pareada tambem e a descoberta reconecta, entao a janela de 4s flagrava oscilacao natural. Oitavo teste do projeto a passar pelo motivo errado. Janela apertada para 0.8s e sessao do intruso virou assert. Plano em d2a95e7.
Task 12: fix round 1/5 em andamento, com experimento de 10 rodadas com e sem o gate
Task 12: fix round 1/5 (1 addressed, 0 open; commits df616d3..e8a084b). Experimento: 10/10 falham com gate desligado, 10/10 passam com ligado. Teste agora discrimina.
Task 12: complete (commits 4ca744a..e8a084b, review clean, 108 testes)
Task 13: implementado (commit 60d944d). Instalador NAO executado por decisao do controller: instala systemd user service e abre porta na rede do usuario, decisao dele. Verificado com bash -n, systemd-analyze verify --user e unidades transientes systemd-run.
Task 13: implementer achou bug real na unit do controller: ReadWritePaths sem o diretorio de runtime, entao sob ProtectSystem=strict o daemon nao criaria o socket do IPC.
Task 13: defeito transversal achado pelo controller: as 53 portas fixas de teste (45xxx) estavam DENTRO do range efemero do kernel (32768-60999), entao qualquer conexao de saida da maquina quebrava a suite aleatoriamente. Renumeradas para 21xxx em 3edb9bc. 108 testes, 4 rodadas limpas.
Task 13: fix round 1/5 (1 addressed, 0 open; commits 3edb9bc..a46e7eb). Teste A/B com systemd-run real: 226/NAMESPACE sem o fix, 0/SUCCESS com.
Task 13: complete (commits e8a084b..a46e7eb, review clean, 108 testes)
TODAS AS 13 TAREFAS COMPLETAS. Iniciando revisao final da branch.

=== REVISAO FINAL DA BRANCH: BLOQUEADA, 3 CRITICAL ===
C1: request_pair estoura TypeError quando somos o servidor TLS. peer_fingerprint e None (CERT_NONE nao pede cert do cliente) e vai direto para sorted() no pair_code. O pair.request ja foi enviado antes de estourar, entao o celular mostra codigo de um pareamento que o PC nao registrou. Suite nao pega porque parear() sempre chama request_pair do lado que abriu a conexao.
C2: contexto TLS do servidor e construido uma vez em start() e nunca reconstruido quando o trust store muda. Aparelho pareado em runtime nunca reconecta inbound ate reiniciar o daemon.
C3: com trust store nao vazio o servidor vira CERT_OPTIONAL, e um aparelho novo que ja pareou com outra coisa apresenta cert e e recusado no handshake, sem log em nenhum lado. Impede parear um segundo aparelho.
Causa comum: todos os testes dirigem a conexao de um lado so. Metade da maquina de estados, justamente a que o celular real vai exercitar, nunca rodou.
Important: 3o caso do bug de limite de linha, agora no phonectl; sem limite de trabalho para peer nao pareado; heartbeat serializa send/encerra sem timeout, um peer travado desliga a deteccao de vida de todos; excecao no heartbeat vira excecao no stop.
FIX WAVE FINAL: commit ed8e889, 112 testes, 3 rodadas. Implementer REJEITOU a opcao simples sugerida (CERT_NONE permanente) com argumento de seguranca correto: sem cert de cliente, _registra_identidade nao teria o que comparar na reconexao e qualquer um na LAN passaria por aparelho pareado. Escolheu derivar fingerprint do PEM + mutar o contexto TLS a cada mudanca do truststore + so apresentar cert a par conhecido.
RE-REVIEW FINAL: Ready to merge. Reviewer reverteu o fix e rodou: 4 falhas, exatamente os 4 testes novos. Propriedade de seguranca intacta em todos os caminhos tracados.
PENDENTE (nao bloqueia merge, mas o reviewer pediu para nao deixar passar): regressao de observabilidade. Aparelho pareado que troca de certificado (reinstalar o app) morre dentro do OpenSSL antes do _on_inbound, sem log em nenhum lado, e ensure_connected le como sucesso e zera o backoff, retentando a cada beacon para sempre. Mesma assinatura do Critical 3. Sugestao: logar quando a conexao fecha antes de chegar identity.
PARA A FATIA 2 (Android): app precisa de dois SSLContext, um com KeyManager e outro sem, escolhendo por device_id do beacon. O setup obvio de um SSLContext so (e o padrao do OkHttp) apresenta cert para todo mundo e reproduz o Critical 3 sem diagnostico. Listener do celular deve usar setWantClientAuth + TrustManager mutavel. Certificados tem CA:TRUE, entao so a comparacao exata de fingerprint barra leaf assinado por par confiavel.
