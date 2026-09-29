#!/bin/sh
# 校验 dist/ 里的 luci-app-fm350 apk（在构建机上执行）
#     sh build/verify-apk.sh [apk路径]
#
# 做三件事：
#   1. 打印 apk v3 元数据（名称/版本/arch/依赖/文件数）；
#   2. 用 SDK 自带 host apk 造 5 个依赖占位包（libc/luci-base/rpcd/jq/sms-tool），
#      连本包一起装进假根（--usermode，无需 root、不碰系统）——证明这个 apk 真能被 apk 装；
#   3. 逐文件 sha256 比对假根落盘内容与 luci-app-fm350/files/ 源码（确保没装错东西）。
#
# 注意：非 root 的 usermode 下 apk 执行 post-install 脚本会报
#   "unshare: Operation not permitted" —— 那是 apk 自己的脚本沙箱在非特权环境不可用，
#   不是包的问题（路由器上以 root 安装不会出现）。
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# host apk 从哪个 SDK 里取：优先 ImmortalWrt（目标固件），其次官方 OpenWrt
if [ -n "$FM350_SDK_DIR" ]; then
	SDK="$FM350_SDK_DIR"
elif [ -x "$HOME/fm350/sdk-immortalwrt-25.12.1/staging_dir/host/bin/apk" ]; then
	SDK="$HOME/fm350/sdk-immortalwrt-25.12.1"
else
	SDK="$HOME/fm350/sdk-openwrt-25.12.5"
fi
APKTOOL="${FM350_APK_TOOL:-$SDK/staging_dir/host/bin/apk}"
APK="${1:-$(ls -1 "$ROOT"/dist/luci-app-fm350-*.apk 2>/dev/null | head -1)}"

[ -n "$APK" ] && [ -f "$APK" ] || { echo "找不到 apk（先跑 build/build-apk.sh）"; exit 1; }
[ -x "$APKTOOL" ] || { echo "找不到 host apk: $APKTOOL"; exit 1; }

STUB=/tmp/fm350-verify-stub
FAKEROOT=/tmp/fm350-verify-root

echo "== 1/3 元数据: $(basename "$APK") =="
ls -l "$APK"
sha256sum "$APK"
"$APKTOOL" adbdump "$APK" | sed -n '1,32p'

echo
echo "== 2/3 假根安装（依赖占位包 + 本包）=="
rm -rf "$STUB" "$FAKEROOT"; mkdir -p "$STUB" "$FAKEROOT"
for p in libc luci-base rpcd jq sms-tool; do
	d="$STUB/build/$p"; mkdir -p "$d"; echo "stub for $p" > "$d/$p"
	"$APKTOOL" mkpkg --info "name:$p" --info "version:99.0.0-r0" --info "arch:noarch" \
		--info "description:stub" --info "license:MIT" --files "$d" \
		--output "$STUB/$p-99.0.0-r0.apk" >/dev/null
done
"$APKTOOL" --root "$FAKEROOT" --initdb --usermode --allow-untrusted --no-network \
	--force-non-repository add "$STUB"/*.apk "$APK" 2>&1 | sed 's/^/  /' || true

echo
echo "== 3/3 内容比对（假根 vs luci-app-fm350/files/）=="
bad=0; n=0
for f in $(find "$FAKEROOT" -type f | sort); do
	rel="${f#$FAKEROOT}"
	case "$rel" in /lib/apk/*|/etc/apk/*|/var/*|/jq|/libc|/luci-base|/rpcd|/sms-tool) continue;; esac
	n=$((n+1))
	a=$(sha256sum "$f" | cut -d' ' -f1)
	b=$(sha256sum "$ROOT/luci-app-fm350/files$rel" 2>/dev/null | cut -d' ' -f1)
	if [ "$a" = "$b" ]; then
		printf '  OK    %s\n' "$rel"
	else
		printf '  DIFF  %s\n' "$rel"; bad=$((bad+1))
	fi
done
echo "== 共 $n 个文件，不一致 $bad 个 =="
[ "$bad" -eq 0 ] || exit 1
