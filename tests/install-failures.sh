#!/bin/sh
# Negative and manifest-selection tests with fake package managers; never touches the host
# package database. Run with BusyBox ash on Linux or OpenWrt: sh tests/install-failures.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d /tmp/fm350-install-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/ipk" "$WORK/apk"

# 假包管理器：记录收到的参数，按 FAIL_STAGE 决定成功或失败
cat > "$WORK/bin/opkg" <<'EOF'
#!/bin/sh
echo "$*" >> "$OPKG_ARGS"
case "$1" in
 list-installed) printf 'luci-base 1\nrpcd 1\nlibubox20240329 1\nlibubus20250102 1\n';;
 install)
   case "$2" in *luci-app*) [ "$FAIL_STAGE" != app ] || exit 42;; *) [ "$FAIL_STAGE" != deps ] || exit 1;; esac
 ;;
esac
exit 0
EOF
cat > "$WORK/bin/uname" <<'EOF'
#!/bin/sh
echo 6.6.122
EOF
cat > "$WORK/bin/apk" <<'EOF'
#!/bin/sh
echo "$*" >> "$APK_ARGS"
case "$1 $2" in
 'list -I') printf 'libc-1.2.5-r4\nluci-base-25.12.1\nrpcd-25.12.1\nkernel-6.12.94~0413601b\n';;
esac
case " $* " in *' add '*) [ "$FAIL_STAGE" != apk-install ] || exit 1;; esac
exit 0
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
OPKG_ARGS="$WORK/opkg-args"
APK_ARGS="$WORK/apk-args"
export OPKG_ARGS APK_ARGS
: > "$OPKG_ARGS"
: > "$APK_ARGS"

# 离线目录骨架：安装器在服务操作前截止（[4/6] 之后不执行）
mk_stage() { # $1=ipk|apk
	d="$WORK/$1"
	case "$1" in
		ipk) dep="./kmod-usb-core_6.6.122-r1_x86_64.ipk"; app="./luci-app-fm350_1.0.0-r1_all.ipk" ;;
		apk) dep="./kmod-usb-core-6.12.94-r1.apk"; app="./luci-app-fm350-1.0.0-r1.apk" ;;
	esac
	cp "$ROOT/dist/deps-$1/META" "$d/META"
	cp "$ROOT/dist/deps-$1/install_all.sh" "$d/full.sh"
	sed '/^echo "\[4\/6\]/,$d' "$d/full.sh" > "$d/install.sh"
	echo 'exit 0' >> "$d/install.sh"
	: > "$d/${dep#./}"
	(cd "$d" && sha256sum "./${dep#./}" > SHA256SUMS)
	: > "$d/${app#./}"
	(cd "$d" && sha256sum "./${app#./}" > APP-SHA256SUMS)
}

expect_fail() { # $1=说明 $2=脚本 $3...=环境
	desc="$1"; script="$2"; shift 2
	if env "$@" sh "$script" > "$WORK/log" 2>&1; then
		cat "$WORK/log"; echo "FAIL $desc: 应当失败却成功了"; exit 1
	fi
	echo "PASS $desc"
}

mk_stage ipk
mk_stage apk

# 1) 依赖失败与主包失败：清单齐全时必须真的失败，不能吞掉
expect_fail ipk-deps-failure "$WORK/ipk/install.sh" FAIL_STAGE=deps
expect_fail ipk-app-failure "$WORK/ipk/install.sh" FAIL_STAGE=app
unset FAIL_STAGE

# 2) 主包与清单不符（旧包/损坏包）且未显式放行 → 必须失败并给出放行提示
rm -f "$WORK/ipk/luci-app-fm350_1.0.0-r1_all.ipk"
: > "$WORK/ipk/luci-app-fm350_0.9.9-r1_all.ipk"
printf '%s  ./luci-app-fm350_1.0.0-r1_all.ipk\n' \
	"0000000000000000000000000000000000000000000000000000000000000000" > "$WORK/ipk/APP-SHA256SUMS"
if sh "$WORK/ipk/install.sh" > "$WORK/log" 2>&1; then
	cat "$WORK/log"; echo "FAIL ipk-app-mismatch: 哈希不符仍然装上了"; exit 1
fi
grep -q 'FM350_LOCAL_APP=1' "$WORK/log" || { cat "$WORK/log"; echo "FAIL ipk-app-mismatch: 未提示本地自编包放行方式"; exit 1; }
echo "PASS ipk-app-mismatch"

# 3) 哈希不符 + FM350_LOCAL_APP=1 → 放行，且必须选清单外的最新本地包
: > "$OPKG_ARGS"
FM350_LOCAL_APP=1 sh "$WORK/ipk/install.sh" > "$WORK/log" 2>&1 || { cat "$WORK/log"; echo "FAIL ipk-local-app: 放行后仍失败"; exit 1; }
grep -q 'luci-app-fm350_0.9.9-r1_all.ipk' "$OPKG_ARGS" || { cat "$OPKG_ARGS"; echo "FAIL ipk-local-app: 未安装本地包"; exit 1; }
echo "PASS ipk-local-app"

# 4) 安装文件只取清单内的：清单外的旧依赖包不得出现在安装参数里
: > "$OPKG_ARGS"
: > "$WORK/ipk/kmod-bogus_1.0_x86_64.ipk"
: > "$WORK/ipk/luci-app-fm350_1.0.0-r1_all.ipk"
(cd "$WORK/ipk" && sha256sum ./luci-app-fm350_1.0.0-r1_all.ipk > APP-SHA256SUMS)
sh "$WORK/ipk/install.sh" > "$WORK/log" 2>&1 || { cat "$WORK/log"; echo "FAIL ipk-manifest-only: 运行失败"; exit 1; }
grep -q 'kmod-bogus' "$OPKG_ARGS" && { cat "$OPKG_ARGS"; echo "FAIL ipk-manifest-only: 装上了清单外的包"; exit 1; }
grep -q 'kmod-usb-core_6.6.122-r1_x86_64.ipk' "$OPKG_ARGS" || { cat "$OPKG_ARGS"; echo "FAIL ipk-manifest-only: 未安装清单内的依赖"; exit 1; }
echo "PASS ipk-manifest-only"

# 5) apk 侧同样的清单校验：主包缺失 → 失败；放行后可继续
rm -f "$WORK/apk/luci-app-fm350-1.0.0-r1.apk"
if sh "$WORK/apk/install.sh" > "$WORK/log" 2>&1; then
	cat "$WORK/log"; echo "FAIL apk-app-missing: 缺主包仍然继续"; exit 1
fi
rm -f "$WORK/apk/APP-SHA256SUMS"
: > "$WORK/apk/luci-app-fm350-1.0.0-r2.apk"
: > "$APK_ARGS"
FM350_LOCAL_APP=1 sh "$WORK/apk/install.sh" > "$WORK/log" 2>&1 || { cat "$WORK/log"; echo "FAIL apk-local-app: 放行后仍失败"; exit 1; }
grep -q 'luci-app-fm350-1.0.0-r2.apk' "$APK_ARGS" || { cat "$APK_ARGS"; echo "FAIL apk-local-app: 未安装本地包"; exit 1; }
echo "PASS apk-app-missing-and-local"

# 6) apk 安装失败与缺文件仍返回失败（构建机侧 verify-apk.sh）
export FM350_APK_TOOL="$WORK/bin/apk"
touch "$WORK/test.apk"
for FAIL_STAGE in apk-install missing-files; do
	export FAIL_STAGE
	if sh "$ROOT/build/verify-apk.sh" "$WORK/test.apk" > "$WORK/log" 2>&1; then
		cat "$WORK/log"; echo "FAIL accepted $FAIL_STAGE"; exit 1
	fi
	echo "PASS apk-$FAIL_STAGE"
done

echo "PASS install-failures"
