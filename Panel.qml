import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Energy: live at-socket watts on the bar, and a panel of consumption
// broken down by day / week / month / year. All figures come from the
// `omaenergy` CLI; this file never reads sysfs or UPower.
//
// Values that originated outside the plugin (CLI labels, formatted
// numbers built from CLI fields) are rendered with Text.PlainText so Qt
// cannot promote a string it thinks looks like markup into rich text.
Panel {
  id: root

  moduleName: "io.github.kevzakaria.energy-meter"
  ipcTarget: "io.github.kevzakaria.energy-meter"

  readonly property string cli: (Quickshell.env("HOME") || "") + "/.local/bin/omaenergy"
  readonly property string iconBolt: "\uF0E7"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color muted: Color.muted
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property color cpuColor: Color.accent
  readonly property color gpuColor: foreground
  readonly property color restColor: Color.muted
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int refreshIntervalSec: Util.clamp(Math.round(Number(setting("refreshIntervalSec", 5))), 2, 60)
  readonly property int highWattThreshold: Util.clamp(Math.round(Number(setting("highWattThreshold", 300))), 50, 2000)
  readonly property string barLabelMode: {
    var m = String(setting("barLabelMode", "watts") || "watts")
    if (m === "todayKwh" || m === "monthKwh") return m
    return "watts"
  }

  // ---------------------------------------------------------------- now

  property string nowStatus: ""
  property real watts: 0
  property real cpuW: 0
  property real gpuW: 0
  property real restW: 0
  property real todayKwh: 0
  property real todayCost: 0
  property real monthKwh: 0
  property real monthCost: 0
  property real uptimeKwh: 0
  property real tariff: 0
  property string currency: "EUR"
  property real sampleAgeS: 0
  property real windowS: 0
  property real intervalS: 0
  property real measuredShare: 0
  property bool hasMeasuredShare: false
  property real baselineW: 0
  property real psuEfficiency: 0
  property bool hasUptime: false
  property bool uptimeTruncated: false

  property bool hasSample: false
  property bool pendingNow: false

  // When the poll produces a fresh reading, and the wall clock as of the last
  // poll tick. Health cannot be derived from exit codes alone: a command that
  // never execs (CLI deleted, not executable, wrong path) creates no process,
  // so `onExited` is never called and Quickshell only logs "Process failed to
  // start". Deriving health from the last exit therefore leaves the last good
  // reading sitting on the bar indefinitely, where it reads as a live
  // measurement of a machine nobody is measuring. A freshness deadline catches
  // that, and every other way a sample can stop arriving -- a hung poll, empty
  // stdout, a stopped daemon -- through the same check.
  property real lastOkMs: 0
  property real clockMs: 0

  readonly property int staleAfterMs: Math.max(refreshIntervalSec * 3, 20) * 1000
  readonly property bool fresh: lastOkMs > 0 && (clockMs - lastOkMs) < staleAfterMs
  readonly property bool healthy: nowStatus === "ok" && fresh
  readonly property bool highDraw: healthy && watts >= highWattThreshold
  readonly property bool verticalBar: !!(bar && bar.vertical)

  // ---------------------------------------------------------- breakdown

  property string granularity: "day"
  property var bucketsCache: ({ day: [], week: [], month: [], year: [] })
  property string bucketsInflight: ""
  property bool pendingBuckets: false
  property var chartPoints: []
  property bool pendingChart: false

  readonly property var visibleBuckets: {
    var cache = bucketsCache || ({})
    var rows = cache[granularity]
    return Array.isArray(rows) ? rows : []
  }
  readonly property real bucketPeak: {
    var rows = visibleBuckets
    var peak = 0
    for (var i = 0; i < rows.length; i++) {
      var k = Number(rows[i] && rows[i].kwh)
      if (isFinite(k) && k > peak) peak = k
    }
    return peak
  }

  readonly property var periodOptions: [
    { value: "day", label: "Day" },
    { value: "week", label: "Week" },
    { value: "month", label: "Month" },
    { value: "year", label: "Year" }
  ]

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: verticalBar ? Style.bar.iconCanvas : button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // ---------------------------------------------------------------- fmt

  function num(v, fallback) {
    var n = Number(v)
    return isFinite(n) ? n : fallback
  }

  function clamp01(v) {
    return Util.clamp(v, 0, 1)
  }

  function plain(s) {
    return String(s || "").replace(/[<>]/g, "")
  }

  function parseJsonObject(text) {
    try {
      var data = JSON.parse(String(text || ""))
      if (!data || typeof data !== "object" || Array.isArray(data)) return null
      return data
    } catch (e) {
      return null
    }
  }

  function currencyPrefix(code) {
    var c = String(code || "EUR").toUpperCase()
    if (c === "EUR") return "\u20AC"
    if (c === "USD") return "$"
    if (c === "GBP") return "\u00A3"
    return c + " "
  }

  function formatCost(value, code) {
    var n = num(value, 0)
    return currencyPrefix(code || currency) + n.toFixed(2)
  }

  function formatKwh(value) {
    var n = num(value, 0)
    if (Math.abs(n) >= 100) return n.toFixed(0) + " kWh"
    if (Math.abs(n) >= 10) return n.toFixed(1) + " kWh"
    return n.toFixed(2) + " kWh"
  }

  function formatWatts(value) {
    return Math.round(num(value, 0)) + " W"
  }

  function formatHours(h) {
    var n = num(h, 0)
    if (n <= 0) return "0 h"
    if (n < 1) return Math.max(1, Math.round(n * 60)) + " min"
    if (n < 10) return n.toFixed(1) + " h"
    return Math.round(n) + " h"
  }

  function formatMeanWindow(s) {
    var n = Number(s)
    if (!isFinite(n) || n <= 0) return "MEAN, LAST INTERVAL"
    return "MEAN, LAST " + Math.round(n) + "S"
  }

  function maxSampleLabel(w) {
    var n = Number(intervalS)
    if (isFinite(n) && n > 0)
      return "max ~" + Math.round(n) + "s " + formatWatts(w)
    return "max sample " + formatWatts(w)
  }


  function todayDate() {
    var now = new Date()
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function formatBucketLabel(period, label) {
    var raw = String(label || "")
    if (period === "day") {
      if (raw === todayDate()) return "Today"
      var parsed = new Date(raw + "T00:00:00")
      if (isNaN(parsed.getTime())) return raw
      var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
      return days[parsed.getDay()] + " " + parsed.getDate()
    }
    if (period === "week") {
      var week = raw.match(/W(\d+)/)
      return week ? ("W" + week[1]) : raw
    }
    if (period === "month") {
      var parts = raw.split("-")
      if (parts.length >= 2) {
        var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var mi = Number(parts[1]) - 1
        if (mi >= 0 && mi < 12) return months[mi] + (parts[0] ? (" " + parts[0]) : "")
      }
      return raw
    }
    return raw
  }

  function bucketTooltip(row) {
    if (!row) return ""
    var parts = [
      plain(String(row.label || "")),
      formatKwh(row.kwh),
      formatCost(row.cost),
      "avg while tracked " + formatWatts(row.avg_w_tracked),
      maxSampleLabel(row.max_sample_w)
    ]
    if (row.coverage < 0.98)
      parts.push("tracked " + formatHours(row.hours) + " (" + Math.round(row.coverage * 100) + "%)")
    parts.push("CPU " + formatKwh(row.cpu_kwh) + " \u00b7 GPU " + formatKwh(row.gpu_kwh) + " \u00b7 rest " + formatKwh(row.rest_kwh))
    return parts.join(" \u00b7 ")
  }

  // `fresh`, not `healthy`, gates the reading. A backend that is reachable but
  // has nothing to say yet still deserves its own status rendering, whereas an
  // unreachable one has no current number at all -- and a dimmed stale wattage
  // is still a wattage someone will read as the machine's draw right now. An
  // em-dash cannot be misread that way.
  readonly property string barText: {
    if (verticalBar) return ""
    if (!hasSample || !fresh) return iconBolt + " \u2014"
    if (barLabelMode === "todayKwh") return iconBolt + " " + formatKwh(todayKwh)
    if (barLabelMode === "monthKwh") return iconBolt + " " + formatKwh(monthKwh)
    return iconBolt + " " + formatWatts(watts)
  }

  readonly property string verticalValue: {
    if (!hasSample || !fresh) return ""
    if (barLabelMode === "todayKwh") return formatKwh(todayKwh).replace(" kWh", "")
    if (barLabelMode === "monthKwh") return formatKwh(monthKwh).replace(" kWh", "")
    return String(Math.round(watts))
  }

  readonly property var verticalLines: {
    if (!verticalBar) return []
    if (verticalValue === "") return [iconBolt]
    return [iconBolt, verticalValue]
  }

  readonly property string tooltipText: {
    if (!hasSample)
      return "Energy meter unavailable"
    var t = "Today " + formatKwh(todayKwh) + " \u00b7 " + formatCost(todayCost)
      + "\nMonth " + formatKwh(monthKwh) + " \u00b7 " + formatCost(monthCost)
    if (hasUptime)
      t += "\nUptime " + formatKwh(uptimeKwh) + (uptimeTruncated ? " (partial)" : "")
    return t
  }

  readonly property string footerText: {
    var caveat = "CPU from a true energy counter; GPU is an integrated power estimate. The rest of the machine is an estimate. Treat the total as +/-15-20% of a wall meter; trends are accurate."
    var rate = "Tariff " + formatCost(tariff) + "/kWh \u2014 set in the energy backend config."
    return caveat + " " + rate
  }

  readonly property string heroMeta: {
    if (!healthy) return hasSample ? "LAST SAMPLE" : "NO DATA"
    return formatMeanWindow(windowS)
  }

  readonly property string measuredShareText: {
    if (!hasMeasuredShare) return ""
    return Math.round(clamp01(measuredShare) * 100) + "% measured"
  }

  readonly property string measuredShareTip: {
    var rest = "the configured baseline estimate plus PSU loss"
    var nBase = Number(baselineW)
    var nPsu = Number(psuEfficiency)
    if (isFinite(nBase) && nBase > 0 && isFinite(nPsu) && nPsu > 0)
      rest = "the configured " + formatWatts(nBase) + " baseline plus PSU loss (" + Math.round(nPsu * 100) + "% efficiency)"
    else if (isFinite(nBase) && nBase > 0)
      rest = "the configured " + formatWatts(nBase) + " baseline plus PSU loss"
    return "The remainder of this reading is " + rest + ". Calibrate these in the energy backend config."
  }

  // ----------------------------------------------------------- persist

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings)
      if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function cycleBarLabel() {
    var next = "watts"
    if (barLabelMode === "watts") next = "todayKwh"
    else if (barLabelMode === "todayKwh") next = "monthKwh"
    persistSettings({ barLabelMode: next })
  }

  function cycleGranularity(dx) {
    var order = ["day", "week", "month", "year"]
    var i = order.indexOf(granularity)
    if (i < 0) i = 0
    var next = order[(i + dx + order.length) % order.length]
    if (next === granularity) return
    granularity = next
    pollBuckets()
  }

  // ------------------------------------------------------------- poll

  function pollNow() {
    if (nowProc.running) {
      pendingNow = true
      return
    }
    nowProc.running = true
  }

  function pollChart() {
    if (!root.opened) return
    if (chartProc.running) {
      pendingChart = true
      return
    }
    chartProc.running = true
  }

  function bucketsArgv() {
    if (granularity === "week") return [cli, "week", "--json", "-n", "6"]
    if (granularity === "month") return [cli, "month", "--json", "-n", "6"]
    if (granularity === "year") return [cli, "year", "--json", "-n", "0"]
    return [cli, "day", "--json", "-n", "7"]
  }

  function pollBuckets() {
    if (!root.opened) return
    if (bucketsProc.running) {
      pendingBuckets = true
      return
    }
    bucketsInflight = granularity
    bucketsProc.command = bucketsArgv()
    bucketsProc.running = true
  }

  function refreshPanelData() {
    pollChart()
    pollBuckets()
  }

  function applyNow(text) {
    var data = parseJsonObject(text)
    if (!data) {
      nowStatus = "error"
      return
    }
    nowStatus = String(data.status || "error")
    // A parseable payload is a live backend, whatever it has to report. The
    // deadline is armed here rather than on the reply's own `status` so a
    // backend that is up but has nothing yet ("no_data") is still recognised
    // as reachable, and only the status decides how it renders.
    lastOkMs = Date.now()
    clockMs = lastOkMs
    if (data.currency) currency = String(data.currency)
    tariff = num(data.tariff, tariff)
    if (data.baseline_w !== undefined) baselineW = num(data.baseline_w, baselineW)
    if (data.psu_efficiency !== undefined) psuEfficiency = num(data.psu_efficiency, psuEfficiency)
    // Absence of `watts` (or an explicit no_data status) is not a reading of
    // zero — it is no sample. Leave last live numbers untouched but stop
    // presenting them.
    if (nowStatus === "no_data" || data.watts === undefined) {
      hasSample = false
      return
    }
    var w = num(data.watts, NaN)
    if (!isFinite(w)) {
      hasSample = false
      return
    }
    watts = w
    cpuW = num(data.cpu_w, 0)
    gpuW = num(data.gpu_w, 0)
    restW = num(data.rest_w, 0)
    todayKwh = num(data.today_kwh, 0)
    todayCost = num(data.today_cost, 0)
    monthKwh = num(data.month_kwh, 0)
    monthCost = num(data.month_cost, 0)
    if (data.uptime_kwh !== undefined) {
      uptimeKwh = num(data.uptime_kwh, 0)
      hasUptime = true
      uptimeTruncated = !!data.uptime_truncated
    }
    sampleAgeS = num(data.sample_age_s, 0)
    if (data.window_s !== undefined) windowS = num(data.window_s, 0)
    if (data.interval_s !== undefined) intervalS = num(data.interval_s, 0)
    if (data.measured_share !== undefined) {
      var share = num(data.measured_share, NaN)
      hasMeasuredShare = isFinite(share)
      if (hasMeasuredShare) measuredShare = clamp01(share)
    } else {
      hasMeasuredShare = false
    }
    hasSample = true
  }

  function applyChart(text) {
    var data = parseJsonObject(text)
    if (!data || data.status !== "ok" || !Array.isArray(data.points))
      return
    var out = []
    for (var i = 0; i < data.points.length; i++) {
      var p = data.points[i] || {}
      var ts = num(p.ts, 0)
      var w = num(p.w, NaN)
      if (ts > 0 && isFinite(w)) out.push({ ts: ts, w: w })
    }
    chartPoints = out
  }

  function applyBuckets(text) {
    var period = bucketsInflight || granularity
    var data = parseJsonObject(text)
    if (!data || data.status !== "ok" || !Array.isArray(data.buckets))
      return
    if (data.currency) currency = String(data.currency)
    var rows = []
    for (var i = 0; i < data.buckets.length; i++) {
      var b = data.buckets[i] || {}
      rows.push({
        label: String(b.label || ""),
        kwh: num(b.kwh, 0),
        cost: num(b.cost, 0),
        avg_w_tracked: num(b.avg_w_tracked, 0),
        max_sample_w: num(b.max_sample_w, 0),
        hours: num(b.hours, 0),
        coverage: clamp01(num(b.coverage, 0)),
        cpu_kwh: num(b.cpu_kwh, 0),
        gpu_kwh: num(b.gpu_kwh, 0),
        rest_kwh: num(b.rest_kwh, 0)
      })
    }
    bucketsCache = {
      day: period === "day" ? rows : (bucketsCache.day || []),
      week: period === "week" ? rows : (bucketsCache.week || []),
      month: period === "month" ? rows : (bucketsCache.month || []),
      year: period === "year" ? rows : (bucketsCache.year || [])
    }
  }

  onOpenedChanged: {
    if (opened) {
      refreshPanelData()
      if (panelFlick) panelFlick.contentY = 0
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    // Advancing the clock here, not in a second timer, ties the freshness check
    // to the poll cadence: every tick either lands a sample and re-arms the
    // deadline, or moves the clock closer to it.
    onTriggered: {
      root.clockMs = Date.now()
      root.pollNow()
    }
  }

  Timer {
    interval: Math.max(root.refreshIntervalSec, 15) * 1000
    running: root.opened
    repeat: true
    onTriggered: root.refreshPanelData()
  }

  Process {
    id: nowProc
    command: [root.cli, "now", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyNow(text)
    }
    onExited: function(code) {
      if (code !== 0) {
        root.nowStatus = "error"
        root.pendingNow = false
        return
      }
      if (root.pendingNow) {
        root.pendingNow = false
        Qt.callLater(root.pollNow)
      }
    }
  }

  Process {
    id: chartProc
    command: [root.cli, "chart", "--json", "--hours", "24"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyChart(text)
    }
    onExited: function(code) {
      if (code !== 0) {
        root.chartPoints = []
        root.pendingChart = false
        return
      }
      if (root.pendingChart) {
        root.pendingChart = false
        if (root.opened) Qt.callLater(root.pollChart)
      }
    }
  }

  Process {
    id: bucketsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyBuckets(text)
    }
    onExited: function(code) {
      if (code !== 0) {
        root.pendingBuckets = false
        return
      }
      if (root.pendingBuckets) {
        root.pendingBuckets = false
        if (root.opened) Qt.callLater(root.pollBuckets)
      }
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    labelVisible: !root.verticalBar
    hasVisualContent: true
    dimmed: !root.healthy
    active: root.highDraw
    useActiveColor: root.highDraw
    foreground: root.highDraw ? root.urgent : root.foreground
    tooltipText: root.plain(root.tooltipText)
    horizontalMargin: 8.75
    verticalPadding: 8.75
    fixedHeight: root.verticalBar ? root.verticalLines.length * Style.bar.iconSlot : -1

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleBarLabel()
      else root.toggle()
    }

    Column {
      visible: root.verticalBar
      anchors.fill: parent

      Repeater {
        model: root.verticalLines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3 ? button.fontSize * 0.9 : button.fontSize
          color: button.foreground
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.cycleGranularity(dx)
        if (dy !== 0 && panelFlick)
          panelFlick.contentY = Util.clamp(
            panelFlick.contentY + dy * Style.space(56),
            0,
            Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshPanelData()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") {
          root.pollNow()
          root.refreshPanelData()
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero ----------
          Row {
            width: parent.width
            spacing: Style.space(12)

            Text {
              textFormat: Text.PlainText
              text: root.iconBolt
              color: root.healthy ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              spacing: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                textFormat: Text.PlainText
                text: root.hasSample ? root.formatWatts(root.watts) : "\u2014"
                color: root.highDraw ? root.urgent : (root.healthy ? root.foreground : root.dim)
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                text: root.heroMeta
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
              }

              Item {
                visible: root.hasSample && root.hasMeasuredShare
                width: measuredShareText.implicitWidth
                height: measuredShareText.implicitHeight

                Text {
                  id: measuredShareText
                  textFormat: Text.PlainText
                  text: root.measuredShareText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  id: measuredHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton
                }

                PanelToolTip {
                  visible: measuredHover.containsMouse && root.measuredShareTip !== ""
                  text: root.measuredShareTip
                  fontFamily: root.fontFamily
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.hasSample && root.hasUptime
                text: "Uptime " + root.formatKwh(root.uptimeKwh) + (root.uptimeTruncated ? " (partial)" : "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          SplitMeter {
            width: parent.width
            visible: root.hasSample
            cpuW: root.cpuW
            gpuW: root.gpuW
            restW: root.restW
            watts: root.watts
            opacity: root.healthy ? 1 : 0.45
          }

          Row {
            width: parent.width
            spacing: Style.space(14)
            visible: root.hasSample

            LegendDot { swatch: root.cpuColor; text: "CPU " + root.formatWatts(root.cpuW) }
            LegendDot { swatch: root.gpuColor; text: "GPU " + root.formatWatts(root.gpuW) }
            LegendDot { swatch: root.restColor; text: "rest " + root.formatWatts(root.restW) }
          }

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            width: parent.width
            text: "LAST 24H"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Sparkline {
            width: parent.width
            points: root.chartPoints
            lineColor: root.foreground
            crosshairColor: root.accent
            dim: root.dim
            fontFamily: root.fontFamily
          }

          PanelSeparator { foreground: root.foreground }

          ButtonGroup {
            width: parent.width
            options: root.periodOptions
            value: root.granularity
            focusable: false
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onChanged: function(v) {
              if (v === root.granularity) return
              root.granularity = v
              root.pollBuckets()
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.visibleBuckets.length > 0

            Repeater {
              model: root.visibleBuckets

              Bucket {
                required property var modelData
                width: column.width
                label: root.formatBucketLabel(root.granularity, modelData.label)
                ratio: root.bucketPeak > 0 ? (Number(modelData.kwh) / root.bucketPeak) : 0
                kwhText: root.formatKwh(modelData.kwh)
                costText: root.formatCost(modelData.cost)
                partial: Number(modelData.coverage) < 0.98
                tooltipText: root.bucketTooltip(modelData)
                foreground: root.foreground
                dim: root.dim
                track: root.track
                fontFamily: root.fontFamily
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.visibleBuckets.length === 0
            width: parent.width
            text: "No data for this period yet"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignLeft
          }
        }
      }
    }
  }

  component LegendDot: Row {
    property color swatch: Color.foreground
    property string text: ""
    spacing: Style.space(6)

    Rectangle {
      width: Style.space(8)
      height: Style.space(8)
      radius: width / 2
      color: swatch
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      textFormat: Text.PlainText
      text: parent.text
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component SplitMeter: Item {
    id: split
    property real cpuW: 0
    property real gpuW: 0
    property real restW: 0
    property real watts: 0
    // Scale to the hero total, not to the sum of segments — the three parts
    // now add up to `watts` at the socket, so the bar fills without a fudge.
    readonly property real scale: Math.max(0, watts)
    implicitHeight: Math.max(Style.space(8), Math.round(Style.spacing.controlHeight * 0.28))

    Rectangle {
      id: splitTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
      clip: true

      Row {
        anchors.fill: parent
        visible: split.scale > 0

        Rectangle {
          height: parent.height
          width: split.scale > 0 ? parent.width * (Math.max(0, split.cpuW) / split.scale) : 0
          color: root.cpuColor
        }
        Rectangle {
          height: parent.height
          width: split.scale > 0 ? parent.width * (Math.max(0, split.gpuW) / split.scale) : 0
          color: root.gpuColor
        }
        Rectangle {
          height: parent.height
          width: split.scale > 0 ? parent.width * (Math.max(0, split.restW) / split.scale) : 0
          color: root.restColor
        }
      }
    }
  }
}
