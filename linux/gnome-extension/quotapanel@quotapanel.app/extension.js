// QuotaPanel — GNOME Shell extension.
//
// A top-bar button that opens a panel mirroring the macOS QuotaPanel app:
// a provider icon strip, Live / Summary / Heatmap tabs, token-composition
// bars, open-session context cards, a 14-day cost chart, and an in-panel
// Settings page. It renders the status.json written by `quotapanel-daemon`;
// it does no network itself. Settings persist to config.json, which the
// daemon also reads (enabled providers).

import GObject from 'gi://GObject';
import St from 'gi://St';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Clutter from 'gi://Clutter';
import Cairo from 'cairo';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const PANEL_WIDTH = 300;  // px — content width (slightly narrower than macOS)
const BAR_WIDTH = PANEL_WIDTH - 20;
const POLL_SECONDS = 30;  // fallback re-read cadence (file monitor covers the rest)
const MAX_ALERT_THRESHOLDS = 6;

// Token-type segment colors (same as the macOS app / ai-token-tracker)
const PART_COLORS = {input: '#e8843a', cache: '#3ea76f', output: '#e6cf4f'};
const CHART_COLOR = '#3b82f6';

// Static provider catalog for the Settings page: config.json can disable a
// provider, and the daemon then stops writing it to status.json — so the
// re-enable list cannot come from status.json. Mirrors Engine.supported.
const PROVIDER_CATALOG = [
    ['claude', 'Claude Code'], ['codex', 'Codex'], ['gemini', 'Gemini'],
    ['copilot', 'Copilot'], ['droid', 'Droid'], ['warp', 'Warp'],
    ['amp', 'Amp'], ['augment', 'Augment'], ['kilo', 'Kilo'],
    ['kiro', 'Kiro'], ['opencode', 'OpenCode'], ['opencodego', 'OpenCode Go'],
    ['antigravity', 'Antigravity'], ['devin', 'Devin'], ['qoder', 'Qoder'],
    ['commandcode', 'Command Code'], ['crossmodel', 'CrossModel'],
    ['manus', 'Manus'], ['codebuff', 'Codebuff'],
];

// status.json / config.json live under $XDG_CONFIG_HOME/quotapanel.
function configDir() {
    const xdg = GLib.getenv('XDG_CONFIG_HOME');
    const base = xdg && xdg.length > 0 ? xdg : GLib.build_filenamev([GLib.get_home_dir(), '.config']);
    return GLib.build_filenamev([base, 'quotapanel']);
}

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

// Percent label: one decimal when fractional (3.1), none when whole (32).
function formatPercent(value) {
    const rounded = Math.round(value * 10) / 10;
    return Number.isInteger(rounded) ? String(rounded) : rounded.toFixed(1);
}

// Compact token count like 1.2M / 45.3K.
function formatTokens(value) {
    if (value >= 1_000_000)
        return `${(value / 1_000_000).toFixed(1)}M`;
    if (value >= 1_000)
        return `${(value / 1_000).toFixed(1)}K`;
    return String(value);
}

function clockTime(date) {
    return date.toLocaleTimeString([], {hour: '2-digit', minute: '2-digit'});
}

// Absolute reset time ("21:21", "tomorrow 21:21", "Mon 21:21", "Jul 20 21:21"),
// mirroring the macOS resetLabel. null when past or unparsable.
function resetLabel(isoString) {
    if (!isoString)
        return null;
    const then = new Date(isoString);
    if (isNaN(then.getTime()) || then <= new Date())
        return null;
    const time = clockTime(then);
    const now = new Date();
    const startOfDay = d => new Date(d.getFullYear(), d.getMonth(), d.getDate());
    const days = Math.round((startOfDay(then) - startOfDay(now)) / 86_400_000);
    if (days === 0)
        return time;
    if (days === 1)
        return `tomorrow ${time}`;
    if (days < 7)
        return `${then.toLocaleDateString([], {weekday: 'short'})} ${time}`;
    return `${then.toLocaleDateString([], {month: 'short', day: 'numeric'})} ${time}`;
}

// Severity color for a usage percent (same steps as the macOS UsageMeterView).
function severityColor(pct) {
    if (pct < 50) return '#2ec27e';   // green
    if (pct < 80) return '#e5c07b';   // yellow
    if (pct < 95) return '#ff7800';   // orange
    return '#e5484d';                 // red
}

function contextColor(pct) {
    if (pct < 70) return '#2ec27e';
    if (pct < 90) return '#ff7800';
    return '#e5484d';
}

function partsTotal(parts) {
    return (parts?.input ?? 0) + (parts?.cache ?? 0) + (parts?.output ?? 0);
}

function partsFractions(parts) {
    const t = Math.max(partsTotal(parts), 1);
    return {input: parts.input / t, cache: parts.cache / t, output: parts.output / t};
}

function hexToRGBA(hex, alpha = 1) {
    const v = parseInt(hex.slice(1), 16);
    return [((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255, alpha];
}

// ---------------------------------------------------------------------------
// config.json — shared with the daemon (it reads enabledProviders).

class Config {
    constructor() {
        this._path = GLib.build_filenamev([configDir(), 'config.json']);
        this.data = {};
        this.load();
    }

    load() {
        try {
            const [ok, contents] = GLib.file_get_contents(this._path);
            if (ok)
                this.data = JSON.parse(new TextDecoder().decode(contents)) ?? {};
        } catch {
            this.data = {};
        }
    }

    save() {
        try {
            GLib.mkdir_with_parents(configDir(), 0o700);
            // file_set_contents writes to a temp file and renames — atomic.
            GLib.file_set_contents(this._path, JSON.stringify(this.data, null, 2));
        } catch (e) {
            logError(e, 'QuotaPanel: failed to save config.json');
        }
    }

    get refreshSeconds() {
        const v = this.data.refreshSeconds;
        return Number.isInteger(v) && v >= 30 ? v : 300;
    }

    get alertThresholds() {
        return Array.isArray(this.data.alertThresholds)
            ? this.data.alertThresholds
            : [80, 95];
    }

    get showPercent() {
        return this.data.showPercentInTopBar ?? true;
    }

    // "30 s", "5 min", "1.5 min" — same wording as the macOS refreshLabel.
    get refreshLabel() {
        const s = this.refreshSeconds;
        if (s < 60) return `${s} s`;
        if (s % 60 === 0) return `${s / 60} min`;
        return `${(s / 60).toFixed(1)} min`;
    }
}

// ---------------------------------------------------------------------------
// Small widget builders

function label(text, styleClass, props = {}) {
    return new St.Label({text, style_class: styleClass, ...props});
}

function iconButton(iconName, accessibleName, onClick) {
    const button = new St.Button({
        style_class: 'quotapanel-icon-button',
        can_focus: true,
        child: new St.Icon({icon_name: iconName, icon_size: 14}),
    });
    button.accessible_name = accessibleName;
    button.connect('clicked', onClick);
    return button;
}

// Bar filled to `percent`, split into input/cache/output segments when
// `parts` has any tokens; solid `tint` otherwise. The track is a horizontal
// BoxLayout so the fill packs at the LEFT edge and grows rightward.
function segmentedBar(percent, parts, tint) {
    const track = new St.BoxLayout({style_class: 'quotapanel-bar-track'});
    track.set_style(`width: ${BAR_WIDTH}px;`);
    const pct = Math.max(0, Math.min(100, percent));
    const fillPx = pct > 0 ? Math.max(2, Math.round(BAR_WIDTH * pct / 100)) : 0;
    if (fillPx <= 0)
        return track;
    if (partsTotal(parts) > 0) {
        const f = partsFractions(parts);
        const box = new St.BoxLayout({style_class: 'quotapanel-bar-fill'});
        box.set_style(`width: ${fillPx}px;`);
        for (const key of ['input', 'cache', 'output']) {
            const seg = new St.Bin();
            seg.set_style(`width: ${Math.round(fillPx * f[key])}px; background-color: ${PART_COLORS[key]};`);
            box.add_child(seg);
        }
        track.add_child(box);
    } else {
        const fill = new St.Bin({style_class: 'quotapanel-bar-fill'});
        fill.set_style(`width: ${fillPx}px; background-color: ${tint};`);
        track.add_child(fill);
    }
    return track;
}

// "· input 2% · cache 19% · output 6%" legend row, each share scaled to `percent`.
function partsCaption(parts, percent) {
    const row = new St.BoxLayout({style_class: 'quotapanel-legend'});
    const f = partsFractions(parts);
    const entries = [['input', f.input], ['cache', f.cache], ['output', f.output]];
    entries.forEach(([name, fraction], i) => {
        if (i > 0)
            row.add_child(label('·', 'quotapanel-legend-sep'));
        const dot = new St.Bin({style_class: 'quotapanel-legend-dot', y_align: Clutter.ActorAlign.CENTER});
        dot.set_style(`background-color: ${PART_COLORS[name]};`);
        row.add_child(dot);
        row.add_child(label(`${name} ${formatPercent(fraction * percent)}%`, 'quotapanel-legend-text'));
    });
    return row;
}

// ---------------------------------------------------------------------------
// Cairo drawings: 14-day chart and the two heatmap grids

function drawChart(area, stats, showCost) {
    area.connect('repaint', () => {
        const cr = area.get_context();
        const [width, height] = area.get_surface_size();
        const fg = area.get_theme_node().get_foreground_color();
        const axisWidth = 34;
        const labelHeight = 12;
        const plotW = width - axisWidth;
        const plotH = height - labelHeight;

        // Last 14 days, oldest first.
        const days = [];
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        const byDay = new Map((stats ?? []).map(s => [s.day, showCost ? s.costUSD : s.tokens]));
        for (let i = 13; i >= 0; i--) {
            const d = new Date(today.getTime() - i * 86_400_000);
            const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
            days.push({date: d, value: byDay.get(key) ?? 0});
        }
        let max = Math.max(...days.map(d => d.value), showCost ? 1 : 1000);
        // Round the axis up to a friendly number.
        const mag = Math.pow(10, Math.floor(Math.log10(max)));
        max = Math.ceil(max / mag) * mag;

        cr.selectFontFace('Sans', Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
        cr.setFontSize(9);

        // Gridlines + axis labels at 0 / ½ / max.
        for (const frac of [0, 0.5, 1]) {
            const y = plotH - frac * (plotH - 4);
            cr.setSourceRGBA(fg.red / 255, fg.green / 255, fg.blue / 255, 0.15);
            cr.rectangle(0, y - 0.5, plotW, 1);
            cr.fill();
            const v = max * frac;
            const text = showCost ? `$${Math.round(v)}` : formatTokens(Math.round(v));
            cr.setSourceRGBA(fg.red / 255, fg.green / 255, fg.blue / 255, 0.55);
            cr.moveTo(plotW + 4, y + 3);
            cr.showText(text);
        }

        // Bars.
        const [br, bg_, bb] = hexToRGBA(CHART_COLOR);
        const slot = plotW / 14;
        const barW = Math.max(4, slot - 4);
        days.forEach((d, i) => {
            if (d.value <= 0)
                return;
            const h = Math.max(1, (d.value / max) * (plotH - 4));
            cr.setSourceRGBA(br, bg_, bb, 1);
            cr.rectangle(i * slot + (slot - barW) / 2, plotH - h, barW, h);
            cr.fill();
        });

        // X labels every 3 days.
        cr.setSourceRGBA(fg.red / 255, fg.green / 255, fg.blue / 255, 0.55);
        days.forEach((d, i) => {
            if (i % 3 !== 0)
                return;
            const text = d.date.toLocaleDateString([], {month: 'short', day: 'numeric'});
            cr.moveTo(i * slot + 1, height - 2);
            cr.showText(text);
        });
        cr.$dispose();
    });
}

const HEAT_ALPHAS = [0, 0.3, 0.55, 0.78, 1.0];
const CELL = 9;
const GAP = 2;
const DAY_LABEL_W = 22;
const DAY_NAMES = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

function heatColor(cr, fg, brand, level) {
    if (level <= 0) {
        cr.setSourceRGBA(fg.red / 255, fg.green / 255, fg.blue / 255, 0.15);
    } else {
        const [r, g, b] = hexToRGBA(brand);
        cr.setSourceRGBA(r, g, b, HEAT_ALPHAS[Math.min(level, 4)]);
    }
}

function roundedCell(cr, x, y) {
    const r = 2;
    cr.newSubPath();
    cr.arc(x + CELL - r, y + r, r, -Math.PI / 2, 0);
    cr.arc(x + CELL - r, y + CELL - r, r, 0, Math.PI / 2);
    cr.arc(x + r, y + CELL - r, r, Math.PI / 2, Math.PI);
    cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
    cr.closePath();
    cr.fill();
}

// GitHub-style daily grid: week columns × 7 rows, day names down the left.
function drawDailyGrid(area, weeks, brand) {
    area.connect('repaint', () => {
        const cr = area.get_context();
        const fg = area.get_theme_node().get_foreground_color();
        cr.selectFontFace('Sans', Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
        cr.setFontSize(7);
        for (let d = 0; d < 7; d++) {
            cr.setSourceRGBA(fg.red / 255, fg.green / 255, fg.blue / 255, 0.5);
            cr.moveTo(0, d * (CELL + GAP) + CELL - 1);
            cr.showText(DAY_NAMES[d]);
        }
        weeks.forEach((column, w) => {
            column.forEach((cell, d) => {
                if (!cell)
                    return;
                heatColor(cr, fg, brand, cell.l);
                roundedCell(cr, DAY_LABEL_W + w * (CELL + GAP), d * (CELL + GAP));
            });
        });
        cr.$dispose();
    });
}

// Hour-of-day punch card: one row per day (oldest on top), 0–23 columns.
function drawHourGrid(area, rows, brand) {
    area.connect('repaint', () => {
        const cr = area.get_context();
        const fg = area.get_theme_node().get_foreground_color();
        cr.selectFontFace('Sans', Cairo.FontSlant.NORMAL, Cairo.FontWeight.NORMAL);
        cr.setFontSize(7);
        rows.forEach((row, d) => {
            cr.setSourceRGBA(fg.red / 255, fg.green / 255, fg.blue / 255, 0.5);
            cr.moveTo(0, d * (CELL + GAP) + CELL - 1);
            cr.showText(row.day);
            row.cells.forEach((cell, h) => {
                heatColor(cr, fg, brand, cell.l);
                roundedCell(cr, DAY_LABEL_W + h * (CELL + GAP), d * (CELL + GAP));
            });
        });
        // Hour scale under the grid.
        cr.setSourceRGBA(fg.red / 255, fg.green / 255, fg.blue / 255, 0.5);
        const y = rows.length * (CELL + GAP) + 8;
        for (const h of [0, 6, 12, 18, 23]) {
            cr.moveTo(DAY_LABEL_W + h * (CELL + GAP), y);
            cr.showText(String(h));
        }
        cr.$dispose();
    });
}

// ---------------------------------------------------------------------------

const QuotaPanelIndicator = GObject.registerClass(
class QuotaPanelIndicator extends PanelMenu.Button {
    _init(extension) {
        super._init(0.5, 'QuotaPanel');
        this._ext = extension;
        this._config = extension._config;
        this._daemonPath = extension._daemonPath;
        this._iconsDir = GLib.build_filenamev([extension.path, 'icons']);

        this._mode = 'live';           // 'live' | 'summary' | 'heatmap'
        this._showSettings = false;
        this._selectedId = this._config.data.selectedProvider ?? null;
        this._status = null;
        this._isRefreshing = false;

        const box = new St.BoxLayout({style_class: 'panel-status-menu-box'});
        this._topIcon = new St.Icon({
            icon_name: 'utilities-system-monitor-symbolic',
            style_class: 'system-status-icon',
        });
        this._topLabel = new St.Label({
            text: '',
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'quotapanel-top-label',
        });
        box.add_child(this._topIcon);
        box.add_child(this._topLabel);
        this.add_child(box);

        this._buildMenu();
    }

    _buildMenu() {
        // Provider strip (horizontal scroll).
        this._stripItem = new PopupMenu.PopupBaseMenuItem({activate: false, reactive: false, can_focus: false});
        this._stripScroll = new St.ScrollView({
            style_class: 'quotapanel-strip-scroll',
            hscrollbar_policy: St.PolicyType.EXTERNAL,
            vscrollbar_policy: St.PolicyType.NEVER,
        });
        this._strip = new St.BoxLayout({style_class: 'quotapanel-strip'});
        if (this._stripScroll.set_child)
            this._stripScroll.set_child(this._strip);
        else
            this._stripScroll.add_actor(this._strip);
        this._stripItem.add_child(this._stripScroll);
        this.menu.addMenuItem(this._stripItem);
        this._stripSep = new PopupMenu.PopupSeparatorMenuItem();
        this.menu.addMenuItem(this._stripSep);

        // Header: dot · name · time · refresh. Built once and updated in
        // place — rebuilding it on every render would destroy the refresh
        // button in the middle of its own click handling.
        this._headerItem = new PopupMenu.PopupBaseMenuItem({activate: false, reactive: false, can_focus: false});
        this._header = new St.BoxLayout({style_class: 'quotapanel-header', x_expand: true});
        this._headerDot = new St.Bin({style_class: 'quotapanel-dot', y_align: Clutter.ActorAlign.CENTER});
        this._headerName = label('QuotaPanel', 'quotapanel-provider-name', {y_align: Clutter.ActorAlign.CENTER});
        this._headerTime = label('', 'quotapanel-time', {y_align: Clutter.ActorAlign.CENTER});
        // Refresh button: a static icon, swapped for a three-dot bouncing
        // loader while the daemon runs (dots share one BinLayout stack so
        // nothing is reparented mid-click).
        this._refreshIcon = new St.Icon({icon_name: 'view-refresh-symbolic', icon_size: 14});
        this._refreshSpinner = new St.BoxLayout({style_class: 'quotapanel-spinner', y_align: Clutter.ActorAlign.CENTER, visible: false});
        this._spinnerDots = [0, 1, 2].map(() => {
            const dot = new St.Bin({style_class: 'quotapanel-spinner-dot'});
            this._refreshSpinner.add_child(dot);
            return dot;
        });
        const refreshStack = new St.Widget({layout_manager: new Clutter.BinLayout()});
        refreshStack.add_child(this._refreshIcon);
        refreshStack.add_child(this._refreshSpinner);
        this._refreshButton = new St.Button({style_class: 'quotapanel-icon-button', can_focus: true, child: refreshStack});
        this._refreshButton.accessible_name = 'Refresh now';
        this._refreshButton.connect('clicked', () => this._refreshNow());
        this._header.add_child(this._headerDot);
        this._header.add_child(this._headerName);
        this._header.add_child(new St.Widget({x_expand: true}));
        this._header.add_child(this._headerTime);
        this._header.add_child(this._refreshButton);
        this._headerItem.add_child(this._header);
        this.menu.addMenuItem(this._headerItem);

        // Body: everything below the header (tabs + view, or Settings), inside
        // a vertical scroll view so tall pages (Settings) wheel-scroll and the
        // popup never outgrows the screen.
        this._bodyItem = new PopupMenu.PopupBaseMenuItem({activate: false, reactive: false, can_focus: false});
        this._bodyScroll = new St.ScrollView({
            style_class: 'quotapanel-body-scroll',
            hscrollbar_policy: St.PolicyType.NEVER,
            vscrollbar_policy: St.PolicyType.AUTOMATIC,
        });
        this._body = new St.BoxLayout({vertical: true, style_class: 'quotapanel-body'});
        if (this._bodyScroll.set_child)
            this._bodyScroll.set_child(this._body);
        else
            this._bodyScroll.add_actor(this._body);
        this._bodyItem.add_child(this._bodyScroll);
        this.menu.addMenuItem(this._bodyItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        // Footer: gear ⇄ back.
        this._footerItem = new PopupMenu.PopupBaseMenuItem({activate: false, reactive: false, can_focus: false});
        this._footer = new St.BoxLayout({style_class: 'quotapanel-footer', x_expand: true});
        this._footerItem.add_child(this._footer);
        this.menu.addMenuItem(this._footerItem);
    }

    // MARK: - Data helpers

    _providers() {
        return this._status?.providers ?? [];
    }

    // Enabled set: explicit config list, or (first run) providers that look
    // signed-in — mirrors the macOS default of "tools with credentials".
    _enabledSet() {
        const cfg = this._config.data.enabledProviders;
        if (Array.isArray(cfg))
            return new Set(cfg);
        return new Set(this._providers().filter(p => p.status !== 'authProblem').map(p => p.id));
    }

    _visibleProviders() {
        const enabled = this._enabledSet();
        const visible = this._providers().filter(p => enabled.has(p.id));
        return visible.length > 0 ? visible : this._providers();
    }

    _selected() {
        const visible = this._visibleProviders();
        if (visible.length === 0)
            return null;
        return visible.find(p => p.id === this._selectedId) ?? visible[0];
    }

    _sessionPercent(p) {
        if (p.status !== 'ok')
            return null;
        let session = -1;
        let worst = -1;
        for (const w of p.windows ?? []) {
            worst = Math.max(worst, w.percent);
            if (isSessionWindow(w))
                session = Math.max(session, w.percent);
        }
        const pct = session >= 0 ? session : worst;
        return pct >= 0 ? Math.max(0, Math.min(100, pct)) : null;
    }

    _hasLocalLogs(p) {
        return p.summary != null || p.heatmap != null || p.daily != null;
    }

    // MARK: - Rendering

    render(status) {
        if (status)
            this._status = status;
        this._renderStrip();
        this._renderHeader();
        this._renderBody();
        this._renderFooter();
        this._renderTopBar();
    }

    _renderTopBar() {
        let pct = -1;
        const enabled = this._enabledSet();
        for (const p of this._providers()) {
            if (!enabled.has(p.id))
                continue;
            const v = this._sessionPercent(p);
            if (v !== null)
                pct = Math.max(pct, v);
        }
        this._topLabel.text = this._config.showPercent && pct >= 0 ? ` ${Math.round(pct)}%` : '';
    }

    _providerIcon(p, size) {
        const path = GLib.build_filenamev([this._iconsDir, `ProviderIcon-${p.id}.svg`]);
        if (GLib.file_test(path, GLib.FileTest.EXISTS)) {
            return new St.Icon({
                gicon: new Gio.FileIcon({file: Gio.File.new_for_path(path)}),
                icon_size: size,
            });
        }
        // Fallback: lettered circle in the brand color.
        const circle = new St.Bin({
            style_class: 'quotapanel-icon-fallback',
            child: label(p.shortLabel ?? '?', 'quotapanel-icon-fallback-text'),
        });
        circle.set_style(`background-color: ${p.brandColor}; width: ${size}px; height: ${size}px; border-radius: ${size / 2}px;`);
        return circle;
    }

    _renderStrip() {
        this._strip.destroy_all_children();
        const visible = this._visibleProviders();
        this._stripItem.visible = this._stripSep.visible = !this._showSettings && visible.length > 0;
        if (this._showSettings)
            return;
        const selected = this._selected();
        for (const p of visible) {
            const chip = new St.Button({
                style_class: p.id === selected?.id ? 'quotapanel-chip quotapanel-chip-selected' : 'quotapanel-chip',
                can_focus: true,
            });
            const box = new St.BoxLayout({vertical: true, style_class: 'quotapanel-chip-box'});
            const iconBin = new St.Bin({child: this._providerIcon(p, 22), x_align: Clutter.ActorAlign.CENTER});
            box.add_child(iconBin);
            box.add_child(label(p.name, 'quotapanel-chip-label', {x_align: Clutter.ActorAlign.CENTER}));
            // Mini bar filled to the session window (left-packed fill).
            const track = new St.BoxLayout({
                style_class: 'quotapanel-chip-bar-track',
                x_align: Clutter.ActorAlign.CENTER,
            });
            const pct = this._sessionPercent(p);
            if (pct !== null && pct > 0) {
                const fill = new St.Bin({style_class: 'quotapanel-chip-bar-fill'});
                fill.set_style(`width: ${Math.max(2, Math.round(44 * pct / 100))}px; background-color: ${p.brandColor};`);
                track.add_child(fill);
            }
            box.add_child(track);
            chip.set_child(box);
            chip.connect('clicked', () => {
                this._selectedId = p.id;
                this._config.data.selectedProvider = p.id;
                this._config.save();
                this.render();
            });
            this._strip.add_child(chip);
        }
    }

    _renderHeader() {
        const p = this._selected();
        this._headerDot.set_style(`background-color: ${p?.brandColor ?? '#888888'};`);
        this._headerName.text = p?.name ?? 'QuotaPanel';
        const generated = this._status?.generatedAt ? new Date(this._status.generatedAt) : null;
        this._headerTime.text = generated && !isNaN(generated.getTime()) ? clockTime(generated) : '';
        // Busy feedback: while the daemon runs the icon gives way to the
        // bouncing-dots loader and the button stops accepting clicks.
        this._refreshButton.reactive = !!this._daemonPath && !this._isRefreshing;
        this._refreshButton.opacity = this._daemonPath ? 255 : 130;
        this._refreshIcon.visible = !this._isRefreshing;
        this._refreshSpinner.visible = this._isRefreshing;
        if (this._isRefreshing)
            this._startSpinner();
        else
            this._stopSpinner();
    }

    // Dots bounce one after another (1 up-down, 2 up-down, 3 up-down, repeat).
    _startSpinner() {
        if (this._spinnerActive)
            return;
        this._spinnerActive = true;
        this._animateSpinner();
    }

    _stopSpinner() {
        if (!this._spinnerActive)
            return;
        this._spinnerActive = false;
        for (const dot of this._spinnerDots) {
            dot.remove_all_transitions();
            dot.translation_y = 0;
        }
    }

    _animateSpinner() {
        if (!this._spinnerActive)
            return;
        this._spinnerDots.forEach((dot, i) => {
            dot.ease({
                translation_y: -3,
                duration: 180,
                delay: i * 160,
                mode: Clutter.AnimationMode.EASE_OUT_QUAD,
                onComplete: () => {
                    dot.ease({
                        translation_y: 0,
                        duration: 180,
                        mode: Clutter.AnimationMode.EASE_IN_QUAD,
                        onComplete: () => {
                            // The last dot landing starts the next wave.
                            if (i === this._spinnerDots.length - 1)
                                this._animateSpinner();
                        },
                    });
                },
            });
        });
    }

    _renderFooter() {
        this._footer.destroy_all_children();
        const gear = iconButton(
            this._showSettings ? 'go-previous-symbolic' : 'emblem-system-symbolic',
            this._showSettings ? 'Back' : 'Settings',
            () => {
                this._showSettings = !this._showSettings;
                this.render();
            });
        this._footer.add_child(gear);
    }

    _renderBody() {
        this._body.destroy_all_children();
        if (this._showSettings) {
            this._renderSettings();
            return;
        }
        if (!this._status) {
            this._note('No status yet — run quotapanel-daemon --once, then Refresh.');
            return;
        }
        const p = this._selected();
        if (!p) {
            this._note('No providers configured yet. Sign in to a tool, then Refresh.');
            return;
        }

        if (this._hasLocalLogs(p)) {
            this._body.add_child(this._makeTabs());
            switch (this._mode) {
            case 'summary': this._renderSummary(p); return;
            case 'heatmap': this._renderHeatmap(p); return;
            }
        }
        this._renderLive(p);
    }

    _note(text, styleClass = 'quotapanel-note') {
        const l = label(text, styleClass);
        l.clutter_text.line_wrap = true;
        this._body.add_child(l);
    }

    _makeTabs() {
        const tabs = new St.BoxLayout({style_class: 'quotapanel-tabs', x_expand: true});
        for (const [key, name] of [['live', 'Live'], ['summary', 'Summary'], ['heatmap', 'Heatmap']]) {
            const tab = new St.Button({
                label: name,
                style_class: key === this._mode ? 'quotapanel-tab quotapanel-tab-selected' : 'quotapanel-tab',
                can_focus: true,
                x_expand: true,
            });
            tab.connect('clicked', () => {
                this._mode = key;
                this.render();
            });
            tabs.add_child(tab);
        }
        return tabs;
    }

    // MARK: Live view

    _renderLive(p) {
        if (p.plan) {
            const plan = label(p.plan, 'quotapanel-plan');
            this._body.add_child(new St.Bin({child: plan, x_align: Clutter.ActorAlign.START}));
        }

        if (p.status === 'authProblem') {
            this._statusRow('dialog-password-symbolic', p.message || 'Not signed in');
        } else if (p.status === 'error') {
            this._statusRow('dialog-warning-symbolic', p.message || 'Error', 'quotapanel-error');
        } else if (!p.windows || p.windows.length === 0) {
            this._note('No usage data');
        } else {
            for (const w of p.windows)
                this._body.add_child(this._windowRow(w, p));
        }

        for (const c of p.contexts ?? [])
            this._body.add_child(this._contextCard(c));

        if (this._hasLocalLogs(p) && p.daily) {
            this._body.add_child(new St.Widget({style_class: 'quotapanel-divider', x_expand: true}));
            this._renderChartSection(p);
        }
    }

    _statusRow(iconName, message, styleClass = 'quotapanel-note') {
        const row = new St.BoxLayout({style_class: 'quotapanel-status-row'});
        row.add_child(new St.Icon({icon_name: iconName, icon_size: 14, style_class: 'quotapanel-status-icon'}));
        const l = label(message, styleClass);
        l.clutter_text.line_wrap = true;
        row.add_child(l);
        this._body.add_child(row);
    }

    _windowRow(w, p) {
        const row = new St.BoxLayout({vertical: true, style_class: 'quotapanel-window'});
        const pct = Math.max(0, Math.min(100, w.percent));
        const color = severityColor(pct);

        const top = new St.BoxLayout({x_expand: true});
        top.add_child(label(w.label, 'quotapanel-window-label'));
        const pctLabel = label(`${formatPercent(pct)}%`, 'quotapanel-pct', {
            x_expand: true, x_align: Clutter.ActorAlign.END,
        });
        pctLabel.set_style(`color: ${color};`);
        top.add_child(pctLabel);
        row.add_child(top);

        // Composition applies to the session window only; weekly windows
        // can't be derived from a 5-hour scan.
        const parts = isSessionWindow(w) ? p.sessionParts : null;
        if (partsTotal(parts) > 0)
            row.add_child(partsCaption(parts, pct));
        row.add_child(segmentedBar(pct, parts, color));

        const reset = resetLabel(w.resetsAt);
        if (reset) {
            const resetRow = new St.BoxLayout({style_class: 'quotapanel-reset-row'});
            resetRow.add_child(new St.Icon({icon_name: 'view-refresh-symbolic', icon_size: 9, style_class: 'quotapanel-reset-icon'}));
            resetRow.add_child(label(`Resets: ${reset}`, 'quotapanel-reset'));
            row.add_child(resetRow);
        }
        return row;
    }

    _contextCard(c) {
        const card = new St.BoxLayout({vertical: true, style_class: 'quotapanel-window'});
        const pct = c.percent ?? 0;

        const top = new St.BoxLayout({x_expand: true});
        top.add_child(label(c.project ? `CONTEXT · ${c.project}` : 'CONTEXT', 'quotapanel-context-title'));
        const pctLabel = label(`${formatPercent(pct)}%`, 'quotapanel-pct', {
            x_expand: true, x_align: Clutter.ActorAlign.END,
        });
        pctLabel.set_style(`color: ${contextColor(pct)};`);
        top.add_child(pctLabel);
        card.add_child(top);

        if (partsTotal(c.parts) > 0)
            card.add_child(partsCaption(c.parts, pct));
        card.add_child(segmentedBar(pct, c.parts, contextColor(pct)));

        const bottom = new St.BoxLayout({x_expand: true});
        bottom.add_child(label(`${formatTokens(c.used)} / ${formatTokens(c.limit)} tokens`, 'quotapanel-context-detail'));
        if (c.detail) {
            bottom.add_child(label(c.detail, 'quotapanel-context-detail', {
                x_expand: true, x_align: Clutter.ActorAlign.END,
            }));
        }
        card.add_child(bottom);
        return card;
    }

    _renderChartSection(p) {
        const isClaude = p.id === 'claude';
        const title = isClaude ? 'Estimated cost (14 days)' : 'Token usage (14 days)';
        this._body.add_child(label(title, 'quotapanel-section-title'));

        if ((p.daily ?? []).length === 0) {
            this._note('No data yet');
        } else {
            const area = new St.DrawingArea({style_class: 'quotapanel-chart'});
            area.set_size(BAR_WIDTH, 84);
            drawChart(area, p.daily, isClaude);
            this._body.add_child(area);
            area.queue_repaint();
        }

        // Today / This month totals under the chart.
        const now = new Date();
        const pad = n => String(n).padStart(2, '0');
        const todayKey = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
        const monthPrefix = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-`;
        const totals = new St.BoxLayout({x_expand: true, style_class: 'quotapanel-chart-totals'});
        if (isClaude) {
            const today = (p.daily ?? []).find(d => d.day === todayKey)?.costUSD ?? 0;
            const month = (p.daily ?? []).filter(d => d.day.startsWith(monthPrefix))
                .reduce((sum, d) => sum + d.costUSD, 0);
            totals.add_child(label(`Today: $${today.toFixed(2)}`, 'quotapanel-note'));
            totals.add_child(label(`This month: $${month.toFixed(2)}`, 'quotapanel-note', {
                x_expand: true, x_align: Clutter.ActorAlign.END,
            }));
        } else {
            const today = (p.daily ?? []).find(d => d.day === todayKey)?.tokens ?? 0;
            totals.add_child(label(`Today: ${formatTokens(today)} tokens`, 'quotapanel-note'));
        }
        this._body.add_child(totals);
    }

    // MARK: Summary view

    _renderSummary(p) {
        for (const bucket of p.summary ?? []) {
            const row = new St.BoxLayout({vertical: true, style_class: 'quotapanel-window'});
            const top = new St.BoxLayout({x_expand: true});
            top.add_child(label(bucket.label, 'quotapanel-window-label'));
            top.add_child(label(`${formatTokens(partsTotal(bucket.parts))} tokens`, 'quotapanel-summary-total', {
                x_expand: true, x_align: Clutter.ActorAlign.END,
            }));
            row.add_child(top);
            if (partsTotal(bucket.parts) > 0) {
                row.add_child(partsCaption(bucket.parts, 100));
                row.add_child(segmentedBar(100, bucket.parts, '#888888'));
            } else {
                row.add_child(label('No usage in this period', 'quotapanel-note-dim'));
            }
            this._body.add_child(row);
        }
    }

    // MARK: Heatmap view

    _renderHeatmap(p) {
        const hm = p.heatmap;
        if (!hm) {
            this._note('No local usage logs found.');
            return;
        }
        const head = new St.BoxLayout({x_expand: true});
        head.add_child(label('Daily · last 12 weeks', 'quotapanel-section-title'));
        head.add_child(label(`${formatTokens(hm.totalTokens)} tokens`, 'quotapanel-summary-total', {
            x_expand: true, x_align: Clutter.ActorAlign.END,
        }));
        this._body.add_child(head);

        const daily = new St.DrawingArea({style_class: 'quotapanel-grid'});
        daily.set_size(DAY_LABEL_W + hm.dailyGrid.length * (CELL + GAP), 7 * (CELL + GAP));
        drawDailyGrid(daily, hm.dailyGrid, p.brandColor);
        this._body.add_child(daily);
        daily.queue_repaint();

        this._body.add_child(label('By hour · last 7 days', 'quotapanel-section-title'));
        const hours = new St.DrawingArea({style_class: 'quotapanel-grid'});
        hours.set_size(DAY_LABEL_W + 24 * (CELL + GAP), hm.hourRows.length * (CELL + GAP) + 12);
        drawHourGrid(hours, hm.hourRows, p.brandColor);
        this._body.add_child(hours);
        hours.queue_repaint();
    }

    // MARK: Settings page

    _checkRow(text, checked, onToggle) {
        const button = new St.Button({style_class: 'quotapanel-check-row', can_focus: true, x_expand: true});
        // St.Button centers its child by default; expand + START keeps the
        // checkbox/label packed at the left edge like the macOS grid.
        const box = new St.BoxLayout({x_expand: true, x_align: Clutter.ActorAlign.START});
        box.add_child(new St.Icon({
            icon_name: checked ? 'checkbox-checked-symbolic' : 'checkbox-symbolic',
            icon_size: 16,
            style_class: checked ? 'quotapanel-check-icon quotapanel-check-icon-on' : 'quotapanel-check-icon',
        }));
        box.add_child(label(text, 'quotapanel-check-label', {y_align: Clutter.ActorAlign.CENTER}));
        button.set_child(box);
        button.connect('clicked', onToggle);
        return button;
    }

    _stepperRow(text, onMinus, onPlus, extra = null) {
        const row = new St.BoxLayout({x_expand: true, style_class: 'quotapanel-stepper-row'});
        row.add_child(label(text, 'quotapanel-check-label', {y_align: Clutter.ActorAlign.CENTER}));
        const spacer = new St.Widget({x_expand: true});
        row.add_child(spacer);
        row.add_child(iconButton('list-remove-symbolic', 'Decrease', onMinus));
        row.add_child(iconButton('list-add-symbolic', 'Increase', onPlus));
        if (extra)
            row.add_child(extra);
        return row;
    }

    _saveEnabled(set) {
        this._config.data.enabledProviders = [...set].sort();
        this._config.save();
    }

    _renderSettings() {
        this._body.add_child(label('Settings', 'quotapanel-headline'));

        // Provider toggles, two columns like the macOS grid.
        const enabled = this._enabledSet();
        const grid = new St.BoxLayout({vertical: true, style_class: 'quotapanel-settings-grid'});
        for (let i = 0; i < PROVIDER_CATALOG.length; i += 2) {
            const rowBox = new St.BoxLayout({x_expand: true});
            for (const entry of [PROVIDER_CATALOG[i], PROVIDER_CATALOG[i + 1]]) {
                if (!entry) {
                    rowBox.add_child(new St.Widget({x_expand: true}));
                    continue;
                }
                const [id, name] = entry;
                const check = this._checkRow(name, enabled.has(id), () => {
                    const set = this._enabledSet();
                    if (set.has(id))
                        set.delete(id);
                    else
                        set.add(id);
                    this._saveEnabled(set);
                    this.render();
                    this._refreshNow();
                });
                check.set_style(`width: ${PANEL_WIDTH / 2 - 12}px;`);
                rowBox.add_child(check);
            }
            grid.add_child(rowBox);
        }
        this._body.add_child(grid);

        this._body.add_child(this._checkRow('Show percent in top bar', this._config.showPercent, () => {
            this._config.data.showPercentInTopBar = !this._config.showPercent;
            this._config.save();
            this.render();
        }));

        this._body.add_child(new St.Widget({style_class: 'quotapanel-divider', x_expand: true}));

        // Refresh interval (30 s steps, 30 s – 30 min), drives the auto-spawn timer.
        this._body.add_child(this._stepperRow(`Refresh interval: ${this._config.refreshLabel}`,
            () => this._bumpInterval(-30), () => this._bumpInterval(30)));

        this._body.add_child(new St.Widget({style_class: 'quotapanel-divider', x_expand: true}));

        // Alert thresholds.
        this._body.add_child(label('Alert thresholds (% used)', 'quotapanel-settings-title'));
        const thresholds = this._config.alertThresholds;
        if (thresholds.length === 0)
            this._note('No thresholds — notifications are off');
        thresholds.forEach((t, index) => {
            const remove = iconButton('edit-delete-symbolic', 'Remove this threshold', () => {
                const list = [...this._config.alertThresholds];
                list.splice(index, 1);
                this._config.data.alertThresholds = list;
                this._config.save();
                this.render();
            });
            this._body.add_child(this._stepperRow(`Threshold: ${Math.round(t)}%`,
                () => this._bumpThreshold(index, -5), () => this._bumpThreshold(index, 5), remove));
        });
        if (thresholds.length < MAX_ALERT_THRESHOLDS) {
            const add = new St.Button({style_class: 'quotapanel-check-row', can_focus: true});
            const box = new St.BoxLayout({x_expand: true, x_align: Clutter.ActorAlign.START});
            box.add_child(new St.Icon({icon_name: 'list-add-symbolic', icon_size: 14, style_class: 'quotapanel-check-icon'}));
            box.add_child(label('Add threshold', 'quotapanel-check-label', {y_align: Clutter.ActorAlign.CENTER}));
            add.set_child(box);
            add.connect('clicked', () => {
                const list = [...this._config.alertThresholds];
                let candidate = Math.min(99, (list.length ? Math.max(...list) : 45) + 10);
                while (list.includes(candidate) && candidate > 5)
                    candidate -= 5;
                list.push(candidate);
                list.sort((a, b) => a - b);
                this._config.data.alertThresholds = list;
                this._config.save();
                this.render();
            });
            this._body.add_child(add);
        }

        // Notifications status + test (GNOME shows extension notifications natively).
        const noteRow = new St.BoxLayout({x_expand: true, style_class: 'quotapanel-stepper-row'});
        const dot = new St.Bin({style_class: 'quotapanel-legend-dot', y_align: Clutter.ActorAlign.CENTER});
        dot.set_style('background-color: #2ec27e;');
        noteRow.add_child(dot);
        noteRow.add_child(label(thresholds.length > 0 ? 'Notifications: on' : 'Notifications: off (no thresholds)',
            'quotapanel-note', {y_align: Clutter.ActorAlign.CENTER}));
        const spacer = new St.Widget({x_expand: true});
        noteRow.add_child(spacer);
        const test = new St.Button({label: 'Test', style_class: 'quotapanel-text-button', can_focus: true});
        test.connect('clicked', () => Main.notify('QuotaPanel', 'Test notification — threshold alerts will look like this.'));
        noteRow.add_child(test);
        this._body.add_child(noteRow);

        this._body.add_child(new St.Widget({style_class: 'quotapanel-divider', x_expand: true}));

        // Credential detection, from the last status (read-only info).
        this._body.add_child(label('Detected from CLI credentials', 'quotapanel-settings-title'));
        const byId = new Map(this._providers().map(p => [p.id, p]));
        for (const [id, name] of PROVIDER_CATALOG) {
            const p = byId.get(id);
            const row = new St.BoxLayout({x_expand: true, style_class: 'quotapanel-detect-row'});
            const swatch = new St.Bin({style_class: 'quotapanel-legend-dot', y_align: Clutter.ActorAlign.CENTER});
            swatch.set_style(`background-color: ${p?.brandColor ?? '#888888'};`);
            row.add_child(swatch);
            row.add_child(label(name, 'quotapanel-check-label', {y_align: Clutter.ActorAlign.CENTER}));
            let state = 'No data';
            let cls = 'quotapanel-note-dim';
            if (p?.status === 'ok') {
                state = 'Detected ✓';
                cls = 'quotapanel-detect-ok';
            } else if (p?.status === 'authProblem') {
                state = 'Not found';
            } else if (p?.status === 'error') {
                state = 'Error';
                cls = 'quotapanel-error';
            }
            row.add_child(label(state, cls, {x_expand: true, x_align: Clutter.ActorAlign.END}));
            this._body.add_child(row);
        }
    }

    _bumpInterval(delta) {
        const v = Math.max(30, Math.min(1800, this._config.refreshSeconds + delta));
        this._config.data.refreshSeconds = v;
        this._config.save();
        this._ext._restartAutoRefresh();
        this.render();
    }

    _bumpThreshold(index, delta) {
        const list = [...this._config.alertThresholds];
        if (index < 0 || index >= list.length)
            return;
        list[index] = Math.max(5, Math.min(99, list[index] + delta));
        list.sort((a, b) => a - b);
        this._config.data.alertThresholds = list;
        this._config.save();
        this.render();
    }

    // MARK: Refresh

    _refreshNow() {
        if (!this._daemonPath || this._isRefreshing)
            return;
        this._isRefreshing = true;
        this._renderHeader();
        try {
            const proc = Gio.Subprocess.new(
                [this._daemonPath, '--once'],
                Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
            proc.wait_async(null, () => {
                this._isRefreshing = false;
                if (this._onRefreshDone)
                    this._onRefreshDone();
                else
                    this._renderHeader();
            });
        } catch (e) {
            this._isRefreshing = false;
            logError(e, 'QuotaPanel: failed to spawn daemon');
        }
    }
});

export default class QuotaPanelExtension extends Extension {
    enable() {
        this._statusPath = GLib.build_filenamev([configDir(), 'status.json']);
        this._daemonPath = findDaemon();
        this._config = new Config();
        this._notified = null;   // percent state per provider:window for threshold alerts

        this._indicator = new QuotaPanelIndicator(this);
        this._indicator._onRefreshDone = () => this._scheduleReload(50);
        Main.panel.addToStatusArea('quotapanel', this._indicator);

        // Watch the config directory for status.json being (atomically) replaced.
        try {
            const dir = Gio.File.new_for_path(configDir());
            this._monitor = dir.monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, null);
            this._monitor.connect('changed', (_m, file, otherFile) => {
                // The daemon writes atomically (temp file + rename), so the
                // rename event carries the temp name in `file` and the real
                // target in `otherFile` — check both.
                if (file?.get_basename() === 'status.json' || otherFile?.get_basename() === 'status.json')
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

        // Auto-refresh: spawn the daemon on the configured cadence, so the
        // data itself stays fresh without a systemd timer.
        this._restartAutoRefresh();

        this._reload();
    }

    disable() {
        for (const id of ['_reloadId', '_pollId', '_autoId']) {
            if (this[id]) {
                GLib.source_remove(this[id]);
                this[id] = 0;
            }
        }
        if (this._monitor) {
            this._monitor.cancel();
            this._monitor = null;
        }
        if (this._indicator) {
            this._indicator.destroy();
            this._indicator = null;
        }
        this._config = null;
        this._notified = null;
    }

    _restartAutoRefresh() {
        if (this._autoId) {
            GLib.source_remove(this._autoId);
            this._autoId = 0;
        }
        if (!this._daemonPath)
            return;
        this._autoId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, this._config.refreshSeconds, () => {
            this._indicator?._refreshNow();
            return GLib.SOURCE_CONTINUE;
        });
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
            if (ok)
                status = JSON.parse(new TextDecoder().decode(contents));
        } catch {
            // Missing/half-written file: keep the previous render, try again later.
            status = this._lastStatus ?? null;
        }
        if (status) {
            this._checkThresholds(status);
            this._lastStatus = status;
        }
        this._indicator.render(status);
    }

    // Notify when a window's usage crosses a configured threshold upward.
    // The first status after enable only seeds the state (no alert storm).
    _checkThresholds(status) {
        const thresholds = this._config.alertThresholds;
        const current = new Map();
        for (const p of status.providers ?? []) {
            if (p.status !== 'ok')
                continue;
            for (const w of p.windows ?? [])
                current.set(`${p.id}:${w.label}`, {percent: w.percent, provider: p.name, window: w.label});
        }
        if (this._notified !== null && thresholds.length > 0) {
            for (const [key, now] of current) {
                const before = this._notified.get(key);
                if (before === undefined)
                    continue;
                for (const t of thresholds) {
                    if (before < t && now.percent >= t) {
                        Main.notify('QuotaPanel',
                            `${now.provider} — ${now.window} reached ${Math.round(t)}% (now ${formatPercent(now.percent)}%)`);
                        break;
                    }
                }
            }
        }
        this._notified = new Map([...current].map(([k, v]) => [k, v.percent]));
    }
}
