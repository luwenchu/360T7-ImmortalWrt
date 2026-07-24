'use strict';
'require view';
'require form';
'require fs';

return view.extend({
	load: function() {
		return fs.exec('/usr/libexec/360t7-hwaccel-status')
			.then(function(result) {
				return JSON.parse(result.stdout || '{}');
			})
			.catch(function() {
				return {};
			});
	},

	render: function(status) {
		var map = new form.Map(
			'firewall',
			_('360T7 硬件加速'),
			_('控制 Qihoo 360T7 的 MediaTek PPE IPv4/IPv6 硬件流量分载。' +
			  '使用 SQM、QoS 或需要逐包检查的策略路由时，请关闭流量分载。')
		);
		var section = map.section(form.TypedSection, 'defaults', _('加速设置'));
		var option;

		section.anonymous = true;
		section.addremove = false;

		option = section.option(
			form.Flag,
			'flow_offloading',
			_('软件流量分载'),
			_('通过内核流表加速已经建立的 IPv4 和 IPv6 连接。')
		);
		option.rmempty = false;

		option = section.option(
			form.Flag,
			'flow_offloading_hw',
			_('硬件流量分载（IPv4/IPv6）'),
			_('将符合条件的 IPv4 和 IPv6 流量交给 MediaTek PPE 硬件处理。')
		);
		option.depends('flow_offloading', '1');
		option.rmempty = false;

		var state = status.hardware_active
			? _('运行中')
			: (status.hardware_enabled ? _('已启用，等待符合条件的流量') : _('已禁用'));
		var details = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('运行状态')),
			E('p', {}, [
				E('strong', {}, _('硬件流量分载：')),
				state
			]),
			E('p', {}, [
				E('strong', {}, _('IPv6 转发：')),
				status.ipv6_forwarding ? _('已启用') : _('未启用')
			]),
			E('p', { 'class': 'cbi-map-descr' },
				_('设备：%s；nft 流量分载模块：%s').format(
					status.board || _('未知'),
					status.module_loaded ? _('已加载') : _('未加载')
				)
			)
		]);

		return map.render().then(function(node) {
			node.insertBefore(details, node.firstChild);
			return node;
		});
	}
});
