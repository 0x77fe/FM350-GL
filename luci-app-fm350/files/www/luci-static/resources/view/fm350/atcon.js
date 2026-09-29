'use strict';
'require view';
'require ui';
'require rpc';

var callAt = rpc.declare({ object: 'fm350', method: 'at_exec', params: ['cmd'], expect: {} });
var dangerRe = /AT\+CFUN|GTUSBMODE|QCRMCALL|GTIPPASS|GTAUTOCONNECT/;

// 部分 LuCI 前端 ui 模块没有 setLoading，安全封装
function setLoading(on) {
	try { ui.setLoading(on); } catch (e) {}
}

var STYLE = E('style', {}, [
	'.fm350-console{max-height:420px;overflow:auto;border-radius:10px;padding:12px 14px;',
	' background:var(--code-background, rgba(20,24,30,.92));color:#d7e2ee;',
	' font-family:ui-monospace,Consolas,Menlo,monospace;font-size:.85rem;',
	' white-space:pre-wrap;word-break:break-all;line-height:1.5;}',
	'.fm350-inputrow{display:flex;gap:8px;margin:10px 0 6px;}',
	'.fm350-inputrow .cbi-input-text{flex:1;}',
	'.fm350-quickrow{margin:8px 0 14px;}',
	'.fm350-quickrow .btn{margin:0 6px 6px 0;}'
].join('\n'));

return view.extend({
	render: function() {
		var input = E('input', {
			'class': 'cbi-input-text',
			'placeholder': '例如: AT+CPIN?   AT+COPS?   AT+GTCCINFO?',
			'style': 'max-width:420px'
		});
		var out = E('pre', { 'class': 'fm350-console' }, '发送命令后在此显示结果…');

		function send(cmd) {
			if (!cmd)
				return;
			if (dangerRe.test(cmd) && !window.confirm('该命令可能中断网络连接，确定发送？'))
				return;
			out.textContent += '>> ' + cmd + '\n… 发送中（最长 15s）…\n';
			out.scrollTop = out.scrollHeight;
			setLoading(true);
			var timer = setTimeout(function() {
				out.textContent += '[无响应] 后端 20s 未返回（串口可能正被守护占用），可稍后重试\n\n';
				out.scrollTop = out.scrollHeight;
			}, 20000);
			callAt(cmd).then(function(d) {
				clearTimeout(timer);
				setLoading(false);
				if (d.error) {
					out.textContent += '[错误] ' + d.error + '\n\n';
				} else {
					out.textContent += (d.resp && d.resp.trim() ? d.resp : '（空响应：命令可能不被支持或串口繁忙，请重试）') + '\n\n';
				}
				out.scrollTop = out.scrollHeight;
			}).catch(function(e) {
				clearTimeout(timer);
				setLoading(false);
				out.textContent += '[错误] ' + e + '\n\n';
			});
		}

		var btn = E('button', { 'class': 'btn primary' }, '发送');
		btn.addEventListener('click', function() {
			send(input.value.trim());
		});
		input.addEventListener('keydown', function(e) {
			if (e.key === 'Enter')
				send(input.value.trim());
		});

		var quick = [ 'ATI', 'AT+CPIN?', 'AT+CSQ', 'AT+COPS?', 'AT+CGDCONT?', 'AT+CGPADDR=3', 'AT+GTDNS=3', 'AT+GTCCINFO?', 'AT+CFUN=1,1' ];
		var quickRow = E('div', { 'class': 'fm350-quickrow' });
		quick.forEach(function(c) {
			var b = E('button', { 'class': 'btn' }, c);
			b.addEventListener('click', function() {
				input.value = c;
				send(c);
			});
			quickRow.appendChild(b);
		});

		var body = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, 'AT 命令控制台'),
			E('p', { 'class': 'muted' }, '串口自动探测 · 10s 看门狗 · 破坏性命令需二次确认'),
			E('div', { 'class': 'fm350-inputrow' }, [ input, btn ]),
			quickRow,
			out,
			STYLE
		]);
		return body;
	}
});
