#!/bin/bash
set -e

SERVICE="${1:-rpcbroker}"
MEDIA_DIR="${MEDIA_DIR:-/vol1/1000}"
PROXY_PREFIX="${PROXY_PREFIX:-}"

log() { echo "[entrypoint] $(date '+%H:%M:%S') $*"; }

# ============================================================
# 首次运行：下载并解压核心二进制（仅执行一次）
# ============================================================
init_downloads() {
    [ -f /opt/trim/.downloads_done ] && return 0
    log "首次运行，下载核心二进制..."

    local base="${PROXY_PREFIX}https://github.com/kesry/trimmedia-linux-arm/releases/download/v1.0.0"

    # fntv: trim-media 核心 + 库
    if [ ! -f /opt/trim/fntv/trim.media/trim-media ]; then
        log "下载 trim-media..."
        wget -q -O /tmp/trim.media.tar.gz "${base}/trim.media.tar.gz"
        mkdir -p /opt/trim/fntv
        tar xzf /tmp/trim.media.tar.gz -C /opt/trim/fntv/
        [ -d /opt/trim/fntv/lib ] || mkdir -p /opt/trim/fntv/lib
        cp /opt/trim/fntv/trim.media/lib/libwebp.so.7 /opt/trim/fntv/lib/ 2>/dev/null || true
        rm -f /tmp/trim.media.tar.gz
    fi

    # fnmusic: trim-music 核心
    if [ ! -f /opt/trim/fnmusic/trim.music/trim-music ]; then
        log "下载 trim-music..."
        wget -q -O /tmp/trim.music.tar.gz "${base}/trim.music.tar.gz"
        mkdir -p /opt/trim/fnmusic
        tar xzf /tmp/trim.music.tar.gz -C /opt/trim/fnmusic/
        [ -d /opt/trim/fnmusic/lib ] || mkdir -p /opt/trim/fnmusic/lib
        cp /opt/trim/fnmusic/trim.music/lib/libzmq.so.5 /opt/trim/fnmusic/lib/ 2>/dev/null || true
        rm -f /tmp/trim.music.tar.gz
    fi

    # mediasrv: 转码核心 + 库
    if [ ! -f /opt/trim/mediasrv/bin/mediasrv ]; then
        log "下载 mediasrv 核心..."
        wget -q -O /tmp/trim-media-lib.zip "${base}/trim-media-lib.zip"
        wget -q -O /tmp/lib.extends.zip "${base}/lib.extends.zip"
        mkdir -p /opt/trim/mediasrv/{bin,lib,extends}
        cd /opt/trim/mediasrv
        unzip -qo /tmp/trim-media-lib.zip 2>/dev/null || true
        unzip -qo /tmp/lib.extends.zip 2>/dev/null || true
        rm -f /tmp/trim-media-lib.zip /tmp/lib.extends.zip
    fi

    touch /opt/trim/.downloads_done
    log "核心二进制就绪"
}

# ============================================================
# 等待 rpcbroker socket 就绪
# ============================================================
wait_for_rpcbroker() {
    local sock="/run/trim_app_cgi/rpcbroker"
    local i=0
    log "等待 rpcbroker..."
    while [ ! -S "$sock" ] && [ $i -lt 60 ]; do
        sleep 1
        i=$((i + 1))
    done
    [ -S "$sock" ] && log "rpcbroker 已就绪" || { log "ERROR: rpcbroker 超时"; exit 1; }
}

# ============================================================
# 环境准备
# ============================================================
mkdir -p "$MEDIA_DIR" /vol1 /var/apps \
         /run/trim_app_cgi /run/trim_app_cgi/rpcbroker

# 如果 MEDIA_DIR 不是默认路径，建立软链接适配核心的写死路径
if [ "$MEDIA_DIR" != "/vol1/1000" ]; then
    mkdir -p /vol1
    ln -sfn "$MEDIA_DIR" /vol1/1000
fi

# 首次运行下载
init_downloads

# ============================================================
# 按服务启动
# ============================================================
case "$SERVICE" in
  rpcbroker)
    log "启动 rpcbroker (MEDIA_DIR=$MEDIA_DIR)"
    export MEDIA_DIR
    exec /opt/trim/rpcbroker/rpcbroker.arm64
    ;;
  mediasrv)
    wait_for_rpcbroker
    log "启动 mediasrv"
    export LD_LIBRARY_PATH="/opt/trim/mediasrv/lib:/opt/trim/mediasrv/lib/mediasrv:/opt/trim/mediasrv/lib/mediasrv/lib:/opt/trim/mediasrv/extends:${LD_LIBRARY_PATH:-}"
    export LD_PRELOAD="/opt/trim/mediasrv/nodri.so"
    mkdir -p /usr/trim/etc
    exec /opt/trim/mediasrv/mediasrv.arm64
    ;;
  fntv)
    wait_for_rpcbroker
    # 数据库初始化
    DB_DIR="/opt/trim/fntv/data/database"
    mkdir -p "$DB_DIR"
    if [ ! -f "$DB_DIR/trimmedia.db" ]; then
        log "初始化 fntv 数据库..."
        MEDIA_DIR_ESC=$(echo "$MEDIA_DIR" | sed 's/[&/\]/\\&/g')
        sed -e "s|/vol1/@appmeta/trim.media|${MEDIA_DIR_ESC}/@appmeta/trim.media|g" \
            -e "s|/vol1|${MEDIA_DIR_ESC}|g" \
            /opt/trim/fntv/init.sql | sqlite3 "$DB_DIR/trimmedia.db"
        log "fntv 数据库初始化完成"
    fi
    log "启动 fntv (端口 ${WEB_PORT:-8005})"
    export LD_LIBRARY_PATH="/opt/trim/fntv/lib:${LD_LIBRARY_PATH:-}"
    exec /opt/trim/fntv/fntv.arm64 \
        --port "${WEB_PORT:-8005}" \
        --static /opt/trim/fntv/trim.media \
        --root /opt/trim/fntv/trim.media \
        --meta "$MEDIA_DIR/@appmeta/trim.media"
    ;;
  fnmusic)
    wait_for_rpcbroker
    # 建立软链接（trim-music 路径写死在 /var/apps/trim.music）
    ln -sfn /opt/trim/fnmusic/trim.music /var/apps/trim.music
    mkdir -p /var/apps/trim.music/var/db

    # 等待 trim-music 自己建库完成后再播种
    (
        local db="/var/apps/trim.music/var/db/music.db"
        local i=0
        while [ $i -lt 120 ]; do
            if [ -f "$db" ]; then
                local state
                state=$(sqlite3 "$db" "SELECT value FROM app_state WHERE key='initialized'" 2>/dev/null || echo "")
                if [ -z "$state" ]; then
                    log "播种 fnmusic 初始数据..."
                    sqlite3 "$db" < /opt/trim/fnmusic/init_data.sql 2>/dev/null && break
                else
                    break
                fi
            fi
            sleep 1
            i=$((i + 1))
        done
    ) &

    export LD_LIBRARY_PATH="/opt/trim/fnmusic/lib:${LD_LIBRARY_PATH:-}"
    log "启动 fnmusic (端口 ${WEB_PORT:-8007})"
    # 启动器内含 HTTP 反代，直接监听 WEB_PORT
    exec /opt/trim/fnmusic/fnmusic.arm64
    ;;
  *)
    log "未知服务: $SERVICE"
    exit 1
    ;;
esac