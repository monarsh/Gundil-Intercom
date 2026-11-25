'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require poll';

// LuCI page for gundil-gateway: Services → Gundil gateway.
const helper = '/usr/libexec/gundil-gateway-luci';

function run(cmd) {
	return fs.exec(helper, [ cmd ]).then(function(r) {
		return ((r.stdout || '') + (r.stderr || '')).trim();
	}).catch(function(e) {
		return _('Error: %s').format(e.message);
	});
}

function parseStatus(text) {
	const s = {};
	text.split('\n').forEach(function(line) {
		const i = line.indexOf('=');
		if (i > 0)
			s[line.substring(0, i)] = line.substring(i + 1);
	});
	return s;
}

function statusText(s) {
	if (s.pid)
		return _('Running (pid %s)').format(s.pid);
	if (s.password !== '1')
		return _('Not running: set the intercom password (10+ characters) or the home key below, then Save & Apply.');
	if (s.enabled !== '1')
		return _('Stopped (not started at boot). Press Restart to start it.');
	return _('Not running. See the log below.');
}

return view.extend({
	load: function() {
		return run('status').then(parseStatus);
	},

	render: function(status) {
		const m = new form.Map('gundil', _('Gundil gateway'),
			_('Lets the Gundil Intercom apps reach the cameras on this LAN from the internet, ' +
			  'with STUN and UDP hole punching through public Nostr relays. No port forwarding needed. ' +
			  'Everything is end-to-end encrypted with the intercom password or the home key.'));

		const s = m.section(form.NamedSection, 'main', 'gateway', _('Settings'));
		s.addremove = false;

		let o = s.option(form.DummyValue, '_status', _('Status'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return E('span', { 'id': 'gundil-status' }, [ statusText(status) ]);
		};

		o = s.option(form.DummyValue, '_version', _('Version'));
		o.cfgvalue = function() { return status.version || '?'; };

		o = s.option(form.Value, 'password', _('Intercom password'),
			_('If your apps use an intercom password: the same one, at least 10 characters. Otherwise leave it empty and use the home key.'));
		o.password = true;
		o.validate = function(id, value) {
			if (value && value.length < 10)
				return _('At least 10 characters');
			return true;
		};

		o = s.option(form.Value, 'home_key', _('Home key'),
			_('If your apps use no password: in a paired app open Settings → Internet calls → Pairing → Copy pairing code, and paste it here (GUNDIL-PAIR-…).'));
		o.password = true;
		o.placeholder = 'GUNDIL-PAIR-…';
		o.validate = function(id, value) {
			const v = (value || '').replace(/\s/g, '');
			const pw = this.section.formvalue(id, 'password');
			if (!v)
				return pw ? true : _('Set the intercom password or the home key');
			if (/^[0-9a-fA-F]{64}$/.test(v) || /^GUNDIL-PAIR-[A-Za-z0-9_-]{46,47}=?$/i.test(v))
				return true;
			return _('Not a pairing code (it starts with GUNDIL-PAIR-)');
		};

		o = s.option(form.Value, 'name', _('Name'), _('The name the apps show for this gateway.'));
		o.placeholder = 'Home router';

		o = s.option(form.Flag, 'share_cameras', _('Share home cameras'),
			_('The apps outside home can reach the cameras on this LAN through this router. ' +
			  'Only devices with the intercom password, and only addresses on this LAN.'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'relays', _('Nostr relays'),
			_('Optional. Comma separated; empty uses the built-in list.'));
		o.placeholder = 'wss://relay.damus.io, wss://nos.lol';

		return m.render().then(function(mapEl) {
			const out = E('pre', {
				'style': 'white-space:pre-wrap; max-height:30em; overflow:auto; margin-top:1em'
			});
			out.textContent = _('Press a button.');

			function action(label, cmd, style) {
				return E('button', {
					'class': 'cbi-button ' + style,
					'click': ui.createHandlerFn(this, function() {
						out.textContent = _('Running %s…').format(label);
						return run(cmd).then(function(text) {
							out.textContent = text || _('(no output)');
							return run('status').then(function(t) { status = parseStatus(t); refresh(); });
						});
					})
				}, [ label ]);
			}

			function refresh() {
				const el = document.getElementById('gundil-status');
				if (el)
					el.textContent = statusText(status);
			}

			poll.add(function() {
				return run('status').then(function(t) { status = parseStatus(t); refresh(); });
			}, 10);

			return E('div', {}, [
				mapEl,
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, [ _('Tools') ]),
					E('div', {}, [
						action(_('Check network'), 'check', 'cbi-button-action'), ' ',
						action(_('Show log'), 'log', 'cbi-button-neutral'), ' ',
						action(_('Restart'), 'restart', 'cbi-button-apply')
					]),
					E('p', { 'class': 'cbi-value-description' }, [
						_('Check network shows the relays, the NAT type (cone means direct calls work) and what is shared. It takes about 10 seconds.')
					]),
					out
				])
			]);
		});
	}
});
