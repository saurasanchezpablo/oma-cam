# Changelog

## 0.1.0

First release.

- Connects to the DroidCam app at login over Wi-Fi, iPhone USB (usbmuxd) or Android
  USB (adb); Auto prefers USB when a phone is plugged in.
- Detects a dead stream (droidcam-cli keeps running when it ends) and reconnects,
  backing off from 3 seconds to 2 minutes while the phone is away.
- Retries at once when a phone is plugged in, a camera device appears, or the
  network changes.
- Waits while another DroidCam client streams from the same phone, or closes it with
  Take over.
- Bar icon with the camera state; middle click connects or disconnects, right click
  reconnects.
- Popup with the phone's name and battery, the connection and device, and the apps
  using the camera.
- Camera controls: zoom, autofocus, torch, mirror, flip. With DroidCam Pro: zoom and
  exposure sliders, exposure and white-balance locks, camera switching.
- Setup check for the client, driver, device permissions, usbmuxd, adb and the network,
  with fixes.
- Only while in use: stream only while an app has the camera open.
- Saved phones, import from the DroidCam desktop app, optional preview and audio.
- Notifications when the camera connects, disconnects or needs setup.
- IPC: status, connect, disconnect, reconnect, toggle, control, set, doctor,
  importSettings, configure.
