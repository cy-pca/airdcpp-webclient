#!/usr/bin/env bash
# airdcpp-webclient smoke test, run by cvcpkg on the staged tree before packing: the documented
# setup commands (--add-user and --configure, answered on stdin), then the daemon itself through
# bin/airdcppd: its HTTP API answers with the version, the Web UI's index is served, and SIGTERM
# stops it cleanly. HOME points into a temp dir, so nothing touches the builder's own settings.
# Linux and macOS; cvcpkg runs this with macOS's own /bin/bash 3.2 there.
set -euo pipefail
: "${CVC_INSTALL_DIR:?CVC_INSTALL_DIR must be set}"
: "${CVC_DEPS_PREFIX:?CVC_DEPS_PREFIX must be set}"

# Physical paths: the launcher resolves its own (macOS's temp dir is /var -> /private/var).
T="$(cd "$(mktemp -d)" && pwd -P)"
pid=""
cleanup() { [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT

# The staged tree reaches its dependencies' libraries through the deps prefix, not its rpaths
# ($ORIGIN, @loader_path), unless the two are one prefix (after an install).
root="$(cd "$CVC_INSTALL_DIR" && pwd -P)"
libpath=""
if [[ "$root" != "$(cd "$CVC_DEPS_PREFIX" && pwd -P)" ]]; then
  if [[ "$(uname -s)" == Darwin ]]; then
    # macOS drops DYLD_* from the environment of anything it protects, /bin/sh (the launcher's
    # interpreter) and /bin/bash among them, so no loader path reaches the daemon. Instead the
    # staged tree is copied into a prefix of its own whose lib/ also links every dependency's
    # dylib, the layout an install gives it, and the daemon loads them through its @loader_path
    # rpaths alone.
    mkdir "$T/root"
    cp -R "$CVC_INSTALL_DIR/." "$T/root/"
    root="$T/root"
    for lib in "$CVC_DEPS_PREFIX"/lib/*.dylib; do
      [[ -e "$lib" ]] || continue
      [[ -e "$root/lib/${lib##*/}" || -L "$root/lib/${lib##*/}" ]] || ln -s "$lib" "$root/lib/"
    done
  else
    # The daemon only: not curl.
    libpath="${CVC_DEPS_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  fi
fi
# Execs the daemon through bin/airdcppd (env and the launcher both exec too).
run_air() {
  if [[ -n "$libpath" ]]; then
    exec env LD_LIBRARY_PATH="$libpath" "$root/bin/airdcppd" "$@"
  fi
  exec "$root/bin/airdcppd" "$@"
}
air() { (run_air "$@"); }
export HOME="$T"
cfg="$T/cfg"

air -v | tee "$T/version"
grep -q '2\.14\.0' "$T/version"

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
printf 'smoke\nsmoke-pass\nsmoke-pass\n' | air -c="$cfg" --add-user >/dev/null
printf '%s\n0\n' "$port" | air -c="$cfg" --configure >/dev/null
test -f "$cfg/web-server.json"

# Backgrounded, run_air is a subshell that execs, so $! is the daemon itself.
run_air -c="$cfg" --no-auto-connect </dev/null >"$T/daemon.log" 2>&1 &
pid=$!
info=""
for _ in $(seq 1 60); do
  info="$(curl -fsS -u smoke:smoke-pass "http://127.0.0.1:${port}/api/v1/system/system_info" 2>/dev/null || true)"
  [[ -n "$info" ]] && break
  sleep 0.5
done
[[ -n "$info" ]] || { echo "airdcppd's API did not answer"; cat "$T/daemon.log"; exit 1; }
echo "$info" | grep -q '"client_version":"AirDC++w 2\.14\.0' \
  || { echo "unexpected system_info: $info"; exit 1; }
curl -fsS -H 'Accept: text/html' "http://127.0.0.1:${port}/" | grep -qi '<title' \
  || { echo "the Web UI index was not served"; cat "$T/daemon.log"; exit 1; }

kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
pid=""
[[ "$rc" == 0 ]] || { echo "airdcppd exited $rc after SIGTERM"; cat "$T/daemon.log"; exit 1; }
# Its stdout is block-buffered into the log, so this is only complete once it has exited.
grep -q "Web resources path: ${root}/share/airdcpp/web-resources/" "$T/daemon.log" \
  || { echo "airdcppd did not use the prefix's web resources"; cat "$T/daemon.log"; exit 1; }
echo "airdcpp-webclient smoke test OK (port ${port})"
