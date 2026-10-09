'use strict';
'require view';
'require ui';
'require rpc';
'require fm350.common as common';

var callStatus = rpc.declare({ object: 'fm350', method: 'status', expect: {} });

var STYLE = E('style', {}, [
	'.fm350-wrap{display:flex;flex-direction:column;gap:20px;align-items:stretch;}',
	'.fm350-card{flex:1 1 420px;height:auto;min-width:340px;border-radius:12px;',
	' background:var(--card-background,var(--main-background,#ffffff));',
	' border:1px solid var(--border-color,#e3e3e3);',
	' box-shadow:0 2px 10px rgba(0,0,0,.07);}',
	'.fm350-bar{height:6px;width:100%;border-radius:12px 12px 0 0;}',
	'.fm350-body{padding:14px 20px 16px;overflow:visible;}',
	'.fm350-title{font-size:1.05rem;font-weight:600;margin:0 0 4px;}',
	'.fm350-sub{font-size:.78rem;color:var(--text-secondary,#8a8a8a);margin:0 0 12px;}',
	'.fm350-row{display:flex;justify-content:space-between;align-items:center;gap:12px;',
	' padding:7px 0;border-bottom:1px dashed var(--border-color,#ececec);}',
	'.fm350-row:last-child{border-bottom:none;}',
	'.fm350-label{color:var(--text-secondary,#8a8a8a);font-size:.85rem;white-space:nowrap;}',
	'.fm350-val{font-weight:600;font-size:1rem;text-align:right;word-break:break-all;}',
	'.fm350-badge{padding:3px 16px;border-radius:999px;color:#fff;font-weight:700;font-size:.95rem;}',
	'.fm350-pill{padding:1px 10px;border-radius:999px;font-size:.8rem;font-weight:600;margin-left:8px;}',
	'.fm350-ok{background:var(--ok,#2f8f4e);}',
	'.fm350-bad{background:var(--err,#cc3a3a);}',
	'.fm350-warn{background:#c98b1f;}',
	'.fm350-mono{font-family:ui-monospace,Consolas,Menlo,monospace;font-size:.85rem;}',
	'.fm350-pre{white-space:pre-wrap;word-break:break-all;font-size:.8rem;',
	' font-family:ui-monospace,Consolas,Menlo,monospace;margin:2px 0 0;}',
	'.fm350-sig{display:flex;align-items:center;gap:8px;width:100%;}',
	'.fm350-sigtrack{flex:1;height:8px;background:var(--border-color,#e8e8e8);border-radius:999px;overflow:hidden;}',
	'.fm350-sigval{width:64px;text-align:right;font-size:.8rem;}',
	'.fm350-muted{color:var(--text-secondary,#8a8a8a);}'
].join('\n'));

function row(label, valEl) {
	return E('div', { 'class': 'fm350-row' }, [
		E('span', { 'class': 'fm350-label' }, label),
		E('span', { 'class': 'fm350-val' }, valEl)
	]);
}

function fmtBytes(n) {
	n = parseInt(n, 10) || 0;
	if (n < 1024)
		return n + ' B';
	if (n < 1024 * 1024)
		return (n / 1024).toFixed(1) + ' KB';
	return (n / 1024 / 1024).toFixed(1) + ' MB';
}

function setText(el, text) {
	if (el.textContent !== text)
		el.textContent = text;
}

function pillClass(ok) {
	return 'fm350-pill ' + (ok ? 'fm350-ok' : 'fm350-bad');
}

var SIG_TIPS = {
	RSRP: '参考信号接收功率（信号强度），dBm，越接近 0 越强',
	RSRQ: '参考信号接收质量，dB，≥-10 良好，≤-15 差',
	SINR: 'SS-SINR（同步信号信干噪比，源自 3GPP AT+CESQ），dB，≥15 良好，≤5 差'
};

// [名称, 色条下限, 色条上限, 良好阈值, 一般阈值, 单位]
var SIG_DEFS = [
	[ 'RSRP', -157, -60, -90, -105, ' dBm' ],
	[ 'RSRQ', -20, -3, -10, -15, ' dB' ],
	[ 'SINR', -23, 40, 15, 5, ' dB' ]
];

// 信号三行：色条原位更新，避免替换节点后引用失效
function signalBlock() {
	var bars = E('div', { 'style': 'display:flex;flex-direction:column;gap:6px' });
	var cells = {};

	SIG_DEFS.forEach(function(d) {
		var fill = E('div', { 'style': 'height:100%;width:0%;border-radius:999px' });
		var val = E('span', { 'class': 'fm350-mono fm350-sigval' }, '—');
		bars.appendChild(E('div', { 'class': 'fm350-sig' }, [
			E('span', {
				'style': 'width:52px;color:var(--text-secondary,#8a8a8a);font-size:.8rem;cursor:help',
				'title': SIG_TIPS[d[0]] || ''
			}, d[0]),
			E('span', { 'class': 'fm350-sigtrack' }, fill),
			val
		]));
		cells[d[0]] = { fill: fill, val: val, def: d };
	});

	var note = E('div', {
		'style': 'font-size:.75rem;color:var(--text-secondary,#8a8a8a)',
		'title': SIG_TIPS.RSRP + '；' + SIG_TIPS.RSRQ + '；' + SIG_TIPS.SINR
	}, 'RSRP 信号强度 · RSRQ 信号质量 · SINR 为 SS-SINR（AT+CESQ，dB，越高越好）');

	var raw = E('pre', { 'class': 'fm350-pre' });
	var wait = E('span', { 'class': 'fm350-muted' }, '暂无信号数据（等待快照）');

	var box = E('div', {
		'style': 'width:100%;flex:1;min-width:0;display:flex;flex-direction:column;gap:6px;text-align:left'
	}, [ bars, note, raw, wait ]);

	function update(cc) {
		cc = cc || {};
		var hasSig = !!cc.rsrp;
		var hasRaw = !hasSig && !!cc.raw;

		bars.style.display = hasSig ? '' : 'none';
		note.style.display = hasSig ? '' : 'none';
		raw.style.display = hasRaw ? '' : 'none';
		wait.style.display = hasSig || hasRaw ? 'none' : '';
		if (hasRaw)
			setText(raw, String(cc.raw).slice(0, 220));
		if (!hasSig)
			return;

		SIG_DEFS.forEach(function(d) {
			var cell = cells[d[0]];
			var v = parseFloat(cc[d[0].toLowerCase()]);
			if (isNaN(v)) {
				cell.fill.style.width = '0%';
				setText(cell.val, '—');
				return;
			}
			var pct = Math.max(0, Math.min(100, (v - d[1]) / (d[2] - d[1]) * 100));
			cell.fill.style.width = pct.toFixed(0) + '%';
			cell.fill.style.background = v >= d[3] ? '#2f8f4e' : v >= d[4] ? '#c98b1f' : '#cc3a3a';
			setText(cell.val, v + d[5]);
		});
	}

	update(null);
	return { el: box, update: update };
}

// 载波聚合：PCC 固定三行文本，SCC 行按数量重建
function caBlock() {
	var wait = E('span', { 'class': 'fm350-muted' }, '等待快照');
	var pill = E('span', {
		'class': 'fm350-pill',
		'title': '已激活=辅载波正在参与聚合（速率提升中）；已配置未激活=基站已下发但暂未启用，会按负载/省电策略动态切换'
	}, '未聚合');
	var pillNote = E('span', { 'style': 'margin-left:8px;font-size:.8rem;color:var(--text-secondary,#8a8a8a)' });
	var pcc = E('div', { 'class': 'fm350-mono' });
	var scc = E('div', {});
	var hint = E('div', { 'style': 'font-size:.75rem;color:var(--text-secondary,#8a8a8a)' },
		'PCC=主载波，SCC=辅载波；ARFCN 为频点号、PCI 为小区标识；未激活的 SCC 不计入聚合速率');
	var body = E('div', {
		'style': 'display:none;flex-direction:column;gap:4px'
	}, [ E('div', {}, [ pill, pillNote ]), pcc, scc, hint ]);

	var box = E('div', {
		'style': 'flex:1;min-width:0;display:flex;flex-direction:column;gap:4px;text-align:left'
	}, [ wait, body ]);

	function update(ca) {
		ca = ca || {};
		if (ca.pcc_band === undefined && ca.raw === undefined) {
			wait.style.display = '';
			body.style.display = 'none';
			return;
		}
		wait.style.display = 'none';
		body.style.display = 'flex';

		if (ca.aggregated) {
			pill.className = 'fm350-pill fm350-ok';
			pill.style.background = '';
			setText(pill, '已激活 ×' + (ca.scc_active || ca.scc_count));
		}
		else {
			pill.className = 'fm350-pill';
			pill.style.background = '#7d7d7d';
			setText(pill, ca.scc_count > 0 ? '已配置未激活 ×' + ca.scc_count : '未聚合');
		}
		setText(pillNote, ca.aggregated ? '辅载波参与提速中' : (ca.scc_count > 0 ? '辅载波待激活' : '仅单载波工作'));
		setText(pcc, 'PCC: n' + ca.pcc_band + ' · PCI ' + (ca.pcc_pci || '-') + ' · ARFCN ' + (ca.pcc_arfcn || '-') +
			(ca.pcc_rsrp ? ' · ' + ca.pcc_rsrp + ' dBm' : ''));

		while (scc.firstChild)
			scc.removeChild(scc.firstChild);
		(ca.scc || []).forEach(function(s, i) {
			scc.appendChild(E('div', { 'class': 'fm350-mono' },
				'SCC' + (i + 1) + ': n' + (s.band || '-') + ' · PCI ' + (s.pci || '-') +
				' · ARFCN ' + (s.arfcn || '-') + (s.rsrp ? ' · ' + s.rsrp + ' dBm' : '') +
				'（' + (s.state === 2 ? '已激活' : '未激活') + '）'));
		});
	}

	update(null);
	return { el: box, update: update };
}

return view.extend({
	load: function() {
		return callStatus();
	},

	render: function(data) {
		var st = (data && data.state) || {};
		var at = (data && data.at) || {};

		// 卡片1: 模组信息状态
		var modelVal = E('span', { 'class': 'fm350-mono' }, '-');
		var simVal = E('span', { 'class': 'fm350-pill fm350-bad' }, '未知');
		var copsVal = E('span', {}, '-');
		var stationVal = E('span', { 'class': 'fm350-mono', 'style': 'font-size:.9rem' }, '—');
		var usbVal = E('span', { 'class': 'fm350-mono' }, '未发现');
		var atPortVal = E('span', { 'class': 'fm350-mono' }, '未就绪');
		var snapshotVal = E('span', { 'class': 'fm350-mono', 'style': 'font-size:.85rem' }, '未采集');

		var sig = signalBlock();
		var ca = caBlock();

		var card1 = E('div', { 'class': 'fm350-card', 'style': 'flex:1.1' }, [
			E('div', { 'class': 'fm350-bar', 'style': 'background:#3466d6' }),
			E('div', { 'class': 'fm350-body' }, [
				E('h3', { 'class': 'fm350-title' }, '📡 模组信息状态'),
				E('p', { 'class': 'fm350-sub' }, 'FM350-GL · USB 自动发现'),
				row('型号 / 固件', modelVal),
				row('SIM 卡', simVal),
				row('运营商', copsVal),
				row('基站', stationVal),
				row('信息快照', snapshotVal),
				E('div', { 'class': 'fm350-row', 'style': 'align-items:flex-start' }, [
					E('span', { 'class': 'fm350-label' }, '载波聚合'),
					ca.el
				]),
				E('div', { 'class': 'fm350-row', 'style': 'align-items:flex-start' }, [
					E('span', { 'class': 'fm350-label' }, '信号'),
					sig.el
				]),
				row('USB', usbVal),
				row('AT 端口', atPortVal)
			])
		]);

		// 卡片2: 网络与拨号状态
		var badge = E('span', { 'class': 'fm350-badge' }, '未知');
		var probVal = E('span', {}, '一切正常');
		var disconnectVal = E('span', {}, '—');
		var v4Text = E('span', { 'class': 'fm350-mono' }, '未拨通');
		var v4Pill = E('span', { 'class': 'fm350-pill fm350-bad' }, '路由丢失');
		var v6Text = E('span', { 'class': 'fm350-mono' }, '无');
		var v6Pill = E('span', { 'class': 'fm350-pill fm350-bad' }, '路由丢失');
		var trVal = E('span', { 'class': 'fm350-mono' }, '↓ 0 B · ↑ 0 B');
		var card2Bar = E('div', { 'class': 'fm350-bar' });

		var card2 = E('div', { 'class': 'fm350-card' }, [
			card2Bar,
			E('div', { 'class': 'fm350-body' }, [
				E('h3', { 'class': 'fm350-title' }, '🌐 网络与拨号状态'),
				E('p', { 'class': 'fm350-sub' }, '守护自动恢复 · 每 5s 刷新'),
				row('拨号状态', badge),
				row('停用断开', disconnectVal),
				row('当前问题', probVal),
				row('IPv4', E('span', {}, [ v4Text, v4Pill ])),
				row('IPv6', E('span', {}, [ v6Text, v6Pill ])),
				row('数据计数', trVal)
			])
		]);

		function applyStatus(state, atData) {
			state = state || {};
			atData = atData || {};
			var net = state.net || {};
			var usb = state.usb || {};
			var cc = state.cell || {};
			var snaps = state.snapshot || {};
			function snapshotAge(name, fallbackAge) {
				var item = snaps[name] || {};
				if (!item.updated_at)
					return '未采集';
				if (!item.available)
					return '不可用';
				var maxAge = item.interval || fallbackAge;
				var age = Math.max(0, Math.floor(Date.now() / 1000 - item.updated_at));
				return age > maxAge * 2 ? '陈旧 ' + age + 's' : age + 's';
			}

			// 模组信息
			setText(modelVal, '-');
			if (atData.ati) {
				var m = atData.ati.match(/Model:\s*(\S+)/);
				var r = atData.ati.match(/Revision:\s*(\S+)/);
				setText(modelVal, (m ? m[1] : '') + (r ? ' · ' + r[1] : '') || (atData.ati.split('\n')[0] || '-'));
			}
			var simOk = /READY/.test(atData.cpin || '');
			simVal.className = 'fm350-pill ' + (simOk ? 'fm350-ok' : 'fm350-bad');
			setText(simVal, simOk ? 'READY' : ((atData.cpin || '').trim() || '未知'));

			setText(copsVal, '-');
			if (atData.cops) {
				var nm = atData.cops.match(/"([^"]+)"/);
				setText(copsVal, (nm ? nm[1] : atData.cops.trim()) + (cc.rat ? ' · ' + cc.rat : ''));
			}

			setText(stationVal,
				(cc.mcc && cc.mnc ? 'MCC ' + cc.mcc + ' · MNC ' + cc.mnc : '') +
				(cc.tac ? ' · TAC ' + cc.tac : '') +
				(cc.cellid ? ' · ' + cc.cellid : '') +
				(cc.band ? ' · Band ' + cc.band : '') || '—');
			setText(usbVal, (usb.path || '未发现') + (usb.vid ? ' · ' + usb.vid + ':' + usb.pid : ''));
			setText(atPortVal, net.at_port || '未就绪');
			setText(snapshotVal, 'AT ' + snapshotAge('at', 30) + ' · 小区 ' + snapshotAge('cell', 120) +
				' · CA ' + snapshotAge('ca', 120));
			sig.update(cc);
			ca.update(state.ca);

			// 网络与拨号
			var netState = state.state || 'UNKNOWN';
			setText(badge, common.stateName(netState));
			badge.style.background = common.stateColor(netState);
			card2Bar.style.background = common.stateColor(netState);
			var profile = state.profile || {};
			var disconnectNames = {
				enabled: '拨号已启用',
				disabled: '已停用 / PDP 已断开',
				pending: '待断开',
				failed: '断开失败，稍后重试'
			};
			setText(disconnectVal, disconnectNames[profile.disconnect_status] || '—');

			setText(probVal, state.problem
				? state.problem_name + ' · L' + state.recovery_level + ' · ' + state.elapsed + 's'
				: '一切正常');

			setText(v4Text, net.v4_at || '未拨通');
			v4Pill.className = pillClass(!!net.v4_route);
			setText(v4Pill, net.v4_route ? '路由正常' : '路由丢失');

			setText(v6Text, net.v6 || '无');
			v6Pill.className = pillClass(!!net.v6_route);
			setText(v6Pill, net.v6_route ? '路由正常' : '路由丢失');

			setText(trVal, '↓ ' + fmtBytes(net.rx) + ' · ↑ ' + fmtBytes(net.tx));
		}

		applyStatus(st, at);

		var body = E('div', { 'class': 'fm350-wrap' }, [ card1, card2 ]);
		body.appendChild(STYLE);

		common.poll(body, 5, function() {
			return callStatus().then(function(d) {
				applyStatus((d && d.state) || {}, (d && d.at) || {});
			}).catch(function() {});
		});

		return body;
	}
});
