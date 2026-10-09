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
. "$LIB/lib/dial.sh"
. "$LIB/lib/probe.sh"
. "$LIB/lib/discover.sh"
RU="$WORK/run"
mkdir -p "$RU"
. "$LIB/lib/at.sh"
event() { EVENTS="${EVENTS:-}|$1"; }
fm350_log() { :; }
uci() { return 1; }
action_ifup() { IFUPS=$(( ${IFUPS:-0} + 1 )); }
action_v6_renew() { RENEWS=$(( ${RENEWS:-0} + 1 )); }
action_modem_restart() { RESTARTS=$(( ${RESTARTS:-0} + 1 )); }
action_usb_reset() { RESETS=$(( ${RESETS:-0} + 1 )); return "${RESET_RESULT:-0}"; }
assert_eq() { [ "$1" = "$2" ] || { echo "${3:-assert_eq}: expected $2, got $1" >&2; exit 1; }; }
fail() { echo "$*" >&2; exit 1; }
run() { if ( "$1" ); then echo "PASS $1"; else echo "FAIL $1"; exit 1; fi; }
run_lock_test() {
	if command -v flock >/dev/null 2>&1; then
		run "$1"
	else
		echo "SKIP $1 (flock is unavailable in this shell environment)"
	fi
}

test_frozen_timer() {
	LAST_COUNTER_TS=0; COUNTER_SUM=0
	frozen_elapsed 100 0 && fail 'first sample triggered'
	frozen_elapsed 105 0 && fail 'early trigger'
	frozen_elapsed 125 0 && fail 'early trigger'
	frozen_elapsed 130 0 || fail '30 seconds not accumulated'
	frozen_elapsed 131 1 && fail 'traffic did not reset timer'
	assert_eq "$LAST_COUNTER_TS" 131
	DFLT_USB_RESET_ENABLED=0; LAST_USBRESET_ATTEMPT=0; LAST_USBRESET_SUCCESS=77
	auto_usb_reset 1000 && fail 'disabled reset executed'
	assert_eq "${RESETS:-0}" 0
	assert_eq "$LAST_USBRESET_ATTEMPT" 0
	assert_eq "$LAST_USBRESET_SUCCESS" 77
	DFLT_USB_RESET_ENABLED=1; LAST_USBRESET_ATTEMPT=0
	RESET_RESULT=1
	auto_usb_reset 1000 && fail 'failed reset reported success'
	assert_eq "$RESETS" 1
	assert_eq "$LAST_USBRESET_ATTEMPT" 1000
	assert_eq "$LAST_USBRESET_SUCCESS" 77
	RESET_RESULT=0; LAST_USBRESET_ATTEMPT=900
	auto_usb_reset 1000 && fail 'cooldown bypassed'
	auto_usb_reset 1200 || fail 'eligible reset rejected'
	assert_eq "$RESETS" 2
	assert_eq "$LAST_USBRESET_ATTEMPT" 1200
	assert_eq "$LAST_USBRESET_SUCCESS" 1200
}

test_recovery_deadlines() {
	R_SINCE=1000; R_LEVEL=0; LAST_RESTART=0; LAST_USBRESET_ATTEMPT=0
	escalate_v4 1179; assert_eq "$R_LEVEL" 0
	escalate_v4 1180; assert_eq "$R_LEVEL" 1
	escalate_v4 1300; escalate_v4 1305
	assert_eq "$RESTARTS" 1
	escalate_v4 1310; assert_eq "${RESETS:-0}" 0
	escalate_v4 1599; assert_eq "${RESETS:-0}" 0
	escalate_v4 1600; assert_eq "$RESETS" 1
}

test_failed_usb_reset_throttle_and_total_timeout() {
	DFLT_USB_RESET_ENABLED=1; DFLT_COOLDOWN=30; DFLT_USB_RESET_TIMEOUT=60; DFLT_RESTART_TIMEOUT=180
	RESET_RESULT=1; RESETS=0; LAST_USBRESET_ATTEMPT=0; LAST_USBRESET_SUCCESS=77
	R_SINCE=1000; R_LEVEL=3; EVENTS=""
	escalate_v4 1060
	assert_eq "$RESETS" 1
	assert_eq "$LAST_USBRESET_ATTEMPT" 1060
	assert_eq "$LAST_USBRESET_SUCCESS" 77
	escalate_v4 1061
	assert_eq "$RESETS" 1
	escalate_v4 1090
	assert_eq "$RESETS" 2
	assert_eq "$LAST_USBRESET_SUCCESS" 77
	escalate_v4 1180
	assert_eq "$R_SINCE" 1180
	assert_eq "$R_LEVEL" 0
	case "$EVENTS" in *"恢复循环超时"*) ;; *) fail 'total timeout did not alert' ;; esac
	RESET_RESULT=0
}

test_profile_disable_transition_once() {
	D_AT_PORT=/dev/null
	PROFILE_ENABLED_LAST=1
	PROFILE_DISABLE_PENDING=0
	DIAL_STOPS=0
	dial_stop() { DIAL_STOPS=$((DIAL_STOPS + 1)); }
	take_req() {
		[ -f "$RU/req" ] || return 1
		mv "$RU/req" "$RU/req.done" || return 1
		cat "$RU/req.done"
	}
	uci() {
		case "$*" in
			'set fm350.profile.enable=0'|'commit fm350') return 0 ;;
			*) return 1 ;;
		esac
	}
	printf 'disable\n' > "$RU/req"
	handle_req || fail 'disable request was not consumed'
	assert_eq "$DIAL_STOPS" 0
	sync_profile_enable 0
	sync_profile_enable 0
	assert_eq "$DIAL_STOPS" 1
	D_AT_PORT=""; PROFILE_ENABLED_LAST=1; PROFILE_DISABLE_PENDING=0
	sync_profile_enable 0
	assert_eq "$PROFILE_DISABLE_PENDING" 1
	D_AT_PORT=/dev/null
	sync_profile_enable 0
	assert_eq "$DIAL_STOPS" 2
	assert_eq "$PROFILE_DISABLE_PENDING" 0
	sync_profile_enable 1
	sync_profile_enable 0
	assert_eq "$DIAL_STOPS" 3
	uci() { return 1; }
}

test_profile_disable_retry_and_cancel() {
	MOCK_NOW=1000
	date() { [ "$1" = +%s ] && echo "$MOCK_NOW"; }
	PROFILE_ENABLED_LAST=1; PROFILE_DISABLE_PENDING=0; PROFILE_DISABLE_FAILED=0
	LAST_DISABLE_ATTEMPT=0; LAST_DISABLE_LOG=0
	PROFILE_DISABLE_RETRY_INTERVAL=30; PROFILE_DISABLE_LOG_INTERVAL=300
	D_AT_PORT=/dev/null; DIAL_STOPS=0; EVENTS=""
	DIAL_STOP_RESULT=1
	dial_stop() {
		DIAL_STOPS=$((DIAL_STOPS + 1))
		DIAL_STOP_REASON="mock AT ERROR"
		return "$DIAL_STOP_RESULT"
	}
	sync_profile_enable 0 0
	assert_eq "$PROFILE_DISABLE_PENDING" 1
	assert_eq "$DIAL_STOPS" 0
	sync_profile_enable 0 1
	assert_eq "$PROFILE_DISABLE_PENDING" 1
	assert_eq "$PROFILE_DISABLE_FAILED" 1
	assert_eq "$DIAL_STOPS" 1
	case "$EVENTS" in *"mock AT ERROR"*) ;; *) fail 'disconnect failure reason was not logged' ;; esac
	FIRST_EVENTS="$EVENTS"
	MOCK_NOW=1005
	sync_profile_enable 0 1
	assert_eq "$DIAL_STOPS" 1
	assert_eq "$EVENTS" "$FIRST_EVENTS"
	MOCK_NOW=1030; DIAL_STOP_RESULT=0
	sync_profile_enable 0 1
	assert_eq "$PROFILE_DISABLE_PENDING" 0
	assert_eq "$PROFILE_DISABLE_FAILED" 0
	assert_eq "$DIAL_STOPS" 2
	sync_profile_enable 0 1
	assert_eq "$DIAL_STOPS" 2
	MOCK_NOW=1100; DIAL_STOP_RESULT=1
	PROFILE_ENABLED_LAST=1; PROFILE_DISABLE_PENDING=0
	sync_profile_enable 0 0
	assert_eq "$PROFILE_DISABLE_PENDING" 1
	sync_profile_enable 1 0
	assert_eq "$PROFILE_DISABLE_PENDING" 0
	assert_eq "$PROFILE_DISABLE_FAILED" 0
	MOCK_NOW=1200
	sync_profile_enable 1 1
	assert_eq "$DIAL_STOPS" 2
}

test_dial_stop_requires_successful_at_response() {
	fcfg() {
		case "$1.$2" in
			profile.define_connect) echo 3 ;;
			global.v4_ifname) echo fm350v4 ;;
			global.v6_ifname) echo fm350v6 ;;
			*) echo "" ;;
		esac
	}
	AT_FAIL=1; IF_DOWNS=0
	at_run() {
		if [ "$AT_FAIL" = "1" ]; then printf ' ERROR \r\nOK\r\n'; else printf 'OK\r\n'; fi
		return 0
	}
	ifdown() { IF_DOWNS=$((IF_DOWNS + 1)); }
	if dial_stop /dev/null; then fail 'AT ERROR plus OK reported successful disconnect'; fi
	case "$DIAL_STOP_REASON" in *ERROR*) ;; *) fail 'dial_stop omitted AT error reason' ;; esac
	assert_eq "$IF_DOWNS" 0
	AT_FAIL=0
	dial_stop /dev/null || fail 'valid OK response did not complete disconnect'
	assert_eq "$IF_DOWNS" 1
}

test_profile_disconnect_state_json() {
	command -v jq >/dev/null 2>&1 || { echo 'SKIP test_profile_disconnect_state_json (jq unavailable)'; return 0; }
	RU="$WORK/profile-state"; mkdir -p "$RU"
	fcfg() {
		case "$1.$2" in
			global.enabled|profile.enable) echo 0 ;;
			watch.ca_interval) echo 120 ;;
			*) echo 0 ;;
		esac
	}
	R_PROBLEM=disabled; R_SINCE=0; R_LEVEL=0; D_USB_PATH=""; D_DEVNODE=""; D_IFNAME=""; D_AT_PORT=""
	V4_AT=""; K_V4_ADDR=""; K_V4_ROUTE=0; K_V6_ADDR=""; K_V6_ROUTE=0; K_V6_GW=""
	P_RX=0; P_TX=0; ONLINE_SINCE=0; ABSENT_SINCE=0; SESS_SINCE=0
	SNAP_ATI=""; SNAP_CPIN=""; SNAP_COPS=""; SNAP_CELL='{}'; SNAP_CA='{}'
	SNAP_AT_TS=0; SNAP_CELL_TS=0; SNAP_CA_TS=0
	PROFILE_DISABLE_PENDING=1; PROFILE_DISABLE_FAILED=0; LAST_DISABLE_ATTEMPT=0
	write_state
	assert_eq "$(jq -r .profile.disconnect_status "$RU/state.json")" pending
	PROFILE_DISABLE_FAILED=1
	write_state
	assert_eq "$(jq -r .profile.disconnect_status "$RU/state.json")" failed
	PROFILE_DISABLE_PENDING=0; PROFILE_DISABLE_FAILED=0
	write_state
	assert_eq "$(jq -r .profile.disconnect_status "$RU/state.json")" disabled
}

test_session_grace_only_on_success() {
	. "$LIB/lib/recover.sh"
	DIAL_RESULT=1
	dial_now() { return "$DIAL_RESULT"; }
	SESS_SINCE=123
	dial_attempt /dev/null 1000 && fail 'failed dial reported success'
	assert_eq "$LAST_DIAL" 1000
	assert_eq "$SESS_SINCE" 123
	DIAL_RESULT=0
	dial_attempt /dev/null 1001 || fail 'successful dial rejected'
	[ "$SESS_SINCE" -gt 123 ] || fail 'successful dial did not start grace period'
	DIAL_RESULT=1
	at_check() { return "$DIAL_RESULT"; }
	sleep() { :; }
	action_ifup() { return 0; }
	SESS_SINCE=123
	action_modem_restart /dev/null && fail 'failed modem restart reported success'
	assert_eq "$SESS_SINCE" 123
	[ "$LAST_RESTART" -gt 0 ] || fail 'failed modem restart attempt time not recorded'
	DIAL_RESULT=0
	action_modem_restart /dev/null || fail 'successful modem restart rejected'
	[ "$SESS_SINCE" -gt 123 ] || fail 'successful modem restart did not start grace period'
	SESS_SINCE=123; LAST_USBRESET_SUCCESS=77
	usb_reset_device() { return 1; }
	action_usb_reset mock '' && fail 'failed USB reset reported success'
	assert_eq "$SESS_SINCE" 123
	assert_eq "$LAST_USBRESET_SUCCESS" 77
	[ "$LAST_USBRESET_ATTEMPT" -gt 0 ] || fail 'failed USB reset attempt time not recorded'
	usb_reset_device() { return 0; }
	action_usb_reset mock '' || fail 'successful USB reset rejected'
	[ "$SESS_SINCE" -gt 123 ] || fail 'successful USB reset did not start grace period'
	[ "$LAST_USBRESET_SUCCESS" -gt 77 ] || fail 'USB reset success time was not recorded'
	sleep() { command sleep "$@"; }
	unset DIAL_RESULT
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
	take_req() {
		[ -f "$RU/req" ] || return 1
		mv "$RU/req" "$RU/req.done" || return 1
		cat "$RU/req.done"
	}
	discover_light() { echo discovery >> "$WORK/discovery"; D_USB_PATH=''; }
	write_state() { :; }
	DFLT_ENABLED=0
	cycle
	[ ! -f "$WORK/discovery" ] || fail 'disabled manager probed USB'
	printf 'disable\n' > "$RU/req"
	DFLT_ENABLED=1; D_AT_PORT=''; D_USB_PATH=''
	cycle
	[ -f "$WORK/disabled" ] || fail 'absent disable not consumed'
	[ ! -f "$RU/req" ] || fail 'request retained'
}

test_cycle_ipv6_snapshots_not_gated_by_escalation() {
	handle_req() { :; }
	discover_light() { :; }; discover_ifname() { D_IFNAME=lo; }; discover_at_port() { D_AT_PORT=/dev/null; }
	dial_ensure_interfaces() { :; }; probe_counters() { P_RX=0; P_TX=0; }
	probe_v4_at() { echo 10.0.0.2; }; refresh_v4() { :; }
	probe_v4_kernel() { K_V4_ROUTE=1; }
	probe_v6_kernel() { K_V6_ADDR=''; K_V6_ROUTE=0; }
	escalate_v6() { R_PROBLEM=v6; V6_ESCALATED="${MOCK_V6_ESCALATED:-0}"; }
	refresh_snapshots() { SNAP_REFRESHES=$((SNAP_REFRESHES + 1)); }
	write_state() { :; }
	fcfg() {
		case "$1.$2" in
			global.enabled|profile.enable) echo 1 ;;
			watch.frozen_enabled) echo 0 ;;
			watch.ipv6_check_enabled) echo 1 ;;
			*) echo "" ;;
		esac
	}
	DFLT_FROZEN_ENABLED=0
	D_USB_PATH=mock; LAST_USB_PATH=mock; D_IFNAME=lo; D_AT_PORT=/dev/null
	R_PROBLEM=v6; V6_RENEW_COUNT=0; LAST_V6RENEW=$(date +%s)
	SNAP_REFRESHES=0; MOCK_V6_ESCALATED=0; PROFILE_ENABLED_LAST=1
	cycle
	assert_eq "$R_PROBLEM" v6
	assert_eq "$V6_ESCALATED" 0
	assert_eq "$SNAP_REFRESHES" 1
	MOCK_V6_ESCALATED=1
	cycle
	assert_eq "$R_PROBLEM" v6
	assert_eq "$SNAP_REFRESHES" 2
	uci() { return 1; }
	. "$LIB/lib/config.sh"
	. "$WORK/main.sh"
	. "$LIB/lib/discover.sh"
	. "$LIB/lib/dial.sh"
}

test_disabled_profile_does_not_redial_when_device_returns() {
	MOCK_PROFILE=0; AUTO_DIALS=0; DIAL_STOPS=0
	fcfg() {
		case "$1.$2" in
			global.enabled) echo 1 ;;
			profile.enable) echo "$MOCK_PROFILE" ;;
			*) echo "" ;;
		esac
	}
	load_config() { :; }
	handle_req() { :; }
	discover_light() { return 0; }
	discover_ifname() { D_IFNAME=lo; }
	discover_at_port() { D_AT_PORT=/dev/null; }
	dial_stop() { DIAL_STOPS=$((DIAL_STOPS + 1)); }
	dial_ensure_interfaces() { AUTO_DIALS=$((AUTO_DIALS + 1)); }
	write_state() { :; }
	D_USB_PATH=mock; LAST_USB_PATH=mock; D_IFNAME=""; D_AT_PORT=""
	PROFILE_ENABLED_LAST=1; PROFILE_DISABLE_PENDING=0
	cycle
	assert_eq "$DIAL_STOPS" 1
	assert_eq "$AUTO_DIALS" 0
	cycle
	assert_eq "$DIAL_STOPS" 1
	assert_eq "$AUTO_DIALS" 0
	uci() { return 1; }
	. "$LIB/lib/config.sh"
}

test_profile_disable_intent_survives_device_absence() {
	local present
	MOCK_PROFILE=0; present=0; DIAL_STOPS=0; AUTO_DIALS=0
	fcfg() {
		case "$1.$2" in
			global.enabled) echo 1 ;;
			profile.enable) echo "$MOCK_PROFILE" ;;
			watch.frozen_enabled|watch.ipv6_check_enabled) echo 0 ;;
			watch.reappear_timeout) echo 300 ;;
			*) echo "" ;;
		esac
	}
	load_config() { :; }
	handle_req() { :; }
	discover_light() {
		if [ "$present" = "1" ]; then D_USB_PATH=mock; return 0; fi
		D_USB_PATH=""
		return 1
	}
	discover_ifname() { D_IFNAME=lo; }
	discover_at_port() { D_AT_PORT=/dev/null; }
	dial_stop() { DIAL_STOPS=$((DIAL_STOPS + 1)); }
	dial_ensure_interfaces() { AUTO_DIALS=$((AUTO_DIALS + 1)); }
	write_state() { :; }
	D_USB_PATH=""; D_IFNAME=""; D_AT_PORT=""; LAST_USB_PATH=""
	ABSENT_SINCE=0; PROFILE_ENABLED_LAST=1; PROFILE_DISABLE_PENDING=0; PROFILE_DISABLE_FAILED=0
	cycle
	assert_eq "$PROFILE_DISABLE_PENDING" 1
	assert_eq "$DIAL_STOPS" 0
	present=1
	cycle
	assert_eq "$PROFILE_DISABLE_PENDING" 0
	assert_eq "$DIAL_STOPS" 1
	assert_eq "$AUTO_DIALS" 0
	cycle
	assert_eq "$DIAL_STOPS" 1
	uci() { return 1; }
	. "$LIB/lib/config.sh"
}

test_ipv6_escalated_sampling_recovers_with_serial() {
	local base now
	fcfg() {
		case "$1.$2" in
			watch.ipv6_escalate) echo 1 ;;
			watch.wait_timeout) echo 30 ;;
			watch.recovery_timeout) echo 30 ;;
			watch.usb_reset_timeout) echo 60 ;;
			watch.restart_timeout) echo 60 ;;
			watch.cooldown) echo 30 ;;
			watch.ca_check_enabled) echo 0 ;;
			watch.ca_interval) echo 120 ;;
			global.enabled|profile.enable) echo 1 ;;
			*) echo "" ;;
		esac
	}
	base=$(date +%s)
	R_PROBLEM=v6; R_SINCE=$base; R_LEVEL=0; V6_RENEW_COUNT=0; LAST_V6RENEW=0; V6_ESCALATED=0
	RENEWS=0
	action_v6_renew() { RENEWS=$((RENEWS + 1)); return 1; }
	escalate_v6 "$base" 1
	escalate_v6 "$((base + 60))" 1
	escalate_v6 "$((base + 120))" 1
	escalate_v6 "$((base + 180))" 1
	assert_eq "$RENEWS" 3
	assert_eq "$R_PROBLEM" v6
	assert_eq "$V6_ESCALATED" 1
	assert_eq "$R_LEVEL" 1

	now=$(date +%s)
	D_AT_PORT=/dev/null; SNAP_SERIAL_READY=0; LAST_SERIAL_PROBE=0
	LAST_SNAP=0; LAST_CELL=$now; LAST_CA=$now
	SNAP_ATI=old; SNAP_CPIN=old; SNAP_COPS=old; SNAP_AT_TS=1
	SERIAL_PAUSE_UNTIL=$((now + 30)); AT_CALLS=0
	at_run() {
		AT_CALLS=$((AT_CALLS + 1))
		case "$2" in
			ATI) printf 'FM350-GL\r\n' ;;
			'AT+CPIN?') printf '+CPIN: READY\r\nOK\r\n' ;;
			'AT+COPS?') printf '+COPS: 0,0,"Carrier",7\r\nOK\r\n' ;;
			*) printf 'OK\r\n' ;;
		esac
		return 0
	}
	refresh_snapshots "$now" 3 && fail 'snapshot sampling ran during serial reset wait'
	assert_eq "$AT_CALLS" 0
	assert_eq "$R_PROBLEM" v6

	SERIAL_PAUSE_UNTIL=$((now - 1))
	refresh_snapshots "$((now + 1))" 3 || fail 'sampling did not resume after serial returned'
	assert_eq "$SNAP_SERIAL_READY" 1
	assert_eq "$SNAP_ATI" "FM350-GL"
	case "$SNAP_CPIN" in *READY*) ;; *) fail 'CPIN snapshot was not refreshed' ;; esac
	assert_eq "$R_PROBLEM" v6

	R_SINCE=$((now - 60)); R_LEVEL=3; V6_ESCALATED=1
	escalate_v4 "$((now + 1))"
	assert_eq "$R_LEVEL" 0
	assert_eq "$V6_ESCALATED" 1
	LAST_SNAP=$((now - 40))
	refresh_snapshots "$((now + 2))" 3 || fail 'snapshot did not continue after overall timeout'
	assert_eq "$SNAP_AT_TS" "$((now + 2))"
	assert_eq "$R_PROBLEM" v6
	if command -v jq >/dev/null 2>&1; then
		RU="$WORK/v6-state"; mkdir -p "$RU"
		D_USB_PATH=mock; D_IFNAME=lo; D_AT_PORT=/dev/null; V4_AT=10.0.0.2
		D_DEVNODE=""; D_VID=""; D_PID=""; K_V4_ADDR=10.0.0.2; K_V4_ROUTE=1; K_V6_ADDR=""; K_V6_ROUTE=0; K_V6_GW=""
		P_RX=0; P_TX=0; ONLINE_SINCE=0; ABSENT_SINCE=0; SESS_SINCE=0
		write_state
		assert_eq "$(jq -r .state "$RU/state.json")" RECOVERING
	else
		echo 'SKIP v6 RECOVERING state assertion (jq unavailable)'
	fi
}

test_discovery_clears_stale_cache_during_scan_cooldown() {
	fcfg() { [ "$1.$2" = global.usb_vid_pid ] && echo ""; }
	D_USB_PATH=gone; D_DEVNODE=/dev/bus/usb/001/009; D_IFNAME=eth9; D_AT_PORT=/dev/ttyUSB9
	D_VID=1234; D_PID=abcd; D_USB_COUNT=1
	date +%s > "$RU/at_probe.last"
	discover_light && fail 'scan cooldown unexpectedly succeeded'
	assert_eq "$D_USB_PATH" ""
	assert_eq "$D_DEVNODE" ""
	assert_eq "$D_IFNAME" ""
	assert_eq "$D_AT_PORT" ""
	assert_eq "$D_VID" ""
	assert_eq "$D_PID" ""
	. "$LIB/lib/config.sh"
}

test_default_route_parsing() {
	ip() {
		case "$*" in
			'-4 addr show dev eth2') echo 'inet 10.0.0.2/24 scope global eth2' ;;
			'-6 addr show dev wwan6') echo 'inet6 2001:db8::2/64 scope global' ;;
			'-4 route show default') printf '%s\n' "$MOCK_ROUTES4" ;;
			'-6 route show default') printf '%s\n' "$MOCK_ROUTES6" ;;
			*) return 1 ;;
		esac
	}
	MOCK_ROUTES4=$(printf '%s\n' 'default via 192.0.2.20 dev eth20 metric 10' 'default via 192.0.2.2 dev eth2 metric 20')
	probe_v4_kernel eth2
	assert_eq "$K_V4_ROUTE" 1
	assert_eq "$K_V4_GW" 192.0.2.2
	MOCK_ROUTES4='default via 192.0.2.20 dev eth20'
	probe_v4_kernel eth2
	assert_eq "$K_V4_ROUTE" 0
	assert_eq "$K_V4_GW" ""
	MOCK_ROUTES4='default dev eth2 scope link'
	probe_v4_kernel eth2
	assert_eq "$K_V4_ROUTE" 1
	assert_eq "$K_V4_GW" ""
	MOCK_ROUTES6=$(printf '%s\n' 'default from 2001:db8:1::/64 via fe80::1 dev wwan6 metric 10' 'default from 2001:db8:2::/64 via fe80::2 dev wwan60 metric 20')
	probe_v6_kernel wwan6
	assert_eq "$K_V6_ROUTE" 1
	assert_eq "$K_V6_GW" fe80::1
	MOCK_ROUTES6='default dev wwan6 metric 1024'
	probe_v6_kernel wwan6
	assert_eq "$K_V6_ROUTE" 1
	assert_eq "$K_V6_GW" ""
	MOCK_ROUTES6='default via fe80::2 dev wwan60'
	probe_v6_kernel wwan6
	assert_eq "$K_V6_ROUTE" 0
	assert_eq "$K_V6_GW" ""
}

test_interface_reconciliation_includes_ipv6() {
	IF_V4=fm350v4; IF_V6=fm350v6; IF_ALIAS=1; IF_DEVICE=eth2
	NET_DB="$WORK/network-db"; NET_WRITES="$WORK/net-writes"; IFDOWNS="$WORK/ifdowns"
	: > "$NET_DB"; : > "$NET_WRITES"; : > "$IFDOWNS"; NETWORK_RELOADS=0; EVENTS=""
	db_set() {
		local key="$1" value="$2" tmp="$NET_DB.new"
		awk -F= -v k="$key" '$1 != k { print }' "$NET_DB" > "$tmp"
		printf '%s=%s\n' "$key" "$value" >> "$tmp"
		mv "$tmp" "$NET_DB"
	}
	db_get() {
		awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; found=1 } END { if (!found) exit 1 }' "$NET_DB"
	}
	fcfg() {
		case "$1.$2" in
			global.v4_ifname) echo "$IF_V4" ;;
			global.v6_ifname) echo "$IF_V6" ;;
			global.v6_alias) echo "$IF_ALIAS" ;;
			global.managed_v4_ifname) db_get fm350.global.managed_v4_ifname ;;
			global.managed_v6_ifname) db_get fm350.global.managed_v6_ifname ;;
			global.enabled|profile.enable) echo 1 ;;
			profile.define_connect) echo 3 ;;
			watch.frozen_enabled|watch.ipv6_check_enabled|watch.ca_check_enabled) echo 0 ;;
			*) echo "" ;;
		esac
	}
	uci() {
		local key value tmp old token result
		if [ "$1" = -q ] && [ "$2" = get ]; then
			db_get "$3"; return $?
		elif [ "$1" = -q ] && [ "$2" = delete ]; then
			key="$3"; echo "delete $key" >> "$NET_WRITES"; tmp="$NET_DB.new"
			awk -F= -v k="$key" '$1 != k && index($1, k ".") != 1 { print }' "$NET_DB" > "$tmp"
			mv "$tmp" "$NET_DB"; return 0
		elif [ "$1" = -q ] && [ "$2" = del_list ]; then
			key=${3%%=*}; value=${3#*=}; old=$(db_get "$key" 2>/dev/null || true); result=""
			for token in $old; do [ "$token" = "$value" ] || result="${result:+$result }$token"; done
			echo "del_list $key=$value" >> "$NET_WRITES"; db_set "$key" "$result"; return 0
		elif [ "$1" = -q ] && [ "$2" = add_list ]; then
			key=${3%%=*}; value=${3#*=}; old=$(db_get "$key" 2>/dev/null || true)
			case " $old " in *" $value "*) ;; *) old="${old:+$old }$value" ;; esac
			echo "add_list $key=$value" >> "$NET_WRITES"; db_set "$key" "$old"; return 0
		elif [ "$1" = add_list ]; then
			key=${2%%=*}; value=${2#*=}; old=$(db_get "$key" 2>/dev/null || true)
			case " $old " in *" $value "*) ;; *) old="${old:+$old }$value" ;; esac
			echo "add_list $key=$value" >> "$NET_WRITES"; db_set "$key" "$old"; return 0
		elif [ "$1" = get ]; then
			db_get "$2"; return $?
		elif [ "$1" = show ] && [ "$2" = firewall ]; then
			echo "firewall.wan_zone.name='wan'"; return 0
		elif [ "$1" = set ]; then
			key=${2%%=*}; value=${2#*=}
			echo "set $key=$value" >> "$NET_WRITES"; db_set "$key" "$value"; return 0
		elif [ "$1" = commit ]; then
			echo "commit $2" >> "$NET_WRITES"; return 0
		fi
		return 1
	}
	service() { NETWORK_RELOADS=$((NETWORK_RELOADS + 1)); }
	ifdown() { echo "$1" >> "$IFDOWNS"; }
	seed_managed_pair() {
		db_set "network.$1" interface; db_set "network.$1.proto" static
		db_set "network.$1.device" "$IF_DEVICE"; db_set "network.$1.ifname" "$IF_DEVICE"; db_set "network.$1.peerdns" 0
		db_set "network.$2" interface; db_set "network.$2.proto" dhcpv6
		db_set "network.$2.extendprefix" 1; db_set "network.$2.device" "$3"; db_set "network.$2.ifname" "$3"
	}
	seed_managed_pair fm350v4 fm350v6 @fm350v4
	db_set firewall.wan_zone.name wan; db_set firewall.wan_zone.network 'fm350v4 fm350v6'
	dial_ensure_interfaces eth2 || fail 'initial managed pair reconciliation failed'
	assert_eq "$(db_get fm350.global.managed_v4_ifname)" fm350v4
	assert_eq "$(db_get fm350.global.managed_v6_ifname)" fm350v6
	assert_eq "$NETWORK_RELOADS" 0

	: > "$NET_WRITES"
	dial_ensure_interfaces eth2 || fail 'idempotent reconciliation failed'
	assert_eq "$(grep -c '^commit network$' "$NET_WRITES" || true)" 0
	assert_eq "$NETWORK_RELOADS" 0

	IF_ALIAS=0
	dial_ensure_interfaces eth2 || fail 'alias toggle failed'
	assert_eq "$(db_get network.fm350v6.device)" eth2
	assert_eq "$NETWORK_RELOADS" 1
	grep -Fx fm350v6 "$IFDOWNS" >/dev/null || fail 'alias change did not stop the old DHCPv6 client'

	IF_V6=wwan6_new
	dial_ensure_interfaces eth2 || {
		cat "$NET_WRITES" >&2
		echo "EVENTS=$EVENTS" >&2
		fail 'IPv6 rename failed'
	}
	assert_eq "$(db_get network.fm350v6 2>/dev/null || echo missing)" missing
	assert_eq "$(db_get network.wwan6_new.proto)" dhcpv6
	assert_eq "$(db_get fm350.global.managed_v6_ifname)" wwan6_new
	case "$(db_get firewall.wan_zone.network)" in *fm350v6*) fail 'old IPv6 firewall reference remained' ;; esac
	assert_eq "$NETWORK_RELOADS" 2

	IF_ALIAS=1; IF_V4=wwan_new
	dial_ensure_interfaces eth2 || fail 'IPv4 rename with alias update failed'
	assert_eq "$(db_get network.fm350v4 2>/dev/null || echo missing)" missing
	assert_eq "$(db_get network.wwan_new.proto)" static
	assert_eq "$(db_get network.wwan6_new.device)" @wwan_new
	assert_eq "$(db_get fm350.global.managed_v4_ifname)" wwan_new
	assert_eq "$NETWORK_RELOADS" 3
	: > "$NET_WRITES"
	dial_ensure_interfaces eth2 || fail 'managed ownership was not retained across daemon restart'
	assert_eq "$(grep -c '^commit network$' "$NET_WRITES" || true)" 0
	assert_eq "$NETWORK_RELOADS" 3

	db_set network.lan interface; db_set network.lan.proto static
	db_set network.lan.device br-lan; db_set network.lan.ifname br-lan; db_set network.lan.peerdns 0
	IF_V6=lan
	: > "$NET_WRITES"; before_reload=$NETWORK_RELOADS
	dial_ensure_interfaces eth2 && fail 'unowned interface conflict was accepted'
	assert_eq "$(grep -c '^delete network\.' "$NET_WRITES" || true)" 0
	assert_eq "$NETWORK_RELOADS" "$before_reload"
	case "$EVENTS" in *'接口配置冲突'*) ;; *) fail 'interface conflict did not warn' ;; esac

	# Exercise the real main loop as well as the interface reconciler: a rejected
	# LAN target must not be overwritten later by refresh_v4 or recovery actions.
	IF_V4=lan; IF_V6=wwan6_new
	db_set network.lan.ipaddr 192.168.4.1
	: > "$NET_WRITES"; : > "$IFDOWNS"
	PROBE_LOG="$WORK/conflict-probes"; : > "$PROBE_LOG"
	load_config() { :; }
	handle_req() { return 1; }
	discover_light() { return 0; }
	discover_ifname() { D_IFNAME="$IF_DEVICE"; }
	discover_at_port() { D_AT_PORT=/dev/null; }
	probe_counters() { echo counters >> "$PROBE_LOG"; P_RX=0; P_TX=0; }
	probe_v4_at() { echo address >> "$PROBE_LOG"; echo 10.20.30.40; }
	probe_v4_kernel() { K_V4_ROUTE=1; }
	fibocom_dns_v4() { echo 223.5.5.5; }
	refresh_snapshots() { :; }
	ifup() { echo "ifup $*" >> "$PROBE_LOG"; }
	write_state() { OBSERVED_PROBLEM="$R_PROBLEM"; }
	D_USB_PATH=mock; LAST_USB_PATH=mock; D_IFNAME="$IF_DEVICE"; D_AT_PORT=/dev/null
	D_VID=""; D_PID=""; ABSENT_SINCE=0; R_PROBLEM=""; PROFILE_ENABLED_LAST=1
	cycle || fail 'conflicting interface cycle failed unexpectedly'
	assert_eq "$(db_get network.lan.ipaddr)" 192.168.4.1
	assert_eq "$(db_get network.lan.device)" br-lan
	assert_eq "$(wc -l < "$NET_WRITES" | tr -d ' ')" 0
	assert_eq "$(wc -l < "$IFDOWNS" | tr -d ' ')" 0
	assert_eq "$(wc -l < "$PROBE_LOG" | tr -d ' ')" 0
	assert_eq "$NETWORK_RELOADS" "$before_reload"
	assert_eq "$OBSERVED_PROBLEM" config
	IF_V4=wwan_new
	cycle || fail 'corrected interface configuration did not resume management'
	assert_eq "$OBSERVED_PROBLEM" ""
	assert_eq "$(db_get network.wwan_new.ipaddr)" 10.20.30.40
	assert_eq "$(db_get network.lan.ipaddr)" 192.168.4.1
	grep -Fx address "$PROBE_LOG" >/dev/null || fail 'AT probing did not resume after correcting configuration'
	# A same-name device section is also a conflict, not an absent interface.
	db_set network.user_device device
	IF_V4=user_device
	: > "$NET_WRITES"; : > "$PROBE_LOG"
	before_reload=$NETWORK_RELOADS
	cycle || fail 'non-interface target cycle failed unexpectedly'
	assert_eq "$(db_get network.user_device)" device
	assert_eq "$(wc -l < "$NET_WRITES" | tr -d ' ')" 0
	assert_eq "$(wc -l < "$PROBE_LOG" | tr -d ' ')" 0
	assert_eq "$NETWORK_RELOADS" "$before_reload"
	assert_eq "$OBSERVED_PROBLEM" config

	: > "$NET_DB"; : > "$NET_WRITES"; : > "$IFDOWNS"; EVENTS=""
	IF_V4=custom4; IF_V6=custom6; IF_ALIAS=1
	seed_managed_pair wwan_5g_0 wwan6_5g_0 @wwan_5g_0
	dial_ensure_interfaces eth2 || fail 'conservative legacy migration failed'
	assert_eq "$(db_get network.wwan_5g_0.proto)" static
	assert_eq "$(db_get network.wwan6_5g_0.proto)" dhcpv6
	assert_eq "$(grep -c '^delete network\.wwan' "$NET_WRITES" || true)" 0
	case "$EVENTS" in *'未登记归属'*) ;; *) fail 'legacy unowned interfaces were not reported' ;; esac
	uci() { return 1; }
	. "$LIB/lib/config.sh"
}

test_snapshot_failure_clears_stale_values() {
	D_AT_PORT=/dev/null
	LAST_SNAP=0; LAST_CELL=0; LAST_CA=0
	SNAP_ATI=old; SNAP_CPIN=old; SNAP_COPS=old; SNAP_CELL='{"rsrp":"-90"}'; SNAP_CA='{"pcc_band":"78"}'
	SNAP_AT_TS=1; SNAP_CELL_TS=1; SNAP_CA_TS=1
	at_run() { return 1; }
	fibocom_cellinfo() { CL_MCC=""; CL_RSRP=""; CL_RAW=""; return 1; }
	fibocom_cesq() { SS_SINR=""; return 1; }
	fibocom_cainfo() { CA_JSON=""; return 1; }
	refresh_snapshots "$(date +%s)" 3
	assert_eq "$SNAP_ATI$SNAP_CPIN$SNAP_COPS" ""
	assert_eq "$SNAP_CELL" '{}'
	assert_eq "$SNAP_CA" '{}'
	[ "$SNAP_AT_TS" -gt 1 ] || fail 'AT failure timestamp not updated'
	[ "$SNAP_CELL_TS" -gt 1 ] || fail 'cell failure timestamp not updated'
	[ "$SNAP_CA_TS" -gt 1 ] || fail 'CA failure timestamp not updated'
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

test_at_response_classification() {
	local response
	response=$(printf '  ERROR  \r\n')
	assert_eq "$(at_response_class "$response")" error at-error-whitespace-crlf
	assert_eq "$(at_response_class "$(printf '+CME ERROR: 10\r\nOK\r\n')")" error at-cme-error-plus-ok
	assert_eq "$(at_response_class "$(printf '+CMS ERROR 500\r\n')")" error at-cms-error
	assert_eq "$(at_response_class "$(printf 'AT+CPIN?\r\n+CPIN: READY\r\nOK\r\n')")" ok at-query-ok-line
	assert_eq "$(at_response_class 'OKAY')" invalid at-ok-must-be-complete-line
	at_response_valid ATI 'FM350-GL Revision 1.0' || fail 'valid vendor-only ATI response rejected'
	if at_response_valid 'AT+CGACT=0,3' 'Fibocom FM350'; then fail 'vendor text accepted as action success'; fi
	if at_response_valid ATI "$(printf 'FM350-GL\r\nERROR\r\n')"; then fail 'ATI response containing ERROR accepted'; fi
	if at_response_valid ATI ''; then fail 'empty ATI response accepted'; fi
	return 0
}

test_probe_v4_at_rejects_errors_and_process_failure() {
	AT_MODE=error
	at_run() {
		case "$AT_MODE" in
			error) printf '+CGPADDR: 3,"10.20.30.40"\r\nERROR\r\nOK\r\n'; return 0 ;;
			process-failure) printf '+CGPADDR: 3,"10.20.30.40"\r\nOK\r\n'; return 23 ;;
			valid) printf '+CGPADDR: 3,"10.20.30.40"\r\nOK\r\n'; return 0 ;;
		esac
	}
	if result=$(probe_v4_at /dev/mock 3); then fail 'CGPADDR value followed by ERROR accepted'; fi
	assert_eq "$result" ""
	AT_MODE=process-failure
	if result=$(probe_v4_at /dev/mock 3); then fail 'partial CGPADDR output hid process failure'; fi
	assert_eq "$result" ""
	AT_MODE=valid
	assert_eq "$(probe_v4_at /dev/mock 3)" 10.20.30.40
}

test_at_transport_status() {
	local response
	sms_tool() {
		case "$MOCK_AT_MODE" in
			success) printf '\r\nOK\r\n'; return 0 ;;
			nonzero-output) printf 'partial response\r\n'; return 23 ;;
			nonzero-ok) printf 'OK\r\n'; return 23 ;;
			timeout-output) printf 'partial response\r\n'; command sleep 3; printf 'OK\r\n'; return 0 ;;
			empty) return 0 ;;
			vendor-ati)
				[ "$4" = ATI ] && { printf 'Fibocom FM350-GL\r\n'; return 0; }
				printf 'Fibocom FM350-GL\r\n'; return 0
			;;
			action-error) printf 'ERROR\r\n'; return 0 ;;
		esac
	}
	MOCK_AT_MODE=success
	response=$(at_run /dev/mock ATI 5) || fail 'successful AT process returned failure'
	assert_eq "$(at_response_class "$response")" ok at-transport-success
	MOCK_AT_MODE=nonzero-output
	if response=$(at_run /dev/mock ATI 5); then fail 'nonzero AT process with output returned success'; fi
	case "$response" in *'partial response'*) ;; *) fail 'nonzero AT output was lost' ;; esac
	MOCK_AT_MODE=nonzero-ok
	if response=$(at_run /dev/mock 'AT+CGACT=0,3' 5); then fail 'nonzero AT process with OK output returned success'; fi
	MOCK_AT_MODE=timeout-output
	if response=$(at_run /dev/mock ATI 1); then fail 'partial output hid AT timeout'; fi
	case "$response" in *'partial response'*'ERROR: AT timeout'*) ;; *) fail 'timeout output or reason was lost' ;; esac
	MOCK_AT_MODE=empty
	response=$(at_run /dev/mock ATI 5) || fail 'empty successful process status changed'
	at_response_valid ATI "$response" && fail 'empty AT response was marked valid'
	MOCK_AT_MODE=vendor-ati
	at_check /dev/mock ATI 5 || fail 'ATI vendor-only response was rejected'
	at_check /dev/mock 'AT+CGACT=0,3' 5 && fail 'vendor-only response accepted as action success'
	MOCK_AT_MODE=action-error
	at_check /dev/mock 'AT+CGACT=0,3' 5 && fail 'ordinary ERROR accepted as action success'
	MOCK_AT_MODE=success
	at_check /dev/mock 'AT+CGACT=0,3' 5 || fail 'valid action OK response rejected'
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
					"	option managed_v4_ifname 'owned_v4'" \
					"	option managed_v6_ifname 'owned_v6'" \
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
	assert_eq "$(fcfg global managed_v4_ifname)" owned_v4
	assert_eq "$(fcfg global managed_v6_ifname)" owned_v6
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
					"	option managed_v6_ifname 'bad name!'" \
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
	assert_eq "$(fcfg global managed_v6_ifname)" ""
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
run test_failed_usb_reset_throttle_and_total_timeout
run test_ipv6_escalation
run_lock_test test_mailbox
run test_switch_and_absent_request
run test_profile_disable_transition_once
run test_profile_disable_retry_and_cancel
run test_dial_stop_requires_successful_at_response
run test_profile_disconnect_state_json
run test_disabled_profile_does_not_redial_when_device_returns
run test_profile_disable_intent_survives_device_absence
run test_session_grace_only_on_success
run test_cycle_ipv6_snapshots_not_gated_by_escalation
run test_ipv6_escalated_sampling_recovers_with_serial
run_lock_test test_singleton
run_lock_test test_serial_mutex
run test_at_response_classification
run test_probe_v4_at_rejects_errors_and_process_failure
run_lock_test test_at_transport_status
run test_discovery_clears_stale_cache_during_scan_cooldown
run test_default_route_parsing
run test_interface_reconciliation_includes_ipv6
run test_snapshot_failure_clears_stale_values
run test_config_cache
