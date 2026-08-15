//@ pragma UseQApplication
// Barra do Lucas em Quickshell. Objetivo: taskbar AGRUPADA por app dentro da barra.
// Iteracao 1: menu Omarchy + taskbar agrupada + relogio. Modulos de status virao depois.
import Quickshell
import Quickshell.Wayland
import Quickshell.Wayland._Screencopy
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.SystemTray
import Quickshell.Services.UPower
import Quickshell.Bluetooth
import Quickshell.Services.Mpris
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects

ShellRoot {
    // faixa clicavel no topo da janela do kitty (KittyStrip.qml)
    KittyStrip { theme: theme }
    // Gaveta de janelas v2 (GavetaPanel.qml). Guardar e so mover pra workspace
    // especial: a v1 hibernava o processo com SIGSTOP e matou uma sessao viva
    // do Claude Code dentro do kitty.
    GavetaPanel { id: gaveta; theme: theme }
    CalendarPanel { id: calendario; theme: theme }
    // notificacao propria, substitui o mako (NotificationPanel.qml)
    NotificationPanel { id: notifPanel; theme: theme }

    id: root

    // HOME em vez de caminho absoluto: caminho com usuario fixo quebra pra
    // qualquer outra pessoa, e o repo deste shell e publico.
    readonly property string lar: Quickshell.env("HOME")
    // estado global: central de acoes (dropdown estilo Windows) aberta?
    property bool acOpen: false
    property var acScreen: null   // monitor onde a central abre (o do chevron clicado)

    // ===== menu de contexto do icone da taskbar (botao direito) =====
    property string appMenuFor: ""    // appId com o menu aberto ("" = fechado)
    property string appMenuLabel: ""  // nome exibido no topo; nao limpa no fechar (sobrevive ao fade)
    property var appMenuScreen: null  // monitor do clique
    property real appMenuX: 0         // x do clique em coordenadas da tela

    function openAppMenu(appId: string, label: string, scr: var, x: real): void {
        root.appMenuFor = appId;
        root.appMenuLabel = label;
        root.appMenuScreen = scr;
        root.appMenuX = x;
    }

    // janelas de um app (mesmo criterio de agrupamento da taskbar)
    function appWins(appId: string): var {
        var out = [];
        var list = ToplevelManager.toplevels.values;
        for (var i = 0; i < list.length; i++) {
            var t = list[i];
            var id = (t.appId && t.appId.length) ? t.appId : "desconhecido";
            if (id === appId) out.push(t);
        }
        return out;
    }

    // encerrar: close normal em todas as janelas (o app salva estado / pergunta)
    function appClose(appId: string): void {
        var w = root.appWins(appId);
        for (var i = 0; i < w.length; i++) w[i].close();
    }

    // forcar: SIGKILL no processo da janela e nos descendentes (app travado)
    function appKill(appId: string): void {
        Quickshell.execDetached([lar + "/.config/quickshell/scripts/taskbar-app.sh",
                                 "kill", appId]);
    }

    // reiniciar: fecha tudo, espera as janelas sumirem, reabre pelo .desktop
    property string restartAppId: ""
    property var restartEntry: null
    property int restartTries: 0
    function appRestart(appId: string): void {
        var de = DesktopEntries.byId(appId) || DesktopEntries.heuristicLookup(appId);
        if (!de) return;   // sem .desktop nao ha como reabrir: melhor nao fechar nada
        root.restartEntry = de;
        root.restartAppId = appId;
        root.restartTries = 0;
        root.appClose(appId);
        restartTimer.restart();
    }
    Timer {
        id: restartTimer
        interval: 300; repeat: true
        onTriggered: {
            root.restartTries++;
            if (root.appWins(root.restartAppId).length === 0) {
                stop();
                if (root.restartEntry) root.restartEntry.execute();
                root.restartAppId = ""; root.restartEntry = null;
            } else if (root.restartTries > 20) {
                // ~6s e a janela nao fechou (dialogo de "salvar?", app travado):
                // desiste em vez de abrir uma 2a instancia por cima
                stop();
                root.restartAppId = ""; root.restartEntry = null;
            }
        }
    }

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
        path: lar + "/.config/omarchy/current/theme/colors.toml"
        watchChanges: true
        // API confirmada (Quickshell.Io FileView): text() le conteudo, signals
        // loaded/fileChanged, metodo reload(). parse roda no load inicial e em
        // cada mudanca do arquivo (troca de tema do Omarchy).
        onLoaded: theme.parse(themeFile.text())
        onFileChanged: { themeFile.reload(); theme.parse(themeFile.text()); }
    }
    // Cor de carga em GRADIENTE CONTINUO: verde -> ambar -> vermelho, conforme
    // stress 0..1. Diferente de 3 faixas discretas, aqui cada metrica mostra um
    // tom proprio mesmo em repouso (CPU 5% verde vivo, RAM 51% ja amarelado),
    // que e como da pra distinguir as tres de relance sem ler o numero.
    // Ancoras vem do tema (ok/warn/danger), nunca hex fixo, entao acompanha
    // troca de tema igual o coracao.
    function corCarga(stress) {
        var s = Math.max(0, Math.min(1, stress));
        // 0..0.5 interpola ok->warn; 0.5..1 interpola warn->danger
        return s < 0.5 ? _mistura(theme.ok, theme.warn, s / 0.5)
                       : _mistura(theme.warn, theme.danger, (s - 0.5) / 0.5);
    }
    function _mistura(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t,
                       a.g + (b.g - a.g) * t,
                       a.b + (b.b - a.b) * t, 1);
    }

    // recarga reativa via IPC: `qs ipc call theme reload` (chamado pelo hook theme-set).
    // re-le o colors.toml sem reiniciar o processo, entao a central nao fecha na troca.
    IpcHandler {
        target: "theme"
        function reload(): void { themeFile.reload(); theme.parse(themeFile.text()); }
    }

    // recria a cena inteira (todos os surfaces) apos uma troca de monitor ao vivo.
    // o quickshell 0.3.0 nao relayouta barra/wallpaper/overlay quando o output muda de
    // posicao; sem isso os surfaces ficam presos na geometria antiga (barra some, overlay
    // preso vira tela preta). chamado pelo watchdog externo do monitors.sh no revert.
    IpcHandler {
        target: "shell"
        function reload(): void { Quickshell.reload(true); }
    }

    // ===== toast de confirmacao do preview de monitores =====
    // Ao aplicar uma troca de monitor, o painel recarrega a cena (pra os surfaces
    // re-layoutarem). Este toast reaparece no startup lendo o estado pending do
    // monitors.sh e deixa Confirmar (persiste) ou Reverter. O watchdog externo reverte
    // sozinho se ninguem clicar, entao nunca fica preso numa config ruim.
    property int monPending: 0
    Process {
        id: monPendingProc
        command: [lar + "/.config/quickshell/scripts/monitors.sh", "pending"]
        stdout: StdioCollector { onStreamFinished: { var n = parseInt(this.text.trim()); root.monPending = isNaN(n) ? 0 : n; } }
    }
    // Confirmar persiste e AGORA recarrega a cena, que e quando os surfaces (barra) sao
    // corrigidos pra nova geometria. Reverter/watchdog tambem recarregam.
    Process { id: monConfirmProc; command: [lar + "/.config/quickshell/scripts/monitors.sh", "confirm"]; onExited: Quickshell.reload(true) }
    Process { id: monCancelProc; command: [lar + "/.config/quickshell/scripts/monitors.sh", "cancel"]; onExited: Quickshell.reload(true) }
    Timer {
        id: monPendingTimer; interval: 1000; repeat: true; running: root.monPending > 0
        onTriggered: { root.monPending--; }  // cosmetico; o revert real e do watchdog
    }
    Component.onCompleted: { monPendingProc.running = true; root.refreshNotifs();
                             netHistProc.running = true; }

    PanelWindow {
        visible: root.monPending > 0
        screen: Quickshell.screens.length ? Quickshell.screens[0] : null
        anchors { top: true; left: true; right: true }
        implicitHeight: 44
        exclusiveZone: 0
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qsbar-montoast"
        mask: Region { item: monToastPill }

        Rectangle {
            id: monToastPill
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top; anchors.topMargin: 6
            implicitHeight: 34; implicitWidth: monToastRow.implicitWidth + 24; radius: 10
            color: theme.bgAlt; border.color: Qt.alpha(theme.warn, 0.6); border.width: 1
            RowLayout {
                id: monToastRow
                anchors.centerIn: parent; spacing: 10
                Text {
                    text: "Manter esta configuração? " + root.monPending + "s"
                    color: theme.fgBright; font.pixelSize: 11
                }
                Rectangle {
                    implicitWidth: 44; implicitHeight: 22; radius: 6
                    color: monToastYes.containsMouse ? theme.ok : Qt.alpha(theme.ok, 0.7)
                    Text { anchors.centerIn: parent; text: "Sim"; color: theme.bg; font.pixelSize: 10; font.bold: true }
                    MouseArea { id: monToastYes; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { monConfirmProc.running = true; root.monPending = 0; } }
                }
                Rectangle {
                    implicitWidth: 66; implicitHeight: 22; radius: 6
                    color: monToastNo.containsMouse ? theme.danger : Qt.alpha(theme.danger, 0.7)
                    Text { anchors.centerIn: parent; text: "Reverter"; color: theme.bg; font.pixelSize: 10; font.bold: true }
                    MouseArea { id: monToastNo; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { monCancelProc.running = true; root.monPending = 0; } }
                }
            }
        }
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
            "s=$(printf '%b' \"$s\"); " +   // decodifica escapes \\xNN do iw (SSID nao-ASCII)
            "echo \"wifi:${s:-Wi-Fi}\"; exit 0; else echo eth; exit 0; fi; done; echo off"]
        stdout: StdioCollector { onStreamFinished: sys.net = this.text.trim() }
    }
    Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: netProc.running = true }

    // ---- medicao de internet (net-medir.sh): latencia, dns e teste sob demanda ----
    // O indicador da barra e SO o ms, decisao dele. As tres pernas (roteador,
    // internet, dns) aparecem no dropdown, porque e o trio que separa a culpa.
    // O dns esta aqui por causa do incidente de 14/08: naquele dia ping e
    // velocidade estavam perfeitos e a internet estava inutilizavel, entao um
    // indicador sem dns teria mostrado tudo verde durante o problema.
    QtObject {
        id: net
        property int gw: -1        // ms ate o roteador
        property int inet: -1      // ms ate 1.1.1.1
        property int dns: -1       // ms para resolver um dominio real
        property bool testando: false
        property var hist: []      // [{t, down, up}], no maximo 3
    }
    Process {
        id: netLatProc
        command: [lar + "/.config/quickshell/scripts/net-medir.sh", "lat"]
        stdout: StdioCollector {
            onStreamFinished: {
                var p = this.text.trim().split(" ");
                net.gw = parseInt(p[0]);
                net.inet = parseInt(p[1]);
                root.netAvaliar();
            }
        }
    }
    Process {
        id: netDnsProc
        command: [lar + "/.config/quickshell/scripts/net-medir.sh", "dns"]
        stdout: StdioCollector { onStreamFinished: net.dns = parseInt(this.text.trim()) }
    }
    Process {
        id: netHistProc
        command: [lar + "/.config/quickshell/scripts/net-medir.sh", "historico"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { net.hist = JSON.parse(this.text.trim()) || []; }
                catch (e) { net.hist = []; }
            }
        }
    }
    Process {
        id: netSpeedProc
        command: [lar + "/.config/quickshell/scripts/net-medir.sh", "speed"]
        // le o historico DEPOIS de terminar: o proprio script grava o resultado,
        // entao reler e o jeito de a lista aparecer sem duplicar a logica aqui
        onExited: { net.testando = false; netHistProc.running = true; }
    }
    // "18:05" se foi hoje, "14/08" se foi antes. Dia inteiro no historico de 3
    // itens seria informacao demais para a largura que o dropdown tem.
    function netQuando(ts) {
        var d = new Date(ts * 1000);
        var hoje = new Date();
        if (d.toDateString() === hoje.toDateString())
            return Qt.formatDateTime(d, "HH:mm");
        return Qt.formatDateTime(d, "dd/MM");
    }
    // ---- vigilancia: avisa quando a internet cai ou fica instavel ----
    //
    // Duas regras existem so pra isso NAO virar spam:
    //  1. avisa apenas na TROCA de estado, nunca repete o mesmo aviso
    //  2. exige duas amostras seguidas concordando (~10s) antes de trocar
    // Sem a segunda, um unico pacote perdido durante um jogo ja dispararia
    // "internet caiu" e ele desligaria o recurso no primeiro dia.
    QtObject {
        id: netVig
        property string estado: "ok"        // "ok" | "instavel" | "caiu"
        property string candidato: "ok"
        property int votos: 0
        property int amostras: 0            // descarta a largada, quando tudo ainda e -1
    }

    function netAvaliar() {
        netVig.amostras++;
        if (netVig.amostras < 2) return;    // na primeira leitura os valores ainda sao -1

        var novo = "ok";
        if (net.inet < 0) novo = "caiu";
        // 150ms e o teto util da escala da barra; dns acima de 500ms ja trava
        // pagina de forma perceptivel, e dns em -1 e falha de resolucao.
        else if (net.inet > 150 || net.dns < 0 || net.dns > 500) novo = "instavel";

        if (novo === netVig.estado) { netVig.votos = 0; netVig.candidato = novo; return; }
        if (novo !== netVig.candidato) { netVig.candidato = novo; netVig.votos = 1; return; }
        netVig.votos++;
        if (netVig.votos < 2) return;

        netVig.estado = novo;
        netVig.votos = 0;
        netAvisar(novo);
    }

    function netAvisar(estado) {
        var titulo, corpo, icone;
        if (estado === "caiu") {
            titulo = "Internet caiu";
            corpo = sys.net === "off" ? "sem rede conectada"
                                      : "o roteador responde, a internet nao";
            icone = "/usr/share/icons/Yaru/22x22/panel/network-offline.svg";
        } else if (estado === "instavel") {
            // diz QUAL perna piorou: sem isso o aviso nao ajuda a decidir se e o
            // wifi da casa, o provedor, ou o dns.
            var causas = [];
            if (net.inet > 150) causas.push("latencia " + net.inet + "ms");
            if (net.dns < 0) causas.push("dns falhando");
            else if (net.dns > 500) causas.push("dns " + net.dns + "ms");
            titulo = "Internet instável";
            corpo = causas.join(", ");
            icone = "/usr/share/icons/Yaru/22x22/panel/network-error.svg";
        } else {
            titulo = "Internet normalizou";
            corpo = net.inet + "ms, dns " + net.dns + "ms";
            icone = "/usr/share/icons/Yaru/22x22/panel/network-idle.svg";
        }
        // urgencia normal de proposito: critica nao expira sozinha no nosso
        // painel, e uma pilula presa na tela durante um jogo seria pior que o
        // proprio problema que ela anuncia.
        Quickshell.execDetached(["notify-send", "-a", "Internet", "-u", "normal",
                                 "-i", icone, titulo, corpo]);
    }

    function testarVelocidade() {
        if (net.testando) return;   // dois testes juntos disputam a banda e mentem
        net.testando = true;
        netSpeedProc.running = true;
    }
    // 5s na latencia (2 pings, custo nenhum) e 30s no dns (1 consulta).
    // O teste de velocidade NUNCA entra em timer: gasta banda e atrapalha jogo.
    Timer { interval: 5000;  running: true; repeat: true; triggeredOnStart: true
            onTriggered: netLatProc.running = true }
    Timer { interval: 30000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: netDnsProc.running = true }

    // ---- WiFi (iwd via wifi.sh): lista estavel + estado + acoes na barra ----
    property var wifiNets: []
    property string wifiActive: ""    // "ssid|sig" ou ""
    property bool wifiBusy: false
    Process {
        id: wifiListProc
        command: [lar + "/.config/quickshell/scripts/wifi.sh", "list"]
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
        command: [lar + "/.config/quickshell/scripts/wifi.sh", "state"]
        stdout: StdioCollector { onStreamFinished: root.wifiActive = this.text.trim() }
    }
    Process { id: wifiScanProc; command: [lar + "/.config/quickshell/scripts/wifi.sh", "scan"] }
    Process { id: wifiActProc }   // connect/disconnect/forget (command setado em wifiCmd)
    function refreshWifi() { wifiListProc.running = true; wifiStateProc.running = true; }
    function scanWifi() { wifiScanProc.running = true; root.wifiBusy = true; }
    function wifiCmd(args) {
        wifiActProc.command = [lar + "/.config/quickshell/scripts/wifi.sh"].concat(args);
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
        wifiDetailsProc.command = [lar + "/.config/quickshell/scripts/wifi.sh", "details", ssid];
        wifiDetailsProc.running = true;
    }


    // ---- temas Omarchy: lista (nome+fundo+accent) + tema atual ----
    property var themes: []
    property string currentTheme: ""
    property var favorites: []            // slugs favoritados, na ordem do arquivo theme-favorites
    property string themeMenuOpenFor: ""  // slug com o menu de contexto aberto (so um por vez)
    function isFav(snake) { return root.favorites.indexOf(snake) !== -1; }
    // ordem de exibicao: tema atual primeiro, depois favoritos (ordem do arquivo), depois resto alfabetico
    readonly property var orderedThemes: {
        var a = themes.slice();
        var fav = root.favorites;
        function rank(t) {
            if (t.snake === currentTheme) return -1;   // atual sempre primeiro
            var fi = fav.indexOf(t.snake);
            if (fi !== -1) return fi;                   // favoritos na ordem em que foram favoritados
            return 100000;                              // resto depois
        }
        a.sort(function (x, y) {
            var rx = rank(x), ry = rank(y);
            if (rx !== ry) return rx - ry;
            return x.snake < y.snake ? -1 : (x.snake > y.snake ? 1 : 0);  // desempate alfabetico
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
        command: ["cat", lar + "/.config/omarchy/current/theme.name"]
        stdout: StdioCollector { onStreamFinished: { root.currentTheme = this.text.trim(); } }
    }
    // le a lista de favoritos (um slug por linha)
    Process {
        id: favReadProc
        command: ["cat", lar + "/.config/omarchy/theme-favorites"]
        stdout: StdioCollector {
            onStreamFinished: {
                var out = [], lines = this.text.split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var s = lines[i].trim();
                    if (s.length && out.indexOf(s) === -1) out.push(s);
                }
                root.favorites = out;
            }
        }
    }
    // alterna favorito e recarrega a lista ao terminar (grade reordena + estrela atualiza)
    Process { id: favToggleProc; onExited: favReadProc.running = true }
    function toggleFav(snake) {
        favToggleProc.command = [lar + "/.local/bin/omarchy-theme-fav", "toggle", snake];
        favToggleProc.running = true;
        root.themeMenuOpenFor = "";
    }
    function refreshThemes() { themesProc.running = true; curThemeProc.running = true; favReadProc.running = true; }
    function setTheme(snake) { Quickshell.execDetached(["omarchy-theme-set", snake]); root.currentTheme = snake; }

    // ---- update do Omarchy disponivel? (git ls-remote, poll raro) ----
    QtObject {
        id: omup
        property bool avail: false
        property string tag: ""
    }
    Process {
        id: omupProc
        // NAO usa `omarchy-update-available`: ele compara TAGS, e a tag mais nova
        // do repo e a do Quattro (v4.0.0-beta3, que o `sort -V` ainda joga na
        // frente do v4.0.0). Quem esta no 3.x nunca casa, entao o icone ficava
        // aceso pra sempre mesmo com a maquina 100% atualizada. Medido em
        // 2026-08-14: master em 3.8.5, zero migrations pendentes, icone aceso.
        //
        // Aqui a pergunta e outra e e a certa: existe commit novo na MINHA
        // branch? Compara o HEAD local com o remoto por ls-remote, sem fetch.
        // Sem rede ou fora de repo, sai != 0 e o icone continua apagado, que e
        // melhor que mentir dizendo que ha atualizacao.
        command: ["sh", "-c",
            "export OMARCHY_PATH=\"${OMARCHY_PATH:-$HOME/.local/share/omarchy}\"; " +
            "cd \"$OMARCHY_PATH\" || exit 1; " +
            "br=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 1; " +
            "loc=$(git rev-parse HEAD 2>/dev/null) || exit 1; " +
            "rem=$(GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote origin \"refs/heads/$br\" 2>/dev/null | awk '{print $1}'); " +
            "[ -n \"$rem\" ] || exit 1; " +
            "[ \"$loc\" != \"$rem\" ] || exit 1; " +
            "echo \"Omarchy update available ($(echo \"$rem\" | cut -c1-7))\"; exit 0"]
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
        property bool mouseFocus: true  // hover foca janela/monitor (desliga pra jogar)
    }
    Process {
        id: tgProc
        command: ["sh", "-c",
            "pgrep -x hypridle >/dev/null && caf=0 || caf=1; " +
            // estado confiavel via wrapper (a query de temperatura do hyprsunset mente no modo identity)
            "[ \"$($HOME/.local/bin/nightlight-toggle get)\" = on ] && night=1 || night=0; " +
            "wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null | grep -q MUTED && mic=1 || mic=0; " +
            "[ \"$($HOME/.local/bin/mouse-focus get)\" = on ] && mf=1 || mf=0; " +
            "echo \"$caf $night $mic $mf\""]
        stdout: StdioCollector {
            onStreamFinished: {
                var p = this.text.trim().split(" ");
                tg.caffeine = p[0] === "1"; tg.night = p[1] === "1"; tg.micMuted = p[2] === "1";
                tg.mouseFocus = p[3] === "1";
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
    function toggleNight() { tg.night = !tg.night; Quickshell.execDetached([lar + "/.local/bin/nightlight-toggle", "toggle"]); tgDelay.restart(); }
    function toggleMic() { tg.micMuted = !tg.micMuted; Quickshell.execDetached(["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"]); tgDelay.restart(); }
    function toggleMouseFocus() { tg.mouseFocus = !tg.mouseFocus; Quickshell.execDetached([lar + "/.local/bin/mouse-focus", "toggle"]); tgDelay.restart(); }

    // ============ volume do dispositivo de SAIDA REAL ============
    // o easyeffects_sink (default) ignora o proprio volume; controlamos o device
    // real (fone BT / alto-falante) via scripts/audio.sh
    QtObject { id: vols; property real vol: 0; property bool mut: false }
    property bool volDragging: false
    property real pendingVol: -1
    Process {
        id: volProc
        command: [lar + "/.config/quickshell/scripts/audio.sh", "get"]
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
                Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh",
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
        Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh", "toggle"]);
    }

    // ---- painel de audio estilo Windows: dispositivos de saida + volume por app + bass ----
    property var audioSinks: []
    property var audioApps: []
    property bool bassOn: false
    property bool mirrorMode: false   // toggle "Espelhar": lista vira multi-selecao
    property var mirrorSel: []         // names dos dispositivos marcados pro espelho
    Process {
        id: sinksProc
        command: [lar + "/.config/quickshell/scripts/audio.sh", "sinks"]
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
        command: [lar + "/.config/quickshell/scripts/audio.sh", "apps"]
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
        command: [lar + "/.config/quickshell/scripts/audio.sh", "bass-get"]
        stdout: StdioCollector { onStreamFinished: root.bassOn = (this.text.trim() === "1") }
    }
    Process {
        id: mirrorGetProc
        command: [lar + "/.config/quickshell/scripts/audio.sh", "mirror-get"]
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
        command: [lar + "/.config/quickshell/scripts/audio.sh", "mic-get"]
        stdout: StdioCollector { onStreamFinished: {
            if (root.micDragging) return;
            var p = this.text.trim().split(" "); mics.vol = (parseInt(p[0]) || 0) / 100; mics.mut = p[1] === "1";
        } }
    }
    Process {
        id: micSrcProc
        command: [lar + "/.config/quickshell/scripts/audio.sh", "sources"]
        stdout: StdioCollector { onStreamFinished: {
            var lines = this.text.trim().split("\n"); var arr = [];
            for (var i = 0; i < lines.length; i++) { if (!lines[i]) continue;
                var p = lines[i].split("|");
                arr.push({ name: p[0], active: p[1] === "1", icon: p[2] || "mic", desc: p.slice(3).join("|") || p[0] }); }
            root.micSources = arr;
        } }
    }
    Timer { id: micApply; interval: 90; repeat: false; onTriggered: {
        if (root.micPending >= 0) { Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh", "mic-set", "" + Math.round(root.micPending * 100)]); root.micPending = -1; } } }
    function refreshMic() { micGetProc.running = true; micSrcProc.running = true; }
    function setMicVol(f) { var ff = Math.max(0, Math.min(1, f)); mics.vol = ff; root.micPending = ff; if (!micApply.running) micApply.start(); }
    function toggleMicMuteAudio() { mics.mut = !mics.mut; Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh", "mic-toggle"]); }
    function setInput(name) { Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh", "input", name]);
                              for (var i = 0; i < micSources.length; i++) micSources[i].active = (micSources[i].name === name);
                              micSources = micSources.slice(); audioRefresh.restart(); }

    function refreshAudio() { sinksProc.running = true; appsProc.running = true; bassGetProc.running = true; mirrorGetProc.running = true; root.refreshVol(); root.refreshMic(); }
    function setOutput(name) { Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh", "output", name]);
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
            Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh", "mirror-off"]);
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
            Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh", "mirror", root.mirrorSel.join(",")]);
            root.bassOn = false;   // bass e espelho nao convivem
        } else if (root.mirrorSel.length === 1) {
            Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh", "output", root.mirrorSel[0]]);
        } else {
            Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh", "mirror-off"]);
        }
        audioRefresh.restart();
    }
    function setAppVol(id, f) { var p = Math.round(Math.max(0, Math.min(1, f)) * 100);
                                Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh", "app-vol", "" + id, "" + p]); }
    // redireciona saida do app para o sink indicado e reavalia
    function setAppOutput(ids, sink) {
        Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh", "app-output", "" + ids, sink]);
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
    function toggleAppMute(id) { Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh", "app-mute", "" + id]); audioRefresh.restart(); }
    // glyph por app (nerd font) pra identificar quem ta tocando no mixer
    function appIcon(name) {
        var n = (name || "").toLowerCase();
        if (n.indexOf("papel de parede") >= 0) return "󰸉";
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
                               Quickshell.execDetached([lar + "/.config/quickshell/scripts/audio.sh", "bass-toggle"]); audioRefresh.restart(); }
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

    // ============ notificacoes (historico do NotificationPanel, tema D) ============
    // substitui `makoctl history -j`: o historico ja mora em memoria no
    // NotificationPanel, so precisa copiar pra ca quando a view abre.
    property var notifs: []
    function refreshNotifs() { root.notifs = notifPanel.historyList; }

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
        // janela guardada na gaveta fica FORA do Alt+Tab: focar uma janela de
        // workspace especial traz o overlay do special e "trava" a tela com o
        // desktop apagado atras, a mesma armadilha que o minimizar ja documenta
        var escondidos = gaveta.escondidos;
        var all = ToplevelManager.toplevels.values.filter(function (t) {
            return escondidos.indexOf(t) === -1;
        });
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
        // pro workspace/monitor de origem, com o fullscreen/maximizado que ela ja tinha.
        // Igual ao KWin: o Alt+Tab so troca o foco, nunca forca um estado novo na janela.
        // activate() cru nao lida com minimizada.
        if (tl.appId && tl.appId.length)
            Quickshell.execDetached([
                lar + "/.config/quickshell/scripts/taskbar-activate.sh",
                tl.appId, tl.title || ""]);
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
            // o clique na linha "Personalizacao" chama refreshThemes() antes de
            // trocar a view (linha 2439); por IPC isso nao acontecia e a aba abria
            // com o grid de temas VAZIO. Mesmo caminho pros dois.
            if (view === "perso") root.refreshThemes();
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
                // janela guardada na gaveta sai da fileira: o icone da gaveta
                // vira o caminho de volta ate ela. Comparacao por IDENTIDADE do
                // toplevel: casar por titulo sumia com a irma de mesmo nome, e
                // deixava a guardada voltar quando o titulo dela mudava.
                var guardadas = gaveta.escondidos;
                for (var i = 0; i < list.length; i++) {
                    var t = list[i];
                    if (guardadas.indexOf(t) !== -1) continue;
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
                // com a gaveta cheia a ilha NAO pode sumir: ela leva junto o
                // unico caminho de volta ate a janela guardada
                visible: bar.groups.length > 0 || gaveta.count > 0
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

                            // badge de notificacao pendente (tema D2). Fica no canto
                            // de CIMA porque as bolinhas de janela ja ocupam o rodape
                            // do botao. Apaga quando o app recebe foco.
                            Rectangle {
                                anchors { top: parent.top; right: parent.right; margins: 2 }
                                width: 8; height: 8; radius: 4
                                color: theme.danger
                                z: 2
                                visible: (notifPanel.pendentesPorApp[appBtn.modelData.appId] || 0) > 0
                            }
                            onAnyActiveChanged: if (anyActive) notifPanel.limparPendente(modelData.appId)

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
                                    // janela sem appId existe (XWayland cru, janela recem-mapeada) e
                                    // `undefined.indexOf` estourava TypeError vivo no log
                                    if (!id || !id.length) return "";
                                    var de = DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id);
                                    // Catalogo ainda carregando (~2s apos o boot): nao pede icone com o
                                    // nome da CLASSE, que quase nunca e nome de icone valido
                                    // ("brave-browser" contra "brave-desktop"). Volta vazio e re-avalia
                                    // sozinho quando o catalogo chegar.
                                    if (!de && ready === 0) return "";
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
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                onClicked: function (e) {
                                    if (e.button === Qt.MiddleButton) { return; }
                                    if (e.button === Qt.RightButton) {
                                        // menu de contexto: encerrar / reiniciar / forcar
                                        var id = appBtn.modelData.appId;
                                        // janela sem appId existe (XWayland cru, janela recem-mapeada) e
                                        // `undefined.indexOf` estourava TypeError vivo no log
                                        if (!id || !id.length) return "";
                                        var de = DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id);
                                        // x do clique em coordenadas da tela: a barra ocupa a
                                        // largura toda, entao a cena da janela ja e a tela
                                        root.openAppMenu(id,
                                                         (de && de.name && de.name.length) ? de.name : id,
                                                         bar.screen,
                                                         appBtn.mapToItem(null, e.x, 0).x);
                                        return;
                                    }
                                    // script faz focus-OU-restore via hyprctl: se a janela do
                                    // app estiver minimizada (special:minimized) ela e restaurada
                                    // pro monitor de origem; senao foca/cicla. Evita activate()
                                    // cru, que trazia o overlay especial e travava.
                                    Quickshell.execDetached([
                                        lar + "/.config/quickshell/scripts/taskbar-activate.sh",
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
                                                                    lar + "/.config/quickshell/scripts/taskbar-activate.sh",
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

                // separador entre os apps abertos e a gaveta
                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 18
                    Layout.alignment: Qt.AlignVCenter
                    visible: bar.groups.length > 0
                    color: Qt.alpha(theme.accent, 0.2)
                }

                // ---- icone da gaveta ----
                // NUNCA some, nem com a gaveta vazia: se sumisse, a fileira se
                // deslocaria a cada guardar/tirar e ele perderia a referencia de
                // onde clicar. Vazia ele so apaga (fgDim).
                Rectangle {
                    id: gavBtn
                    implicitWidth: 40
                    implicitHeight: 32
                    radius: 8
                    color: gaveta.modo === "tirar" ? Qt.alpha(theme.accent, 0.2)
                           : (gavHov.hovered ? Qt.alpha(theme.accent, 0.13) : "transparent")

                    HoverHandler { id: gavHov }
                    property bool showList: gavHov.hovered || gavListHov.hovered
                    Timer { id: gavHideTimer; interval: 250; repeat: false }
                    onShowListChanged: showList ? gavHideTimer.stop() : gavHideTimer.restart()

                    // glifo, nao icone de tema: e o que distingue da fileira de
                    // apps ao lado, que e toda de icone colorido
                    Text {
                        anchors.centerIn: parent
                        text: "\uf187"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 16
                        color: gaveta.count > 0 ? theme.fg : theme.fgDim
                    }

                    // uma bolinha por janela guardada (teto de 4). Nao usa o
                    // badge vermelho: aquilo ja significa notificacao pendente.
                    Row {
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 1
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 3
                        Repeater {
                            model: Math.min(gaveta.count, 4)
                            delegate: Rectangle {
                                width: 4; height: 3; radius: 1.5
                                color: theme.accent
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: function (e) {
                            if (e.button === Qt.RightButton) {
                                if (gaveta.count > 0) gavMenu.visible = !gavMenu.visible;
                                return;
                            }
                            gavMenu.visible = false;
                            gaveta.abrirTirar();
                        }
                    }

                    // lista das guardadas no hover: titulo traz de volta na hora,
                    // X fecha a janela sem trazer
                    PopupWindow {
                        anchor.item: gavBtn
                        anchor.edges: Edges.Top
                        anchor.gravity: Edges.Top
                        implicitWidth: 230
                        implicitHeight: gavCol.implicitHeight + 12
                        visible: (gavBtn.showList || gavHideTimer.running) && gaveta.count > 0
                        color: "transparent"
                        Rectangle {
                            anchors.fill: parent
                            radius: 10
                            color: theme.bg
                            border.color: Qt.alpha(theme.accent, 0.2)
                            border.width: 1
                            HoverHandler { id: gavListHov }
                            ColumnLayout {
                                id: gavCol
                                anchors.fill: parent
                                anchors.margins: 6
                                spacing: 2
                                Repeater {
                                    model: gaveta.itens
                                    delegate: Rectangle {
                                        required property string addr
                                        required property string appId
                                        required property string titulo
                                        Layout.fillWidth: true
                                        implicitHeight: 28
                                        radius: 6
                                        color: gavRowHov.hovered ? Qt.alpha(theme.accent, 0.2) : "transparent"
                                        HoverHandler { id: gavRowHov }
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: 9; anchors.rightMargin: 6
                                            spacing: 4
                                            Text {
                                                Layout.fillWidth: true
                                                color: theme.fg; font.pixelSize: 12
                                                elide: Text.ElideRight
                                                text: titulo || appId || addr
                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: gaveta.tirar(addr)
                                                }
                                            }
                                            // X com CONFIRMACAO em dois toques. Ele fica a 4px
                                            // do titulo que restaura, num popup que abre so de
                                            // passar o mouse, e fecha a janela de verdade: errar
                                            // o alvo com um kitty rodando sessao viva perde a
                                            // sessao. O 1o toque arma, o 2o executa, e 3s sem
                                            // toque desarma sozinho.
                                            Rectangle {
                                                id: xBtn
                                                property bool armado: false
                                                Layout.preferredWidth: armado ? 62 : 20
                                                Layout.preferredHeight: 20
                                                radius: 5
                                                color: armado ? Qt.alpha(theme.danger, 0.28)
                                                              : (gavXHov.hovered ? Qt.alpha(theme.danger, 0.2) : "transparent")
                                                Behavior on Layout.preferredWidth {
                                                    NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
                                                }
                                                Timer {
                                                    id: xDesarma
                                                    interval: 3000; repeat: false
                                                    onTriggered: xBtn.armado = false
                                                }
                                                // desarma se o mouse sair da lista inteira
                                                Connections {
                                                    target: gavBtn
                                                    function onShowListChanged() { if (!gavBtn.showList) xBtn.armado = false }
                                                }
                                                Text {
                                                    anchors.centerIn: parent
                                                    font.family: "JetBrainsMono Nerd Font"
                                                    font.pixelSize: xBtn.armado ? 10 : 12
                                                    color: (xBtn.armado || gavXHov.hovered) ? theme.danger : theme.fgDim
                                                    text: xBtn.armado ? "fechar?" : "󰅖"
                                                }
                                                HoverHandler { id: gavXHov }
                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        if (!xBtn.armado) { xBtn.armado = true; xDesarma.restart(); return; }
                                                        xDesarma.stop();
                                                        xBtn.armado = false;
                                                        gaveta.fecharJanela(addr);
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // menu do botao direito: acao em lote, nunca fecha janela
                    PopupWindow {
                        id: gavMenu
                        anchor.item: gavBtn
                        anchor.edges: Edges.Top
                        anchor.gravity: Edges.Top
                        implicitWidth: 200
                        implicitHeight: 40
                        visible: false
                        color: "transparent"
                        Rectangle {
                            anchors.fill: parent
                            radius: 10
                            color: theme.bg
                            border.color: Qt.alpha(theme.accent, 0.2)
                            border.width: 1
                            Rectangle {
                                anchors.fill: parent
                                anchors.margins: 6
                                radius: 6
                                color: gavTudoHov.hovered ? Qt.alpha(theme.accent, 0.2) : "transparent"
                                HoverHandler { id: gavTudoHov }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left
                                    anchors.leftMargin: 9
                                    text: "Trazer tudo de volta"
                                    color: theme.fg; font.pixelSize: 12
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { gavMenu.visible = false; gaveta.tirarTudo(); }
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

                // ---- system tray: apps em segundo plano ----
                // Em vez dos icones soltos na barra, um botao unico abre um painel
                // pequeno com a grade dos apps, igual ao "mostrar icones ocultos"
                // do Windows. O botao some sozinho quando a bandeja esta vazia.
                Item {
                    id: trayBtn
                    property var trayItems: SystemTray.items ? SystemTray.items.values : []
                    property bool open: false
                    property double lastCleared: 0
                    visible: trayItems.length > 0
                    onVisibleChanged: if (!visible) open = false
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: visible ? 22 : 0
                    Layout.preferredHeight: 22

                    Rectangle {
                        anchors.fill: parent
                        radius: 6
                        color: trayBtn.open ? Qt.alpha(theme.accent, 0.20)
                               : (trayHover.hovered ? Qt.alpha(theme.accent, 0.12) : "transparent")
                        HoverHandler { id: trayHover }
                        Text {
                            anchors.centerIn: parent
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 13
                            color: trayBtn.open ? theme.accent : theme.fgDim
                            // grade, nao chevron: a central de acoes ao lado ja usa
                            // "󰅃" e dois chevrons colados ficavam ambiguos
                            text: "󰕰"
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                // o focus grab ja fechou no mesmo clique -> nao reabrir
                                if (Date.now() - trayBtn.lastCleared < 200) return;
                                trayBtn.open = !trayBtn.open;
                            }
                        }
                    }

                    // fecha o painel ao clicar em qualquer lugar fora dele
                    HyprlandFocusGrab {
                        windows: [trayPopup]
                        active: trayBtn.open
                        onCleared: {
                            trayBtn.open = false;
                            // marca o instante: o clique no proprio botao tambem conta
                            // como "fora", e sem isso o onClicked logo em seguida
                            // reabriria o painel (parecendo que ele nunca fecha)
                            trayBtn.lastCleared = Date.now();
                        }
                    }

                    // painel: abre PRA CIMA porque a barra fica embaixo da tela
                    PopupWindow {
                        id: trayPopup
                        anchor.item: trayBtn
                        anchor.edges: Edges.Top
                        anchor.gravity: Edges.Top
                        visible: trayBtn.open
                        color: "transparent"
                        // Tamanho FIXO, calculado so a partir da grade. Nao pode depender
                        // do hover: se o painel se redimensiona ao mostrar o nome, ele
                        // cresce pra cima, o icone sai de baixo do cursor, o hover cai,
                        // o painel encolhe e o cursor volta ao icone -> flicker infinito.
                        implicitWidth: Math.max(trayGrid.implicitWidth, 120) + 16
                        implicitHeight: trayGrid.implicitHeight + 18 + 16

                        Rectangle {
                            id: trayCard
                            property string hovered: ""
                            anchors.fill: parent
                            radius: 10
                            color: theme.bg
                            border.width: 1
                            border.color: Qt.alpha(theme.accent, 0.2)

                            ColumnLayout {
                                id: trayCol
                                anchors.fill: parent
                                anchors.margins: 8
                                spacing: 0

                                GridLayout {
                                    id: trayGrid
                                    Layout.alignment: Qt.AlignHCenter
                                    columns: Math.min(4, Math.max(1, trayBtn.trayItems.length))
                                    rowSpacing: 2
                                    columnSpacing: 2

                                    Repeater {
                                        model: trayBtn.trayItems
                                        delegate: Rectangle {
                                            required property var modelData
                                            implicitWidth: 36; implicitHeight: 36
                                            radius: 8
                                            color: itemHover.hovered ? Qt.alpha(theme.accent, 0.18) : "transparent"
                                            HoverHandler {
                                                id: itemHover
                                                onHoveredChanged: trayCard.hovered = hovered
                                                    ? ("" + (modelData.tooltipTitle || modelData.title || "")) : ""
                                            }
                                            Image {
                                                anchors.centerIn: parent
                                                width: 20; height: 20
                                                fillMode: Image.PreserveAspectFit
                                                source: modelData.icon
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                                onClicked: function (e) {
                                                    if (e.button === Qt.RightButton) {
                                                        // menu de contexto do proprio app (Quit Discord etc.):
                                                        // vem via DBusMenu, quickshell so precisa de um QsWindow
                                                        // de ancora e um ponto local a ele pra abrir perto do clique
                                                        if (modelData.hasMenu)
                                                            modelData.display(trayPopup, e.x, e.y);
                                                        return;
                                                    }
                                                    if (e.button === Qt.MiddleButton) { modelData.secondaryActivate(); return; }
                                                    // Steam: activate() nao restaura a janela quando esta fechado
                                                    // pra bandeja. O steam:// abre a janela principal da instancia ativa.
                                                    var id = ("" + (modelData.id || "") + (modelData.title || "")).toLowerCase();
                                                    if (id.indexOf("steam") !== -1)
                                                        Quickshell.execDetached(["steam", "steam://open/main"]);
                                                    else
                                                        modelData.activate();
                                                    trayBtn.open = false;
                                                }
                                            }
                                        }
                                    }
                                }

                                // nome do app sob o cursor (o Windows mostra em tooltip).
                                // fillWidth + preferredWidth 1 impede o texto de ditar a
                                // largura do painel; altura fixa mantem o espaco reservado
                                // mesmo sem hover. Some por opacidade, nunca por visible,
                                // pra nao alterar o tamanho do layout.
                                Text {
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 1
                                    Layout.preferredHeight: 18
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                    elide: Text.ElideRight
                                    font.pixelSize: 11
                                    color: theme.fgDim
                                    opacity: trayCard.hovered.length > 0 ? 1 : 0
                                    text: trayCard.hovered
                                }
                            }
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
                    // sai do layout quando fecha de vez: item de largura zero
                    // ainda consome o spacing dos dois lados, e sobrava um vao
                    // grande entre o chevron e o sino com a barra recolhida
                    visible: Layout.preferredWidth > 0
                    Behavior on Layout.preferredWidth {
                        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                    }
                    RowLayout {
                        id: clusterRow
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: ui.moduleSpacing

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
                    property real stress: Math.max(0, Math.min(1, sys.cpu / 100))
                    color: root.corCarga(stress)
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 13
                    text: "CPU " + sys.cpu + "%"
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["kitty", "btop"])
                    }
                }

                // ---- ram ----
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    property real stress: Math.max(0, Math.min(1, sys.mem / 100))
                    color: root.corCarga(stress)
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 13
                    text: "RAM " + sys.mem + "%"
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
                    // temperatura util vai de ~35C (parada) a ~85C (limite),
                    // entao normaliza nessa faixa em vez de 0..100
                    property real stress: Math.max(0, Math.min(1, (gpu.temp - 35) / 50))
                    color: root.corCarga(stress)
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 13
                    text: "GPU " + gpu.temp + "°"
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

                    // A BATERIA E O BOTAO DE ENERGIA. Ideia dele: em vez de uma
                    // linha "Energia" na central, o proprio modulo abre o menu de
                    // desligar. Alvo maior que o desenho (o icone tem 30x14, o alvo
                    // tem 34x24) porque 14px de altura e alvo pequeno demais pra
                    // mouse. Realce discreto no hover, so pra ele descobrir que e
                    // clicavel; sem isso o alvo ficaria invisivel.
                    Rectangle {
                        anchors.centerIn: parent
                        width: 34; height: 24
                        radius: 6
                        z: -1
                        color: battMa.containsMouse ? Qt.alpha(theme.accent, 0.18) : "transparent"
                    }
                    MouseArea {
                        id: battMa
                        anchors.centerIn: parent
                        width: 34; height: 24
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["sh", "-c", "omarchy-menu power || wlogout"])
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

                    } // fim clusterRow
                } // fim clusterBox

                // ---- notificacoes: sino SEMPRE visivel ----
                // Fica FORA do clusterBox de proposito: dentro dele o sino sumia
                // com a barra recolhida e nao dava pra ver que havia notificacao
                // nova sem expandir.
                Item {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: 18; implicitHeight: 18
                    // glifo reflete o modo: sem isso nao da pra saber que esta
                    // em silencio ate perder uma notificacao (tema D2)
                    Text {
                        anchors.centerIn: parent
                        color: notifPanel.modo === "normal" ? theme.fg : theme.fgDim
                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14
                        text: notifPanel.modo === "dnd" ? "󰂛"
                              : (notifPanel.modo === "discreto" ? "󰂜" : "󰂚")
                    }
                    // contador de NAO LIDAS, ligado direto na propriedade do painel.
                    // Antes era root.notifs.length, uma copia congelada que so
                    // atualizava ao abrir a central: nao acendia em notificacao nova
                    // e nunca mais apagava depois da primeira.
                    Rectangle {
                        visible: notifPanel.naoLidas > 0
                        // DENTRO dos limites do item: com margem negativa o badge
                        // saia da ilha da barra e aparecia cortado
                        anchors.right: parent.right; anchors.top: parent.top
                        implicitWidth: Math.max(11, cntTxt.implicitWidth + 5); implicitHeight: 11
                        radius: 6; color: theme.danger
                        Text {
                            id: cntTxt
                            anchors.centerIn: parent
                            text: notifPanel.naoLidas > 9 ? "9+" : notifPanel.naoLidas
                            font.pixelSize: 8; font.bold: true
                            color: theme.bg
                        }
                    }
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.acScreen = bar.screen; card.view = "notif";
                            root.refreshNotifs(); notifPanel.marcarLidas(); root.acOpen = true;
                        }
                    }
                }


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

                // relogio: clique abre o calendario, estilo Windows 11
                Text {
                    id: relogioTxt
                    Layout.alignment: Qt.AlignVCenter
                    color: relogioHov.hovered ? theme.accent : theme.fg
                    font.pixelSize: 13
                    text: clock.date.toLocaleString(Qt.locale("pt_BR"), "ddd dd/MM  HH:mm")
                    HoverHandler { id: relogioHov }
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: calendario.aberto ? calendario.fechar()
                                                     : calendario.abrir(bar.screen)
                    }
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
    // ---- menu de contexto do icone da taskbar (botao direito) ----
    // janela propria em fullscreen: pinta o menu junto do mouse e captura o
    // clique fora pra fechar (PopupWindow ancorado no icone nao pega clique fora).
    PanelWindow {
        visible: root.appMenuFor !== "" || menuBox.opacity > 0.01
        screen: root.appMenuScreen ? root.appMenuScreen : Quickshell.screens[0]
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qsbar-appmenu"

        // clique fora (qualquer botao) fecha
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onClicked: root.appMenuFor = ""
        }

        Rectangle {
            id: menuBox
            width: 200
            implicitHeight: appMenuCol.implicitHeight + 10
            height: implicitHeight
            // segue o mouse na horizontal (preso na tela) e senta em cima da barra
            x: Math.max(6, Math.min(root.appMenuX - 12, parent.width - width - 6))
            y: parent.height - ui.islandHeight - ui.barMargin * 2 - height - 6
            radius: 12
            color: Qt.alpha(theme.bg, 0.97)
            border.color: Qt.alpha(theme.accent, 0.25)
            border.width: 1
            opacity: root.appMenuFor !== "" ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

            // absorve o clique dentro do menu (senao o backdrop fecha antes da acao)
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: appMenuCol
                anchors.fill: parent; anchors.margins: 5; spacing: 2

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 9; Layout.rightMargin: 9
                    Layout.topMargin: 3; Layout.bottomMargin: 2
                    color: theme.fgDim; font.pixelSize: 11
                    elide: Text.ElideRight
                    text: root.appMenuLabel
                }

                Repeater {
                    model: [
                        { icon: "󰅖", label: "Encerrar",            act: "close",   danger: false },
                        { icon: "󰑐", label: "Reiniciar",           act: "restart", danger: false },
                        { icon: "󰚌", label: "Forçar encerramento", act: "kill",    danger: true  }
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 30
                        radius: 6
                        color: itemHov.hovered
                               ? Qt.alpha(modelData.danger ? theme.danger : theme.accent, 0.2)
                               : "transparent"
                        HoverHandler { id: itemHov }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 9; anchors.rightMargin: 9
                            spacing: 8
                            Text {
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13
                                color: modelData.danger ? theme.danger : theme.accent
                                text: modelData.icon
                            }
                            Text {
                                Layout.fillWidth: true
                                color: modelData.danger ? theme.danger : theme.fg
                                font.pixelSize: 12
                                text: modelData.label
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                var id = root.appMenuFor;
                                if (id === "") return;
                                if (modelData.act === "close") root.appClose(id);
                                else if (modelData.act === "restart") root.appRestart(id);
                                else root.appKill(id);
                                root.appMenuFor = "";
                            }
                        }
                    }
                }
            }
        }
    }

    // backdrop de dismiss nos OUTROS monitores: o card vive so no acScreen, entao
    // sem isto um clique em qualquer outro monitor nao fecha a central.
    Variants {
        model: Quickshell.screens
        PanelWindow {
            property var modelData
            screen: modelData
            visible: root.acOpen && root.acScreen && modelData.name !== root.acScreen.name
            anchors { top: true; bottom: true; left: true; right: true }
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "qsbar-ac-dismiss"
            MouseArea { anchors.fill: parent; onClicked: root.acOpen = false }
        }
    }

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
            property string view: "main"   // "main" | "wifi" | "bt" | "notif" | "perso" | "audio"
            onViewChanged: { if (view === "wifi") root.refreshWifi();
                             else if (view === "notif") root.refreshNotifs();
                             else if (view === "audio") root.refreshAudio();
                             else if (view === "monitors") { monitorsCol.reload(); monitorsCol.loadProfiles(); }
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
                             : (view === "audio" ? audioCol.implicitHeight
                             : (view === "perso" ? persoCol.implicitHeight
                             : (view === "monitors" ? monitorsCol.implicitHeight : acCol.implicitHeight)))))) + 28
            // teto pela altura logica da propria janela layershell, nao pela
            // fisica do monitor: assim vale em qualquer monitor e escala. Sem
            // isso a lista de notificacoes empurrava o cabecalho pra fora da tela.
            height: Math.min(implicitHeight,
                             parent.height - (ui.islandHeight + ui.barMargin * 2 + 6) - 40)
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 8
            anchors.bottomMargin: ui.islandHeight + ui.barMargin * 2 + 6
            radius: 16
            // fundo praticamente solido: com 0.75 o texto da janela atras
            // vazava atraves do card inteiro e virava ruido visual sobre o
            // conteudo do painel. 0.97 e o mesmo valor ja usado no card do
            // Alt+Tab (linha 1665), entao fica coerente com o resto da shell.
            color: Qt.alpha(theme.bg, 0.97)
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

                // toggles rapidos: caffeine, nightlight, mic, foco por mouse
                // (Bass saiu daqui em 2026-06-24: da pra ver/ativar na aba "Som")
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: [
                            { key: "caf",   icon: "󰅶", label: "Cafeína" },
                            { key: "night", icon: "󰖔", label: "Noturno" },
                            { key: "mic",   icon: "󰍬", label: "Mic" },
                            { key: "focus", icon: "󰍽", label: "Foco" }
                        ]
                        delegate: Rectangle {
                            required property var modelData
                            property bool on: modelData.key === "caf" ? tg.caffeine
                                            : (modelData.key === "night" ? tg.night
                                            : (modelData.key === "mic" ? !tg.micMuted
                                            : tg.mouseFocus))
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
                                    else if (modelData.key === "mic") root.toggleMic();
                                    else root.toggleMouseFocus();
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
                        id: netPill
                        Layout.fillWidth: true
                        implicitHeight: 52; radius: 12
                        // conectado E estado real (cabo ou wifi com rede), entao recebe o
                        // mesmo destaque do Bluetooth ligado. Sem rede fica neutra.
                        // (antes ficava sempre neutra e parecia desligada mesmo conectada)
                        property bool conectado: sys.net === "eth" || sys.net.indexOf("wifi") === 0
                        color: conectado ? Qt.alpha(theme.accent, 0.2) : theme.bgAlt
                        border.color: conectado ? theme.accent : "transparent"; border.width: 1
                        ColumnLayout {
                            anchors.centerIn: parent; spacing: 1
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18
                                color: netPill.conectado ? theme.accent : theme.fgDim
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

                // separador entre o bloco grade (toggles/pills) e o bloco lista abaixo
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 4; Layout.bottomMargin: 4
                    height: 1
                    color: theme.surface
                }

                // bloco lista: personalizacao, monitores, energia. Sem "Menu" (o
                // Lucas ja tem SUPER pra isso, botao era redundante) e sem
                // subtitulo (ficava inconsistente com as linhas sem subtitulo, e
                // o texto de duas linhas desalinhava o icone/chevron das linhas de
                // uma linha so). Todos uniformes: icone + label + chevron,
                // centralizados de verdade (Layout.alignment explicito, referencia
                // Windows 11). Coluna propria com spacing apertado (4px), pra nao
                // herdar o spacing 14 do acCol, que e o respiro ENTRE secoes, nao
                // entre linha e linha dentro da mesma lista.
                ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                Repeater {
                    model: [
                        { icon: "󰉼", label: "Personalização", view: "perso", cmd: null },
                        { icon: "󰍹", label: "Monitores", view: "monitors", cmd: null }
                        // "Energia" saiu daqui em 2026-08-14: virou clique no proprio
                        // modulo de bateria da barra, ideia dele. Linha de menu que so
                        // dispara um comando externo nao pertence a uma lista de
                        // paineis, e o alvo agora fica onde o assunto ja esta.
                    ]
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 46; radius: 12
                        color: listMa.containsMouse ? theme.surface2 : theme.bgAlt
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: theme.accent; text: modelData.icon
                            }
                            Text {
                                Layout.fillWidth: true; Layout.alignment: Qt.AlignVCenter
                                color: theme.fgBright; font.pixelSize: 12; font.bold: true; text: modelData.label
                            }
                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                text: "󰅂"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14; color: theme.fgDim
                            }
                        }
                        MouseArea {
                            id: listMa
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (modelData.cmd) { Quickshell.execDetached(modelData.cmd); root.acOpen = false; return; }
                                if (modelData.view === "perso") root.refreshThemes();
                                card.view = modelData.view;
                            }
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

                // ---- medicao da conexao ----
                // Mora aqui, e nao num dropdown proprio na barra, porque esta
                // tela so tinha a lista de redes e sobrava espaco morto embaixo.
                //
                // Tres pernas de proposito, e cada uma acusa um trecho diferente:
                // roteador alto = wifi da casa, roteador bom com internet alta =
                // provedor, dns alto = resolucao de nome. Em 14/08 a internet
                // ficou inutilizavel com ping em 46ms e download a 15 MB/s: o
                // quebrado era so o dns, e sem essa terceira linha o painel teria
                // mostrado tudo verde durante o problema inteiro.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    implicitHeight: 1
                    color: Qt.alpha(theme.fgDim, 0.25)
                }

                Text {
                    text: "Conexão"
                    color: theme.fgDim
                    font.pixelSize: 11
                    font.bold: true
                    Layout.topMargin: 2
                }

                Repeater {
                    model: [
                        { rot: "Roteador", val: net.gw,   teto: 20  },
                        { rot: "Internet", val: net.inet, teto: 150 },
                        { rot: "DNS",      val: net.dns,  teto: 300 }
                    ]
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 6
                        Text {
                            Layout.fillWidth: true
                            text: modelData.rot
                            color: theme.fg
                            font.pixelSize: 12
                        }
                        Text {
                            text: modelData.val < 0 ? "falhou" : modelData.val + " ms"
                            color: root.corCarga(modelData.val < 0 ? 1
                                   : Math.max(0, Math.min(1, modelData.val / modelData.teto)))
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 12
                        }
                    }
                }

                // Teste de velocidade: SO no clique. Baixa 25 MB e envia 10 MB,
                // entao rodar sozinho de tempos em tempos gastaria a franquia dele
                // e atrapalharia jogo em andamento.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 6
                    implicitHeight: 30
                    radius: 8
                    color: net.testando ? Qt.alpha(theme.accent, 0.35)
                         : (btnVelHov.hovered ? Qt.alpha(theme.accent, 0.22) : theme.surface2)
                    HoverHandler { id: btnVelHov }
                    Text {
                        anchors.centerIn: parent
                        text: net.testando ? "testando…" : "Testar velocidade"
                        color: theme.fg
                        font.pixelSize: 12
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: !net.testando
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.testarVelocidade()
                    }
                }

                Text {
                    text: "Últimos testes"
                    color: theme.fgDim
                    font.pixelSize: 11
                    font.bold: true
                    Layout.topMargin: 4
                }
                Text {
                    visible: net.hist.length === 0
                    text: "nenhum ainda"
                    color: theme.fgDim
                    font.pixelSize: 11
                }
                Repeater {
                    model: net.hist
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            text: root.netQuando(modelData.t)
                            color: theme.fgDim
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 11
                        }
                        Item { Layout.fillWidth: true }
                        Text {
                            text: modelData.down < 0 ? "falhou" : modelData.down + " Mb \u2193"
                            color: theme.fg
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 11
                        }
                        Text {
                            visible: modelData.up >= 0
                            text: modelData.up + " Mb \u2191"
                            color: theme.fgDim
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 11
                        }
                    }
                }
                // Lista rolavel com teto de altura. Com 13 redes por perto a
                // coluna passava da altura do card e o bloco de conexao ia
                // desenhar POR CIMA da barra, fora do painel.
                Flickable {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(redesCol.implicitHeight, 250)
                    contentHeight: redesCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ColumnLayout {
                        id: redesCol
                        width: parent.width
                        spacing: 8
                        Repeater {
                            model: root.wifiNets
                            delegate: Rectangle {
                                id: netRow
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: rowCol.implicitHeight + 8; radius: 8
                                // hover e realce neutro; accent fica so pra conexao real (tema A)
                                color: modelData.conn ? Qt.alpha(theme.accent, 0.13)
                                       : (netRowMa.containsMouse ? theme.surface2 : "transparent")

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
                        // === true: com o menu fechado wifiMenuData e {}, e undefined nao pode
                        // ser atribuido a bool (gerava warning no log do quickshell)
                        visible: !wifiCol.wifiShowDetails && wifiCol.wifiMenuData.conn === true
                        Layout.fillWidth: true; implicitHeight: 30; radius: 6
                        color: dMa.containsMouse ? Qt.alpha(theme.accent, 0.2) : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 8
                               text: "Desconectar"; color: theme.fg; font.pixelSize: 12 }
                        MouseArea { id: dMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { root.wifiCmd(["disconnect"]); wifiCol.wifiMenuFor = ""; } }
                    }
                    // Esquecer (conhecida)
                    Rectangle {
                        visible: !wifiCol.wifiShowDetails && wifiCol.wifiMenuData.known === true
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
                    Text { text: "Notificações"; color: theme.fg; font.pixelSize: 14; font.bold: true }
                    Item { Layout.fillWidth: true }

                    // ---- modo de notificacao, clicavel (o Lucas nao usa atalho) ----
                    // um chip por modo, o ativo destacado. Substitui depender do
                    // SUPER CTRL virgula, que continua funcionando em paralelo.
                    Repeater {
                        model: [
                            { m: "normal",   ic: "󰂚", dica: "Normal: pílula + som" },
                            { m: "discreto", ic: "󰂜", dica: "Discreto: só ícone no app + som" },
                            { m: "dnd",      ic: "󰂛", dica: "Não perturbe: só histórico" }
                        ]
                        delegate: Rectangle {
                            required property var modelData
                            property bool ativo: notifPanel.modo === modelData.m
                            implicitWidth: 26; implicitHeight: 22; radius: 6
                            color: ativo ? Qt.alpha(theme.accent, 0.2)
                                         : (modoMa.containsMouse ? theme.surface2 : "transparent")
                            border.color: ativo ? theme.accent : "transparent"; border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: modelData.ic
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13
                                color: parent.ativo ? theme.accent : theme.fgDim
                            }
                            MouseArea {
                                id: modoMa
                                anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: notifPanel.setModo(modelData.m)
                            }
                        }
                    }
                    // separador entre os modos e as acoes da lista
                    Rectangle { implicitWidth: 1; implicitHeight: 16; color: theme.surface }

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
                    // limpar de verdade: dispensa as pilulas ativas e zera o
                    // historico (tema D, NotificationPanel.qml, sem mako)
                    Text {
                        text: "󰎟"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15
                        color: root.notifs.length > 0 ? theme.fg : theme.surface2
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        notifPanel.limparTudo();
                                        root.notifs = [];
                                    } }
                    }
                    Text {
                        text: "󰑐"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16; color: theme.fg
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.refreshNotifs() }
                    }
                }

                // lista rolavel: antes o card crescia pra cima sem limite e com
                // ~12 itens o cabecalho e o botao de limpar saiam pela borda de
                // cima da tela. O cabecalho fica FORA do Flickable, sempre visivel.
                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredHeight: Math.min(histCol.implicitHeight, 420)
                    contentHeight: histCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ColumnLayout {
                        id: histCol
                        width: parent.width
                        spacing: 8
                        Repeater {
                            model: root.notifs
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                Layout.fillWidth: true
                                implicitHeight: ntCol.implicitHeight + 12
                                radius: 8
                                color: ntMa.containsMouse ? theme.surface2 : theme.bgAlt
                                ColumnLayout {
                                    id: ntCol
                                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                                    anchors.leftMargin: 10; anchors.rightMargin: 34
                                    spacing: 1
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Text {
                                            Layout.fillWidth: true; color: theme.accent; font.pixelSize: 10
                                            elide: Text.ElideRight
                                            text: (modelData["appName"] || "")
                                        }
                                        Text {
                                            color: theme.fgDim; font.pixelSize: 10
                                            text: modelData["ts"] ? notifPanel._hora(modelData["ts"]) : ""
                                        }
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

                                    // ---- resposta rapida, so em notificacao do celular ----
                                    // Aparece no HISTORICO de proposito: a pilula some em
                                    // segundos e ele pediu para poder responder depois.
                                    // Funciona enquanto o app de origem nao cancelar a
                                    // acao; quando cancelar, o celular devolve o motivo.
                                    RowLayout {
                                        visible: !!(modelData["podeResponder"]) && !!(modelData["chaveCel"])
                                        Layout.fillWidth: true
                                        Layout.topMargin: 4
                                        spacing: 6
                                        Rectangle {
                                            Layout.fillWidth: true
                                            implicitHeight: 26
                                            radius: 6
                                            color: theme.surface2
                                            TextInput {
                                                id: campoResp
                                                anchors.fill: parent
                                                anchors.leftMargin: 8; anchors.rightMargin: 8
                                                verticalAlignment: TextInput.AlignVCenter
                                                color: theme.fg; font.pixelSize: 11
                                                clip: true
                                                onAccepted: {
                                                    notifPanel.responderCelular(modelData["chaveCel"], text);
                                                    text = "";
                                                }
                                                Text {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    visible: campoResp.text === ""
                                                    text: "responder…"
                                                    color: theme.fgDim; font.pixelSize: 11
                                                }
                                            }
                                        }
                                        Rectangle {
                                            implicitWidth: 30; implicitHeight: 26
                                            radius: 6
                                            color: envHov.hovered ? theme.accent : Qt.alpha(theme.accent, 0.35)
                                            HoverHandler { id: envHov }
                                            Text {
                                                anchors.centerIn: parent
                                                text: "\u{F048A}"
                                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13
                                                color: theme.fg
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    notifPanel.responderCelular(modelData["chaveCel"], campoResp.text);
                                                    campoResp.text = "";
                                                }
                                            }
                                        }
                                    }
                                }
                                // clique no corpo vai pra origem (so pelo appId: a acao
                                // "default" do protocolo nao sobrevive ao fechamento)
                                MouseArea {
                                    id: ntMa
                                    anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { notifPanel.ativarHistorico(index); root.acOpen = false; }
                                }
                                // remove SO este item
                                Rectangle {
                                    anchors { right: parent.right; top: parent.top; margins: 4 }
                                    width: 24; height: 24; radius: 12
                                    color: rmMa.containsMouse ? theme.surface : "transparent"
                                    Text {
                                        anchors.centerIn: parent
                                        text: "󰅖"; font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 11; color: theme.fgDim
                                    }
                                    MouseArea {
                                        id: rmMa
                                        anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: { notifPanel.removerHistorico(index); root.refreshNotifs(); }
                                    }
                                }
                            }
                        }
                    }
                }

                Text {
                    visible: root.notifs.length === 0
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    color: theme.fgDim; font.pixelSize: 11
                    text: "Sem notificações recentes"
                }
            }

            // ---- view: personalizacao (tema + papel de parede) ----
            MonitorPanel {
                id: monitorsCol
                visible: card.view === "monitors"
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 14
                theme: theme
                screen: root.acScreen
                onBack: card.view = "main"
                // aplicou ao vivo: fecha a central (sem flash) e mostra o toast lendo o
                // pending. O reload que corrige a barra fica pro Confirmar/Reverter.
                onApplied: { card.view = "main"; root.acOpen = false; monPendingProc.running = true; }
            }

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
                    Text { Layout.fillWidth: true; text: "Personalização"; color: theme.fg; font.pixelSize: 14; font.bold: true }
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
                                id: themeCard
                                required property var modelData
                                readonly property bool current: modelData.snake === root.currentTheme
                                readonly property bool fav: root.isFav(modelData.snake)
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
                                    // estrela: tema favoritado
                                    Text {
                                        visible: themeCard.fav
                                        text: "󰓎"; font.family: "JetBrainsMono Nerd Font"
                                        font.pixelSize: 13; color: theme.accent
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
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: function (e) {
                                        if (e.button === Qt.RightButton) {
                                            root.themeMenuOpenFor = modelData.snake;   // abre menu de contexto
                                        } else {
                                            root.themeMenuOpenFor = "";
                                            root.setTheme(modelData.snake);            // esquerdo aplica
                                        }
                                    }
                                }
                                // fecha o menu ao sair do card e do popup (com tolerancia)
                                property bool menuHovering: tHov.containsMouse || menuAreaHover.hovered
                                onMenuHoveringChanged: menuHovering ? menuCloseTimer.stop() : menuCloseTimer.restart()
                                Timer {
                                    id: menuCloseTimer; interval: 400
                                    onTriggered: if (root.themeMenuOpenFor === modelData.snake) root.themeMenuOpenFor = ""
                                }
                                // menu de contexto (clique direito): Favoritar / Desfavoritar
                                PopupWindow {
                                    anchor.item: themeCard
                                    anchor.edges: Edges.Bottom
                                    anchor.gravity: Edges.Bottom
                                    implicitWidth: 160
                                    implicitHeight: menuCol.implicitHeight + 10
                                    visible: root.themeMenuOpenFor === modelData.snake
                                    color: "transparent"
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 10
                                        color: theme.bg
                                        border.color: Qt.alpha(theme.accent, 0.25); border.width: 1
                                        HoverHandler { id: menuAreaHover }
                                        ColumnLayout {
                                            id: menuCol
                                            anchors.fill: parent; anchors.margins: 5; spacing: 2
                                            Rectangle {
                                                Layout.fillWidth: true; implicitHeight: 30; radius: 6
                                                color: favRowHov.hovered ? Qt.alpha(theme.accent, 0.2) : "transparent"
                                                HoverHandler { id: favRowHov }
                                                RowLayout {
                                                    anchors.fill: parent; anchors.leftMargin: 9; anchors.rightMargin: 9; spacing: 8
                                                    Text {
                                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13
                                                        color: theme.accent; text: "󰓎"
                                                    }
                                                    Text {
                                                        Layout.fillWidth: true; color: theme.fg; font.pixelSize: 12
                                                        text: themeCard.fav ? "Desfavoritar" : "Favoritar"
                                                    }
                                                }
                                                MouseArea {
                                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.toggleFav(modelData.snake)
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


            // ---- menu de contexto de saida por app (botao direito) ----
            MouseArea {
                visible: card.view === "audio" && audioCol.appMenuFor !== ""
                anchors.fill: parent; z: 99
                acceptedButtons: Qt.AllButtons
                onClicked: { audioCol.appMenuFor = ""; }
            }
            Rectangle {
                id: appOutMenu
                visible: card.view === "audio" && audioCol.appMenuFor !== ""
                z: 100
                x: audioCol.appMenuX; y: audioCol.appMenuY
                width: 178
                implicitHeight: appOutMenuCol.implicitHeight + 12
                height: implicitHeight
                radius: 10
                color: theme.bgAlt
                border.color: Qt.alpha(theme.accent, 0.3); border.width: 1

                ColumnLayout {
                    id: appOutMenuCol
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    anchors.margins: 6
                    spacing: 2

                    Text {
                        Layout.fillWidth: true; Layout.margins: 4
                        text: audioCol.appMenuData.name || ""
                        color: theme.fgBright; font.pixelSize: 11; font.bold: true; elide: Text.ElideRight
                    }

                    // um item por dispositivo de saida
                    Repeater {
                        model: root.audioSinks
                        delegate: Rectangle {
                            required property var modelData
                            property bool isCur: modelData.name === audioCol.appMenuData.outSink
                            Layout.fillWidth: true; implicitHeight: 30; radius: 6
                            color: devMa.containsMouse ? theme.surface2 : "transparent"
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; spacing: 8
                                Text { text: root.sinkGlyph(modelData.icon); font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14
                                       color: isCur ? theme.accent : theme.fg }
                                Text { Layout.fillWidth: true; text: modelData.desc; color: theme.fg; font.pixelSize: 12; elide: Text.ElideRight }
                                Text { visible: isCur; text: "󰄬"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 12; color: theme.ok }
                            }
                            MouseArea { id: devMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.setAppOutput(audioCol.appMenuData.ids, modelData.name);
                                    audioCol.appMenuFor = "";
                                } }
                        }
                    }

                    // voltar ao padrao (so quando o app esta roteado pra fora do padrao)
                    Rectangle {
                        visible: audioCol.appMenuData.outSink !== root.defaultSinkName() && root.defaultSinkName() !== ""
                        Layout.fillWidth: true; implicitHeight: 30; radius: 6
                        color: defMa.containsMouse ? theme.surface2 : "transparent"
                        Text { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 8
                               text: "Voltar ao padrao"; color: theme.warn; font.pixelSize: 12 }
                        MouseArea { id: defMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.setAppOutput(audioCol.appMenuData.ids, root.defaultSinkName());
                                audioCol.appMenuFor = "";
                            } }
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
                // estado do menu de contexto de saida por app (botao direito)
                property string appMenuFor: ""
                property real appMenuX: 0
                property real appMenuY: 0
                property var appMenuData: ({})

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
                    Text { Layout.fillWidth: true; text: "Saída"; color: theme.fgBright; font.pixelSize: 13; font.bold: true }
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
                        color: checked ? Qt.alpha(theme.accent, 0.2) : (sinkMa.containsMouse ? theme.surface2 : "transparent")
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
                    delegate: Rectangle {
                        id: appRow
                        required property var modelData
                        property real av: modelData.vol
                        // app roteado pra um device real diferente do padrao
                        property var curSink: root.sinkByName(modelData.outSink)
                        property bool routed: curSink !== null && root.defaultSinkName() !== ""
                                              && modelData.outSink !== root.defaultSinkName()
                        Layout.fillWidth: true
                        implicitHeight: appContent.implicitHeight + 12; radius: 8
                        color: routed ? Qt.alpha(theme.accent, 0.10)
                                      : (appRowMa.containsMouse ? Qt.alpha(theme.accent, 0.06) : "transparent")

                        RowLayout {
                            id: appContent
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                            anchors.leftMargin: 6; anchors.rightMargin: 6; spacing: 8
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
                                // badge bem visivel quando o app esta mudo (chip vermelho, estilo do "conectado")
                                Rectangle {
                                    visible: appRow.modelData.mut
                                    Layout.alignment: Qt.AlignLeft
                                    Layout.topMargin: 1
                                    implicitWidth: mutRow.implicitWidth + 12; implicitHeight: 16; radius: 8
                                    color: Qt.alpha(theme.danger, 0.20)
                                    RowLayout {
                                        id: mutRow; anchors.centerIn: parent; spacing: 4
                                        Text { text: "󰝟"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10; color: theme.danger }
                                        Text { text: "mutado"; font.pixelSize: 9; font.bold: true; color: theme.danger }
                                    }
                                }
                            }
                            Text { Layout.preferredWidth: 30; text: Math.round(Math.min(1, appRow.av) * 100) + "%"; color: theme.fgDim
                                   font.pixelSize: 10; horizontalAlignment: Text.AlignRight }
                            // icone do device de saida atual (so quando esta num device real)
                            Text {
                                visible: appRow.curSink !== null
                                text: appRow.curSink ? root.sinkGlyph(appRow.curSink.icon) : ""
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14
                                color: appRow.routed ? theme.accent : theme.fgDim
                                Layout.preferredWidth: 18; horizontalAlignment: Text.AlignHCenter
                            }
                        }
                        // botao direito -> menu de escolha de saida (so RightButton: clique esquerdo cai pro slider/icone abaixo)
                        MouseArea {
                            id: appRowMa; anchors.fill: parent; hoverEnabled: true
                            acceptedButtons: Qt.RightButton; cursorShape: Qt.ArrowCursor
                            onClicked: function (e) {
                                var pt = appRow.mapToItem(card, e.x, e.y);
                                audioCol.appMenuX = Math.max(8, Math.min(pt.x, card.width - 186));
                                audioCol.appMenuY = Math.max(8, Math.min(pt.y, card.height - 60));
                                audioCol.appMenuData = { ids: appRow.modelData.id, name: appRow.modelData.name, outSink: appRow.modelData.outSink };
                                audioCol.appMenuFor = appRow.modelData.id;
                            }
                        }
                    }
                }

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: theme.surface }

                // ---- microfone ----
                Text { text: "Microfone"; color: theme.fgBright; font.pixelSize: 13; font.bold: true }
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
                        color: modelData.active ? Qt.alpha(theme.ok, 0.2) : (srcMa.containsMouse ? theme.surface2 : "transparent")
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
                                                // janela sem appId existe (XWayland cru, janela recem-mapeada) e
                                                // `undefined.indexOf` estourava TypeError vivo no log
                                                if (!id || !id.length) return "";
                                                var de = DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id);
                                                // Catalogo ainda carregando (~2s apos o boot): nao pede icone com o
                                                // nome da CLASSE, que quase nunca e nome de icone valido
                                                // ("brave-browser" contra "brave-desktop"). Volta vazio e re-avalia
                                                // sozinho quando o catalogo chegar.
                                                if (!de && ready === 0) return "";
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
