//@ pragma UseQApplication
// Barra em Quickshell. Objetivo: taskbar AGRUPADA por app dentro da barra.
// Iteracao 1: menu Omarchy + taskbar agrupada + relogio. Modulos de status virao depois.
import Quickshell
import Quickshell.Wayland
import Quickshell.Wayland._Screencopy
import Quickshell.Io
import Quickshell.Services.SystemTray
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import Quickshell.Bluetooth
import QtQuick
import QtQuick.Layouts

ShellRoot {
    id: root
    readonly property string scripts: Quickshell.env("HOME") + "/.config/quickshell/scripts"
    // estado global: central de acoes (dropdown estilo Windows) aberta?
    property bool acOpen: false
    property var acScreen: null   // monitor onde a central abre (o do chevron clicado)

    // relogio do sistema
    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // mantem o sink de audio padrao "vivo" pra volume/mute atualizarem em tempo real
    PwObjectTracker {
        objects: Pipewire.defaultAudioSink ? [Pipewire.defaultAudioSink] : []
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
            "if [ -d \"$i/wireless\" ]; then q=$(awk -v dev=\"$d:\" '$1==dev{print int($3*100/70)}' /proc/net/wireless); " +
            "s=$(iw dev \"$d\" link 2>/dev/null | sed -n 's/.*SSID: //p'); " +
            "echo \"wifi:${q:-0}:${s:-Wi-Fi}\"; exit 0; else echo eth; exit 0; fi; done; echo off"]
        stdout: StdioCollector { onStreamFinished: sys.net = this.text.trim() }
    }
    Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: netProc.running = true }

    // ---- lista de redes wifi (iwd) p/ o dropdown de conexao rapida ----
    property var wifiNets: []
    Process {
        id: wifiListProc
        command: [root.scripts + "/wifi-list.sh"]
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = this.text.trim().split("\n");
                var arr = [];
                for (var i = 0; i < lines.length; i++) {
                    if (!lines[i]) continue;
                    var p = lines[i].split("|");
                    arr.push({ conn: p[0] === "1", sig: parseInt(p[1]) || 0,
                               name: p.slice(2).join("|") });
                }
                root.wifiNets = arr;
            }
        }
    }
    function refreshWifi() { wifiListProc.running = true; }
    function connectWifi(name) {
        Quickshell.execDetached([root.scripts + "/wifi-connect.sh", name]);
    }

    // ---- clima (omarchy-weather): poll raro, curl a wttr.in ----
    QtObject {
        id: weather
        property string icon: ""
        property string temp: ""
        property string place: ""
        property string wind: ""
        property bool ok: false
    }
    Process {
        id: weatherProc
        command: [root.scripts + "/weather.sh"]
        stdout: StdioCollector {
            onStreamFinished: {
                var p = this.text.trim().split("\t");
                weather.icon = p[0] || "";
                weather.temp = p[1] || "";
                weather.place = p[2] || "";
                weather.wind = p[3] || "";
                weather.ok = (weather.icon !== "" || weather.temp !== "");
            }
        }
    }
    Timer { interval: 1200000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: weatherProc.running = true }   // 20 min

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

    // ---- voxtype (ditado): stream de estado JSON por linha ----
    QtObject {
        id: vox
        property string state: ""   // idle | recording | transcribing | ...
        property string tip: ""
        property bool present: false
    }
    Process {
        id: voxProc
        command: ["sh", "-c",
            "export PATH=\"$HOME/.local/share/omarchy/bin:$PATH\"; exec omarchy-voxtype-status"]
        running: true
        stdout: SplitParser {
            onRead: function (line) {
                try {
                    var o = JSON.parse(line);
                    vox.state = o.class || o.alt || "";
                    vox.tip = o.tooltip || "";
                    vox.present = true;
                } catch (e) {}
            }
        }
    }

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
    function attConfirm() {
        var tl = (attOpen && attList[attIndex]) ? attList[attIndex] : null;
        attOpen = false;   // fecha e solta o teclado ANTES de focar
        if (!tl) return;
        // usa o mesmo restore da taskbar: foca OU restaura minimizada (special:minimized)
        // pro workspace/monitor de origem. activate() cru nao lida com minimizada.
        if (tl.appId && tl.appId.length)
            Quickshell.execDetached([
                root.scripts + "/taskbar-activate.sh",
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
            implicitHeight: 38
            // ~85% opaca: o wallpaper aparece sutilmente atraves da barra (AARRGGBB, D9=~85%)
            color: "#d91a1b26"

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

            // menu Omarchy (ancorado a esquerda)
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                    text: ""
                    font.family: "omarchy"
                    font.pixelSize: 20
                    color: "#a9b1d6"
                    Layout.alignment: Qt.AlignVCenter
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["omarchy-menu"])
                    }
                }

            // ---- taskbar agrupada (CENTRO da tela) ----
            RowLayout {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
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
                            color: anyActive ? "#33557aa2" : (hov.hovered ? "#22557aa2" : "transparent")

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
                                        color: "#7aa2f7"
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
                                        root.scripts + "/taskbar-activate.sh",
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
                                    color: "#1a1b26"
                                    border.color: "#33557aa2"
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
                                                color: rowHover.hovered ? "#33557aa2"
                                                       : ((win && win.activated) ? "#22557aa2" : "transparent")
                                                HoverHandler { id: rowHover }
                                                Text {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    anchors.left: parent.left; anchors.leftMargin: 9
                                                    anchors.right: parent.right; anchors.rightMargin: 9
                                                    color: "#a9b1d6"; font.pixelSize: 12
                                                    elide: Text.ElideRight
                                                    text: (win && win.title && win.title.length)
                                                          ? win.title : appBtn.modelData.appId
                                                }
                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        if (!win) return;
                                                        // foca/restaura a janela ESPECIFICA (por titulo) via script
                                                        Quickshell.execDetached([
                                                            root.scripts + "/taskbar-activate.sh",
                                                            appBtn.modelData.appId, win.title || ""]);
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

            // ---- grupo da direita: status ----
            RowLayout {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12

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
                                    if (e.button === Qt.MiddleButton) modelData.secondaryActivate();
                                    else modelData.activate();
                                }
                            }
                        }
                    }
                }

                // ---- update do Omarchy disponivel ----
                Text {
                    visible: omup.avail
                    Layout.alignment: Qt.AlignVCenter
                    color: "#e0af68"
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
                    color: "#a9b1d6"
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
                    color: "#a9b1d6"
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 13
                    text: "󰍛 " + sys.mem + "%"
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Quickshell.execDetached(["kitty", "btop"])
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
                        border.color: "#a9b1d6"
                        border.width: 1.5

                        // preenchimento proporcional a carga
                        Rectangle {
                            anchors.left: parent.left
                            anchors.leftMargin: 2
                            anchors.verticalCenter: parent.verticalCenter
                            height: parent.height - 4
                            width: Math.max(0, (parent.width - 4) * battWidget.frac)
                            radius: 1.5
                            color: battWidget.chg ? "#9ece6a"
                                   : (battWidget.frac <= 0.15 ? "#f7768e" : "#7aa2f7")
                            Behavior on width { NumberAnimation { duration: 300 } }
                        }
                    }
                    // polo (nub) na ponta direita
                    Rectangle {
                        anchors.left: battBody.right
                        anchors.leftMargin: 1
                        anchors.verticalCenter: parent.verticalCenter
                        width: 2.5; height: 6; radius: 1
                        color: "#a9b1d6"
                    }
                }

                // ---- chevron: abre a central de acoes ----
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    color: root.acOpen ? "#7aa2f7" : "#a9b1d6"
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
                    color: "#a9b1d6"
                    font.pixelSize: 13
                    text: clock.date.toLocaleString(Qt.locale("pt_BR"), "ddd dd/MM  HH:mm")
                }
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
        onVisibleChanged: if (!visible) card.view = "main"   // sempre reabre na view principal
        screen: root.acScreen ? root.acScreen : Quickshell.screens[0]
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qsbar-ac"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

        // backdrop: clique fora do card fecha
        MouseArea { anchors.fill: parent; onClicked: root.acOpen = false }

        Rectangle {
            id: card
            property string view: "main"   // "main" | "wifi" | "bt"
            onViewChanged: if (view === "wifi") root.refreshWifi()
            // animacao de abrir/fechar: fade + leve slide de baixo pra cima
            opacity: root.acOpen ? 1 : 0
            property real slide: root.acOpen ? 0 : 14
            transform: Translate { y: card.slide }
            Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            Behavior on slide { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            width: 340
            implicitHeight: (view === "wifi" ? wifiCol.implicitHeight
                             : (view === "bt" ? btCol.implicitHeight : acCol.implicitHeight)) + 28
            height: implicitHeight
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 8
            anchors.bottomMargin: 46
            radius: 16
            color: "#1a1b26"
            border.color: "#33557aa2"
            border.width: 1

            // absorve cliques no card pra nao fechar ao clicar em espaco vazio
            MouseArea { anchors.fill: parent }

            property var sink: Pipewire.defaultAudioSink
            property real vol: (sink && sink.audio) ? sink.audio.volume : 0
            property bool mut: (sink && sink.audio) ? sink.audio.muted : false
            function setVol(v) {
                if (sink && sink.audio) sink.audio.volume = Math.max(0, Math.min(1, v));
            }

            ColumnLayout {
                id: acCol
                visible: card.view === "main"
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 14
                spacing: 14

                // titulo
                Text {
                    text: "Ajustes rapidos"
                    color: "#a9b1d6"; font.pixelSize: 14; font.bold: true
                }

                // volume: glyph + slider + %
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: card.mut ? "󰝟" : "󰕾"
                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18
                        color: "#a9b1d6"
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: { if (card.sink && card.sink.audio) card.sink.audio.muted = !card.sink.audio.muted; }
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        height: 6; radius: 3; color: "#2a2e44"
                        Rectangle {
                            width: parent.width * (card.mut ? 0 : card.vol)
                            height: parent.height; radius: 3; color: "#7aa2f7"
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onPressed: function (e) { card.setVol(e.x / width); }
                            onPositionChanged: function (e) { if (pressed) card.setVol(e.x / width); }
                        }
                    }
                    Text {
                        Layout.preferredWidth: 36
                        text: Math.round(card.vol * 100) + "%"
                        color: "#a9b1d6"; font.pixelSize: 12; horizontalAlignment: Text.AlignRight
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
                        color: "#22557aa2"
                        ColumnLayout {
                            anchors.centerIn: parent; spacing: 1
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: "#7aa2f7"
                                text: sys.net === "eth" ? "󰈀" : (sys.net.indexOf("wifi") === 0 ? "󰤨" : "󰤭")
                            }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                color: "#a9b1d6"; font.pixelSize: 11
                                elide: Text.ElideRight
                                Layout.maximumWidth: 120
                                text: sys.net === "eth" ? "Cabo"
                                      : (sys.net.indexOf("wifi") === 0 ? (sys.net.split(":").slice(2).join(":") || "Wi-Fi") : "Sem rede")
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
                        color: on ? "#33557aa2" : "#1f2235"
                        border.color: on ? "#557aa2" : "transparent"; border.width: 1
                        ColumnLayout {
                            anchors.centerIn: parent; spacing: 1
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18
                                color: btPill.on ? "#7aa2f7" : "#6b7089"
                                text: btPill.on ? "󰂯" : "󰂲"
                            }
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                color: "#a9b1d6"; font.pixelSize: 11
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

                // bateria
                RowLayout {
                    Layout.fillWidth: true
                    visible: UPower.displayDevice && UPower.displayDevice.isLaptopBattery
                    spacing: 8
                    property var d: UPower.displayDevice
                    Text {
                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16; color: "#a9b1d6"
                        text: "󰁹"
                    }
                    Text {
                        Layout.fillWidth: true
                        color: "#a9b1d6"; font.pixelSize: 12
                        text: "Bateria  " + (parent.d ? Math.round(parent.d.percentage * 100) : 0) + "%"
                    }
                }

                // clima (movido da barra; mostra lugar e vento)
                RowLayout {
                    Layout.fillWidth: true
                    visible: weather.ok
                    spacing: 8
                    Text {
                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16; color: "#7aa2f7"
                        text: weather.icon || "󰖐"
                    }
                    Text {
                        Layout.fillWidth: true
                        color: "#a9b1d6"; font.pixelSize: 12; elide: Text.ElideRight
                        text: (weather.temp || "--")
                              + (weather.place ? "  ·  " + weather.place : "")
                              + (weather.wind ? "  ·  " + weather.wind : "")
                    }
                    Text {
                        text: "󰑐"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13; color: "#6b7089"
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: weatherProc.running = true }
                    }
                }

                // voxtype (ditado): mic indica estado; clique abre a config
                Rectangle {
                    Layout.fillWidth: true
                    visible: vox.present
                    implicitHeight: 30; radius: 8
                    color: voxMa.containsMouse ? "#33557aa2" : "transparent"
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 2; anchors.rightMargin: 6; spacing: 8
                        Text {
                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16
                            color: vox.state === "recording" ? "#f7768e"
                                   : (vox.state === "transcribing" ? "#e0af68" : "#7aa2f7")
                            text: "󰍬"
                        }
                        Text {
                            Layout.fillWidth: true
                            color: "#a9b1d6"; font.pixelSize: 12
                            text: "Voxtype  " + (vox.state === "recording" ? "gravando"
                                  : (vox.state === "transcribing" ? "transcrevendo" : "pronto"))
                        }
                        Text { text: "󰒓"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 12; color: "#6b7089" }
                    }
                    MouseArea {
                        id: voxMa
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Quickshell.execDetached(["sh", "-c",
                                "export PATH=\"$HOME/.local/share/omarchy/bin:$PATH\"; exec kitty -e omarchy-voxtype-config"]);
                            root.acOpen = false;
                        }
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
                            color: actMa.containsMouse ? "#33557aa2" : "#1f2235"
                            ColumnLayout {
                                anchors.centerIn: parent; spacing: 2
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16; color: "#a9b1d6"
                                    text: modelData.icon
                                }
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    color: "#a9b1d6"; font.pixelSize: 10
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

            // ---- view: lista de redes wifi (conexao rapida) ----
            ColumnLayout {
                id: wifiCol
                visible: card.view === "wifi"
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 14
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        text: "󰁍"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: "#a9b1d6"
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: card.view = "main" }
                    }
                    Text { text: "Redes Wi-Fi"; color: "#a9b1d6"; font.pixelSize: 14; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: "󰑐"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16; color: "#a9b1d6"
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.refreshWifi() }
                    }
                }

                Repeater {
                    model: root.wifiNets
                    delegate: Rectangle {
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 36; radius: 8
                        color: netRowMa.containsMouse ? "#33557aa2"
                               : (modelData.conn ? "#22557aa2" : "transparent")
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10; anchors.rightMargin: 10
                            spacing: 8
                            Text {
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15; color: "#7aa2f7"
                                text: modelData.sig >= 4 ? "󰤨" : (modelData.sig === 3 ? "󰤥"
                                      : (modelData.sig === 2 ? "󰤢" : (modelData.sig >= 1 ? "󰤟" : "󰤯")))
                            }
                            Text {
                                Layout.fillWidth: true
                                color: "#a9b1d6"; font.pixelSize: 12; elide: Text.ElideRight
                                text: modelData.name
                            }
                            Text {
                                visible: modelData.conn
                                color: "#9ece6a"; font.pixelSize: 10
                                text: "conectado"
                            }
                        }
                        MouseArea {
                            id: netRowMa
                            anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.connectWifi(modelData.name)
                        }
                    }
                }

                Text {
                    visible: root.wifiNets.length === 0
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    color: "#6b7089"; font.pixelSize: 11
                    text: "Procurando redes…"
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

                // cabecalho: voltar / titulo / escanear / abrir bluetui
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        text: "󰁍"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 18; color: "#a9b1d6"
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: card.view = "main" }
                    }
                    Text { text: "Bluetooth"; color: "#a9b1d6"; font.pixelSize: 14; font.bold: true }
                    Item { Layout.fillWidth: true }
                    // escanear (toggle discovering) — so quando o radio esta ligado
                    Text {
                        visible: btCol.adp ? btCol.adp.enabled : false
                        text: "󰑐"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16
                        color: (btCol.adp && btCol.adp.discovering) ? "#7aa2f7" : "#a9b1d6"
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: if (btCol.adp) btCol.adp.discovering = !btCol.adp.discovering }
                    }
                    // abrir bluetui (parear dispositivo novo)
                    Text {
                        text: "󰍜"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16; color: "#a9b1d6"
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { Quickshell.execDetached(["omarchy-launch-bluetooth"]); root.acOpen = false } }
                    }
                }

                // radio desligado: oferece ligar (ligar e seguro; nao togglamos OFF aqui)
                Rectangle {
                    visible: btCol.adp ? !btCol.adp.enabled : true
                    Layout.fillWidth: true
                    implicitHeight: 40; radius: 8
                    color: btOnMa.containsMouse ? "#33557aa2" : "#1f2235"
                    Text {
                        anchors.centerIn: parent
                        color: "#a9b1d6"; font.pixelSize: 12
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
                        color: btRowMa.containsMouse ? "#33557aa2"
                               : (modelData.connected ? "#22557aa2" : "transparent")
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10; anchors.rightMargin: 10
                            spacing: 8
                            Text {
                                font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15
                                color: btRow.modelData.connected ? "#7aa2f7" : "#6b7089"
                                text: "󰂯"
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                Text {
                                    Layout.fillWidth: true
                                    color: "#a9b1d6"; font.pixelSize: 12; elide: Text.ElideRight
                                    text: btRow.modelData.deviceName || btRow.modelData.name || btRow.modelData.address
                                }
                                Text {
                                    visible: btRow.modelData.batteryAvailable && btRow.modelData.connected
                                    color: "#6b7089"; font.pixelSize: 9
                                    text: "bateria " + Math.round(btRow.modelData.battery * 100) + "%"
                                }
                            }
                            Text {
                                color: btRow.busy ? "#e0af68"
                                       : (btRow.modelData.connected ? "#9ece6a" : "#6b7089")
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
                            onClicked: {
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
                    color: "#6b7089"; font.pixelSize: 11
                    text: "Nenhum dispositivo pareado"
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
                }
            }
            Keys.onReleased: function (e) {
                if (e.key === Qt.Key_Alt || e.key === Qt.Key_Meta) {
                    root.attConfirm(); e.accepted = true;
                }
            }
        }

        Rectangle {
            id: attCard
            anchors.centerIn: parent
            opacity: 0
            scale: 0.95
            transformOrigin: Item.Center
            Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            width: Math.min(att.width * 0.94, attRow.implicitWidth + 40)
            height: attRow.implicitHeight + 36
            radius: 18
            color: "#ee16161e"
            border.color: "#33557aa2"; border.width: 1
            MouseArea { anchors.fill: parent }   // absorve cliques no card

            RowLayout {
                id: attRow
                anchors.centerIn: parent
                spacing: 14
                Repeater {
                    model: root.attList
                    delegate: Rectangle {
                        id: thumb
                        required property var modelData
                        required property int index
                        property bool sel: index === root.attIndex
                        implicitWidth: 240
                        implicitHeight: 176
                        radius: 12
                        color: sel ? "#332f6aa8" : "#1f2235"
                        border.color: sel ? "#7aa2f7" : "#2a2e44"
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
                                        return Quickshell.iconPath(icon, "application-x-executable");
                                    }
                                }
                                Text {
                                    color: thumb.sel ? "#c0caf5" : "#a9b1d6"
                                    font.pixelSize: 11; elide: Text.ElideRight
                                    Layout.maximumWidth: 188
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
                            onPositionChanged: root.attIndex = thumb.index
                            onClicked: { root.attIndex = thumb.index; root.attConfirm(); }
                        }
                    }
                }
            }
        }
    }
}
