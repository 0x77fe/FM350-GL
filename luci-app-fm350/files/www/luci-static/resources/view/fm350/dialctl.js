'use strict';
'require view';
'require ui';
'require uci';
'require rpc';

var callDial = rpc.declare({ object: 'fm350', method: 'dial_op', params: ['action'], expect: {} });

// 部分 LuCI 前端 ui 模块没有 setLoading，安全封装
function setLoading(on) {
	try { ui.setLoading(on); } catch (e) {}
}

// 通知封装：主题缺 .fade-out 过渡时 LuCI 的"关闭"按钮永不生效（transitionend 不触发）；
// 注入兜底过渡让关闭可用，并采用限时自动消失（8s）双保险
var NOTIFY_CSS = '.alert-message.fade-out{opacity:0 !important;transition:opacity .35s ease !important;}';
function notify(msg, type) {
	if (!document.getElementById('fm350-notify-css')) {
		var st = E('style', { 'id': 'fm350-notify-css' }, NOTIFY_CSS);
		document.head.appendChild(st);
	}
	return ui.addTimeLimitedNotification(null, E('p', {}, msg), 8000, type || 'info');
}

var STYLE = E('style', {}, [
	'.fm350-chip{display:inline-flex;align-items:center;gap:8px;padding:7px 14px;margin:0 10px 10px 0;',
	' border:1px solid var(--border-color,#e3e3e3);border-radius:999px;',
	' background:var(--background-nth,rgba(0,0,0,.04));font-size:.9rem;}',
	'.fm350-chip b{color:var(--text-secondary,#8a8a8a);font-weight:600;font-size:.8rem;}',
	'.fm350-action{display:flex;align-items:center;gap:14px;padding:10px 4px;',
	' border-bottom:1px solid var(--border-color,#ececec);}',
	'.fm350-action:last-child{border-bottom:none;}',
	'.fm350-action .btn{min-width:130px;margin:0;}',
	'.fm350-action .desc{flex:1;color:var(--text-secondary,#8a8a8a);font-size:.85rem;}',
	'.btn-danger{background:#cc3a3a;border-color:#cc3a3a;color:#fff;}',
	'.btn-danger:hover{background:#a92f2f;border-color:#a92f2f;}'
].join('\n'));

var ITEMS = [
	[ 'enable', '启用拨号', '', '' ],
	[ 'disable', '断开联网', '停用拨号并断开 PDP 上下文，链路中断', 'danger' ],
	[ 'reconnect', '重新拨号', '重新激活 PDP（可能短暂断网）', 'danger' ],
	[ 'ifup', '重建网络接口', '仅刷新 netifd 接口，不触碰模组', '' ],
	[ 'modem_restart', '软重启模组', 'AT+CFUN 重启，约 1 分钟断网', 'danger' ],
	[ 'usb_reset', 'USB 硬件复位', '假死无响应时使用，重新枚举模组 1~3 分钟断网', 'danger' ]
];

return view.extend({
	load: function() {
		return uci.load('fm350');
	},

	render: function() {
		var apn = uci.get('fm350', 'profile', 'apn') || 'ctnet';
		var pdp = uci.get('fm350', 'profile', 'pdp_type') || 'ipv4v6';
		var define = uci.get('fm350', 'profile', 'define_connect') || '3';
		var enable = uci.get('fm350', 'profile', 'enable');

		function chip(label, value) {
			return E('span', { 'class': 'fm350-chip' }, [
				E('b', {}, label),
				E('span', { 'style': 'font-weight:600' }, value)
			]);
		}

		var chips = E('div', {}, [
			chip('APN', apn),
			chip('PDP', pdp),
			chip('上下文', define),
			chip('拨号', enable === '1' ? '启用' : '停用')
		]);

		var actions = E('div', {});
		ITEMS.forEach(function(d) {
			var b = E('button', { 'class': 'btn' + (d[3] === 'danger' ? ' btn-danger' : '') }, d[1]);
			b.addEventListener('click', function() {
				if (d[0] === 'disable' && !window.confirm('断开后 5G 链路将中断，确定？'))
					return;
				if (d[0] === 'reconnect' && !window.confirm('将重新激活 PDP 上下文，可能短暂断网，确定？'))
					return;
				if (d[0] === 'modem_restart' && !window.confirm('模组重启期间网络中断约 1 分钟，确定？'))
					return;
				if (d[0] === 'usb_reset' && !window.confirm('USB 复位将重新枚举模组，网络中断 1~3 分钟，确定？'))
					return;
				setLoading(true);
				callDial(d[0]).then(function(r) {
					setLoading(false);
					notify(r.error ? ('操作失败: ' + r.error) : ('指令已入队: ' + d[1]),
						r.error ? 'error' : 'info');
				}).catch(function(e) {
					setLoading(false);
					notify('调用失败: ' + (e && (e.message || e.error) ? (e.message || e.error) : String(e)), 'error');
				});
			});
			actions.appendChild(E('div', { 'class': 'fm350-action' }, [
				b,
				E('span', { 'class': 'desc' }, d[2])
			]));
		});

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '拨号管理'),
			chips,
			E('p', { 'class': 'muted' }, '点击按钮后指令经由守护队列原子执行，无需停留在本页等待。'),
			actions,
			STYLE
		]);
	}
});
