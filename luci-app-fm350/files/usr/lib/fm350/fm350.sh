#!/bin/sh
# FM350-GL 管理守护：发现→拨号→维护→分级恢复（单进程单循环）
RU="/var/run/fm350"
LIB="/usr/lib/fm350/lib"
. "$LIB/config.sh"
. "$LIB/util.sh"
. "$LIB/at.sh"
. "$LIB/discover.sh"
. "$LIB/probe.sh"
. "$LIB/dial.sh"
. "$LIB/recover.sh"
. "/usr/lib/fm350/fibocom.sh"

# 发现状态（VID/PID 在识别前留空；自动模式由 discover_auto 填充，手动模式由配置填充）
D_VID=""
D_PID=""
D_USB_PATH=""
D_DEVNODE=""
D_IFNAME=""
D_AT_PORT=""
LAST_USB_PATH=""
LAST_VID=""
LAST_PID=""

# 恢复/计时状态
R_PROBLEM=""
R_SINCE=0
R_LEVEL=0
LAST_IFUP=0
LAST_RESTART=0
LAST_USBRESET=0
LAST_V6RENEW=0
V6_RENEW_COUNT=0
V6_PING_FAILS=0
LAST_V6PING=0
LAST_V6DONE=0
LAST_REC_DONE=0
LAST_DIAL=0
LAST_COUNTER_TS=0
COUNTER_SUM=0
GW_FAIL_SINCE=0
SESS_SINCE=0
ABSENT_SINCE=0
LAST_ABSENT_ALARM=0
ONLINE_SINCE=0

# 模组信息快照（供 UI 读取，避免与 AT 控制台竞争串口）
LAST_SNAP=0
LAST_CELL=0
LAST_CA=0
SNAP_ATI=""
SNAP_CPIN=""
SNAP_COPS=""
SNAP_CELL=""
SNAP_CA=""

# 每轮快照
V4_AT=""
K_V4_ADDR=""
K_V4_ROUTE=0
K_V4_GW=""
K_V6_ADDR=""
K_V6_ROUTE=0
K_V6_GW=""
P_RX=0
P_TX=0

startup_guard()
{
	if pgrep -f "modem_network_task.sh|/usr/share/modem/modem_task.sh|modem_watching.sh" >/dev/null 2>&1; then
		fm350_log err "检测到旧 modem 守护仍在运行，拒绝启动；请先执行 install_fm350.sh"
		exit 1
	fi
}

# 单实例锁：procd respawn 与手动重启并发时，第二个实例自动退出（防双实例抢串口/双拨号）
singleton_guard()
{
	local p
	p=$(cat "${RU}/daemon.pid" 2>/dev/null)
	if [ -n "$p" ] && [ "$p" != "$$" ] && kill -0 "$p" 2>/dev/null \
	   && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "fm350.sh daemon"; then
		fm350_log warn "已有守护实例运行中(pid $p)，本实例退出"
		exit 1
	fi
	echo $$ > "${RU}/daemon.pid"
}

# 清理历史遗留的 AT 临时文件（tmpfs 防膨胀）：非当前进程的 at.* 一律清空，
# 程序只复用 at.$$ 单文件，此处保证旧进程残留下的内容不再占内存
cleanup_stale()
{
	local f
	for f in "${RU}"/at.*; do
		[ -f "$f" ] || continue
		case "$f" in
			*".$$") continue ;;
		esac
		: > "$f"
	done
}

write_state()
{
	local now state_name problem_name elapsed
	now=$(date +%s)
	elapsed=0
	[ "$R_SINCE" -gt 0 ] && elapsed=$((now - R_SINCE))
	if [ -z "$D_USB_PATH" ]; then
		state_name="ABSENT"
	elif [ "$(fcfg profile enable)" != "1" ]; then
		state_name="DISABLED"
	elif [ -z "$D_IFNAME" ] || [ -z "$D_AT_PORT" ]; then
		state_name="PRESENT"
	elif [ -n "$R_PROBLEM" ]; then
		state_name="RECOVERING"
	elif [ -z "$V4_AT" ] || [ "$V4_AT" = "0.0.0.0" ]; then
		state_name="DIALING"
	else
		state_name="ONLINE"
	fi
	case "$R_PROBLEM" in
		"v6") problem_name="IPv6" ;;
		"v4") problem_name="IPv4" ;;
		"data") problem_name="数据面" ;;
		"absent") problem_name="模块离线" ;;
		*) problem_name="" ;;
	esac
	jq -n --arg ts "$now" \
		--arg st "$state_name" --arg problem "$R_PROBLEM" --arg problem_name "$problem_name" \
		--arg level "$R_LEVEL" --arg since "$R_SINCE" --arg elapsed "$elapsed" \
		--arg path "$D_USB_PATH" --arg devnode "$D_DEVNODE" --arg ifname "$D_IFNAME" \
		--arg vid "$D_VID" --arg pid "$D_PID" \
		--arg at_port "$D_AT_PORT" --arg v4 "$V4_AT" --arg v4k "$K_V4_ADDR" --arg v4route "$K_V4_ROUTE" \
		--arg v6 "$K_V6_ADDR" --arg v6route "$K_V6_ROUTE" --arg v6gw "$K_V6_GW" \
		--arg rx "$P_RX" --arg tx "$P_TX" --arg online_since "$ONLINE_SINCE" \
		--arg absent_since "$ABSENT_SINCE" --arg sess_since "$SESS_SINCE" \
		--arg at_ati "$SNAP_ATI" --arg at_cpin "$SNAP_CPIN" --arg at_cops "$SNAP_COPS" \
		--arg cell_json "$SNAP_CELL" --arg ca_json "$SNAP_CA" \
		'{
			ts: ($ts | tonumber),
			state: $st, problem: $problem, problem_name: $problem_name,
			recovery_level: ($level | tonumber), problem_since: ($since | tonumber),
			elapsed: ($elapsed | tonumber),
			usb: { present: ($path != ""), path: $path, devnode: $devnode, vid: $vid, pid: $pid },
			net: { ifname: $ifname, at_port: $at_port, v4_at: $v4, v4_kernel: $v4k,
			       v4_route: ($v4route == "1"), v6: $v6, v6_route: ($v6route == "1"), v6_gw: $v6gw,
			       rx: ($rx | tonumber), tx: ($tx | tonumber) },
			online_since: ($online_since | tonumber),
			absent_since: ($absent_since | tonumber),
			sess_since: ($sess_since | tonumber),
			at: { ati: $at_ati, cpin: $at_cpin, cops: $at_cops },
			cell: ($cell_json | fromjson? // {}),
			ca: ($ca_json | fromjson? // {})
		}' > "${RU}/state.json.tmp" && mv "${RU}/state.json.tmp" "${RU}/state.json"
}

# 处理请求文件（UI 指令队列）
handle_req()
{
	local req port
	[ -f "${RU}/req" ] || return 0
	req=$(cat "${RU}/req")
	# 消费式取走：原子 rename 写入方不受清空竞态影响
	mv "${RU}/req" "${RU}/req.done" 2>/dev/null || true
	port="$D_AT_PORT"
	[ -z "$req" ] && return 0
	case "$req" in
		"enable")
			uci set fm350.profile.enable=1
			uci commit fm350
			event "UI 指令: 启用拨号"
		;;
		"disable")
			uci set fm350.profile.enable=0
			uci commit fm350
			event "UI 指令: 停用拨号"
			[ -n "$port" ] && dial_stop "$port"
		;;
		"reconnect")
			event "UI 指令: 重新拨号"
			[ -n "$port" ] && {
				dial_now "$port"
				LAST_DIAL=$(date +%s)
			}
		;;
		"modem_restart")
			event "UI 指令: 软重启模组"
			[ -n "$port" ] && action_modem_restart "$port"
		;;
		"usb_reset")
			event "UI 指令: USB 硬件复位"
			action_usb_reset "$D_USB_PATH" "$D_DEVNODE"
		;;
		"ifup")
			event "UI 指令: 重建网络接口"
			action_ifup
		;;
		*)
			fm350_log warn "未知 UI 指令: $req"
		;;
	esac
}

cycle()
{
	local now define v4cur
	now=$(date +%s)

	# --- 发现 ---
	discover_light
	if [ -z "$D_USB_PATH" ]; then
		if [ "$ABSENT_SINCE" = "0" ]; then
			ABSENT_SINCE=$now
			event "模块离线（USB 不可见）"
		fi
		R_PROBLEM="absent"
		R_SINCE=$ABSENT_SINCE
		if [ "$((now - ABSENT_SINCE))" -ge "$(fcfg watch reappear_timeout)" ] && [ "$((now - LAST_ABSENT_ALARM))" -ge 600 ]; then
			event "模块离线已超过 $(fcfg watch reappear_timeout)s，请检查 USB 线缆/供电"
			LAST_ABSENT_ALARM=$now
		fi
		write_state
		return 0
	fi
	if [ "$ABSENT_SINCE" != "0" ]; then
		event "模块重新出现（${D_USB_PATH}），自动重新拨号中"
		ABSENT_SINCE=0
		R_PROBLEM=""
		R_SINCE=0
		R_LEVEL=0
		# 重枚举后立即重探 AT 口/刷新快照：清空探测冷却，不等下一轮
		: > "${RU}/at_probe.last"
		LAST_SNAP=0
		LAST_CELL=0
		LAST_CA=0
	fi
	if [ "$D_USB_PATH" != "$LAST_USB_PATH" ]; then
		old="$LAST_USB_PATH"
		LAST_USB_PATH="$D_USB_PATH"
		[ -n "$old" ] && [ "$old" != "$D_USB_PATH" ] && event "模块位置变更: ${old} → ${D_USB_PATH}"
		D_IFNAME=""
		D_AT_PORT=""
	fi
	if [ -n "$D_VID" ] && [ "$D_VID:$D_PID" != "$LAST_VID:$LAST_PID" ]; then
		LAST_VID="$D_VID"
		LAST_PID="$D_PID"
		event "模组识别: ${D_VID}:${D_PID}（配置留空时为自动识别）"
	fi
	hint=$(fcfg global usb_path_hint)
	[ -n "$hint" ] && [ "$hint" != "$D_USB_PATH" ] && event "模块位置与提示路径不一致: hint=${hint} now=${D_USB_PATH}"
	[ -n "$D_IFNAME" ] && [ ! -e "/sys/class/net/$D_IFNAME" ] && D_IFNAME=""
	[ -n "$D_AT_PORT" ] && [ ! -e "$D_AT_PORT" ] && D_AT_PORT=""
	[ -z "$D_IFNAME" ] && discover_ifname
	[ -z "$D_AT_PORT" ] && discover_at_port "$(fcfg global at_port)"

	# --- 总开关 / 基础设施 ---
	handle_req
	if [ "$(fcfg profile enable)" != "1" ]; then
		if [ "$R_PROBLEM" != "disabled" ]; then
			event "拨号已停用（profile.enable=0）"
			R_PROBLEM="disabled"
		fi
		write_state
		return 0
	fi
	if [ "$R_PROBLEM" = "disabled" ]; then
		R_PROBLEM=""
		event "拨号已启用"
	fi
	if [ -z "$D_IFNAME" ] || [ -z "$D_AT_PORT" ]; then
		write_state
		return 0
	fi
	dial_ensure_interfaces "$D_IFNAME"

	# 计数器采样（供 UI 展示）
	probe_counters "$D_IFNAME"

	# --- 拨号保障（AT 权威 IPv4） ---
	define=$(fcfg profile define_connect)
	V4_AT=$(probe_v4_at "$D_AT_PORT" "$define")

	if [ -z "$V4_AT" ] || [ "$V4_AT" = "0.0.0.0" ]; then
		if [ "$R_PROBLEM" != "v4" ]; then
			event "拨号丢失（CGPADDR 为空），进入恢复流程"
			R_PROBLEM="v4"
			R_SINCE=$now
			R_LEVEL=0
		fi
		if [ $((now - LAST_DIAL)) -ge 60 ] && [ "$R_LEVEL" -le 1 ]; then
			event "重拨（AT+CGACT=1,${define}）"
			dial_now "$D_AT_PORT"
			LAST_DIAL=$now
			SESS_SINCE=$now
		fi
		escalate_v4 "$now"
		write_state
		return 0
	fi

	# v4 地址变化 → 刷新 uci（首次/换网）
	v4cur=$(uci -q get "network.$(fcfg global v4_ifname).ipaddr")
	if [ "$v4cur" != "$V4_AT" ]; then
		event "IPv4 地址变更: ${v4cur:-无} → ${V4_AT}"
		refresh_v4 "$D_AT_PORT" "$define" "$(fcfg global v4_ifname)"
		SESS_SINCE=$now
	fi

	# --- 数据面活性检测（计数冻结 + 公共DNS不可达 才判假死；计数在动但ping不通=上游问题，不动模组） ---
	if [ "$(fcfg watch frozen_enabled)" = "1" ] && [ "$V4_AT" != "0.0.0.0" ] && [ "$((now - SESS_SINCE))" -ge "$(fcfg watch frozen_grace)" ]; then
		probe_counters "$D_IFNAME"
		sum=$((P_RX + P_TX))
		if ping -c 1 -W 2 "$(fcfg watch ipv4_ping_target)" >/dev/null 2>&1; then
			COUNTER_SUM=$sum
			LAST_COUNTER_TS=$now
		else
			if [ "$sum" = "$COUNTER_SUM" ] && [ "$COUNTER_SUM" != "0" ] && [ "$((now - LAST_COUNTER_TS))" -ge "$(fcfg watch frozen_sample)" ]; then
				event "数据面假死（计数无变化且 $(fcfg watch ipv4_ping_target) 不可达 ≥$(fcfg watch frozen_sample)s），执行 USB 复位"
				action_usb_reset "$D_USB_PATH" "$D_DEVNODE"
				LAST_USBRESET=$now
				COUNTER_SUM=0
				SESS_SINCE=$now
				R_PROBLEM="data"
				R_SINCE=$now
				R_LEVEL=4
				write_state
				return 0
			fi
			COUNTER_SUM=$sum
			LAST_COUNTER_TS=$now
		fi
	fi

	# --- IPv4 内核校验 ---
	probe_v4_kernel "$D_IFNAME"
	if [ "$K_V4_ROUTE" != "1" ]; then
		if [ "$R_PROBLEM" != "v4" ]; then
			event "IPv4 路由丢失（内核），进入恢复流程"
			R_PROBLEM="v4"
			R_SINCE=$now
			R_LEVEL=0
		fi
		escalate_v4 "$now"
		write_state
		return 0
	fi

	# --- IPv6 校验（探测周期化 + 连续 2 次失败才判故障：单次 ICMP 抖动不翻转状态） ---
	if [ "$(fcfg watch ipv6_check_enabled)" = "1" ]; then
		probe_v6_kernel "$D_IFNAME"
		if [ -z "$K_V6_ADDR" ] || [ "$K_V6_ROUTE" != "1" ]; then
			V6_PING_FAILS=0
			escalate_v6 "$now" 1
		else
			if [ "$((now - LAST_V6PING))" -ge "$(fcfg watch ipv6_ping_interval)" ]; then
				LAST_V6PING=$now
				if probe_v6_ping "$(fcfg watch ipv6_ping_target)"; then
					V6_PING_FAILS=0
				else
					V6_PING_FAILS=$((V6_PING_FAILS + 1))
				fi
			fi
			if [ "$V6_PING_FAILS" -ge 2 ]; then
				escalate_v6 "$now" 0
			elif [ "$R_PROBLEM" = "v6" ]; then
				recover_done
				# 恢复事件去抖：10 分钟内只记录一次（状态仍即时复位）
				if [ "$((now - LAST_V6DONE))" -ge 600 ]; then
					LAST_V6DONE=$now
					event "网络恢复完成（IPv6）"
				fi
			fi
		fi
	fi

	# --- 模组信息快照（30s AT / 120s 小区，供 UI 零竞争读取，避免与 AT 控制台抢串口） ---
	if [ -n "$D_AT_PORT" ] && { [ -z "$R_PROBLEM" ] || [ "$R_PROBLEM" = "v6" ]; }; then
		if [ "$((now - LAST_SNAP))" -ge 30 ]; then
			SNAP_ATI=$(at_run "$D_AT_PORT" "ATI" 3)
			SNAP_CPIN=$(at_run "$D_AT_PORT" "AT+CPIN?" 3)
			SNAP_COPS=$(at_run "$D_AT_PORT" "AT+COPS?" 3)
			LAST_SNAP=$now
		fi
		if [ "$((now - LAST_CELL))" -ge 120 ]; then
			fibocom_cellinfo "$D_AT_PORT" "$define" >/dev/null 2>&1
			# SS-SINR/SS-RSRP/SS-RSRQ 取自 3GPP 标准 AT+CESQ 扩展位（第 7/8/9 字段，255=无效）
			ss_rsrp=""; ss_rsrq=""; ss_sinr=""
			cesq_line=$(at_run "$D_AT_PORT" "AT+CESQ" 4 | grep "^+CESQ:" | head -1)
			c7=$(echo "$cesq_line" | cut -d, -f7)
			c8=$(echo "$cesq_line" | cut -d, -f8)
			c9=$(echo "$cesq_line" | cut -d, -f9 | tr -d '\r')
			[ -n "$c7" ] && [ "$c7" != "255" ] && ss_rsrq=$(awk "BEGIN{printf \"%.1f\", $c7/2 - 43}")
			[ -n "$c8" ] && [ "$c8" != "255" ] && ss_rsrp=$(awk "BEGIN{printf \"%d\", $c8 - 156}")
			[ -n "$c9" ] && [ "$c9" != "255" ] && ss_sinr=$(awk "BEGIN{printf \"%.1f\", $c9/2 - 23.25}")
			if [ -n "$CL_MCC" ] || [ -n "$CL_RSRP" ] || [ -n "$ss_sinr" ]; then
				SNAP_CELL=$(jq -n --arg rat "$CL_RAT" --arg netmode "$CL_NETMODE" --arg mcc "$CL_MCC" \
					--arg mnc "$CL_MNC" --arg tac "$CL_TAC" --arg cellid "$CL_CELLID" --arg band "$CL_BAND" \
					--arg bw "$CL_BW" --arg rsrp "$CL_RSRP" --arg rsrq "$CL_RSRQ" --arg sinr "$ss_sinr" \
					--arg ss_rsrp "$ss_rsrp" --arg ss_rsrq "$ss_rsrq" --arg ss_sinr "$ss_sinr" \
					--arg raw "$CL_RAW" --arg model "$CL_MODEL" \
					'{rat:$rat,netmode:$netmode,mcc:$mcc,mnc:$mnc,tac:$tac,cellid:$cellid,band:$band,bw:$bw,rsrp:$rsrp,rsrq:$rsrq,sinr:$sinr,ss_rsrp:$ss_rsrp,ss_rsrq:$ss_rsrq,ss_sinr:$ss_sinr,raw:$raw,model:$model}' 2>/dev/null)
			fi
			LAST_CELL=$now
		fi
		# 载波聚合快照（固件未提供 CA 使能命令，此项仅监控查询；解析失败保留原始回显）
		if [ "$(fcfg watch ca_check_enabled)" = "1" ] && [ "$((now - LAST_CA))" -ge "$(fcfg watch ca_interval)" ]; then
			ca_raw=$(at_run "$D_AT_PORT" "AT+GTCAINFO?" 6)
			ca_pcc_line=$(echo "$ca_raw" | grep "^PCC:" | head -1 | cut -d: -f2-)
			if [ -n "$ca_pcc_line" ]; then
				ca_band_num=$(echo "$ca_pcc_line" | cut -d, -f1 | tr -d '\r')
				ca_pci=$(echo "$ca_pcc_line" | cut -d, -f2)
				ca_arfcn=$(echo "$ca_pcc_line" | cut -d, -f3)
				ca_rsrp=$(echo "$ca_pcc_line" | awk -F, '{print $NF}' | tr -d '\r')
				ca_band=$(fibocom_get_band "NR" "$ca_band_num")
				[ -n "$ca_band" ] || ca_band="$ca_band_num"
				# 解析 SCC 行（手册字段：<scell_state>,<ul_configured>,<band>,<pci>,<narfcn>,...[,rssnr,rsrp,rsrq]）
				# scell_state：1=已配置未激活 2=已配置已激活
				echo "$ca_raw" | grep "^SCC" | tr -d '\r' > "${RU}/ca.scc"
				ca_scc_active=0
				ca_scc_json="[]"
				while IFS= read -r scc_line; do
					scc_body=$(echo "$scc_line" | cut -d: -f2-)
					scc_state=$(echo "$scc_body" | cut -d, -f1)
					scc_band_num=$(echo "$scc_body" | cut -d, -f3)
					scc_band=$(fibocom_get_band "NR" "$scc_band_num")
					[ -n "$scc_band" ] || scc_band="$scc_band_num"
					scc_pci=$(echo "$scc_body" | cut -d, -f4)
					scc_arfcn=$(echo "$scc_body" | cut -d, -f5)
					scc_rsrp=$(echo "$scc_body" | awk -F, '{print $NF}' | tr -d '\r')
					[ "$scc_state" = "2" ] && ca_scc_active=$((ca_scc_active + 1))
					ca_scc_json=$(echo "$ca_scc_json" | jq --arg st "$scc_state" --arg b "$scc_band" \
						--arg p "$scc_pci" --arg a "$scc_arfcn" --arg r "$scc_rsrp" \
						'. + [{state:($st|tonumber? // 0), band:$b, pci:$p, arfcn:$a, rsrp:$r}]' 2>/dev/null)
				done < "${RU}/ca.scc"
				ca_scc_total=$(echo "$ca_scc_json" | jq 'length' 2>/dev/null)
				[ -n "$ca_scc_total" ] || ca_scc_total=0
				SNAP_CA=$(jq -n --arg agg "$([ "$ca_scc_active" -gt 0 ] && echo 1 || echo 0)" \
					--arg scc "$ca_scc_total" --arg scc_active "$ca_scc_active" --argjson scc_list "$ca_scc_json" \
					--arg band "$ca_band" --arg pci "$ca_pci" \
					--arg arfcn "$ca_arfcn" --arg rsrp "$ca_rsrp" --arg raw "$(echo "$ca_raw" | tr -d '\r')" \
					'{aggregated:($agg=="1"),scc_count:($scc|tonumber),scc_active:($scc_active|tonumber),scc:$scc_list,pcc_band:$band,pcc_pci:$pci,pcc_arfcn:$arfcn,pcc_rsrp:$rsrp,raw:$raw}' 2>/dev/null)
			fi
			LAST_CA=$now
		fi
	fi

	# --- 完全正常 ---
	if [ -n "$R_PROBLEM" ] && [ "$R_PROBLEM" != "v6" ]; then
		recover_done
		# 恢复事件去抖：5 分钟内只记录一次
		if [ "$((now - LAST_REC_DONE))" -ge 300 ]; then
			LAST_REC_DONE=$now
			event "网络恢复完成"
		fi
	fi
	if [ "$R_PROBLEM" = "" ]; then
		[ "$ONLINE_SINCE" = "0" ] && ONLINE_SINCE=$now
	else
		ONLINE_SINCE=0
	fi
	write_state
	return 0
}

main()
{
	mkdir -p "$RU"
	startup_guard
	singleton_guard
	cleanup_stale
	# 恢复上次发现缓存（重启后减少 AT 全量探测）
	LAST_USB_PATH=$(state_jget usb.path)
	[ -n "$LAST_USB_PATH" ] && [ -f "/sys/bus/usb/devices/${LAST_USB_PATH}/idVendor" ] && {
		D_USB_PATH="$LAST_USB_PATH"
		D_IFNAME=$(state_jget net.ifname)
		D_AT_PORT=$(state_jget net.at_port)
		D_DEVNODE=$(state_jget usb.devnode)
	}
	# 自动识别模式（usb_vid_pid 留空）：复用上次识别的 VID:PID
	[ -z "$(fcfg global usb_vid_pid)" ] && {
		v=$(state_jget usb.vid)
		p=$(state_jget usb.pid)
		[ -n "$v" ] && D_VID="$v"
		[ -n "$p" ] && D_PID="$p"
	}
	s=$(state_jget sess_since)
	[ -n "$s" ] && [ "$s" -gt 0 ] && SESS_SINCE=$s
	event "FM350 管理守护启动（pid $$）"
	while true; do
		cycle
		sleep "$(fcfg global interval)"
	done
}

check_mode()
{
	echo "== fm350 check =="
	if discover_scan; then
		echo "USB: present path=$D_USB_PATH count=$D_USB_COUNT devnode=$D_DEVNODE"
		echo "netif: ${D_IFNAME:-未就绪}"
		echo "at_port: ${D_AT_PORT:-未探测}"
	else
		echo "USB: ABSENT"
		return 1
	fi
	probe_v4_kernel "$D_IFNAME"
	echo "v4: addr=${K_V4_ADDR:-无} route=${K_V4_ROUTE}"
	probe_v6_kernel "$D_IFNAME"
	echo "v6: addr=${K_V6_ADDR:-无} route=${K_V6_ROUTE}"
	if [ -n "$D_AT_PORT" ]; then
		echo "AT: $(at_run "$D_AT_PORT" 'ATI' 4 | tr -d '\r' | head -3 | tr '\n' ' ')"
	fi
	return 0
}

case "$1" in
	daemon) main ;;
	check) check_mode ;;
	at_cli)
		at_run "$2" "$3" "${4:-8}"
		# RPC 单次进程：用完立即清空自身临时文件（tmpfs 防膨胀）
		: > "${RU}/at.$$"
		;;
	cell_cli)
		fibocom_cellinfo "$2" "$(fcfg profile define_connect)"
		jq -n --arg rat "$CL_RAT" --arg netmode "$CL_NETMODE" --arg mcc "$CL_MCC" --arg mnc "$CL_MNC" \
			--arg tac "$CL_TAC" --arg cellid "$CL_CELLID" --arg band "$CL_BAND" --arg bw "$CL_BW" \
			--arg rsrp "$CL_RSRP" --arg rsrq "$CL_RSRQ" --arg sinr "$CL_SINR" --arg raw "$CL_RAW" \
			--arg model "$CL_MODEL" \
			'{rat: $rat, netmode: $netmode, mcc: $mcc, mnc: $mnc, tac: $tac, cellid: $cellid,
			  band: $band, bw: $bw, rsrp: $rsrp, rsrq: $rsrq, sinr: $sinr, raw: $raw, model: $model}'
	;;
	*) main ;;
esac
