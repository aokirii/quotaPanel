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
        static void Main(string[] args)
        {
            bool createdNew;
            // One instance is enough; a second launch just exits.
            var mutex = new Mutex(true, "QuotaPanelTraySingleton", out createdNew);
            if (!createdNew) return;

            try { SetProcessDPIAware(); } catch (Exception) { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new TrayContext(args));
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
        // severity ramp — same values as the GNOME extension / macOS UsageMeterView
        public static readonly Color Green = ColorTranslator.FromHtml("#2ec27e");
        public static readonly Color Yellow = ColorTranslator.FromHtml("#e5c07b");
        public static readonly Color Orange = ColorTranslator.FromHtml("#ff7800");
        public static readonly Color Red = ColorTranslator.FromHtml("#e5484d");
        // token composition (input / cache / output) — extension.js PART_COLORS
        public static readonly Color PartInput = ColorTranslator.FromHtml("#e8843a");
        public static readonly Color PartCache = ColorTranslator.FromHtml("#3ea76f");
        public static readonly Color PartOutput = ColorTranslator.FromHtml("#e6cf4f");
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
            if (percent >= 50) return Yellow;
            return Green;
        }

        /// Context bars use their own (harsher) ramp, like the other shells.
        public static Color ContextColor(double percent)
        {
            if (percent >= 90) return Red;
            if (percent >= 70) return Orange;
            return Green;
        }

        public static Color Brand(string hex)
        {
            try { return ColorTranslator.FromHtml(hex); }
            catch (Exception) { return Color.Gray; }
        }

        /// Brand color adjusted for glyph tinting on the dark panel: near-black
        /// brands (manus #34322d) would vanish, so they get the light neutral
        /// the GNOME extension uses.
        public static Color GlyphTint(Color brand)
        {
            var lum = (0.299 * brand.R + 0.587 * brand.G + 0.114 * brand.B) / 255.0;
            return lum < 0.2 ? ColorTranslator.FromHtml("#b5b2a8") : brand;
        }

        public static string Percent(double p)
        {
            // Always fractional ("8.1%", "88.0%") — matches the macOS habit of
            // suffix-form decimal percentages.
            return Math.Round(p, 1).ToString("0.0", CultureInfo.InvariantCulture) + "%";
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

    // ============================================================ draw helpers

    static class Draw
    {
        public static GraphicsPath Rounded(Rectangle rect, int radius)
        {
            var path = new GraphicsPath();
            var d = Math.Min(radius * 2, Math.Min(rect.Width, rect.Height));
            if (d < 2) { path.AddRectangle(rect); return path; }
            path.AddArc(rect.X, rect.Y, d, d, 180, 90);
            path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
            path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
            path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        public static void FillRounded(Graphics g, Brush brush, Rectangle rect, int radius)
        {
            if (rect.Width <= 0 || rect.Height <= 0) return;
            using (var path = Rounded(rect, radius)) g.FillPath(brush, path);
        }

        /// Fills the input/cache/output composition segments inside a
        /// rounded-clipped bar.
        public static void FillSegments(Graphics g, Rectangle bar, int radius, Parts parts)
        {
            if (bar.Width <= 0 || parts == null || parts.Total <= 0) return;
            using (var clip = Rounded(bar, radius))
            {
                g.SetClip(clip, CombineMode.Intersect);
                long total = parts.Total;
                int xi = bar.X;
                int wi = (int)Math.Round(bar.Width * (double)parts.Input / total);
                int wc = (int)Math.Round(bar.Width * (double)parts.Cache / total);
                int wo = bar.Width - wi - wc;
                if (wi > 0) using (var b = new SolidBrush(Theme.PartInput)) g.FillRectangle(b, xi, bar.Y, wi, bar.Height);
                xi += wi;
                if (wc > 0) using (var b = new SolidBrush(Theme.PartCache)) g.FillRectangle(b, xi, bar.Y, wc, bar.Height);
                xi += wc;
                if (wo > 0) using (var b = new SolidBrush(Theme.PartOutput)) g.FillRectangle(b, xi, bar.Y, wo, bar.Height);
                g.ResetClip();
            }
        }
    }

    // ============================================================= svg glyphs

    /// Minimal renderer for the repo's ProviderIcon-*.svg brand glyphs — the
    /// same files the macOS app and the GNOME extension use (flat paths,
    /// mostly white = tinted with the brand color at draw time). Not a
    /// general SVG engine: it supports exactly what those files contain
    /// (path data M/L/H/V/C/S/Q/T/A/Z, viewBox, per-path solid fills).
    static class SvgIcon
    {
        class Shape
        {
            public GraphicsPath Path;
            public Color Fill;
            public bool UseTint;
        }

        class Glyph
        {
            public float MinX, MinY, W, H;
            public List<Shape> Shapes;
        }

        static readonly Dictionary<string, Glyph> cache = new Dictionary<string, Glyph>();

        public static bool Has(string id) { return Get(id) != null; }

        /// Draws the glyph tinted into rect; false = no svg, caller falls back.
        public static bool Draw(Graphics g, string id, RectangleF rect, Color tint)
        {
            var glyph = Get(id);
            if (glyph == null || glyph.W <= 0 || glyph.H <= 0) return false;
            float scale = Math.Min(rect.Width / glyph.W, rect.Height / glyph.H);
            float ox = rect.X + (rect.Width - glyph.W * scale) / 2f - glyph.MinX * scale;
            float oy = rect.Y + (rect.Height - glyph.H * scale) / 2f - glyph.MinY * scale;
            using (var m = new Matrix())
            {
                m.Translate(ox, oy);
                m.Scale(scale, scale);
                foreach (var s in glyph.Shapes)
                {
                    using (var path = (GraphicsPath)s.Path.Clone())
                    {
                        path.Transform(m);
                        using (var b = new SolidBrush(s.UseTint ? tint : s.Fill))
                            g.FillPath(b, path);
                    }
                }
            }
            return true;
        }

        static Glyph Get(string id)
        {
            Glyph cached;
            if (cache.TryGetValue(id, out cached)) return cached;
            Glyph glyph = null;
            try
            {
                var file = FindFile(id);
                if (file != null) glyph = Parse(File.ReadAllText(file));
            }
            catch (Exception) { glyph = null; }
            cache[id] = glyph;
            return glyph;
        }

        static string FindFile(string id)
        {
            var name = "ProviderIcon-" + id + ".svg";
            var candidates = new List<string>();
            var exeDir = Path.GetDirectoryName(Application.ExecutablePath);
            if (exeDir != null)
            {
                candidates.Add(Path.Combine(exeDir, "icons", name));
                candidates.Add(Path.Combine(exeDir, "..", "..", "Resources", name));  // repo checkout
            }
            var localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA");
            if (!string.IsNullOrEmpty(localAppData))
                candidates.Add(Path.Combine(localAppData, "QuotaPanel", "icons", name));
            foreach (var c in candidates)
            {
                try { if (File.Exists(c)) return c; }
                catch (Exception) { }
            }
            return null;
        }

        static Glyph Parse(string svg)
        {
            var glyph = new Glyph();
            glyph.Shapes = new List<Shape>();

            var vb = System.Text.RegularExpressions.Regex.Match(svg, "viewBox=\"([^\"]+)\"");
            if (vb.Success)
            {
                var parts = vb.Groups[1].Value.Split(new char[] { ' ', ',' }, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length == 4)
                {
                    glyph.MinX = ParseF(parts[0]);
                    glyph.MinY = ParseF(parts[1]);
                    glyph.W = ParseF(parts[2]);
                    glyph.H = ParseF(parts[3]);
                }
            }
            if (glyph.W <= 0 || glyph.H <= 0)
            {
                glyph.W = ParseF(Attr(svg, "width"));
                glyph.H = ParseF(Attr(svg, "height"));
                if (glyph.W <= 0 || glyph.H <= 0) return null;
            }

            foreach (System.Text.RegularExpressions.Match m in
                     System.Text.RegularExpressions.Regex.Matches(svg, "<path\\b[^>]*>"))
            {
                var tag = m.Value;
                var d = Attr(tag, "d");
                if (string.IsNullOrEmpty(d)) continue;
                var fill = Attr(tag, "fill");
                if (fill == "none") continue;
                var rule = Attr(tag, "fill-rule");
                GraphicsPath path;
                try { path = ParsePathData(d, rule == "evenodd"); }
                catch (Exception) { continue; }
                var shape = new Shape();
                shape.Path = path;
                shape.UseTint = fill == null || IsTintable(fill);
                if (!shape.UseTint) shape.Fill = ParseColor(fill);
                glyph.Shapes.Add(shape);
            }
            return glyph.Shapes.Count > 0 ? glyph : null;
        }

        static bool IsTintable(string fill)
        {
            var f = fill.Trim().ToLowerInvariant();
            return f == "white" || f == "#fff" || f == "#ffffff" || f == "currentcolor" || f.StartsWith("url(");
        }

        static Color ParseColor(string fill)
        {
            try
            {
                var f = fill.Trim();
                if (f == "black") return Color.Black;
                return ColorTranslator.FromHtml(f);
            }
            catch (Exception) { return Color.White; }
        }

        static string Attr(string tag, string name)
        {
            var m = System.Text.RegularExpressions.Regex.Match(tag, "(?<![\\w-])" + name + "=\"([^\"]*)\"");
            return m.Success ? m.Groups[1].Value : null;
        }

        static float ParseF(string s)
        {
            if (s == null) return 0;
            float f;
            return float.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out f) ? f : 0;
        }

        // ---- path data -----------------------------------------------------

        static GraphicsPath ParsePathData(string d, bool evenOdd)
        {
            var path = new GraphicsPath(evenOdd ? FillMode.Alternate : FillMode.Winding);
            int i = 0;
            char cmd = ' ';
            char prev = ' ';
            float cx = 0, cy = 0;    // current point
            float sx = 0, sy = 0;    // subpath start
            float pcx = 0, pcy = 0;  // previous control point (for S/T reflection)

            while (true)
            {
                SkipSep(d, ref i);
                if (i >= d.Length) break;
                var c = d[i];
                if (char.IsLetter(c)) { cmd = c; i++; }
                else if (cmd == 'M') cmd = 'L';
                else if (cmd == 'm') cmd = 'l';

                bool rel = char.IsLower(cmd);
                switch (char.ToUpperInvariant(cmd))
                {
                    case 'M':
                    {
                        var x = Num(d, ref i); var y = Num(d, ref i);
                        if (rel) { x += cx; y += cy; }
                        path.StartFigure();
                        cx = x; cy = y; sx = x; sy = y;
                        break;
                    }
                    case 'L':
                    {
                        var x = Num(d, ref i); var y = Num(d, ref i);
                        if (rel) { x += cx; y += cy; }
                        path.AddLine(cx, cy, x, y);
                        cx = x; cy = y;
                        break;
                    }
                    case 'H':
                    {
                        var x = Num(d, ref i);
                        if (rel) x += cx;
                        path.AddLine(cx, cy, x, cy);
                        cx = x;
                        break;
                    }
                    case 'V':
                    {
                        var y = Num(d, ref i);
                        if (rel) y += cy;
                        path.AddLine(cx, cy, cx, y);
                        cy = y;
                        break;
                    }
                    case 'C':
                    {
                        var x1 = Num(d, ref i); var y1 = Num(d, ref i);
                        var x2 = Num(d, ref i); var y2 = Num(d, ref i);
                        var x = Num(d, ref i); var y = Num(d, ref i);
                        if (rel) { x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy; }
                        path.AddBezier(cx, cy, x1, y1, x2, y2, x, y);
                        pcx = x2; pcy = y2; cx = x; cy = y;
                        break;
                    }
                    case 'S':
                    {
                        var x2 = Num(d, ref i); var y2 = Num(d, ref i);
                        var x = Num(d, ref i); var y = Num(d, ref i);
                        if (rel) { x2 += cx; y2 += cy; x += cx; y += cy; }
                        var p = char.ToUpperInvariant(prev);
                        float x1 = (p == 'C' || p == 'S') ? 2 * cx - pcx : cx;
                        float y1 = (p == 'C' || p == 'S') ? 2 * cy - pcy : cy;
                        path.AddBezier(cx, cy, x1, y1, x2, y2, x, y);
                        pcx = x2; pcy = y2; cx = x; cy = y;
                        break;
                    }
                    case 'Q':
                    {
                        var qx = Num(d, ref i); var qy = Num(d, ref i);
                        var x = Num(d, ref i); var y = Num(d, ref i);
                        if (rel) { qx += cx; qy += cy; x += cx; y += cy; }
                        QuadBezier(path, cx, cy, qx, qy, x, y);
                        pcx = qx; pcy = qy; cx = x; cy = y;
                        break;
                    }
                    case 'T':
                    {
                        var x = Num(d, ref i); var y = Num(d, ref i);
                        if (rel) { x += cx; y += cy; }
                        var p = char.ToUpperInvariant(prev);
                        float qx = (p == 'Q' || p == 'T') ? 2 * cx - pcx : cx;
                        float qy = (p == 'Q' || p == 'T') ? 2 * cy - pcy : cy;
                        QuadBezier(path, cx, cy, qx, qy, x, y);
                        pcx = qx; pcy = qy; cx = x; cy = y;
                        break;
                    }
                    case 'A':
                    {
                        var rx = Num(d, ref i); var ry = Num(d, ref i);
                        var rot = Num(d, ref i);
                        var laf = Flag(d, ref i); var sf = Flag(d, ref i);
                        var x = Num(d, ref i); var y = Num(d, ref i);
                        if (rel) { x += cx; y += cy; }
                        ArcSegment(path, cx, cy, rx, ry, rot, laf != 0, sf != 0, x, y);
                        cx = x; cy = y;
                        break;
                    }
                    case 'Z':
                    {
                        path.CloseFigure();
                        cx = sx; cy = sy;
                        break;
                    }
                    default:
                        return path;  // unknown command — render what we have
                }
                prev = cmd;
            }
            return path;
        }

        static void QuadBezier(GraphicsPath path, float x0, float y0, float qx, float qy, float x, float y)
        {
            // quadratic → cubic control points
            float c1x = x0 + 2f / 3f * (qx - x0), c1y = y0 + 2f / 3f * (qy - y0);
            float c2x = x + 2f / 3f * (qx - x), c2y = y + 2f / 3f * (qy - y);
            path.AddBezier(x0, y0, c1x, c1y, c2x, c2y, x, y);
        }

        /// SVG elliptical arc → cubic bezier segments (W3C F.6.5).
        static void ArcSegment(GraphicsPath path, float x0, float y0, float rx, float ry,
                               float rotDeg, bool largeArc, bool sweep, float x, float y)
        {
            if (rx == 0 || ry == 0 || (x0 == x && y0 == y)) { path.AddLine(x0, y0, x, y); return; }
            double phi = rotDeg * Math.PI / 180.0;
            double cosP = Math.Cos(phi), sinP = Math.Sin(phi);
            double rxd = Math.Abs(rx), ryd = Math.Abs(ry);

            double dx2 = (x0 - x) / 2.0, dy2 = (y0 - y) / 2.0;
            double x1p = cosP * dx2 + sinP * dy2;
            double y1p = -sinP * dx2 + cosP * dy2;
            double lam = (x1p * x1p) / (rxd * rxd) + (y1p * y1p) / (ryd * ryd);
            if (lam > 1) { var s = Math.Sqrt(lam); rxd *= s; ryd *= s; }

            double rx2 = rxd * rxd, ry2 = ryd * ryd;
            double num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p;
            double den = rx2 * y1p * y1p + ry2 * x1p * x1p;
            double co = den == 0 ? 0 : Math.Sqrt(Math.Max(0, num / den));
            if (largeArc == sweep) co = -co;
            double cxp = co * rxd * y1p / ryd;
            double cyp = -co * ryd * x1p / rxd;
            double ccx = cosP * cxp - sinP * cyp + (x0 + x) / 2.0;
            double ccy = sinP * cxp + cosP * cyp + (y0 + y) / 2.0;

            double theta1 = VecAngle(1, 0, (x1p - cxp) / rxd, (y1p - cyp) / ryd);
            double dTheta = VecAngle((x1p - cxp) / rxd, (y1p - cyp) / ryd,
                                     (-x1p - cxp) / rxd, (-y1p - cyp) / ryd);
            if (!sweep && dTheta > 0) dTheta -= 2 * Math.PI;
            if (sweep && dTheta < 0) dTheta += 2 * Math.PI;

            int segs = Math.Max(1, (int)Math.Ceiling(Math.Abs(dTheta) / (Math.PI / 2)));
            double delta = dTheta / segs;
            double t = 4.0 / 3.0 * Math.Tan(delta / 4.0);
            double angle = theta1;
            for (int k = 0; k < segs; k++)
            {
                double a2 = angle + delta;
                double e1x = ccx + rxd * Math.Cos(angle) * cosP - ryd * Math.Sin(angle) * sinP;
                double e1y = ccy + rxd * Math.Cos(angle) * sinP + ryd * Math.Sin(angle) * cosP;
                double e2x = ccx + rxd * Math.Cos(a2) * cosP - ryd * Math.Sin(a2) * sinP;
                double e2y = ccy + rxd * Math.Cos(a2) * sinP + ryd * Math.Sin(a2) * cosP;
                double d1x = -rxd * Math.Sin(angle) * cosP - ryd * Math.Cos(angle) * sinP;
                double d1y = -rxd * Math.Sin(angle) * sinP + ryd * Math.Cos(angle) * cosP;
                double d2x = -rxd * Math.Sin(a2) * cosP - ryd * Math.Cos(a2) * sinP;
                double d2y = -rxd * Math.Sin(a2) * sinP + ryd * Math.Cos(a2) * cosP;
                path.AddBezier(
                    (float)e1x, (float)e1y,
                    (float)(e1x + t * d1x), (float)(e1y + t * d1y),
                    (float)(e2x - t * d2x), (float)(e2y - t * d2y),
                    (float)e2x, (float)e2y);
                angle = a2;
            }
        }

        static double VecAngle(double ux, double uy, double vx, double vy)
        {
            double dot = ux * vx + uy * vy;
            double len = Math.Sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy));
            if (len == 0) return 0;
            double ang = Math.Acos(Math.Max(-1, Math.Min(1, dot / len)));
            if (ux * vy - uy * vx < 0) ang = -ang;
            return ang;
        }

        static void SkipSep(string d, ref int i)
        {
            while (i < d.Length && (d[i] == ' ' || d[i] == ',' || d[i] == '\n' || d[i] == '\r' || d[i] == '\t')) i++;
        }

        static float Num(string d, ref int i)
        {
            SkipSep(d, ref i);
            int start = i;
            if (i < d.Length && (d[i] == '+' || d[i] == '-')) i++;
            bool dot = false;
            while (i < d.Length)
            {
                var ch = d[i];
                if (ch >= '0' && ch <= '9') { i++; continue; }
                if (ch == '.' && !dot) { dot = true; i++; continue; }
                if ((ch == 'e' || ch == 'E') && i > start)
                {
                    i++;
                    if (i < d.Length && (d[i] == '+' || d[i] == '-')) i++;
                    dot = true;  // no dot allowed after the exponent
                    continue;
                }
                break;
            }
            float f;
            float.TryParse(d.Substring(start, i - start), NumberStyles.Float, CultureInfo.InvariantCulture, out f);
            return f;
        }

        static int Flag(string d, ref int i)
        {
            SkipSep(d, ref i);
            if (i < d.Length && (d[i] == '0' || d[i] == '1')) { var v = d[i] - '0'; i++; return v; }
            return (int)Num(d, ref i) != 0 ? 1 : 0;
        }
    }

    // ======================================================== credential store

    /// Read/write access to `~/.quotapanel/credentials.json` — the same store
    /// the macOS app and the daemon use. Entries are kept as raw dictionaries
    /// so fields this shell doesn't know survive a round-trip.
    static class CredStore
    {
        public static string Home
        {
            get
            {
                var h = Environment.GetEnvironmentVariable("USERPROFILE");
                if (string.IsNullOrEmpty(h)) h = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                return h;
            }
        }

        static string FilePath { get { return Path.Combine(Home, ".quotapanel", "credentials.json"); } }

        public static Dictionary<string, object> LoadAll()
        {
            try
            {
                if (!File.Exists(FilePath)) return new Dictionary<string, object>();
                var ser = new JavaScriptSerializer();
                var root = J.Dict(ser.DeserializeObject(File.ReadAllText(FilePath)));
                return root != null ? root : new Dictionary<string, object>();
            }
            catch (Exception) { return new Dictionary<string, object>(); }
        }

        public static bool Has(string id) { return J.Dict(J.Get(LoadAll(), id)) != null; }

        public static void Save(string id, Dictionary<string, object> entry)
        {
            var all = LoadAll();
            all[id] = entry;
            WriteAll(all);
        }

        public static void Delete(string id)
        {
            var all = LoadAll();
            if (!all.Remove(id)) return;
            if (all.Count == 0)
            {
                try { File.Delete(FilePath); } catch (Exception) { }
            }
            else WriteAll(all);
        }

        static void WriteAll(Dictionary<string, object> all)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
                var ser = new JavaScriptSerializer();
                File.WriteAllText(FilePath, ser.Serialize(all), new UTF8Encoding(false));
            }
            catch (Exception) { }
        }
    }

    // ================================================================== oauth

    /// OAuth client ids, read at runtime from %APPDATA%\quotapanel\
    /// oauth-clients.json (same file the daemon uses) — never committed.
    static class OAuthCfg
    {
        public static string ClientId(string key)
        {
            return Value(key, "clientId", "_CLIENT_ID");
        }

        public static string ClientSecret(string key)
        {
            return Value(key, "clientSecret", "_CLIENT_SECRET");
        }

        static string Value(string key, string field, string envSuffix)
        {
            var env = Environment.GetEnvironmentVariable("QUOTAPANEL_" + key.ToUpperInvariant() + envSuffix);
            if (!string.IsNullOrEmpty(env)) return env;
            try
            {
                var path = Path.Combine(Config.Dir, "oauth-clients.json");
                if (!File.Exists(path)) return "";
                var ser = new JavaScriptSerializer();
                var root = J.Dict(ser.DeserializeObject(File.ReadAllText(path)));
                var entry = J.Dict(J.Get(root, key));
                var value = J.Str(entry, field, "");
                return value.StartsWith("PASTE_") ? "" : value;
            }
            catch (Exception) { return ""; }
        }

        public static string MissingHint(string provider)
        {
            return provider + " client id missing — copy oauth-clients.sample.json to\n" +
                   Path.Combine(Config.Dir, "oauth-clients.json") + " and fill it in.";
        }
    }

    static class Pkce
    {
        public static string Random(int bytes)
        {
            var buf = new byte[bytes];
            using (var rng = new System.Security.Cryptography.RNGCryptoServiceProvider()) rng.GetBytes(buf);
            return B64Url(buf);
        }

        public static string Challenge(string verifier)
        {
            using (var sha = new System.Security.Cryptography.SHA256Managed())
                return B64Url(sha.ComputeHash(Encoding.ASCII.GetBytes(verifier)));
        }

        static string B64Url(byte[] data)
        {
            return Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');
        }
    }

    /// Ports of the macOS app's sign-in flows (Services/OAuth.swift): Claude =
    /// paste-a-code PKCE, Codex = localhost:1455 loopback callback, Gemini and
    /// Antigravity = Google loopback callback on localhost:8976, Copilot =
    /// GitHub device flow. Tokens are written to ~/.quotapanel/credentials.json;
    /// the daemon prefers them and keeps them refreshed. Each flow returns null
    /// on success, "" on user cancel, or an error message.
    static class OAuthFlows
    {
        public static string SignInClaude(IWin32Window owner)
        {
            var clientId = OAuthCfg.ClientId("claude");
            if (clientId.Length == 0) return OAuthCfg.MissingHint("Claude");
            var verifier = Pkce.Random(64);
            var state = Pkce.Random(32);
            const string redirect = "https://console.anthropic.com/oauth/code/callback";
            var url = "https://claude.ai/oauth/authorize?code=true" +
                "&client_id=" + Uri.EscapeDataString(clientId) +
                "&response_type=code" +
                "&redirect_uri=" + Uri.EscapeDataString(redirect) +
                "&scope=" + Uri.EscapeDataString("org:create_api_key user:profile user:inference") +
                "&code_challenge=" + Pkce.Challenge(verifier) +
                "&code_challenge_method=S256" +
                "&state=" + Uri.EscapeDataString(state);
            try { Process.Start(url); }
            catch (Exception) { return "Could not open the browser."; }

            var input = PromptDialog.Show(owner, "Sign in to Claude",
                "Approve access in the browser, then paste the code shown:");
            if (input == null) return "";
            var trimmed = input.Trim();
            if (trimmed.Length == 0) return "Empty code — paste it exactly as shown.";
            var pieces = trimmed.Split(new char[] { '#' }, 2);
            var code = pieces[0];
            var gotState = pieces.Length > 1 ? pieces[1] : state;
            if (gotState != state) return "Security check (state) mismatch — restart the sign-in.";

            string error;
            var body = new Dictionary<string, string>();
            body["grant_type"] = "authorization_code";
            body["code"] = code;
            body["state"] = gotState;
            body["client_id"] = clientId;
            body["redirect_uri"] = redirect;
            body["code_verifier"] = verifier;
            var json = PostJson("https://console.anthropic.com/v1/oauth/token", body, out error);
            if (json == null) return error != null ? error : "Token exchange failed.";
            var access = J.Str(json, "access_token", "");
            if (access.Length == 0) return "Token exchange failed (no access token).";

            var entry = new Dictionary<string, object>();
            entry["accessToken"] = access;
            var refresh = J.Str(json, "refresh_token", null);
            if (refresh != null) entry["refreshToken"] = refresh;
            var account = J.Dict(J.Get(json, "account"));
            var uuid = J.Str(account, "uuid", null);
            if (uuid != null) entry["accountId"] = uuid;
            AddExpiry(entry, json);
            var plan = J.Str(json, "subscription_type", null);
            if (plan == null) plan = J.Str(account, "subscription_type", null);
            if (plan != null) entry["plan"] = plan;
            CredStore.Save("claude", entry);
            return null;
        }

        public static string SignInCodex(IWin32Window owner)
        {
            var clientId = OAuthCfg.ClientId("codex");
            if (clientId.Length == 0) return OAuthCfg.MissingHint("Codex");
            var verifier = Pkce.Random(64);
            var state = Pkce.Random(32);
            const string redirect = "http://localhost:1455/auth/callback";

            System.Net.Sockets.TcpListener listener;
            try
            {
                listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 1455);
                listener.Start();
            }
            catch (Exception)
            {
                return "Port 1455 is in use (another codex sign-in may be running) — close it and retry.";
            }

            var url = "https://auth.openai.com/oauth/authorize?response_type=code" +
                "&client_id=" + Uri.EscapeDataString(clientId) +
                "&redirect_uri=" + Uri.EscapeDataString(redirect) +
                "&scope=" + Uri.EscapeDataString("openid profile email offline_access") +
                "&code_challenge=" + Pkce.Challenge(verifier) +
                "&code_challenge_method=S256" +
                "&state=" + Uri.EscapeDataString(state) +
                "&id_token_add_organizations=true";
            try { Process.Start(url); }
            catch (Exception) { listener.Stop(); return "Could not open the browser."; }

            string code = null, cbError = null;
            bool done = false;
            var worker = new Thread(delegate()
            {
                try
                {
                    using (var client = listener.AcceptTcpClient())
                    using (var stream = client.GetStream())
                    {
                        var buf = new byte[16384];
                        int n = stream.Read(buf, 0, buf.Length);
                        var request = Encoding.UTF8.GetString(buf, 0, Math.Max(0, n));
                        var line = request.Split('\n')[0];
                        var q = ParseQuery(line);
                        string gotState, gotCode;
                        q.TryGetValue("state", out gotState);
                        q.TryGetValue("code", out gotCode);
                        if (q.ContainsKey("error")) cbError = "Sign-in was denied.";
                        else if (gotState != state) cbError = "Security check (state) mismatch — restart the sign-in.";
                        else if (string.IsNullOrEmpty(gotCode)) cbError = "No code in the callback.";
                        else code = gotCode;

                        var html = cbError == null
                            ? "<html><body style='font-family:sans-serif'><h3>Sign-in complete ✓</h3><p>You can close this window and return to QuotaPanel.</p></body></html>"
                            : "<html><body style='font-family:sans-serif'><h3>Sign-in failed</h3><p>Return to QuotaPanel and try again.</p></body></html>";
                        var payload = Encoding.UTF8.GetBytes(html);
                        var header = Encoding.ASCII.GetBytes(
                            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: " +
                            payload.Length + "\r\n\r\n");
                        stream.Write(header, 0, header.Length);
                        stream.Write(payload, 0, payload.Length);
                        stream.Flush();
                    }
                }
                catch (Exception) { /* listener stopped = cancelled */ }
                finally
                {
                    try { listener.Stop(); } catch (Exception) { }
                    done = true;
                }
            });
            worker.IsBackground = true;
            worker.Start();

            var finished = WaitDialog.Show(owner, "Sign in to Codex",
                "Waiting for the browser sign-in…", delegate { return done; }, 300);
            if (!finished)
            {
                try { listener.Stop(); } catch (Exception) { }
                return "";
            }
            if (cbError != null) return cbError;
            if (code == null) return "Sign-in timed out — try again.";

            string error;
            var body = new Dictionary<string, string>();
            body["grant_type"] = "authorization_code";
            body["code"] = code;
            body["redirect_uri"] = redirect;
            body["client_id"] = clientId;
            body["code_verifier"] = verifier;
            var json = PostJson("https://auth.openai.com/oauth/token", body, out error);
            if (json == null) return error != null ? error : "Token exchange failed.";
            var access = J.Str(json, "access_token", "");
            if (access.Length == 0) return "Token exchange failed (no access token).";

            var entry = new Dictionary<string, object>();
            entry["accessToken"] = access;
            var refresh = J.Str(json, "refresh_token", null);
            if (refresh != null) entry["refreshToken"] = refresh;
            var idToken = J.Str(json, "id_token", null);
            if (idToken != null)
            {
                entry["idToken"] = idToken;
                var auth = J.Dict(J.Get(JwtClaims(idToken), "https://api.openai.com/auth"));
                var accountId = J.Str(auth, "chatgpt_account_id", null);
                if (accountId != null) entry["accountId"] = accountId;
                var plan = J.Str(auth, "chatgpt_plan_type", null);
                if (plan != null) entry["plan"] = plan;
            }
            AddExpiry(entry, json);
            CredStore.Save("codex", entry);
            return null;
        }

        // --- Google (Gemini & Antigravity) --------------------------------
        // Shared Google "installed app" flow, mirroring the macOS GoogleAuth:
        // PKCE + loopback callback on localhost:8976/oauth2callback. The two
        // providers differ only in which OAuth client signs the request.

        const int GooglePort = 8976;
        const string GooglePath = "/oauth2callback";
        const string GoogleScopes =
            "https://www.googleapis.com/auth/cloud-platform " +
            "https://www.googleapis.com/auth/userinfo.email " +
            "https://www.googleapis.com/auth/userinfo.profile";

        public static string SignInGemini(IWin32Window owner)
        {
            return SignInGoogle(owner, "gemini", "Gemini");
        }

        public static string SignInAntigravity(IWin32Window owner)
        {
            return SignInGoogle(owner, "antigravity", "Antigravity");
        }

        static string SignInGoogle(IWin32Window owner, string key, string display)
        {
            var clientId = OAuthCfg.ClientId(key);
            var clientSecret = OAuthCfg.ClientSecret(key);
            if (clientId.Length == 0 || clientSecret.Length == 0) return OAuthCfg.MissingHint(display);

            var verifier = Pkce.Random(64);
            var state = Pkce.Random(32);
            var redirect = "http://localhost:" + GooglePort + GooglePath;
            var url = "https://accounts.google.com/o/oauth2/v2/auth?response_type=code" +
                "&client_id=" + Uri.EscapeDataString(clientId) +
                "&redirect_uri=" + Uri.EscapeDataString(redirect) +
                "&scope=" + Uri.EscapeDataString(GoogleScopes) +
                "&code_challenge=" + Pkce.Challenge(verifier) +
                "&code_challenge_method=S256" +
                "&state=" + Uri.EscapeDataString(state) +
                // offline + consent guarantee a refresh_token on every sign-in
                "&access_type=offline&prompt=consent";

            string code;
            var err = AwaitLoopbackCode(owner, "Sign in to " + display, GooglePort, GooglePath, state, url, out code);
            if (err != null) return err;

            string error;
            var form = new Dictionary<string, string>();
            form["grant_type"] = "authorization_code";
            form["code"] = code;
            form["client_id"] = clientId;
            form["client_secret"] = clientSecret;
            form["redirect_uri"] = redirect;
            form["code_verifier"] = verifier;
            var json = PostForm("https://oauth2.googleapis.com/token", form, out error);
            if (json == null) return error != null ? error : "Token exchange failed.";
            var access = J.Str(json, "access_token", "");
            if (access.Length == 0) return "Token exchange failed (no access token).";

            var entry = new Dictionary<string, object>();
            entry["accessToken"] = access;
            var refresh = J.Str(json, "refresh_token", null);
            if (refresh != null) entry["refreshToken"] = refresh;
            var idToken = J.Str(json, "id_token", null);
            if (idToken != null) entry["idToken"] = idToken;
            AddExpiry(entry, json);
            CredStore.Save(key, entry);
            return null;
        }

        // --- Copilot (GitHub device-code flow) ----------------------------
        // The flow copilot.vim and the other editor plugins use: show a short
        // code, open github.com/login/device, poll until the user approves.

        public static string SignInCopilot(IWin32Window owner)
        {
            var clientId = OAuthCfg.ClientId("copilot");
            if (clientId.Length == 0) return OAuthCfg.MissingHint("Copilot");

            string error;
            var start = new Dictionary<string, string>();
            start["client_id"] = clientId;
            start["scope"] = "read:user";
            var device = PostForm("https://github.com/login/device/code", start, out error);
            if (device == null) return error != null ? error : "Could not start the GitHub sign-in.";
            var userCode = J.Str(device, "user_code", "");
            var deviceCode = J.Str(device, "device_code", "");
            var verifyUri = J.Str(device, "verification_uri", "https://github.com/login/device");
            var interval = (int)J.Num(device, "interval", 5);
            var expiresIn = (int)J.Num(device, "expires_in", 900);
            if (userCode.Length == 0 || deviceCode.Length == 0)
                return "GitHub device sign-in failed to start: " +
                    J.Str(device, "error_description", J.Str(device, "error", "unexpected response"));

            try { Clipboard.SetText(userCode); } catch (Exception) { }
            try { Process.Start(verifyUri); }
            catch (Exception) { return "Could not open the browser."; }

            Dictionary<string, object> token = null;
            string pollError = null;
            bool done = false, cancelled = false;
            var worker = new Thread(delegate()
            {
                try
                {
                    var wait = Math.Max(interval, 5);
                    var deadline = DateTime.UtcNow.AddSeconds(expiresIn);
                    while (!cancelled && DateTime.UtcNow < deadline)
                    {
                        Thread.Sleep(wait * 1000);
                        if (cancelled) break;
                        string pollErr;
                        var body = new Dictionary<string, string>();
                        body["client_id"] = clientId;
                        body["device_code"] = deviceCode;
                        body["grant_type"] = "urn:ietf:params:oauth:grant-type:device_code";
                        var json = PostForm("https://github.com/login/oauth/access_token", body, out pollErr);
                        if (json == null)
                        {
                            pollError = pollErr != null ? pollErr : "GitHub polling failed.";
                            break;
                        }
                        if (J.Str(json, "access_token", "").Length > 0) { token = json; break; }
                        var ghError = J.Str(json, "error", "");
                        if (ghError == "authorization_pending") continue;
                        if (ghError == "slow_down") { wait += 5; continue; }
                        if (ghError == "expired_token") { pollError = "The code expired — try again."; break; }
                        if (ghError == "access_denied") { pollError = "Sign-in was denied."; break; }
                        pollError = J.Str(json, "error_description",
                            ghError.Length > 0 ? ghError : "unexpected GitHub response");
                        break;
                    }
                }
                catch (Exception ex) { pollError = ex.Message; }
                finally { done = true; }
            });
            worker.IsBackground = true;
            worker.Start();

            var finished = WaitDialog.Show(owner, "Sign in to Copilot",
                "Enter code " + userCode + " on github.com — it's on your clipboard.",
                delegate { return done; }, expiresIn);
            cancelled = true;   // stops the poll loop on cancel/timeout
            if (!finished) return "";
            if (pollError != null) return pollError;
            if (token == null) return "Sign-in timed out — try again.";

            var entry = new Dictionary<string, object>();
            entry["accessToken"] = J.Str(token, "access_token", "");
            var ghRefresh = J.Str(token, "refresh_token", null);
            if (ghRefresh != null) entry["refreshToken"] = ghRefresh;
            AddExpiry(entry, token);
            CredStore.Save("copilot", entry);
            return null;
        }

        // --- loopback helper ----------------------------------------------

        /// Starts a loopback listener on `port`, opens `url` in the browser,
        /// and waits (behind a modal WaitDialog) for a request to `pathPrefix`
        /// carrying the OAuth code. Non-matching requests (favicon etc.) get a
        /// 404 and the wait continues. Returns null with `code` set on
        /// success, "" on user cancel, or an error message.
        static string AwaitLoopbackCode(IWin32Window owner, string title, int port,
                                        string pathPrefix, string state, string url, out string code)
        {
            code = null;
            System.Net.Sockets.TcpListener listener;
            try
            {
                listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, port);
                listener.Start();
            }
            catch (Exception)
            {
                return "Port " + port + " is in use (another sign-in may be running) — close it and retry.";
            }

            try { Process.Start(url); }
            catch (Exception)
            {
                try { listener.Stop(); } catch (Exception) { }
                return "Could not open the browser.";
            }

            string gotCode = null, cbError = null;
            bool done = false;
            var worker = new Thread(delegate()
            {
                try
                {
                    while (true)
                    {
                        using (var client = listener.AcceptTcpClient())
                        using (var stream = client.GetStream())
                        {
                            var buf = new byte[16384];
                            int n = stream.Read(buf, 0, buf.Length);
                            var request = Encoding.UTF8.GetString(buf, 0, Math.Max(0, n));
                            var line = request.Split('\n')[0];
                            var parts = line.Split(' ');
                            var path = parts.Length > 1 ? parts[1] : "";
                            if (!path.StartsWith(pathPrefix))
                            {
                                WriteHttp(stream, "404 Not Found", "");
                                continue;
                            }
                            var q = ParseQuery(line);
                            string gotState, got;
                            q.TryGetValue("state", out gotState);
                            q.TryGetValue("code", out got);
                            if (q.ContainsKey("error")) cbError = "Sign-in was denied.";
                            else if (gotState != state) cbError = "Security check (state) mismatch — restart the sign-in.";
                            else if (string.IsNullOrEmpty(got)) cbError = "No code in the callback.";
                            else gotCode = got;

                            var html = cbError == null
                                ? "<html><body style='font-family:sans-serif'><h3>Sign-in complete ✓</h3><p>You can close this window and return to QuotaPanel.</p></body></html>"
                                : "<html><body style='font-family:sans-serif'><h3>Sign-in failed</h3><p>Return to QuotaPanel and try again.</p></body></html>";
                            WriteHttp(stream, "200 OK", html);
                            break;
                        }
                    }
                }
                catch (Exception) { /* listener stopped = cancelled */ }
                finally
                {
                    try { listener.Stop(); } catch (Exception) { }
                    done = true;
                }
            });
            worker.IsBackground = true;
            worker.Start();

            var finished = WaitDialog.Show(owner, title,
                "Waiting for the browser sign-in…", delegate { return done; }, 300);
            try { listener.Stop(); } catch (Exception) { }
            if (!finished) return "";
            if (cbError != null) return cbError;
            if (gotCode == null) return "Sign-in timed out — try again.";
            code = gotCode;
            return null;
        }

        static void WriteHttp(System.Net.Sockets.NetworkStream stream, string status, string html)
        {
            var payload = Encoding.UTF8.GetBytes(html);
            var header = Encoding.ASCII.GetBytes(
                "HTTP/1.1 " + status + "\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: " +
                payload.Length + "\r\n\r\n");
            stream.Write(header, 0, header.Length);
            if (payload.Length > 0) stream.Write(payload, 0, payload.Length);
            stream.Flush();
        }

        /// POST a form-encoded body and parse the JSON response (Accept:
        /// application/json — GitHub needs the header, Google ignores it).
        static Dictionary<string, object> PostForm(string url, Dictionary<string, string> form, out string error)
        {
            error = null;
            try
            {
                System.Net.ServicePointManager.SecurityProtocol |= System.Net.SecurityProtocolType.Tls12;
                var sb = new StringBuilder();
                foreach (var pair in form)
                {
                    if (sb.Length > 0) sb.Append('&');
                    sb.Append(Uri.EscapeDataString(pair.Key)).Append('=').Append(Uri.EscapeDataString(pair.Value));
                }
                var req = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(url);
                req.Method = "POST";
                req.ContentType = "application/x-www-form-urlencoded";
                req.Accept = "application/json";
                req.Timeout = 30000;
                var payload = Encoding.UTF8.GetBytes(sb.ToString());
                using (var s = req.GetRequestStream()) s.Write(payload, 0, payload.Length);
                using (var resp = (System.Net.HttpWebResponse)req.GetResponse())
                using (var reader = new StreamReader(resp.GetResponseStream()))
                    return J.Dict(new JavaScriptSerializer().DeserializeObject(reader.ReadToEnd()));
            }
            catch (System.Net.WebException ex)
            {
                error = "Request failed";
                try
                {
                    if (ex.Response != null)
                        using (var reader = new StreamReader(ex.Response.GetResponseStream()))
                        {
                            var text = reader.ReadToEnd();
                            error += ": " + (text.Length > 200 ? text.Substring(0, 200) : text);
                        }
                    else error += ": " + ex.Message;
                }
                catch (Exception) { error += ": " + ex.Message; }
                return null;
            }
            catch (Exception ex)
            {
                error = ex.Message;
                return null;
            }
        }

        static void AddExpiry(Dictionary<string, object> entry, Dictionary<string, object> json)
        {
            var seconds = J.Num(json, "expires_in", 0);
            if (seconds > 0)
                entry["expiresAt"] = DateTime.UtcNow.AddSeconds(seconds)
                    .ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        }

        static Dictionary<string, string> ParseQuery(string requestLine)
        {
            var result = new Dictionary<string, string>();
            var qIdx = requestLine.IndexOf('?');
            if (qIdx < 0) return result;
            var end = requestLine.IndexOf(' ', qIdx);
            var query = end > qIdx ? requestLine.Substring(qIdx + 1, end - qIdx - 1) : requestLine.Substring(qIdx + 1);
            foreach (var pair in query.Split('&'))
            {
                var eq = pair.IndexOf('=');
                if (eq <= 0) continue;
                result[Uri.UnescapeDataString(pair.Substring(0, eq))] =
                    Uri.UnescapeDataString(pair.Substring(eq + 1));
            }
            return result;
        }

        static Dictionary<string, object> JwtClaims(string token)
        {
            try
            {
                var parts = token.Split('.');
                if (parts.Length < 2) return null;
                var payload = parts[1].Replace('-', '+').Replace('_', '/');
                while (payload.Length % 4 != 0) payload += "=";
                var json = Encoding.UTF8.GetString(Convert.FromBase64String(payload));
                return J.Dict(new JavaScriptSerializer().DeserializeObject(json));
            }
            catch (Exception) { return null; }
        }

        static Dictionary<string, object> PostJson(string url, Dictionary<string, string> body, out string error)
        {
            error = null;
            try
            {
                System.Net.ServicePointManager.SecurityProtocol |= System.Net.SecurityProtocolType.Tls12;
                var ser = new JavaScriptSerializer();
                var req = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(url);
                req.Method = "POST";
                req.ContentType = "application/json";
                req.Timeout = 30000;
                var payload = Encoding.UTF8.GetBytes(ser.Serialize(body));
                using (var s = req.GetRequestStream()) s.Write(payload, 0, payload.Length);
                using (var resp = (System.Net.HttpWebResponse)req.GetResponse())
                using (var reader = new StreamReader(resp.GetResponseStream()))
                    return J.Dict(ser.DeserializeObject(reader.ReadToEnd()));
            }
            catch (System.Net.WebException ex)
            {
                error = "Token exchange failed";
                try
                {
                    if (ex.Response != null)
                        using (var reader = new StreamReader(ex.Response.GetResponseStream()))
                        {
                            var text = reader.ReadToEnd();
                            error += ": " + (text.Length > 200 ? text.Substring(0, 200) : text);
                        }
                    else error += ": " + ex.Message;
                }
                catch (Exception) { error += ": " + ex.Message; }
                return null;
            }
            catch (Exception ex)
            {
                error = ex.Message;
                return null;
            }
        }
    }

    // ========================================================== oauth dialogs

    static class DialogStyle
    {
        public static Form MakeForm(string title, int w, int h)
        {
            var f = new Form();
            f.Text = title;
            f.FormBorderStyle = FormBorderStyle.FixedDialog;
            f.MaximizeBox = false;
            f.MinimizeBox = false;
            f.StartPosition = FormStartPosition.CenterScreen;
            f.BackColor = Theme.Background;
            f.ForeColor = Theme.Text;
            f.Font = new Font("Segoe UI", 9f);
            f.ClientSize = new Size(w, h);
            f.TopMost = true;
            return f;
        }

        public static Button MakeButton(string text, bool primary)
        {
            var b = new Button();
            b.Text = text;
            b.FlatStyle = FlatStyle.Flat;
            b.FlatAppearance.BorderSize = primary ? 0 : 1;
            b.FlatAppearance.BorderColor = Theme.Track;
            b.BackColor = primary ? Theme.Accent : Theme.Card;
            b.ForeColor = primary ? Color.FromArgb(30, 30, 35) : Theme.Text;
            if (primary) b.Font = new Font("Segoe UI", 9f, FontStyle.Bold);
            b.Size = new Size(96, 30);
            return b;
        }
    }

    static class PromptDialog
    {
        /// Modal text prompt; null = cancelled.
        public static string Show(IWin32Window owner, string title, string message)
        {
            using (var f = DialogStyle.MakeForm(title, 400, 150))
            {
                var label = new Label();
                label.Text = message;
                label.Location = new Point(14, 12);
                label.Size = new Size(372, 34);
                label.ForeColor = Theme.Text;
                f.Controls.Add(label);

                var box = new TextBox();
                box.Location = new Point(14, 52);
                box.Width = 372;
                box.BackColor = Theme.Card;
                box.ForeColor = Theme.Text;
                box.BorderStyle = BorderStyle.FixedSingle;
                f.Controls.Add(box);

                var ok = DialogStyle.MakeButton("Sign in", true);
                ok.Location = new Point(290, 106);
                ok.DialogResult = DialogResult.OK;
                f.Controls.Add(ok);

                var cancel = DialogStyle.MakeButton("Cancel", false);
                cancel.Location = new Point(186, 106);
                cancel.DialogResult = DialogResult.Cancel;
                f.Controls.Add(cancel);

                f.AcceptButton = ok;
                f.CancelButton = cancel;
                return f.ShowDialog(owner) == DialogResult.OK ? box.Text : null;
            }
        }
    }

    static class WaitDialog
    {
        /// Modal wait: polls isDone every 200 ms, auto-closes when it returns
        /// true or after timeoutSeconds. Returns false when the user cancelled.
        public static bool Show(IWin32Window owner, string title, string message,
                                Func<bool> isDone, int timeoutSeconds)
        {
            using (var f = DialogStyle.MakeForm(title, 360, 110))
            {
                var label = new Label();
                label.Text = message;
                label.Location = new Point(14, 16);
                label.Size = new Size(332, 30);
                label.ForeColor = Theme.Text;
                f.Controls.Add(label);

                var cancel = DialogStyle.MakeButton("Cancel", false);
                cancel.Location = new Point(250, 66);
                cancel.DialogResult = DialogResult.Cancel;
                f.Controls.Add(cancel);
                f.CancelButton = cancel;

                var waited = 0;
                var timer = new System.Windows.Forms.Timer();
                timer.Interval = 200;
                timer.Tick += delegate
                {
                    waited += 200;
                    if (isDone() || waited >= timeoutSeconds * 1000)
                    {
                        timer.Stop();
                        f.DialogResult = DialogResult.OK;
                        f.Close();
                    }
                };
                timer.Start();
                var result = f.ShowDialog(owner);
                timer.Stop();
                timer.Dispose();
                return result == DialogResult.OK;
            }
        }
    }

    // ============================================================= scroll host

    /// Scroll container without the native (light) scrollbars: hosts one
    /// content control, scrolls it by moving its Top, and shows a slim dark
    /// thumb on the right.
    class ScrollHost : Panel
    {
        Control content;
        ScrollThumb thumb;

        public ScrollHost()
        {
            BackColor = Theme.Background;
            thumb = new ScrollThumb(this);
            Controls.Add(thumb);
        }

        public Control Content { get { return content; } }
        public int Offset { get { return content != null ? -content.Top : 0; } }
        public int MaxOffset
        {
            get { return content == null ? 0 : Math.Max(0, content.Height - ClientSize.Height); }
        }

        public void SetContent(Control c)
        {
            if (content != null) Controls.Remove(content);
            content = c;
            c.Location = new Point(0, 0);
            Controls.Add(c);
            thumb.BringToFront();
            Relayout();
        }

        public void ScrollBy(int delta) { ScrollTo(Offset + delta); }

        public void ScrollTo(int offset)
        {
            if (content == null) return;
            offset = Math.Max(0, Math.Min(MaxOffset, offset));
            content.Top = -offset;
            thumb.Reposition();
        }

        public void Relayout()
        {
            if (content == null) return;
            content.Width = ClientSize.Width;
            ScrollTo(Offset);
            thumb.Reposition();
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            Relayout();
        }
    }

    class ScrollThumb : Control
    {
        readonly ScrollHost host;
        bool dragging;
        int dragStartY, dragStartOffset;

        public ScrollThumb(ScrollHost host)
        {
            this.host = host;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer, true);
            BackColor = Theme.Background;
            Cursor = Cursors.Hand;
            Visible = false;
        }

        public void Reposition()
        {
            var viewH = host.ClientSize.Height;
            var contentH = host.Content != null ? host.Content.Height : 0;
            if (contentH <= viewH || viewH <= 0) { Visible = false; return; }
            Visible = true;
            int trackH = viewH - 8;
            int h = Math.Max(28, (int)((double)viewH / contentH * trackH));
            int y = 4 + (int)((double)host.Offset / (contentH - viewH) * (trackH - h));
            SetBounds(host.ClientSize.Width - 9, y, 6, h);
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var b = new SolidBrush(dragging ? Theme.SubText : Theme.Track))
                Draw.FillRounded(e.Graphics, b, new Rectangle(0, 0, Width, Height), Width / 2);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            dragging = true;
            dragStartY = Cursor.Position.Y;
            dragStartOffset = host.Offset;
            Invalidate();
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (!dragging) return;
            var viewH = host.ClientSize.Height;
            var contentH = host.Content != null ? host.Content.Height : 0;
            int trackH = viewH - 8;
            if (contentH <= viewH || trackH - Height <= 0) return;
            var dy = Cursor.Position.Y - dragStartY;
            host.ScrollTo(dragStartOffset + (int)((double)dy * (contentH - viewH) / (trackH - Height)));
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            dragging = false;
            Invalidate();
        }
    }

    // ================================================================== slider

    /// Dark themed value slider (the native TrackBar can't be styled).
    class Slider : DoubleBufferedControl
    {
        public int Minimum = 30;
        public int Maximum = 1800;
        public int Step = 30;
        int value_ = 30;
        bool dragging;
        public event EventHandler ValueChanged;

        public int Value
        {
            get { return value_; }
            set
            {
                var snapped = Math.Max(Minimum, Math.Min(Maximum,
                    Minimum + (int)Math.Round((value - Minimum) / (double)Step) * Step));
                if (snapped == value_) return;
                value_ = snapped;
                Invalidate();
                if (ValueChanged != null) ValueChanged(this, EventArgs.Empty);
            }
        }

        int Pad { get { return Height / 2; } }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            int cy = Height / 2;
            int x0 = Pad, x1 = Width - Pad;
            using (var b = new SolidBrush(Theme.Track))
                Draw.FillRounded(g, b, new Rectangle(x0, cy - 2, x1 - x0, 4), 2);
            double t = (value_ - Minimum) / (double)(Maximum - Minimum);
            int tx = x0 + (int)(t * (x1 - x0));
            using (var b = new SolidBrush(Theme.Accent))
                Draw.FillRounded(g, b, new Rectangle(x0, cy - 2, Math.Max(4, tx - x0), 4), 2);
            var r = dragging ? 8 : 7;
            using (var b = new SolidBrush(Theme.Text)) g.FillEllipse(b, tx - r, cy - r, r * 2, r * 2);
            using (var p = new Pen(Theme.Background, 2)) g.DrawEllipse(p, tx - r, cy - r, r * 2, r * 2);
        }

        void SetFromX(int x)
        {
            double t = (x - Pad) / (double)Math.Max(1, Width - 2 * Pad);
            t = Math.Max(0, Math.Min(1, t));
            Value = Minimum + (int)Math.Round(t * (Maximum - Minimum));
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            dragging = true;
            SetFromX(e.X);
            Invalidate();
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            if (dragging) SetFromX(e.X);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            dragging = false;
            Invalidate();
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

        public TrayContext(string[] args)
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

            // Debug affordance: `QuotaPanelTray --panel [view]` opens the popup
            // pinned (no auto-hide) so tooling can screenshot it; the tray icon
            // is the normal path.
            if (args != null && args.Length > 0 && args[0] == "--panel")
            {
                ShowPanel();
                if (panel != null)
                {
                    panel.Pinned = true;
                    if (args.Length > 1) panel.SelectView(args[1]);
                }
            }
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
            if (daemon == null)
            {
                if (panel != null && !panel.IsDisposed) panel.RefreshDone();
                return;
            }
            try
            {
                var psi = new ProcessStartInfo(daemon, "--once");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                var proc = Process.Start(psi);
                // The FileSystemWatcher picks up the rewritten status.json; the
                // Exited fallback reloads in case a watcher event was missed and
                // clears the panel's "refreshing…" indicator either way.
                if (proc != null)
                {
                    proc.EnableRaisingEvents = true;
                    proc.Exited += delegate
                    {
                        try
                        {
                            syncForm.BeginInvoke((MethodInvoker)delegate
                            {
                                LoadStatus();
                                if (panel != null && !panel.IsDisposed) panel.RefreshDone();
                                proc.Dispose();
                            });
                        }
                        catch (Exception) { }
                    };
                }
            }
            catch (Exception)
            {
                if (panel != null && !panel.IsDisposed) panel.RefreshDone();
            }
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
                // brand glyph (same SVGs as macOS/GNOME); letter disc fallback
                var glyphRect = new RectangleF(3, 0, size - 6, size - 8);
                if (p == null || !SvgIcon.Draw(g, p.Id, glyphRect, Theme.GlyphTint(brand)))
                {
                    using (var brush = new SolidBrush(Theme.GlyphTint(brand)))
                        g.FillEllipse(brush, 1, 0, size - 2, size - 8);
                    using (var f = new Font("Segoe UI", 13, FontStyle.Bold, GraphicsUnit.Pixel))
                    {
                        var text = label.Length > 2 ? label.Substring(0, 2) : label;
                        var sz = g.MeasureString(text, f);
                        g.DrawString(text, f, Brushes.White,
                            (size - sz.Width) / 2f, (size - 8 - sz.Height) / 2f + 1);
                    }
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
        ScrollHost contentHost;
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

            contentHost = new ScrollHost();
            contentHost.Dock = DockStyle.Fill;

            canvas = new ContentCanvas(this);
            contentHost.SetContent(canvas);

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
            refreshing = false;
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
            contentHost.ScrollTo(0);
            RefreshAll();
        }

        bool refreshing;
        public bool Refreshing { get { return refreshing; } }

        /// Debug: opened via `--panel`, so don't hide on focus loss.
        public bool Pinned;

        public void RequestRefresh()
        {
            if (refreshing) return;
            refreshing = true;
            header.Invalidate();
            owner.SpawnDaemon();
        }

        public void RefreshDone()
        {
            refreshing = false;
            header.Invalidate();
        }

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
                contentHost.Relayout();
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
            if (Pinned) return;
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
            if (view == "settings")
            {
                // The Save/Back bar is pinned, but the option list itself
                // must scroll with the wheel too.
                settings.ScrollBy(-Math.Sign(e.Delta) * S(60));
                return;
            }
            contentHost.ScrollBy(-Math.Sign(e.Delta) * S(60));
        }

        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            // Rounded popup corners, Windows 11 style.
            try
            {
                using (var path = Draw.Rounded(new Rectangle(0, 0, Width, Height), S(12)))
                    Region = new Region(path);
            }
            catch (Exception) { }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using (var pen = new Pen(Theme.Track))
            using (var path = Draw.Rounded(new Rectangle(0, 0, Width - 1, Height - 1), S(12)))
                e.Graphics.DrawPath(pen, path);
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
        int contentWidth;
        string hoverId;
        Rectangle leftChevron, rightChevron;
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
            leftChevron = Rectangle.Empty;
            rightChevron = Rectangle.Empty;

            var status = form.Status;
            if (status == null || status.Providers == null)
            {
                TextRenderer.DrawText(g, "Waiting for status.json…", Font,
                    new Point(form.S(14), form.S(24)), Theme.SubText);
                return;
            }

            int disc = form.S(34);
            int cellW = disc + form.S(12);
            int gap = form.S(4);
            int y = form.S(9);
            int x = form.S(14) - scrollX;
            var selected = form.Current;

            foreach (var p in status.Providers)
            {
                if (!form.Cfg.IsEnabled(p.Id)) continue;
                var cell = new Rectangle(x, form.S(4), cellW, Height - form.S(8));
                hits.Add(new KeyValuePair<Rectangle, string>(cell, p.Id));

                var isSelected = selected != null && selected.Id == p.Id;
                if (isSelected || hoverId == p.Id)
                    using (var bg = new SolidBrush(isSelected ? Theme.Card : Theme.CardHover))
                        Draw.FillRounded(g, bg, cell, form.S(10));
                if (isSelected)
                    using (var pen = new Pen(Theme.Brand(p.BrandColor), form.S(2)))
                    using (var outline = Draw.Rounded(cell, form.S(10)))
                        g.DrawPath(pen, outline);

                int dx = x + (cellW - disc) / 2;
                var brand = Theme.Brand(p.BrandColor);
                // real brand glyph (same SVGs as macOS/GNOME), tinted with the
                // brand color; letter disc only when no icon ships
                var glyphRect = new RectangleF(dx + form.S(2), y + form.S(2), disc - form.S(4), disc - form.S(4));
                if (!SvgIcon.Draw(g, p.Id, glyphRect, Theme.GlyphTint(brand)))
                {
                    using (var brush = new SolidBrush(Theme.GlyphTint(brand)))
                        g.FillEllipse(brush, dx, y, disc, disc);
                    using (var f = new Font("Segoe UI", 10f, FontStyle.Bold))
                    {
                        var text = p.ShortLabel;
                        var sz = g.MeasureString(text, f);
                        g.DrawString(text, f, Brushes.White,
                            dx + (disc - sz.Width) / 2f, y + (disc - sz.Height) / 2f);
                    }
                }
                // status dot for problems, with a background ring so it reads
                // as a badge instead of a smudge
                if (p.Status == "authProblem" || p.Status == "error")
                {
                    var badge = new Rectangle(dx + disc - form.S(10), y - form.S(1), form.S(10), form.S(10));
                    using (var ring = new Pen(Theme.Background, form.S(3)))
                        g.DrawEllipse(ring, badge);
                    using (var dot = new SolidBrush(p.Status == "authProblem" ? Theme.Orange : Theme.Red))
                        g.FillEllipse(dot, badge);
                }

                // 5h-session mini bar under the disc
                var barY = y + disc + form.S(5);
                var track = new Rectangle(dx, barY, disc, form.S(4));
                using (var tb = new SolidBrush(Theme.Track)) Draw.FillRounded(g, tb, track, form.S(2));
                var window = p.TrayWindow;
                if (window != null)
                {
                    var w = (int)Math.Round(disc * Math.Min(100, Math.Max(0, window.Percent)) / 100.0);
                    if (w > 0)
                        using (var fill = new SolidBrush(Theme.UsageColor(window.Percent)))
                            Draw.FillRounded(g, fill, new Rectangle(dx, barY, w, form.S(4)), form.S(2));
                }
                x += cellW + gap;
            }
            contentWidth = x + scrollX + form.S(10);

            // edge chevrons when the strip overflows
            int maxScroll = Math.Max(0, contentWidth - Width);
            using (var f = new Font("Segoe UI", 11f, FontStyle.Bold))
            {
                if (scrollX > 0)
                {
                    leftChevron = new Rectangle(0, 0, form.S(18), Height);
                    using (var bg = new SolidBrush(Theme.Background)) g.FillRectangle(bg, leftChevron);
                    TextRenderer.DrawText(g, "‹", f, leftChevron, Theme.SubText,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                }
                if (scrollX < maxScroll)
                {
                    rightChevron = new Rectangle(Width - form.S(18), 0, form.S(18), Height);
                    using (var bg = new SolidBrush(Theme.Background)) g.FillRectangle(bg, rightChevron);
                    TextRenderer.DrawText(g, "›", f, rightChevron, Theme.SubText,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
                }
            }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            string over = null;
            foreach (var h in hits)
                if (h.Key.Contains(e.Location)) { over = h.Value; break; }
            if (over != hoverId) { hoverId = over; Invalidate(); }
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (hoverId != null) { hoverId = null; Invalidate(); }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (leftChevron.Width > 0 && leftChevron.Contains(e.Location)) { ScrollBy(-form.S(88)); return; }
            if (rightChevron.Width > 0 && rightChevron.Contains(e.Location)) { ScrollBy(form.S(88)); return; }
            foreach (var h in hits)
                if (h.Key.Contains(e.Location)) { form.SelectProvider(h.Value); return; }
        }

        public void ScrollBy(int delta)
        {
            int max = Math.Max(0, contentWidth - Width);
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
        int hover;   // 0 none, 1 refresh, 2 gear

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
            int x = form.S(14);

            gearRect = new Rectangle(Width - form.S(42), Height / 2 - form.S(14), form.S(28), form.S(28));
            refreshRect = new Rectangle(Width - form.S(74), Height / 2 - form.S(14), form.S(28), form.S(28));

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
                string sub;
                if (form.Refreshing) sub = "refreshing…";
                else
                {
                    sub = "";
                    if (!string.IsNullOrEmpty(p.Plan)) sub = p.Plan;
                    var ago = Theme.Ago(p.UpdatedAt);
                    if (ago.Length > 0) sub = sub.Length > 0 ? sub + " · " + ago : ago;
                }
                if (sub.Length > 0)
                    TextRenderer.DrawText(g, sub, Font, new Point(x, Height / 2 - form.S(8)),
                        form.Refreshing ? Theme.Accent : Theme.SubText);
            }
            else
            {
                TextRenderer.DrawText(g, form.Refreshing ? "Refreshing…" : "No data yet",
                    Font, new Point(x, Height / 2 - form.S(8)), Theme.SubText);
            }

            PaintButton(g, refreshRect, "↻", hover == 1,
                form.Refreshing ? Theme.Accent : Theme.SubText);
            PaintButton(g, gearRect, "⚙", hover == 2,
                form.View == "settings" ? Theme.Accent : Theme.SubText);

            using (var pen = new Pen(Theme.Card))
                g.DrawLine(pen, form.S(12), Height - 1, Width - form.S(12), Height - 1);
        }

        void PaintButton(Graphics g, Rectangle rect, string glyph, bool hovered, Color color)
        {
            if (hovered)
                using (var bg = new SolidBrush(Theme.CardHover))
                    g.FillEllipse(bg, rect);
            var final = hovered && color == Theme.SubText ? Theme.Text : color;
            using (var f = new Font("Segoe UI", 12f))
                TextRenderer.DrawText(g, glyph, f, rect, final,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            int h = 0;
            if (refreshRect.Contains(e.Location)) h = 1;
            else if (gearRect.Contains(e.Location)) h = 2;
            if (h != hover)
            {
                hover = h;
                Cursor = h != 0 ? Cursors.Hand : Cursors.Default;
                Invalidate();
            }
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (hover != 0) { hover = 0; Cursor = Cursors.Default; Invalidate(); }
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            base.OnMouseUp(e);
            if (refreshRect.Contains(e.Location)) form.RequestRefresh();
            else if (gearRect.Contains(e.Location))
                form.SelectView(form.View == "settings" ? "live" : "settings");
        }
    }

    // =================================================================== tabs

    class TabsControl : DoubleBufferedControl
    {
        readonly PanelForm form;
        string hoverName;
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
            g.SmoothingMode = SmoothingMode.AntiAlias;
            hits.Clear();
            var p = form.Current;
            if (p == null || !p.HasExtras)
            {
                Height = form.S(6);
                return;
            }
            Height = form.S(44);

            // segmented pill control
            string[] names = { "live", "summary", "heatmap" };
            string[] labels = { "Live", "Summary", "Heatmap" };
            var container = new Rectangle(form.S(12), form.S(7), Width - form.S(24), form.S(30));
            using (var bg = new SolidBrush(Theme.Card))
                Draw.FillRounded(g, bg, container, form.S(15));

            int segW = container.Width / names.Length;
            for (int i = 0; i < names.Length; i++)
            {
                var rect = new Rectangle(container.X + i * segW, container.Y, segW, container.Height);
                if (i == names.Length - 1) rect.Width = container.Right - rect.X;
                hits.Add(new KeyValuePair<Rectangle, string>(rect, names[i]));
                bool isActive = form.View == names[i];
                var seg = Rectangle.Inflate(rect, -form.S(3), -form.S(3));
                if (isActive)
                    using (var fill = new SolidBrush(Theme.Track))
                        Draw.FillRounded(g, fill, seg, form.S(12));
                else if (hoverName == names[i])
                    using (var fill = new SolidBrush(Color.FromArgb(70, Theme.Track)))
                        Draw.FillRounded(g, fill, seg, form.S(12));
                using (var f = new Font("Segoe UI", 9f, isActive ? FontStyle.Bold : FontStyle.Regular))
                    TextRenderer.DrawText(g, labels[i], f, rect,
                        isActive ? Theme.Text : Theme.SubText,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            base.OnMouseMove(e);
            string over = null;
            foreach (var h in hits)
                if (h.Key.Contains(e.Location)) { over = h.Value; break; }
            if (over != hoverName)
            {
                hoverName = over;
                Cursor = over != null ? Cursors.Hand : Cursors.Default;
                Invalidate();
            }
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            base.OnMouseLeave(e);
            if (hoverName != null) { hoverName = null; Cursor = Cursors.Default; Invalidate(); }
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
            // Width is owned by the hosting ScrollHost; only measure height.
            using (var g = CreateGraphics())
                contentHeight = Paint_(g, true);
            Height = Math.Max(contentHeight, form.S(80));
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
                var accent = p.Status == "authProblem" ? Theme.Orange : Theme.Red;
                var needed = TextRenderer.MeasureText(msg, Font,
                    new Size(w - form.S(26), 1000), TextFormatFlags.WordBreak).Height;
                var bannerH = Math.Max(form.S(38), needed + form.S(18));
                if (!measureOnly)
                {
                    var rect = new Rectangle(x, y, w, bannerH);
                    using (var bg = new SolidBrush(Theme.Card)) Draw.FillRounded(g, bg, rect, form.S(8));
                    using (var stripe = new SolidBrush(accent))
                        Draw.FillRounded(g, stripe, new Rectangle(x, y, form.S(4), bannerH), form.S(2));
                    TextRenderer.DrawText(g, msg, Font,
                        new Rectangle(x + form.S(16), y + form.S(9), w - form.S(26), bannerH - form.S(18)),
                        accent, TextFormatFlags.Left | TextFormatFlags.WordBreak);
                }
                y += bannerH + form.S(10);
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
                        IsSessionWindow(win, p) ? p.SessionParts : null,
                        Theme.UsageColor(win.Percent), measureOnly);
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
                        c.Percent, c.PartsValue, Theme.ContextColor(c.Percent), measureOnly);
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
        /// input/cache/output segments (scaled to the used fraction) and an
        /// "input x% · cache y% · output z%" legend line is added, like the
        /// GNOME extension's partsCaption. `accent` colors the percent text
        /// and the solid fill.
        int PaintBarRow(Graphics g, int x, int y, int w, string label, string percentText,
                        string rightText, double percent, Parts parts, Color accent, bool measureOnly)
        {
            if (!measureOnly)
            {
                TextRenderer.DrawText(g, label, Font, new Point(x, y), Theme.Text,
                    TextFormatFlags.EndEllipsis);
                using (var f = new Font("Segoe UI", 9f, FontStyle.Bold))
                {
                    var pw = TextRenderer.MeasureText(percentText, f).Width;
                    TextRenderer.DrawText(g, percentText, f, new Point(x + w - pw, y), accent);
                    if (rightText != null)
                    {
                        var rw = TextRenderer.MeasureText(rightText, Font).Width;
                        TextRenderer.DrawText(g, rightText, Font,
                            new Point(x + w - pw - rw - form.S(8), y), Theme.SubText);
                    }
                }
            }
            y += form.S(20);

            if (parts != null && parts.Total > 0)
            {
                // per-part share of the bar's percent, e.g. "cache 19.4%"
                if (!measureOnly)
                {
                    int lx = x;
                    lx = PaintPartLegend(g, lx, y, Theme.PartInput, "input", parts.Input, parts.Total, percent);
                    lx = PaintPartLegend(g, lx, y, Theme.PartCache, "cache", parts.Cache, parts.Total, percent);
                    PaintPartLegend(g, lx, y, Theme.PartOutput, "output", parts.Output, parts.Total, percent);
                }
                y += form.S(17);
            }

            var barRect = new Rectangle(x, y, w, form.S(8));
            if (!measureOnly)
            {
                using (var track = new SolidBrush(Theme.Track)) Draw.FillRounded(g, track, barRect, form.S(4));
                var used = Math.Min(100, Math.Max(0, percent)) / 100.0;
                var usedW = (int)Math.Round(w * used);
                if (usedW > 0)
                {
                    if (parts != null && parts.Total > 0)
                    {
                        // input / cache / output segments within the used width
                        Draw.FillSegments(g,
                            new Rectangle(barRect.X, barRect.Y, usedW, barRect.Height),
                            form.S(4), parts);
                    }
                    else
                    {
                        using (var fill = new SolidBrush(accent))
                            Draw.FillRounded(g, fill, new Rectangle(barRect.X, barRect.Y, usedW, barRect.Height), form.S(4));
                    }
                }
            }
            return y + form.S(18);
        }

        /// One "· input 2.1%" legend entry (colored dot + share of `percent`).
        int PaintPartLegend(Graphics g, int x, int y, Color color, string name,
                            long value, long total, double percent)
        {
            var share = total > 0 ? (double)value / total * percent : 0;
            using (var f = new Font("Segoe UI", 8f))
            {
                var box = new Rectangle(x, y + form.S(4), form.S(8), form.S(8));
                using (var b = new SolidBrush(color)) Draw.FillRounded(g, b, box, form.S(2));
                var tx = x + form.S(11);
                var text = name + " " + Theme.Percent(share);
                TextRenderer.DrawText(g, text, f, new Point(tx, y + form.S(1)), Theme.SubText);
                return tx + TextRenderer.MeasureText(text, f).Width + form.S(10);
            }
        }

        int PaintChart(Graphics g, ProviderStatus p, int x, int y, int w, bool isCost, bool measureOnly)
        {
            // Fixed 14-day window ending today so sparse history renders as a
            // proper timeline instead of one or two panel-wide slabs.
            const int slots = 14;
            var byDay = new Dictionary<string, double>();
            foreach (var d in p.Daily)
            {
                var val = isCost ? d.CostUSD : d.Tokens;
                double cur;
                byDay[d.Day] = (byDay.TryGetValue(d.Day, out cur) ? cur : 0) + val;
            }
            var vals = new double[slots];
            for (int i = 0; i < slots; i++)
            {
                var key = DateTime.Now.Date.AddDays(i - (slots - 1))
                    .ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                double v;
                vals[i] = byDay.TryGetValue(key, out v) ? v : 0;
            }
            double max = 0;
            foreach (var v in vals) max = Math.Max(max, v);

            int chartH = form.S(84);
            int gap = form.S(5);
            int bw = (w - gap * (slots - 1)) / slots;
            if (bw > form.S(20)) bw = form.S(20);
            if (bw < form.S(4)) bw = form.S(4);
            int totalW = bw * slots + gap * (slots - 1);
            int x0 = x + (w - totalW) / 2;

            if (!measureOnly)
            {
                // dotted max reference line + label
                if (max > 0)
                {
                    var label = isCost
                        ? "$" + max.ToString(max >= 10 ? "0" : "0.00", CultureInfo.InvariantCulture)
                        : Theme.Tokens((long)max);
                    using (var f = new Font("Segoe UI", 7f))
                    {
                        var lw = TextRenderer.MeasureText(label, f).Width;
                        TextRenderer.DrawText(g, label, f,
                            new Point(x + w - lw, y - form.S(3)), Theme.SubText);
                        using (var pen = new Pen(Theme.Track))
                        {
                            pen.DashStyle = DashStyle.Dot;
                            g.DrawLine(pen, x0, y + form.S(3), x + w - lw - form.S(6), y + form.S(3));
                        }
                    }
                }
                var barColor = Color.FromArgb(215, Theme.Brand(p.BrandColor));
                int xi = x0;
                for (int i = 0; i < slots; i++)
                {
                    int bh = max > 0 ? (int)Math.Round((chartH - form.S(6)) * vals[i] / max) : 0;
                    if (vals[i] > 0 && bh < form.S(3)) bh = form.S(3);
                    if (bh > 0)
                    {
                        var rect = new Rectangle(xi, y + chartH - bh, bw, bh);
                        using (var b = new SolidBrush(i == slots - 1 ? Theme.Accent : barColor))
                            Draw.FillRounded(g, b, rect, form.S(3));
                    }
                    else
                    {
                        using (var b = new SolidBrush(Theme.Track))
                            g.FillRectangle(b, xi, y + chartH - form.S(2), bw, form.S(2));
                    }
                    xi += bw + gap;
                }
                // x-axis range labels
                using (var f = new Font("Segoe UI", 7f))
                {
                    var from = DateTime.Now.Date.AddDays(-(slots - 1))
                        .ToString("MMM d", CultureInfo.InvariantCulture);
                    TextRenderer.DrawText(g, from, f, new Point(x0, y + chartH + form.S(4)), Theme.SubText);
                    var tw = TextRenderer.MeasureText("today", f).Width;
                    TextRenderer.DrawText(g, "today", f,
                        new Point(x0 + totalW - tw, y + chartH + form.S(4)), Theme.SubText);
                }
            }
            y += chartH + form.S(20);

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
                int cardH = form.S(88);
                if (!measureOnly)
                {
                    var card = new Rectangle(x, y, w, cardH);
                    using (var bg = new SolidBrush(Theme.Card)) Draw.FillRounded(g, bg, card, form.S(10));

                    int ix = x + form.S(14);
                    int iw = w - form.S(28);
                    int iy = y + form.S(12);

                    TextRenderer.DrawText(g, b.Label, Font, new Point(ix, iy), Theme.Text);
                    using (var f = new Font("Segoe UI", 9.5f, FontStyle.Bold))
                    {
                        var t = Theme.Tokens(parts.Total) + " tokens";
                        var tw = TextRenderer.MeasureText(t, f).Width;
                        TextRenderer.DrawText(g, t, f, new Point(ix + iw - tw, iy), Theme.Text);
                    }
                    iy += form.S(24);

                    // composition shares in percent, like the GNOME partsCaption
                    int lx = ix;
                    lx = PaintPartLegend(g, lx, iy, Theme.PartInput, "input", parts.Input, parts.Total, 100);
                    lx = PaintPartLegend(g, lx, iy, Theme.PartCache, "cache", parts.Cache, parts.Total, 100);
                    PaintPartLegend(g, lx, iy, Theme.PartOutput, "output", parts.Output, parts.Total, 100);
                    iy += form.S(20);

                    // full-width composition bar (GNOME summary parity)
                    var track = new Rectangle(ix, iy, iw, form.S(8));
                    using (var tb = new SolidBrush(Theme.Track)) Draw.FillRounded(g, tb, track, form.S(4));
                    if (parts.Total > 0)
                        Draw.FillSegments(g, track, form.S(4), parts);
                }
                y += cardH + form.S(10);
            }
            return y + form.S(6);
        }

        // ---- heatmap ------------------------------------------------------------

        int PaintHeatmap(Graphics g, ProviderStatus p, int x, int y, int w, bool measureOnly)
        {
            var h = p.HeatmapValue;
            if (!measureOnly)
            {
                using (var f = new Font("Segoe UI", 9.5f, FontStyle.Bold))
                    TextRenderer.DrawText(g, Theme.Tokens(h.TotalTokens) + " tokens", f,
                        new Point(x, y), Theme.Text);
                var sub = "last 12 weeks";
                var sw = TextRenderer.MeasureText(sub, Font).Width;
                TextRenderer.DrawText(g, sub, Font, new Point(x + w - sw, y + form.S(1)), Theme.SubText);
            }
            y += form.S(28);

            int labelW = form.S(30);

            // daily grid: columns = weeks, rows = Mon...Sun
            int cols = h.DailyGrid != null ? h.DailyGrid.Count : 0;
            if (cols > 0)
            {
                int gap = form.S(3);
                int cell = (w - labelW - gap * (cols - 1)) / cols;
                if (cell > form.S(16)) cell = form.S(16);
                if (cell < form.S(6)) cell = form.S(6);
                string[] dayLabels = { "Mon", "", "Wed", "", "Fri", "", "Sun" };
                if (!measureOnly)
                {
                    using (var f = new Font("Segoe UI", 7f))
                        for (int r = 0; r < 7; r++)
                            if (dayLabels[r].Length > 0)
                                TextRenderer.DrawText(g, dayLabels[r], f,
                                    new Point(x, y + r * (cell + gap) + Math.Max(0, (cell - form.S(11)) / 2)),
                                    Theme.SubText);
                    for (int c = 0; c < cols; c++)
                    {
                        var column = h.DailyGrid[c];
                        for (int r = 0; r < 7 && r < column.Count; r++)
                        {
                            var cellV = column[r];
                            if (cellV == null) continue;  // future day
                            var rect = new Rectangle(x + labelW + c * (cell + gap), y + r * (cell + gap), cell, cell);
                            var lvl = Math.Max(0, Math.Min(4, cellV.Level));
                            using (var b = new SolidBrush(Theme.Heat[lvl]))
                                Draw.FillRounded(g, b, rect, form.S(3));
                        }
                    }
                }
                y += 7 * (cell + gap) + form.S(6);

                // Less … More legend, GitHub style
                if (!measureOnly)
                {
                    using (var f = new Font("Segoe UI", 7f))
                    {
                        int box = form.S(10);
                        int lgap = form.S(3);
                        var lessW = TextRenderer.MeasureText("Less", f).Width;
                        var moreW = TextRenderer.MeasureText("More", f).Width;
                        int lx = x + w - moreW - 5 * box - 4 * lgap - lessW - form.S(12);
                        TextRenderer.DrawText(g, "Less", f, new Point(lx, y + form.S(1)), Theme.SubText);
                        lx += lessW + form.S(4);
                        for (int i = 0; i < 5; i++)
                        {
                            using (var b = new SolidBrush(Theme.Heat[i]))
                                Draw.FillRounded(g, b, new Rectangle(lx, y + form.S(2), box, box), form.S(2));
                            lx += box + lgap;
                        }
                        TextRenderer.DrawText(g, "More", f, new Point(lx + form.S(2), y + form.S(1)), Theme.SubText);
                    }
                }
                y += form.S(26);
            }

            // hour-of-day punch card
            if (h.HourRows != null && h.HourRows.Count > 0)
            {
                y = PaintSectionTitle(g, x, y, "BY HOUR — LAST 7 DAYS", measureOnly);
                int gap = form.S(3);
                int cell = (w - labelW - gap * 23) / 24;
                if (cell > form.S(12)) cell = form.S(12);
                if (cell < form.S(5)) cell = form.S(5);
                if (!measureOnly)
                {
                    using (var f = new Font("Segoe UI", 7f))
                    {
                        int[] ticks = { 0, 6, 12, 18 };
                        foreach (var t in ticks)
                            TextRenderer.DrawText(g, t.ToString(CultureInfo.InvariantCulture), f,
                                new Point(x + labelW + t * (cell + gap), y), Theme.SubText);
                    }
                }
                y += form.S(14);
                if (!measureOnly)
                {
                    using (var f = new Font("Segoe UI", 7f))
                    {
                        int r = 0;
                        foreach (var row in h.HourRows)
                        {
                            TextRenderer.DrawText(g, row.Day, f,
                                new Point(x, y + r * (cell + gap) + Math.Max(0, (cell - form.S(11)) / 2)),
                                Theme.SubText);
                            for (int c = 0; c < 24 && c < row.Cells.Count; c++)
                            {
                                var cellV = row.Cells[c];
                                if (cellV == null) continue;
                                var lvl = Math.Max(0, Math.Min(4, cellV.Level));
                                var rect = new Rectangle(x + labelW + c * (cell + gap), y + r * (cell + gap), cell, cell);
                                using (var b = new SolidBrush(Theme.Heat[lvl]))
                                    Draw.FillRounded(g, b, rect, form.S(2));
                            }
                            r++;
                        }
                    }
                }
                y += h.HourRows.Count * (cell + gap) + form.S(8);
            }
            return y + form.S(12);
        }
    }

    // =============================================================== settings

    class SettingsPanel : Panel
    {
        readonly PanelForm form;
        ScrollHost scroll;     // scrollable options (dark slim thumb, no native bars)
        Panel bottomBar;       // pinned Save/Back, always reachable
        Button saveButton;
        Dictionary<string, CheckBox> checks = new Dictionary<string, CheckBox>();
        Slider refreshSlider;
        Label refreshValue;
        TextBox thresholdsBox;
        ToolTip tips = new ToolTip();
        Config current;

        public SettingsPanel(PanelForm form)
        {
            this.form = form;
            BackColor = Theme.Background;

            scroll = new ScrollHost();
            scroll.Dock = DockStyle.Fill;

            bottomBar = new Panel();
            bottomBar.Dock = DockStyle.Bottom;
            bottomBar.Height = form.S(54);
            bottomBar.BackColor = Theme.Card;

            var back = DialogStyle.MakeButton("‹ Back", false);
            back.Size = new Size(form.S(90), form.S(32));
            back.Location = new Point(form.S(14), form.S(11));
            back.TabStop = false;
            back.Click += delegate { form.SelectView("live"); };

            saveButton = DialogStyle.MakeButton("Save", true);
            saveButton.Size = new Size(form.S(110), form.S(32));
            saveButton.TabStop = false;
            saveButton.Click += delegate { OnSave(); };

            bottomBar.Controls.Add(saveButton);
            bottomBar.Controls.Add(back);
            bottomBar.Resize += delegate
            {
                saveButton.Location = new Point(bottomBar.Width - saveButton.Width - form.S(14), form.S(11));
            };

            Controls.Add(scroll);
            Controls.Add(bottomBar);
        }

        public void LoadFrom(Config c)
        {
            current = c;
            checks.Clear();
            var body = new Panel();
            body.BackColor = Theme.Background;

            int margin = form.S(14);
            int y = form.S(12);
            int innerW = form.ClientSize.Width - margin * 2 - form.S(10);

            // --- providers, with a detection dot per row ----------------------
            body.Controls.Add(MakeLabel("PROVIDERS", margin, y, true));
            y += form.S(24);
            int colW = innerW / 2;
            int i = 0;
            foreach (var info in Catalog.Supported)
            {
                int rx = margin + (i % 2) * colW;
                int ry = y + (i / 2) * form.S(28);

                var dot = new Label();
                dot.Text = "●";
                dot.AutoSize = true;
                dot.Font = new Font("Segoe UI", 8f);
                dot.BackColor = Theme.Background;
                string tipText;
                dot.ForeColor = DetectionColor(info.Id, out tipText);
                dot.Location = new Point(rx, ry + form.S(3));
                tips.SetToolTip(dot, info.Name + ": " + tipText);
                body.Controls.Add(dot);

                var cb = new CheckBox();
                cb.Text = info.Name;
                cb.ForeColor = Theme.Text;
                cb.BackColor = Theme.Background;
                cb.Location = new Point(rx + form.S(18), ry);
                cb.Width = colW - form.S(24);
                cb.Checked = c.IsEnabled(info.Id);
                checks[info.Id] = cb;
                body.Controls.Add(cb);
                i++;
            }
            y += ((Catalog.Supported.Length + 1) / 2) * form.S(28) + form.S(6);
            var legend = MakeLabel("Dots: green data · orange sign-in needed · red error", margin, y, false);
            body.Controls.Add(legend);
            y += form.S(28);

            // --- accounts (in-app sign-in, like the macOS Settings) ----------
            body.Controls.Add(MakeLabel("ACCOUNTS", margin, y, true));
            y += form.S(24);
            y = AddAccountRow(body, "claude", "Claude Code", margin, innerW, y);
            y = AddAccountRow(body, "codex", "Codex", margin, innerW, y);
            y = AddAccountRow(body, "gemini", "Gemini", margin, innerW, y);
            y = AddAccountRow(body, "copilot", "Copilot", margin, innerW, y);
            y = AddAccountRow(body, "antigravity", "Antigravity", margin, innerW, y);
            y += form.S(10);

            // --- refresh interval slider -------------------------------------
            body.Controls.Add(MakeLabel("REFRESH INTERVAL", margin, y, true));
            refreshValue = new Label();
            refreshValue.AutoSize = true;
            refreshValue.Font = new Font("Segoe UI", 8.5f, FontStyle.Bold);
            refreshValue.ForeColor = Theme.Accent;
            refreshValue.BackColor = Theme.Background;
            refreshValue.Text = IntervalText(c.RefreshSeconds);
            refreshValue.Location = new Point(margin + innerW - form.S(60), y - form.S(2));
            body.Controls.Add(refreshValue);
            y += form.S(22);

            refreshSlider = new Slider();
            refreshSlider.Minimum = 30;
            refreshSlider.Maximum = 1800;
            refreshSlider.Step = 30;
            refreshSlider.Value = Math.Max(30, Math.Min(1800, c.RefreshSeconds));
            refreshSlider.SetBounds(margin, y, innerW, form.S(26));
            refreshSlider.ValueChanged += delegate
            {
                refreshValue.Text = IntervalText(refreshSlider.Value);
                refreshValue.Left = margin + innerW - refreshValue.Width;
            };
            body.Controls.Add(refreshSlider);
            y += form.S(36);

            // --- alert thresholds --------------------------------------------
            body.Controls.Add(MakeLabel("ALERT THRESHOLDS (%)", margin, y, true));
            y += form.S(24);
            var boxHost = new Panel();
            boxHost.BackColor = Theme.Card;
            boxHost.SetBounds(margin, y, form.S(220), form.S(28));
            thresholdsBox = new TextBox();
            thresholdsBox.Text = string.Join(", ", current.AlertThresholds
                .Select(t => t.ToString(CultureInfo.InvariantCulture)).ToArray());
            thresholdsBox.BorderStyle = BorderStyle.None;
            thresholdsBox.BackColor = Theme.Card;
            thresholdsBox.ForeColor = Theme.Text;
            thresholdsBox.SetBounds(form.S(8), form.S(6), form.S(204), form.S(18));
            boxHost.Controls.Add(thresholdsBox);
            body.Controls.Add(boxHost);
            y += form.S(34);

            body.Controls.Add(MakeLabel("Comma-separated · empty disables · max 6", margin, y, false));
            y += form.S(30);

            body.Height = y;
            scroll.SetContent(body);
            scroll.ScrollTo(0);
            HookWheel(body);
        }

        // --- accounts row ----------------------------------------------------

        int AddAccountRow(Panel body, string id, string name, int margin, int innerW, int y)
        {
            var card = new Panel();
            card.BackColor = Theme.Card;
            card.SetBounds(margin, y, innerW, form.S(44));

            var glyph = new AccountGlyph(id);
            glyph.SetBounds(form.S(10), form.S(11), form.S(22), form.S(22));
            card.Controls.Add(glyph);

            var title = new Label();
            title.Text = name;
            title.AutoSize = true;
            title.Font = new Font("Segoe UI", 9f, FontStyle.Bold);
            title.ForeColor = Theme.Text;
            title.BackColor = Theme.Card;
            title.Location = new Point(form.S(40), form.S(5));
            card.Controls.Add(title);

            var state = new Label();
            state.AutoSize = true;
            state.Font = new Font("Segoe UI", 8f);
            state.BackColor = Theme.Card;
            bool inApp;
            state.Text = AccountState(id, out inApp);
            state.ForeColor = inApp ? Theme.Green : Theme.SubText;
            state.Location = new Point(form.S(40), form.S(23));
            card.Controls.Add(state);

            var button = DialogStyle.MakeButton(inApp ? "Sign out" : "Sign in…", !inApp);
            button.Size = new Size(form.S(84), form.S(28));
            button.Location = new Point(innerW - form.S(94), form.S(8));
            button.TabStop = false;
            button.Click += delegate
            {
                if (CredStore.Has(id))
                {
                    CredStore.Delete(id);
                    LoadFrom(current);       // rebuild rows
                    form.RequestRefresh();
                    return;
                }
                string err;
                if (id == "claude") err = OAuthFlows.SignInClaude(form);
                else if (id == "codex") err = OAuthFlows.SignInCodex(form);
                else if (id == "gemini") err = OAuthFlows.SignInGemini(form);
                else if (id == "copilot") err = OAuthFlows.SignInCopilot(form);
                else err = OAuthFlows.SignInAntigravity(form);
                if (err == null)
                {
                    LoadFrom(current);
                    form.RequestRefresh();
                }
                else if (err.Length > 0)
                {
                    MessageBox.Show(form, err, "Sign-in failed",
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            };
            card.Controls.Add(button);

            body.Controls.Add(card);
            return y + form.S(52);
        }

        string AccountState(string id, out bool inApp)
        {
            inApp = CredStore.Has(id);
            if (inApp) return "Signed in via QuotaPanel";
            var home = CredStore.Home;
            var via = "Using the " + id + " CLI's sign-in";
            var candidates = new List<string>();
            if (id == "claude") candidates.Add(Path.Combine(home, ".claude", ".credentials.json"));
            else if (id == "codex") candidates.Add(Path.Combine(home, ".codex", "auth.json"));
            else if (id == "gemini") candidates.Add(Path.Combine(home, ".gemini", "oauth_creds.json"));
            else if (id == "copilot")
            {
                // Same locations the daemon's CopilotProvider probes
                via = "Using the editor's GitHub sign-in";
                var dirs = new string[]
                {
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    Path.Combine(home, ".config"),
                };
                foreach (var dir in dirs)
                {
                    if (string.IsNullOrEmpty(dir)) continue;
                    candidates.Add(Path.Combine(dir, "github-copilot", "apps.json"));
                    candidates.Add(Path.Combine(dir, "github-copilot", "hosts.json"));
                }
            }
            else if (id == "antigravity")
            {
                via = "Using local Google credentials";
                candidates.Add(Path.Combine(home, ".quotapanel", "antigravity", "oauth_creds.json"));
            }
            try
            {
                foreach (var file in candidates)
                    if (File.Exists(file)) return via;
            }
            catch (Exception) { }
            return "Signed out";
        }

        Color DetectionColor(string id, out string tip)
        {
            var status = form.Status;
            var p = status != null ? status.Find(id) : null;
            if (p == null) { tip = "no data yet"; return Theme.Track; }
            if (p.Status == "ok") { tip = "detected — data OK"; return Theme.Green; }
            if (p.Status == "authProblem")
            {
                tip = p.Message != null ? p.Message : "needs sign-in";
                return Theme.Orange;
            }
            if (p.Status == "error")
            {
                tip = p.Message != null ? p.Message : "error";
                return Theme.Red;
            }
            tip = "loading…";
            return Theme.SubText;
        }

        // Wheel events land on whichever child is focused; route them all to
        // the scroll host so the option list actually scrolls.
        void HookWheel(Control root)
        {
            foreach (Control ch in root.Controls)
            {
                if (ch is TextBox || ch is Slider) continue;  // keep native wheel/drag
                ch.MouseWheel += OnChildWheel;
                HookWheel(ch);
            }
        }

        void OnChildWheel(object sender, MouseEventArgs e)
        {
            var he = e as HandledMouseEventArgs;
            if (he != null) he.Handled = true;
            ScrollBy(-Math.Sign(e.Delta) * form.S(60));
        }

        public void ScrollBy(int delta) { scroll.ScrollBy(delta); }

        static string IntervalText(int seconds)
        {
            if (seconds % 60 == 0) return (seconds / 60) + " min";
            return (seconds / 60.0).ToString("0.#", CultureInfo.InvariantCulture) + " min";
        }

        Label MakeLabel(string text, int x, int y, bool isSection)
        {
            var l = new Label();
            l.Text = text;
            l.AutoSize = true;
            l.Location = new Point(x, y);
            l.ForeColor = Theme.SubText;
            l.BackColor = Theme.Background;
            l.Font = new Font("Segoe UI", isSection ? 7.5f : 8f, isSection ? FontStyle.Bold : FontStyle.Regular);
            return l;
        }

        void OnSave()
        {
            if (current == null) return;
            var enabled = new List<string>();
            foreach (var pair in checks)
                if (pair.Value.Checked) enabled.Add(pair.Key);
            // all checked = null (daemon default "all supported")
            current.EnabledProviders = enabled.Count == Catalog.Supported.Length ? null : enabled;
            current.RefreshSeconds = refreshSlider.Value;

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
            current.AlertThresholds = thresholds;

            form.ApplySettings(current);
        }
    }

    /// Small brand glyph for the account rows (SVG if available, letter disc
    /// fallback).
    class AccountGlyph : DoubleBufferedControl
    {
        readonly string id;

        public AccountGlyph(string id)
        {
            this.id = id;
            BackColor = Theme.Card;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var info = Catalog.Find(id);
            var brand = Theme.GlyphTint(Theme.Brand(info != null ? info.ColorHex : "#888888"));
            if (!SvgIcon.Draw(g, id, new RectangleF(0, 0, Width, Height), brand))
            {
                using (var b = new SolidBrush(brand)) g.FillEllipse(b, 0, 0, Width - 1, Height - 1);
                using (var f = new Font("Segoe UI", 8f, FontStyle.Bold))
                    TextRenderer.DrawText(g, info != null ? info.ShortLabel : "?", f,
                        new Rectangle(0, 0, Width, Height), Color.White,
                        TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
        }
    }
}
