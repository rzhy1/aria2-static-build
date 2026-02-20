#!/bin/bash

# Dockerfile to build aria2 Windows binary using ubuntu mingw-w64
# cross compiler chain.
#
# $ sudo docker build -t aria2-mingw - < Dockerfile.mingw

set -euo pipefail

HOST=x86_64-w64-mingw32
PREFIX=$PWD/$HOST
SELF_DIR="$(dirname "$(realpath "${0}")")"
BUILD_INFO="${SELF_DIR}/build_info.md"

# 🛠️ 关键修复 1：绝对禁止混入宿主机的 Linux pkgconfig
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

# 🛠️ 关键修复 2：加入 -static 确保没有任何 DLL 依赖
export CFLAGS="-march=tigerlake -mtune=tigerlake -O2 -ffunction-sections -fdata-sections -flto=$(nproc) -pipe -g0 -I$PREFIX/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,--gc-sections -flto=$(nproc) -static -static-libgcc -static-libstdc++ -L$PREFIX/lib"

echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S') - 下载并配置 mingw-w64⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
USE_GCC=0
if []; then
    echo "使用最新版的 mingw-w64-x86_64-toolchain (GCC 16)..."
    curl -SLf -o "/tmp/mingw-w64-x86_64-toolchain.tar.zst" "https://github.com/rzhy1/build-mingw-w64/releases/download/mingw-w64/mingw-w64-x86_64-toolchain.tar.zst"
    sudo tar --zstd -xf "/tmp/mingw-w64-x86_64-toolchain.tar.zst" -C /usr/
else
    echo "使用相对成熟的 musl-cross (GCC 15)..."
    curl -SLf -o "/tmp/x86_64-w64-mingw32.tar.xz"  "https://github.com/rzhy1/musl-cross/releases/download/mingw-w64/x86_64-w64-mingw32-1.tar.xz"
    sudo mkdir -p /opt/mingw64
    sudo tar -xf "/tmp/x86_64-w64-mingw32.tar.xz" --strip-components=1 -C /opt/mingw64
    export PATH="/opt/mingw64/bin:${PATH}"    
fi

if command -v lld-link >/dev/null 2>&1; then
    sudo ln -sf $(which lld-link) /usr/bin/x86_64-w64-mingw32-ld.lld
    export LD=x86_64-w64-mingw32-ld.lld
else
    export LD=$HOST-ld
fi

end_time=$(date +%s.%N)
duration1=$(awk -v t1=$start_time -v t2=$end_time 'BEGIN{printf "%.1f", t2-t1}')

echo "x86_64-w64-mingw32-gcc版本是："
$HOST-gcc --version

echo "## aria2c.exe dependencies:" >"${BUILD_INFO}"
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
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S') - 下载并编译 GMP⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
# 还原您原本完美的正则表达式
gmp_tag="$(retry curl -s https://ftp.gnu.org/gnu/gmp/ | grep -oE 'href="gmp-+\.tar\.(xz|gz)"' | sed -r 's/href="gmp-(+)\.tar\..+"/\1/' | sort -rV | head -n 1)"
echo "gmp最新版本是${gmp_tag} ，下载地址是https://ftp.gnu.org/gnu/gmp/gmp-${gmp_tag}.tar.xz"
rm -rf gmp-*
curl -L https://ftp.gnu.org/gnu/gmp/gmp-${gmp_tag}.tar.xz | tar x --xz
cd gmp-*

# 还原您的长格式注释函数
find_and_comment() {
  local file="$1"
  local search_str="Test compile: long long reliability test"
  local current_line=1
  while read -r start_line; do  
    [] && { echo "在文件 $file 中未找到更多字符串 '$search_str'"; break; }
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
duration2=$(awk -v t1=$start_time -v t2=$end_time 'BEGIN{printf "%.1f", t2-t1}')

# 2.  Expat
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S') - Expat⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
expat_tag=$(retry curl -s https://api.github.com/repos/libexpat/libexpat/releases/latest | jq -r '.tag_name' | sed 's/R_//' | tr _ .)
expat_latest_url=$(retry curl -s "https://api.github.com/repos/libexpat/libexpat/releases/latest" | jq -r '.assets[] | select(.name | test("\\.tar\\.bz2$")) | .browser_download_url' | head -n 1)
echo "libexpat最新版本是${expat_tag} ，下载地址是${expat_latest_url}"
rm -rf expat-*
curl -L ${expat_latest_url} | tar xj
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
duration3=$(awk -v t1=$start_time -v t2=$end_time 'BEGIN{printf "%.1f", t2-t1}')

# 3.  SQLite
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S') - SQLite⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
sqlite_tag=$(curl -s https://sqlite.org/index.html | awk '/Version+\.+\.+/ {match($0, /Version (+\.+\.+)/, a); print a; exit}')
download_page=$(curl -sL "https://www.sqlite.org/download.html")
csv_data=$(echo "$download_page" | sed -n '/Download product data for scripts to read/,/-->/p')
tarball_url=$(echo "$csv_data" | grep "autoconf.*\.tar\.gz" | cut -d ',' -f 3 | head -n 1)
sqlite_latest_url="https://www.sqlite.org/${tarball_url}"
echo "sqlite最新版本是${sqlite_tag}，下载地址是${sqlite_latest_url}"
rm -rf sqlite-*
curl -L ${sqlite_latest_url} | tar xz
cd sqlite-*
# 🛠️ 关键修复 3：移除被写死的 LDFLAGS 和手动覆盖行为
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
    --build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE) \
    LIBS="-lpthread"
make -j$(nproc) install
echo "| sqlite | ${sqlite_tag} | ${sqlite_latest_url} |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration4=$(awk -v t1=$start_time -v t2=$end_time 'BEGIN{printf "%.1f", t2-t1}')

# ⚠️ 注意：这里移除了您原本在 SQLite 之后意外重置 LDFLAGS 导致丢失垃圾回收参数的错误代码。

# 4. 下载并编译 zlib
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S') - zlib⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
zlib_tag=$(retry curl -s https://api.github.com/repos/madler/zlib/releases/latest | jq -r '.name' | cut -d' ' -f2)
zlib_latest_url=$(retry curl -s "https://api.github.com/repos/madler/zlib/releases/latest" | jq -r '.assets[] | select(.name | test("\\.tar\\.gz$")) | .browser_download_url' | head -n 1)
echo "zlib最新版本是${zlib_tag} ，下载地址是${zlib_latest_url}"
rm -rf zlib-*
curl -L ${zlib_latest_url} | tar xz
cd zlib-*
CC=$HOST-gcc AR=$HOST-ar LD=$HOST-ld RANLIB=$HOST-ranlib STRIP=$HOST-strip \
./configure \
    --prefix=$PREFIX \
    --libdir=$PREFIX/lib \
    --includedir=$PREFIX/include \
    --static
make -j$(nproc) install
echo "| zlib | ${zlib_tag} | ${zlib_latest_url} |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration5=$(awk -v t1=$start_time -v t2=$end_time 'BEGIN{printf "%.1f", t2-t1}')

# 5. 下载并编译 c-ares
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S') - c-ares⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
cares_tag=$(retry curl -s https://api.github.com/repos/c-ares/c-ares/releases/latest | jq -r '.tag_name | sub("^v"; "")')
cares_latest_url="https://github.com/c-ares/c-ares/releases/download/v${cares_tag}/c-ares-${cares_tag}.tar.gz"
echo "cares最新版本是${cares_tag} ，下载地址是${cares_latest_url}"
rm -rf c-ares-*
curl -L ${cares_latest_url} | tar xz
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
duration6=$(awk -v t1=$start_time -v t2=$end_time 'BEGIN{printf "%.1f", t2-t1}')

# 6. 下载并编译 libssh2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S') - libssh2⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
libssh2_tag=$(retry curl -s https://libssh2.org/download/ | grep -o 'libssh2-*\.tar\.\(gz\|xz\)' | sed -n 's/.*libssh2-\(*\)\.tar\.\(gz\|xz\).*/\1/p' | sort -V | tail -n 1)
libssh2_latest_url="https://libssh2.org/download/libssh2-${libssh2_tag}.tar.gz"
echo "libssh2最新版本是${libssh2_tag} ，下载地址是${libssh2_latest_url}"
rm -rf libssh2-*
curl -L ${libssh2_latest_url} | tar xz
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
duration7=$(awk -v t1=$start_time -v t2=$end_time 'BEGIN{printf "%.1f", t2-t1}')

# 7. 下载并编译 aria2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S') - aria2⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
ARIA2_REF=refs/heads/master
rm -rf aria2
git clone -j$(nproc) --depth 1 https://github.com/aria2/aria2.git
cd aria2
sed -i 's/"1", 1, 16/"1", 1, 1024/' src/OptionHandlerFactory.cc
sed -i 's/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1M", 1_m, 1_g))/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1K", 1_k, 1_g))/g' src/OptionHandlerFactory.cc
autoreconf -i

# 🛠️ 关键修复 4：加入了 --with-wintls，使 Windows 下能进行 HTTPS 下载
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
    --with-wintls \
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
    SQLITE3_LIBS="-L$PREFIX/lib -lsqlite3 -lpthread" \
    CPPFLAGS="-I$PREFIX/include"
make -j$(nproc)
$HOST-strip src/aria2c.exe
mv -fv "src/aria2c.exe" "${SELF_DIR}/aria2c.exe"

ARIA2_VER=$(grep -oP 'aria2 \K\d+(\.\d+)*' NEWS | head -n 1)
aria2_latest_url="https://github.com/aria2/aria2/archive/master.tar.gz"
echo "| aria2 |  ${ARIA2_VER} | ${aria2_latest_url:-cached aria2} |" >>"${BUILD_INFO}"
end_time=$(date +%s.%N)
duration8=$(awk -v t1=$start_time -v t2=$end_time 'BEGIN{printf "%.1f", t2-t1}')

echo "=============================================="
echo "下载mingw-w64用时: ${duration1}s"
echo "编译 GMP 用时: ${duration2}s"
echo "编译 Expat 用时: ${duration3}s"
echo "编译 SQLite 用时: ${duration4}s"
echo "编译 zlib 用时: ${duration5}s"
echo "编译 c-ares 用时: ${duration6}s"
echo "编译 libssh2 用时: ${duration7}s"
echo "编译 aria2 用时: ${duration8}s"
