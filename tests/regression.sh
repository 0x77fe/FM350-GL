#!/bin/sh
# Run with BusyBox ash on Linux/OpenWrt. All network/AT actions are mocked.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d /tmp/fm350-test.XXXXXX) || exit 1
trap 'rm -rf "$WORK"' EXIT
LIB="$ROOT/luci-app-fm350/files/usr/lib/fm350"
sed -n '/^# 发现状态/,/^case "\$1" in/{ /^case "\$1" in/d; p; }' "$LIB/fm350.sh" > "$WORK/main.sh"
. "$WORK/main.sh"
. "$LIB/lib/config.sh"
. "$LIB/lib/recover.sh"
RU="$WORK/run"
mkdir -p "$RU"
event() { :; }
fm350_log() { :; }
uci() { return 1; }
action_ifup() { IFUPS=$(( ${IFUPS:-0} + 1 )); }
action_v6_renew() { RENEWS=$(( ${RENEWS:-0} + 1 )); }
action_modem_restart() { RESTARTS=$(( ${RESTARTS:-0} + 1 )); }
action_usb_reset() { RESETS=$(( ${RESETS:-0} + 1 )); }
assert_eq() { [ "$1" = "$2" ] || { echo "expected $2, got $1" >&2; exit 1; }; }
fail() { echo "$*" >&2; exit 1; }
run() { if ( "$1" ); then echo "PASS $1"; else echo "FAIL $1"; exit 1; fi; }

test_frozen_timer() {
	LAST_COUNTER_TS=0; COUNTER_SUM=0
	frozen_elapsed 100 0 && fail 'first sample triggered'
	frozen_elapsed 105 0 && fail 'early trigger'
	frozen_elapsed 125 0 && fail 'early trigger'
	frozen_elapsed 130 0 || fail '30 seconds not accumulated'
	frozen_elapsed 131 1 && fail 'traffic did not reset timer'
	assert_eq "$LAST_COUNTER_TS" 131
	DFLT_USB_RESET_ENABLED=0
	auto_usb_reset 1000 && fail 'disabled reset executed'
	assert_eq "${RESETS:-0}" 0
	DFLT_USB_RESET_ENABLED=1; LAST_USBRESET=900
	auto_usb_reset 1000 && fail 'cooldown bypassed'
	auto_usb_reset 1200 || fail 'eligible reset rejected'
	assert_eq "$RESETS" 1
}

test_recovery_deadlines() {
	R_SINCE=1000; R_LEVEL=0; LAST_RESTART=0; LAST_USBRESET=0
	escalate_v4 1179; assert_eq "$R_LEVEL" 0
	escalate_v4 1180; assert_eq "$R_LEVEL" 1
	escalate_v4 1300; escalate_v4 1305
	assert_eq "$RESTARTS" 1
	escalate_v4 1310; assert_eq "${RESETS:-0}" 0
	escalate_v4 1599; assert_eq "${RESETS:-0}" 0
	escalate_v4 1600; assert_eq "$RESETS" 1
}

test_ipv6_escalation() {
	R_PROBLEM=''; LAST_V6RENEW=0
	escalate_v6 1000 1; escalate_v6 1060 1; escalate_v6 1120 1
	assert_eq "$RENEWS" 3
	assert_eq "${V6_ESCALATED:-0}" 0
	escalate_v6 1180 1
	assert_eq "$R_PROBLEM" v6
	assert_eq "$V6_ESCALATED" 1
	escalate_v6 1480 1; escalate_v6 1485 1
	assert_eq "$RESTARTS" 1
	recover_done; assert_eq "$V6_ESCALATED" 0
}

test_mailbox() {
	enqueue_req disable >/dev/null || fail enqueue
	enqueue_req enable > "$WORK/busy" && fail 'overwrote pending command'
	assert_eq "$(cat "$WORK/busy")" busy
	assert_eq "$(take_req)" disable
	enqueue_req enable >/dev/null || fail enqueue
	assert_eq "$(take_req)" enable
	# Concurrent producers: exactly one succeeds and its payload is retained.
	(enqueue_req disable > "$WORK/p1") & a=$!
	(enqueue_req enable > "$WORK/p2") & b=$!
	wait "$a"; wait "$b"
	assert_eq "$(grep -l '^queued$' "$WORK/p1" "$WORK/p2" | wc -l | tr -d ' ')" 1
	take_req >/dev/null || fail consume
}

test_switch_and_absent_request() {
	uci() { case "$*" in 'set fm350.profile.enable=0') echo disabled > "$WORK/disabled";; esac; return 1; }
	discover_light() { echo discovery >> "$WORK/discovery"; D_USB_PATH=''; }
	write_state() { :; }
	DFLT_ENABLED=0
	cycle
	[ ! -f "$WORK/discovery" ] || fail 'disabled manager probed USB'
	enqueue_req disable >/dev/null
	DFLT_ENABLED=1; D_AT_PORT=''; D_USB_PATH=''
	cycle
	[ -f "$WORK/disabled" ] || fail 'absent disable not consumed'
	[ ! -f "$RU/req" ] || fail 'request retained'
}

test_cycle_ipv6_not_cleared() {
	handle_req() { :; }
	discover_light() { :; }; discover_ifname() { D_IFNAME=lo; }; discover_at_port() { D_AT_PORT=/dev/null; }
	dial_ensure_interfaces() { :; }; probe_counters() { P_RX=0; P_TX=0; }
	probe_v4_at() { echo 10.0.0.2; }; refresh_v4() { :; }
	probe_v4_kernel() { K_V4_ROUTE=1; }
	probe_v6_kernel() { K_V6_ADDR=''; K_V6_ROUTE=0; }
	write_state() { :; }
	DFLT_FROZEN_ENABLED=0
	D_USB_PATH=mock; LAST_USB_PATH=mock; D_IFNAME=lo; D_AT_PORT=/dev/null
	R_PROBLEM=v6; V6_RENEW_COUNT=3; LAST_V6RENEW=0
	cycle
	assert_eq "$R_PROBLEM" v6
	assert_eq "$V6_ESCALATED" 1
}

test_singleton() {
	( singleton_guard; touch "$WORK/locked"; sleep 2 ) & owner=$!
	while [ ! -f "$WORK/locked" ]; do sleep 1; done
	( singleton_guard ) && fail 'second daemon acquired lock'
	wait "$owner"
	( singleton_guard ) || fail 'lock not released on exit'
}

test_serial_mutex() {
	. "$LIB/lib/at.sh"
	sms_tool() {
		mkdir "$WORK/serial-active" || { echo overlap >> "$WORK/overlap"; return 1; }
		sleep 1
		rmdir "$WORK/serial-active"
		echo OK
	}
	(at_run /dev/mock ATI 5 > "$WORK/at1") & a=$!
	(at_run /dev/mock ATI 5 > "$WORK/at2") & b=$!
	wait "$a" || fail 'first AT failed'
	wait "$b" || fail 'second AT failed'
	[ ! -f "$WORK/overlap" ] || fail 'concurrent serial writers'
	assert_eq "$(cat "$WORK/at1")" OK
	assert_eq "$(cat "$WORK/at2")" OK
	assert_eq "$(find "$RU" -name 'at.*' | wc -l | tr -d ' ')" 0
}

# 配置缓存：load_config 之后 fcfg 必须读 uci 的值（而不是全部落到默认值），非法值回退默认
test_config_cache() {
	uci() {
		case "$*" in
			'-q export fm350')
				printf "%s\n" \
					"package fm350" \
					"" \
					"config fm350 'global'" \
					"	option enabled '0'" \
					"	option interval '7'" \
					"	option v4_ifname 'wwan_x9'" \
					"" \
					"config fm350 'profile'" \
					"	option apn 'test.apn'" \
					"	option pdp_type 'ipv4'"
			;;
			*) return 1 ;;
		esac
	}
	CFG_LOADED=""; CFG_RAW=""
	load_config
	assert_eq "$(fcfg global enabled)" 0
	assert_eq "$(fcfg global interval)" 7
	assert_eq "$(fcfg global v4_ifname)" wwan_x9
	assert_eq "$(fcfg profile apn)" test.apn
	assert_eq "$(fcfg profile pdp_type)" ipv4
	# 未配置项仍走默认值
	assert_eq "$(fcfg watch cooldown)" 300

	# 非法值：布尔/数字/接口名/枚举全部回退默认
	uci() {
		case "$*" in
			'-q export fm350')
				printf "%s\n" \
					"config fm350 'global'" \
					"	option enabled '2'" \
					"	option interval 'abc'" \
					"	option v4_ifname 'bad name!'" \
					"config fm350 'profile'" \
					"	option pdp_type 'ipv9'" \
					"	option define_connect '99'"
			;;
			*) return 1 ;;
		esac
	}
	CFG_LOADED=""; CFG_RAW=""
	load_config
	assert_eq "$(fcfg global enabled)" 1
	assert_eq "$(fcfg global interval)" 5
	assert_eq "$(fcfg global v4_ifname)" wwan_5g_0
	assert_eq "$(fcfg profile pdp_type)" ipv4v6
	assert_eq "$(fcfg profile define_connect)" 3

	# 无缓存（CLI 路径）时仍能直接查 uci
	CFG_LOADED=""; CFG_RAW=""
	uci() { [ "$*" = '-q get fm350.global.interval' ] && echo 9; }
	assert_eq "$(fcfg global interval)" 9
	uci() { return 1; }
}

run test_frozen_timer
run test_recovery_deadlines
run test_ipv6_escalation
run test_mailbox
run test_switch_and_absent_request
run test_cycle_ipv6_not_cleared
run test_singleton
run test_serial_mutex
run test_config_cache
