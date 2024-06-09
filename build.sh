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
PREFIX=/usr/local/$HOST

# 配置 apt 以保留下载的 .deb 包，并禁用 HTTPS 证书验证
rm -f /etc/apt/apt.conf.d/*
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https

echo "$(date '+%Y/%m/%d %a %H:%M:%S.%N') - Updating and upgrading packages"
apt-get update
DEBIAN_FRONTEND="noninteractive" apt-get upgrade -y
echo "$(date '+%Y/%m/%d %a %H:%M:%S.%N') - Installing required packages"
apt-get install -y --no-install-recommends \
    make binutils autoconf automake autotools-dev libtool \
    patch ca-certificates \
    pkg-config git curl dpkg-dev gcc-mingw-w64 g++-mingw-w64 \
    autopoint libcppunit-dev lzip \
    wget ccache

# 设置 ccache
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_DIR="/ccache"
ccache --max-size=5G

# 下载并编译 GMP
echo "$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 GMP"
wget -q -O- https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz | tar x --xz
cd gmp-*
./configure \
    --disable-shared \
    --enable-static \
    --prefix=/usr/local/$HOST \
    --host=$HOST \
    --disable-cxx \
    --enable-fat \
    CFLAGS="-mtune=generic -O2 -g0"
make -j$(nproc) install
cd ..

# 下载并编译 Expat
echo "$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 Expat"
wget -q -O- https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.bz2 | tar xj
cd expat-*
./configure \
    --disable-shared \
    --enable-static \
    --prefix=/usr/local/$HOST \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)
make -j$(nproc) install
cd ..

# 下载并编译 SQLite
echo "$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 SQLite"
wget -q -O- https://www.sqlite.org/2024/sqlite-autoconf-3460000.tar.gz | tar xz
cd sqlite-autoconf-*
./configure \
    --disable-shared \
    --enable-static \
    --prefix=/usr/local/$HOST \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)
make -j$(nproc) install
cd ..

# 下载并编译 zlib
echo "$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 zlib"
wget -q -O- https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz | tar xz
cd zlib-*
CC=$HOST-gcc \
AR=$HOST-ar \
LD=$HOST-ld \
RANLIB=$HOST-ranlib \
STRIP=$HOST-strip \
./configure \
    --prefix=/usr/local/$HOST \
    --libdir=/usr/local/$HOST/lib \
    --includedir=/usr/local/$HOST/include \
    --static
make -j$(nproc) install
cd ..

# 下载并编译 c-ares
echo "$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 c-ares"
wget -q -O- https://github.com/c-ares/c-ares/releases/download/v1.30.0/c-ares-1.30.0.tar.gz | tar xz
cd c-ares-*
./configure \
    --disable-shared \
    --enable-static \
    --without-random \
    --prefix=/usr/local/$HOST \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    LIBS="-lws2_32"
make -j$(nproc) install
cd ..

# 下载并编译 libssh2
echo "$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 libssh2"
wget -q -O- https://libssh2.org/download/libssh2-1.11.0.tar.gz | tar xz
cd libssh2-*
./configure \
    --disable-shared \
    --enable-static \
    --prefix=/usr/local/$HOST \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    LIBS="-lws2_32"
make -j$(nproc) install
cd ..

# 下载并编译 aria2
echo "$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 aria2"
PKG_CONFIG_PATH=/usr/local/$HOST/lib/pkgconfig
ARIA2_VERSION=master
ARIA2_REF=refs/heads/master
curl -L -o version.json https://api.github.com/repos/aria2/aria2/git/$ARIA2_REF
git clone -b $ARIA2_VERSION --depth 1 https://github.com/aria2/aria2.git
cd aria2
sed -i 's/"1", 1, 16/"1", 1, 1024/' src/OptionHandlerFactory.cc
sed -i 's/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1M", 1_m, 1_g))/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1K", 1_k, 1_g))/g' src/OptionHandlerFactory.cc
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
echo "当前完整路径是: $PWD"
# 查找 aria2c.exe 并显示其完整路径
echo "$(date '+%Y/%m/%d %a %H:%M:%S.%N') - Finding aria2c.exe"
find $(pwd) -name "aria2c.exe" -exec realpath {} \;
echo "$(date '+%Y/%m/%d %a %H:%M:%S.%N') - Script finished"
