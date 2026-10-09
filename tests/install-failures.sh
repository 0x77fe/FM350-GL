#!/bin/sh
# POSIX sh negative and manifest-selection tests with fake package managers;
# never touches the host package database. Run with sh or BusyBox ash.
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
   case "$2" in
     *luci-app*) [ "$FAIL_STAGE" != app ] || { echo 'mock-opkg app rejection' >&2; exit 42; };;
     *) [ "$FAIL_STAGE" != deps ] || { echo 'mock-opkg dependency rejection' >&2; exit 1; };;
   esac
 ;;
esac
exit 0
EOF
cat > "$WORK/bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$UNAME_ARGS"
[ "$1" = -r ] || exit 64
echo "$FAKE_KERNEL"
EOF
cat > "$WORK/bin/apk" <<'EOF'
#!/bin/sh
echo "$*" >> "$APK_ARGS"
case "$1 $2" in
 'list -I') printf 'libc-1.2.5-r4\nluci-base-25.12.1\nrpcd-25.12.1\nkernel-6.12.94~0413601b\n';;
esac
case " $* " in
 *' add '*) [ "$FAIL_STAGE" != apk-install ] || { echo 'mock-apk install rejection' >&2; exit 1; };;
esac
exit 0
EOF
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
OPKG_ARGS="$WORK/opkg-args"
APK_ARGS="$WORK/apk-args"
UNAME_ARGS="$WORK/uname-args"
FAKE_KERNEL=6.6.122
export OPKG_ARGS APK_ARGS UNAME_ARGS FAKE_KERNEL
: > "$OPKG_ARGS"
: > "$APK_ARGS"
: > "$UNAME_ARGS"
# The actual UNAME_ARGS assertion below proves installer subprocesses resolve
# the mock; command -v differs across dash, BusyBox ash, and applet builds.

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
	(cd "$d" && sha256sum "./${dep#./}" | sed 's/ \*/  /' > SHA256SUMS)
	: > "$d/${app#./}"
	(cd "$d" && sha256sum "./${app#./}" | sed 's/ \*/  /' > APP-SHA256SUMS)
}

expect_fail() { # $1=说明 $2=脚本 $3=预期错误 $4=日志 $5=install|no_install $6...=环境
	desc="$1"; script="$2"; reason="$3"; manager_log="$4"; action="$5"; shift 5
	: > "$manager_log"
	if env "$@" "PATH=$WORK/bin:$PATH" sh "$script" > "$WORK/log" 2>&1; then
		cat "$WORK/log"; echo "FAIL $desc: 应当失败却成功了"; exit 1
	fi
	grep -F "$reason" "$WORK/log" >/dev/null || { cat "$WORK/log"; echo "FAIL $desc: 未到达预期失败原因 [$reason]"; exit 1; }
	if [ "$action" = install ]; then
		grep -Eq '^(install|add)( |$)' "$manager_log" || { cat "$manager_log"; echo "FAIL $desc: 未调用包安装器"; exit 1; }
	else
		if grep -Eq '^(install|add)( |$)' "$manager_log"; then
			cat "$manager_log"; echo "FAIL $desc: 校验失败前已调用包安装器"; exit 1
		fi
	fi
	echo "PASS $desc"
}

mk_stage ipk
mk_stage apk

# 1) 依赖失败与主包失败：清单齐全时必须真的失败，不能吞掉
expect_fail ipk-deps-failure "$WORK/ipk/install.sh" 'mock-opkg dependency rejection' "$OPKG_ARGS" install FAIL_STAGE=deps
expect_fail ipk-app-failure "$WORK/ipk/install.sh" 'mock-opkg app rejection' "$OPKG_ARGS" install FAIL_STAGE=app
unset FAIL_STAGE
grep -F -- '-r' "$UNAME_ARGS" >/dev/null || { echo 'FAIL uname mock was bypassed'; exit 1; }

# Manifest and META failures must be identified before any package install call.
for kind in ipk apk; do
	case "$kind" in ipk) manager_log="$OPKG_ARGS";; apk) manager_log="$APK_ARGS";; esac
	for state in missing empty malformed mismatch; do
		mk_stage "$kind"
		case "$state" in
			missing) rm -f "$WORK/$kind/SHA256SUMS"; reason='缺失或为空' ;;
			empty) : > "$WORK/$kind/SHA256SUMS"; reason='缺失或为空' ;;
			malformed) printf 'not-a-hash  ./bad.%s\n' "$kind" > "$WORK/$kind/SHA256SUMS"; reason='格式无效' ;;
			mismatch)
				read -r _want dep_path < "$WORK/$kind/SHA256SUMS"
				printf '%064d  %s\n' 0 "$dep_path" > "$WORK/$kind/SHA256SUMS"
				reason='校验失败'
			;;
		esac
		expect_fail "$kind-manifest-$state" "$WORK/$kind/install.sh" "$reason" "$manager_log" no_install
	done
	mk_stage "$kind"
	read -r _want dep_path < "$WORK/$kind/SHA256SUMS"
	printf '%064d  %s\n' 0 "$dep_path" > "$WORK/$kind/SHA256SUMS"
	expect_fail "$kind-local-app-does-not-bypass-deps" "$WORK/$kind/install.sh" '校验失败' "$manager_log" no_install FM350_LOCAL_APP=1
	mk_stage "$kind"
	printf 'FM350_VER=1.0; touch %s\n' "$WORK/meta-injected" > "$WORK/$kind/META"
	expect_fail "$kind-invalid-meta" "$WORK/$kind/install.sh" 'META 格式无效' "$manager_log" no_install
	[ ! -e "$WORK/meta-injected" ] || { echo "FAIL $kind META was executed"; exit 1; }
done

# 2) 主包与清单不符（旧包/损坏包）且未显式放行 → 必须失败并给出放行提示
mk_stage ipk
rm -f "$WORK/ipk/luci-app-fm350_1.0.0-r1_all.ipk"
: > "$WORK/ipk/luci-app-fm350_0.9.9-r1_all.ipk"
printf '%s  ./luci-app-fm350_1.0.0-r1_all.ipk\n' \
	"0000000000000000000000000000000000000000000000000000000000000000" > "$WORK/ipk/APP-SHA256SUMS"
	: > "$OPKG_ARGS"
if env "PATH=$WORK/bin:$PATH" sh "$WORK/ipk/install.sh" > "$WORK/log" 2>&1; then
	cat "$WORK/log"; echo "FAIL ipk-app-mismatch: 哈希不符仍然装上了"; exit 1
fi
grep -q 'FM350_LOCAL_APP=1' "$WORK/log" || { cat "$WORK/log"; echo "FAIL ipk-app-mismatch: 未提示本地自编包放行方式"; exit 1; }
! grep -Eq '^(install|add)( |$)' "$OPKG_ARGS" || { cat "$OPKG_ARGS"; echo "FAIL ipk-app-mismatch: 校验失败前调用了包安装器"; exit 1; }
echo "PASS ipk-app-mismatch"

# 3) 哈希不符 + FM350_LOCAL_APP=1 → 放行，且必须选清单外的最新本地包
: > "$OPKG_ARGS"
FM350_LOCAL_APP=1 env "PATH=$WORK/bin:$PATH" sh "$WORK/ipk/install.sh" > "$WORK/log" 2>&1 || { cat "$WORK/log"; echo "FAIL ipk-local-app: 放行后仍失败"; exit 1; }
grep -q 'luci-app-fm350_0.9.9-r1_all.ipk' "$OPKG_ARGS" || { cat "$OPKG_ARGS"; echo "FAIL ipk-local-app: 未安装本地包"; exit 1; }
echo "PASS ipk-local-app"

# 4) 安装文件只取清单内的：清单外的旧依赖包不得出现在安装参数里
: > "$OPKG_ARGS"
: > "$WORK/ipk/kmod-bogus_1.0_x86_64.ipk"
: > "$WORK/ipk/luci-app-fm350_1.0.0-r1_all.ipk"
(cd "$WORK/ipk" && sha256sum ./luci-app-fm350_1.0.0-r1_all.ipk | sed 's/ \*/  /' > APP-SHA256SUMS)
env "PATH=$WORK/bin:$PATH" sh "$WORK/ipk/install.sh" > "$WORK/log" 2>&1 || { cat "$WORK/log"; echo "FAIL ipk-manifest-only: 运行失败"; exit 1; }
grep -q 'kmod-bogus' "$OPKG_ARGS" && { cat "$OPKG_ARGS"; echo "FAIL ipk-manifest-only: 装上了清单外的包"; exit 1; }
grep -q 'kmod-usb-core_6.6.122-r1_x86_64.ipk' "$OPKG_ARGS" || { cat "$OPKG_ARGS"; echo "FAIL ipk-manifest-only: 未安装清单内的依赖"; exit 1; }
echo "PASS ipk-manifest-only"

# 5) apk 侧同样的清单校验：主包缺失 → 失败；放行后可继续
mk_stage apk
rm -f "$WORK/apk/luci-app-fm350-1.0.0-r1.apk"
if env "PATH=$WORK/bin:$PATH" sh "$WORK/apk/install.sh" > "$WORK/log" 2>&1; then
	cat "$WORK/log"; echo "FAIL apk-app-missing: 缺主包仍然继续"; exit 1
fi
grep -q '主包缺失或与 APP-SHA256SUMS 不符' "$WORK/log" || { cat "$WORK/log"; echo "FAIL apk-app-missing: 未到达主包缺失分支"; exit 1; }
! grep -Eq '^(add)( |$)' "$APK_ARGS" || { cat "$APK_ARGS"; echo "FAIL apk-app-missing: 主包校验前调用了包安装器"; exit 1; }
rm -f "$WORK/apk/APP-SHA256SUMS"
: > "$WORK/apk/luci-app-fm350-1.0.0-r2.apk"
: > "$APK_ARGS"
FM350_LOCAL_APP=1 env "PATH=$WORK/bin:$PATH" sh "$WORK/apk/install.sh" > "$WORK/log" 2>&1 || { cat "$WORK/log"; echo "FAIL apk-local-app: 放行后仍失败"; exit 1; }
grep -q 'luci-app-fm350-1.0.0-r2.apk' "$APK_ARGS" || { cat "$APK_ARGS"; echo "FAIL apk-local-app: 未安装本地包"; exit 1; }
echo "PASS apk-app-missing-and-local"

# 6) apk 安装失败与缺文件仍返回失败（构建机侧 verify-apk.sh）
export FM350_APK_TOOL="$WORK/bin/apk"
touch "$WORK/test.apk"
for FAIL_STAGE in apk-install missing-files; do
	export FAIL_STAGE
	if env "PATH=$WORK/bin:$PATH" sh "$ROOT/build/verify-apk.sh" "$WORK/test.apk" > "$WORK/log" 2>&1; then
		cat "$WORK/log"; echo "FAIL accepted $FAIL_STAGE"; exit 1
	fi
	case "$FAIL_STAGE" in
		apk-install) expected='mock-apk install rejection' ;;
		missing-files) expected='MISSING' ;;
	esac
	grep -F "$expected" "$WORK/log" >/dev/null || { cat "$WORK/log"; echo "FAIL $FAIL_STAGE: 未到达预期失败原因 [$expected]"; exit 1; }
	grep -F ' add ' "$APK_ARGS" >/dev/null || { cat "$APK_ARGS"; echo "FAIL $FAIL_STAGE: verify-apk 未调用安装器"; exit 1; }
	echo "PASS apk-$FAIL_STAGE"
done

echo "PASS install-failures"
