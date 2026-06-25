# 09 | PcHeartbeat | os "batimentos" do PC

Um monitor cardiaco do PC pra barra: um **coracao** que pulsa + um **grafico de ECG**
que rola + o **bpm**, tudo no ritmo do estresse da maquina. Quando o PC esta tranquilo,
bate devagar e fica verde; quando esta sob carga (CPU/RAM/temp altos), acelera, os picos
ficam mais juntos e a cor vai pra ambar e depois vermelho | como alguem correndo.

Componente Quickshell/QtQuick self-contained no render. Ja vem integrado na barra da pasta
06 (lado esquerdo, ao lado do menu); aqui ele esta empacotado como componente reutilizavel
+ um demo que roda sozinho.

## Como funciona
- `stress = max(cpu%, ram acima de 50%, temp acima de 45C)`, normalizado em 0..1.
- `bpm = bpmMin + stress * (bpmMax - bpmMin)` (padrao 60 tranquilo -> 160 "correndo").
- Cor: verde (`stress < 0.45`) -> ambar (`< 0.75`) -> vermelho.
- Um `Timer` (30 ms/amostra) rola o buffer do grafico; quando uma batida vence
  (`phase >= 60000/bpm`) injeta o pico (QRS) no grafico **e** dispara o pulso (lub-dub) do
  coracao | os dois sincronizados pelo mesmo timer.

## Arquivos
- `files/PcHeartbeat.qml` | o componente reutilizavel (so render; voce alimenta cpu/mem/temp).
- `files/stats.sh` | coleta `cpu mem temp` (delta de `/proc/stat`, `/proc/meminfo`, nvidia-smi
  ou `/sys/class/thermal`).
- `files/demo-shell.qml` | um Quickshell standalone que junta os dois.
- `run-demo.sh` | sobe o demo (seta o caminho do stats.sh e chama `quickshell`).

## Rodar o demo
```bash
./run-demo.sh
```
Aparece um coracao no canto inferior esquerdo. Pra ver vermelho/rapido, estresse a CPU
(ex: `for i in $(seq $(nproc)); do timeout 8 sh -c 'while :; do :; done' & done`).

## Embutir na sua barra
Coloque `PcHeartbeat.qml` ao lado do seu `shell.qml` (mesma pasta = importavel direto) e
alimente as entradas com os seus pollers:
```qml
PcHeartbeat {
    cpu: sys.cpu          // 0-100
    mem: sys.mem          // 0-100
    temp: gpu.temp        // C (0 desativa o fator temperatura)
    // opcionais:
    bpmMin: 60; bpmMax: 160
    graphWidth: 64; graphHeight: 20
    showBpm: true
    fontFamily: "JetBrainsMono Nerd Font"
}
```

## Dependencias
- `quickshell-git` (AUR).
- Uma **Nerd Font** (o coracao usa o glifo `nf-md-heart`). Ex: JetBrainsMono Nerd Font.
- `stats.sh`: `awk`, `/proc` (Linux). Temperatura: `nvidia-smi` (NVIDIA) ou
  `/sys/class/thermal` (CPU); sem nenhum, o fator temperatura fica 0 e o resto funciona.

## Personalizar
Props do componente: `bpmMin`, `bpmMax`, `graphWidth`, `graphHeight`, `heartSize`,
`showBpm`, `fontFamily`, `calmColor`/`warnColor`/`hotColor`/`textColor`. O formato do pico
do ECG esta em `shape` dentro do `Canvas`.
