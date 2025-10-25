#!/bin/bash

set -euo pipefail

# 配置
HOST=x86_64-w64-mingw32
PREFIX="$PWD/$HOST"
SELF_DIR="$(dirname "$(realpath "${0}")")"
BUILD_INFO="${SELF_DIR}/build_info.md"
JOBS=$(nproc)
BUILD_DIR="$PWD/build"
DOWNLOAD_DIR="$PWD/downloads"

# 编译优化
export CFLAGS="-march=native -O3 -ffunction-sections -fdata-sections -flto=$JOBS -pipe -g0"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,--gc-sections -flto=$JOBS -static -s"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:/usr/lib/pkgconfig"

mkdir -p "$BUILD_DIR" "$DOWNLOAD_DIR" "$PREFIX"

# 工具函数
log() { echo "⭐⭐ $1 ⭐⭐"; }
timer() { 
    local task_name="$1"
    shift
    local start=$(date +%s.%N)
    log "开始 $task_name"
    "$@"
    local end=$(date +%s.%N)
    local duration=$(echo "$end - $start" | bc | xargs printf "%.1f")
    log "$task_name 完成: ${duration}s"
}
retry() { for i in {1..5}; do "$@" && return 0; sleep 3; done; return 1; }

# 初始化构建信息
echo "## aria2c.exe 构建信息" > "$BUILD_INFO"
echo "| Dependency | Version | Source |" >> "$BUILD_INFO"
echo "|------------|---------|--------|" >> "$BUILD_INFO"

# 下载工具链
download_toolchain() {
    log "下载工具链"
    curl -fSL -o "/tmp/x86_64-w64-mingw32.tar.xz" \
        "https://github.com/rzhy1/musl-cross/releases/download/mingw-w64/x86_64-w64-mingw32-1.tar.xz"
    sudo mkdir -p /opt/mingw64
    sudo tar -xf "/tmp/x86_64-w64-mingw32.tar.xz" --strip-components=1 -C /opt/mingw64
    export PATH="/opt/mingw64/bin:${PATH}"
    sudo ln -sf "$(which lld-link)" "/usr/bin/x86_64-w64-mingw32-ld.lld" 2>/dev/null || true
}

# 智能构建函数
build_lib() {
    local name=$1 version_cmd=$2 url_cmd=$3 configure_args=$4
    local version=$(eval "$version_cmd")
    local url=$(eval "$url_cmd")
    
    log "构建 $name $version"
    
    # 下载
    local tarball="$DOWNLOAD_DIR/$(basename "$url")"
    [[ ! -f "$tarball" ]] && curl -fSL -o "$tarball" "$url"
    
    # 解压和构建
    rm -rf "$BUILD_DIR/$name-$version"
    mkdir -p "$BUILD_DIR/$name-$version"
    tar -xf "$tarball" -C "$BUILD_DIR/$name-$version" --strip-components=1
    cd "$BUILD_DIR/$name-$version"
    
    # 特殊处理
    case $name in
        gmp) 
            sed -i '/Test compile: long long reliability test/,+37s/^/#/' configure 
            BUILD_CC=gcc BUILD_CXX=g++ ./configure --disable-shared --enable-static --prefix=$PREFIX --host=$HOST --enable-cxx --disable-assembly
            ;;
        zlib) 
            CC=$HOST-gcc AR=$HOST-ar ./configure --prefix=$PREFIX --static
            make -j$JOBS install
            cd - >/dev/null
            echo "| $name | $version | $url |" >> "$BUILD_INFO"
            return
            ;;
        *) 
            ./configure --disable-shared --enable-static --prefix=$PREFIX --host=$HOST $configure_args
            ;;
    esac
    
    # 通用编译和安装
    make -j$JOBS install
    
    echo "| $name | $version | $url |" >> "$BUILD_INFO"
    cd - >/dev/null
}

# 主构建流程
main() {
    log "开始构建 aria2"
    
    # 工具链
    timer "download_toolchain" download_toolchain
    
    # 并行下载所有依赖
    log "并行下载依赖"
    
    # GMP
    build_lib gmp \
        "curl -fs https://mirrors.kernel.org/gnu/gmp/ | grep -oE 'href=\"gmp-[0-9.]+\\.tar\\.(xz|gz)\"' | sed -r 's/href=\"gmp-([0-9.]+)\\.tar\\..+\"/\\1/' | sort -rV | head -1" \
        "echo \"https://ftp.gnu.org/gnu/gmp/gmp-\$version.tar.xz\"" \
        "--enable-cxx --disable-assembly" &
    
    # Expat
    build_lib expat \
        "curl -fs https://api.github.com/repos/libexpat/libexpat/releases/latest | jq -r '.tag_name | sub(\"^R_\"; \"\") | gsub(\"_\"; \".\")'" \
        "curl -fs \"https://api.github.com/repos/libexpat/libexpat/releases/latest\" | jq -r '.assets[] | select(.name | test(\"\\.tar\\.bz2$\")) | .browser_download_url' | head -1" \
        "--without-examples --without-tests" &
    
    # SQLite
    build_lib sqlite \
        "curl -fs https://sqlite.org/index.html | awk '/Version [0-9]+\\.[0-9]+\\.[0-9]+/ {match(\$0, /Version ([0-9]+\\.[0-9]+\\.[0-9]+)/, a); print a[1]; exit}'" \
        "echo \"https://www.sqlite.org/\$(curl -fsL https://www.sqlite.org/download.html | sed -n '/Download product data for scripts to read/,/-->/p' | grep 'autoconf.*\\.tar\\.gz' | cut -d ',' -f 3 | head -1)\"" \
        "--enable-threadsafe --disable-debug --disable-editline --disable-fts3 --disable-fts4 --disable-fts5 --disable-rtree --disable-session --disable-load-extension" &
    
    # zlib
    build_lib zlib \
        "curl -fs https://api.github.com/repos/madler/zlib/releases/latest | jq -r '.tag_name | sub(\"^v\"; \"\")'" \
        "echo \"https://github.com/madler/zlib/releases/download/v\$version/zlib-\$version.tar.gz\"" \
        "" &
    
    # c-ares
    build_lib cares \
        "curl -fs https://api.github.com/repos/c-ares/c-ares/releases/latest | jq -r '.tag_name | sub(\"^v\"; \"\")'" \
        "echo \"https://github.com/c-ares/c-ares/releases/download/v\$version/c-ares-\$version.tar.gz\"" \
        "--disable-tests --without-random LIBS=\"-lws2_32\"" &
    
    # libssh2
    build_lib libssh2 \
        "curl -fs https://libssh2.org/download/ | grep -o 'libssh2-[0-9.]*\\.tar\\.\\(gz\\|xz\\)' | sed -n 's/.*libssh2-\\([0-9.]*\\).tar\\.\\(gz\\|xz\\).*/\\1/p' | sort -V | tail -1" \
        "echo \"https://libssh2.org/download/libssh2-\$version.tar.gz\"" \
        "--disable-examples-build --disable-docker-tests --disable-sshd-tests --disable-debug LIBS=\"-lws2_32\"" &
    
    wait
    
    # 构建 aria2
    log "构建 aria2"
    cd "$BUILD_DIR"
    if [[ ! -d "aria2" ]]; then
        git clone --depth 1 https://github.com/aria2/aria2.git
    fi
    cd aria2
    
    # 优化配置
    sed -i 's/"1", 1, 16/"1", 1, 1024/; s/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1M", 1_m, 1_g))/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1K", 1_k, 1_g))/g' src/OptionHandlerFactory.cc
    
    autoreconf -i
    ./configure \
        --host=$HOST \
        --prefix=$PREFIX \
        --enable-static \
        --disable-shared \
        --with-libz --with-libgmp --with-libssh2 --with-libcares --with-sqlite3 --with-libexpat \
        --without-libxml2 --without-openssl \
        --disable-nls \
        ARIA2_STATIC=yes \
        CXXFLAGS="$CXXFLAGS" \
        LDFLAGS="$LDFLAGS"
    
    make -j$JOBS
    $HOST-strip -s src/aria2c.exe
    cp src/aria2c.exe "$SELF_DIR/"
    
    # 记录版本
    local aria2_version=$(grep -oP 'aria2 \K\d+(\.\d+)*' NEWS 2>/dev/null || echo "master")
    echo "| aria2 | $aria2_version | https://github.com/aria2/aria2 |" >> "$BUILD_INFO"
    
    log "构建完成: $SELF_DIR/aria2c.exe ($(du -h "$SELF_DIR/aria2c.exe" | cut -f1))"
}

# 运行
main "$@"
