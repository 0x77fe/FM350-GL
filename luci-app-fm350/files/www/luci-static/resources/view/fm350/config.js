'use strict';
'require view';
'require form';

return view.extend({
	render: function() {
		var m = new form.Map('fm350', 'FM350 管理器设置', '修改后保存即生效（守护每轮重新读取配置）');

		var s = m.section(form.NamedSection, 'global', 'fm350', '全局');
		s.addremove = false;
		s.option(form.Flag, 'enabled', '启用管理器', '关闭后守护不再做任何探测与恢复动作');
		s.option(form.Value, 'interval', '轮询间隔（秒）', '探测与恢复检查周期，建议 5');
		s.option(form.Value, 'usb_vid_pid', '模块 USB VID:PID', '留空 = 自动识别模组（按串口 AT 应答定位）；也可手填如 0e8d:7127 指定');
		s.option(form.Value, 'at_port', 'AT 口（留空自动探测）', '例如 /dev/ttyUSB1；留空由守护探测');
		s.option(form.Value, 'usb_path_hint', 'USB 路径提示（仅告警用）', '例如 1-3.2，与现状不符时记录"位置变更"事件');
		s.option(form.Value, 'v4_ifname', 'IPv4 接口名', 'netifd 接口，默认 wwan_5g_0');
		s.option(form.Value, 'v6_ifname', 'IPv6 接口名', 'netifd 接口，默认 wwan6_5g_0');
		s.option(form.Flag, 'v6_alias', 'IPv6 别名绑定', 'dhcpv6 挂在 IPv4 接口别名上');

		var w = m.section(form.NamedSection, 'watch', 'fm350', '守护与恢复');
		w.addremove = false;
		w.option(form.Value, 'wait_timeout', 'L0 等待超时（秒）', '损毁后先等待自愈的时间');
		w.option(form.Value, 'recovery_timeout', 'L1 升级到模组重启时间（秒）');
		w.option(form.Value, 'usb_reset_timeout', 'L2 升级到 USB 复位时间（秒）');
		w.option(form.Value, 'restart_timeout', 'L3 告警循环周期（秒）');
		w.option(form.Value, 'cooldown', '动作冷却（秒）', '两次模组重启/USB 复位的最小间隔');
		w.option(form.Flag, 'usb_reset_enabled', '允许 USB 级复位', '关闭时到达该级别仅告警');
		w.option(form.Flag, 'frozen_enabled', '数据面冻结检测', '计数无变化直接 USB 复位（最对症）');
		w.option(form.Value, 'frozen_sample', '冻结判定时长（秒）');
		w.option(form.Value, 'frozen_grace', '冻结判定宽限期（秒）', '重拨/换IP/复位后的观察期，期间不判定假死');
		w.option(form.Flag, 'ipv6_check_enabled', 'IPv6 检测', '禁用后不刷新 IPv6');
		w.option(form.Value, 'ipv6_ping_target', 'IPv6 探测目标', '实测可靠的只有 2400:3200::1');
		w.option(form.Value, 'ipv6_ping_interval', 'IPv6 探测周期（秒）', '连续 2 次失败才判故障，单次 ICMP 抖动不触发恢复');
		w.option(form.Value, 'ipv4_ping_target', 'IPv4 活性探测目标', '假死判定用公共 DNS（网关 ICMP 通常被过滤，勿填网关）');
		w.option(form.Flag, 'ca_check_enabled', '载波聚合状态查询', '定期读取 AT+GTCAINFO? 并在界面展示（模组固件未提供 CA 使能/配置命令，此项仅控制监控）');
		w.option(form.Value, 'ca_interval', 'CA 查询周期（秒）');
		w.option(form.Flag, 'ipv6_escalate', 'IPv6 刷新失败升级', '连续 3 次刷新失败后升级整体恢复');
		w.option(form.Value, 'reappear_timeout', '离线告警时间（秒）', '模块消失超过该时长告警');

		var p = m.section(form.NamedSection, 'profile', 'fm350', '拨号配置');
		p.addremove = false;
		p.option(form.Flag, 'enable', '启用拨号', '停用后守护保持离线（可由拨号页切换）');
		p.option(form.Value, 'apn', 'APN');
		p.option(form.Value, 'pdp_type', 'PDP 类型', 'ipv4 / ipv6 / ipv4v6');
		p.option(form.Value, 'define_connect', 'PDP 上下文序号', '当前固件为 3');
		p.option(form.Flag, 'presets_enabled', '厂商预设', 'AT+GTAUTODHCP / GTIPPASS / GTAUTOCONNECT，默认关闭');

		var n = m.section(form.NamedSection, 'notify', 'fm350', '日志');
		n.addremove = false;
		n.option(form.Value, 'events_keep', '事件保留条数');

		return m.render();
	}
});
