// Painel de monitores da central de controle. UI pura; todo efeito de sistema
// (ler hyprctl, aplicar, persistir, perfis) vai pro scripts/monitors.sh.
// Plugado no shell.qml como a view card.view === "monitors".
import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: panel
    property var theme: null
    property var screen: null
    signal back()
    signal applied()   // emitido apos aplicar ao vivo; o shell fecha o painel e mostra o toast

    property var mons: []          // JSON cru do hyprctl monitors -j
    property var draft: ({})       // nome -> { res, scale, x, y, enabled, transform, w, h }
    property string expanded: ""   // monitor com a lista de modos aberta
    spacing: 8

    // ===== IO: ler estado =====
    Process {
        id: getProc
        command: ["/home/vings/.config/quickshell/scripts/monitors.sh", "get"]
        stdout: StdioCollector { onStreamFinished: panel._ingest(this.text) }
    }
    function reload() { getProc.running = true }
    function _norm(modeStr) {
        // "1920x1080@144.00Hz" -> "1920x1080@144"
        return String(modeStr).replace("Hz", "").replace(/@(\d+)(\.\d+)?$/, "@$1");
    }
    function _ingest(txt) {
        var arr;
        try { arr = JSON.parse(txt); } catch (e) { panel.mons = []; return; }
        var d = ({});
        for (var i = 0; i < arr.length; i++) {
            var m = arr[i];
            d[m.name] = {
                res: m.width + "x" + m.height + "@" + Math.round(m.refreshRate || 60),
                scale: Math.round((m.scale || 1) * 100) / 100,
                x: m.x || 0, y: m.y || 0,
                enabled: !m.disabled,
                transform: m.transform || 0,
                w: m.width, h: m.height
            };
        }
        panel.draft = d;
        panel.mons = arr;
    }
    // muda campos de um monitor criando objetos NOVOS (referencia nova),
    // senao o QML nao percebe a mudanca e nao redesenha
    function _set(name, patch) {
        var d = Object.assign({}, panel.draft);
        d[name] = Object.assign({}, d[name], patch);
        panel.draft = d;
    }
    Component.onCompleted: { reload(); loadProfiles(); }

    // ===== layout virtual do mapa =====
    // lista dos monitores ligados com dimensoes LOGICAS (pos-escala) e posicao do draft
    function _isPrimary(name) { return panel.mons.length > 0 && panel.mons[0].name === name; }
    function _setPos(name, vx, vy) { panel._set(name, { x: Math.round(vx), y: Math.round(vy) }); }
    // dimensoes NATIVAS (com swap se girado 90/270) — e o que o usuario espera ver no mapa
    function _dims(c) { var w = c.w, h = c.h; var t = c.transform || 0; if (t === 1 || t === 3) { var tmp = w; w = h; h = tmp; } return { w: w, h: h }; }
    // largura/altura LOGICAS (pos-escala) — e o que o Hyprland usa pra posicionar
    function _lw(c) { var d = _dims(c); return Math.max(1, Math.round(d.w / c.scale)); }
    function _lh(c) { var d = _dims(c); return Math.max(1, Math.round(d.h / c.scale)); }

    // layout VISUAL do mapa: TAMANHO = resolucao NATIVA (intuicao do usuario: quem tem mais
    // pixels aparece maior; eDP 1920 > HDMI 1366). POSICAO = ancorada no principal em (0,0),
    // convertendo o delta LOGICO do draft pra escala visual do principal. Assim "borda encosta"
    // continua verdadeiro e o offset perpendicular arrastado e preservado.
    property var vlay: _computeVisual()
    function _computeVisual() {
        var out = [];
        if (!panel.mons.length) return out;
        var prim = panel.draft[panel.mons[0].name];
        if (!prim) return out;
        var pd = _dims(prim), s = prim.scale;
        var plw = _lw(prim), plh = _lh(prim);
        out.push({ name: panel.mons[0].name, nw: pd.w, nh: pd.h, vx: 0, vy: 0, isPrim: true });
        for (var i = 1; i < panel.mons.length; i++) {
            var nm = panel.mons[i].name, c = panel.draft[nm];
            if (!c || !c.enabled) continue;
            var d = _dims(c), slw = _lw(c), slh = _lh(c);
            // eixo colado: usa tamanho NATIVO direto pra borda encostar de verdade (o eixo
            // logico do lado esquerdo/acima usa a dimensao do secundario, que nao converte
            // certo pela escala do principal). eixo livre: delta logico * escala do principal.
            var vx, vy;
            if (c.x >= prim.x + plw) {            // direita
                vx = pd.w; vy = (c.y - prim.y) * s;
            } else if (c.x + slw <= prim.x) {     // esquerda
                vx = -d.w; vy = (c.y - prim.y) * s;
            } else if (c.y >= prim.y + plh) {     // abaixo
                vy = pd.h; vx = (c.x - prim.x) * s;
            } else {                               // acima
                vy = -d.h; vx = (c.x - prim.x) * s;
            }
            out.push({ name: nm, nw: d.w, nh: d.h, vx: vx, vy: vy, isPrim: false });
        }
        return out;
    }
    property real vMinX: { var v = 0; for (var i = 0; i < vlay.length; i++) v = i ? Math.min(v, vlay[i].vx) : vlay[i].vx; return v; }
    property real vMinY: { var v = 0; for (var i = 0; i < vlay.length; i++) v = i ? Math.min(v, vlay[i].vy) : vlay[i].vy; return v; }
    property real vMaxX: { var v = 0; for (var i = 0; i < vlay.length; i++) { var e = vlay[i].vx + vlay[i].nw; v = i ? Math.max(v, e) : e; } return v; }
    property real vMaxY: { var v = 0; for (var i = 0; i < vlay.length; i++) { var e = vlay[i].vy + vlay[i].nh; v = i ? Math.max(v, e) : e; } return v; }

    // gruda em alvos de alinhamento quando o valor arrastado esta a <= thr deles; senao
    // deixa livre. Evita zona morta: bordas desalinhadas fazem o cursor travar ao cruzar.
    function _magnet(v, targets, thr) {
        for (var i = 0; i < targets.length; i++) if (Math.abs(v - targets[i]) <= thr) return targets[i];
        return v;
    }
    // gruda o secundario na borda do lado escolhido (eixo principal) e mantem o offset
    // perpendicular arrastado (vx/vy = posicao VISUAL NATIVA onde foi solto, rel. ao principal;
    // convertida pra delta logico pela escala do principal). O perpendicular tem snap magnetico
    // pras bordas alinhadas (topo/centro/base ou esq/centro/dir), pra o cursor atravessar a borda
    // inteira; fora do ima, offset livre. Clampa pra manter sobreposicao minima. Saida LOGICA.
    function _snap(name, side, vx, vy) {
        if (!panel.mons.length) return;
        var prim = panel.draft[panel.mons[0].name], c = panel.draft[name];
        if (!prim || !c) return;
        var s = prim.scale, thr = 40;
        var plw = _lw(prim), plh = _lh(prim), slw = _lw(c), slh = _lh(c);
        var x, y;
        if (side === "right" || side === "left") {
            x = side === "right" ? prim.x + plw : prim.x - slw;
            var ly = _magnet(prim.y + vy / s, [prim.y, prim.y + (plh - slh) / 2, prim.y + plh - slh], thr);
            var ov = Math.min(slh, plh) * 0.15;
            y = Math.max(prim.y - slh + ov, Math.min(prim.y + plh - ov, ly));
        } else {
            y = side === "below" ? prim.y + plh : prim.y - slh;
            var lx = _magnet(prim.x + vx / s, [prim.x, prim.x + (plw - slw) / 2, prim.x + plw - slw], thr);
            var oh = Math.min(slw, plw) * 0.15;
            x = Math.max(prim.x - slw + oh, Math.min(prim.x + plw - oh, lx));
        }
        panel._setPos(name, x, y);
    }

    // descreve o arranjo em texto (cada secundario em relacao ao principal)
    function _arrangeText() {
        if (panel.mons.length < 2) return "";
        var prim = panel.draft[panel.mons[0].name];
        if (!prim) return "";
        var plw = Math.round(prim.w / prim.scale), plh = Math.round(prim.h / prim.scale);
        var pcx = prim.x + plw / 2, pcy = prim.y + plh / 2, parts = [];
        for (var i = 1; i < panel.mons.length; i++) {
            var n = panel.mons[i].name, c = panel.draft[n];
            if (!c || !c.enabled) { parts.push(n + ": desligado"); continue; }
            var mcx = c.x + Math.round(c.w / c.scale) / 2, mcy = c.y + Math.round(c.h / c.scale) / 2;
            var dx = mcx - pcx, dy = mcy - pcy;
            var dir = Math.abs(dx) >= Math.abs(dy) ? (dx > 0 ? "a direita" : "a esquerda") : (dy > 0 ? "abaixo" : "acima");
            parts.push(n + " " + dir);
        }
        return parts.join(", ");
    }

    // ===== aplicar =====
    function _lines() {
        // normaliza posicoes pra min 0,0 (Hyprland prefere coords nao-negativas)
        var minx = 1e9, miny = 1e9;
        for (var n in panel.draft) { var cc = panel.draft[n]; if (cc.enabled) { minx = Math.min(minx, cc.x); miny = Math.min(miny, cc.y); } }
        if (minx === 1e9) { minx = 0; miny = 0; }
        var out = [];
        for (var name in panel.draft) {
            var c = panel.draft[name];
            if (!c.enabled) { out.push(name + ",disable"); continue; }
            var line = name + "," + c.res + "," + (c.x - minx) + "x" + (c.y - miny) + "," + c.scale;
            if (c.transform && c.transform !== 0) line += ",transform," + c.transform;
            out.push(line);
        }
        return out;
    }
    function _anyEnabled() {
        for (var n in panel.draft) if (panel.draft[n].enabled) return true;
        return false;
    }

    // aplica ao vivo via monitors.sh (que arma o watchdog e guarda o pending) e, ao
    // terminar, emite applied(). O shell fecha o painel e mostra o toast SEM recarregar
    // (Aplicar fica sem flash; a barra do secundario fica levemente fora do lugar por ~10s).
    // O reload que corrige os surfaces so acontece no Confirmar/Reverter (ou no watchdog).
    Process { id: previewProc; onExited: panel.applied() }
    function preview() {
        if (!_anyEnabled()) return;
        previewProc.command = ["/home/vings/.config/quickshell/scripts/monitors.sh", "preview"].concat(_lines());
        previewProc.running = true;
    }

    // ===== perfis (corpo na Task 7; stub aqui pra Component.onCompleted nao quebrar) =====
    property var profiles: []
    function loadProfiles() { profListProc.running = true }
    Process {
        id: profListProc
        command: ["/home/vings/.config/quickshell/scripts/monitors.sh", "profiles-list"]
        stdout: StdioCollector { onStreamFinished: panel.profiles = this.text.trim() ? this.text.trim().split("\n") : [] }
    }

    // ===== header =====
    RowLayout {
        Layout.fillWidth: true; spacing: 8
        Text {
            text: "󰅁"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 16; color: theme.fg
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: panel.back() }
        }
        Text { text: "Monitores"; color: theme.fgBright; font.bold: true; font.pixelSize: 13; Layout.fillWidth: true }
        Text {
            text: "󰑐"; font.family: "JetBrainsMono Nerd Font"; color: theme.fgDim; font.pixelSize: 13
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: panel.reload() }
        }
    }

    // ===== mapa: arraste para posicionar =====
    Rectangle {
        id: mapArea
        Layout.fillWidth: true
        implicitHeight: 150
        radius: 10
        color: theme.surface
        border.color: theme.border; border.width: 1
        visible: panel.vlay.length > 0

        property real factor: {
            var w = panel.vMaxX - panel.vMinX, h = panel.vMaxY - panel.vMinY;
            if (w <= 0 || h <= 0) return 0.05;
            return Math.min((width - 16) / w, (height - 16) / h, 0.10);
        }
        property real ox: (width - (panel.vMaxX - panel.vMinX) * factor) / 2
        property real oy: (height - (panel.vMaxY - panel.vMinY) * factor) / 2

        Repeater {
            model: panel.vlay
            delegate: Rectangle {
                id: tile
                required property var modelData
                property bool isPrim: modelData.isPrim
                property real factor: mapArea.factor
                width: modelData.nw * factor
                height: modelData.nh * factor
                radius: 4
                // posicao SEM binding (pra nao brigar com o arraste); reposiciona quando o
                // layout muda ou a area redimensiona, mas nunca durante o arraste.
                function _resetPos() {
                    if (dragMa.drag.active) return;
                    tile.x = mapArea.ox + (modelData.vx - panel.vMinX) * factor;
                    tile.y = mapArea.oy + (modelData.vy - panel.vMinY) * factor;
                }
                Component.onCompleted: _resetPos()
                onFactorChanged: _resetPos()
                Connections { target: panel; function onVlayChanged() { tile._resetPos() } }
                Connections { target: mapArea; function onOxChanged() { tile._resetPos() } function onOyChanged() { tile._resetPos() } }
                color: tile.isPrim ? Qt.alpha(theme.fgDim, 0.28)
                       : (dragMa.drag.active ? Qt.alpha(theme.accent, 0.6) : Qt.alpha(theme.accent, 0.3))
                border.width: tile.isPrim ? 1 : 2
                border.color: tile.isPrim ? theme.fgDim : theme.accent
                Column {
                    anchors.centerIn: parent; width: parent.width - 6; spacing: 0
                    Text {
                        width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                        text: modelData.name; color: theme.fgBright; font.pixelSize: 11; font.bold: true
                    }
                    Text {
                        width: parent.width; horizontalAlignment: Text.AlignHCenter
                        text: tile.isPrim ? "principal" : (modelData.nw + "x" + modelData.nh)
                        color: theme.fgDim; font.pixelSize: 8
                    }
                }
                MouseArea {
                    id: dragMa
                    anchors.fill: parent
                    enabled: !tile.isPrim
                    cursorShape: tile.isPrim ? Qt.ArrowCursor : Qt.SizeAllCursor
                    drag.target: tile.isPrim ? null : tile
                    drag.threshold: 3
                    onReleased: {
                        if (tile.isPrim) return;
                        var prim = panel.draft[panel.mons[0].name], pd = panel._dims(prim);
                        // posicao VISUAL NATIVA do canto sup-esq onde soltou, rel. ao principal (vx=0)
                        var vx = (tile.x - mapArea.ox) / mapArea.factor + panel.vMinX;
                        var vy = (tile.y - mapArea.oy) / mapArea.factor + panel.vMinY;
                        // lado decidido pelo centro do tile vs centro do principal (nativo), normalizado
                        var cx = vx + tile.modelData.nw / 2, cy = vy + tile.modelData.nh / 2;
                        var ndx = (cx - pd.w / 2) / (pd.w / 2), ndy = (cy - pd.h / 2) / (pd.h / 2);
                        var side = Math.abs(ndx) >= Math.abs(ndy) ? (ndx > 0 ? "right" : "left") : (ndy > 0 ? "below" : "above");
                        panel._snap(tile.modelData.name, side, vx, vy);
                        // drag.active so zera DEPOIS deste handler; adia o snap visual pro proximo
                        // tick, quando o guard de _resetPos ja liberou.
                        Qt.callLater(tile._resetPos);
                    }
                }
            }
        }
    }

    // texto do arranjo (referencia clara de onde cada secundario ficou)
    Text {
        Layout.fillWidth: true
        visible: panel.vlay.length > 1
        horizontalAlignment: Text.AlignHCenter
        text: panel.mons.length ? (panel.mons[0].name + " (principal), " + panel._arrangeText()) : ""
        color: theme.fgDim; font.pixelSize: 10; wrapMode: Text.WordWrap
    }

    // ===== lista de monitores =====
    Repeater {
        model: panel.mons
        delegate: Rectangle {
            id: mrow
            required property var modelData
            property string mname: modelData.name
            property var cfg: panel.draft[mname] || ({ res: "", scale: 1, enabled: true, transform: 0 })
            property var modes: (modelData.availableModes || []).map(function (s) { return panel._norm(s); })
            Layout.fillWidth: true
            color: theme.bgAlt; radius: 10
            implicitHeight: mcol.implicitHeight + 16

            ColumnLayout {
                id: mcol
                anchors.fill: parent; anchors.margins: 8; spacing: 6

                // titulo + toggle on/off
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    Text { text: mrow.mname; color: theme.fgBright; font.bold: true; font.pixelSize: 12; Layout.fillWidth: true }
                    Text { text: mrow.cfg.enabled ? "" : "desligado"; color: theme.fgDim; font.pixelSize: 9 }
                    Rectangle {
                        width: 40; height: 20; radius: 10
                        color: mrow.cfg.enabled ? theme.accent : theme.surface
                        Rectangle {
                            width: 16; height: 16; radius: 8; color: "white"; y: 2
                            x: mrow.cfg.enabled ? 22 : 2
                            Behavior on x { NumberAnimation { duration: 120 } }
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: panel._set(mrow.mname, { enabled: !mrow.cfg.enabled })
                        }
                    }
                }

                // modo (resolucao@refresh) com lista expansivel
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 26; radius: 6; color: theme.surface
                    visible: mrow.cfg.enabled
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8
                        Text { text: "Modo"; color: theme.fgDim; font.pixelSize: 10 }
                        Text { text: mrow.cfg.res; color: theme.fg; font.pixelSize: 11; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight }
                        Text { text: panel.expanded === mrow.mname ? "󰅃" : "󰅀"; font.family: "JetBrainsMono Nerd Font"; color: theme.fgDim; font.pixelSize: 11 }
                    }
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onClicked: panel.expanded = (panel.expanded === mrow.mname ? "" : mrow.mname)
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 1
                    visible: mrow.cfg.enabled && panel.expanded === mrow.mname
                    Repeater {
                        model: mrow.modes
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true; implicitHeight: 22; radius: 4
                            color: modeMa.containsMouse ? Qt.alpha(theme.accent, 0.25)
                                   : (modelData === mrow.cfg.res ? Qt.alpha(theme.accent, 0.15) : "transparent")
                            Text { anchors.centerIn: parent; text: modelData; color: theme.fg; font.pixelSize: 10 }
                            MouseArea {
                                id: modeMa
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { panel._set(mrow.mname, { res: modelData }); panel.expanded = ""; }
                            }
                        }
                    }
                }

                // escala
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    visible: mrow.cfg.enabled
                    Text { text: "Escala"; color: theme.fg; font.pixelSize: 11; Layout.fillWidth: true }
                    MonitorStep {
                        theme: panel.theme; glyph: "󰍷"
                        onTriggered: panel._set(mrow.mname, { scale: Math.max(0.5, Math.round((mrow.cfg.scale - 0.25) * 100) / 100) })
                    }
                    Text { text: mrow.cfg.scale.toFixed(2); color: theme.fgBright; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; Layout.preferredWidth: 34 }
                    MonitorStep {
                        theme: panel.theme; glyph: "󰐕"
                        onTriggered: panel._set(mrow.mname, { scale: Math.min(3, Math.round((mrow.cfg.scale + 0.25) * 100) / 100) })
                    }
                }

                // girar (a posicao agora e pelo mapa la em cima)
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    visible: mrow.cfg.enabled
                    Text { text: "Girar"; color: theme.fg; font.pixelSize: 11; Layout.fillWidth: true }
                    Text { text: [ "0", "90", "180", "270" ][mrow.cfg.transform] + "°"; color: theme.fgDim; font.pixelSize: 10 }
                    MonitorStep {
                        theme: panel.theme; glyph: "󰑥"
                        onTriggered: panel._set(mrow.mname, { transform: (mrow.cfg.transform + 1) % 4 })
                    }
                }
            }
        }
    }

    // ===== acao: Aplicar =====
    // aplica ao vivo; a shell recarrega e mostra o toast Confirmar/Reverter (rede de
    // seguranca: o watchdog reverte sozinho em 10s se nao confirmar).
    Rectangle {
        Layout.fillWidth: true; implicitHeight: 38; radius: 10
        color: aplMa.containsMouse ? Qt.alpha(theme.accent, 0.3) : theme.accent
        opacity: panel._anyEnabled() ? 1 : 0.4
        RowLayout {
            anchors.centerIn: parent; spacing: 6
            Text { text: "󰍹"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 14; color: theme.bg }
            Text { text: "Aplicar"; color: theme.bg; font.pixelSize: 11; font.bold: true }
        }
        MouseArea { id: aplMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: panel.preview() }
    }
}
