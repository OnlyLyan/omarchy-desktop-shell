// Demo standalone do PcHeartbeat: roda sozinho com `quickshell -p demo-shell.qml`
// (ou use o run-demo.sh, que ja seta o caminho do stats.sh).
// Mostra so o "coracao" do PC num PanelWindow no canto inferior esquerdo.
import Quickshell
import Quickshell.Io
import QtQuick

ShellRoot {
    PanelWindow {
        anchors { bottom: true; left: true }
        implicitWidth: 200
        implicitHeight: 34
        color: "#1a1b26"

        QtObject { id: sys; property int cpu: 0; property int mem: 0; property int temp: 0 }

        // le "cpu mem temp" do stats.sh. O run-demo.sh seta HEARTBEAT_STATS com o caminho
        // absoluto; ao embutir na sua barra, troque pelo caminho do seu stats.sh.
        Process {
            id: statsProc
            command: [Quickshell.env("HEARTBEAT_STATS") || "stats.sh"]
            stdout: StdioCollector {
                onStreamFinished: {
                    var p = this.text.trim().split(" ");
                    sys.cpu = parseInt(p[0]) || 0;
                    sys.mem = parseInt(p[1]) || 0;
                    sys.temp = parseInt(p[2]) || 0;
                }
            }
        }
        Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true
                onTriggered: statsProc.running = true }

        PcHeartbeat {
            anchors.centerIn: parent
            cpu: sys.cpu
            mem: sys.mem
            temp: sys.temp
        }
    }
}
