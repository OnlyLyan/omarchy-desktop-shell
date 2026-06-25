// PcHeartbeat | "batimentos" do PC: coracao + grafico de ECG + bpm que reagem ao estresse.
// Componente Quickshell/QtQuick REUTILIZAVEL e self-contained no render.
//
// Voce alimenta as entradas (cpu, mem, temp); o componente cuida do resto:
//   stress = pior entre cpu% (peso cheio), ram acima de 50% e temp acima de 45C
//   bpm    = bpmMin + stress*(bpmMax-bpmMin)
//   cor    = verde (calmo) -> ambar -> vermelho (sobrecarregado)
// Um Timer no ritmo do bpm injeta o pico (QRS) no grafico que rola, e dispara o
// pulso (lub-dub) do coracao | os dois sincronizados.
//
// Uso minimo (veja demo-shell.qml para um exemplo que roda sozinho):
//   PcHeartbeat { cpu: sys.cpu; mem: sys.mem; temp: sys.temp }
import QtQuick

Row {
    id: root

    // ---- entradas (alimente como quiser) ----
    property int cpu: 0     // uso de CPU 0-100
    property int mem: 0     // uso de RAM 0-100
    property int temp: 0    // temperatura em C (GPU ou CPU; 0 desativa)

    // ---- configuracao ----
    property int bpmMin: 60
    property int bpmMax: 160
    property bool showBpm: true
    property int graphWidth: 64
    property int graphHeight: 20
    property int heartSize: 14
    property string fontFamily: "JetBrainsMono Nerd Font"  // precisa de Nerd Font p/ o glifo do coracao
    property color calmColor: "#9ece6a"
    property color warnColor: "#e0af68"
    property color hotColor: "#f7768e"
    property color textColor: "#6b7089"

    // ---- derivados ----
    property real stress: Math.max(0, Math.min(1, Math.max(
        cpu / 100,
        Math.max(0, (mem - 50) / 50),
        temp > 0 ? Math.max(0, (temp - 45) / 45) : 0)))
    property int bpm: Math.round(bpmMin + stress * (bpmMax - bpmMin))
    property color beatColor: stress > 0.75 ? hotColor : (stress > 0.45 ? warnColor : calmColor)

    spacing: 5

    Text {
        id: heart
        anchors.verticalCenter: parent.verticalCenter
        font.family: root.fontFamily; font.pixelSize: root.heartSize
        text: "󰋑"   // nf-md-heart
        color: root.beatColor
        transformOrigin: Item.Center
    }

    // ---- grafico de ECG: linha que rola com o pico no ritmo do bpm ----
    Canvas {
        id: ecg
        anchors.verticalCenter: parent.verticalCenter
        width: root.graphWidth; height: root.graphHeight
        property var buf: []
        property int cols: 42
        property real phase: 0          // ms desde a ultima batida
        property int sampleMs: 30       // ms por amostra (= intervalo do timer)
        property int spikeIdx: -1       // posicao dentro do pico (QRS)
        readonly property var shape: [0.0, -0.12, 0.06, 1.0, -0.5, 0.12, 0.0, 0.0]

        Component.onCompleted: { var a = []; for (var i = 0; i < cols; i++) a.push(0); buf = a; }

        function step() {
            phase += sampleMs;
            var period = 60000 / root.bpm;
            if (phase >= period) { phase -= period; spikeIdx = 0; beatAnim.restart(); }
            var v = 0;
            if (spikeIdx >= 0 && spikeIdx < shape.length) { v = shape[spikeIdx]; spikeIdx++; }
            else spikeIdx = -1;
            buf.push(v); if (buf.length > cols) buf.shift();
            requestPaint();
        }
        Timer { interval: ecg.sampleMs; running: true; repeat: true; onTriggered: ecg.step() }

        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.strokeStyle = root.beatColor;
            ctx.lineWidth = 1.5; ctx.lineJoin = "round"; ctx.lineCap = "round";
            ctx.beginPath();
            var n = buf.length, dx = width / (cols - 1), mid = height * 0.62, amp = height * 0.52;
            for (var i = 0; i < n; i++) {
                var x = i * dx, y = mid - buf[i] * amp;
                if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
            }
            ctx.stroke();
        }
    }

    Text {
        visible: root.showBpm
        anchors.verticalCenter: parent.verticalCenter
        color: root.textColor; font.pixelSize: 10
        text: root.bpm + " bpm"
    }

    // pulso do coracao (lub-dub), disparado junto com o pico do ECG
    SequentialAnimation {
        id: beatAnim
        NumberAnimation { target: heart; property: "scale"; to: 1.35; duration: 70; easing.type: Easing.OutQuad }
        NumberAnimation { target: heart; property: "scale"; to: 1.12; duration: 60 }
        NumberAnimation { target: heart; property: "scale"; to: 1.28; duration: 60; easing.type: Easing.OutQuad }
        NumberAnimation { target: heart; property: "scale"; to: 1.0;  duration: 110; easing.type: Easing.InQuad }
    }
}
