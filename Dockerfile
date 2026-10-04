# ============================================================
# trimmedia-linux-arm Dockerfile
# 构建镜像时编译 Go 启动器 + nodri.so，首次启动时下载核心二进制
# 目标平台: linux/arm64
# ============================================================

# ---- Stage 1: 编译 Go 启动器 + nodri.so ----
# 使用 $BUILDPLATFORM 让 builder 在构建机（x86）上原生运行，
# 通过 GOARCH=arm64 交叉编译，比 QEMU 模拟快 10 倍以上
FROM --platform=$BUILDPLATFORM golang:1.24-bookworm AS builder

ARG TARGETARCH

WORKDIR /src
COPY . .

# 安装交叉编译工具链（Go CGO + nodri.so）
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu libc6-dev-arm64-cross && \
    rm -rf /var/lib/apt/lists/*

# 设置交叉编译环境
ENV CGO_ENABLED=1
ENV GOOS=linux
ENV GOARCH=${TARGETARCH}
ENV CC=aarch64-linux-gnu-gcc

# 逐个编译，方便定位哪个包出错
RUN echo "=== Building rpcbroker ===" && \
    go build -v -trimpath -ldflags="-s -w" -o /build/rpcbroker.arm64 ./apps/rpcbroker && \
    echo "=== Building mediasrv ===" && \
    go build -v -trimpath -ldflags="-s -w" -o /build/mediasrv.arm64 ./apps/mediasrv && \
    echo "=== Building fntv ===" && \
    go build -v -trimpath -ldflags="-s -w" -o /build/fntv.arm64 ./apps/fntv && \
    echo "=== Building fnmusic ===" && \
    go build -v -trimpath -ldflags="-s -w" -o /build/fnmusic.arm64 ./apps/fnmusic

# 用 ARM64 交叉编译器编译 nodri.so 打桩库
RUN aarch64-linux-gnu-gcc -shared -fPIC -o /build/nodri.so /src/nodri.c

# ---- Stage 2: 运行时镜像 ----
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV MEDIA_DIR=/vol1/1000
ENV FNTV_PORT=8005
ENV FNMUSIC_PORT=8007
ENV PROXY_PREFIX=

# 安装运行时依赖
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        sqlite3 wget ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# 创建目录结构
RUN mkdir -p /opt/trim/{rpcbroker,mediasrv,fntv,fnmusic} \
             /var/apps /vol1 /media \
             /run/trim_app_cgi /run/trim_app_cgi/rpcbroker

# 从 builder 拷贝编译产物
COPY --from=builder /build/rpcbroker.arm64  /opt/trim/rpcbroker/
COPY --from=builder /build/mediasrv.arm64   /opt/trim/mediasrv/
COPY --from=builder /build/fntv.arm64       /opt/trim/fntv/
COPY --from=builder /build/fnmusic.arm64    /opt/trim/fnmusic/
COPY --from=builder /build/nodri.so         /opt/trim/mediasrv/

# 拷贝启动器所需的源文件（SQL、安装脚本、内置库）
COPY apps/rpcbroker/rpcbroker.go    /opt/trim/rpcbroker/
COPY apps/mediasrv/mediasrv.go      /opt/trim/mediasrv/
COPY apps/fntv/fntv.go              /opt/trim/fntv/
COPY apps/fntv/init.sql             /opt/trim/fntv/
COPY apps/fntv/lib/                 /opt/trim/fntv/lib/
COPY apps/fnmusic/fnmusic.go        /opt/trim/fnmusic/
COPY apps/fnmusic/init_data.sql     /opt/trim/fnmusic/
COPY apps/fnmusic/lib/              /opt/trim/fnmusic/lib/
COPY apps/fnmusic/mobile_api.go     /opt/trim/fnmusic/
COPY apps/fnmusic/proxy.go          /opt/trim/fnmusic/

# 拷贝入口脚本
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# 暴露端口（fntv 和 fnmusic 通过 compose 的 ports 映射，此处仅文档用途）
EXPOSE 8005 8007

VOLUME ["/vol1", "/media", "/run"]

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["rpcbroker"]
