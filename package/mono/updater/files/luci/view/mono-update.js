'use strict';
'require view';
'require dom';
'require rpc';
'require ui';

var callStatus  = rpc.declare({ object: 'mono-update', method: 'status',  expect: {} });
var callCheck   = rpc.declare({ object: 'mono-update', method: 'check',   expect: {} });
var callInstall = rpc.declare({ object: 'mono-update', method: 'install', expect: {} });

return view.extend({
	// This page drives an external tool - no config form to save/apply.
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return callStatus().catch(function() { return {}; });
	},

	// Fill the summary node + toggle the Install button from a status object
	// ({ current, url, available, tag }). Works on a detached node too, so it
	// can run synchronously during render() as well as after a check.
	renderStatus: function(st) {
		var rows = [
			E('tr', {}, [
				E('td', { 'width': '33%' }, _('Running release')),
				E('td', {}, E('strong', {}, st.current || _('unknown')))
			]),
			E('tr', {}, [
				E('td', {}, _('Update server')),
				E('td', {}, st.url
					? E('code', {}, st.url)
					: E('em', {}, _('not configured (set mono-update.check.url)')))
			])
		];

		if (st.available && st.tag)
			rows.push(E('tr', {}, [
				E('td', {}, _('Available')),
				E('td', {}, E('strong', { 'style': 'color:#e08000' }, st.tag))
			]));

		dom.content(this.summaryNode, E('table', { 'class': 'table' }, rows));

		this.lastTag = (st.available && st.tag) ? st.tag : null;
		this.installBtn.style.display = this.lastTag ? '' : 'none';
	},

	handleCheck: function(ev) {
		var self = this;
		var b = ev.currentTarget;
		b.classList.add('spinning');
		b.disabled = true;

		return callCheck().then(function(res) {
			self.renderStatus({
				current:   res.current,
				url:       self.stURL,
				available: res.available,
				tag:       res.tag
			});
			self.logNode.style.display = '';
			self.logNode.textContent = (res.log || '').trim() ||
				(res.available ? _('Update available: %s').format(res.tag)
				               : _('No update available.'));
			ui.addNotification(null, E('p', res.available
				? _('Update available: %s').format(res.tag)
				: _('Firmware is up to date.')), 'info');
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Update check failed: %s').format(e.message || e)), 'danger');
		}).finally(function() {
			b.classList.remove('spinning');
			b.disabled = false;
		});
	},

	handleInstall: function() {
		var self = this;
		var tag = self.lastTag;
		if (!tag) return;

		ui.showModal(_('Install %s').format(tag), [
			E('p', {}, _('This downloads the signed image, verifies its signature and hash, then applies it with sysupgrade. The device will reboot and be unreachable for one to two minutes.')),
			E('p', { 'class': 'alert-message warning' }, _('Do not power off the device during the upgrade.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': ui.createHandlerFn(self, 'doInstall')
				}, _('Install and reboot'))
			])
		]);
	},

	doInstall: function() {
		return callInstall().then(function() {
			ui.showModal(_('Upgrade in progress'), [
				E('p', { 'class': 'spinning' }, _('The device is verifying and flashing the new image, then rebooting. This page will not respond until it is back — wait one to two minutes and reload.')),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': function() { location.reload(); } }, _('Reload now'))
				])
			]);
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', _('Could not start the upgrade: %s').format(e.message || e)), 'danger');
		});
	},

	render: function(st) {
		st = st || {};
		this.stURL = st.url || '';

		this.summaryNode = E('div', {});
		this.installBtn = E('button', {
			'class': 'btn cbi-button cbi-button-negative',
			'style': 'display:none',
			'click': ui.createHandlerFn(this, 'handleInstall')
		}, _('Install update'));
		this.logNode = E('pre', { 'style': 'display:none;margin-top:1em;white-space:pre-wrap' });

		// Populate the initial summary synchronously (detached node is fine).
		this.renderStatus({ current: st.current, url: this.stURL, available: st.available, tag: st.tag });

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Firmware Updates')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Check the Mono update server for a newer signed release and install it. Updates are verified by signature and hash before flashing.')),
			E('div', { 'class': 'cbi-section' }, [
				this.summaryNode,
				E('div', { 'style': 'margin-top:1em' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, 'handleCheck')
					}, _('Check for updates')),
					' ',
					this.installBtn
				]),
				this.logNode
			])
		]);
	}
});
