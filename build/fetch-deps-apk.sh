#!/bin/sh
# 生成 / 刷新 dist/deps-apk/ 的离线依赖包（apk 体系：OpenWrt / ImmortalWrt 25.12.x）
#
# 在构建机上执行：sh build/fetch-deps-apk.sh
# 产物：dist/deps-apk/*.apk + SHA256SUMS（install_all.sh 与 README.md 是仓库里的固定文件，不动）
#
# 环境变量：
#   FM350_VER        固件版本           默认读 dist/deps-apk/META
#   FM350_ABI        kmods ABI 目录名   默认读 META；显式留空（FM350_ABI=）则自动探测，
#                    探测到多个候选时列出并失败，不擅自取第一个
#   FM350_MIRROR     主源（列表 + 文件）默认 https://mirror.nju.edu.cn/immortalwrt
#   FM350_LIST_MIRROR 备用源            默认 https://downloads.immortalwrt.org
#
# 镜像选择（2026-09 实测，不必重复踩坑）：只有 mirror.nju.edu.cn 的目录列表完整，
# 用于取包名与文件名；其它镜像列表会截断或目录页是 JS 空壳，只作文件回落后备。
# 统一用 curl；文件名靠列表解析（兼容相对/绝对 href），文件优先主源、失败回落到备用源。
#
# 为什么需要它：kmod 与固件内核 ABI 强绑定（apk 会拒绝装错版本的 kmod），
# 换固件版本（或换发行版）必须重新抓一套；本脚本把「抓哪些、从哪抓、怎么核对」固化下来。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/dist/deps-apk"
TMP="$DEST/.fetch-tmp"
META="$DEST/META"

# 版本 / 架构 / ABI 的唯一来源是 META，环境变量优先
meta() { [ -f "$META" ] && sed -n "s/^$1=//p" "$META" | head -1; }
VER="${FM350_VER:-$(meta FM350_VER)}"
TARGET="${FM350_TARGET:-$(meta FM350_TARGET)}"
PKGARCH="${FM350_PKGARCH:-$(meta FM350_PKGARCH)}"
[ -n "$VER" ] && [ -n "$TARGET" ] && [ -n "$PKGARCH" ] \
	|| { echo "缺少 $META 里的 FM350_VER / FM350_TARGET / FM350_PKGARCH"; exit 1; }
MIRROR="${FM350_MIRROR:-https://mirror.nju.edu.cn/immortalwrt}"
LIST_MIRROR="${FM350_LIST_MIRROR:-https://downloads.immortalwrt.org}"

# ABI：显式给出（含留空 = 自动探测）优先；否则用 META 里的值，版本不符时重新探测
if [ "${FM350_ABI+set}" = set ]; then
	ABI="$FM350_ABI"
else
	ABI="$(meta FM350_ABI)"
	[ "$(meta FM350_VER)" = "$VER" ] || ABI=""
fi

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
	curl -fsSL --max-time 180 -o "$TMP/kmods-idx.html" "$MIRROR/releases/$VER/targets/$TARGET/kmods/" || { echo "取不到 kmods 目录页"; exit 1; }
	cands="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-[0-9a-f]{16,}' "$TMP/kmods-idx.html" | sort -u)"
	n="$(printf '%s\n' "$cands" | grep -c .)"
	if [ "$n" -ne 1 ]; then
		echo "  !! 探测到 $n 个 ABI 候选，请用 FM350_ABI 显式指定："
		printf '%s\n' "$cands" | sed 's/^/     /'
		exit 1
	fi
	ABI="$cands"
	echo "  探测到 ABI: $ABI"
fi

KURL="$MIRROR/releases/$VER/targets/$TARGET/kmods/$ABI"
KFALL="$LIST_MIRROR/releases/$VER/targets/$TARGET/kmods/$ABI"
PURL="$MIRROR/releases/$VER/packages/$PKGARCH/packages"
PFALL="$LIST_MIRROR/releases/$VER/packages/$PKGARCH/packages"
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

echo "== 落到 $DEST 并写清单 =="
rm -f "$DEST"/*.apk
cp -f "$TMP"/*.apk "$DEST"/
rm -rf "$TMP"
cd "$DEST"
# 依赖清单只含第三方依赖：主包由 APP-SHA256SUMS 管理，混进 SHA256SUMS 会让安装器把它当依赖
for f in *.apk; do
	case "$f" in
		luci-app-fm350-*) continue ;;
	esac
	sha256sum "$f"
done > SHA256SUMS
echo "  依赖 $(wc -l < SHA256SUMS) 个（主包不计入）"

# 元数据：下载脚本与安装预检共用同一份版本 / 架构 / ABI
KERNEL_VER="$(printf '%s\n' "$ABI" | sed -n 's/^\([0-9.]*\)-[0-9]*-\([0-9a-f]\{8\}\).*/\1~\2/p')"
[ -n "$KERNEL_VER" ] || KERNEL_VER="$(meta FM350_KERNEL)"
cat > META <<EOF
# dist/deps-apk 元数据：固件版本、目标架构、包架构、内核包版本与 kmods ABI
# download.sh / install_all.sh 共同读取，避免版本与 ABI 分散在多处
FM350_VER=$VER
FM350_TARGET=$TARGET
FM350_PKGARCH=$PKGARCH
FM350_KERNEL=$KERNEL_VER
FM350_ABI=$ABI
EOF
echo "  已更新 META（VER=$VER ABI=$ABI）"

# 主包清单由发布流程钉死；本地自编包与它不一致时只提示，不擅自改写
if [ -f APP-SHA256SUMS ]; then
	sha256sum -c APP-SHA256SUMS >/dev/null 2>&1 \
		|| echo "  !! 拷入的主包与 APP-SHA256SUMS 不一致（本地测试构建）：发布前需更新该清单，本地安装用 FM350_LOCAL_APP=1"
fi
echo "  共 $(ls -1 ./*.apk | wc -l) 个包 / $(du -sh "$DEST" | cut -f1)"
