#!/bin/sh
# Stand-in for `xcrun simctl io <udid> recordVideo ... <output>` in SimctlVideoRecorder tests.
# Usage: fake-record-video.sh <mode> <marker-delay-seconds> simctl io <udid> recordVideo ... <output>
#   normal      prints "Recording started" after the delay; on SIGINT writes the output and exits 0
#   no-marker   never prints the marker; on SIGINT writes the output and exits 0
#   early-exit  creates an empty output (as simctl --force does) and fails with exit 22
#   quit        exits 2 after the delay without a marker or a file (a Ctrl+C that reached simctl first)
#   slow-stop   like normal, but takes 10 s to finish after SIGINT; SIGTERM ends it at once
mode="$1"
delay="$2"
shift 2
for output; do :; done

trap 'printf "fake movie data" > "$output"; echo "Recording completed. Writing to disk."; exit 0' INT

case "$mode" in
  slow-stop)
    trap 'sleep 10; printf "fake movie data" > "$output"; exit 0' INT
    sleep "$delay"
    echo "Recording started" >&2
    ;;
  normal)
    sleep "$delay"
    echo "Recording started" >&2
    ;;
  no-marker)
    echo "Recording is warming up" >&2
    ;;
  early-exit)
    : > "$output"
    echo "Error: Device does not have a '9' display port" >&2
    exit 22
    ;;
  quit)
    sleep "$delay"
    exit 2
    ;;
esac

while :; do
  sleep 0.05
done
