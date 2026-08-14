// Faixa clicavel colada no topo da janela do kitty, e so dela.
//
// Por que nao foi feito de outro jeito:
//   - tab bar do kitty: nao aceita clique customizado. O tratamento e fixo em
//     tabs.py, o clique vira id de aba, e clique fora de aba cria aba nova.
//   - botao do hyprbars: os botoes sao globais, nao ha regra por classe, entao
//     ele apareceria tambem no Brave e no Obsidian.
//
// Aqui a faixa e desenhada pelo quickshell numa camada de overlay que cobre a
// tela toda mas e transparente, com um retangulo posicionado exatamente sobre a
// janela do kitty em foco. Ela segue a janela quando move, redimensiona ou troca
// de workspace, porque reconsulta a cada evento do Hyprland.

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts

Scope {
    id: root
    // HOME em vez de caminho absoluto: caminho com usuario fixo quebra pra
    // qualquer outra pessoa, e o repo deste shell e publico.
    readonly property string lar: Quickshell.env("HOME")


    // tema ativo, passado pelo shell.qml (mesmo padrao do MonitorPanel.qml).
    // sem isso as cores ficam hex fixo, nunca acompanham troca de tema.
    property var theme: null

    // Janelas do kitty que estao rodando o Claude Code. A faixa aparece nelas e
    // so nelas: seguir o FOCO fazia a barra pular para um terminal qualquer, e
    // ali ela mentiria, porque aquele shell nao tem MCP nenhum.
    // Cada item: {x, y, w}
    property var janelas: []
    property string mcps: ""
    property int nServ: 0
    property int nTools: 0
    property int nGuardados: 0

    // A faixa mora DENTRO da barra de titulo do hyprbars, no espaco vazio entre
    // o titulo (a esquerda) e os tres botoes (a direita). Assim nao cria uma
    // segunda linha nem rouba espaco do terminal.
    readonly property int alturaFaixa: 28   // a propria altura da barra
    // -28: o "at" do Hyprland aponta para o CONTEUDO. Com bar_part_of_window,
    // o hyprbars desenha a barra 28px ACIMA disso. Sem o deslocamento negativo a
    // faixa caia uma linha abaixo do titulo, cobrindo o texto do terminal.
    readonly property int barraTitulo: -28
    // Canto superior ESQUERDO da janela, compacta. O titulo do hyprbars foi
    // centralizado (bar_text_align = center) para nao colidir com ela.
    readonly property int larguraFaixa: 250

    // ---- consulta a janela ativa ----
    Process {
        id: consulta
        // Devolve [{x, y, w}] das janelas kitty VISIVEIS rodando Claude.
        //
        // A logica mora em ~/.local/bin/claude-janela, nao aqui. Antes era um
        // python inline gigante nesta string, e a MESMA busca estava copiada no
        // claude-restart. As copias divergiram e cada uma teve que ser
        // consertada separadamente, sempre pelo mesmo motivo: `pgrep -P` so
        // acha filho direto e o Claude quase nunca e filho direto do terminal.
        //
        // Caminho absoluto de proposito: o quickshell sobe como servico de
        // usuario e nao necessariamente tem ~/.local/bin no PATH.
        //
        // O script ja filtra `visible` e `fullscreen`. Sem o filtro de
        // visibilidade a faixa desenhava por cima do Discord em tela cheia,
        // porque ela mora numa camada do layershell e nada a cobre: sabia ONDE
        // o kitty estava, mas nao se dava para ve-lo.
        command: [lar + "/.local/bin/claude-janela", "lista"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.janelas = JSON.parse(this.text.trim()) || []; }
                catch (e) { root.janelas = []; }
            }
        }
    }

    // ---- le quais MCPs estao carregados ----
    Process {
        id: leMcps
        command: ["sh", "-c",
            "python3 - <<'PY'\n" +
            "import json,os\n" +
            "def c(p,d):\n" +
            "    try: return json.load(open(os.path.expanduser(p)))\n" +
            "    except Exception: return d\n" +
            "a=c('~/.claude.json',{}).get('mcpServers',{})\n" +
            "g=c('~/.claude/mcp-disponiveis.json',{})\n" +
            "t=c('~/.claude/mcp-tool-counts.json',{})\n" +
            "print(' '.join(sorted(a)))\n" +
            "print(len(a), sum(t.get(k,0) for k in a), len(g))\n" +
            "PY"]
        stdout: StdioCollector {
            onStreamFinished: {
                var l = this.text.trim().split("\n");
                if (l.length < 2) return;
                root.mcps = l[0].trim();
                var n = l[1].trim().split(/\s+/);
                root.nServ = parseInt(n[0]) || 0;
                root.nTools = parseInt(n[1]) || 0;
                root.nGuardados = parseInt(n[2]) || 0;
            }
        }
    }

    // ---- abre o menu ----
    Process {
        id: abreMenu
        command: ["sh", "-c",
            "kitty @ launch --type=overlay --title Ferramentas " +
            lar + "/.local/bin/barra-ferramentas 2>/dev/null || " +
            "setsid kitty --title Ferramentas -e " + lar + "/.local/bin/barra-ferramentas"]
    }

    // ---- eventos do Hyprland: reconsulta quando algo muda ----
    // socat na socket2, uma linha por evento. Mais previsivel que depender da
    // API do modulo Hyprland, e e o mesmo mecanismo que o hyprctl usa.
    Process {
        id: eventos
        running: true
        command: ["sh", "-c",
            "socat -u UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock -"]
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function (linha) {
                var e = linha.split(">>")[0];
                if (e === "activewindow" || e === "activewindowv2" || e === "openwindow"
                    || e === "closewindow" || e === "movewindow" || e === "resizeactive"
                    || e === "workspace" || e === "focusedmon" || e === "changefloatingmode"
                    || e === "fullscreen" || e === "monitorremoved" || e === "monitoradded") {
                    consulta.running = true;
                }
            }
        }
    }

    // rede de seguranca: se um evento escapar, o estado se corrige sozinho
    Timer {
        interval: 1500; running: true; repeat: true; triggeredOnStart: true
        onTriggered: { consulta.running = true; leMcps.running = true; }
    }

    // ---- a faixa ----
    // Uma PanelWindow PEQUENA por janela do Claude, ancorada no topo e na
    // esquerda com margens. Antes era uma camada do tamanho da tela com mascara
    // recortada, mas a mascara exigia uma lista de regioes que o Repeater nao
    // expoe. Assim e mais simples e nao ha risco de engolir clique do desktop.
    Variants {
        model: root.janelas

        PanelWindow {
            id: faixaWin
            property var modelData

            screen: {
                var ss = Quickshell.screens;
                for (var i = 0; i < ss.length; i++) {
                    var s = ss[i];
                    if (modelData.x >= s.x && modelData.x < s.x + s.width) return s;
                }
                return ss[0];
            }

            anchors { top: true; left: true }
            margins.left: modelData.x - (screen ? screen.x : 0) + 8
            margins.top: modelData.y - (screen ? screen.y : 0) + root.barraTitulo
            implicitWidth: Math.min(root.larguraFaixa, Math.max(1, modelData.w - 16))
            implicitHeight: root.alturaFaixa

            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            // Top, nao Overlay. Overlay desenha acima de absolutamente tudo,
            // inclusive de janela em tela cheia de outro aplicativo. Top ja
            // fica acima das janelas normais, que e o suficiente para a faixa
            // pousar sobre a barra de titulo do kitty.
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.namespace: "qsbar-kittystrip"

            Rectangle {
                anchors.fill: parent
                // hover e realce neutro (tema A); sem tema carregado, cai pro
                // fixo antigo so pra nao quebrar se algum dia rodar sem theme
                color: hov.containsMouse ? (root.theme ? root.theme.surface2 : "#2a2f45") : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    spacing: 8

                    Text {
                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13
                        // faixa so aparece com Claude+MCP carregado de verdade: e estado
                        // real, mesma regra do tema A pra quando o azul de destaque vale
                        color: root.theme ? root.theme.accent : "#7d82d9"
                        text: "\u{F0493}"
                    }
                    Text {
                        Layout.fillWidth: true
                        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13
                        color: root.theme ? (hov.containsMouse ? root.theme.fg : root.theme.fgDim) : "#6a7090"
                        elide: Text.ElideRight
                        text: root.nServ + " mcp, " + root.nTools + " tools"
                              + (root.nGuardados > 0 ? " | +" + root.nGuardados : "")
                    }
                }

                MouseArea {
                    id: hov
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: abreMenu.running = true
                }
            }
        }
    }
}
