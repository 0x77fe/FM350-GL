#!/bin/sh
# 下载离线依赖包（apk 体系）到本目录并逐一校验 —— 在**联网的开发机**上执行
#
# 目标固件：ImmortalWrt 25.12.x x86/64（kernel 6.12.94，kmods ABI 6.12.94-1-0413601b1c3f0490e17f340fe09229ea）
# 用法：
#     sh download.sh                     # 下载 + 校验 19 个依赖
#     tar czf - . | ssh root@<路由器> "mkdir -p /tmp/deps-apk && tar xzf - -C /tmp/deps-apk"
#     ssh root@<路由器> "sh /tmp/deps-apk/install_all.sh"
#
# 环境变量：
#   FM350_VER      固件版本      默认 25.12.1（换版本要同时换一套 SHA256SUMS 与主包）
#   FM350_ABI      kmods ABI     默认 6.12.94-1-0413601b1c3f0490e17f340fe09229ea
#   FM350_MIRRORS  镜像列表（按顺序尝试），默认 NJU → USTC → PKU → 官方
#
# 说明：
#   · 仓库**不含二进制**：包名与 sha256 固定在 SHA256SUMS 里，本脚本按清单逐个下载并校验，
#     只有校验通过才会留下文件（不会留下半成品或被篡改的包）；
#   · 镜像实测：NJU ~350KB/s 且目录列表完整；USTC 快但列表会截断；PKU 很快但目录页是空壳；
#     官方源最全但国内很慢 —— 这里直接按文件名直取，所以四个都能用。
#   · 本项目自身的包（luci-app-fm350-*.apk）由 build/build-apk.sh 编译产出，不在 SHA256SUMS 里。
set -e

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$DIR"

VER="${FM350_VER:-25.12.1}"
ABI="${FM350_ABI:-6.12.94-1-0413601b1c3f0490e17f340fe09229ea}"
MIRRORS="${FM350_MIRRORS:-https://mirror.nju.edu.cn/immortalwrt https://mirrors.ustc.edu.cn/immortalwrt https://mirrors.pku.edu.cn/immortalwrt https://downloads.immortalwrt.org}"

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
		if curl -fsSL --max-time 300 -o "$f.new" "$m/releases/$VER/$rel" 2>/dev/null \
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
if ls ./luci-app-fm350-*.apk >/dev/null 2>&1; then
	echo "== 主包已在本目录 =="
	ls -l ./luci-app-fm350-*.apk
else
	echo "== 还缺主包 luci-app-fm350-*.apk（仓库不含二进制）=="
	echo "   在构建机上编译后把 dist/luci-app-fm350-*.apk 拷到本目录："
	echo "     sh build/build-apk.sh          # 默认 ImmortalWrt SDK 25.12.1"
fi
echo
echo "== 下一步：整个目录传到路由器，再跑 install_all.sh =="
