import QtQuick
import qs.Commons

// Last-24h power sparkline. Hover shows a crosshair and a watts/time readout.
// `points` is [{ts, w}, ...] with unix-seconds timestamps, oldest first.
Item {
  id: root

  property var points: []
  property color lineColor: Color.foreground
  property color fillColor: Qt.rgba(lineColor.r, lineColor.g, lineColor.b, 0.14)
  property color crosshairColor: Color.accent
  property color dim: Qt.darker(lineColor, 1.55)
  property string fontFamily: Style.font.family

  readonly property int pad: Math.max(4, Style.space(6))
  readonly property int count: Array.isArray(points) ? points.length : 0
  readonly property real maxW: {
    var peak = 1
    var list = Array.isArray(points) ? points : []
    for (var i = 0; i < list.length; i++) {
      var w = Number(list[i] && list[i].w)
      if (isFinite(w) && w > peak) peak = w
    }
    return peak * 1.08
  }

  property var hover: null

  implicitHeight: Style.space(88)

  function css(c, a) {
    if (!c) return "rgba(0,0,0,0)"
    var alpha = (a === undefined || a === null) ? 1 : a
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + ","
      + Math.round(c.b * 255) + "," + alpha + ")"
  }

  function tsOf(p) {
    var t = Number(p && p.ts)
    if (!isFinite(t) || t <= 0) return 0
    return t > 1e12 ? t / 1000 : t
  }

  function wOf(p) {
    var w = Number(p && p.w)
    return isFinite(w) ? Math.max(0, w) : 0
  }

  function tRange() {
    var list = Array.isArray(root.points) ? root.points : []
    if (list.length === 0) return { t0: 0, t1: 1 }
    var t1 = tsOf(list[list.length - 1])
    var t0 = t1 - 24 * 3600
    var first = tsOf(list[0])
    if (first > 0 && first < t0) t0 = first
    if (!(t1 > t0)) t1 = t0 + 1
    return { t0: t0, t1: t1 }
  }

  function xForTs(ts) {
    var r = tRange()
    var span = plot.width - root.pad * 2
    if (span <= 0) return root.pad
    var x = root.pad + ((ts - r.t0) / (r.t1 - r.t0)) * span
    return Math.max(root.pad, Math.min(plot.width - root.pad, x))
  }

  function yForW(w) {
    var span = plot.height - pad * 2
    if (span <= 0) return plot.height - pad
    var p = maxW > 0 ? Math.max(0, Math.min(1, w / maxW)) : 0
    return pad + (1 - p) * span
  }

  function nearest(mx) {
    var list = Array.isArray(root.points) ? root.points : []
    if (list.length === 0 || plot.width <= 0) return null
    var r = tRange()
    var span = plot.width - pad * 2
    var ts = r.t0 + ((mx - pad) / Math.max(1, span)) * (r.t1 - r.t0)
    var best = 0
    var bestD = Infinity
    for (var i = 0; i < list.length; i++) {
      var d = Math.abs(tsOf(list[i]) - ts)
      if (d < bestD) { bestD = d; best = i }
    }
    var p = list[best]
    var w = wOf(p)
    var t = tsOf(p)
    return { ts: t, w: w, x: xForTs(t), y: yForW(w) }
  }

  function formatTime(ts) {
    var ms = ts * 1000
    var d = new Date(ms)
    if (isNaN(d.getTime())) return ""
    var hh = String(d.getHours()).padStart(2, "0")
    var mm = String(d.getMinutes()).padStart(2, "0")
    return hh + ":" + mm
  }

  function formatHover(h) {
    if (!h) return ""
    return Math.round(h.w) + " W  " + formatTime(h.ts)
  }

  onPointsChanged: plot.requestPaint()
  onLineColorChanged: plot.requestPaint()
  onFillColorChanged: plot.requestPaint()
  onMaxWChanged: plot.requestPaint()
  onWidthChanged: plot.requestPaint()
  onHeightChanged: plot.requestPaint()

  Text {
    textFormat: Text.PlainText
    visible: root.count === 0
    anchors.centerIn: parent
    text: "No 24h samples yet"
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Canvas {
    id: plot
    anchors.fill: parent
    visible: root.count > 0
    antialiasing: true
    renderStrategy: Canvas.Cooperative

    onPaint: {
      var ctx = getContext("2d")
      if (!ctx) return
      ctx.reset()
      var list = Array.isArray(root.points) ? root.points : []
      if (list.length === 0 || width <= 0 || height <= 0) return

      var coords = []
      for (var i = 0; i < list.length; i++) {
        coords.push({ x: root.xForTs(root.tsOf(list[i])), y: root.yForW(root.wOf(list[i])) })
      }

      ctx.lineWidth = 1
      ctx.strokeStyle = root.css(root.lineColor, 0.12)
      ctx.beginPath()
      ctx.moveTo(root.pad, height - root.pad)
      ctx.lineTo(width - root.pad, height - root.pad)
      ctx.stroke()

      var xSpan = coords.length > 1 ? (coords[coords.length - 1].x - coords[0].x) : 0
      if (coords.length > 1 && xSpan > 8) {
        ctx.beginPath()
        ctx.moveTo(coords[0].x, height - root.pad)
        for (var f = 0; f < coords.length; f++) ctx.lineTo(coords[f].x, coords[f].y)
        ctx.lineTo(coords[coords.length - 1].x, height - root.pad)
        ctx.closePath()
        ctx.fillStyle = root.css(root.lineColor, 0.14)
        ctx.fill()

        ctx.beginPath()
        ctx.moveTo(coords[0].x, coords[0].y)
        for (var s = 1; s < coords.length; s++) ctx.lineTo(coords[s].x, coords[s].y)
        ctx.strokeStyle = root.css(root.lineColor, 1)
        ctx.lineWidth = 1.75
        ctx.lineJoin = "round"
        ctx.lineCap = "round"
        ctx.stroke()
      }

      ctx.fillStyle = root.css(root.lineColor, 1)
      for (var d = 0; d < coords.length; d++) {
        ctx.beginPath()
        ctx.arc(coords[d].x, coords[d].y, 2.5, 0, Math.PI * 2)
        ctx.fill()
      }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    enabled: root.count > 0
    onPositionChanged: function(ev) { root.hover = root.nearest(ev.x) }
    onExited: root.hover = null
  }

  Rectangle {
    visible: root.hover !== null
    x: root.hover ? Math.round(root.hover.x) : 0
    width: 1
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    color: Qt.rgba(root.crosshairColor.r, root.crosshairColor.g, root.crosshairColor.b, 0.55)
  }

  Rectangle {
    visible: root.hover !== null
    x: root.hover ? Math.round(root.hover.x - 3) : 0
    y: root.hover ? Math.round(root.hover.y - 3) : 0
    width: 6
    height: 6
    radius: 3
    color: root.crosshairColor
    border.width: 1
    border.color: root.lineColor
  }

  Text {
    id: readout
    textFormat: Text.PlainText
    visible: root.hover !== null
    text: root.formatHover(root.hover)
    color: root.lineColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    x: {
      if (!root.hover) return 0
      var left = root.hover.x + Style.space(8)
      if (left + implicitWidth > root.width - 2) return Math.max(0, root.hover.x - implicitWidth - Style.space(8))
      return left
    }
    y: {
      if (!root.hover) return 0
      var top = root.hover.y - implicitHeight - Style.space(4)
      return top < 0 ? root.hover.y + Style.space(6) : top
    }
  }
}
