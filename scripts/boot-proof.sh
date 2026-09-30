#!/usr/bin/env bash
set -euo pipefail
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}"
export PATH="$sdk/cmdline-tools/latest/bin:$sdk/platform-tools:$sdk/emulator:$PATH"
yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager 'platform-tools' 'emulator' "system-images;android-${TARGET_API};google_apis;x86_64" >/dev/null
export ANDROID_AVD_HOME="${RUNNER_TEMP}/nectar-avd"
mkdir -p "$ANDROID_AVD_HOME"
echo no | avdmanager create avd -n nectar-proof -k "system-images;android-${TARGET_API};google_apis;x86_64" --force >/dev/null
accel=(-accel off)
if [[ -e /dev/kvm ]]; then sudo chmod 666 /dev/kvm; accel=(-accel on); fi
emulator -avd nectar-proof -no-window -no-audio -no-snapshot -no-boot-anim -gpu swiftshader_indirect "${accel[@]}" >"${RUNNER_TEMP}/emulator-proof.log" 2>&1 &
pid=$!
deadline=$((SECONDS+1100))
until [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n ')" == 1 ]]; do
  kill -0 "$pid" 2>/dev/null || exit 21
  (( SECONDS < deadline )) || exit 22
  sleep 5
done
deadline=$((SECONDS+120))
until adb shell service check package 2>/dev/null | grep -q 'found'; do (( SECONDS < deadline )) || exit 23; sleep 3; done
adb shell input keyevent 82
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb shell svc wifi disable
adb shell settings put global airplane_mode_on 1
echo "DEVICE_API=$(adb shell getprop ro.build.version.sdk | tr -d '\r\n')" >> "$GITHUB_ENV"
