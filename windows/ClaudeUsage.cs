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
        const int PollMinutes = 5;
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
        readonly bool waitForClaude;
        bool hiddenNow;
        readonly ToolStripMenuItem topMostItem = new ToolStripMenuItem("Toujours au premier plan");
        readonly ToolStripMenuItem autoStartItem = new ToolStripMenuItem("Se lancer avec l'app Claude");

        List<Limit> rows = new List<Limit>();
        string message = "Chargement…";
        bool needLogin;
        DateTime lastOk = DateTime.MinValue;
        DateTime lastPoll = DateTime.MinValue;

        BrowserForm browser;
        WebView2 web;
        bool webReady;
        Step step = Step.None;
        string orgId;
        int lastStatus;

        public WidgetForm(bool waitForClaude)
        {
            this.waitForClaude = waitForClaude;
            if (waitForClaude) Opacity = 0; // evite un flash au demarrage de Windows, avant de savoir si Claude est ouvert
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
            pollTimer.Tick += delegate { Poll(); };
            watchdog.Interval = WatchdogSeconds * 1000;
            watchdog.Tick += delegate { OnWatchdog(); };
            repaintTimer.Interval = 30 * 1000;
            repaintTimer.Tick += delegate { Invalidate(); };
            fullscreenTimer.Interval = 3000;
            fullscreenTimer.Tick += delegate { UpdateState(); };
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

        // Le widget se masque si l'app Claude est fermee, ou si un plein ecran occupe SON ecran.
        // Un jeu sur l'autre ecran ne change rien. Il revient toujours sans prendre le focus.
        void UpdateState()
        {
            bool claudeOpen = !waitForClaude || ClaudeApp.IsRunning();
            if (claudeOpen && browser == null) StartBrowser();
            else if (!claudeOpen && browser != null && !browser.LoginVisible) StopBrowser();

            Screen occupied = FullscreenApp.ScreenInUse();
            bool onOccupiedScreen = occupied != null
                && occupied.DeviceName == Screen.FromRectangle(Bounds).DeviceName;

            bool hide = !claudeOpen || onOccupiedScreen;
            if (hide == hiddenNow) return;
            hiddenNow = hide;
            ShowWindow(Handle, hide ? SwHide : SwShowNoActivate);
            if (!hide) Poll();
        }

        // Claude ferme : on libere le moteur Edge pour que le widget en attente ne consomme presque rien.
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
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            UpdateState();
            if (waitForClaude) Opacity = 1;
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
            lastPoll = DateTime.Now;
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
            if (rows.Count > 0) ShowProblem("claude.ai ne répond pas");
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
            rows = newRows;
            message = null;
            needLogin = false;
            lastOk = DateTime.Now;
            UpdateShape();
        }

        void ShowMessage(string text)
        {
            message = text;
            UpdateShape();
        }

        // Les derniers chiffres restent affiches, avec leur age, pour ne jamais les faire passer pour frais.
        void ShowProblem(string text)
        {
            needLogin = false;
            ShowMessage(text);
        }

        void ShowLoginNeeded(string text)
        {
            needLogin = true;
            rows = new List<Limit>();
            ShowMessage(text);
        }

        // ---------- Dessin ----------

        const float Pad = 12f;
        const float RowHeight = 46f;
        const float FooterHeight = 18f;
        const float MessageHeight = 44f;

        void UpdateShape()
        {
            float h = Pad * 2;
            if (rows.Count > 0)
            {
                h += rows.Count * RowHeight - 6;
                if (message != null) h += FooterHeight;
            }
            else
            {
                h += MessageHeight;
            }
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

            foreach (Limit row in rows)
            {
                DrawRow(g, row, x, y, w);
                y += S(RowHeight);
            }

            if (rows.Count > 0 && message != null)
            {
                y -= S(4);
                using (var b = new SolidBrush(Warn))
                    DrawText(g, Footer(), fontSmall, b, x, y, w, S(FooterHeight));
            }
            else if (rows.Count == 0)
            {
                using (var b = new SolidBrush(needLogin ? Accent : TextMuted))
                    DrawText(g, message ?? "", fontLabel, b, x, y, w, S(MessageHeight));
            }
        }

        string Footer()
        {
            if (lastOk == DateTime.MinValue) return message;
            int minutes = (int)(DateTime.Now - lastOk).TotalMinutes;
            return minutes < 1 ? message : message + " · il y a " + minutes + " min";
        }

        void DrawRow(Graphics g, Limit row, float x, float y, float w)
        {
            string value = Math.Round(row.Percent).ToString(CultureInfo.InvariantCulture) + " %";
            Color color = row.Percent >= 90 ? Danger : row.Percent >= 70 ? Warn : Accent;

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
            return "Réinitialisation " + at.Value.ToString("ddd HH:mm", CultureInfo.GetCultureInfo("fr-FR"));
        }

        // ---------- Souris et menu ----------

        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            if (e.Button != MouseButtons.Left) return;

            Point before = Location;
            ReleaseCapture();
            SendMessage(Handle, 0xA1 /* WM_NCLBUTTONDOWN */, (IntPtr)2 /* HTCAPTION */, IntPtr.Zero);

            if (Location != before)
            {
                SaveSettings();
            }
            else if (needLogin)
            {
                OpenLogin();
            }
            else if ((DateTime.Now - lastPoll).TotalSeconds > 10)
            {
                Poll();
            }
        }

        ContextMenuStrip BuildMenu()
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("Actualiser", null, delegate { Poll(); });
            menu.Items.Add("Se connecter / changer de compte", null, delegate { OpenLogin(); });
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
            try
            {
                if (File.Exists(SettingsPath))
                {
                    string[] parts = File.ReadAllText(SettingsPath).Trim().Split(' ');
                    if (parts.Length == 3)
                    {
                        Point saved = new Point(int.Parse(parts[0]), int.Parse(parts[1]));
                        top = parts[2] == "1";
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
        }

        void SaveSettings()
        {
            try
            {
                Directory.CreateDirectory(DataDir);
                File.WriteAllText(SettingsPath, Location.X + " " + Location.Y + " " + (TopMost ? "1" : "0"));
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

            // Diagnostic sans fenetre : ClaudeUsage.exe --check-fullscreen resultat.txt
            if (args.Length == 2 && args[0] == "--check-fullscreen")
            {
                File.WriteAllText(args[1], FullscreenApp.Describe() + " claudeOuvert=" + ClaudeApp.IsRunning());
                return 0;
            }

            bool created;
            using (var mutex = new Mutex(true, @"Local\ClaudeUsageWidget", out created))
            {
                if (!created) return 0;
                // Avec --with-claude (demarrage de Windows), le widget attend l'ouverture de l'app Claude.
                bool waitForClaude = args.Length == 1 && args[0] == "--with-claude";
                Application.Run(new WidgetForm(waitForClaude));
                GC.KeepAlive(mutex);
            }
            return 0;
        }

        static int RenderDemo(string jsonPath, string pngPath)
        {
            object json = UsageParser.ParseJson(File.ReadAllText(jsonPath));
            using (var form = new WidgetForm(false))
            {
                form.SetRows(UsageParser.Parse(json));
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
