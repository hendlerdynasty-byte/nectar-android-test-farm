#!/usr/bin/env bash
set -euo pipefail
DEST="${RUNNER_TEMP:-/tmp}/bundletool-all-1.18.3.jar"
curl -fsSL --retry 3 --max-time 120 -o "$DEST" https://github.com/google/bundletool/releases/download/1.18.3/bundletool-all-1.18.3.jar
echo 'a099cfa1543f55593bc2ed16a70a7c67fe54b1747bb7301f37fdfd6d91028e29  '"$DEST" | sha256sum -c -
echo "BUNDLETOOL_JAR=$DEST" >> "${GITHUB_ENV:?}"
