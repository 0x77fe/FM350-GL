#!/bin/sh
# 下载离线依赖包（ipk 体系）到本目录并逐一校验 —— 在**联网的 Windows/Linux 机器**上执行
# 顺带把预编译的主包 luci-app-fm350_*.ipk 从 GitHub Release 取回（见 APP-SHA256SUMS），
# 所以跑完本脚本 + 传到路由器就能装，不需要自己编译。
#
# 目标固件：ImmortalWrt 24.10.x x86_64（kernel 6.6.122，kmods ABI 6.6.122-1-e7e50fbc0aafa7443418a79928da2602）
# 用法（Linux / macOS，或 Windows 上的 Git Bash / WSL；以下命令在仓库根目录执行）：
#     sh dist/deps-ipk/download.sh        # 下载 + 校验 17 个依赖，并取回主包
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
#   FM350_RELEASE_BASE  主包来源前缀，默认本项目 GitHub Release 的 latest/download
#   FM350_NO_APP   设了就不去取主包（只要依赖时用）
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
#   · 本项目自身的包（luci-app-fm350_*.ipk）不在 SHA256SUMS 里：文件名与 sha256 固定在
#     APP-SHA256SUMS，本脚本据此从 GitHub Release（预编译产物）取回；也可自行编译后拷进来
#     （构建机：sh build/build-ipk.sh，或走 docker 的 sh build/build.sh）。
set -e

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$DIR"

# 固件版本、目标架构与 kmods ABI 来自本目录 META；同名环境变量优先
meta() { [ -f META ] && sed -n "s/^$1=//p" META | head -1; }
VER="${FM350_VER:-$(meta FM350_VER)}"
ABI="${FM350_ABI:-$(meta FM350_ABI)}"
TARGET="${FM350_TARGET:-$(meta FM350_TARGET)}"
PKGARCH="${FM350_PKGARCH:-$(meta FM350_PKGARCH)}"
[ -n "$VER" ] && [ -n "$ABI" ] && [ -n "$TARGET" ] && [ -n "$PKGARCH" ] \
	|| { echo "缺少 META（固件版本/架构/ABI）；可用 FM350_VER 等环境变量显式给出"; exit 1; }
MIRRORS="${FM350_MIRRORS:-https://mirror.nju.edu.cn/immortalwrt https://mirrors.ustc.edu.cn/immortalwrt https://mirrors.pku.edu.cn/immortalwrt https://downloads.immortalwrt.org}"
CURL_OPTS="${FM350_CURL_OPTS:-}"

[ -f SHA256SUMS ] || { echo "缺少 SHA256SUMS（依赖清单），无法确定要下什么"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "需要 curl"; exit 1; }

sha() { sha256sum "$1" | cut -d' ' -f1; }
# pick_local_app <glob>：本地自编主包按 -r<release> 的数字取最大（仅 FM350_LOCAL_APP 放行路径用）
pick_local_app()
{
	ls -1 $1 2>/dev/null | awk '{ n=$0; sub(/.*-r/, "", n); sub(/[^0-9].*/, "", n); if (n == "") n=0; print n" "$0 }' \
		| sort -rn | head -1 | cut -d' ' -f2-
}

echo "== 目标固件 $VER / $TARGET / ABI $ABI =="
ok=0; fail=0
while read -r want file; do
	[ -n "$file" ] || continue
	f="${file#./}"
	case "$f" in
		kmod-*) rel="targets/$TARGET/kmods/$ABI/$f" ;;
		odhcp*) rel="packages/$PKGARCH/base/$f" ;;
		*)      rel="packages/$PKGARCH/packages/$f" ;;
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
# 主包：按 APP-SHA256SUMS 的确切文件名与 sha256 核验，不跳过旧包 / 损坏包
RELEASE_BASE="${FM350_RELEASE_BASE:-https://github.com/0x77fe/FM350-GL/releases/latest/download}"
app=""
app_want=""
app_name=""
if [ -f APP-SHA256SUMS ]; then
	read -r app_want app_name < APP-SHA256SUMS
	app_name="${app_name#./}"
fi

if [ -n "$FM350_NO_APP" ]; then
	echo "== 跳过主包（FM350_NO_APP 已设，只要依赖）=="
elif [ -z "$app_name" ]; then
	echo "!! 缺少 APP-SHA256SUMS（主包文件名与 sha256），无法核验主包"
elif [ -s "$app_name" ] && [ "$(sha "$app_name")" = "$app_want" ]; then
	echo "== 主包已在本目录且校验通过：$app_name =="
	app="$app_name"
elif [ -n "$FM350_LOCAL_APP" ]; then
	app=$(pick_local_app './luci-app-fm350_*.ipk')
	if [ -n "$app" ]; then
		echo "== 跳过发布哈希校验（FM350_LOCAL_APP=1，本地自编包）：$app =="
	else
		echo "!! FM350_LOCAL_APP=1，但本目录没有 luci-app-fm350_*.ipk"
	fi
else
	[ -e "$app_name" ] && echo "== 已有 $app_name 与清单哈希不符（旧包或损坏），重新取回 =="
	echo "== 从 Release 取主包：$app_name（最多 3 次）=="
	got=0; try_n=1
	while [ "$try_n" -le 3 ]; do
		if curl -fsSL $CURL_OPTS --max-time 600 -o "$app_name.new" "$RELEASE_BASE/$app_name" 2>/dev/null \
			&& [ -s "$app_name.new" ] && [ "$(sha "$app_name.new")" = "$app_want" ]; then
			got=1; break
		fi
		rm -f "$app_name.new"
		if [ "$try_n" -lt 3 ]; then
			echo "  第 $try_n/3 次失败（GitHub 偶发连不上），3 秒后重试…"
			sleep 3
		fi
		try_n=$((try_n + 1))
	done
	if [ "$got" = 1 ]; then
		mv -f "$app_name.new" "$app_name"
		# 清掉不在清单里的旧主包，避免安装器或人工挑错文件
		for old in ./luci-app-fm350_*.ipk; do
			[ -e "$old" ] || continue
			[ "$old" = "./$app_name" ] && continue
			echo "  清理不在清单里的主包：$old"
			rm -f "$old"
		done
		echo "  已取回 $app_name（sha256 与 APP-SHA256SUMS 一致）✓"
		app="$app_name"
	else
		echo "  !! 取不到或校验失败（已重试 3 次）：GitHub 在国内可能很慢或不可达"
		echo "     ① 换镜像/代理重跑：FM350_RELEASE_BASE=<镜像前缀> sh download.sh"
		echo "     ② 在构建机上自行编译后拷进来：sh build/build-ipk.sh"
		echo "        本地自编包用于测试时，下载脚本加 FM350_LOCAL_APP=1 放行，或直接手动拷入"
	fi
fi

if [ -z "$app" ] && [ -z "$FM350_NO_APP" ]; then
	echo
	echo "== 本目录还不完整（缺清单里的主包）：按上面的提示补上后再传路由器 =="
	exit 1
fi
echo
echo "== 下一步：整个目录传到路由器，再跑 install_all.sh （以下命令在仓库根目录执行）=="
echo "   Linux   ：tar -czf - -C dist/deps-ipk . | ssh root@<router> \"mkdir -p /tmp/deps-ipk && tar -xzf - -C /tmp/deps-ipk\""
echo '   Windows ：tar -czf "$env:TEMP\deps-ipk.tar.gz" -C dist/deps-ipk .'
echo '             scp -O "$env:TEMP\deps-ipk.tar.gz" root@<router>:/tmp/'
echo '             ssh root@<router> "mkdir -p /tmp/deps-ipk && tar -xzf /tmp/deps-ipk.tar.gz -C /tmp/deps-ipk"'
echo '             ssh root@<router> "sh /tmp/deps-ipk/install_all.sh"'
