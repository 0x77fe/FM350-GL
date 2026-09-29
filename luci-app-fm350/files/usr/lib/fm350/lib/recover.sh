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
	port="$1"
	define=$(fcfg profile define_connect)
	event "恢复动作 L2: AT+CFUN 软重启模组 (${port})"
	at_run "$port" "AT+CFUN=0" >/dev/null
	sleep 3
	at_run "$port" "AT+CFUN=1" >/dev/null
	sleep 5
	dial_now "$port"
	action_ifup
}

action_usb_reset()
{
	local path="$1" devnode="$2"
	event "恢复动作 L3: USB 级复位 ${path} (${devnode:-未定位})"
	if [ -n "$path" ] && [ -w "/sys/bus/usb/drivers/usb/unbind" ]; then
		echo "$path" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
		sleep 2
		echo "$path" > /sys/bus/usb/drivers/usb/bind 2>/dev/null
	elif [ -n "$devnode" ] && [ -x /usr/bin/usbreset ]; then
		usbreset "$devnode" 2>/dev/null
	fi
}

# recover_done：网络恢复后复位计时
recover_done()
{
	R_PROBLEM=""
	R_SINCE=0
	R_LEVEL=0
	V6_RENEW_COUNT=0
}

# escalate_v4 <now>：IPv4 阶梯（0 等待→1 重建接口→2 模组重启→3 USB复位→4 告警循环）
escalate_v4()
{
	local now="$1" elapsed wait_t rec_t usb_t end_t cool
	now="$1"
	elapsed=$((now - R_SINCE))
	wait_t=$(fcfg watch wait_timeout)
	rec_t=$(fcfg watch recovery_timeout)
	usb_t=$(fcfg watch usb_reset_timeout)
	end_t=$(fcfg watch restart_timeout)
	cool=$(fcfg watch cooldown)

	case "$R_LEVEL" in
	0)
		if [ "$elapsed" -ge "$wait_t" ]; then
			action_ifup
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
		if [ "$(fcfg watch usb_reset_enabled)" = "1" ] && [ $((now - LAST_USBRESET)) -ge "$cool" ]; then
			action_usb_reset "$D_USB_PATH" "$D_DEVNODE"
			LAST_USBRESET=$now
			R_LEVEL=4
		elif [ "$(fcfg watch usb_reset_enabled)" != "1" ]; then
			R_LEVEL=4
		fi
	;;
	4)
		if [ "$elapsed" -ge "$end_t" ]; then
			event "恢复循环超时(${elapsed}s)，进入告警；请人工检查 USB/模组，5 分钟后重试"
			R_SINCE=$now
			R_LEVEL=0
		fi
	;;
	esac
}

# escalate_v6 <now>：IPv6 专项（只动 wwan6；soft=仅 ping 不可达）
escalate_v6()
{
	local now="$1" hard="$2" last renew_count
	now="$1"
	if [ "$R_PROBLEM" != "v6" ]; then
		R_PROBLEM="v6"
		R_SINCE=$now
		R_LEVEL=0
		V6_RENEW_COUNT=0
	fi
	last=$((now - LAST_V6RENEW))
	if [ "$hard" = "1" ]; then
		if [ "$last" -ge 60 ]; then
			action_v6_renew
			LAST_V6RENEW=$now
			V6_RENEW_COUNT=$((V6_RENEW_COUNT + 1))
			if [ "$V6_RENEW_COUNT" -ge 3 ] && [ "$(fcfg watch ipv6_escalate)" = "1" ]; then
				event "IPv6 连续刷新失败，升级为整体恢复"
				R_PROBLEM="v4"
				R_SINCE=$now
				R_LEVEL=1
				escalate_v4 "$now"
			fi
		fi
	else
		# soft：前缀可能已被运营商回收，30 分钟兜底刷新一次
		if [ "$last" -ge 1800 ]; then
			event "IPv6 出口不可达，执行兜底前缀刷新"
			action_v6_renew
			LAST_V6RENEW=$now
		fi
	fi
}
