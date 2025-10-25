#!/bin/bash

set -euo pipefail

# 配置常量
readonly HOST=x86_64-w64-mingw32
readonly PREFIX="$PWD/$HOST"
readonly SELF_DIR="$(dirname "$(realpath "${0}")")"
readonly BUILD_INFO="${SELF_DIR}/build_info.md"
readonly JOBS=$(nproc)
readonly BUILD_DIR="$PWD/build"
readonly DOWNLOAD_DIR="$PWD/downloads"
readonly TMPFS_DIR="/dev/shm/aria2-build"

# 编译优化选项
export CFLAGS="-march=native -O3 -ffunction-sections -fdata-sections -flto=$JOBS -pipe -g0 -fno-semantic-interposition"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-Wl,--gc-sections -flto=$JOBS -static -Wl,--enable-stdcall-fixup -s"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:/usr/lib/pkgconfig:/usr/local/lib/pkgconfig"
export AR="$HOST-ar"
export RANLIB="$HOST-ranlib"

# 版本缓存
declare -A VERSIONS DOWNLOAD_URLS

# 创建必要目录
mkdir -p "$BUILD_DIR" "$DOWNLOAD_DIR" "$PREFIX"

# 统一的日志函数
log() {
    echo "⭐⭐⭐⭐⭐⭐$(date '+%Y/%m/%d %a %H:%M:%S') - $1 ⭐⭐⭐⭐⭐⭐"
}

# 计时函数
timer() {
    local start_time=$(date +%s.%N)
    local job_name="$1"
    shift
    
    log "开始 $job_name"
    "$@"
    local exit_code=$?
    
    local end_time=$(date +%s.%N)
    local duration=$(echo "$end_time - $start_time" | bc | xargs printf "%.1f")
    
    log "$job_name 完成，用时 ${duration}s"
    return $exit_code
}

# 重试函数
retry() {
    local max_retries=5
    local sleep_seconds=3
    local attempt=1
    local command=("$@")
    
    while [ $attempt -le $max_retries ]; do
        if [ $attempt -gt 1 ]; then
            log "第 $attempt 次重试: ${command[*]}"
        fi
        
        if "${command[@]}"; then
            return 0
        fi
        
        sleep $sleep_seconds
        ((attempt++))
    done
    
    log "命令 '${command[*]}' 失败，已达最大重试次数"
    return 1
}

# 并行下载函数
parallel_download() {
    local urls=("$@")
    local pid_list=()
    local download_ok=true
    
    for url in "${urls[@]}"; do
        local filename="$DOWNLOAD_DIR/$(basename "$url")"
        if [[ ! -f "$filename" ]] || [[ ! -s "$filename" ]]; then
            log "下载: $(basename "$filename")"
            curl -fSL --connect-timeout 30 --retry 3 --retry-delay 2 -o "$filename" "$url" &
            pid_list+=($!)
        else
            log "使用缓存: $(basename "$filename")"
        fi
    done
    
    # 等待所有下载完成
    for pid in "${pid_list[@]}"; do
        if ! wait "$pid"; then
            log "下载进程 $pid 失败"
            download_ok=false
        fi
    done
    
    $download_ok
}

# 设置内存盘加速
setup_tmpfs() {
    if [[ -w "/dev/shm" ]] && [[ ! -d "$TMPFS_DIR" ]]; then
        mkdir -p "$TMPFS_DIR"
        export TMPDIR="$TMPFS_DIR"
        log "使用内存盘加速: $TMPFS_DIR"
    fi
}

# 清理临时文件
clean_intermediate_files() {
    log "清理中间文件"
    find "$BUILD_DIR" -name "*.o" -delete 2>/dev/null || true
    find "$BUILD_DIR" -name "*.lo" -delete 2>/dev/null || true
    find "$BUILD_DIR" -name ".deps" -type d -exec rm -rf {} + 2>/dev/null || true
    find "$BUILD_DIR" -name ".libs" -type d -exec rm -rf {} + 2>/dev/null || true
}

# 检查是否需要重新编译
should_rebuild() {
    local lib="$1"
    local version="$2"
    local stamp_file="$BUILD_DIR/${lib}.stamp"
    
    if [[ -f "$stamp_file" ]]; then
        local cached_version=$(cat "$stamp_file")
        if [[ "$cached_version" == "$version" ]]; then
            log "$lib $version 已构建，跳过"
            return 1
        fi
    fi
    return 0
}

# 标记构建完成
mark_built() {
    local lib="$1"
    local version="$2"
    echo "$version" > "$BUILD_DIR/${lib}.stamp"
}

# 智能配置函数
configure_library() {
    local name="$1"
    shift
    local extra_args=("$@")
    
    local common_args=(
        "--disable-shared"
        "--enable-static" 
        "--prefix=$PREFIX"
        "--host=$HOST"
        "--build=$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)"
        "--enable-silent-rules"
    )
    
    log "配置 $name: ${common_args[*]} ${extra_args[*]}"
    ./configure "${common_args[@]}" "${extra_args[@]}"
}

# 获取最新版本信息
cache_versions() {
    log "获取最新版本信息"
    
    # GMP
    VERSIONS[gmp]=$(retry curl -fs https://mirrors.kernel.org/gnu/gmp/ | \
        grep -oE 'href="gmp-[0-9.]+\.tar\.(xz|gz)"' | \
        sed -r 's/href="gmp-([0-9.]+)\.tar\..+"/\1/' | \
        sort -rV | head -1)
    DOWNLOAD_URLS[gmp]="https://ftp.gnu.org/gnu/gmp/gmp-${VERSIONS[gmp]}.tar.xz"
    
    # Expat
    VERSIONS[expat]=$(retry curl -fs https://api.github.com/repos/libexpat/libexpat/releases/latest | \
        jq -r '.tag_name | sub("^R_"; "") | gsub("_"; ".")')
    DOWNLOAD_URLS[expat]=$(retry curl -fs "https://api.github.com/repos/libexpat/libexpat/releases/latest" | \
        jq -r '.assets[] | select(.name | test("\\.tar\\.bz2$")) | .browser_download_url' | head -1)
    
    # SQLite
    VERSIONS[sqlite]=$(retry curl -fs https://sqlite.org/index.html | \
        awk '/Version [0-9]+\.[0-9]+\.[0-9]+/ {match($0, /Version ([0-9]+\.[0-9]+\.[0-9]+)/, a); print a[1]; exit}')
    local download_page=$(retry curl -fsL "https://www.sqlite.org/download.html")
    local csv_data=$(echo "$download_page" | sed -n '/Download product data for scripts to read/,/-->/p')
    local tarball_url=$(echo "$csv_data" | grep "autoconf.*\.tar\.gz" | cut -d ',' -f 3 | head -n 1)
    DOWNLOAD_URLS[sqlite]="https://www.sqlite.org/${tarball_url}"
    
    # zlib
    VERSIONS[zlib]=$(retry curl -fs https://api.github.com/repos/madler/zlib/releases/latest | \
        jq -r '.tag_name | sub("^v"; "")')
    DOWNLOAD_URLS[zlib]="https://github.com/madler/zlib/releases/download/v${VERSIONS[zlib]}/zlib-${VERSIONS[zlib]}.tar.gz"
    
    # c-ares
    VERSIONS[cares]=$(retry curl -fs https://api.github.com/repos/c-ares/c-ares/releases/latest | \
        jq -r '.tag_name | sub("^v"; "")')
    DOWNLOAD_URLS[cares]="https://github.com/c-ares/c-ares/releases/download/v${VERSIONS[cares]}/c-ares-${VERSIONS[cares]}.tar.gz"
    
    # libssh2
    VERSIONS[libssh2]=$(retry curl -fs https://libssh2.org/download/ | \
        grep -o 'libssh2-[0-9.]*\.tar\.\(gz\|xz\)' | \
        sed -n 's/.*libssh2-\([0-9.]*\)\.tar\.\(gz\|xz\).*/\1/p' | \
        sort -V | tail -n 1)
    DOWNLOAD_URLS[libssh2]="https://libssh2.org/download/libssh2-${VERSIONS[libssh2]}.tar.gz"
    
    log "版本信息获取完成"
}

# 初始化构建信息
init_build_info() {
    cat > "$BUILD_INFO" << EOF
## aria2c.exe 构建信息

构建时间: $(date)
构建主机: $HOST
编译线程数: $JOBS

### 依赖库版本

| Dependency | Version | Source |
|------------|---------|--------|
EOF
}

# 下载工具链
download_toolchain() {
    local USE_GCC=0
    
    if [[ $USE_GCC -eq 1 ]]; then
        log "使用 GCC 工具链"
        retry curl -fSL -o "/tmp/mingw-w64-x86_64-toolchain.tar.zst" \
            "https://github.com/rzhy1/build-mingw-w64/releases/download/mingw-w64/mingw-w64-x86_64-toolchain.tar.zst"
        sudo tar --zstd -xf "/tmp/mingw-w64-x86_64-toolchain.tar.zst" -C /usr/
    else
        log "使用 musl-cross 工具链"
        retry curl -fSL -o "/tmp/x86_64-w64-mingw32.tar.xz" \
            "https://github.com/rzhy1/musl-cross/releases/download/mingw-w64/x86_64-w64-mingw32-1.tar.xz"
        sudo mkdir -p /opt/mingw64
        sudo tar -xf "/tmp/x86_64-w64-mingw32.tar.xz" --strip-components=1 -C /opt/mingw64
        export PATH="/opt/mingw64/bin:${PATH}"
    fi
    
    # 创建符号链接
    sudo ln -sf "$(which lld-link)" "/usr/bin/x86_64-w64-mingw32-ld.lld" 2>/dev/null || true
    
    # 验证工具链
    log "工具链版本信息"
    x86_64-w64-mingw32-gcc --version | head -1
}

# 构建 GMP
build_gmp() {
    local version="${VERSIONS[gmp]}"
    local url="${DOWNLOAD_URLS[gmp]}"
    
    if ! should_rebuild "gmp" "$version"; then
        return 0
    fi
    
    local tarball="$DOWNLOAD_DIR/$(basename "$url")"
    [[ -f "$tarball" ]] || { log "文件不存在: $tarball"; return 1; }
    
    # 清理旧构建
    rm -rf "$BUILD_DIR/gmp-$version"
    mkdir -p "$BUILD_DIR/gmp-$version"
    
    # 解压到构建目录
    tar -xf "$tarball" -C "$BUILD_DIR/gmp-$version" --strip-components=1
    cd "$BUILD_DIR/gmp-$version"
    
    # 应用补丁避免长long检测
    sed -i '
        /Test compile: long long reliability test/,+37 {
            /^#/! s/^/#/
        }
    ' configure
    
    # 配置和编译
    BUILD_CC=gcc BUILD_CXX=g++ configure_library "gmp" \
        --enable-cxx \
        --disable-assembly
    
    make -j$JOBS
    make install
    
    # 记录构建信息
    echo "| gmp | $version | $url |" >> "$BUILD_INFO"
    
    mark_built "gmp" "$version"
    cd - >/dev/null
}

# 构建 Expat
build_expat() {
    local version="${VERSIONS[expat]}"
    local url="${DOWNLOAD_URLS[expat]}"
    
    if ! should_rebuild "expat" "$version"; then
        return 0
    fi
    
    local tarball="$DOWNLOAD_DIR/$(basename "$url")"
    [[ -f "$tarball" ]] || { log "文件不存在: $tarball"; return 1; }
    
    rm -rf "$BUILD_DIR/expat-$version"
    mkdir -p "$BUILD_DIR/expat-$version"
    tar -xf "$tarball" -C "$BUILD_DIR/expat-$version" --strip-components=1
    cd "$BUILD_DIR/expat-$version"
    
    configure_library "expat" \
        --without-examples \
        --without-tests
    
    make -j$JOBS
    make install
    
    echo "| libexpat | $version | $url |" >> "$BUILD_INFO"
    mark_built "expat" "$version"
    cd - >/dev/null
}

# 构建 SQLite
build_sqlite() {
    local version="${VERSIONS[sqlite]}"
    local url="${DOWNLOAD_URLS[sqlite]}"
    
    if ! should_rebuild "sqlite" "$version"; then
        return 0
    fi
    
    local tarball="$DOWNLOAD_DIR/$(basename "$url")"
    [[ -f "$tarball" ]] || { log "文件不存在: $tarball"; return 1; }
    
    rm -rf "$BUILD_DIR/sqlite-$version"
    mkdir -p "$BUILD_DIR/sqlite-$version"
    tar -xf "$tarball" -C "$BUILD_DIR/sqlite-$version" --strip-components=1
    cd "$BUILD_DIR/sqlite-$version"
    
    # 临时修改LDFLAGS
    local old_ldflags="$LDFLAGS"
    export LDFLAGS="$old_ldflags -L/opt/mingw64/x86_64-w64-mingw32/sysroot/usr/x86_64-w64-mingw32/lib -lpthread"
    
    configure_library "sqlite" \
        --enable-threadsafe \
        --disable-debug \
        --disable-editline \
        --disable-fts3 --disable-fts4 --disable-fts5 \
        --disable-rtree \
        --disable-session \
        --disable-load-extension
    
    make -j$JOBS
    make install
    
    # 创建静态库
    $HOST-ar cr libsqlite3.a sqlite3.o
    cp libsqlite3.a "$PREFIX/lib/"
    
    export LDFLAGS="$old_ldflags"
    echo "| sqlite | $version | $url |" >> "$BUILD_INFO"
    mark_built "sqlite" "$version"
    cd - >/dev/null
}

# 构建 zlib
build_zlib() {
    local version="${VERSIONS[zlib]}"
    local url="${DOWNLOAD_URLS[zlib]}"
    
    if ! should_rebuild "zlib" "$version"; then
        return 0
    fi
    
    local tarball="$DOWNLOAD_DIR/$(basename "$url")"
    [[ -f "$tarball" ]] || { log "文件不存在: $tarball"; return 1; }
    
    rm -rf "$BUILD_DIR/zlib-$version"
    mkdir -p "$BUILD_DIR/zlib-$version"
    tar -xf "$tarball" -C "$BUILD_DIR/zlib-$version" --strip-components=1
    cd "$BUILD_DIR/zlib-$version"
    
    # zlib 使用自定义配置
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
    
    make -j$JOBS
    make install
    
    echo "| zlib | $version | $url |" >> "$BUILD_INFO"
    mark_built "zlib" "$version"
    cd - >/dev/null
}

# 构建 c-ares
build_cares() {
    local version="${VERSIONS[cares]}"
    local url="${DOWNLOAD_URLS[cares]}"
    
    if ! should_rebuild "cares" "$version"; then
        return 0
    fi
    
    local tarball="$DOWNLOAD_DIR/$(basename "$url")"
    [[ -f "$tarball" ]] || { log "文件不存在: $tarball"; return 1; }
    
    rm -rf "$BUILD_DIR/c-ares-$version"
    mkdir -p "$BUILD_DIR/c-ares-$version"
    tar -xf "$tarball" -C "$BUILD_DIR/c-ares-$version" --strip-components=1
    cd "$BUILD_DIR/c-ares-$version"
    
    configure_library "c-ares" \
        --disable-tests \
        --without-random \
        LIBS="-lws2_32"
    
    make -j$JOBS
    make install
    
    echo "| c-ares | $version | $url |" >> "$BUILD_INFO"
    mark_built "cares" "$version"
    cd - >/dev/null
}

# 构建 libssh2
build_libssh2() {
    local version="${VERSIONS[libssh2]}"
    local url="${DOWNLOAD_URLS[libssh2]}"
    
    if ! should_rebuild "libssh2" "$version"; then
        return 0
    fi
    
    local tarball="$DOWNLOAD_DIR/$(basename "$url")"
    [[ -f "$tarball" ]] || { log "文件不存在: $tarball"; return 1; }
    
    rm -rf "$BUILD_DIR/libssh2-$version"
    mkdir -p "$BUILD_DIR/libssh2-$version"
    tar -xf "$tarball" -C "$BUILD_DIR/libssh2-$version" --strip-components=1
    cd "$BUILD_DIR/libssh2-$version"
    
    configure_library "libssh2" \
        --disable-examples-build \
        --disable-docker-tests \
        --disable-sshd-tests \
        --disable-debug \
        LIBS="-lws2_32"
    
    make -j$JOBS
    make install
    
    echo "| libssh2 | $version | $url |" >> "$BUILD_INFO"
    mark_built "libssh2" "$version"
    cd - >/dev/null
}

# 构建 aria2
build_aria2() {
    cd "$BUILD_DIR"
    
    local aria2_dir="$BUILD_DIR/aria2"
    if [[ ! -d "$aria2_dir" ]]; then
        log "克隆 aria2 仓库"
        git clone --depth 1 --branch master --single-branch \
            https://github.com/aria2/aria2.git
    else
        log "更新 aria2 仓库"
        cd aria2
        git pull origin master
        cd ..
    fi
    
    cd aria2
    
    # 应用性能优化补丁
    sed -i '
        s/"1", 1, 16/"1", 1, 1024/
        s/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1M", 1_m, 1_g))/PREF_PIECE_LENGTH, TEXT_PIECE_LENGTH, "1K", 1_k, 1_g))/g
    ' src/OptionHandlerFactory.cc
    
    # 配置编译环境
    export CPPFLAGS="-I$PREFIX/include -DNDEBUG -DHAVE_MMAP=0"
    export LIBS="-lws2_32 -liphlpapi"
    
    autoreconf -i
    
    ./configure \
        --host=$HOST \
        --prefix=$PREFIX \
        --with-sysroot=$PREFIX \
        --enable-static \
        --disable-shared \
        --with-libz \
        --with-libgmp \
        --with-libssh2 \
        --with-libcares \
        --with-sqlite3 \
        --with-libexpat \
        --without-libxml2 \
        --without-openssl \
        --without-gnutls \
        --disable-nls \
        --disable-debug \
        --disable-epoll \
        ARIA2_STATIC=yes \
        SQLITE3_LIBS="-L$PREFIX/lib -lsqlite3" \
        PKG_CONFIG="/usr/bin/pkg-config" \
        CXXFLAGS="$CXXFLAGS" \
        LDFLAGS="$LDFLAGS"
    
    # 并行编译
    make -j$JOBS
    
    # 优化和验证二进制
    $HOST-strip -s src/aria2c.exe
    
    if file src/aria2c.exe | grep -q "PE32+"; then
        cp src/aria2c.exe "$SELF_DIR/"
        log "构建成功: $SELF_DIR/aria2c.exe"
        
        # 获取版本信息
        local aria2_version=$(grep -oP 'aria2 \K\d+(\.\d+)*' NEWS 2>/dev/null || echo "master")
        echo "| aria2 | $aria2_version | https://github.com/aria2/aria2/archive/master.tar.gz |" >> "$BUILD_INFO"
    else
        log "构建失败：二进制格式错误"
        return 1
    fi
    
    cd - >/dev/null
}

# 依赖关系构建
build_dependencies() {
    log "开始构建依赖库"
    
    # 并行下载所有依赖
    parallel_download "${DOWNLOAD_URLS[@]}"
    
    # 按依赖顺序构建
    timer "构建 GMP" build_gmp
    timer "构建 Expat" build_expat
    timer "构建 SQLite" build_sqlite
    timer "构建 zlib" build_zlib
    timer "构建 c-ares" build_cares
    timer "构建 libssh2" build_libssh2
}

# 资源监控（后台进程）
start_resource_monitor() {
    local monitor_pid_file="$BUILD_DIR/monitor.pid"
    
    {
        echo "时间,CPU使用%,内存使用%,磁盘使用MB"
        while [[ -f "$BUILD_DIR/build.started" ]]; do
            local cpu=$(ps -o %cpu= -p $$ 2>/dev/null | tr -d ' ' || echo "0")
            local mem=$(ps -o %mem= -p $$ 2>/dev/null | tr -d ' ' || echo "0")
            local disk=$(du -sm "$BUILD_DIR" 2>/dev/null | cut -f1 || echo "0")
            echo "$(date '+%H:%M:%S'),$cpu,$mem,$disk"
            sleep 30
        done
    } > "$BUILD_DIR/resources.csv" &
    
    echo $! > "$monitor_pid_file"
}

stop_resource_monitor() {
    local monitor_pid_file="$BUILD_DIR/monitor.pid"
    if [[ -f "$monitor_pid_file" ]]; then
        local pid=$(cat "$monitor_pid_file")
        kill "$pid" 2>/dev/null || true
        rm -f "$monitor_pid_file"
    fi
}

# 主构建流程
main() {
    log "开始构建 aria2 Windows 版本"
    
    # 标记构建开始
    touch "$BUILD_DIR/build.started"
    
    # 初始化
    init_build_info
    setup_tmpfs
    
    # 启动资源监控
    start_resource_monitor
    
    # 下载和设置工具链
    timer "下载工具链" download_toolchain
    
    # 获取版本信息
    timer "获取版本信息" cache_versions
    
    # 构建依赖库
    build_dependencies
    
    # 构建 aria2
    timer "构建 aria2" build_aria2
    
    # 清理
    clean_intermediate_files
    stop_resource_monitor
    rm -f "$BUILD_DIR/build.started"
    
    # 输出总结
    log "构建完成总结"
    echo "=========================================="
    echo "最终二进制: $SELF_DIR/aria2c.exe"
    echo "构建信息: $BUILD_INFO"
    echo "二进制大小: $(du -h "$SELF_DIR/aria2c.exe" | cut -f1)"
    echo "文件类型: $(file "$SELF_DIR/aria2c.exe")"
    echo "=========================================="
    
    # 清理内存盘
    if [[ -d "$TMPFS_DIR" ]]; then
        rm -rf "$TMPFS_DIR"
    fi
}

# 信号处理
trap 'log "构建被中断"; stop_resource_monitor; exit 1' INT TERM
trap 'clean_intermediate_files; stop_resource_monitor' EXIT

# 运行主函数
main "$@"
