'use strict';
'require view';
'require form';
'require fs';
'require poll';
'require rpc';
'require uci';
'require ui';

/*
 * LuCI shell for the uptime-kuma service.
 *
 * Scope is deliberately small: run state, start/stop/restart, listen address,
 * port, data directory, a log tail, a link to the panel and an on-demand
 * backup. The monitoring UI itself stays Uptime Kuma's own web app and is
 * never embedded here - it sends "X-Frame-Options: SAMEORIGIN", and its
 * session cookies have no business being proxied through the LuCI origin.
 */

var INIT_SCRIPT = '/etc/init.d/uptime-kuma';
var LOGREAD = '/sbin/logread';
var BACKUP_HELPER = '/usr/libexec/luci-app-uptime-kuma/backup';
var SYNC_FIREWALL = '/usr/libexec/luci-app-uptime-kuma/sync-firewall';

/* keep the textarea readable: the syslog ring buffer holds ~64 KiB */
var LOG_MAX_LINES = 400;

/* how often the run state is re-read while the page stays open, in seconds */
var STATUS_POLL_INTERVAL = 5;

var isReadonlyView = !L.hasViewPermission() || null;

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name', 'verbose' ],
	expect: { '': {} }
});

/*
 * Pick the running instance out of an `ubus call service list` reply: the
 * reply is keyed by service name and carries an "instances" table. A service
 * that never started since boot has no key at all.
 */
function runningInstance(reply) {
	var svc = reply ? reply['uptime-kuma'] : null;

	if (!svc || !svc.instances)
		return null;

	for (var name in svc.instances)
		if (svc.instances[name] && svc.instances[name].running)
			return svc.instances[name];

	return null;
}

/*
 * The panel is served over plain HTTP in this deployment, so the URL is built
 * from the configured listen address - except for the wildcard addresses,
 * where the host the browser already used is the only sensible choice.
 */
function panelURL(listen, port) {
	var host = (listen && listen != '0.0.0.0' && listen != '::')
		? listen
		: window.location.hostname;

	if (host.indexOf(':') != -1 && host.charAt(0) != '[')
		host = '[%s]'.format(host);

	return 'http://%s:%s/'.format(host, port);
}

function commandError(res) {
	var msg = ((res && res.stderr) || '') + ((res && res.stdout) || '');

	msg = msg.trim();

	return new Error(msg || _('The command failed with exit code %s.').format(res ? res.code : '?'));
}

/*
 * procd tags everything the service writes to stdout/stderr with
 * "<argv0>[<pid>]" in syslog. The init script starts the server through
 * `/bin/sh -c "cd … && exec node …"`, so argv0 is `sh`, while `exec` keeps the
 * pid: matching on the pid covers both `sh[1234]` and `node[1234]` without
 * guessing which wrapper procd saw. Messages the init script itself logs are
 * tagged with the service name instead, so keep those too.
 */
function filterServiceLog(text, pid) {
	var lines = String(text || '').split(/\n/),
	    out = [],
	    marks = [ 'uptime-kuma' ];

	if (pid)
		marks.push('[%s]'.format(pid));

	for (var i = 0; i < lines.length; i++) {
		for (var j = 0; j < marks.length; j++) {
			if (lines[i].indexOf(marks[j]) != -1) {
				out.push(lines[i]);
				break;
			}
		}
	}

	if (out.length > LOG_MAX_LINES)
		out = out.slice(out.length - LOG_MAX_LINES);

	return out.join('\n');
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('uptime-kuma'),
			L.resolveDefault(callServiceList('uptime-kuma', true), {})
		]).then(L.bind(function(data) {
			var sections = uci.sections('uptime-kuma');

			this.section = sections.length ? sections[0]['.name'] : null;
			this.state = runningInstance(data[1]);

			return this.readLog();
		}, this)).then(L.bind(function(log) {
			this.log = log;

			return true;
		}, this));
	},

	/* ---------------------------------------------------------------- uci */

	settings: function() {
		var get = L.bind(function(option, fallback) {
			return (this.section ? uci.get('uptime-kuma', this.section, option) : null) || fallback;
		}, this);

		return {
			listen: get('listen', '0.0.0.0'),
			port: get('port', '3001'),
			data_dir: get('data_dir', '/opt/uptime-kuma/data')
		};
	},

	/* ------------------------------------------------------------- service */

	runInit: function(action) {
		return fs.exec(INIT_SCRIPT, [ action ]).then(function(res) {
			if (res && res.code != 0)
				throw commandError(res);

			return res;
		});
	},

	wait: function(ms) {
		return new Promise(function(resolve) {
			window.setTimeout(resolve, ms);
		});
	},

	refreshStatus: function() {
		return L.resolveDefault(callServiceList('uptime-kuma', true), {}).then(L.bind(function(reply) {
			this.state = runningInstance(reply);
			this.updateStateNodes();
		}, this));
	},

	updateStateNodes: function() {
		var nodes = this.nodes;

		if (!nodes || !nodes.badge)
			return;

		var running = this.state != null,
		    settings = this.settings(),
		    url = panelURL(settings.listen, settings.port),
		    pid = running ? String(this.state.pid || '') : '';

		nodes.badge.className = running ? 'label success' : 'label';
		nodes.badge.textContent = running ? _('Running') : _('Stopped');
		nodes.pid.textContent = pid || '\u2013';
		nodes.link.href = url;
		nodes.link.textContent = url;
		nodes.open.href = url;
		nodes.dataDir.textContent = settings.data_dir;

		nodes.start.disabled = (running || isReadonlyView) ? true : false;
		nodes.stop.disabled = (!running || isReadonlyView) ? true : false;
		nodes.restart.disabled = (!running || isReadonlyView) ? true : false;
	},

	/*
	 * The button state is re-applied after the action rather than before it:
	 * `ui.createHandlerFn()` re-enables its button once the handler promise
	 * settles, so the authoritative state has to land one task later.
	 */
	handleServiceAction: function(action, ev) {
		var self = this;

		if (isReadonlyView)
			return;

		ui.showModal(_('Please wait'), [
			E('p', { 'class': 'spinning' }, _('Running %s %s …').format(INIT_SCRIPT, action))
		]);

		return this.runInit(action).then(function() {
			/* procd registers the instance a moment after the init call */
			return self.wait(action == 'stop' ? 1500 : 2500);
		}).then(function() {
			return self.refreshStatus();
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Unable to run "%s": %s').format(action, err.message || err)));
		}).then(function() {
			ui.hideModal();
			window.setTimeout(L.bind(self.updateStateNodes, self), 0);
		});
	},

	/* ------------------------------------------------------------------ log */

	readLog: function() {
		var pid = this.state ? this.state.pid : null;

		return fs.exec(LOGREAD, []).then(function(res) {
			if (res && res.code != 0)
				throw commandError(res);

			return { text: filterServiceLog(res && res.stdout, pid), error: null };
		}).catch(function(err) {
			return { text: '', error: err.message || String(err) };
		});
	},

	handleRefreshLog: function(ev) {
		var node = this.nodes.log;

		if (!node)
			return;

		node.value = _('Loading …');

		return this.readLog().then(L.bind(function(log) {
			this.log = log;
			node.value = log.error
				? _('Unable to read the log: %s').format(log.error)
				: (log.text || _('No log lines from this service yet.'));
		}, this));
	},

	/* --------------------------------------------------------------- backup */

	handleBackup: function(ev) {
		var self = this,
		    settings = this.settings();

		if (isReadonlyView)
			return;

		ui.showModal(_('Please wait'), [
			E('p', { 'class': 'spinning' }, _('Packing %s …').format(settings.data_dir))
		]);

		return fs.exec(BACKUP_HELPER, []).then(function(res) {
			if (res && res.code != 0)
				throw commandError(res);

			ui.hideModal();
			ui.addNotification(null,
				E('p', {}, _('Backup written to %s').format((res.stdout || '').trim())), 'info');
		}).catch(function(err) {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('Backup failed: %s').format(err.message || err)));
		});
	},

	/* ---------------------------------------------------------------- views */

	renderStatus: function() {
		var settings = this.settings(),
		    url = panelURL(settings.listen, settings.port);

		var row = function(title, value) {
			return E('tr', { 'class': 'tr' }, [
				E('th', { 'class': 'th', 'style': 'width:30%' }, title),
				E('td', { 'class': 'td' }, value)
			]);
		};

		var badge = E('span', { 'class': this.state ? 'label success' : 'label' },
			this.state ? _('Running') : _('Stopped'));

		var pid = E('span', {}, this.state ? String(this.state.pid || '') : '\u2013');

		var link = E('a', { 'href': url, 'target': '_blank', 'rel': 'noopener noreferrer' }, url);

		var dataDir = E('span', {}, settings.data_dir);

		var start = E('button', {
			'class': 'cbi-button cbi-button-positive',
			'click': ui.createHandlerFn(this, 'handleServiceAction', 'start'),
			'disabled': (this.state || isReadonlyView) ? true : null
		}, _('Start'));

		var stop = E('button', {
			'class': 'cbi-button cbi-button-negative',
			'click': ui.createHandlerFn(this, 'handleServiceAction', 'stop'),
			'disabled': (!this.state || isReadonlyView) ? true : null
		}, _('Stop'));

		var restart = E('button', {
			'class': 'cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, 'handleServiceAction', 'restart'),
			'disabled': (!this.state || isReadonlyView) ? true : null
		}, _('Restart'));

		var open = E('a', {
			'class': 'cbi-button cbi-button-action',
			'href': url,
			'target': '_blank',
			'rel': 'noopener noreferrer'
		}, _('Open panel'));

		this.nodes = this.nodes || {};
		this.nodes.badge = badge;
		this.nodes.pid = pid;
		this.nodes.link = link;
		this.nodes.open = open;
		this.nodes.dataDir = dataDir;
		this.nodes.start = start;
		this.nodes.stop = stop;
		this.nodes.restart = restart;

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Service state')),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('Item')),
					E('th', { 'class': 'th' }, _('Value'))
				]),
				row(_('State'), badge),
				row(_('Process ID'), pid),
				row(_('Panel address'), link),
				row(_('Data directory'), dataDir)
			]),
			E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
				start, ' ', stop, ' ', restart, ' ', open
			])
		]);
	},

	renderSettings: function() {
		if (!this.section)
			return Promise.resolve(E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Service settings')),
				E('p', { 'class': 'cbi-section-descr' },
					_('No "uptime-kuma" configuration found. Install the uptime-kuma package and reload this page.'))
			]));

		var map = new form.Map('uptime-kuma', _('Service settings'),
			_('Changes are staged in UCI and committed by "Save & Apply"; the service is then reloaded so a new address or port takes effect.'));

		var section = map.section(form.NamedSection, this.section, 'uptime-kuma');

		var listen = section.option(form.Value, 'listen', _('Listen address'),
			_('Address the panel binds to. 0.0.0.0 listens on every interface, 127.0.0.1 keeps it local to the device.'));
		listen.placeholder = '0.0.0.0';
		listen.datatype = 'host';
		listen.rmempty = false;

		var port = section.option(form.Value, 'port', _('Port'),
			_('TCP port the panel listens on.'));
		port.placeholder = '3001';
		port.datatype = 'port';
		port.rmempty = false;

		var dataDir = section.option(form.Value, 'data_dir', _('Data directory'),
			_('Holds the SQLite database and the monitor configuration. Keep it on persistent storage such as /opt or /mnt; /tmp lives in RAM and is lost on reboot.'));
		dataDir.placeholder = '/opt/uptime-kuma/data';
		dataDir.rmempty = false;
		dataDir.validate = function(section_id, value) {
			if (value == null || value == '')
				return _('A data directory is required.');

			if (value.charAt(0) != '/')
				return _('Use an absolute path.');

			if (value == '/tmp' || value.indexOf('/tmp/') == 0)
				return _('/tmp lives in RAM and is lost on reboot. Pick a persistent directory.');

			return true;
		};

		return map.render();
	},

	renderLog: function() {
		var textarea = E('textarea', {
			'rows': 18,
			'readonly': 'readonly',
			'wrap': 'off',
			'style': 'width:100%; font-family:monospace; font-size:12px'
		}, [
			this.log && this.log.error
				? _('Unable to read the log: %s').format(this.log.error)
				: ((this.log && this.log.text) || _('No log lines from this service yet.'))
		]);

		this.nodes = this.nodes || {};
		this.nodes.log = textarea;

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Service log')),
			E('p', { 'class': 'cbi-section-descr' },
				_('Last lines the service wrote, taken from the system log through procd.')),
			textarea,
			E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleRefreshLog')
				}, _('Refresh'))
			])
		]);
	},

	renderBackup: function() {
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Backup')),
			E('p', { 'class': 'cbi-section-descr' },
				_('Packs the data directory into /opt/uptime-kuma/backup-YYYYMMDD.tgz on the device. The archive is not downloaded automatically; fetch it over SSH or SCP.')),
			E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left' }, [
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleBackup'),
					'disabled': isReadonlyView ? true : null
				}, _('Create backup'))
			])
		]);
	},

	render: function() {
		var self = this,
		    status = this.renderStatus(),
		    backup = this.renderBackup(),
		    log = this.renderLog();

		return this.renderSettings().then(function(settings) {
			/* poll the run state only while this page is still on screen */
			self.pollFn = function() {
				if (!document.body.contains(self.nodes.badge)) {
					poll.remove(self.pollFn);
					return;
				}

				return self.refreshStatus();
			};

			poll.add(self.pollFn, STATUS_POLL_INTERVAL);

			return E([], [
				E('h2', {}, _('Uptime Kuma')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Manages the local uptime-kuma service. The monitoring panel is a separate web app and opens in a new tab.')),
				status,
				settings,
				backup,
				log
			]);
		});
	},

	/*
	 * Save & Apply: stage the UCI changes, commit them with rollback
	 * protection, then reload the service so the new listen address and port
	 * actually apply. The LAN firewall rule is created once by the install
	 * hook, so it is re-pointed at the new port here as well.
	 */
	handleSaveApply: function(ev) {
		var self = this;

		return this.handleSave(ev).then(function() {
			return uci.changes();
		}).then(function(changes) {
			var count = 0;

			for (var config in changes)
				if (changes.hasOwnProperty(config))
					count += changes[config].length;

			if (count == 0)
				return null;

			return uci.apply(10);
		}).then(function() {
			/* committed, so the staged-change badge no longer applies */
			ui.changes.setIndicator(0);

			return self.runInit('reload');
		}).then(function() {
			return fs.exec(SYNC_FIREWALL, []).then(function(res) {
				if (res && res.code != 0)
					throw commandError(res);
			});
		}).then(function() {
			ui.addNotification(null, E('p', {}, _('Settings applied and the service was reloaded.')), 'info');
			return self.refreshStatus();
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, _('Unable to apply the settings: %s').format(err.message || err)));
		});
	},

	handleReset: null
});
