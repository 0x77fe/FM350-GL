#!/bin/sh
# 构建 luci-app-fm350 的 apk（OpenWrt / ImmortalWrt 25.12+ 的包格式是 apk，不再是 ipk）
# 用法: sh build/build-apk.sh
# 产物: dist/luci-app-fm350-<版本>-r<release>.apk
#
# 环境变量：
#   FM350_SDK_FLAVOR  immortalwrt | openwrt        默认 immortalwrt
#   FM350_SDK_VER     版本号                       默认 25.12.1（immortalwrt）/ 25.12.5（openwrt）
#   FM350_WORK        工作根（缓存 + 解压的 SDK）  默认 $HOME/fm350
#   FM350_SDK_DIR     已解压 SDK，给了就跳过下载与解压
#   FM350_SDK_BASE    SDK 镜像基址
#
# 在 Windows/Git Bash 上传到构建机：打 tar（排除 .tmp/.git/dist）后 scp，再解包执行本脚本。
#
# 说明：本包 PKGARCH:=all（apk 元数据 arch=noarch），与目标架构无关；SDK 里 package/ 只有
# Makefile/kernel/toolchain，但自带 base feed 元数据（luci-base / rpcd 已在 .config 中），
# 无需 scripts/feeds update 即可编译。公共流程见 build/common.sh。
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLAVOR="${FM350_SDK_FLAVOR:-immortalwrt}"
case "$FLAVOR" in
	immortalwrt) VER="${FM350_SDK_VER:-25.12.1}" ;;
	openwrt) VER="${FM350_SDK_VER:-25.12.5}" ;;
	*) echo "未知 FM350_SDK_FLAVOR: $FLAVOR（应为 openwrt 或 immortalwrt）"; exit 1 ;;
esac
FM350_FORMAT=apk
export FM350_FORMAT

. "$ROOT/build/common.sh"

sdk_ensure
pkg_build
pkg_collect
