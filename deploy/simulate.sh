#!/bin/sh
# FM350 恢复能力测试脚本 —— 在路由器上执行
# 注意：选项 2/3 会中断本机网络，请选择无人使用网络的时段执行
echo "== FM350 恢复能力模拟 =="
echo " 1) IPv6 失效模拟    (ifdown wwan6_5g_0)  —— 守护会自动刷新，IPv4 不受影响"
echo " 2) IPv4 失联模拟    (ifdown wwan_5g_0)  —— 恢复约 1~5 分钟，期间断网"
echo " 3) 模块离线模拟    (手工拔掉 USB 线 60 秒后插回)  —— 恢复约 2~5 分钟，期间断网"
echo " 4) 只读检查       (fm350 check 干跑)"
read -r -p "请选择 [1-4]: " c
case "$c" in
	1)
		echo "执行: ifdown wwan6_5g_0（若未自动恢复，请检查概览页状态）"
		ifdown wwan6_5g_0
	;;
	2)
		echo "执行: ifdown wwan_5g_0 -> 25 秒后互检。断网期间请保持路由器通电。"
		ifdown wwan_5g_0
		sleep 25
		sh /usr/lib/fm350/fm350.sh check
	;;
	3)
		echo "请拔出 FM350 的 USB 线缆 60 秒，再插回。插回后本脚本自动等待 150 秒并检查。"
		sleep 60
		echo "已等待 60s，请现在插回 USB 线，并将继续等待 150s..."
		sleep 150
		sh /usr/lib/fm350/fm350.sh check
	;;
	4)
		sh /usr/lib/fm350/fm350.sh check
	;;
	*)
		echo "无效选择"; exit 1
	;;
esac
echo "完成。查看详细记录: logread | grep fm350"
