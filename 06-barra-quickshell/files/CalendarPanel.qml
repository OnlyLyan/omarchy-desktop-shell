// Calendario com feriados e agenda, aberto pelo clique no relogio da barra.
//
// Decisoes dele, 2026-08-14:
//   - abre clicando no relogio, estilo Windows 11
//   - feriados nacionais + estaduais do Tocantins + municipais de Palmas
//   - eventos guardados localmente, sem conta e sem sincronizacao
//   - alarme programavel por evento, ele escolhe quando quer ser avisado
//
// Toda a persistencia mora em scripts/agenda.sh. Aqui so entra tela e horario:
// se um dia ele quiser trocar o armazenamento, nada deste arquivo muda.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts

Scope {
    id: root

    property var theme: null
    property var tela: null
    property bool aberto: false

    readonly property string lar: Quickshell.env("HOME")
    readonly property string script: lar + "/.config/quickshell/scripts/agenda.sh"

    // mes exibido, separado do dia selecionado: navegar de mes nao pode perder
    // a selecao, senao a lista de baixo pisca a cada clique na seta
    property int anoRef: new Date().getFullYear()
    property int mesRef: new Date().getMonth()
    property string diaSel: _iso(new Date())

    property var feriados: ({})     // "AAAA-MM-DD" -> {nome, tipo}
    property var eventos: []
    property int anoCarregado: -1

    // formulario de evento novo
    property bool formAberto: false
    property string fTitulo: ""
    property string fHora: ""
    property var fAvisos: [0]       // minutos ANTES; 0 = na hora
    property string fErro: ""       // mensagem embaixo do formulario

    // ---------------------------------------------------------------- util
    function _2(n) { return n < 10 ? "0" + n : "" + n; }
    function _iso(d) { return d.getFullYear() + "-" + _2(d.getMonth() + 1) + "-" + _2(d.getDate()); }
    function _isoDe(a, m, d) { return a + "-" + _2(m + 1) + "-" + _2(d); }

    readonly property var nomesMes: ["janeiro","fevereiro","março","abril","maio","junho",
                                     "julho","agosto","setembro","outubro","novembro","dezembro"]
    readonly property var nomesDia: ["domingo","segunda","terça","quarta","quinta","sexta","sábado"]

    function abrir(screen) {
        root.tela = screen;
        var h = new Date();
        root.anoRef = h.getFullYear();
        root.mesRef = h.getMonth();
        root.diaSel = _iso(h);
        root.formAberto = false;
        root.aberto = true;
        recarregar();
    }
    function fechar() { root.aberto = false; root.formAberto = false; }

    function recarregar() {
        listarProc.running = true;
        if (root.anoCarregado !== root.anoRef) carregarFeriados(root.anoRef);
    }
    function carregarFeriados(ano) {
        feriadosProc.command = [root.script, "feriados", "" + ano];
        feriadosProc.running = true;
    }

    // navegacao de mes. Feriado e por ano, entao virar dezembro->janeiro
    // precisa buscar o ano novo, senao o mes seguinte aparece sem feriado nenhum.
    function mudarMes(delta) {
        var m = root.mesRef + delta, a = root.anoRef;
        if (m < 0) { m = 11; a--; }
        else if (m > 11) { m = 0; a++; }
        root.mesRef = m; root.anoRef = a;
        if (root.anoCarregado !== a) carregarFeriados(a);
    }

    // 42 celulas nunca: so o necessario. Celula com dia 0 e o vazio antes do
    // primeiro dia da semana do mes.
    function celulas() {
        var pri = new Date(root.anoRef, root.mesRef, 1);
        var vazias = pri.getDay();
        var total = new Date(root.anoRef, root.mesRef + 1, 0).getDate();
        var out = [];
        for (var v = 0; v < vazias; v++) out.push({ dia: 0, data: "" });
        for (var d = 1; d <= total; d++) out.push({ dia: d, data: _isoDe(root.anoRef, root.mesRef, d) });
        return out;
    }

    function eventosDe(data) {
        var out = [];
        for (var i = 0; i < root.eventos.length; i++)
            if (root.eventos[i].data === data) out.push(root.eventos[i]);
        return out;
    }
    function temEvento(data) { return eventosDe(data).length > 0; }
    function feriadoDe(data) { return root.feriados[data] || null; }

    function tituloDia(data) {
        var p = data.split("-");
        var d = new Date(parseInt(p[0]), parseInt(p[1]) - 1, parseInt(p[2]));
        return nomesDia[d.getDay()] + ", " + d.getDate() + " de " + nomesMes[d.getMonth()];
    }

    // ---------------------------------------------------------------- dados
    Process {
        id: feriadosProc
        stdout: StdioCollector {
            onStreamFinished: {
                var mapa = {};
                try {
                    var arr = JSON.parse(this.text.trim()) || [];
                    for (var i = 0; i < arr.length; i++)
                        mapa[arr[i].data] = { nome: arr[i].nome, tipo: arr[i].tipo };
                } catch (e) { }
                root.feriados = mapa;
                root.anoCarregado = root.anoRef;
            }
        }
    }
    Process {
        id: listarProc
        command: [root.script, "listar"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.eventos = JSON.parse(this.text.trim()) || []; }
                catch (e) { root.eventos = []; }
            }
        }
    }
    // add/del/avisado devolvem a agenda inteira ja atualizada, entao a lista se
    // reconstroi da resposta e nao precisa de um segundo `listar` depois
    Process {
        id: escritaProc
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.eventos = JSON.parse(this.text.trim()) || []; }
                catch (e) { }
            }
        }
    }
    // Toda recusa aqui PRECISA dizer o porque. A primeira versao so fazia
    // `return` calado: ele marcou um evento as 18:19 quando ja eram 19:18, o
    // alarme (corretamente) nao tocou por estar vencido, e a tela nao deu pista
    // nenhuma do motivo. Falhar em silencio e pior que nao ter o recurso.
    function salvarEvento() {
        var t = root.fTitulo.trim();
        var h = root.fHora.trim();
        root.fErro = "";
        if (t === "") { root.fErro = "falta o nome do evento"; return; }
        if (!/^\d{1,2}:\d{2}$/.test(h)) { root.fErro = "hora incompleta, use 19:30"; return; }
        var p = h.split(":");
        var hh = parseInt(p[0]), mm = parseInt(p[1]);
        if (hh > 23 || mm > 59) { root.fErro = "hora inválida"; return; }
        var dp = root.diaSel.split("-");
        var quando = new Date(parseInt(dp[0]), parseInt(dp[1]) - 1, parseInt(dp[2]), hh, mm);
        if (quando.getTime() < new Date().getTime() - 60000) {
            root.fErro = "esse horário já passou, o alarme não tocaria";
            return;
        }
        h = _2(hh) + ":" + _2(mm);
        escritaProc.command = [root.script, "add", root.diaSel, h, t, root.fAvisos.join(",")];
        escritaProc.running = true;
        root.fTitulo = ""; root.fHora = ""; root.fAvisos = [0]; root.fErro = "";
        root.formAberto = false;
    }
    function horaSugerida() {
        var d = new Date(new Date().getTime() + 5 * 60000);
        // dia futuro nao tem "agora": comeca as 09:00, que e o palpite util
        if (root.diaSel !== _iso(new Date())) return "09:00";
        return _2(d.getHours()) + ":" + _2(d.getMinutes());
    }
    function apagarEvento(id) {
        escritaProc.command = [root.script, "del", id];
        escritaProc.running = true;
    }
    function alternarAviso(min) {
        var a = root.fAvisos.slice();
        var i = a.indexOf(min);
        if (i >= 0) a.splice(i, 1); else a.push(min);
        if (a.length === 0) a = [0];                     // sempre pelo menos um
        root.fAvisos = a;
    }

    // ---------------------------------------------------------------- alarme
    // Roda SEMPRE, com o painel fechado inclusive: este Scope e instanciado no
    // shell.qml de forma permanente e so a janela e que aparece e some.
    //
    // Janela de 10 minutos de proposito. Sem ela, um evento antigo dispararia
    // todos os avisos atrasados de uma vez na primeira varredura depois de ligar
    // o PC. Passou da janela, o aviso simplesmente nao acontece.
    Timer {
        interval: 30000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.varrerAlarmes()
    }
    // 60s, e nao 5min: evento criado por fora (script, editor de texto, outra
    // instancia) so entra na varredura depois de recarregar, e com 5 minutos um
    // alarme marcado pra daqui a pouco simplesmente nao tocava. Descoberto no
    // teste: o primeiro disparo falhou exatamente por isso.
    Timer {
        interval: 60000; running: true; repeat: true
        onTriggered: listarProc.running = true
    }
    Component.onCompleted: { listarProc.running = true; carregarFeriados(root.anoRef); }

    function varrerAlarmes() {
        var agora = new Date().getTime();
        for (var i = 0; i < root.eventos.length; i++) {
            var e = root.eventos[i];
            if (!e.data || !e.hora) continue;
            var dp = e.data.split("-"), hp = e.hora.split(":");
            var quando = new Date(parseInt(dp[0]), parseInt(dp[1]) - 1, parseInt(dp[2]),
                                  parseInt(hp[0]), parseInt(hp[1])).getTime();
            var avisos = e.avisos || [0];
            var feitos = e.avisados || [];
            for (var j = 0; j < avisos.length; j++) {
                var m = avisos[j];
                if (feitos.indexOf(m) >= 0) continue;
                var alvo = quando - m * 60000;
                if (agora < alvo) continue;
                if (agora - alvo > 600000) continue;     // atrasado demais, deixa passar
                dispararAlarme(e, m);
            }
        }
    }
    function dispararAlarme(e, min) {
        var corpo = min === 0 ? "agora, " + e.hora
                  : (min < 60 ? "em " + min + " minutos, às " + e.hora
                              : "em " + (min / 60) + "h, às " + e.hora);
        Quickshell.execDetached(["notify-send", "-a", "Agenda", "-u", "normal",
                                 "-i", "/usr/share/icons/Yaru/48x48/status/appointment-soon.png",
                                 e.titulo, corpo]);
        escritaProc.command = [root.script, "avisado", e.id, "" + min];
        escritaProc.running = true;
    }

    // IPC: mesmo padrao dos outros paineis. Serve pra abrir sem mouse e,
    // principalmente, pra conseguir testar o painel de fora.
    IpcHandler {
        target: "calendario"
        function abrir(): void { root.abrir(Quickshell.screens[0]); }
        function fechar(): void { root.fechar(); }
        function alternar(): void {
            if (root.aberto) root.fechar(); else root.abrir(Quickshell.screens[0]);
        }
        // forca a varredura de alarme na hora, sem esperar os 30s do timer
        function checarAlarmes(): void { root.varrerAlarmes(); }
    }

    // ---------------------------------------------------------------- tela
    PanelWindow {
        id: janela
        visible: root.aberto
        screen: root.tela ? root.tela : Quickshell.screens[0]
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qsbar-calendario"
        // Exclusive so quando o formulario esta aberto: fora disso roubar o
        // teclado impediria ele de usar qualquer atalho com o painel na tela.
        WlrLayershell.keyboardFocus: root.formAberto ? WlrKeyboardFocus.Exclusive
                                                     : WlrKeyboardFocus.None

        // clique fora fecha
        MouseArea { anchors.fill: parent; onClicked: root.fechar() }

        Rectangle {
            id: cartao
            // canto inferior direito, logo acima da barra, que e onde o relogio
            // fica. Nao e centralizado de proposito: o painel tem que nascer
            // perto do que foi clicado.
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 8
            anchors.bottomMargin: 48
            width: 330
            implicitHeight: col.implicitHeight + 24
            radius: 12
            color: root.theme ? root.theme.bg : "#12141f"
            border.color: root.theme ? Qt.alpha(root.theme.accent, 0.25) : "#33395c"
            border.width: 1

            // engole o clique pra nao fechar ao clicar dentro
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: col
                anchors { left: parent.left; right: parent.right; top: parent.top }
                anchors.margins: 12
                spacing: 6

                // ---- cabecalho do mes ----
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "‹"
                        color: root.theme ? root.theme.fg : "#e6e8f0"
                        font.pixelSize: 20
                        MouseArea { anchors.fill: parent; anchors.margins: -6
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.mudarMes(-1) }
                    }
                    Text {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: root.nomesMes[root.mesRef] + " de " + root.anoRef
                        color: root.theme ? root.theme.fg : "#e6e8f0"
                        font.pixelSize: 13
                        font.bold: true
                    }
                    Text {
                        text: "›"
                        color: root.theme ? root.theme.fg : "#e6e8f0"
                        font.pixelSize: 20
                        MouseArea { anchors.fill: parent; anchors.margins: -6
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.mudarMes(1) }
                    }
                }

                // ---- cabecalho dos dias da semana ----
                Row {
                    Layout.alignment: Qt.AlignHCenter
                    Repeater {
                        model: ["dom","seg","ter","qua","qui","sex","sáb"]
                        delegate: Item {
                            required property string modelData
                            width: 42; height: 18
                            Text {
                                anchors.centerIn: parent
                                text: modelData
                                color: root.theme ? root.theme.fgDim : "#7a80a0"
                                font.pixelSize: 10
                            }
                        }
                    }
                }

                // ---- grade ----
                // Grid com celula de tamanho fixo, nao GridLayout: com tamanho
                // fixo nao ha negociacao de largura e portanto nao ha risco de
                // laco de binding, que ja custou caro neste shell.
                Grid {
                    Layout.alignment: Qt.AlignHCenter
                    columns: 7
                    Repeater {
                        model: root.celulas()
                        delegate: Item {
                            required property var modelData
                            width: 42; height: 34
                            visible: true

                            readonly property bool vazio: modelData.dia === 0
                            readonly property bool hoje: modelData.data === root._iso(new Date())
                            readonly property bool sel: modelData.data === root.diaSel
                            readonly property var fer: vazio ? null : root.feriadoDe(modelData.data)

                            Rectangle {
                                anchors.centerIn: parent
                                width: 32; height: 30
                                radius: 8
                                visible: !parent.vazio
                                color: parent.sel ? Qt.alpha(root.theme ? root.theme.accent : "#7d82d9", 0.30)
                                     : (celHov.hovered ? Qt.alpha(root.theme ? root.theme.accent : "#7d82d9", 0.14)
                                                       : "transparent")
                                border.width: parent.hoje ? 1 : 0
                                border.color: root.theme ? root.theme.accent : "#7d82d9"
                                HoverHandler { id: celHov }
                            }
                            Text {
                                anchors.centerIn: parent
                                visible: !parent.vazio
                                text: modelData.dia
                                font.pixelSize: 12
                                font.bold: parent.hoje
                                // feriado ganha cor propria: e a unica forma de
                                // ele bater o olho na grade e ver que tem folga
                                color: parent.fer ? (root.theme ? root.theme.danger : "#e05c5c")
                                                  : (root.theme ? root.theme.fg : "#e6e8f0")
                            }
                            // ponto de evento, embaixo do numero
                            Rectangle {
                                visible: !parent.vazio && root.temEvento(modelData.data)
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 3
                                width: 4; height: 4; radius: 2
                                color: root.theme ? root.theme.accent : "#7d82d9"
                            }
                            MouseArea {
                                anchors.fill: parent
                                enabled: !parent.vazio
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { root.diaSel = modelData.data; root.formAberto = false; }
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    implicitHeight: 1
                    color: root.theme ? Qt.alpha(root.theme.fgDim, 0.25) : "#33395c"
                }

                // ---- dia selecionado ----
                Text {
                    text: root.tituloDia(root.diaSel)
                    color: root.theme ? root.theme.fg : "#e6e8f0"
                    font.pixelSize: 12
                    font.bold: true
                }
                Text {
                    visible: root.feriadoDe(root.diaSel) !== null
                    text: {
                        var f = root.feriadoDe(root.diaSel);
                        return f ? f.nome + "  ·  " + f.tipo : "";
                    }
                    color: root.theme ? root.theme.danger : "#e05c5c"
                    font.pixelSize: 11
                }

                Text {
                    visible: root.eventosDe(root.diaSel).length === 0 && !root.formAberto
                    text: "nenhum compromisso"
                    color: root.theme ? root.theme.fgDim : "#7a80a0"
                    font.pixelSize: 11
                }

                Repeater {
                    model: root.eventosDe(root.diaSel)
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 8
                        // passado fica apagado: sem isso, um evento vencido
                        // parece igualzinho a um que ainda vai tocar
                        readonly property bool passou: {
                            var dp = modelData.data.split("-"), hp = modelData.hora.split(":");
                            return new Date(parseInt(dp[0]), parseInt(dp[1]) - 1, parseInt(dp[2]),
                                            parseInt(hp[0]), parseInt(hp[1])).getTime() < new Date().getTime();
                        }
                        Text {
                            text: modelData.hora
                            color: parent.passou ? (root.theme ? root.theme.fgDim : "#7a80a0")
                                                 : (root.theme ? root.theme.accent : "#7d82d9")
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 11
                        }
                        Text {
                            Layout.fillWidth: true
                            text: modelData.titulo
                            color: parent.passou ? (root.theme ? root.theme.fgDim : "#7a80a0")
                                                 : (root.theme ? root.theme.fg : "#e6e8f0")
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                        Text {
                            text: "󰅖"
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 11
                            color: xHov.hovered ? (root.theme ? root.theme.danger : "#e05c5c")
                                                : (root.theme ? root.theme.fgDim : "#7a80a0")
                            HoverHandler { id: xHov }
                            MouseArea { anchors.fill: parent; anchors.margins: -4
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.apagarEvento(modelData.id) }
                        }
                    }
                }

                // ---- botao novo ----
                Rectangle {
                    visible: !root.formAberto
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    implicitHeight: 28
                    radius: 8
                    color: novoHov.hovered ? Qt.alpha(root.theme ? root.theme.accent : "#7d82d9", 0.22)
                                           : (root.theme ? root.theme.surface2 : "#232739")
                    HoverHandler { id: novoHov }
                    Text {
                        anchors.centerIn: parent
                        text: "+ Novo evento"
                        color: root.theme ? root.theme.fg : "#e6e8f0"
                        font.pixelSize: 11
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.formAberto = true; root.fTitulo = "";
                            root.fAvisos = [0]; root.fErro = "";
                            // ja vem preenchido com agora + 5 min: digitar hora
                            // do zero foi exatamente onde ele errou e marcou um
                            // horario no passado sem perceber
                            root.fHora = root.horaSugerida();
                            campoHora.text = root.fHora;
                        }
                    }
                }

                // ---- formulario ----
                ColumnLayout {
                    visible: root.formAberto
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    spacing: 6

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 28
                        radius: 6
                        color: root.theme ? root.theme.surface2 : "#232739"
                        TextInput {
                            id: campoTitulo
                            anchors.fill: parent
                            anchors.leftMargin: 8; anchors.rightMargin: 8
                            verticalAlignment: TextInput.AlignVCenter
                            color: root.theme ? root.theme.fg : "#e6e8f0"
                            font.pixelSize: 12
                            clip: true
                            focus: root.formAberto
                            onVisibleChanged: if (visible) forceActiveFocus()
                            onTextChanged: root.fTitulo = text
                            onAccepted: campoHora.forceActiveFocus()
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: campoTitulo.text === ""
                                text: "o que é"
                                color: root.theme ? root.theme.fgDim : "#7a80a0"
                                font.pixelSize: 12
                            }
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 28
                        radius: 6
                        color: root.theme ? root.theme.surface2 : "#232739"
                        TextInput {
                            id: campoHora
                            anchors.fill: parent
                            anchors.leftMargin: 8; anchors.rightMargin: 8
                            verticalAlignment: TextInput.AlignVCenter
                            color: root.theme ? root.theme.fg : "#e6e8f0"
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 12
                            clip: true
                            inputMask: "99:99"
                            onTextChanged: root.fHora = text
                            onAccepted: root.salvarEvento()
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: campoHora.text === "  :  " || campoHora.text === ""
                                text: "hora, ex 19:30"
                                color: root.theme ? root.theme.fgDim : "#7a80a0"
                                font.pixelSize: 12
                            }
                        }
                    }

                    Text {
                        text: "avisar"
                        color: root.theme ? root.theme.fgDim : "#7a80a0"
                        font.pixelSize: 10
                        font.bold: true
                    }
                    // combinaveis de proposito: ele pediu alarme programavel, e
                    // "1h antes E na hora" e o caso comum de quem quase perde algo
                    Row {
                        Layout.fillWidth: true
                        spacing: 5
                        Repeater {
                            model: [ { m: 0, r: "na hora" }, { m: 10, r: "10 min" },
                                     { m: 60, r: "1 h" },    { m: 1440, r: "1 dia" } ]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool ativo: root.fAvisos.indexOf(modelData.m) >= 0
                                width: chipTxt.implicitWidth + 16
                                height: 22
                                radius: 11
                                color: ativo ? Qt.alpha(root.theme ? root.theme.accent : "#7d82d9", 0.35)
                                             : (root.theme ? root.theme.surface2 : "#232739")
                                Text {
                                    id: chipTxt
                                    anchors.centerIn: parent
                                    text: modelData.r
                                    color: root.theme ? root.theme.fg : "#e6e8f0"
                                    font.pixelSize: 10
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.alternarAviso(modelData.m)
                                }
                            }
                        }
                    }

                    Text {
                        visible: root.fErro !== ""
                        Layout.fillWidth: true
                        text: root.fErro
                        color: root.theme ? root.theme.danger : "#e05c5c"
                        font.pixelSize: 10
                        wrapMode: Text.WordWrap
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 26; radius: 6
                            color: root.theme ? root.theme.surface2 : "#232739"
                            Text { anchors.centerIn: parent; text: "cancelar"
                                   color: root.theme ? root.theme.fgDim : "#7a80a0"; font.pixelSize: 11 }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: root.formAberto = false }
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 26; radius: 6
                            color: root.theme ? root.theme.accent : "#7d82d9"
                            Text { anchors.centerIn: parent; text: "salvar"
                                   color: root.theme ? root.theme.bg : "#12141f"
                                   font.pixelSize: 11; font.bold: true }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: root.salvarEvento() }
                        }
                    }
                }
            }
        }
    }
}
