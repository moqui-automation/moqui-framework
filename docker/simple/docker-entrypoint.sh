#!/usr/bin/env sh
set -e

MOQUI_HOME="${MOQUI_HOME:-/opt/moqui}"
VENV_DIR="${VENV_DIR:-$MOQUI_HOME/runtime/python_venv}"
PORT="${PORT:-80}"

unset PYTHONPATH
export PYTHONNOUSERSITE=1

PYBIN="$VENV_DIR/bin/python"
[ -x "$PYBIN" ] || { echo "ERROR: venv python not found at $PYBIN" >&2; exit 2; }

# Resolve libjep.so and site-packages using the venv
read -r JEP_LIB SITE_PKGS <<EOF
$("$PYBIN" - <<'PY'
import sysconfig, os
site = sysconfig.get_paths().get('purelib') or ''
lib  = os.path.join(site, 'jep', 'libjep.so')
print((lib if os.path.isfile(lib) else '') + ' ' + site)
PY
)
EOF

[ -f "$JEP_LIB" ] || { echo "ERROR: libjep.so not found in venv (looked at $JEP_LIB)" >&2; exit 3; }

# Ensure the JVM finds the native library
export LD_LIBRARY_PATH="$(dirname "$JEP_LIB")${LD_LIBRARY_PATH:+:}$LD_LIBRARY_PATH"

# Start Moqui
# exec java -Djep.lib="$JEP_LIB" -jar moqui.war
exec java -Djep.lib="$JEP_LIB" -Djep_site_pkgs="$SITE_PKGS" -cp . MoquiStart "port=$PORT" "$@"
