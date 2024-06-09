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

# Change HOST to x86_64-w64-mingw32 to build 64-bit binary
HOST=x86_64-w64-mingw32
PREFIX=/usr/local/$HOST

# It would be better to use nearest ubuntu archive mirror for faster
# downloads.

apt-get update && \
DEBIAN_FRONTEND="noninteractive" apt-get upgrade -y && \
apt-get install -y --no-install-recommends \
    make binutils autoconf automake autotools-dev libtool \
    patch ca-certificates \
    pkg-config git curl dpkg-dev gcc-mingw-w64 g++-mingw-w64 \
    autopoint libcppunit-dev libxml2-dev libgcrypt20-dev lzip \
    python3-docutils

curl -L -O https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz && \
curl -L -O https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.bz2 && \
curl -L -O https://www.sqlite.org/2024/sqlite-autoconf-3460000.tar.gz && \
curl -L -O https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz && \
curl -L -O https://github.com/c-ares/c-ares/releases/download/v1.30.0/c-ares-1.30.0.tar.gz && \
curl -L -O https://libssh2.org/download/libssh2-1.11.0.tar.gz

tar xf gmp-6.3.0.tar.xz && \
cd gmp-* && \
./configure \
    --disable-shared \
    --enable-static \
    --prefix=/usr/local/$HOST \
    --host=$HOST \
    --disable-cxx \
    --enable-fat \
    CFLAGS="-mtune=generic -O2 -g0" && \
make -j$(nproc) install
cd ..

tar xf expat-2.6.2.tar.bz2 && \
cd expat-* && \
./configure \
    --disable-shared \
    --enable-static \
    --prefix=/usr/local/$HOST \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) && \
make -j$(nproc) install
cd ..

tar xf sqlite-autoconf-3460000.tar.gz && \
cd sqlite-autoconf-* && \
./configure \
    --disable-shared \
    --enable-static \
    --prefix=/usr/local/$HOST \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) && \
make -j$(nproc) install
cd ..

file zlib-1.3.1.tar.gz && \
tar xf zlib-1.3.1.tar.gz && \
cd zlib-* && \
CC=$HOST-gcc \
AR=$HOST-ar \
LD=$HOST-ld \
RANLIB=$HOST-ranlib \
STRIP=$HOST-strip \
./configure \
    --prefix=/usr/local/$HOST \
    --libdir=/usr/local/$HOST/lib \
    --includedir=/usr/local/$HOST/include \
    --static && \
make -j$(nproc) install
cd ..

tar xf c-ares-1.30.0.tar.gz && \
cd c-ares-* && \
./configure \
    --disable-shared \
    --enable-static \
    --without-random \
    --prefix=/usr/local/$HOST \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    LIBS="-lws2_32" && \
make -j$(nproc) install
cd ..

tar xf libssh2-1.11.0.tar.gz && \
cd libssh2-* && \
./configure \
    --disable-shared \
    --enable-static \
    --prefix=/usr/local/$HOST \
    --host=$HOST \
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    LIBS="-lws2_32" && \
make -j$(nproc) install
cd ..

PKG_CONFIG_PATH=/usr/local/$HOST/lib/pkgconfig
ARIA2_VERSION=master
ARIA2_REF=refs/heads/master
curl -L -o version.json https://api.github.com/repos/aria2/aria2/git/$ARIA2_REF
git clone -b $ARIA2_VERSION --depth 1 https://github.com/aria2/aria2.git && \
cd aria2 && \
sed -i 's/"1", 1, 16/"1", 1, 1024/' src/OptionHandlerFactory.cc && \
sed -i 's/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1M", 1_m, 1_g))/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1K", 1_k, 1_g))/g' src/OptionHandlerFactory.cc && \
autoreconf -i && \
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
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" && \
make -j$(nproc) && \
$HOST-strip src/aria2c.exe
