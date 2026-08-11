#!/bin/zsh
#
# Take PSM 0x1001 from bluetoothd, then run the probe.
#
#   ./grab-channel.sh [bt-address] [-- probe args...]
#
# Needs `brew install blueutil switchaudio-osx`.
#
# Why this works. Disconnecting the AirPods by hand is not enough: macOS pulls
# them back within a second, because they are the Mac's default *audio output
# device* and coreaudiod re-acquires them the moment they drop. Move the output
# elsewhere first and that pressure is gone — the disconnect sticks, bluetoothd
# releases the AAP channel, and openL2CAPChannelSync wins it on the first try.
#
# This replaces the old advice of racing a manual disconnect, and it is what
# `--steal` was reaching for and never achieved.
set -u

ADDR=${1:-}
if [[ -n $ADDR && $ADDR != --* ]]; then shift; else
  ADDR=$(blueutil --paired | sed -n 's/^address: \([^,]*\),.*AirPods.*/\1/p' | head -1)
fi
[[ -z $ADDR ]] && { print -u2 "No paired AirPods found. Pass an address."; exit 1; }
[[ ${1:-} == "--" ]] && shift

ATTEMPTS=${ATTEMPTS:-20}
HERE=${0:A:h}

# Pick somewhere that is not the buds to park the audio output.
ORIG=$(SwitchAudioSource -c)
FALLBACK=$(SwitchAudioSource -a -t output | grep -iE "speaker|colunas|built-in|integrad" | head -1)
[[ -z $FALLBACK ]] && FALLBACK=$(SwitchAudioSource -a -t output | grep -vi airpod | head -1)
[[ -z $FALLBACK ]] && { print -u2 "No non-AirPods output device to park on."; exit 1; }

restore() {
  print "[teardown] output -> $ORIG"
  SwitchAudioSource -t output -s "$ORIG" >/dev/null 2>&1
}
trap restore EXIT INT TERM

osascript -e 'tell application "Spotify" to pause' >/dev/null 2>&1
osascript -e 'tell application "Music" to pause'   >/dev/null 2>&1
print "[setup] output -> $FALLBACK"
SwitchAudioSource -t output -s "$FALLBACK" >/dev/null || exit 1
sleep 1

# Never pipe the probe straight into `grep -q`: it exits on the first match and
# SIGPIPEs the probe mid-run. Capture the attempt, then look at it.
RUN=$(mktemp)
for i in $(seq 1 $ATTEMPTS); do
  print "===== attempt $i ====="
  blueutil --disconnect $ADDR
  sleep 0.35
  "$HERE/hr-probe" --address $ADDR "$@" | tee "$RUN"
  if grep -q "Channel open." "$RUN"; then
    print "[done] channel opened on attempt $i"
    exit 0
  fi
done

print -u2 "[fail] channel never opened in $ATTEMPTS attempts"
exit 1
