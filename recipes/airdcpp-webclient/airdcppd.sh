#!/bin/sh
# airdcppd launcher (cvcpkg airdcpp-webclient): runs the daemon from libexec/ with the prefix's
# Web UI, so the prefix can live anywhere. Every argument is passed through; a --web-resources
# on the command line wins.
set -e
# Follow symlinks to the real bin/airdcppd one link at a time: plain readlink is on Linux and macOS
# alike, and readlink -f is not on every macOS.
self=$0
while [ -L "$self" ]; do
  link=$(readlink "$self")
  case "$link" in
    /*) self=$link ;;
    *) self=$(dirname "$self")/$link ;;
  esac
done
prefix=$(cd "$(dirname "$self")/.." && pwd -P)
daemon="$prefix/libexec/airdcpp-webclient/airdcppd"
for arg in "$@"; do
  case "$arg" in
    --web-resources=*) exec "$daemon" "$@" ;;
  esac
done
exec "$daemon" "--web-resources=$prefix/share/airdcpp/web-resources/" "$@"
