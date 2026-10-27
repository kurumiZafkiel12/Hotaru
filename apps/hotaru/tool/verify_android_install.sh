#!/usr/bin/env bash
set -euo pipefail

logs=archive-probe
trap 'timeout 10s adb logcat -d > "$logs/logcat.txt" 2>&1 || true' EXIT
adb logcat -c
adb push "$logs/probe.jar" baseline published candidate /data/local/tmp/
timeout 120s adb shell 'CLASSPATH=/data/local/tmp/probe.jar app_process /system/bin AndroidArchiveProbe /data/local/tmp/baseline/*.apk /data/local/tmp/published/*.apk /data/local/tmp/candidate/*.apk' | tee "$logs/parse.log"
test "$(grep -c '^ARCHIVE_OK ' "$logs/parse.log")" -eq 9
for stage in baseline published candidate; do
    apk=$(find "$stage" -name '*-android-x86_64.apk')
    timeout 120s adb install -r "$apk" | tee "$logs/install-$stage.log"
    grep -qx Success "$logs/install-$stage.log"
done
adb shell am start -W -n dev.hotaru.hotaru/.MainActivity > "$logs/launch.txt"
sleep 10
adb shell pidof dev.hotaru.hotaru > "$logs/pid.txt"
adb shell dumpsys package dev.hotaru.hotaru > "$logs/package.txt"
