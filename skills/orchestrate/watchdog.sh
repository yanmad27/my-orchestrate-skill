#!/bin/sh
# Runs watchdog.mjs with node, or with Paseo's bundled Electron runtime when node is absent.
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if command -v node >/dev/null 2>&1; then
  exec node "$dir/watchdog.mjs" "$@"
fi
res=$(dirname -- "$(readlink -f -- "${PASEO_CLI:-$(command -v paseo)}")")/..
for exe in "$res/../Frameworks/Paseo Helper.app/Contents/MacOS/Paseo Helper" "$res/../Paseo.bin" "$res/../Paseo"; do
  if [ -x "$exe" ]; then
    ELECTRON_RUN_AS_NODE=1 exec "$exe" "$dir/watchdog.mjs" "$@"
  fi
done
echo "watchdog: need node or the Paseo app on PATH" >&2
exit 1
