#!/bin/sh
# Parse fixtures for the vendor module. The AT responses below follow the manual field
# layout, not hardware captures; replace them with real captures once a modem is attached.
# Run with BusyBox ash on Linux or OpenWrt:  sh tests/parse-samples.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$ROOT/luci-app-fm350/files/usr/lib/fm350"
RU="${TMPDIR:-/tmp}/fm350-parse-$$"
mkdir -p "$RU"

. "$LIB/lib/at.sh"

S_ATI=""
S_CCINFO=""
S_CESQ=""
S_CAINFO=""

at_run()
{
	case "$2" in
		ATI) echo "$S_ATI" ;;
		AT+GTCCINFO?) echo "$S_CCINFO" ;;
		AT+CESQ) echo "$S_CESQ" ;;
		AT+GTCAINFO?) echo "$S_CAINFO" ;;
		*) echo "" ;;
	esac
}

. "$LIB/fibocom.sh"

assert_eq()
{
	[ "$1" = "$2" ] || { echo "FAIL $3: expected '$2', got '$1'" >&2; exit 1; }
	echo "PASS $3"
}

assert_empty()
{
	[ -z "$1" ] || { echo "FAIL $2: expected empty, got '$1'" >&2; exit 1; }
	echo "PASS $2"
}

# 频段与带宽换算
assert_eq "$(fibocom_get_band NR 5078)" 78 band-nr-prefix
assert_eq "$(fibocom_get_band NR 78)" 78 band-nr-plain
assert_eq "$(fibocom_get_band LTE 103)" 3 band-lte-offset
assert_eq "$(fibocom_get_bandwidth NR 25)" 5 bw-nr-25
assert_eq "$(fibocom_get_bandwidth NR 1000)" 200 bw-nr-1000
assert_eq "$(fibocom_get_bandwidth LTE 100)" 20 bw-lte-100
assert_eq "$(fibocom_get_rat 7)" LTE rat-lte
assert_eq "$(fibocom_get_rat 11)" NR rat-nr

# NR 服务小区：raw 61 → -95 dBm，raw 64 → -11 dB（SINR 不再从 GTCCINFO 解析）
S_ATI="FM350-GL
Revision: 1.0.0"
S_CCINFO="AT+GTCCINFO?
+GTCCINFO:
NR service cell:
0,0,460,01,1a2b,1234567,630000,10,78,100,10,30,61,64
OK"
fibocom_cellinfo /dev/mock 3 >/dev/null || true
assert_eq "$CL_RAT" NR cellinfo-nr-rat
assert_eq "$CL_NETMODE" NR5G-SA cellinfo-nr-netmode
assert_eq "$CL_MCC" 460 cellinfo-nr-mcc
assert_eq "$CL_MNC" 01 cellinfo-nr-mnc
assert_eq "$CL_TAC" 1a2b cellinfo-nr-tac
assert_eq "$CL_CELLID" 1234567 cellinfo-nr-cellid
assert_eq "$CL_BAND" 78 cellinfo-nr-band
assert_eq "$CL_BW" 20 cellinfo-nr-bw
assert_eq "$CL_RSRP" -95 cellinfo-nr-rsrp
assert_eq "$CL_RSRQ" -11 cellinfo-nr-rsrq
assert_empty "$CL_SINR" cellinfo-nr-no-sinr
assert_eq "$CL_MODEL" "FM350-GL" cellinfo-nr-model

# LTE 服务小区：raw 46 → -95 dBm，raw 18 → -11 dB，频段 103 → B3
S_CCINFO="AT+GTCCINFO?
+GTCCINFO:
LTE service cell:
0,0,460,01,1a2b,1234567,1650,10,103,100,10,30,46,18
OK"
fibocom_cellinfo /dev/mock 3 >/dev/null || true
assert_eq "$CL_RAT" LTE cellinfo-lte-rat
assert_eq "$CL_NETMODE" LTE cellinfo-lte-netmode
assert_eq "$CL_BAND" 3 cellinfo-lte-band
assert_eq "$CL_BW" 20 cellinfo-lte-bw
assert_eq "$CL_RSRP" -95 cellinfo-lte-rsrp
assert_eq "$CL_RSRQ" -11 cellinfo-lte-rsrq

# 空响应：不解析任何字段，且不报错（界面回退到原始回显）
S_CCINFO=""
fibocom_cellinfo /dev/mock 3 >/dev/null || true
assert_empty "$CL_RSRP" cellinfo-empty-rsrp
assert_empty "$CL_BAND" cellinfo-empty-band

# CESQ 扩展位：raw 61 → -95 dBm，raw 64 → -11.0 dB，raw 80 → 16.8 dB
S_CESQ="AT+CESQ
+CESQ: 99,99,255,255,54,60,64,61,80
OK"
fibocom_cesq /dev/mock >/dev/null
assert_eq "$SS_RSRP" -95 cesq-ss-rsrp
assert_eq "$SS_RSRQ" -11.0 cesq-ss-rsrq
assert_eq "$SS_SINR" 16.8 cesq-ss-sinr

# CESQ 无效位（255）留空
S_CESQ="+CESQ: 99,99,255,255,54,60,255,255,255
OK"
fibocom_cesq /dev/mock >/dev/null
assert_empty "$SS_RSRP" cesq-invalid-rsrp
assert_empty "$SS_RSRQ" cesq-invalid-rsrq
assert_empty "$SS_SINR" cesq-invalid-sinr

# CESQ 整行缺失：留空且不报错
S_CESQ=""
fibocom_cesq /dev/mock >/dev/null || true
assert_empty "$SS_SINR" cesq-missing-sinr

# 载波聚合：PCC 78/10/630000/-92，SCC 5078 → B78 且已激活
S_CAINFO="AT+GTCAINFO?
PCC: 78,10,630000,-92
SCC: 2,1,5078,11,640000,0,0,-90
OK"
if command -v jq >/dev/null 2>&1; then
	fibocom_cainfo /dev/mock >/dev/null
	# printf（而非 echo）：ash/dash 的内建 echo 会把 JSON 里的 \n 转义还原成真实换行
	assert_eq "$(printf '%s' "$CA_JSON" | jq -r .aggregated)" true ca-aggregated
	assert_eq "$(printf '%s' "$CA_JSON" | jq -r .scc_count)" 1 ca-scc-count
	assert_eq "$(printf '%s' "$CA_JSON" | jq -r .scc_active)" 1 ca-scc-active
	assert_eq "$(printf '%s' "$CA_JSON" | jq -r .pcc_band)" 78 ca-pcc-band
	assert_eq "$(printf '%s' "$CA_JSON" | jq -r .pcc_pci)" 10 ca-pcc-pci
	assert_eq "$(printf '%s' "$CA_JSON" | jq -r .pcc_rsrp)" -92 ca-pcc-rsrp
	assert_eq "$(printf '%s' "$CA_JSON" | jq -r '.scc[0].band')" 78 ca-scc-band
	assert_eq "$(printf '%s' "$CA_JSON" | jq -r '.scc[0].state')" 2 ca-scc-state
	assert_eq "$(printf '%s' "$CA_JSON" | jq -r '.scc[0].rsrp')" -90 ca-scc-rsrp

	# 未激活的辅载波不计入聚合
	S_CAINFO="PCC: 78,10,630000,-92
SCC: 1,1,5078,11,640000,0,0,-90
OK"
	fibocom_cainfo /dev/mock >/dev/null
	assert_eq "$(printf '%s' "$CA_JSON" | jq -r .aggregated)" false ca-inactive-aggregated
	assert_eq "$(printf '%s' "$CA_JSON" | jq -r .scc_active)" 0 ca-inactive-scc-active

	# 无 PCC 行：CA_JSON 留空，调用方标记本轮快照不可用
	S_CAINFO="AT+GTCAINFO?
OK"
	if fibocom_cainfo /dev/mock; then
		echo "FAIL ca-missing-pcc: should report failure" >&2
		exit 1
	fi
	assert_empty "$CA_JSON" ca-missing-pcc
else
	echo "SKIP carrier aggregation samples (jq not found)"
fi

# 完整 ERROR 行优先于同一响应里的 OK；错误查询不能留下可用解析值。
S_CCINFO="+GTCCINFO: LTE service cell:
0,0,460,01,1a2b,1234567,1650,10,103,100,10,30,46,18
ERROR
OK"
if fibocom_cellinfo /dev/mock 3 >/dev/null; then
	echo "FAIL cellinfo-error-plus-ok: query reported success" >&2
	exit 1
fi
assert_empty "$CL_RAW" cellinfo-error-clears-raw
S_CESQ="+CESQ: 99,99,255,255,54,60,64,61,80
+CME ERROR: 10
OK"
if fibocom_cesq /dev/mock >/dev/null; then
	echo "FAIL cesq-error-plus-ok: query reported success" >&2
	exit 1
fi
assert_empty "$SS_SINR" cesq-error-clears-values
S_CAINFO="PCC: 78,10,630000,-92
ERROR
OK"
if fibocom_cainfo /dev/mock >/dev/null; then
	echo "FAIL cainfo-error-plus-ok: query reported success" >&2
	exit 1
fi
assert_empty "$CA_JSON" cainfo-error-clears-json

echo "PASS parse-samples"
