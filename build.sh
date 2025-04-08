#!/bin/bash

# Dockerfile to build aria2 Windows binary using ubuntu mingw-w64
# cross compiler chain.
#
# $ sudo docker build -t aria2-mingw - < Dockerfile.mingw
#
# After successful build, windows binary is located at
# /aria2/src/aria2c.exe.  You can copy the binary using following
# commands:
#
# $ sudo docker run --rm -it -v /path/to/dest:/out aria2-mingw cp /aria2/src/aria2c.exe /out
export LD=x86_64-w64-mingw32-ld.lld
set -euo pipefail
HOST=x86_64-w64-mingw32
PREFIX=$PWD/$HOST
SELF_DIR="$(dirname "$(realpath "${0}")")"
BUILD_INFO="${SELF_DIR}/build_info.md"
export PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:$PREFIX/lib/pkgconfig}
export CFLAGS="-march=tigerlake -mtune=tigerlake -O2 -ffunction-sections -fdata-sections -flto=$(nproc) -pipe  -g0"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,--gc-sections -flto=$(nproc)"

echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载最新版mingw-w64⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
USE_GCC15=0
if [[ "$USE_GCC15" -eq 1 ]]; then
    echo "使用最新版的 mingw-w64-x86_64-toolchain (GCC 15)..."
    curl -SLf -o "/tmp/mingw-w64-x86_64-toolchain.tar.zst" "https://github.com/rzhy1/build-mingw-w64/releases/download/mingw-w64/mingw-w64-x86_64-toolchain.tar.zst"
    sudo tar --zstd -xf "/tmp/mingw-w64-x86_64-toolchain.tar.zst" -C /usr/
else
    echo "使用相对成熟的 mingw-w64-x86_64-toolchain (GCC 14)..."
    curl -SLf -o "/tmp/x86_64-w64-mingw32.tar.xz"  "https://github.com/rzhy1/musl-cross/releases/download/mingw-w64/x86_64-w64-mingw32.tar.xz"
    mkdir -p /opt/mingw64
    tar -xf "/tmp/x86_64-w64-mingw32.tar.xz" --strip-components=1 -C /opt/mingw64
    export PATH="/opt/mingw64/bin:${PATH}"    
fi
end_time=$(date +%s.%N)
duration1=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")
# ln -sf /opt/mingw64/bin/x86_64-w64-mingw32-* /usr/bin/ 一次链接所有
sudo ln -s $(which lld-link) /usr/bin/x86_64-w64-mingw32-ld.lld

echo "x86_64-w64-mingw32-gcc版本是："
x86_64-w64-mingw32-gcc --version
#x86_64-w64-mingw32-gcc -print-search-dirs

# 配置 apt 以保留下载的 .deb 包，并禁用 HTTPS 证书验证
#rm -f /etc/apt/apt.conf.d/*
#echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
#echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https    

echo "## aria2c.exe （zlib & libexpat） dependencies:" >>"${BUILD_INFO}"
# 初始化表格
echo "| Dependency | Version | Source |" >>"${BUILD_INFO}"
echo "|------------|---------|--------|" >>"${BUILD_INFO}"

retry() {
  local max_retries=5
  local sleep_seconds=3
  local command="$@"

  for (( i=1; i<=max_retries; i++ )); do
    echo "正在执行 (重试次数: $i): $command" >&2
    if $command; then
      return 0
    else
      echo "命令 '$command' 执行失败 (重试次数: $i)" >&2
      sleep "$sleep_seconds"
    fi
  done
  echo "命令 '$command' 执行失败 (已达到最大重试次数)" >&2
  return 1
}

# 1. 下载并编译 GMP
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 GMP⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
gmp_tag="$(retry curl -s https://ftp.gnu.org/gnu/gmp/ | grep -oE 'href="gmp-[0-9.]+\.tar\.(xz)"' | sort -rV | head -n 1 | sed -r 's/href="gmp-(.+)\.tar\..+"/\1/')"
echo "gmp最新版本是${gmp_tag} ，下载地址是https://ftp.gnu.org/gnu/gmp/gmp-${gmp_tag}.tar.xz"
curl -L https://ftp.gnu.org/gnu/gmp/gmp-${gmp_tag}.tar.xz | tar x --xz
cd gmp-*
#curl -o configure https://raw.githubusercontent.com/rzhy1/aria2-static-build/refs/heads/main/configure || exit 1

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
    --prefix=$PREFIX \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)
make -j$(nproc) install
echo "| gmp | ${gmp_tag} | https://ftp.gnu.org/gnu/gmp/gmp-${gmp_tag}.tar.xz |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration2=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 2.  Expat
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') -  Expat⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
expat_tag=$(retry curl -s https://api.github.com/repos/libexpat/libexpat/releases/latest | jq -r '.tag_name' | sed 's/R_//' | tr _ .)
expat_latest_url=$(retry curl -s "https://api.github.com/repos/libexpat/libexpat/releases/latest" | jq -r '.assets[] | select(.name | test("\\.tar\\.bz2$")) | .browser_download_url' | head -n 1)
echo "libexpat最新版本是${expat_tag} ，下载地址是${expat_latest_url}"
curl -L ${expat_latest_url} | tar xj
#curl -L https://github.com/libexpat/libexpat/releases/download/R_2_6_3/expat-2.6.3.tar.bz2 | tar xj
cd expat-*
./configure \
    --disable-shared \
    --enable-static \
    --without-examples \
    --without-tests \
    --enable-silent-rules \
    --prefix=$PREFIX \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)
make -j$(nproc) install
echo "| libexpat | ${expat_tag} | ${expat_latest_url} |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration3=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 3.  SQLite
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') -  SQLite⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
sqlite_tag=$(curl -s https://sqlite.org/index.html | awk '/Version [0-9]+\.[0-9]+\.[0-9]+/ {match($0, /Version ([0-9]+\.[0-9]+\.[0-9]+)/, a); print a[1]; exit}')
echo "sqlite最新版本是${sqlite_tag}"
download_page=$(curl -sL "https://www.sqlite.org/download.html")
echo "download_page是${download_page}"
csv_data=$(echo "$download_page" | sed -n '/Download product data for scripts to read/,/-->/p')
echo "csv_data是${csv_data}"
tarball_url=$(echo "$csv_data" | grep "autoconf.*\.tar\.gz" | cut -d ',' -f 3 | head -n 1)
echo "tarball_url是${tarball_url}"
sqlite_latest_url="https://www.sqlite.org/${tarball_url}"
echo "sqlite最新版本是${sqlite_tag}，下载地址是${sqlite_latest_url}"
curl -L ${sqlite_latest_url} | tar xz
#curl -L https://www.sqlite.org/2024/sqlite-autoconf-3470200.tar.gz | tar xz
cd sqlite-*
export LDFLAGS="$LDFLAGS -L/usr/x86_64-w64-mingw32/lib -lwinpthread"
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
    --prefix=$PREFIX \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)
make -j$(nproc) install
x86_64-w64-mingw32-ar cr libsqlite3.a sqlite3.o
cp libsqlite3.a "$PREFIX/lib/" ||  exit 1
echo "| sqlite | ${sqlite_tag} | ${sqlite_latest_url} |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration4=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

export LDFLAGS="-L$PREFIX/lib -flto=$(nproc)"

# 4. 下载并编译 zlib
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 zlib⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
zlib_tag=$(retry curl -s https://api.github.com/repos/madler/zlib/releases/latest | jq -r '.name' | cut -d' ' -f2)
zlib_latest_url=$(retry curl -s "https://api.github.com/repos/madler/zlib/releases/latest" | jq -r '.assets[] | select(.name | test("\\.tar\\.gz$")) | .browser_download_url' | head -n 1)
#zlib_tag="$(retry wget -qO- --compression=auto https://zlib.net/ \| grep -i "'<FONT.*FONT>'" \| sed -r "'s/.*zlib\s*([^<]+).*/\1/'" \| head -1)"
#zlib_latest_url="https://zlib.net/zlib-${zlib_tag}.tar.gz"
echo "zlib最新版本是${zlib_tag} ，下载地址是${zlib_latest_url}"
curl -L ${zlib_latest_url} | tar xz
#curl -L https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz | tar xz
cd zlib-*
CC=$HOST-gcc \
AR=$HOST-ar \
LD=$HOST-ld \
RANLIB=$HOST-ranlib \
STRIP=$HOST-strip \
./configure \
    --prefix=$PREFIX \
    --libdir=$PREFIX/lib \
    --includedir=$PREFIX/include \
    --static
make -j$(nproc) install
echo "| zlib | ${zlib_tag} | ${zlib_latest_url} |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration5=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 5. 下载并编译 c-ares
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 c-ares⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
cares_tag=$(retry curl -s https://api.github.com/repos/c-ares/c-ares/releases/latest | jq -r '.tag_name | sub("^v"; "")')
cares_latest_url="https://github.com/c-ares/c-ares/releases/download/v${cares_tag}/c-ares-${cares_tag}.tar.gz"
echo "cares最新版本是${cares_tag} ，下载地址是${cares_latest_url}"
curl -L ${cares_latest_url} | tar xz
#curl -L https://github.com/c-ares/c-ares/releases/download/v1.34.1/c-ares-1.34.1.tar.gz | tar xz
cd c-ares-*
./configure \
    --disable-shared \
    --enable-static \
    --disable-tests \
    --enable-silent-rules \
    --without-random \
    --prefix=$PREFIX \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    LIBS="-lws2_32"
make -j$(nproc) install
echo "| c-ares | ${cares_tag} | ${cares_latest_url} |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration6=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 6. 下载并编译 libssh2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 libssh2⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
libssh2_tag=$(retry curl -s https://libssh2.org/ | sed -nr 's@.*libssh2 ([^<]*).*released on.*@\1@p')
libssh2_latest_url="https://libssh2.org/download/libssh2-${libssh2_tag}.tar.gz"
echo "libssh2最新版本是${libssh2_tag} ，下载地址是${libssh2_latest_url}"
curl -L ${libssh2_latest_url} | tar xz
#curl -L https://libssh2.org/download/libssh2-1.11.0.tar.gz | tar xz
cd libssh2-*
./configure \
    --disable-shared \
    --enable-static \
    --enable-silent-rules \
    --disable-examples-build \
    --disable-docker-tests \
    --disable-sshd-tests \
    --disable-debug \
    --prefix=$PREFIX \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    LIBS="-lws2_32"
make -j$(nproc) install
echo "| libssh2 | ${libssh2_tag} | ${libssh2_latest_url} |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration7=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 7. 下载并编译 aria2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 aria2⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
ARIA2_VERSION=master
ARIA2_REF=refs/heads/master
curl -L -o version.json https://api.github.com/repos/aria2/aria2/git/$ARIA2_REF
git clone -j$(nproc) --depth 1 https://github.com/aria2/aria2.git
cd aria2
sed -i 's/"1", 1, 16/"1", 1, 1024/' src/OptionHandlerFactory.cc
sed -i 's/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1M", 1_m, 1_g))/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1K", 1_k, 1_g))/g' src/OptionHandlerFactory.cc
#sed -i 's/void sock_state_cb(void\* arg, int fd, int read, int write)/void sock_state_cb(void\* arg, ares_socket_t fd, int read, int write)/g' src/AsyncNameResolver.cc
#sed -i 's/void AsyncNameResolver::handle_sock_state(int fd, int read, int write)/void AsyncNameResolver::handle_sock_state(ares_socket_t fd, int read, int write)/g' src/AsyncNameResolver.cc
#sed -i 's/void handle_sock_state(int sock, int read, int write)/void handle_sock_state(ares_socket_t sock, int read, int write)/g' src/AsyncNameResolver.h
autoreconf -i
./configure \
    --host=$HOST \
    --prefix=$PREFIX \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    --with-sysroot=$PREFIX \
    --with-cppunit-prefix=$PREFIX \
    --enable-silent-rules \
    --with-libz \
    --with-libgmp \
    --with-libssh2 \
    --with-libcares \
    --with-sqlite3 \
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
    SQLITE3_LIBS="-L$PREFIX/lib -lsqlite3" \
    CPPFLAGS="-I$PREFIX/include" \
    PKG_CONFIG="/usr/bin/pkg-config" \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
make -j$(nproc)
$HOST-strip src/aria2c.exe
mv -fv "src/aria2c.exe" "${SELF_DIR}/aria2c.exe"
ARIA2_VER=$(grep -oP 'aria2 \K\d+(\.\d+)*' NEWS)
aria2_latest_url="https://github.com/aria2/aria2/archive/master.tar.gz"
echo "| aria2 |  ${ARIA2_VER} | ${aria2_latest_url:-cached aria2} |" >>"${BUILD_INFO}"
end_time=$(date +%s.%N)
duration8=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")
echo "下载mingw-w64用时: ${duration1}s"
echo "编译 GMP 用时: ${duration2}s"
echo "编译 Expat 用时: ${duration3}s"
echo "编译 SQLite 用时: ${duration4}s"
echo "编译 zlib 用时: ${duration5}s"
echo "编译 c-ares 用时: ${duration6}s"
echo "编译 libssh2 用时: ${duration7}s"
echo "编译 aria2 用时: ${duration8}s"
