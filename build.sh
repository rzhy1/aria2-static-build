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
set -euo pipefail
# Change HOST to x86_64-w64-mingw32 to build 64-bit binary
HOST=x86_64-w64-mingw32
PREFIX=$PWD/$HOST

# 配置 apt 以保留下载的 .deb 包，并禁用 HTTPS 证书验证
#rm -f /etc/apt/apt.conf.d/*
#echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
#echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https    

retry() {
  local try="${1:-5}"
  local initial_delay="${2:-1}" # 初始间隔 1 秒
  shift 2

  local delay="$initial_delay"
  for i in $(seq 1 "$try"); do
    echo "Executing with retry ($i/$try): $@" >&2
    if eval "$@"; then
      return 0
    fi
    echo "Execute '$@' failed, retrying in $delay seconds..." >&2
    sleep "$delay"
    delay=$((delay * 2)) # 每次间隔加倍
  done
  echo "Execute '$@' failed after $try tries." >&2
  return 1
}

# 下载并编译 GMP
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 GMP⭐⭐⭐⭐⭐⭐"
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
    CFLAGS="-mtune=generic -O2 -g0"
make -j$(nproc) install
cd ..

# 下载并编译 Expat
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 Expat⭐⭐⭐⭐⭐⭐"
expat_tag=$(retry curl -s https://api.github.com/repos/libexpat/libexpat/releases/latest | jq -r '.tag_name' | sed 's/R_//' | tr _ .)
expat_latest_url=$(retry curl -s "https://api.github.com/repos/libexpat/libexpat/releases/latest" | jq -r '.assets[] | select(.name | test("\\.tar\\.bz2$")) | .browser_download_url' | head -n 1)
echo "libexpa最新版本是${expat_tag} ，下载地址是${expat_latest_url}"
curl -L ${expat_latest_url} | tar xj
#curl -L https://github.com/libexpat/libexpat/releases/download/R_2_6_3/expat-2.6.3.tar.bz2 | tar xj
cd expat-*
./configure \
    --disable-shared \
    --enable-static \
    --prefix=$PREFIX \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)
make -j$(nproc) install
cd ..

# 下载并编译 SQLite
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 SQLite⭐⭐⭐⭐⭐⭐"
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
    --prefix=$PREFIX \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)
make -j$(nproc) install
cd ..

# 下载并编译 zlib
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 zlib⭐⭐⭐⭐⭐⭐"
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
cd ..

# 下载并编译 c-ares
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 c-ares⭐⭐⭐⭐⭐⭐"
cares_tag=$(retry curl -s https://api.github.com/repos/c-ares/c-ares/releases/latest | jq -r '.tag_name | sub("^v"; "")')
cares_latest_url="https://github.com/c-ares/c-ares/releases/download/v${cares_tag}/c-ares-${cares_tag}.tar.gz"
echo "cares最新版本是${cares_tag} ，下载地址是${cares_latest_url}"
curl -L ${cares_latest_url} | tar xz
#curl -L https://github.com/c-ares/c-ares/releases/download/v1.34.1/c-ares-1.34.1.tar.gz | tar xz
cd c-ares-*
./configure \
    --disable-shared \
    --enable-static \
    --without-random \
    --prefix=$PREFIX \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    LIBS="-lws2_32"
make -j$(nproc) install
cd ..

# 下载并编译 libssh2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 libssh2⭐⭐⭐⭐⭐⭐"
libssh2_tag=$(retry curl -s https://libssh2.org/ | sed -nr 's@.*libssh2 ([^<]*).*released on.*@\1@p')
libssh2_latest_url="https://libssh2.org/download/libssh2-${libssh2_tag}.tar.gz"
echo "libssh2最新版本是${libssh2_tag} ，下载地址是${libssh2_latest_url}"
curl -L ${libssh2_latest_url} | tar xz
#curl -L https://libssh2.org/download/libssh2-1.11.0.tar.gz | tar xz
cd libssh2-*
./configure \
    --disable-shared \
    --enable-static \
    --prefix=$PREFIX \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    LIBS="-lws2_32"
make -j$(nproc) install
cd ..

# 下载并编译 aria2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 aria2⭐⭐⭐⭐⭐⭐"
PKG_CONFIG_PATH=/usr/local/$HOST/lib/pkgconfig
ARIA2_VERSION=master
ARIA2_REF=refs/heads/master
curl -L -o version.json https://api.github.com/repos/aria2/aria2/git/$ARIA2_REF
git clone -b $ARIA2_VERSION --depth 1 https://github.com/aria2/aria2.git
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
    --without-included-gettext \
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
    ARIA2_STATIC=yes \
    CPPFLAGS="-I$PREFIX/include" \
    LDFLAGS="-L$PREFIX/lib" \
    PKG_CONFIG="/usr/bin/pkg-config" \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
make -j$(nproc)
$HOST-strip src/aria2c.exe
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 编译完成⭐⭐⭐⭐⭐⭐"
