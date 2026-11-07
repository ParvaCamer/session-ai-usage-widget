// Mini widget : affiche la limite d'utilisation du forfait Claude sur le bureau Windows.
//
// Un navigateur WebView2 cache garde ta session claude.ai et lit les memes donnees que la page
// Parametres > Utilisation. Le widget ne voit jamais ton mot de passe : tu te connectes directement
// sur claude.ai dans la fenetre de connexion.
//
// Compilation : build.bat (C# 5, compilateur inclus dans Windows, rien a installer).

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32;

namespace ClaudeUsage
{
    class Limit
    {
        public string Label;
        public double Percent;
        public DateTime? ResetsAt;
    }

    // Lecture de la reponse de claude.ai. L'adresse n'est pas documentee : on accepte les deux formats
    // connus et on ignore tout ce qui manque plutot que d'afficher un chiffre faux.
    static class UsageParser
    {
        public static object ParseJson(string text)
        {
            if (string.IsNullOrEmpty(text)) return null;
            string t = text.Trim();
            if (t.Length == 0 || (t[0] != '{' && t[0] != '[')) return null;
            try
            {
                var ser = new JavaScriptSerializer();
                ser.MaxJsonLength = int.MaxValue;
                return ser.DeserializeObject(t);
            }
            catch (ArgumentException) { return null; }
            catch (InvalidOperationException) { return null; }
        }

        public static List<Limit> Parse(object json)
        {
            var root = json as Dictionary<string, object>;
            if (root == null) throw new FormatException("Réponse inattendue");

            var rows = new List<Limit>();
            object limits;
            if (root.TryGetValue("limits", out limits) && limits is object[])
            {
                foreach (object item in (object[])limits)
                {
                    var e = item as Dictionary<string, object>;
                    if (e == null) continue;
                    Add(rows, LabelForKind(e), Get(e, "percent"), Get(e, "resets_at"));
                }
            }
            else
            {
                AddFlat(rows, root, "five_hour", "Session");
                AddFlat(rows, root, "seven_day", "Semaine");
                AddFlat(rows, root, "seven_day_opus", "Semaine · Opus");
                AddFlat(rows, root, "seven_day_sonnet", "Semaine · Sonnet");
            }
            if (rows.Count == 0) throw new FormatException("Aucune limite dans la réponse");
            return rows;
        }

        static object Get(Dictionary<string, object> d, string key)
        {
            object v;
            return d.TryGetValue(key, out v) ? v : null;
        }

        static string LabelForKind(Dictionary<string, object> e)
        {
            string kind = Get(e, "kind") as string;
            if (kind == "session") return "Session";
            if (kind == "weekly_all") return "Semaine";
            if (kind == "weekly_scoped")
            {
                var scope = Get(e, "scope") as Dictionary<string, object>;
                var model = scope == null ? null : Get(scope, "model") as Dictionary<string, object>;
                string name = model == null ? null : Get(model, "display_name") as string;
                return string.IsNullOrEmpty(name) ? "Semaine (modèle)" : "Semaine · " + name;
            }
            return kind;
        }

        static void AddFlat(List<Limit> rows, Dictionary<string, object> root, string key, string label)
        {
            var e = Get(root, key) as Dictionary<string, object>;
            if (e != null) Add(rows, label, Get(e, "utilization"), Get(e, "resets_at"));
        }

        static void Add(List<Limit> rows, string label, object percent, object resetsAt)
        {
            if (string.IsNullOrEmpty(label) || percent == null) return;
            double p;
            try { p = Convert.ToDouble(percent, CultureInfo.InvariantCulture); }
            catch (FormatException) { return; }
            catch (InvalidCastException) { return; }
            if (double.IsNaN(p) || double.IsInfinity(p) || p < 0) return;

            DateTime? reset = null;
            string s = resetsAt as string;
            DateTimeOffset parsed;
            if (s != null && DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.None, out parsed))
                reset = parsed.LocalDateTime;

            rows.Add(new Limit { Label = label, Percent = Math.Min(p, 100), ResetsAt = reset });
        }

        public static string PickOrganization(object json)
        {
            var orgs = json as object[];
            if (orgs == null) return null;
            string first = null;
            foreach (object o in orgs)
            {
                var org = o as Dictionary<string, object>;
                if (org == null) continue;
                string uuid = Get(org, "uuid") as string;
                if (string.IsNullOrEmpty(uuid)) continue;
                if (first == null) first = uuid;
                var caps = Get(org, "capabilities") as object[];
                if (caps != null && Array.IndexOf(caps, "chat") >= 0) return uuid;
            }
            return first;
        }

        public static string ErrorType(object json)
        {
            var root = json as Dictionary<string, object>;
            if (root == null) return null;
            var err = Get(root, "error") as Dictionary<string, object>;
            if (err != null) return (Get(err, "type") as string) ?? "error";
            return Get(root, "error") != null ? "error" : null;
        }

        public static bool IsAuthError(string type)
        {
            string t = (type ?? "").ToLowerInvariant();
            return t.Contains("auth") || t.Contains("permission") || t.Contains("session");
        }
    }

    // Detecte un jeu, une video ou une presentation en plein ecran, et sur quel ecran il se trouve.
    static class FullscreenApp
    {
        [StructLayout(LayoutKind.Sequential)]
        struct Rect { public int Left, Top, Right, Bottom; }

        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int index);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder name, int size);
        [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);

        const int GwlStyle = -16;
        const int WsCaption = 0x00C00000;
        const int QunsBusy = 2;
        const int QunsD3dFullscreen = 3;
        const int QunsPresentation = 4;

        static IntPtr tracked = IntPtr.Zero;

        // Ecran occupe par un plein ecran, ou null. La fenetre reste suivie quand elle perd le focus :
        // cliquer sur l'autre ecran pendant une partie ne doit pas faire reapparaitre le widget sur le jeu.
        public static Screen ScreenInUse()
        {
            if (tracked != IntPtr.Zero && !CoversItsScreen(tracked)) tracked = IntPtr.Zero;
            IntPtr foreground = GetForegroundWindow();
            if (IsFullscreen(foreground)) tracked = foreground;
            return tracked == IntPtr.Zero ? null : Screen.FromHandle(tracked);
        }

        static bool IsFullscreen(IntPtr h)
        {
            if (!CoversItsScreen(h)) return false;

            // Une fenetre agrandie sur un ecran sans barre des taches couvre aussi tout l'ecran, mais garde sa barre de titre.
            if ((GetWindowLong(h, GwlStyle) & WsCaption) != WsCaption) return true;

            int state;
            return SHQueryUserNotificationState(out state) == 0
                && (state == QunsBusy || state == QunsD3dFullscreen || state == QunsPresentation);
        }

        static bool CoversItsScreen(IntPtr h)
        {
            if (h == IntPtr.Zero || !IsWindow(h) || !IsWindowVisible(h) || IsIconic(h)) return false;

            var name = new System.Text.StringBuilder(64);
            GetClassName(h, name, name.Capacity);
            string cls = name.ToString();
            if (cls == "Progman" || cls == "WorkerW") return false; // le bureau lui-meme

            Rect r;
            if (!GetWindowRect(h, out r)) return false;
            Rectangle screen = Screen.FromHandle(h).Bounds;
            return r.Left <= screen.Left && r.Top <= screen.Top && r.Right >= screen.Right && r.Bottom >= screen.Bottom;
        }

        public static string Describe()
        {
            Screen s = ScreenInUse();
            return "ecranOccupe=" + (s == null ? "aucun" : s.DeviceName);
        }
    }

    // Reconnait l'app Claude de bureau, sans la confondre avec Claude Code lance dans un terminal.
    static class ClaudeApp
    {
        public static bool IsRunning()
        {
            foreach (System.Diagnostics.Process p in System.Diagnostics.Process.GetProcessesByName("claude"))
            {
                try
                {
                    string path = p.MainModule.FileName;
                    if (path.IndexOf("WindowsApps", StringComparison.OrdinalIgnoreCase) >= 0
                        || path.IndexOf("AnthropicClaude", StringComparison.OrdinalIgnoreCase) >= 0)
                        return true;
                }
                catch (System.ComponentModel.Win32Exception) { }
                catch (InvalidOperationException) { } // processus termine entre-temps
                finally { p.Dispose(); }
            }
            return false;
        }
    }

    class CodexResult
    {
        public List<Limit> Rows;
        public string Error;
    }

    // Codex donne lui-meme ses limites via son app-server : il garde sa connexion, le widget ne voit aucun jeton.
    static class CodexClient
    {
        const int TimeoutMs = 20000;

        public static bool IsRunning()
        {
            System.Diagnostics.Process[] found = System.Diagnostics.Process.GetProcessesByName("codex");
            foreach (System.Diagnostics.Process p in found) p.Dispose();
            return found.Length > 0;
        }

        public static string FindExecutable()
        {
            foreach (System.Diagnostics.Process p in System.Diagnostics.Process.GetProcessesByName("codex"))
            {
                try { if (p.MainModule.FileName.EndsWith("codex.exe", StringComparison.OrdinalIgnoreCase)) return p.MainModule.FileName; }
                catch (System.ComponentModel.Win32Exception) { }
                catch (InvalidOperationException) { }
                finally { p.Dispose(); }
            }

            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string appBin = Path.Combine(local, "OpenAI", "Codex", "bin");
            string newest = null;
            if (Directory.Exists(appBin))
            {
                foreach (string dir in Directory.GetDirectories(appBin))
                {
                    string candidate = Path.Combine(dir, "codex.exe");
                    if (File.Exists(candidate)
                        && (newest == null || File.GetLastWriteTimeUtc(candidate) > File.GetLastWriteTimeUtc(newest)))
                        newest = candidate;
                }
            }
            if (newest != null) return newest;

            foreach (string dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
            {
                try
                {
                    if (dir.Length > 0 && File.Exists(Path.Combine(dir, "codex.exe"))) return Path.Combine(dir, "codex.exe");
                }
                catch (ArgumentException) { }
            }

            string npm = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm", "codex.cmd");
            return File.Exists(npm) ? npm : null;
        }

        public static CodexResult Read()
        {
            string exe = FindExecutable();
            if (exe == null) return new CodexResult { Error = "Codex introuvable sur cet ordinateur" };

            var info = new System.Diagnostics.ProcessStartInfo(exe, "app-server");
            info.UseShellExecute = false;
            info.CreateNoWindow = true; // jamais de fenetre : rien ne doit gener un jeu
            info.RedirectStandardInput = true;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;
            info.StandardOutputEncoding = System.Text.Encoding.UTF8;

            try
            {
                using (System.Diagnostics.Process p = System.Diagnostics.Process.Start(info))
                using (new System.Threading.Timer(delegate { TryKill(p); }, null, TimeoutMs, Timeout.Infinite))
                {
                    p.BeginErrorReadLine();
                    Send(p, "{\"method\":\"initialize\",\"id\":1,\"params\":{\"clientInfo\":"
                        + "{\"name\":\"claude_usage_widget\",\"title\":\"Claude Usage Widget\",\"version\":\"1.0\"}}}");
                    if (ReadResponse(p, 1) == null) return new CodexResult { Error = "Codex ne répond pas" };

                    Send(p, "{\"method\":\"initialized\"}");
                    Send(p, "{\"method\":\"account/rateLimits/read\",\"id\":2}");
                    Dictionary<string, object> reply = ReadResponse(p, 2);

                    p.StandardInput.Close();
                    if (!p.WaitForExit(3000)) TryKill(p);

                    return Parse(reply);
                }
            }
            catch (Exception ex)
            {
                return new CodexResult { Error = "Lecture Codex impossible : " + ex.Message };
            }
        }

        static void Send(System.Diagnostics.Process p, string json)
        {
            byte[] bytes = new System.Text.UTF8Encoding(false).GetBytes(json + "\n");
            p.StandardInput.BaseStream.Write(bytes, 0, bytes.Length);
            p.StandardInput.BaseStream.Flush();
        }

        static Dictionary<string, object> ReadResponse(System.Diagnostics.Process p, int id)
        {
            string line;
            while ((line = p.StandardOutput.ReadLine()) != null)
            {
                var message = UsageParser.ParseJson(line) as Dictionary<string, object>;
                object value;
                if (message != null && message.TryGetValue("id", out value) && value is int && (int)value == id) return message;
            }
            return null;
        }

        static void TryKill(System.Diagnostics.Process p)
        {
            try { if (!p.HasExited) p.Kill(); }
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }

        public static CodexResult Parse(Dictionary<string, object> reply)
        {
            if (reply == null) return new CodexResult { Error = "Codex ne répond pas" };
            object value;
            if (!reply.TryGetValue("result", out value) || !(value is Dictionary<string, object>))
                return new CodexResult { Error = "Ouvre Codex et connecte-toi" };
            return ParseResult((Dictionary<string, object>)value);
        }

        public static CodexResult ParseResult(Dictionary<string, object> result)
        {
            object value;
            var limits = result.TryGetValue("rateLimits", out value) ? value as Dictionary<string, object> : null;
            var rows = new List<Limit>();
            if (limits != null)
            {
                AddWindow(rows, limits, "primary");
                AddWindow(rows, limits, "secondary");
            }
            if (rows.Count == 0) return new CodexResult { Error = "Aucune limite Codex pour ce compte" };
            return new CodexResult { Rows = rows };
        }

        static void AddWindow(List<Limit> rows, Dictionary<string, object> limits, string key)
        {
            object value;
            var window = limits.TryGetValue(key, out value) ? value as Dictionary<string, object> : null;
            if (window == null || !window.TryGetValue("usedPercent", out value) || value == null) return;

            double percent;
            try { percent = Convert.ToDouble(value, CultureInfo.InvariantCulture); }
            catch (FormatException) { return; }
            catch (InvalidCastException) { return; }
            if (double.IsNaN(percent) || double.IsInfinity(percent) || percent < 0) return;

            DateTime? reset = null;
            if (window.TryGetValue("resetsAt", out value) && value != null)
            {
                try { reset = DateTimeOffset.FromUnixTimeSeconds(Convert.ToInt64(value, CultureInfo.InvariantCulture)).LocalDateTime; }
                catch (FormatException) { }
                catch (InvalidCastException) { }
                catch (ArgumentOutOfRangeException) { }
            }

            double? minutes = null;
            if (window.TryGetValue("windowDurationMins", out value) && value != null)
            {
                try { minutes = Convert.ToDouble(value, CultureInfo.InvariantCulture); }
                catch (FormatException) { }
                catch (InvalidCastException) { }
            }

            rows.Add(new Limit { Label = LabelForMinutes(minutes), Percent = Math.Min(percent, 100), ResetsAt = reset });
        }

        static string LabelForMinutes(double? minutes)
        {
            if (minutes == null) return "Limite";
            double m = minutes.Value;
            if (Math.Abs(m - 300) <= 30) return "Session";
            if (Math.Abs(m - 1440) <= 144) return "Jour";
            if (Math.Abs(m - 10080) <= 1008) return "Semaine";
            if (Math.Abs(m - 43200) <= 4320) return "Mois";
            return "Limite";
        }
    }

    enum Mood { Normal, Panic, Sleepy }

    // Une image de l'animation : la grille de pixels et son decalage (en pixels de mascotte).
    class MascotFrame
    {
        public char[][] Cells;
        public int Dx;
        public int Dy;

        public MascotFrame(string[] rows)
        {
            Cells = new char[rows.Length][];
            for (int i = 0; i < rows.Length; i++) Cells[i] = rows[i].ToCharArray();
        }

        public void Row(int row, string text) { Cells[row] = text.ToCharArray(); }
        public void Put(int row, int col, char c) { Cells[row][col] = c; }

        public void Replace(char from, char to)
        {
            foreach (char[] line in Cells)
                for (int i = 0; i < line.Length; i++)
                    if (line[i] == from) line[i] = to;
        }
    }

    // Petites mascottes en pixel art (10 x 8), dessinees par le code. Ce ne sont pas les logos officiels.
    // '#' corps, 'x' interieur, 'o' details, 'w' texte clair, 'b' goutte, 'z' sommeil, 'r' alerte, '.' transparent.
    class Mascot
    {
        public const int Width = 10;

        public Color Body;
        public Color Inner;
        public Color Detail;
        public Func<int, Mood, MascotFrame> Animate;

        static readonly Color Light = Color.FromArgb(201, 209, 217);
        static readonly Color Sweat = Color.FromArgb(127, 179, 255);
        static readonly Color Sleep = Color.FromArgb(166, 163, 154);
        static readonly Color Alert = Color.FromArgb(226, 88, 76);

        static readonly int[] JumpHeights = { 1, -1, -2, -2, -1, 0 }; // accroupi, saut, atterrissage

        public static readonly Mascot Claude = new Mascot
        {
            Body = Color.FromArgb(217, 119, 87),
            Inner = Color.FromArgb(217, 119, 87),
            Detail = Color.FromArgb(31, 30, 29),
            Animate = ClaudeFrame,
        };

        public static readonly Mascot Codex = new Mascot
        {
            Body = Color.FromArgb(138, 180, 248),
            Inner = Color.FromArgb(27, 39, 51),
            Detail = Color.FromArgb(232, 234, 237),
            Animate = CodexFrame,
        };

        static readonly string[] ClaudeBase =
        {
            "....##....",
            "...####...",
            "..######..",
            "..#o##o#..",
            "..######..",
            "..######..",
            "...####...",
            "..#....#..",
        };

        static readonly string[] CodexBase =
        {
            ".########.",
            ".#xxxxxx#.",
            ".#oxxxxx#.",
            ".#xoxxxx#.",
            ".#oxxoox#.",
            ".#xxxxxx#.",
            ".########.",
            "...#..#...",
        };

        static void Walk(MascotFrame f, int t, string legs)
        {
            if ((t / 4) % 2 == 1)
            {
                f.Row(7, legs);
                f.Dy = -1;
            }
        }

        // Petit Zzz qui monte, en boucle.
        static void Snore(MascotFrame f, int frame, int col)
        {
            int z = (frame / 4) % 4;
            if (z < 3) f.Put(2 - z, z == 0 ? col - 1 : col, 'z');
            f.Dy = (frame / 8) % 2 == 0 ? 0 : 1; // respiration lente
        }

        // Boucle d'environ 11 secondes : marche, clignement, regards, saut, salut, sourire.
        // Au-dela de 90 % elle panique (tremblement, goutte de sueur) ; sous 5 % elle dort.
        static MascotFrame ClaudeFrame(int frame, Mood mood)
        {
            var f = new MascotFrame(ClaudeBase);
            if (frame == 0) return f;

            if (mood == Mood.Panic)
            {
                f.Dx = frame % 2;
                f.Row(5, "..###o##..");
                int drop = frame % 4;
                if (drop < 3) f.Put(1 + drop, 8, 'b');
                if (frame % 2 == 1) f.Row(7, "...#..#...");
                return f;
            }
            if (mood == Mood.Sleepy)
            {
                f.Row(3, "..######..");
                Snore(f, frame, 9);
                return f;
            }

            int t = frame % 96;
            if (t < 24) Walk(f, t, "...#..#...");
            else if (t < 26) f.Row(3, "..######..");                // clignement
            else if (t < 34) { }
            else if (t < 40) f.Row(3, "..o##o##..");                // regarde a gauche
            else if (t < 46) f.Row(3, "..##o##o..");                // regarde a droite
            else if (t < 50) { }
            else if (t < 56) f.Dy = JumpHeights[t - 50];            // saut
            else if (t < 68)
            {
                bool up = ((t - 56) / 2) % 2 == 0;                  // salut de la main
                f.Row(2, up ? "..######.#" : "..######..");
                f.Row(3, up ? "..#o##o##." : "..#o##o###");
            }
            else if (t < 76) f.Row(5, "..##oo##..");                // sourire
            else Walk(f, t, "...#..#...");
            return f;
        }

        static void HideCursor(MascotFrame f)
        {
            f.Put(4, 5, 'x');
            f.Put(4, 6, 'x');
        }

        static void ScreenOff(MascotFrame f)
        {
            for (int row = 1; row <= 5; row++) f.Row(row, ".#xxxxxx#.");
        }

        // Boucle d'environ 10 secondes : curseur, frappe, lignes de resultat, marche, saut, ecran qui clignote.
        // Au-dela de 90 % l'ecran vire au rouge ; sous 5 % il se met en veille.
        static MascotFrame CodexFrame(int frame, Mood mood)
        {
            var f = new MascotFrame(CodexBase);
            if (frame == 0) return f;

            if (mood == Mood.Panic)
            {
                f.Dx = frame % 2;
                if (frame % 4 < 2) f.Replace('x', 'r');
                if (frame % 2 == 1) f.Row(7, "..#....#..");
                return f;
            }
            if (mood == Mood.Sleepy)
            {
                ScreenOff(f);
                Snore(f, frame, 9);
                return f;
            }

            int t = frame % 80;
            if (t < 16)
            {
                if ((t / 4) % 2 == 1) HideCursor(f);
            }
            else if (t < 28)
            {
                int typed = Math.Min(3, (t - 16) / 2);                // frappe de quelques caracteres
                for (int col = 3; col <= 7; col++) f.Put(4, col, 'x');
                for (int i = 0; i < typed; i++) f.Put(4, 4 + i, 'w');
                if (t < 24 || t % 4 < 2) f.Put(4, 4 + typed, 'o');
            }
            else if (t < 40)
            {
                f.Row(1, ".#wwwwxx#.");                               // lignes de resultat
                f.Row(2, ".#xxxxxx#.");
                f.Row(3, ".#wwwxwx#.");
                f.Row(4, ".#xxxxxx#.");
                f.Row(5, ".#wwxxxx#.");
            }
            else if (t < 56)
            {
                Walk(f, t, "..#....#..");
                if ((t / 4) % 2 == 1) HideCursor(f);
            }
            else if (t < 62) f.Dy = JumpHeights[t - 56];
            else if (t < 64) ScreenOff(f);
            else if ((t / 4) % 2 == 1) HideCursor(f);
            return f;
        }

        // frame avance d'un cran toutes les 120 ms ; 0 donne la pose fixe.
        public void Draw(Graphics g, float x, float y, int pixel, int frame, Mood mood)
        {
            MascotFrame f = Animate(frame, mood);
            SmoothingMode previous = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.None;
            using (var body = new SolidBrush(Body))
            using (var inner = new SolidBrush(Inner))
            using (var detail = new SolidBrush(Detail))
            using (var light = new SolidBrush(Light))
            using (var sweat = new SolidBrush(Sweat))
            using (var sleep = new SolidBrush(Sleep))
            using (var alert = new SolidBrush(Alert))
            {
                for (int row = 0; row < f.Cells.Length; row++)
                {
                    for (int col = 0; col < f.Cells[row].Length; col++)
                    {
                        Brush b;
                        switch (f.Cells[row][col])
                        {
                            case '#': b = body; break;
                            case 'x': b = inner; break;
                            case 'o': b = detail; break;
                            case 'w': b = light; break;
                            case 'b': b = sweat; break;
                            case 'z': b = sleep; break;
                            case 'r': b = alert; break;
                            default: b = null; break;
                        }
                        if (b != null)
                            g.FillRectangle(b, (int)x + (col + f.Dx) * pixel, (int)y + (row + f.Dy) * pixel, pixel, pixel);
                    }
                }
            }
            g.SmoothingMode = previous;
        }

        public static Mood MoodOf(List<Limit> rows)
        {
            if (rows.Count == 0) return Mood.Normal;
            double max = 0;
            foreach (Limit l in rows) max = Math.Max(max, l.Percent);
            if (max >= 90) return Mood.Panic;
            if (max <= 5) return Mood.Sleepy;
            return Mood.Normal;
        }
    }

    // Verifie sur GitHub si une version plus recente est publiee. Rien d'autre n'est envoye.
    static class Updates
    {
        public const string Version = "1.0.2";
        public const string ReleasesUrl = "https://github.com/ParvaCamer/session-ai-usage-widget/releases/latest";
        const string ApiUrl = "https://api.github.com/repos/ParvaCamer/session-ai-usage-widget/releases/latest";

        public static readonly string[] Arrow =
        {
            "..###..",
            "..###..",
            "..###..",
            "#######",
            ".#####.",
            "..###..",
            "...#...",
            "#######",
        };

        // Numero de la version plus recente, ou null (a jour, pas de reseau, pas encore de version publiee).
        // zipUrl recoit l'adresse du zip publie avec cette version, ou null s'il manque.
        public static string NewerVersion(out string zipUrl)
        {
            zipUrl = null;
            try
            {
                System.Net.ServicePointManager.SecurityProtocol |= System.Net.SecurityProtocolType.Tls12;
                var request = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(ApiUrl);
                request.UserAgent = "claude-usage-widget/" + Version;
                request.Accept = "application/vnd.github+json";
                request.Timeout = 15000;
                using (var response = request.GetResponse())
                using (var reader = new StreamReader(response.GetResponseStream()))
                {
                    var json = UsageParser.ParseJson(reader.ReadToEnd()) as Dictionary<string, object>;
                    object tag;
                    if (json == null || !json.TryGetValue("tag_name", out tag) || !(tag is string)) return null;
                    string latest = ((string)tag).TrimStart('v', 'V');
                    System.Version remote, local;
                    if (!System.Version.TryParse(latest, out remote) || !System.Version.TryParse(Version, out local) || remote <= local)
                        return null;
                    object assets;
                    if (json.TryGetValue("assets", out assets) && assets is object[])
                        foreach (object item in (object[])assets)
                        {
                            var asset = item as Dictionary<string, object>;
                            object name, url;
                            if (asset != null && asset.TryGetValue("name", out name) && (name as string) == SelfUpdater.AssetName
                                && asset.TryGetValue("browser_download_url", out url) && url is string
                                && ((string)url).StartsWith("https://github.com/"))
                                zipUrl = (string)url;
                        }
                    return latest;
                }
            }
            catch (System.Net.WebException) { return null; }
            catch (IOException) { return null; }
        }
    }

    // Mise a jour en un clic : telecharge le zip publie, remplace les fichiers du widget puis le relance.
    // Un exe en cours d'execution ne peut pas etre ecrase, mais il peut etre renomme : les anciens fichiers
    // deviennent *.old et sont supprimes au lancement suivant. En cas d'echec, tout est remis en place.
    static class SelfUpdater
    {
        public const string AssetName = "ClaudeUsage-Windows.zip";
        public const string RestartArg = "--updated";

        static string AppDir { get { return Path.GetDirectoryName(Application.ExecutablePath); } }

        // A appeler hors du fil de l'interface. Renvoie null si la nouvelle version est installee, sinon la raison de l'echec.
        public static string Install(string zipUrl)
        {
            string work = Path.Combine(Path.GetTempPath(), "ClaudeUsageUpdate-" + Guid.NewGuid().ToString("N"));
            try
            {
                Directory.CreateDirectory(work);
                string zip = Path.Combine(work, AssetName);
                try
                {
                    System.Net.ServicePointManager.SecurityProtocol |= System.Net.SecurityProtocolType.Tls12;
                    using (var client = new System.Net.WebClient())
                    {
                        client.Headers["User-Agent"] = "claude-usage-widget/" + Updates.Version;
                        client.DownloadFile(zipUrl, zip);
                    }
                }
                catch (System.Net.WebException) { return "téléchargement impossible"; }

                string extracted = Path.Combine(work, "zip");
                try { System.IO.Compression.ZipFile.ExtractToDirectory(zip, extracted); }
                catch (InvalidDataException) { return "zip illisible"; }

                // Le zip contient un dossier ClaudeUsage avec l'exe, les dll et les licences.
                string source = Path.Combine(extracted, "ClaudeUsage");
                string newExe = Path.Combine(source, "ClaudeUsage.exe");
                if (!File.Exists(newExe)) return "zip incomplet";
                try { System.Reflection.AssemblyName.GetAssemblyName(newExe); }
                catch (BadImageFormatException) { return "exe téléchargé invalide"; }

                return Replace(source, AppDir);
            }
            catch (IOException) { return "fichiers inaccessibles"; }
            catch (UnauthorizedAccessException) { return "dossier du widget protégé en écriture"; }
            finally
            {
                try { Directory.Delete(work, true); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }

        static string Replace(string source, string appDir)
        {
            var renamed = new List<string>();
            var copied = new List<string>();
            try
            {
                foreach (string file in Directory.GetFiles(source))
                {
                    string target = Path.Combine(appDir, Path.GetFileName(file));
                    if (File.Exists(target))
                    {
                        string old = target + ".old";
                        if (File.Exists(old)) File.Delete(old);
                        File.Move(target, old);
                        renamed.Add(target);
                    }
                    File.Copy(file, target);
                    copied.Add(target);
                }
                return null;
            }
            catch (IOException) { Rollback(renamed, copied); return "remplacement impossible"; }
            catch (UnauthorizedAccessException) { Rollback(renamed, copied); return "dossier du widget protégé en écriture"; }
        }

        static void Rollback(List<string> renamed, List<string> copied)
        {
            foreach (string file in copied)
            {
                try { File.Delete(file); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            foreach (string file in renamed)
            {
                try { File.Move(file + ".old", file); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }

        // Lance la nouvelle version, qui attend la fermeture de celle-ci avant de demarrer.
        public static void Restart()
        {
            try { System.Diagnostics.Process.Start(Application.ExecutablePath, RestartArg); }
            catch (System.ComponentModel.Win32Exception) { return; }
            Application.Exit();
        }

        // Au lancement : supprime les fichiers de la version precedente.
        public static void CleanUp()
        {
            try
            {
                foreach (string file in Directory.GetFiles(AppDir, "*.old"))
                {
                    try { File.Delete(file); }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    // Une colonne d'informations par outil suivi.
    class Section
    {
        public Mascot Mascot;
        public string Name;
        public bool Visible;
        public List<Limit> Rows = new List<Limit>();
        public string Message = "Chargement…";
        public bool NeedLogin;
        public DateTime LastOk = DateTime.MinValue;
    }

    // Fenetre du navigateur : hors de l'ecran pendant les mises a jour, visible pour se connecter.
    // Sa structure ne change jamais, car recreer la fenetre casserait le controle WebView2.
    class BrowserForm : Form
    {
        const int GwlExStyle = -20;
        const int WsExNoActivate = 0x08000000;

        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int index);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hWnd, int index, int value);

        public bool LoginVisible;

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= WsExNoActivate;
                return cp;
            }
        }

        // Hors connexion, cette fenetre ne peut pas devenir active : elle ne prendra jamais le focus d'un jeu.
        public void AllowActivation(bool allow)
        {
            int style = GetWindowLong(Handle, GwlExStyle);
            SetWindowLong(Handle, GwlExStyle, allow ? style & ~WsExNoActivate : style | WsExNoActivate);
        }

        public BrowserForm()
        {
            Text = "Connexion à Claude";
            FormBorderStyle = FormBorderStyle.SizableToolWindow;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000);
            ClientSize = new Size(480, 720);
        }

        protected override bool ShowWithoutActivation { get { return !LoginVisible; } }
    }

    class WidgetForm : Form
    {
        const int PollMinutes = 2;
        const int WatchdogSeconds = 30;
        const string BaseUrl = "https://claude.ai";
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunValue = "ClaudeUsageWidget";

        enum Step { None, Organizations, Usage }

        static readonly string DataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClaudeUsageWidget");
        static readonly string SettingsPath = Path.Combine(DataDir, "settings.txt");
        static readonly string LogPath = Path.Combine(DataDir, "journal.txt"); // etats et codes HTTP, jamais de contenu

        static readonly Color Bg = Color.FromArgb(31, 30, 29);
        static readonly Color Line = Color.FromArgb(62, 60, 56);
        static readonly Color Track = Color.FromArgb(58, 56, 52);
        static readonly Color TextMain = Color.FromArgb(245, 244, 239);
        static readonly Color TextMuted = Color.FromArgb(166, 163, 154);
        static readonly Color Accent = Color.FromArgb(217, 119, 87);
        static readonly Color Warn = Color.FromArgb(232, 175, 72);
        static readonly Color Danger = Color.FromArgb(226, 88, 76);

        readonly Font fontLabel = new Font("Segoe UI", 9f);
        readonly Font fontValue = new Font("Segoe UI Semibold", 10f);
        readonly Font fontSmall = new Font("Segoe UI", 8f);

        readonly float scale;
        readonly System.Windows.Forms.Timer pollTimer = new System.Windows.Forms.Timer();
        readonly System.Windows.Forms.Timer watchdog = new System.Windows.Forms.Timer();
        readonly System.Windows.Forms.Timer repaintTimer = new System.Windows.Forms.Timer();
        readonly System.Windows.Forms.Timer fullscreenTimer = new System.Windows.Forms.Timer();
        readonly System.Windows.Forms.Timer animTimer = new System.Windows.Forms.Timer();
        readonly List<Rectangle> mascotAreas = new List<Rectangle>();
        int animFrame;
        readonly System.Windows.Forms.Timer updateTimer = new System.Windows.Forms.Timer();
        readonly ToolStripMenuItem updateItem = new ToolStripMenuItem();
        string updateVersion;
        string updateZipUrl;
        bool updating; // la fleche passe au gris pendant l'installation
        Rectangle updateHit;
        readonly bool waitForApps;
        bool hiddenNow;
        readonly ToolStripMenuItem topMostItem = new ToolStripMenuItem("Toujours au premier plan");
        readonly ToolStripMenuItem autoStartItem = new ToolStripMenuItem("Se lancer avec l'app Claude ou Codex");

        readonly Section claude = new Section { Name = "Claude", Mascot = Mascot.Claude };
        readonly Section codex = new Section { Name = "Codex", Mascot = Mascot.Codex };
        readonly ToolStripMenuItem showClaudeItem = new ToolStripMenuItem("Afficher Claude");
        readonly ToolStripMenuItem showCodexItem = new ToolStripMenuItem("Afficher Codex");
        bool codexBusy;
        DateTime lastRefresh = DateTime.MinValue;

        BrowserForm browser;
        WebView2 web;
        bool webReady;
        Step step = Step.None;
        string orgId;
        int lastStatus;

        public WidgetForm(bool waitForApps)
        {
            this.waitForApps = waitForApps;
            if (waitForApps) Opacity = 0; // evite un flash au demarrage de Windows, avant de savoir si une app est ouverte
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            DoubleBuffered = true;
            BackColor = Bg;
            Text = "Utilisation Claude";
            using (Graphics g = CreateGraphics()) scale = g.DpiX / 96f;
            Size = new Size(S(236), S(96));

            ContextMenuStrip = BuildMenu();
            LoadSettings();

            pollTimer.Interval = PollMinutes * 60 * 1000;
            pollTimer.Tick += delegate { RefreshAll(); };
            watchdog.Interval = WatchdogSeconds * 1000;
            watchdog.Tick += delegate { OnWatchdog(); };
            repaintTimer.Interval = 30 * 1000;
            repaintTimer.Tick += delegate { Invalidate(); };
            fullscreenTimer.Interval = 3000;
            fullscreenTimer.Tick += delegate { UpdateState(); };

            updateTimer.Interval = 6 * 60 * 60 * 1000; // nouvelles versions : toutes les 6 heures
            updateTimer.Tick += delegate { CheckForUpdate(); };

            // Seules les mascottes sont redessinees, et rien du tout quand le widget est masque.
            animTimer.Interval = 120;
            animTimer.Tick += delegate
            {
                if (hiddenNow) return;
                animFrame++;
                foreach (Rectangle area in mascotAreas) Invalidate(area);
            };
        }

        int S(float v) { return (int)Math.Round(v * scale); }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x80;       // WS_EX_TOOLWINDOW : pas dans Alt+Tab
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE : cliquer dessus ne prend pas le focus
                return cp;
            }
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int cmd);
        const int SwHide = 0;
        const int SwShowNoActivate = 4;

        // Le widget se masque si aucune app suivie n'est ouverte, ou si un plein ecran occupe SON ecran.
        // Un jeu sur l'autre ecran ne change rien. Il revient toujours sans prendre le focus.
        void UpdateState()
        {
            bool appsOpen = !waitForApps
                || (claude.Visible && ClaudeApp.IsRunning())
                || (codex.Visible && CodexClient.IsRunning());

            bool wantBrowser = claude.Visible && appsOpen;
            if (wantBrowser && browser == null) StartBrowser();
            else if (!wantBrowser && browser != null && !browser.LoginVisible) StopBrowser();

            Screen occupied = FullscreenApp.ScreenInUse();
            bool onOccupiedScreen = occupied != null
                && occupied.DeviceName == Screen.FromRectangle(Bounds).DeviceName;

            bool hide = !appsOpen || onOccupiedScreen;
            if (hide == hiddenNow) return;
            hiddenNow = hide;
            ShowWindow(Handle, hide ? SwHide : SwShowNoActivate);
            if (!hide) RefreshAll();
        }

        void RefreshAll()
        {
            lastRefresh = DateTime.Now;
            Poll();
            PollCodex();
        }

        async void PollCodex()
        {
            if (!codex.Visible || hiddenNow || codexBusy) return;
            codexBusy = true;
            try
            {
                CodexResult result = await System.Threading.Tasks.Task.Run(() => CodexClient.Read());
                if (result.Rows != null)
                {
                    SetCodexRows(result.Rows);
                }
                else
                {
                    Log("codex : " + result.Error);
                    codex.Message = result.Error;
                    UpdateShape();
                }
            }
            finally
            {
                codexBusy = false;
            }
        }

        // Plus aucune raison d'afficher Claude : on libere le moteur Edge, le widget ne consomme presque rien.
        void StopBrowser()
        {
            FinishPoll();
            webReady = false;
            web.Dispose();
            browser.Dispose();
            web = null;
            browser = null;
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            UpdateShape();
            pollTimer.Start();
            repaintTimer.Start();
            fullscreenTimer.Start();
            animTimer.Start();
            updateTimer.Start();
            CheckForUpdate();
        }

        async void CheckForUpdate()
        {
            string zipUrl = null;
            string newer = await System.Threading.Tasks.Task.Run(() => Updates.NewerVersion(out zipUrl));
            if (newer == null || newer == updateVersion || updating) return;
            updateVersion = newer;
            updateZipUrl = zipUrl;
            updateItem.Text = "Mettre à jour vers la v" + newer;
            updateItem.Visible = true;
            Log("mise a jour disponible : v" + newer);
            Invalidate();
        }

        // Clic sur la fleche ou sur le menu : installe la nouvelle version, ou ouvre la page si ce n'est pas possible.
        async void StartUpdate()
        {
            if (updating) return;
            if (updateZipUrl == null) { OpenReleasesPage(); return; }
            updating = true;
            updateItem.Text = "Mise à jour en cours…";
            updateItem.Enabled = false;
            Invalidate();

            string url = updateZipUrl;
            string failure = await System.Threading.Tasks.Task.Run(() => SelfUpdater.Install(url));
            if (failure == null)
            {
                Log("mise a jour installee : v" + updateVersion);
                SelfUpdater.Restart();
                return;
            }
            Log("mise a jour impossible : " + failure);
            updating = false;
            updateItem.Text = "Mettre à jour vers la v" + updateVersion;
            updateItem.Enabled = true;
            Invalidate();
            OpenReleasesPage(); // repli : la page de telechargement, comme avant
        }

        static void OpenReleasesPage()
        {
            try { System.Diagnostics.Process.Start(Updates.ReleasesUrl); }
            catch (System.ComponentModel.Win32Exception) { }
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            UpdateState();
            if (waitForApps) Opacity = 1;
            PollCodex();
        }

        // ---------- Donnees ----------

        async void StartBrowser()
        {
            try
            {
                browser = new BrowserForm();
                web = new WebView2();
                web.Dock = DockStyle.Fill;
                browser.Controls.Add(web);
                browser.FormClosing += OnBrowserClosing;
                browser.Show();

                Directory.CreateDirectory(DataDir);
                CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(DataDir, "web"));
                await web.EnsureCoreWebView2Async(env);
                web.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
                web.CoreWebView2.SourceChanged += delegate { CheckLoginFinished(); };
                web.CoreWebView2.MemoryUsageTargetLevel = CoreWebView2MemoryUsageTargetLevel.Low;
                webReady = true;
                Poll();
            }
            catch (WebView2RuntimeNotFoundException)
            {
                ShowMessage("Installe « WebView2 Runtime » de Microsoft, puis relance.");
            }
            catch (Exception ex)
            {
                ShowMessage("Navigateur indisponible : " + ex.Message);
            }
        }

        void Poll()
        {
            if (!webReady || browser.LoginVisible || step != Step.None) return;
            if (hiddenNow) return; // rattrape des que le widget redevient visible
            watchdog.Stop();
            watchdog.Start();
            if (orgId == null)
            {
                step = Step.Organizations;
                web.CoreWebView2.Navigate(BaseUrl + "/api/organizations");
            }
            else
            {
                step = Step.Usage;
                web.CoreWebView2.Navigate(BaseUrl + "/api/organizations/" + Uri.EscapeDataString(orgId) + "/usage");
            }
        }

        async void OnNavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs e)
        {
            if (browser == null) return;
            if (browser.LoginVisible)
            {
                CheckLoginFinished();
                return;
            }
            if (step == Step.None) return;

            // Navigation remplacee par une autre : la page affichee n'est pas celle attendue.
            if (e.WebErrorStatus == CoreWebView2WebErrorStatus.OperationCanceled) return;

            lastStatus = e.HttpStatusCode;

            if (IsOffline(e.WebErrorStatus))
            {
                FinishPoll();
                ShowProblem("Pas de connexion réseau");
                return;
            }

            try
            {
                Uri source = new Uri(web.Source.ToString());
                if (source.Host != "claude.ai") return;

                string raw = await web.ExecuteScriptAsync("document.body ? document.body.innerText : ''");
                string text = new JavaScriptSerializer().Deserialize<string>(raw);
                object json = UsageParser.ParseJson(text);

                // Page HTML : verification Cloudflare en cours. Le chien de garde prend le relais si elle ne se termine pas.
                if (json == null) return;

                HandleResponse(json);
                Rest();
            }
            catch (Exception ex)
            {
                FinishPoll();
                ShowProblem("Lecture impossible : " + ex.Message);
            }
        }

        void HandleResponse(object json)
        {
            string error = UsageParser.ErrorType(json);
            if (error != null)
            {
                // Seul un vrai refus d'acces demande une connexion : une surcharge ne doit pas te deconnecter.
                bool loginNeeded = lastStatus == 401 || lastStatus == 403 || UsageParser.IsAuthError(error);
                Log("erreur etape=" + step + " http=" + lastStatus + " type=" + error);
                FinishPoll();
                if (loginNeeded)
                {
                    orgId = null;
                    ShowLoginNeeded("Clique ici pour te connecter à claude.ai");
                }
                else
                {
                    ShowProblem("claude.ai a répondu : " + error);
                }
                return;
            }

            if (step == Step.Organizations)
            {
                orgId = UsageParser.PickOrganization(json);
                FinishPoll();
                if (orgId == null)
                {
                    ShowLoginNeeded("Clique ici pour te connecter à claude.ai");
                    return;
                }
                Poll();
                return;
            }

            try
            {
                List<Limit> parsed = UsageParser.Parse(json);
                FinishPoll();
                SetRows(parsed);
            }
            catch (FormatException ex)
            {
                FinishPoll();
                ShowProblem(ex.Message);
            }
        }

        static bool IsOffline(CoreWebView2WebErrorStatus status)
        {
            return status == CoreWebView2WebErrorStatus.Disconnected
                || status == CoreWebView2WebErrorStatus.CannotConnect
                || status == CoreWebView2WebErrorStatus.HostNameNotResolved
                || status == CoreWebView2WebErrorStatus.Timeout
                || status == CoreWebView2WebErrorStatus.ServerUnreachable
                || status == CoreWebView2WebErrorStatus.ConnectionAborted
                || status == CoreWebView2WebErrorStatus.ConnectionReset;
        }

        void FinishPoll()
        {
            step = Step.None;
            watchdog.Stop();
        }

        // Entre deux lectures, le navigateur attend sur une page vide pour consommer le moins possible.
        void Rest()
        {
            if (!webReady || browser.LoginVisible || step != Step.None) return;
            web.CoreWebView2.Navigate("about:blank");
        }

        void OnWatchdog()
        {
            Log("delai depasse etape=" + step + " http=" + lastStatus);
            FinishPoll();
            if (claude.Rows.Count > 0) ShowProblem("claude.ai ne répond pas");
            else ShowLoginNeeded("Vérification requise : clique pour ouvrir claude.ai");
        }

        static void Log(string line)
        {
            try
            {
                Directory.CreateDirectory(DataDir);
                if (File.Exists(LogPath) && new FileInfo(LogPath).Length > 64 * 1024) File.Delete(LogPath);
                File.AppendAllText(LogPath, DateTime.Now.ToString("s") + " " + line + "\r\n");
            }
            catch (IOException) { }
        }

        // ---------- Connexion ----------

        void OpenLogin()
        {
            if (!webReady || hiddenNow) return;
            FinishPoll();
            browser.LoginVisible = true;
            browser.AllowActivation(true);
            web.CoreWebView2.MemoryUsageTargetLevel = CoreWebView2MemoryUsageTargetLevel.Normal;
            Rectangle area = Screen.FromControl(this).WorkingArea;
            browser.Location = new Point(
                area.Left + (area.Width - browser.Width) / 2,
                area.Top + (area.Height - browser.Height) / 2);
            browser.Activate();
            Log("fenetre de connexion ouverte");
            // La page d'accueil ne montre le formulaire que si la session n'est vraiment plus valable.
            web.CoreWebView2.Navigate(BaseUrl + "/");
        }

        void CheckLoginFinished()
        {
            if (browser == null || !browser.LoginVisible) return;
            Uri u;
            if (!Uri.TryCreate(web.Source == null ? "" : web.Source.ToString(), UriKind.Absolute, out u)) return;
            if (u.Host != "claude.ai") return;
            string p = u.AbsolutePath;
            if (p == "/" || p.StartsWith("/login") || p.StartsWith("/magic-link") || p.StartsWith("/cdn-cgi")
                || p.StartsWith("/api")) return;
            CloseLogin();
            Poll();
        }

        void CloseLogin()
        {
            browser.LoginVisible = false;
            browser.AllowActivation(false);
            web.CoreWebView2.MemoryUsageTargetLevel = CoreWebView2MemoryUsageTargetLevel.Low;
            browser.Location = new Point(-32000, -32000);
        }

        void OnBrowserClosing(object sender, FormClosingEventArgs e)
        {
            // Le navigateur sert aussi aux mises a jour : seule la sortie du programme le ferme vraiment.
            if (e.CloseReason == CloseReason.ApplicationExitCall
                || e.CloseReason == CloseReason.WindowsShutDown
                || e.CloseReason == CloseReason.TaskManagerClosing) return;
            e.Cancel = true;
            CloseLogin();
            Poll();
        }

        // ---------- Etat affiche ----------

        public void SetRows(List<Limit> newRows)
        {
            claude.Rows = newRows;
            claude.Message = null;
            claude.NeedLogin = false;
            claude.LastOk = DateTime.Now;
            UpdateShape();
        }

        public void SetCodexRows(List<Limit> newRows)
        {
            codex.Rows = newRows;
            codex.Message = null;
            codex.LastOk = DateTime.Now;
            UpdateShape();
        }

        // Pour le mode demo : affiche la fleche comme si une version plus recente existait.
        public void SetUpdateForDemo(string version)
        {
            updateVersion = version;
        }

        // Pour le mode demo : choisit les sections a dessiner.
        public void SetVisibleSections(bool showClaude, bool showCodex)
        {
            claude.Visible = showClaude;
            codex.Visible = showCodex;
            UpdateShape();
        }

        void ShowMessage(string text)
        {
            claude.Message = text;
            UpdateShape();
        }

        // Les derniers chiffres restent affiches, avec leur age, pour ne jamais les faire passer pour frais.
        void ShowProblem(string text)
        {
            claude.NeedLogin = false;
            ShowMessage(text);
        }

        void ShowLoginNeeded(string text)
        {
            claude.NeedLogin = true;
            claude.Rows = new List<Limit>();
            ShowMessage(text);
        }

        // ---------- Dessin ----------

        const float Pad = 12f;
        const float RowHeight = 46f;
        const float FooterHeight = 18f;
        const float MessageHeight = 44f;
        const float HeaderHeight = 22f;
        const float SectionGap = 10f;

        float SectionHeight(Section s)
        {
            float h = HeaderHeight;
            if (s.Rows.Count > 0)
            {
                h += s.Rows.Count * RowHeight - 6;
                if (s.Message != null) h += FooterHeight;
            }
            else
            {
                h += MessageHeight;
            }
            return h;
        }

        void UpdateShape()
        {
            float h = Pad * 2;
            int shown = 0;
            foreach (Section s in new[] { claude, codex })
            {
                if (!s.Visible) continue;
                if (shown++ > 0) h += SectionGap;
                h += SectionHeight(s);
            }
            if (shown == 0) h += MessageHeight;
            Size = new Size(S(236), S(h));
            using (GraphicsPath path = RoundedRect(new RectangleF(0, 0, Width, Height), S(10)))
            {
                Region old = Region;
                Region = new Region(path);
                if (old != null) old.Dispose();
            }
            Invalidate();
        }

        static GraphicsPath RoundedRect(RectangleF r, float radius)
        {
            float d = radius * 2;
            var p = new GraphicsPath();
            p.AddArc(r.Left, r.Top, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Top, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Render(e.Graphics);
        }

        public void Render(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            g.Clear(Bg);

            using (var pen = new Pen(Line))
            using (GraphicsPath border = RoundedRect(new RectangleF(0, 0, Width - 1, Height - 1), S(10)))
                g.DrawPath(pen, border);

            float x = S(Pad);
            float w = Width - 2 * x;
            float y = S(Pad);

            int shown = 0;
            mascotAreas.Clear();
            foreach (Section s in new[] { claude, codex })
            {
                if (!s.Visible) continue;
                if (shown++ > 0) y += S(SectionGap);
                DrawSection(g, s, x, y, w);
                y += S(SectionHeight(s));
            }

            if (shown == 0)
            {
                using (var b = new SolidBrush(TextMuted))
                    DrawText(g, "Clic droit pour choisir Claude ou Codex", fontLabel, b, x, y, w, S(MessageHeight));
            }

            if (updateVersion != null) DrawUpdateArrow(g);
        }

        // Fleche de telechargement en haut a droite, qui rebondit doucement. Un clic ouvre la page des versions.
        void DrawUpdateArrow(Graphics g)
        {
            int pixel = Math.Max(2, S(2));
            int width = Updates.Arrow[0].Length * pixel;
            int left = Width - S(Pad) - width;
            int top = S(Pad) + S(2) + (!updating && (animFrame / 4) % 2 == 1 ? pixel : 0);
            SmoothingMode previous = g.SmoothingMode;
            g.SmoothingMode = SmoothingMode.None; // sans lissage, sinon les pixels laissent des joints
            using (var green = new SolidBrush(updating ? TextMuted : Color.FromArgb(111, 207, 151)))
            {
                for (int row = 0; row < Updates.Arrow.Length; row++)
                    for (int col = 0; col < Updates.Arrow[row].Length; col++)
                        if (Updates.Arrow[row][col] == '#')
                            g.FillRectangle(green, left + col * pixel, top + row * pixel, pixel, pixel);
            }
            g.SmoothingMode = previous;
            int pad = Math.Max(S(5), (S(24) - width) / 2);
            updateHit = new Rectangle(left - pad, S(Pad) - pad, width + 2 * pad, 9 * pixel + 2 * pad);
            mascotAreas.Add(new Rectangle(left - 1, S(Pad), width + 2, 10 * pixel + 2));
        }

        void DrawSection(Graphics g, Section s, float x, float y, float w)
        {
            int pixel = Math.Max(2, S(2));
            float mascotY = y + (S(HeaderHeight) - 8 * pixel) / 2f - S(2);
            s.Mascot.Draw(g, x, mascotY, pixel, animFrame, Mascot.MoodOf(s.Rows));
            // Zone a redessiner a chaque image : la mascotte, son saut et son tremblement.
            mascotAreas.Add(new Rectangle((int)x - pixel - 1, (int)mascotY - 3 * pixel - 1,
                (Mascot.Width + 2) * pixel + 2, 12 * pixel + 2));
            using (var main = new SolidBrush(TextMuted))
                DrawText(g, s.Name, fontValue, main, x + Mascot.Width * pixel + S(4), y, w, S(HeaderHeight));
            y += S(HeaderHeight);

            foreach (Limit row in s.Rows)
            {
                DrawRow(g, row, x, y, w, s.Mascot.Body);
                y += S(RowHeight);
            }

            if (s.Rows.Count > 0 && s.Message != null)
            {
                y -= S(4);
                using (var b = new SolidBrush(Warn))
                    DrawText(g, Footer(s), fontSmall, b, x, y, w, S(FooterHeight));
            }
            else if (s.Rows.Count == 0)
            {
                using (var b = new SolidBrush(s.NeedLogin ? Accent : TextMuted))
                    DrawText(g, s.Message ?? "", fontLabel, b, x, y, w, S(MessageHeight));
            }
        }

        static string Footer(Section s)
        {
            if (s.LastOk == DateTime.MinValue) return s.Message;
            int minutes = (int)(DateTime.Now - s.LastOk).TotalMinutes;
            return minutes < 1 ? s.Message : s.Message + " · il y a " + minutes + " min";
        }

        void DrawRow(Graphics g, Limit row, float x, float y, float w, Color normal)
        {
            string value = Math.Round(row.Percent).ToString(CultureInfo.InvariantCulture) + " %";
            Color color = row.Percent >= 90 ? Danger : row.Percent >= 70 ? Warn : normal;

            float valueW = g.MeasureString(value, fontValue).Width;
            using (var main = new SolidBrush(TextMain))
            {
                DrawText(g, row.Label, fontLabel, main, x, y, w - valueW, S(18));
                using (var format = new StringFormat(StringFormatFlags.NoWrap))
                {
                    format.Alignment = StringAlignment.Far;
                    g.DrawString(value, fontValue, main, new RectangleF(x, y - S(1), w, S(20)), format);
                }
            }

            float barY = y + S(20);
            float barH = S(4);
            using (var track = new SolidBrush(Track))
            using (GraphicsPath t = RoundedRect(new RectangleF(x, barY, w, barH), barH / 2))
                g.FillPath(track, t);

            float fill = (float)(w * row.Percent / 100);
            if (fill > 0)
            {
                using (var b = new SolidBrush(color))
                using (GraphicsPath f = RoundedRect(new RectangleF(x, barY, Math.Max(fill, barH), barH), barH / 2))
                    g.FillPath(b, f);
            }

            using (var muted = new SolidBrush(TextMuted))
                DrawText(g, ResetText(row.ResetsAt), fontSmall, muted, x, y + S(25), w, S(15));
        }

        static void DrawText(Graphics g, string text, Font font, Brush brush, float x, float y, float w, float h)
        {
            using (var format = new StringFormat())
            {
                format.Trimming = StringTrimming.EllipsisCharacter;
                g.DrawString(text, font, brush, new RectangleF(x, y, w, h), format);
            }
        }

        static string ResetText(DateTime? at)
        {
            if (at == null) return "";
            TimeSpan left = at.Value - DateTime.Now;
            if (left.TotalMinutes < 1) return "Réinitialisation imminente";
            if (left.TotalHours < 1) return "Réinitialisation dans " + (int)left.TotalMinutes + " min";
            if (left.TotalHours < 24)
                return "Réinitialisation dans " + (int)left.TotalHours + " h " + left.Minutes.ToString("00");
            if (left.TotalDays >= 7)
                return "Réinitialisation le " + at.Value.ToString("d MMM", CultureInfo.GetCultureInfo("fr-FR"));
            return "Réinitialisation " + at.Value.ToString("ddd HH:mm", CultureInfo.GetCultureInfo("fr-FR"));
        }

        // ---------- Souris et menu ----------

        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;

            if (updateVersion != null && updateHit.Contains(e.Location))
            {
                StartUpdate();
                return;
            }

            Point before = Location;
            ReleaseCapture();
            SendMessage(Handle, 0xA1 /* WM_NCLBUTTONDOWN */, (IntPtr)2 /* HTCAPTION */, IntPtr.Zero);

            if (Location != before)
            {
                SaveSettings();
            }
            else if (claude.Visible && claude.NeedLogin)
            {
                OpenLogin();
            }
            else if ((DateTime.Now - lastRefresh).TotalSeconds > 10)
            {
                RefreshAll();
            }
        }

        ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();
            updateItem.Visible = false;
            updateItem.Click += delegate { StartUpdate(); };
            menu.Items.Add(updateItem);
            menu.Items.Add("Actualiser", null, delegate { RefreshAll(); });
            menu.Items.Add("Claude : se connecter / changer de compte", null, delegate { OpenLogin(); });
            menu.Items.Add(new ToolStripSeparator());

            showClaudeItem.Click += delegate { ToggleSection(claude, showClaudeItem); };
            menu.Items.Add(showClaudeItem);
            showCodexItem.Click += delegate { ToggleSection(codex, showCodexItem); };
            menu.Items.Add(showCodexItem);
            menu.Items.Add(new ToolStripSeparator());

            topMostItem.Click += delegate
            {
                TopMost = !TopMost;
                topMostItem.Checked = TopMost;
                SaveSettings();
            };
            menu.Items.Add(topMostItem);

            autoStartItem.Click += delegate { SetAutoStart(!autoStartItem.Checked); };
            menu.Items.Add(autoStartItem);

            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Quitter", null, delegate { Application.Exit(); });
            menu.Opening += delegate { autoStartItem.Checked = IsAutoStart(); };
            return menu;
        }

        void ToggleSection(Section section, ToolStripMenuItem item)
        {
            section.Visible = !section.Visible;
            item.Checked = section.Visible;
            SaveSettings();
            UpdateShape();
            UpdateState();
            if (section == codex) PollCodex();
        }

        static bool IsAutoStart()
        {
            using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunKey))
                return key != null && key.GetValue(RunValue) != null;
        }

        static void SetAutoStart(bool enable)
        {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (enable) key.SetValue(RunValue, "\"" + Application.ExecutablePath + "\" --with-claude");
                else key.DeleteValue(RunValue, false);
            }
        }

        // ---------- Reglages : position et premier plan ----------

        void LoadSettings()
        {
            Rectangle wa = Screen.PrimaryScreen.WorkingArea;
            Point pos = new Point(wa.Right - Width - S(20), wa.Top + S(20));
            bool top = true;

            // Sans reglage : on affiche ce qui est detecte, pour ne pas demander une connexion Claude a qui n'utilise que Codex.
            bool codexFound = CodexClient.FindExecutable() != null;
            bool claudeUsed = Directory.Exists(Path.Combine(DataDir, "web"));
            claude.Visible = claudeUsed || !codexFound;
            codex.Visible = codexFound;

            try
            {
                if (File.Exists(SettingsPath))
                {
                    string[] parts = File.ReadAllText(SettingsPath).Trim().Split(' ');
                    if (parts.Length >= 3)
                    {
                        Point saved = new Point(int.Parse(parts[0]), int.Parse(parts[1]));
                        top = parts[2] == "1";
                        if (parts.Length >= 5)
                        {
                            claude.Visible = parts[3] == "1";
                            codex.Visible = parts[4] == "1";
                        }
                        // L'ecran a pu etre debranche depuis : on ne replace le widget que s'il reste visible.
                        foreach (Screen s in Screen.AllScreens)
                            if (s.WorkingArea.Contains(new Point(saved.X + S(20), saved.Y + S(20)))) pos = saved;
                    }
                }
            }
            catch (IOException) { }
            catch (FormatException) { }
            catch (OverflowException) { }
            Location = pos;
            TopMost = top;
            topMostItem.Checked = top;
            showClaudeItem.Checked = claude.Visible;
            showCodexItem.Checked = codex.Visible;
        }

        void SaveSettings()
        {
            try
            {
                Directory.CreateDirectory(DataDir);
                File.WriteAllText(SettingsPath, Location.X + " " + Location.Y + " " + (TopMost ? "1" : "0")
                    + " " + (claude.Visible ? "1" : "0") + " " + (codex.Visible ? "1" : "0"));
            }
            catch (IOException) { }
        }
    }

    static class Program
    {
        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();

        [STAThread]
        static int Main(string[] args)
        {
            SetProcessDPIAware();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            // Test sans reseau ni connexion : ClaudeUsage.exe --demo reponse.json image.png
            if (args.Length == 3 && args[0] == "--demo")
                return RenderDemo(args[1], args[2]);

            // Planche des poses animees, pour verifier l'animation sans fenetre.
            if (args.Length == 2 && args[0] == "--demo-frames")
            {
                // Ligne 1-2 : scenes normales. Ligne 3-4 : panique (2 poses) puis sommeil (2 poses).
                int[] claudeFrames = { 0, 5, 24, 36, 42, 52, 58, 60, 72 };
                int[] codexFrames = { 0, 6, 20, 26, 30, 45, 58, 62, 70 };
                int[] moodFrames = { 1, 2, 4, 8 };
                using (var bmp = new Bitmap(9 * 28 + 6, 4 * 28 + 6))
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.Clear(Color.FromArgb(31, 30, 29));
                    for (int i = 0; i < 9; i++)
                    {
                        Mascot.Claude.Draw(g, 6 + i * 28, 10, 2, claudeFrames[i], Mood.Normal);
                        Mascot.Codex.Draw(g, 6 + i * 28, 38, 2, codexFrames[i], Mood.Normal);
                    }
                    for (int i = 0; i < 4; i++)
                    {
                        Mood mood = i < 2 ? Mood.Panic : Mood.Sleepy;
                        Mascot.Claude.Draw(g, 6 + i * 28, 66, 2, moodFrames[i], mood);
                        Mascot.Codex.Draw(g, 6 + i * 28, 94, 2, moodFrames[i], mood);
                    }
                    bmp.Save(args[1], ImageFormat.Png);
                }
                return 0;
            }

            // Diagnostic sans fenetre : ClaudeUsage.exe --check-codex resultat.txt
            if (args.Length == 2 && args[0] == "--check-codex")
            {
                CodexResult r = CodexClient.Read();
                string text = "exe=" + (CodexClient.FindExecutable() != null) + " erreur=" + (r.Error ?? "aucune");
                if (r.Rows != null)
                    foreach (Limit l in r.Rows) text += " | " + l.Label + " " + l.Percent + "% reset=" + l.ResetsAt;
                File.WriteAllText(args[1], text);
                return 0;
            }

            // Diagnostic sans fenetre : ClaudeUsage.exe --check-fullscreen resultat.txt
            if (args.Length == 2 && args[0] == "--check-fullscreen")
            {
                File.WriteAllText(args[1], FullscreenApp.Describe() + " claudeOuvert=" + ClaudeApp.IsRunning());
                return 0;
            }

            bool created;
            using (var mutex = new Mutex(true, @"Local\ClaudeUsageWidget", out created))
            {
                // Apres une mise a jour, l'ancienne version est encore en train de se fermer : on l'attend.
                if (!created && Array.IndexOf(args, SelfUpdater.RestartArg) >= 0)
                {
                    try { created = mutex.WaitOne(15000); }
                    catch (AbandonedMutexException) { created = true; }
                }
                if (!created) return 0;
                SelfUpdater.CleanUp();
                // Avec --with-claude (demarrage de Windows), le widget attend l'ouverture de l'app Claude ou Codex.
                bool waitForApps = args.Length == 1 && args[0] == "--with-claude";
                Application.Run(new WidgetForm(waitForApps));
                GC.KeepAlive(mutex);
            }
            return 0;
        }

        static int RenderDemo(string jsonPath, string pngPath)
        {
            var json = UsageParser.ParseJson(File.ReadAllText(jsonPath)) as Dictionary<string, object>;
            using (var form = new WidgetForm(false))
            {
                object part;
                bool hasClaude = json.TryGetValue("claude", out part);
                if (hasClaude) form.SetRows(UsageParser.Parse(part));
                bool hasCodex = json.TryGetValue("codex", out part);
                if (hasCodex) form.SetCodexRows(CodexClient.ParseResult((Dictionary<string, object>)part).Rows);
                form.SetVisibleSections(hasClaude, hasCodex);
                if (json.TryGetValue("update", out part) && part is string) form.SetUpdateForDemo((string)part);
                using (var bmp = new Bitmap(form.Width, form.Height))
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    form.Render(g);
                    bmp.Save(pngPath, ImageFormat.Png);
                }
            }
            return 0;
        }
    }
}
