'use strict';
'require view';
'require form';
'require fs';
'require poll';
'require uci';
'require ui';

/*
 * The status helper is deliberately a constant.  This view never accepts a
 * command, path or argument from the browser and never starts or stops the
 * controller directly.  Saving UCI lets the core init script's reload trigger
 * reconcile the running controller.
 */
var STATUS_PATH = '/usr/libexec/ax9000-fan-status';
var STATUS_POLL_SECONDS = 5;
var DEFAULTS = {
	enabled: '1',
	poll_seconds: '5',
	hysteresis_c: '3',
	temp_warm: '55',
	temp_hot: '62',
	temp_max: '70',
	pwm_cool: '110',
	pwm_warm: '160',
	pwm_hot: '210',
	pwm_max: '255',
	zero_rpm_limit: '3'
};

function asNumber(value) {
	if (value === null || value === undefined || value === '' || !/^-?\d+(?:\.\d+)?$/.test(String(value))) return null;
	var number = Number(value);
	return isFinite(number) ? number : null;
}

function isCanonicalUnsignedInteger(value) {
	return /^(?:0|[1-9]\d*)$/.test(String(value));
}

function booleanValue(value) {
	return value === true || value === 1 || value === '1' || value === 'true' || value === 'yes';
}

function faultValue(value) {
	if (value === false || value === 0 || value === '0' || value === '' || value === null || value === undefined || value === 'false' || value === 'none') return false;
	return Boolean(value);
}

function parseStatusResult(result) {
	if (!result || typeof result.stdout !== 'string' || !result.stdout.trim())
		throw new Error(result && result.stderr ? result.stderr : '状态程序没有返回数据');

	var payload = JSON.parse(result.stdout);
	if (!payload || typeof payload !== 'object' || Array.isArray(payload))
		throw new Error('状态程序返回格式无效');

	/* A non-zero exit is the documented fault signal. Preserve its JSON so the
	 * operator can still see temperature, RPM, PWM and the fault reason. */
	if (Number(result.code) !== 0 && !faultValue(payload.fault))
		payload.transport_error = result.stderr || '状态程序异常退出';

	return payload;
}

function faultDescription(value) {
	var labels = {
		controller_not_found: '未检测到 EMC2301/EMC2305 控制器',
		fan_not_found: '未检测到风扇 PWM 接口',
		tachometer_unavailable: '风扇转速传感器不可读',
		zero_rpm: '风扇连续零转速，已进入全速保护',
		no_sensor: '没有可用温度传感器，已进入全速保护',
		pwm_write_error: 'PWM 写入失败',
		no_sensor_pwm_write_error: '温度传感器故障且 PWM 写入失败',
		runtime_dir_error: '运行目录不可用',
		pidfile_error: '服务状态文件不可写',
		disabled_fullspeed_error: '自动控制已禁用，但未能确认风扇全速，系统正在重试',
		disabled: '自动控制已禁用，风扇保持全速'
	};
	if (!value) return '未提供故障详情';
	if (labels[value]) return labels[value];
	if (String(value).indexOf('unsupported_board:') === 0)
		return '当前设备不在 AX9000 支持列表：' + String(value).slice('unsupported_board:'.length);
	if (String(value).indexOf('config_error:') === 0)
		return '配置无效：' + String(value).slice('config_error:'.length);
	return String(value);
}

function sectionNumber(option, sectionId, name) {
	var value = option.section.formvalue(sectionId, name);
	if (value === null || value === undefined || value === '') value = uci.get('ax9000-fan', sectionId, name);
	if (value === null || value === undefined || value === '') value = DEFAULTS[name];
	return asNumber(value);
}

function integerRange(min, max, message) {
	return function(sectionId, value) {
		if (!isCanonicalUnsignedInteger(value)) return '请输入不带前导零的整数。';
		var number = Number(value);
		if (!isFinite(number) || number < min || number > max) return message;
		return true;
	};
}

function temperatureValidator(min, maxAllowed, message) {
	return function(sectionId, value) {
		if (!isCanonicalUnsignedInteger(value)) return '请输入不带前导零的整数。';
		var number = asNumber(value);
		if (number === null || Math.floor(number) !== number || number < min || number > maxAllowed) return message;
		var warm = sectionNumber(this, sectionId, 'temp_warm');
		var hot = sectionNumber(this, sectionId, 'temp_hot');
		var max = sectionNumber(this, sectionId, 'temp_max');
		if (warm !== null && hot !== null && max !== null && !(warm < hot && hot < max)) return '温度曲线必须满足：温暖 < 高温 < 最高。';
		var hysteresis = sectionNumber(this, sectionId, 'hysteresis_c');
		if (hysteresis !== null && warm !== null && hot !== null && hot - warm < hysteresis) return '温暖与高温阈值之差不能小于回差。';
		if (hysteresis !== null && hot !== null && max !== null && max - hot < hysteresis) return '高温与最高阈值之差不能小于回差。';
		return true;
	};
}

function hysteresisValidator(sectionId, value) {
	if (!isCanonicalUnsignedInteger(value)) return '请输入不带前导零的整数。';
	var number = asNumber(value);
	if (number === null || Math.floor(number) !== number || number < 1 || number > 20) return '回差必须是 1–20 °C 的整数。';
	var warm = sectionNumber(this, sectionId, 'temp_warm');
	var hot = sectionNumber(this, sectionId, 'temp_hot');
	var max = sectionNumber(this, sectionId, 'temp_max');
	if (warm !== null && number > warm) return '回差不能让温暖档下降阈值低于 0 °C。';
	if (warm !== null && hot !== null && number > hot - warm) return '回差过大，会让温暖和高温下降阈值重叠。';
	if (hot !== null && max !== null && number > max - hot) return '回差过大，会让高温和最高下降阈值重叠。';
	return true;
}

function pwmValidator() {
	return function(sectionId, value) {
		if (!isCanonicalUnsignedInteger(value)) return '请输入不带前导零的整数。';
		var number = asNumber(value);
		if (number === null || Math.floor(number) !== number || number < 1 || number > 255) return 'PWM 必须是 1–255 的整数。';
		var cool = sectionNumber(this, sectionId, 'pwm_cool');
		var warm = sectionNumber(this, sectionId, 'pwm_warm');
		var hot = sectionNumber(this, sectionId, 'pwm_hot');
		var max = sectionNumber(this, sectionId, 'pwm_max');
		if (cool !== null && warm !== null && hot !== null && max !== null && !(cool <= warm && warm <= hot && hot <= max)) return 'PWM 曲线必须满足：冷却 ≤ 温暖 ≤ 高温 ≤ 最高。';
		if (this.option === 'pwm_max' && number !== 255) return '最高 PWM 必须保持为 255，以保留故障全速保护。';
		return true;
	};
}

function text(node, value) {
	if (node) node.textContent = value === null || value === undefined || value === '' ? '—' : String(value);
}

function formatTemperature(value) {
	var mC = asNumber(value);
	if (mC === null || mC < -20000 || mC > 200000) return '—';
	return (mC / 1000).toFixed(1) + ' °C';
}

function formatRpm(value) {
	var rpm = asNumber(value);
	return rpm === null || rpm < 0 ? '—' : Math.round(rpm) + ' RPM';
}

function formatPwm(value) {
	var pwm = asNumber(value);
	if (pwm === null || pwm < 0 || pwm > 255) return '—';
	return Math.round(pwm * 100 / 255) + '% (' + Math.round(pwm) + '/255)';
}

function formatSource(value) {
	if (typeof value !== 'string' || !value) return '温度源：—';
	return '温度源：' + value;
}

function formatProfile(profile, thresholds) {
	var name = typeof profile === 'string' ? profile : (profile && profile.name ? profile.name : '自动曲线');
	if (thresholds && typeof thresholds === 'object') {
		var warm = thresholds.warm !== undefined ? thresholds.warm : thresholds.temp_warm;
		var hot = thresholds.hot !== undefined ? thresholds.hot : thresholds.temp_hot;
		var max = thresholds.max !== undefined ? thresholds.max : thresholds.temp_max;
		if (warm !== undefined && hot !== undefined && max !== undefined) name += ' · ' + warm + ' / ' + hot + ' / ' + max + ' °C';
	}
	return name;
}

function statusError(error) {
	if (!error) return '状态程序没有返回数据。';
	return error.message || String(error);
}

function buildMap() {
	var map = new form.Map('ax9000-fan', 'AX9000 风扇控制', '修改配置后请点击底部“保存并应用”。这会写入 UCI，并由核心 init 的 reload trigger 重载控制器；页面不提供立即停转或把风扇设为 0 的快捷操作。');
	var section = map.section(form.NamedSection, 'main', 'ax9000_fan', '风扇控制参数', '参数仅描述自动曲线；硬件故障时核心控制器仍应执行全速保护。');
	section.anonymous = true;
	section.addremove = false;

	section.tab('temperature', '温度曲线', '按最高温度选择冷却、温暖、高温和最高档。温度输入单位为摄氏度。');
	section.tab('output', '风扇输出', 'PWM 为 1–255 的原始输出值，页面不会直接写入硬件，也不允许设置为停转。');
	section.tab('protection', '保护', '轮询与零转速保护由核心服务执行；改动后由 init reload trigger 应用。');

	var enabled = section.taboption('protection', form.Flag, 'enabled', '启用自动风扇控制', '关闭后不再按温度曲线调速；请确认设备有独立散热保护。');
	enabled.enabled = '1';
	enabled.disabled = '0';
	enabled.default = DEFAULTS.enabled;
	enabled.rmempty = false;

	var pollSeconds = section.taboption('protection', form.Value, 'poll_seconds', '温度轮询周期（秒）', '核心控制器每隔 1–3600 秒读取一次温度。状态面板固定每 5 秒刷新。');
	pollSeconds.datatype = 'range(1, 3600)';
	pollSeconds.default = DEFAULTS.poll_seconds;
	pollSeconds.rmempty = false;
	pollSeconds.inputmode = 'numeric';
	pollSeconds.validate = integerRange(1, 3600, '轮询周期必须为 1–3600 秒。');

	var zeroRpm = section.taboption('protection', form.Value, 'zero_rpm_limit', '零转速保护次数', '连续检测到 0 RPM 达到该次数后，核心服务报告故障并保持全速保护。范围 1–60 次。');
	zeroRpm.datatype = 'range(1, 60)';
	zeroRpm.default = DEFAULTS.zero_rpm_limit;
	zeroRpm.rmempty = false;
	zeroRpm.inputmode = 'numeric';
	zeroRpm.validate = integerRange(1, 60, '零转速保护次数必须为 1–60。');

	var hysteresis = section.taboption('temperature', form.Value, 'hysteresis_c', '下降回差（°C）', '仅用于降档：1–20 °C。回差不能让下降阈值低于 0 °C 或与相邻档重叠。');
	hysteresis.datatype = 'range(1, 20)';
	hysteresis.default = DEFAULTS.hysteresis_c;
	hysteresis.rmempty = false;
	hysteresis.inputmode = 'numeric';
	hysteresis.validate = hysteresisValidator;

	var tempWarm = section.taboption('temperature', form.Value, 'temp_warm', '温暖阈值（°C）', '达到该温度时使用温暖 PWM；范围 30–100 °C，且必须低于高温阈值。');
	tempWarm.datatype = 'range(30, 100)';
	tempWarm.default = DEFAULTS.temp_warm;
	tempWarm.rmempty = false;
	tempWarm.inputmode = 'numeric';
	tempWarm.validate = temperatureValidator(30, 100, '温暖阈值必须是 30–100 °C 的整数。');

	var tempHot = section.taboption('temperature', form.Value, 'temp_hot', '高温阈值（°C）', '达到该温度时使用高温 PWM；范围 31–110 °C，且必须位于温暖与最高之间。');
	tempHot.datatype = 'range(31, 110)';
	tempHot.default = DEFAULTS.temp_hot;
	tempHot.rmempty = false;
	tempHot.inputmode = 'numeric';
	tempHot.validate = temperatureValidator(31, 110, '高温阈值必须是 31–110 °C 的整数。');

	var tempMax = section.taboption('temperature', form.Value, 'temp_max', '最高阈值（°C）', '达到该温度时使用最高 PWM；范围 32–120 °C，且必须高于高温阈值。');
	tempMax.datatype = 'range(32, 120)';
	tempMax.default = DEFAULTS.temp_max;
	tempMax.rmempty = false;
	tempMax.inputmode = 'numeric';
	tempMax.validate = temperatureValidator(32, 120, '最高阈值必须是 32–120 °C 的整数。');

	var pwmCool = section.taboption('output', form.Value, 'pwm_cool', '冷却 PWM（1–255）', '低于温暖阈值时的输出；为避免意外停转，不允许设置为 0。');
	pwmCool.datatype = 'range(1, 255)';
	pwmCool.default = DEFAULTS.pwm_cool;
	pwmCool.rmempty = false;
	pwmCool.inputmode = 'numeric';
	pwmCool.validate = pwmValidator();

	var pwmWarm = section.taboption('output', form.Value, 'pwm_warm', '温暖 PWM（1–255）', '温暖区间的输出；必须不低于冷却 PWM。');
	pwmWarm.datatype = 'range(1, 255)';
	pwmWarm.default = DEFAULTS.pwm_warm;
	pwmWarm.rmempty = false;
	pwmWarm.inputmode = 'numeric';
	pwmWarm.validate = pwmValidator();

	var pwmHot = section.taboption('output', form.Value, 'pwm_hot', '高温 PWM（1–255）', '高温区间的输出；必须不低于温暖 PWM。');
	pwmHot.datatype = 'range(1, 255)';
	pwmHot.default = DEFAULTS.pwm_hot;
	pwmHot.rmempty = false;
	pwmHot.inputmode = 'numeric';
	pwmHot.validate = pwmValidator();

	var pwmMax = section.taboption('output', form.Value, 'pwm_max', '最高 PWM（必须为 255）', '保护档固定为 255，确保温度异常或风扇故障时可以全速运行。');
	pwmMax.datatype = 'range(255, 255)';
	pwmMax.default = DEFAULTS.pwm_max;
	pwmMax.rmempty = false;
	pwmMax.inputmode = 'numeric';
	pwmMax.validate = pwmValidator();

	return map;
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('ax9000-fan'),
			fs.exec(STATUS_PATH, []).then(function(result) {
				return parseStatusResult(result);
			}).catch(function(error) {
				return { transport_error: statusError(error) };
			})
		]);
	},

	render: function(data) {
		var self = this;
		var initialStatus = data && data[1] ? data[1] : { error: '等待状态数据。' };
		var refreshButton = E('button', {
			'class': 'cbi-button ax9-refresh-button',
			'type': 'button',
			'aria-label': '刷新风扇状态',
			'click': function() { self.refreshStatus(); }
		}, '刷新');
		this.refreshButton = refreshButton;
		this.statusBadge = E('span', { 'class': 'ax9-status-badge loading', 'role': 'status', 'aria-live': 'polite' }, '加载中…');
		this.metricService = E('dd', {}, '加载中…');
		this.metricFan = E('dd', {}, '加载中…');
		this.metricRpm = E('dd', {}, '加载中…');
		this.metricTemp = E('dd', {}, '加载中…');
		this.metricPwm = E('dd', {}, '加载中…');
		this.metricSource = E('p', { 'class': 'ax9-status-source' }, '温度源：加载中…');
		this.metricProfile = E('p', { 'class': 'ax9-status-profile' }, '曲线：加载中…');
		this.statusErrorNode = E('p', { 'class': 'ax9-status-error', 'role': 'alert', 'hidden': true });

		var root = E('div', { 'class': 'ax9-fan-page' }, [
			E('link', { 'rel': 'stylesheet', 'href': L.resource('view/ax9000-fan/overview.css') }),
			E('header', { 'class': 'ax9-page-header' }, [
				E('div', { 'class': 'ax9-title-block' }, [
					E('p', { 'class': 'ax9-eyebrow' }, 'AX9000 · 风扇控制'),
					E('h1', {}, 'AX9000 风扇'),
					E('p', {}, '生产控制面板：实时查看硬件状态，并安全调整自动温度曲线。')
				]),
				E('div', { 'class': 'ax9-page-actions' }, [
					refreshButton,
					E('span', { 'class': 'ax9-poll-note' }, '自动刷新：每 5 秒')
				])
			]),
			E('section', { 'class': 'ax9-status-panel', 'aria-labelledby': 'ax9-status-title' }, [
				E('div', { 'class': 'ax9-status-heading' }, [
					E('div', {}, [E('p', { 'class': 'ax9-eyebrow' }, '实时状态'), E('h2', { 'id': 'ax9-status-title' }, '风扇控制器')]),
					this.statusBadge
				]),
				E('dl', { 'class': 'ax9-metric-grid' }, [
					E('div', { 'class': 'ax9-metric' }, [E('dt', {}, '运行状态'), this.metricService]),
					E('div', { 'class': 'ax9-metric' }, [E('dt', {}, '风扇状态'), this.metricFan]),
					E('div', { 'class': 'ax9-metric' }, [E('dt', {}, '转速'), this.metricRpm]),
					E('div', { 'class': 'ax9-metric' }, [E('dt', {}, '最高温度'), this.metricTemp]),
					E('div', { 'class': 'ax9-metric' }, [E('dt', {}, 'PWM 输出'), this.metricPwm])
				]),
				this.metricSource,
				this.metricProfile,
				this.statusErrorNode
			]),
			E('div', { 'class': 'ax9-config-note', 'role': 'note' }, '保存并应用会重载 AX9000 风扇控制器。修改前请确认阈值和 PWM 曲线；本页面没有立即停转、强制 0 PWM 或任意命令执行按钮。'),
			E('div', { 'class': 'ax9-config-host' })
		]);

		this.root = root;
		this.renderStatus(initialStatus);
		this.pollFn = L.bind(this.refreshStatus, this);
		poll.add(this.pollFn, STATUS_POLL_SECONDS);
		poll.start();

		var map = buildMap();
		return map.render().then(function(mapNode) {
			root.querySelector('.ax9-config-host').appendChild(mapNode);
			return root;
		});
	},

	renderStatus: function(data) {
		var payload = data && typeof data === 'object' ? data : { error: '状态数据无效。' };
		var transportError = payload.transport_error;
		var faultReason = payload.error;
		var fanFound = booleanValue(payload.fan_found);
		var fault = faultValue(payload.fault);
		var running = booleanValue(payload.service_running);
		var enabled = booleanValue(payload.enabled);
		var kind = 'ok';
		var badge = '运行中';

		if (transportError) { kind = 'error'; badge = '读取失败'; }
		else if (!fanFound) { kind = 'missing'; badge = '未检测到硬件'; }
		else if (fault) { kind = 'fault'; badge = '故障'; }
		else if (!running) { kind = 'stopped'; badge = enabled ? '未运行' : '已禁用'; }

		if (this.statusBadge) {
			this.statusBadge.className = 'ax9-status-badge ' + kind;
			text(this.statusBadge, badge);
		}
		text(this.metricService, transportError ? '—' : (running ? '运行中' : '未运行'));
		text(this.metricFan, transportError ? '—' : (fault ? '故障保护' : (fanFound ? '正常' : '未检测到硬件')));
		text(this.metricRpm, transportError || !fanFound ? '—' : formatRpm(payload.rpm));
		text(this.metricTemp, transportError ? '—' : formatTemperature(payload.max_temp_mC));
		text(this.metricPwm, transportError ? '—' : formatPwm(payload.pwm));
		text(this.metricSource, transportError ? '温度源：—' : formatSource(payload.max_temp_source));
		text(this.metricProfile, transportError ? '控制：—' : '控制：' + (enabled ? '已启用' : '已禁用') + ' · 曲线：' + formatProfile(payload.profile, payload.thresholds));
		if (this.statusErrorNode) {
			this.statusErrorNode.hidden = !transportError && !fault;
			text(this.statusErrorNode, transportError ? '状态读取错误：' + statusError(transportError) : (fault ? '故障原因：' + faultDescription(faultReason) : ''));
		}
	},

	refreshStatus: function() {
		var self = this;
		if (this.statusRequest) return this.statusRequest;
		if (this.refreshButton) this.refreshButton.disabled = true;
		this.statusRequest = fs.exec(STATUS_PATH, []).then(function(result) {
			var payload = parseStatusResult(result);
			self.renderStatus(payload);
			return payload;
		}).catch(function(error) {
			var payload = { transport_error: statusError(error) };
			self.renderStatus(payload);
			return payload;
		}).then(function(result) {
			if (self.refreshButton) self.refreshButton.disabled = false;
			self.statusRequest = null;
			return result;
		});
		return this.statusRequest;
	},

	destroy: function() {
		if (this.pollFn) poll.remove(this.pollFn);
	}
});
