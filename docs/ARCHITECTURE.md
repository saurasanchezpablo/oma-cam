# Architecture

## Files

| File | Role |
|------|------|
| `manifest.json` | Plugin manifest: id `io.github.saurasanchezpablo.droidcam`, kinds `service` and `bar-widget`, defaults, settings schema. |
| `Service.qml` | The connection, once per shell: state machine, retries, controls, phone status, notifications, IPC. |
| `Panel.qml` | The bar icon and popup, one per monitor. A view of the service. |
| `Model.js` | Pure logic with no QML state: settings, the helper's output, planning a connection, error classification, labels. Tested in `tests/`. |
| `bin/droidcam-helper.sh` | Every system check and the stream supervisor. The shell runs it with `bash`, so it needs no exec bit. |
| `dev/mock_droidcam.py` | Fake phone app: HTTP API and video protocol, switchable scenarios. |
| `dev/fake_droidcam_cli.py` | Stand-in for `droidcam-cli` that talks to the mock and never opens a video device. |
| `dev/deploy.sh` | Copies the plugin into `~/.config/omarchy/plugins/` and restarts the shell. |

## Why a service and a widget

The shell starts services when the plugin is enabled, before bars exist, so the
camera connects at login. Bars have one widget per monitor; each attaches to the
service (`bar.shell.serviceFor(id)`, polled because it does not notify) and only
displays its state. The IPC target lives in the service, since a target can only
route to one object.

Settings are the widget's entry in `shell.json`. A service gets no settings of its
own, so it reads its entry from `shell.barConfig` at startup and takes the copy
each view pushes when the bar updates it. Saving goes through
`shell.updateEntryInline()`, which rewrites only this entry. Removing the widget
from the bar disables the plugin, service included.

## How the stream is supervised

`droidcam-cli` does the work: it connects to the phone, decodes the MJPEG stream and
writes frames into the v4l2loopback device. The plugin starts it through
`droidcam-helper.sh run`, which:

- line-buffers its stdout (`stdbuf -oL`), so `Video: /dev/videoN` arrives at once;
- starts it with `setpriv --pdeathsig INT`, so it quits if the helper is killed
  (the shell unloading the plugin);
- passes the helper's stdin through, so the plugin can send the control keys;
- watches its sockets, because **droidcam-cli does not exit when the stream ends**:
  the video thread closes the socket and the process idles forever, still holding the
  device. The helper counts the client's socket fds (one `find` every 5 seconds,
  every second for the first 10). Once streaming, fewer sockets than at the peak
  means the stream is gone (`@lost`, exit 75). No socket after 8 seconds without ever
  streaming means the phone refused (`@refused`, exit 76);
- quits when the shell process disappears, and stops the client with SIGINT
  (droidcam-cli's clean exit), then SIGKILL after 2 seconds.

The service also reads the client's stderr and classifies its messages
(`Model.classifyError`). After "busy", "connection reset", device or format errors
the client would idle, so the service stops it at once instead of waiting for the
helper.

## Connecting

`attempt()` runs `helper check`, which prints what a connection needs right now in
one go (about 0.1 s): client installed, the device it would use and whether it can
be opened, other DroidCam clients and the stream each one has open, iPhone/usbmuxd,
adb, and whether the phone answers on Wi-Fi. `Model.plan()` turns that into one of:

- **start** in a mode (`auto` resolves to iPhone USB, Android USB or Wi-Fi, in that
  order);
- **release**: with Take over on, ask the clients holding this phone to quit
  (SIGINT, then SIGTERM), once, then check again;
- **wait** with a state (`setup`, `waiting`, `blocked`) and a reason.

Another client only blocks when it holds the same phone: over Wi-Fi a stream to the
same address; over USB any open stream. An idle DroidCam window does not block.

Retries are one-shot timers: 3, 5, 10, 20, 40, 60, then every 120 seconds; 2 seconds
after a lost stream; 120 seconds for problems the user has to fix. Opening the popup
retries at once, and so does an event while waiting: `udevadm monitor` (a USB or video
device added) and `ip monitor address route` (the network changed, Wi-Fi modes only).
Both monitors sleep until the kernel reports something, run only while waiting, and
quit with the shell (`setpriv --pdeathsig`).

## Controls

droidcam-cli reads single keys on stdin while streaming and forwards them to the
phone in-band (`CMD /v1/ctl?N`): `+`/`-` zoom, `a` autofocus, `l` torch, and local
`m` mirror / `v` flip. These work with the free app. Mirror and flip are also saved,
so the next connection starts with them.

The phone's HTTP API on the same port (`PUT /v3/camera/zoom/<x>`, `/v3/camera/ev/<x>`,
`/v1/camera/active/<n>`, `/v1/camera/el_toggle`, `/v1/camera/wbl_toggle`,
`/v1/camera/torch_toggle`, `/v1/camera/autofocus`) needs DroidCam Pro: the free app
answers `550`. `GET /v1/camera/info` tells which controls exist (`-1` means
unsupported); the popup shows only those. Read-only endpoints that work with the free
app: `/v1/phone/name`, `/v1/phone/battery_info` (`{"level":82,"state":1}`, state > 0
charging), `/v1/camera/camera_list` (one camera per line).

Over USB the HTTP API is reachable through adb's port forward (`127.0.0.1`), not
through usbmuxd; an iPhone on USB needs its Wi-Fi address set for phone status and Pro
controls.

## Talking to the phone

All requests are short `curl` runs from the helper: 64 KB replies at most, 4 seconds,
3 to connect, plain http, no redirects. Hosts, ports and control paths are checked
in `Model.js` and again in the helper before use. There are no secrets anywhere.

## Preview

With Preview on, `helper snapshot` grabs one frame with ffmpeg every 2 seconds while
the popup is open. Frames are camera pictures, so they go to
`$XDG_RUNTIME_DIR/droidcam-omarchy/preview.jpg` (the cache dir only when there is no
runtime dir): the folder is created mode 700 and refused if it is a symlink or not
ours, the file is written with umask 077, and `helper forget` deletes it as soon as the
popup closes or preview stops.

## Only while in use

`helper consumers /dev/videoN` lists the processes of the current user that have the
device open, with a single `find` over `/proc/*/fd` (about 15 ms). In on-demand mode
the service checks every 15 seconds, starts the stream when an app appears, and stops
it `idleStop` seconds after the last one goes. Apps of other users are invisible
without root.

## What runs when

| Situation | Background work |
|---|---|
| Off | nothing |
| Waiting, blocked, setup | one `check` per retry (backing off to 2 minutes); the idle udev and network monitors |
| Live | the helper's loop: one `find` every 5 seconds |
| Standby (on-demand) | one `consumers` every 15 seconds |
| Popup open | phone status every 15 s, camera users every 5 s, preview every 2 s if enabled |

## Shell quirks

- `console.log` from third-party plugins does not reach the shell log: use the
  `status` IPC.
- Hot reload keeps compiled QML: `bash dev/deploy.sh` restarts the shell.
- `shell.json` is written a moment after a settings change; restarting the shell
  right after `configure` can lose the change.
- Arrays from `shell.json` are not real JS arrays: `Model.toArray()`.
- Manifest `defaults` are not applied by the shell: `Model.settingsFrom()` does it.
- A destroyed service can still get process callbacks: every callback checks
  `alive`.
- `Item` already has a `state` property, hence `camState`.
