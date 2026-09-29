#!/bin/sh
# 生成 / 刷新 dist/deps-apk/ 的离线依赖包（apk 体系：OpenWrt / ImmortalWrt 25.12.x）
#
# 在构建机上执行：sh build/fetch-deps-apk.sh
# 产物：dist/deps-apk/*.apk + SHA256SUMS（install_all.sh 与 README.md 是仓库里的固定文件，不动）
#
# 环境变量：
#   FM350_VER        固件版本           默认 25.12.1
#   FM350_ABI        kmods ABI 目录名   默认 6.12.94-1-0413601b1c3f0490e17f340fe09229ea
#                    （留空 = 自动从 kmods 目录页里挑唯一一个 ABI）
#   FM350_MIRROR     主源（列表 + 文件）默认 https://mirror.nju.edu.cn/immortalwrt
#   FM350_LIST_MIRROR 备用源            默认 https://downloads.immortalwrt.org
#
# 镜像实测（2026-09，别再重复踩）：
#   · mirror.nju.edu.cn        346KB/s，kmods 列表 1199 条、packages 列表 4700 条（a→z 全，含 jq/sms-tool）→ 用它
#   · mirrors.ustc.edu.cn      290KB/s，但**目录列表不全**（kmods 997 条，缺 kmod-usb-common / kmod-usb-wdm，
#                              packages 只列前 1000 条 jq 在截断之外）——文件本身存在，只有列表缺
#   · mirrors.pku.edu.cn       18MB/s，但目录页是 JS 空壳（597 字节），列不出文件名
#   · downloads.immortalwrt.org 官方源，列表全但国内 ~5KB/s，且这台机器上 wget 打它会卡死（curl 正常）
#   → 所以统一用 curl；文件名靠列表解析（兼容相对/绝对 href），文件优先主源、失败回落到备用源。
#
# 为什么需要它：kmod 与固件内核 ABI 强绑定（apk 会拒绝装错版本的 kmod），
# 换固件版本（或换发行版）必须重新抓一套；本脚本把「抓哪些、从哪抓、怎么核对」固化下来。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER="${FM350_VER:-25.12.1}"
MIRROR="${FM350_MIRROR:-https://mirror.nju.edu.cn/immortalwrt}"
LIST_MIRROR="${FM350_LIST_MIRROR:-https://downloads.immortalwrt.org}"
ABI="${FM350_ABI:-6.12.94-1-0413601b1c3f0490e17f340fe09229ea}"
DEST="$ROOT/dist/deps-apk"
TMP="$DEST/.fetch-tmp"

# USB 主机控制器 + 数据面(RNDIS/ECM) + 串口(AT) + 依赖
# kmod-nls-base 是 kmod-usb-core 的依赖，漏了整条 USB 链路装不上
KMODS="kmod-usb-core kmod-usb-common kmod-nls-base
kmod-usb2 kmod-usb3 kmod-usb-xhci-hcd kmod-usb-ehci kmod-usb-ohci
kmod-usb-net kmod-usb-net-cdc-ether kmod-usb-net-rndis
kmod-usb-serial kmod-usb-serial-wwan kmod-usb-acm kmod-usb-wdm
kmod-mii kmod-libphy"
PKGS="jq sms-tool"

mkdir -p "$DEST" "$TMP"
rm -f "$TMP"/*.apk "$TMP"/*.html

# 从目录列表页解析包名对应的确切文件名（路径部分可缺省：兼容 href="x.apk" 与 href="/m/…/x.apk"）
list_file() { # $1=列表文件 $2=包名
	grep -oE "href=\"([^\"]*/)?${2}-[0-9][^\"]*\.apk\"" "$1" 2>/dev/null \
		| sed -e 's/^href="//' -e 's/"$//' -e 's|.*/||' | sort -u | head -1
}
grab() { # $1=主源目录URL $2=备用目录URL $3=文件名
	if curl -fsSL --max-time 300 -o "$TMP/$3" "$1/$3" 2>/dev/null && [ -s "$TMP/$3" ]; then
		return 0
	fi
	[ -n "$2" ] || return 1
	curl -fsSL --max-time 300 -o "$TMP/$3" "$2/$3" 2>/dev/null && [ -s "$TMP/$3" ]
}

if [ -z "$ABI" ]; then
	echo "== 自动探测 kmods ABI =="
	curl -fsSL --max-time 180 -o "$TMP/kmods-idx.html" "$MIRROR/releases/$VER/targets/x86/64/kmods/" || { echo "取不到 kmods 目录页"; exit 1; }
	ABI="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-[0-9a-f]{16,}' "$TMP/kmods-idx.html" | sort -u | head -1)"
	[ -n "$ABI" ] || { echo "探测失败，请显式指定 FM350_ABI"; exit 1; }
fi

KURL="$MIRROR/releases/$VER/targets/x86/64/kmods/$ABI"
KFALL="$LIST_MIRROR/releases/$VER/targets/x86/64/kmods/$ABI"
PURL="$MIRROR/releases/$VER/packages/x86_64/packages"
PFALL="$LIST_MIRROR/releases/$VER/packages/x86_64/packages"
echo "== 版本: $VER / ABI: $ABI"
echo "   主源: $MIRROR"
echo "   备用: $LIST_MIRROR"

fetch_list() { # $1=URL $2=输出
	[ -s "$2" ] || curl -fsSL --max-time 300 -o "$2" "$1" 2>/dev/null || true
}

fail=0
echo "== kmods =="
fetch_list "$KURL/" "$TMP/klist.html"
[ -s "$TMP/klist.html" ] || { echo "  !! 取不到 kmods 列表 $KURL/"; exit 1; }
for p in $KMODS; do
	f="$(list_file "$TMP/klist.html" "$p")"
	if [ -z "$f" ]; then
		fetch_list "$KFALL/" "$TMP/klist-fall.html"
		f="$(list_file "$TMP/klist-fall.html" "$p")"
	fi
	[ -n "$f" ] || { echo "  !! 两个源的列表里都没有 $p"; fail=$((fail+1)); continue; }
	grab "$KURL" "$KFALL" "$f" || { echo "  !! 下载失败 $f"; fail=$((fail+1)); continue; }
	printf '  %-40s %s\n' "$f" "$(stat -c%s "$TMP/$f")"
done

echo "== jq / sms-tool =="
fetch_list "$PURL/" "$TMP/plist.html"
for p in $PKGS; do
	f="$(list_file "$TMP/plist.html" "$p")"
	if [ -z "$f" ]; then
		fetch_list "$PFALL/" "$TMP/plist-fall.html"
		f="$(list_file "$TMP/plist-fall.html" "$p")"
	fi
	[ -n "$f" ] || { echo "  !! 两个源的列表里都没有 $p"; fail=$((fail+1)); continue; }
	grab "$PURL" "$PFALL" "$f" || { echo "  !! 下载失败 $f"; fail=$((fail+1)); continue; }
	printf '  %-40s %s\n' "$f" "$(stat -c%s "$TMP/$f")"
done

[ "$fail" -eq 0 ] || { echo "!! 有 $fail 个包没抓到，保持原目录不变（检查 FM350_VER / FM350_ABI / FM350_MIRROR）"; exit 1; }

echo "== 主包（来自 dist/，由 build-apk.sh 产出）=="
APP="$(ls -1 "$ROOT"/dist/luci-app-fm350-*.apk 2>/dev/null | head -1)"
[ -n "$APP" ] || { echo "缺少 dist/luci-app-fm350-*.apk，先跑 build/build-apk.sh"; exit 1; }
cp -f "$APP" "$TMP/"
echo "  $(basename "$APP")"

echo "== 落到 $DEST 并写 SHA256SUMS =="
rm -f "$DEST"/*.apk
cp -f "$TMP"/*.apk "$DEST"/
rm -rf "$TMP"
cd "$DEST"
sha256sum ./*.apk > SHA256SUMS
echo "  共 $(wc -l < SHA256SUMS) 个包 / $(du -sh "$DEST" | cut -f1)"
