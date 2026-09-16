import QtQuick
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
  // The base Panel registers open/close/show/hide/toggle on `ipcTarget`. We
  // take that over to add `settings`, so the config pane is reachable without
  // hunting for the gear -- bindable from Hyprland, and scriptable:
  //   omarchy-shell io.github.kevzakaria.energy-meter settings
  manageIpc: false

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // Opens the panel if needed, then shows the config pane, so one call
    // lands on settings from any starting state.
    function settings(): void {
      if (!root.opened) root.open()
      root.openConfig()
    }
  }

  readonly property string cli: (Quickshell.env("HOME") || "") + "/.local/bin/omaenergy"
  readonly property string iconBolt: "\uF0E7"
  readonly property string iconCog: "\uF013"
  readonly property string iconBack: "\uF060"
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
  property string currencySymbol: ""
  property int costDecimals: 2
  property bool hasCurrencyMeta: false

  // Price and currency live only in the backend config file. Do not add
  // them to manifest.json's barWidget.schema: that would write a second
  // copy into shell.json that omaenergy would ignore. Read them from the
  // `now` payload for display; write through `omaenergy config`.
  property bool configOpen: false
  property bool configSaving: false
  property int configEpoch: 0
  property int configFocusCount: 0
  property var configValues: ({})
  property var configDrafts: ({})
  property var configErrors: ({})
  property string configSaveError: ""
  property bool restartRequired: false
  // What the last save wrote, and whether to still be saying so. A successful
  // save used to change nothing on screen: the error path had a message, the
  // success path had none, and because this pane covers the panel body the
  // recomputed cost was not visible either. So a save looked identical to a
  // dead button.
  property string configSavedKeys: ""
  property bool configSavedShown: false
  // Whether the last save moved existing figures or only future sampling. The
  // two deserve different sentences: one is already true, the other is a
  // promise pending a restart.
  property bool retroactiveSave: false
  readonly property var retroactiveKeys: [
    "tariff", "currency", "currency_symbol", "cost_decimals",
    "baseline_w", "psu_efficiency"
  ]
  readonly property bool configFieldFocused: configFocusCount > 0
  property int configDraftGen: 0

  // Currencies are fetched once per shell session, the first time the
  // settings pane opens — not at widget construction and not on the
  // `now` poll. An empty or failed list falls back to the free-text
  // field so a broken picker cannot lock the user out.
  property var currencyOptions: []
  property bool currenciesLoaded: false
  property bool currenciesFailed: false
  property bool currenciesLoading: false
  property bool currencyPopupOpen: false



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

  function applyCurrencyMeta(data) {
    if (!data) return
    if (data.currency) currency = String(data.currency)
    var symbol = data.currency_symbol
    var decimals = data.cost_decimals
    var haveSymbol = symbol !== undefined && symbol !== null && String(symbol) !== ""
    var d = num(decimals, NaN)
    var haveDecimals = decimals !== undefined && decimals !== null && isFinite(d)
    if (haveSymbol && haveDecimals) {
      currencySymbol = String(symbol)
      costDecimals = Math.max(0, Math.min(6, Math.round(d)))
      hasCurrencyMeta = true
    }
  }

  function groupThousands(intStr) {
    var n = String(intStr || "0")
    var out = ""
    while (n.length > 3) {
      out = "," + n.substring(n.length - 3) + out
      n = n.substring(0, n.length - 3)
    }
    return n + out
  }

  function formatMoneyNumber(value, decimals) {
    var n = num(value, 0)
    var d = Math.max(0, Math.min(6, Math.round(num(decimals, 2))))
    var sign = n < 0 ? "-" : ""
    var abs = Math.abs(n)
    var parts = abs.toFixed(d).split(".")
    var grouped = groupThousands(parts[0])
    if (d > 0 && parts.length > 1)
      return sign + grouped + "." + parts[1]
    return sign + grouped
  }

  function formatCost(value) {
    var n = num(value, 0)
    if (!hasCurrencyMeta)
      return formatMoneyNumber(n, 2) + " " + String(currency || "EUR")
    var body = formatMoneyNumber(n, costDecimals)
    var symbol = String(currencySymbol || "")
    if (symbol.length === 1)
      return symbol + body
    return symbol + " " + body
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

  readonly property string accuracyNote: "CPU is a hardware energy counter; GPU is an integrated estimate. Baseline and PSU efficiency stand in for the rest, so the total is ±15–20% of a wall meter. Trends are accurate."

  readonly property var configMoneyFields: [
    { key: "tariff", label: "Tariff", unit: "/kWh", blurb: "price per kWh", kind: "number" },
    { key: "currency", label: "Currency", unit: "", blurb: "ISO 4217 code. The list is not exhaustive.", kind: "currency" },
    { key: "currency_symbol", label: "Symbol", unit: "", blurb: "override the symbol; empty means auto", kind: "text" },
    { key: "cost_decimals", label: "Decimals", unit: "", blurb: "decimal places for money; auto by currency", kind: "autoNumber" }
  ]
  readonly property var configEstimateFields: [
    { key: "baseline_w", label: "Baseline", unit: "W", blurb: "estimated draw of everything without a sensor", kind: "number" },
    { key: "psu_efficiency", label: "PSU efficiency", unit: "", blurb: "AC->DC efficiency, 0.3-1.0", kind: "number" }
  ]
  readonly property var configRestartFields: [
    { key: "interval_s", label: "Sample interval", unit: "s", blurb: "seconds per stored sample", kind: "number" },
    { key: "gpu_interval_s", label: "GPU interval", unit: "s", blurb: "GPU sub-sample spacing; sets GPU accuracy", kind: "number" },
    { key: "raw_retention_days", label: "Raw retention", unit: "days", blurb: "how long per-sample rows are kept", kind: "number" },
    { key: "sanity_max_cpu_w", label: "CPU sanity cap", unit: "W", blurb: "package draw above this is a counter reset", kind: "number" },
    { key: "gpu_source", label: "GPU source", unit: "", blurb: "auto | off | an explicit hwmon path", kind: "text" }
  ]


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
    return "The remainder of this reading is " + rest + ". Open settings (gear) to calibrate."
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
  function configLoadedText(key) {
    if (!configValues || configValues[key] === undefined || configValues[key] === null)
      return ""
    return String(configValues[key])
  }

  function configFieldError(key) {
    if (!configErrors || configErrors[key] === undefined || configErrors[key] === null)
      return ""
    return String(configErrors[key])
  }

  function setConfigDraft(key, value) {
    if (!configDrafts) configDrafts = ({})
    configDrafts[key] = value
    configDraftGen += 1
  }

  function allConfigFields() {
    return configMoneyFields.concat(configEstimateFields).concat(configRestartFields)
  }

  function applyConfigList(text) {
    var data = parseJsonObject(text)
    if (!data) return
    configValues = data
    var drafts = ({})
    var fields = allConfigFields()
    for (var i = 0; i < fields.length; i++) {
      var k = fields[i].key
      drafts[k] = configLoadedText(k)
    }
    configDrafts = drafts
    configErrors = ({})
    configEpoch += 1
  }

  function loadConfig() {
    if (loadConfigProc.running) return
    loadConfigProc.command = [root.cli, "config", "--json"]
    loadConfigProc.running = true
  }

  function openConfig() {
    configOpen = true
    configSaveError = ""
    restartRequired = false
    configFocusCount = 0
    loadConfig()
    loadCurrencies()
    if (panelFlick) panelFlick.contentY = 0
  }

  function closeConfig() {
    if (root.bar) root.bar.hideTooltip(gearHit)
    configOpen = false
    configFocusCount = 0
    currencyPopupOpen = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function toggleConfig() {
    if (configOpen) closeConfig()
    else openConfig()
  }

  function valuesEqual(spec, draft, original) {
    var a = String(draft || "").trim()
    var emptyOrig = original === undefined || original === null || String(original) === ""
    if (spec.kind === "number" || spec.kind === "autoNumber") {
      if (a === "" && emptyOrig) return true
      if (a === "" || emptyOrig) return a === "" && emptyOrig
      var dn = Number(a.replace(",", "."))
      var on = Number(original)
      if (isFinite(dn) && isFinite(on)) return dn === on
    }
    return a === String(original === undefined || original === null ? "" : original).trim()
  }

  function commitConfig() {
    if (configSaving || saveConfigProc.running) return
    var errors = ({})
    var pairs = []
    var fields = allConfigFields()
    var hasErr = false
    for (var i = 0; i < fields.length; i++) {
      var spec = fields[i]
      var draft = String((configDrafts && configDrafts[spec.key]) || "").trim()
      if ((spec.kind === "number" || spec.kind === "autoNumber") && draft !== "") {
        if (!isFinite(Number(draft.replace(",", ".")))) {
          errors[spec.key] = "must be a number"
          hasErr = true
          continue
        }
      }
      var orig = configValues ? configValues[spec.key] : undefined
      if (valuesEqual(spec, draft, orig)) continue
      pairs.push(spec.key + "=" + draft)
    }
    configErrors = errors
    configSaveError = ""
    configSavedShown = false
    if (hasErr) return
    if (pairs.length === 0) {
      // Clicking Save with nothing changed used to be a silent no-op, which is
      // the same non-event as a broken button. Say so instead.
      configSavedKeys = ""
      configSavedShown = true
      savedNoteTimer.restart()
      return
    }
    // Keys only, for the confirmation. Values are already on screen in their
    // fields, and a tariff does not need repeating back.
    var keys = []
    for (var k = 0; k < pairs.length; k++) keys.push(pairs[k].split("=")[0])
    configSavedKeys = keys.join(", ")
    configSaving = true
    restartRequired = false
    // argv array, not a concatenated shell string: a currency code or
    // hwmon path is untrusted keystrokes, and execvp-style argv cannot
    // turn it into extra words or operators. bar.shellQuote is the
    // fallback only if we had to go through bash -c.
    var cmd = [root.cli, "config", "--json"]
    for (var j = 0; j < pairs.length; j++) cmd.push(pairs[j])
    saveConfigProc.command = cmd
    saveConfigProc.running = true
  }

  function applyConfigSave(code) {
    configSaving = false
    if (code !== 0) {
      var err = String(saveConfigErr.text || "").trim()
      if (!err) err = String(saveConfigOut.text || "").trim()
      if (!err) err = "could not save settings"
      var line = err.split("\n")[err.split("\n").length - 1]
      var m = line.match(/^omaenergy:\s*([a-z_]+):\s*(.*)$/)
      if (m) {
        var fieldErrs = ({})
        fieldErrs[m[1]] = m[2]
        configErrors = fieldErrs
        configSaveError = ""
      } else {
        configSaveError = line.replace(/^omaenergy:\s*/, "")
      }
      return
    }
    configErrors = ({})
    configSaveError = ""
    var data = parseJsonObject(saveConfigOut.text)
    restartRequired = !!(data && data.restart_required)
    // Name the keys the backend says it wrote, not the ones we sent. They are
    // the same set today, and when they are not, the file is the fact.
    var written = (data && data.updated && typeof data.updated === "object")
      ? Object.keys(data.updated) : []
    if (written.length > 0) configSavedKeys = written.join(", ")
    retroactiveSave = false
    for (var r = 0; r < written.length; r++) {
      if (retroactiveKeys.indexOf(written[r]) !== -1) {
        retroactiveSave = true
        break
      }
    }
    // Retroactive keys re-derive every stored day, so refresh now and
    // the open breakdown together rather than waiting for the poll.
    pollNow()
    refreshPanelData()
    loadConfig()
    configSavedShown = true
    savedNoteTimer.restart()
  }

  function restartSampler() {
    // Absolute path, not `systemctl`: this string is handed to the bar's
    // shell, which resolves a bare name through the PATH the long-lived
    // shell process happens to have inherited. A writable directory earlier
    // in that PATH is all it takes for someone else's binary to be what a
    // user's click on "restart the sampler" actually runs. systemd is not
    // optional on this distribution, so /usr/bin/systemctl is where it is;
    // if it is ever not, the restart fails instead of falling back to a
    // search, and the widget's freshness deadline reports a sampler that
    // stopped producing readings.
    if (root.bar && typeof root.bar.run === "function")
      root.bar.run("/usr/bin/systemctl --user restart omarchy-energy")
    restartRequired = false
  }
  function parseJsonArray(text) {
    try {
      var data = JSON.parse(String(text || ""))
      if (!Array.isArray(data)) return null
      return data
    } catch (e) {
      return null
    }
  }

  function formatCurrencyExample(symbol, decimals) {
    var body = formatMoneyNumber(1234, decimals)
    var s = String(symbol || "")
    if (s.length === 1) return s + body
    return s + " " + body
  }

  function currencyInList(code) {
    var c = String(code || "").trim().toUpperCase()
    if (!c) return false
    var opts = currencyOptions || []
    for (var i = 0; i < opts.length; i++) {
      if (String(opts[i].value).toUpperCase() === c) return true
    }
    return false
  }

  readonly property string currencyOverrideHint: {
    var _ = configDraftGen
    var sym = String((configDrafts && configDrafts.currency_symbol) || "").trim()
    var dec = String((configDrafts && configDrafts.cost_decimals) || "").trim()
    if (sym === "" && dec === "") return ""
    var bits = []
    if (sym !== "") bits.push("symbol " + sym)
    if (dec !== "") bits.push(dec + " decimal place" + (dec === "1" ? "" : "s"))
    return "Override in effect: " + bits.join(", ") + " wins over this currency's default."
  }

  function loadCurrencies() {
    if (currenciesLoaded || currenciesLoading || loadCurrenciesProc.running) return
    currenciesLoading = true
    currenciesFailed = false
    loadCurrenciesProc.command = [root.cli, "currencies", "--json"]
    loadCurrenciesProc.running = true
  }

  function applyCurrencies(text) {
    currenciesLoading = false
    var data = parseJsonArray(text)
    if (!data || data.length === 0) {
      currenciesFailed = true
      currencyOptions = []
      currenciesLoaded = false
      return
    }
    var opts = []
    for (var i = 0; i < data.length; i++) {
      var row = data[i]
      if (!row || row.code === undefined || row.code === null) continue
      var code = String(row.code).trim()
      if (!code) continue
      var symbol = (row.symbol !== undefined && row.symbol !== null && String(row.symbol) !== "")
        ? String(row.symbol) : code
      var decimals = num(row.decimals, 2)
      var example = formatCurrencyExample(symbol, decimals)
      opts.push({
        value: code,
        label: code + " \u00b7 " + symbol + " \u00b7 " + example
      })
    }
    if (opts.length === 0) {
      currenciesFailed = true
      currencyOptions = []
      currenciesLoaded = false
      return
    }
    currencyOptions = opts
    currenciesLoaded = true
    currenciesFailed = false
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
    applyCurrencyMeta(data)
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
    applyCurrencyMeta(data)
    if (data.tariff !== undefined) tariff = num(data.tariff, tariff)
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
    } else if (configOpen) {
      closeConfig()
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

  // The confirmation is transient on purpose. A permanent "Saved" banner stops
  // meaning anything after the second glance, and the settings pane is a place
  // people pass through rather than watch.
  Timer {
    id: savedNoteTimer
    interval: 6000
    onTriggered: root.configSavedShown = false
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
  Process {
    id: loadConfigProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyConfigList(text)
    }
  }

  Process {
    id: saveConfigProc
    stdout: StdioCollector {
      id: saveConfigOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: saveConfigErr
      waitForEnd: true
    }
    onExited: function(code) { root.applyConfigSave(code) }
  }
  Process {
    id: loadCurrenciesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyCurrencies(text)
    }
    onExited: function(code) {
      root.currenciesLoading = false
      if (code !== 0 && !root.currenciesLoaded) {
        root.currenciesFailed = true
        root.currencyOptions = []
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
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.configFieldFocused || root.currencyPopupOpen
      onMoveRequested: function(dx, dy) {
        if (root.configOpen) {
          if (dy !== 0 && panelFlick)
            panelFlick.contentY = Util.clamp(
              panelFlick.contentY + dy * Style.space(56),
              0,
              Math.max(0, panelFlick.contentHeight - panelFlick.height))
          return
        }
        if (dx !== 0) root.cycleGranularity(dx)
        if (dy !== 0 && panelFlick)
          panelFlick.contentY = Util.clamp(
            panelFlick.contentY + dy * Style.space(56),
            0,
            Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: {
        // Enter inside a field already saves. This is the same key with the
        // pane open and no field focused, which otherwise did nothing at all.
        if (root.configOpen) root.commitConfig()
        else root.refreshPanelData()
      }
      onCloseRequested: {
        if (root.configOpen) root.closeConfig()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.configOpen) return
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

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero ----------
          Item {
            width: parent.width
            height: Math.max(heroRow.height, gearHit.height)

            Row {
              id: heroRow
              anchors.left: parent.left
              anchors.right: gearHit.left
              anchors.rightMargin: Style.space(8)
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

            Item {
              id: gearHit
              anchors.right: parent.right
              anchors.top: parent.top
              width: Style.space(28)
              height: Style.space(28)

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: root.iconCog
                color: root.foreground
                opacity: gearHover.containsMouse || root.configOpen ? 0.95 : 0.38
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                id: gearHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: if (root.bar) root.bar.showTooltip(gearHit, "Settings")
                onExited: if (root.bar) root.bar.hideTooltip(gearHit)
                onClicked: root.toggleConfig()
              }
            }
          }

          Column {
            visible: !root.configOpen
            width: parent.width
            spacing: Style.space(12)

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
                  fontFamily: root.fontFamily
                  dim: root.dim
                  track: root.track
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
          }

          Column {
            visible: root.configOpen
            width: parent.width
            spacing: Style.space(10)

            Row {
              spacing: Style.space(8)

              Item {
                width: Style.space(22)
                height: Style.space(22)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: root.iconBack
                  color: root.foreground
                  opacity: backHover.containsMouse ? 0.95 : 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  id: backHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.closeConfig()
                }
              }

              Text {
                textFormat: Text.PlainText
                text: "SETTINGS"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            PanelSectionHeader {
              width: parent.width
              text: "APPLIES TO ALL HISTORY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Saving these re-prices every stored day immediately."
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.configMoneyFields
              ConfigRow {
                required property var modelData
                width: column.width
                spec: modelData
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              topPadding: Style.space(4)
              text: root.accuracyNote
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.configEstimateFields
              ConfigRow {
                required property var modelData
                width: column.width
                spec: modelData
              }
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              width: parent.width
              text: "NEEDS A DAEMON RESTART"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.configRestartFields
              ConfigRow {
                required property var modelData
                width: column.width
                spec: modelData
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.configSaveError !== ""
              width: parent.width
              text: root.configSaveError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // A confirmation that proves the value is live, not just written.
            // "Saved" alone asks to be trusted; naming the figure the save just
            // moved lets the user check it. The whole point of a retroactive
            // tariff is that today's cost changes the instant it lands, and
            // this pane is covering the place that number is normally shown.
            Text {
              textFormat: Text.PlainText
              visible: root.configSavedShown && root.configSaveError === ""
              width: parent.width
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              text: {
                if (root.configSavedKeys === "")
                  return "Nothing to save: no value changed."
                var head = "Saved " + root.configSavedKeys + "."
                // One save can touch both kinds of key, so the clauses are
                // additive rather than exclusive. The restart clause follows
                // the button's own condition: a sentence pointing at a button
                // that is not rendered is worse than no sentence.
                if (root.retroactiveSave)
                  head += " Applied to the whole history: today now reads "
                    + root.formatKwh(root.todayKwh) + " / " + root.formatCost(root.todayCost) + "."
                if (root.restartRequired)
                  head += " Sampling changes need the restart below."
                return head
              }
            }

            Row {
              spacing: Style.space(8)

              Button {
                text: root.configSaving ? "Saving" : "Save"
                enabled: !root.configSaving
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                verticalPadding: Style.space(2)
                horizontalPadding: Style.space(10)
                onClicked: root.commitConfig()
              }

              Button {
                visible: root.restartRequired
                text: "Restart sampler"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                verticalPadding: Style.space(2)
                horizontalPadding: Style.space(10)
                onClicked: root.restartSampler()
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.restartRequired
              width: parent.width
              text: "systemctl --user restart omarchy-energy"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }

  component ConfigRow: Column {
    id: cfg
    property var spec: ({})
    property bool customOpen: false
    width: parent ? parent.width : 0
    spacing: Style.space(2)

    readonly property string key: spec && spec.key ? String(spec.key) : ""
    readonly property string kind: spec && spec.kind ? String(spec.kind) : "text"
    readonly property bool usePicker: kind === "currency" && root.currenciesLoaded
    property bool currenciesReady: root.currenciesLoaded
    onCurrenciesReadyChanged: if (kind === "currency") syncEditors()

    function syncEditors() {
      var current = ""
      if (root.configDrafts && root.configDrafts[cfg.key] !== undefined)
        current = String(root.configDrafts[cfg.key])
      else
        current = root.configLoadedText(cfg.key)
      field.text = current
      if (cfg.kind === "currency") {
        currencyPicker.value = current
        currencyCustomField.text = current
        if (root.currenciesLoaded)
          cfg.customOpen = current !== "" && !root.currencyInList(current)
      }
    }

    function commitCurrency(code) {
      var v = String(code || "")
      root.setConfigDraft("currency", v)
      if (field.text !== v) field.text = v
      if (currencyCustomField.text !== v) currencyCustomField.text = v
      if (currencyPicker.value !== v) currencyPicker.value = v
    }

    Row {
      width: parent.width
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        width: Style.space(118)
        text: cfg.spec && cfg.spec.label ? String(cfg.spec.label) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
      }

      SearchableDropdown {
        id: currencyPicker
        visible: cfg.usePicker
        width: visible ? Math.min(Style.spacing.searchableDropdownWidth, Math.max(Style.space(150), cfg.width - Style.space(126))) : 0
        height: visible ? implicitHeight : 0
        showLabel: false
        enabled: !root.configSaving
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        placeholderText: "Search currencies..."
        emptyText: "No matches"
        options: root.currencyOptions
        onPopupOpenChanged: if (cfg.kind === "currency") root.currencyPopupOpen = popupOpen
        onVisibleChanged: if (!visible) close()
        onChanged: function(v) {
          if (cfg.kind !== "currency") return
          cfg.commitCurrency(v)
          cfg.customOpen = !root.currencyInList(v)
        }
      }

      TextField {
        id: field
        visible: !cfg.usePicker
        width: Style.space(150)
        enabled: !root.configSaving
        placeholderText: cfg.kind === "autoNumber" ? "auto" : ""
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        verticalPadding: Style.space(2)
        inputMethodHints: (cfg.kind === "number" || cfg.kind === "autoNumber") ? Qt.ImhFormattedNumbersOnly : Qt.ImhNone
        property int epoch: root.configEpoch
        onEpochChanged: cfg.syncEditors()
        Component.onCompleted: cfg.syncEditors()
        onTextChanged: root.setConfigDraft(cfg.key, text)
        onActiveFocusChanged: {
          if (activeFocus) root.configFocusCount += 1
          else root.configFocusCount = Math.max(0, root.configFocusCount - 1)
        }
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.closeConfig()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.commitConfig()
            event.accepted = true
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: !!(cfg.spec && cfg.spec.unit)
        text: cfg.spec && cfg.spec.unit ? String(cfg.spec.unit) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: cfg.usePicker
      width: parent.width
      text: cfg.customOpen ? "Custom code (2–5 letters), then Save." : "Not listed? Custom code — any 2–5 letter code."
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: cfg.customOpen = !cfg.customOpen
      }
    }

    TextField {
      id: currencyCustomField
      visible: cfg.usePicker && cfg.customOpen
      width: Style.space(150)
      enabled: !root.configSaving
      placeholderText: "e.g. XXX"
      foreground: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      verticalPadding: Style.space(2)
      onTextChanged: cfg.commitCurrency(text)
      onActiveFocusChanged: {
        if (activeFocus) root.configFocusCount += 1
        else root.configFocusCount = Math.max(0, root.configFocusCount - 1)
      }
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.closeConfig()
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.commitConfig()
          event.accepted = true
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: cfg.spec && cfg.spec.blurb ? String(cfg.spec.blurb) : ""
      color: root.muted
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      visible: cfg.key === "currency" && root.currencyOverrideHint !== ""
      width: parent.width
      text: root.currencyOverrideHint
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Text {
      textFormat: Text.PlainText
      visible: root.configFieldError(cfg.key) !== ""
      width: parent.width
      text: root.configFieldError(cfg.key)
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
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
