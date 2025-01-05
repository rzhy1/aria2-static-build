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
export LD=ld.lld
set -euo pipefail
HOST=x86_64-w64-mingw32
PREFIX=$PWD/$HOST
SELF_DIR="$(dirname "$(realpath "${0}")")"
BUILD_INFO="${SELF_DIR}/build_info.md"
export PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:$PREFIX/lib/pkgconfig}
#export LIBRARY_PATH=$PREFIX/lib:$LIBRARY_PATH
#export C_INCLUDE_PATH=$PREFIX/include:$C_INCLUDE_PATH
#export CPLUS_INCLUDE_PATH=$PREFIX/include:$CPLUS_INCLUDE_PATH
echo "$BUILD_INFO"
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载最新版mingw-w64⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
USE_GCC15=1
if [[ "$USE_GCC15" -eq 1 ]]; then
    echo "使用最新版的 mingw-w64-x86_64-toolchain (GCC 15)..."
    curl -SLf -o "/tmp/mingw-w64-x86_64-toolchain.tar.zst" "https://github.com/rzhy1/build-mingw-w64/releases/download/mingw-w64/mingw-w64-x86_64-toolchain.tar.zst"
    tar --zstd -xf "/tmp/mingw-w64-x86_64-toolchain.tar.zst" -C "/usr/"
else
    echo "使用相对成熟的 mingw-w64-x86_64-toolchain (GCC 14)..."
    curl -SLf -o "/tmp/x86_64-w64-mingw32.tar.xz"  "https://github.com/rzhy1/musl-cross/releases/download/mingw-w64/x86_64-w64-mingw32.tar.xz"
    mkdir -p /opt/mingw64
    tar -xf "/tmp/x86_64-w64-mingw32.tar.xz" --strip-components=1 -C /opt/mingw64
    export PATH="/opt/mingw64/bin:${PATH}"
fi
end_time=$(date +%s.%N)
duration1=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

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

# 下载并编译 GMP
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 GMP⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
gmp_tag="$(retry curl -s https://ftp.gnu.org/gnu/gmp/ | grep -oE 'href="gmp-[0-9.]+\.tar\.(xz)"' | sort -rV | head -n 1 | sed -r 's/href="gmp-(.+)\.tar\..+"/\1/')"
echo "gmp最新版本是${gmp_tag} ，下载地址是https://ftp.gnu.org/gnu/gmp/gmp-${gmp_tag}.tar.xz"
curl -L https://ftp.gnu.org/gnu/gmp/gmp-${gmp_tag}.tar.xz | tar x --xz
cd gmp-*
./configure \
    --disable-shared \
    --enable-static \
    --prefix=$PREFIX \
    --host=$HOST \
    --disable-cxx \
    --enable-fat \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    CFLAGS="-mtune=generic -O2 -g0" \
    CXXFLAGS="-mtune=generic -O2 -g0"
make -j$(nproc) install
echo "1111111"
x86_64-w64-mingw32-gcc -L$PREFIX/lib -print-file-name=libgmp.a
echo "2222222"
echo | x86_64-w64-mingw32-gcc -I$PREFIX/include -E -v -
echo "3333333"
ls $PREFIX/lib/libgmp.a
file $PREFIX/lib/libgmp.a
nm $PREFIX/lib/libgmp.a | grep __gmpz_init
echo "4444444"
x86_64-w64-mingw32-g++ -I/__w/aria2-static-build/aria2-static-build/x86_64-w64-mingw32/include -L/__w/aria2-static-build/aria2-static-build/x86_64-w64-mingw32/lib  test.c -lgmp -o test.exe
echo "| gmp | ${gmp_tag} | https://ftp.gnu.org/gnu/gmp/gmp-${gmp_tag}.tar.xz |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration2=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

if [[ "$USE_GCC15" -eq 1 ]]; then
    cp "$PREFIX/lib/pkgconfig/gmp.pc" "$PREFIX/lib/pkgconfig/libgmp.pc"
    sed -i 's/^Name: GNU MP$/Name: gmp/' "$PREFIX/lib/pkgconfig/gmp.pc"
    sed -i 's/^Name: GNU MP$/Name: libgmp/' "$PREFIX/lib/pkgconfig/libgmp.pc"
fi
find / -name "libgmp*.a" -o -name "libgmp*.lib"
find / -name "gmp*.a" -o -name "gmp*.lib"
echo "555555"
cat $PREFIX/lib/pkgconfig/gmp.pc
echo "666666"
cat $PREFIX/lib/pkgconfig/libgmp.pc
# 下载并编译 Expat
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 Expat⭐⭐⭐⭐⭐⭐"
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
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    CFLAGS="-mtune=generic -O2 -g0 -flto=$(nproc)" \
    CXXFLAGS="-mtune=generic -O2 -g0 -flto=$(nproc)"
make -j$(nproc) install
echo "| libexpat | ${expat_tag} | ${expat_latest_url} |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration3=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 下载并编译 SQLite
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 SQLite⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
sqlite_tag=$(retry curl -s "https://www.sqlite.org/index.html" | sed -nr 's/.*>Version ([0-9.]+)<.*/\1/p')
download_page=$(curl -s "https://www.sqlite.org/download.html")
csv_data=$(echo "$download_page" | sed -n '/Download product data for scripts to read/,/-->/p')
tarball_url=$(echo "$csv_data" | grep "autoconf.*\.tar\.gz" | cut -d ',' -f 3 | head -n 1)
sqlite_latest_url="https://www.sqlite.org/${tarball_url}"
echo "sqlite最新版本是${sqlite_tag}，下载地址是${sqlite_latest_url}"
curl -L ${sqlite_latest_url} | tar xz
#curl -L https://www.sqlite.org/2024/sqlite-autoconf-3460100.tar.gz | tar xz
cd sqlite-*
./configure \
    --disable-shared \
    --enable-static \
    --disable-debug \
    --enable-silent-rules \
    --enable-editline=no \
    --enable-fts3=no --enable-fts4=no --enable-fts5=no \
    --enable-rtree=no \
    --enable-session=no \
    --disable-dynamic-extensions \
    --prefix=$PREFIX \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    CFLAGS="-O2 -g0 -flto=$(nproc)" \
    CXXFLAGS="-O2 -g0 -flto=$(nproc)"
make -j$(nproc) install
echo "| sqlite | ${sqlite_tag} | ${sqlite_latest_url} |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration4=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 下载并编译 zlib
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
CFLAGS="-O2 -g0" \
CXXFLAGS="-O2 -g0 " \
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

# 下载并编译 c-ares
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
    LIBS="-lws2_32" \
    CFLAGS="-O2 -g0 -flto=$(nproc)" \
    CXXFLAGS="-O2 -g0 -flto=$(nproc)" 
make -j$(nproc) install
echo "| c-ares | ${cares_tag} | ${cares_latest_url} |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration6=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 下载并编译 libssh2
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
    LIBS="-lws2_32" \
    CFLAGS="-O2 -g0 -flto=$(nproc)" \
    CXXFLAGS="-O2 -g0 -flto=$(nproc)" 
make -j$(nproc) install
echo "| libssh2 | ${libssh2_tag} | ${libssh2_latest_url} |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration7=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

# 下载并编译 aria2
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
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    --prefix=$PREFIX \
    --without-included-gettext \
    --disable-dependency-tracking \
    --disable-libtool-lock \
    --enable-silent-rules \
    --disable-nls \
    --with-libcares \
    --without-gnutls \
    --without-openssl \
    --with-sqlite3 \
    --with-libexpat \
    --without-libxml2 \
    --with-libz \
    --with-libgmp \
    --with-libssh2 \
    --without-libgcrypt \
    --without-libnettle \
    --with-cppunit-prefix=$PREFIX \
    --disable-checking \
    --with-sysroot=$PREFIX \
    ARIA2_STATIC=yes \
    CPPFLAGS="-I$PREFIX/include" \
    LDFLAGS="-L$PREFIX/lib" \
    PKG_CONFIG="/usr/bin/pkg-config" \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
    CFLAGS="-O2 -g0 -flto=$(nproc)" \
    CXXFLAGS="-O2 -g0 -flto=$(nproc)"
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
