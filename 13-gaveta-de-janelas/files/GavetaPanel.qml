// Gaveta de janelas, v2. Reescrita do zero.
//
// A v1 sondava `hyprctl activewindow` + `cursorpos` a cada 200ms pra ADIVINHAR
// arraste, e hibernava processo com SIGSTOP (o que quebrou uma sessao viva do
// Claude Code). Nada disso sobreviveu:
//   - o gatilho agora e bind de mouse do Hyprland (SUPER+CTRL+esquerdo na barra
//     de titulo), evento real do compositor, custo zero em repouso
//   - guardar e so mover pra workspace especial, sem tocar em processo
//
// A janela guardada SOME da taskbar, entao esta gaveta e o unico caminho de
// volta ate ela. Por isso a lista vem sempre do Hyprland (`Hyprland.toplevels`),
// nunca de arquivo: janela morta nao aparece, logo nao vira slot fantasma.
//
// Plano: wiki/references/rework-desktop-gaveta-de-janelas-v2-2026-08-14.md
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Layouts
import QtQml.Models

Scope {
    id: root
    // HOME em vez de caminho absoluto: caminho com usuario fixo quebra pra
    // qualquer outra pessoa, e o repo deste shell e publico.
    readonly property string lar: Quickshell.env("HOME")

    property var theme: null

    // "fechada" | "guardar" | "tirar"
    property string modo: "fechada"
    // lista compacta: so o cabecalho de cada janela (icone + titulo), sem
    // miniatura. Com a gaveta cheia, ver tudo de uma vez vale mais que ver
    // bonito. Alterna pelo chevron ao lado do divisor.
    property bool compacto: false
    readonly property int count: modelo.count

    // ListModel, nunca troca de array: reatribuir o array recria TODOS os
    // delegates, e numa lista de ScreencopyView isso derruba e recria a captura
    // ao vivo de cada miniatura a cada mudanca (pisca feio)
    ListModel { id: modelo }
    // exposto pro icone da gaveta na barra montar a lista do hover
    property alias itens: modelo

    // endereco que o gesto agarrou e ainda nao foi solto num slot
    property string pendente: ""
    readonly property string pendenteTitulo: {
        if (!pendente.length) return "";
        var l = Hyprland.toplevels.values;
        for (var i = 0; i < l.length; i++)
            if (root._ende(l[i].address) === root._ende(pendente)) return l[i].title || "";
        return "";
    }

    // ===== leitura do estado real =====
    // Fonte da verdade: `Hyprland.toplevels`. HyprlandToplevel liga `address`
    // (o que o script move) a `wayland` (o toplevel que a taskbar e o Alt+Tab
    // enxergam), entao da pra casar janela por IDENTIDADE. A tentativa anterior
    // casava por (classe, titulo) e tinha dois furos graves:
    //   - duas janelas do mesmo app com o mesmo titulo: guardar uma sumia com as
    //     duas da taskbar, e a viva ficava sem botao e sem entrada na gaveta
    //   - titulo que muda sozinho (kitty com Claude Code faz isso o tempo todo)
    //     fazia a janela guardada reaparecer na taskbar segundos depois
    // De quebra some a sondagem: isto e reativo, o Hyprland avisa.
    // ARMADILHA: `HyprlandToplevel.address` vem SEM o prefixo "0x"
    // ("55d14e9508b0"), enquanto `hyprctl clients -j` e o script usam com
    // ("0x55d14e9508b0"). E o Hyprland ignora EM SILENCIO um
    // `address:` sem prefixo, sem erro nenhum. Misturar os dois formatos deixou
    // a gaveta com porta de mao unica: guardava e nao devolvia. Tudo que
    // atravessa a fronteira QML <-> script passa por aqui.
    function _ende(a) {
        var s = String(a || "");
        if (!s.length) return "";
        return s.indexOf("0x") === 0 ? s : "0x" + s;
    }

    readonly property var guardadas: {
        var r = [];
        var l = Hyprland.toplevels.values;
        for (var i = 0; i < l.length; i++) {
            var w = l[i].workspace;
            if (w && String(w.name).indexOf("special:gav") === 0) r.push(l[i]);
        }
        return r;
    }
    // toplevels Wayland a esconder da taskbar e do Alt+Tab (comparacao por
    // identidade de objeto, nunca por texto)
    readonly property var escondidos: {
        var r = [];
        for (var i = 0; i < guardadas.length; i++)
            if (guardadas[i].wayland) r.push(guardadas[i].wayland);
        return r;
    }

    // enderecos que NOS estamos tirando agora. Sem isso, tirar da gaveta dispara
    // o aviso de "janela fechou sozinha", porque some da lista do mesmo jeito.
    property var saindo: ({})

    // reconcilia o ListModel com `guardadas`, item a item. O ListModel existe pra
    // NAO recriar delegate: cada delegate tem um ScreencopyView, e recriar
    // derruba e reabre a captura ao vivo (pisca feio).
    onGuardadasChanged: _reconciliar()
    function recarregar() { _reconciliar() }
    function _reconciliar() {
        var vivos = {};   // endereco que o Hyprland ainda conhece
        var todos = Hyprland.toplevels.values;
        for (var t = 0; t < todos.length; t++) vivos[root._ende(todos[t].address)] = true;

        var atual = {};   // endereco -> HyprlandToplevel guardado agora
        for (var g = 0; g < guardadas.length; g++) atual[root._ende(guardadas[g].address)] = guardadas[g];

        // saiu da gaveta: por acao nossa, por restauracao externa, ou por morte
        for (var i = modelo.count - 1; i >= 0; i--) {
            var perdida = modelo.get(i);
            if (atual[perdida.addr]) continue;
            // TUDO copiado ANTES do remove: `ListModel.get()` devolve uma
            // referencia que INVALIDA no remove, e ler `perdida.addr` depois dava
            // undefined. Resultado: `saindo` nunca era limpo, e a janela que ja
            // tinha saido uma vez morria em silencio depois, sem o aviso.
            var end = perdida.addr;
            var eraNossa = root.saindo[end] === true;
            var morreu = vivos[end] !== true;
            var tit = perdida.titulo || end;
            modelo.remove(i);
            if (eraNossa) delete root.saindo[end];
            // so avisa quando a janela morreu MESMO e nao fomos nos: silencio
            // aqui e o pior caso, ela some do mundo e ele nao sabe se foi bug
            if (morreu && !eraNossa)
                Quickshell.execDetached(["notify-send", "-a", "Gaveta",
                                         "Janela fechou sozinha", tit]);
        }
        // entrou na gaveta, ou o titulo mudou enquanto ela estava guardada
        for (var e = 0; e < guardadas.length; e++) {
            var tl = guardadas[e];
            var achou = -1;
            for (var j = 0; j < modelo.count; j++)
                if (modelo.get(j).addr === root._ende(tl.address)) { achou = j; break; }
            var titulo = tl.title || "";
            var classe = (tl.wayland && tl.wayland.appId) ? tl.wayland.appId : "";
            if (achou === -1) modelo.append({ addr: root._ende(tl.address), appId: classe, titulo: titulo });
            else {
                if (modelo.get(achou).titulo !== titulo) modelo.setProperty(achou, "titulo", titulo);
                if (classe.length && modelo.get(achou).appId !== classe) modelo.setProperty(achou, "appId", classe);
            }
        }
    }

    // toplevel Wayland de um endereco, pra miniatura ao vivo casar por identidade
    function waylandDe(addr) {
        var l = Hyprland.toplevels.values;
        for (var i = 0; i < l.length; i++)
            if (root._ende(l[i].address) === root._ende(addr)) return l[i].wayland;
        return null;
    }

    // ===== acoes =====
    // roda o script e limpa o estado no fim. `exited` NAO dispara quando o
    // processo falha em iniciar (binario sumido, permissao), e sem a rede de
    // seguranca do timer o Process vazava e o painel ficava preso em "guardar".
    function _rodar(args, aoFim) {
        var p = Qt.createQmlObject('import Quickshell.Io; Process { }', root);
        var acabou = false;
        var fim = function () {
            if (acabou) return;
            acabou = true;
            aoFim();
            p.destroy();
        };
        p.exited.connect(fim);
        var t = Qt.createQmlObject(
            'import QtQuick; Timer { interval: 4000; repeat: false }', root);
        t.triggered.connect(function () { fim(); t.destroy(); });
        p.command = args;
        p.running = true;
        t.start();
    }

    function guardar(addr) {
        addr = root._ende(addr);
        if (!addr) return;
        root._rodar([lar + "/.config/quickshell/scripts/gaveta.sh", "guardar", addr],
                    function () { root.recarregar(); root.modo = "fechada"; root.pendente = ""; });
    }
    function tirar(addr) {
        addr = root._ende(addr);
        if (!addr) return;
        root.saindo[addr] = true;   // saida nossa, nao e morte de janela
        root._rodar([lar + "/.config/quickshell/scripts/gaveta.sh", "tirar", addr],
                    function () { root.recarregar(); root.modo = "fechada"; });
    }
    function tirarTudo() {
        for (var i = 0; i < modelo.count; i++) root.saindo[modelo.get(i).addr] = true;
        Quickshell.execDetached([lar + "/.config/quickshell/scripts/gaveta.sh", "tirar-tudo"]);
        root.modo = "fechada";
        recarregarDepois.restart();
    }
    // fecha a janela guardada sem trazer de volta (X da lista do hover)
    function fecharJanela(addr) {
        addr = root._ende(addr);
        if (!addr) return;
        root.saindo[addr] = true;
        Quickshell.execDetached(["hyprctl", "dispatch", "closewindow", "address:" + addr]);
        recarregarDepois.restart();
    }
    Timer { id: recarregarDepois; interval: 400; repeat: false; onTriggered: root.recarregar() }

    // ===== em qual monitor o painel abre =====
    // Sem isto o painel nascia sempre no primeiro monitor: clicar no icone da
    // barra do HDMI abria a gaveta la no notebook. So muda com o painel FECHADO,
    // porque trocar `screen` de janela viva recria a superficie e deixa fantasma.
    property var tela: null
    function _telaFocada() {
        var nome = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
        var telas = Quickshell.screens;
        for (var i = 0; i < telas.length; i++)
            if (telas[i].name === nome) return telas[i];
        return telas.length ? telas[0] : null;
    }

    function abrirTirar() {
        if (root.modo === "tirar") { root.modo = "fechada"; return; }
        // idem: so com o painel fechado
        if (root.modo === "fechada") root.tela = root._telaFocada();
        root.modo = "tirar";
        root.recarregar();
    }
    function fechar() { root.modo = "fechada"; root.pendente = ""; }

    // ===== gatilho do gesto, vindo do bind de mouse =====
    IpcHandler {
        target: "gaveta"
        // chamado pelo bind SUPER+CTRL+esquerdo: entra no modo guardar se o
        // cursor estava na barra de titulo de alguma janela
        function agarrar(addr: string): void {
            if (!addr || addr.length === 0) return;
            root.pendente = addr;
            // so troca de monitor com o painel FECHADO: trocar `screen` de janela
            // layer-shell viva recria a superficie e deixa fantasma
            if (root.modo === "fechada") root.tela = root._telaFocada();
            root.modo = "guardar";
        }
        function abrir(): void { root.abrirTirar() }
        // rede de seguranca por terminal, e o mesmo caminho do clique na
        // miniatura: le o endereco DO MODELO, nao do Hyprland. Se o modelo
        // guardar endereco em formato errado, isto falha junto com a UI.
        function tirarPrimeira(): void { if (modelo.count > 0) root.tirar(modelo.get(0).addr) }
        function tudo(): void { root.tirarTudo() }
        function compactar(): void { root.compacto = !root.compacto }
        function fechar(): void { root.fechar() }
        function recarregar(): void { root.recarregar() }
    }

    Component.onCompleted: recarregar()
    // `guardadas` so re-avalia quando alguem entra ou sai da gaveta; titulo que
    // muda com a janela ja guardada nao dispara nada. Este pulso e so pra isso.
    Timer { interval: 2000; running: root.count > 0; repeat: true; onTriggered: root._reconciliar() }

    // ===== painel =====
    // UMA janela fullscreen: fundo que fecha ao clicar fora, e o card por cima.
    // Aqui tinham DUAS janelas layer-shell na mesma camada, o apanhador de clique
    // e o painel. Elas brigam pelo z-order e o apanhador engole TODOS os cliques
    // do card: a gaveta abria e nao dava pra clicar em nada, nem arrastar janela
    // nenhuma na tela. E a mesma armadilha ja documentada na central de acoes
    // (shell.qml, linha 1889).
    PanelWindow {
        id: painel
        visible: root.modo !== "fechada"
        screen: root.tela
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        // camada definida UMA vez; so `visible` alterna. Trocar camada em tempo
        // de execucao da janela fantasma.
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qsbar-gaveta"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        // fundo: clique em qualquer lugar fora do card fecha
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onClicked: root.fechar()
        }

        Rectangle {
            id: card
            width: 300
            // Altura ACOMPANHA o conteudo, com teto de 80% da tela.
            //
            // O plano mandava altura externa fixa por medo de laco de binding, e
            // por isso a gaveta vazia era uma caixa de 396px de nada. O medo valia
            // quando o painel ERA a janela layer-shell (janela media conteudo,
            // conteudo media janela). Agora a janela e fullscreen e independente,
            // e a largura do card e FIXA em 300: os cards se dimensionam pela
            // largura, nunca pela altura, entao nao existe ciclo.
            //
            // Modo guardar fica travado em UM slot e nao cresce, que e o que ele
            // pediu. Modo tirar mostra tudo, que tambem e o que ele pediu.
            readonly property int alturaConteudo: root.modo === "guardar"
                                                  ? 120
                                                  : Math.max(20, listaCol.implicitHeight)
            // 24 margens + 20 cabecalho + 8 vao + 5 divisor + 8 vao + conteudo.
            // Faltava UM dos dois vaos aqui, e o item compacto saia cortado.
            height: Math.min(24 + 20 + 8 + 5 + 8 + alturaConteudo,
                             Math.round(parent.height * 0.8))
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            radius: 16
            // mesma opacidade do card da central de notificacao, que ele aprovou:
            // com 0.93 o texto do painel disputava leitura com a pagina de tras
            color: root.theme ? Qt.alpha(root.theme.bg, 0.97) : "#1a1b26"
            border.width: 1
            border.color: root.theme ? Qt.alpha(root.theme.accent, 0.2) : "#3d59a1"

            // absorve o clique dentro do card, senao o fundo fecha a gaveta antes
            // de a acao acontecer
            MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                // Item, nao RowLayout: o titulo fica centrado no meio REAL do card.
                // Num RowLayout o contador roubaria largura e empurraria o centro
                // pra esquerda. Aqui o contador flutua ancorado a direita e nao
                // interfere. (Tambem evita o acidente de fillHeight TRUE por padrao
                // em layout aninhado, que empurrava o slot ~200px pra baixo.)
                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 20
                    Text {
                        anchors.centerIn: parent
                        text: root.modo === "guardar" ? "Guardar na gaveta" : "Gaveta"
                        color: root.theme ? root.theme.fgBright : "#c0caf5"
                        font.pixelSize: 13; font.bold: true
                    }
                    Text {
                        id: contador
                        anchors.right: chevron.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.modo === "tirar" && modelo.count > 0
                        text: modelo.count
                        color: root.theme ? root.theme.fgDim : "#6a7090"
                        font.pixelSize: 11
                    }
                    // encolhe/expande a lista
                    Rectangle {
                        id: chevron
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22; height: 22; radius: 6
                        visible: root.modo === "tirar" && modelo.count > 0
                        color: chevMa.containsMouse
                               ? (root.theme ? Qt.alpha(root.theme.accent, 0.2) : "#2a2f45")
                               : "transparent"
                        Text {
                            anchors.centerIn: parent
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 13
                            color: root.theme ? root.theme.fgDim : "#6a7090"
                            text: root.compacto ? "󰅀" : "󰅃"
                        }
                        MouseArea {
                            id: chevMa
                            anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.compacto = !root.compacto
                        }
                    }
                }

                // divisor sob o titulo, mesmo do painel de ajustes (shell.qml:2320).
                // `Layout.preferredHeight` e nao `height`: em filho de layout o
                // height cru e sobrescrito, armadilha ja documentada nesta casa.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    Layout.topMargin: 2
                    Layout.bottomMargin: 2
                    color: root.theme ? root.theme.surface : "#32344a"
                }

                // ---- modo guardar: UM slot vazio, so um, sem crescer ----
                Rectangle {
                    visible: root.modo === "guardar"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 120
                    radius: 12
                    // fundo proprio, nunca transparente: sem ele o texto do slot
                    // disputa legibilidade com o terminal que estiver atras
                    color: soltarMa.containsMouse
                           ? (root.theme ? Qt.alpha(root.theme.accent, 0.16) : "#2a2f45")
                           : (root.theme ? Qt.alpha(root.theme.surface, 0.6) : "#22243a")
                    border.width: 2
                    border.color: root.theme ? Qt.alpha(root.theme.accent, 0.5) : "#3d59a1"

                    ColumnLayout {
                        anchors.centerIn: parent
                        width: parent.width - 24
                        spacing: 4
                        // qual janela vai entrar. Sem isso o slot pede uma acao
                        // sem dizer sobre o que ela e.
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            text: root.pendenteTitulo
                            visible: root.pendenteTitulo.length > 0
                            color: root.theme ? root.theme.fg : "#c0caf5"
                            font.pixelSize: 12; font.bold: true
                        }
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: "clique para guardar"
                            color: root.theme ? root.theme.fgDim : "#6a7090"
                            font.pixelSize: 11
                        }
                    }
                    MouseArea {
                        id: soltarMa
                        anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.guardar(root.pendente)
                    }
                }

                // Fora da lista de proposito: dentro dela o texto herdava a calha
                // de 8px da barra de rolagem e saia 4px a esquerda do centro real.
                Text {
                    visible: root.modo === "tirar" && modelo.count === 0
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: "gaveta vazia"
                    color: root.theme ? root.theme.fgDim : "#6a7090"
                    font.pixelSize: 11
                }

                // ---- modo tirar: lista de miniaturas ----
                Flickable {
                    id: lista
                    visible: root.modo === "tirar"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: listaCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    // barra de rolagem: so aparece quando sobra conteudo. Sem ela,
                    // com a gaveta cheia a janela de baixo ficava invisivel e sem
                    // nenhum aviso de que existia mais coisa.
                    Rectangle {
                        anchors.right: parent.right
                        width: 3
                        radius: 1.5
                        visible: lista.contentHeight > lista.height + 1
                        color: root.theme ? Qt.alpha(root.theme.accent, 0.45) : "#3d59a1"
                        height: Math.max(24, lista.height * (lista.height / lista.contentHeight))
                        y: lista.contentY + (lista.height - height)
                           * (lista.contentHeight > lista.height
                              ? lista.contentY / (lista.contentHeight - lista.height) : 0)
                    }

                    ColumnLayout {
                        id: listaCol
                        // calha de 8px SEMPRE reservada pra barra de rolagem, mesmo
                        // sem rolagem. Reservar so quando rola daria laco: a largura
                        // dependeria de "rola?", que depende da altura do conteudo,
                        // que depende da largura.
                        width: parent.width - 8
                        spacing: 8

                        Repeater {
                            model: modelo
                            delegate: Rectangle {
                                required property string addr
                                required property string appId
                                required property string titulo
                                Layout.fillWidth: true
                                // paisagem: 9/16 da largura REAL do card, mais o
                                // cabecalho. Sai da largura da coluna (que ja desconta
                                // margem e calha), nunca da altura: por isso nao fecha ciclo.
                                Layout.preferredHeight: root.compacto
                                                        ? 34
                                                        : Math.round(listaCol.width * 9 / 16) + 30
                                Behavior on Layout.preferredHeight {
                                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                                }
                                radius: 12
                                // preenchido, igual ao card do Alt+Tab. Vazado, a
                                // faixa do cabecalho mostrava o fundo do painel e
                                // so a miniatura tinha fundo: dois irmaos com
                                // preenchimento diferente na mesma casa
                                color: root.theme ? root.theme.bgAlt : "#1f2130"
                                border.width: 1
                                border.color: miniMa.containsMouse
                                              ? (root.theme ? root.theme.accent : "#7d82d9")
                                              : (root.theme ? root.theme.surface : "#32344a")

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 1
                                    spacing: 0

                                    // cabecalho EM CIMA (invertido em relacao ao
                                    // Alt+Tab, que poe a imagem em cima)
                                    RowLayout {
                                        Layout.fillWidth: true
                                        // compacto: o cabecalho E o item inteiro, entao
                                        // centraliza na altura. Expandido: faixa fixa em
                                        // cima da miniatura.
                                        Layout.fillHeight: root.compacto
                                        Layout.preferredHeight: 28
                                        Layout.leftMargin: 8; Layout.rightMargin: 8
                                        spacing: 7
                                        Image {
                                            Layout.preferredWidth: 20; Layout.preferredHeight: 20
                                            Layout.alignment: Qt.AlignVCenter
                                            fillMode: Image.PreserveAspectFit
                                            // MESMA resolucao da taskbar (shell.qml ~1105).
                                            // Passar a classe crua pro iconPath quebra:
                                            // "brave-browser" nao e nome de icone, e o
                                            // Brave saia como quadriculado magenta. Quem
                                            // sabe o nome do icone e o DesktopEntries.
                                            source: {
                                                // dependencia reativa: DesktopEntries carrega
                                                // ~2s depois do boot; ao mudar de 0 p/ N apps
                                                // este binding re-avalia
                                                var pronto = DesktopEntries.applications.values.length;
                                                var id = appId;
                                                if (!id || !id.length) return "";
                                                var de = DesktopEntries.byId(id) || DesktopEntries.heuristicLookup(id);
                                                // Catalogo ainda carregando (~2s apos o boot): nao pede icone com o
                                                // nome da CLASSE, que quase nunca e nome de icone valido
                                                // ("brave-browser" contra "brave-desktop"). Volta vazio e re-avalia
                                                // sozinho quando o catalogo chegar.
                                                if (!de && pronto === 0) return "";
                                                var icone = (de && de.icon && de.icon.length) ? de.icon : id;
                                                // jogos Steam: a janela e steam_app_<id>,
                                                // mas o icone no tema e steam_icon_<id>
                                                if (id.indexOf("steam_app_") === 0)
                                                    icone = "steam_icon_" + id.substring(10);
                                                return Quickshell.iconPath(icone, "application-x-executable");
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            Layout.alignment: Qt.AlignVCenter
                                            verticalAlignment: Text.AlignVCenter
                                            text: titulo || appId
                                            elide: Text.ElideRight
                                            color: root.theme ? root.theme.fg : "#c0caf5"
                                            font.pixelSize: 12
                                        }
                                    }
                                    // conteudo ao vivo embaixo, sobre fundo OPACO.
                                    // O ScreencopyView escreve o alfa da janela
                                    // capturada em vez de compor: sem este fundo,
                                    // janela com transparencia (kitty roda com
                                    // background_opacity) vira buraco no painel e
                                    // a miniatura mostra o que esta ATRAS da gaveta.
                                    Rectangle {
                                        // compacto = so o cabecalho. Sem isto a
                                        // miniatura ficava viva, espremida em poucos
                                        // pixels, e aparecia como falha embaixo do texto
                                        visible: !root.compacto
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        color: root.theme ? root.theme.bgAlt : "#1a1b26"
                                        // layer.enabled poe fundo + captura num buffer
                                        // proprio ANTES de compor no painel. Sem ele a
                                        // captura leva o alfa dela pro painel inteiro e
                                        // a miniatura vira janela pro que esta atras.
                                        layer.enabled: true
                                        // ...mas layer.enabled tambem desenha numa
                                        // textura propria, SEM recorte pelo raio do pai,
                                        // e o canto de baixo saia reto dentro de um card
                                        // arredondado. Raio proprio resolve.
                                        bottomLeftRadius: 11
                                        bottomRightRadius: 11
                                        ScreencopyView {
                                            anchors.fill: parent
                                            live: true
                                            // casa por identidade (endereco), nao
                                            // por titulo: titulo repete e muda
                                            captureSource: root.waylandDe(addr)
                                        }
                                    }
                                }
                                MouseArea {
                                    id: miniMa
                                    anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.tirar(addr)
                                }
                            }
                        }

                    }
                }
            }
        }
    }
}
