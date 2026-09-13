import QtQuick
import qs.Commons
import qs.Ui

// One consumption bucket: label, bar scaled to the visible peak, kWh, cost.
// Partial rows (coverage < 0.98) are dimmed so "the machine was off" does
// not read as "I used little power".
Item {
  id: root

  property string label: ""
  property real ratio: 0
  property string kwhText: ""
  property string costText: ""
  property bool partial: false
  property string tooltipText: ""
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color track: Style.selectedFillFor(foreground, Color.accent)
  property string fontFamily: Style.font.family

  readonly property color labelColor: partial ? root.dim : root.foreground

  implicitHeight: Math.max(nameLabel.implicitHeight, kwhLabel.implicitHeight) + Style.spacing.sm
  opacity: partial ? 0.62 : 1

  Text {
    id: nameLabel
    textFormat: Text.PlainText
    text: root.label
    color: root.labelColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: !root.partial
    elide: Text.ElideRight
    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(64)
  }

  Rectangle {
    id: barTrack
    anchors.left: nameLabel.right
    anchors.right: kwhLabel.left
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
    radius: height / 2
    color: root.track

    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height
      radius: parent.radius
      width: parent.width * Math.max(0, Math.min(1, root.ratio))
      color: root.partial ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45) : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }

  Text {
    id: kwhLabel
    textFormat: Text.PlainText
    text: root.kwhText
    color: root.labelColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    anchors.right: costLabel.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(70)
  }

  Text {
    id: costLabel
    textFormat: Text.PlainText
    text: root.costText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(80)
  }

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
  }

  PanelToolTip {
    visible: hover.containsMouse && root.tooltipText !== ""
    text: root.tooltipText
    fontFamily: root.fontFamily
  }
}
