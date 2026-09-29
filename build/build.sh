#!/bin/sh
# 在开发服务器(<test-host-2410>)上执行：docker 内用 ImmortalWrt SDK 构建 IPK
# 用法: sh build/build.sh   （需将本工程上传到服务器任意目录）
# 注意: SDK 宿主依赖需 glibc（预编译 fakeroot），容器必须用 debian 而非 alpine
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
CACHE="${FM350_CACHE:-/var/lib/docker/fm350-cache}"
mkdir -p "$CACHE" "$ROOT/dist"

echo "== 项目根: $ROOT / 缓存: $CACHE =="
docker run --rm \
	-v "$ROOT":/src:ro \
	-v "$ROOT/dist":/dist \
	-v "$CACHE":/cache \
	debian:bookworm-slim sh -c '
set -e

# CN 镜像优先，失败回退官方源
if ! sed -i "s|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g" /etc/apt/sources.list.d/debian.sources; then :; fi
apt-get update -qq >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
	wget zstd tar make gcc g++ gawk python3 perl gettext git rsync \
	findutils bash patch grep gzip bzip2 unzip coreutils file libncurses-dev \
	pkg-config xz-utils ca-certificates python3-distutils python3-setuptools >/dev/null 2>&1 || {
	echo "--- 清华镜像安装失败, 回退官方源 ---"
	sed -i "s|mirrors.tuna.tsinghua.edu.cn|deb.debian.org|g" /etc/apt/sources.list.d/debian.sources
	apt-get update -qq >/dev/null 2>&1
	DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
		wget zstd tar make gcc g++ gawk python3 perl gettext git rsync \
		findutils bash patch grep gzip bzip2 unzip coreutils file libncurses-dev \
		pkg-config xz-utils ca-certificates python3-distutils python3-setuptools >/dev/null 2>&1
}

SDK_VER=24.10.6
SDK_URL=https://downloads.immortalwrt.org/releases/$SDK_VER/targets/x86/64
SDK_NAME=immortalwrt-sdk-${SDK_VER}-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst
SDIR=/cache/sdk

if [ ! -d "$SDIR" ]; then
	echo "== 下载 SDK (约500MB压缩, 仅首次) =="
	[ -f /cache/sdk.tar.zst ] || {
		wget -q -O /cache/sdk.tar.zst $SDK_URL/$SDK_NAME || {
			F=$(wget -qO- $SDK_URL | grep -oE "immortalwrt-sdk-${SDK_VER}-x86-64[^\"]*\\.tar\\.zst" | head -1)
			[ -n "$F" ] || { echo "SDK 下载失败（文件名可能变化，请更新 build.sh 中的 SDK_NAME）"; exit 1; }
			wget -q -O /cache/sdk.tar.zst $SDK_URL/$F
		}
	}
	echo "== 解压 SDK =="
	mkdir -p $SDIR
	tar --zstd -xf /cache/sdk.tar.zst -C $SDIR --strip-components=1
fi

echo "== 拷入包源码 =="
[ -d $SDIR/package/luci-app-fm350 ] && mv $SDIR/package/luci-app-fm350 /cache/trash-pkg-$(date +%s)-$$
cp -r /src/luci-app-fm350 $SDIR/package/luci-app-fm350

echo "== 编译 =="
cd $SDIR
[ -f .config ] || { echo "== 生成 .config (defconfig) =="; make defconfig > /cache/defconfig.log 2>&1 || tail -20 /cache/defconfig.log; }
if make package/luci-app-fm350/compile V=s > /cache/build.log 2>&1; then
	tail -15 /cache/build.log
else
	echo "== 编译失败, 日志尾部: =="
	tail -60 /cache/build.log
	exit 1
fi

IPK=$(find $SDIR/bin -name "luci-app-fm350*.ipk" | head -1)
[ -n "$IPK" ] || { echo "ipk 未生成"; exit 1; }
cp "$IPK" /dist/
echo "== 成功: dist/$(basename "$IPK") =="
'
