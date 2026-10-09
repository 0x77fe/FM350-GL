'use strict';
'require baseclass';
'require ui';

// 页面共用的状态名称、配色、通知与轮询封装。
// LuCI 的 require 要求模块工厂返回构造器（内部会 new 一次并注册到 L.fm350.common），
// 所以这里用 baseclass.extend 返回类，引用方拿到的实例直接带下列方法。

var STATE_NAMES = {
	ABSENT: '模块离线',
	PRESENT: '模块就绪',
	DIALING: '拨号中',
	RECOVERING: '恢复中',
	ONLINE: '在线',
	DISABLED: '拨号已停用'
};

var STATE_COLORS = {
	ONLINE: '#2f8f4e',
	RECOVERING: '#c98b1f',
	ABSENT: '#cc3a3a',
	DIALING: '#3466d6',
	PRESENT: '#7d7d7d',
	DISABLED: '#7d7d7d'
};

// 主题缺 .fade-out 过渡时通知的关闭按钮不生效，注入兜底过渡并限时自动消失
var NOTIFY_CSS = '.alert-message.fade-out{opacity:0 !important;transition:opacity .35s ease !important;}';

return baseclass.extend({
	stateName: function(st) {
		return STATE_NAMES[st] || st;
	},

	stateColor: function(st) {
		return STATE_COLORS[st] || '#7d7d7d';
	},

	stateBadgeClass: function(st) {
		if (st === 'ONLINE')
			return 'label label-warning';
		if (st === 'RECOVERING' || st === 'ABSENT')
			return 'label label-error';
		if (st === 'DIALING')
			return 'label label-info';
		return 'label label-syslog';
	},

	notify: function(msg, type) {
		if (!document.getElementById('fm350-notify-css')) {
			var st = E('style', { 'id': 'fm350-notify-css' }, NOTIFY_CSS);
			document.head.appendChild(st);
		}
		return ui.addTimeLimitedNotification(null, E('p', {}, msg), 8000, type || 'info');
	},

	// 部分 LuCI 前端 ui 模块没有 setLoading
	setLoading: function(on) {
		try { ui.setLoading(on); } catch (e) {}
	},

	// 轮询：root 离开文档后自动注销，避免切换页面后残留定时器与请求
	poll: function(root, interval, fn) {
		var tick = function() {
			if (!root.isConnected) {
				L.Poll.remove(tick);
				return;
			}
			return fn();
		};
		L.Poll.add(tick, interval);
		return tick;
	}
});
