#!/bin/sh
# Docker 入口：只在容器里准备构建环境（glibc 宿主依赖，SDK 自带的 fakeroot 需要 glibc，
# 所以容器用 debian 而不是 alpine），构建流程本身由 build/build-ipk.sh 负责。
# 用法: sh build/build.sh   （需要本机有 docker；工程目录会被只读挂载）
# 环境变量：
#   FM350_CACHE      容器缓存目录（SDK 与日志）   默认 /var/lib/docker/fm350-cache
#   FM350_SDK_VER    SDK / 固件版本               默认 24.10.6
#   FM350_SDK_BASE   SDK 镜像基址                 默认按 build/common.sh 的 sdk_meta
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${FM350_CACHE:-/var/lib/docker/fm350-cache}"
SDK_VER="${FM350_SDK_VER:-24.10.6}"
SDK_BASE_ARG="${FM350_SDK_BASE:-}"
mkdir -p "$CACHE" "$ROOT/dist"

echo "== 项目根: $ROOT / 缓存: $CACHE / SDK 版本: $SDK_VER =="
docker run --rm \
	-e FM350_WORK=/cache \
	-e FM350_DIST=/dist \
	-e FM350_SDK_VER="$SDK_VER" \
	-e FM350_SDK_BASE="$SDK_BASE_ARG" \
	-v "$ROOT":/src:ro \
	-v "$ROOT/dist":/dist \
	-v "$CACHE":/cache \
	debian:bookworm-slim sh -c '
set -e

# CN 镜像优先，失败回退官方源
if ! sed -i "s|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g" /etc/apt/sources.list.d/debian.sources; then :; fi
if ! { apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
	wget curl zstd tar make gcc g++ gawk python3 perl gettext git rsync \
	findutils bash patch grep gzip bzip2 unzip coreutils file libncurses-dev \
	pkg-config xz-utils ca-certificates python3-distutils python3-setuptools >/dev/null 2>&1; }; then
	echo "--- 清华镜像安装失败, 回退官方源 ---"
	sed -i "s|mirrors.tuna.tsinghua.edu.cn|deb.debian.org|g" /etc/apt/sources.list.d/debian.sources
	apt-get update -qq >/dev/null 2>&1
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
		wget curl zstd tar make gcc g++ gawk python3 perl gettext git rsync \
		findutils bash patch grep gzip bzip2 unzip coreutils file libncurses-dev \
		pkg-config xz-utils ca-certificates python3-distutils python3-setuptools >/dev/null 2>&1
fi

# 环境就绪后走公共流程（SDK 落在 /cache，产物写 /dist）
sh /src/build/build-ipk.sh
'
