#!/bin/sh
# 构建 luci-app-fm350 的 apk（OpenWrt / ImmortalWrt 25.12+ 的包格式是 apk，不再是 ipk）
#
# 在构建机（<user>@<build-host> · Ubuntu 26.04 · 无 docker）上执行：
#     sh build/build-apk.sh
# 产物：dist/luci-app-fm350-<版本>-r<release>.apk
#
# 目标固件与 SDK 的对应关系（用哪个 SDK 编，取决于固件是哪个发行版）：
#     FM350_SDK_FLAVOR=immortalwrt  （默认）ImmortalWrt —— 本项目目标固件，测试机 <test-host-2512> 是 25.12.1
#     FM350_SDK_FLAVOR=openwrt      官方 OpenWrt
#
# 环境变量：
#     FM350_SDK_FLAVOR  immortalwrt | openwrt        默认 immortalwrt
#     FM350_SDK_VER     版本号                       默认 25.12.1（immortalwrt）/ 25.12.5（openwrt）
#     FM350_WORK        工作根（缓存 + 解压的 SDK）  默认 $HOME/fm350
#     FM350_SDK_BASE    SDK 下载基址（镜像）         见下方 case
#
# 本机（Windows/Git Bash）投递方式：
#     tar -czf /tmp/fm350-src.tar.gz --exclude=./.tmp --exclude=./.git --exclude=./dist .
#     scp /tmp/fm350-src.tar.gz <user>@<build-host>:/tmp/
#     ssh <user>@<build-host> "rm -rf ~/fm350/src && mkdir -p ~/fm350/src && \
#         tar -xzf /tmp/fm350-src.tar.gz -C ~/fm350/src && cd ~/fm350/src && sh build/build-apk.sh"
#
# 说明：
#   · 本包 PKGARCH:=all（apk 元数据 arch=noarch），与目标架构无关：
#     x86/64 的 SDK 编出的包，aarch64 路由器同样能用；
#   · SDK 里 package/ 只有 Makefile/kernel/toolchain，但自带 base feed 元数据
#     （luci-base / rpcd 已在 .config 中），无需 scripts/feeds update 即可编译；
#   · 不依赖 docker（旧的 build/build.sh 走 docker + ImmortalWrt SDK 24.10 出 ipk，互不影响）；
#   · downloads.immortalwrt.org 在国内实测只有 ~7KB/s（590MB 下不动），
#     immortalwrt 分支默认走 PKU 官方镜像（实测 18MB/s），并校验收到的 sha256。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${FM350_WORK:-$HOME/fm350}"
FLAVOR="${FM350_SDK_FLAVOR:-immortalwrt}"

case "$FLAVOR" in
	immortalwrt)
		VER="${FM350_SDK_VER:-25.12.1}"
		case "$VER" in
			25.12.1)
				SDK_FILE="immortalwrt-sdk-25.12.1-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
				SDK_SHA256="02ad8cfc775001ccae8e9282d19696de54e3ab3963f005737ad61f8698263edd"
				SDK_BASE="${FM350_SDK_BASE:-https://mirrors.pku.edu.cn/immortalwrt}"
				;;
			*) SDK_FILE=""; SDK_SHA256=""; SDK_BASE="${FM350_SDK_BASE:-https://downloads.immortalwrt.org}" ;;
		esac
		;;
	openwrt)
		VER="${FM350_SDK_VER:-25.12.5}"
		case "$VER" in
			25.12.5)
				SDK_FILE="openwrt-sdk-25.12.5-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst"
				SDK_SHA256="0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c"
				SDK_BASE="${FM350_SDK_BASE:-https://downloads.openwrt.org}"
				;;
			*) SDK_FILE=""; SDK_SHA256=""; SDK_BASE="${FM350_SDK_BASE:-https://downloads.openwrt.org}" ;;
		esac
		;;
	*) echo "未知 FM350_SDK_FLAVOR: $FLAVOR（应为 openwrt 或 immortalwrt）"; exit 1 ;;
esac

SDK_DIR="$WORK/sdk-$FLAVOR-$VER"
URL="$SDK_BASE/releases/$VER/targets/x86/64"
TAR="$WORK/cache/${SDK_FILE:-sdk-$VER.tar.zst}"
OUT="$WORK/out"

mkdir -p "$WORK/cache" "$OUT" "$ROOT/dist"

echo "== 项目根: $ROOT"
echo "== 发行版: $FLAVOR $VER / SDK 目录: $SDK_DIR"

# ---------------------------------------------------------------- 1. 取 SDK
if [ -z "$SDK_FILE" ]; then
	echo "== 未内置 $VER 的 SDK 文件名，从目录页解析 =="
	SDK_FILE="$(wget -qO- "$URL/" | grep -oE "${FLAVOR}-sdk-${VER}-x86-64[^\"]*\.tar\.zst" | head -1)"
	[ -n "$SDK_FILE" ] || { echo "解析 SDK 文件名失败: $URL"; exit 1; }
	TAR="$WORK/cache/$SDK_FILE"
fi

if [ ! -s "$TAR" ]; then
	echo "== 下载 SDK（仅首次）: $URL/$SDK_FILE =="
	curl -fL --retry 3 --retry-delay 3 -o "$TAR.part" "$URL/$SDK_FILE"
	mv -f "$TAR.part" "$TAR"
fi

if [ -n "$SDK_SHA256" ]; then
	echo "== 校验 SDK sha256 =="
	echo "$SDK_SHA256  $TAR" | sha256sum -c -
fi

if [ ! -d "$SDK_DIR" ]; then
	echo "== 解压 SDK（约 1.5~4GB，仅首次）=="
	mkdir -p "$SDK_DIR"
	tar --zstd -xf "$TAR" -C "$SDK_DIR" --strip-components=1
fi

# ---------------------------------------------------------------- 2. 编译
echo "== 拷入包源码 =="
rm -rf "$SDK_DIR/package/luci-app-fm350"
cp -r "$ROOT/luci-app-fm350" "$SDK_DIR/package/luci-app-fm350"

cd "$SDK_DIR"
[ -f .config ] || { echo "== 生成 .config (defconfig) =="; make defconfig > "$OUT/defconfig.log" 2>&1 || { tail -20 "$OUT/defconfig.log"; exit 1; }; }

LOG="$OUT/build-$FLAVOR-$VER.log"
echo "== 编译（日志: $LOG）=="
if make package/luci-app-fm350/compile V=s > "$LOG" 2>&1; then
	tail -3 "$LOG"
else
	echo "== 编译失败，日志尾部 =="
	tail -60 "$LOG"
	exit 1
fi

# ---------------------------------------------------------------- 3. 取产物
APK="$(find "$SDK_DIR/bin/packages" -name 'luci-app-fm350-*.apk' | head -1)"
[ -n "$APK" ] || { echo "apk 未生成"; exit 1; }
cp -f "$APK" "$ROOT/dist/"
echo "== 成功: dist/$(basename "$APK") =="
ls -l "$ROOT/dist/$(basename "$APK")"
sha256sum "$ROOT/dist/$(basename "$APK")"
