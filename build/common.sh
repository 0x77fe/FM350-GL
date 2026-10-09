#!/bin/sh
# 构建公共流程：SDK 解析与准备、包编译、产物收集
# 由 build/build-apk.sh 与 build/build-ipk.sh 引用。调用方须先设置：
#   ROOT          仓库根目录
#   FLAVOR        immortalwrt | openwrt
#   VER           SDK / 固件版本
#   FM350_FORMAT  apk | ipk（决定产物文件名）
# 环境变量：
#   FM350_WORK      工作根（缓存 + 解压的 SDK），默认 $HOME/fm350
#   FM350_SDK_DIR   已解压好的 SDK 根目录；给了就直接用，不下载不解压
#   FM350_SDK_BASE  SDK 镜像基址，默认按发行版取（见 sdk_meta）
#   FM350_DIST      产物输出目录，默认 $ROOT/dist

# sdk_meta <flavor> <ver>：输出 "SDK 文件名|sha256|镜像基址"（未知版本留空文件名，由目录页解析）
sdk_meta()
{
	case "$1:$2" in
		immortalwrt:25.12.1) echo "immortalwrt-sdk-25.12.1-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst|02ad8cfc775001ccae8e9282d19696de54e3ab3963f005737ad61f8698263edd|https://mirrors.pku.edu.cn/immortalwrt" ;;
		immortalwrt:24.10.6) echo "immortalwrt-sdk-24.10.6-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst|709bea2ce466b7ad671ce00fdcb1eb69b2b3fa0f0921b12b620725d95cd8c0e5|https://mirrors.pku.edu.cn/immortalwrt" ;;
		openwrt:25.12.5) echo "openwrt-sdk-25.12.5-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst|0c8df0151a1e88feb7c03d694d61f6a18d51872815b7c811d76e2b77504d5e9c|https://downloads.openwrt.org" ;;
		openwrt:24.10.5) echo "openwrt-sdk-24.10.5-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst||https://downloads.openwrt.org" ;;
		immortalwrt:*) echo "||https://downloads.immortalwrt.org" ;;
		openwrt:*) echo "||https://downloads.openwrt.org" ;;
		*) echo "||" ;;
	esac
}

# pkg_field <Makefile 变量名>
pkg_field()
{
	sed -n "s/^$1:=//p" "$ROOT/luci-app-fm350/Makefile"
}

# sdk_ensure：确保 $SDK_DIR 是可用的 SDK（优先复用，其次下载解压）
sdk_ensure()
{
	local meta

	WORK="${FM350_WORK:-$HOME/fm350}"
	DIST="${FM350_DIST:-$ROOT/dist}"
	SDK_DIR="${FM350_SDK_DIR:-$WORK/sdk-$FLAVOR-$VER}"
	meta="$(sdk_meta "$FLAVOR" "$VER")"
	SDK_FILE="$(echo "$meta" | cut -d'|' -f1)"
	SDK_SHA256="$(echo "$meta" | cut -d'|' -f2)"
	SDK_BASE="${FM350_SDK_BASE:-$(echo "$meta" | cut -d'|' -f3)}"
	URL="$SDK_BASE/releases/$VER/targets/x86/64"
	TAR="$WORK/cache/${SDK_FILE:-sdk-$VER.tar.zst}"

	mkdir -p "$WORK/cache" "$WORK/out" "$DIST"
	echo "== 项目根: $ROOT / 输出: $DIST"
	echo "== 发行版: $FLAVOR $VER / SDK 目录: $SDK_DIR"
	[ -n "$SDK_BASE" ] || { echo "未知发行版组合: $FLAVOR $VER（可用 FM350_SDK_BASE 或 FM350_SDK_DIR 指定）"; exit 1; }

	if [ -f "$SDK_DIR/include/package.mk" ]; then
		echo "== SDK 已就绪，跳过下载与解压 =="
		return 0
	fi

	if [ -z "$SDK_FILE" ]; then
		echo "== 未内置 $VER 的 SDK 文件名，从目录页解析 =="
		SDK_FILE="$(wget -qO- "$URL/" | grep -oE "${FLAVOR}-sdk-${VER}-x86-64[^\"]*\.tar\.zst" | head -1)"
		[ -n "$SDK_FILE" ] || { echo "解析 SDK 文件名失败: $URL"; exit 1; }
		TAR="$WORK/cache/$SDK_FILE"
	fi

	if [ ! -s "$TAR" ]; then
		echo "== 下载 SDK（仅首次）: $URL/$SDK_FILE =="
		curl -fL --retry 3 --retry-delay 3 -o "$TAR.part" "$URL/$SDK_FILE"
		mv -f "$TAR.part" "$TAR"
	fi

	if [ -n "$SDK_SHA256" ]; then
		echo "== 校验 SDK sha256 =="
		echo "$SDK_SHA256  $TAR" | sha256sum -c -
	fi

	echo "== 解压 SDK =="
	rm -rf "$SDK_DIR"
	mkdir -p "$SDK_DIR"
	tar --zstd -xf "$TAR" -C "$SDK_DIR" --strip-components=1
	[ -f "$SDK_DIR/include/package.mk" ] || { echo "SDK 目录不完整: $SDK_DIR"; exit 1; }
}

# pkg_build：拷入包源码并编译
pkg_build()
{
	local log

	echo "== 拷入包源码 =="
	rm -rf "$SDK_DIR/package/luci-app-fm350"
	cp -r "$ROOT/luci-app-fm350" "$SDK_DIR/package/luci-app-fm350"

	cd "$SDK_DIR"
	[ -f .config ] || {
		echo "== 生成 .config (defconfig) =="
		make defconfig > "$WORK/out/defconfig-$FLAVOR-$VER.log" 2>&1 \
			|| { tail -20 "$WORK/out/defconfig-$FLAVOR-$VER.log"; exit 1; }
	}

	log="$WORK/out/build-$FM350_FORMAT-$FLAVOR-$VER.log"
	echo "== 编译（日志: $log）=="
	if make package/luci-app-fm350/compile CONFIG_PACKAGE_luci-app-fm350=m V=s > "$log" 2>&1; then
		tail -3 "$log"
	else
		echo "== 编译失败，日志尾部 =="
		tail -60 "$log"
		exit 1
	fi
}

# pkg_collect：按 Makefile 里的版本与 release 取产物到 $DIST
pkg_collect()
{
	local version release artifact found

	version="$(pkg_field PKG_VERSION)"
	release="$(pkg_field PKG_RELEASE)"
	case "$FM350_FORMAT" in
		apk) artifact="luci-app-fm350-${version}-r${release}.apk" ;;
		ipk) artifact="luci-app-fm350_${version}-r${release}_all.ipk" ;;
		*) echo "未知包格式: $FM350_FORMAT"; exit 1 ;;
	esac

	found="$(find "$SDK_DIR/bin/packages" -name "$artifact" | head -1)"
	[ -n "$found" ] || { echo "未生成 $artifact（检查 Makefile 版本与编译日志）"; exit 1; }
	mkdir -p "$DIST"
	cp -f "$found" "$DIST/"
	echo "== 成功: $DIST/$artifact =="
	ls -l "$DIST/$artifact"
	sha256sum "$DIST/$artifact"
}
