# Install guide

This guide takes you from nothing to a phone webcam in the Omarchy bar. It takes
about ten minutes; most of it is installing the DroidCam driver once.

1. [Install the app on the phone](#1-install-the-app-on-the-phone)
2. [Install the DroidCam client and driver](#2-install-the-droidcam-client-and-driver)
3. [Optional extras](#3-optional-extras)
4. [Install the plugin](#4-install-the-plugin)
5. [Connect the phone](#5-connect-the-phone)
6. [Check that apps see the camera](#6-check-that-apps-see-the-camera)
7. [Update](#7-update)
8. [Remove](#8-remove)
9. [Troubleshooting](#9-troubleshooting)

## 1. Install the app on the phone

Install **DroidCam** by Dev47Apps from the Google Play Store (Android) or the App
Store (iPhone), open it, and allow camera access. The main screen shows:

- **WiFi IP**, e.g. `192.168.1.50`
- **DroidCam Port**, normally `4747`

Keep the app in the foreground while streaming; iOS stops it in the background.

The free app is enough. DroidCam Pro adds the zoom and exposure sliders, the locks,
and camera switching to the plugin's popup.

## 2. Install the DroidCam client and driver

The plugin drives `droidcam-cli`, the official Linux client. The client writes the
picture into a virtual camera device created by a kernel module, `v4l2loopback-dc`
(DroidCam's own), or plain `v4l2loopback`.

### Arch, CachyOS, Omarchy

The `droidcam` package from the AUR installs the client and the `v4l2loopback-dc`
driver (built with DKMS):

```bash
yay -S droidcam
```

DKMS needs the headers of your kernel, e.g. `linux-headers`, or `linux-cachyos-headers`
on CachyOS. Install the matching one if the build complains.

### Other distributions

Use the official installer from [droidcam.app/linux](https://droidcam.app/linux/). It
installs `droidcam-cli` and the `v4l2loopback-dc` driver.

### Check it

```bash
droidcam-cli 2>&1 | head -1     # prints the usage: the client is installed
ls /sys/module | grep v4l2loopback
ls /dev/video*
```

If the module is not loaded, load it now, and at every boot. Both need administrator
rights:

```bash
modprobe v4l2loopback_dc                                     # now (as root)
echo v4l2loopback_dc > /etc/modules-load.d/droidcam.conf     # at boot (as root)
```

The DroidCam driver has a fixed picture size, 640x480 by default. To change it,
create `/etc/modprobe.d/droidcam.conf` (as root) and reboot:

```
options v4l2loopback_dc width=1280 height=720
```

### Permission to use the device

Your user must be able to open `/dev/videoN`. On most systems that means the `video`
group:

```bash
groups | grep -w video || echo "not in the video group"
```

To join it, run `gpasswd -a "$USER" video` as root, then log out and back in.

## 3. Optional extras

| For | Install | Notes |
|---|---|---|
| iPhone over USB | `usbmuxd`, `libimobiledevice` | Plug the phone in and tap **Trust**. usbmuxd usually starts by itself when an iPhone is plugged in. |
| Android over USB | `android-tools` (adb) | Turn on Developer options and **USB debugging** on the phone, and accept the prompt. |
| Preview in the popup | `ffmpeg` | |
| Phone as a microphone | the `snd-aloop` kernel module | Load it like the driver above: `modprobe snd-aloop`. |
| Better device detection | `v4l-utils` | Recommended when both v4l2loopback and v4l2loopback-dc are loaded. |

## 4. Install the plugin

From the [Omarchy plugin marketplace](https://omarchyplugins.com), or from a terminal:

```bash
omarchy plugin add https://github.com/saurasanchezpablo/oma-cam.git --enable
```

`omarchy plugin add` warns that plugins run as unsandboxed code inside the shell; the
plugin's code is in that repository if you want to read it first. Without `--enable`
it lands disabled; enable it with:

```bash
omarchy plugin enable io.github.saurasanchezpablo.droidcam
```

A webcam icon appears in the right section of the bar. To move it:

```bash
omarchy bar move io.github.saurasanchezpablo.droidcam --section center
```

## 5. Connect the phone

Click the bar icon and open **Settings**.

**Over Wi-Fi.** Choose **Wi-Fi** (or leave **Auto**), enter the WiFi IP and port from
the app, and click **Save & connect**. The phone and the computer must be on the same
network. If you used the DroidCam desktop app before, **Import from app** fills
everything in.

**Over USB.** Leave **Auto**, or choose **iPhone USB** / **Android USB**, and plug the
phone in with the app open. Auto prefers USB when a phone is attached and falls back to
Wi-Fi.

Within a few seconds the status turns to **Live** and the icon lights up. From then on
the plugin connects at login and reconnects by itself.

If it does not, click **Check**: the setup check lists what is missing and how to fix
it.

Using the DroidCam desktop window too? The phone serves one client at a time. While the
window is streaming from the same phone the plugin waits; close the window, or turn on
**Take over** in Settings to let the plugin close it.

## 6. Check that apps see the camera

Pick the camera in the app's video settings. It is named **Droidcam** (the DroidCam
driver) or **DroidCam**/**Dummy video device** (plain v4l2loopback). Quick test:

```bash
ffplay /dev/video0     # the device the popup shows under "Device"
```

Browsers ask for camera access as usual. The popup's **In use by** line shows the apps
that have the camera open.

## 7. Update

```bash
omarchy plugin update io.github.saurasanchezpablo.droidcam
```

It shows the changes and asks before updating. Settings are kept.

## 8. Remove

```bash
omarchy plugin remove io.github.saurasanchezpablo.droidcam
```

This disables the plugin, which stops the stream and removes the bar icon and its
settings, then deletes the plugin folder (`~/.config/omarchy/plugins/io.github.saurasanchezpablo.droidcam`).
The plugin leaves nothing else behind: the optional preview picture lives in a
private folder (`$XDG_RUNTIME_DIR/droidcam-omarchy`) and is deleted as soon as the popup
closes.

The DroidCam client, the driver and the phone app are separate; uninstall them with
your package manager or the official uninstaller if you no longer need them.

## 9. Troubleshooting

| The popup says | Do this |
|---|---|
| droidcam-cli is not installed | Step 2. If it is installed somewhere unusual, set `cliPath`: `omarchy-shell io.github.saurasanchezpablo.droidcam configure '{"cliPath":"/opt/droidcam/droidcam-cli"}'` |
| No camera device | Load the driver (step 2). After a kernel update, DKMS must rebuild it: reinstall the driver package. |
| Can't open the camera device | Join the `video` group and log in again. |
| The camera device has the wrong format | Plain v4l2loopback must use YU12; prefer the DroidCam driver. |
| No phone address | Enter the WiFi IP, or plug the phone in. |
| Phone not reachable | Open the app; check the IP (it can change), and that both are on the same network. Guest networks and some routers block devices from talking to each other. |
| Phone refused the stream | Another client is streaming from it, or the app is in the background. |
| usbmuxd is not running | Install `usbmuxd` and re-plug the iPhone. |
| USB debugging not allowed | Accept the prompt on the phone; re-plug if it does not show. |
| In use by another DroidCam client | Close the DroidCam window or the other `droidcam-cli`, or turn on **Take over**. |

For scripts and bug reports, the full state is one command away:

```bash
omarchy-shell io.github.saurasanchezpablo.droidcam status
```
