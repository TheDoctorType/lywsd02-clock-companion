// Vulcan.Core - compiled core for the LYWSD02 / Aranet4 tray widget.
//
// Everything that used to be slow in PowerShell lives here:
//   * Data   - both CSV histories held in memory as primitive arrays (loaded once,
//              appended live) instead of Import-Csv on every refresh.
//   * Model  - the room inference (outdoor baseline, ventilation, occupancy,
//              pressure tendency) as plain numeric code that can be unit-tested.
//   * Gfx    - drawing primitives used by the PowerShell painters.
//   * controls (cards, toggle, segmented selector, pill button, breathing orb).
//
// C# 5 only: this is compiled by the .NET Framework compiler that ships with
// Windows PowerShell 5.1 (no string interpolation, no out-var, no "?." etc).
using System;
using System.IO;
using System.Text;
using System.Globalization;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;
using System.Runtime.InteropServices;
using DV = System.Windows.Forms.DataVisualization.Charting;

namespace Vulcan {

// ---------------------------------------------------------------------------
//  Data
// ---------------------------------------------------------------------------
public sealed class XY {
    public double[] X; public double[] Y; public bool[] Break;
    public int Count { get { return X == null ? 0 : X.Length; } }
}

/// <summary>A time-ordered table of samples: one DateTime column + N double columns.</summary>
public sealed class Table {
    public readonly int Cols;
    DateTime[] t; double[][] c; int n;

    public Table(int cols) {
        Cols = cols; t = new DateTime[4096]; c = new double[cols][];
        for (int i = 0; i < cols; i++) c[i] = new double[4096];
    }
    public int Count { get { return n; } }
    public DateTime Time(int i) { return t[i]; }
    public double Val(int col, int i) { return c[col][i]; }
    public DateTime LastTime { get { return n > 0 ? t[n - 1] : DateTime.MinValue; } }
    public double Last(int col) { return n > 0 ? c[col][n - 1] : double.NaN; }
    public void Clear() { n = 0; }

    public void Add(DateTime when, double[] vals) {
        if (n == t.Length) {
            int cap = n * 2;
            Array.Resize(ref t, cap);
            for (int k = 0; k < Cols; k++) Array.Resize(ref c[k], cap);
        }
        int pos = n;
        if (n > 0 && when < t[n - 1]) {           // out-of-order row (clock change): keep sorted
            pos = LowerBound(when);
            Array.Copy(t, pos, t, pos + 1, n - pos);
            for (int k = 0; k < Cols; k++) Array.Copy(c[k], pos, c[k], pos + 1, n - pos);
        }
        t[pos] = when;
        for (int k = 0; k < Cols; k++) c[k][pos] = (vals != null && k < vals.Length) ? vals[k] : double.NaN;
        n++;
    }
    /// <summary>First index whose time is >= x (n if none).</summary>
    public int LowerBound(DateTime x) {
        int lo = 0, hi = n;
        while (lo < hi) { int m = (lo + hi) >> 1; if (t[m] < x) lo = m + 1; else hi = m; }
        return lo;
    }
    /// <summary>Index of the last sample at or before x (-1 if none).</summary>
    public int IndexAtOrBefore(DateTime x) { return LowerBound(x.AddTicks(1)) - 1; }

    /// <summary>Value of the sample nearest in time to 'when', or NaN if none within tolMin minutes.</summary>
    public double ValueNear(int col, DateTime when, double tolMin) {
        if (n == 0) return double.NaN;
        int i = LowerBound(when); int best = -1; double bd = double.MaxValue;
        for (int j = i - 1; j <= i; j++) {
            if (j < 0 || j >= n) continue;
            double d = Math.Abs((t[j] - when).TotalMinutes);
            if (d < bd && !double.IsNaN(c[col][j])) { bd = d; best = j; }
        }
        return (best >= 0 && bd <= tolMin) ? c[col][best] : double.NaN;
    }

    /// <summary>Bucket means over [from,to] for a sparkline (time-linear, gaps interpolated).</summary>
    public double[] Spark(int col, DateTime from, DateTime to, int buckets) {
        int i0 = LowerBound(from), i1 = LowerBound(to.AddTicks(1));
        if (i1 - i0 < 2 || buckets < 2) return new double[0];
        double span = (to - from).TotalSeconds; if (span <= 0) return new double[0];
        double[] sum = new double[buckets]; int[] cnt = new int[buckets];
        for (int i = i0; i < i1; i++) {
            double v = c[col][i]; if (double.IsNaN(v)) continue;
            int b = (int)((t[i] - from).TotalSeconds / span * buckets);
            if (b < 0) b = 0; if (b >= buckets) b = buckets - 1;
            sum[b] += v; cnt[b]++;
        }
        int first = -1, last = -1;
        for (int b = 0; b < buckets; b++) if (cnt[b] > 0) { if (first < 0) first = b; last = b; }
        if (first < 0 || last == first) return new double[0];
        double[] o = new double[last - first + 1];
        int prev = first;
        for (int b = first; b <= last; b++) {
            if (cnt[b] > 0) {
                double v = sum[b] / cnt[b]; o[b - first] = v;
                for (int k = prev + 1; k < b; k++) {      // fill the gap linearly
                    double f = (double)(k - prev) / (b - prev);
                    o[k - first] = o[prev - first] + (v - o[prev - first]) * f;
                }
                prev = b;
            }
        }
        return o;
    }

    void Gather(int col, DateTime from, DateTime to, List<double> xs, List<double> ys) {
        int i0 = LowerBound(from), i1 = LowerBound(to.AddTicks(1));
        for (int i = i0; i < i1; i++) {
            double v = c[col][i]; if (double.IsNaN(v)) continue;
            xs.Add(t[i].ToOADate()); ys.Add(v);
        }
    }
    // Largest-triangle-three-buckets: thin to 'budget' points, keeping real samples and the visual shape.
    static void Lttb(List<double> xs, List<double> ys, int budget, List<int> pick) {
        int count = xs.Count;
        if (count <= budget || budget < 3) { for (int i = 0; i < count; i++) pick.Add(i); return; }
        double every = (double)(count - 2) / (budget - 2);
        int a = 0; pick.Add(0);
        for (int i = 0; i < budget - 2; i++) {
            int as0 = (int)Math.Floor((i + 1) * every) + 1, ae = (int)Math.Floor((i + 2) * every) + 1;
            if (ae > count) ae = count;
            double ax = 0, ay = 0; int len = ae - as0;
            for (int j = as0; j < ae; j++) { ax += xs[j]; ay += ys[j]; }
            if (len > 0) { ax /= len; ay /= len; } else { ax = xs[count - 1]; ay = ys[count - 1]; }
            int rs = (int)Math.Floor(i * every) + 1, re = (int)Math.Floor((i + 1) * every) + 1;
            double maxArea = -1; int next = rs;
            for (int j = rs; j < re; j++) {
                double area = Math.Abs((xs[a] - ax) * (ys[j] - ys[a]) - (xs[a] - xs[j]) * (ay - ys[a]));
                if (area > maxArea) { maxArea = area; next = j; }
            }
            pick.Add(next); a = next;
        }
        pick.Add(count - 1);
    }
    void Part(int col, DateTime from, DateTime to, int budget, double gapDays, List<double> ox, List<double> oy, List<bool> ob) {
        List<double> xs = new List<double>(), ys = new List<double>(); List<int> pick = new List<int>();
        Gather(col, from, to, xs, ys); if (xs.Count == 0) return;
        Lttb(xs, ys, budget, pick);
        int[] gaps = new int[xs.Count];            // running count of real outages in the source data
        for (int i = 1; i < xs.Count; i++) gaps[i] = gaps[i - 1] + ((xs[i] - xs[i - 1]) > gapDays ? 1 : 0);
        for (int j = 0; j < pick.Count; j++) {
            int i = pick[j];
            bool brk = j == 0 ? (ox.Count > 0 && xs[i] - ox[ox.Count - 1] > gapDays) : gaps[i] != gaps[pick[j - 1]];
            ox.Add(xs[i]); oy.Add(ys[i]); ob.Add(brk);
        }
    }
    /// <summary>
    /// Points for a chart over [from,to], thinned to about 'budget' real samples.
    /// Inside [focusFrom,focusTo] the full budget is spent again, so a zoomed view
    /// gets full detail. Break[i] marks a real outage (longer than gapDays) before
    /// point i, so the line can be broken there and nowhere else.
    /// </summary>
    public XY Sample(int col, DateTime from, DateTime to, int budget, DateTime focusFrom, DateTime focusTo, double gapDays) {
        List<double> ox = new List<double>(), oy = new List<double>(); List<bool> ob = new List<bool>();
        bool focus = focusTo > focusFrom && (focusFrom > from.AddSeconds(1) || focusTo < to.AddSeconds(-1));
        if (!focus) Part(col, from, to, budget, gapDays, ox, oy, ob);
        else {
            if (focusFrom < from) focusFrom = from; if (focusTo > to) focusTo = to;
            Part(col, from, focusFrom.AddTicks(-1), Math.Max(3, budget / 4), gapDays, ox, oy, ob);
            Part(col, focusFrom, focusTo, budget, gapDays, ox, oy, ob);
            Part(col, focusTo.AddTicks(1), to, Math.Max(3, budget / 4), gapDays, ox, oy, ob);
        }
        XY r = new XY(); r.X = ox.ToArray(); r.Y = oy.ToArray(); r.Break = ob.ToArray(); return r;
    }
}

/// <summary>The two device histories. Columns are fixed (see the constants).</summary>
public static class Data {
    // Clock (LYWSD02) columns
    public const int CTemp = 0, CHum = 1, CBatt = 2, CDew = 3;
    // Air (Aranet4) columns
    public const int ACo2 = 0, ATemp = 1, AHum = 2, APres = 3, ABatt = 4;

    public static readonly Table Clock = new Table(4);
    public static readonly Table Air = new Table(5);
    public static string LastError = "";
    static string clockPath, airPath;
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);

    static bool ParseTime(string s, out DateTime d) {
        if (DateTime.TryParseExact(s, "yyyy-MM-dd HH:mm:ss", Inv, DateTimeStyles.None, out d)) return true;
        return DateTime.TryParse(s, Inv, DateTimeStyles.None, out d) || DateTime.TryParse(s, out d);
    }
    static double Num(string[] p, int i) {
        if (i >= p.Length) return double.NaN;
        double v; return double.TryParse(p[i], NumberStyles.Float, Inv, out v) ? v : double.NaN;
    }
    /// <summary>Load both CSV histories into memory. Returns the number of rows read.</summary>
    public static int Load(string clockCsv, string airCsv) {
        clockPath = clockCsv; airPath = airCsv; Clock.Clear(); Air.Clear(); LastError = "";
        int rows = 0;
        try {
            if (File.Exists(clockCsv)) foreach (string line in ReadShared(clockCsv)) {
                string[] p = line.Split(','); DateTime d;
                if (p.Length < 4 || !ParseTime(p[0], out d)) continue;
                double tc = Num(p, 1), hu = Num(p, 3);
                if (double.IsNaN(tc)) continue;
                Clock.Add(d, new double[] { tc, hu, Num(p, 4), Model.DewPoint(tc, hu) }); rows++;
            }
        } catch (Exception e) { LastError = "clock csv: " + e.Message; }
        try {
            if (File.Exists(airCsv)) foreach (string line in ReadShared(airCsv)) {
                string[] p = line.Split(','); DateTime d;
                if (p.Length < 5 || !ParseTime(p[0], out d)) continue;
                double co2 = Num(p, 1);
                if (double.IsNaN(co2)) continue;
                Air.Add(d, new double[] { co2, Num(p, 2), Num(p, 3), Num(p, 4), Num(p, 5) }); rows++;
            }
        } catch (Exception e) { LastError = "air csv: " + e.Message; }
        Model.Reset();
        return rows;
    }
    static IEnumerable<string> ReadShared(string path) {
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (StreamReader sr = new StreamReader(fs, Encoding.UTF8, true, 1 << 16)) {
            string line; while ((line = sr.ReadLine()) != null) yield return line;
        }
    }
    static string F(double v, string fmt) { return double.IsNaN(v) ? "" : v.ToString(fmt, Inv); }
    static void Append(string path, string header, string row) {
        try {
            if (!File.Exists(path)) File.WriteAllText(path, header + "\r\n", new UTF8Encoding(true));
            File.AppendAllText(path, row + "\r\n", Utf8);
        } catch (Exception e) { LastError = "append: " + e.Message; }
    }
    public static void AddClock(DateTime when, double tempC, double hum, double batt, bool write) {
        Clock.Add(when, new double[] { tempC, hum, batt, Model.DewPoint(tempC, hum) });
        if (write && clockPath != null)
            Append(clockPath, "timestamp,tempC,tempF,humidity,battery",
                when.ToString("yyyy-MM-dd HH:mm:ss", Inv) + "," + F(tempC, "0.##") + "," + F(Math.Round(tempC * 9 / 5 + 32, 1), "0.#") + "," + F(hum, "0") + "," + F(batt, "0"));
    }
    public static void AddAir(DateTime when, double co2, double tempC, double hum, double pres, double batt, string status, bool write) {
        Air.Add(when, new double[] { co2, tempC, hum, pres, batt });
        if (write && airPath != null)
            Append(airPath, "timestamp,co2,tempC,humidity,pressure,battery,status",
                when.ToString("yyyy-MM-dd HH:mm:ss", Inv) + "," + F(co2, "0") + "," + F(tempC, "0.#") + "," + F(hum, "0") + "," + F(pres, "0.#") + "," + F(batt, "0") + "," + (status ?? ""));
    }
}

public static class Files {
    /// <summary>Keep a log from growing without bound: when it passes maxBytes, keep only its last keepBytes.</summary>
    public static bool TrimLog(string path, long maxBytes, int keepBytes) {
        try {
            FileInfo fi = new FileInfo(path);
            if (!fi.Exists || fi.Length <= maxBytes) return false;
            byte[] buf = new byte[keepBytes];
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
                fs.Seek(-keepBytes, SeekOrigin.End);
                int got = 0; while (got < keepBytes) { int r = fs.Read(buf, got, keepBytes - got); if (r <= 0) break; got += r; }
            }
            int start = Array.IndexOf(buf, (byte)'\n'); start = start < 0 ? 0 : start + 1;
            string tmp = path + ".tmp";
            using (FileStream o = new FileStream(tmp, FileMode.Create, FileAccess.Write)) o.Write(buf, start, buf.Length - start);
            File.Copy(tmp, path, true); File.Delete(tmp);
            return true;
        } catch { return false; }
    }
}

// ---------------------------------------------------------------------------
//  Model - what the readings imply about the room
// ---------------------------------------------------------------------------
/// <summary>One CO2 decay (a peak falling to a trough) and the air-change rate fitted to it.</summary>
public sealed class Decay {
    public DateTime Start, End;     // End = the trough (or the latest sample if still falling)
    public double K;                // air changes per hour
    public double R2, Css, Drop, Hours, Quality;
    public int N;
    public bool Free;               // true: asymptote fitted (room still occupied), false: asymptote = outdoor
    public bool Ongoing;            // still falling at the end of the data (no rise has ended it yet)
}

public sealed class RoomState {
    public DateTime Now;
    public double Baseline = 420;              // estimated outdoor CO2 as this sensor reads it (ppm)
    public double Co2 = double.NaN, Co2AgeMin = double.NaN, Co2Slope = double.NaN;   // slope in ppm/hour
    // ventilation
    public bool AchLive;                       // a decay is in progress or ended in the last 30 minutes
    public double AchLiveK = double.NaN, AchLiveR2 = double.NaN; public bool AchLiveOccupied;
    public double AchLast = double.NaN, AchLastAgeMin = double.NaN;   // most recent measured decay (12 h)
    public double AchTypical = double.NaN; public int AchHistory;     // median over 30 days, and how many decays
    public double AchClosed = Model.DefaultAch;                       // lower quartile: the room with windows shut
    public double AchUsed = Model.DefaultAch; public string AchSource = "assumed";
    public double FreshenMin = double.NaN;     // minutes to fall back to 800 ppm at AchUsed with the room empty
    // occupancy
    public double OccN = double.NaN; public int OccLevel = -1; public bool OccLowSignal;
    public bool OccHeld;                       // airing in progress: the count from just before it is held
    // pressure tendency (hPa per 3 hours, signed); NaN when there is under an hour of data
    public double PresRate3h = double.NaN;
    // today's timeline: x = fraction of the day, CO2, inferred occupancy band (0..3)
    public double[] TlX = new double[0]; public double[] TlCo2 = new double[0]; public int[] TlOcc = new int[0];
}

public static class Model {
    // CO2 a person adds, as ppm*m3 per hour: 0.0186 m3/h seated and awake (about 1.2 met),
    // about 0.013 m3/h asleep (Persily and de Jonge 2017).
    public const double GenAwake = 18600.0, GenAsleep = 13000.0;
    public const double DefaultAch = 0.5;      // a closed room in an ordinary home, used only until a decay is seen
    public const double ExhaledPpm = 38000.0;  // CO2 added to exhaled breath (Rudnick and Milton 2003)

    static List<Decay> hist = new List<Decay>(); static DateTime histAt = DateTime.MinValue; static double histBase;
    static double baseCache = 420; static DateTime baseAt = DateTime.MinValue;
    public static void Reset() { hist = new List<Decay>(); histAt = DateTime.MinValue; baseAt = DateTime.MinValue; }

    /// <summary>Dew point (C), Magnus formula over water.</summary>
    public static double DewPoint(double t, double rh) {
        if (double.IsNaN(t) || double.IsNaN(rh) || rh <= 0) return double.NaN;
        double g = Math.Log(rh / 100.0) + (17.62 * t) / (243.12 + t);
        return (243.12 * g) / (17.62 - g);
    }
    /// <summary>Absolute humidity, grams of water per cubic metre of air.</summary>
    public static double AbsHum(double t, double rh) {
        if (double.IsNaN(t) || double.IsNaN(rh)) return double.NaN;
        double e = rh / 100.0 * 6.112 * Math.Exp((17.62 * t) / (243.12 + t));    // vapour pressure, hPa
        return 216.74 * e / (273.15 + t);
    }
    /// <summary>Share of each breath that was already exhaled by someone in the room (%).</summary>
    public static double Rebreathed(double co2, double cout) {
        double r = (co2 - cout) / ExhaledPpm * 100.0; return r < 0 ? 0 : r;
    }
    static double Gen(DateTime when) { int h = when.Hour; return (h >= 23 || h < 6) ? GenAsleep : GenAwake; }

    /// <summary>
    /// Outdoor CO2 as this sensor reads it: the 2nd percentile of the last 14 days
    /// (a room that is ever aired out bottoms out at outdoor level), clamped to
    /// 380-500 ppm. Absorbs the sensor's calibration offset, which a fixed 420 cannot.
    /// </summary>
    public static double Baseline(DateTime now) {
        if (baseAt != DateTime.MinValue && now >= baseAt && (now - baseAt).TotalMinutes < 60) return baseCache;
        Table a = Data.Air; int i0 = a.LowerBound(now.AddDays(-14)), i1 = a.LowerBound(now.AddTicks(1));
        double b = 420;
        if (i1 - i0 >= 1500) {
            double[] v = new double[i1 - i0]; int m = 0;
            for (int i = i0; i < i1; i++) { double x = a.Val(Data.ACo2, i); if (!double.IsNaN(x)) v[m++] = x; }
            if (m >= 1500) {
                Array.Sort(v, 0, m); b = v[(int)(0.02 * m)];
                if (b < 380) b = 380; if (b > 500) b = 500;
            }
        }
        baseCache = b; baseAt = now; return b;
    }

    /// <summary>Least-squares slope of a column over [from,to], per hour. NaN when there is too little data.</summary>
    public static double SlopePerHour(Table tb, int col, DateTime from, DateTime to, int minN, double minSpanH) {
        int i0 = tb.LowerBound(from), i1 = tb.LowerBound(to.AddTicks(1));
        int m = 0; double sx = 0, sy = 0, sxx = 0, sxy = 0, xmin = double.MaxValue, xmax = double.MinValue;
        for (int i = i0; i < i1; i++) {
            double y = tb.Val(col, i); if (double.IsNaN(y)) continue;
            double x = (tb.Time(i) - from).TotalHours;
            sx += x; sy += y; sxx += x * x; sxy += x * y; m++;
            if (x < xmin) xmin = x; if (x > xmax) xmax = x;
        }
        if (m < minN || (xmax - xmin) < minSpanH) return double.NaN;
        double den = m * sxx - sx * sx; if (den <= 1e-12) return double.NaN;
        return (m * sxy - sx * sy) / den;
    }

    /// <summary>
    /// Every usable CO2 decay in [from,to]. The room's air-change rate k comes from
    ///     dC/dt = S - k (C - C_out)
    /// during a fall: with nobody adding CO2 the excess decays as exp(-k t), so
    /// ln(C - C_out) against time is a line of slope -k. If people stay in the room
    /// the fall levels off above outdoor, and that fit reads low; when the curve
    /// shows the levelling clearly (at least one time constant, much better fit) the
    /// asymptote is fitted too.
    /// </summary>
    public static List<Decay> FindDecays(DateTime from, DateTime to, double cout) {
        List<Decay> res = new List<Decay>();
        Table a = Data.Air; int i0 = a.LowerBound(from), i1 = a.LowerBound(to.AddTicks(1));
        if (i1 - i0 < 5) return res;
        double[] th = new double[i1 - i0], cc = new double[i1 - i0]; int n = 0, chunk = 0;
        DateTime t0 = a.Time(i0);
        for (int i = i0; i < i1; i++) {
            double c = a.Val(Data.ACo2, i); if (double.IsNaN(c)) continue;
            double h = (a.Time(i) - t0).TotalHours;
            if (n > chunk) {
                double gap = h - th[n - 1];
                if (gap > 0.34) { Legs(th, cc, chunk, n, t0, cout, res); chunk = n; }     // outage: never fit across it
                else if (c == cc[n - 1] && gap < 0.06) continue;                          // same measurement re-broadcast
            }
            th[n] = h; cc[n] = c; n++;
        }
        Legs(th, cc, chunk, n, t0, cout, res);
        return res;
    }
    // Split one gap-free run into rising and falling legs (turning points confirmed by
    // a 30 ppm reversal) and fit each falling leg.
    static void Legs(double[] th, double[] cc, int s, int e, DateTime t0, double cout, List<Decay> res) {
        int n = e - s; if (n < 5) return;
        double[] sm = new double[n];
        for (int i = 0; i < n; i++) {
            int lo = Math.Max(0, i - 1), hi = Math.Min(n - 1, i + 1); double sum = 0;
            for (int j = lo; j <= hi; j++) sum += cc[s + j];
            sm[i] = sum / (hi - lo + 1);
        }
        const double delta = 30;
        int dir = 0, hiI = 0, loI = 0, ext = 0, peak = -1;
        for (int i = 1; i < n; i++) {
            if (dir == 0) {
                if (sm[i] > sm[hiI]) hiI = i; if (sm[i] < sm[loI]) loI = i;
                if (sm[hiI] - sm[i] >= delta) { peak = hiI; dir = -1; ext = i; }
                else if (sm[i] - sm[loI] >= delta) { dir = 1; ext = i; }
            } else if (dir > 0) {
                if (sm[i] > sm[ext]) ext = i;
                else if (sm[ext] - sm[i] >= delta) { peak = ext; dir = -1; ext = i; }
            } else {
                if (sm[i] < sm[ext]) ext = i;
                else if (sm[i] - sm[ext] >= delta) { Leg(th, cc, sm, s, peak, ext, t0, cout, res, false); dir = 1; ext = i; peak = -1; }
            }
        }
        if (dir < 0 && peak >= 0) Leg(th, cc, sm, s, peak, ext, t0, cout, res, true);   // still falling at the end of the data
    }
    static void Leg(double[] th, double[] cc, double[] sm, int s, int p, int q, DateTime t0, double cout, List<Decay> res, bool ongoing) {
        double drop = sm[p] - sm[q]; if (drop < 40) return;
        // trim the rounded shoulder at the peak and the flat foot at the trough
        int a = p; for (int i = p; i <= q; i++) { if (sm[i] >= sm[p] - 0.08 * drop) a = i; else break; }
        int b = q; for (int i = q; i >= a; i--) { if (sm[i] <= sm[q] + 0.08 * drop) b = i; else break; }
        int m = b - a + 1; if (m < 4) return;
        double hours = th[s + b] - th[s + a]; if (hours < 0.12) return;
        double[] x = new double[m], y = new double[m]; double ymin = double.MaxValue, ymean = 0;
        for (int i = 0; i < m; i++) { x[i] = th[s + a + i] - th[s + a]; y[i] = cc[s + a + i]; if (y[i] < ymin) ymin = y[i]; ymean += y[i]; }
        ymean /= m;
        double sst = 0; for (int i = 0; i < m; i++) sst += (y[i] - ymean) * (y[i] - ymean);
        if (sst <= 0) return;

        // (1) asymptote fixed at outdoor: straight line through ln(C - C_out)
        int ml = 0; double sx = 0, sy = 0, sxx = 0, sxy = 0, syy = 0;
        for (int i = 0; i < m; i++) {
            double ex = y[i] - cout; if (ex < 25) continue;
            double ly = Math.Log(ex); sx += x[i]; sy += ly; sxx += x[i] * x[i]; sxy += x[i] * ly; syy += ly * ly; ml++;
        }
        if (ml < 4) return;
        double den = ml * sxx - sx * sx; if (den <= 1e-12) return;
        double slope = (ml * sxy - sx * sy) / den, icpt = (sy - slope * sx) / ml;
        double sstl = syy - sy * sy / ml; if (sstl <= 0) return;
        double ssel = 0, sseFix = 0;
        for (int i = 0; i < m; i++) {
            double pred = cout + Math.Exp(icpt + slope * x[i]); sseFix += (y[i] - pred) * (y[i] - pred);
            double ex = y[i] - cout; if (ex < 25) continue;
            double r = Math.Log(ex) - (icpt + slope * x[i]); ssel += r * r;
        }
        double k = -slope, r2 = 1 - ssel / sstl, css = cout; bool free = false;

        // (2) asymptote free: C = Css + A exp(-k t), 1-D search over k with a linear fit for Css and A
        if (m >= 8 && drop >= 100) {
            double bestSse = double.MaxValue, bestK = 0, bestCss = 0;
            for (int g = 0; g < 120; g++) {
                double kk = 0.08 * Math.Pow(15.0 / 0.08, g / 119.0);
                double su = 0, suu = 0, syv = 0, suy = 0;
                for (int i = 0; i < m; i++) { double u = Math.Exp(-kk * x[i]); su += u; suu += u * u; syv += y[i]; suy += u * y[i]; }
                double d2 = m * suu - su * su; if (d2 <= 1e-12) continue;
                double A = (m * suy - su * syv) / d2, C = (syv - A * su) / m;
                double lo = cout - 10, hi = ymin - 3;
                if (C < lo || C > hi) {                  // pin the asymptote to the plausible range and refit A
                    C = C < lo ? lo : hi; double num = 0;
                    for (int i = 0; i < m; i++) num += Math.Exp(-kk * x[i]) * (y[i] - C);
                    A = num / suu;
                }
                if (A <= 0) continue;
                double sse = 0;
                for (int i = 0; i < m; i++) { double r = y[i] - C - A * Math.Exp(-kk * x[i]); sse += r * r; }
                if (sse < bestSse) { bestSse = sse; bestK = kk; bestCss = C; }
            }
            // only believe it when the levelling-off is unmistakable: a full time constant
            // observed, a much better fit, and a rate that is not wildly above the simple one
            if (bestK > 0 && bestK * hours >= 1.0 && bestCss - cout >= 40 && bestSse <= 0.5 * sseFix && bestK > k * 1.15 && bestK <= k * 6 && bestK < 14.5) {
                k = bestK; css = bestCss; free = true; r2 = 1 - bestSse / sst;
            }
        }
        if (!(k >= 0.05 && k <= 15) || r2 < 0.7) return;
        Decay d = new Decay();
        d.Start = t0.AddHours(th[s + a]); d.End = t0.AddHours(th[s + q]);
        d.K = k; d.R2 = r2; d.Css = css; d.Drop = drop; d.Hours = hours; d.N = m; d.Free = free; d.Ongoing = ongoing;
        d.Quality = r2 * Math.Min(1.0, drop / 120.0) * Math.Min(1.0, m / 8.0);
        res.Add(d);
    }
    static double Median(List<double> v) {
        if (v.Count == 0) return double.NaN;
        v.Sort(); int m = v.Count / 2;
        return (v.Count % 2 == 1) ? v[m] : (v[m - 1] + v[m]) / 2.0;
    }
    static int Level(double n) { return n < 0.5 ? 0 : n < 2.5 ? 1 : n < 5.0 ? 2 : 3; }
    // A fast fall with no levelling-off is someone airing the room: the mass balance
    // cannot tell "empty" from "occupied with the window open" until the curve
    // flattens, so the count from just before the airing began is held instead.
    static bool Airing(Decay d, double closed) { return !d.Free && d.K > 1.5 * closed; }
    static double PeopleBefore(Decay d, double closed, double volume, double cout) {
        Table a = Data.Air;
        double c0 = a.ValueNear(Data.ACo2, d.Start, 8); if (double.IsNaN(c0)) return double.NaN;
        double s0 = SlopePerHour(a, Data.ACo2, d.Start.AddMinutes(-20), d.Start, 3, 0.1);
        return People(c0, s0, closed, volume, cout, d.Start);
    }

    /// <summary>
    /// People in the room from the CO2 mass balance, including the transient term:
    ///     V dC/dt = n G - k V (C - C_out)   =>   n = V (dC/dt + k (C - C_out)) / G
    /// (a room that is emptying and decaying gives n = 0; one that is filling gives
    /// the right count before the plateau).
    /// </summary>
    public static double People(double co2, double slopePerHour, double ach, double volume, double cout, DateTime when) {
        double ex = co2 - cout, sl = double.IsNaN(slopePerHour) ? 0 : slopePerHour;
        if (ex < 30 && sl < 40) return 0;            // at outdoor level there is nothing to infer from
        double n = volume * (sl + ach * ex) / Gen(when);
        return n < 0 ? 0 : n;
    }

    public static RoomState Evaluate(DateTime now, double volume) {
        RoomState st = new RoomState(); st.Now = now;
        if (volume <= 0) volume = 29;
        Table a = Data.Air;
        double cout = Baseline(now); st.Baseline = cout;
        int ia = a.IndexAtOrBefore(now);
        if (ia >= 0) {
            st.Co2AgeMin = (now - a.Time(ia)).TotalMinutes;
            if (st.Co2AgeMin <= 20) st.Co2 = a.Val(Data.ACo2, ia);
        }
        // ---- ventilation ----
        if (histAt == DateTime.MinValue || now < histAt || (now - histAt).TotalMinutes > 30 || Math.Abs(cout - histBase) > 5) {
            hist = FindDecays(now.AddDays(-30), now, cout); histAt = now; histBase = cout;
        }
        List<Decay> recent = FindDecays(now.AddHours(-12), now, cout);
        List<double> ks = new List<double>();
        foreach (Decay d in hist) if (d.Quality >= 0.35) ks.Add(d.K);
        foreach (Decay d in recent) if (d.End > histAt && d.Quality >= 0.35) ks.Add(d.K);
        st.AchHistory = ks.Count;
        double closed = DefaultAch;
        if (ks.Count >= 1) {
            double med = Median(ks);                      // sorts ks
            if (ks.Count >= 3) st.AchTypical = med;
            closed = ks.Count >= 4 ? ks[(int)(0.25 * (ks.Count - 1))] : med;
        }
        st.AchClosed = closed;
        Decay last = null;
        foreach (Decay d in recent) if (last == null || d.End > last.End) last = d;
        if (last != null) {
            st.AchLast = last.K; st.AchLastAgeMin = (now - last.End).TotalMinutes;
            // "in progress" only while readings are still arriving to show it
            if (last.Ongoing && st.AchLastAgeMin <= 30 && st.Co2AgeMin <= 10) { st.AchLive = true; st.AchLiveK = last.K; st.AchLiveR2 = last.R2; st.AchLiveOccupied = last.Free; }
        }
        if (st.AchLive) { st.AchUsed = st.AchLiveK; st.AchSource = "live"; }
        else { st.AchUsed = closed; st.AchSource = ks.Count >= 1 ? "typical" : "assumed"; }

        // ---- occupancy now ----
        if (!double.IsNaN(st.Co2)) {
            st.Co2Slope = SlopePerHour(a, Data.ACo2, now.AddMinutes(-20), now, 3, 0.1);
            st.OccN = People(st.Co2, st.Co2Slope, st.AchUsed, volume, cout, now);
            if (st.AchLive && Airing(last, closed)) {
                double held = PeopleBefore(last, closed, volume, cout);
                if (!double.IsNaN(held)) { st.OccN = held; st.OccHeld = true; }
            }
            st.OccLevel = Level(st.OccN);
            st.OccLowSignal = (st.Co2 - cout) < 40;
            if (st.Co2 > 800 && st.AchUsed > 0)
                st.FreshenMin = Math.Log((st.Co2 - cout) / (800 - cout)) / st.AchUsed * 60.0;
        }
        // ---- pressure tendency ----
        double ps = SlopePerHour(a, Data.APres, now.AddHours(-3), now, 6, 1.0);
        if (!double.IsNaN(ps) && st.Co2AgeMin <= 30) st.PresRate3h = ps * 3.0;   // a tendency needs current readings

        // ---- today's timeline ----
        int j0 = a.LowerBound(now.Date), j1 = ia + 1, m = j1 - j0;
        if (m >= 2) {
            List<Decay> today = FindDecays(now.Date.AddHours(-3), now, cout);
            double[] held = new double[today.Count];
            for (int d = 0; d < today.Count; d++) held[d] = Airing(today[d], closed) ? PeopleBefore(today[d], closed, volume, cout) : double.NaN;
            double[] nn = new double[m]; double[] tm = new double[m];
            for (int i = 0; i < m; i++) tm[i] = (a.Time(j0 + i) - now.Date).TotalMinutes;
            for (int i = 0; i < m; i++) {
                DateTime ti = a.Time(j0 + i); double ci = a.Val(Data.ACo2, j0 + i);
                double sl = SlopePerHour(a, Data.ACo2, ti.AddMinutes(-10), ti.AddMinutes(10) < now ? ti.AddMinutes(10) : now, 3, 0.08);
                double k = closed, hold = double.NaN;
                for (int d = 0; d < today.Count; d++) if (ti >= today[d].Start && ti <= today[d].End) { k = today[d].K; hold = held[d]; break; }
                nn[i] = double.IsNaN(ci) ? 0 : (!double.IsNaN(hold) ? hold : People(ci, sl, k, volume, cout, ti));
            }
            int step = (int)Math.Ceiling(m / 600.0); if (step < 1) step = 1;
            int outN = (m + step - 1) / step;
            st.TlX = new double[outN]; st.TlCo2 = new double[outN]; st.TlOcc = new int[outN];
            List<double> win = new List<double>();
            for (int o = 0; o < outN; o++) {
                int g0 = o * step, g1 = Math.Min(m, g0 + step), mid = (g0 + g1 - 1) / 2;
                double sum = 0; int cnt = 0;
                for (int i = g0; i < g1; i++) { double v = a.Val(Data.ACo2, j0 + i); if (!double.IsNaN(v)) { sum += v; cnt++; } }
                st.TlCo2[o] = cnt > 0 ? sum / cnt : double.NaN;
                st.TlX[o] = tm[mid] / 1440.0;
                win.Clear();                       // 16-minute median so the band does not flicker
                for (int i = mid; i >= 0 && tm[mid] - tm[i] <= 8; i--) win.Add(nn[i]);
                for (int i = mid + 1; i < m && tm[i] - tm[mid] <= 8; i++) win.Add(nn[i]);
                st.TlOcc[o] = Level(Median(win));
            }
        }
        return st;
    }
}

// ---------------------------------------------------------------------------
//  Theme + drawing primitives
// ---------------------------------------------------------------------------
public static class Theme {
    public static Color Canvas = Color.FromArgb(13, 14, 16), Surface = Color.FromArgb(23, 24, 27), Sunken = Color.FromArgb(30, 31, 35);
    public static Color TextP = Color.FromArgb(244, 244, 241), TextS = Color.FromArgb(162, 164, 172), TextT = Color.FromArgb(110, 112, 119);
    public static Color Hairline = Color.FromArgb(20, 255, 255, 255), Accent = Color.FromArgb(43, 182, 164), AccentWash = Color.FromArgb(26, 43, 182, 164);
    public static Color Caution = Color.FromArgb(214, 162, 74), Alert = Color.FromArgb(215, 122, 92), OnAccent = Color.FromArgb(13, 14, 16);
    public static Color Hover = Color.FromArgb(40, 42, 47);
}

public static class Gfx {
    static StringFormat typo;
    static StringFormat Typo { get {
        if (typo == null) { typo = (StringFormat)StringFormat.GenericTypographic.Clone(); typo.FormatFlags |= StringFormatFlags.MeasureTrailingSpaces; }
        return typo; } }

    public static void Setup(Graphics g) {
        g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
    }
    public static GraphicsPath Round(float x, float y, float w, float h, float r) {
        GraphicsPath gp = new GraphicsPath();
        float d = r * 2; if (d > w) d = w; if (d > h) d = h; if (d < 1) d = 1;
        gp.AddArc(x, y, d, d, 180, 90); gp.AddArc(x + w - d, y, d, d, 270, 90);
        gp.AddArc(x + w - d, y + h - d, d, d, 0, 90); gp.AddArc(x, y + h - d, d, d, 90, 90); gp.CloseFigure();
        return gp;
    }
    public static void Fill(Graphics g, Color c, float x, float y, float w, float h, float r) {
        if (w <= 0 || h <= 0) return;
        using (GraphicsPath gp = Round(x, y, w, h, r)) using (SolidBrush b = new SolidBrush(c)) g.FillPath(b, gp);
    }
    public static void Stroke(Graphics g, Color c, float x, float y, float w, float h, float r) {
        if (w <= 0 || h <= 0) return;
        using (GraphicsPath gp = Round(x, y, w, h, r)) using (Pen p = new Pen(c, 1f)) g.DrawPath(p, gp);
    }
    /// <summary>Clear to the canvas and draw a card surface with its hairline border.</summary>
    public static void Card(Graphics g, int w, int h, float r) {
        Setup(g); g.Clear(Theme.Canvas);
        Fill(g, Theme.Surface, 0, 0, w - 1, h - 1, r); Stroke(g, Theme.Hairline, 0, 0, w - 1, h - 1, r);
    }
    public static void Dot(Graphics g, Color c, float x, float y, float d) {
        using (SolidBrush b = new SolidBrush(c)) g.FillEllipse(b, x, y, d, d);
    }
    public static void Line(Graphics g, Color c, float w, float x1, float y1, float x2, float y2, bool dotted) {
        using (Pen p = new Pen(c, w)) { if (dotted) p.DashStyle = DashStyle.Dot; p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; g.DrawLine(p, x1, y1, x2, y2); }
    }
    public static void Text(Graphics g, string s, Font f, Color c, float x, float y) {
        if (string.IsNullOrEmpty(s)) return;
        using (SolidBrush b = new SolidBrush(c)) g.DrawString(s, f, b, x, y);
    }
    public static void TextRight(Graphics g, string s, Font f, Color c, float x, float y, float w) {
        if (string.IsNullOrEmpty(s)) return;
        using (StringFormat sf = new StringFormat()) using (SolidBrush b = new SolidBrush(c)) {
            sf.Alignment = StringAlignment.Far; sf.FormatFlags = StringFormatFlags.NoWrap;
            g.DrawString(s, f, b, new RectangleF(x, y, w, f.Height + 4), sf);
        }
    }
    /// <summary>Text confined to a box: wraps, and ends in an ellipsis when it does not fit.</summary>
    public static void TextBox(Graphics g, string s, Font f, Color c, float x, float y, float w, float h, bool wrap) {
        if (string.IsNullOrEmpty(s) || w <= 0 || h <= 0) return;
        using (StringFormat sf = new StringFormat()) using (SolidBrush b = new SolidBrush(c)) {
            sf.Trimming = StringTrimming.EllipsisCharacter; if (!wrap) sf.FormatFlags = StringFormatFlags.NoWrap;
            g.DrawString(s, f, b, new RectangleF(x, y, w, h), sf);
        }
    }
    public static float Width(Graphics g, string s, Font f) { return string.IsNullOrEmpty(s) ? 0 : g.MeasureString(s, f).Width; }
    public static float Height(Graphics g, string s, Font f, float w) { return string.IsNullOrEmpty(s) ? 0 : g.MeasureString(s, f, (int)w).Height; }
    /// <summary>Draw a number with every digit in a fixed-width cell (tabular figures). Returns the width drawn.</summary>
    public static float Num(Graphics g, string s, Font f, Color c, float x, float y) {
        if (string.IsNullOrEmpty(s)) return 0;
        StringFormat fmt = Typo; PointF o = new PointF(0, 0);
        float cell = g.MeasureString("0", f, o, fmt).Width, cx = x;
        using (SolidBrush b = new SolidBrush(c)) {
            foreach (char ch in s) {
                string one = ch.ToString(); float w = g.MeasureString(one, f, o, fmt).Width;
                if (ch >= '0' && ch <= '9') { g.DrawString(one, f, b, cx + (cell - w) / 2, y, fmt); cx += cell; }
                else { g.DrawString(one, f, b, cx, y, fmt); cx += w; }
            }
        }
        return cx - x;
    }
    public static void Spark(Graphics g, double[] pts, float x, float y, float w, float h, Color line, Color wash) {
        if (pts == null || pts.Length < 2 || w <= 2 || h <= 2) return;
        double mn = double.MaxValue, mx = double.MinValue;
        foreach (double v in pts) { if (v < mn) mn = v; if (v > mx) mx = v; }
        double rng = mx - mn; if (rng <= 0) rng = 1;
        int n = pts.Length; PointF[] poly = new PointF[n + 2];
        for (int i = 0; i < n; i++) poly[i] = new PointF(x + (float)(i * (double)w / (n - 1)), y + h - 1 - (float)((pts[i] - mn) / rng * (h - 2)));
        poly[n] = new PointF(x + w, y + h); poly[n + 1] = new PointF(x, y + h);
        using (SolidBrush b = new SolidBrush(wash)) g.FillPolygon(b, poly);
        PointF[] ln = new PointF[n]; Array.Copy(poly, ln, n);
        using (Pen p = new Pen(line, 1.5f)) { p.LineJoin = LineJoin.Round; g.DrawLines(p, ln); }
    }
    /// <summary>A threshold band: a sunken track with tinted zones and a marker at the value.</summary>
    public static void Band(Graphics g, float x, float y, float w, float h, double min, double max, double[] zoneLo, double[] zoneHi, Color[] zoneCol, double value) {
        Fill(g, Theme.Sunken, x, y, w, h, h / 2);
        double span = max - min; if (span <= 0) span = 1;
        for (int i = 0; zoneLo != null && i < zoneLo.Length; i++) {
            float zx = x + (float)((zoneLo[i] - min) / span * w), zw = (float)((zoneHi[i] - zoneLo[i]) / span * w);
            if (zw < 1) continue;
            Fill(g, Color.FromArgb(46, zoneCol[i].R, zoneCol[i].G, zoneCol[i].B), zx, y, zw, h, h / 2);
        }
        if (!double.IsNaN(value)) {
            double v = value < min ? min : value > max ? max : value;
            float mx = x + (float)((v - min) / span * w);
            using (SolidBrush b = new SolidBrush(Theme.TextP)) g.FillRectangle(b, mx - 1.5f, y - 3, 3f, h + 6);
        }
    }
    public static int Nearest(double[] xs, double x) {
        int best = -1; double bd = double.MaxValue;
        for (int i = 0; xs != null && i < xs.Length; i++) { double d = Math.Abs(xs[i] - x); if (d < bd) { bd = d; best = i; } }
        return best;
    }
    /// <summary>Today's CO2 area and the inferred-occupancy step line. Returns {yMin, yMax} of the CO2 scale.</summary>
    public static double[] Timeline(Graphics g, RoomState st, float x, float y, float w, float h, Color accent, Color wash, Color occ) {
        double mn = 400, mx = 900;
        if (st == null || st.TlX.Length < 2) return new double[] { mn, mx };
        foreach (double v in st.TlCo2) { if (double.IsNaN(v)) continue; if (v > mx) mx = v; if (v < mn) mn = v; }
        double rng = mx - mn; if (rng <= 0) rng = 1;
        int n = st.TlX.Length; int i = 0;
        using (SolidBrush wb = new SolidBrush(wash)) using (Pen lp = new Pen(accent, 1.6f)) using (Pen op = new Pen(occ, 1.4f)) {
            lp.LineJoin = LineJoin.Round;
            while (i < n) {
                int j = i;       // one gap-free run [i, j]
                while (j + 1 < n && st.TlX[j + 1] - st.TlX[j] < 0.0175 && !double.IsNaN(st.TlCo2[j + 1])) j++;
                int m = j - i + 1;
                if (m >= 2 && !double.IsNaN(st.TlCo2[i])) {
                    PointF[] ln = new PointF[m]; List<PointF> oc = new List<PointF>(m * 2);
                    float prevOy = 0;
                    for (int k = 0; k < m; k++) {
                        float px = x + (float)(st.TlX[i + k] * w);
                        ln[k] = new PointF(px, y + h - (float)((st.TlCo2[i + k] - mn) / rng * h));
                        float oy = y + h - 1 - (float)(st.TlOcc[i + k] / 3.0 * h * 0.5);
                        if (k > 0 && oy != prevOy) oc.Add(new PointF(px, prevOy));
                        oc.Add(new PointF(px, oy)); prevOy = oy;
                    }
                    PointF[] area = new PointF[m + 2]; Array.Copy(ln, area, m);
                    area[m] = new PointF(ln[m - 1].X, y + h); area[m + 1] = new PointF(ln[0].X, y + h);
                    g.FillPolygon(wb, area); g.DrawLines(lp, ln);
                    if (oc.Count >= 2) g.DrawLines(op, oc.ToArray());
                }
                i = j + 1;
            }
        }
        return new double[] { mn, mx };
    }
}

public static class ChartUtil {
    /// <summary>Replace a chart series' points, breaking the line at real outages.</summary>
    public static void Fill(DV.Series s, XY d) {
        s.Points.SuspendUpdates(); s.Points.Clear();
        for (int i = 0; d != null && i < d.Count; i++) {
            if (i > 0 && d.Break[i]) { int idx = s.Points.AddXY(d.X[i - 1] + 0.0004, 0.0); s.Points[idx].IsEmpty = true; }
            s.Points.AddXY(d.X[i], d.Y[i]);
        }
        s.Points.ResumeUpdates();
    }
}

public static class Native {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool DestroyIcon(IntPtr handle);
    /// <summary>True while this session shows the lock / sign-in screen (nobody is looking).</summary>
    public static bool SessionLocked() {
        try {
            int me = System.Diagnostics.Process.GetCurrentProcess().SessionId; bool locked = false;
            foreach (System.Diagnostics.Process p in System.Diagnostics.Process.GetProcessesByName("LogonUI")) {
                try { if (p.SessionId == me) locked = true; } catch { }
                p.Dispose();
            }
            return locked;
        } catch { return false; }
    }
}

// ---------------------------------------------------------------------------
//  Controls
// ---------------------------------------------------------------------------
/// <summary>Double-buffered owner-drawn panel (no smear on resize).</summary>
public class CardPanel : Panel {
    public CardPanel() { DoubleBuffered = true; SetStyle(ControlStyles.ResizeRedraw, true); }
}
public class BufferedTable : TableLayoutPanel {
    public BufferedTable() { DoubleBuffered = true; SetStyle(ControlStyles.ResizeRedraw, true); }
}
/// <summary>Borderless top-level window that shows without taking focus and stays out of Alt-Tab.</summary>
public class NoActivatePopup : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x00000080; return cp; }
    }
}
public abstract class OwnerDrawn : Control {
    protected bool hover, down;
    protected OwnerDrawn() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
        Cursor = Cursors.Hand;
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { down = true; Focus(); Invalidate(); base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected override bool IsInputKey(Keys k) { return k == Keys.Space || k == Keys.Enter || k == Keys.Left || k == Keys.Right || base.IsInputKey(k); }
    protected void FocusRing(Graphics g, float r) {
        if (Focused && ShowFocusCues) Gfx.Stroke(g, Theme.Accent, 0.5f, 0.5f, Width - 2, Height - 2, r);
    }
    protected Color Back { get { return Parent != null ? Parent.BackColor : Theme.Canvas; } }
}
/// <summary>The breathing status dot beside the verdict. Animates itself.</summary>
public class Orb : Control {
    Timer tm; double phase = 1, tt; public Color Tone = Color.FromArgb(43, 182, 164);
    public Orb() {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        Size = new Size(20, 20);
        tm = new Timer(); tm.Interval = 60;
        tm.Tick += delegate {
            Form f = FindForm(); if (f == null || !Visible || f.WindowState == FormWindowState.Minimized) return;
            tt += 0.06; phase = (1 - Math.Cos(tt / 2.4 * 2 * Math.PI)) / 2; Invalidate();
        };
    }
    public bool Animate { get { return tm.Enabled; } set { if (value) tm.Start(); else { tm.Stop(); phase = 1; Invalidate(); } } }
    public void SetTone(Color c) { if (c != Tone) { Tone = c; Invalidate(); } }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.Clear(Parent != null ? Parent.BackColor : Theme.Canvas);
        float d = 12f + (float)phase * 1.5f; int al = (int)(120 + 135 * phase);
        using (SolidBrush b = new SolidBrush(Color.FromArgb(al, Tone.R, Tone.G, Tone.B))) g.FillEllipse(b, (Width - d) / 2, (Height - d) / 2, d, d);
    }
    protected override void Dispose(bool disposing) { if (disposing) tm.Dispose(); base.Dispose(disposing); }
}
/// <summary>Rounded button with an optional Segoe MDL2 glyph.</summary>
public class PillButton : OwnerDrawn {
    public string Glyph = ""; public bool Primary; public bool Quiet;
    static Font glyphFont = new Font("Segoe MDL2 Assets", 10.5f);
    static Font textFont = new Font("Segoe UI Semibold", 9.5f);
    public PillButton() { Height = 36; AccessibleRole = AccessibleRole.PushButton; }
    public int Fit() {
        using (Graphics g = CreateGraphics()) {
            float w = 30 + Gfx.Width(g, Text, textFont) + (Glyph.Length > 0 ? (Text.Length > 0 ? 22 : 6) : 0);
            Width = (int)Math.Ceiling(w); return Width;
        }
    }
    protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { OnClick(EventArgs.Empty); e.Handled = true; } base.OnKeyDown(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; Gfx.Setup(g); g.Clear(Back);
        Color fill = Primary ? Theme.Accent : (Quiet && !hover ? Back : (hover ? Theme.Hover : Theme.Sunken));
        if (Primary && hover) fill = Color.FromArgb(Math.Min(255, fill.R + 14), Math.Min(255, fill.G + 14), Math.Min(255, fill.B + 14));
        if (down) fill = Color.FromArgb((fill.R * 9) / 10, (fill.G * 9) / 10, (fill.B * 9) / 10);
        Gfx.Fill(g, fill, 0, 0, Width - 1, Height - 1, Height / 2f);
        if (!Primary && !Quiet) Gfx.Stroke(g, Theme.Hairline, 0, 0, Width - 1, Height - 1, Height / 2f);
        Color fg = Primary ? Theme.OnAccent : (Enabled ? Theme.TextP : Theme.TextT);
        float tw = Gfx.Width(g, Text, textFont), gw = Glyph.Length > 0 ? 18 : 0, gap = (gw > 0 && Text.Length > 0) ? 4 : 0;
        float x = (Width - (tw + gw + gap)) / 2f;
        if (gw > 0) { Gfx.Text(g, Glyph, glyphFont, fg, x - 1, (Height - glyphFont.Height) / 2f + 1); x += gw + gap; }
        Gfx.Text(g, Text, textFont, fg, x, (Height - textFont.Height) / 2f - 0.5f);
        FocusRing(g, Height / 2f);
    }
}
/// <summary>On/off switch.</summary>
public class Toggle : OwnerDrawn {
    bool on; public event EventHandler CheckedChanged;
    public Toggle() { Size = new Size(44, 24); AccessibleRole = AccessibleRole.CheckButton; }
    public bool Checked { get { return on; } set { if (on != value) { on = value; Invalidate(); } } }
    void Flip() { on = !on; Invalidate(); if (CheckedChanged != null) CheckedChanged(this, EventArgs.Empty); }
    protected override void OnClick(EventArgs e) { Flip(); base.OnClick(e); }
    protected override void OnKeyDown(KeyEventArgs e) { if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter) { Flip(); e.Handled = true; } base.OnKeyDown(e); }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; Gfx.Setup(g); g.Clear(Back);
        Color track = on ? Theme.Accent : (hover ? Theme.TextT : Color.FromArgb((Theme.TextT.R + Theme.Sunken.R) / 2, (Theme.TextT.G + Theme.Sunken.G) / 2, (Theme.TextT.B + Theme.Sunken.B) / 2));
        Gfx.Fill(g, track, 0, 0, Width - 1, Height - 1, Height / 2f);
        float kd = Height - 8, kx = on ? Width - kd - 5 : 4;
        Gfx.Dot(g, Color.White, kx, 3.5f, kd);
        FocusRing(g, Height / 2f);
    }
}
/// <summary>Segmented selector: one of a few options.</summary>
public class Segmented : OwnerDrawn {
    public string[] Items = new string[0]; int sel = -1; public event EventHandler SelectedChanged;
    static Font f = new Font("Segoe UI Semibold", 9f);
    public Segmented() { Height = 30; }
    public int SelectedIndex { get { return sel; } set { if (sel != value) { sel = value; Invalidate(); } } }
    void Pick(int i) { if (i < 0 || i >= Items.Length || i == sel) return; sel = i; Invalidate(); if (SelectedChanged != null) SelectedChanged(this, EventArgs.Empty); }
    protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (Items.Length > 0) Pick((int)(e.X / ((float)Width / Items.Length))); }
    protected override void OnKeyDown(KeyEventArgs e) {
        if (e.KeyCode == Keys.Left) { Pick(sel - 1); e.Handled = true; } else if (e.KeyCode == Keys.Right) { Pick(sel + 1); e.Handled = true; }
        base.OnKeyDown(e);
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics; Gfx.Setup(g); g.Clear(Back);
        Gfx.Fill(g, Theme.Sunken, 0, 0, Width - 1, Height - 1, 9);
        if (Items.Length == 0) return;
        float sw = (Width - 1f) / Items.Length;
        for (int i = 0; i < Items.Length; i++) {
            if (i == sel) Gfx.Fill(g, Theme.Accent, i * sw + 2, 2, sw - 4, Height - 5, 7);
            float tw = Gfx.Width(g, Items[i], f);
            Gfx.Text(g, Items[i], f, i == sel ? Theme.OnAccent : Theme.TextS, i * sw + (sw - tw) / 2f, (Height - f.Height) / 2f - 0.5f);
        }
        FocusRing(g, 9);
    }
}

}
