'use strict';
'require view';
'require ui';
'require rpc';

var callStatus = rpc.declare({ object: 'fm350', method: 'status', expect: {} });
var callCell = rpc.declare({ object: 'fm350', method: 'cell', expect: {} });

var stateNames = {
	ABSENT: '模块离线',
	PRESENT: '模块就绪',
	DIALING: '拨号中',
	RECOVERING: '恢复中',
	ONLINE: '在线',
	DISABLED: '拨号已停用'
};

var stateColor = {
	ONLINE: '#2f8f4e',
	RECOVERING: '#c98b1f',
	ABSENT: '#cc3a3a',
	DIALING: '#3466d6',
	PRESENT: '#7d7d7d',
	DISABLED: '#7d7d7d'
};

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
	' font-family:ui-monospace,Consolas,Menlo,monospace;margin:2px 0 0;}'
].join('\n'));

function stateColorOf(st) {
	return stateColor[st] || '#7d7d7d';
}

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

return view.extend({
	load: function() {
		return Promise.all([
			callStatus(),
			callCell()
		]).then(function(r) {
			return { status: r[0], cell: r[1] };
		});
	},

	render: function(data) {
		var st = data.status.state || {};
		var at = data.status.at || {};
		var cc = (data.cell && data.cell.cell) || {};

		// ------ 卡片1: 模组信息状态 ------
		var modelVal = E('span', { 'class': 'fm350-mono' }, '-');
		if (at.ati) {
			var m = at.ati.match(/Model:\s*(\S+)/);
			var r = at.ati.match(/Revision:\s*(\S+)/);
			modelVal.textContent = (m ? m[1] : '') + (r ? ' · ' + r[1] : '') || (at.ati.split('\n')[0] || '-');
		}
		var simOk = /READY/.test(at.cpin || '');
		var simVal = E('span', {
			'class': 'fm350-pill ' + (simOk ? 'fm350-ok' : 'fm350-bad')
		}, simOk ? 'READY' : ((at.cpin || '').trim() || '未知'));
		var copsVal = E('span', {}, '-');
		if (at.cops) {
			var nm = at.cops.match(/"([^"]+)"/);
			copsVal.textContent = (nm ? nm[1] : at.cops.trim()) + (cc.rat ? ' · ' + cc.rat : '');
		}
		// 信号条：RSRP/RSRQ/SINR 三行，红/黄/绿分段着色
		var SIG_TIPS = {
			RSRP: '参考信号接收功率（信号强度），dBm，越接近 0 越强',
			RSRQ: '参考信号接收质量，dB，≥-10 良好，≤-15 差',
			SINR: 'SS-SINR（同步信号信干噪比，源自 3GPP AT+CESQ），dB，≥15 良好，≤5 差'
		};
		function sigRow(label, val, min, max, good, warn, unit) {
			var t = E('div', { 'style': 'display:flex;align-items:center;gap:8px;width:100%' }, [
				E('span', {
					'style': 'width:52px;color:var(--text-secondary,#8a8a8a);font-size:.8rem;cursor:help',
					'title': SIG_TIPS[label] || ''
				}, label),
				E('span', {
					'style': 'flex:1;height:8px;background:var(--border-color,#e8e8e8);' +
						'border-radius:999px;overflow:hidden'
				}, null),
				E('span', { 'class': 'fm350-mono', 'style': 'width:64px;text-align:right;font-size:.8rem' }, '—')
			]);
			var track = t.children[1], valEl = t.children[2];
			var v = parseFloat(val);
			if (!isNaN(v)) {
				var pct = (v - min) / (max - min) * 100;
				pct = Math.max(0, Math.min(100, pct));
				var color = v >= good ? '#2f8f4e' : v >= warn ? '#c98b1f' : '#cc3a3a';
				track.appendChild(E('div', {
					'style': 'height:100%;width:' + pct.toFixed(0) + '%;background:' + color + ';border-radius:999px'
				}));
				valEl.textContent = v + (unit || '');
			}
			return t;
		}

		function buildSig(ccData) {
			var box = E('div', {
				'style': 'width:100%;flex:1;min-width:0;display:flex;flex-direction:column;gap:6px;text-align:left'
			});
			if (ccData && ccData.rsrp) {
				box.appendChild(sigRow('RSRP', ccData.rsrp, -157, -60, -90, -105, ' dBm'));
				box.appendChild(sigRow('RSRQ', ccData.rsrq, -20, -3, -10, -15, ' dB'));
				box.appendChild(sigRow('SINR', ccData.sinr, -23, 40, 15, 5, ' dB'));
				box.appendChild(E('div', {
					'style': 'font-size:.75rem;color:var(--text-secondary,#8a8a8a)',
					'title': SIG_TIPS.RSRP + '；' + SIG_TIPS.RSRQ + '；' + SIG_TIPS.SINR
				}, 'RSRP 信号强度 · RSRQ 信号质量 · SINR 为 SS-SINR（AT+CESQ，dB，越高越好）'));
			} else if (ccData && ccData.raw) {
				box.appendChild(E('pre', { 'class': 'fm350-pre' }, String(ccData.raw).slice(0, 220)));
			} else {
				box.appendChild(E('span', { 'style': 'color:var(--text-secondary,#8a8a8a)' }, '暂无信号数据（等待快照）'));
			}
			return box;
		}

		var sigVal = buildSig(cc);

		var atOk = !!(st.net && st.net.at_port);
		var card1 = E('div', { 'class': 'fm350-card', 'style': 'flex:1.1' }, [
			E('div', { 'class': 'fm350-bar', 'style': 'background:#3466d6' }),
			E('div', { 'class': 'fm350-body' }, [
				E('h3', { 'class': 'fm350-title' }, '📡 模组信息状态'),
				E('p', { 'class': 'fm350-sub' }, 'FM350-GL · USB 自动发现'),
				row('型号 / 固件', modelVal),
				row('SIM 卡', simVal),
				row('运营商', copsVal),
				row('基站', E('span', { 'class': 'fm350-mono', 'style': 'font-size:.9rem' },
					(cc.mcc && cc.mnc ? 'MCC ' + cc.mcc + ' · MNC ' + cc.mnc : '') +
					(cc.tac ? ' · TAC ' + cc.tac : '') +
					(cc.cellid ? ' · ' + cc.cellid : '') +
					(cc.band ? ' · Band ' + cc.band : '') || '—')),
				E('div', { 'class': 'fm350-row', 'style': 'align-items:flex-start' }, [
					E('span', {
						'class': 'fm350-label',
						'title': '载波聚合（CA）：基站把多个载波（PCC 主载波 + SCC 辅载波）捆绑给本机使用以提升速率；未激活的 SCC 暂不参与聚合'
					}, '载波聚合'),
					(function() {
						var ca = st.ca || {};
						var box = E('div', { 'style': 'flex:1;min-width:0;display:flex;flex-direction:column;gap:4px;text-align:left' });
						if (ca.pcc_band === undefined && ca.raw === undefined) {
							box.appendChild(E('span', { 'style': 'color:var(--text-secondary,#8a8a8a)' }, '等待快照'));
							return box;
						}
						var pillTxt, pillCls, pillBg;
						if (ca.aggregated) {
							pillTxt = '已激活 ×' + (ca.scc_active || ca.scc_count);
							pillCls = 'fm350-pill fm350-ok';
							pillBg = '';
						} else if (ca.scc_count > 0) {
							pillTxt = '已配置未激活 ×' + ca.scc_count;
							pillCls = 'fm350-pill';
							pillBg = 'background:#7d7d7d';
						} else {
							pillTxt = '未聚合';
							pillCls = 'fm350-pill';
							pillBg = 'background:#7d7d7d';
						}
						box.appendChild(E('div', {}, [
							E('span', {
								'class': pillCls, 'style': pillBg,
								'title': '已激活=辅载波正在参与聚合（速率提升中）；已配置未激活=基站已下发但暂未启用，会按负载/省电策略动态切换'
							}, pillTxt),
							E('span', { 'style': 'margin-left:8px;font-size:.8rem;color:var(--text-secondary,#8a8a8a)' },
								ca.aggregated ? '辅载波参与提速中' : (ca.scc_count > 0 ? '辅载波待激活' : '仅单载波工作'))
						]));
						box.appendChild(E('div', { 'class': 'fm350-mono', 'style': 'font-size:.85rem' },
							'PCC: n' + ca.pcc_band + ' · PCI ' + (ca.pcc_pci || '-') + ' · ARFCN ' + (ca.pcc_arfcn || '-') +
							(ca.pcc_rsrp ? ' · ' + ca.pcc_rsrp + ' dBm' : '')));
						(ca.scc || []).forEach(function(s, i) {
							box.appendChild(E('div', { 'class': 'fm350-mono', 'style': 'font-size:.85rem' },
								'SCC' + (i + 1) + ': n' + (s.band || '-') + ' · PCI ' + (s.pci || '-') +
								' · ARFCN ' + (s.arfcn || '-') + (s.rsrp ? ' · ' + s.rsrp + ' dBm' : '') +
								'（' + (s.state === 2 ? '已激活' : '未激活') + '）'));
						});
						box.appendChild(E('div', { 'style': 'font-size:.75rem;color:var(--text-secondary,#8a8a8a)' },
							'PCC=主载波，SCC=辅载波；ARFCN 为频点号、PCI 为小区标识；未激活的 SCC 不计入聚合速率'));
						return box;
					})()
				]),
				E('div', { 'class': 'fm350-row', 'style': 'align-items:flex-start' }, [
					E('span', { 'class': 'fm350-label' }, '信号'),
					sigVal
				]),
				row('USB', E('span', { 'class': 'fm350-mono' },
					((st.usb && st.usb.path) || '未发现') +
					(st.usb && st.usb.vid ? ' · ' + st.usb.vid + ':' + st.usb.pid : ''))),
				row('AT 端口', E('span', { 'class': 'fm350-mono' },
					(st.net && st.net.at_port ? st.net.at_port : '未就绪')))
			])
		]);

		// ------ 卡片2: 网络与拨号状态 ------
		var netState = st.state || 'UNKNOWN';
		var badge = E('span', {
			'class': 'fm350-badge',
			'style': 'background:' + stateColorOf(netState)
		}, stateNames[netState] || netState);

		var probVal = E('span', {}, '一切正常');
		if (st.problem)
			probVal.textContent = st.problem_name + ' · L' + st.recovery_level + ' · ' + st.elapsed + 's';

		var v4RouteOk = !!(st.net && st.net.v4_route);
		var v4Val = E('span', {}, [
			E('span', { 'class': 'fm350-mono' }, (st.net && st.net.v4_at) || '未拨通'),
			E('span', { 'class': 'fm350-pill ' + (v4RouteOk ? 'fm350-ok' : 'fm350-bad') },
				v4RouteOk ? '路由正常' : '路由丢失')
		]);
		var v6RouteOk = !!(st.net && st.net.v6_route);
		var v6Val = E('span', {}, [
			E('span', { 'class': 'fm350-mono' }, (st.net && st.net.v6) || '无'),
			E('span', { 'class': 'fm350-pill ' + (v6RouteOk ? 'fm350-ok' : 'fm350-bad') },
				v6RouteOk ? '路由正常' : '路由丢失')
		]);
		var trVal = E('span', { 'class': 'fm350-mono' }, '↓ … · ↑ …');
		var rx = st.net && st.net.rx, tx = st.net && st.net.tx;
		trVal.textContent = '↓ ' + fmtBytes(rx) + ' · ↑ ' + fmtBytes(tx);

		var card2 = E('div', { 'class': 'fm350-card' }, [
			E('div', { 'class': 'fm350-bar', 'style': 'background:' + stateColorOf(netState) }),
			E('div', { 'class': 'fm350-body' }, [
				E('h3', { 'class': 'fm350-title' }, '🌐 网络与拨号状态'),
				E('p', { 'class': 'fm350-sub' }, '守护自动恢复 · 每 5s 刷新'),
				row('拨号状态', badge),
				row('当前问题', probVal),
				row('IPv4', v4Val),
				row('IPv6', v6Val),
				row('数据计数', trVal)
			])
		]);

		var body = E('div', { 'class': 'fm350-wrap' }, [ card1, card2 ]);
		body.appendChild(STYLE);

		// 60s 轮询：读守护快照（零串口竞争），原位刷新信号条
		setInterval(function() {
			callCell().then(function(d) {
				var n = (d && d.cell) || {};
				sigVal.replaceWith(buildSig(n));
			}).catch(function() {});
		}, 60000);

		// 轻量刷新：状态徽章 + 地址 + 计数
		setInterval(function() {
			callStatus().then(function(d) {
				var s2 = (d.state && d.state.state) || 'UNKNOWN';
				var n2 = (d.state && d.state.net) || {};
				badge.textContent = stateNames[s2] || s2;
				badge.style.background = stateColorOf(s2);
				card2.children[0].style.background = stateColorOf(s2);
				v4Val.children[0].textContent = n2.v4_at || '未拨通';
				var r4 = !!n2.v4_route;
				v4Val.children[1].textContent = r4 ? '路由正常' : '路由丢失';
				v4Val.children[1].className = 'fm350-pill ' + (r4 ? 'fm350-ok' : 'fm350-bad');
				v6Val.children[0].textContent = n2.v6 || '无';
				var r6 = !!n2.v6_route;
				v6Val.children[1].textContent = r6 ? '路由正常' : '路由丢失';
				v6Val.children[1].className = 'fm350-pill ' + (r6 ? 'fm350-ok' : 'fm350-bad');
				trVal.textContent = '↓ ' + fmtBytes(n2.rx) + ' · ↑ ' + fmtBytes(n2.tx);
			}).catch(function() {});
		}, 5000);

		return body;
	}
});
