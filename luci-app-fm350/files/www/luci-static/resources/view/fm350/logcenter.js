'use strict';
'require view';
'require ui';
'require rpc';

var callLogs = rpc.declare({ object: 'fm350', method: 'logs', params: ['lines'], expect: {} });
var callEvents = rpc.declare({ object: 'fm350', method: 'events', params: ['lines'], expect: {} });
var callEventsClear = rpc.declare({ object: 'fm350', method: 'events_clear', expect: {} });

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

// 显示上限：超出自动移除旧行（只保留最近 N 行）
var MAX_LINES = 80;

function tailLines(text, n) {
	var arr = String(text || '').split('\n');
	while (arr.length > 0 && arr[arr.length - 1] === '')
		arr.pop();
	return arr.length > n ? arr.slice(arr.length - n).join('\n') : arr.join('\n');
}

var STYLE = E('style', {}, [
	'.fm350-log{max-height:340px;overflow:auto;border-radius:10px;padding:12px 14px;',
	' background:var(--code-background, rgba(20,24,30,.92));color:#d7e2ee;',
	' font-family:ui-monospace,Consolas,Menlo,monospace;font-size:.8rem;',
	' white-space:pre-wrap;word-break:break-all;line-height:1.6;}',
	'.fm350-logbar{display:flex;gap:8px;margin:0 0 10px;}'
].join('\n'));

return view.extend({
	render: function() {
		var pre1 = E('pre', { 'class': 'fm350-log' }, '加载中…');
		var pre2 = E('pre', { 'class': 'fm350-log' }, '加载中…');

		// 默认滚动到最新一行（底部）
		function scrollBottom(pre) {
			pre.scrollTop = pre.scrollHeight;
		}

		function refresh() {
			Promise.all([ callLogs(MAX_LINES + 40), callEvents(MAX_LINES + 40) ]).then(function(r) {
				pre1.textContent = tailLines(r[0].logs, MAX_LINES) || '（无 syslog 记录）';
				pre2.textContent = tailLines((r[1].events || []).join('\n'), MAX_LINES) || '（无事件）';
				scrollBottom(pre1);
				scrollBottom(pre2);
			}).catch(function(e) {
				pre1.textContent = /abort|Abort/i.test(String(e))
					? '请求被页面导航中断（属正常现象），点击"刷新"重试'
					: '获取失败: ' + e;
			});
		}

		function clearLogs() {
			pre1.textContent = '（已清除本页显示；系统日志本身保留，点击"刷新"可重新载入）';
		}

		function clearEvents() {
			if (!window.confirm('清空守护事件时间线？将删除事件文件内容（后续事件会重新累积）。'))
				return;
			callEventsClear().then(function(r) {
				var ok = r && r.ok;
				notify(ok ? '事件时间线已清空' : ('清除失败: ' + ((r && r.out) || 'unknown')), ok ? 'info' : 'error');
				pre2.textContent = ok ? '（事件已清空）' : pre2.textContent;
			}).catch(function(e) {
				notify('清除失败: ' + ((e && (e.message || e.error)) || e), 'error');
			});
		}

		var bar1 = E('div', { 'class': 'fm350-logbar' }, [
			E('button', { 'class': 'btn primary' }, '刷新'),
			E('button', { 'class': 'btn' }, '清除显示')
		]);
		bar1.children[0].addEventListener('click', refresh);
		bar1.children[1].addEventListener('click', clearLogs);

		var bar2 = E('div', { 'class': 'fm350-logbar' }, [
			E('button', { 'class': 'btn primary' }, '刷新'),
			E('button', { 'class': 'btn btn-danger' }, '清空事件')
		]);
		bar2.children[0].addEventListener('click', refresh);
		bar2.children[1].addEventListener('click', clearEvents);

		refresh();

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, '运行日志（logread · fm350）'),
			E('p', { 'class': 'muted' }, '旧 → 新排列（最新在底部），仅显示最近 ' + MAX_LINES + ' 行，打开即滚动到最新行'),
			bar1,
			pre1,
			E('h3', {}, '守护事件时间线'),
			E('p', { 'class': 'muted' }, '旧 → 新排列（最新在底部），仅显示最近 ' + MAX_LINES + ' 条'),
			bar2,
			pre2,
			STYLE
		]);
	}
});
