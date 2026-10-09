#!/bin/sh
# luci-app-fm350 离线安装 —— apk 体系（OpenWrt / ImmortalWrt 25.12 及以后）
#
# 目标：ImmortalWrt 25.12.x x86/64（kernel 6.12.94，kmods ABI 6.12.94-1-0413601b1c3f0490e17f340fe09229ea）
# 用法：先把本目录整包传到路由器，再在路由器上执行本脚本 —— 路由器**不需要联网**
#       传送前必须先在联网机器上跑 download.sh 或 download.ps1（两者等价），把 19 个依赖与
#       预编译主包下齐并校验；缺文件或哈希不符时本脚本会在安装前失败。
#       传输注意：PowerShell 里的 tar 管道会损坏二进制，须先打包再传；scp 必须 -O（dropbear 无 sftp-server）。
#
# 目录内容：download.sh / download.ps1（联网下载，二选一）+ 19 个依赖包 + SHA256SUMS
#           + 主包 luci-app-fm350-*.apk + APP-SHA256SUMS（主包的发布锚点）
#   · 仓库不含二进制：第三方依赖由下载脚本按 SHA256SUMS 从官方镜像取得并校验，
#     主包（本项目自建）由下载脚本按 APP-SHA256SUMS 从 GitHub Release 取回并校验；
#   · kmod 与固件内核 ABI 强绑定，装错版本 apk 会直接拒绝（所以脚本先预检 ABI）；
#   · 所有 apk add 都带 --network=no：只用本目录 + 固件已装的包，不访问网络。
set -e

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$DIR"

# 固件版本、目标架构与内核 ABI 只来自 META，不再在各脚本里各写一份
validate_meta()
{
	[ -s META ] || { echo "缺少或为空的 META（固件版本与内核 ABI）"; exit 1; }
	awk -F= '
		/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
		NF != 2 { bad=1; next }
		$1 !~ /^FM350_(VER|TARGET|PKGARCH|KERNEL|ABI)$/ { bad=1; next }
		$2 !~ /^[-A-Za-z0-9._\/~+]+$/ { bad=1; next }
		seen[$1]++ { bad=1 }
		END {
			n=split("FM350_VER,FM350_TARGET,FM350_PKGARCH,FM350_KERNEL,FM350_ABI", required, ",")
			for (i=1; i<=n; i++) if (seen[required[i]] != 1) bad=1
			if (bad) exit 1
		}' META || { echo "META 格式无效（需包含唯一且有效的 FM350_VER/TARGET/PKGARCH/KERNEL/ABI）"; exit 1; }
}

validate_manifest()
{
	[ -s SHA256SUMS ] || { echo "依赖清单 SHA256SUMS 缺失或为空"; exit 1; }
	awk '
		NF != 2 { bad=1; next }
		length($1) != 64 || $1 !~ /^[A-Fa-f0-9]+$/ { bad=1; next }
		$2 !~ /^\.\/[A-Za-z0-9][A-Za-z0-9_.+~-]*\.apk$/ { bad=1; next }
		seen[$2]++ { bad=1; next }
		{ count++ }
		END { if (count < 1 || bad) exit 1 }
	' SHA256SUMS || { echo "依赖清单 SHA256SUMS 格式无效"; exit 1; }
	sha256sum -c SHA256SUMS >/dev/null 2>&1 || { echo "依赖清单 SHA256SUMS 校验失败（缺包或哈希不符）"; exit 1; }
}

validate_meta
. ./META
KMOD_ABI="${FM350_ABI:-}"
KMOD_ABI_PREFIX="${FM350_KERNEL:-}"
validate_manifest

# pick_local_app <glob>：本地自编主包按 -r<release> 的数字取最大（仅 FM350_LOCAL_APP 放行路径用）
pick_local_app()
{
	ls -1 $1 2>/dev/null | awk '{ n=$0; sub(/.*-r/, "", n); sub(/[^0-9].*/, "", n); if (n == "") n=0; print n" "$0 }' \
		| sort -rn | head -1 | cut -d' ' -f2-
}

echo "[0/6] 预检"

# 固件自带（不在本目录里，缺了离线就装不上）
miss=""
for p in libc luci-base rpcd; do
	apk list -I 2>/dev/null | grep -q "^${p}-" || miss="$miss $p"
done
if [ -n "$miss" ]; then
	echo "  !! 固件缺少：$miss"
	echo "     本目录不含这些基础包（正常 25.12 官方/ImmortalWrt 镜像自带），需联网补装后重试"
	exit 1
fi

kern=$(apk list -I 2>/dev/null | awk '/^kernel-/{print $1; exit}' | sed 's/^kernel-//')
echo "  固件 kernel: ${kern:-未知}（本目录 ABI: ${KMOD_ABI:-未知}）"
case "$kern" in
	"$KMOD_ABI_PREFIX"*) echo "  内核 ABI 与本目录 kmod 匹配 ✓" ;;
	*)
		echo "  !! 内核 ABI 不匹配：本目录 kmod 对应 $KMOD_ABI"
		echo "     换固件版本后需重新抓离线包：在构建机上跑 build/fetch-deps-apk.sh"
		exit 1
		;;
esac

echo "[1/6] 校验包完整性（SHA256SUMS）"
DEP_LIST=""
n=$(wc -l < SHA256SUMS)
echo "  $n 个依赖校验通过 ✓"
# 安装文件只取清单里列出且已校验通过的那些，不用通配符
while read -r _want _file; do
	DEP_LIST="$DEP_LIST ./${_file#./}"
done < SHA256SUMS

# 主包：按 APP-SHA256SUMS 里的确切文件名与 sha256 校验（防旧版本 / 截断 / 被替换）
# 本地自编包（build/build-apk.sh）用于测试时，用 FM350_LOCAL_APP=1 显式放行
APP=""
if [ -f APP-SHA256SUMS ]; then
	read -r app_want app_name < APP-SHA256SUMS
	app_name="${app_name#./}"
	if [ -n "$app_name" ] && [ -f "./$app_name" ] \
		&& [ "$(sha256sum "./$app_name" | cut -d' ' -f1)" = "$app_want" ]; then
		APP="./$app_name"
		echo "  主包校验通过 ✓ $app_name"
	elif [ -n "$FM350_LOCAL_APP" ]; then
		APP=$(pick_local_app './luci-app-fm350-*.apk')
		[ -n "$APP" ] && echo "  !! 跳过发布哈希校验（FM350_LOCAL_APP=1，本地自编包）：$APP"
	fi
else
	echo "  (无 APP-SHA256SUMS)"
	if [ -n "$FM350_LOCAL_APP" ]; then
		APP=$(pick_local_app './luci-app-fm350-*.apk')
	fi
fi

[ -n "$APP" ] || {
	echo "  !! 主包缺失或与 APP-SHA256SUMS 不符（期望 ${app_name:-未知}）"
	echo "     ① 回联网的 Windows/Linux 机器跑本目录的下载脚本，按发布清单取回主包；"
	echo "     ② 本地自编包测试时用 FM350_LOCAL_APP=1 显式放行（跳过发布哈希校验）"
	sha256sum -c APP-SHA256SUMS 2>&1 | grep -v OK
	exit 1
}

echo "[2/6] 安装内核模块与工具（本地文件，禁网）"
if [ -n "$DEP_LIST" ]; then
	apk add --network=no --allow-untrusted $DEP_LIST
fi

echo "[3/6] 安装主包 $APP"
apk add --network=no --allow-untrusted "$APP"

echo "[4/6] 重启 rpcd（否则 ubus 对象 fm350 不注册，页面全空）"
/etc/init.d/rpcd restart
sleep 2

echo "[5/6] 刷新静态资源 ETag"
touch /www/luci-static/resources/view/fm350/*.js /www/luci-static/resources/fm350/*.js 2>/dev/null || true
echo "  提示：浏览器仍显示旧界面或报错时，请强制刷新一次（Ctrl+Shift+R）"
# stop → 停顿 → start：procd 对 restart 的 stop/start 竞争会产生双实例记录
/etc/init.d/fm350mgr stop 2>/dev/null || true
sleep 2
/etc/init.d/fm350mgr enable
/etc/init.d/fm350mgr start
sleep 8

echo "[6/6] 状态检查"
apk list -I 2>/dev/null | grep -E '^luci-app-fm350' || echo "  !! 未出现在已装列表"
if ubus list 2>/dev/null | grep -q '^fm350$'; then
	echo "  ubus 对象 fm350 已注册 ✓"
else
	echo "  !! ubus 里没有 fm350（rpcd 未加载后端？）"
fi
echo "  守护进程数=$(pgrep -f '[f]m350.sh daemon' | wc -l)"
jq -r '.state, .net.v4_at, .usb.vid' /var/run/fm350/state.json 2>/dev/null || echo "  (state.json 未生成：logread | grep fm350 查看原因)"
echo "-------- 完成 --------"
echo "LuCI: 服务 -> FM350 管理（概览/AT命令/拨号管理/设置/日志）"
