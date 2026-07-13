// QuotaPanel — GNOME Shell extension.
//
// A top-bar button that opens a panel (click to open, click again to close —
// PanelMenu.Button gives this natively) showing AI coding-tool usage quotas.
// It renders the status.json written by `quotapanel-daemon`; it does no network
// itself. "Refresh" spawns the daemon once and re-reads the file.

import GObject from 'gi://GObject';
import St from 'gi://St';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Clutter from 'gi://Clutter';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

// status.json lives under $XDG_CONFIG_HOME/quotapanel (default ~/.config/...).
function configDir() {
    const xdg = GLib.getenv('XDG_CONFIG_HOME');
    const base = xdg && xdg.length > 0 ? xdg : GLib.build_filenamev([GLib.get_home_dir(), '.config']);
    return GLib.build_filenamev([base, 'quotapanel']);
}

const BAR_WIDTH = 168; // px — the usage-bar track width
const POLL_SECONDS = 30; // fallback re-read cadence (file monitor covers the rest)

// Is this the 5-hour / session window? Matched by label so the different
// provider wordings ("Session (5h)", "Session (7h)", "5-hour") all resolve here.
function isSessionWindow(w) {
    const label = (w.label || '').toLowerCase();
    return label.startsWith('session') || label.includes('5-hour') || label.includes('5h');
}

// Resolve the daemon binary: PATH first, then ~/.local/bin.
function findDaemon() {
    const onPath = GLib.find_program_in_path('quotapanel-daemon');
    if (onPath)
        return onPath;
    const local = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'bin', 'quotapanel-daemon']);
    return GLib.file_test(local, GLib.FileTest.IS_EXECUTABLE) ? local : null;
}

// "resets in 2h 10m" / "resets in 3d" — or null if there is no valid date.
function formatReset(isoString) {
    if (!isoString)
        return null;
    const then = Date.parse(isoString);
    if (isNaN(then))
        return null;
    let secs = Math.round((then - Date.now()) / 1000);
    if (secs <= 0)
        return 'resets now';
    const d = Math.floor(secs / 86400); secs -= d * 86400;
    const h = Math.floor(secs / 3600); secs -= h * 3600;
    const m = Math.floor(secs / 60);
    if (d > 0)
        return `resets in ${d}d ${h}h`;
    if (h > 0)
        return `resets in ${h}h ${m}m`;
    return `resets in ${m}m`;
}

const QuotaPanelIndicator = GObject.registerClass(
class QuotaPanelIndicator extends PanelMenu.Button {
    _init(daemonPath) {
        super._init(0.5, 'QuotaPanel');
        this._daemonPath = daemonPath;

        const box = new St.BoxLayout({style_class: 'panel-status-menu-box'});
        this._icon = new St.Icon({
            icon_name: 'utilities-system-monitor-symbolic',
            style_class: 'system-status-icon',
        });
        this._label = new St.Label({
            text: '',
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'quotapanel-top-label',
        });
        box.add_child(this._icon);
        box.add_child(this._label);
        this.add_child(box);

        this._buildMenu();
    }

    _buildMenu() {
        // The whole panel body is one non-activatable item holding a vertical box.
        this._bodyItem = new PopupMenu.PopupBaseMenuItem({
            activate: false,
            reactive: false,
            can_focus: false,
        });
        this._body = new St.BoxLayout({vertical: true, style_class: 'quotapanel-body'});
        this._bodyItem.add_child(this._body);
        this.menu.addMenuItem(this._bodyItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        this._refreshItem = new PopupMenu.PopupImageMenuItem('Refresh', 'view-refresh-symbolic');
        this._refreshItem.connect('activate', () => this._refreshNow());
        this.menu.addMenuItem(this._refreshItem);
        if (!this._daemonPath)
            this._refreshItem.setSensitive(false);
    }

    // MARK: - Rendering

    _clearBody() {
        this._body.destroy_all_children();
    }

    _addTextRow(text, styleClass) {
        const label = new St.Label({text, style_class: styleClass ?? 'quotapanel-note'});
        label.clutter_text.line_wrap = true;
        this._body.add_child(label);
    }

    _addProvider(p) {
        const header = new St.BoxLayout({style_class: 'quotapanel-provider-header'});
        const swatch = new St.Bin({style_class: 'quotapanel-swatch'});
        swatch.set_style(`background-color: ${p.brandColor};`);
        const name = new St.Label({text: p.name, style_class: 'quotapanel-provider-name'});
        header.add_child(swatch);
        header.add_child(name);
        if (p.plan) {
            const plan = new St.Label({
                text: p.plan,
                x_expand: true,
                x_align: Clutter.ActorAlign.END,
                style_class: 'quotapanel-provider-plan',
            });
            header.add_child(plan);
        }
        this._body.add_child(header);

        if (p.status === 'error') {
            this._addTextRow(p.message || 'Error', 'quotapanel-error');
            return;
        }
        if (!p.windows || p.windows.length === 0) {
            this._addTextRow('No usage data', 'quotapanel-note');
            return;
        }
        for (const w of p.windows)
            this._body.add_child(this._makeWindowRow(w, p.brandColor));
    }

    _makeWindowRow(w, color) {
        const row = new St.BoxLayout({vertical: true, style_class: 'quotapanel-window'});

        const top = new St.BoxLayout({style_class: 'quotapanel-window-top'});
        const label = new St.Label({text: w.label, style_class: 'quotapanel-window-label'});
        const pct = Math.max(0, Math.min(100, w.percent));
        const pctLabel = new St.Label({
            text: `${Math.round(pct)}%`,
            x_expand: true,
            x_align: Clutter.ActorAlign.END,
            style_class: pct >= 90 ? 'quotapanel-pct quotapanel-pct-high' : 'quotapanel-pct',
        });
        top.add_child(label);
        top.add_child(pctLabel);
        row.add_child(top);

        const track = new St.BoxLayout({style_class: 'quotapanel-bar-track'});
        track.set_style(`width: ${BAR_WIDTH}px;`);
        const fillPx = Math.max(2, Math.round(BAR_WIDTH * pct / 100));
        const fill = new St.Bin({style_class: 'quotapanel-bar-fill'});
        const fillColor = pct >= 90 ? '#e5484d' : color;
        fill.set_style(`width: ${fillPx}px; background-color: ${fillColor};`);
        track.add_child(fill);
        row.add_child(track);

        const reset = formatReset(w.resetsAt);
        if (reset) {
            const resetLabel = new St.Label({text: reset, style_class: 'quotapanel-reset'});
            row.add_child(resetLabel);
        }
        return row;
    }

    render(status) {
        this._clearBody();

        if (!status) {
            this._label.text = '';
            this._addTextRow('No status yet — run quotapanel-daemon --once, then Refresh.', 'quotapanel-note');
            return;
        }

        const providers = status.providers || [];
        const active = providers.filter(p => p.status === 'ok' || p.status === 'error');
        const needAuth = providers.filter(p => p.status === 'authProblem');

        if (active.length === 0) {
            this._addTextRow('No providers configured yet. Sign in to a tool, then Refresh.', 'quotapanel-note');
        } else {
            active.forEach((p, i) => {
                if (i > 0)
                    this._body.add_child(new St.Widget({style_class: 'quotapanel-gap'}));
                this._addProvider(p);
            });
        }

        if (needAuth.length > 0) {
            this._body.add_child(new St.Widget({style_class: 'quotapanel-gap'}));
            this._addTextRow(`${needAuth.length} not signed in: ${needAuth.map(p => p.name).join(', ')}`,
                'quotapanel-note-dim');
        }

        // Top-bar label: the fullest 5-hour session window across ok providers,
        // falling back to the fullest window overall when no provider exposes a
        // session window (so the label is never blank while data exists).
        let sessionPct = -1;
        let anyPct = -1;
        for (const p of providers) {
            if (p.status !== 'ok')
                continue;
            for (const w of (p.windows || [])) {
                anyPct = Math.max(anyPct, w.percent);
                if (isSessionWindow(w))
                    sessionPct = Math.max(sessionPct, w.percent);
            }
        }
        const shown = sessionPct >= 0 ? sessionPct : anyPct;
        this._label.text = shown >= 0 ? ` ${Math.round(shown)}%` : '';
    }

    _refreshNow() {
        if (!this._daemonPath)
            return;
        try {
            const proc = Gio.Subprocess.new(
                [this._daemonPath, '--once'],
                Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
            proc.wait_async(null, () => {
                if (this._onRefreshDone)
                    this._onRefreshDone();
            });
        } catch (e) {
            logError(e, 'QuotaPanel: failed to spawn daemon');
        }
    }
});

export default class QuotaPanelExtension extends Extension {
    enable() {
        this._statusPath = GLib.build_filenamev([configDir(), 'status.json']);
        this._daemonPath = findDaemon();

        this._indicator = new QuotaPanelIndicator(this._daemonPath);
        this._indicator._onRefreshDone = () => this._scheduleReload(50);
        Main.panel.addToStatusArea('quotapanel', this._indicator);

        // Watch the config directory for status.json being (atomically) replaced.
        try {
            const dir = Gio.File.new_for_path(configDir());
            this._monitor = dir.monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, null);
            this._monitor.connect('changed', (_m, file) => {
                if (file && file.get_basename() === 'status.json')
                    this._scheduleReload(200);
            });
        } catch (e) {
            logError(e, 'QuotaPanel: directory monitor failed');
        }

        // Fallback poll in case the monitor misses an event.
        this._pollId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, POLL_SECONDS, () => {
            this._reload();
            return GLib.SOURCE_CONTINUE;
        });

        this._reload();
    }

    disable() {
        if (this._reloadId) {
            GLib.source_remove(this._reloadId);
            this._reloadId = 0;
        }
        if (this._pollId) {
            GLib.source_remove(this._pollId);
            this._pollId = 0;
        }
        if (this._monitor) {
            this._monitor.cancel();
            this._monitor = null;
        }
        if (this._indicator) {
            this._indicator.destroy();
            this._indicator = null;
        }
    }

    _scheduleReload(delayMs) {
        if (this._reloadId)
            GLib.source_remove(this._reloadId);
        this._reloadId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, delayMs ?? 200, () => {
            this._reloadId = 0;
            this._reload();
            return GLib.SOURCE_REMOVE;
        });
    }

    _reload() {
        if (!this._indicator)
            return;
        let status = null;
        try {
            const file = Gio.File.new_for_path(this._statusPath);
            const [ok, contents] = file.load_contents(null);
            if (ok) {
                const decoder = new TextDecoder();
                status = JSON.parse(decoder.decode(contents));
            }
        } catch (e) {
            // Missing/half-written file: keep the previous render, try again later.
            status = this._lastStatus ?? null;
        }
        if (status)
            this._lastStatus = status;
        this._indicator.render(status);
    }
}
