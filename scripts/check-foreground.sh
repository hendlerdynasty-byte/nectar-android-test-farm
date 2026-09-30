#!/usr/bin/env bash
set -euo pipefail
: "${PACKAGE:?}"
ADB="${ADB:-$(command -v adb)}"
ACTIVITY=$("$ADB" shell dumpsys activity activities 2>/dev/null | grep -E 'topResumedActivity|mResumedActivity' || true)
WINDOW=$("$ADB" shell dumpsys window windows 2>/dev/null | grep -E 'mCurrentFocus|mFocusedApp' || true)
if grep -F "$PACKAGE" <<< "$ACTIVITY" >/dev/null || grep -F "$PACKAGE" <<< "$WINDOW" >/dev/null; then
  echo "foreground verified: $PACKAGE"
else
  echo "foreground not verified: $PACKAGE" >&2
  exit 1
fi
