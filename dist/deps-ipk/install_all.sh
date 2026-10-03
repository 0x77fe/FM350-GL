#!/bin/sh
# luci-app-fm350 离线安装 —— ipk 体系（ImmortalWrt / OpenWrt 24.10 及以前，opkg）
#
# 目标：ImmortalWrt 24.10.x x86_64（kernel 6.6.122，kmods ABI 6.6.122-1-e7e50fbc0aafa7443418a79928da2602）
# 前置：在**联网的 Windows/Linux 机器**上先跑下载脚本把依赖下齐并校验
#       （Linux：`sh download.sh`；Windows 原生：`download.ps1`，二者等价），
#       再把整个目录传到路由器执行本脚本 —— 路由器**不需要联网**
#     # Linux
#     sh download.sh
#     tar -czf - -C dist/deps-ipk . | ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf - -C /tmp/deps-ipk"
#     # Windows 原生（PowerShell 里的 tar 管道会损坏二进制 → 先打包再传；scp -O 适配 dropbear 无 sftp-server）
#     powershell -ExecutionPolicy Bypass -File dist\deps-ipk\download.ps1
#     tar -czf "$env:TEMP\deps-ipk.tar.gz" -C dist\deps-ipk .
#     scp -O "$env:TEMP\deps-ipk.tar.gz" root@<router>:/tmp/
#     ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf /tmp/deps-ipk.tar.gz -C /tmp/deps-ipk"
#     # 两边一样：在路由器上离线安装
#     ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"
#
# 目录内容：download.sh / download.ps1（联网下载，二选一）+ 17 个依赖包 + SHA256SUMS + 主包 luci-app-fm350_*.ipk（自建）
#   · 仓库不含二进制，依赖由下载脚本按 SHA256SUMS 从官方源取得并校验
set -e

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$DIR"

KERNEL_VER=6.6.122

echo "[0/6] 预检"
# 注意 libubox / libubus 在 24.10 是带版本号的包名（libubox20240329、libubus20250102），
# 所以按前缀匹配，不能按固定名查
miss=""
for p in luci-base rpcd; do
	opkg list-installed 2>/dev/null | grep -q "^${p} " || miss="$miss $p"
done
for p in libubox libubus; do
	opkg list-installed 2>/dev/null | grep -q "^${p}" || miss="$miss $p"
done
if [ -n "$miss" ]; then
	echo "  !! 固件缺少：$miss"
	echo "     本目录不含这些基础包（正常 24.10 镜像自带），需联网补装后重试"
	exit 1
fi

kern=$(uname -r)
echo "  固件 kernel: $kern"
case "$kern" in
	"$KERNEL_VER"*) echo "  内核版本与本目录 kmod 匹配 ✓" ;;
	*)
		echo "  !! 内核不匹配：本目录 kmod 是 $KERNEL_VER-r1"
		echo "     换固件版本后需重新抓离线包（kmod 必须与固件内核 ABI 完全一致）"
		exit 1
		;;
esac

echo "[1/6] 校验包完整性（SHA256SUMS）"
if [ -f SHA256SUMS ]; then
	n=$(wc -l < SHA256SUMS)
	sha256sum -c SHA256SUMS >/dev/null && echo "  $n 个依赖校验通过 ✓" || {
		echo "  !! 校验失败（缺包或内容不符）：请在联网的 Windows/Linux 机器上先跑本目录的下载脚本（download.sh / download.ps1），再重新传过来"
		sha256sum -c SHA256SUMS | grep -v OK
		exit 1
	}
else
	echo "  (无 SHA256SUMS，跳过)"
fi

echo "[2/6] 安装依赖包（kmod / sms-tool / jq / odhcp6c / odhcpd-ipv6only）"
opkg install ./kmod-usb-core_*.ipk ./kmod-usb2_*.ipk ./kmod-usb3_*.ipk \
	./kmod-usb-ehci_*.ipk ./kmod-usb-ohci_*.ipk ./kmod-usb-xhci-hcd_*.ipk \
	./kmod-usb-net_*.ipk ./kmod-usb-net-cdc-ether_*.ipk ./kmod-usb-net-rndis_*.ipk \
	./kmod-usb-acm_*.ipk ./kmod-usb-serial_*.ipk ./kmod-usb-serial-wwan_*.ipk \
	./kmod-usb-wdm_*.ipk ./sms-tool_*.ipk ./jq_*.ipk ./odhcp6c_*.ipk ./odhcpd-ipv6only_*.ipk 2>&1 | tail -5

APP=$(ls ./luci-app-fm350_*.ipk 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "缺少 luci-app-fm350 ipk"; exit 1; }
echo "[3/6] 安装 $APP"
opkg install "$APP" 2>&1 | tail -4

echo "[4/6] 重启 rpcd（否则 ubus 对象 fm350 不注册，页面全空）"
/etc/init.d/rpcd restart
sleep 2

echo "[5/6] uhttpd 防缓存 + 启用并启动守护"
uci -q get uhttpd.main.no_cache | grep -q js || { uci set uhttpd.main.no_cache='js'; uci commit uhttpd; }
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
touch /www/luci-static/resources/view/fm350/*.js 2>/dev/null || true
# stop → 停顿 → start：procd 对 restart 的 stop/start 竞争会产生双实例记录
/etc/init.d/fm350mgr disable 2>/dev/null || true
/etc/init.d/fm350mgr stop 2>/dev/null || true
sleep 2
/etc/init.d/fm350mgr enable
/etc/init.d/fm350mgr start
sleep 8

echo "[6/6] 状态检查"
opkg list-installed 2>/dev/null | grep -E '^luci-app-fm350' || echo "  !! 未出现在已装列表"
if ubus list 2>/dev/null | grep -q '^fm350$'; then
	echo "  ubus 对象 fm350 已注册 ✓"
else
	echo "  !! ubus 里没有 fm350（rpcd 未加载后端？）"
fi
echo "  守护进程数=$(pgrep -f '[f]m350.sh daemon' | wc -l)"
jq -r '.state, .net.v4_at, .usb.vid' /var/run/fm350/state.json 2>/dev/null || echo "  (state.json 未生成：logread | grep fm350 查看原因)"
echo "-------- 完成 --------"
echo "LuCI: 服务 -> FM350 管理（概览/AT命令/拨号管理/设置/日志）"
