#!/bin/sh
# 构建 luci-app-fm350 的 ipk（ImmortalWrt / OpenWrt 24.10 及以前 · opkg 体系）
#
# 在构建机（Linux · 无需 docker）上执行：
#     sh build/build-ipk.sh
# 产物：dist/luci-app-fm350_<版本>-r<release>_all.ipk
#
# 与 build/build.sh 的关系：两者都编 ipk —— build.sh 走 docker（任何有 docker 的机器都能跑，
# 容器里装 SDK 宿主依赖），本脚本直接跑 SDK，只要求构建机是 Linux 且 SDK 自带的
# fakeroot/mkhash 能运行（实测 Ubuntu 26.04 可行）。apk 侧同理见 build/build-apk.sh。
#
# 环境变量：
#   FM350_SDK_DIR     已解压好的 SDK 根目录     给了就直接用它编译（跳过下载与解压）
#   FM350_SDK_FLAVOR  immortalwrt | openwrt     默认 immortalwrt
#   FM350_SDK_VER     版本号                    默认 24.10.6（immortalwrt）/ 24.10.5（openwrt）
#   FM350_WORK        工作根（缓存 + 解压的 SDK）默认 $HOME/fm350
#   FM350_SDK_BASE    SDK 下载基址（镜像）      见下方 case
#
# 本机（Windows/Git Bash）投递方式：
#     tar -czf /tmp/fm350-src.tar.gz --exclude=./.tmp --exclude=./.git --exclude=./dist .
#     scp /tmp/fm350-src.tar.gz <user>@<build-host>:/tmp/
#     ssh <user>@<build-host> "rm -rf ~/fm350/src-ipk && mkdir -p ~/fm350/src-ipk && \
#         tar -xzf /tmp/fm350-src.tar.gz -C ~/fm350/src-ipk && cd ~/fm350/src-ipk && sh build/build-ipk.sh"
#
# 说明：
#   · 本包 PKGARCH:=all（与目标架构无关）：x86/64 SDK 编出的 ipk，aarch64 路由器同样能用；
#   · 包内文件与 apk 侧逐字节相同（29 个文件），差别只在包格式与包管理器：opkg 的 .ipk vs apk-tools 3 的 .apk；
#   · 本包 Makefile 只 include rules.mk + package.mk，不依赖 luci feed，
#     所以 SDK 无需 `scripts/feeds update` 即可直接编译；
#   · SDK 走 PKU 镜像（官方源在国内实测很慢），内置版本会校验 sha256。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${FM350_WORK:-$HOME/fm350}"
FLAVOR="${FM350_SDK_FLAVOR:-immortalwrt}"

case "$FLAVOR" in
	immortalwrt)
		VER="${FM350_SDK_VER:-24.10.6}"
		case "$VER" in
			24.10.6)
				SDK_FILE="immortalwrt-sdk-24.10.6-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst"
				SDK_SHA256="709bea2ce466b7ad671ce00fdcb1eb69b2b3fa0f0921b12b620725d95cd8c0e5"
				SDK_BASE="${FM350_SDK_BASE:-https://mirrors.pku.edu.cn/immortalwrt}"
				;;
			*) SDK_FILE=""; SDK_SHA256=""; SDK_BASE="${FM350_SDK_BASE:-https://downloads.immortalwrt.org}" ;;
		esac
		;;
	openwrt)
		VER="${FM350_SDK_VER:-24.10.5}"
		case "$VER" in
			24.10.5)
				SDK_FILE="openwrt-sdk-24.10.5-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst"
				SDK_SHA256=""
				SDK_BASE="${FM350_SDK_BASE:-https://downloads.openwrt.org}"
				;;
			*) SDK_FILE=""; SDK_SHA256=""; SDK_BASE="${FM350_SDK_BASE:-https://downloads.openwrt.org}" ;;
		esac
		;;
	*) echo "未知 FM350_SDK_FLAVOR: $FLAVOR（应为 openwrt 或 immortalwrt）"; exit 1 ;;
esac

SDK_DIR="${FM350_SDK_DIR:-$WORK/sdk-$FLAVOR-$VER}"
URL="$SDK_BASE/releases/$VER/targets/x86/64"
TAR="$WORK/cache/${SDK_FILE:-sdk-$VER.tar.zst}"
OUT="$WORK/out"

mkdir -p "$WORK/cache" "$OUT" "$ROOT/dist"

echo "== 项目根: $ROOT"
echo "== 发行版: $FLAVOR $VER / SDK 目录: $SDK_DIR"

# ---------------------------------------------------------------- 1. 备好 SDK
if [ -f "$SDK_DIR/include/package.mk" ]; then
	echo "== SDK 已就绪，跳过下载/解压 =="
else
	if [ -z "$SDK_FILE" ]; then
		echo "== 未内置 $VER 的 SDK 文件名，从目录页解析 =="
		SDK_FILE="$(wget -qO- "$URL/" | grep -oE "${FLAVOR}-sdk-${VER}-x86-64[^\"]*\.tar\.zst" | head -1)"
		[ -n "$SDK_FILE" ] || { echo "解析 SDK 文件名失败: $URL"; exit 1; }
		TAR="$WORK/cache/$SDK_FILE"
	fi

	if [ ! -s "$TAR" ]; then
		echo "== 下载 SDK（仅首次，约 500MB）: $URL/$SDK_FILE =="
		curl -fL --retry 3 --retry-delay 3 -o "$TAR.part" "$URL/$SDK_FILE"
		mv -f "$TAR.part" "$TAR"
	fi

	if [ -n "$SDK_SHA256" ]; then
		echo "== 校验 SDK sha256 =="
		echo "$SDK_SHA256  $TAR" | sha256sum -c -
	fi

	echo "== 解压 SDK（约 1.5~3GB，仅首次）=="
	rm -rf "$SDK_DIR"
	mkdir -p "$SDK_DIR"
	tar --zstd -xf "$TAR" -C "$SDK_DIR" --strip-components=1
fi

[ -f "$SDK_DIR/include/package.mk" ] || { echo "SDK 目录不完整（缺 include/package.mk）: $SDK_DIR"; exit 1; }

# ---------------------------------------------------------------- 2. 编译
echo "== 拷入包源码 =="
rm -rf "$SDK_DIR/package/luci-app-fm350"
cp -r "$ROOT/luci-app-fm350" "$SDK_DIR/package/luci-app-fm350"

cd "$SDK_DIR"
[ -f .config ] || { echo "== 生成 .config (defconfig) =="; make defconfig > "$OUT/defconfig.log" 2>&1 || { tail -20 "$OUT/defconfig.log"; exit 1; }; }

LOG="$OUT/build-ipk-$FLAVOR-$VER.log"
echo "== 编译（日志: $LOG）=="
if make package/luci-app-fm350/compile V=s > "$LOG" 2>&1; then
	tail -3 "$LOG"
else
	echo "== 编译失败，日志尾部 =="
	tail -60 "$LOG"
	exit 1
fi

# ---------------------------------------------------------------- 3. 取产物
IPK="$(find "$SDK_DIR/bin/packages" -name 'luci-app-fm350*.ipk' | head -1)"
[ -n "$IPK" ] || { echo "ipk 未生成"; exit 1; }
cp -f "$IPK" "$ROOT/dist/"
echo "== 成功: dist/$(basename "$IPK") =="
ls -l "$ROOT/dist/$(basename "$IPK")"
sha256sum "$ROOT/dist/$(basename "$IPK")"
