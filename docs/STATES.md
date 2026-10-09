# States

`omarchy-shell io.github.saurasanchezpablo.droidcam status` returns `state` and
`reason`; the popup shows the title and the hint.

| state | Bar icon | Meaning | Next |
|---|---|---|---|
| `off` | webcam off, dimmed | Not wanted: disconnected, or Connect at login is off | Connect |
| `connecting` | webcam, pulsing | droidcam-cli is starting or the stream is opening | `live`, or a waiting state |
| `live` | webcam | Streaming | `waiting`/`lost` when the stream ends |
| `standby` | webcam off, dimmed | Only while in use: no app has the camera open | `live` when one does |
| `waiting` | webcam off, dimmed | The phone can't be reached right now | Retries with back-off |
| `blocked` | webcam off, dimmed | Another DroidCam client holds this phone | Retries; Take over closes it |
| `setup` | warning, urgent color | Something has to be installed or configured | Retries every 2 minutes |

## Reasons

| reason | state | Title | Hint |
|---|---|---|---|
| `noCli` | setup | droidcam-cli is not installed | Install the DroidCam Linux client |
| `noDevice` | setup | No camera device | Load v4l2loopback-dc or v4l2loopback |
| `noAccess` | setup | Can't open the camera device | Join the video group |
| `badFormat` | setup | The camera device has the wrong format | YU12 for plain v4l2loopback |
| `noHost` | setup | No phone address | Enter the Wi-Fi address, or plug in over USB |
| `usbmuxd` | setup / waiting | usbmuxd is not running | Needed for iPhone USB |
| `adbMissing` | setup | adb is not installed | Needed for Android USB |
| `notReachable` | waiting | Phone not reachable | Open the app; check address and Wi-Fi |
| `refused` | waiting | Phone refused the stream | App closed, or another client |
| `busy` | waiting | Phone busy | Another client is streaming |
| `noUsb` | waiting | No phone on USB | Plug in and trust this computer |
| `iosApp` | waiting | Can't reach the app over USB | Open the app, re-plug |
| `adbUnauthorized` | waiting | USB debugging not allowed | Accept the prompt on the phone |
| `adbOffline` | waiting | Phone offline over adb | Re-plug |
| `adbForward` | waiting | adb port forward failed | Re-plug |
| `lost` | waiting | Stream lost | Reconnects after 2 seconds |
| `exited` | waiting | droidcam-cli stopped | Retries |
| `otherClient` | blocked | In use by another DroidCam client | Close it, or turn on Take over |

## Notifications

With Notifications on: "Camera connected" (first time), "Camera disconnected" (a live
stream ended), "Camera reconnected", and each setup problem once per session.
