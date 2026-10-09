// Unit tests for Model.js: node --test tests/
"use strict"
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

// Model.js is a QML JS library: drop the pragma and run it as a module.
const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const sandbox = { module: { exports: {} } }
vm.runInNewContext(source, sandbox)
const M = sandbox.module.exports
// Objects from the sandbox have another realm's prototypes; compare as JSON.
const plain = (v) => JSON.parse(JSON.stringify(v))

test("settings get defaults and are validated", () => {
  const s = M.settingsFrom({})
  assert.equal(s.mode, "auto")
  assert.equal(s.port, 4747)
  assert.equal(s.host, "")
  assert.equal(s.autoConnect, true)
  assert.equal(s.takeOver, false)
  assert.equal(s.size, "640x480")
  const bad = M.settingsFrom({ mode: "x", host: "a b", port: 99999, device: "/etc/passwd", size: "huge", idleStop: 2 })
  assert.equal(bad.mode, "auto")
  assert.equal(bad.host, "")
  assert.equal(bad.port, 4747)
  assert.equal(bad.device, "")
  assert.equal(bad.size, "640x480")
  assert.equal(bad.idleStop, 15)
})

test("array-like phone lists from shell.json are read", () => {
  const s = M.settingsFrom({ phones: { length: 1, 0: { name: "Pixel", mode: "wifi", host: "192.168.1.50", port: 4747 } } })
  assert.equal(s.phones.length, 1)
  assert.equal(s.phones[0].name, "Pixel")
})

test("configure patches are checked", () => {
  assert.equal(M.cleanPatch({ host: "192.168.1.50", port: "4747" }).ok, true)
  assert.equal(M.cleanPatch({ host: "192.168.1.50", port: "4747" }).patch.port, 4747)
  assert.match(M.cleanPatch({ nope: 1 }).error, /unknown setting/)
  assert.match(M.cleanPatch({ host: "$(rm -rf ~)" }).error, /invalid host/)
  assert.match(M.cleanPatch({ device: "/dev/sda" }).error, /device/)
  assert.match(M.cleanPatch({ mode: "bluetooth" }).error, /mode/)
  assert.equal(M.cleanPatch([]).ok, false)
})

test("helper output parses, with repeated keys as lists", () => {
  const kv = M.parseKv("cli=1\nother=droidcam\nother=droidcam-cli\ninfo={\"a\":1}\nnoise\n")
  assert.equal(kv.cli, "1")
  assert.deepEqual(plain(kv.other), ["droidcam", "droidcam-cli"])
  assert.equal(kv.info, "{\"a\":1}")
})

test("droidcam-cli errors are classified", () => {
  assert.equal(M.classifyError("Video: Connect failed to 192.168.1.50:4747"), "notReachable")
  assert.equal(M.classifyError("Error: Error sending request, DroidCam might be busy with another client."), "busy")
  assert.equal(M.classifyError("Error: Connection reset!"), "refused")
  assert.equal(M.classifyError("Error: Droidcam/v4l2loopback device not found (/dev/video[0-9])."), "noDevice")
  assert.equal(M.classifyError("Error opening '/dev/video3': 13 'Permission denied'"), "noAccess")
  assert.equal(M.classifyError("Make sure usbmuxd service is installed and running."), "usbmuxd")
  assert.equal(M.classifyError("Make sure usbmuxd service running and this computer is trusted."), "noUsb")
  assert.equal(M.classifyError("Error: Device is in unauthorized state"), "adbUnauthorized")
  assert.equal(M.classifyError("Client v2.1.5"), "")
})

test("auto mode prefers USB, then Wi-Fi", () => {
  const cfg = M.settingsFrom({ host: "192.168.1.50" })
  const base = { cli: "1", device: "/dev/video0", access: "1", other: [] }
  assert.equal(M.plan(cfg, { ...base, ios_attached: "1", usbmuxd: "1", wifi: "1" }).mode, "ios")
  assert.equal(M.plan(cfg, { ...base, adb_state: "device", wifi: "1" }).mode, "adb")
  assert.equal(M.plan(cfg, { ...base, wifi: "1" }).mode, "wifi")
  assert.deepEqual(plain(M.plan(cfg, { ...base, wifi: "0" })), { action: "wait", state: "waiting", reason: "notReachable" })
  assert.equal(M.plan(M.settingsFrom({}), { ...base }).reason, "noHost")
  assert.equal(M.plan(cfg, { ...base, ios_attached: "1", usbmuxd: "0", wifi: "0" }).reason, "usbmuxd")
})

test("blockers come before connecting", () => {
  const cfg = M.settingsFrom({ host: "192.168.1.50", mode: "wifi" })
  const base = { cli: "1", device: "/dev/video0", access: "1", other: [], wifi: "1" }
  assert.equal(M.plan(cfg, { ...base, cli: "0" }).reason, "noCli")
  assert.equal(M.plan(cfg, { ...base, other: ["droidcam"] }).state, "blocked")
  assert.equal(M.plan(M.settingsFrom({ host: "192.168.1.50", takeOver: true }), { ...base, other: ["droidcam"] }).action, "start")
  assert.equal(M.plan(cfg, { cli: "1", device_missing: "", other: [] }).reason, "noDevice")
  assert.equal(M.plan(cfg, { ...base, access: "0" }).reason, "noAccess")
})

test("explicit modes report their own problems", () => {
  const base = { cli: "1", device: "/dev/video0", access: "1", other: [] }
  assert.equal(M.plan(M.settingsFrom({ mode: "ios" }), { ...base, usbmuxd: "0" }).reason, "usbmuxd")
  assert.equal(M.plan(M.settingsFrom({ mode: "ios" }), { ...base, usbmuxd: "1", ios_attached: "0" }).reason, "noUsb")
  assert.equal(M.plan(M.settingsFrom({ mode: "adb" }), { ...base, adb: "0" }).reason, "adbMissing")
  assert.equal(M.plan(M.settingsFrom({ mode: "adb" }), { ...base, adb: "1", adb_state: "unauthorized" }).reason, "adbUnauthorized")
  assert.equal(M.plan(M.settingsFrom({ mode: "adb" }), { ...base, adb: "1", adb_state: "device" }).mode, "adb")
})

test("droidcam-cli arguments", () => {
  const cfg = M.settingsFrom({ host: "192.168.1.50", port: 4848, hflip: true, size: "1280x720" })
  assert.deepEqual(plain(M.cliArgs(cfg, "wifi", "/dev/video2")),
    ["-dev=/dev/video2", "-size=1280x720", "-hflip", "192.168.1.50", "4848"])
  assert.deepEqual(plain(M.cliArgs(M.settingsFrom({ audio: true }), "ios", "")),
    ["-size=640x480", "-a", "-v", "ios", "4747"])
})

test("retry delays back off and stay bounded", () => {
  assert.equal(M.retryDelay(0, "notReachable"), 3000)
  assert.equal(M.retryDelay(3, "notReachable"), 20000)
  assert.equal(M.retryDelay(50, "notReachable"), 120000)
  assert.equal(M.retryDelay(0, "lost"), 2000)
  assert.equal(M.retryDelay(0, "noDevice"), 120000)
})

test("phone info and Pro controls", () => {
  const phone = M.phoneFrom(M.parseKv("reachable=1\nname=Pixel\nbattery={\"level\":82,\"state\":1}\ncameras=Front|Back\ninfo_code=550\n"))
  assert.equal(phone.name, "Pixel")
  assert.deepEqual(plain(phone.battery), { level: 82, charging: true })
  assert.deepEqual(plain(phone.cameras), ["Front", "Back"])
  assert.equal(phone.pro, false)
  assert.equal(phone.restricted, true)
  assert.equal(M.phoneFrom({ reachable: "0" }).reachable, false)
  const caps = M.parseCameraInfo(JSON.stringify({ active: 1, led_on: 0, zmValue: 2, zmMin: 1, zmMax: 8, evValue: 0, evMin: -4, evMax: 4, exposure_lock: -1, wbLock: 0 }))
  assert.deepEqual(plain(caps.zoom), { value: 2, min: 1, max: 8 })
  assert.equal(caps.exposureLock, null)
  assert.equal(caps.torch, false)
  assert.equal(M.parseCameraInfo("not json"), null)
})

test("control keys and HTTP paths", () => {
  assert.equal(M.controlKey("torch"), "l")
  assert.equal(M.controlKey("zoomIn"), "+")
  assert.equal(M.controlKey("rm"), "")
  assert.equal(M.proPath("zoom", 2.345), "/v3/camera/zoom/2.35")
  assert.equal(M.proPath("camera", 1), "/v1/camera/active/1")
  assert.equal(M.proPath("camera", "1; rm"), "")
  assert.equal(M.proPath("other", 1), "")
})

test("import from the DroidCam app's config", () => {
  assert.equal(M.importPatch({ found: "0" }), null)
  assert.deepEqual(plain(M.importPatch(M.parseKv("found=1\nip=192.168.1.50\nport=4747\nsize=640x480\nhorizontal_flip=1\nvertical_flip=0\naudio=0\ntype=0\n"))),
    { host: "192.168.1.50", port: 4747, size: "640x480", hflip: true, vflip: false, audio: false, mode: "wifi" })
})

test("saved phones", () => {
  let list = M.addPhone([], { name: "Pixel", mode: "wifi", host: "192.168.1.50", port: 4747 })
  list = M.addPhone(list, { name: "Pixel again", mode: "wifi", host: "192.168.1.50", port: 4747 })
  assert.equal(list.length, 1)
  assert.equal(list[0].name, "Pixel again")
  list = M.addPhone(list, { name: "iPhone", mode: "ios", host: "", port: 4747 })
  assert.equal(list.length, 2)
  assert.equal(M.removePhone(list, 0).length, 1)
  assert.equal(M.isCurrentPhone(M.settingsFrom({ mode: "ios" }), list[0]), true)
})

test("setup check rows", () => {
  const cfg = M.settingsFrom({ host: "192.168.1.50", mode: "wifi" })
  const rows = M.doctorRows(M.parseKv("cli=/usr/bin/droidcam-cli\ncurl=1\nmodule_dc=1\ndevice=/dev/video0\naccess=1\nvideo_group=1\nwifi=0\nother=droidcam\n"), cfg)
  const failed = rows.filter((r) => !r.ok).map((r) => r.label)
  assert.deepEqual(plain(failed), ["Phone answers on 192.168.1.50:4747", "Other DroidCam client running: droidcam"])
})
