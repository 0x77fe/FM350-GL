#!/bin/sh
# 构建 luci-app-fm350 的 ipk（ImmortalWrt / OpenWrt 24.10 及以前 · opkg 体系）
# 用法: sh build/build-ipk.sh
# 产物: dist/luci-app-fm350_<版本>-r<release>_all.ipk
#
# 环境变量：
#   FM350_SDK_DIR     已解压好的 SDK 根目录，给了就直接用它编译（跳过下载与解压）
#   FM350_SDK_FLAVOR  immortalwrt | openwrt        默认 immortalwrt
#   FM350_SDK_VER     版本号                       默认 24.10.6（immortalwrt）/ 24.10.5（openwrt）
#   FM350_WORK        工作根（缓存 + 解压的 SDK）  默认 $HOME/fm350
#   FM350_SDK_BASE    SDK 下载基址
#
# 在 Windows/Git Bash 上传到构建机：打 tar（排除 .tmp/.git/dist）后 scp，再解包执行本脚本。
#
# 说明：本包 PKGARCH:=all，与目标架构无关，包内文件与 apk 侧逐字节相同；SDK 只 include
# rules.mk + package.mk，不依赖 luci feed。容器入口（build/build.sh）只准备宿主依赖，
# 构建流程仍走本脚本。公共流程见 build/common.sh。
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLAVOR="${FM350_SDK_FLAVOR:-immortalwrt}"
case "$FLAVOR" in
	immortalwrt) VER="${FM350_SDK_VER:-24.10.6}" ;;
	openwrt) VER="${FM350_SDK_VER:-24.10.5}" ;;
	*) echo "未知 FM350_SDK_FLAVOR: $FLAVOR（应为 openwrt 或 immortalwrt）"; exit 1 ;;
esac
FM350_FORMAT=ipk
export FM350_FORMAT

. "$ROOT/build/common.sh"

sdk_ensure
pkg_build
pkg_collect
