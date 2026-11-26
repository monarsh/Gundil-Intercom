'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require poll';

// LuCI page for gundil-update-server: Services → Gundil update server.
// Start, stop, configure and reset; the admin work (devices, policy,
// versions) is on the server's own web page.
const helper = '/usr/libexec/gundil-update-server-luci';

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
	if (s.enabled !== '1')
		return _('Stopped (not started at boot). Press Restart to start it.');
	return _('Not running. See the log below.');
}

// The admin page's address, as this browser reaches the router.
function pageURL(s) {
	const listen = s.listen || '0.0.0.0:8780';
	const i = listen.lastIndexOf(':');
	let host = listen.substring(0, i), port = listen.substring(i + 1);
	if (host === '' || host === '0.0.0.0' || host === '::' || host === '[::]')
		host = window.location.hostname;
	return window.location.protocol.replace('https:', 'http:') + '//' + host + ':' + port + '/';
}

return view.extend({
	load: function() {
		return run('status').then(parseStatus);
	},

	render: function(status) {
		const m = new form.Map('gundil-update', _('Gundil update server'),
			_('Tells every Gundil Intercom which version to install (upgrade or downgrade) and hands out the files. ' +
			  'The apps reach it through public Nostr relays, STUN and UDP hole punching: no public IP or port forwarding needed. ' +
			  'Devices, versions and the update policy are managed on its own admin page.'));

		const s = m.section(form.NamedSection, 'main', 'server', _('Server'));
		s.addremove = false;

		let o = s.option(form.DummyValue, '_status', _('Status'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return E('span', { 'id': 'gus-status' }, [ statusText(status) ]);
		};

		o = s.option(form.DummyValue, '_version', _('Version'));
		o.cfgvalue = function() { return status.version || '?'; };

		o = s.option(form.DummyValue, '_page', _('Admin page'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			const url = pageURL(status);
			return E('span', {}, [
				E('a', { 'href': url, 'target': '_blank', 'rel': 'noopener', 'class': 'cbi-button cbi-button-action' }, [ _('Open admin page') ]),
				' ', E('code', {}, [ url ]),
				E('div', { 'class': 'cbi-value-description', 'id': 'gus-initial' }, [ initialText(status) ])
			]);
		};

		o = s.option(form.DummyValue, '_code', _('Server code'),
			_('The apps trust only this server. Put it into the GitHub repository variable GUNDIL_UPDATE_SERVER (built into every release), or paste it in an app: Settings → Updates → Update server.'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			if (!status.code)
				return E('em', {}, [ _('Made at the first start.') ]);
			return E('span', {}, [
				E('code', { 'id': 'gus-code', 'style': 'word-break:break-all' }, [ status.code ]), ' ',
				E('button', {
					'class': 'cbi-button cbi-button-neutral',
					'click': function(ev) {
						ev.preventDefault();
						const t = document.getElementById('gus-code').textContent;
						if (navigator.clipboard)
							navigator.clipboard.writeText(t).then(function() {
								ui.addNotification(null, E('p', [ _('Server code copied') ]), 'info');
							});
					}
				}, [ _('Copy') ])
			]);
		};

		o = s.option(form.Value, 'listen', _('Admin page address'),
			_('Address and port of the admin page. 0.0.0.0:8780 = every network of the router; use the LAN address (e.g. 192.168.1.1:8780) to keep it off the WAN.'));
		o.placeholder = '0.0.0.0:8780';
		o.datatype = 'string';
		o.validate = function(id, value) {
			if (!value)
				return true;
			return /^[0-9a-fA-F.:\[\]]*:\d{1,5}$/.test(value) ? true : _('Like 192.168.1.1:8780');
		};

		o = s.option(form.Value, 'data_dir', _('Data folder'),
			_('Where the server keeps its key, devices and versions. Kept copies of release files can be large (about 500 MB per release): ' +
			  'on a small router keep no copies (the apps then download from GitHub) or use a USB disk, e.g. /mnt/sda1/gundil-update-server. ' +
			  'Moving it starts with an empty folder (a new server key) unless you copy the old folder there first.'));
		o.placeholder = '/etc/gundil-update-server';

		o = s.option(form.DummyValue, '_free', _('Free space there'));
		o.cfgvalue = function() {
			const k = parseInt(status.free, 10);
			return isNaN(k) ? '?' : (k >= 1048576 ? (k / 1048576).toFixed(1) + ' GB' : Math.round(k / 1024) + ' MB');
		};

		o = s.option(form.Value, 'github_repo', _('GitHub repository'),
			_('Where the server finds the releases it offers.'));
		o.placeholder = 'monarsh/Gundil-Intercom';

		o = s.option(form.Value, 'relays', _('Nostr relays'),
			_('Optional. Comma separated; empty uses the built-in list.'));
		o.placeholder = 'wss://relay.damus.io, wss://nos.lol';

		function initialText(st) {
			return st.initial
				? _('New admin account: sign in as "admin" with the one-time password %s, then choose your own.').format(st.initial)
				: '';
		}

		return m.render().then(function(mapEl) {
			const out = E('pre', {
				'style': 'white-space:pre-wrap; max-height:30em; overflow:auto; margin-top:1em'
			});
			out.textContent = _('Press a button.');

			function refresh() {
				const el = document.getElementById('gus-status');
				if (el)
					el.textContent = statusText(status);
				const ini = document.getElementById('gus-initial');
				if (ini)
					ini.textContent = initialText(status);
			}

			function action(label, cmd, style, confirmText) {
				return E('button', {
					'class': 'cbi-button ' + style,
					'click': ui.createHandlerFn(this, function() {
						if (confirmText && !window.confirm(confirmText))
							return;
						out.textContent = _('Running %s…').format(label);
						return run(cmd).then(function(text) {
							out.textContent = text || _('(no output)');
							return run('status').then(function(t) { status = parseStatus(t); refresh(); });
						});
					})
				}, [ label ]);
			}

			poll.add(function() {
				return run('status').then(function(t) { status = parseStatus(t); refresh(); });
			}, 10);

			return E('div', {}, [
				mapEl,
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, [ _('Tools') ]),
					E('div', {}, [
						action(_('Show log'), 'log', 'cbi-button-neutral'), ' ',
						action(_('Restart'), 'restart', 'cbi-button-apply'), ' ',
						action(_('Reset portal'), 'reset', 'cbi-button-reset',
							_('Replace the admin account with a new one (one-time password)? Devices, policy and versions are kept.')), ' ',
						action(_('Reset all'), 'reset-all', 'cbi-button-remove',
							_('Start completely fresh: a new admin account, and forget all devices, the policy, the versions and kept files? The server code stays the same.'))
					]),
					E('p', { 'class': 'cbi-value-description' }, [
						_('Reset portal: when the admin password is lost. The new one-time password is shown here and must be changed at the first sign-in. ' +
						  'The server key (and so the server code in the apps) is never changed here; for that use "gundil-reset-portal --all --new-key" over SSH.')
					]),
					out
				])
			]);
		});
	}
});
