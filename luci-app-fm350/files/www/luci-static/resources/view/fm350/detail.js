'use strict';
'require view';
'require ui';
'require rpc';

var callStatus = rpc.declare({ object: 'fm350', method: 'status', params: ['quick'], expect: {} });
var callCell = rpc.declare({ object: 'fm350', method: 'cell', expect: {} });
var callEvents = rpc.declare({ object: 'fm350', method: 'events', params: ['lines'], expect: {} });

var stateNames = {
	ABSENT: '模块离线',
	PRESENT: '模块就绪',
	DIALING: '拨号中',
	RECOVERING: '恢复中',
	ONLINE: '在线',
	DISABLED: '拨号已停用'
};

function badge(st) {
	var cls = 'syslog';
	if (st === 'ONLINE')
		cls = 'warning';
	else if (st === 'RECOVERING' || st === 'ABSENT')
		cls = 'error';
	else if (st === 'DIALING')
		cls = 'info';

	return E('span', { 'class': 'label label-' + cls }, stateNames[st] || st);
}

function row(label, value) {
	return E('tr', {}, [
		E('th', { 'class': 'col-xs-4' }, label),
		E('td', {}, value)
	]);
}

function table(title, rows) {
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, title),
		E('table', { 'class': 'table' }, E('tbody', {}, rows))
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			callStatus(),
			callCell(),
			callEvents(15)
		]).then(function(r) {
			return { status: r[0], cell: r[1], events: r[2] };
		});
	},

	render: function(data) {
		var st = data.status.state || {};
		var at = data.status.at || {};

		var modRows = [];
		if (at.ati)
			modRows.push(row('型号', E('pre', { 'style': 'white-space:pre-wrap;margin:0' }, at.ati)));
		if (at.cpin)
			modRows.push(row('SIM', at.cpin));
		if (at.cops)
			modRows.push(row('运营商', at.cops));
		if (st.net && st.net.at_port)
			modRows.push(row('AT 端口', st.net.at_port));

		var cc = (data.cell && data.cell.cell) || {};
		if (cc.raw || cc.rsrp) {
			var sigTip = 'RSRP 信号强度(dBm,越接近0越强)；RSRQ 信号质量(dB,≥-10 良好)；SINR 为 SS-SINR（源自 AT+CESQ，dB,≥15 良好）';
			var sig = E('span', { 'title': sigTip, 'style': 'cursor:help' }, [
				(cc.netmode ? cc.netmode + ' | ' : '') +
				(cc.band ? 'Band ' + cc.band + (cc.bw ? ' (' + cc.bw + 'MHz)' : '') + ' | ' : '') +
				(cc.rsrp ? 'RSRP ' + cc.rsrp + 'dBm | ' : '') +
				(cc.rsrq ? 'RSRQ ' + cc.rsrq + 'dB | ' : '') +
				(cc.sinr ? 'SINR ' + cc.sinr : '')
			]);
			if (!cc.rsrp && cc.raw)
				sig.appendChild(E('pre', { 'style': 'white-space:pre-wrap;margin:0' }, cc.raw));
			modRows.push(row('信号', sig));
			if (cc.ss_rsrp || cc.ss_rsrq || cc.ss_sinr) {
				modRows.push(row('信号（CESQ 对照）', E('span', {
					'style': 'font-family:var(--font-mono,monospace);font-size:.85rem'
				}, 'SS-RSRP ' + (cc.ss_rsrp || '-') + ' dBm · SS-RSRQ ' + (cc.ss_rsrq || '-') +
					' dB · SS-SINR ' + (cc.ss_sinr || '-') + ' dB')));
			}
			modRows.push(row('基站', E('span', { 'style': 'font-family:var(--font-mono,monospace);font-size:.85rem' },
				(cc.mcc && cc.mnc ? 'MCC ' + cc.mcc + ' · MNC ' + cc.mnc : '') +
				(cc.tac ? ' · TAC ' + cc.tac : '') +
				(cc.cellid ? ' · 小区 ' + cc.cellid : '') +
				(cc.band ? ' · Band ' + cc.band : '') || '—')));
		}

		var ca = st.ca || {};
		if (ca.raw || ca.pcc_band) {
			var caState = ca.aggregated
				? '已激活（' + (ca.scc_active || ca.scc_count) + ' 个辅载波）'
				: (ca.scc_count > 0 ? '已配置未激活（' + ca.scc_count + ' 个辅载波）' : '未聚合');
			var caEl = E('span', {}, [
				E('b', {}, caState),
				ca.pcc_band
					? ' ｜ PCC n' + ca.pcc_band + ' · ARFCN ' + (ca.pcc_arfcn || '-') +
					  ' · PCI ' + (ca.pcc_pci || '-') + ' · ' + (ca.pcc_rsrp || '-') + ' dBm'
					: ''
			]);
			(ca.scc || []).forEach(function(s, i) {
				caEl.appendChild(E('div', { 'style': 'font-size:.82rem' },
					'SCC' + (i + 1) + ': n' + (s.band || '-') + ' · PCI ' + (s.pci || '-') +
					' · ARFCN ' + (s.arfcn || '-') + (s.rsrp ? ' · ' + s.rsrp + ' dBm' : '') +
					'（' + (s.state === 2 ? '已激活' : '未激活') + '）'));
			});
			if (ca.raw)
				caEl.appendChild(E('pre', { 'style': 'white-space:pre-wrap;margin:2px 0 0;font-size:.78rem' }, String(ca.raw)));
			modRows.push(row('载波聚合', caEl));
		}

		var stateEl = badge(st.state);
		var netRows = [
			row('守护状态', stateEl),
			row('USB 路径', st.usb && st.usb.path
				? st.usb.path + (st.usb.vid ? ' · ' + st.usb.vid + ':' + st.usb.pid : '') +
				  (st.usb.devnode ? ' (' + st.usb.devnode + ')' : '')
				: '未发现'),
			row('网络接口', st.net && st.net.ifname ? st.net.ifname : '未就绪'),
			row('IPv4（AT 权威）', st.net && st.net.v4_at ? st.net.v4_at : '未拨通'),
			row('IPv4 内核地址', st.net && st.net.v4_kernel ? st.net.v4_kernel : '无'),
			row('IPv4 路由', st.net && st.net.v4_route ? '正常' : '丢失'),
			row('IPv6 地址', st.net && st.net.v6 ? st.net.v6 : '无'),
			row('IPv6 路由', st.net && st.net.v6_route ? '正常(' + (st.net.v6_gw ? st.net.v6_gw : '') + ')' : '丢失')
		];

		if (st.problem) {
			netRows.push(row('当前问题', st.problem_name + '（级别 ' + st.recovery_level + '，已持续 ' + st.elapsed + 's）'));
		}

		var evRows = [];
		(data.events && data.events.events || []).forEach(function(l) {
			evRows.push(E('tr', {}, E('td', {}, E('code', {}, l))));
		});

		var body = E('div', {}, [
			table('模组/信号', modRows),
			table('网络与守护', netRows),
			table('事件时间线', evRows.length ? evRows : E('td', {}, '无事件'))
		]);

		body.appendChild(E('style', {}, [
			'.fm350-pre{white-space:pre-wrap;word-break:break-all;margin:0;',
			' font-family:ui-monospace,Consolas,Menlo,monospace;font-size:.8rem;}'
		].join('\n')));

		setInterval(function() {
			callStatus().then(function(d) {
				var s2 = (d.state || {}).state;
				var cls = 'syslog';
				if (s2 === 'ONLINE')
					cls = 'warning';
				else if (s2 === 'RECOVERING' || s2 === 'ABSENT')
					cls = 'error';
				else if (s2 === 'DIALING')
					cls = 'info';
				stateEl.textContent = stateNames[s2] || s2;
				stateEl.className = 'label label-' + cls;
			}).catch(function() {});
		}, 5000);

		return body;
	}
});
