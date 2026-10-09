# 所有 AT 调用者共享内核锁；卡住的 sms_tool 保留锁，禁止第二个串口写入者。
# at_run <port> <command> [timeout秒]：输出响应，超时强制结束
at_run()
(
	local port="$1" cmd="$2" timeout="${3:-8}" tmp pid t=0
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
		cat "$tmp"
		echo 'ERROR: AT timeout'
		exit 1
	fi
	cat "$tmp"
)

# at_check <port> <command>：响应含 OK 或厂商特征串即视为成功（ATI 应答未必带 OK）
at_check()
{
	at_run "$@" | grep -qE "OK|FM350|Fibocom|Manufacturer"
}

# at_probe_port <port>：ATI 返回 OK 判定为 AT 口
at_probe_port()
{
	at_check "$1" "ATI" 3
}
