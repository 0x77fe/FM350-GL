#!/bin/sh
# 下载离线依赖包（ipk 体系）到本目录并逐一校验 —— 在**联网的 Windows/Linux 机器**上执行
#
# 目标固件：ImmortalWrt 24.10.x x86_64（kernel 6.6.122，kmods ABI 6.6.122-1-e7e50fbc0aafa7443418a79928da2602）
# 用法（Linux / macOS，或 Windows 上的 Git Bash / WSL；以下命令在仓库根目录执行）：
#     sh dist/deps-ipk/download.sh        # 下载 + 校验 17 个依赖
#     tar -czf - -C dist/deps-ipk . | ssh root@<路由器> "mkdir -p /tmp/deps-ipk && tar -xzf - -C /tmp/deps-ipk"
#     ssh root@<路由器> "sh /tmp/deps-ipk/install_all.sh"
#
# Windows 原生用法（不需要 Git Bash / WSL）：跑同目录等价的 download.ps1
#     powershell -ExecutionPolicy Bypass -File dist\deps-ipk\download.ps1      # 在仓库根目录执行
#     # 传输：PowerShell 里的 tar 管道会损坏二进制 → 先打包再传（Windows 自带 bsdtar 与 OpenSSH；
#     #       scp 必须 -O：dropbear 没有 sftp-server，OpenSSH 9+ 默认的 SFTP 协议会直接失败）
#     tar -czf "$env:TEMP\deps-ipk.tar.gz" -C dist\deps-ipk .
#     scp -O "$env:TEMP\deps-ipk.tar.gz" root@<路由器>:/tmp/
#     ssh root@<路由器> "mkdir -p /tmp/deps-ipk && tar -xzf /tmp/deps-ipk.tar.gz -C /tmp/deps-ipk"
#     ssh root@<路由器> "sh /tmp/deps-ipk/install_all.sh"
#
# 环境变量：
#   FM350_VER      固件版本      默认 24.10.5（换版本要同时换一套 SHA256SUMS 与主包）
#   FM350_ABI      kmods ABI     默认 6.6.122-1-e7e50fbc0aafa7443418a79928da2602
#   FM350_MIRRORS  镜像列表（按顺序尝试），默认 NJU → USTC → PKU → 官方
#   FM350_CURL_OPTS 额外传给 curl 的参数（默认空）。Windows 上的 Git Bash 若报
#                   `curl: (35) schannel: CRYPT_E_REVOCATION_OFFLINE`（Git 自带 curl 走 Schannel，
#                   联网校验证书吊销列表失败），加 --ssl-no-revoke 即可：
#                       FM350_CURL_OPTS=--ssl-no-revoke sh download.sh
#                   （或者直接用同目录的 download.ps1，它不受这个问题影响）
#
# 说明：
#   · 仓库**不含二进制**：包名与 sha256 固定在 SHA256SUMS 里，本脚本按清单逐个下载并校验；
#   · kmod 与固件内核 ABI 强绑定，装错版本 opkg 会拒绝；odhcp6c / odhcpd-ipv6only 来自 base feed，
#     其余（jq / sms-tool）来自 packages feed —— 下面按包名前缀分派下载路径；
#   · 本项目自身的包（luci-app-fm350_*.ipk）由 build/build.sh 编译产出，不在 SHA256SUMS 里。
set -e

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$DIR"

VER="${FM350_VER:-24.10.5}"
ABI="${FM350_ABI:-6.6.122-1-e7e50fbc0aafa7443418a79928da2602}"
MIRRORS="${FM350_MIRRORS:-https://mirror.nju.edu.cn/immortalwrt https://mirrors.ustc.edu.cn/immortalwrt https://mirrors.pku.edu.cn/immortalwrt https://downloads.immortalwrt.org}"
CURL_OPTS="${FM350_CURL_OPTS:-}"

[ -f SHA256SUMS ] || { echo "缺少 SHA256SUMS（依赖清单），无法确定要下什么"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "需要 curl"; exit 1; }

sha() { sha256sum "$1" | cut -d' ' -f1; }

echo "== 目标固件 $VER / ABI $ABI =="
ok=0; fail=0
while read -r want file; do
	[ -n "$file" ] || continue
	f="${file#./}"
	case "$f" in
		kmod-*) rel="targets/x86/64/kmods/$ABI/$f" ;;
		odhcp*) rel="packages/x86_64/base/$f" ;;
		*)      rel="packages/x86_64/packages/$f" ;;
	esac

	if [ -s "$f" ] && [ "$(sha "$f")" = "$want" ]; then
		printf '  已有  %s\n' "$f"; ok=$((ok + 1)); continue
	fi

	got=""
	for m in $MIRRORS; do
		if curl -fsSL $CURL_OPTS --max-time 300 -o "$f.new" "$m/releases/$VER/$rel" 2>/dev/null \
			&& [ -s "$f.new" ] && [ "$(sha "$f.new")" = "$want" ]; then
			mv -f "$f.new" "$f"; got="$m"; break
		fi
		rm -f "$f.new"
	done

	if [ -n "$got" ]; then
		printf '  下载  %-58s ← %s\n' "$f" "$got"; ok=$((ok + 1))
	else
		printf '  失败  %s（所有镜像都下不到，或 sha256 不符）\n' "$f"; fail=$((fail + 1))
	fi
done < SHA256SUMS

echo "== 依赖：成功 $ok 个，失败 $fail 个 =="
[ "$fail" -eq 0 ] || exit 1

echo
if ls ./luci-app-fm350_*.ipk >/dev/null 2>&1; then
	echo "== 主包已在本目录 =="
	ls -l ./luci-app-fm350_*.ipk
else
	echo "== 还缺主包 luci-app-fm350_*.ipk（仓库不含二进制）=="
	echo "   在装有 docker 的构建机上编译后把 dist/luci-app-fm350_*.ipk 拷到本目录："
	echo "     sh build/build.sh             # docker + ImmortalWrt SDK（出 ipk）"
fi
echo
echo "== 下一步：整个目录传到路由器，再跑 install_all.sh （以下命令在仓库根目录执行）=="
echo "   Linux   ：tar -czf - -C dist/deps-ipk . | ssh root@<router> \"mkdir -p /tmp/deps-ipk && tar -xzf - -C /tmp/deps-ipk\""
echo '   Windows ：tar -czf "$env:TEMP\deps-ipk.tar.gz" -C dist/deps-ipk .'
echo '             scp -O "$env:TEMP\deps-ipk.tar.gz" root@<router>:/tmp/'
echo '             ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf /tmp/deps-ipk.tar.gz -C /tmp/deps-ipk"'
echo '             ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"'
