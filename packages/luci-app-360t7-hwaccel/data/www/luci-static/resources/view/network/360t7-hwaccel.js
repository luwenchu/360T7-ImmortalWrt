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
			_('360T7 Hardware Acceleration'),
			_('Controls the MediaTek PPE hardware flow offload used by the Qihoo 360T7. ' +
			  'Disable offloading when using SQM/QoS or policy routing that must inspect every packet.')
		);
		var section = map.section(form.TypedSection, 'defaults', _('Acceleration settings'));
		var option;

		section.anonymous = true;
		section.addremove = false;

		option = section.option(
			form.Flag,
			'flow_offloading',
			_('Software flow offloading'),
			_('Offload established flows through the kernel flow table.')
		);
		option.rmempty = false;

		option = section.option(
			form.Flag,
			'flow_offloading_hw',
			_('Hardware flow offloading'),
			_('Send eligible flows to the MediaTek packet processing engine.')
		);
		option.depends('flow_offloading', '1');
		option.rmempty = false;

		var state = status.hardware_active
			? _('Active')
			: (status.hardware_enabled ? _('Enabled, waiting for eligible traffic') : _('Disabled'));
		var details = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Runtime status')),
			E('p', {}, [
				E('strong', {}, _('Hardware offload: ')),
				state
			]),
			E('p', { 'class': 'cbi-map-descr' },
				_('Board: %s; nft flow-offload module: %s').format(
					status.board || _('unknown'),
					status.module_loaded ? _('loaded') : _('not loaded')
				)
			)
		]);

		return map.render().then(function(node) {
			node.insertBefore(details, node.firstChild);
			return node;
		});
	}
});
