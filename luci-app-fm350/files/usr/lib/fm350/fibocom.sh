# 广和通厂商逻辑
#
# 版权与许可：本文件的信号/小区换算公式与解析结构抽取自 luci-app-modem v1.4.4
#   Copyright (C) 2023 Siriling <siriling@qq.com>
#   上游地址: https://github.com/qianlyun123/luci-app-modem （GPLv3）
# 本文件为其修改版，以 GPL-3.0-only 授权，全文见仓库根目录 LICENSE 或本包 LICENSE。
# 本程序不提供任何担保（NO WARRANTY）。
#
# 依赖 lib/at.sh（at_run）；取数走本项目 AT 层，解析结果写入全局变量 CL_* 供守护/UI 使用。

# fibocom_dns_v4 <port> <define_connect> <1|2>：输出运营商 IPv4 DNS（兜底公共DNS）
fibocom_dns_v4()
{
	local port="$1" define="$2" idx="$3" resp d1 d2
	[ -z "$define" ] && define="1"
	resp=$(at_run "$port" "AT+GTDNS=${define}" | grep "+GTDNS: " | grep -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sed -n '1p')
	d1=$(echo "$resp" | awk -F'"' '{print $2}' | awk -F, '{print $1}')
	d2=$(echo "$resp" | awk -F'"' '{print $4}' | awk -F, '{print $1}')
	[ -z "$d1" ] && d1="223.5.5.5"
	[ -z "$d2" ] && d2="119.29.29.29"
	if [ "$idx" = "2" ]; then echo "$d2"; else echo "$d1"; fi
}

# fibocom_get_rat <数字>
fibocom_get_rat()
{
	case $1 in
		"0"|"1"|"3"|"8") echo "GSM" ;;
		"2"|"4"|"5"|"6"|"9"|"10") echo "WCDMA" ;;
		"7") echo "LTE" ;;
		"11"|"12") echo "NR" ;;
	esac
}

fibocom_get_band()
{
	local band="$2"
	case $1 in
		"LTE") band=$((band - 100)) ;;
		# 手册：NR 编码为前缀拼接 "50"+n（501=n1、5010=n10、5078=n78、50512=n512），删前缀即得频段号
		"NR") band=${band#50} ;;
	esac
	echo "$band"
}

fibocom_get_bandwidth()
{
	local bandwidth=""
	case $1 in
		"LTE")
			case $2 in
				"6") bandwidth="1.4" ;;
				"15"|"25"|"50"|"75"|"100") bandwidth=$(( $2 / 5 )) ;;
			esac
		;;
		"NR")
			# FM350 手册 NR 带宽编码：25=5/50=10/75=15/100=20/125=25/150=30/200=40/
			# 250=50/300=60/400=80/450=90/500=100/1000=200/2000=400 (MHz)
			case $2 in
				"25") bandwidth="5" ;;
				"50") bandwidth="10" ;;
				"75") bandwidth="15" ;;
				"100") bandwidth="20" ;;
				"125") bandwidth="25" ;;
				"150") bandwidth="30" ;;
				"200") bandwidth="40" ;;
				"250") bandwidth="50" ;;
				"300") bandwidth="60" ;;
				"400") bandwidth="80" ;;
				"450") bandwidth="90" ;;
				"500") bandwidth="100" ;;
				"1000") bandwidth="200" ;;
				"2000") bandwidth="400" ;;
			esac
		;;
	esac
	echo "$bandwidth"
}

fibocom_get_rxlev()
{
	local rxlev=""
	case $1 in
		"GSM") rxlev=$(( $2 - 110 )) ;;
		"WCDMA") rxlev=$(( $2 - 121 )) ;;
		"LTE") rxlev=$(( $2 - 141 )) ;;
		"NR") rxlev=$(( $2 - 157 )) ;;
	esac
	echo "$rxlev"
}

fibocom_get_rsrp()
{
	local rsrp=""
	case $1 in
		"LTE") rsrp=$(( $2 - 141 )) ;;
		"NR") rsrp=$(( $2 - 156 )) ;;
	esac
	echo "$rsrp"
}

fibocom_get_rsrq()
{
	local rsrq=""
	case $1 in
		"LTE") rsrq=$(awk "BEGIN{ printf \"%.2f\", $2 * 0.5 - 20 }" | sed 's/\.*0*$//') ;;
		"NR") rsrq=$(awk -v n="$2" "BEGIN{ printf \"%.2f\", n / 2 - 43 }" | sed 's/\.*0*$//') ;;
	esac
	echo "$rsrq"
}

# fibocom_cesq <port>：解析 AT+CESQ 扩展位（3GPP SS-RSRQ/SS-RSRP/SS-SINR）
# 输出全局：SS_RSRQ SS_RSRP SS_SINR；字段为 255 或整行缺失时对应项留空
fibocom_cesq()
{
	local line c7 c8 c9

	SS_RSRQ=""
	SS_RSRP=""
	SS_SINR=""
	line=$(at_run "$1" "AT+CESQ" 4 | grep "^+CESQ:" | head -1)
	[ -n "$line" ] || return 1
	c7=$(echo "$line" | cut -d, -f7)
	c8=$(echo "$line" | cut -d, -f8)
	c9=$(echo "$line" | cut -d, -f9 | tr -d '\r')
	[ -n "$c7" ] && [ "$c7" != "255" ] && SS_RSRQ=$(awk "BEGIN{printf \"%.1f\", $c7/2 - 43}")
	[ -n "$c8" ] && [ "$c8" != "255" ] && SS_RSRP=$(awk "BEGIN{printf \"%d\", $c8 - 156}")
	[ -n "$c9" ] && [ "$c9" != "255" ] && SS_SINR=$(awk "BEGIN{printf \"%.1f\", $c9/2 - 23.25}")
	return 0
}

# fibocom_cainfo <port>：解析 AT+GTCAINFO?
# 输出全局：CA_JSON（含原始回显）；读不到 PCC 行时 CA_JSON 留空，由调用方保留上次快照
fibocom_cainfo()
{
	local raw pcc_line band_num pci arfcn rsrp band scc_line scc_body state
	local scc_band_num scc_band scc_pci scc_arfcn scc_rsrp active json total

	CA_JSON=""
	raw=$(at_run "$1" "AT+GTCAINFO?" 6)
	[ -n "$raw" ] || return 1
	# 行内字段以冒号后的空格分隔，先去掉空白再切字段
	pcc_line=$(echo "$raw" | grep "^PCC:" | head -1 | cut -d: -f2- | tr -d ' \r')
	[ -n "$pcc_line" ] || return 1

	band_num=$(echo "$pcc_line" | cut -d, -f1)
	pci=$(echo "$pcc_line" | cut -d, -f2)
	arfcn=$(echo "$pcc_line" | cut -d, -f3)
	rsrp=$(echo "$pcc_line" | awk -F, '{print $NF}')
	band=$(fibocom_get_band "NR" "$band_num")
	[ -n "$band" ] || band="$band_num"

	# SCC 字段（手册）：<scell_state>,<ul_configured>,<band>,<pci>,<narfcn>,…[,rssnr,rsrp,rsrq]
	# scell_state：1=已配置未激活，2=已配置已激活
	active=0
	json="[]"
	while IFS= read -r scc_line; do
		[ -n "$scc_line" ] || continue
		scc_body=$(echo "$scc_line" | cut -d: -f2- | tr -d ' \r')
		state=$(echo "$scc_body" | cut -d, -f1)
		scc_band_num=$(echo "$scc_body" | cut -d, -f3)
		scc_band=$(fibocom_get_band "NR" "$scc_band_num")
		[ -n "$scc_band" ] || scc_band="$scc_band_num"
		scc_pci=$(echo "$scc_body" | cut -d, -f4)
		scc_arfcn=$(echo "$scc_body" | cut -d, -f5)
		scc_rsrp=$(echo "$scc_body" | awk -F, '{print $NF}')
		[ "$state" = "2" ] && active=$((active + 1))
		json=$(echo "$json" | jq --arg st "$state" --arg b "$scc_band" \
			--arg p "$scc_pci" --arg a "$scc_arfcn" --arg r "$scc_rsrp" \
			'. + [{state:($st|tonumber? // 0), band:$b, pci:$p, arfcn:$a, rsrp:$r}]' 2>/dev/null)
	done <<EOF
$(echo "$raw" | grep "^SCC" | tr -d '\r')
EOF

	total=$(echo "$json" | jq 'length' 2>/dev/null)
	[ -n "$total" ] || total=0
	CA_JSON=$(jq -n --arg agg "$([ "$active" -gt 0 ] && echo 1 || echo 0)" \
		--arg scc "$total" --arg scc_active "$active" --argjson scc_list "$json" \
		--arg band "$band" --arg pci "$pci" \
		--arg arfcn "$arfcn" --arg rsrp "$rsrp" --arg raw "$(echo "$raw" | tr -d '\r')" \
		'{aggregated:($agg=="1"),scc_count:($scc|tonumber),scc_active:($scc_active|tonumber),scc:$scc_list,pcc_band:$band,pcc_pci:$pci,pcc_arfcn:$arfcn,pcc_rsrp:$rsrp,raw:$raw}' 2>/dev/null)
	[ -n "$CA_JSON" ] || return 1
	return 0
}

# fibocom_cellinfo <port> <define_connect>：解析 AT+GTCCINFO?
# 输出全局：CL_RAT CL_NETMODE CL_MCC CL_MNC CL_TAC CL_CELLID CL_BAND CL_BW CL_RSRP CL_RSRQ CL_SINR CL_RAW CL_MODEL
fibocom_cellinfo()
{
	local port="$1" define="$2" response rat_num rat resp rat2 model
	CL_RAT=""
	CL_NETMODE=""
	CL_MCC=""
	CL_MNC=""
	CL_TAC=""
	CL_CELLID=""
	CL_BAND=""
	CL_BW=""
	CL_RSRP=""
	CL_RSRQ=""
	CL_SINR=""
	CL_RAW=""

	CL_MODEL=$(at_run "$port" "ATI" 4 | grep -i -E "FM350" | head -1 | tr -d '\r')

	response=$(at_run "$port" "AT+GTCCINFO?" 6)
	CL_RAW="$response"

	# 联发科平台：GTCCINFO 无 "service" 行时退回 COPS? 取 RAT
	rat=$(echo "$response" | grep "service" | awk '{print $1}' | sed 's/:/ /g' | awk '{print $1}')
	[ -z "$rat" ] && {
		rat_num=$(at_run "$port" "AT+COPS?" 4 | grep "+COPS:" | awk -F, '{print $4}' | sed 's/\r//g')
		rat=$(fibocom_get_rat "$rat_num")
	}
	CL_RAT="$rat"

	case "$rat" in
		"NR") CL_NETMODE="NR5G-SA" ;;
		"LTE-NR") CL_NETMODE="EN-DC" ;;
		"LTE"|"eMTC"|"NB-IoT") CL_NETMODE="LTE" ;;
		"WCDMA"|"UMTS") CL_NETMODE="WCDMA" ;;
	esac

	for response in $response; do
		case "$response" in
			*","*)
				case "$rat" in
					"NR"|"LTE-NR")
						CL_MCC=$(echo "$response" | awk -F, '{print $3}')
						CL_MNC=$(echo "$response" | awk -F, '{print $4}')
						CL_TAC=$(echo "$response" | awk -F, '{print $5}')
						CL_CELLID=$(echo "$response" | awk -F, '{print $6}')
						CL_BAND=$(fibocom_get_band "NR" "$(echo "$response" | awk -F, '{print $9}')")
						CL_BW=$(fibocom_get_bandwidth "NR" "$(echo "$response" | awk -F, '{print $10}')")
						# 第 11 字段不是 SS-SINR，不解析为 SINR；SINR 由 AT+CESQ 提供
						CL_RSRP=$(fibocom_get_rsrp "NR" "$(echo "$response" | awk -F',' '{print $13}' | sed 's/\r//g')")
						CL_RSRQ=$(fibocom_get_rsrq "NR" "$(echo "$response" | awk -F',' '{print $14}' | sed 's/\r//g')")
					;;
					"LTE"|"eMTC"|"NB-IoT")
						CL_MCC=$(echo "$response" | awk -F, '{print $3}')
						CL_MNC=$(echo "$response" | awk -F, '{print $4}')
						CL_TAC=$(echo "$response" | awk -F, '{print $5}')
						CL_CELLID=$(echo "$response" | awk -F, '{print $6}')
						CL_BAND=$(fibocom_get_band "LTE" "$(echo "$response" | awk -F, '{print $9}')")
						CL_BW=$(fibocom_get_bandwidth "LTE" "$(echo "$response" | awk -F, '{print $10}')")
						CL_RSRP=$(fibocom_get_rsrp "LTE" "$(echo "$response" | awk -F',' '{print $13}' | sed 's/\r//g')")
						CL_RSRQ=$(fibocom_get_rsrq "LTE" "$(echo "$response" | awk -F',' '{print $14}' | sed 's/\r//g')")
					;;
					"WCDMA"|"UMTS")
						CL_MCC=$(echo "$response" | awk -F, '{print $3}')
						CL_MNC=$(echo "$response" | awk -F, '{print $4}')
						CL_TAC=$(echo "$response" | awk -F, '{print $5}')
						CL_CELLID=$(echo "$response" | awk -F, '{print $6}')
						CL_BAND=$(fibocom_get_band "WCDMA" "$(echo "$response" | awk -F, '{print $9}')")
						CL_RSRP=$(fibocom_get_rxlev "WCDMA" "$(echo "$response" | awk -F',' '{print $11}' | sed 's/\r//g')")
					;;
				esac
				break
			;;
		esac
	done

	[ -z "$CL_MCC" ] && [ -z "$CL_RSRP" ] && {
		# 解析失败：保留原始响应，供界面展示
		CL_RAW="$response"
	}
	return 0
}
