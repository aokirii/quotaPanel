// QuotaPanelTray.cs — Windows tray shell for QuotaPanel.
//
// Counterpart of the GNOME Shell extension: reads the status.json the
// quotapanel-daemon writes (%APPDATA%\quotapanel\status.json), renders a tray
// icon + popup panel (Live / Summary / Heatmap / Settings), spawns the daemon
// on a timer, and raises threshold balloon notifications.
//
// Deliberately a single file with zero NuGet dependencies so it compiles with
// the compiler every Windows ships in-box (C# 5):
//
//   %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe ^
//     /out:QuotaPanelTray.exe /r:System.dll /r:System.Core.dll /r:System.Drawing.dll ^
//     /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll QuotaPanelTray.cs
//
// (install.ps1 runs exactly that.) Keep the code C# 5 compatible: no string
// interpolation, no ?., no expression-bodied members, no nameof.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace QuotaPanel
{
    // ============================================================ entry point

    static class Program
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [STAThread]
        static void Main()
        {
            bool createdNew;
            // One instance is enough; a second launch just exits.
            var mutex = new Mutex(true, "QuotaPanelTraySingleton", out createdNew);
            if (!createdNew) return;

            try { SetProcessDPIAware(); } catch (Exception) { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayContext());
            GC.KeepAlive(mutex);
        }
    }

    // ======================================================= provider catalog

    /// Static mirror of Provider.swift for the providers the daemon supports,
    /// in Engine.supported display order. Used by the Settings page (disabled
    /// providers don't appear in status.json) and as a fallback for colors.
    class ProviderInfo
    {
        public string Id;
        public string Name;
        public string ShortLabel;
        public string ColorHex;

        public ProviderInfo(string id, string name, string shortLabel, string colorHex)
        {
            Id = id; Name = name; ShortLabel = shortLabel; ColorHex = colorHex;
        }
    }

    static class Catalog
    {
        public static readonly ProviderInfo[] Supported = new ProviderInfo[]
        {
            new ProviderInfo("claude",      "Claude Code",  "C",  "#d97757"),
            new ProviderInfo("codex",       "Codex",        "X",  "#10a37f"),
            new ProviderInfo("gemini",      "Gemini",       "G",  "#4285f4"),
            new ProviderInfo("copilot",     "Copilot",      "Co", "#8250df"),
            new ProviderInfo("droid",       "Droid",        "D",  "#cc5933"),
            new ProviderInfo("warp",        "Warp",         "Wa", "#938bb4"),
            new ProviderInfo("amp",         "Amp",          "A",  "#dc2626"),
            new ProviderInfo("augment",     "Augment",      "Au", "#6366f1"),
            new ProviderInfo("kilo",        "Kilo",         "K",  "#f27027"),
            new ProviderInfo("kiro",        "Kiro",         "Ki", "#ff9900"),
            new ProviderInfo("opencode",    "OpenCode",     "O",  "#3b82f6"),
            new ProviderInfo("opencodego",  "OpenCode Go",  "Og", "#3b82f6"),
            new ProviderInfo("antigravity", "Antigravity",  "Ag", "#60ba7e"),
            new ProviderInfo("devin",       "Devin",        "De", "#46b482"),
            new ProviderInfo("qoder",       "Qoder",        "Q",  "#10b981"),
            new ProviderInfo("commandcode", "Command Code", "Cc", "#6b7380"),
            new ProviderInfo("crossmodel",  "CrossModel",   "Cm", "#7c3aed"),
            new ProviderInfo("manus",       "Manus",        "M",  "#34322d"),
            new ProviderInfo("codebuff",    "Codebuff",     "Cb", "#44ff00"),
        };

        public static ProviderInfo Find(string id)
        {
            for (int i = 0; i < Supported.Length; i++)
                if (Supported[i].Id == id) return Supported[i];
            return null;
        }
    }

    // ============================================================ json helpers

    /// Small helpers over JavaScriptSerializer's Dictionary/object[] output.
    static class J
    {
        public static Dictionary<string, object> Dict(object o)
        {
            return o as Dictionary<string, object>;
        }

        public static IEnumerable<object> List(object o)
        {
            var arr = o as object[];
            if (arr != null) return arr;
            var list = o as System.Collections.ArrayList;
            if (list != null) return list.Cast<object>();
            return new object[0];
        }

        public static object Get(Dictionary<string, object> d, string key)
        {
            object v;
            if (d != null && d.TryGetValue(key, out v)) return v;
            return null;
        }

        public static string Str(Dictionary<string, object> d, string key, string fallback)
        {
            var v = Get(d, key) as string;
            return v != null ? v : fallback;
        }

        public static double Num(Dictionary<string, object> d, string key, double fallback)
        {
            var v = Get(d, key);
            if (v == null) return fallback;
            try { return Convert.ToDouble(v, CultureInfo.InvariantCulture); }
            catch (Exception) { return fallback; }
        }

        public static int Int(Dictionary<string, object> d, string key, int fallback)
        {
            return (int)Math.Round(Num(d, key, fallback));
        }
    }

    // ================================================================= models

    class WindowStatus
    {
        public string Label;
        public double Percent;      // percent USED, 0...100
        public DateTime? ResetsAt;  // local time
    }

    class Parts
    {
        public long Input;
        public long Cache;
        public long Output;
        public long Total { get { return Input + Cache + Output; } }
    }

    class ContextStatus
    {
        public string Project;
        public string Detail;
        public long Used;
        public long Limit;
        public double Percent;
        public Parts PartsValue;
    }

    class DailyStat
    {
        public string Day;       // "yyyy-MM-dd"
        public double CostUSD;
        public long Tokens;
    }

    class SummaryBucket
    {
        public string Id;
        public string Label;
        public Parts PartsValue;
    }

    class HeatCell
    {
        public long Tokens;
        public int Level;        // 0...4
    }

    class HourRow
    {
        public string Day;       // "Mon" ... "Sun"
        public List<HeatCell> Cells;
    }

    class Heatmap
    {
        public long TotalTokens;
        public List<List<HeatCell>> DailyGrid;  // week columns × 7 (null cell = future)
        public List<HourRow> HourRows;
    }

    class ProviderStatus
    {
        public string Id;
        public string Name;
        public string ShortLabel;
        public string BrandColor;
        public string Status;      // loading | ok | authProblem | error
        public string Message;
        public string Plan;
        public DateTime? UpdatedAt;
        public List<WindowStatus> Windows;
        // v2 extras (claude/codex only)
        public Parts SessionParts;
        public List<ContextStatus> Contexts;
        public List<DailyStat> Daily;
        public List<SummaryBucket> Summary;
        public Heatmap HeatmapValue;

        public bool HasExtras
        {
            get { return Daily != null || Summary != null || HeatmapValue != null; }
        }

        /// Mirrors UsageSnapshot.sessionWindow on macOS: prefer the 5-hour
        /// session window; fall back to the fullest window so the tray label
        /// is never blank.
        public WindowStatus SessionWindow
        {
            get
            {
                if (Windows == null) return null;
                for (int i = 0; i < Windows.Count; i++)
                {
                    var l = Windows[i].Label.ToLowerInvariant();
                    if (l.StartsWith("session") || l.Contains("5-hour") || l.Contains("5h"))
                        return Windows[i];
                }
                return null;
            }
        }

        public WindowStatus TrayWindow
        {
            get
            {
                var s = SessionWindow;
                if (s != null) return s;
                WindowStatus worst = null;
                if (Windows != null)
                    for (int i = 0; i < Windows.Count; i++)
                        if (worst == null || Windows[i].Percent > worst.Percent) worst = Windows[i];
                return worst;
            }
        }
    }

    class StatusFile
    {
        public int Version;
        public DateTime? GeneratedAt;
        public List<ProviderStatus> Providers;

        public ProviderStatus Find(string id)
        {
            if (Providers == null) return null;
            for (int i = 0; i < Providers.Count; i++)
                if (Providers[i].Id == id) return Providers[i];
            return null;
        }
    }

    // ================================================================ parsing

    static class StatusParser
    {
        public static StatusFile Parse(string json)
        {
            var ser = new JavaScriptSerializer();
            ser.MaxJsonLength = 64 * 1024 * 1024;
            var root = J.Dict(ser.DeserializeObject(json));
            if (root == null) return null;

            var file = new StatusFile();
            file.Version = J.Int(root, "version", 1);
            file.GeneratedAt = ParseDate(J.Str(root, "generatedAt", null));
            file.Providers = new List<ProviderStatus>();
            foreach (var po in J.List(J.Get(root, "providers")))
            {
                var p = ParseProvider(J.Dict(po));
                if (p != null) file.Providers.Add(p);
            }
            return file;
        }

        static ProviderStatus ParseProvider(Dictionary<string, object> d)
        {
            if (d == null) return null;
            var p = new ProviderStatus();
            p.Id = J.Str(d, "id", "");
            p.Name = J.Str(d, "name", p.Id);
            p.ShortLabel = J.Str(d, "shortLabel", "?");
            p.BrandColor = J.Str(d, "brandColor", "#888888");
            p.Status = J.Str(d, "status", "error");
            p.Message = J.Str(d, "message", null);
            p.Plan = J.Str(d, "plan", null);
            p.UpdatedAt = ParseDate(J.Str(d, "updatedAt", null));

            p.Windows = new List<WindowStatus>();
            foreach (var wo in J.List(J.Get(d, "windows")))
            {
                var wd = J.Dict(wo);
                if (wd == null) continue;
                var w = new WindowStatus();
                w.Label = J.Str(wd, "label", "");
                w.Percent = J.Num(wd, "percent", 0);
                w.ResetsAt = ParseDate(J.Str(wd, "resetsAt", null));
                p.Windows.Add(w);
            }

            p.SessionParts = ParseParts(J.Dict(J.Get(d, "sessionParts")));

            var contexts = J.Get(d, "contexts");
            if (contexts != null)
            {
                p.Contexts = new List<ContextStatus>();
                foreach (var co in J.List(contexts))
                {
                    var cd = J.Dict(co);
                    if (cd == null) continue;
                    var c = new ContextStatus();
                    c.Project = J.Str(cd, "project", "");
                    c.Detail = J.Str(cd, "detail", "");
                    c.Used = (long)J.Num(cd, "used", 0);
                    c.Limit = (long)J.Num(cd, "limit", 0);
                    c.Percent = J.Num(cd, "percent", 0);
                    c.PartsValue = ParseParts(J.Dict(J.Get(cd, "parts")));
                    p.Contexts.Add(c);
                }
            }

            var daily = J.Get(d, "daily");
            if (daily != null)
            {
                p.Daily = new List<DailyStat>();
                foreach (var eo in J.List(daily))
                {
                    var ed = J.Dict(eo);
                    if (ed == null) continue;
                    var stat = new DailyStat();
                    stat.Day = J.Str(ed, "day", "");
                    stat.CostUSD = J.Num(ed, "costUSD", 0);
                    stat.Tokens = (long)J.Num(ed, "tokens", 0);
                    p.Daily.Add(stat);
                }
            }

            var summary = J.Get(d, "summary");
            if (summary != null)
            {
                p.Summary = new List<SummaryBucket>();
                foreach (var so in J.List(summary))
                {
                    var sd = J.Dict(so);
                    if (sd == null) continue;
                    var b = new SummaryBucket();
                    b.Id = J.Str(sd, "id", "");
                    b.Label = J.Str(sd, "label", "");
                    b.PartsValue = ParseParts(J.Dict(J.Get(sd, "parts")));
                    p.Summary.Add(b);
                }
            }

            var heat = J.Dict(J.Get(d, "heatmap"));
            if (heat != null)
            {
                var h = new Heatmap();
                h.TotalTokens = (long)J.Num(heat, "totalTokens", 0);
                h.DailyGrid = new List<List<HeatCell>>();
                foreach (var col in J.List(J.Get(heat, "dailyGrid")))
                {
                    var column = new List<HeatCell>();
                    foreach (var cell in J.List(col)) column.Add(ParseHeatCell(J.Dict(cell)));
                    h.DailyGrid.Add(column);
                }
                h.HourRows = new List<HourRow>();
                foreach (var ro in J.List(J.Get(heat, "hourRows")))
                {
                    var rd = J.Dict(ro);
                    if (rd == null) continue;
                    var row = new HourRow();
                    row.Day = J.Str(rd, "day", "");
                    row.Cells = new List<HeatCell>();
                    foreach (var cell in J.List(J.Get(rd, "cells"))) row.Cells.Add(ParseHeatCell(J.Dict(cell)));
                    h.HourRows.Add(row);
                }
                p.HeatmapValue = h;
            }
            return p;
        }

        static Parts ParseParts(Dictionary<string, object> d)
        {
            if (d == null) return null;
            var parts = new Parts();
            parts.Input = (long)J.Num(d, "input", 0);
            parts.Cache = (long)J.Num(d, "cache", 0);
            parts.Output = (long)J.Num(d, "output", 0);
            return parts;
        }

        static HeatCell ParseHeatCell(Dictionary<string, object> d)
        {
            if (d == null) return null;  // future day
            var c = new HeatCell();
            c.Tokens = (long)J.Num(d, "t", 0);
            c.Level = J.Int(d, "l", 0);
            return c;
        }

        public static DateTime? ParseDate(string iso)
        {
            if (string.IsNullOrEmpty(iso)) return null;
            DateTime dt;
            if (DateTime.TryParse(iso, CultureInfo.InvariantCulture,
                                  DateTimeStyles.RoundtripKind, out dt))
                return dt.Kind == DateTimeKind.Utc ? dt.ToLocalTime() : dt;
            return null;
        }
    }

    // ================================================================= config

    /// config.json is shared with the daemon (UserConfig.swift). Loaded and
    /// saved as a raw dictionary so keys this shell doesn't know survive a
    /// round-trip. `selectedProvider` is tray-only state; the daemon ignores
    /// unknown keys.
    class Config
    {
        public List<string> EnabledProviders;   // null = all supported
        public int RefreshSeconds = 120;
        public List<double> AlertThresholds = new List<double> { 80, 95 };
        public string SelectedProvider = "claude";

        Dictionary<string, object> raw = new Dictionary<string, object>();

        public static string Dir
        {
            get
            {
                var appData = Environment.GetEnvironmentVariable("APPDATA");
                if (string.IsNullOrEmpty(appData))
                    appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
                return Path.Combine(appData, "quotapanel");
            }
        }

        public static string ConfigPath { get { return Path.Combine(Dir, "config.json"); } }
        public static string StatusPath { get { return Path.Combine(Dir, "status.json"); } }

        public static Config Load()
        {
            var c = new Config();
            try
            {
                if (File.Exists(ConfigPath))
                {
                    var ser = new JavaScriptSerializer();
                    var d = J.Dict(ser.DeserializeObject(File.ReadAllText(ConfigPath)));
                    if (d != null)
                    {
                        c.raw = d;
                        var enabled = J.Get(d, "enabledProviders");
                        if (enabled != null)
                            c.EnabledProviders = J.List(enabled).Select(o => Convert.ToString(o)).ToList();
                        c.RefreshSeconds = Math.Max(30, J.Int(d, "refreshSeconds", 120));
                        var thresholds = J.Get(d, "alertThresholds");
                        if (thresholds != null)
                            c.AlertThresholds = J.List(thresholds)
                                .Select(o => Convert.ToDouble(o, CultureInfo.InvariantCulture)).ToList();
                        c.SelectedProvider = J.Str(d, "selectedProvider", c.SelectedProvider);
                    }
                }
            }
            catch (Exception) { }
            return c;
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Dir);
                if (EnabledProviders != null) raw["enabledProviders"] = EnabledProviders;
                else raw.Remove("enabledProviders");
                raw["refreshSeconds"] = RefreshSeconds;
                raw["alertThresholds"] = AlertThresholds;
                raw["selectedProvider"] = SelectedProvider;
                var ser = new JavaScriptSerializer();
                File.WriteAllText(ConfigPath, ser.Serialize(raw), new UTF8Encoding(false));
            }
            catch (Exception) { }
        }

        public bool IsEnabled(string id)
        {
            if (EnabledProviders == null || EnabledProviders.Count == 0) return true;
            return EnabledProviders.Contains(id);
        }
    }

    // ================================================================== theme

    static class Theme
    {
        public static readonly Color Background = ColorTranslator.FromHtml("#1e1e23");
        public static readonly Color Card = ColorTranslator.FromHtml("#2a2a31");
        public static readonly Color CardHover = ColorTranslator.FromHtml("#34343d");
        public static readonly Color Track = ColorTranslator.FromHtml("#3a3a44");
        public static readonly Color Text = ColorTranslator.FromHtml("#e8e8ec");
        public static readonly Color SubText = ColorTranslator.FromHtml("#9a9aa5");
        public static readonly Color Accent = ColorTranslator.FromHtml("#8ab4f8");
        public static readonly Color Green = ColorTranslator.FromHtml("#33d17a");
        public static readonly Color Yellow = ColorTranslator.FromHtml("#f6d32d");
        public static readonly Color Orange = ColorTranslator.FromHtml("#ff7800");
        public static readonly Color Red = ColorTranslator.FromHtml("#e01b24");
        // token composition (input / cache / output), matching the other shells
        public static readonly Color PartInput = ColorTranslator.FromHtml("#8ab4f8");
        public static readonly Color PartCache = ColorTranslator.FromHtml("#b48af8");
        public static readonly Color PartOutput = ColorTranslator.FromHtml("#5fd0a5");
        // GitHub-style heat ramp, level 0...4
        public static readonly Color[] Heat = new Color[]
        {
            ColorTranslator.FromHtml("#2a2a31"),
            ColorTranslator.FromHtml("#0e4429"),
            ColorTranslator.FromHtml("#006d32"),
            ColorTranslator.FromHtml("#26a641"),
            ColorTranslator.FromHtml("#39d353"),
        };

        public static Color UsageColor(double percent)
        {
            if (percent >= 95) return Red;
            if (percent >= 80) return Orange;
            if (percent >= 60) return Yellow;
            return Green;
        }

        public static Color Brand(string hex)
        {
            try { return ColorTranslator.FromHtml(hex); }
            catch (Exception) { return Color.Gray; }
        }

        public static string Percent(double p)
        {
            var rounded1 = Math.Round(p, 1);
            if (Math.Abs(rounded1 - Math.Round(p)) >= 0.05)
                return rounded1.ToString("0.0", CultureInfo.InvariantCulture) + "%";
            return Math.Round(p).ToString(CultureInfo.InvariantCulture) + "%";
        }

        public static string Tokens(long t)
        {
            if (t >= 1000000000) return (t / 1e9).ToString("0.0", CultureInfo.InvariantCulture) + "B";
            if (t >= 1000000) return (t / 1e6).ToString("0.0", CultureInfo.InvariantCulture) + "M";
            if (t >= 1000) return (t / 1e3).ToString("0.0", CultureInfo.InvariantCulture) + "k";
            return t.ToString(CultureInfo.InvariantCulture);
        }

        public static string Reset(DateTime? at)
        {
            if (at == null) return null;
            var local = at.Value;
            if (local.Date == DateTime.Now.Date)
                return "resets " + local.ToString("HH:mm", CultureInfo.InvariantCulture);
            return "resets " + local.ToString("ddd HH:mm", CultureInfo.InvariantCulture);
        }

        public static string Ago(DateTime? at)
        {
            if (at == null) return "";
            var s = (DateTime.Now - at.Value).TotalSeconds;
            if (s < 5) return "just now";
            if (s < 90) return ((int)s) + "s ago";
            if (s < 90 * 60) return ((int)(s / 60)) + "m ago";
            return ((int)(s / 3600)) + "h ago";
        }
    }

    // =========================================================== tray context

    class TrayContext : ApplicationContext
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        static extern bool DestroyIcon(IntPtr handle);

        NotifyIcon tray;
        PanelForm panel;
        Form syncForm;   // hidden; marshals FileSystemWatcher events to the UI thread
        System.Windows.Forms.Timer refreshTimer;
        System.Windows.Forms.Timer reloadDebounce;
        FileSystemWatcher watcher;
        Config config;
        StatusFile status;
        Icon currentIcon;
        // fired alert keys: "provider|window|threshold"
        HashSet<string> firedAlerts = new HashSet<string>();
        Dictionary<string, double> lastPercents = new Dictionary<string, double>();

        public TrayContext()
        {
            config = Config.Load();

            tray = new NotifyIcon();
            tray.Visible = true;
            tray.Text = "QuotaPanel";
            tray.MouseUp += OnTrayClick;

            var menu = new ContextMenuStrip();
            menu.Items.Add("Open QuotaPanel", null, delegate { ShowPanel(); });
            menu.Items.Add("Refresh now", null, delegate { SpawnDaemon(); });
            var autostart = new ToolStripMenuItem("Start with Windows");
            autostart.Checked = IsAutostartEnabled();
            autostart.Click += delegate
            {
                SetAutostart(!IsAutostartEnabled());
                autostart.Checked = IsAutostartEnabled();
            };
            menu.Items.Add(autostart);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quit", null, delegate { ExitApp(); });
            tray.ContextMenuStrip = menu;

            RenderTrayIcon();

            // Hidden form whose handle lives on the UI thread; the watcher
            // marshals its events through it.
            syncForm = new Form();
            syncForm.ShowInTaskbar = false;
            syncForm.WindowState = FormWindowState.Minimized;
            syncForm.CreateControl();
            var forceHandle = syncForm.Handle;
            GC.KeepAlive(forceHandle);

            // Reload when the daemon rewrites status.json (atomic temp+rename),
            // debounced since the rename fires several watcher events.
            try
            {
                Directory.CreateDirectory(Config.Dir);
                watcher = new FileSystemWatcher(Config.Dir);
                watcher.Filter = "*.json";
                watcher.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName;
                watcher.SynchronizingObject = syncForm;
                FileSystemEventHandler handler = delegate(object s, FileSystemEventArgs e)
                {
                    if (e.Name != null && e.Name.ToLowerInvariant() == "status.json") QueueReload();
                };
                watcher.Changed += handler;
                watcher.Created += handler;
                watcher.Renamed += delegate(object s, RenamedEventArgs e)
                {
                    if (e.Name != null && e.Name.ToLowerInvariant() == "status.json") QueueReload();
                };
                watcher.EnableRaisingEvents = true;
            }
            catch (Exception) { }

            reloadDebounce = new System.Windows.Forms.Timer();
            reloadDebounce.Interval = 300;
            reloadDebounce.Tick += delegate
            {
                reloadDebounce.Stop();
                LoadStatus();
            };

            refreshTimer = new System.Windows.Forms.Timer();
            refreshTimer.Interval = Math.Max(30, config.RefreshSeconds) * 1000;
            refreshTimer.Tick += delegate { SpawnDaemon(); };
            refreshTimer.Start();

            LoadStatus();
            SpawnDaemon();
        }

        // --- panel -----------------------------------------------------------

        void OnTrayClick(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) TogglePanel();
        }

        void TogglePanel()
        {
            if (panel != null && panel.Visible) { panel.Hide(); return; }
            ShowPanel();
        }

        void ShowPanel()
        {
            if (panel == null || panel.IsDisposed)
            {
                panel = new PanelForm(this, config);
                panel.SetStatus(status);
            }
            panel.ShowNearTray();
        }

        // --- data ------------------------------------------------------------

        void QueueReload()
        {
            // Already on the UI thread (watcher.SynchronizingObject = syncForm).
            reloadDebounce.Stop();
            reloadDebounce.Start();
        }

        public void LoadStatus()
        {
            try
            {
                if (!File.Exists(Config.StatusPath)) return;
                var parsed = StatusParser.Parse(File.ReadAllText(Config.StatusPath));
                if (parsed == null) return;
                status = parsed;
            }
            catch (Exception) { return; }

            CheckAlerts();
            RenderTrayIcon();
            if (panel != null && !panel.IsDisposed) panel.SetStatus(status);
        }

        public ProviderStatus SelectedProvider()
        {
            if (status == null) return null;
            var p = status.Find(config.SelectedProvider);
            if (p != null && config.IsEnabled(p.Id)) return p;
            if (status.Providers != null)
                for (int i = 0; i < status.Providers.Count; i++)
                    if (config.IsEnabled(status.Providers[i].Id)) return status.Providers[i];
            return null;
        }

        // --- daemon ----------------------------------------------------------

        public static string FindDaemon()
        {
            var exeDir = Path.GetDirectoryName(Application.ExecutablePath);
            var candidates = new List<string>();
            if (exeDir != null)
            {
                candidates.Add(Path.Combine(exeDir, "quotapanel-daemon.exe"));
                candidates.Add(Path.Combine(exeDir, "bin", "quotapanel-daemon.exe"));
            }
            var localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA");
            if (!string.IsNullOrEmpty(localAppData))
                candidates.Add(Path.Combine(localAppData, "QuotaPanel", "quotapanel-daemon.exe"));
            foreach (var c in candidates)
                if (File.Exists(c)) return c;

            var pathVar = Environment.GetEnvironmentVariable("Path");
            if (pathVar != null)
                foreach (var dir in pathVar.Split(';'))
                {
                    if (dir.Trim().Length == 0) continue;
                    try
                    {
                        var c = Path.Combine(dir.Trim(), "quotapanel-daemon.exe");
                        if (File.Exists(c)) return c;
                    }
                    catch (Exception) { }
                }
            return null;
        }

        public void SpawnDaemon()
        {
            var daemon = FindDaemon();
            if (daemon == null) return;
            try
            {
                var psi = new ProcessStartInfo(daemon, "--once");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                Process.Start(psi);
                // The FileSystemWatcher picks up the rewritten status.json.
            }
            catch (Exception) { }
        }

        public void ApplyConfig(Config c)
        {
            config = c;
            config.Save();
            refreshTimer.Interval = Math.Max(30, config.RefreshSeconds) * 1000;
            RenderTrayIcon();
            SpawnDaemon();
        }

        public Config CurrentConfig { get { return config; } }

        // --- tray icon --------------------------------------------------------

        public void RenderTrayIcon()
        {
            var p = SelectedProvider();
            var label = p != null ? p.ShortLabel : "Q";
            var brand = p != null ? Theme.Brand(p.BrandColor) : Color.Gray;
            var window = p != null ? p.TrayWindow : null;
            double percent = window != null ? window.Percent : 0;
            bool hasData = window != null;

            var size = 32;
            using (var bmp = new Bitmap(size, size))
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                // letter disc
                using (var brush = new SolidBrush(brand))
                    g.FillEllipse(brush, 1, 0, size - 2, size - 8);
                using (var f = new Font("Segoe UI", 13, FontStyle.Bold, GraphicsUnit.Pixel))
                {
                    var text = label.Length > 2 ? label.Substring(0, 2) : label;
                    var sz = g.MeasureString(text, f);
                    g.DrawString(text, f, Brushes.White,
                        (size - sz.Width) / 2f, (size - 8 - sz.Height) / 2f + 1);
                }
                // usage bar
                var barY = size - 5;
                using (var track = new SolidBrush(Theme.Track))
                    g.FillRectangle(track, 2, barY, size - 4, 4);
                if (hasData)
                {
                    var w = (int)Math.Round((size - 4) * Math.Min(100, Math.Max(0, percent)) / 100.0);
                    if (w > 0)
                        using (var fill = new SolidBrush(Theme.UsageColor(percent)))
                            g.FillRectangle(fill, 2, barY, w, 4);
                }

                var handle = bmp.GetHicon();
                var icon = Icon.FromHandle(handle);
                tray.Icon = (Icon)icon.Clone();
                icon.Dispose();
                DestroyIcon(handle);
                if (currentIcon != null) currentIcon.Dispose();
                currentIcon = tray.Icon;
            }

            var tip = "QuotaPanel";
            if (p != null)
            {
                tip = p.Name;
                if (window != null)
                {
                    tip += " — " + window.Label + " " + Theme.Percent(window.Percent);
                    var reset = Theme.Reset(window.ResetsAt);
                    if (reset != null) tip += " · " + reset;
                }
                else if (p.Message != null) tip += " — " + p.Message;
            }
            tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
        }

        // --- alerts -----------------------------------------------------------

        void CheckAlerts()
        {
            if (status == null || status.Providers == null) return;
            var thresholds = config.AlertThresholds;
            foreach (var p in status.Providers)
            {
                if (!config.IsEnabled(p.Id) || p.Windows == null) continue;
                foreach (var w in p.Windows)
                {
                    var stateKey = p.Id + "|" + w.Label;
                    double last;
                    var hadLast = lastPercents.TryGetValue(stateKey, out last);
                    lastPercents[stateKey] = w.Percent;

                    // window reset: a large drop re-arms every threshold
                    if (hadLast && last - w.Percent >= 25)
                    {
                        firedAlerts.RemoveWhere(k => k.StartsWith(stateKey + "|"));
                        tray.ShowBalloonTip(4000, p.Name,
                            w.Label + " limit reset (" + Theme.Percent(w.Percent) + ")",
                            ToolTipIcon.Info);
                        continue;
                    }
                    if (thresholds == null) continue;
                    foreach (var t in thresholds)
                    {
                        var key = stateKey + "|" + t.ToString(CultureInfo.InvariantCulture);
                        if (w.Percent >= t && !firedAlerts.Contains(key))
                        {
                            firedAlerts.Add(key);
                            // Only notify on an actual crossing, not on startup
                            // when usage is already past the threshold.
                            if (hadLast && last < t)
                                tray.ShowBalloonTip(4000, p.Name,
                                    w.Label + " reached " + Theme.Percent(w.Percent),
                                    ToolTipIcon.Warning);
                        }
                        else if (w.Percent < t && firedAlerts.Contains(key))
                        {
                            firedAlerts.Remove(key);
                        }
                    }
                }
            }
        }

        // --- autostart ---------------------------------------------------------

        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        static bool IsAutostartEnabled()
        {
            try
            {
                using (var key = Registry.CurrentUser.OpenSubKey(RunKey))
                    return key != null && key.GetValue("QuotaPanel") != null;
            }
            catch (Exception) { return false; }
        }

        static void SetAutostart(bool enable)
        {
            try
            {
                using (var key = Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (key == null) return;
                    if (enable) key.SetValue("QuotaPanel", "\"" + Application.ExecutablePath + "\"");
                    else key.DeleteValue("QuotaPanel", false);
                }
            }
            catch (Exception) { }
        }

        void ExitApp()
        {
            tray.Visible = false;
            tray.Dispose();
            if (panel != null && !panel.IsDisposed) panel.Dispose();
            Application.Exit();
        }
    }

    // ============================================================= panel form

    class PanelForm : Form
    {
        readonly TrayContext owner;
        Config config;
        StatusFile status;
        string view = "live";           // live | summary | heatmap | settings

        StripControl strip;
        HeaderControl header;
        TabsControl tabs;
        Panel contentHost;
        ContentCanvas canvas;
        SettingsPanel settings;
        System.Windows.Forms.Timer agoTimer;

        public PanelForm(TrayContext owner, Config config)
        {
            this.owner = owner;
            this.config = config;

            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            BackColor = Theme.Background;
            Font = new Font("Segoe UI", 9f);
            var scale = DeviceDpi / 96f;
            Size = new Size((int)(380 * scale), (int)(600 * scale));
            TopMost = true;

            strip = new StripControl(this);
            strip.Dock = DockStyle.Top;
            strip.Height = S(64);

            header = new HeaderControl(this);
            header.Dock = DockStyle.Top;
            header.Height = S(44);

            tabs = new TabsControl(this);
            tabs.Dock = DockStyle.Top;
            tabs.Height = S(34);

            contentHost = new Panel();
            contentHost.Dock = DockStyle.Fill;
            contentHost.AutoScroll = true;
            contentHost.BackColor = Theme.Background;

            canvas = new ContentCanvas(this);
            canvas.Width = ClientSize.Width - S(18);
            contentHost.Controls.Add(canvas);

            settings = new SettingsPanel(this);
            settings.Visible = false;
            settings.Dock = DockStyle.Fill;

            Controls.Add(contentHost);
            Controls.Add(settings);
            Controls.Add(tabs);
            Controls.Add(header);
            Controls.Add(strip);

            agoTimer = new System.Windows.Forms.Timer();
            agoTimer.Interval = 5000;
            agoTimer.Tick += delegate { header.Invalidate(); };
        }

        public int S(int px) { return (int)Math.Round(px * DeviceDpi / 96.0); }

        public Config Cfg { get { return config; } }
        public StatusFile Status { get { return status; } }
        public string View { get { return view; } }

        public ProviderStatus Current
        {
            get
            {
                if (status == null) return null;
                var p = status.Find(config.SelectedProvider);
                if (p != null && config.IsEnabled(p.Id)) return p;
                if (status.Providers != null)
                    foreach (var q in status.Providers)
                        if (config.IsEnabled(q.Id)) return q;
                return null;
            }
        }

        public void SetStatus(StatusFile s)
        {
            status = s;
            RefreshAll();
        }

        public void SelectProvider(string id)
        {
            config.SelectedProvider = id;
            config.Save();
            owner.RenderTrayIcon();
            if (view == "settings") view = "live";
            var p = Current;
            if (p != null && !p.HasExtras && view != "live") view = "live";
            RefreshAll();
        }

        public void SelectView(string v)
        {
            view = v;
            settings.Visible = v == "settings";
            contentHost.Visible = v != "settings";
            if (v == "settings") settings.LoadFrom(config);
            RefreshAll();
        }

        public void RequestRefresh() { owner.SpawnDaemon(); }

        public void ApplySettings(Config c)
        {
            config = c;
            owner.ApplyConfig(c);
            SelectView("live");
        }

        public void RefreshAll()
        {
            strip.Invalidate();
            header.Invalidate();
            tabs.Invalidate();
            if (view != "settings")
            {
                canvas.Rebuild();
                canvas.Invalidate();
            }
        }

        public void ShowNearTray()
        {
            var area = Screen.PrimaryScreen.WorkingArea;
            Location = new Point(area.Right - Width - S(8), area.Bottom - Height - S(8));
            Show();
            Activate();
            agoTimer.Start();
            RefreshAll();
        }

        protected override void OnDeactivate(EventArgs e)
        {
            base.OnDeactivate(e);
            agoTimer.Stop();
            Hide();
        }

        protected override void OnMouseWheel(MouseEventArgs e)
        {
            base.OnMouseWheel(e);
            // Over the strip: scroll it horizontally; elsewhere: scroll content.
            var stripPt = strip.PointToClient(Cursor.Position);
            if (strip.ClientRectangle.Contains(stripPt))
            {
                strip.ScrollBy(-Math.Sign(e.Delta) * S(40));
                return;
            }
            if (view == "settings") return;
            if (!contentHost.VerticalScroll.Visible) return;
            int v = contentHost.VerticalScroll.Value - Math.Sign(e.Delta) * S(60);
            v = Math.Max(contentHost.VerticalScroll.Minimum,
                Math.Min(contentHost.VerticalScroll.Maximum, v));
            contentHost.VerticalScroll.Value = v;
            contentHost.PerformLayout();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            using (var pen = new Pen(Theme.Track))
                e.Graphics.DrawRectangle(pen, 0, 0, Width - 1, Height - 1);
        }
    }

    // ============================================================ base canvas

    class DoubleBufferedControl : Control
    {
        public DoubleBufferedControl()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            // Keep focus on the form so PanelForm.OnMouseWheel drives scrolling.
            SetStyle(ControlStyles.Selectable, false);
        }
    }

    // ========================================================= provider strip

    class StripControl : DoubleBufferedControl
    {
        readonly PanelForm form;
        int scrollX;
        List<KeyValuePair<Rectangle, string>> hits = new List<KeyValuePair<Rectangle, string>>();

        public StripControl(PanelForm form)
        {
            this.form = form;
            BackColor = Theme.Background;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            hits.Clear();

            var status = form.Status;
            if (status == null || status.Providers == null)
            {
                TextRenderer.DrawText(g, "Waiting for status.json…", Font,
                    new Point(form.S(12), form.S(24)), Theme.SubText);
                return;
            }

            int chip = form.S(44);
            int gap = form.S(8);
            int x = form.S(12) - scrollX;
            int y = form.S(8);
            var selected = form.Current;

            foreach (var p in status.Providers)
            {
                if (!form.Cfg.IsEnabled(p.Id)) continue;
                var rect = new Rectangle(x, y, chip, chip + form.S(6));
                hits.Add(new KeyValuePair<Rectangle, string>(rect, p.Id));

                var isSelected = selected != null && selected.Id == p.Id;
                if (isSelected)
                    using (var bg = new SolidBrush(Theme.Card))
                        g.FillRectangle(bg, new Rectangle(x - form.S(3), y - form.S(3),
                            chip + form.S(6), chip + form.S(12)));

                // letter disc
                var brand = Theme.Brand(p.BrandColor);
                using (var brush = new SolidBrush(brand))
                    g.FillEllipse(brush, x, y, chip - form.S(8), chip - form.S(8));
                using (var f = new Font("Segoe UI", 12f, FontStyle.Bold))
                {
                    var text = p.ShortLabel;
                    var sz = g.MeasureString(text, f);
                    g.DrawString(text, f, Brushes.White,
                        x + (chip - form.S(8) - sz.Width) / 2f,
                        y + (chip - form.S(8) - sz.Height) / 2f);
                }
                // status dot for problems
                if (p.Status == "authProblem" || p.Status == "error")
                    using (var dot = new SolidBrush(p.Status == "authProblem" ? Theme.Orange : Theme.Red))
                        g.FillEllipse(dot, x + chip - form.S(14), y, form.S(9), form.S(9));

                // 5h-session mini bar
                var barY = y + chip - form.S(2);
                using (var track = new SolidBrush(Theme.Track))
                    g.FillRectangle(track, x, barY, chip - form.S(8), form.S(3));
                var window = p.TrayWindow;
                if (window != null)
                {
                    var w = (int)Math.Round((chip - form.S(8)) * Math.Min(100, Math.Max(0, window.Percent)) / 100.0);
                    if (w > 0)
                        using (var fill = new SolidBrush(Theme.UsageColor(window.Percent)))
                            g.FillRectangle(fill, x, barY, w, form.S(3));
                }
                x += chip + gap;
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            foreach (var h in hits)
                if (h.Key.Contains(e.Location)) { form.SelectProvider(h.Value); return; }
        }

        public void ScrollBy(int delta)
        {
            int total = hits.Count * form.S(52) + form.S(24);
            int max = Math.Max(0, total - Width);
            scrollX = Math.Max(0, Math.Min(max, scrollX + delta));
            Invalidate();
        }
    }

    // ================================================================= header

    class HeaderControl : DoubleBufferedControl
    {
        readonly PanelForm form;
        Rectangle refreshRect;
        Rectangle gearRect;

        public HeaderControl(PanelForm form)
        {
            this.form = form;
            BackColor = Theme.Background;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var p = form.Current;
            int x = form.S(12);

            if (p != null)
            {
                // status dot
                Color dotColor = Theme.Green;
                if (p.Status == "authProblem") dotColor = Theme.Orange;
                else if (p.Status == "error") dotColor = Theme.Red;
                else if (p.Status == "loading") dotColor = Theme.SubText;
                using (var dot = new SolidBrush(dotColor))
                    g.FillEllipse(dot, x, Height / 2 - form.S(4), form.S(8), form.S(8));
                x += form.S(14);

                using (var f = new Font("Segoe UI", 10.5f, FontStyle.Bold))
                {
                    TextRenderer.DrawText(g, p.Name, f, new Point(x, Height / 2 - form.S(10)), Theme.Text);
                    x += TextRenderer.MeasureText(p.Name, f).Width + form.S(6);
                }
                var sub = "";
                if (!string.IsNullOrEmpty(p.Plan)) sub = p.Plan;
                var ago = Theme.Ago(p.UpdatedAt);
                if (ago.Length > 0) sub = sub.Length > 0 ? sub + " · " + ago : ago;
                if (sub.Length > 0)
                    TextRenderer.DrawText(g, sub, Font, new Point(x, Height / 2 - form.S(8)), Theme.SubText);
            }
            else
            {
                TextRenderer.DrawText(g, "No data yet", Font, new Point(x, Height / 2 - form.S(8)), Theme.SubText);
            }

            // right-side buttons: ⟳ and ⚙ (drawn as text for portability)
            using (var f = new Font("Segoe UI", 12f))
            {
                gearRect = new Rectangle(Width - form.S(34), Height / 2 - form.S(12), form.S(24), form.S(24));
                refreshRect = new Rectangle(Width - form.S(62), Height / 2 - form.S(12), form.S(24), form.S(24));
                TextRenderer.DrawText(g, "↻", f, refreshRect, Theme.SubText,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                TextRenderer.DrawText(g, "⚙", f, gearRect, Theme.SubText,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (refreshRect.Contains(e.Location)) form.RequestRefresh();
            else if (gearRect.Contains(e.Location)) form.SelectView("settings");
        }
    }

    // =================================================================== tabs

    class TabsControl : DoubleBufferedControl
    {
        readonly PanelForm form;
        List<KeyValuePair<Rectangle, string>> hits = new List<KeyValuePair<Rectangle, string>>();

        public TabsControl(PanelForm form)
        {
            this.form = form;
            BackColor = Theme.Background;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            hits.Clear();
            var p = form.Current;
            if (p == null || !p.HasExtras)
            {
                Height = form.S(4);
                return;
            }
            Height = form.S(34);

            string[] names = { "live", "summary", "heatmap" };
            string[] labels = { "Live", "Summary", "Heatmap" };
            int x = form.S(12);
            for (int i = 0; i < names.Length; i++)
            {
                using (var f = new Font("Segoe UI", 9f, form.View == names[i] ? FontStyle.Bold : FontStyle.Regular))
                {
                    var w = TextRenderer.MeasureText(labels[i], f).Width + form.S(18);
                    var rect = new Rectangle(x, form.S(3), w, form.S(26));
                    hits.Add(new KeyValuePair<Rectangle, string>(rect, names[i]));
                    if (form.View == names[i])
                        using (var bg = new SolidBrush(Theme.Card))
                            g.FillRectangle(bg, rect);
                    TextRenderer.DrawText(g, labels[i], f, rect,
                        form.View == names[i] ? Theme.Text : Theme.SubText,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                    x += w + form.S(6);
                }
            }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            foreach (var h in hits)
                if (h.Key.Contains(e.Location)) { form.SelectView(h.Value); return; }
        }
    }

    // ========================================================= content canvas

    /// Paints the active view (Live / Summary / Heatmap) into a tall control
    /// hosted in an AutoScroll panel. Layout runs in Rebuild() so the height
    /// is known before painting.
    class ContentCanvas : DoubleBufferedControl
    {
        readonly PanelForm form;
        int contentHeight = 100;

        public ContentCanvas(PanelForm form)
        {
            this.form = form;
            BackColor = Theme.Background;
        }

        public void Rebuild()
        {
            using (var g = CreateGraphics())
                contentHeight = Paint_(g, true);
            Height = Math.Max(contentHeight, form.S(80));
            Width = Parent != null ? Parent.ClientSize.Width - form.S(4) : Width;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Paint_(e.Graphics, false);
        }

        // Draws (or measures when measureOnly) and returns the total height.
        int Paint_(Graphics g, bool measureOnly)
        {
            var p = form.Current;
            int x = form.S(12);
            int y = form.S(8);
            int w = Width - form.S(24);

            if (p == null)
            {
                if (!measureOnly)
                    TextRenderer.DrawText(g, "No data yet — press ↻ or wait for the daemon.",
                        Font, new Point(x, y), Theme.SubText);
                return y + form.S(30);
            }

            if (p.Status == "authProblem" || p.Status == "error")
            {
                var msg = p.Message != null ? p.Message : p.Status;
                var rect = new Rectangle(x, y, w, form.S(40));
                if (!measureOnly)
                {
                    using (var bg = new SolidBrush(Theme.Card)) g.FillRectangle(bg, rect);
                    TextRenderer.DrawText(g, msg, Font, Rectangle.Inflate(rect, -form.S(8), 0),
                        p.Status == "authProblem" ? Theme.Orange : Theme.Red,
                        TextFormatFlags.Left | TextFormatFlags.VerticalCenter |
                        TextFormatFlags.WordBreak);
                }
                y += form.S(48);
            }

            if (form.View == "summary" && p.Summary != null) return PaintSummary(g, p, x, y, w, measureOnly);
            if (form.View == "heatmap" && p.HeatmapValue != null) return PaintHeatmap(g, p, x, y, w, measureOnly);
            return PaintLive(g, p, x, y, w, measureOnly);
        }

        // ---- live -------------------------------------------------------------

        int PaintLive(Graphics g, ProviderStatus p, int x, int y, int w, bool measureOnly)
        {
            if (p.Windows != null && p.Windows.Count > 0)
            {
                foreach (var win in p.Windows)
                {
                    y = PaintBarRow(g, x, y, w, win.Label, Theme.Percent(win.Percent),
                        Theme.Reset(win.ResetsAt), win.Percent,
                        IsSessionWindow(win, p) ? p.SessionParts : null, measureOnly);
                }
            }
            else if (p.Status == "ok")
            {
                if (!measureOnly)
                    TextRenderer.DrawText(g, "No rate windows reported.", Font, new Point(x, y), Theme.SubText);
                y += form.S(24);
            }

            if (p.Contexts != null && p.Contexts.Count > 0)
            {
                y += form.S(6);
                y = PaintSectionTitle(g, x, y, "CONTEXT", measureOnly);
                foreach (var c in p.Contexts)
                {
                    var label = c.Project.Length > 0 ? c.Project : "session";
                    if (c.Detail.Length > 0) label += " — " + c.Detail;
                    var detail = Theme.Tokens(c.Used) + " / " + Theme.Tokens(c.Limit);
                    y = PaintBarRow(g, x, y, w, label, Theme.Percent(c.Percent), detail,
                        c.Percent, c.PartsValue, measureOnly);
                }
            }

            if (p.Daily != null && p.Daily.Count > 0)
            {
                y += form.S(6);
                var isCost = p.Id == "claude";
                y = PaintSectionTitle(g, x, y, isCost ? "COST — LAST 14 DAYS" : "TOKENS — LAST 14 DAYS", measureOnly);
                y = PaintChart(g, p, x, y, w, isCost, measureOnly);
            }
            return y + form.S(12);
        }

        bool IsSessionWindow(WindowStatus w, ProviderStatus p)
        {
            var s = p.SessionWindow;
            return s != null && ReferenceEquals(s, w);
        }

        int PaintSectionTitle(Graphics g, int x, int y, string title, bool measureOnly)
        {
            if (!measureOnly)
                using (var f = new Font("Segoe UI", 7.5f, FontStyle.Bold))
                    TextRenderer.DrawText(g, title, f, new Point(x, y), Theme.SubText);
            return y + form.S(18);
        }

        /// A labelled usage bar; when parts is non-null the fill is split into
        /// input/cache/output segments (scaled to the used fraction).
        int PaintBarRow(Graphics g, int x, int y, int w, string label, string percentText,
                        string rightText, double percent, Parts parts, bool measureOnly)
        {
            if (!measureOnly)
            {
                TextRenderer.DrawText(g, label, Font, new Point(x, y), Theme.Text,
                    TextFormatFlags.EndEllipsis);
                using (var f = new Font("Segoe UI", 9f, FontStyle.Bold))
                {
                    var pw = TextRenderer.MeasureText(percentText, f).Width;
                    TextRenderer.DrawText(g, percentText, f, new Point(x + w - pw, y), Theme.Text);
                    if (rightText != null)
                    {
                        var rw = TextRenderer.MeasureText(rightText, Font).Width;
                        TextRenderer.DrawText(g, rightText, Font,
                            new Point(x + w - pw - rw - form.S(8), y), Theme.SubText);
                    }
                }
            }
            y += form.S(20);

            var barRect = new Rectangle(x, y, w, form.S(8));
            if (!measureOnly)
            {
                using (var track = new SolidBrush(Theme.Track)) FillRounded(g, track, barRect, form.S(4));
                var used = Math.Min(100, Math.Max(0, percent)) / 100.0;
                var usedW = (int)Math.Round(w * used);
                if (usedW > 0)
                {
                    if (parts != null && parts.Total > 0)
                    {
                        // input / cache / output segments within the used width
                        long total = parts.Total;
                        int xi = barRect.X;
                        int wi = (int)Math.Round(usedW * (double)parts.Input / total);
                        int wc = (int)Math.Round(usedW * (double)parts.Cache / total);
                        int wo = usedW - wi - wc;
                        if (wi > 0) using (var b = new SolidBrush(Theme.PartInput)) g.FillRectangle(b, xi, barRect.Y, wi, barRect.Height);
                        xi += wi;
                        if (wc > 0) using (var b = new SolidBrush(Theme.PartCache)) g.FillRectangle(b, xi, barRect.Y, wc, barRect.Height);
                        xi += wc;
                        if (wo > 0) using (var b = new SolidBrush(Theme.PartOutput)) g.FillRectangle(b, xi, barRect.Y, wo, barRect.Height);
                    }
                    else
                    {
                        using (var fill = new SolidBrush(Theme.UsageColor(percent)))
                            FillRounded(g, fill, new Rectangle(barRect.X, barRect.Y, usedW, barRect.Height), form.S(4));
                    }
                }
            }
            return y + form.S(18);
        }

        int PaintChart(Graphics g, ProviderStatus p, int x, int y, int w, bool isCost, bool measureOnly)
        {
            var days = p.Daily.Count > 14 ? p.Daily.Skip(p.Daily.Count - 14).ToList() : p.Daily;
            int chartH = form.S(70);
            if (!measureOnly && days.Count > 0)
            {
                double max = 0;
                foreach (var d in days) max = Math.Max(max, isCost ? d.CostUSD : d.Tokens);
                if (max <= 0) max = 1;
                int gap = form.S(3);
                int bw = Math.Max(form.S(4), (w - gap * (days.Count - 1)) / days.Count);
                int xi = x;
                var today = DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                foreach (var d in days)
                {
                    var v = isCost ? d.CostUSD : d.Tokens;
                    int bh = (int)Math.Round(chartH * v / max);
                    var color = d.Day == today ? Theme.Accent : Theme.Brand(p.BrandColor);
                    if (bh > 0)
                        using (var b = new SolidBrush(color))
                            g.FillRectangle(b, xi, y + chartH - bh, bw, bh);
                    else
                        using (var b = new SolidBrush(Theme.Track))
                            g.FillRectangle(b, xi, y + chartH - form.S(2), bw, form.S(2));
                    xi += bw + gap;
                }
            }
            y += chartH + form.S(6);

            if (!measureOnly)
            {
                double todayV = 0, monthV = 0;
                var todayKey = DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                var monthKey = DateTime.Now.ToString("yyyy-MM", CultureInfo.InvariantCulture);
                foreach (var d in p.Daily)
                {
                    var v = isCost ? d.CostUSD : d.Tokens;
                    if (d.Day == todayKey) todayV += v;
                    if (d.Day.StartsWith(monthKey)) monthV += v;
                }
                string totals;
                if (isCost)
                    totals = "today $" + todayV.ToString("0.00", CultureInfo.InvariantCulture) +
                             " · this month $" + monthV.ToString("0.00", CultureInfo.InvariantCulture);
                else
                    totals = "today " + Theme.Tokens((long)todayV) +
                             " · this month " + Theme.Tokens((long)monthV);
                TextRenderer.DrawText(g, totals, Font, new Point(x, y), Theme.SubText);
            }
            return y + form.S(22);
        }

        // ---- summary ------------------------------------------------------------

        int PaintSummary(Graphics g, ProviderStatus p, int x, int y, int w, bool measureOnly)
        {
            foreach (var b in p.Summary)
            {
                var parts = b.PartsValue != null ? b.PartsValue : new Parts();
                if (!measureOnly)
                {
                    TextRenderer.DrawText(g, b.Label, Font, new Point(x, y), Theme.Text);
                    using (var f = new Font("Segoe UI", 9f, FontStyle.Bold))
                    {
                        var t = Theme.Tokens(parts.Total);
                        var tw = TextRenderer.MeasureText(t, f).Width;
                        TextRenderer.DrawText(g, t, f, new Point(x + w - tw, y), Theme.Text);
                    }
                }
                y += form.S(20);

                if (!measureOnly)
                {
                    var barRect = new Rectangle(x, y, w, form.S(10));
                    using (var track = new SolidBrush(Theme.Track)) FillRounded(g, track, barRect, form.S(5));
                    if (parts.Total > 0)
                    {
                        int xi = x;
                        int wi = (int)Math.Round(w * (double)parts.Input / parts.Total);
                        int wc = (int)Math.Round(w * (double)parts.Cache / parts.Total);
                        int wo = w - wi - wc;
                        if (wi > 0) using (var br = new SolidBrush(Theme.PartInput)) g.FillRectangle(br, xi, y, wi, form.S(10));
                        xi += wi;
                        if (wc > 0) using (var br = new SolidBrush(Theme.PartCache)) g.FillRectangle(br, xi, y, wc, form.S(10));
                        xi += wc;
                        if (wo > 0) using (var br = new SolidBrush(Theme.PartOutput)) g.FillRectangle(br, xi, y, wo, form.S(10));
                    }
                }
                y += form.S(16);

                if (!measureOnly)
                {
                    var legend = "in " + Theme.Tokens(parts.Input) +
                                 " · cache " + Theme.Tokens(parts.Cache) +
                                 " · out " + Theme.Tokens(parts.Output);
                    TextRenderer.DrawText(g, legend, Font, new Point(x, y), Theme.SubText);
                }
                y += form.S(26);
            }
            return y + form.S(8);
        }

        // ---- heatmap ------------------------------------------------------------

        int PaintHeatmap(Graphics g, ProviderStatus p, int x, int y, int w, bool measureOnly)
        {
            var h = p.HeatmapValue;
            if (!measureOnly)
                TextRenderer.DrawText(g, Theme.Tokens(h.TotalTokens) + " tokens in the last 12 weeks",
                    Font, new Point(x, y), Theme.SubText);
            y += form.S(24);

            // daily grid: columns = weeks, rows = Mon...Sun
            int cols = h.DailyGrid != null ? h.DailyGrid.Count : 0;
            if (cols > 0)
            {
                int gap = form.S(2);
                int cell = Math.Max(form.S(6), Math.Min(form.S(14), (w - form.S(28) - gap * (cols - 1)) / cols));
                string[] dayLabels = { "Mon", "", "Wed", "", "Fri", "", "" };
                if (!measureOnly)
                {
                    using (var f = new Font("Segoe UI", 7f))
                        for (int r = 0; r < 7; r++)
                            if (dayLabels[r].Length > 0)
                                TextRenderer.DrawText(g, dayLabels[r], f,
                                    new Point(x, y + r * (cell + gap)), Theme.SubText);
                    for (int c = 0; c < cols; c++)
                    {
                        var column = h.DailyGrid[c];
                        for (int r = 0; r < 7 && r < column.Count; r++)
                        {
                            var cellV = column[r];
                            var rect = new Rectangle(x + form.S(28) + c * (cell + gap), y + r * (cell + gap), cell, cell);
                            if (cellV == null) continue;  // future day
                            var lvl = Math.Max(0, Math.Min(4, cellV.Level));
                            using (var b = new SolidBrush(Theme.Heat[lvl])) g.FillRectangle(b, rect);
                        }
                    }
                }
                y += 7 * (cell + gap) + form.S(14);
            }

            // hour-of-day punch card
            if (h.HourRows != null && h.HourRows.Count > 0)
            {
                y = PaintSectionTitle(g, x, y, "BY HOUR — LAST 7 DAYS", measureOnly);
                int gap = form.S(2);
                int cell = Math.Max(form.S(6), Math.Min(form.S(12), (w - form.S(28) - gap * 23) / 24));
                if (!measureOnly)
                {
                    using (var f = new Font("Segoe UI", 7f))
                    {
                        int r = 0;
                        foreach (var row in h.HourRows)
                        {
                            TextRenderer.DrawText(g, row.Day, f, new Point(x, y + r * (cell + gap)), Theme.SubText);
                            for (int c = 0; c < 24 && c < row.Cells.Count; c++)
                            {
                                var cellV = row.Cells[c];
                                if (cellV == null) continue;
                                var lvl = Math.Max(0, Math.Min(4, cellV.Level));
                                var rect = new Rectangle(x + form.S(28) + c * (cell + gap), y + r * (cell + gap), cell, cell);
                                using (var b = new SolidBrush(Theme.Heat[lvl])) g.FillRectangle(b, rect);
                            }
                            r++;
                        }
                    }
                }
                y += h.HourRows.Count * (cell + gap) + form.S(8);
            }
            return y + form.S(12);
        }

        static void FillRounded(Graphics g, Brush brush, Rectangle rect, int radius)
        {
            if (rect.Width <= 0 || rect.Height <= 0) return;
            var d = Math.Min(radius * 2, Math.Min(rect.Width, rect.Height));
            if (d < 2) { g.FillRectangle(brush, rect); return; }
            using (var path = new GraphicsPath())
            {
                path.AddArc(rect.X, rect.Y, d, d, 180, 90);
                path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
                path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
                path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
                path.CloseFigure();
                g.FillPath(brush, path);
            }
        }
    }

    // =============================================================== settings

    class SettingsPanel : Panel
    {
        readonly PanelForm form;
        Dictionary<string, CheckBox> checks = new Dictionary<string, CheckBox>();
        NumericUpDown refreshBox;
        TextBox thresholdsBox;

        public SettingsPanel(PanelForm form)
        {
            this.form = form;
            BackColor = Theme.Background;
            AutoScroll = true;
        }

        public void LoadFrom(Config c)
        {
            Controls.Clear();
            checks.Clear();
            int x = form.S(14);
            int y = form.S(10);

            Controls.Add(MakeLabel("PROVIDERS", x, y, true));
            y += form.S(22);
            foreach (var info in Catalog.Supported)
            {
                var cb = new CheckBox();
                cb.Text = info.Name;
                cb.ForeColor = Theme.Text;
                cb.BackColor = Theme.Background;
                cb.Location = new Point(x, y);
                cb.Width = form.S(170);
                cb.Checked = c.IsEnabled(info.Id);
                checks[info.Id] = cb;
                Controls.Add(cb);
                y += form.S(26);
            }

            y += form.S(8);
            Controls.Add(MakeLabel("REFRESH INTERVAL (SECONDS)", x, y, true));
            y += form.S(22);
            refreshBox = new NumericUpDown();
            refreshBox.Minimum = 30;
            refreshBox.Maximum = 1800;
            refreshBox.Increment = 30;
            refreshBox.Value = Math.Max(30, Math.Min(1800, c.RefreshSeconds));
            refreshBox.Location = new Point(x, y);
            refreshBox.Width = form.S(90);
            Controls.Add(refreshBox);
            y += form.S(34);

            Controls.Add(MakeLabel("ALERT THRESHOLDS (%, COMMA-SEPARATED — EMPTY DISABLES)", x, y, true));
            y += form.S(22);
            thresholdsBox = new TextBox();
            thresholdsBox.Text = string.Join(", ", c.AlertThresholds
                .Select(t => t.ToString(CultureInfo.InvariantCulture)).ToArray());
            thresholdsBox.Location = new Point(x, y);
            thresholdsBox.Width = form.S(200);
            thresholdsBox.BackColor = Theme.Card;
            thresholdsBox.ForeColor = Theme.Text;
            Controls.Add(thresholdsBox);
            y += form.S(36);

            var save = new Button();
            save.Text = "Save";
            save.FlatStyle = FlatStyle.Flat;
            save.ForeColor = Theme.Text;
            save.BackColor = Theme.Card;
            save.Location = new Point(x, y);
            save.Click += delegate { SaveTo(c); };
            Controls.Add(save);

            var back = new Button();
            back.Text = "Back";
            back.FlatStyle = FlatStyle.Flat;
            back.ForeColor = Theme.SubText;
            back.BackColor = Theme.Background;
            back.Location = new Point(x + form.S(90), y);
            back.Click += delegate { form.SelectView("live"); };
            Controls.Add(back);
        }

        Label MakeLabel(string text, int x, int y, bool isSection)
        {
            var l = new Label();
            l.Text = text;
            l.AutoSize = true;
            l.Location = new Point(x, y);
            l.ForeColor = Theme.SubText;
            l.Font = new Font("Segoe UI", isSection ? 7.5f : 9f, isSection ? FontStyle.Bold : FontStyle.Regular);
            return l;
        }

        void SaveTo(Config c)
        {
            var enabled = new List<string>();
            foreach (var pair in checks)
                if (pair.Value.Checked) enabled.Add(pair.Key);
            // all checked = null (daemon default "all supported")
            c.EnabledProviders = enabled.Count == Catalog.Supported.Length ? null : enabled;
            c.RefreshSeconds = (int)refreshBox.Value;

            var thresholds = new List<double>();
            foreach (var part in thresholdsBox.Text.Split(','))
            {
                double v;
                if (double.TryParse(part.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out v)
                    && v > 0 && v <= 100)
                    thresholds.Add(v);
            }
            thresholds.Sort();
            if (thresholds.Count > 6) thresholds = thresholds.Take(6).ToList();
            c.AlertThresholds = thresholds;

            form.ApplySettings(c);
        }
    }
}
