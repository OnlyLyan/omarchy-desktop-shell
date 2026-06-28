//@ pragma UseQApplication
// Barra do Lucas em Quickshell. Objetivo: taskbar AGRUPADA por app dentro da barra.
// Iteracao 1: menu Omarchy + taskbar agrupada + relogio. Modulos de status virao depois.
import Quickshell
import Quickshell.Wayland
import Quickshell.Wayland._Screencopy
import Quickshell.Io
import Quickshell.Services.SystemTray
import Quickshell.Services.UPower
import Quickshell.Bluetooth
import Quickshell.Services.Mpris
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects

ShellRoot {
    id: root
    // estado global: central de acoes (dropdown estilo Windows) aberta?
    property bool acOpen: false
    property var acScreen: null   // monitor onde a central abre (o do chevron clicado)
    property var wpaMonitors: []  // conectores onde o grafo aparece (vazio = todos)
    property int wpaFps: 30

    // ===== tokens de geometria das ilhas (theme-independente; ajuste ao vivo) =====
    QtObject {
        id: ui
        readonly property int islandRadius: 16     // raio dos cantos da ilha
        readonly property int islandHeight: 32     // altura interna da ilha
        readonly property int barMargin: 4         // respiro das bordas da tela (barra mais baixa)
        readonly property int islandPadH: 13       // padding horizontal interno
        readonly property int moduleSpacing: 10    // espaco entre modulos dentro da ilha
        readonly property real islandOpacity: 0.75 // opacidade do fundo da ilha
        readonly property real shadowBlur: 16      // desfoque da sombra
        readonly property real shadowOpacity: 0.35 // alpha da sombra
    }

    // relogio do sistema
    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // ---- TEMA: le colors.toml do tema ativo do Omarchy ----
    // Mapeia accent/fg/bg/color0-15 -> papeis semanticos. Shades intermediarios
    // sao derivados (Qt.lighter/darker) pra ficar coerente em QUALQUER tema.
    QtObject {
        id: theme
        // cores cruas (fallback = Tokyo Night atual, caso o arquivo falhe)
        property color bg:       "#1a1b26"
        property color fg:       "#a9b1d6"
        property color fgBright: "#c0caf5"
        property color accent:   "#7aa2f7"
        property color sel:      "#7aa2f7"
        property color cRed:     "#f7768e"
        property color cGreen:   "#9ece6a"
        property color cYellow:  "#e0af68"
        property color cBlue:    "#7aa2f7"
        property color cMagenta: "#bb9af7"
        property color cCyan:    "#449dab"
        property color c0:       "#32344a"
        property color c8:       "#444b6a"
        // shades derivados / aliases usados pela barra
        readonly property color bgDark:   Qt.darker(bg, 1.4)
        readonly property color bgAlt:    Qt.lighter(bg, 1.25)
        readonly property color surface:  c0
        readonly property color surface2: Qt.lighter(c0, 1.3)
        readonly property color border:   c8
        readonly property color fgDim:    Qt.darker(fg, 1.55)
        readonly property color ok:       cGreen
        readonly property color warn:     cYellow
        readonly property color danger:   cRed
        readonly property color info:     cBlue
        readonly property color purple:   cMagenta
        readonly property color accentText: fgBright
        function applyMap(m) {
            if (m.background) bg = m.background;
            if (m.foreground) fg = m.foreground;
            if (m.cursor) fgBright = m.cursor;
            if (m.accent) accent = m.accent;
            if (m.selection_background) sel = m.selection_background;
            if (m.color1) cRed = m.color1;
            if (m.color2) cGreen = m.color2;
            if (m.color3) cYellow = m.color3;
            if (m.color4) cBlue = m.color4;
            if (m.color5) cMagenta = m.color5;
            if (m.color6) cCyan = m.color6;
            if (m.color0) c0 = m.color0;
            if (m.color8) c8 = m.color8;
        }
        function parse(txt) {
            var map = {}, lines = (txt || "").split("\n");
            for (var i = 0; i < lines.length; i++) {
                var r = lines[i].match(/^\s*([a-zA-Z0-9_]+)\s*=\s*"(#[0-9a-fA-F]{6,8})"/);
                if (r) map[r[1]] = r[2];
            }
            applyMap(map);
        }
    }
    // le e observa o colors.toml; chama theme.parse no load e a cada troca de tema
    FileView {
        id: themeFile
        path: "/home/lucas/.config/omarchy/current/theme/colors.toml"
        watchChanges: true
        // API confirmada (Quickshell.Io FileView): text() le conteudo, signals
        // loaded/fileChanged, metodo reload(). parse roda no load inicial e em
        // cada mudanca do arquivo (troca de tema do Omarchy).
        onLoaded: theme.parse(themeFile.text())
        onFileChanged: { themeFile.reload(); theme.parse(themeFile.text()); }
    }
    // recarga reativa via IPC: `qs ipc call theme reload` (chamado pelo hook theme-set).
    // re-le o colors.toml sem reiniciar o processo, entao a central nao fecha na troca.
    IpcHandler {
        target: "theme"
        function reload(): void { themeFile.reload(); theme.parse(themeFile.text()); }
    }

    // ---- estado de sistema (cpu/ram/rede) por polling ----
    QtObject {
        id: sys
        property int cpu: 0
        property int mem: 0
        property string net: "off"   // "eth" | "wifi:NN" | "off"
    }

    // cpu+ram: amostra /proc/stat 2x (delta) e /proc/meminfo
    Process {
        id: cpuProc
        command: ["sh", "-c",
            "set -- $(awk '/^cpu /{for(i=2;i<=NF;i++)s+=$i; print s, $5}' /proc/stat); t1=$1; i1=$2; sleep 0.25; " +
            "set -- $(awk '/^cpu /{for(i=2;i<=NF;i++)s+=$i; print s, $5}' /proc/stat); t2=$1; i2=$2; " +
            "dt=$((t2-t1)); di=$((i2-i1)); if [ $dt -gt 0 ]; then cpu=$((100*(dt-di)/dt)); else cpu=0; fi; " +
            "mem=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print int((t-a)*100/t)}' /proc/meminfo); " +
            "echo \"$cpu $mem\""]
        stdout: StdioCollector {
            onStreamFinished: {
                var p = this.text.trim().split(" ");
                sys.cpu = parseInt(p[0]) || 0;
                sys.mem = parseInt(p[1]) || 0;
            }
        }
    }
    Timer { interval: 3000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: cpuProc.running = true }

    // rede: nmcli -> "eth" / "wifi:<sinal>" / "off"
    Process {
        id: netProc
        command: ["sh", "-c",
            "for i in /sys/class/net/*; do d=${i##*/}; [ \"$d\" = lo ] && continue; " +
            "[ \"$(cat $i/operstate 2>/dev/null)\" = up ] || continue; " +
            "if [ -d \"$i/wireless\" ]; then " +
            "s=$(iw dev \"$d\" link 2>/dev/null | sed -n 's/.*SSID: //p'); " +
            "echo \"wifi:${s:-Wi-Fi}\"; exit 0; else echo eth; exit 0; fi; done; echo off"]
        stdout: StdioCollector { onStreamFinished: sys.net = this.text.trim() }
    }
    Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: netProc.running = true }

    // ---- WiFi (iwd via wifi.sh): lista estavel + estado + acoes na barra ----
    property var wifiNets: []
    property string wifiActive: ""    // "ssid|sig" ou ""
    property bool wifiBusy: false
    Process {
        id: wifiListProc
        command: ["/home/lucas/.config/quickshell/scripts/wifi.sh", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = this.text.trim().split("\n");
                var arr = [];
                for (var i = 0; i < lines.length; i++) {
                    if (!lines[i]) continue;
                    var p = lines[i].split("|");
                    if (p.length < 5) continue;
                    arr.push({ conn: p[0] === "1", sig: parseInt(p[1]) || 0,
                               sec: p[2], known: p[3] === "1",
                               name: p.slice(4).join("|") });
                }
                if (arr.length > 0) root.wifiNets = arr;   // nunca zera com lista vazia
                root.wifiBusy = false;
            }
        }
    }
    Process {
        id: wifiStateProc
        command: ["/home/lucas/.config/quickshell/scripts/wifi.sh", "state"]
        stdout: StdioCollector { onStreamFinished: root.wifiActive = this.text.trim() }
    }
    Process { id: wifiScanProc; command: ["/home/lucas/.config/quickshell/scripts/wifi.sh", "scan"] }
    Process { id: wifiActProc }   // connect/disconnect/forget (command setado em wifiCmd)
    function refreshWifi() { wifiListProc.running = true; wifiStateProc.running = true; }
    function scanWifi() { wifiScanProc.running = true; root.wifiBusy = true; }
    function wifiCmd(args) {
        wifiActProc.command = ["/home/lucas/.config/quickshell/scripts/wifi.sh"].concat(args);
        wifiActProc.running = true;
    }
    property var wifiDetails: []
    Process {
        id: wifiDetailsProc
        stdout: StdioCollector {
            onStreamFinished: {
                var arr = [];
                var lines = this.text.trim().split("\n");
                for (var i = 0; i < lines.length; i++) {
                    if (!lines[i]) continue;
                    var p = lines[i].split("|");
                    if (p.length < 2) continue;
                    arr.push({ k: p[0], v: p.slice(1).join("|") });
                }
                root.wifiDetails = arr;
            }
        }
    }
    function wifiFetchDetails(ssid) {
        root.wifiDetails = [];
        wifiDetailsProc.command = ["/home/lucas/.config/quickshell/scripts/wifi.sh", "details", ssid];
        wifiDetailsProc.running = true;
    }

    // ---- painel de wallpaper (grafo): busca Pinterest + ciclo do Omarchy ----
    property var wpaSearchItems: []   // [{id, ext, w, h, in_cycle}]
    property var wpaCycleItems: []    // [{file}]
    property bool wpaBusy: false
    readonly property string wpaApi: "http://127.0.0.1:8799"

    function wpaPost(path, body, cb) {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                root.wpaBusy = false;
                if (xhr.status === 200 && cb) {
                    try { cb(JSON.parse(xhr.responseText)); } catch (e) {}
                }
            }
        };
        // try/catch: erro de rede nao deixa o indicador travado em "buscando"
        try {
            xhr.open("POST", root.wpaApi + path);
            xhr.setRequestHeader("Content-Type", "application/json");
            xhr.send(JSON.stringify(body || {}));
        } catch (e) { root.wpaBusy = false; }
    }
    function wpaGet(path, cb) {
        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function () {
            if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200 && cb) {
                try { cb(JSON.parse(xhr.responseText)); } catch (e) {}
            }
        };
        xhr.open("GET", root.wpaApi + path); xhr.send();
    }
    function wpaSearch(vibe) {
        root.wpaBusy = true; root.wpaSearchItems = [];
        root.wpaPost("/api/search", { vibe: vibe, count: 12 }, function (r) {
            root.wpaSearchItems = r.items || [];
        });
    }
    function wpaAdd(ids) {
        root.wpaPost("/api/add", { ids: ids }, function () { root.wpaLoadCycle(); });
    }
    function wpaLoadCycle() {
        root.wpaGet("/api/cycle", function (r) { root.wpaCycleItems = r.items || []; });
    }
    function wpaRemove(files) {
        root.wpaPost("/api/remove", { files: files }, function () { root.wpaLoadCycle(); });
    }

    // ---- backends do grafo de agentes (Claude Agents Wallpaper) ----
    // O coletor varre ~/.claude/projects e serve graph.json (8787).
    // O painel faz a busca de wallpaper (8799). Ambos vivem com o qsbar.
    Process {
        id: wpaCollector
        command: ["python3", "/home/lucas/claude-agents-wallpaper/collector/serve.py"]
        running: true
    }
    Process {
        id: wpaPanelServer
        command: ["python3", "/home/lucas/claude-agents-wallpaper/panel/panel_server.py"]
        running: true
    }

    // grafo de agentes na camada Bottom (substitui o host GTK4+WebKit)
    AgentGraph {
        id: agentGraph
        // config lida de ~/.config/wpa/config.json (Task 6); padrao: todos os monitores, 30fps
        enabledMonitors: root.wpaMonitors
        fps: root.wpaFps
    }

    // ---- temas Omarchy: lista (nome+fundo+accent) + tema atual ----
    property var themes: []
    property string currentTheme: ""
    // ordem de exibicao: tema atual primeiro, resto alfabetico
    readonly property var orderedThemes: {
        var a = themes.slice();
        a.sort(function (x, y) {
            if (x.snake === currentTheme) return -1;
            if (y.snake === currentTheme) return 1;
            return x.snake < y.snake ? -1 : (x.snake > y.snake ? 1 : 0);
        });
        return a;
    }
    Process {
        id: themesProc
        // varre temas embutidos e do usuario; saida: snake|displayName|bg|accent por linha
        command: ["bash", "-c",
            "for d in \"$HOME/.local/share/omarchy/themes\"/*/ \"$HOME/.config/omarchy/themes\"/*/; do " +
            "[ -f \"$d/colors.toml\" ] || continue; snake=$(basename \"$d\"); " +
            "bg=$(grep -m1 '^background' \"$d/colors.toml\" | grep -oE '#[0-9a-fA-F]{6,8}'); " +
            "ac=$(grep -m1 '^accent' \"$d/colors.toml\" | grep -oE '#[0-9a-fA-F]{6,8}'); " +
            "echo \"$snake|$bg|$ac\"; done | sort -u"]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = this.text.trim().split("\n");
                var seen = {}, arr = [];
                for (var i = 0; i < lines.length; i++) {
                    if (!lines[i]) continue;
                    var p = lines[i].split("|");
                    var snake = p[0];
                    if (!snake || seen[snake]) continue;
                    seen[snake] = true;
                    var nice = snake.split("-").map(function (w) {
                        return w.charAt(0).toUpperCase() + w.slice(1);
                    }).join(" ");
                    arr.push({ snake: snake, name: nice,
                               bg: p[1] || "#000000", accent: p[2] || "#888888" });
                }
                root.themes = arr;
            }
        }
    }
    Process {
        id: curThemeProc
        command: ["cat", "/home/lucas/.config/omarchy/current/theme.name"]
        stdout: StdioCollector { onStreamFinished: { root.currentTheme = this.text.trim(); } }
    }
    function refreshThemes() { themesProc.running = true; curThemeProc.running = true; }
    function setTheme(snake) { Quickshell.execDetached(["omarchy-theme-set", snake]); root.currentTheme = snake; }

    // ---- update do Omarchy disponivel? (git ls-remote, poll raro) ----
    QtObject {
        id: omup
        property bool avail: false
        property string tag: ""
    }
    Process {
        id: omupProc
        command: ["sh", "-c",
            "export OMARCHY_PATH=\"${OMARCHY_PATH:-$HOME/.local/share/omarchy}\"; " +
            "PATH=\"$OMARCHY_PATH/bin:$PATH\" omarchy-update-available"]
        stdout: StdioCollector {
            onStreamFinished: {
                var m = this.text.match(/\(([^)]+)\)/);
                omup.tag = m ? m[1] : "";
            }
        }
        onExited: function (code, status) { omup.avail = (code === 0); }
    }
    Timer { interval: 1800000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: omupProc.running = true }   // 30 min

    // ============ toggles rapidos (bass boost / caffeine / nightlight / mic) ============
    QtObject {
        id: tg
        property bool caffeine: false   // inibindo idle (hypridle NAO rodando)
        property bool night: false      // nightlight ligado (temperatura != 6000)
        property bool micMuted: false
    }
    Process {
        id: tgProc
        command: ["sh", "-c",
            "pgrep -x hypridle >/dev/null && caf=0 || caf=1; " +
            // estado confiavel via wrapper (a query de temperatura do hyprsunset mente no modo identity)
            "[ \"$($HOME/.local/bin/nightlight-toggle get)\" = on ] && night=1 || night=0; " +
            "wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | grep -q MUTED && mic=1 || mic=0; " +
            "echo \"$caf $night $mic\""]
        stdout: StdioCollector {
            onStreamFinished: {
                var p = this.text.trim().split(" ");
                tg.caffeine = p[0] === "1"; tg.night = p[1] === "1"; tg.micMuted = p[2] === "1";
            }
        }
    }
    // (bass boost agora e o modelo novo: root.bassOn / toggleBassNew, via audio.sh.
    //  O antigo 'easyeffects -b 3' foi removido: ele LIGAVA o EE e alternava o bypass
    //  como efeito colateral de so consultar o estado, quebrando o roteamento de audio.)
    Timer { interval: 10000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: tgProc.running = true }
    function tgRefresh() { tgProc.running = true; }
    // reconciliam o estado real um pouco depois (o clique ja virou na hora, otimista)
    Timer { id: tgDelay; interval: 800; repeat: false; onTriggered: tgProc.running = true }
    function toggleCaffeine() { tg.caffeine = !tg.caffeine; Quickshell.execDetached(["sh", "-c", "export PATH=\"$HOME/.local/share/omarchy/bin:$PATH\"; omarchy-toggle-idle"]); tgDelay.restart(); }
    function toggleNight() { tg.night = !tg.night; Quickshell.execDetached(["/home/lucas/.local/bin/nightlight-toggle", "toggle"]); tgDelay.restart(); }
    function toggleMic() { tg.micMuted = !tg.micMuted; Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"]); tgDelay.restart(); }

    // ============ volume do dispositivo de SAIDA REAL ============
    // o easyeffects_sink (default) ignora o proprio volume; controlamos o device
    // real (fone BT / alto-falante) via scripts/audio.sh
    QtObject { id: vols; property real vol: 0; property bool mut: false }
    property bool volDragging: false
    property real pendingVol: -1
    Process {
        id: volProc
        command: ["/home/lucas/.config/quickshell/scripts/audio.sh", "get"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (root.volDragging) return;   // nao sobrescreve o valor enquanto arrasta
                var p = this.text.trim().split(" ");
                vols.vol = (parseInt(p[0]) || 0) / 100;
                vols.mut = p[1] === "1";
            }
        }
    }
    function refreshVol() { volProc.running = true; }
    // poll so enquanto a central esta aberta
    // (inclui sinks/sources/mirror: fone que conecta com o painel aberto aparece sozinho)
    Timer { interval: 2000; running: root.acOpen; repeat: true; triggeredOnStart: true
            onTriggered: { volProc.running = true; bassGetProc.running = true;
                           if (!root.volDragging) sinksProc.running = true;
                           micSrcProc.running = true; mirrorGetProc.running = true; } }
    // throttle: aplica no maximo a cada 90ms o ultimo valor arrastado (1 processo, nao 1 por pixel)
    Timer {
        id: volApply; interval: 90; repeat: false
        onTriggered: {
            if (root.pendingVol >= 0) {
                Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh",
                    "set", "" + Math.round(root.pendingVol * 100)]);
                root.pendingVol = -1;
            }
        }
    }
    function setVolReal(f) {
        var ff = Math.max(0, Math.min(1, f));
        vols.vol = ff;            // feedback visual instantaneo
        root.pendingVol = ff;
        if (!volApply.running) volApply.start();
    }
    function toggleVolMute() {
        vols.mut = !vols.mut;     // otimista
        Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh", "toggle"]);
    }

    // ---- painel de audio estilo Windows: dispositivos de saida + volume por app + bass ----
    property var audioSinks: []
    property var audioApps: []
    property bool bassOn: false
    property bool mirrorMode: false   // toggle "Espelhar": lista vira multi-selecao
    property var mirrorSel: []         // names dos dispositivos marcados pro espelho
    Process {
        id: sinksProc
        command: ["/home/lucas/.config/quickshell/scripts/audio.sh", "sinks"]
        stdout: StdioCollector { onStreamFinished: {
            var lines = this.text.trim().split("\n"); var arr = [];
            for (var i = 0; i < lines.length; i++) { if (!lines[i]) continue;
                var p = lines[i].split("|");
                arr.push({ name: p[0], active: p[1] === "1", icon: p[2] || "speaker",
                           desc: p.slice(3).join("|") || p[0] }); }
            root.audioSinks = arr;
        } }
    }
    Process {
        id: appsProc
        command: ["/home/lucas/.config/quickshell/scripts/audio.sh", "apps"]
        stdout: StdioCollector { onStreamFinished: {
            var lines = this.text.trim().split("\n"); var arr = [];
            for (var i = 0; i < lines.length; i++) { if (!lines[i]) continue;
                var p = lines[i].split("|");
                arr.push({ id: p[0], mut: p[1] === "1", vol: (parseInt(p[2]) || 0) / 100,
                           outSink: p[3] || "", name: p.slice(4).join("|") || ("app " + p[0]) }); }
            root.audioApps = arr;
        } }
    }
    Process {
        id: bassGetProc
        command: ["/home/lucas/.config/quickshell/scripts/audio.sh", "bass-get"]
        stdout: StdioCollector { onStreamFinished: root.bassOn = (this.text.trim() === "1") }
    }
    Process {
        id: mirrorGetProc
        command: ["/home/lucas/.config/quickshell/scripts/audio.sh", "mirror-get"]
        stdout: StdioCollector { onStreamFinished: {
            var s = this.text.trim();
            if (s.length > 0) { root.mirrorMode = true; root.mirrorSel = s.split(","); }
            // espelho real (2+ dispositivos) sumiu por fora: reseta o estado.
            // (nao mexe quando ha <2 selecionados: usuario ainda escolhendo no painel)
            else if (root.mirrorSel.length >= 2) { root.mirrorMode = false; root.mirrorSel = []; }
        } }
    }

    // ---- microfone (entrada): mesmo modelo do output ----
    QtObject { id: mics; property real vol: 0; property bool mut: false }
    property bool micDragging: false
    property real micPending: -1
    property var micSources: []
    Process {
        id: micGetProc
        command: ["/home/lucas/.config/quickshell/scripts/audio.sh", "mic-get"]
        stdout: StdioCollector { onStreamFinished: {
            if (root.micDragging) return;
            var p = this.text.trim().split(" "); mics.vol = (parseInt(p[0]) || 0) / 100; mics.mut = p[1] === "1";
        } }
    }
    Process {
        id: micSrcProc
        command: ["/home/lucas/.config/quickshell/scripts/audio.sh", "sources"]
        stdout: StdioCollector { onStreamFinished: {
            var lines = this.text.trim().split("\n"); var arr = [];
            for (var i = 0; i < lines.length; i++) { if (!lines[i]) continue;
                var p = lines[i].split("|");
                arr.push({ name: p[0], active: p[1] === "1", icon: p[2] || "mic", desc: p.slice(3).join("|") || p[0] }); }
            root.micSources = arr;
        } }
    }
    Timer { id: micApply; interval: 90; repeat: false; onTriggered: {
        if (root.micPending >= 0) { Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh", "mic-set", "" + Math.round(root.micPending * 100)]); root.micPending = -1; } } }
    function refreshMic() { micGetProc.running = true; micSrcProc.running = true; }
    function setMicVol(f) { var ff = Math.max(0, Math.min(1, f)); mics.vol = ff; root.micPending = ff; if (!micApply.running) micApply.start(); }
    function toggleMicMuteAudio() { mics.mut = !mics.mut; Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh", "mic-toggle"]); }
    function setInput(name) { Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh", "input", name]);
                              for (var i = 0; i < micSources.length; i++) micSources[i].active = (micSources[i].name === name);
                              micSources = micSources.slice(); audioRefresh.restart(); }

    function refreshAudio() { sinksProc.running = true; appsProc.running = true; bassGetProc.running = true; mirrorGetProc.running = true; root.refreshVol(); root.refreshMic(); }
    function setOutput(name) { Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh", "output", name]);
                               for (var i = 0; i < audioSinks.length; i++) audioSinks[i].active = (audioSinks[i].name === name);
                               audioSinks = audioSinks.slice(); audioRefresh.restart(); }
    // ---- espelho: tocar em varios dispositivos ao mesmo tempo (combine-sink) ----
    function mirrorHas(name) { return root.mirrorSel.indexOf(name) >= 0; }
    function toggleMirrorMode() {
        root.mirrorMode = !root.mirrorMode;
        if (root.mirrorMode) {
            // entra no modo espelho: semeia a selecao com o dispositivo ativo atual
            if (root.mirrorSel.length === 0) {
                var sel = [];
                for (var i = 0; i < audioSinks.length; i++) if (audioSinks[i].active) sel.push(audioSinks[i].name);
                root.mirrorSel = sel;
            }
        } else {
            // sai do modo espelho: desfaz o combine, volta pro 1o dispositivo
            root.mirrorSel = [];
            Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh", "mirror-off"]);
            audioRefresh.restart();
        }
    }
    function toggleMirrorDev(name) {
        var sel = root.mirrorSel.slice();
        var idx = sel.indexOf(name);
        if (idx >= 0) sel.splice(idx, 1); else sel.push(name);
        root.mirrorSel = sel;
        root.applyMirror();
    }
    function applyMirror() {
        if (root.mirrorSel.length >= 2) {
            Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh", "mirror", root.mirrorSel.join(",")]);
            root.bassOn = false;   // bass e espelho nao convivem
        } else if (root.mirrorSel.length === 1) {
            Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh", "output", root.mirrorSel[0]]);
        } else {
            Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh", "mirror-off"]);
        }
        audioRefresh.restart();
    }
    function setAppVol(id, f) { var p = Math.round(Math.max(0, Math.min(1, f)) * 100);
                                Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh", "app-vol", "" + id, "" + p]); }
    // redireciona saida do app para o sink indicado e reavalia
    function setAppOutput(ids, sink) {
        Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh", "app-output", "" + ids, sink]);
        audioRefresh.restart();
    }
    // retorna objeto de audioSinks com name igual ao informado, ou null
    function sinkByName(name) {
        for (var i = 0; i < audioSinks.length; i++) if (audioSinks[i].name === name) return audioSinks[i];
        return null;
    }
    // retorna o name do sink ativo (active === true), ou string vazia
    function defaultSinkName() {
        for (var i = 0; i < audioSinks.length; i++) if (audioSinks[i].active) return audioSinks[i].name;
        return "";
    }
    // glyph nerdfont por tipo de dispositivo (headphones/tv/usb/speaker)
    function sinkGlyph(icon) {
        return icon === "headphones" ? "󰋋" : (icon === "tv" ? "󰔂" : (icon === "usb" ? "󰕓" : "󰓃"));
    }
    function toggleAppMute(id) { Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh", "app-mute", "" + id]); audioRefresh.restart(); }
    // glyph por app (nerd font) pra identificar quem ta tocando no mixer
    function appIcon(name) {
        var n = (name || "").toLowerCase();
        if (n.indexOf("brave") >= 0) return "󰖟";
        if (n.indexOf("firefox") >= 0) return "󰈹";
        if (n.indexOf("chrom") >= 0) return "󰊯";
        if (n.indexOf("mpv") >= 0 || n.indexOf("vlc") >= 0 || n.indexOf("video") >= 0) return "󰕧";
        if (n.indexOf("spotify") >= 0) return "󰓇";
        if (n.indexOf("discord") >= 0) return "󰙯";
        if (n.indexOf("steam") >= 0) return "󰓓";
        if (n.indexOf("telegram") >= 0) return "󰔁";
        if (n.indexOf("sdl") >= 0 || n.indexOf("game") >= 0) return "󰊗";
        return "󰝚";
    }
    function toggleBassNew() { root.bassOn = !root.bassOn;
                               Quickshell.execDetached(["/home/lucas/.config/quickshell/scripts/audio.sh", "bass-toggle"]); audioRefresh.restart(); }
    Timer { id: audioRefresh; interval: 600; repeat: false; onTriggered: root.refreshAudio() }

    // ============ GPU (NVIDIA): temperatura + uso, por polling ============
    QtObject { id: gpu; property int temp: 0; property int util: 0; property bool ok: false }
    Process {
        id: gpuProc
        command: ["sh", "-c",
            "nvidia-smi --query-gpu=temperature.gpu,utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1"]
        stdout: StdioCollector {
            onStreamFinished: {
                var t = this.text.trim();
                if (!t) { gpu.ok = false; return; }
                var p = t.split(",");
                gpu.temp = parseInt(p[0]) || 0; gpu.util = parseInt(p[1]) || 0; gpu.ok = true;
            }
        }
    }
    Timer { interval: 10000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: gpuProc.running = true }

    // ============ notificacoes (historico do mako) ============
    property var notifs: []
    Process {
        id: notifProc
        command: ["makoctl", "history", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var arr = JSON.parse(this.text);
                    if (arr && arr.data) arr = arr.data[0] || [];   // tolera formato aninhado
                    root.notifs = arr || [];
                } catch (e) { root.notifs = []; }
            }
        }
        Component.onCompleted: running = true
    }
    function refreshNotifs() { notifProc.running = true; }

    // ============ player de midia (MPRIS) ============
    // escolhe o player tocando; senao o primeiro disponivel
    property var player: {
        var ps = (Mpris.players && Mpris.players.values) ? Mpris.players.values : [];
        var any = null;
        for (var i = 0; i < ps.length; i++) {
            if (!any) any = ps[i];
            if (ps[i].playbackState === MprisPlaybackState.Playing) return ps[i];
        }
        return any;
    }
    property bool hasPlayer: !!player

    // ============ Alt+Tab estilo Windows (thumbnails ao vivo) ============
    property bool attOpen: false
    property int attIndex: 0
    property var attList: []      // toplevels exibidos (ordem MRU), montado ao abrir
    property var attMru: []       // toplevels por uso recente (mais recente primeiro)
    property var attScreen: null  // monitor onde o overlay abre (stash de bar.screen)
    property var attBars: ({})    // nome do monitor -> ShellScreen (pra abrir no monitor focado)

    function attTouch(tl) {
        var a = attMru.filter(function (x) { return x !== tl; });
        a.unshift(tl);
        attMru = a;
    }
    function attForget(tl) {
        attMru = attMru.filter(function (x) { return x !== tl; });
    }
    // monta a lista exibida: MRU primeiro, depois quaisquer janelas ainda nao focadas
    function attBuildList() {
        var all = ToplevelManager.toplevels.values;
        var ordered = [];
        for (var i = 0; i < attMru.length; i++)
            if (all.indexOf(attMru[i]) >= 0) ordered.push(attMru[i]);
        for (var j = 0; j < all.length; j++)
            if (ordered.indexOf(all[j]) < 0) ordered.push(all[j]);
        return ordered;
    }
    function attStart(dir) {
        attList = attBuildList();
        if (attList.length === 0) return;
        // 1o Alt+Tab seleciona a janela ANTERIOR (index 1), como no Windows
        attIndex = attList.length > 1 ? (dir > 0 ? 1 : attList.length - 1) : 0;
        attOpen = true;
    }
    function attStep(dir) {
        if (attList.length === 0) return;
        attIndex = (attIndex + dir + attList.length) % attList.length;
    }
    // miniatura de tamanho FIXO (faixa horizontal normal). So calcula quantas
    // cabem na largura da tela; o resto desce pra uma nova fileira embaixo.
    function attLayout(n, availW, availH) {
        var tw = 240, th = 176, gap = 14, pad = 20;
        if (n < 1) return { cols: 1, rows: 1, tw: tw, th: th, gap: gap, pad: pad };
        var innerW = Math.max(1, availW - 2 * pad);
        var cols = Math.max(1, Math.floor((innerW + gap) / (tw + gap)));
        cols = Math.min(cols, n);
        var rows = Math.ceil(n / cols);
        return { cols: cols, rows: rows, tw: tw, th: th, gap: gap, pad: pad };
    }
    function attConfirm() {
        var tl = (attOpen && attList[attIndex]) ? attList[attIndex] : null;
        attOpen = false;   // fecha e solta o teclado ANTES de focar
        if (!tl) return;
        // usa o mesmo restore da taskbar: foca OU restaura minimizada (special:minimized)
        // pro workspace/monitor de origem. activate() cru nao lida com minimizada.
        if (tl.appId && tl.appId.length)
            Quickshell.execDetached([
                "/home/lucas/.config/quickshell/scripts/taskbar-activate.sh",
                tl.appId, tl.title || "", "max"]);
        else
            tl.activate();
    }

    // rastreia MRU observando .activated de cada janela (sem hyprctl)
    Instantiator {
        model: ToplevelManager.toplevels
        delegate: QtObject {
            required property var modelData
            property bool act: modelData.activated
            onActChanged: if (act) root.attTouch(modelData)
            Component.onCompleted: if (modelData.activated) root.attTouch(modelData)
            Component.onDestruction: root.attForget(modelData)
        }
    }

    IpcHandler {
        target: "alttab"
        function next(mon: string): void {
            if (root.attOpen) { root.attStep(1); return; }
            if (mon && root.attBars[mon]) root.attScreen = root.attBars[mon];
            root.attStart(1);
        }
        function prev(mon: string): void {
            if (root.attOpen) { root.attStep(-1); return; }
            if (mon && root.attBars[mon]) root.attScreen = root.attBars[mon];
            root.attStart(-1);
        }
        function confirm(): void { root.attConfirm(); }
        function cancel(): void { root.attOpen = false; }
    }

    // abre/fecha a central de acoes (e opcionalmente ja numa view, ex: wall)
    IpcHandler {
        target: "ac"
        function open(view: string): void {
            root.acScreen = Quickshell.screens[0];
            if (view) card.view = view;
            root.acOpen = true;
        }
        function close(): void { root.acOpen = false; }
    }

    // uma barra por monitor
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: bar
            property var modelData
            screen: modelData
            // registra o screen de cada monitor (por nome) p/ o overlay abrir no monitor focado
            Component.onCompleted: {
                if (bar.screen) root.attBars[bar.screen.name] = bar.screen;
                if (!root.attScreen) root.attScreen = bar.screen;
            }

            anchors { bottom: true; left: true; right: true }
            // ilhas flutuantes: janela ocupa a faixa toda mas e transparente
            implicitHeight: ui.islandHeight + ui.barMargin * 2
            // reserva a ilha + vao em cima E embaixo (barra totalmente solta; janelas nao encostam no topo da barra)
            exclusiveZone: ui.islandHeight + ui.barMargin * 2
            color: "transparent"

            // mask de input: so as 3 ilhas recebem clique; os vaos transparentes
            // deixam o clique passar pra janela de baixo
            mask: Region {
                Region { item: islandLeft }
                Region { item: islandCenter }
                Region { item: islandRight }
            }

            // ---- agrupa as janelas por appId ----
            property var groups: {
                var map = {};
                var order = [];
                var list = ToplevelManager.toplevels.values;
                for (var i = 0; i < list.length; i++) {
                    var t = list[i];
                    var id = (t.appId && t.appId.length) ? t.appId : "desconhecido";
                    if (!map[id]) { map[id] = []; order.push(id); }
                    map[id].push(t);
                }
                return order.map(function (k) { return { appId: k, wins: map[k] }; });
            }

            // ---- ilha esquerda: menu Omarchy + batimentos do PC ----
            Rectangle {
                id: islandLeft
                anchors.left: parent.left
                anchors.leftMargin: ui.barMargin
                anchors.verticalCenter: parent.verticalCenter
                height: ui.islandHeight
                width: leftRow.implicitWidth + ui.islandPadH * 2
                radius: ui.islandRadius
                color: Qt.alpha(theme.bg, ui.islandOpacity)
                border.width: 1
                border.color: Qt.alpha(theme.accent, 0.2)
                RowLayout {
                    id: leftRow
                    anchors.centerIn: parent
                    spacing: ui.moduleSpacing

                    // menu Omarchy
                    Text {
                    text:""
                    font.family: "omarchy"
                    font.pixelSize: 20
                    color: theme.fg
                    Layout.alignment: Qt.AlignVCenter
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["omarchy-menu"])
                    }
                }

            // ---- "batimentos" do PC: o coracao bate mais rapido sob estresse ----
            // estresse 0..1 = pior entre CPU (peso cheio), RAM (>50%) e temp da GPU (>45C).
            // bpm 60 (tranquilo) -> 160 (correndo); cor verde -> ambar -> vermelho.
            Row {
                id: heartBeat
                Layout.alignment: Qt.AlignVCenter
                spacing: 5
                property real stress: Math.max(0, Math.min(1, Math.max(
                    sys.cpu / 100,
                    Math.max(0, (sys.mem - 50) / 50),
                    Math.max(0, (gpu.temp - 45) / 45))))
                property int bpm: Math.round(60 + heartBeat.stress * 100)

                // cor do batimento conforme o estresse (verde -> ambar -> vermelho)
                property string beatColor: heartBeat.stress > 0.75 ? theme.danger
                                           : (heartBeat.stress > 0.45 ? theme.warn : theme.ok)

                Text {
                    id: heart
                    anchors.verticalCenter: parent.verticalCenter
                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14
                    text: "󰋑"
                    color: heartBeat.beatColor
                    transformOrigin: Item.Center
                }

                // ---- gráfico ECG: linha que rola com o pico no ritmo do bpm ----
                Canvas {
                    id: ecg
                    anchors.verticalCenter: parent.verticalCenter
                    width: 64; height: 20
                    property var buf: []
                    property int cols: 42
                    property real phase: 0           // ms acumulados desde a ultima batida
                    property int interval: 30        // ms por amostra (= intervalo do timer)
                    property int spikeIdx: -1        // posicao atual dentro do pico (QRS)
                    // formato do pico cardiaco (R grande, q/s pequenos), em amostras
                    readonly property var shape: [0.0, -0.12, 0.06, 1.0, -0.5, 0.12, 0.0, 0.0]

                    Component.onCompleted: { var a = []; for (var i = 0; i < cols; i++) a.push(0); buf = a; }

                    function step() {
                        phase += interval;
                        var period = 60000 / heartBeat.bpm;
                        if (phase >= period) { phase -= period; spikeIdx = 0; beatAnim.restart(); }
                        var v = 0;
                        if (spikeIdx >= 0 && spikeIdx < shape.length) { v = shape[spikeIdx]; spikeIdx++; }
                        else spikeIdx = -1;
                        buf.push(v); if (buf.length > cols) buf.shift();
                        requestPaint();
                    }
                    Timer { interval: ecg.interval; running: true; repeat: true; onTriggered: ecg.step() }

                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        ctx.strokeStyle = heartBeat.beatColor;
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
                    anchors.verticalCenter: parent.verticalCenter
                    color: theme.fgDim; font.pixelSize: 10
                    text: heartBeat.bpm + " bpm"
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
                }
            }

            // ---- taskbar agrupada (CENTRO da tela) ----
            Rectangle {
                id: islandCenter
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                height: ui.islandHeight
                width: taskRow.implicitWidth + ui.islandPadH * 2
                visible: bar.groups.length > 0
                radius: ui.islandRadius
                color: Qt.alpha(theme.bg, ui.islandOpacity)
                border.width: 1
                border.color: Qt.alpha(theme.accent, 0.2)
                RowLayout {
                    id: taskRow
                    anchors.centerIn: parent
                    spacing: 4
                Repeater {
                    model: bar.groups
                        delegate: Rectangle {
                            id: appBtn
                            required property var modelData
                            property var wins: modelData.wins
                            property bool anyActive: {
                                for (var i = 0; i < wins.length; i++)
                                    if (wins[i].activated) return true;
                                return false;
                            }
                            implicitWidth: 40
                            implicitHeight: 32
                            radius: 8
                            color: anyActive ? Qt.alpha(theme.accent, 0.2) : (hov.hovered ? Qt.alpha(theme.accent, 0.13) : "transparent")

                            HoverHandler { id: hov }
                            // lista de janelas no hover: aberta enquanto hover no icone OU
                            // na lista; 250ms de tolerancia pra atravessar o vao ate o popup
                            property bool showList: hov.hovered || listHover.hovered
                            Timer { id: hideTimer; interval: 250; repeat: false }
                            onShowListChanged: showList ? hideTimer.stop() : hideTimer.restart()

                            Image {
                                anchors.centerIn: parent
                                width: 22; height: 22
                                fillMode: Image.PreserveAspectFit
                                source: {
                                    // dependencia reativa: DesktopEntries carrega ~2s depois do
                                    // boot; ao mudar de 0 p/ N apps, este binding re-avalia.
                                    var ready = DesktopEntries.applications.values.length;
                                    var id = appBtn.modelData.appId;
                                    var de = DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id);
                                    var icon = (de && de.icon && de.icon.length) ? de.icon : id;
                                    // jogos Steam: a janela e steam_app_<id>, mas o icone no tema e steam_icon_<id>
                                    if (id.indexOf("steam_app_") === 0) icon = "steam_icon_" + id.substring(10);
                                    return Quickshell.iconPath(icon, "application-x-executable");
                                }
                            }

                            // uma bolinha por janela (a janela ativa fica mais larga)
                            Row {
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 1
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: 3
                                Repeater {
                                    // no maximo 4 bolinhas (senao vaza pro lado do icone)
                                    model: Math.min(appBtn.wins.length, 4)
                                    delegate: Rectangle {
                                        required property int index
                                        width: (appBtn.wins[index] && appBtn.wins[index].activated) ? 9 : 4
                                        height: 3; radius: 1.5
                                        color: theme.accent
                                        Behavior on width { NumberAnimation { duration: 150 } }
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                onClicked: function (e) {
                                    if (e.button === Qt.MiddleButton) { return; }
                                    // script faz focus-OU-restore via hyprctl: se a janela do
                                    // app estiver minimizada (special:minimized) ela e restaurada
                                    // pro monitor de origem; senao foca/cicla. Evita activate()
                                    // cru, que trazia o overlay especial e travava.
                                    Quickshell.execDetached([
                                        "/home/lucas/.config/quickshell/scripts/taskbar-activate.sh",
                                        appBtn.modelData.appId]);
                                }
                            }

                            // popup: lista de janelas (nomes) no hover, clicaveis
                            PopupWindow {
                                id: winPopup
                                // ancora no proprio icone (rastreado automaticamente):
                                // acima dele (edge Top, cresce pra cima)
                                anchor.item: appBtn
                                anchor.edges: Edges.Top
                                anchor.gravity: Edges.Top
                                implicitWidth: 230
                                implicitHeight: listCol.implicitHeight + 12
                                visible: appBtn.showList || hideTimer.running
                                color: "transparent"

                                Rectangle {
                                    anchors.fill: parent
                                    radius: 10
                                    color: theme.bg
                                    border.color: Qt.alpha(theme.accent, 0.2)
                                    border.width: 1
                                    HoverHandler { id: listHover }

                                    ColumnLayout {
                                        id: listCol
                                        anchors.fill: parent
                                        anchors.margins: 6
                                        spacing: 2
                                        Repeater {
                                            model: appBtn.wins.length
                                            delegate: Rectangle {
                                                required property int index
                                                property var win: appBtn.wins[index]
                                                Layout.fillWidth: true
                                                implicitHeight: 28
                                                radius: 6
                                                color: rowHover.hovered ? Qt.alpha(theme.accent, 0.2)
                                                       : ((win && win.activated) ? Qt.alpha(theme.accent, 0.13) : "transparent")
                                                HoverHandler { id: rowHover }
                                                RowLayout {
                                                    anchors.fill: parent
                                                    anchors.leftMargin: 9; anchors.rightMargin: 6
                                                    spacing: 4
                                                    // titulo: clique foca/restaura a janela
                                                    Text {
                                                        Layout.fillWidth: true
                                                        color: theme.fg; font.pixelSize: 12
                                                        elide: Text.ElideRight
                                                        text: (win && win.title && win.title.length)
                                                              ? win.title : appBtn.modelData.appId
                                                        MouseArea {
                                                            anchors.fill: parent
                                                            cursorShape: Qt.PointingHandCursor
                                                            onClicked: {
                                                                if (!win) return;
                                                                Quickshell.execDetached([
                                                                    "/home/lucas/.config/quickshell/scripts/taskbar-activate.sh",
                                                                    appBtn.modelData.appId, win.title || ""]);
                                                            }
                                                        }
                                                    }
                                                    // X: fecha a janela direto (sem precisar focar nela)
                                                    Rectangle {
                                                        Layout.preferredWidth: 20; Layout.preferredHeight: 20
                                                        radius: 5
                                                        color: xHover.hovered ? Qt.alpha(theme.danger, 0.2) : "transparent"
                                                        Text {
                                                            anchors.centerIn: parent
                                                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 12
                                                            color: xHover.hovered ? theme.danger : theme.fgDim
                                                            text: "󰅖"
                                                        }
                                                        HoverHandler { id: xHover }
                                                        MouseArea {
                                                            anchors.fill: parent
                                                            cursorShape: Qt.PointingHandCursor
                                                            onClicked: { if (win) win.close(); }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ---- ilha direita: status ----
            Rectangle {
                id: islandRight
                anchors.right: parent.right
                anchors.rightMargin: ui.barMargin
                anchors.verticalCenter: parent.verticalCenter
                height: ui.islandHeight
                width: rightRow.implicitWidth + ui.islandPadH * 2
                radius: ui.islandRadius
                color: Qt.alpha(theme.bg, ui.islandOpacity)
                border.width: 1
                border.color: Qt.alpha(theme.accent, 0.2)
                RowLayout {
                    id: rightRow
                    property bool clusterExpanded: false
                    anchors.centerIn: parent
                    spacing: ui.moduleSpacing

                // ---- player de midia: so um icone play/pause (titulo fica na central) ----
                // clique esquerdo = play/pause; clique direito = abre a central com o player
                Text {
                    visible: root.hasPlayer
                    Layout.alignment: Qt.AlignVCenter
                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15; color: theme.accent
                    text: (root.player && root.player.playbackState === MprisPlaybackState.Playing) ? "󰏤" : "󰐊"
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: function (e) {
                            if (e.button === Qt.RightButton) { root.acScreen = bar.screen; root.acOpen = true; }
                            else if (root.player) root.player.togglePlaying();
                        }
                    }
                }

                // ---- botao recolher/expandir o cluster (tray + metricas) ----
                Text {
                    id: clusterToggle
                    Layout.alignment: Qt.AlignVCenter
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 14
                    color: rightRow.clusterExpanded ? theme.accent : theme.fgDim
                    text: rightRow.clusterExpanded ? "󰅁" : "󰅂"   // expandido: recolher (esq); recolhido: expandir (dir)
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: rightRow.clusterExpanded = !rightRow.clusterExpanded
                    }
                }

                // ---- cluster recolhivel: tray + update + cpu + ram + gpu ----
                Item {
                    id: clusterBox
                    clip: true
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredHeight: ui.islandHeight
                    Layout.preferredWidth: rightRow.clusterExpanded ? clusterRow.implicitWidth : 0
                    Behavior on Layout.preferredWidth {
                        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                    }
                    RowLayout {
                        id: clusterRow
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: ui.moduleSpacing

                // ---- system tray ----
                RowLayout {
                    spacing: 8
                    Layout.alignment: Qt.AlignVCenter
                    Repeater {
                        model: SystemTray.items
                        delegate: Item {
                            required property var modelData
                            implicitWidth: 20; implicitHeight: 20
                            Image {
                                anchors.centerIn: parent
                                width: 18; height: 18
                                fillMode: Image.PreserveAspectFit
                                source: modelData.icon
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                onClicked: function (e) {
                                    if (e.button === Qt.MiddleButton) { modelData.secondaryActivate(); return; }
                                    // Steam: activate() nao restaura a janela quando esta fechado
                                    // pra bandeja. O steam:// abre a janela principal da instancia ativa.
                                    var id = ("" + (modelData.id || "") + (modelData.title || "")).toLowerCase();
                                    if (id.indexOf("steam") !== -1)
                                        Quickshell.execDetached(["steam", "steam://open/main"]);
                                    else
                                        modelData.activate();
                                }
                            }
                        }
                    }
                }

                // ---- update do Omarchy disponivel ----
                Text {
                    visible: omup.avail
                    Layout.alignment: Qt.AlignVCenter
                    color: theme.warn
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 14
                    text: "󰚰"
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["kitty", "-e", "omarchy-update"])
                    }
                }

                // ---- cpu ----
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    color: theme.fg
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 13
                    text: "󰓅 " + sys.cpu + "%"
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["kitty", "btop"])
                    }
                }

                // ---- ram ----
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    color: theme.fg
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 13
                    text: "󰍛 " + sys.mem + "%"
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["kitty", "btop"])
                    }
                }

                // ---- gpu: temperatura (vermelho quando quente) ----
                Text {
                    visible: gpu.ok
                    Layout.alignment: Qt.AlignVCenter
                    color: gpu.temp >= 80 ? theme.danger : theme.fg
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 13
                    text: "󰢮 " + gpu.temp + "°"
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["sh", "-c", "kitty -e sh -c 'watch -n1 nvidia-smi'"])
                    }
                }

                // ---- bateria: indicador grafico que enche conforme a carga ----
                // (sem numero; cheio = 100%, vermelho quando baixa, verde carregando)
                Item {
                    id: battWidget
                    visible: UPower.displayDevice && UPower.displayDevice.isLaptopBattery
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: 30
                    implicitHeight: 14
                    property var dev: UPower.displayDevice
                    // percentage do Quickshell e 0.0-1.0
                    property real frac: dev ? Math.max(0, Math.min(1, dev.percentage)) : 0
                    property bool chg: dev && (dev.state === UPowerDeviceState.Charging
                                               || dev.state === UPowerDeviceState.FullyCharged)

                    Rectangle {
                        id: battBody
                        width: 26; height: 13
                        anchors.verticalCenter: parent.verticalCenter
                        radius: 3
                        color: "transparent"
                        border.color: theme.fg
                        border.width: 1.5

                        // preenchimento proporcional a carga
                        Rectangle {
                            anchors.left: parent.left
                            anchors.leftMargin: 2
                            anchors.verticalCenter: parent.verticalCenter
                            height: parent.height - 4
                            width: Math.max(0, (parent.width - 4) * battWidget.frac)
                            radius: 1.5
                            color: battWidget.chg ? theme.ok
                                   : (battWidget.frac <= 0.15 ? theme.danger : theme.accent)
                            Behavior on width { NumberAnimation { duration: 300 } }
                        }
                    }
                    // polo (nub) na ponta direita
                    Rectangle {
                        anchors.left: battBody.right
                        anchors.leftMargin: 1
                        anchors.verticalCenter: parent.verticalCenter
                        width: 2.5; height: 6; radius: 1
                        color: theme.fg
                    }
                }

                // ---- mic mutado: so aparece quando o microfone esta mudo ----
                Text {
                    visible: tg.micMuted
                    Layout.alignment: Qt.AlignVCenter
                    color: theme.danger
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 14
                    text: "󰍭"
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleMic()
                    }
                }

                // ---- notificacoes: sino abre a central na view de notificacoes ----
                Item {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: 18; implicitHeight: 18
                    Text {
                        anchors.centerIn: parent
                        color: theme.fg; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14
                        text: "󰂚"
                    }
                    Rectangle {
                        visible: root.notifs.length > 0
                        anchors.right: parent.right; anchors.top: parent.top
                        width: 6; height: 6; radius: 3; color: theme.danger
                    }
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: { root.acScreen = bar.screen; card.view = "notif"; root.refreshNotifs(); root.acOpen = true; }
                    }
                }

                    } // fim clusterRow
                } // fim clusterBox

                // ---- chevron: abre a central de acoes ----
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    color: root.acOpen ? theme.accent : theme.fg
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 16
                    text: root.acOpen ? "󰅀" : "󰅃"
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.acScreen = bar.screen; root.acOpen = !root.acOpen; }
                    }
                }

                // relogio
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    color: theme.fg
                    font.pixelSize: 13
                    text: clock.date.toLocaleString(Qt.locale("pt_BR"), "ddd dd/MM  HH:mm")
                }
                }
            }
            RectangularShadow {
                anchors.fill: islandLeft
                radius: islandLeft.radius
                blur: ui.shadowBlur
                spread: 0
                offset: Qt.vector2d(0, 2)
                color: Qt.rgba(0, 0, 0, ui.shadowOpacity)
                cached: true
                z: -1
            }
            RectangularShadow {
                anchors.fill: islandCenter
                radius: islandCenter.radius
                blur: ui.shadowBlur
                spread: 0
                offset: Qt.vector2d(0, 2)
                color: Qt.rgba(0, 0, 0, ui.shadowOpacity)
                cached: true
                z: -1
                visible: islandCenter.visible
            }
            RectangularShadow {
                anchors.fill: islandRight
                radius: islandRight.radius
                blur: ui.shadowBlur
                spread: 0
                offset: Qt.vector2d(0, 2)
                color: Qt.rgba(0, 0, 0, ui.shadowOpacity)
                cached: true
                z: -1
            }
        }
    }

    // ============ Central de acoes (dropdown estilo Windows) ============
    // UMA janela fullscreen: backdrop (fecha ao clicar fora) + card por cima.
    // (Duas janelas layer-shell separadas na mesma camada brigavam pelo z-order
    // e o backdrop engolia todos os cliques do card.)
    PanelWindow {
        id: ac
        // fica mapeada enquanto a animacao de fechar roda (ate o fade terminar)
        visible: root.acOpen || card.opacity > 0.01
        onVisibleChanged: if (!visible) { card.view = "main";   // sempre reabre na view principal
                          if (Bluetooth.defaultAdapter) Bluetooth.defaultAdapter.discovering = false; }
        screen: root.acScreen ? root.acScreen : Quickshell.screens[0]
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qsbar-ac"
        // OnDemand normal; Exclusive enquanto a linha de senha do wifi esta aberta
        // (garante que a digitacao caia no campo no overlay layer-shell)
        WlrLayershell.keyboardFocus: (card.view === "wifi" && wifiCol.wifiSel !== "")
                                     ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

        // backdrop: clique fora do card fecha
        MouseArea { anchors.fill: parent; onClicked: root.acOpen = false }

        Rectangle {
            id: card
            property string view: "main"   // "main" | "wifi" | "bt" | "notif" | "perso" | "wall" | "audio"
            onViewChanged: { if (view === "wifi") root.refreshWifi();
                             else if (view === "notif") root.refreshNotifs();
                             else if (view === "wall") root.wpaLoadCycle();
                             else if (view === "audio") root.refreshAudio();
                             else if (view === "bt" && Bluetooth.defaultAdapter && Bluetooth.defaultAdapter.enabled)
                                  Bluetooth.defaultAdapter.discovering = true; }
            // animacao de abrir/fechar: fade + leve slide de baixo pra cima
            opacity: root.acOpen ? 1 : 0
            property real slide: root.acOpen ? 0 : 14
            transform: Translate { y: card.slide }
            Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            Behavior on slide { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            width: 340
            implicitHeight: (view === "wifi" ? wifiCol.implicitHeight
                             : (view === "bt" ? btCol.implicitHeight
                             : (view === "notif" ? notifCol.implicitHeight
                             : (view === "wall" ? wallCol.implicitHeight
                             : (view === "audio" ? audioCol.implicitHeight
                             : (view === "perso" ? persoCol.implicitHeight : acCol.implicitHeight)))))) + 28
            height: implicitHeight
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 8
            anchors.bottomMargin: ui.islandHeight + ui.barMargin * 2 + 6
            radius: 16
            color: Qt.alpha(theme.bg, 0.75)
            border.color: Qt.alpha(theme.accent, 0.2)
            border.width: 1

            // absorve cliques no card pra nao fechar ao clicar em espaco vazio
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: acCol
                visible: card.view === "main"
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 14
                spacing: 14

                // secao: tocando agora (so quando ha player)
                Text {
                    visible: root.hasPlayer
                    text: "Tocando agora"
                    color: theme.fgDim; font.pixelSize: 11; font.bold: true
                }

                // player de midia (MPRIS): capa + faixa + controles
                Rectangle {
                    Layout.fillWidth: true
                    visible: root.hasPlayer
                    implicitHeight: 64; radius: 12
                    color: theme.bgAlt
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 10
                        anchors.topMargin: 8; anchors.bottomMargin: 8
                        spacing: 10
                        // capa (ou glyph quando nao ha arte)
                        Item {
                            Layout.preferredWidth: 48; Layout.preferredHeight: 48
                            Image {
                                id: artImg
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectCrop
                                source: (root.player && root.player.trackArtUrl) ? root.player.trackArtUrl : ""
                                visible: status === Image.Ready
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: artImg.status !== Image.Ready
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 26; color: theme.accent
                                text: "󰝚"
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 1
                            Text {
                                Layout.fillWidth: true; color: theme.fgBright; font.pixelSize: 12; font.bold: true
                                elide: Text.ElideRight
                                text: root.player ? (root.player.trackTitle || "—") : "—"
                            }
                            Text {
                                Layout.fillWidth: true; color: theme.fg; font.pixelSize: 11
                                elide: Text.ElideRight
                                text: root.player ? (root.player.trackArtist || "") : ""
                            }
                        }
                        Text {
                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: theme.fg; text: "󰒮"
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: if (root.player) root.player.previous() }
                        }
                        Text {
                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 22; color: theme.accent
                            text: (root.player && root.player.playbackState === MprisPlaybackState.Playing) ? "󰏤" : "󰐊"
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: if (root.player) root.player.togglePlaying() }
                        }
                        Text {
                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: theme.fg; text: "󰒭"
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: if (root.player) root.player.next() }
                        }
                    }
                }

                // volume: glyph + slider + %
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: vols.mut ? "󰝟" : "󰕾"
                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18
                        color: theme.fg
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: root.toggleVolMute()
                        }
                    }
                    // area de arraste alta (20px); controla o device de saida real (vol.sh)
                    Item {
                        Layout.fillWidth: true
                        implicitHeight: 20
                        Rectangle {
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            height: 6; radius: 3; color: theme.surface
                            Rectangle {
                                width: parent.width * (vols.mut ? 0 : vols.vol)
                                height: parent.height; radius: 3; color: theme.accent
                            }
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onPressed: function (e) { root.volDragging = true; root.setVolReal(e.x / width); }
                            onPositionChanged: function (e) { if (pressed) root.setVolReal(e.x / width); }
                            onReleased: { root.volDragging = false; root.refreshVol(); }
                        }
                    }
                    Text {
                        Layout.preferredWidth: 32
                        text: Math.round(vols.vol * 100) + "%"
                        color: theme.fg; font.pixelSize: 12; horizontalAlignment: Text.AlignRight
                    }
                    // abre o painel de audio (dispositivos de saida + volume por app)
                    Text {
                        text: "󰓃"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16
                        color: audOpenMa.containsMouse ? theme.accent : theme.fg
                        MouseArea { id: audOpenMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.refreshAudio(); card.view = "audio" } }
                    }
                }

                // secao: ajustes rapidos
                Text {
                    text: "Ajustes rápidos"
                    color: theme.fgDim; font.pixelSize: 11; font.bold: true
                }

                // toggles rapidos: caffeine, nightlight, mic
                // (Bass saiu daqui em 2026-06-24: da pra ver/ativar na aba "Som")
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: [
                            { key: "caf",   icon: "󰅶", label: "Caffeine" },
                            { key: "night", icon: "󰖔", label: "Noturno" },
                            { key: "mic",   icon: "󰍬", label: "Mic" }
                        ]
                        delegate: Rectangle {
                            required property var modelData
                            property bool on: modelData.key === "caf" ? tg.caffeine
                                            : (modelData.key === "night" ? tg.night
                                            : !tg.micMuted)
                            Layout.fillWidth: true
                            implicitHeight: 52; radius: 12
                            color: on ? Qt.alpha(theme.accent, 0.2) : theme.bgAlt
                            border.color: on ? theme.accent : "transparent"; border.width: 1
                            ColumnLayout {
                                anchors.centerIn: parent; spacing: 2
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 17
                                    color: on ? theme.accent : theme.fgDim
                                    text: (modelData.key === "mic" && tg.micMuted) ? "󰍭" : modelData.icon
                                }
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    color: theme.fg; font.pixelSize: 10
                                    text: modelData.label
                                }
                            }
                            MouseArea {
                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (modelData.key === "caf") root.toggleCaffeine();
                                    else if (modelData.key === "night") root.toggleNight();
                                    else root.toggleMic();
                                }
                            }
                        }
                    }
                }

                // pills: rede + bluetooth
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    // rede (info)
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 52; radius: 12
                        color: Qt.alpha(theme.accent, 0.13)
                        ColumnLayout {
                            anchors.centerIn: parent; spacing: 1
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: theme.accent
                                text: sys.net === "eth" ? "󰈀" : (sys.net.indexOf("wifi") === 0 ? "󰤨" : "󰤭")
                            }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                color: theme.fg; font.pixelSize: 11
                                elide: Text.ElideRight
                                Layout.maximumWidth: 120
                                text: sys.net === "eth" ? "Cabo"
                                      : (sys.net.indexOf("wifi") === 0 ? (sys.net.split(":").slice(1).join(":") || "Wi-Fi") : "Sem rede")
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { card.view = "wifi"; root.refreshWifi(); }
                        }
                    }
                    // bluetooth (toggle)
                    Rectangle {
                        id: btPill
                        Layout.fillWidth: true
                        implicitHeight: 52; radius: 12
                        property var adp: Bluetooth.defaultAdapter
                        property bool on: adp ? adp.enabled : false
                        color: on ? Qt.alpha(theme.accent, 0.2) : theme.bgAlt
                        border.color: on ? theme.accent : "transparent"; border.width: 1
                        ColumnLayout {
                            anchors.centerIn: parent; spacing: 1
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18
                                color: btPill.on ? theme.accent : theme.fgDim
                                text: btPill.on ? "󰂯" : "󰂲"
                            }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                color: theme.fg; font.pixelSize: 11
                                text: "Bluetooth"
                            }
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            // abre o painel de pareados (conecta/desconecta em QML puro).
                            // parear novos = botao bluetui dentro da view; NAO togglar o radio aqui
                            // (desligar desconectava o fone e o BlueZ nao reconectava sozinho).
                            onClicked: card.view = "bt"
                        }
                    }
                }

                // (bateria e clima removidos da central em 2026-06-24: ja aparecem na taskbar)

                // personalizacao: card proprio (tema + papel de parede)
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 46; radius: 12
                    color: persoMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : theme.bgAlt
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                        Text { font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: theme.accent; text: "󰉼" }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 0
                            Text { color: theme.fgBright; font.pixelSize: 12; font.bold: true; text: "Personalizacao" }
                            Text { color: theme.fgDim; font.pixelSize: 10; text: "Tema e papel de parede" }
                        }
                        Text { text: "󰅂"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14; color: theme.fgDim }
                    }
                    MouseArea {
                        id: persoMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { root.refreshThemes(); card.view = "perso" }
                    }
                }

                // acoes
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Repeater {
                        model: [
                            { icon: "󰍜", label: "Menu", cmd: ["omarchy-menu"] },
                            { icon: "󰐥", label: "Energia", cmd: ["sh", "-c", "omarchy-menu power || wlogout"] }
                        ]
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: 46; radius: 12
                            color: actMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : theme.bgAlt
                            ColumnLayout {
                                anchors.centerIn: parent; spacing: 2
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16; color: theme.fg
                                    text: modelData.icon
                                }
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    color: theme.fg; font.pixelSize: 10
                                    text: modelData.label
                                }
                            }
                            MouseArea {
                                id: actMa
                                anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { Quickshell.execDetached(modelData.cmd); root.acOpen = false; }
                            }
                        }
                    }
                }
            }

            // ---- view: lista de redes wifi (autossuficiente, iwd via wifi.sh) ----
            ColumnLayout {
                id: wifiCol
                visible: card.view === "wifi"
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 14
                spacing: 8

                property string wifiSel: ""    // ssid com a linha expandida (senha)
                // menu de contexto (botao direito)
                property string wifiMenuFor: ""
                property real wifiMenuX: 0
                property real wifiMenuY: 0
                property var wifiMenuData: ({})
                property bool wifiShowDetails: false

                // poll nao-bloqueante enquanto a view esta aberta
                Timer {
                    interval: 3000; repeat: true
                    running: card.view === "wifi" && root.acOpen
                    onRunningChanged: if (running) { root.scanWifi(); root.refreshWifi(); }
                    onTriggered: root.refreshWifi()
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        text: "󰁍"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: theme.fg
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: card.view = "main" }
                    }
                    ColumnLayout {
                        spacing: 0
                        Text { text: "Redes Wi-Fi"; color: theme.fg; font.pixelSize: 14; font.bold: true }
                        Text {
                            visible: root.wifiActive !== ""
                            text: "conectado: " + root.wifiActive.split("|")[0]
                            color: theme.ok; font.pixelSize: 10; elide: Text.ElideRight
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: "󰑐"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16
                        color: root.wifiBusy ? theme.accent : theme.fg
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.scanWifi(); root.refreshWifi(); } }
                    }
                }

                Repeater {
                    model: root.wifiNets
                    delegate: Rectangle {
                        id: netRow
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: rowCol.implicitHeight + 8; radius: 8
                        color: netRowMa.containsMouse ? Qt.alpha(theme.accent, 0.2)
                               : (modelData.conn ? Qt.alpha(theme.accent, 0.13) : "transparent")

                        ColumnLayout {
                            id: rowCol
                            anchors { left: parent.left; right: parent.right; top: parent.top }
                            anchors.leftMargin: 10; anchors.rightMargin: 10; anchors.topMargin: 4
                            spacing: 6

                            // linha principal (clicavel)
                            Item {
                                Layout.fillWidth: true
                                implicitHeight: 28
                                RowLayout {
                                    anchors.fill: parent
                                    spacing: 8
                                    Text {
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15; color: theme.accent
                                        text: netRow.modelData.sig >= 4 ? "󰤨" : (netRow.modelData.sig === 3 ? "󰤥"
                                              : (netRow.modelData.sig === 2 ? "󰤢" : (netRow.modelData.sig >= 1 ? "󰤟" : "󰤯")))
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        color: theme.fg; font.pixelSize: 12; elide: Text.ElideRight
                                        text: netRow.modelData.name
                                    }
                                    Text {
                                        visible: netRow.modelData.sec !== "open"
                                        text: "󰌾"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11; color: theme.fgDim
                                    }
                                    Text {
                                        visible: netRow.modelData.conn
                                        color: theme.ok; font.pixelSize: 10
                                        text: "conectado"
                                    }
                                }
                                MouseArea {
                                    id: netRowMa
                                    anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: function (mouse) {
                                        if (mouse.button === Qt.RightButton) {
                                            var pt = netRowMa.mapToItem(card, mouse.x, mouse.y);
                                            wifiCol.wifiMenuX = Math.max(8, Math.min(pt.x, card.width - 186));
                                            wifiCol.wifiMenuY = Math.max(8, Math.min(pt.y, card.height - 60));
                                            wifiCol.wifiMenuData = { conn: netRow.modelData.conn, known: netRow.modelData.known,
                                                                     sec: netRow.modelData.sec, name: netRow.modelData.name };
                                            wifiCol.wifiShowDetails = false;
                                            wifiCol.wifiMenuFor = netRow.modelData.name;
                                            return;
                                        }
                                        // esquerda: conecta direto (ou abre senha em rede nova protegida)
                                        if (netRow.modelData.conn) return;
                                        if (netRow.modelData.known || netRow.modelData.sec === "open")
                                            root.wifiCmd(["connect", netRow.modelData.name]);
                                        else
                                            wifiCol.wifiSel = (wifiCol.wifiSel === netRow.modelData.name ? "" : netRow.modelData.name);
                                    }
                                }
                            }

                            // expansao: senha (rede nova protegida) OU acoes (conectada/conhecida)
                            ColumnLayout {
                                visible: wifiCol.wifiSel === netRow.modelData.name
                                Layout.fillWidth: true; spacing: 6

                                RowLayout {
                                    visible: !netRow.modelData.conn && !netRow.modelData.known && netRow.modelData.sec !== "open"
                                    Layout.fillWidth: true; spacing: 6
                                    Rectangle {
                                        Layout.fillWidth: true; implicitHeight: 30; radius: 6
                                        color: theme.bgAlt; border.color: Qt.alpha(theme.accent, 0.3); border.width: 1
                                        TextInput {
                                            id: pwInput
                                            anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                                            verticalAlignment: TextInput.AlignVCenter
                                            color: theme.fg; font.pixelSize: 12
                                            echoMode: TextInput.Password; clip: true
                                            focus: wifiCol.wifiSel === netRow.modelData.name
                                            onVisibleChanged: if (visible) forceActiveFocus()
                                            onAccepted: { root.wifiCmd(["connect", netRow.modelData.name, text]); wifiCol.wifiSel = ""; }
                                        }
                                    }
                                    Rectangle {
                                        implicitWidth: 76; implicitHeight: 30; radius: 6; color: theme.accent
                                        Text { anchors.centerIn: parent; text: "Conectar"; color: theme.bg; font.pixelSize: 11; font.bold: true }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                            onClicked: { root.wifiCmd(["connect", netRow.modelData.name, pwInput.text]); wifiCol.wifiSel = ""; } }
                                    }
                                }

                            }
                        }
                    }
                }

                Text {
                    visible: root.wifiNets.length === 0
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    color: theme.fgDim; font.pixelSize: 11
                    text: "Procurando redes…"
                }
            }

            // ---- menu de contexto do wifi (botao direito) ----
            MouseArea {
                visible: card.view === "wifi" && wifiCol.wifiMenuFor !== ""
                anchors.fill: parent; z: 99
                acceptedButtons: Qt.AllButtons
                onClicked: { wifiCol.wifiMenuFor = ""; wifiCol.wifiShowDetails = false; }
            }
            Rectangle {
                id: wifiMenu
                visible: card.view === "wifi" && wifiCol.wifiMenuFor !== ""
                z: 100
                x: wifiCol.wifiMenuX; y: wifiCol.wifiMenuY
                width: 178
                implicitHeight: wifiMenuCol.implicitHeight + 12
                height: implicitHeight
                radius: 10
                color: theme.bgAlt
                border.color: Qt.alpha(theme.accent, 0.3); border.width: 1

                ColumnLayout {
                    id: wifiMenuCol
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    anchors.margins: 6
                    spacing: 2

                    Text {
                        Layout.fillWidth: true; Layout.margins: 4
                        text: wifiCol.wifiMenuData.name || ""
                        color: theme.fgBright; font.pixelSize: 11; font.bold: true; elide: Text.ElideRight
                    }

                    // Conectar (nao conectada)
                    Rectangle {
                        visible: !wifiCol.wifiShowDetails && !wifiCol.wifiMenuData.conn
                        Layout.fillWidth: true; implicitHeight: 30; radius: 6
                        color: cMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 8
                               text: "Conectar"; color: theme.fg; font.pixelSize: 12 }
                        MouseArea { id: cMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                var d = wifiCol.wifiMenuData;
                                if (!d.known && d.sec !== "open") wifiCol.wifiSel = d.name;   // abre senha inline
                                else root.wifiCmd(["connect", d.name]);
                                wifiCol.wifiMenuFor = "";
                            } }
                    }
                    // Desconectar (conectada)
                    Rectangle {
                        visible: !wifiCol.wifiShowDetails && wifiCol.wifiMenuData.conn
                        Layout.fillWidth: true; implicitHeight: 30; radius: 6
                        color: dMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 8
                               text: "Desconectar"; color: theme.fg; font.pixelSize: 12 }
                        MouseArea { id: dMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { root.wifiCmd(["disconnect"]); wifiCol.wifiMenuFor = ""; } }
                    }
                    // Esquecer (conhecida)
                    Rectangle {
                        visible: !wifiCol.wifiShowDetails && wifiCol.wifiMenuData.known
                        Layout.fillWidth: true; implicitHeight: 30; radius: 6
                        color: fMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 8
                               text: "Esquecer"; color: theme.warn; font.pixelSize: 12 }
                        MouseArea { id: fMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { root.wifiCmd(["forget", wifiCol.wifiMenuData.name]); wifiCol.wifiMenuFor = ""; } }
                    }
                    // Detalhes
                    Rectangle {
                        visible: !wifiCol.wifiShowDetails
                        Layout.fillWidth: true; implicitHeight: 30; radius: 6
                        color: deMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 8
                               text: "Detalhes"; color: theme.fg; font.pixelSize: 12 }
                        MouseArea { id: deMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { root.wifiFetchDetails(wifiCol.wifiMenuData.name); wifiCol.wifiShowDetails = true; } }
                    }

                    // lista de detalhes
                    Repeater {
                        model: wifiCol.wifiShowDetails ? root.wifiDetails : []
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true; Layout.leftMargin: 4; Layout.rightMargin: 4; spacing: 6
                            Text { text: modelData.k; color: theme.fgDim; font.pixelSize: 10 }
                            Item { Layout.fillWidth: true }
                            Text { text: modelData.v; color: theme.fg; font.pixelSize: 10; elide: Text.ElideRight }
                        }
                    }
                    Text {
                        visible: wifiCol.wifiShowDetails && root.wifiDetails.length === 0
                        Layout.fillWidth: true; Layout.margins: 4
                        text: "carregando…"; color: theme.fgDim; font.pixelSize: 10
                    }
                }
            }

            // ---- menu de contexto do bluetooth (botao direito) ----
            MouseArea {
                visible: card.view === "bt" && btCol.btMenuFor !== ""
                anchors.fill: parent; z: 99
                acceptedButtons: Qt.AllButtons
                onClicked: { btCol.btMenuFor = ""; btCol.btShowDetails = false; }
            }
            Rectangle {
                id: btMenu
                visible: card.view === "bt" && btCol.btMenuFor !== "" && btCol.btMenuDev
                z: 100
                x: btCol.btMenuX; y: btCol.btMenuY
                width: 178
                implicitHeight: btMenuCol.implicitHeight + 12
                height: implicitHeight
                radius: 10
                color: theme.bgAlt
                border.color: Qt.alpha(theme.accent, 0.3); border.width: 1

                ColumnLayout {
                    id: btMenuCol
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    anchors.margins: 6
                    spacing: 2

                    Text {
                        Layout.fillWidth: true; Layout.margins: 4
                        text: btCol.btMenuDev ? (btCol.btMenuDev.deviceName || btCol.btMenuDev.name || btCol.btMenuDev.address) : ""
                        color: theme.fgBright; font.pixelSize: 11; font.bold: true; elide: Text.ElideRight
                    }

                    // Conectar (pareado, desconectado)
                    Rectangle {
                        visible: !btCol.btShowDetails && btCol.btMenuDev
                                 && (btCol.btMenuDev.paired || btCol.btMenuDev.bonded) && !btCol.btMenuDev.connected
                        Layout.fillWidth: true; implicitHeight: 30; radius: 6
                        color: btcMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 8
                               text: "Conectar"; color: theme.fg; font.pixelSize: 12 }
                        MouseArea { id: btcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { btCol.btMenuDev.connect(); btCol.btMenuFor = ""; } }
                    }
                    // Desconectar (conectado)
                    Rectangle {
                        visible: !btCol.btShowDetails && btCol.btMenuDev && btCol.btMenuDev.connected
                        Layout.fillWidth: true; implicitHeight: 30; radius: 6
                        color: btdMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 8
                               text: "Desconectar"; color: theme.fg; font.pixelSize: 12 }
                        MouseArea { id: btdMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { btCol.btMenuDev.disconnect(); btCol.btMenuFor = ""; } }
                    }
                    // Parear (nao pareado)
                    Rectangle {
                        visible: !btCol.btShowDetails && btCol.btMenuDev
                                 && !(btCol.btMenuDev.paired || btCol.btMenuDev.bonded)
                        Layout.fillWidth: true; implicitHeight: 30; radius: 6
                        color: btpMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 8
                               text: "Parear"; color: theme.fg; font.pixelSize: 12 }
                        MouseArea { id: btpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { btCol.btMenuDev.pair(); btCol.btMenuFor = ""; } }
                    }
                    // Esquecer (pareado)
                    Rectangle {
                        visible: !btCol.btShowDetails && btCol.btMenuDev
                                 && (btCol.btMenuDev.paired || btCol.btMenuDev.bonded)
                        Layout.fillWidth: true; implicitHeight: 30; radius: 6
                        color: btfMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 8
                               text: "Esquecer"; color: theme.warn; font.pixelSize: 12 }
                        MouseArea { id: btfMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { btCol.btMenuDev.forget(); btCol.btMenuFor = ""; } }
                    }
                    // Detalhes
                    Rectangle {
                        visible: !btCol.btShowDetails
                        Layout.fillWidth: true; implicitHeight: 30; radius: 6
                        color: bteMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 8
                               text: "Detalhes"; color: theme.fg; font.pixelSize: 12 }
                        MouseArea { id: bteMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: btCol.btShowDetails = true }
                    }

                    // detalhes (direto do device, sem processo externo)
                    ColumnLayout {
                        visible: btCol.btShowDetails && btCol.btMenuDev
                        Layout.fillWidth: true; spacing: 2
                        RowLayout {
                            Layout.fillWidth: true; Layout.leftMargin: 4; Layout.rightMargin: 4; spacing: 6
                            Text { text: "Endereco"; color: theme.fgDim; font.pixelSize: 10 }
                            Item { Layout.fillWidth: true }
                            Text { text: btCol.btMenuDev ? btCol.btMenuDev.address : ""; color: theme.fg; font.pixelSize: 10 }
                        }
                        RowLayout {
                            Layout.fillWidth: true; Layout.leftMargin: 4; Layout.rightMargin: 4; spacing: 6
                            Text { text: "Estado"; color: theme.fgDim; font.pixelSize: 10 }
                            Item { Layout.fillWidth: true }
                            Text {
                                color: theme.fg; font.pixelSize: 10
                                text: !btCol.btMenuDev ? "" : (btCol.btMenuDev.connected ? "conectado"
                                      : ((btCol.btMenuDev.paired || btCol.btMenuDev.bonded) ? "pareado" : "disponivel"))
                            }
                        }
                        RowLayout {
                            visible: btCol.btMenuDev && btCol.btMenuDev.batteryAvailable
                            Layout.fillWidth: true; Layout.leftMargin: 4; Layout.rightMargin: 4; spacing: 6
                            Text { text: "Bateria"; color: theme.fgDim; font.pixelSize: 10 }
                            Item { Layout.fillWidth: true }
                            Text { text: btCol.btMenuDev ? Math.round(btCol.btMenuDev.battery * 100) + "%" : ""
                                   color: theme.fg; font.pixelSize: 10 }
                        }
                    }
                }
            }

            // ---- view: bluetooth (conexao rapida aos pareados) ----
            ColumnLayout {
                id: btCol
                visible: card.view === "bt"
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 14
                spacing: 8

                property var adp: Bluetooth.defaultAdapter

                // menu de contexto (botao direito)
                property string btMenuFor: ""
                property var btMenuDev: null
                property real btMenuX: 0
                property real btMenuY: 0
                property bool btShowDetails: false

                // cabecalho: voltar / titulo / escanear / abrir bluetui
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        text: "󰁍"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: theme.fg
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: card.view = "main" }
                    }
                    Text { text: "Bluetooth"; color: theme.fg; font.pixelSize: 14; font.bold: true }
                    Item { Layout.fillWidth: true }
                    // escanear (toggle discovering) — so quando o radio esta ligado
                    Text {
                        visible: btCol.adp ? btCol.adp.enabled : false
                        text: "󰑐"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16
                        color: (btCol.adp && btCol.adp.discovering) ? theme.accent : theme.fg
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: if (btCol.adp) btCol.adp.discovering = !btCol.adp.discovering }
                    }
                }

                // radio desligado: oferece ligar (ligar e seguro; nao togglamos OFF aqui)
                Rectangle {
                    visible: btCol.adp ? !btCol.adp.enabled : true
                    Layout.fillWidth: true
                    implicitHeight: 40; radius: 8
                    color: btOnMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : theme.bgAlt
                    Text {
                        anchors.centerIn: parent
                        color: theme.fg; font.pixelSize: 12
                        text: "Bluetooth desligado — toque para ligar"
                    }
                    MouseArea { id: btOnMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: if (btCol.adp) btCol.adp.enabled = true }
                }

                // lista de dispositivos pareados
                Repeater {
                    model: Bluetooth.devices
                    delegate: Rectangle {
                        id: btRow
                        required property var modelData
                        property bool busy: modelData.state === BluetoothDeviceState.Connecting
                                            || modelData.state === BluetoothDeviceState.Disconnecting
                        visible: (btCol.adp ? btCol.adp.enabled : false)
                                 && (modelData.paired || modelData.bonded)
                        Layout.fillWidth: true
                        implicitHeight: 40; radius: 8
                        color: btRowMa.containsMouse ? Qt.alpha(theme.accent, 0.2)
                               : (modelData.connected ? Qt.alpha(theme.accent, 0.13) : "transparent")
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10; anchors.rightMargin: 10
                            spacing: 8
                            Text {
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15
                                color: btRow.modelData.connected ? theme.accent : theme.fgDim
                                text: "󰂯"
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Text {
                                    Layout.fillWidth: true
                                    color: theme.fg; font.pixelSize: 12; elide: Text.ElideRight
                                    text: btRow.modelData.deviceName || btRow.modelData.name || btRow.modelData.address
                                }
                                Text {
                                    visible: btRow.modelData.batteryAvailable && btRow.modelData.connected
                                    color: theme.fgDim; font.pixelSize: 9
                                    text: "bateria " + Math.round(btRow.modelData.battery * 100) + "%"
                                }
                            }
                            Text {
                                color: btRow.busy ? theme.warn
                                       : (btRow.modelData.connected ? theme.ok : theme.fgDim)
                                font.pixelSize: 10
                                text: btRow.busy
                                      ? (btRow.modelData.state === BluetoothDeviceState.Connecting ? "conectando…" : "desconectando…")
                                      : (btRow.modelData.connected ? "conectado" : "")
                            }
                        }
                        MouseArea {
                            id: btRowMa
                            anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: function (mouse) {
                                if (mouse.button === Qt.RightButton) {
                                    var pt = btRowMa.mapToItem(card, mouse.x, mouse.y);
                                    btCol.btMenuX = Math.max(8, Math.min(pt.x, card.width - 186));
                                    btCol.btMenuY = Math.max(8, Math.min(pt.y, card.height - 60));
                                    btCol.btMenuDev = btRow.modelData;
                                    btCol.btShowDetails = false;
                                    btCol.btMenuFor = btRow.modelData.address;
                                    return;
                                }
                                if (btRow.busy) return;
                                if (btRow.modelData.connected) btRow.modelData.disconnect();
                                else btRow.modelData.connect();
                            }
                        }
                    }
                }

                // nenhum pareado
                Text {
                    visible: (btCol.adp ? btCol.adp.enabled : false)
                             && (!Bluetooth.devices
                                 || Bluetooth.devices.values.filter(function (d) { return d.paired || d.bonded; }).length === 0)
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    color: theme.fgDim; font.pixelSize: 11
                    text: "Nenhum dispositivo pareado"
                }

                // ---- disponiveis (descobertos, ainda nao pareados) ----
                Text {
                    visible: (btCol.adp ? btCol.adp.enabled : false) && btCol.adp && btCol.adp.discovering
                    text: "Disponíveis"; color: theme.fgDim; font.pixelSize: 11; font.bold: true
                    Layout.topMargin: 6
                }
                Repeater {
                    model: Bluetooth.devices
                    delegate: Rectangle {
                        id: btNew
                        required property var modelData
                        property bool busy: modelData.state === BluetoothDeviceState.Connecting
                                            || modelData.state === BluetoothDeviceState.Disconnecting
                                            || modelData.pairing
                        visible: (btCol.adp ? btCol.adp.enabled : false) && !(modelData.paired || modelData.bonded)
                        Layout.fillWidth: true
                        implicitHeight: 38; radius: 8
                        color: btNewMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : "transparent"
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10; anchors.rightMargin: 10
                            spacing: 8
                            Text { font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15; color: theme.fgDim; text: "󰂲" }
                            Text {
                                Layout.fillWidth: true; color: theme.fg; font.pixelSize: 12; elide: Text.ElideRight
                                text: btNew.modelData.deviceName || btNew.modelData.name || btNew.modelData.address
                            }
                            Text {
                                color: btNew.busy ? theme.warn : theme.fgDim; font.pixelSize: 10
                                text: btNew.busy ? "pareando…" : "parear"
                            }
                        }
                        MouseArea {
                            id: btNewMa
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: function (mouse) {
                                if (mouse.button === Qt.RightButton) {
                                    var pt = btNewMa.mapToItem(card, mouse.x, mouse.y);
                                    btCol.btMenuX = Math.max(8, Math.min(pt.x, card.width - 186));
                                    btCol.btMenuY = Math.max(8, Math.min(pt.y, card.height - 60));
                                    btCol.btMenuDev = btNew.modelData;
                                    btCol.btShowDetails = false;
                                    btCol.btMenuFor = btNew.modelData.address;
                                    return;
                                }
                                if (btNew.busy) return;
                                btNew.modelData.pair();
                            }
                        }
                    }
                }
            }

            // ---- view: notificacoes (historico do mako) ----
            ColumnLayout {
                id: notifCol
                visible: card.view === "notif"
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 14
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        text: "󰁍"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: theme.fg
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: card.view = "main" }
                    }
                    Text { text: "Notificacoes"; color: theme.fg; font.pixelSize: 14; font.bold: true }
                    Item { Layout.fillWidth: true }
                    // ler a notificacao mais recente (a do topo) em voz, via TTS
                    Text {
                        text: "󰔊"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15
                        color: root.notifs.length > 0 ? theme.fg : theme.surface2
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (root.notifs.length === 0) return;
                                        var n = root.notifs[0];
                                        var txt = ((n["summary"] || "") + ". " + (n["body"] || "")).trim();
                                        Quickshell.execDetached(["sh", "-c", "exec \"$HOME/.local/bin/tts-read\" \"$1\"", "_", txt]);
                                    } }
                    }
                    // limpar de verdade: dispensa as ativas e DRENA o historico do mako
                    // (restore traz de volta, dismiss --no-history remove sem regravar)
                    Text {
                        text: "󰎟"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15
                        color: root.notifs.length > 0 ? theme.fg : theme.surface2
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        Quickshell.execDetached(["sh", "-c",
                                            "makoctl dismiss --all 2>/dev/null; i=0; " +
                                            "while [ $i -lt 40 ] && makoctl restore 2>/dev/null; do " +
                                            "makoctl dismiss --no-history 2>/dev/null; i=$((i+1)); done"]);
                                        root.notifs = [];
                                    } }
                    }
                    Text {
                        text: "󰑐"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16; color: theme.fg
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.refreshNotifs() }
                    }
                }

                Repeater {
                    model: root.notifs
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: ntCol.implicitHeight + 12
                        radius: 8; color: theme.bgAlt
                        ColumnLayout {
                            id: ntCol
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                            anchors.leftMargin: 10; anchors.rightMargin: 10
                            spacing: 1
                            Text {
                                Layout.fillWidth: true; color: theme.accent; font.pixelSize: 10
                                elide: Text.ElideRight
                                text: (modelData["app_name"] || "")
                            }
                            Text {
                                Layout.fillWidth: true; color: theme.fgBright; font.pixelSize: 12
                                elide: Text.ElideRight
                                text: (modelData["summary"] || "")
                            }
                            Text {
                                Layout.fillWidth: true; visible: !!(modelData["body"])
                                color: theme.fg; font.pixelSize: 11
                                wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
                                text: (modelData["body"] || "")
                            }
                        }
                    }
                }

                Text {
                    visible: root.notifs.length === 0
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    color: theme.fgDim; font.pixelSize: 11
                    text: "Sem notificacoes recentes"
                }
            }

            // ---- view: personalizacao (tema + papel de parede) ----
            ColumnLayout {
                id: persoCol
                visible: card.view === "perso"
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 14
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        text: "󰁍"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: theme.fg
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: card.view = "main" }
                    }
                    Text { Layout.fillWidth: true; text: "Personalizacao"; color: theme.fg; font.pixelSize: 14; font.bold: true }
                    Text {
                        text: "󰑐"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15
                        color: persoRefMa.containsMouse ? theme.accent : theme.fgDim
                        MouseArea { id: persoRefMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor; onClicked: root.refreshThemes() }
                    }
                }

                Text { Layout.fillWidth: true; text: "Tema"; color: theme.fgDim; font.pixelSize: 11; font.bold: true }

                // grade de temas: nome + amostras (fundo/accent), atual destacado
                Flickable {
                    Layout.fillWidth: true
                    implicitHeight: Math.min(themeGrid.implicitHeight, 260)
                    contentWidth: width
                    contentHeight: themeGrid.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    GridLayout {
                        id: themeGrid
                        width: parent.width
                        columns: 2
                        rowSpacing: 8; columnSpacing: 8

                        Repeater {
                            model: root.orderedThemes
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool current: modelData.snake === root.currentTheme
                                Layout.fillWidth: true
                                implicitHeight: 42; radius: 10
                                color: current ? Qt.alpha(theme.accent, 0.22)
                                                : (tHov.containsMouse ? Qt.alpha(theme.accent, 0.12) : theme.bgAlt)
                                border.width: current ? 1 : 0
                                border.color: theme.accent
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                                    // amostras de cor do tema
                                    Rectangle {
                                        width: 22; height: 22; radius: 6
                                        color: modelData.bg
                                        border.width: 1; border.color: Qt.alpha(theme.fg, 0.25)
                                        Rectangle {
                                            width: 11; height: 11; radius: 3
                                            anchors.right: parent.right; anchors.bottom: parent.bottom
                                            anchors.rightMargin: 2; anchors.bottomMargin: 2
                                            color: modelData.accent
                                            border.width: 1; border.color: Qt.alpha(theme.bg, 0.4)
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.name
                                        color: current ? theme.fgBright : theme.fg
                                        font.pixelSize: 11; font.bold: current
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        visible: current
                                        text: "󰄬"; font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 13; color: theme.accent
                                    }
                                }
                                MouseArea {
                                    id: tHov
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.setTheme(modelData.snake)
                                }
                            }
                        }
                    }
                }

                // papel de parede: leva pro previewer existente
                Rectangle {
                    Layout.fillWidth: true; Layout.topMargin: 4
                    implicitHeight: 44; radius: 10
                    color: persoWallMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : theme.bgAlt
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                        Text { font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: theme.accent; text: "󰸉" }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 0
                            Text { color: theme.fgBright; font.pixelSize: 12; font.bold: true; text: "Papel de parede" }
                            Text { color: theme.fgDim; font.pixelSize: 10; text: "Trocar ou baixar" }
                        }
                        Text { text: "󰅂"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14; color: theme.fgDim }
                    }
                    MouseArea {
                        id: persoWallMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { card.view = "wall" }
                    }
                }
            }

            // ---- view: papel de parede (grafo de agentes + Pinterest) ----
            ColumnLayout {
                id: wallCol
                visible: card.view === "wall"
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 14
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Text {
                        text: "󰉍"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: theme.fg
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: card.view = "main" }
                    }
                    Text { Layout.fillWidth: true; text: "Papel de parede"; color: theme.fg; font.pixelSize: 14; font.bold: true }
                }

                // busca por vibe
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    Rectangle {
                        Layout.fillWidth: true; implicitHeight: 32; radius: 8; color: theme.bgAlt
                        border.width: 1; border.color: theme.border
                        TextInput {
                            id: vibeInput
                            anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                            verticalAlignment: TextInput.AlignVCenter
                            color: theme.fgBright; font.pixelSize: 12; clip: true
                            onAccepted: if (text.trim()) root.wpaSearch(text.trim())
                            Text {
                                anchors.fill: parent; verticalAlignment: Text.AlignVCenter
                                visible: !vibeInput.text && !vibeInput.activeFocus
                                color: theme.fgDim; font.pixelSize: 12
                                text: "Descreva uma vibe (ex: montanha neblina)"
                            }
                        }
                    }
                    Rectangle {
                        implicitWidth: 70; implicitHeight: 32; radius: 8
                        color: root.wpaBusy ? theme.surface : Qt.alpha(theme.accent, 0.25)
                        Text {
                            anchors.centerIn: parent; font.pixelSize: 12; color: theme.fgBright
                            text: root.wpaBusy ? "..." : "Buscar"
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            enabled: !root.wpaBusy
                            onClicked: if (vibeInput.text.trim()) root.wpaSearch(vibeInput.text.trim())
                        }
                    }
                }

                // feedback enquanto busca (gallery-dl baixa do Pinterest, ~30-40s)
                Text {
                    visible: root.wpaBusy
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    color: theme.accent; font.pixelSize: 11
                    text: "Buscando wallpapers no Pinterest, pode levar ate ~40s..."
                }

                // grid de resultados da busca (clicar adiciona ao ciclo)
                Text {
                    visible: root.wpaSearchItems.length > 0
                    Layout.fillWidth: true; color: theme.fgDim; font.pixelSize: 10
                    text: "Clique pra adicionar ao ciclo do tema."
                }
                Flickable {
                    visible: root.wpaSearchItems.length > 0
                    Layout.fillWidth: true
                    implicitHeight: Math.min(searchGrid.implicitHeight, 200)
                    contentWidth: width; contentHeight: searchGrid.implicitHeight
                    clip: true; boundsBehavior: Flickable.StopAtBounds
                    Grid {
                        id: searchGrid
                        width: parent.width; columns: 3; spacing: 8
                        property real cellW: (width - 2*spacing) / 3
                        Repeater {
                            model: root.wpaSearchItems
                            delegate: Rectangle {
                                required property var modelData
                                width: searchGrid.cellW; height: width * 0.62
                                radius: 8; clip: true; color: theme.bgDark
                                border.width: sMa.containsMouse ? 2 : 0; border.color: theme.accent
                                Image {
                                    anchors.fill: parent
                                    source: root.wpaApi + "/api/thumb/" + modelData.id
                                    fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: true
                                }
                                Text {
                                    visible: modelData.in_cycle
                                    anchors { right: parent.right; top: parent.top; margins: 3 }
                                    text: "󰈌"; font.family: "JetBrainsMono Nerd Font"
                                    font.pixelSize: 12; color: theme.ok; style: Text.Outline; styleColor: theme.bgDark
                                }
                                MouseArea {
                                    id: sMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.wpaAdd([modelData.id])
                                }
                            }
                        }
                    }
                }

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: theme.surface }

                // ciclo atual (remover com clique)
                Text {
                    Layout.fillWidth: true; color: theme.fgDim; font.pixelSize: 11; font.bold: true
                    text: "No ciclo do tema (" + root.wpaCycleItems.length + ")"
                }
                Text {
                    visible: root.wpaCycleItems.length === 0
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                    color: theme.fgDim; font.pixelSize: 11
                    text: "Vazio. Busque acima e clique numa imagem pra adicionar."
                }
                Flickable {
                    visible: root.wpaCycleItems.length > 0
                    Layout.fillWidth: true
                    implicitHeight: Math.min(cycleGrid.implicitHeight, 180)
                    contentWidth: width; contentHeight: cycleGrid.implicitHeight
                    clip: true; boundsBehavior: Flickable.StopAtBounds
                    Grid {
                        id: cycleGrid
                        width: parent.width; columns: 3; spacing: 8
                        property real cellW: (width - 2*spacing) / 3
                        Repeater {
                            model: root.wpaCycleItems
                            delegate: Rectangle {
                                required property var modelData
                                width: cycleGrid.cellW; height: width * 0.62
                                radius: 8; clip: true; color: theme.bgDark
                                border.width: cMa.containsMouse ? 2 : 0; border.color: theme.danger
                                Image {
                                    anchors.fill: parent
                                    source: root.wpaApi + "/api/cyclethumb?f=" + encodeURIComponent(modelData.file)
                                    fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: true
                                }
                                Text {
                                    visible: cMa.containsMouse
                                    anchors.centerIn: parent
                                    text: "󰖚"; font.family: "JetBrainsMono Nerd Font"
                                    font.pixelSize: 18; color: theme.danger; style: Text.Outline; styleColor: theme.bgDark
                                }
                                MouseArea {
                                    id: cMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.wpaRemove([modelData.file])
                                }
                            }
                        }
                    }
                }
            }

            // ---- view: som (dispositivos de saida + volume por app + bass) ----
            ColumnLayout {
                id: audioCol
                visible: card.view === "audio"
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 14
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Text {
                        text: "󰁍"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: theme.fg
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: card.view = "main" }
                    }
                    Text { Layout.fillWidth: true; text: "Som"; color: theme.fg; font.pixelSize: 14; font.bold: true }
                    Text {
                        text: "󰑐"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15
                        color: audRefMa.containsMouse ? theme.accent : theme.fgDim
                        MouseArea { id: audRefMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor; onClicked: root.refreshAudio() }
                    }
                }

                // volume master (sink padrao, mesmo das teclas de volume)
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Text { text: vols.mut ? "󰝟" : "󰕾"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: theme.fg
                           MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleVolMute() } }
                    Item {
                        Layout.fillWidth: true; implicitHeight: 20
                        Rectangle {
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                            height: 6; radius: 3; color: theme.surface
                            Rectangle { width: parent.width * (vols.mut ? 0 : vols.vol); height: parent.height; radius: 3; color: theme.accent }
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onPressed: function (e) { root.volDragging = true; root.setVolReal(e.x / width); }
                            onPositionChanged: function (e) { if (pressed) root.setVolReal(e.x / width); }
                            onReleased: { root.volDragging = false; root.refreshVol(); }
                        }
                    }
                    Text { Layout.preferredWidth: 32; text: Math.round(vols.vol * 100) + "%"; color: theme.fg
                           font.pixelSize: 12; horizontalAlignment: Text.AlignRight }
                }

                // saida: escolher o dispositivo (igual Windows) | espelhar = tocar em varios
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Text { Layout.fillWidth: true; text: "Saída"; color: theme.fgDim; font.pixelSize: 11; font.bold: true }
                    Text { text: "Espelhar"; font.pixelSize: 10; font.bold: root.mirrorMode
                           color: root.mirrorMode ? theme.accent : theme.fgDim }
                    // mini switch on/off
                    Rectangle {
                        implicitWidth: 26; implicitHeight: 14; radius: 7
                        color: root.mirrorMode ? theme.accent : Qt.alpha(theme.fg, 0.2)
                        Rectangle {
                            width: 10; height: 10; radius: 5; color: theme.fgBright
                            anchors.verticalCenter: parent.verticalCenter
                            x: root.mirrorMode ? parent.width - width - 2 : 2
                            Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.toggleMirrorMode() }
                    }
                }
                Text { visible: root.mirrorMode; text: root.mirrorSel.length >= 2
                            ? ("Tocando em " + root.mirrorSel.length + " dispositivos")
                            : "Marque 2 ou mais dispositivos"
                       color: theme.fgDim; font.pixelSize: 10 }
                Repeater {
                    model: root.audioSinks
                    delegate: Rectangle {
                        required property var modelData
                        property bool checked: root.mirrorMode ? root.mirrorHas(modelData.name) : modelData.active
                        Layout.fillWidth: true
                        implicitHeight: 34; radius: 8
                        color: checked ? Qt.alpha(theme.accent, 0.2) : (sinkMa.containsMouse ? Qt.alpha(theme.accent, 0.12) : "transparent")
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                            // no modo espelho mostra checkbox; senao o icone do dispositivo
                            Text { font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15
                                   color: checked ? theme.accent : theme.fg
                                   text: root.mirrorMode
                                         ? (checked ? "󰄲" : "󰄱")
                                         : (modelData.icon === "headphones" ? "󰋋" : (modelData.icon === "tv" ? "󰔂" : (modelData.icon === "usb" ? "󰕓" : "󰓃"))) }
                            Text { Layout.fillWidth: true; color: theme.fgBright; font.pixelSize: 12
                                   elide: Text.ElideRight; text: modelData.desc }
                            Text { visible: !root.mirrorMode && modelData.active; text: "󰄬"; font.family: "JetBrainsMono Nerd Font"
                                   font.pixelSize: 13; color: theme.ok }
                        }
                        MouseArea {
                            id: sinkMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: root.mirrorMode ? root.toggleMirrorDev(modelData.name) : root.setOutput(modelData.name)
                        }
                    }
                }

                // aplicativos: volume por programa (igual mixer do Windows)
                Text { visible: root.audioApps.length > 0; text: "Aplicativos"; color: theme.fgDim; font.pixelSize: 11; font.bold: true }
                Text { visible: root.audioApps.length === 0; text: "Nenhum app tocando agora."; color: theme.fgDim; font.pixelSize: 11 }
                Repeater {
                    model: root.audioApps
                    delegate: RowLayout {
                        id: appRow
                        required property var modelData
                        property real av: modelData.vol
                        Layout.fillWidth: true; spacing: 8
                        // icone do app (identifica + clique muta; vermelho quando mudo)
                        Text { text: root.appIcon(appRow.modelData.name); font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15
                               color: appRow.modelData.mut ? theme.danger : theme.accent; opacity: appRow.modelData.mut ? 0.7 : 1
                               Layout.preferredWidth: 20; horizontalAlignment: Text.AlignHCenter
                               MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleAppMute(appRow.modelData.id) } }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 2
                            Text { Layout.fillWidth: true; color: theme.fg; font.pixelSize: 11; elide: Text.ElideRight; text: appRow.modelData.name }
                            Item {
                                Layout.fillWidth: true; implicitHeight: 14
                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                                    height: 5; radius: 3; color: theme.surface
                                    Rectangle { width: parent.width * Math.min(1, appRow.av); height: parent.height; radius: 3; color: theme.purple }
                                }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onPressed: function (e) { appRow.av = e.x / width; root.setAppVol(appRow.modelData.id, e.x / width); }
                                    onPositionChanged: function (e) { if (pressed) { appRow.av = e.x / width; root.setAppVol(appRow.modelData.id, e.x / width); } }
                                }
                            }
                        }
                        Text { Layout.preferredWidth: 30; text: Math.round(Math.min(1, appRow.av) * 100) + "%"; color: theme.fgDim
                               font.pixelSize: 10; horizontalAlignment: Text.AlignRight }
                    }
                }

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: theme.surface }

                // ---- microfone ----
                Text { text: "Microfone"; color: theme.fgDim; font.pixelSize: 11; font.bold: true }
                RowLayout {
                    Layout.fillWidth: true; spacing: 10
                    Text { text: mics.mut ? "󰍭" : "󰍬"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18
                           color: mics.mut ? theme.danger : theme.fg
                           MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleMicMuteAudio() } }
                    Item {
                        Layout.fillWidth: true; implicitHeight: 20
                        Rectangle {
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                            height: 6; radius: 3; color: theme.surface
                            Rectangle { width: parent.width * (mics.mut ? 0 : mics.vol); height: parent.height; radius: 3; color: theme.ok }
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onPressed: function (e) { root.micDragging = true; root.setMicVol(e.x / width); }
                            onPositionChanged: function (e) { if (pressed) root.setMicVol(e.x / width); }
                            onReleased: { root.micDragging = false; root.refreshMic(); }
                        }
                    }
                    Text { Layout.preferredWidth: 32; text: Math.round(mics.vol * 100) + "%"; color: theme.fg
                           font.pixelSize: 12; horizontalAlignment: Text.AlignRight }
                }
                // escolher o microfone de entrada
                Repeater {
                    model: root.micSources
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 34; radius: 8
                        color: modelData.active ? Qt.alpha(theme.ok, 0.2) : (srcMa.containsMouse ? Qt.alpha(theme.ok, 0.12) : "transparent")
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                            Text { font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15
                                   color: modelData.active ? theme.ok : theme.fg
                                   text: modelData.icon === "btmic" ? "󰋎" : "󰍬" }
                            Text { Layout.fillWidth: true; color: theme.fgBright; font.pixelSize: 12
                                   elide: Text.ElideRight; text: modelData.desc }
                            Text { visible: modelData.active; text: "󰄬"; font.family: "JetBrainsMono Nerd Font"
                                   font.pixelSize: 13; color: theme.ok }
                        }
                        MouseArea { id: srcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.setInput(modelData.name) }
                    }
                }

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: theme.surface }

                // bass boost: liga o EasyEffects sob demanda, roteado pro dispositivo atual
                // (indisponivel enquanto espelha em varios: combine-sink e EE nao convivem)
                Rectangle {
                    id: bassRow
                    property bool blocked: root.mirrorMode && root.mirrorSel.length >= 2
                    Layout.fillWidth: true; implicitHeight: 36; radius: 8
                    opacity: blocked ? 0.45 : 1
                    color: (!blocked && root.bassOn) ? Qt.alpha(theme.purple, 0.2) : (bassMa2.containsMouse && !blocked ? Qt.alpha(theme.purple, 0.12) : "transparent")
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; spacing: 8
                        Text { font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15
                               color: (!bassRow.blocked && root.bassOn) ? theme.purple : theme.fg; text: "󰋃" }
                        Text { Layout.fillWidth: true; color: theme.fg; font.pixelSize: 12; text: "Bass boost (EasyEffects)" }
                        Text { color: bassRow.blocked ? theme.fgDim : (root.bassOn ? theme.ok : theme.fgDim); font.pixelSize: 11
                               text: bassRow.blocked ? "indisponível" : (root.bassOn ? "ligado" : "desligado") }
                    }
                    MouseArea { id: bassMa2; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { if (!bassRow.blocked) root.toggleBassNew() } }
                }
            }
        }
    }

    // ============ Overlay do Alt+Tab (faixa de thumbnails ao vivo) ============
    PanelWindow {
        id: att
        visible: root.attOpen
        screen: root.attScreen ? root.attScreen : Quickshell.screens[0]
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qsbar-alttab"
        // grab de teclado: segura Alt, Tab cicla, solta Alt escolhe
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        onVisibleChanged: {
            if (visible) { attKeys.forceActiveFocus(); attCard.opacity = 1; attCard.scale = 1; }
            else { attCard.opacity = 0; attCard.scale = 0.95; }
        }

        // backdrop: clique fora cancela
        MouseArea { anchors.fill: parent; onClicked: root.attOpen = false }

        // captura de teclado (Tab cicla / Shift+Tab volta / Esc cancela / Enter confirma / solta Alt escolhe)
        Item {
            id: attKeys
            anchors.fill: parent
            focus: true
            Keys.onPressed: function (e) {
                if (e.key === Qt.Key_Tab || e.key === Qt.Key_Backtab || e.key === Qt.Key_QuoteLeft) {
                    root.attStep((e.modifiers & Qt.ShiftModifier) ? -1 : 1);
                    e.accepted = true;
                } else if (e.key === Qt.Key_Escape) {
                    root.attOpen = false; e.accepted = true;
                } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                    root.attConfirm(); e.accepted = true;
                } else if (e.key === Qt.Key_Left) {
                    root.attStep(-1); e.accepted = true;
                } else if (e.key === Qt.Key_Right) {
                    root.attStep(1); e.accepted = true;
                } else if (e.key === Qt.Key_Up) {
                    root.attStep(-att.geom.cols); e.accepted = true;   // fileira de cima
                } else if (e.key === Qt.Key_Down) {
                    root.attStep(att.geom.cols); e.accepted = true;    // fileira de baixo
                }
            }
            Keys.onReleased: function (e) {
                if (e.key === Qt.Key_Alt || e.key === Qt.Key_Meta) {
                    root.attConfirm(); e.accepted = true;
                }
            }
        }

        // grade responsiva: se ajusta a tela e quebra em fileiras quando enche a largura
        property var geom: root.attLayout(root.attList.length, att.width * 0.94, att.height * 0.92)
        // fatia a lista em fileiras de `cols` janelas (ultima fileira pode ter menos)
        property var rowsData: {
            var out = [], c = att.geom.cols, list = root.attList;
            for (var i = 0; i < list.length; i += c) out.push(list.slice(i, i + c));
            return out;
        }

        Rectangle {
            id: attCard
            anchors.centerIn: parent
            opacity: 0
            scale: 0.95
            transformOrigin: Item.Center
            Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            width:  att.geom.cols * att.geom.tw + (att.geom.cols - 1) * att.geom.gap + 2 * att.geom.pad
            height: att.geom.rows * att.geom.th + (att.geom.rows - 1) * att.geom.gap + 2 * att.geom.pad
            radius: 18
            color: Qt.alpha(theme.bgDark, 0.93)
            border.color: Qt.alpha(theme.accent, 0.2); border.width: 1
            MouseArea { anchors.fill: parent }   // absorve cliques no card
            // scroll do mouse cicla a selecao
            WheelHandler { onWheel: function (e) { root.attStep(e.angleDelta.y < 0 ? 1 : -1); } }

            // fileiras empilhadas; cada fileira centralizada (a ultima, parcial, fica no meio)
            Column {
                id: attCol
                anchors.centerIn: parent
                spacing: att.geom.gap
                Repeater {
                    model: att.rowsData
                    delegate: Row {
                        id: attRowDeleg
                        required property var modelData   // array de janelas desta fileira
                        required property int index       // indice da fileira
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: att.geom.gap
                        Repeater {
                            model: attRowDeleg.modelData
                            delegate: Rectangle {
                                id: thumb
                                required property var modelData
                                required property int index          // indice dentro da fileira
                                property int gIndex: attRowDeleg.index * att.geom.cols + index  // indice global
                                property bool sel: gIndex === root.attIndex
                                implicitWidth: att.geom.tw
                                implicitHeight: att.geom.th
                                radius: 12
                                color: sel ? Qt.alpha(theme.accent, 0.2) : theme.bgAlt
                                border.color: sel ? theme.accent : theme.surface
                                border.width: sel ? 3 : 1
                                Behavior on border.color { ColorAnimation { duration: 90 } }

                                ColumnLayout {
                                    anchors.fill: parent; anchors.margins: 8; spacing: 6
                                    ScreencopyView {
                                        Layout.fillWidth: true; Layout.fillHeight: true
                                        captureSource: thumb.modelData
                                        live: true
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6
                                        Item { Layout.fillWidth: true }
                                        Image {
                                            Layout.preferredWidth: 16; Layout.preferredHeight: 16
                                            fillMode: Image.PreserveAspectFit
                                            source: {
                                                var ready = DesktopEntries.applications.values.length;  // re-avalia ao carregar
                                                var id = thumb.modelData.appId;
                                                var de = DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id);
                                                var icon = (de && de.icon && de.icon.length) ? de.icon : id;
                                                // jogos Steam: janela steam_app_<id> -> icone steam_icon_<id>
                                                if (id.indexOf("steam_app_") === 0) icon = "steam_icon_" + id.substring(10);
                                                return Quickshell.iconPath(icon, "application-x-executable");
                                            }
                                        }
                                        Text {
                                            color: thumb.sel ? theme.fgBright : theme.fg
                                            font.pixelSize: 11; elide: Text.ElideRight
                                            Layout.maximumWidth: Math.max(40, thumb.width - 52)
                                            text: (thumb.modelData.title && thumb.modelData.title.length)
                                                  ? thumb.modelData.title : (thumb.modelData.appId || "?")
                                        }
                                        Item { Layout.fillWidth: true }
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onPositionChanged: root.attIndex = thumb.gIndex
                                    onClicked: { root.attIndex = thumb.gIndex; root.attConfirm(); }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
