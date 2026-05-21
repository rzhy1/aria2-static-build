#!/bin/bash

# Dockerfile to build aria2 Windows binary using ubuntu mingw-w64
# cross compiler chain.
set -euo pipefail

HOST=x86_64-w64-mingw32
PREFIX=$PWD/$HOST
SELF_DIR="$(dirname "$(realpath "${0}")")"
BUILD_INFO="${SELF_DIR}/build_info.md"

# 导出环境变量
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG="/usr/bin/pkg-config"

# 优化 CPU 架构以兼顾性能与兼容性 (x86-64-v3 包含 AVX2, FMA3 等)
export CFLAGS="-march=x86-64-v3 -O2 -ffunction-sections -fdata-sections -flto=auto -pipe -g0"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,--gc-sections -flto=auto -L$PREFIX/lib"

# 显式指定 LTO 适用的静态打包工具
export AR="$HOST-gcc-ar"
export RANLIB="$HOST-gcc-ranlib"

# 重试函数
retry() {
  local max_retries=5
  local sleep_seconds=3
  for (( i=1; i<=max_retries; i++ )); do
    echo "正在执行 (重试次数: $i): $*" >&2
    if "$@"; then
      return 0
    else
      echo "命令 '$*' 执行失败 (重试次数: $i)" >&2
      sleep "$sleep_seconds"
    fi
  done
  echo "命令 '$*' 执行失败 (已达到最大重试次数)" >&2
  return 1
}

echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载最新版mingw-w64⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
USE_GCC=0
if [[ "$USE_GCC" -eq 1 ]]; then
    echo "使用最新版的 mingw-w64-x86_64-toolchain (GCC 16)..."
    retry curl -SLf -o "/tmp/mingw-w64-x86_64-toolchain.tar.zst" "https://github.com/rzhy1/build-mingw-w64/releases/download/mingw-w64/mingw-w64-x86_64-toolchain.tar.zst"
    sudo tar --zstd -xf "/tmp/mingw-w64-x86_64-toolchain.tar.zst" -C /usr/
else
    echo "使用相对成熟的 musl-cross (GCC 15)..."
    retry curl -SLf -o "/tmp/x86_64-w64-mingw32.tar.xz" "https://github.com/rzhy1/musl-cross/releases/download/mingw-w64/x86_64-w64-mingw32-1.tar.xz"
    mkdir -p /opt/mingw64
    tar -xf "/tmp/x86_64-w64-mingw32.tar.xz" --strip-components=1 -C /opt/mingw64
    export PATH="/opt/mingw64/bin:${PATH}"    
fi
end_time=$(date +%s.%N)
duration1=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 修正软链接，必须链接 GNU 兼容的 ld.lld 而非 MSVC 接口的 lld-link
sudo ln -sf "$(which ld.lld)" /usr/bin/x86_64-w64-mingw32-ld.lld

echo "x86_64-w64-mingw32-gcc版本是："
x86_64-w64-mingw32-gcc --version

echo "## aria2c.exe dependencies:" >>"${BUILD_INFO}"
echo "| Dependency | Version | Source |" >>"${BUILD_INFO}"
echo "|------------|---------|--------|" >>"${BUILD_INFO}"

# 1. 下载并编译 GMP
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 GMP⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
gmp_tag="$(retry curl -s https://ftp.gnu.org/gnu/gmp/ | grep -oE 'href="gmp-[0-9.]+\.tar\.(xz|gz)"' | sed -r 's/href="gmp-([0-9.]+)\.tar\..+"/\1/' | sort -rV | head -n 1)"
gmp_url="https://ftp.gnu.org/gnu/gmp/gmp-${gmp_tag}.tar.xz"
echo "gmp最新版本是${gmp_tag} ，下载地址是${gmp_url}"

retry curl -SLf -o "/tmp/gmp-${gmp_tag}.tar.xz" "$gmp_url"
tar -xf "/tmp/gmp-${gmp_tag}.tar.xz"
cd gmp-*
sed -i 's/gmp_cv_c_long_long=no/gmp_cv_c_long_long=yes/g' configure

BUILD_CC=gcc BUILD_CXX=g++ ./configure \
    --disable-shared \
    --enable-static \
    --prefix="$PREFIX" \
    --host="$HOST" \
    --build="$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)"
make -j$(nproc) install
echo "| gmp | ${gmp_tag} | ${gmp_url} |" >>"${BUILD_INFO}"
cd ..
rm -rf gmp-*
end_time=$(date +%s.%N)
duration2=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 2. Expat
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - Expat⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
expat_tag=$(retry curl -s https://api.github.com/repos/libexpat/libexpat/releases/latest | jq -r '.tag_name' | sed 's/R_//' | tr _ .)
expat_latest_url=$(retry curl -s "https://api.github.com/repos/libexpat/libexpat/releases/latest" | jq -r '.assets[] | select(.name | test("\\.tar\\.bz2$")) | .browser_download_url' | head -n 1)
echo "libexpat最新版本是${expat_tag} ，下载地址是${expat_latest_url}"

retry curl -SLf -o "/tmp/expat-${expat_tag}.tar.bz2" "${expat_latest_url}"
tar -xf "/tmp/expat-${expat_tag}.tar.bz2"
cd expat-*
./configure \
    --disable-shared \
    --enable-static \
    --without-examples \
    --without-tests \
    --enable-silent-rules \
    --prefix="$PREFIX" \
    --host="$HOST" \
    --build="$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)"
make -j$(nproc) install
echo "| libexpat | ${expat_tag} | ${expat_latest_url} |" >>"${BUILD_INFO}"
cd ..
rm -rf expat-*
end_time=$(date +%s.%N)
duration3=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 3. SQLite
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - SQLite⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
sqlite_tag=$(curl -s https://sqlite.org/index.html | awk '/Version [0-9]+\.[0-9]+\.[0-9]+/ {match($0, /Version ([0-9]+\.[0-9]+\.[0-9]+)/, a); print a[1]; exit}')
download_page=$(curl -sL "https://www.sqlite.org/download.html")
csv_data=$(echo "$download_page" | sed -n '/Download product data for scripts to read/,/-->/p')
tarball_url=$(echo "$csv_data" | grep "autoconf.*\.tar\.gz" | cut -d ',' -f 3 | head -n 1)
sqlite_latest_url="https://www.sqlite.org/${tarball_url}"
echo "sqlite最新版本是${sqlite_tag}，下载地址是${sqlite_latest_url}"

retry curl -SLf -o "/tmp/sqlite.tar.gz" "${sqlite_latest_url}"
tar -xf "/tmp/sqlite.tar.gz"
cd sqlite-*
./configure \
    --disable-shared \
    --enable-threadsafe \
    --enable-static \
    --disable-debug \
    --enable-silent-rules \
    --disable-editline \
    --disable-fts3 --disable-fts4 --disable-fts5 \
    --disable-rtree \
    --disable-session \
    --disable-load-extension \
    --prefix="$PREFIX" \
    --host="$HOST" \
    --build="$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)" \
    LIBS="-lpthread"
# 规范化编译与安装，生成 sqlite3.pc 以供 aria2 自动识别
make -j$(nproc) install
echo "| sqlite | ${sqlite_tag} | ${sqlite_latest_url} |" >>"${BUILD_INFO}"
cd ..
rm -rf sqlite-*
end_time=$(date +%s.%N)
duration4=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 4. 下载并编译 zlib (使用 Windows 平台标准的 Makefile 进行编译)
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 zlib⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
zlib_tag=$(retry curl -s https://api.github.com/repos/madler/zlib/releases/latest | jq -r '.name' | cut -d' ' -f2)
zlib_latest_url=$(retry curl -s "https://api.github.com/repos/madler/zlib/releases/latest" | jq -r '.assets[] | select(.name | test("\\.tar\\.gz$")) | .browser_download_url' | head -n 1)
echo "zlib最新版本是${zlib_tag} ，下载地址是${zlib_latest_url}"

retry curl -SLf -o "/tmp/zlib.tar.gz" "${zlib_latest_url}"
tar -xf "/tmp/zlib.tar.gz"
cd zlib-*
# 针对 MinGW 环境，使用其原生维护的 win32/Makefile.gcc 编译最为稳妥
make -f win32/Makefile.gcc PREFIX="$HOST-" -j$(nproc)
make -f win32/Makefile.gcc PREFIX="$HOST-" DESTDIR="$PREFIX/" BINARY_PATH=bin INCLUDE_PATH=include LIBRARY_PATH=lib install
echo "| zlib | ${zlib_tag} | ${zlib_latest_url} |" >>"${BUILD_INFO}"
cd ..
rm -rf zlib-*
end_time=$(date +%s.%N)
duration5=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 5. 下载并编译 c-ares
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 c-ares⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
cares_tag=$(retry curl -s https://api.github.com/repos/c-ares/c-ares/releases/latest | jq -r '.tag_name | sub("^v"; "")')
cares_latest_url="https://github.com/c-ares/c-ares/releases/download/v${cares_tag}/c-ares-${cares_tag}.tar.gz"
echo "cares最新版本是${cares_tag} ，下载地址是${cares_latest_url}"

retry curl -SLf -o "/tmp/c-ares.tar.gz" "${cares_latest_url}"
tar -xf "/tmp/c-ares.tar.gz"
cd c-ares-*
./configure \
    --disable-shared \
    --enable-static \
    --disable-tests \
    --enable-silent-rules \
    --prefix="$PREFIX" \
    --host="$HOST" \
    --build="$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)" \
    LIBS="-lws2_32"
make -j$(nproc) install
echo "| c-ares | ${cares_tag} | ${cares_latest_url} |" >>"${BUILD_INFO}"
cd ..
rm -rf c-ares-*
end_time=$(date +%s.%N)
duration6=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 6. 下载并编译 libssh2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 libssh2⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
libssh2_tag=$(retry curl -s https://libssh2.org/download/ | grep -o 'libssh2-[0-9.]*\.tar\.\(gz\|xz\)' | sed -n 's/.*libssh2-\([0-9.]*\)\.tar\.\(gz\|xz\).*/\1/p' | sort -V | tail -n 1)
libssh2_latest_url="https://libssh2.org/download/libssh2-${libssh2_tag}.tar.gz"
echo "libssh2最新版本是${libssh2_tag} ，下载地址是${libssh2_latest_url}"

retry curl -SLf -o "/tmp/libssh2.tar.gz" "${libssh2_latest_url}"
tar -xf "/tmp/libssh2.tar.gz"
cd libssh2-*
./configure \
    --disable-shared \
    --enable-static \
    --enable-silent-rules \
    --disable-examples-build \
    --disable-docker-tests \
    --disable-sshd-tests \
    --disable-debug \
    --with-crypto=wincng \
    --prefix="$PREFIX" \
    --host="$HOST" \
    --build="$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)" \
    LIBS="-lws2_32"
make -j$(nproc) install
echo "| libssh2 | ${libssh2_tag} | ${libssh2_latest_url} |" >>"${BUILD_INFO}"
cd ..
rm -rf libssh2-*
end_time=$(date +%s.%N)
duration7=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 7. 下载并编译 aria2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 aria2⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
ARIA2_VERSION=master
ARIA2_REF=refs/heads/master
retry curl -SLf -o version.json "https://api.github.com/repos/aria2/aria2/git/$ARIA2_REF"
git clone -j$(nproc) --depth 1 https://github.com/aria2/aria2.git
cd aria2

# 源码特征修改
sed -i 's/"1", 1, 16/"1", 1, 1024/' src/OptionHandlerFactory.cc
sed -i 's/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1M", 1_m, 1_g))/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1K", 1_k, 1_g))/g' src/OptionHandlerFactory.cc

autoreconf -i
./configure \
    --host="$HOST" \
    --prefix="$PREFIX" \
    --build="$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)" \
    --with-sysroot="$PREFIX" \
    --with-cppunit-prefix="$PREFIX" \
    --enable-silent-rules \
    --with-libz \
    --with-libgmp \
    --with-libssh2 \
    --with-libcares \
    --with-sqlite3 \
    --with-wintls \
    --with-libexpat \
    --with-libuv=no \
    --with-tcmalloc=no \
    --with-jemalloc=no \
    --without-appletls \
    --without-gnutls \
    --without-openssl \
    --without-libxml2 \
    --without-libgcrypt \
    --without-libnettle \
    --without-included-gettext \
    --disable-epoll \
    --disable-nls \
    --disable-dependency-tracking \
    --disable-libtool-lock \
    --disable-checking \
    ARIA2_STATIC=yes \
    CPPFLAGS="-I$PREFIX/include"
make -j$(nproc)

$HOST-strip src/aria2c.exe
mv -fv "src/aria2c.exe" "${SELF_DIR}/aria2c.exe"
ARIA2_VER=$(grep -oP 'aria2 \K\d+(\.\d+)*' NEWS)
aria2_latest_url="https://github.com/aria2/aria2/archive/master.tar.gz"
echo "| aria2 |  ${ARIA2_VER} | ${aria2_latest_url} |" >>"${BUILD_INFO}"
cd ..
rm -rf aria2
end_time=$(date +%s.%N)
duration8=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

echo "=================== 耗时统计 ==================="
echo "下载mingw-w64用时: ${duration1}s"
echo "编译 GMP 用时: ${duration2}s"
echo "编译 Expat 用时: ${duration3}s"
echo "编译 SQLite 用时: ${duration4}s"
echo "编译 zlib 用时: ${duration5}s"
echo "编译 c-ares 用时: ${duration6}s"
echo "编译 libssh2 用时: ${duration7}s"
echo "编译 aria2 用时: ${duration8}s"
