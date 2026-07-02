// Botao quadrado pequeno com glyph, usado nos controles do MonitorPanel.
import QtQuick

Rectangle {
    id: btn
    property var theme: null
    property string glyph: ""
    signal triggered()
    width: 26; height: 26; radius: 6
    color: ma.containsMouse ? Qt.alpha(theme.accent, 0.3) : theme.surface
    Text {
        anchors.centerIn: parent; text: btn.glyph
        font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13; color: theme.fg
    }
    MouseArea {
        id: ma
        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
        onClicked: btn.triggered()
    }
}
