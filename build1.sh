#!/bin/bash -e

export CROSS_HOST="x86_64-w64-mingw32"
export CROSS_ROOT="/cross_root"
export PATH="${CROSS_ROOT}/bin:${PATH}"
export CROSS_PREFIX="${CROSS_ROOT}/${CROSS_HOST}"
export CFLAGS="-I${CROSS_PREFIX}/include -march=tigerlake -mtune=tigerlake -O2 -ffunction-sections -fdata-sections -pipe -flto=$(nproc) -g0"
export CXXFLAGS="$CFLAGS"
export PKG_CONFIG_PATH="${CROSS_PREFIX}/lib64/pkgconfig:${CROSS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
export LDFLAGS="-L${CROSS_PREFIX}/lib64 -L${CROSS_PREFIX}/lib -static -s -Wl,--gc-sections -flto=$(nproc)"
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
    curl -SLf -o "/tmp/x86_64-w64-mingw32.tar.xz" "https://github.com/rzhy1/musl-cross/releases/download/mingw-w64/x86_64-w64-mingw32.tar.xz"
    mkdir -p ${CROSS_ROOT}
    tar -xf "/tmp/x86_64-w64-mingw32.tar.xz" --strip-components=1 -C ${CROSS_ROOT}
fi
ln -s $(which lld-link) /usr/bin/x86_64-w64-mingw32-ld.lld
echo "x86_64-w64-mingw32-gcc版本是："
x86_64-w64-mingw32-gcc --version
echo "查询"
find / -name "*pthread.a"
find / -name "*pthread.h"
find / -name "*pthread*.pc"
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
    zlib_ng_latest_tag="$(retry wget -qO- --compression=auto https://api.github.com/repos/zlib-ng/zlib-ng/releases \| jq -r "'.[0].tag_name'")"
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
    echo "修复pthread头文件路径问题..."
    
    # 1. 检查pthread.h的位置
    echo "=== 查找pthread.h位置 ==="
    PTHREAD_HEADERS=(
        "/usr/x86_64-w64-mingw32/include/pthread.h"
    )
    
    PTHREAD_HEADER_PATH=""
    for header_path in "${PTHREAD_HEADERS[@]}"; do
        if [ -f "$header_path" ]; then
            echo "✓ 找到pthread.h: $header_path"
            PTHREAD_HEADER_PATH="$(dirname "$header_path")"
            break
        fi
    done
    
    if [ -z "$PTHREAD_HEADER_PATH" ]; then
        echo "错误：找不到pthread.h头文件"
        echo "尝试创建符号链接..."
        
        # 尝试创建符号链接
        if [ -f "/usr/share/mingw-w64/include/pthread.h" ]; then
            mkdir -p "${CROSS_ROOT}/x86_64-w64-mingw32/include"
            ln -sf "/usr/share/mingw-w64/include/pthread.h" "${CROSS_ROOT}/x86_64-w64-mingw32/include/pthread.h"
            PTHREAD_HEADER_PATH="${CROSS_ROOT}/x86_64-w64-mingw32/include"
            echo "✓ 创建pthread.h符号链接到: $PTHREAD_HEADER_PATH"
        else
            echo "错误：无法找到或创建pthread.h"
            exit 1
        fi
    fi
    
    # 2. 测试修复后的pthread编译
    echo "=== 测试修复后的pthread编译 ==="
    cat > test_pthread_fixed.c << 'EOF'
#include <pthread.h>
#include <stdio.h>

int main() {
    printf("pthread test\n");
    pthread_t thread;
    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    return 0;
}
EOF
    
    PTHREAD_SUCCESS=0
    WORKING_PTHREAD=""
    
    # 使用正确的头文件路径进行测试
    PTHREAD_TESTS=(
        "-I$PTHREAD_HEADER_PATH -lwinpthread"
        "-I$PTHREAD_HEADER_PATH -lpthread"
        "-I$PTHREAD_HEADER_PATH -L/usr/x86_64-w64-mingw32/lib -lwinpthread"
    )
    
    for test_option in "${PTHREAD_TESTS[@]}"; do
        echo "测试: x86_64-w64-mingw32-gcc test_pthread_fixed.c $test_option"
        if x86_64-w64-mingw32-gcc test_pthread_fixed.c $test_option -o test_pthread.exe 2>/dev/null; then
            echo "✓ 成功: $test_option"
            WORKING_PTHREAD="$test_option"
            PTHREAD_SUCCESS=1
            break
        else
            echo "✗ 失败: $test_option"
        fi
    done
    
    rm -f test_pthread_fixed.c test_pthread.exe
    
    if [ $PTHREAD_SUCCESS -eq 0 ]; then
        echo "错误：即使修复头文件路径，pthread仍然无法工作"
        exit 1
    fi
    
    echo "✓ pthread修复成功: $WORKING_PTHREAD"
    
    # 3. 继续SQLite编译，使用修复的pthread配置
    echo "=== 开始编译SQLite ==="
    
    sqlite_tag="$(retry wget -qO- --compression=auto https://raw.githubusercontent.com/sqlite/sqlite/refs/heads/master/VERSION)"
    sqlite_latest_url="https://www.sqlite.org/src/tarball/sqlite.tar.gz"
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
    
    # 4. 强制绕过configure的pthread检测
    echo "修补configure脚本..."
    cp configure configure.backup
    sed -i '/Error: Missing required pthread libraries/,+3c\
echo "强制跳过pthread检测 - 已手动验证pthread可用"\
echo "pthread配置: '"$WORKING_PTHREAD"'"\
ac_cv_lib_pthread_pthread_create=yes' configure
    
    # 设置环境变量
    export ac_cv_lib_pthread_pthread_create=yes
    export ac_cv_header_pthread_h=yes
    export ac_cv_func_pthread_create=yes
    
    # 从WORKING_PTHREAD中提取库和头文件路径
    PTHREAD_INCLUDE="-I$PTHREAD_HEADER_PATH"
    PTHREAD_LIB=$(echo "$WORKING_PTHREAD" | grep -o '\-l[^ ]*')
    PTHREAD_LIBPATH=$(echo "$WORKING_PTHREAD" | grep -o '\-L[^ ]*' || true)
    
    echo "pthread配置："
    echo "  头文件: $PTHREAD_INCLUDE"
    echo "  库路径: $PTHREAD_LIBPATH"
    echo "  库文件: $PTHREAD_LIB"
    
    # 设置编译参数
    local CFLAGS="$CFLAGS $PTHREAD_INCLUDE -DHAVE_PTHREAD -DSQLITE_THREADSAFE=1"
    local LDFLAGS="$LDFLAGS $PTHREAD_LIBPATH $PTHREAD_LIB"
    export LIBS="$PTHREAD_LIB"
    
    echo "最终编译参数："
    echo "CFLAGS: $CFLAGS"
    echo "LDFLAGS: $LDFLAGS"
    echo "LIBS: $LIBS"
    
    # 5. 运行configure
    ./configure \
        --build="${BUILD_ARCH}" \
        --host="${CROSS_HOST}" \
        --prefix="${CROSS_PREFIX}" \
        --disable-shared \
        "${SQLITE_EXT_CONF}" \
        --enable-threadsafe \
        --disable-debug \
        --disable-fts3 --disable-fts4 --disable-fts5 \
        --disable-rtree \
        --disable-tcl \
        --disable-session \
        --disable-editline \
        --disable-load-extension
    
    if [ $? -ne 0 ]; then
        echo "错误：configure失败"
        exit 1
    fi
    
    echo "✓ configure成功"
    
    # 6. 编译和安装
    make -j$(nproc)
    if [ $? -ne 0 ]; then
        echo "错误：编译失败"
        exit 1
    fi
    
    x86_64-w64-mingw32-ar cr libsqlite3.a sqlite3.o
    cp libsqlite3.a "${CROSS_PREFIX}/lib/" || exit 1
    make install
    
    # 7. 更新pkg-config文件
    if [ -f "${CROSS_PREFIX}/lib/pkgconfig/sqlite3.pc" ]; then
        sed -i "s/Libs: -L\${libdir} -lsqlite3/Libs: -L\${libdir} -lsqlite3 $PTHREAD_LIB/" "${CROSS_PREFIX}/lib/pkgconfig/sqlite3.pc"
        sqlite_ver="$(grep 'Version:' "${CROSS_PREFIX}/lib/pkgconfig/"sqlite*.pc | awk '{print $2}')"
        echo "✓ SQLite ${sqlite_ver} 编译成功（线程安全版本）"
        echo "| sqlite | ${sqlite_ver} (threadsafe) | ${sqlite_latest_url:-cached sqlite} |" >>"${BUILD_INFO}"
    else
        echo "错误：SQLite安装验证失败"
        exit 1
    fi
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
    --disable-debug
  make -j$(nproc)
  make install
  libssh2_ver="$(grep 'Version:' "${CROSS_PREFIX}/lib/pkgconfig/libssh2.pc" | awk '{print $2}')"
  echo "| libssh2 | ${libssh2_ver} | ${libssh2_latest_url:-cached libssh2} |" >>"${BUILD_INFO}"
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
  if [ x"${TARGET_HOST}" = xwin ]; then
    ARIA2_EXT_CONF='--without-openssl'
  # else
  #   ARIA2_EXT_CONF='--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt'
  fi
  #LDFLAGS="$LDFLAGS -L/usr/x86_64-w64-mingw32/lib -lwinpthread"
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
    --without-openssl \
    --without-libgmp \
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
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 libiconv⭐⭐⭐⭐⭐⭐"
#prepare_libiconv
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 zlib、xz、libxml2、sqlite、c_ares、libssh2⭐⭐⭐⭐⭐⭐"
prepare_zlib_ng
prepare_xz
prepare_libxml2
#wait
prepare_sqlite
prepare_c_ares
prepare_libssh2
#wait
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 aria2⭐⭐⭐⭐⭐⭐"
build_aria2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 编译完成⭐⭐⭐⭐⭐⭐"

# get release
${CROSS_HOST}-strip "${CROSS_PREFIX}/bin/aria2c.exe"
mv -fv "${CROSS_PREFIX}/bin/aria2c.exe" "${SELF_DIR}/aria2c1.exe"
