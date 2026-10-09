import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The DroidCam connection, once per shell. The shell starts this service
// with the plugin, so the camera connects at login even before a bar is
// drawn; the bar widget (one per monitor) is only a view of it.
//
// Nothing here polls while idle: the stream is watched by the helper's
// `run` command (one small bash loop next to droidcam-cli), retries are
// one-shot timers that back off to two minutes, and the phone, preview, and
// camera users are only queried while a popup is open.
Item {
  id: root

  // Injected by the shell's service loader.
  property var shell: null
  property var manifest: null

  // Late process callbacks must not touch a destroyed service.
  property bool alive: true

  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("bin/droidcam-helper.sh").toString().replace(/^file:\/\//, ""))
  // Owner-only runtime dir; the cache dir when there is none.
  // Preview frames are camera pictures: they only ever live in the owner-only
  // runtime dir, and there is no preview without one.
  readonly property string runtimeBase: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property bool previewAvailable: runtimeBase !== ""
  readonly property string previewPath: previewAvailable ? runtimeBase + "/droidcam-omarchy/preview.jpg" : ""

  // ---------- Settings ----------
  //
  // The widget's entry in shell.json. The service reads it from the bar
  // config (available at startup, before any widget exists); views push their
  // copy too, which the bar keeps current.
  property var viewSettings: null
  readonly property var barEntry: findEntry(shell ? shell.barConfig : null)
  readonly property var rawSettings: viewSettings !== null ? viewSettings : (barEntry || ({}))
  readonly property var cfg: Model.settingsFrom(rawSettings)
  readonly property string cli: cfg.cliPath !== "" ? cfg.cliPath : "droidcam-cli"
  // Settings that need a new connection when they change.
  readonly property string connectionKey: [cfg.mode, cfg.host, cfg.port, cfg.device, cfg.size, cfg.audio, cli].join("|")

  function findEntry(barConfig) {
    var layout = barConfig && barConfig.layout ? barConfig.layout : null
    if (!layout) return null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = Model.toArray(layout[sections[s]])
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].id === Model.PLUGIN_ID) return withoutId(list[i])
      }
    }
    return null
  }

  function withoutId(entry) {
    var out = {}
    for (var k in entry) if (k !== "id") out[k] = entry[k]
    return out
  }

  function updateSettings(next) {
    viewSettings = next ? withoutId(next) : null
  }

  function saveSettings(patch) {
    var next = Object.assign({}, rawSettings, patch)
    viewSettings = next
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline(Model.PLUGIN_ID, next)
  }

  // ---------- Views ----------
  property var views: []
  readonly property bool popupOpen: {
    for (var i = 0; i < views.length; i++) if (views[i] && views[i].opened === true) return true
    return false
  }

  function attachView(view) {
    if (!view || views.indexOf(view) >= 0) return
    if (view.settings) updateSettings(view.settings)
    views = views.concat([view])
  }

  function detachView(view) {
    var i = views.indexOf(view)
    if (i < 0) return
    var next = views.slice()
    next.splice(i, 1)
    views = next
  }

  // ---------- State ----------
  // off, connecting, live, waiting, blocked, setup, standby
  // (not `state`: Item already has one)
  property string camState: "off"
  property string reason: ""
  property string activeMode: ""
  property string device: ""
  property string errorLine: ""
  property int attempts: 0
  property bool wanted: false
  property bool checking: false
  property bool stopping: false
  property bool restartAfterStop: false
  property bool everLive: false
  property bool lostSinceLive: false
  property double liveSince: 0
  property var lastCheck: ({})
  property var phone: ({ reachable: false })
  property var consumers: []
  property double idleSince: 0
  property var doctor: ({ rows: [], at: 0, running: false })
  // A short message for the popup, e.g. a control the phone refused.
  property string notice: ""
  onNoticeChanged: if (notice !== "") noticeTimer.restart()
  Timer {
    id: noticeTimer
    interval: 6000
    onTriggered: root.notice = ""
  }
  property int previewTick: 0
  property bool previewOk: false
  property bool takeOverTried: false

  readonly property bool live: camState === "live"
  readonly property bool running: runner.running
  readonly property string apiHost: Model.apiHost(activeMode || cfg.mode, cfg)
  readonly property string statusText: Model.stateLabel(camState, reason, activeMode)

  function setState(next, why) {
    camState = next
    reason = why || ""
  }

  // ---------- Lifecycle ----------

  Timer {
    // Let the shell finish loading settings before the first attempt.
    id: startupTimer
    interval: 1500
    running: true
    onTriggered: {
      if (root.cfg.autoConnect) root.connectCamera()
    }
  }

  // Remove preview frames an earlier run or version may have left behind.
  Component.onCompleted: helperCall(["cleanup"], function() {})

  Component.onDestruction: {
    alive = false
    // Unloaded while the preview ran: delete the frame (a detached process,
    // since this object's children are going away).
    if (previewing) Quickshell.execDetached(["bash", helper, "forget", previewPath])
    if (runner.running) runner.signal(15)
  }

  onConnectionKeyChanged: {
    if (startupTimer.running) return
    if (wanted) reconnect()
  }

  onPopupOpenChanged: {
    if (!popupOpen) return
    refreshPhone()
    refreshConsumers()
    // Opening the popup is a good moment to try again right away.
    if (wanted && !runner.running && !checking && camState !== "standby") {
      attempts = 0
      attempt()
    }
    if (camState === "setup" || camState === "blocked") runDoctor()
  }

  // ---------- Connecting ----------

  function connectCamera() {
    wanted = true
    attempts = 0
    takeOverTried = false
    attempt()
    return "ok"
  }

  function disconnectCamera() {
    wanted = false
    retryTimer.stop()
    if (runner.running) {
      stopping = true
      runner.running = false
    }
    setState("off", "")
    activeMode = ""
    consumers = []
    return "ok"
  }

  function toggleConnection() {
    return wanted ? disconnectCamera() : connectCamera()
  }

  function reconnect() {
    wanted = true
    attempts = 0
    retryTimer.stop()
    if (runner.running) {
      stopping = true
      restartAfterStop = true
      runner.running = false
    } else {
      attempt()
    }
    return "ok"
  }

  function scheduleRetry(why) {
    retryTimer.interval = Model.retryDelay(attempts, why)
    attempts++
    retryTimer.restart()
  }

  Timer {
    id: retryTimer
    repeat: false
    onTriggered: root.attempt()
  }

  function attempt() {
    retryTimer.stop()
    if (!wanted) { setState("off", ""); return }
    if (runner.running || checking) return
    checking = true
    if (camState === "off") setState("connecting", "")
    helperCall(["check", cfg.mode, cfg.host, String(cfg.port), cfg.device, cli, "0"], function(code, out) {
      checking = false
      if (!wanted || runner.running) return
      var kv = Model.parseKv(out)
      lastCheck = kv
      var p = Model.plan(cfg, kv)
      if (p.action === "wait") {
        if (p.state !== camState || p.reason !== reason) notifyProblem(p.reason)
        setState(p.state, p.reason)
        scheduleRetry(p.reason)
        if (p.state === "setup" && popupOpen) runDoctor()
        return
      }
      if (p.action === "release") {
        if (takeOverTried) {
          setState("blocked", "otherClient")
          scheduleRetry("otherClient")
          return
        }
        // Ask the other client to quit once, then check again.
        takeOverTried = true
        helperCall(["release"].concat(p.pids.map(String)), function() {
          retryTimer.interval = 1500
          retryTimer.restart()
        })
        return
      }
      if (cfg.onDemand) {
        // Stream only while an app has the camera open.
        helperCall(["consumers", p.device, ""], function(code2, out2) {
          var apps = Model.unique(Model.parseKv(out2).app)
          consumers = apps
          if (!wanted || runner.running) return
          if (apps.length === 0) {
            device = p.device
            activeMode = p.mode
            setState("standby", "")
            return
          }
          launch(p.mode, p.device)
        })
        return
      }
      launch(p.mode, p.device)
    })
  }

  function launch(mode, dev) {
    activeMode = mode
    device = dev
    errorLine = ""
    runnerReason = ""
    setState("connecting", "")
    runner.command = ["bash", helper, "run", cli].concat(Model.cliArgs(cfg, mode, dev))
    runner.running = true
  }

  property string runnerReason: ""

  Process {
    id: runner
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) { root.onRunnerLine(line) }
    }
    stderr: SplitParser {
      onRead: function(line) { root.onRunnerError(line) }
    }
    onExited: function(code, status) { root.onRunnerExit(code) }
  }

  function onRunnerLine(line) {
    if (!alive) return
    if (line.indexOf("Video: /dev/") === 0) {
      device = line.slice(7).trim()
    } else if (line === "@live") {
      onLive()
    } else if (line === "@lost") {
      runnerReason = "lost"
    } else if (line === "@refused") {
      if (runnerReason === "") runnerReason = "refused"
    }
  }

  function onRunnerError(line) {
    if (!alive) return
    var why = Model.classifyError(line)
    if (why === "") return
    errorLine = line
    runnerReason = why
    // droidcam-cli idles instead of exiting after these; stop it now.
    if (camState === "connecting" && ["busy", "refused", "noDevice", "noAccess", "badFormat"].indexOf(why) >= 0)
      runner.running = false
  }

  function onLive() {
    var wasLost = lostSinceLive
    attempts = 0
    lostSinceLive = false
    takeOverTried = false
    liveSince = Date.now()
    idleSince = Date.now()
    setState("live", "")
    if (wasLost) notify("Camera reconnected", "Streaming again" + modeSuffix())
    else if (!everLive) notify("Camera connected", "Streaming" + modeSuffix())
    everLive = true
    refreshPhone()
  }

  function modeSuffix() {
    return activeMode === "wifi" ? " over Wi-Fi" : activeMode === "ios" || activeMode === "adb" ? " over USB" : ""
  }

  function onRunnerExit(code) {
    if (!alive) return
    var wasLive = camState === "live"
    if (stopping) {
      stopping = false
      if (restartAfterStop) {
        restartAfterStop = false
        setState("connecting", "")
        attempt()
      } else if (wanted && cfg.onDemand) {
        setState("standby", "")
      }
      return
    }
    var why = runnerReason !== "" ? runnerReason
      : code === 75 ? "lost"
      : code === 76 ? "refused"
      : code === 127 ? "noCli"
      : "exited"
    if (wasLive && !Model.isSetupReason(why)) why = "lost"
    if (wasLive) {
      lostSinceLive = true
      notify("Camera disconnected", "Reconnecting…")
    }
    if (!wanted) { setState("off", ""); return }
    setState(Model.isSetupReason(why) ? "setup" : "waiting", why)
    scheduleRetry(why)
  }

  // ---------- Retry on events ----------
  //
  // While waiting for the phone, a plugged-in device or a network change
  // retries at once instead of at the next back-off step. Both monitors sleep
  // until the kernel reports something, and run only while waiting.
  readonly property bool watchEvents: wanted && !runner.running
    && (camState === "waiting" || camState === "blocked" || camState === "setup")

  Process {
    id: deviceWatch
    running: root.watchEvents
    command: ["setpriv", "--pdeathsig", "TERM", "--", "udevadm", "monitor", "--udev", "--subsystem-match=usb", "--subsystem-match=video4linux"]
    stdout: SplitParser {
      onRead: function(line) { if (/\sadd\s/.test(line)) eventRetry.restart() }
    }
  }

  Process {
    id: networkWatch
    running: root.watchEvents && (root.cfg.mode === "wifi" || root.cfg.mode === "auto") && root.cfg.host !== ""
    command: ["setpriv", "--pdeathsig", "TERM", "--", "ip", "-o", "monitor", "address", "route"]
    stdout: SplitParser {
      onRead: function(line) { eventRetry.restart() }
    }
  }

  Timer {
    // Events come in bursts; wait for them to settle (the phone's app also
    // needs a moment after USB enumeration).
    id: eventRetry
    interval: 3000
    onTriggered: {
      if (!root.watchEvents || root.checking) return
      root.attempts = 0
      root.attempt()
    }
  }

  // ---------- Controls ----------

  // Zoom, focus, torch, mirror and flip go to droidcam-cli's stdin, which
  // works with the free app. Absolute zoom, exposure, locks, and camera
  // switching use the phone's HTTP API, which needs DroidCam Pro.
  function control(name, value) {
    if (["zoom", "ev", "exposureLock", "wbLock", "camera"].indexOf(name) >= 0) {
      return proControl(name, value)
    }
    var key = Model.controlKey(name)
    if (key === "") return "unknown control: " + name
    if (!live || !runner.running) return "not streaming"
    // Torch and focus work better through the API when it is available.
    if ((name === "torch" || name === "focus") && phone.pro && apiHost !== "") return proControl(name, value)
    runner.write(key)
    if (name === "mirror") saveSettings({ hflip: !cfg.hflip })
    if (name === "flip") saveSettings({ vflip: !cfg.vflip })
    return "ok"
  }

  function proControl(name, value) {
    var path = Model.proPath(name, value)
    if (path === "") return "invalid value"
    if (apiHost === "") return "no phone address for camera controls"
    helperCall(["put", apiHost, String(cfg.port), path], function(code, out) {
      var res = Model.parseKv(out).code
      if (res === "550") notice = "This control needs DroidCam Pro."
      else if (res === "555") notice = "The DroidCam app is stopped."
      else if (res !== "200") notice = "The phone did not accept the change."
      else notice = ""
      refreshPhone()
    })
    return "ok"
  }

  // ---------- Phone, users, preview (only while a popup is open) ----------

  function refreshPhone() {
    if (apiHost === "" || phoneBusy) return
    phoneBusy = true
    helperCall(["phone", apiHost, String(cfg.port)], function(code, out) {
      phoneBusy = false
      phone = Model.phoneFrom(Model.parseKv(out))
    })
  }
  property bool phoneBusy: false

  function refreshConsumers() {
    var dev = device || cfg.device || lastCheck.device || ""
    if (dev === "" || consumersBusy) return
    consumersBusy = true
    helperCall(["consumers", dev, ""], function(code, out) {
      consumersBusy = false
      consumers = Model.unique(Model.parseKv(out).app)
      onDemandTick()
    })
  }
  property bool consumersBusy: false

  // On-demand: start when an app opens the camera, stop after idleStop
  // seconds without one.
  function onDemandTick() {
    if (!cfg.onDemand || !wanted) return
    if (consumers.length > 0) {
      idleSince = Date.now()
      if (camState === "standby" && !runner.running && !checking) launch(activeMode || cfg.mode, device)
    } else if (live && Date.now() - idleSince > cfg.idleStop * 1000) {
      stopping = true
      runner.running = false
    }
  }

  Timer {
    id: phoneTimer
    interval: 15000
    repeat: true
    running: root.popupOpen && root.apiHost !== ""
    onTriggered: root.refreshPhone()
  }

  Timer {
    // On-demand needs to watch for camera users; otherwise only the popup does.
    id: consumersTimer
    interval: root.popupOpen ? 5000 : 15000
    repeat: true
    running: root.popupOpen || (root.cfg.onDemand && root.wanted)
    onTriggered: root.refreshConsumers()
  }

  Timer {
    id: previewTimer
    interval: 2000
    repeat: true
    triggeredOnStart: true
    running: root.popupOpen && root.cfg.preview && root.previewAvailable && root.live && root.device !== ""
    onTriggered: root.grabPreview()
  }

  property bool previewBusy: false
  readonly property bool previewing: previewTimer.running

  // No camera picture is kept once nobody is looking at it.
  onPreviewingChanged: {
    if (previewing) return
    previewOk = false
    helperCall(["forget", previewPath], function() {})
  }

  function grabPreview() {
    if (previewBusy) return
    previewBusy = true
    helperCall(["snapshot", device, previewPath], function(code, out) {
      previewBusy = false
      previewOk = Model.parseKv(out).ok === "1"
      if (previewOk) previewTick++
    })
  }

  // ---------- Setup check, import ----------

  function runDoctor() {
    if (doctor.running) return
    doctor = { rows: doctor.rows, at: doctor.at, running: true }
    helperCall(["doctor", cfg.mode, cfg.host, String(cfg.port), cfg.device, cli], function(code, out) {
      var kv = Model.parseKv(out)
      doctor = { rows: Model.doctorRows(kv, cfg), at: Date.now(), running: false, ffmpeg: kv.ffmpeg === "1", devices: kv.loop_device }
    })
  }

  function importDroidcam() {
    helperCall(["import"], function(code, out) {
      var patch = Model.importPatch(Model.parseKv(out))
      if (!patch) { notice = "No DroidCam app settings found."; return }
      notice = "Imported the DroidCam app's settings."
      saveSettings(patch)
    })
  }

  function savePhone(name) {
    saveSettings({ phones: Model.addPhone(cfg.phones, { name: name, mode: cfg.mode, host: cfg.host, port: cfg.port }) })
  }

  function usePhone(index) {
    var p = cfg.phones[index]
    if (!p) return
    saveSettings({ mode: p.mode, host: p.host, port: p.port })
    if (!wanted) connectCamera()
  }

  function forgetPhone(index) {
    saveSettings({ phones: Model.removePhone(cfg.phones, index) })
  }

  // ---------- Notifications ----------

  function notify(title, body) {
    if (!cfg.notify) return
    var args = ["notify-send", "--app-name=DroidCam", "--icon=camera-web", "--", title, Model.escapeMarkup(body)]
    notifyComponent.createObject(root, { command: args }).running = true
  }

  // Setup problems are announced once each, not on every retry.
  property var announced: ({})
  function notifyProblem(why) {
    if (!Model.isSetupReason(why) || announced[why]) return
    var next = Object.assign({}, announced)
    next[why] = true
    announced = next
    notify(Model.reasonTitle(why), Model.reasonHint(why))
  }

  Component {
    id: notifyComponent
    Process { onExited: destroy() }
  }

  // ---------- Helper processes ----------

  Component {
    id: helperComponent
    Process {
      id: proc
      property var callback: null
      property int exitCode: -1
      property bool exited: false
      property bool streamEnded: false
      property bool finished: false
      function finish() {
        if (finished || !exited || !streamEnded) return
        finished = true
        var cb = callback
        callback = null
        if (cb && root.alive) cb(exitCode, collector.text)
        proc.destroy()
      }
      stdout: StdioCollector {
        id: collector
        waitForEnd: true
        onStreamFinished: { proc.streamEnded = true; proc.finish() }
      }
      onExited: function(code) { proc.exitCode = code; proc.exited = true; proc.finish() }
    }
  }

  function helperCall(args, callback) {
    var p = helperComponent.createObject(root, { command: ["bash", helper].concat(args), callback: callback })
    p.running = true
    return p
  }

  // ---------- Status ----------

  function statusObject() {
    return {
      state: camState, reason: reason, status: statusText, hint: Model.reasonHint(reason),
      wanted: wanted, mode: cfg.mode, activeMode: activeMode, device: device,
      host: cfg.host, port: cfg.port, liveSince: liveSince, attempts: attempts,
      retryIn: retryTimer.running ? retryTimer.interval : 0,
      error: errorLine, phone: phone, consumers: consumers, onDemand: cfg.onDemand,
      notice: notice, others: Model.parseOthers(lastCheck.other), doctor: doctor.rows
    }
  }

  IpcHandler {
    target: Model.PLUGIN_ID

    function status(): string { return JSON.stringify(root.statusObject()) }
    function connect(): string { return root.connectCamera() }
    function disconnect(): string { return root.disconnectCamera() }
    function reconnect(): string { return root.reconnect() }
    function toggle(): string { return root.toggleConnection() }
    // zoomIn, zoomOut, focus, torch, mirror, flip
    function control(name: string): string { return root.control(name) }
    // zoom <factor>, ev <value>, camera <index> (DroidCam Pro)
    function set(name: string, value: string): string { return root.control(name, Number(value)) }
    // Runs the setup check; read the result with `status` (doctor).
    function doctor(): string { root.runDoctor(); return "running" }
    function importSettings(): string { root.importDroidcam(); return "ok" }
    // Merge settings from JSON, e.g. '{"mode":"wifi","host":"192.168.1.50"}'.
    function configure(json: string): string {
      var patch
      try { patch = JSON.parse(json) } catch (e) { return "invalid JSON" }
      var res = Model.cleanPatch(patch)
      if (!res.ok) return res.error
      root.saveSettings(res.patch)
      return "ok"
    }
  }
}
