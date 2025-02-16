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
curl -L https://github.com/mstorsjo/llvm-mingw/releases/download/20250212/llvm-mingw-20250212-ucrt-ubuntu-20.04-x86_64.tar.xz | tar x --xz
mv llvm-mingw-20250212-ucrt-ubuntu-20.04-x86_64 llvm-mingw
export PATH=$(pwd)/llvm-mingw/bin:$PATH
export LD=x86_64-w64-mingw32-ld.lld
export CC=x86_64-w64-mingw32-clang
export CXX=x86_64-w64-mingw32-clang++
export AR=x86_64-w64-mingw32-ar
export RANLIB=x86_64-w64-mingw32-ranlib
export STRIP=x86_64-w64-mingw32-strip

set -euo pipefail
HOST=x86_64-w64-mingw32
PREFIX=$PWD/$HOST
SELF_DIR="$(dirname "$(realpath "${0}")")"
BUILD_INFO="${SELF_DIR}/build_info.md"
export PKG_CONFIG_PATH=${PKG_CONFIG_PATH:-/usr/lib/pkgconfig:/usr/local/lib/pkgconfig:$PREFIX/lib/pkgconfig}
export CFLAGS="-march=tigerlake -mtune=tigerlake -O2 -ffunction-sections -fdata-sections -flto=$(nproc) -pipe  -g0"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,--gc-sections -flto=$(nproc)"

echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 检查 clang 版本⭐⭐⭐⭐⭐⭐"
x86_64-w64-mingw32-clang --version

echo "x86_64-w64-mingw32-gcc版本 (为了对比，实际上已经切换到 clang 了):"
x86_64-w64-mingw32-gcc --version

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

# patch configure（不检测long long），与原脚本相同
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

BUILD_CC=$CC BUILD_CXX=$CXX ./configure \
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

# 下载并编译 Expat
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 Expat⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
expat_tag=$(retry curl -s https://api.github.com/repos/libexpat/libexpat/releases/latest | jq -r '.tag_name' | sed 's/R_//' | tr _ .)
expat_latest_url=$(retry curl -s "https://api.github.com/repos/libexpat/libexpat/releases/latest" | jq -r '.assets[] | select(.name | test("\\.tar\\.bz2$")) | .browser_download_url' | head -n 1)
echo "libexpat最新版本是${expat_tag} ，下载地址是${expat_latest_url}"
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
$AR cr libsqlite3.a sqlite3.o # 使用 AR 变量
cp libsqlite3.a "$PREFIX/lib/" ||  exit 1
echo "| sqlite | ${sqlite_tag} | ${sqlite_latest_url} |" >>"${BUILD_INFO}"
cd ..
end_time=$(date +%s.%N)
duration4=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")

export LDFLAGS="-L$PREFIX/lib -flto=$(nproc)"

# 下载并编译 zlib
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 zlib⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
zlib_tag=$(retry curl -s https://api.github.com/repos/madler/zlib/releases/latest | jq -r '.name' | cut -d' ' -f2)
zlib_latest_url=$(retry curl -s "https://api.github.com/repos/madler/zlib/releases/latest" | jq -r '.assets[] | select(.name | test("\\.tar\\.gz$")) | .browser_download_url' | head -n 1)
echo "zlib最新版本是${zlib_tag} ，下载地址是${zlib_latest_url}"
curl -L ${zlib_latest_url} | tar xz
cd zlib-*
# 显式指定 clang 工具链 - 实际上这里环境变量已经设置，configure 会自动使用
# CC=$HOST-clang
# AR=$HOST-ar
# LD=$HOST-ld
# RANLIB=$HOST-ranlib
# STRIP=$HOST-strip
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

# 下载并编译 libssh2
echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S.%N') - 下载并编译 libssh2⭐⭐⭐⭐⭐⭐"
start_time=$(date +%s.%N)
libssh2_tag=$(retry curl -s https://libssh2.org/ | sed -nr 's@.*libssh2 ([^<]*).*released on.*@\1@p')
libssh2_latest_url="https://libssh2.org/download/libssh2-${libssh2_tag}.tar.gz"
echo "libssh2最新版本是${libssh2_tag} ，下载地址是${libssh2_latest_url}"
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
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
    CC=$CC \ # 确保 configure 也使用 Clang
    CXX=$CXX # 确保 configure 也使用 Clang++
make -j$(nproc)
$STRIP src/aria2c.exe # 使用 STRIP 变量
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
