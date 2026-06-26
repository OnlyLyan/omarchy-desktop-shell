// ===== BLOCO A: estado + processos (cole na raiz do shell.qml, perto dos outros pollers) =====
    // ============ monitor do Claude Code (trabalhando? agentes? workflow?) ============
    QtObject {
        id: claude
        property bool working: false
        property int agents: 0
        property string kind: "none"   // workflow | single | none
        property int sessions: 0
    }
    Process {
        id: claudeProc
        command: ["/home/lucas/.config/quickshell/scripts/claude-status.sh"]
        stdout: StdioCollector { onStreamFinished: {
            var p = this.text.trim().split(" ");
            claude.working = p[0] === "working";
            claude.agents = parseInt(p[1]) || 0;
            claude.kind = p[2] || "none";
            claude.sessions = parseInt(p[3]) || 0;
        } }
    }
    Timer { interval: 3000; running: true; repeat: true; triggeredOnStart: true
            onTriggered: claudeProc.running = true }

    // salas (uma por sessao): nome|working|nagents
    property var claudeRooms: []
    Process {
        id: roomsProc
        command: ["/home/lucas/.config/quickshell/scripts/claude-status.sh", "rooms"]
        stdout: StdioCollector { onStreamFinished: {
            var lines = this.text.trim().split("\n"); var arr = [];
            for (var i = 0; i < lines.length; i++) { if (!lines[i]) continue;
                var p = lines[i].split("|");
                arr.push({ name: p[0] || "sessao", working: p[1] === "1", agents: parseInt(p[2]) || 0 }); }
            root.claudeRooms = arr;
        } }
    }
    function refreshRooms() { roomsProc.running = true; }


// ===== BLOCO B: icone + popup das Salas (cole dentro da RowLayout do cluster direito) =====
                // ---- monitor do Claude Code: robo pulsa quando trabalhando; badge = nº de agentes ----
                Item {
                    id: claudeBtn
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: claudeRow.implicitWidth; implicitHeight: 22
                    property bool popOpen: false
                    onPopOpenChanged: if (popOpen) root.refreshRooms()
                    Timer { interval: 2500; running: claudeBtn.popOpen; repeat: true
                            triggeredOnStart: true; onTriggered: root.refreshRooms() }

                    Row {
                        id: claudeRow
                        anchors.centerIn: parent
                        spacing: 3
                        property color accent: claude.kind === "workflow" ? "#bb9af7" : "#7aa2f7"

                        // spinner de "carregando" enquanto trabalha (braille girando)
                        Text {
                            id: spin
                            visible: claude.working
                            anchors.verticalCenter: parent.verticalCenter
                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 12
                            color: claudeRow.accent
                            property int frame: 0
                            readonly property var frames: ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
                            text: frames[frame]
                            Timer { interval: 80; running: spin.visible; repeat: true
                                    onTriggered: spin.frame = (spin.frame + 1) % spin.frames.length }
                        }

                        // robo (cor pelo estado)
                        Text {
                            id: claudeIcon
                            anchors.verticalCenter: parent.verticalCenter
                            font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16
                            text: "󰚩"
                            color: claude.working ? claudeRow.accent : "#6b7089"
                        }

                        // agentes: bolinhas indo de um lado pro outro, e a Claude estalando
                        // o chicote em cima delas (animacao besta, 2026-06-25)
                        Item {
                            id: agentTrack
                            visible: claude.agents > 0
                            anchors.verticalCenter: parent.verticalCenter
                            width: 38; height: 16
                            Repeater {
                                model: claude.agents
                                delegate: Rectangle {
                                    required property int index
                                    width: 5; height: 5; radius: 2.5
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: claudeRow.accent
                                    SequentialAnimation on x {
                                        loops: Animation.Infinite; running: true
                                        NumberAnimation { from: 0; to: 32; duration: 620 + (index % 4) * 140; easing.type: Easing.InOutSine }
                                        NumberAnimation { from: 32; to: 0; duration: 620 + (index % 4) * 140; easing.type: Easing.InOutSine }
                                    }
                                }
                            }
                            // chicote: estala periodicamente do lado do robo (esquerda)
                            Canvas {
                                id: whip
                                anchors.fill: parent
                                property real t: 0   // 0 relaxado .. 1 estalado
                                onTChanged: requestPaint()
                                SequentialAnimation on t {
                                    loops: Animation.Infinite; running: agentTrack.visible
                                    PauseAnimation { duration: 1200 }
                                    NumberAnimation { from: 0; to: 1; duration: 170; easing.type: Easing.OutQuad }
                                    NumberAnimation { from: 1; to: 0; duration: 130; easing.type: Easing.InQuad }
                                }
                                onPaint: {
                                    var ctx = getContext("2d"); ctx.reset();
                                    var w = width, h = height, t = whip.t;
                                    var sx = 0, sy = h * 0.3;                 // punho (lado do robo)
                                    var reach = 0.35 + 0.6 * t;
                                    var tx = w * reach, ty = h * 0.62;        // ponta do chicote
                                    var cx = w * reach * 0.45, cy = h * 0.15 - t * 4;  // curva relaxa -> estala
                                    ctx.strokeStyle = claudeRow.accent;
                                    ctx.lineWidth = 1.4; ctx.lineCap = "round"; ctx.lineJoin = "round";
                                    ctx.beginPath(); ctx.moveTo(sx, sy); ctx.quadraticCurveTo(cx, cy, tx, ty); ctx.stroke();
                                    if (t > 0.7) {   // estalo na ponta
                                        ctx.beginPath();
                                        ctx.moveTo(tx, ty); ctx.lineTo(tx + 3.5, ty - 3.5);
                                        ctx.moveTo(tx, ty); ctx.lineTo(tx + 4, ty + 1.5);
                                        ctx.stroke();
                                    }
                                }
                            }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: { claudeProc.running = true; root.refreshRooms(); claudeBtn.popOpen = !claudeBtn.popOpen }
                    }

                    // popup com o detalhe (cresce pra cima, barra fica no rodape)
                    PopupWindow {
                        id: claudePop
                        anchor.item: claudeBtn
                        anchor.edges: Edges.Top
                        anchor.gravity: Edges.Top
                        implicitWidth: 280
                        implicitHeight: claudePopCol.implicitHeight + 20
                        visible: claudeBtn.popOpen
                        color: "transparent"
                        Rectangle {
                            anchors.fill: parent; radius: 10; color: "#1a1b26"
                            border.color: "#33557aa2"; border.width: 1
                            ColumnLayout {
                                id: claudePopCol
                                anchors.fill: parent; anchors.margins: 12; spacing: 8
                                RowLayout {
                                    Layout.fillWidth: true; spacing: 8
                                    Text { font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16
                                           color: claude.working ? "#7aa2f7" : "#6b7089"; text: "󰚩" }
                                    Text { Layout.fillWidth: true; color: "#c0caf5"; font.pixelSize: 13; font.bold: true; text: "Salas do Claude" }
                                    Text { color: "#6b7089"; font.pixelSize: 10; text: root.claudeRooms.length + " sala(s)" }
                                }

                                Text { visible: root.claudeRooms.length === 0; color: "#6b7089"; font.pixelSize: 11
                                       text: "Nenhuma sessao recente." }

                                // uma SALA por sessao: Claude na mesa + alunos (agentes)
                                Repeater {
                                    model: root.claudeRooms
                                    delegate: Rectangle {
                                        id: room
                                        required property var modelData
                                        Layout.fillWidth: true
                                        radius: 8; color: "#15161e"
                                        border.color: room.modelData.working ? "#33557aa2" : "#2a2e42"; border.width: 1
                                        implicitHeight: roomCol.implicitHeight + 14

                                        ColumnLayout {
                                            id: roomCol
                                            anchors.fill: parent; anchors.margins: 7; spacing: 6
                                            // placa da sala
                                            RowLayout {
                                                Layout.fillWidth: true; spacing: 5
                                                Rectangle { width: 6; height: 6; radius: 3
                                                            color: room.modelData.working ? "#9ece6a" : "#3a3f5a" }
                                                Text { Layout.fillWidth: true; color: "#a9b1d6"; font.pixelSize: 10
                                                       elide: Text.ElideRight; text: room.modelData.name }
                                                Text { color: "#6b7089"; font.pixelSize: 9
                                                       text: room.modelData.agents > 0 ? (room.modelData.agents + " agentes")
                                                             : (room.modelData.working ? "so a Claude" : "vazia") }
                                            }
                                            // a sala
                                            RowLayout {
                                                Layout.fillWidth: true; spacing: 10
                                                // Claude professora + mesa
                                                ColumnLayout {
                                                    spacing: 2
                                                    Rectangle {
                                                        Layout.alignment: Qt.AlignHCenter
                                                        width: 24; height: 24; radius: 12; color: "#1f2235"
                                                        border.color: room.modelData.working ? "#7aa2f7" : "#3a3f5a"; border.width: 1
                                                        Text { anchors.centerIn: parent; font.family: "JetBrainsMono Nerd Font"
                                                               font.pixelSize: 14; color: room.modelData.working ? "#7aa2f7" : "#6b7089"; text: "󰚩" }
                                                    }
                                                    Rectangle { Layout.alignment: Qt.AlignHCenter; width: 32; height: 5; radius: 2; color: "#3a3f5a" }
                                                }
                                                // alunos (agentes) ou cadeiras vazias
                                                Flow {
                                                    Layout.fillWidth: true; spacing: 6
                                                    Repeater {
                                                        model: room.modelData.agents > 0 ? room.modelData.agents : 3
                                                        delegate: Item {
                                                            required property int index
                                                            width: 14; height: 20
                                                            Rectangle { anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
                                                                        width: 13; height: 4; radius: 1; color: "#2a2e42" }   // cadeira
                                                            Rectangle {
                                                                visible: room.modelData.agents > 0
                                                                anchors.horizontalCenter: parent.horizontalCenter; anchors.top: parent.top; anchors.topMargin: 2
                                                                width: 10; height: 10; radius: 5
                                                                color: room.modelData.agents > 1 ? "#bb9af7" : "#7aa2f7"
                                                                SequentialAnimation on y {
                                                                    loops: Animation.Infinite; running: room.modelData.working
                                                                    NumberAnimation { from: 2; to: -1; duration: 480 + index * 80; easing.type: Easing.InOutSine }
                                                                    NumberAnimation { from: -1; to: 2; duration: 480 + index * 80; easing.type: Easing.InOutSine }
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
                            MouseArea { anchors.fill: parent; onClicked: claudeBtn.popOpen = false; z: -1 }
                        }
                    }
                }

