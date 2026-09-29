#!/bin/sh
# luci-app-fm350 离线安装 —— apk 体系（OpenWrt / ImmortalWrt 25.12 及以后）
#
# 目标：ImmortalWrt 25.12.x x86/64（kernel 6.12.94，kmods ABI 6.12.94-1-0413601b1c3f0490e17f340fe09229ea）
# 前置：在**联网的开发机**上先执行 `sh download.sh` 把依赖下齐并校验，
#       再把整个目录传到路由器执行本脚本 —— 路由器**不需要联网**
#     sh download.sh
#     tar -czf - -C dist/deps-apk . | ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf - -C /tmp/deps-apk"
#     ssh root@<router> "sh /tmp/deps-apk/install_all.sh"
#
# 目录内容：download.sh（联网下载）+ 19 个依赖包 + SHA256SUMS + 主包 luci-app-fm350-*.apk（自建）
#   · 仓库不含二进制，依赖由 download.sh 按 SHA256SUMS 从官方源取得并校验；
#   · kmod 与固件内核 ABI 强绑定，装错版本 apk 会直接拒绝（所以脚本先预检 ABI）；
#   · 所有 apk add 都带 --network=no：只用本目录 + 固件已装的包，不访问网络。
set -e

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$DIR"

KMOD_ABI=6.12.94-1-0413601b1c3f0490e17f340fe09229ea
KMOD_ABI_PREFIX=6.12.94~0413601b

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
echo "  固件 kernel: ${kern:-未知}"
case "$kern" in
	"$KMOD_ABI_PREFIX"*) echo "  内核 ABI 与本目录 kmod 匹配 ✓" ;;
	*)
		echo "  !! 内核 ABI 不匹配：本目录 kmod 对应 $KMOD_ABI"
		echo "     换固件版本后需重新抓离线包：在构建机上跑 build/fetch-deps-apk.sh"
		exit 1
		;;
esac

echo "[1/6] 校验包完整性（SHA256SUMS）"
if [ -f SHA256SUMS ]; then
	n=$(wc -l < SHA256SUMS)
	sha256sum -c SHA256SUMS >/dev/null && echo "  $n 个依赖校验通过 ✓" || {
		echo "  !! 校验失败（缺包或内容不符）：请在联网的开发机上先跑本目录的 download.sh，再重新传过来"
		sha256sum -c SHA256SUMS | grep -v OK
		exit 1
	}
else
	echo "  (无 SHA256SUMS，跳过)"
fi

echo "[2/6] 安装内核模块与工具（本地文件，禁网）"
apk add --network=no --allow-untrusted ./kmod-*.apk ./jq-*.apk ./sms-tool-*.apk

APP=$(ls ./luci-app-fm350-*.apk 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "缺少 luci-app-fm350 apk"; exit 1; }
echo "[3/6] 安装主包 $APP"
apk add --network=no --allow-untrusted "$APP"

echo "[4/6] 重启 rpcd（否则 ubus 对象 fm350 不注册，页面全空）"
/etc/init.d/rpcd restart
sleep 2

echo "[5/6] uhttpd 防缓存 + 启用并启动守护"
uci -q get uhttpd.main.no_cache | grep -q js || { uci set uhttpd.main.no_cache='js'; uci commit uhttpd; }
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
touch /www/luci-static/resources/view/fm350/*.js 2>/dev/null || true
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
