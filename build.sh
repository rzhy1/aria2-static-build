#!/bin/bash -e

# This script is for static cross compiling
# Please run this script in docker image: abcfy2/muslcc-toolchain-ubuntu:${CROSS_HOST}
# E.g: docker run --rm -v `git rev-parse --show-toplevel`:/build abcfy2/muslcc-toolchain-ubuntu:arm-linux-musleabi /build/build.sh
# Artifacts will be copied to the same directory.

set -o pipefail

# value from: https://musl.cc/ (without -cross or -native)
# export CROSS_HOST="${CROSS_HOST:-arm-linux-musleabi}"
# value from openssl source: ./Configure LIST
case "${CROSS_HOST}" in
arm-linux*)
  export OPENSSL_COMPILER=linux-armv4
  ;;
aarch64-linux*)
  export OPENSSL_COMPILER=linux-aarch64
  ;;
mips-linux* | mipsel-linux*)
  export OPENSSL_COMPILER=linux-mips32
  ;;
mips64-linux*)
  export OPENSSL_COMPILER=linux64-mips64
  ;;
x86_64-linux*)
  export OPENSSL_COMPILER=linux-x86_64
  ;;
s390x-linux*)
  export OPENSSL_COMPILER=linux64-s390x
  ;;
*)
  export OPENSSL_COMPILER=gcc
  ;;
esac
# export CROSS_ROOT="${CROSS_ROOT:-/cross_root}"
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
# Ubuntu mirror for local building
if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  cat >/etc/apt/sources.list <<EOF
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://mirror.sjtu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF
fi

export DEBIAN_FRONTEND=noninteractive

# keep debs in container for store cache in docker volume
rm -f /etc/apt/apt.conf.d/*
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https

apt update
apt install -y g++ \
  make \
  libtool \
  jq \
  pkgconf \
  file \
  tcl \
  autoconf \
  automake \
  autopoint \
  patch \
  wget \
  unzip

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
  rm -fr "${CROSS_ROOT}"
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
  apt update
  apt install -y wine mingw-w64
  export WINEPREFIX=/tmp/
  RUNNER_CHECKER="wine"
  ;;
*)
  TARGET_HOST=Linux
  apt install -y "qemu-user-static"
  RUNNER_CHECKER="qemu-${TARGET_ARCH}-static"
  ;;
esac

export PATH="${CROSS_ROOT}/bin:${PATH}"
export CROSS_PREFIX="${CROSS_ROOT}/${CROSS_HOST}"
export PKG_CONFIG_PATH="${CROSS_PREFIX}/lib64/pkgconfig:${CROSS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
export LDFLAGS="-L${CROSS_PREFIX}/lib64 -L${CROSS_PREFIX}/lib -I${CROSS_PREFIX}/include -s -static --static"
SELF_DIR="$(dirname "$(realpath "${0}")")"
BUILD_INFO="${SELF_DIR}/build_info.md"

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

echo "## Build Info - ${CROSS_HOST} With ${SSL} and ${ZLIB}" >"${BUILD_INFO}"
echo "Building using these dependencies:" >>"${BUILD_INFO}"

prepare_cmake() {
  if ! which cmake &>/dev/null; then
    cmake_latest_ver="$(retry wget -qO- --compression=auto https://cmake.org/download/ | grep "'Latest Release'" | sed -r "'s/.*Latest Release\s*\((.+)\).*/\1/'" | head -1)"
    cmake_binary_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
    cmake_sha256_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-SHA-256.txt"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      cmake_binary_url="https://mirror.ghproxy.com/${cmake_binary_url}"
      cmake_sha256_url="https://mirror.ghproxy.com/${cmake_sha256_url}"
    fi
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
    mkdir -p /usr/local/cmake
    tar -zxf "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" --strip-components=1 -C /usr/local/cmake
    ln -sf /usr/local/cmake/bin/* /usr/local/bin/
  fi
  cmake --version
}

prepare_ninja() {
  if ! which ninja &>/dev/null; then
    ninja_ver=$(retry wget -qO- --compression=auto https://api.github.com/repos/ninja-build/ninja/tags | jq -r '.[0].name')
    ninja_binary_url="https://github.com/ninja-build/ninja/releases/download/${ninja_ver}/ninja-linux.zip"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      ninja_binary_url="https://mirror.ghproxy.com/${ninja_binary_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip" ]; then
      rm -f "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part"
      retry wget -cT10 -O "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part" "${ninja_binary_url}"
      mv -fv "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part" "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip"
    fi
    unzip -o "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip" -d /usr/local/bin
  fi
  ninja --version
}

prepare_zlib() {
  if [ x"${USE_ZLIB_NG}" = x1 ]; then
    ZLIB=zlib-ng
  else
    ZLIB=zlib
  fi
  if [ x"${USE_ZLIB_NG}" = x1 ]; then
    zlib_ver=$(retry wget -qO- --compression=auto https://api.github.com/repos/zlib-ng/zlib-ng/tags | jq -r '.[0].name')
  else
    zlib_ver=$(retry wget -qO- --compression=auto https://api.github.com/repos/madler/zlib/tags | jq -r '.[0].name')
  fi
  echo "zlib Version: ${zlib_ver}" >>"${BUILD_INFO}"
  if [ x"${USE_ZLIB_NG}" = x1 ]; then
    zlib_url="https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${zlib_ver}.tar.gz"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      zlib_url="https://mirror.ghproxy.com/${zlib_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/zlib-ng-${zlib_ver}.tar.gz" ]; then
      rm -f "${DOWNLOADS_DIR}/zlib-ng-${zlib_ver}.tar.gz.part"
      retry wget -cT10 -O "${DOWNLOADS_DIR}/zlib-ng-${zlib_ver}.tar.gz.part" "${zlib_url}"
      mv -fv "${DOWNLOADS_DIR}/zlib-ng-${zlib_ver}.tar.gz.part" "${DOWNLOADS_DIR}/zlib-ng-${zlib_ver}.tar.gz"
    fi
    tar -zxf "${DOWNLOADS_DIR}/zlib-ng-${zlib_ver}.tar.gz" -C "${SELF_DIR}"
    cd "${SELF_DIR}/zlib-ng-${zlib_ver}"
  else
    zlib_url="https://github.com/madler/zlib/archive/refs/tags/${zlib_ver}.tar.gz"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      zlib_url="https://mirror.ghproxy.com/${zlib_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/zlib-${zlib_ver}.tar.gz" ]; then
      rm -f "${DOWNLOADS_DIR}/zlib-${zlib_ver}.tar.gz.part"
      retry wget -cT10 -O "${DOWNLOADS_DIR}/zlib-${zlib_ver}.tar.gz.part" "${zlib_url}"
      mv -fv "${DOWNLOADS_DIR}/zlib-${zlib_ver}.tar.gz.part" "${DOWNLOADS_DIR}/zlib-${zlib_ver}.tar.gz"
    fi
    tar -zxf "${DOWNLOADS_DIR}/zlib-${zlib_ver}.tar.gz" -C "${SELF_DIR}"
    cd "${SELF_DIR}/zlib-${zlib_ver}"
  fi
  cmake -Bbuild -DCMAKE_INSTALL_PREFIX="${CROSS_PREFIX}" -DZLIB_COMPAT=ON
  cmake --build build --target install -- -j$(nproc)
}

prepare_ssl() {
  if [ x"${USE_LIBRESSL}" = x1 ]; then
    SSL=LibreSSL
  else
    SSL=OpenSSL
  fi
  if [ x"${USE_LIBRESSL}" = x1 ]; then
    ssl_ver=$(retry wget -qO- --compression=auto https://api.github.com/repos/libressl-portable/portable/tags | jq -r '.[0].name')
  else
    ssl_ver=$(retry wget -qO- --compression=auto https://api.github.com/repos/openssl/openssl/tags | jq -r '.[0].name')
  fi
  echo "SSL Version: ${ssl_ver}" >>"${BUILD_INFO}"
  if [ x"${USE_LIBRESSL}" = x1 ]; then
    ssl_url="https://github.com/libressl-portable/portable/archive/refs/tags/${ssl_ver}.tar.gz"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      ssl_url="https://mirror.ghproxy.com/${ssl_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/libressl-${ssl_ver}.tar.gz" ]; then
      rm -f "${DOWNLOADS_DIR}/libressl-${ssl_ver}.tar.gz.part"
      retry wget -cT10 -O "${DOWNLOADS_DIR}/libressl-${ssl_ver}.tar.gz.part" "${ssl_url}"
      mv -fv "${DOWNLOADS_DIR}/libressl-${ssl_ver}.tar.gz.part" "${DOWNLOADS_DIR}/libressl-${ssl_ver}.tar.gz"
    fi
    tar -zxf "${DOWNLOADS_DIR}/libressl-${ssl_ver}.tar.gz" -C "${SELF_DIR}"
    cd "${SELF_DIR}/libressl-${ssl_ver}"
  else
    ssl_url="https://github.com/openssl/openssl/archive/refs/tags/${ssl_ver}.tar.gz"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      ssl_url="https://mirror.ghproxy.com/${ssl_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/openssl-${ssl_ver}.tar.gz" ]; then
      rm -f "${DOWNLOADS_DIR}/openssl-${ssl_ver}.tar.gz.part"
      retry wget -cT10 -O "${DOWNLOADS_DIR}/openssl-${ssl_ver}.tar.gz.part" "${ssl_url}"
      mv -fv "${DOWNLOADS_DIR}/openssl-${ssl_ver}.tar.gz.part" "${DOWNLOADS_DIR}/openssl-${ssl_ver}.tar.gz"
    fi
    tar -zxf "${DOWNLOADS_DIR}/openssl-${ssl_ver}.tar.gz" -C "${SELF_DIR}"
    cd "${SELF_DIR}/openssl-${ssl_ver}"
  fi
  ./config --prefix="${CROSS_PREFIX}" --openssldir="${CROSS_PREFIX}/ssl" no-shared no-tests no-ssl2 no-ssl3
  make -j$(nproc)
  make install
}

prepare_libxml2() {
  libxml2_ver=$(retry wget -qO- --compression=auto https://api.github.com/repos/GNOME/libxml2/tags | jq -r '.[0].name')
  libxml2_url="https://github.com/GNOME/libxml2/archive/refs/tags/${libxml2_ver}.tar.gz"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    libxml2_url="https://mirror.ghproxy.com/${libxml2_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/libxml2-${libxml2_ver}.tar.gz" ]; then
    rm -f "${DOWNLOADS_DIR}/libxml2-${libxml2_ver}.tar.gz.part"
    retry wget -cT10 -O "${DOWNLOADS_DIR}/libxml2-${libxml2_ver}.tar.gz.part" "${libxml2_url}"
    mv -fv "${DOWNLOADS_DIR}/libxml2-${libxml2_ver}.tar.gz.part" "${DOWNLOADS_DIR}/libxml2-${libxml2_ver}.tar.gz"
  fi
  tar -zxf "${DOWNLOADS_DIR}/libxml2-${libxml2_ver}.tar.gz" -C "${SELF_DIR}"
  cd "${SELF_DIR}/libxml2-${libxml2_ver}"
  ./autogen.sh --prefix="${CROSS_PREFIX}" --host="${CROSS_HOST}" --without-python
  make -j$(nproc)
  make install
}

prepare_sqlite() {
  sqlite_ver=$(retry wget -qO- --compression=auto https://api.github.com/repos/sqlite/sqlite/tags | jq -r '.[0].name')
  sqlite_url="https://github.com/sqlite/sqlite/archive/refs/tags/${sqlite_ver}.tar.gz"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    sqlite_url="https://mirror.ghproxy.com/${sqlite_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/sqlite-${sqlite_ver}.tar.gz" ]; then
    rm -f "${DOWNLOADS_DIR}/sqlite-${sqlite_ver}.tar.gz.part"
    retry wget -cT10 -O "${DOWNLOADS_DIR}/sqlite-${sqlite_ver}.tar.gz.part" "${sqlite_url}"
    mv -fv "${DOWNLOADS_DIR}/sqlite-${sqlite_ver}.tar.gz.part" "${DOWNLOADS_DIR}/sqlite-${sqlite_ver}.tar.gz"
  fi
  tar -zxf "${DOWNLOADS_DIR}/sqlite-${sqlite_ver}.tar.gz" -C "${SELF_DIR}"
  cd "${SELF_DIR}/sqlite-${sqlite_ver}"
  ./configure --prefix="${CROSS_PREFIX}" --host="${CROSS_HOST}" --disable-shared
  make -j$(nproc)
  make install
}

prepare_c_ares() {
  cares_ver=$(retry wget -qO- --compression=auto https://api.github.com/repos/c-ares/c-ares/tags | jq -r '.[0].name')
  cares_url="https://github.com/c-ares/c-ares/archive/refs/tags/${cares_ver}.tar.gz"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    cares_url="https://mirror.ghproxy.com/${cares_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/c-ares-${cares_ver}.tar.gz" ]; then
    rm -f "${DOWNLOADS_DIR}/c-ares-${cares_ver}.tar.gz.part"
    retry wget -cT10 -O "${DOWNLOADS_DIR}/c-ares-${cares_ver}.tar.gz.part" "${cares_url}"
    mv -fv "${DOWNLOADS_DIR}/c-ares-${cares_ver}.tar.gz.part" "${DOWNLOADS_DIR}/c-ares-${cares_ver}.tar.gz"
  fi
  tar -zxf "${DOWNLOADS_DIR}/c-ares-${cares_ver}.tar.gz" -C "${SELF_DIR}"
  cd "${SELF_DIR}/c-ares-${cares_ver}"
  ./configure --prefix="${CROSS_PREFIX}" --host="${CROSS_HOST}" --disable-shared
  make -j$(nproc)
  make install
}

prepare_libssh2() {
  libssh2_ver=$(retry wget -qO- --compression=auto https://api.github.com/repos/libssh2/libssh2/tags | jq -r '.[0].name')
  libssh2_url="https://github.com/libssh2/libssh2/archive/refs/tags/${libssh2_ver}.tar.gz"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    libssh2_url="https://mirror.ghproxy.com/${libssh2_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/libssh2-${libssh2_ver}.tar.gz" ]; then
    rm -f "${DOWNLOADS_DIR}/libssh2-${libssh2_ver}.tar.gz.part"
    retry wget -cT10 -O "${DOWNLOADS_DIR}/libssh2-${libssh2_ver}.tar.gz.part" "${libssh2_url}"
    mv -fv "${DOWNLOADS_DIR}/libssh2-${libssh2_ver}.tar.gz.part" "${DOWNLOADS_DIR}/libssh2-${libssh2_ver}.tar.gz"
  fi
  tar -zxf "${DOWNLOADS_DIR}/libssh2-${libssh2_ver}.tar.gz" -C "${SELF_DIR}"
  cd "${SELF_DIR}/libssh2-${libssh2_ver}"
  cmake -Bbuild -DCMAKE_INSTALL_PREFIX="${CROSS_PREFIX}" -DCMAKE_C_COMPILER="${CROSS_HOST}-gcc" -DBUILD_SHARED_LIBS=OFF
  cmake --build build --target install -- -j$(nproc)
}

build_aria2() {
  aria2_ver=$(retry wget -qO- --compression=auto https://api.github.com/repos/rzhy1/aria2/tags | jq -r '.[0].name')
  aria2_url="https://github.com/rzhy1/aria2/archive/refs/tags/${aria2_ver}.tar.gz"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    aria2_url="https://mirror.ghproxy.com/${aria2_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/aria2-${aria2_ver}.tar.gz" ]; then
    rm -f "${DOWNLOADS_DIR}/aria2-${aria2_ver}.tar.gz.part"
    retry wget -cT10 -O "${DOWNLOADS_DIR}/aria2-${aria2_ver}.tar.gz.part" "${aria2_url}"
    mv -fv "${DOWNLOADS_DIR}/aria2-${aria2_ver}.tar.gz.part" "${DOWNLOADS_DIR}/aria2-${aria2_ver}.tar.gz"
  fi
  tar -zxf "${DOWNLOADS_DIR}/aria2-${aria2_ver}.tar.gz" -C "${SELF_DIR}"
  cd "${SELF_DIR}/aria2-${aria2_ver}"
  ./configure --prefix="${CROSS_PREFIX}" --host="${CROSS_HOST}" --without-libnettle --without-libgmp --without-libexpat --without-libxml2 --without-libuv --without-gnutls --without-openssl --without-sqlite3 --without-libcares --without-libssh2
  make -j$(nproc)
  make install
}

# Main build process
prepare_cmake
prepare_ninja
prepare_zlib
prepare_ssl
prepare_libxml2
prepare_sqlite
prepare_c_ares
prepare_libssh2
build_aria2

echo "Build process completed."
