# trimmedia Docker Compose 使用指南

## 前提条件

- ARM64 设备（树莓派 4/5、RK3588、Apple Silicon Mac、斐讯 N1 等）
- Docker + Docker Compose v2
- Git

## 方式一：GitHub Actions 云端构建（推荐）

无需本地安装 Docker，push 代码后自动构建 ARM64 镜像推到 GHCR。

### 1. Fork 或克隆仓库，将本目录的文件放入项目根目录

```
trimmedia-linux-arm/
├── .github/workflows/docker-build.yml   ← 新增
├── Dockerfile                            ← 新增
├── docker-compose.yml                    ← 新增
├── docker-entrypoint.sh                  ← 新增
├── .env                                  ← 新增
├── apps/
│   ├── rpcbroker/
│   ├── mediasrv/
│   ├── fntv/
│   └── fnmusic/
├── nodri.c
└── Makefile
```

### 2. 触发构建

```bash
# 方式 A：push 到 main 分支自动构建
git add -A && git commit -m "add docker support" && git push

# 方式 B：打 tag 触发构建（推荐，会生成版本标签）
git tag v1.0.0 && git push origin v1.0.0

# 方式 C：手动触发（在 GitHub 仓库 Actions 页面点 "Run workflow"）
```

### 3. 在目标 ARM64 设备上拉取并运行

```bash
# 登录 GHCR（首次需要）
echo <你的GitHub PAT> | docker login ghcr.io -u <用户名> --password-stdin

# 拉取镜像
docker pull ghcr.io/<你的用户名>/trimmedia-linux-arm:main

# 或者用 tag 版本
docker pull ghcr.io/<你的用户名>/trimmedia-linux-arm:1.0.0

# 用 docker compose 启动（修改 docker-compose.yml 中的 image 指向你的镜像）
docker compose up -d
```

### 4. 修改 docker-compose.yml 使用远程镜像

把每个 service 的 `build` 块替换为 `image`：

```yaml
services:
  rpcbroker:
    image: ghcr.io/<你的用户名>/trimmedia-linux-arm:main
    # 删除 build 块
    ...
```

---

## 方式二：本地构建

在 ARM64 设备上直接构建（需要安装 Docker）：

```bash
# 1. 克隆项目
git clone https://github.com/kesry/trimmedia-linux-arm.git
cd trimmedia-linux-arm

# 2. 把本目录的 Docker 相关文件复制到项目根目录
cp -r trimmedia-docker/* .

# 3. 构建镜像（首次需要，约 2-3 分钟）
docker compose build

# 4. 启动全部服务
docker compose up -d

# 5. 访问
#    飞牛影视: http://<设备IP>:8005
#    飞牛音乐: http://<设备IP>:8007
#    账号: admin  密码: 123456
```

> 如果是 x86 机器想交叉构建 ARM64 镜像：
> ```bash
> docker buildx build --platform linux/arm64 -t trimmedia:latest --load .
> ```
> 需要先 `docker run --privileged --rm tonistiigi/binfmt --install arm64` 安装 QEMU 模拟器。

## 自定义配置

编辑 `.env` 文件：

```bash
# 媒体目录（把你的视频/音乐文件放进去）
MEDIA_DIR=/vol1/1000

# 修改对外端口
FNTV_PORT=8005
FNMUSIC_PORT=8007

# 国内 GitHub 加速（可选）
PROXY_PREFIX=https://ghfast.top/
```

## 挂载本地媒体文件

在 `docker-compose.yml` 的 `volumes` 部分，把 `media-data` 改为 bind mount：

```yaml
volumes:
  - /path/to/your/media:/media   # 替换为你的实际路径
```

然后在 `.env` 中设置 `MEDIA_DIR=/media`。

## 常用命令

```bash
# 查看日志
docker compose logs -f              # 全部
docker compose logs -f fntv         # 某个服务

# 重启单个服务
docker compose restart fntv

# 停止全部
docker compose down

# 停止并删除数据卷（⚠️ 会清除数据库）
docker compose down -v

# 重新构建（代码更新后）
docker compose build --no-cache
docker compose up -d
```

## 服务依赖关系

```
rpcbroker (健康检查: socket 就绪)
    ├── mediasrv   (转码服务)
    ├── fntv       (影视 :8005)
    └── fnmusic    (音乐 :8007)
```

`rpcbroker` 有健康检查，其他三个服务会等它就绪后才启动。

## 首次启动说明

首次 `docker compose up` 时，容器会自动从 GitHub 下载核心二进制（约 200-300MB），耗时取决于网络速度。下载完成后会创建标记文件，后续启动不再重复下载。

如果下载慢，在 `.env` 里设置 `PROXY_PREFIX`。

## 故障排查

| 问题 | 排查 |
|---|---|
| fntv/fnmusic 启动后页面报错 | 检查 rpcbroker 是否正常：`docker compose logs rpcbroker` |
| mediasrv 启动即退出 | 容器内无 `/dev/dri`，entrypoint 已自动设置 `LD_PRELOAD=nodri.so`，正常情况不会退出 |
| fnmusic panic: unable to open database file | 删除 fnmusic 数据卷让它重建：`docker compose down -v && docker compose up -d fnmusic` |
| 首次下载超时 | 设置 `PROXY_PREFIX` 或手动下载 release 包挂载进容器 |