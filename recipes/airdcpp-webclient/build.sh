#!/usr/bin/env bash
# airdcpp-webclient: the daemon from upstream's source (CMake), the Web UI from cvcpkg's
# airdcpp-webui package, and the bin/airdcppd launcher. See the recipe's notes for why each piece
# is where it is. Every input but the compiler is a cvcpkg package: cmake, ninja and python
# (python312) run from the build or dependency prefix, never the machine's copies. Linux and macOS;
# cvcpkg runs this with macOS's own /bin/bash 3.2 there.
set -euo pipefail

: "${CVC_SOURCE_DIR:?CVC_SOURCE_DIR must be set}"
: "${CVC_BUILD_DIR:?CVC_BUILD_DIR must be set}"
: "${CVC_INSTALL_DIR:?CVC_INSTALL_DIR must be set}"
: "${CVC_DEPS_PREFIX:?CVC_DEPS_PREFIX must be set}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CVC_JOBS="${CVC_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
case "${CVC_PLATFORM:-$(uname -s | tr '[:upper:]' '[:lower:]')}" in
  macos|darwin) macos=1 ;;
  *) macos="" ;;
esac
case "$(echo "${CVC_BUILD_TYPE:-release}" | tr '[:upper:]' '[:lower:]')" in
  debug) BUILD_TYPE=Debug ;;
  *) BUILD_TYPE=Release ;;
esac

AIRDCPP_VERSION=2.14.0
WEBUI_VERSION=2.14.0

# A file from one of cvcpkg's packages, in the build or the dependency prefix.
cvc_file() {
  local rel="$1" pkg="$2" root
  for root in ${CVC_BUILD_PREFIX:+"$CVC_BUILD_PREFIX"} "$CVC_DEPS_PREFIX"; do
    [[ -e "$root/$rel" ]] && { echo "$root/$rel"; return; }
  done
  echo "airdcpp-webclient: $rel (cvcpkg package '$pkg') is in neither the build nor the dependency prefix; run cvcpkg install-deps airdcpp-webclient --include-host-tools" >&2
  exit 1
}
cmake_bin="$(cvc_file bin/cmake cmake)"
ninja_bin="$(cvc_file bin/ninja ninja)"
python_bin="$(cvc_file bin/python3.12 python312)"
# Upstream's INSTALL_WEB_UI step runs `npm install airdcpp-webui@<version>` and copies its dist/;
# cvcpkg's airdcpp-webui is that package's dist/.
webui_dir="$(cvc_file share/airdcpp-webui airdcpp-webui)"
webui_license="$(cvc_file share/licenses/airdcpp-webui/LICENSE airdcpp-webui)"
"$cmake_bin" --version | head -1
echo "cmake ${cmake_bin}; ninja ${ninja_bin}; python ${python_bin}; Web UI ${webui_dir}"

# bin/ (where upstream installs the daemon), libexec/airdcpp-webclient/ (where it ends up) and lib/
# all reach lib/.
if [[ -n "$macos" ]]; then
  install_rpath='@loader_path/../lib;@loader_path/../../lib'
else
  install_rpath='$ORIGIN/../lib;$ORIGIN/../../lib'
fi

prefix_path="${CVC_DEPS_PREFIX}"
if [[ -n "${CVC_BUILD_PREFIX:-}" && "${CVC_BUILD_PREFIX}" != "${CVC_DEPS_PREFIX}" ]]; then
  prefix_path="${CVC_DEPS_PREFIX};${CVC_BUILD_PREFIX}"
fi

# RESOURCE_DIRECTORY and GLOBAL_CONFIG_DIRECTORY are compiled in. The first is only a fallback
# here (the launcher passes --web-resources); the second is where upstream reads an optional
# system-wide dcppboot.xml, /etc/airdcpp/ as in its distribution packages.
"$cmake_bin" -G Ninja -S "${CVC_SOURCE_DIR}" -B "${CVC_BUILD_DIR}" \
  -DCMAKE_MAKE_PROGRAM="${ninja_bin}" \
  -DPYTHON_EXECUTABLE="${python_bin}" \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DCMAKE_INSTALL_PREFIX="${CVC_INSTALL_DIR}" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_PREFIX_PATH="${prefix_path}" \
  -DBUILD_SHARED_LIBS=ON \
  -DINSTALL_WEB_UI=OFF \
  -DENABLE_NATPMP=OFF \
  -DENABLE_TBB=OFF \
  -DSTRIP=OFF \
  -DRESOURCE_DIRECTORY=/usr/share/airdcpp/ \
  -DGLOBAL_CONFIG_DIRECTORY=/etc/airdcpp/ \
  -DCMAKE_INSTALL_RPATH="${install_rpath}"
"$cmake_bin" --build "${CVC_BUILD_DIR}" -j "${CVC_JOBS}"
"$cmake_bin" --install "${CVC_BUILD_DIR}"

# On Apple, upstream installs the daemon as an application bundle, airdcppd.app, at the prefix root,
# and libairdcpp and libairdcpp-webapi into "AirDC++;Web;Client.app/Contents/MacOS" (its
# PROJECT_NAME_GLOBAL is a CMake list there). The bundle layout only gets in the way of a daemon,
# so the daemon and the libraries move to where they are on Linux and the bundles go.
if [[ -n "$macos" ]]; then
  app_bin="${CVC_INSTALL_DIR}/airdcppd.app/Contents/MacOS/airdcppd"
  test -f "$app_bin" || { echo "airdcpp-webclient: no $app_bin after the install" >&2; exit 1; }
  install -d "${CVC_INSTALL_DIR}/bin" "${CVC_INSTALL_DIR}/lib"
  mv "$app_bin" "${CVC_INSTALL_DIR}/bin/airdcppd"
  found=""
  for lib in "${CVC_INSTALL_DIR}"/*.app/Contents/MacOS/libairdcpp*.dylib; do
    [[ -e "$lib" || -L "$lib" ]] || continue
    mv "$lib" "${CVC_INSTALL_DIR}/lib/"
    found=1
  done
  [[ -n "$found" ]] || { echo "airdcpp-webclient: no libairdcpp*.dylib after the install" >&2; exit 1; }
  rm -rf "${CVC_INSTALL_DIR}"/*.app
fi

# The daemon moves to libexec/; bin/airdcppd becomes the launcher.
install -d "${CVC_INSTALL_DIR}/libexec/airdcpp-webclient"
mv "${CVC_INSTALL_DIR}/bin/airdcppd" "${CVC_INSTALL_DIR}/libexec/airdcpp-webclient/airdcppd"
install -m 0755 "${SCRIPT_DIR}/airdcppd.sh" "${CVC_INSTALL_DIR}/bin/airdcppd"

resources="${CVC_INSTALL_DIR}/share/airdcpp/web-resources"
rm -rf "${resources}" && install -d "${resources}"
cp -R "${webui_dir}/." "${resources}/"
test -f "${resources}/index.html" || { echo "airdcpp-webclient: the Web UI has no index.html" >&2; exit 1; }

# Licence texts: upstream's tree has none, so cvcpkg would find nothing to copy (see recipe.yaml).
licenses="${CVC_INSTALL_DIR}/share/licenses/airdcpp-webclient"
install -d "${licenses}"
install -m 0644 "${SCRIPT_DIR}/GPL-3.0.txt" "${licenses}/GPL-3.0.txt"
install -m 0644 "${webui_license}" "${licenses}/airdcpp-webui-LICENSE"
cat > "${licenses}/README" <<TXT
airdcpp-webclient ${AIRDCPP_VERSION}, built from https://github.com/airdcpp-web/airdcpp-webclient
(tag ${AIRDCPP_VERSION}). The daemon is free software under the GNU General Public License, version 3 or (at
your option) any later version: GPL-3.0.txt. Its Web UI, airdcpp-webui ${WEBUI_VERSION}
(https://github.com/airdcpp-web/airdcpp-webui), is MIT: airdcpp-webui-LICENSE.
TXT

echo "cvcpkg: airdcpp-webclient -> ${CVC_INSTALL_DIR} (bin/airdcppd launcher, libexec/airdcpp-webclient/airdcppd)"
