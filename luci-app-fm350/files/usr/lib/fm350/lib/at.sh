# AT 通道封装（sms_tool + 看门狗；路由器无 timeout 命令）
# 注意：不做 wait 回收（sms_tool 若陷入不可中断等待，wait 会让调用方（ucode popen）永久挂起）；
# 临时文件按进程固定复用（进程内串行调用，覆盖写即可，避免文件无限制膨胀）
# at_run <port> <command> [timeout秒]：输出响应，超时强制结束
at_run()
{
	local port="$1" cmd="$2" timeout="${3:-8}" tmp pid t
	tmp="${RU}/at.$$"
	: > "$tmp"
	sms_tool -d "$port" at "$cmd" > "$tmp" 2>&1 &
	pid=$!
	t=0
	while [ "$t" -lt "$timeout" ] && kill -0 "$pid" 2>/dev/null; do
		sleep 1
		t=$((t + 1))
	done
	kill -9 "$pid" 2>/dev/null
	cat "$tmp"
}

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
