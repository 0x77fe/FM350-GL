# 所有 AT 调用者共享内核锁；卡住的 sms_tool 保留锁，禁止第二个串口写入者。
# at_run <port> <command> [timeout秒]：输出响应，超时强制结束
at_run()
(
	local port="$1" cmd="$2" timeout="${3:-8}" tmp pid t=0
	local status
	# AT 子进程只持有串口锁，不能延长已退出守护的实例锁寿命。
	exec 9>&-
	mkdir -p "$RU" || exit 1
	exec 8>"$RU/serial.lock"
	while ! flock -n 8; do
		[ "$t" -lt 20 ] || { echo 'ERROR: AT channel busy'; exit 1; }
		sleep 1
		t=$((t + 1))
	done
	tmp=$(mktemp "$RU/at.XXXXXX") || exit 1
	trap 'rm -f "$tmp"' EXIT
	sms_tool -d "$port" at "$cmd" > "$tmp" 2>&1 9>&- &
	pid=$!
	t=0
	while [ "$t" -lt "$timeout" ] && kill -0 "$pid" 2>/dev/null; do
		sleep 1
		t=$((t + 1))
	done
	if kill -0 "$pid" 2>/dev/null; then
		kill -9 "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null || :
		cat "$tmp"
		echo 'ERROR: AT timeout'
		exit 1
	fi
	cat "$tmp"
	if wait "$pid"; then status=0; else status=$?; fi
	[ "$status" = "0" ] || exit "$status"
)

# at_response_class <response>：完整响应行分类，优先拒绝 ERROR，再认 OK / 厂商标识。
at_response_class()
{
	printf '%s\n' "$1" | awk '
	function trim(s) {
		sub(/\r$/, "", s)
		sub(/^[ \t]+/, "", s)
		sub(/[ \t]+$/, "", s)
		return s
	}
	{
		line = trim($0)
		if (line ~ /^ERROR([ \t:].*)?$/ || line ~ /^\+CME[ \t]+ERROR([ \t:].*)?$/ || line ~ /^\+CMS[ \t]+ERROR([ \t:].*)?$/)
			error = 1
		if (line == "OK")
			ok = 1
		if (line ~ /(FM350|Fibocom|Manufacturer)/)
			vendor = 1
	}
	END {
		if (error) print "error"
		else if (ok) print "ok"
		else if (vendor) print "vendor"
		else print "invalid"
	}'
}

# at_response_valid <command> <response>：动作必须有独立 OK 行；ATI 兼容厂商标识回显。
at_response_valid()
{
	local class
	class=$(at_response_class "$2")
	case "$class" in
		ok) return 0 ;;
		vendor) [ "$1" = "ATI" ] ;;
		*) return 1 ;;
	esac
}

# at_check <port> <command>：动作命令需完整 OK 行；ATI 可用合法厂商响应。
at_check()
{
	local port="$1" cmd="$2" response
	AT_CHECK_REASON=""
	if ! response=$(at_run "$@"); then
		AT_CHECK_REASON=$(printf '%s\n' "$response" | tr -d '\r' | awk '/ERROR/ { print; exit }')
		[ -n "$AT_CHECK_REASON" ] || AT_CHECK_REASON="AT 命令执行失败"
		return 1
	fi
	if ! at_response_valid "$cmd" "$response"; then
		AT_CHECK_REASON=$(printf '%s\n' "$response" | tr -d '\r' | awk '/^[ \t]*\+?(CME|CMS)[ \t]+ERROR|^[ \t]*ERROR([ :]|$)/ { sub(/^[ \t]+/, ""); print; exit }')
		[ -n "$AT_CHECK_REASON" ] || AT_CHECK_REASON="响应缺少完整 OK 行"
		return 1
	fi
	return 0
}

# at_probe_port <port>：ATI 返回完整 OK 或合法厂商标识时判定为 AT 口
at_probe_port()
{
	at_check "$1" "ATI" 3
}
