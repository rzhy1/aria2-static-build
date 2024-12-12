#!/bin/bash -e

# This scrip is for static cross compiling
# Please run this scrip in docker image: "rzhy/ubuntu:x86_64-w64-mingw32" or "ubuntu:rolling"
# Artifacts will copy to the same directory.
export CROSS_HOST="x86_64-w64-mingw32"
export CROSS_ROOT="/cross_root"
export PATH="${CROSS_ROOT}/bin:${PATH}"
export CROSS_PREFIX="${CROSS_ROOT}/${CROSS_HOST}"
export LD=ld.lld
set -o pipefail
export USE_ZLIB_NG="${USE_ZLIB_NG:-1}"
retry() {
  # max retry 5 times
  try=5
  # sleep 3s every retry
  sleep_time=30
  for i in $(seq ${try}); do
    echo "executing with retry: $@" >&2
    if eval "$@"; then
      return 0
    else
      echo "execute '$@' failed, tries: ${i}" >&2
      sleep ${sleep_time}
    fi
  done
  echo "execute '$@' failed" >&2
  return 1
}
source /etc/os-release
dpkg --add-architecture i386

export DEBIAN_FRONTEND=noninteractive
# keep debs in container for store cache in docker volume
rm -f /etc/apt/apt.conf.d/*
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https

echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载最新版mingw-w64⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
USE_GCC15=0
if [ "$USE_GCC15" -eq 1 ]; then
    echo "使用最新版的 mingw-w64-x86_64-toolchain (GCC 15)..."
    curl -SLf -o "/tmp/mingw-w64-x86_64-toolchain.tar.zst" "https://github.com/rzhy1/build-mingw-w64/releases/download/mingw-w64/mingw-w64-x86_64-toolchain.tar.zst"
    tar --zstd -xf "/tmp/mingw-w64-x86_64-toolchain.tar.zst" -C "/usr/"
else
    curl -SLf -o "/tmp/x86_64-w64-mingw32.tar.xz" "https://github.com/rzhy1/musl-cross/releases/download/mingw-w64/x86_64-w64-mingw32.tar.xz"
    mkdir -p ${CROSS_ROOT}
    tar -xf "/tmp/x86_64-w64-mingw32.tar.xz" --strip-components=1 -C ${CROSS_ROOT}
fi
end_time=$(date +%s.%N)
duration1=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")
echo "x86_64-w64-mingw32-gcc版本是："
x86_64-w64-mingw32-gcc --version

BUILD_ARCH="$(gcc -dumpmachine)"
TARGET_ARCH="${CROSS_HOST%%-*}"
TARGET_HOST="${CROSS_HOST#*-}"
case "${TARGET_ARCH}" in
"armel"*)
  TARGET_ARCH=armel
  ;;
"arm"*)
  TARGET_ARCH=arm
  ;;
esac
case "${TARGET_HOST}" in
*"mingw"*)
  TARGET_HOST=Windows
  hash -r
  # if [ ! -f "/usr/share/keyrings/winehq-archive.key" ]; then
  #   rm -f /usr/share/keyrings/winehq-archive.key.part
  #   retry wget -cT30 -O /usr/share/keyrings/winehq-archive.key.part https://dl.winehq.org/wine-builds/winehq.key
  #   mv -fv /usr/share/keyrings/winehq-archive.key.part /usr/share/keyrings/winehq-archive.key
  # fi
  # if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  #   WINEHQ_URL="http://mirrors.tuna.tsinghua.edu.cn/wine-builds/ubuntu/"
  # else
  #   WINEHQ_URL="http://dl.winehq.org/wine-builds/ubuntu/"
  # fi
  # echo "deb [signed-by=/usr/share/keyrings/winehq-archive.key] ${WINEHQ_URL} ${UBUNTU_CODENAME} main" >/etc/apt/sources.list.d/winehq.list
  export WINEPREFIX=/tmp/
  RUNNER_CHECKER="wine"
  ;;
*)
  TARGET_HOST=Linux
  apt install -y "qemu-user-static"
  RUNNER_CHECKER="qemu-${TARGET_ARCH}-static"
  ;;
esac
export PKG_CONFIG_PATH="${CROSS_PREFIX}/lib64/pkgconfig:${CROSS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
export LDFLAGS="-L${CROSS_PREFIX}/lib64 -L${CROSS_PREFIX}/lib -I${CROSS_PREFIX}/include -s -static --static"
SELF_DIR="$(dirname "$(realpath "${0}")")"
BUILD_INFO="${SELF_DIR}/build_info1.md"

# Create download cache directory
mkdir -p "${SELF_DIR}/downloads/"
export DOWNLOADS_DIR="${SELF_DIR}/downloads"
if [ x"${USE_ZLIB_NG}" = x1 ]; then
  ZLIB=zlib-ng
else
  ZLIB=zlib
fi
if [ x"${USE_LIBRESSL}" = x1 ]; then
  SSL=LibreSSL
else
  SSL=OpenSSL
fi

echo "## aria2c1.exe （zlib_ng & libxml2 & WinTLS ） dependencies:" >>"${BUILD_INFO}"
# 初始化表格
echo "| Dependency | Version | Source |" >>"${BUILD_INFO}"
echo "|------------|---------|--------|" >>"${BUILD_INFO}"
prepare_cmake() {
  local start_time=$(date +%s.%N)
  if ! which cmake &>/dev/null; then
    cmake_latest_ver="$(retry wget -qO- --compression=auto https://cmake.org/download/ \| grep "'Latest Release'" \| sed -r "'s/.*Latest Release\s*\((.+)\).*/\1/'" \| head -1)"
    cmake_binary_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
    cmake_sha256_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-SHA-256.txt"

    if [ -f "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      cd "${DOWNLOADS_DIR}"
      cmake_sha256="$(retry wget -qO- --compression=auto "${cmake_sha256_url}")"
      if ! echo "${cmake_sha256}" | grep "cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" | sha256sum -c; then
        rm -f "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
      fi
    fi
    if [ ! -f "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      retry wget -cT10 -O "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" "${cmake_binary_url}"
    fi
    tar -zxf "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" -C /usr/local --strip-components 1
  fi
  cmake --version
  local end_time=$(date +%s.%N)
  local duration=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")
  echo "$duration" > "cmake_duration.txt"
  find / -name "cmake_duration.txt" 2>/dev/null
  duration2=$(cat cmake_duration.txt)
  echo $duration2
}
prepare_ninja() {
    start_time=$(date +%s.%N)
  if ! which ninja &>/dev/null; then
    ninja_ver="$(retry wget -qO- --compression=auto https://ninja-build.org/ \| grep "'The last Ninja release is'" \| sed -r "'s@.*<b>(.+)</b>.*@\1@'" \| head -1)"
    ninja_binary_url="https://github.com/ninja-build/ninja/releases/download/${ninja_ver}/ninja-linux.zip"
    if [ ! -f "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip" ]; then
      rm -f "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part"
      retry wget -cT10 -O "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part" "${ninja_binary_url}"
      mv -fv "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part" "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip"
    fi
    unzip -d /usr/local/bin "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip"
  fi
  echo "Ninja version $(ninja --version)"
  local end_time=$(date +%s.%N)
  local duration=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")
  echo "$duration" > "ninja_duration.txt"
}

prepare_zlib() {
  local start_time=$(date +%s.%N)
  if [ x"${USE_ZLIB_NG}" = x"1" ]; then
    zlib_ng_latest_tag="$(retry wget -qO- --compression=auto https://api.github.com/repos/zlib-ng/zlib-ng/releases \| jq -r "'.[0].tag_name'")"
    #zlib_ng_latest_url="https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${zlib_ng_latest_tag}.tar.gz"
    zlib_ng_latest_url="https://github.com/zlib-ng/zlib-ng/archive/master.tar.gz"
    if [[ ! $zlib_ng_latest_url =~ master\.tar\.gz ]]; then
      retry wget -cT10 -O "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz.part" "${zlib_ng_latest_url}"
      mv -fv "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz.part" "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz"
      mkdir -p "/usr/src/zlib-ng-${zlib_ng_latest_tag}"
      tar -zxf "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz" --strip-components=1 -C "/usr/src/zlib-ng-${zlib_ng_latest_tag}"
      cd "/usr/src/zlib-ng-${zlib_ng_latest_tag}"
      echo "当前完整路径是: $PWD"
    else
      mkdir -p "/usr/src/zlib-ng"
      cd "/usr/src/zlib-ng"
      wget -q -O- https://github.com/zlib-ng/zlib-ng/archive/master.tar.gz | tar xz
      cd zlib-ng-develop
      echo "当前完整路径是: $PWD"
    fi   
    rm -fr build
    cmake -B build \
      -G Ninja \
      -DBUILD_SHARED_LIBS=OFF \
      -DZLIB_COMPAT=ON \
      -DCMAKE_SYSTEM_NAME="${TARGET_HOST}" \
      -DCMAKE_INSTALL_PREFIX="${CROSS_PREFIX}" \
      -DCMAKE_C_COMPILER="${CROSS_HOST}-gcc" \
      -DCMAKE_CXX_COMPILER="${CROSS_HOST}-g++" \
      -DCMAKE_SYSTEM_PROCESSOR="${TARGET_ARCH}" \
      -DWITH_GTEST=OFF
    cmake --build build
    cmake --install build
    zlib_ng_ver="${zlib_ng_latest_tag}($(grep '^Version:' ${CROSS_PREFIX}/lib/pkgconfig/zlib.pc | awk '{print $2}'))"
    echo "| zlib-ng | ${zlib_ng_ver} | ${zlib_ng_latest_url:-cached zlib-ng} |" >>"${BUILD_INFO}" || exit
    # Fix mingw build sharedlibdir lost issue
    sed -i 's@^sharedlibdir=.*@sharedlibdir=${libdir}@' "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc"
  else
    zlib_tag="$(retry wget -qO- --compression=auto https://zlib.net/ \| grep -i "'<FONT.*FONT>'" \| sed -r "'s/.*zlib\s*([^<]+).*/\1/'" \| head -1)"
    zlib_latest_url="https://zlib.net/zlib-${zlib_tag}.tar.xz"
    if [ ! -f "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz" ]; then
      retry wget -cT10 -O "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz.part" "${zlib_latest_url}"
      mv -fv "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz.part" "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz"
    fi
    mkdir -p "/usr/src/zlib-${zlib_tag}"
    tar -Jxf "${DOWNLOADS_DIR}/zlib-${zlib_tag}.tar.gz" --strip-components=1 -C "/usr/src/zlib-${zlib_tag}"
    cd "/usr/src/zlib-${zlib_tag}"
    if [ x"${TARGET_HOST}" = xWindows ]; then
      make -f win32/Makefile.gcc BINARY_PATH="${CROSS_PREFIX}/bin" INCLUDE_PATH="${CROSS_PREFIX}/include" LIBRARY_PATH="${CROSS_PREFIX}/lib" SHARED_MODE=0 PREFIX="${CROSS_HOST}-" -j$(nproc) install
    else
      CHOST="${CROSS_HOST}" ./configure --prefix="${CROSS_PREFIX}" --static
      make -j$(nproc)
      make install
    fi
    zlib_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc | awk '{print $2}'")"
    echo "| zlib | ${zlib_ver} | ${zlib_latest_url:-cached zlib} |" >>"${BUILD_INFO}"
  fi
  local end_time=$(date +%s.%N)
  local duration=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")
  echo "$duration" > "zlib_duration.txt"
}

prepare_xz() {
  local start_time=$(date +%s.%N)
  # Download from github release (now breakdown)
  # xz_release_info="$(retry wget -qO- --compression=auto https://api.github.com/repos/tukaani-project/xz/releases \| jq -r "'[.[] | select(.prerelease == false)][0]'")"
  # local xz_tag="$(printf '%s' "${xz_release_info}" | jq -r '.tag_name')"
  # local xz_archive_name="$(printf '%s' "${xz_release_info}" | jq -r '.assets[].name | select(endswith("tar.xz"))')"
  # local xz_latest_url="https://github.com/tukaani-project/xz/releases/download/${xz_tag}/${xz_archive_name}"
  # Download from sourceforge
  xz_tag="$(retry wget -qO- --compression=auto https://sourceforge.net/projects/lzmautils/files/ \| grep -i \'span class=\"sub-label\"\' \| head -1 \| sed -r "'s/.*xz-(.+)\.tar\.gz.*/\1/'")"
  xz_latest_url="https://sourceforge.net/projects/lzmautils/files/xz-${xz_tag}.tar.xz"
  if [ ! -f "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz.part" "${xz_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz.part" "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz"
  fi
  mkdir -p "/usr/src/xz-${xz_tag}"
  tar -Jxf "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz" --strip-components=1 -C "/usr/src/xz-${xz_tag}"
  cd "/usr/src/xz-${xz_tag}"
  ./configure \
    --host="${CROSS_HOST}" \
    --prefix="${CROSS_PREFIX}" \
    --enable-silent-rules \
    --enable-static \
    --disable-shared \
    --disable-doc \
    --enable-debug=no \
    --disable-nls \
    CFLAGS="-O2 -g0"  \
    CXXFLAGS="-O2 -g0" 
  make -j$(nproc)
  make install
   xz_ver="$(grep 'Version:' "${CROSS_PREFIX}/lib/pkgconfig/liblzma.pc" | awk '{print $2}')"
  echo "| xz | ${xz_ver} | ${xz_latest_url:-cached xz} |" >>"${BUILD_INFO}" 
  local end_time=$(date +%s.%N)
  local duration=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")
  echo "$duration" > "xz_duration.txt"
}

prepare_libxml2() {
  local start_time=$(date +%s.%N)
  libxml2_latest_url="$(retry wget -qO- --compression=auto 'https://gitlab.gnome.org/api/graphql' --header="'Content-Type: application/json'" --post-data="'{\"query\":\"query {project(fullPath:\\\"GNOME/libxml2\\\"){releases(first:1,sort:RELEASED_AT_DESC){nodes{assets{links{nodes{directAssetUrl}}}}}}}\"}'" \| jq -r "'.data.project.releases.nodes[0].assets.links.nodes[0].directAssetUrl'")"
  llibxml2_tag="$(echo "${libxml2_latest_url}" | sed -r 's/.*libxml2-(.+).tar.*/\1/')"
  libxml2_filename="$(echo "${libxml2_latest_url}" | sed -r 's/.*(libxml2-(.+).tar.*)/\1/')"
  if [ ! -f "${DOWNLOADS_DIR}/${libxml2_filename}" ]; then
    retry wget -c -O "${DOWNLOADS_DIR}/${libxml2_filename}.part" "${libxml2_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/${libxml2_filename}.part" "${DOWNLOADS_DIR}/${libxml2_filename}"
  fi
  mkdir -p "/usr/src/libxml2-${libxml2_tag}"
  tar -axf "${DOWNLOADS_DIR}/${libxml2_filename}" --strip-components=1 -C "/usr/src/libxml2-${libxml2_tag}"
  cd "/usr/src/libxml2-${libxml2_tag}"
  ./configure \
    --host="${CROSS_HOST}" \
    --prefix="${CROSS_PREFIX}" \
    --enable-silent-rules \
    --without-python \
    --without-icu \
    --enable-static \
    --disable-shared \
    CFLAGS="-O2 -g0" \
    CXXFLAGS="-O2 -g0"
  make -j$(nproc)
  make install
  llibxml2_ver="$(grep 'Version:' "${CROSS_PREFIX}/lib/pkgconfig/"libxml-*.pc | awk '{print $2}')"
  echo "| libxml2 | ${libxml2_ver} | ${libxml2_latest_url:-cached libxml2} |" >>"${BUILD_INFO}"
  local end_time=$(date +%s.%N)
  local duration=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")
  echo "$duration" > "libxml2_duration.txt"
}

prepare_sqlite() {
  local start_time=$(date +%s.%N)
  lsqlite_tag="$(retry wget -qO- --compression=auto https://www.sqlite.org/index.html \| sed -nr "'s/.*>Version (.+)<.*/\1/p'")"
  lsqlite_latest_url="https://github.com/sqlite/sqlite/archive/release.tar.gz"
  if [ ! -f "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz.part" "${sqlite_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz.part" "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/sqlite-${sqlite_tag}"
  tar -zxf "${DOWNLOADS_DIR}/sqlite-${sqlite_tag}.tar.gz" --strip-components=1 -C "/usr/src/sqlite-${sqlite_tag}"
  cd "/usr/src/sqlite-${sqlite_tag}"
  if [ x"${TARGET_HOST}" = x"Windows" ]; then
    ln -sf mksourceid.exe mksourceid
    SQLITE_EXT_CONF="config_TARGET_EXEEXT=.exe"
  fi
  ./configure --build="${BUILD_ARCH}" --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared  ${SQLITE_EXT_CONF} \
    --disable-debug \
    --enable-editline=no \
    --enable-fts3=no --enable-fts4=no --enable-fts5=no \
    --enable-rtree=no \
    --enable-session=no \
    CFLAGS="-O2 -g0  -flto=$(nproc)" \
    CXXFLAGS="-O2 -g0  -flto=$(nproc)" 
  make -j$(nproc)
  make install
   sqlite_ver="$(grep 'Version:' "${CROSS_PREFIX}/lib/pkgconfig/"sqlite*.pc | awk '{print $2}')"
  echo "| sqlite | ${sqlite_ver} | ${sqlite_latest_url:-cached sqlite} |" >>"${BUILD_INFO}"
  local end_time=$(date +%s.%N)
  local duration=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")
  echo "$duration" > "sqlite_duration.txt"
}

prepare_c_ares() {
  local start_time=$(date +%s.%N)
  cares_tag="$(retry wget -qO- --compression=auto https://api.github.com/repos/c-ares/c-ares/releases | jq -r '.[0].tag_name | sub("^v"; "")')"
  #cares_latest_url="https://github.com/c-ares/c-ares/releases/download/v${cares_tag}/c-ares-${cares_tag}.tar.gz"
  cares_latest_url="https://github.com/c-ares/c-ares/archive/master.tar.gz"
  if [[ ! $cares_latest_url =~ master\.tar\.gz ]]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/c-ares-${cares_tag}.tar.gz.part" "${cares_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/c-ares-${cares_tag}.tar.gz.part" "${DOWNLOADS_DIR}/c-ares-${cares_tag}.tar.gz"
    mkdir -p "/usr/src/c-ares-${cares_tag}"
    tar -zxf "${DOWNLOADS_DIR}/c-ares-${cares_tag}.tar.gz" --strip-components=1 -C "/usr/src/c-ares-${cares_tag}"
    cd "/usr/src/c-ares-${cares_tag}"
    echo "当前完整路径是: $PWD"
  else
    mkdir -p "/usr/src/c-ares"
    cd "/usr/src/c-ares"
    wget -q -O- https://github.com/c-ares/c-ares/archive/master.tar.gz | tar xz
    cd c-ares-main
    echo "当前完整路径是: $PWD"
  fi
  if [ ! -f "./configure" ]; then
    autoreconf -i
  fi
  ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" \
    --enable-static \
    --disable-shared \
    --enable-silent-rules \
    --disable-tests \
    --without-random \
    CFLAGS="-O2 -g0 -flto=$(nproc)" \
    CXXFLAGS="-O2 -g0 -flto=$(nproc)"
  make -j$(nproc)
  make install
  cares_ver="$(grep 'Version:' "${CROSS_PREFIX}/lib/pkgconfig/libcares.pc" | awk '{print $2}')"
  echo "| c-ares | ${cares_ver} | ${cares_latest_url:-cached c-ares} |" >>"${BUILD_INFO}"
  local end_time=$(date +%s.%N)
  local duration=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")
  echo "$duration" > "c_ares_duration.txt"
}

prepare_libssh2() {
  local start_time=$(date +%s.%N)
  libssh2_tag="$(retry wget -qO- --compression=auto https://libssh2.org/ \| sed -nr "'s@.*libssh2 ([^<]*).*released on.*@\1@p'")"
  libssh2_latest_url="https://libssh2.org/download/libssh2-${libssh2_tag}.tar.gz"
  if [ ! -f "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz.part" "${libssh2_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz.part" "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/libssh2-${libssh2_tag}"
  tar -zxf "${DOWNLOADS_DIR}/libssh2-${libssh2_tag}.tar.gz" --strip-components=1 -C "/usr/src/libssh2-${libssh2_tag}"
  cd "/usr/src/libssh2-${libssh2_tag}"
  ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared --enable-silent-rules \
    --disable-examples-build \
    --disable-docker-tests \
    --disable-sshd-tests \
    --disable-debug \
    CFLAGS="-O2 -g0 -flto=$(nproc)" \
    CXXFLAGS="-O2 -g0 -flto=$(nproc)"
  make -j$(nproc)
  make install
  #unset CFLAGS
  libssh2_ver="$(grep 'Version:' "${CROSS_PREFIX}/lib/pkgconfig/libssh2.pc" | awk '{print $2}')"
  echo "| libssh2 | ${libssh2_ver} | ${libssh2_latest_url:-cached libssh2} |" >>"${BUILD_INFO}"
  local end_time=$(date +%s.%N)
  local duration=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")
  echo "$duration" > "libssh2_duration.txt"
}

build_aria2() {
  local start_time=$(date +%s.%N)
  if [ -n "${ARIA2_VER}" ]; then
    aria2_tag="${ARIA2_VER}"
  else
    aria2_tag=master
    # Check download cache whether expired
    if [ -f "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz" ]; then
      cached_file_ts="$(stat -c '%Y' "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz")"
      current_ts="$(date +%s)"
      if [ "$((${current_ts} - "${cached_file_ts}"))" -gt 86400 ]; then
        echo "Delete expired aria2 archive file cache..."
        rm -f "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz"
      fi
    fi
  fi

  if [ -n "${ARIA2_VER}" ]; then
    aria2_latest_url="https://github.com/aria2/aria2/releases/download/release-${ARIA2_VER}/aria2-${ARIA2_VER}.tar.gz"
  else
    aria2_latest_url="https://github.com/aria2/aria2/archive/master.tar.gz"
  fi
  echo "aria2_latest_url: $aria2_latest_url"  

  if [ ! -f "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz.part" "${aria2_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz.part" "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/aria2-${aria2_tag}"
  tar -zxf "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz" --strip-components=1 -C "/usr/src/aria2-${aria2_tag}"
  cd "/usr/src/aria2-${aria2_tag}"
  sed -i 's/"1", 1, 16/"1", 1, 1024/' src/OptionHandlerFactory.cc
  sed -i 's/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1M", 1_m, 1_g))/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1K", 1_k, 1_g))/g' src/OptionHandlerFactory.cc
  sed -i 's/void sock_state_cb(void\* arg, int fd, int read, int write)/void sock_state_cb(void\* arg, ares_socket_t fd, int read, int write)/g' src/AsyncNameResolver.cc
  sed -i 's/void AsyncNameResolver::handle_sock_state(int fd, int read, int write)/void AsyncNameResolver::handle_sock_state(ares_socket_t fd, int read, int write)/g' src/AsyncNameResolver.cc
  sed -i 's/void handle_sock_state(int sock, int read, int write)/void handle_sock_state(ares_socket_t sock, int read, int write)/g' src/AsyncNameResolver.h

  if [ ! -f ./configure ]; then
    autoreconf -i
  fi
  if [ x"${TARGET_HOST}" = xwin ]; then
    ARIA2_EXT_CONF='--without-openssl'
  # else
  #   ARIA2_EXT_CONF='--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt'
  fi
  ./configure \
    --host="${CROSS_HOST}" \
    --prefix="${CROSS_PREFIX}" \
    --enable-static \
    --disable-shared \
    --enable-silent-rules \
    --disable-checking \
    --enable-checking=release \
    ARIA2_STATIC=yes \
    ${ARIA2_EXT_CONF} \
    CFLAGS="-O2 -g0 -flto=$(nproc)" \
    CXXFLAGS="-O2 -g0 -flto=$(nproc)"
  make -j$(nproc)
  make install
  ARIA2_VER=$(grep -oP 'aria2 \K\d+(\.\d+)*' NEWS)
  echo "| aria2 |  ${ARIA2_VER} | ${aria2_latest_url:-cached aria2} |" >>"${BUILD_INFO}"
  local end_time=$(date +%s.%N)
  local duration=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")
  echo "$duration" > "aria2_duration.txt"
}

echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 cmake⭐⭐⭐⭐⭐⭐"
prepare_cmake
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 ninja⭐⭐⭐⭐⭐⭐"
prepare_ninja
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 zlib、xz、libxml2、sqlite、c_ares、libssh2⭐⭐⭐⭐⭐⭐"
prepare_zlib &
prepare_xz &
prepare_libxml2 &
prepare_sqlite &
prepare_c_ares &
prepare_libssh2 &
wait
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 aria2⭐⭐⭐⭐⭐⭐"
build_aria2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 编译完成⭐⭐⭐⭐⭐⭐"

duration2=$(cat cmake_duration.txt)
duration3=$(cat ninja_duration.txt)
duration4=$(cat zlib_duration.txt)
duration5=$(cat xz_duration.txt)
duration6=$(cat libxml2_duration.txt)
duration7=$(cat sqlite_duration.txt)
duration8=$(cat c_ares_duration.txt)
duration9=$(cat libssh2_duration.txt)
duration10=$(cat aria2_duration.txt)

echo "下载mingw-w64用时: ${duration1}s"
echo "编译 cmake 用时: ${duration2}s"
echo "编译 ninja 用时: ${duration3}s"
echo "编译 zlib 用时: ${duration4}s"
echo "编译 xz 用时: ${duration5}s"
echo "编译 libxml2 用时: ${duration6}s"
echo "编译 sqlite 用时: ${duration7}s"
echo "编译 c_ares 用时: ${duration8}s"
echo "编译 libssh2 用时: ${duration9}s"
echo "编译 aria2 用时: ${duration10}s"

# get release
${CROSS_HOST}-strip "${CROSS_PREFIX}/bin/aria2c.exe"
mv -fv "${CROSS_PREFIX}/bin/aria2c.exe" "${SELF_DIR}/aria2c1.exe"
