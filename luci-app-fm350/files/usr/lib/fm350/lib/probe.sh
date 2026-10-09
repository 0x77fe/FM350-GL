# 分层探测（全部只读）
# 输出全局：P_RX P_TX（字节）/ K_V4_ADDR K_V4_ROUTE K_V4_GW / K_V6_ADDR K_V6_ROUTE K_V6_GW

probe_counters()
{
	local line
	line=$(awk -v f="$1:" '$1 == f { print $2, $10 }' /proc/net/dev 2>/dev/null)
	P_RX=$(echo "$line" | awk '{print $1}')
	P_TX=$(echo "$line" | awk '{print $2}')
	[ -n "$P_RX" ] || P_RX=0
	[ -n "$P_TX" ] || P_TX=0
}

probe_default_route()
{
	local family="$1" ifname="$2" routes route route_dev route_gw
	PROBE_ROUTE_MATCH=0
	PROBE_ROUTE_GW=""
	routes=$(ip -"$family" route show default 2>/dev/null)
	while IFS= read -r route; do
		set -- $route
		[ "${1:-}" = "default" ] || continue
		shift
		route_dev=""
		route_gw=""
		while [ "$#" -gt 0 ]; do
			case "$1" in
				via)
					shift
					route_gw="${1:-}"
				;;
				dev)
					shift
					route_dev="${1:-}"
				;;
			esac
			shift
		done
		[ "$route_dev" = "$ifname" ] || continue
		PROBE_ROUTE_MATCH=1
		PROBE_ROUTE_GW="$route_gw"
		return 0
	done <<EOF
$routes
EOF
	return 1
}

probe_v4_kernel()
{
	K_V4_ADDR=$(ip -4 addr show dev "$1" 2>/dev/null | awk '/inet /{print $2; exit}')
	K_V4_ROUTE=0
	K_V4_GW=""
	probe_default_route 4 "$1" && {
		K_V4_ROUTE=$PROBE_ROUTE_MATCH
		K_V4_GW=$PROBE_ROUTE_GW
	}
}

probe_v6_kernel()
{
	K_V6_ADDR=$(ip -6 addr show dev "$1" 2>/dev/null | awk '/global/{print $2; exit}')
	K_V6_ROUTE=0
	K_V6_GW=""
	probe_default_route 6 "$1" && {
		K_V6_ROUTE=$PROBE_ROUTE_MATCH
		K_V6_GW=$PROBE_ROUTE_GW
	}
}

# probe_v6_ping <target>：0=通 1=不通（默认不通）
probe_v6_ping()
{
	ping6 -c 2 -W 1 "$1" >/dev/null 2>&1
}

# probe_v4_at <port> <define_connect>：输出模块权威 IPv4（空=未拨通）
probe_v4_at()
{
	local cmd="AT+CGPADDR=$2" response
	response=$(at_run "$1" "$cmd") || return 1
	at_response_valid "$cmd" "$response" || return 1
	printf '%s\n' "$response" | grep "+CGPADDR: " | awk -F, '{print $2}' | sed 's/"//g' | tr -d '\r\n'
}
