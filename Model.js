.pragma library

// Pure helpers for the DroidCam plugin: settings, the helper's key=value
// output, connection planning, error classification, and labels. No QML
// state lives here, so it also loads in node for the tests in tests/.

var PLUGIN_ID = "io.github.saurasanchezpablo.droidcam"
var DEFAULT_PORT = 4747
var MODES = ["auto", "wifi", "ios", "adb"]
var SIZES = ["640x480", "960x720", "1280x720", "1920x1080"]

// Nerd Font (Material Design) glyphs, the same set the shell's bar uses.
var ICONS = {
  webcam: "\u{F05A0}",
  webcamOff: "\u{F1737}",
  video: "\u{F0567}",
  videoOff: "\u{F0568}",
  alert: "\u{F0026}",
  play: "\u{F040A}",
  stop: "\u{F04DB}",
  restart: "\u{F0709}",
  refresh: "\u{F0450}",
  cog: "\u{F0493}",
  check: "\u{F012C}",
  close: "\u{F0156}",
  flash: "\u{F0241}",
  focus: "\u{F02F1}",
  zoomIn: "\u{F034B}",
  zoomOut: "\u{F034A}",
  mirror: "\u{F10E7}",
  flip: "\u{F10E8}",
  cameraSwitch: "\u{F0108}",
  wifi: "\u{F05A9}",
  usb: "\u{F0553}",
  battery: "\u{F0079}",
  charging: "\u{F0084}",
  stethoscope: "\u{F04D9}",
  lock: "\u{F033E}",
  lockOpen: "\u{F033F}",
  phone: "\u{F011C}",
  pause: "\u{F03E4}",
  image: "\u{F02E9}",
  plus: "\u{F0415}",
  delete: "\u{F01B4}"
}

// ---------- Settings ----------

function toArray(value) {
  if (value === undefined || value === null) return []
  if (Array.isArray(value)) return value.slice()
  // Arrays read from shell.json are array-like objects, not real arrays.
  if (typeof value === "object" && typeof value.length === "number")
    return Array.prototype.slice.call(value)
  return []
}

function validHost(host) {
  return typeof host === "string" && /^[A-Za-z0-9._:-]{1,253}$/.test(host)
}

function validPort(port) {
  var n = Number(port)
  return Math.floor(n) === n && n > 0 && n < 65536
}

function validDevice(path) {
  return typeof path === "string" && /^\/dev\/video[0-9]{1,3}$/.test(path)
}

function bool(value, fallback) {
  if (value === true || value === false) return value
  if (value === "true") return true
  if (value === "false") return false
  return fallback
}

function int(value, fallback, min, max) {
  var n = Math.round(Number(value))
  if (!isFinite(n) || value === "" || value === null || value === undefined) return fallback
  return Math.max(min, Math.min(max, n))
}

function normalizePhone(p) {
  if (!p || typeof p !== "object") return null
  var mode = MODES.indexOf(p.mode) >= 0 ? p.mode : "wifi"
  var host = String(p.host || "").trim()
  if (host !== "" && !validHost(host)) return null
  return {
    name: String(p.name || host || mode).slice(0, 40),
    mode: mode,
    host: host,
    port: validPort(p.port) ? Number(p.port) : DEFAULT_PORT
  }
}

// Settings as the plugin uses them, from the raw shell.json entry (the shell
// does not merge manifest defaults, and nothing validates the file).
function settingsFrom(raw) {
  raw = raw || {}
  var host = String(raw.host || "").trim()
  var device = String(raw.device || "").trim()
  var size = String(raw.size || "")
  var phones = []
  var list = toArray(raw.phones)
  for (var i = 0; i < list.length && phones.length < 8; i++) {
    var p = normalizePhone(list[i])
    if (p) phones.push(p)
  }
  return {
    mode: MODES.indexOf(raw.mode) >= 0 ? raw.mode : "auto",
    host: validHost(host) ? host : "",
    port: validPort(raw.port) ? Number(raw.port) : DEFAULT_PORT,
    device: validDevice(device) ? device : "",
    size: /^[0-9]{3,4}x[0-9]{3,4}$/.test(size) ? size : "640x480",
    hflip: bool(raw.hflip, false),
    vflip: bool(raw.vflip, false),
    audio: bool(raw.audio, false),
    autoConnect: bool(raw.autoConnect, true),
    takeOver: bool(raw.takeOver, false),
    onDemand: bool(raw.onDemand, false),
    idleStop: int(raw.idleStop, 60, 15, 3600),
    notify: bool(raw.notify, true),
    hideWhenOff: bool(raw.hideWhenOff, false),
    preview: bool(raw.preview, false),
    cliPath: typeof raw.cliPath === "string" ? raw.cliPath.trim() : "",
    phones: phones
  }
}

// Keys accepted by the configure IPC and the popup, with their types.
var SETTING_TYPES = {
  mode: "mode", host: "host", port: "port", device: "device", size: "size",
  hflip: "bool", vflip: "bool", audio: "bool", autoConnect: "bool", takeOver: "bool",
  onDemand: "bool", idleStop: "int", notify: "bool", hideWhenOff: "bool",
  preview: "bool", cliPath: "string", phones: "phones"
}

// Validates a settings patch. Returns { ok, patch, error }.
function cleanPatch(patch) {
  if (!patch || typeof patch !== "object" || Array.isArray(patch))
    return { ok: false, error: "expected a JSON object" }
  var out = {}
  for (var key in patch) {
    var type = SETTING_TYPES[key]
    var v = patch[key]
    if (!type) return { ok: false, error: "unknown setting: " + key }
    if (type === "mode" && MODES.indexOf(v) < 0) return { ok: false, error: "mode must be one of " + MODES.join(", ") }
    if (type === "host" && v !== "" && !validHost(String(v))) return { ok: false, error: "invalid host" }
    if (type === "port" && !validPort(v)) return { ok: false, error: "invalid port" }
    if (type === "device" && v !== "" && !validDevice(String(v))) return { ok: false, error: "device must look like /dev/videoN, or be empty for automatic" }
    if (type === "size" && !/^[0-9]{3,4}x[0-9]{3,4}$/.test(String(v))) return { ok: false, error: "size must look like 1280x720" }
    if (type === "bool" && v !== true && v !== false) return { ok: false, error: key + " must be true or false" }
    if (type === "int" && !(typeof v === "number" && isFinite(v))) return { ok: false, error: key + " must be a number" }
    if (type === "string" && typeof v !== "string") return { ok: false, error: key + " must be a string" }
    if (type === "phones" && !Array.isArray(v)) return { ok: false, error: "phones must be a list" }
    out[key] = type === "port" ? Number(v) : type === "host" ? String(v).trim() : v
  }
  return { ok: true, patch: out }
}

// ---------- Helper output ----------

// Parses "key=value" lines. Keys that may repeat become arrays.
var LIST_KEYS = ["other", "loop_device", "app", "released"]

function parseKv(text) {
  var out = {}
  for (var i = 0; i < LIST_KEYS.length; i++) out[LIST_KEYS[i]] = []
  var lines = String(text || "").split("\n")
  for (var j = 0; j < lines.length; j++) {
    var line = lines[j]
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    var key = line.slice(0, eq)
    var value = line.slice(eq + 1)
    if (LIST_KEYS.indexOf(key) >= 0) out[key].push(value)
    else out[key] = value
  }
  return out
}

function unique(list) {
  var out = []
  for (var i = 0; i < list.length; i++) if (out.indexOf(list[i]) < 0) out.push(list[i])
  return out
}

function parseBattery(text) {
  try {
    var b = JSON.parse(text)
    var level = Number(b.level)
    if (!isFinite(level) || level < 0 || level > 100) return null
    return { level: Math.round(level), charging: Number(b.state) > 0 }
  } catch (e) {
    return null
  }
}

function parseCameras(text) {
  if (!text) return []
  return String(text).split("|").map(function(s) { return s.trim() })
    .filter(function(s) { return s !== "" }).slice(0, 8)
}

function num(v) {
  var n = Number(v)
  return isFinite(n) ? n : -1
}

// Pro controls from /v1/camera/info: only the ones the phone supports
// (the app reports -1 for unsupported values).
function parseCameraInfo(text) {
  var i
  try { i = JSON.parse(text) } catch (e) { return null }
  if (!i || typeof i !== "object") return null
  var caps = {
    active: num(i.active),
    torch: num(i.led_on) >= 0 ? num(i.led_on) === 1 : null,
    zoom: null, ev: null,
    exposureLock: num(i.exposure_lock) >= 0 ? num(i.exposure_lock) === 1 : null,
    wbLock: num(i.wbLock) >= 0 ? num(i.wbLock) === 1 : null
  }
  if (num(i.zmMax) > num(i.zmMin) && num(i.zmMin) >= 0)
    caps.zoom = { value: num(i.zmValue), min: num(i.zmMin), max: num(i.zmMax) }
  if (num(i.evMax) > num(i.evMin) && i.evMin !== -1)
    caps.ev = { value: Number(i.evValue) || 0, min: Number(i.evMin), max: Number(i.evMax) }
  return caps
}

function phoneFrom(kv) {
  if (kv.reachable !== "1") return { reachable: false }
  return {
    reachable: true,
    name: String(kv.name || "").slice(0, 60),
    battery: parseBattery(kv.battery || ""),
    cameras: parseCameras(kv.cameras),
    pro: kv.info_code === "200",
    restricted: kv.info_code === "550",
    caps: kv.info_code === "200" ? parseCameraInfo(kv.info || "") : null
  }
}

// ---------- Errors ----------

// droidcam-cli 2.1.5 messages (stderr) and what they mean.
var ERROR_PATTERNS = [
  [/droidcam-cli not found/, "noCli"],
  [/Connect failed/, "notReachable"],
  [/busy with another client/, "busy"],
  [/Connection reset!|Is the app running\?|Invalid data stream/, "refused"],
  [/device not found \(\/dev\/video|Missing video device/, "noDevice"],
  [/^Error opening '/, "noAccess"],
  [/pixel format|Unable to query|Unable to determine video device/, "badFormat"],
  [/usbmuxd service is installed and running/, "usbmuxd"],
  [/computer is trusted/, "noUsb"],
  [/Error getting a connection/, "iosApp"],
  [/check if adb is installed/, "adbMissing"],
  [/unauthorized state/, "adbUnauthorized"],
  [/Device is offline/, "adbOffline"],
  [/Error adding adb forward/, "adbForward"],
  [/No devices detected/, "noUsb"]
]

function classifyError(line) {
  var text = String(line || "")
  for (var i = 0; i < ERROR_PATTERNS.length; i++)
    if (ERROR_PATTERNS[i][0].test(text)) return ERROR_PATTERNS[i][1]
  return ""
}

// Problems the user has to fix: retried slowly, not hammered.
var SETUP_REASONS = ["noCli", "noDevice", "noAccess", "badFormat", "noHost", "adbMissing", "usbmuxd"]

function isSetupReason(reason) {
  return SETUP_REASONS.indexOf(reason) >= 0
}

var REASON_TEXT = {
  noCli: ["droidcam-cli is not installed", "Install the DroidCam Linux client (droidcam package)."],
  noDevice: ["No camera device", "Load the v4l2loopback-dc (or v4l2loopback) kernel module; see the README."],
  noAccess: ["Can't open the camera device", "Add yourself to the video group and log in again."],
  badFormat: ["The camera device has the wrong format", "Set the loopback device to YU12 (see the README) or use the DroidCam driver."],
  noHost: ["No phone address", "Enter the phone's Wi-Fi address in Settings, or plug it in over USB."],
  notReachable: ["Phone not reachable", "Open the DroidCam app on the phone and check the address and Wi-Fi."],
  busy: ["Phone busy", "The DroidCam app is streaming to another client."],
  refused: ["Phone refused the stream", "Open the DroidCam app on the phone, or close the other client."],
  noUsb: ["No phone on USB", "Plug the phone in and trust this computer."],
  usbmuxd: ["usbmuxd is not running", "Install and start usbmuxd for iPhone over USB."],
  iosApp: ["Can't reach the app over USB", "Open the DroidCam app and re-plug the phone."],
  adbMissing: ["adb is not installed", "Install android-tools for Android over USB."],
  adbUnauthorized: ["USB debugging not allowed", "Accept the USB debugging prompt on the phone."],
  adbOffline: ["Phone offline over adb", "Re-plug the phone."],
  adbForward: ["adb port forward failed", "Re-plug the phone and try again."],
  otherClient: ["In use by another DroidCam client", "Close it, or turn on Take over in Settings."],
  lost: ["Stream lost", "Reconnecting."],
  exited: ["droidcam-cli stopped", "Retrying."]
}

function reasonTitle(reason) {
  return REASON_TEXT[reason] ? REASON_TEXT[reason][0] : (reason || "")
}

function reasonHint(reason) {
  return REASON_TEXT[reason] ? REASON_TEXT[reason][1] : ""
}

// ---------- Connection planning ----------

// Where the phone's HTTP API answers for a connection mode: Wi-Fi uses the
// address, adb the forwarded local port, iOS USB only when an address is
// also set (the phone on the same Wi-Fi).
function apiHost(mode, cfg) {
  if (mode === "adb") return "127.0.0.1"
  return cfg.host
}

// droidcam-cli arguments: options first, then the connection.
function cliArgs(cfg, mode, device) {
  var args = []
  if (device) args.push("-dev=" + device)
  args.push("-size=" + cfg.size)
  if (cfg.audio) { args.push("-a"); args.push("-v") }
  if (cfg.hflip) args.push("-hflip")
  if (cfg.vflip) args.push("-vflip")
  if (mode === "wifi") { args.push(cfg.host); args.push(String(cfg.port)) }
  else { args.push(mode); args.push(String(cfg.port)) }
  return args
}

// Decides what to do with the result of `helper check`.
// Returns { action: "start", mode, device } or
//         { action: "wait", state: "setup"|"waiting"|"blocked", reason }.
function plan(cfg, kv) {
  if (kv.cli !== "1") return wait("setup", "noCli")
  if ((kv.other || []).length > 0 && !cfg.takeOver) return wait("blocked", "otherClient")
  if (kv.device_missing !== undefined) return wait("setup", "noDevice")
  if (kv.access === "0") return wait("setup", "noAccess")
  var device = kv.device || ""

  var mode = cfg.mode
  if (mode === "auto") {
    if (kv.ios_attached === "1" && kv.usbmuxd === "1") mode = "ios"
    else if (kv.adb_state === "device") mode = "adb"
    else if (cfg.host !== "" && kv.wifi === "1") mode = "wifi"
    else if (kv.ios_attached === "1") return wait(cfg.host !== "" ? "waiting" : "setup", "usbmuxd")
    else if (kv.adb_state === "unauthorized") return wait("waiting", "adbUnauthorized")
    else if (cfg.host === "") return wait("setup", "noHost")
    else return wait("waiting", "notReachable")
  } else if (mode === "wifi") {
    if (cfg.host === "") return wait("setup", "noHost")
    if (kv.wifi !== "1") return wait("waiting", "notReachable")
  } else if (mode === "ios") {
    if (kv.usbmuxd !== "1") return wait("setup", "usbmuxd")
    if (kv.ios_attached !== "1") return wait("waiting", "noUsb")
  } else if (mode === "adb") {
    if (kv.adb !== "1") return wait("setup", "adbMissing")
    if (kv.adb_state === "unauthorized") return wait("waiting", "adbUnauthorized")
    if (kv.adb_state === "offline") return wait("waiting", "adbOffline")
    if (kv.adb_state !== "device") return wait("waiting", "noUsb")
  }
  return { action: "start", mode: mode, device: device }
}

function wait(state, reason) {
  return { action: "wait", state: state, reason: reason }
}

// Retry delay in ms: quick at first, then backing off to two minutes.
// Setup problems wait longer, since they need the user anyway.
var BACKOFF = [3, 5, 10, 20, 40, 60, 120]

function retryDelay(attempt, reason) {
  if (reason === "lost") return 2000
  if (isSetupReason(reason)) return 120000
  var i = Math.max(0, Math.min(BACKOFF.length - 1, attempt))
  return BACKOFF[i] * 1000
}

// ---------- Controls ----------

// Keys droidcam-cli reads on stdin while streaming (no DroidCam Pro needed).
var CONTROL_KEYS = { zoomIn: "+", zoomOut: "-", focus: "a", torch: "l", mirror: "m", flip: "v" }

function controlKey(name) {
  return CONTROL_KEYS[name] || ""
}

function fmt(n) {
  return String(Math.round(Number(n) * 100) / 100)
}

// HTTP paths for Pro controls (PUT), or "" for an unknown control.
function proPath(name, value) {
  switch (name) {
  case "torch": return "/v1/camera/torch_toggle"
  case "focus": return "/v1/camera/autofocus"
  case "exposureLock": return "/v1/camera/el_toggle"
  case "wbLock": return "/v1/camera/wbl_toggle"
  case "zoom": return isFinite(Number(value)) ? "/v3/camera/zoom/" + fmt(value) : ""
  case "ev": return isFinite(Number(value)) ? "/v3/camera/ev/" + fmt(value) : ""
  case "camera": return Math.floor(Number(value)) === Number(value) && value >= 0 ? "/v1/camera/active/" + value : ""
  }
  return ""
}

// ---------- Labels ----------

function stateLabel(state, reason, mode) {
  switch (state) {
  case "off": return "Off"
  case "standby": return "Standby"
  case "connecting": return "Connecting"
  case "live": return mode === "wifi" ? "Live over Wi-Fi" : mode === "ios" || mode === "adb" ? "Live over USB" : "Live"
  case "waiting": return reasonTitle(reason) || "Waiting for phone"
  case "blocked": return reasonTitle(reason)
  case "setup": return reasonTitle(reason) || "Setup needed"
  }
  return reasonTitle(reason) || "Error"
}

function stateIcon(state) {
  switch (state) {
  case "live": return ICONS.webcam
  case "connecting": return ICONS.webcam
  case "setup": return ICONS.alert
  case "off": case "standby": return ICONS.webcamOff
  }
  return ICONS.webcamOff
}

function modeLabel(mode) {
  return { auto: "Auto", wifi: "Wi-Fi", ios: "iPhone USB", adb: "Android USB" }[mode] || mode
}

function batteryText(b) {
  if (!b) return ""
  return b.level + "%" + (b.charging ? " charging" : "")
}

// ---------- Setup check ----------

// Rows for the popup's setup check from `helper doctor`.
function doctorRows(kv, cfg) {
  var rows = []
  function row(ok, label, hint) { rows.push({ ok: ok, label: label, hint: ok ? "" : hint }) }
  row(kv.cli !== "" && kv.cli !== undefined, "droidcam-cli installed", reasonHint("noCli"))
  row(kv.curl === "1", "curl installed", "Install curl.")
  row(kv.module_dc === "1" || kv.module_loopback === "1", "Loopback driver loaded", reasonHint("noDevice"))
  row(!!kv.device, "Camera device" + (kv.device ? " " + kv.device : ""), reasonHint("noDevice"))
  if (kv.device) {
    row(kv.access === "1", "Device readable and writable", reasonHint("noAccess"))
    row(kv.video_group === "1" || kv.access === "1", "In the video group", reasonHint("noAccess"))
  }
  var wantIos = cfg.mode === "ios" || (cfg.mode === "auto" && kv.ios_attached === "1")
  var wantAdb = cfg.mode === "adb" || (cfg.mode === "auto" && kv.android_attached === "1")
  if (wantIos) row(kv.usbmuxd === "1", "usbmuxd running (iPhone USB)", reasonHint("usbmuxd"))
  if (wantAdb) row(kv.adb === "1", "adb installed (Android USB)", reasonHint("adbMissing"))
  if (wantAdb && kv.adb === "1")
    row(kv.adb_state === "device", "Phone authorized over adb", reasonHint(kv.adb_state === "unauthorized" ? "adbUnauthorized" : "noUsb"))
  if (cfg.mode === "wifi" || cfg.mode === "auto") {
    if (cfg.host === "") row(cfg.mode === "auto" && (kv.ios_attached === "1" || kv.android_attached === "1"), "Phone address set", reasonHint("noHost"))
    else row(kv.wifi === "1", "Phone answers on " + cfg.host + ":" + cfg.port, reasonHint("notReachable"))
  }
  if (cfg.audio) row(kv.module_aloop === "1", "snd-aloop loaded (audio)", "Load the snd-aloop module for DroidCam audio.")
  var others = unique(kv.other || [])
  if (others.length > 0) row(false, "Other DroidCam client running: " + others.join(", "), reasonHint("otherClient"))
  return rows
}

// Settings patch from the DroidCam app's own config (`helper import`).
function importPatch(kv) {
  if (kv.found !== "1") return null
  var patch = {}
  if (validHost(kv.ip || "")) patch.host = kv.ip
  if (validPort(kv.port)) patch.port = Number(kv.port)
  if (/^[0-9]{3,4}x[0-9]{3,4}$/.test(kv.size || "")) patch.size = kv.size
  if (kv.horizontal_flip === "0" || kv.horizontal_flip === "1") patch.hflip = kv.horizontal_flip === "1"
  if (kv.vertical_flip === "0" || kv.vertical_flip === "1") patch.vflip = kv.vertical_flip === "1"
  if (kv.audio === "0" || kv.audio === "1") patch.audio = kv.audio === "1"
  // The app's connection type: 0 Wi-Fi, 1 Android USB, 2 iOS USB.
  if (kv.type === "0" && patch.host) patch.mode = "wifi"
  else if (kv.type === "1") patch.mode = "adb"
  else if (kv.type === "2") patch.mode = "ios"
  return patch
}

// ---------- Saved phones ----------

function phoneKey(p) {
  return p.mode + "|" + p.host + "|" + p.port
}

function addPhone(phones, phone) {
  var p = normalizePhone(phone)
  if (!p) return phones.slice()
  var out = phones.filter(function(q) { return phoneKey(q) !== phoneKey(p) })
  out.unshift(p)
  return out.slice(0, 8)
}

function removePhone(phones, index) {
  var out = phones.slice()
  if (index >= 0 && index < out.length) out.splice(index, 1)
  return out
}

function isCurrentPhone(cfg, p) {
  return p.mode === cfg.mode && p.host === cfg.host && p.port === cfg.port
}

// Escapes text for notification bodies (they accept markup).
function escapeMarkup(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

if (typeof module !== "undefined") {
  module.exports = {
    PLUGIN_ID: PLUGIN_ID, DEFAULT_PORT: DEFAULT_PORT, MODES: MODES, SIZES: SIZES, ICONS: ICONS,
    toArray: toArray, validHost: validHost, validPort: validPort, validDevice: validDevice,
    settingsFrom: settingsFrom, cleanPatch: cleanPatch, parseKv: parseKv, unique: unique,
    parseBattery: parseBattery, parseCameras: parseCameras, parseCameraInfo: parseCameraInfo,
    phoneFrom: phoneFrom, classifyError: classifyError, isSetupReason: isSetupReason,
    reasonTitle: reasonTitle, reasonHint: reasonHint, apiHost: apiHost, cliArgs: cliArgs,
    plan: plan, retryDelay: retryDelay, controlKey: controlKey, proPath: proPath,
    stateLabel: stateLabel, stateIcon: stateIcon, modeLabel: modeLabel, batteryText: batteryText,
    doctorRows: doctorRows, importPatch: importPatch, addPhone: addPhone, removePhone: removePhone,
    isCurrentPhone: isCurrentPhone, escapeMarkup: escapeMarkup
  }
}
