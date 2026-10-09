# 恢复动作与阶梯（节流幂等；故障计时由主循环变量维护）

action_ifup()
{
	event "恢复动作 L1: 重建接口 $(fcfg global v4_ifname) / $(fcfg global v6_ifname)"
	ifup "$(fcfg global v4_ifname)" 2>/dev/null
	ifup "$(fcfg global v6_ifname)" 2>/dev/null
}

action_v6_renew()
{
	local v6
	v6=$(fcfg global v6_ifname)
	event "恢复动作 IPv6: 刷新 ${v6} (odhcp6c)"
	ifdown "$v6" 2>/dev/null
	ifup "$v6" 2>/dev/null
}

action_modem_restart()
{
	local port="$1" define
	LAST_RESTART=$(date +%s)
	SERIAL_PAUSE_UNTIL=$((LAST_RESTART + 30))
	clear_info_snapshots
	define=$(fcfg profile define_connect)
	event "恢复动作 L2: AT+CFUN 软重启模组 (${port})"
	at_check "$port" "AT+CFUN=0" 8 || return 1
	sleep 3
	at_check "$port" "AT+CFUN=1" 8 || return 1
	sleep 5
	dial_now "$port" || return 1
	action_ifup || return 1
	mark_session_success
}

action_usb_reset()
{
	local path="$1" devnode="$2"
	LAST_USBRESET_ATTEMPT=$(date +%s)
	SERIAL_PAUSE_UNTIL=$((LAST_USBRESET_ATTEMPT + 30))
	clear_info_snapshots
	event "恢复动作 L3: USB 级复位 ${path} (${devnode:-未定位})"
	usb_reset_device "$path" "$devnode" || return 1
	LAST_USBRESET_SUCCESS=$(date +%s)
	mark_session_success
	return 0
}

# 可替换的设备级动作入口，便于在模拟环境验证失败与成功语义。
usb_reset_device()
{
	local path="$1" devnode="$2"
	if [ -n "$path" ] && [ -w "/sys/bus/usb/drivers/usb/unbind" ]; then
		echo "$path" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || return 1
		sleep 2
		echo "$path" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || return 1
	elif [ -n "$devnode" ] && [ -x /usr/bin/usbreset ]; then
		usbreset "$devnode" 2>/dev/null || return 1
	else
		return 1
	fi
	return 0
}

# 会话宽限期只从成功完成的拨号、模组重启或 USB 复位开始；失败尝试不刷新它。
mark_session_success()
{
	SESS_SINCE=$(date +%s)
	LAST_COUNTER_TS=0
	COUNTER_SUM=0
	clear_info_snapshots
}

# recover_done：网络恢复后复位计时
recover_done()
{
	R_PROBLEM=""
	R_SINCE=0
	R_LEVEL=0
	V6_RENEW_COUNT=0
	V6_ESCALATED=0
}

# 失败样本仅在计数变化时重新计时；零字节计数也属于有效样本。
frozen_elapsed()
{
	local now="$1" sum="$2"
	if [ "$LAST_COUNTER_TS" = "0" ] || [ "$sum" != "$COUNTER_SUM" ]; then
		COUNTER_SUM=$sum
		LAST_COUNTER_TS=$now
		return 1
	fi
	[ "$((now - LAST_COUNTER_TS))" -ge "$(fcfg watch frozen_sample)" ]
}

# 自动复位的统一开关与冷却；手动 UI 操作不受自动恢复开关限制。
auto_usb_reset()
{
	local now="$1" last_attempt
	[ "$(fcfg watch usb_reset_enabled)" = "1" ] || return 1
	last_attempt=${LAST_USBRESET_ATTEMPT:-0}
	[ "$((now - last_attempt))" -ge "$(fcfg watch cooldown)" ] || return 1
	# 失败也按尝试时间进入冷却，避免每个主循环反复写 sysfs。
	LAST_USBRESET_ATTEMPT=$now
	action_usb_reset "$D_USB_PATH" "$D_DEVNODE" || return 1
	LAST_USBRESET_SUCCESS=$now
}

# escalate_v4 <now>：IPv4 阶梯（0 等待→1 重建接口→2 模组重启→3 USB复位→4 告警循环）
escalate_v4()
{
	local now="$1" elapsed wait_t rec_t usb_t end_t cool
	elapsed=$((now - R_SINCE))
	wait_t=$(fcfg watch wait_timeout)
	rec_t=$(fcfg watch recovery_timeout)
	usb_t=$(fcfg watch usb_reset_timeout)
	end_t=$(fcfg watch restart_timeout)
	cool=$(fcfg watch cooldown)
	# 总恢复超时覆盖整个流程，USB 复位失败或被禁用时也能进入下一恢复周期。
	if [ "$elapsed" -ge "$end_t" ]; then
		event "恢复循环超时(${elapsed}s)，进入告警；请人工检查 USB/模组，重新开始恢复计时"
		R_SINCE=$now
		R_LEVEL=0
		return 0
	fi

	case "$R_LEVEL" in
	0)
		if [ "$elapsed" -ge "$wait_t" ]; then
			action_ifup
			LAST_IFUP=$now
			R_LEVEL=1
		fi
	;;
	1)
		if [ "$elapsed" -ge "$rec_t" ]; then
			R_LEVEL=2
		elif [ $((now - LAST_IFUP)) -ge 60 ]; then
			action_ifup
			LAST_IFUP=$now
		fi
	;;
	2)
		if [ $((now - LAST_RESTART)) -ge "$cool" ]; then
			action_modem_restart "$D_AT_PORT"
			LAST_RESTART=$now
			R_LEVEL=3
		fi
		[ "$elapsed" -ge "$usb_t" ] && R_LEVEL=3
	;;
	3)
		[ "$elapsed" -ge "$usb_t" ] || return 0
		if auto_usb_reset "$now"; then
			R_LEVEL=4
		elif [ "$(fcfg watch usb_reset_enabled)" != "1" ]; then
			R_LEVEL=4
		fi
	;;
	esac
}

# escalate_v6 <now>：IPv6 专项（只动 wwan6；soft=仅 ping 不可达）
escalate_v6()
{
	local now="$1" hard="$2" last
	if [ "$R_PROBLEM" != "v6" ]; then
		R_PROBLEM="v6"
		R_SINCE=$now
		R_LEVEL=0
		V6_RENEW_COUNT=0
		V6_ESCALATED=0
	fi
	last=$((now - LAST_V6RENEW))
	if [ "$hard" = "1" ]; then
		if [ "${V6_ESCALATED:-0}" = "1" ]; then
			escalate_v4 "$now"
			return 0
		fi
		if [ "$last" -ge 60 ]; then
			# 下一轮仍是硬故障，才算上次刷新失败。
			if [ "$V6_RENEW_COUNT" -ge 3 ] && [ "$(fcfg watch ipv6_escalate)" = "1" ]; then
				event "IPv6 连续刷新失败，升级为整体恢复"
				V6_ESCALATED=1
				R_SINCE=$now
				R_LEVEL=1
				escalate_v4 "$now"
			else
				action_v6_renew
				LAST_V6RENEW=$now
				V6_RENEW_COUNT=$((V6_RENEW_COUNT + 1))
			fi
		fi
	else
		# 地址/路由已恢复，不继续模组级升级；等待 ping 验证。
		V6_ESCALATED=0
		R_LEVEL=0
		# soft：前缀可能已被运营商回收，30 分钟兜底刷新一次
		if [ "$last" -ge 1800 ]; then
			event "IPv6 出口不可达，执行兜底前缀刷新"
			action_v6_renew
			LAST_V6RENEW=$now
		fi
	fi
}
