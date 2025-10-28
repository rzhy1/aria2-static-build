#!/bin/bash -e

export CROSS_HOST="x86_64-w64-mingw32"
export CROSS_ROOT="/cross_root"
export PATH="${CROSS_ROOT}/bin:${PATH}"
export CROSS_PREFIX="${CROSS_ROOT}/${CROSS_HOST}"
export CFLAGS="-I${CROSS_PREFIX}/include -march=tigerlake -mtune=tigerlake -O2 -ffunction-sections -fdata-sections -pipe -flto=$(nproc) -g0"
export CXXFLAGS="$CFLAGS"
export PKG_CONFIG_PATH="${CROSS_PREFIX}/lib64/pkgconfig:${CROSS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
export WINPTHREAD_LIB="${CROSS_ROOT}/x86_64-w64-mingw32/sysroot/usr/x86_64-w64-mingw32/lib"
export LDFLAGS="-L${WINPTHREAD_LIB} -L${CROSS_PREFIX}/lib64 -L${CROSS_PREFIX}/lib -static -s -Wl,--gc-sections -flto=$(nproc)"
export LD=x86_64-w64-mingw32-ld.lld
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
USE_GCC=0
if [ "$USE_GCC" -eq 1 ]; then
    echo "使用最新版的 mingw-w64-x86_64-toolchain (GCC 16)..."
    curl -SLf -o "/tmp/mingw-w64-x86_64-toolchain.tar.zst" "https://github.com/rzhy1/build-mingw-w64/releases/download/mingw-w64/mingw-w64-x86_64-toolchain.tar.zst"
    tar --zstd -xf "/tmp/mingw-w64-x86_64-toolchain.tar.zst" -C "/usr/"
else
    echo "使用相对成熟的 musl-cros (GCC 15)..."
    curl -SLf -o "/tmp/x86_64-w64-mingw32.tar.xz" "https://github.com/rzhy1/musl-cross/releases/download/mingw-w64/x86_64-w64-mingw32-1.tar.xz"
    mkdir -p ${CROSS_ROOT}
    tar -xf "/tmp/x86_64-w64-mingw32.tar.xz" --strip-components=1 -C ${CROSS_ROOT}
fi

ln -s $(which lld-link) /usr/bin/x86_64-w64-mingw32-ld.lld
echo "x86_64-w64-mingw32-gcc版本是："
x86_64-w64-mingw32-gcc --version
#find / -name "*pthread.a"
#find / -name "*pthread.h"
#find / -name "*pthread*.pc"
echo "查询结束"
BUILD_ARCH="$(x86_64-w64-mingw32-gcc -dumpmachine)"
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
}
prepare_ninja() {
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
}

prepare_libiconv() {
  libiconv_tag="$(retry curl -s https://ftp.gnu.org/gnu/libiconv/ | grep -oE 'href="libiconv-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.gz"' | sort -rV | head -n 1 | sed -E 's/href="libiconv-([0-9.]+)\.tar\.gz"/\1/')"
  echo "libiconv最新版本是${libiconv_tag} ，下载地址是https://ftp.gnu.org/gnu/libiconv/libiconv-${libiconv_tag}.tar.gz"
  curl -L https://ftp.gnu.org/gnu/libiconv/libiconv-${libiconv_tag}.tar.gz | tar xz
  cd libiconv-*
  ./configure \
    --host="${CROSS_HOST}" \
    --prefix="${CROSS_PREFIX}" \
    --disable-shared \
    --enable-static
  make -j$(nproc) install
  echo "| libiconv | ${libiconv_tag} | https://ftp.gnu.org/gnu/libiconv/libiconv-${libiconv_tag}.tar.gz |" >>"${BUILD_INFO}"
}

prepare_zlib_ng() {
    zlib_ng_latest_tag="$(retry wget -qO- https://raw.githubusercontent.com/zlib-ng/zlib-ng/master/Makefile.in | grep '^VER=' | cut -d= -f2 | tr -d '"')"
    zlib_ng_latest_url="https://github.com/zlib-ng/zlib-ng/archive/master.tar.gz"
    mkdir -p "/usr/src/zlib-ng"
    cd "/usr/src/zlib-ng"
    wget -q -O- https://github.com/zlib-ng/zlib-ng/archive/master.tar.gz | tar xz
    cd zlib-ng-develop
    echo "当前完整路径是: $PWD" 
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
    zlib_ng_ver="${zlib_ng_latest_tag}"
    echo "| zlib-ng | ${zlib_ng_ver} | ${zlib_ng_latest_url:-cached zlib-ng} |" >>"${BUILD_INFO}" || exit
    # Fix mingw build sharedlibdir lost issue
    sed -i 's@^sharedlibdir=.*@sharedlibdir=${libdir}@' "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc"
}

prepare_xz() {
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
    --disable-nls
  make -j$(nproc)
  make install
   xz_ver="$(grep 'Version:' "${CROSS_PREFIX}/lib/pkgconfig/liblzma.pc" | awk '{print $2}')"
  echo "| xz | ${xz_ver} | ${xz_latest_url:-cached xz} |" >>"${BUILD_INFO}" 
}

prepare_gmp() {
  gmp_tag="$(retry curl -s https://mirrors.kernel.org/gnu/gmp/ | grep -oE 'href="gmp-[0-9.]+\.tar\.(xz|gz)"' | sed -r 's/href="gmp-([0-9.]+)\.tar\..+"/\1/' | sort -rV | head -n 1)"
  echo "gmp最新版本是${gmp_tag} ，下载地址是https://mirrors.kernel.org/gnu/gmp/gmp-${gmp_tag}.tar.xz"
  gmp_latest_url="https://mirrors.kernel.org/gnu/gmp/gmp-${gmp_tag}.tar.xz"
  curl -L https://mirrors.kernel.org/gnu/gmp/gmp-${gmp_tag}.tar.xz | tar x --xz
  cd gmp-*
  
  # patch configure（不检测long long）
  find_and_comment() {
    local file="$1"
    local search_str="Test compile: long long reliability test"
    local current_line=1
    while read -r start_line; do  
      [[ -z "$start_line" ]] && { echo "在文件 $file 中未找到更多字符串 '$search_str'"; break; }
      local end_line=$((start_line + 37))
      sed -i "${start_line},${end_line}s/^/# /" "$file"
      echo "注释了文件 $file 中从第 $start_line 行到第 $end_line 行"
      current_line=$((end_line + 1))
    done < <(awk -v s="$search_str" -v cl="$current_line" 'NR >= cl && !/^# / && $0 ~ s {print NR}' "$file")
  }
  find_and_comment "configure"  && echo "configure文件修改完成"
  
  BUILD_CC=gcc BUILD_CXX=g++ ./configure \
      --disable-shared \
      --enable-static \
      --prefix="${CROSS_PREFIX}" \
      --host="${CROSS_HOST}" \
      --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)
  make -j$(nproc) install
  echo "| gmp | ${gmp_tag} | ${gmp_latest_url:-cached gmp} |" >>"${BUILD_INFO}"
}

prepare_libxml2() {
  libxml2_tag=$(retry wget -qO- https://gitlab.gnome.org/api/v4/projects/GNOME%2Flibxml2/releases \
      | jq -r '.[].tag_name' \
      | sed 's/^v//' \
      | sort -Vr \
      | head -n1)
  libxml2_latest_url="https://download.gnome.org/sources/libxml2/${libxml2_tag%.*}/libxml2-${libxml2_tag}.tar.xz"
  libxml2_filename="libxml2-${libxml2_tag}.tar.xz"
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
    --without-iconv \
    --without-icu \
    --enable-static \
    --disable-shared
  make -j$(nproc)
  make install
  libxml2_ver="$(grep 'Version:' "${CROSS_PREFIX}/lib/pkgconfig/"libxml-*.pc | awk '{print $2}')"
  echo "| libxml2 | ${libxml2_ver} | ${libxml2_latest_url:-cached libxml2} |" >>"${BUILD_INFO}"
}

prepare_sqlite() {
  sqlite_tag="$(retry wget -qO- --compression=auto https://raw.githubusercontent.com/sqlite/sqlite/refs/heads/master/VERSION)"
  sqlite_latest_url="https://github.com/sqlite/sqlite/archive/refs/heads/master.tar.gz"
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
  local LDFLAGS="${LDFLAGS} -L${CROSS_ROOT}/x86_64-w64-mingw32/sysroot/usr/x86_64-w64-mingw32/lib -lwinpthread -lmsvcrt"
  CFLAGS="$CFLAGS -DHAVE_PTHREAD" ./configure --build="${BUILD_ARCH}" --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --disable-shared  "${SQLITE_EXT_CONF}" \
    --enable-threadsafe \
    --disable-debug \
    --disable-fts3 --disable-fts4 --disable-fts5 \
    --disable-rtree \
    --disable-tcl \
    --disable-session \
    --disable-editline \
    --disable-math \
    --disable-load-extension
  make -j$(nproc)
  x86_64-w64-mingw32-ar cr libsqlite3.a sqlite3.o
  cp libsqlite3.a "${CROSS_PREFIX}/lib/" ||  exit 1
  make install
  sqlite_ver="$(grep 'Version:' "${CROSS_PREFIX}/lib/pkgconfig/"sqlite*.pc | awk '{print $2}')"
  echo "| sqlite | ${sqlite_ver} | ${sqlite_latest_url:-cached sqlite} |" >>"${BUILD_INFO}"
}

prepare_c_ares() {
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
    --without-random
  make -j$(nproc)
  make install
  cares_ver="$(grep 'Version:' "${CROSS_PREFIX}/lib/pkgconfig/libcares.pc" | awk '{print $2}')"
  echo "| c-ares | ${cares_ver} | ${cares_latest_url:-cached c-ares} |" >>"${BUILD_INFO}"
}

prepare_libssh2() {
  libssh2_tag=$(retry curl -s https://libssh2.org/download/ | grep -o 'libssh2-[0-9.]*\.tar\.\(gz\|xz\)' | sed -n 's/.*libssh2-\([0-9.]*\)\.tar\.\(gz\|xz\).*/\1/p' | sort -V | tail -n 1)
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
    --disable-debug
  make -j$(nproc)
  make install
  libssh2_ver="$(grep 'Version:' "${CROSS_PREFIX}/lib/pkgconfig/libssh2.pc" | awk '{print $2}')"
  echo "| libssh2 | ${libssh2_ver} | ${libssh2_latest_url:-cached libssh2} |" >>"${BUILD_INFO}"
}

prepare_openssl() {
  openssl_tag=$(retry curl -s https://api.github.com/repos/OpenSSL/OpenSSL/releases | grep -o '"tag_name": *"[^"]*"' | grep openssl | head -1 | sed 's/"tag_name": *"openssl-\([0-9.]*\)"/\1/')
  if [ -z "$openssl_tag" ]; then
    openssl_tag="3.6.0"  # 备用版本号
  fi
  openssl_latest_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_tag}/openssl-${openssl_tag}.tar.gz"
  
  if [ ! -f "${DOWNLOADS_DIR}/openssl-${openssl_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/openssl-${openssl_tag}.tar.gz.part" "${openssl_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/openssl-${openssl_tag}.tar.gz.part" "${DOWNLOADS_DIR}/openssl-${openssl_tag}.tar.gz"
  fi
  
  mkdir -p "/usr/src/openssl-${openssl_tag}"
  tar -zxf "${DOWNLOADS_DIR}/openssl-${openssl_tag}.tar.gz" --strip-components=1 -C "/usr/src/openssl-${openssl_tag}"
  cd "/usr/src/openssl-${openssl_tag}"
  
  # 优化后的禁用列表
  DISABLED_FEATURES=(
    no-err no-dso no-engine no-async no-autoalginit
    no-dtls no-sctp no-ssl3 no-tls1 no-tls1_1
    no-comp no-ts no-ocsp no-ct no-cms no-psk no-srp no-srtp no-rfc3779
    no-fips no-acvp-tests no-docs no-stdio no-ui-console
    no-afalgeng no-ssl-trace no-filenames
    no-aria no-bf no-blake2 no-camellia no-cast no-cmac
    no-dh no-dsa no-ec2m no-gost no-idea no-rc2 no-rc4 no-rc5 no-rmd160
    no-scrypt no-seed no-siphash no-siv no-sm2 no-sm3 no-sm4 no-whirlpool
    no-tests no-apps
  )

  CFLAGS="-march=tigerlake -mtune=tigerlake -Os -ffunction-sections -fdata-sections -pipe -g0 -fvisibility=hidden $LTO_FLAGS" \
  LDFLAGS="-Wl,--gc-sections -Wl,--icf=all -static -static-libgcc $LTO_FLAGS" \
  ./Configure -static \
    --prefix="${CROSS_PREFIX}" \
    --libdir=lib \
    --cross-compile-prefix="${CROSS_HOST}-" \
    mingw64 no-shared \
    --with-zlib-include="${CROSS_PREFIX}/include" \
    --with-zlib-lib="${CROSS_PREFIX}/lib/libz.a" \
    "${DISABLED_FEATURES[@]}"
  
  make -j$(nproc)
  make install_sw
  
  ${CROSS_HOST}-strip --strip-unneeded "${CROSS_PREFIX}/lib/libcrypto.a" || true
  ${CROSS_HOST}-strip --strip-unneeded "${CROSS_PREFIX}/lib/libssl.a" || true
  
  openssl_ver="$(grep 'Version:' "${CROSS_PREFIX}/lib/pkgconfig/openssl.pc" 2>/dev/null | awk '{print $2}' || echo ${openssl_tag})"
  echo "| openssl | ${openssl_ver} | ${openssl_latest_url:-cached openssl} |" >>"${BUILD_INFO}"
}

build_aria2() {
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
  sed -i 's/res += "zlib\/" ZLIB_VERSION " ";/res += "zlib_ng\/" ZLIBNG_VERSION " ";/' "src/FeatureConfig.cc"
  sed -i 's/"1", 1, 16/"1", 1, 1024/' src/OptionHandlerFactory.cc
  sed -i 's/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1M", 1_m, 1_g))/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1K", 1_k, 1_g))/g' src/OptionHandlerFactory.cc
  sed -i 's/void sock_state_cb(void\* arg, int fd, int read, int write)/void sock_state_cb(void\* arg, ares_socket_t fd, int read, int write)/g' src/AsyncNameResolver.cc
  sed -i 's/void AsyncNameResolver::handle_sock_state(int fd, int read, int write)/void AsyncNameResolver::handle_sock_state(ares_socket_t fd, int read, int write)/g' src/AsyncNameResolver.cc
  sed -i 's/void handle_sock_state(int sock, int read, int write)/void handle_sock_state(ares_socket_t sock, int read, int write)/g' src/AsyncNameResolver.h
  if [ ! -f ./configure ]; then
    autoreconf -i
  fi
  
  local LDFLAGS="$LDFLAGS -L/usr/x86_64-w64-mingw32/lib -lwinpthread"
  ./configure \
    --host="${CROSS_HOST}" \
    --prefix="${CROSS_PREFIX}" \
    --enable-static \
    --disable-shared \
    --with-cppunit-prefix=$PREFIX \
    --enable-silent-rules \
    --with-libz \
    --with-libssh2 \
    --with-libxml2 \
    --with-libcares \
    --with-sqlite3 \
    --with-libuv=no \
    --with-tcmalloc=no \
    --with-jemalloc=no \
    --without-appletls \
    --without-gnutls \
    --with-openssl \
    --with-libgmp \
    --without-libexpat \
    --without-libgcrypt \
    --without-libnettle \
    --without-included-gettext \
    --disable-epoll \
    --disable-nls \
    --disable-dependency-tracking \
    --disable-libtool-lock \
    --disable-checking \
    --enable-checking=release \
    ARIA2_STATIC=yes \
    ${ARIA2_EXT_CONF}
  make -j$(nproc)
  make install
  ARIA2_VER=$(grep -oP 'aria2 \K\d+(\.\d+)*' NEWS)
  echo "| aria2 |  ${ARIA2_VER} | ${aria2_latest_url:-cached aria2} |" >>"${BUILD_INFO}"
}

echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 cmake⭐⭐⭐⭐⭐⭐"
prepare_cmake
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 ninja⭐⭐⭐⭐⭐⭐"
prepare_ninja
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 gmp⭐⭐⭐⭐⭐⭐"
prepare_gmp
#echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 libiconv⭐⭐⭐⭐⭐⭐"
#prepare_libiconv
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 zlib_ng ⭐⭐⭐⭐⭐⭐"
prepare_zlib_ng
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 xz ⭐⭐⭐⭐⭐⭐"
prepare_xz
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 libxml2 ⭐⭐⭐⭐⭐⭐"
prepare_libxml2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译  sqlite ⭐⭐⭐⭐⭐⭐"
prepare_sqlite
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 c_ares 2⭐⭐⭐⭐⭐⭐"
prepare_c_ares
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 libssh2 ⭐⭐⭐⭐⭐⭐"
prepare_libssh2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 penssl ⭐⭐⭐⭐⭐⭐"
prepare_openssl
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 aria2⭐⭐⭐⭐⭐⭐"
build_aria2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 编译完成⭐⭐⭐⭐⭐⭐"

# get release
${CROSS_HOST}-strip "${CROSS_PREFIX}/bin/aria2c.exe"
mv -fv "${CROSS_PREFIX}/bin/aria2c.exe" "${SELF_DIR}/aria2c1.exe"
