// Notificacao propria em Quickshell, substitui o mako.
//
// TERCEIRA ESCRITA. As duas anteriores guardavam as pilulas num array JS e
// TROCAVAM O ARRAY INTEIRO a cada mudanca. Em QML isso destroi e recria todos
// os delegates a cada notificacao, e foi a causa unica de praticamente todos os
// defeitos que apareceram no uso real:
//   - "RangeError: Maximum call stack size exceeded" em rajada
//   - pilula que nao expirava (o timer de cada delegate reiniciava do zero
//     toda vez que outra notificacao chegava)
//   - pilula que simplesmente nao desenhava
//   - X e chevron mortos ao clicar
// Agora o estado mora num ListModel: append/remove por item, delegate nasce uma
// vez e vive ate a sua propria pilula sair. Ver plano:
// /home/lucas/AWA/wiki/references/rework-desktop-tema-d2-notificacoes-redesenho-2026-08-14.md
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Notifications
import QtQuick
import QtQuick.Layouts
import QtQml.Models

Scope {
    id: root
    property var theme: null

    readonly property int maxVisiveis: 5
    readonly property int defaultTimeout: 4000  // ms, usado quando o app manda -1

    // ===== estado das pilulas na tela =====
    // Um modelo por camada. Sao dois porque trocar WlrLayershell.layer de uma
    // janela viva recria a superficie e derruba o desenho no meio; com dois
    // modelos cada janela tem camada FIXA e nunca muda.
    ListModel { id: modeloNormais }
    ListModel { id: modeloCriticas }

    // objetos Notification vivos, por id. Fora do ListModel de proposito: o
    // ListModel guarda valores, nao QObject.
    property var objetos: ({})

    property var historyList: []
    readonly property int historyCap: 50
    property int naoLidas: 0
    property var pendentesPorApp: ({})

    // ===== monitor =====
    property var telaAlvo: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null
    // guarda contra reatribuir a MESMA tela: `screen` reatribuido recria a
    // superficie, e se isso cai junto com a chegada da pilula ela nao desenha
    property string telaNome: Quickshell.screens.length > 0 ? Quickshell.screens[0].name : ""
    function _fixarTela() {
        var alvo = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
        if (!alvo || alvo === root.telaNome) return;
        var scr = Quickshell.screens;
        for (var i = 0; i < scr.length; i++)
            if (scr[i].name === alvo) { root.telaAlvo = scr[i]; root.telaNome = scr[i].name; return; }
    }

    // ===== modo: normal | discreto | dnd =====
    property string modo: "normal"

    FileView {
        id: modoFile
        path: "/home/lucas/.local/state/notif-modo"
        onLoaded: {
            var m = (this.text() || "").trim();
            if (m === "normal" || m === "discreto" || m === "dnd") root.modo = m;
        }
    }
    Process {
        id: migraDnd
        command: ["sh", "-c",
            "if [ -f ~/.local/state/notif-dnd ]; then rm -f ~/.local/state/notif-dnd; echo dnd; fi"]
        stdout: StdioCollector {
            onStreamFinished: { if (this.text.trim() === "dnd") root.setModo("dnd"); }
        }
    }
    Component.onCompleted: { migraDnd.running = true; histFile.reload(); }

    function setModo(m) {
        root.modo = m;
        Quickshell.execDetached(["sh", "-c",
            "mkdir -p ~/.local/state && printf '%s' '" + m + "' > ~/.local/state/notif-modo"]);
    }
    function ciclarModo() {
        setModo(root.modo === "normal" ? "discreto" : (root.modo === "discreto" ? "dnd" : "normal"));
    }
    IpcHandler {
        target: "notif"
        function ciclarModo(): void { root.ciclarModo() }
        function setModo(m: string): void { root.setModo(m) }
        function toggleDnd(): void { root.ciclarModo() }
        function limparTudo(): void { root.limparTudo() }
        // fecha a primeira pilula: MESMO caminho de codigo do botao X, exposto
        // pra auditoria automatizada (nao ha clique sintetico neste sistema)
        function fecharPrimeira(): void {
            var m = modeloCriticas.count > 0 ? modeloCriticas : modeloNormais;
            if (m.count > 0) root.fechar(m.get(0).nid);
        }
        // mesmo caminho do clique no corpo da pilula
        function ativarPrimeira(): void {
            var m = modeloCriticas.count > 0 ? modeloCriticas : modeloNormais;
            if (m.count > 0) root.ativar(m.get(0).nid);
        }
        // expande a pilula do indice dado. Existe pra automacao e auditoria: nao
        // ha ferramenta de clique sintetico neste sistema.
        function expandir(i: int): void {
            var m = modeloCriticas.count > 0 ? modeloCriticas : modeloNormais;
            root.alternarExpandido(m, i);
        }
    }

    // ===== historico em disco =====
    FileView {
        id: histFile
        path: "/home/lucas/.local/state/notif-history.json"
        atomicWrites: true
        onLoaded: {
            try {
                var arr = JSON.parse(this.text() || "[]");
                if (Array.isArray(arr)) root.historyList = arr;
            } catch (e) { root.historyList = []; }
        }
    }
    Timer {
        id: histSalvar
        interval: 1000; repeat: false
        onTriggered: histFile.setText(JSON.stringify(root.historyList))
    }

    // ===== regras herdadas do core.ini do mako =====
    // sem omarchy-notification-dismiss: ele e `makoctl list | makoctl dismiss`
    // e esta morto desde que o mako parou. Quem dispensa e o proprio painel.
    readonly property var acoesEspeciais: [
        { match: "Setup Wi-Fi", cmd: ["omarchy-launch-wifi"] },
        { match: "Update System", cmd: ["omarchy-launch-floating-terminal-with-presentation", "omarchy-update"] },
        { match: "Learn Keybindings", cmd: ["omarchy-menu-keybindings"] },
        { match: "Install Dictation with Voxtype", cmd: ["omarchy-launch-floating-terminal-with-presentation", "omarchy-voxtype-install"] }
    ]
    function _acaoEspecial(summary) {
        for (var i = 0; i < acoesEspeciais.length; i++)
            if (String(summary || "").indexOf(acoesEspeciais[i].match) !== -1) return acoesEspeciais[i];
        return null;
    }

    // corpo do Discord vem com \n real: sem achatar, quebra linha mesmo com
    // elide e transborda a pilula
    function _umaLinha(t) {
        return String(t || "").replace(/[\r\n]+/g, " ").replace(/\s{2,}/g, " ").trim();
    }
    function _hora(ts) {
        var d = new Date(ts);
        return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2);
    }
    function _appIdDeCampos(desktopEntry, appName) {
        var de = String(desktopEntry || "").trim();
        if (de.length > 0) return de.replace(/\.desktop$/, "");
        return String(appName || "").toLowerCase().trim();
    }

    // ===== servidor =====
    NotificationServer {
        id: server
        bodySupported: true
        bodyMarkupSupported: false
        actionsSupported: true
        imageSupported: true
        persistenceSupported: false
        onNotification: function (notification) {
            notification.tracked = true;

            if (notification.appName === "Spotify") { notification.dismiss(); return; }

            var critica = notification.urgency === NotificationUrgency.Critical;
            var hints = notification.hints || {};
            // notify-send manda o icone no hint image-path; kitty manda no
            // parametro app_icon. Os dois caminhos precisam ser lidos.
            var icone = notification.appIcon || hints["image-path"] || hints["image_path"] || "";

            // acoes lidas UMA vez: notification.actions devolve uma lista nova a
            // cada leitura, ligar binding nela reavalia pra sempre
            var actsRaw = notification.actions || [];
            var temDefault = false;
            var rotulos = [];
            var ids = [];
            for (var ai = 0; ai < actsRaw.length; ai++) {
                if (actsRaw[ai].identifier === "default") { temDefault = true; continue; }
                rotulos.push(actsRaw[ai].text);
                ids.push(actsRaw[ai].identifier);
            }

            var id = notification.id;
            root.objetos[id] = notification;

            var timeout = critica ? 0
                          : (notification.expireTimeout > 0
                             ? Math.max(3000, Math.min(15000, notification.expireTimeout))
                             : root.defaultTimeout);

            var appId = root._appIdDeCampos(notification.desktopEntry, notification.appName);
            var temOrigem = temDefault || (root._acaoEspecial(notification.summary) !== null)
                            || (appId.length > 0 && appId !== "notify-send");

            var registro = {
                nid: String(id),
                appName: notification.appName || "",
                appIcon: icone,
                appId: appId,
                summary: notification.summary || "",
                body: notification.body || "",
                critica: critica,
                temOrigem: temOrigem,
                // ListModel nao guarda array: junta com  e separa na hora de usar
                acoesTxt: rotulos.join(""),
                acoesId: ids.join(""),
                ts: Date.now(),
                count: 1,
                timeout: timeout,
                // prazo ABSOLUTO: com prazo relativo por delegate, qualquer
                // remontagem reiniciava a contagem e a pilula nunca vencia
                expiraEm: timeout > 0 ? Date.now() + timeout : 0,
                expandido: false
            };

            root._addHistorico(registro);
            root.naoLidas = root.naoLidas + 1;
            root._addPendente(appId);

            var mostraPilula = (root.modo === "normal");
            var tocaSom = (root.modo !== "dnd") && !hints["suppress-sound"];
            // print de tela nao pede som: e acao que ele acabou de fazer
            if (String(notification.summary || "").toLowerCase().indexOf("screenshot") !== -1)
                tocaSom = false;
            // escape hatch do aviso-armazenamento, herdado do core.ini
            if (root.modo === "dnd" && notification.appName === "notify-send") {
                mostraPilula = true; tocaSom = true;
            }

            if (tocaSom)
                Quickshell.execDetached(["canberra-gtk-play", "-i",
                    critica ? "dialog-warning" : "message-new-instant"]);

            if (!mostraPilula) return;

            var modelo = critica ? modeloCriticas : modeloNormais;
            if (modeloNormais.count === 0 && modeloCriticas.count === 0) root._fixarTela();

            // agrupamento por app + assunto: em vez de outra pilula, incrementa
            // o contador e renova o prazo da que ja esta na tela
            for (var g = 0; g < modelo.count; g++) {
                var it = modelo.get(g);
                if (it.appName === registro.appName && it.summary === registro.summary) {
                    modelo.setProperty(g, "count", it.count + 1);
                    modelo.setProperty(g, "body", registro.body);
                    modelo.setProperty(g, "ts", registro.ts);
                    modelo.setProperty(g, "expiraEm", registro.expiraEm);
                    return;
                }
            }

            modelo.insert(0, registro);   // mais nova no topo

            // estouro derruba a MAIS VELHA, nunca a que acabou de chegar
            while (modelo.count > root.maxVisiveis) {
                var alvoId = modelo.get(modelo.count - 1).nid;
                modelo.remove(modelo.count - 1);
                root._soltarObjeto(alvoId, true);
            }
        }
    }

    // ===== ciclo de vida das pilulas =====
    // A UI e a autoridade sobre a propria lista: remove daqui primeiro e so
    // depois avisa o servidor. O objeto Notification pode ja ter sido destruido
    // (cliente saiu), e ai dismiss() estoura e a pilula ficava presa na tela.
    function _soltarObjeto(nid, expirar) {
        var obj = root.objetos[nid];
        delete root.objetos[nid];
        if (!obj) return;
        try {
            if (expirar && typeof obj.expire === "function") obj.expire();
            else if (typeof obj.dismiss === "function") obj.dismiss();
        } catch (e) { /* objeto morto: sair da lista ja bastou */ }
    }
    function _removerPorId(nid, expirar) {
        for (var m = 0; m < 2; m++) {
            var modelo = m === 0 ? modeloNormais : modeloCriticas;
            for (var i = 0; i < modelo.count; i++)
                if (modelo.get(i).nid === nid) { modelo.remove(i); break; }
        }
        root._soltarObjeto(nid, expirar === true);
    }
    function fechar(nid) { root._removerPorId(nid, false); }

    function alternarExpandido(modelo, i) {
        if (!modelo || i < 0 || i >= modelo.count) return;
        var it = modelo.get(i);
        var abrindo = !it.expandido;
        modelo.setProperty(i, "expandido", abrindo);
        // ao FECHAR, o prazo recomeca: sem isso a pilula voltava ja vencida e
        // sumia no mesmo instante
        if (!abrindo && it.timeout > 0)
            modelo.setProperty(i, "expiraEm", Date.now() + it.timeout);
    }

    // relogio unico, imune a remontagem de delegate
    Timer {
        interval: 500; running: true; repeat: true
        onTriggered: {
            var agora = Date.now();
            var vencidos = [];
            for (var m = 0; m < 2; m++) {
                var modelo = m === 0 ? modeloNormais : modeloCriticas;
                for (var i = modelo.count - 1; i >= 0; i--) {
                    var it = modelo.get(i);
                    if (it.expiraEm > 0 && !it.expandido && agora >= it.expiraEm) {
                        vencidos.push(it.nid);
                        modelo.remove(i);
                    }
                }
            }
            // avisa o servidor depois de a lista ja estar consistente
            for (var j = 0; j < vencidos.length; j++) root._soltarObjeto(vencidos[j], true);
        }
    }

    // ===== acoes =====
    function _registroDe(nid) {
        for (var m = 0; m < 2; m++) {
            var modelo = m === 0 ? modeloNormais : modeloCriticas;
            for (var i = 0; i < modelo.count; i++)
                if (modelo.get(i).nid === nid) return modelo.get(i);
        }
        return null;
    }
    function ativar(nid) {
        var reg = root._registroDe(nid);
        if (!reg) { root.fechar(nid); return; }
        var obj = root.objetos[nid];

        // 1) acao "default" do protocolo: e o que o kitty manda em toda
        // notificacao e o que o omarchy-capture-screenshot usa pro "clique
        // pra editar". Quem sabe a janela certa e o proprio app.
        if (obj) {
            try {
                var acts = obj.actions || [];
                for (var a = 0; a < acts.length; a++)
                    if (acts[a].identifier === "default") {
                        acts[a].invoke();
                        root.fechar(nid);
                        return;
                    }
            } catch (e) { }
        }
        // 2) regra especial herdada do core.ini
        var esp = root._acaoEspecial(reg.summary);
        if (esp) { Quickshell.execDetached(esp.cmd); root.fechar(nid); return; }
        // 3) fallback por appId. taskbar-activate.sh e nao focuswindow cru:
        // focar janela num special:min-<addr> REVELA o special inteiro
        // (ver window-minimize na nota de customizacoes)
        if (reg.appId && reg.appId !== "notify-send") {
            Quickshell.execDetached(
                ["/home/lucas/.config/quickshell/scripts/taskbar-activate.sh", reg.appId]);
            root.limparPendente(reg.appId);
        }
        root.fechar(nid);
    }
    function invocarAcao(nid, acaoId) {
        var obj = root.objetos[nid];
        if (obj) {
            try {
                var acts = obj.actions || [];
                for (var a = 0; a < acts.length; a++)
                    if (acts[a].identifier === acaoId) { acts[a].invoke(); break; }
            } catch (e) { }
        }
        root.fechar(nid);
    }

    function ativarHistorico(i) {
        var it = root.historyList[i];
        if (!it) return;
        var appId = root._appIdDeCampos(it.desktopEntry, it.appName);
        if (appId && appId !== "notify-send")
            Quickshell.execDetached(
                ["/home/lucas/.config/quickshell/scripts/taskbar-activate.sh", appId]);
    }
    function removerHistorico(i) {
        var h = root.historyList.slice();
        h.splice(i, 1);
        root.historyList = h;
        histSalvar.restart();
    }

    // ===== badge da taskbar =====
    function _addPendente(appId) {
        if (!appId) return;
        var p = Object.assign({}, root.pendentesPorApp);
        p[appId] = (p[appId] || 0) + 1;
        root.pendentesPorApp = p;
    }
    function limparPendente(appId) {
        if (!appId || !root.pendentesPorApp[appId]) return;
        var p = Object.assign({}, root.pendentesPorApp);
        delete p[appId];
        root.pendentesPorApp = p;
    }
    function marcarLidas() { root.naoLidas = 0; }

    function limparTudo() {
        var ids = [];
        for (var m = 0; m < 2; m++) {
            var modelo = m === 0 ? modeloNormais : modeloCriticas;
            for (var i = 0; i < modelo.count; i++) ids.push(modelo.get(i).nid);
            modelo.clear();
        }
        for (var j = 0; j < ids.length; j++) root._soltarObjeto(ids[j], false);
        root.historyList = [];
        root.naoLidas = 0;
        root.pendentesPorApp = ({});
        histSalvar.restart();
    }

    function _addHistorico(reg) {
        var h = root.historyList.slice();
        h.unshift({
            appName: reg.appName, appIcon: reg.appIcon, desktopEntry: reg.appId,
            summary: reg.summary, body: reg.body, urgency: reg.critica ? 2 : 1, ts: reg.ts
        });
        if (h.length > root.historyCap) h = h.slice(0, root.historyCap);
        root.historyList = h;
        histSalvar.restart();
    }
    function historico() { return root.historyList; }

    // ===== superficie =====
    component PilhaNotif: PanelWindow {
        id: notifWin
        // propriedade normal, nao `required`: dentro de componente inline o
        // required nao propaga a atualizacao do binding e a lista chegava vazia
        property var modelo: null
        property int camada: WlrLayer.Top
        property int quantas: 0
        property int deslocamentoTopo: 0

        screen: root.telaAlvo
        anchors { top: true; right: true }
        margins.top: notifWin.deslocamentoTopo
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: notifWin.camada
        WlrLayershell.namespace: "qsbar-notif"

        // 380 = 360 da pilula + 20 de folga a esquerda + 0 de margem direita.
        // Medido: com gaps_out 0 a janela do Hyprland encosta na borda da tela
        // (conteudo termina em 1278 e a borda de 2px vai ate 1280). Encostar a
        // pilula em 1278 ainda deixava a borda da janela sobrando 2px pra fora;
        // em 0 as duas terminam na mesma coluna.
        implicitWidth: 380
        // altura minima FIXA: encolher a janela pra 1px quando vazia muda a
        // geometria da superficie no mesmo instante em que o delegate esta
        // sendo montado, e a primeira pilula nao chegava a desenhar
        implicitHeight: Math.max(40, pilulasCol.implicitHeight + 40)

        // regiao por COORDENADA. `Region { item: X }` exige item com tamanho
        // explicito; apontar pro ColumnLayout devolvia regiao vazia e ai NADA
        // recebia clique, o X e o chevron ficavam mortos.
        // A mascara comeca onde as pilulas comecam. Cobrindo a janela inteira, a
        // faixa vazia de cima continuava capturando clique e engolia os botoes do
        // hyprbars que estao atras dela: descer a pilula com `topMargin` resolveu
        // so o visual, o clique seguia preso aqui.
        mask: Region {
            x: 0
            y: 36
            width: notifWin.width
            height: notifWin.quantas > 0 ? Math.max(0, notifWin.height - 36) : 0
        }

        ColumnLayout {
            id: pilulasCol
            anchors { top: parent.top; left: parent.left; right: parent.right }
            anchors.margins: 20
            // direita alinhada com a janela, nao com a folga do topo
            anchors.rightMargin: 0
            // COMECA ABAIXO DA BARRA DE TITULO. Medido: janela tiled tem o topo
            // do quadro em y=2 e o conteudo em y=30, ou seja a barra do hyprbars
            // ocupa 2..29. Com 20 a pilula caia em cima dela e tampava os botoes
            // de fechar/minimizar/maximizar/gaveta. 36 = 30 do conteudo + 6 de folga.
            anchors.topMargin: 36
            spacing: 8

            Repeater {
                model: notifWin.modelo
                delegate: ColumnLayout {
                    id: linha
                    // ANCORA A DIREITA. A pilula tem largura FIXA (360), e filho de
                    // ColumnLayout sem fillWidth e CENTRALIZADO por padrao: ela ficava
                    // centrada na coluna, sobrando ~10px de cada lado. Por isso mexer
                    // na margem direita quase nao movia a pilula, so a deslocava pela
                    // metade. Agora a direita dela bate com a borda da janela.
                    Layout.alignment: Qt.AlignRight
                    required property int index
                    required property string nid
                    required property string appName
                    required property string appIcon
                    required property string summary
                    required property string body
                    required property bool critica
                    required property bool temOrigem
                    required property string acoesTxt
                    required property string acoesId
                    required property double ts
                    required property int count
                    required property bool expandido
                    spacing: 4

                    // ---- pilula ----
                    Rectangle {
                        Layout.preferredWidth: 360
                        Layout.preferredHeight: 44
                        radius: height / 2
                        // fundo SOLIDO: Qt.alpha baixo vaza a janela de tras
                        color: root.theme ? root.theme.bgAlt : "#24283b"
                        border.width: 1
                        border.color: linha.critica
                                      ? (root.theme ? root.theme.danger : "#f7768e")
                                      : (root.theme ? Qt.alpha(root.theme.accent, 0.2) : "#3d59a1")

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10; anchors.rightMargin: 4
                            spacing: 8

                            // ---- alvo 1: corpo, vai pra origem ----
                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                RowLayout {
                                    anchors.fill: parent
                                    spacing: 8
                                    Image {
                                        id: appImg
                                        Layout.preferredWidth: 20; Layout.preferredHeight: 20
                                        Layout.alignment: Qt.AlignVCenter
                                        fillMode: Image.PreserveAspectFit
                                        visible: status === Image.Ready
                                        source: {
                                            var ic = linha.appIcon;
                                            if (!ic) return "";
                                            if (ic.indexOf("/") === 0 || ic.indexOf("file://") === 0) return ic;
                                            return Quickshell.iconPath(ic);
                                        }
                                    }
                                    Text {
                                        visible: appImg.status !== Image.Ready
                                        Layout.preferredWidth: 20
                                        Layout.alignment: Qt.AlignVCenter
                                        horizontalAlignment: Text.AlignHCenter
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 15
                                        color: root.theme ? root.theme.accent : "#7d82d9"
                                        text: "󰂚"
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                        wrapMode: Text.NoWrap
                                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 12
                                        color: root.theme ? root.theme.fg : "#c0caf5"
                                        text: root._umaLinha(linha.summary)
                                              + (linha.body ? "  ·  " + root._umaLinha(linha.body) : "")
                                    }
                                    Rectangle {
                                        visible: linha.count > 1
                                        Layout.alignment: Qt.AlignVCenter
                                        implicitWidth: cnt.implicitWidth + 10; implicitHeight: 16
                                        radius: 8
                                        color: root.theme ? Qt.alpha(root.theme.accent, 0.2) : "#3d59a1"
                                        Text {
                                            id: cnt
                                            anchors.centerIn: parent
                                            text: linha.count + "x"
                                            font.pixelSize: 10
                                            color: root.theme ? root.theme.accent : "#7d82d9"
                                        }
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                    cursorShape: linha.temOrigem ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: function (e) {
                                        if (e.button === Qt.MiddleButton) { root.fechar(linha.nid); return; }
                                        if (linha.temOrigem) root.ativar(linha.nid);
                                        else root.fechar(linha.nid);
                                    }
                                }
                            }

                            // ---- alvo 2: chevron, abre o dropdown ----
                            Rectangle {
                                Layout.preferredWidth: 28; Layout.preferredHeight: 44
                                color: chevMa.containsMouse ? (root.theme ? root.theme.surface2 : "#2a2f45") : "transparent"
                                radius: 14
                                Text {
                                    anchors.centerIn: parent
                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13
                                    color: root.theme ? root.theme.fgDim : "#6a7090"
                                    text: linha.expandido ? "󰅃" : "󰅀"
                                }
                                MouseArea {
                                    id: chevMa
                                    anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.alternarExpandido(notifWin.modelo, linha.index)
                                }
                            }

                            // ---- alvo 3: X, dispensa sem ativar nada ----
                            Rectangle {
                                Layout.preferredWidth: 28; Layout.preferredHeight: 44
                                color: xMa.containsMouse ? (root.theme ? root.theme.surface2 : "#2a2f45") : "transparent"
                                radius: 14
                                Text {
                                    anchors.centerIn: parent
                                    font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13
                                    color: root.theme ? root.theme.fgDim : "#6a7090"
                                    text: "󰅖"
                                }
                                MouseArea {
                                    id: xMa
                                    anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.fechar(linha.nid)
                                }
                            }
                        }
                    }

                    // ---- dropdown: mensagem inteira ----
                    // Column simples com largura EXPLICITA. Um ColumnLayout
                    // ancorado dentro de um Rectangle cuja altura vem do
                    // implicitHeight desse mesmo layout fecha laco de binding.
                    Rectangle {
                        visible: linha.expandido
                        Layout.preferredWidth: 360
                        Layout.preferredHeight: visible ? dropCol.height + 20 : 0
                        radius: 12
                        color: root.theme ? root.theme.bgAlt : "#24283b"
                        border.width: 1
                        border.color: root.theme ? Qt.alpha(root.theme.accent, 0.2) : "#3d59a1"

                        Column {
                            id: dropCol
                            x: 10; y: 10
                            width: 340
                            spacing: 4

                            Item {
                                width: parent.width
                                height: Math.max(cabApp.implicitHeight, cabHora.implicitHeight)
                                Text {
                                    id: cabApp
                                    anchors.left: parent.left
                                    anchors.right: cabHora.left; anchors.rightMargin: 6
                                    text: linha.appName
                                    font.pixelSize: 10
                                    color: root.theme ? root.theme.accent : "#7d82d9"
                                    elide: Text.ElideRight
                                }
                                Text {
                                    id: cabHora
                                    anchors.right: parent.right
                                    text: root._hora(linha.ts)
                                    font.pixelSize: 10
                                    color: root.theme ? root.theme.fgDim : "#6a7090"
                                }
                            }
                            Text {
                                width: parent.width
                                text: linha.summary
                                font.pixelSize: 12; font.bold: true
                                color: root.theme ? root.theme.fgBright : "#c0caf5"
                                wrapMode: Text.WordWrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                visible: !!linha.body
                                // aqui NAO achata: quebra de linha real e o que
                                // se quer ver dentro do dropdown
                                text: linha.body
                                font.pixelSize: 11
                                color: root.theme ? root.theme.fg : "#c0caf5"
                                wrapMode: Text.WordWrap
                                maximumLineCount: 6
                                elide: Text.ElideRight
                            }
                            Row {
                                spacing: 6
                                visible: linha.acoesTxt.length > 0
                                Repeater {
                                    // string juntada, nao array: ListModel nao
                                    // guarda array, e ligar o model direto em
                                    // obj.actions reavalia pra sempre
                                    model: linha.acoesTxt.length > 0 ? linha.acoesTxt.split("") : []
                                    delegate: Rectangle {
                                        required property string modelData
                                        required property int index
                                        width: actTxt.implicitWidth + 20
                                        height: 28
                                        radius: 14
                                        color: actMa2.containsMouse
                                               ? (root.theme ? root.theme.surface2 : "#2a2f45")
                                               : (root.theme ? root.theme.surface : "#32344a")
                                        Text {
                                            id: actTxt
                                            anchors.centerIn: parent
                                            text: modelData
                                            font.pixelSize: 11
                                            color: root.theme ? root.theme.fg : "#c0caf5"
                                        }
                                        MouseArea {
                                            id: actMa2
                                            anchors.fill: parent; hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                var ids = linha.acoesId.split("");
                                                root.invocarAcao(linha.nid, ids[index]);
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

    // criticas no Overlay (acima ate de tela cheia), normais no Top e
    // empurradas pra baixo delas. Camada FIXA em cada janela.
    PilhaNotif {
        modelo: modeloCriticas
        camada: WlrLayer.Overlay
        quantas: modeloCriticas.count
    }
    PilhaNotif {
        modelo: modeloNormais
        camada: WlrLayer.Top
        quantas: modeloNormais.count
        // calculado so pela contagem: uma janela observar o implicitHeight da
        // outra fecha laco entre superficies e as duas param de desenhar
        deslocamentoTopo: modeloCriticas.count > 0 ? (modeloCriticas.count * 52) : 0
    }
}
