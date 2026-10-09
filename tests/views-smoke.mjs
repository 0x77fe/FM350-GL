// Execute the LuCI view modules against a stub DOM and stub LuCI API.
// Covers render paths, in-place refresh, poll lifecycle and require resolution.
// Needs Node.js >= 18: node tests/views-smoke.mjs [resources-dir]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const RES = process.argv[2] || path.join(ROOT, 'luci-app-fm350/files/www/luci-static/resources');
const errors = [];
const ok = async (name, fn) => {
	try { await fn(); console.log('PASS ' + name); }
	catch (e) { errors.push(name + ': ' + (e && e.stack || e)); console.log('FAIL ' + name + ': ' + e.message); }
};

function Node(tag, attrs, children) {
	this.tagName = tag;
	this.attrs = attrs || {};
	this.childNodes = [];
	this.parentNode = null;
	this.style = {};
	this._text = '';
	this.className = this.attrs.class || '';
	this.id = this.attrs.id || null;
	this.title = this.attrs.title || null;
	this.isConnected = false;
	this.handlers = {};
	if (typeof children === 'string' || typeof children === 'number')
		this._text = String(children);
	else if (Array.isArray(children))
		children.forEach(c => this.appendChild(c));
	else if (children instanceof Node)
		this.appendChild(children);
}
Object.defineProperty(Node.prototype, 'firstChild', { get() { return this.childNodes[0] || null; } });
Object.defineProperty(Node.prototype, 'children', { get() { return this.childNodes; } });
Object.defineProperty(Node.prototype, 'textContent', {
	get() { return this.childNodes.length ? this.childNodes.map(c => c.textContent).join('') : this._text; },
	set(v) { this.childNodes = []; this._text = String(v); }
});
Node.prototype.appendChild = function (c) {
	if (!(c instanceof Node)) { this._text += String(c); return c; }
	if (c.parentNode) c.parentNode.removeChild(c);
	this.childNodes.push(c);
	c.parentNode = this;
	return c;
};
Node.prototype.removeChild = function (c) {
	const i = this.childNodes.indexOf(c);
	if (i >= 0) { this.childNodes.splice(i, 1); c.parentNode = null; }
	return c;
};
Node.prototype.addEventListener = function (ev, fn) { (this.handlers[ev] = this.handlers[ev] || []).push(fn); };
Node.prototype.click = function () { (this.handlers.click || []).forEach(fn => fn({})); };
Node.prototype.setAttribute = function (k, v) { this.attrs[k] = v; };
Node.prototype.querySelectorAll = function () { return []; };
Node.prototype.querySelector = function () { return null; };
Node.prototype.dispatchEvent = function () {};

const E = (tag, attrs, children) => new Node(tag, attrs, children);
const document = {
	head: new Node('head'),
	body: new Node('body'),
	getElementById: () => null,
	querySelector: () => null,
	querySelectorAll: () => [],
	addEventListener: () => {},
	createElement: t => new Node(t)
};
const window = { confirm: () => true, location: { href: '' }, console };
const _ = s => s;

// Shared queue: one L.Poll for every module, like the real LuCI singleton.
const POLL = [];
const L = {
	Poll: {
		add(fn, interval) { POLL.push({ fn, interval }); return true; },
		remove(fn) {
			const i = POLL.findIndex(e => e.fn === fn);
			if (i >= 0) POLL.splice(i, 1);
			return i >= 0;
		},
		start: () => true, stop: () => true, active: () => true
	}
};

function fakeForm() {
	function Section() { this.addremove = false; this.option = () => ({}); }
	return {
		Map: function () {
			this.section = () => new Section();
			this.render = () => E('div', { class: 'cbi-map' });
		},
		NamedSection: function () {}, Flag: function () {}, Value: function () {}, ListValue: function () {}
	};
}

const cache = new Map();
function load(name) {
	if (cache.has(name)) return cache.get(name);
	const file = path.join(RES, name.replace(/\./g, '/') + '.js');
	const src = fs.readFileSync(file, 'utf8');
	const scope = {
		E, document, window, _, console,
		view: { extend: o => o },
		ui: { setLoading: () => {}, addTimeLimitedNotification: () => {}, showModal: () => {} },
		rpc: { declare: spec => (...args) => Promise.resolve((scope.rpcHandlers[spec.method] || (() => ({})))(...args)) },
		rpcHandlers: {},
		uci: {
			load: () => Promise.resolve(),
			get: (pkg, sec, opt) => ({ apn: 'ctnet', pdp_type: 'ipv4v6', define_connect: '3', enable: '1' }[opt] || '1')
		},
		form: fakeForm(),
		L
	};
	const deps = {};
	for (const line of src.split('\n')) {
		const m = /^require\s+(\S+)(?:\s+as\s+(\S+))?\s*$/.exec(line.replace(/['";]/g, '').trim());
		if (!m) continue;
		const [, dep, as] = m;
		if (dep in scope) continue;
		deps[as || dep.replace(/[^a-zA-Z0-9_]/g, '_')] = load(dep).mod;
	}
	const names = Object.keys(scope).concat(Object.keys(deps));
	const mod = new Function(...names, src)(...names.map(k => (k in deps ? deps[k] : scope[k])));
	const exports = { mod, scope };
	cache.set(name, exports);
	return exports;
}

const richState = {
	state: 'RECOVERING', problem: 'v4', problem_name: 'IPv4', recovery_level: 2, elapsed: 61,
	usb: { present: true, path: '1-3', devnode: '/dev/bus/usb/001/004', vid: '0e8d', pid: '7127' },
	net: {
		ifname: 'wwan_5g_0', at_port: '/dev/ttyUSB2', v4_at: '10.20.30.40', v4_kernel: '10.20.30.40',
		v4_route: true, v6: '240e::1', v6_route: false, v6_gw: '', rx: 12345, tx: 67890
	},
	at: { ati: 'FM350-GL\nRevision: 1.0.0', cpin: '+CPIN: READY', cops: '+COPS: 0,0,"CHN-UNICOM",11' },
	cell: {
		rat: 'NR', netmode: 'NR5G-SA', mcc: '460', mnc: '01', tac: '1a2b', cellid: '1234567',
		band: '78', bw: '100', rsrp: '-95', rsrq: '-11', sinr: '18', ss_rsrp: '-94', ss_rsrq: '-10',
		ss_sinr: '18', raw: 'OK', model: 'FM350-GL'
	},
	ca: {
		aggregated: true, scc_count: 1, scc_active: 1,
		scc: [{ state: 2, band: '78', pci: '11', arfcn: '640000', rsrp: '-90' }],
		pcc_band: '78', pcc_pci: '10', pcc_arfcn: '630000', pcc_rsrp: '-92', raw: 'PCC:...'
	}
};
const emptyState = { state: 'ABSENT', usb: { present: false }, net: {}, at: {}, cell: {}, ca: {} };

const flush = async () => { for (let i = 0; i < 5; i++) await new Promise(r => setImmediate(r)); };
const collect = n => (n instanceof Node ? n.textContent : String(n));
function markConnected(n) {
	if (!(n instanceof Node)) return;
	n.isConnected = true;
	n.childNodes.forEach(markConnected);
}
function findByClass(n, cls) {
	const out = [];
	(function walk(x) {
		if (!(x instanceof Node)) return;
		if (x.className && String(x.className).split(/\s+/).includes(cls)) out.push(x);
		x.childNodes.forEach(walk);
	})(n);
	return out;
}
function expectText(text, wants, label) {
	for (const w of wants)
		if (!text.includes(w)) throw new Error(label + ' missing text: ' + w);
}

async function main() {
	const board = load('view/fm350/board');

	await ok('board:render(rich)', async () => {
		board.scope.rpcHandlers.status = () => ({ state: richState, at: richState.at });
		const node = board.mod.render(await board.mod.load());
		if (!node || node.tagName !== 'div') throw new Error('render did not return a node');
		expectText(collect(node), ['恢复中', 'FM350-GL', 'CHN-UNICOM', '10.20.30.40', '240e::1', '12.1 KB',
			'66.3 KB', 'IPv4 · L2 · 61s', '已激活 ×1', '-95 dBm', '18 dB'], 'board');
		markConnected(node);
	});

	await flush();
	await ok('board:poll-registered', async () => {
		if (POLL.length !== 1) throw new Error('poll not registered: ' + POLL.length);
	});

	await ok('board:poll-runs-without-error', async () => {
		board.scope.rpcHandlers.status = () => ({ state: emptyState, at: {} });
		POLL[0].fn();
		await flush();
	});

	await ok('board:poll-refreshes-all-fields', async () => {
		POLL.length = 0;
		const st = richState;
		board.scope.rpcHandlers.status = () => ({ state: st, at: st.at });
		const node = board.mod.render({ state: st, at: st.at });
		markConnected(node);
		expectText(collect(node), ['IPv4 · L2 · 61s', 'CHN-UNICOM · NR', '已激活 ×1'], 'board initial');

		const st2 = {
			state: 'ONLINE', problem: '', elapsed: 0,
			usb: { present: true, path: '1-3', vid: '0e8d', pid: '7127' },
			net: { at_port: '/dev/ttyUSB2', v4_at: '10.0.0.9', v4_route: true, v6: '240e::2', v6_route: true, rx: 1, tx: 2 },
			at: { ati: 'FM350-GL\nRevision: 2', cpin: '+CPIN: READY', cops: '+COPS: 0,0,"CMCC",7' },
			cell: { rat: 'LTE', rsrp: '-80', rsrq: '-8', sinr: '22' },
			ca: { scc_count: 0, pcc_band: '3' }
		};
		board.scope.rpcHandlers.status = () => ({ state: st2, at: st2.at });
		POLL[0].fn();
		await flush();
		const t2 = collect(node);
		expectText(t2, ['在线', '一切正常', 'CMCC · LTE', '10.0.0.9', '240e::2', '-80 dBm', '未聚合', '仅单载波工作'], 'board refresh');
		if (t2.includes('IPv4 · L2 · 61s')) throw new Error('stale problem text kept');
		POLL.length = 0;
	});

	await ok('board:render(empty)', async () => {
		const node = board.mod.render({ state: emptyState, at: {} });
		expectText(collect(node), ['模块离线', '未发现', '未拨通', '暂无信号数据（等待快照）', '等待快照', '一切正常'], 'board empty');
	});

	await ok('board:poll-self-removes-when-detached', async () => {
		POLL.length = 0;
		board.mod.render({ state: richState, at: richState.at });
		if (POLL.length !== 1) throw new Error('poll not registered on render');
		POLL[0].fn();
		if (POLL.length !== 0) throw new Error('detached poll not removed');
		const node = board.mod.render({ state: richState, at: richState.at });
		markConnected(node);
		const entry = POLL[0];
		entry.fn();
		if (!POLL.includes(entry)) throw new Error('attached poll removed');
		await flush();
		POLL.length = 0;
	});

	await ok('dataview:render+events', async () => {
		POLL.length = 0;
		const dv = load('view/fm350/dataview');
		dv.scope.rpcHandlers.status = () => ({ state: richState, at: richState.at });
		dv.scope.rpcHandlers.cell = () => ({ cell: richState.cell });
		dv.scope.rpcHandlers.events = () => ({ events: ['2026-10-09 10:00:00 模块离线'] });
		const node = dv.mod.render(await dv.mod.load());
		expectText(collect(node), ['模组/信号', '事件时间线', '模块离线', 'IPv4 内核地址', '当前问题', 'SS-RSRP -94'], 'dataview');
		markConnected(node);
		if (POLL.length !== 1) throw new Error('poll not registered');
		POLL[0].fn();
		await flush();
		POLL.length = 0;
	});

	await ok('atcon:render+quick-button', async () => {
		const ac = load('view/fm350/atcon');
		let sent = null;
		ac.scope.rpcHandlers.at_exec = cmd => { sent = cmd; return { resp: 'OK' }; };
		const node = ac.mod.render();
		expectText(collect(node), ['AT 命令控制台'], 'atcon');
		markConnected(node);
		findByClass(node, 'fm350-quickrow')[0].children[0].click();
		await flush();
		if (sent !== 'ATI') throw new Error('command not sent: ' + sent);
	});

	await ok('dialpan:render+action', async () => {
		const dp = load('view/fm350/dialpan');
		let action = null;
		dp.scope.rpcHandlers.dial_op = a => { action = a; return { queued: true }; };
		const node = dp.mod.render(await dp.mod.load());
		expectText(collect(node), ['拨号管理', '启用拨号', 'USB 硬件复位', 'ctnet'], 'dialpan');
		markConnected(node);
		findByClass(node, 'fm350-action')[0].children[0].click();
		await flush();
		if (action !== 'enable') throw new Error('action not submitted: ' + action);
	});

	await ok('logpanel:render+clear-events', async () => {
		const lp = load('view/fm350/logpanel');
		let cleared = false;
		lp.scope.rpcHandlers.logs = () => ({ logs: 'line1\nline2\n' });
		lp.scope.rpcHandlers.events = () => ({ events: ['e1', 'e2'] });
		lp.scope.rpcHandlers.events_clear = () => { cleared = true; return { ok: true }; };
		const node = lp.mod.render();
		expectText(collect(node), ['运行日志'], 'logpanel');
		markConnected(node);
		await flush();
		findByClass(node, 'fm350-logbar')[1].children[1].click();
		await flush();
		if (!cleared) throw new Error('events_clear not called');
		expectText(collect(node), ['line1'], 'logpanel');
	});

	await ok('config:render', async () => {
		if (!load('view/fm350/config').mod.render())
			throw new Error('render did not return a node');
	});

	await ok('requires:resolve-to-installed-files', async () => {
		const builtin = ['view', 'ui', 'rpc', 'uci', 'form', 'fs', 'poll'];
		for (const f of fs.readdirSync(path.join(RES, 'view/fm350'))) {
			const src = fs.readFileSync(path.join(RES, 'view/fm350', f), 'utf8');
			for (const line of src.split('\n')) {
				const m = /^'require\s+([^\s']+)(?:\s+as\s+\S+)?'\s*;?\s*$/.exec(line.trim());
				if (!m || builtin.includes(m[1])) continue;
				if (!fs.existsSync(path.join(RES, m[1].replace(/\./g, '/') + '.js')))
					throw new Error(f + ' unresolved dependency: ' + m[1]);
			}
		}
	});

	if (errors.length) {
		console.log('\n== failures ==\n' + errors.join('\n\n'));
		process.exit(1);
	}
	console.log('\nall view checks passed');
}

main().catch(e => { console.log('HARNESS ERROR: ' + (e.stack || e)); process.exit(1); });
