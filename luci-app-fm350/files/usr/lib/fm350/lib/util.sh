# 通用工具与日志
RU="/var/run/fm350"

fm350_log()
{
	local level="$1" msg="$2"
	logger -p "daemon.${level}" -t fm350 "$msg"
}

# event <消息>：追加事件日志并截断、同步 syslog
event()
{
	local line keep n
	line="$(date '+%Y-%m-%d %H:%M:%S') $1"
	echo "$line" >> "${RU}/events.log"
	[ -f "${RU}/events.log" ] && {
		keep=$(fcfg notify events_keep)
		keep=${keep:-200}
		n=$(wc -l < "${RU}/events.log")
		while [ "$n" -gt "$keep" ] 2>/dev/null; do
			sed -i '1d' "${RU}/events.log"
			n=$((n - 1))
		done
	}
	fm350_log info "$1"
}

# state_jget <key>：从 state.json 取值（不存在输出空）
state_jget()
{
	[ -f "${RU}/state.json" ] && jq -r ".$1 // empty" "${RU}/state.json" 2>/dev/null
}
