#!/bin/sh
# 下载离线依赖包（apk 体系）到本目录并逐一校验 —— 在**联网的 Windows/Linux 机器**上执行
# 顺带把预编译的主包 luci-app-fm350-*.apk 从 GitHub Release 取回（见 APP-SHA256SUMS），
# 所以跑完本脚本 + 传到路由器就能装，不需要自己编译。
#
# 目标固件：ImmortalWrt 25.12.x x86/64（kernel 6.12.94，kmods ABI 6.12.94-1-0413601b1c3f0490e17f340fe09229ea）
# 用法（Linux / macOS，或 Windows 上的 Git Bash / WSL；以下命令在仓库根目录执行）：
#     sh dist/deps-apk/download.sh        # 下载 + 校验 19 个依赖，并取回主包
#     tar -czf - -C dist/deps-apk . | ssh root@<路由器> "mkdir -p /tmp/deps-apk && tar -xzf - -C /tmp/deps-apk"
#     ssh root@<路由器> "sh /tmp/deps-apk/install_all.sh"
#
# Windows 原生用法（不需要 Git Bash / WSL）：跑同目录等价的 download.ps1
#     powershell -ExecutionPolicy Bypass -File dist\deps-apk\download.ps1      # 在仓库根目录执行
#     # 传输：PowerShell 里的 tar 管道会损坏二进制 → 先打包再传（Windows 自带 bsdtar 与 OpenSSH；
#     #       scp 必须 -O：dropbear 没有 sftp-server，OpenSSH 9+ 默认的 SFTP 协议会直接失败）
#     tar -czf "$env:TEMP\deps-apk.tar.gz" -C dist\deps-apk .
#     scp -O "$env:TEMP\deps-apk.tar.gz" root@<路由器>:/tmp/
#     ssh root@<路由器> "mkdir -p /tmp/deps-apk && tar -xzf /tmp/deps-apk.tar.gz -C /tmp/deps-apk"
#     ssh root@<路由器> "sh /tmp/deps-apk/install_all.sh"
#
# 环境变量：
#   FM350_VER      固件版本      默认 25.12.1（换版本要同时换一套 SHA256SUMS 与主包）
#   FM350_ABI      kmods ABI     默认 6.12.94-1-0413601b1c3f0490e17f340fe09229ea
#   FM350_MIRRORS  镜像列表（按顺序尝试），默认 NJU → USTC → PKU → 官方
#   FM350_RELEASE_BASE  主包来源前缀，默认本项目 GitHub Release 的 latest/download
#   FM350_NO_APP   设了就不去取主包（只要依赖时用）
#   FM350_CURL_OPTS 额外传给 curl 的参数（默认空）。Windows 上的 Git Bash 若报
#                   `curl: (35) schannel: CRYPT_E_REVOCATION_OFFLINE`（Git 自带 curl 走 Schannel，
#                   联网校验证书吊销列表失败），加 --ssl-no-revoke 即可：
#                       FM350_CURL_OPTS=--ssl-no-revoke sh download.sh
#                   （或者直接用同目录的 download.ps1，它不受这个问题影响）
#
# 说明：
#   · 仓库**不含二进制**：包名与 sha256 固定在 SHA256SUMS 里，本脚本按清单逐个下载并校验，
#     只有校验通过才会留下文件（不会留下半成品或被篡改的包）；
#   · 镜像实测：NJU ~350KB/s 且目录列表完整；USTC 快但列表会截断；PKU 很快但目录页是空壳；
#     官方源最全但国内很慢 —— 这里直接按文件名直取，所以四个都能用。
#   · 本项目自身的包（luci-app-fm350-*.apk）不在 SHA256SUMS 里：文件名与 sha256 固定在
#     APP-SHA256SUMS，本脚本据此从 GitHub Release（预编译产物）取回；也可自行编译后拷进来
#     （构建机：sh build/build-apk.sh）。
set -e

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$DIR"

VER="${FM350_VER:-25.12.1}"
ABI="${FM350_ABI:-6.12.94-1-0413601b1c3f0490e17f340fe09229ea}"
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
		printf '  下载  %-42s ← %s\n' "$f" "$got"; ok=$((ok + 1))
	else
		printf '  失败  %s（所有镜像都下不到，或 sha256 不符）\n' "$f"; fail=$((fail + 1))
	fi
done < SHA256SUMS

echo "== 依赖：成功 $ok 个，失败 $fail 个 =="
[ "$fail" -eq 0 ] || exit 1

echo
# ---- 主包：本目录已有就跳过；没有则按 APP-SHA256SUMS 从 GitHub Release 取回预编译产物 ----
RELEASE_BASE="${FM350_RELEASE_BASE:-https://github.com/0x77fe/FM350-GL/releases/latest/download}"
app=$(ls -1 ./luci-app-fm350-*.apk 2>/dev/null | head -1)

if [ -n "$app" ]; then
	echo "== 主包已在本目录：$app =="
elif [ -n "$FM350_NO_APP" ]; then
	echo "== 跳过主包（FM350_NO_APP 已设）=="
elif [ -f APP-SHA256SUMS ]; then
	read -r want name < APP-SHA256SUMS
	name="${name#./}"
	echo "== 主包不在本目录 → 从 Release 取：$name =="
	got=0; try_n=1
	while [ "$try_n" -le 3 ]; do
		if curl -fsSL $CURL_OPTS --max-time 600 -o "$name.new" "$RELEASE_BASE/$name" 2>/dev/null \
			&& [ -s "$name.new" ] && [ "$(sha "$name.new")" = "$want" ]; then
			got=1; break
		fi
		rm -f "$name.new"
		if [ "$try_n" -lt 3 ]; then
			echo "  第 $try_n/3 次失败（GitHub 偶发连不上），3 秒后重试…"
			sleep 3
		fi
		try_n=$((try_n + 1))
	done
	if [ "$got" = 1 ]; then
		mv -f "$name.new" "$name"
		echo "  已取回 $name（sha256 与 APP-SHA256SUMS 一致）✓"
		app="$name"
	else
		echo "  !! 取不到或校验失败（已重试 3 次）：GitHub 在国内可能很慢或不可达"
		echo "     ① 换镜像/代理重跑：FM350_RELEASE_BASE=<镜像前缀> sh download.sh"
		echo "     ② 在构建机上自行编译后拷进来："
		echo "        sh build/build-apk.sh && cp dist/luci-app-fm350-*.apk dist/deps-apk/"
	fi
else
	echo "== 缺少 APP-SHA256SUMS，无法确定主包文件名与 sha256 =="
fi

[ -n "$app" ] || {
	echo
	echo "== 本目录还不完整（缺主包 luci-app-fm350-*.apk）：按上面的提示补上后再传路由器 =="
	exit 1
}
echo
echo "== 下一步：整个目录传到路由器，再跑 install_all.sh （以下命令在仓库根目录执行）=="
echo "   Linux   ：tar -czf - -C dist/deps-apk . | ssh root@<router> \"mkdir -p /tmp/deps-apk && tar -xzf - -C /tmp/deps-apk\""
echo '   Windows ：tar -czf "$env:TEMP\deps-apk.tar.gz" -C dist/deps-apk .'
echo '             scp -O "$env:TEMP\deps-apk.tar.gz" root@<router>:/tmp/'
echo '             ssh root@<router> "mkdir -p /tmp/deps-apk && tar -xzf /tmp/deps-apk.tar.gz -C /tmp/deps-apk"'
echo '             ssh root@<router> "sh /tmp/deps-apk/install_all.sh"'
