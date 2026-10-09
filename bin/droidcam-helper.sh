#!/usr/bin/env bash
# DroidCam helper for the Omarchy plugin. Every system check and every
# long-running process goes through here, so the shell only parses short
# "key=value" lines. Run it as `bash droidcam-helper.sh <command> ...`.
#
# Commands:
#   run <cli> <args...>       run droidcam-cli and supervise the stream
#   check <mode> <host> <port> <device> <cli> <ownpid>
#                             what a connection attempt needs right now
#   phone <host> <port>       phone name, battery, cameras, Pro controls
#   put <host> <port> <path>  one camera control request (HTTP PUT)
#   consumers <device> <pids> apps that have the camera open
#   others <ownpid>           other DroidCam clients running
#   release <pids...>         ask these DroidCam clients to quit
#   doctor <mode> <host> <port> <device> <cli>
#                             full setup check
#   snapshot <device> <file>  grab one frame into a private dir (needs ffmpeg)
#   forget <file>             delete the preview frame
#   import                    settings from the DroidCam app's config
set -u

# Limits for every request to the phone: small replies, short timeouts,
# plain HTTP, no redirects.
curl_phone() {
  curl --silent --show-error --max-time 4 --connect-timeout 3 \
    --max-filesize 65536 --proto =http --max-redirs 0 "$@"
}

valid_host() { [[ $1 =~ ^[A-Za-z0-9._:-]{1,253}$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( $1 > 0 && $1 < 65536 )); }

url_host() {
  # Bracket IPv6 literals.
  if [[ $1 == *:* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}

# Print the value on one line, with control characters removed.
one_line() { tr -d '\000-\037' | head -c 4096; }

# ---------- Devices ----------

# Each loopback video device as "path|kind|card", kind dc (the DroidCam
# driver), loopback (plain v4l2loopback) or "" (not a loopback device).
# Uses v4l2-ctl when installed (the same bus check droidcam-cli does),
# sysfs otherwise.
list_devices() {
  local dev name bus kind card
  local have_dc=0 have_lb=0
  [[ -d /sys/module/v4l2loopback_dc ]] && have_dc=1
  [[ -d /sys/module/v4l2loopback ]] && have_lb=1
  for dev in /dev/video[0-9]*; do
    [[ -e $dev ]] || continue
    name=$(cat "/sys/class/video4linux/${dev#/dev/}/name" 2>/dev/null)
    kind="" card=$name
    if command -v v4l2-ctl >/dev/null 2>&1; then
      local info
      info=$(v4l2-ctl -d "$dev" --info 2>/dev/null)
      bus=$(sed -n 's/^[[:space:]]*Bus info[[:space:]]*: //p' <<<"$info" | head -n1)
      card=$(sed -n 's/^[[:space:]]*Card type[[:space:]]*: //p' <<<"$info" | head -n1)
      case $bus in
        platform:v4l2loopback_dc*) kind=dc ;;
        platform:v4l2loopback*) kind=loopback ;;
      esac
    elif (( have_dc && !have_lb )); then
      kind=dc
    elif (( have_lb && !have_dc )); then
      kind=loopback
    elif (( have_dc )) && [[ $name == "Loopback video device" ]]; then
      # The DroidCam driver's fixed sysfs name. Plain v4l2loopback can use it
      # too, so this is a best guess without v4l2-ctl.
      kind=dc
    elif (( have_lb )); then
      kind=loopback
    fi
    [[ -n $kind ]] && printf '%s|%s|%s\n' "$dev" "$kind" "$card"
  done
}

# The device droidcam-cli would pick: the first DroidCam driver device,
# else the first plain loopback device.
pick_device() {
  local devices
  devices=$(list_devices)
  local line
  line=$(grep -m1 '|dc|' <<<"$devices") || line=$(grep -m1 '|loopback|' <<<"$devices") || return 1
  printf '%s\n' "${line%%|*}"
}

device_format() {
  cat "/sys/class/video4linux/${1#/dev/}/format" 2>/dev/null | one_line
}

# ---------- USB ----------

# An attached iPhone/iPad (Apple vendor id), no daemon needed.
apple_attached() {
  grep -qsx '05ac' /sys/bus/usb/devices/*/idVendor
}

usbmuxd_running() {
  [[ -S /run/usbmuxd || -S /var/run/usbmuxd ]]
}

# An attached device with an ADB interface (class ff, subclass 42, protocol 01).
adb_interface_attached() {
  local d
  for d in /sys/bus/usb/devices/*:*; do
    [[ $(cat "$d/bInterfaceClass" 2>/dev/null) == ff ]] || continue
    [[ $(cat "$d/bInterfaceSubClass" 2>/dev/null) == 42 ]] || continue
    [[ $(cat "$d/bInterfaceProtocol" 2>/dev/null) == 01 ]] && return 0
  done
  return 1
}

# "device", "unauthorized", "offline" or "" for the first adb device.
adb_state() {
  command -v adb >/dev/null 2>&1 || return 1
  timeout 5 adb devices 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $2; exit }'
}

# ---------- Processes ----------

# Other droidcam / droidcam-cli processes of this user, except our own, as
# "pid|name|peer": peer is the host:port of its open TCP stream, or empty
# when it is idle (or streaming over USB through usbmuxd).
other_clients() {
  local own=${1:-0} pid comm peer streams=""
  command -v ss >/dev/null 2>&1 && streams=$(ss -Htnp state established 2>/dev/null)
  for pid in $(pgrep -u "$(id -u)" -x 'droidcam|droidcam-cli' 2>/dev/null); do
    [[ $pid == "$own" ]] && continue
    comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
    peer=$(awk -v p="pid=$pid," 'index($0, p) { print $4; exit }' <<<"$streams")
    printf '%s|%s|%s\n' "$pid" "$comm" "$peer"
  done
}

socket_count() {
  find "/proc/$1/fd" -maxdepth 1 -lname 'socket:*' 2>/dev/null | wc -l
}

# ---------- Commands ----------

# The client to run as an argv prefix. A .py path (the test stand-in in
# dev/) runs through python3, so it needs no exec bit.
cli_argv() {
  if [[ $1 == *.py && -f $1 ]]; then printf '%s\n' python3 "$1"; else printf '%s\n' "$1"; fi
}

have_cli() {
  [[ $1 == *.py && -f $1 ]] || command -v "$1" >/dev/null 2>&1
}

cmd_run() {
  local cli=$1; shift
  have_cli "$cli" || { echo "Error: droidcam-cli not found" >&2; exit 127; }
  local parent=$PPID child
  local -a argv
  mapfile -t argv < <(cli_argv "$cli")
  # Line-buffered stdout, so "Video: /dev/videoN" arrives at once.
  command -v stdbuf >/dev/null 2>&1 && argv=(stdbuf -oL "${argv[@]}")
  # If this script is killed outright (the shell unloading the plugin), the
  # client gets SIGINT instead of holding on to the phone.
  command -v setpriv >/dev/null 2>&1 && argv=(setpriv --pdeathsig INT -- "${argv[@]}")
  # Background jobs get /dev/null as stdin unless it is redirected
  # explicitly; the control keys arrive on our stdin.
  exec 3<&0
  "${argv[@]}" "$@" <&3 &
  child=$!
  exec 3<&-
  echo "@pid $child"

  stop_child() {
    kill -INT "$child" 2>/dev/null
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$child" 2>/dev/null || return 0
      sleep 0.2
    done
    kill -KILL "$child" 2>/dev/null
  }
  trap 'stop_child; exit 0' TERM INT HUP

  # droidcam-cli never exits when the stream ends: the video thread closes its
  # socket and the process idles. So watch its sockets: once streaming, fewer
  # sockets than at the peak means the stream is gone.
  local elapsed=0 peak=0 live=0 n
  while kill -0 "$child" 2>/dev/null; do
    if ! kill -0 "$parent" 2>/dev/null; then stop_child; exit 0; fi
    n=$(socket_count "$child")
    (( n > peak )) && peak=$n
    if (( !live && elapsed >= 3 && n > 0 )); then
      live=1
      echo "@live"
    fi
    if (( live && n < peak )); then
      echo "@lost"
      stop_child
      exit 75
    fi
    # Never streaming and no socket left: refused, or the app is not
    # running. Wait long enough for adb's server to start on the first run.
    if (( !live && n == 0 && (peak > 0 && elapsed >= 3 || elapsed >= 8) )); then
      echo "@refused"
      stop_child
      exit 76
    fi
    if (( elapsed < 10 )); then
      sleep 1 & wait $!
      elapsed=$((elapsed + 1))
    else
      sleep 5 & wait $!
      elapsed=$((elapsed + 5))
    fi
  done
  wait "$child"
  local rc=$?
  echo "@exit $rc"
  exit "$rc"
}

cmd_check() {
  local mode=$1 host=$2 port=$3 device=$4 cli=$5 own=${6:-0}
  if have_cli "$cli"; then echo "cli=1"; else echo "cli=0"; fi

  local line
  while IFS= read -r line; do [[ -n $line ]] && echo "other=$line"; done < <(other_clients "$own" | head -n 5)

  if [[ -n $device ]]; then
    if [[ -c $device ]]; then echo "device=$device"; else echo "device_missing=$device"; fi
  else
    local picked
    picked=$(pick_device) && echo "device=$picked" || echo "device_missing="
  fi
  local dev_path=${device:-${picked:-}}
  if [[ -n $dev_path && -c $dev_path ]]; then
    [[ -r $dev_path && -w $dev_path ]] && echo "access=1" || echo "access=0"
    echo "format=$(device_format "$dev_path")"
    local kind
    kind=$(list_devices | grep -m1 "^$dev_path|" | cut -d'|' -f2)
    echo "kind=$kind"
  fi

  if [[ $mode == auto || $mode == ios ]]; then
    apple_attached && echo "ios_attached=1" || echo "ios_attached=0"
    usbmuxd_running && echo "usbmuxd=1" || echo "usbmuxd=0"
  fi
  if [[ $mode == auto || $mode == adb ]]; then
    if command -v adb >/dev/null 2>&1; then
      echo "adb=1"
      # Only ask adb (which starts its server) when a phone with an ADB
      # interface is plugged in.
      if adb_interface_attached || [[ $mode == adb ]]; then
        echo "adb_state=$(adb_state)"
      fi
    else
      echo "adb=0"
    fi
  fi
  if [[ $mode == auto || $mode == wifi ]] && [[ -n $host ]]; then
    if valid_host "$host" && valid_port "$port" \
      && curl_phone -o /dev/null "http://$(url_host "$host"):$port/v1/phone/name" 2>/dev/null; then
      echo "wifi=1"
    else
      echo "wifi=0"
    fi
  fi
}

cmd_phone() {
  local host=$1 port=$2
  valid_host "$host" && valid_port "$port" || { echo "reachable=0"; return; }
  local base="http://$(url_host "$host"):$port" name
  if ! name=$(curl_phone --fail "$base/v1/phone/name" 2>/dev/null); then
    echo "reachable=0"
    return
  fi
  echo "reachable=1"
  echo "name=$(one_line <<<"$name")"
  echo "battery=$(curl_phone --fail "$base/v1/phone/battery_info" 2>/dev/null | one_line)"
  echo "cameras=$(curl_phone --fail "$base/v1/camera/camera_list" 2>/dev/null | head -n 8 | paste -sd '|' | one_line)"
  local tmp code
  tmp=$(mktemp) || return
  code=$(curl_phone -o "$tmp" -w '%{http_code}' "$base/v1/camera/info" 2>/dev/null)
  echo "info_code=$code"
  [[ $code == 200 ]] && echo "info=$(one_line <"$tmp")"
  rm -f "$tmp"
}

cmd_put() {
  local host=$1 port=$2 path=$3
  valid_host "$host" && valid_port "$port" || { echo "code=0"; return; }
  # Only camera controls, with a numeric argument at most.
  [[ $path =~ ^/v[13]/camera/[a-z_]+(/-?[0-9]+(\.[0-9]+)?)?$ ]] || { echo "code=0"; return; }
  echo "code=$(curl_phone -o /dev/null -X PUT -w '%{http_code}' "http://$(url_host "$host"):$port$path" 2>/dev/null)"
}

cmd_consumers() {
  local device=$1 skip=" ${2:-} " link pid comm seen=" "
  [[ -c $device ]] || return 0
  # One find over every process's fds; other users' processes are not visible.
  while IFS= read -r link; do
    pid=${link#/proc/}; pid=${pid%%/*}
    [[ $skip == *" $pid "* || $seen == *" $pid "* ]] && continue
    seen+="$pid "
    comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
    [[ $comm == droidcam || $comm == droidcam-cli ]] && continue
    echo "app=$comm"
  done < <(find /proc/[0-9]*/fd -maxdepth 1 -lname "$device" 2>/dev/null)
}

cmd_others() {
  local line
  while IFS= read -r line; do echo "other=$line"; done < <(other_clients "${1:-0}")
}

# Asks the given DroidCam clients to quit: SIGINT (droidcam-cli's clean
# exit), then SIGTERM after 2 seconds. Only pids that are still droidcam
# processes of this user are touched.
cmd_release() {
  local pid line i alive targets=()
  for pid in "$@"; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    while IFS= read -r line; do
      if [[ ${line%%|*} == "$pid" ]]; then
        kill -INT "$pid" 2>/dev/null && targets+=("$pid") && echo "released=$(cut -d'|' -f2 <<<"$line")"
      fi
    done < <(other_clients 0)
  done
  (( ${#targets[@]} )) || return 0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    alive=0
    for pid in "${targets[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
    (( alive )) || return 0
    sleep 0.2
  done
  for pid in "${targets[@]}"; do kill -TERM "$pid" 2>/dev/null; done
  return 0
}

cmd_doctor() {
  local mode=$1 host=$2 port=$3 device=$4 cli=$5
  if [[ $cli == *.py ]] && have_cli "$cli"; then echo "cli=$cli"
  elif command -v "$cli" >/dev/null 2>&1; then echo "cli=$(command -v "$cli")"; else echo "cli="; fi
  command -v curl >/dev/null 2>&1 && echo "curl=1" || echo "curl=0"
  command -v v4l2-ctl >/dev/null 2>&1 && echo "v4l2ctl=1" || echo "v4l2ctl=0"
  command -v ffmpeg >/dev/null 2>&1 && echo "ffmpeg=1" || echo "ffmpeg=0"
  [[ -d /sys/module/v4l2loopback_dc ]] && echo "module_dc=1" || echo "module_dc=0"
  [[ -d /sys/module/v4l2loopback ]] && echo "module_loopback=1" || echo "module_loopback=0"
  [[ -d /sys/module/snd_aloop ]] && echo "module_aloop=1" || echo "module_aloop=0"
  local line
  while IFS= read -r line; do [[ -n $line ]] && echo "loop_device=$line"; done < <(list_devices)
  local dev=${device:-$(pick_device)}
  if [[ -n $dev ]]; then
    echo "device=$dev"
    if [[ -c $dev ]]; then
      [[ -r $dev && -w $dev ]] && echo "access=1" || echo "access=0"
      echo "format=$(device_format "$dev")"
    else
      echo "access=0"
    fi
  fi
  id -nG | tr ' ' '\n' | grep -qx video && echo "video_group=1" || echo "video_group=0"
  apple_attached && echo "ios_attached=1" || echo "ios_attached=0"
  usbmuxd_running && echo "usbmuxd=1" || echo "usbmuxd=0"
  if command -v adb >/dev/null 2>&1; then
    echo "adb=1"
    if adb_interface_attached || [[ $mode == adb ]]; then echo "adb_state=$(adb_state)"; fi
  else
    echo "adb=0"
  fi
  adb_interface_attached && echo "android_attached=1" || echo "android_attached=0"
  if [[ -n $host ]]; then
    if valid_host "$host" && valid_port "$port" \
      && curl_phone -o /dev/null "http://$(url_host "$host"):$port/v1/phone/name" 2>/dev/null; then
      echo "wifi=1"
    else
      echo "wifi=0"
    fi
  fi
  while IFS= read -r line; do [[ -n $line ]] && echo "other=$line"; done < <(other_clients 0)
}

# The preview frames are camera pictures: keep them in a directory only we
# can enter, never in one that is a symlink or belongs to someone else.
private_dir() {
  local dir=$1
  ( umask 077 && mkdir -p -- "$dir" ) 2>/dev/null || return 1
  [[ -d $dir && ! -L $dir && -O $dir ]] || return 1
  chmod 700 -- "$dir" 2>/dev/null
}

# Only the plugin's own preview file, by name.
preview_file() {
  [[ $(basename -- "$1") == preview.jpg && $(basename -- "$(dirname -- "$1")") == droidcam-omarchy ]]
}

cmd_snapshot() {
  local device=$1 file=$2
  command -v ffmpeg >/dev/null 2>&1 || { echo "ok=0"; return; }
  [[ -c $device ]] && preview_file "$file" || { echo "ok=0"; return; }
  private_dir "$(dirname -- "$file")" || { echo "ok=0"; return; }
  umask 077
  if timeout 5 ffmpeg -nostdin -loglevel error -y -f v4l2 -i "$device" \
      -frames:v 1 -vf "scale=320:-2" -q:v 6 "$file.tmp.jpg" 2>/dev/null; then
    mv -f -- "$file.tmp.jpg" "$file"
    echo "ok=1"
  else
    rm -f -- "$file.tmp.jpg"
    echo "ok=0"
  fi
}

# Deletes the preview picture (the popup closed, or preview was turned off).
cmd_forget() {
  preview_file "$1" || return 0
  rm -f -- "$1" "$1.tmp.jpg"
}

cmd_import() {
  local file=${XDG_CONFIG_HOME:-$HOME/.config}/droidcam
  [[ -f $file ]] || { echo "found=0"; return; }
  echo "found=1"
  local key value
  while IFS='=' read -r key value; do
    case $key in
      ip|port|size|vertical_flip|horizontal_flip|audio|type)
        echo "$key=$(one_line <<<"$value")" ;;
    esac
  done < <(head -n 50 "$file")
}

command=${1:-}
shift || true
case $command in
  run) cmd_run "$@" ;;
  check) cmd_check "${1:-wifi}" "${2:-}" "${3:-4747}" "${4:-}" "${5:-droidcam-cli}" "${6:-0}" ;;
  phone) cmd_phone "${1:-}" "${2:-4747}" ;;
  put) cmd_put "${1:-}" "${2:-4747}" "${3:-}" ;;
  consumers) cmd_consumers "${1:-}" "${2:-}" ;;
  others) cmd_others "${1:-0}" ;;
  release) cmd_release "$@" ;;
  doctor) cmd_doctor "${1:-auto}" "${2:-}" "${3:-4747}" "${4:-}" "${5:-droidcam-cli}" ;;
  snapshot) cmd_snapshot "${1:-}" "${2:-}" ;;
  forget) cmd_forget "${1:-}" ;;
  import) cmd_import ;;
  *) echo "usage: droidcam-helper.sh <run|check|phone|put|consumers|others|release|doctor|snapshot|forget|import> ..." >&2; exit 2 ;;
esac
