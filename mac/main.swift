// Mini widget : limite d'utilisation du forfait Claude dans la barre de menu et sur le bureau du Mac.
//
// Un navigateur WKWebView cache garde ta session claude.ai et lit les memes donnees que la page
// Parametres > Utilisation. Le widget ne voit jamais ton mot de passe.
//
// Compilation : bash build.sh (necessite seulement les outils de ligne de commande Xcode).

import AppKit
import ServiceManagement
import WebKit

struct Limit {
    let label: String
    let percent: Double
    let resetsAt: Date?
}

// Lecture de la reponse de claude.ai. L'adresse n'est pas documentee : on accepte les deux formats
// connus et on ignore tout ce qui manque plutot que d'afficher un chiffre faux.
enum UsageParser {
    static func json(from text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))
    }

    static func limits(from json: Any) -> [Limit] {
        guard let root = json as? [String: Any] else { return [] }
        var rows: [Limit] = []
        if let list = root["limits"] as? [[String: Any]] {
            for entry in list {
                if let label = label(for: entry),
                   let row = limit(label: label, percent: entry["percent"], resetsAt: entry["resets_at"]) {
                    rows.append(row)
                }
            }
        } else {
            let keys = [("five_hour", "Session"), ("seven_day", "Semaine"),
                        ("seven_day_opus", "Semaine · Opus"), ("seven_day_sonnet", "Semaine · Sonnet")]
            for (key, label) in keys {
                if let entry = root[key] as? [String: Any],
                   let row = limit(label: label, percent: entry["utilization"], resetsAt: entry["resets_at"]) {
                    rows.append(row)
                }
            }
        }
        return rows
    }

    private static func label(for entry: [String: Any]) -> String? {
        guard let kind = entry["kind"] as? String else { return nil }
        switch kind {
        case "session": return "Session"
        case "weekly_all": return "Semaine"
        case "weekly_scoped":
            let scope = entry["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            if let name = model?["display_name"] as? String, !name.isEmpty { return "Semaine · " + name }
            return "Semaine (modèle)"
        default: return kind
        }
    }

    private static func limit(label: String, percent: Any?, resetsAt: Any?) -> Limit? {
        guard let value = (percent as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return nil }
        return Limit(label: label, percent: min(value, 100), resetsAt: date(from: resetsAt as? String))
    }

    private static func date(from text: String?) -> Date? {
        guard let text = text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: text) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func organization(from json: Any) -> String? {
        guard let orgs = json as? [[String: Any]] else { return nil }
        let chat = orgs.first { ($0["capabilities"] as? [String])?.contains("chat") == true }
        return (chat ?? orgs.first)?["uuid"] as? String
    }

    static func errorType(from json: Any) -> String? {
        guard let root = json as? [String: Any], let error = root["error"], !(error is NSNull) else { return nil }
        return (error as? [String: Any])?["type"] as? String ?? "error"
    }

    static func isAuthError(_ type: String) -> Bool {
        let t = type.lowercased()
        return t.contains("auth") || t.contains("permission") || t.contains("session")
    }
}

func resetText(_ date: Date?) -> String {
    guard let date = date else { return "" }
    let left = date.timeIntervalSinceNow
    if left < 60 { return "Réinitialisation imminente" }
    if left < 3600 { return "Réinitialisation dans \(Int(left / 60)) min" }
    if left < 86400 {
        let hours = Int(left / 3600)
        let minutes = Int(left.truncatingRemainder(dividingBy: 3600) / 60)
        return "Réinitialisation dans \(hours) h " + String(format: "%02d", minutes)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "fr_FR")
    if left >= 7 * 86400 {
        formatter.dateFormat = "d MMM"
        return "Réinitialisation le " + formatter.string(from: date)
    }
    formatter.dateFormat = "EEE HH:mm"
    return "Réinitialisation " + formatter.string(from: date)
}

func percentText(_ value: Double) -> String { "\(Int(value.rounded())) %" }

// Une partie du widget par outil suivi.
final class Section {
    let name: String
    var visible = true
    var limits: [Limit] = []
    var message: String? = "Chargement…"
    var loginNeeded = false
    var lastOk: Date?

    init(name: String) { self.name = name }
}

// Codex donne lui-meme ses limites via son app-server : il garde sa connexion, le widget ne voit aucun jeton.
enum CodexClient {
    static func findExecutable() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home + "/.local/bin/codex",
            home + "/.npm-global/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func read() -> (limits: [Limit]?, error: String?) {
        guard let executable = findExecutable() else { return (nil, "Codex introuvable sur ce Mac") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        // Une app lancee depuis le Finder n'a pas le PATH du terminal : codex installe par npm a besoin de node.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return (nil, "Lecture Codex impossible") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            if process.isRunning { process.terminate() }
        }

        var buffer = Data()
        func send(_ json: String) { input.fileHandleForWriting.write(Data((json + "\n").utf8)) }
        func response(_ id: Int) -> [String: Any]? {
            while true {
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                       (message["id"] as? NSNumber)?.intValue == id {
                        return message
                    }
                }
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { return nil }
                buffer.append(chunk)
            }
        }

        send(#"{"method":"initialize","id":1,"params":{"clientInfo":{"name":"claude_usage_widget","title":"Claude Usage Widget","version":"1.0"}}}"#)
        guard response(1) != nil else { process.terminate(); return (nil, "Codex ne répond pas") }
        send(#"{"method":"initialized"}"#)
        send(#"{"method":"account/rateLimits/read","id":2}"#)
        let reply = response(2)
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }

        guard let reply = reply else { return (nil, "Codex ne répond pas") }
        guard let result = reply["result"] as? [String: Any] else { return (nil, "Ouvre Codex et connecte-toi") }
        let rows = limits(from: result)
        return rows.isEmpty ? (nil, "Aucune limite Codex pour ce compte") : (rows, nil)
    }

    static func limits(from result: [String: Any]) -> [Limit] {
        guard let rateLimits = result["rateLimits"] as? [String: Any] else { return [] }
        return ["primary", "secondary"].compactMap { key in
            guard let window = rateLimits[key] as? [String: Any],
                  let used = (window["usedPercent"] as? NSNumber)?.doubleValue, used.isFinite, used >= 0 else { return nil }
            let reset = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let minutes = (window["windowDurationMins"] as? NSNumber)?.doubleValue
            return Limit(label: label(minutes: minutes), percent: min(used, 100), resetsAt: reset)
        }
    }

    private static func label(minutes: Double?) -> String {
        guard let m = minutes else { return "Limite" }
        if abs(m - 300) <= 30 { return "Session" }
        if abs(m - 1440) <= 144 { return "Jour" }
        if abs(m - 10080) <= 1008 { return "Semaine" }
        if abs(m - 43200) <= 4320 { return "Mois" }
        return "Limite"
    }
}

// Transporte le resultat de Codex du fil d'arriere-plan vers l'interface.
final class CodexResultBox: NSObject {
    let limits: [Limit]?
    let error: String?
    init(_ result: (limits: [Limit]?, error: String?)) {
        limits = result.limits
        error = result.error
    }
}

// ---------- Vue du widget ----------

final class WidgetView: NSView {
    static let width: CGFloat = 236
    static let pad: CGFloat = 12
    static let rowHeight: CGFloat = 46
    static let footerHeight: CGFloat = 18
    static let messageHeight: CGFloat = 44
    static let headerHeight: CGFloat = 22
    static let sectionGap: CGFloat = 10

    var sections: [Section] = []
    var onClick: (() -> Void)?
    var contextMenu: NSMenu?

    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var dragged = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu }

    static func height(of section: Section) -> CGFloat {
        var height = headerHeight
        if section.limits.isEmpty {
            height += messageHeight
        } else {
            height += CGFloat(section.limits.count) * rowHeight - 6
            if section.message != nil { height += footerHeight }
        }
        return height
    }

    var preferredHeight: CGFloat {
        let shown = sections.filter { $0.visible }
        if shown.isEmpty { return Self.pad * 2 + Self.messageHeight }
        return Self.pad * 2 + shown.map { Self.height(of: $0) }.reduce(0, +) + CGFloat(shown.count - 1) * Self.sectionGap
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - dragStartMouse.x
        let dy = mouse.y - dragStartMouse.y
        if abs(dx) > 3 || abs(dy) > 3 { dragged = true }
        if dragged {
            window?.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSColor(srgbRed: 31 / 255, green: 30 / 255, blue: 29 / 255, alpha: 1).setFill()
        background.fill()
        NSColor(srgbRed: 62 / 255, green: 60 / 255, blue: 56 / 255, alpha: 1).setStroke()
        background.lineWidth = 1
        background.stroke()

        let x = Self.pad
        let width = bounds.width - 2 * Self.pad
        var y = Self.pad

        let shown = sections.filter { $0.visible }
        if shown.isEmpty {
            draw("Clic droit pour choisir Claude ou Codex", font: .systemFont(ofSize: 12), color: Self.muted,
                 in: NSRect(x: x, y: y, width: width, height: Self.messageHeight))
        }
        for (index, section) in shown.enumerated() {
            if index > 0 { y += Self.sectionGap }
            drawSection(section, x: x, y: y, width: width)
            y += Self.height(of: section)
        }
    }

    private func drawSection(_ section: Section, x: CGFloat, y top: CGFloat, width: CGFloat) {
        draw(section.name, font: .systemFont(ofSize: 12, weight: .semibold), color: Self.muted,
             in: NSRect(x: x, y: top, width: width, height: Self.headerHeight))
        var y = top + Self.headerHeight

        for limit in section.limits {
            drawRow(limit, x: x, y: y, width: width)
            y += Self.rowHeight
        }

        if section.limits.isEmpty {
            let color: NSColor = section.loginNeeded ? Self.accent : Self.muted
            draw(section.message ?? "", font: .systemFont(ofSize: 12), color: color,
                 in: NSRect(x: x, y: y, width: width, height: Self.messageHeight))
        } else if let message = section.message {
            var text = message
            if let lastOk = section.lastOk {
                let minutes = Int(-lastOk.timeIntervalSinceNow / 60)
                if minutes >= 1 { text += " · il y a \(minutes) min" }
            }
            draw(text, font: .systemFont(ofSize: 10.5), color: Self.warn,
                 in: NSRect(x: x, y: y - 4, width: width, height: Self.footerHeight))
        }
    }

    static let accent = NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
    static let warn = NSColor(srgbRed: 232 / 255, green: 175 / 255, blue: 72 / 255, alpha: 1)
    static let danger = NSColor(srgbRed: 226 / 255, green: 88 / 255, blue: 76 / 255, alpha: 1)
    static let main = NSColor(srgbRed: 245 / 255, green: 244 / 255, blue: 239 / 255, alpha: 1)
    static let muted = NSColor(srgbRed: 166 / 255, green: 163 / 255, blue: 154 / 255, alpha: 1)
    static let track = NSColor(srgbRed: 58 / 255, green: 56 / 255, blue: 52 / 255, alpha: 1)

    private func drawRow(_ limit: Limit, x: CGFloat, y: CGFloat, width: CGFloat) {
        let value = percentText(limit.percent) as NSString
        let valueAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: Self.main,
        ]
        let valueWidth = value.size(withAttributes: valueAttributes).width
        value.draw(at: NSPoint(x: x + width - valueWidth, y: y - 1), withAttributes: valueAttributes)
        draw(limit.label, font: .systemFont(ofSize: 12), color: Self.main,
             in: NSRect(x: x, y: y, width: width - valueWidth - 6, height: 18))

        let barY = y + 20
        let barHeight: CGFloat = 4
        Self.track.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: barY, width: width, height: barHeight), xRadius: 2, yRadius: 2).fill()

        let color = limit.percent >= 90 ? Self.danger : limit.percent >= 70 ? Self.warn : Self.accent
        let fill = width * CGFloat(limit.percent) / 100
        if fill > 0 {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: barY, width: max(fill, barHeight), height: barHeight),
                         xRadius: 2, yRadius: 2).fill()
        }

        draw(resetText(limit.resetsAt), font: .systemFont(ofSize: 10.5), color: Self.muted,
             in: NSRect(x: x, y: y + 25, width: width, height: 15))
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
}

// ---------- Application ----------

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSWindowDelegate, NSMenuDelegate {
    private enum Step { case none, organizations, usage }

    private let baseURL = "https://claude.ai"
    private let pollInterval: TimeInterval = 120
    private let watchdogInterval: TimeInterval = 30

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private let widget = WidgetView(frame: NSRect(x: 0, y: 0, width: WidgetView.width, height: 96))
    private let menu = NSMenu()
    private let claude = Section(name: "Claude")
    private let codex = Section(name: "Codex")
    private var codexBusy = false
    private var lastRefresh = Date.distantPast

    private var web: WKWebView!
    private var browserWindow: NSWindow!
    private var loginVisible = false
    private var step = Step.none
    private var orgId: String?
    private var lastPoll = Date.distantPast
    private var lastStatus = 0

    private var watchdog: Timer?
    private var loginTimer: Timer?

    private var alwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: "alwaysOnTop") }
        set { UserDefaults.standard.set(newValue, forKey: "alwaysOnTop") }
    }

    private var showWidget: Bool {
        get { UserDefaults.standard.object(forKey: "showWidget") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showWidget") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Claude…"
        menu.delegate = self
        statusItem.menu = menu

        // Sans reglage : on affiche ce qui est detecte, pour ne pas demander une connexion Claude a qui n'utilise que Codex.
        let codexFound = CodexClient.findExecutable() != nil
        let defaults = UserDefaults.standard
        let claudeAppInstalled = FileManager.default.fileExists(atPath: "/Applications/Claude.app")
        claude.visible = defaults.object(forKey: "showClaude") as? Bool ?? (claudeAppInstalled || !codexFound)
        codex.visible = defaults.object(forKey: "showCodex") as? Bool ?? codexFound
        widget.sections = [claude, codex]

        buildPanel()
        buildBrowser()

        Timer.scheduledTimer(timeInterval: pollInterval, target: self, selector: #selector(refreshAll),
                             userInfo: nil, repeats: true)
        Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(repaint),
                             userInfo: nil, repeats: true)
        refreshDisplay()
        refreshAll()
    }

    @objc private func refreshAll() {
        lastRefresh = Date()
        pollNow()
        pollCodex()
    }

    private func pollCodex() {
        guard codex.visible, !codexBusy else { return }
        codexBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let box = CodexResultBox(CodexClient.read())
            self?.performSelector(onMainThread: #selector(AppDelegate.codexFinished(_:)), with: box, waitUntilDone: false)
        }
    }

    @objc private func codexFinished(_ box: CodexResultBox) {
        codexBusy = false
        if let limits = box.limits {
            codex.limits = limits
            codex.message = nil
            codex.lastOk = Date()
        } else {
            codex.message = box.error
        }
        refreshDisplay()
    }

    // Fenetre sans focus : elle ne devient jamais active et n'apparait pas par-dessus un jeu en plein ecran.
    private func buildPanel() {
        panel = NSPanel(contentRect: widget.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = widget
        widget.contextMenu = menu
        widget.onClick = { [weak self] in self?.widgetClicked() }

        if !panel.setFrameUsingName("ClaudeUsageWidget"), let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.maxX - WidgetView.width - 20, y: area.maxY - 116))
        }
        panel.setFrameAutosaveName("ClaudeUsageWidget")
        applyWindowLevel()
        applyWidgetVisibility()
    }

    private func applyWindowLevel() {
        panel.level = alwaysOnTop
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    private func applyWidgetVisibility() {
        if showWidget { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    private func buildBrowser() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 720), configuration: configuration)
        web.navigationDelegate = self

        browserWindow = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable],
                                 backing: .buffered, defer: false)
        browserWindow.title = "Connexion à Claude"
        browserWindow.contentView = web
        browserWindow.isReleasedWhenClosed = false
        browserWindow.delegate = self
    }

    // ---------- Donnees ----------

    @objc private func pollNow() {
        guard claude.visible, !loginVisible, step == .none else { return }
        lastPoll = Date()
        startWatchdog()
        if let orgId = orgId?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            step = .usage
            load("\(baseURL)/api/organizations/\(orgId)/usage")
        } else {
            step = .organizations
            load("\(baseURL)/api/organizations")
        }
    }

    private func load(_ address: String) {
        guard let url = URL(string: address) else { return }
        web.load(URLRequest(url: url))
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(timeInterval: watchdogInterval, target: self,
                                        selector: #selector(watchdogFired), userInfo: nil, repeats: false)
    }

    @objc private func watchdogFired() {
        finishPoll()
        if claude.limits.isEmpty {
            showLoginNeeded("Vérification requise : clique pour ouvrir claude.ai")
        } else {
            showProblem("claude.ai ne répond pas")
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        lastStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode ?? 0
        decisionHandler(.allow)
    }

    private func finishPoll() {
        step = .none
        watchdog?.invalidate()
        watchdog = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !loginVisible, step != .none, webView.url?.host == "claude.ai" else { return }
        webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
            guard let self = self, self.step != .none, let text = result as? String else { return }
            // Page HTML : verification Cloudflare en cours. Le chien de garde prend le relais si elle ne se termine pas.
            guard let json = UsageParser.json(from: text) else { return }
            self.handle(json)
            if self.step == .none && !self.loginVisible { self.load("about:blank") }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        let code = (error as NSError).code
        guard !loginVisible, step != .none, code != NSURLErrorCancelled else { return }
        finishPoll()
        showProblem("Pas de connexion réseau")
    }

    private func handle(_ json: Any) {
        if let error = UsageParser.errorType(from: json) {
            // Seul un vrai refus d'acces demande une connexion : une surcharge ne doit pas te deconnecter.
            let needLogin = lastStatus == 401 || lastStatus == 403 || UsageParser.isAuthError(error)
            finishPoll()
            if needLogin {
                orgId = nil
                showLoginNeeded("Clique ici pour te connecter à claude.ai")
            } else {
                showProblem("claude.ai a répondu : \(error)")
            }
            return
        }

        if step == .organizations {
            orgId = UsageParser.organization(from: json)
            finishPoll()
            if orgId == nil {
                showLoginNeeded("Clique ici pour te connecter à claude.ai")
            } else {
                pollNow()
            }
            return
        }

        let rows = UsageParser.limits(from: json)
        finishPoll()
        if rows.isEmpty {
            showProblem("Aucune limite dans la réponse")
        } else {
            claude.limits = rows
            claude.message = nil
            claude.loginNeeded = false
            claude.lastOk = Date()
            refreshDisplay()
        }
    }

    // ---------- Connexion ----------

    private func widgetClicked() {
        if claude.visible && claude.loginNeeded {
            openLogin()
        } else if -lastRefresh.timeIntervalSinceNow > 10 {
            refreshAll()
        }
    }

    @objc private func openLogin() {
        finishPoll()
        loginVisible = true
        browserWindow.center()
        browserWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // La page d'accueil ne montre le formulaire que si la session n'est vraiment plus valable.
        load("\(baseURL)/")
        loginTimer?.invalidate()
        loginTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(checkLoginFinished),
                                          userInfo: nil, repeats: true)
    }

    @objc private func checkLoginFinished() {
        guard loginVisible, let url = web.url, url.host == "claude.ai" else { return }
        let path = url.path
        let waiting = ["/login", "/magic-link", "/cdn-cgi", "/api"].contains { path.hasPrefix($0) }
        if path.isEmpty || path == "/" || waiting { return }
        closeLogin()
        pollNow()
    }

    private func closeLogin() {
        loginVisible = false
        loginTimer?.invalidate()
        loginTimer = nil
        browserWindow.orderOut(nil)
    }

    // Le navigateur sert aussi aux mises a jour : fermer la fenetre ne fait que la masquer.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeLogin()
        pollNow()
        return false
    }

    // ---------- Affichage ----------

    private func showProblem(_ text: String) {
        claude.loginNeeded = false
        claude.message = text
        refreshDisplay()
    }

    private func showLoginNeeded(_ text: String) {
        claude.loginNeeded = true
        claude.limits = []
        claude.message = text
        refreshDisplay()
    }

    @objc private func repaint() {
        widget.needsDisplay = true
    }

    private func refreshDisplay() {
        // Barre de menu : le premier pourcentage de chaque outil affiche.
        let parts = widget.sections.filter { $0.visible }.compactMap { section -> String? in
            guard let first = section.limits.first else { return nil }
            return "\(section.name.prefix(2)) \(percentText(first.percent))"
        }
        statusItem.button?.title = parts.isEmpty ? (claude.visible && claude.loginNeeded ? "Claude ?" : "Claude…")
                                                 : parts.joined(separator: " · ")

        // Le coin haut gauche reste fixe quand le nombre de lignes change.
        let height = widget.preferredHeight
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: WidgetView.width, height: height)
        panel.setFrame(frame, display: true)
        widget.needsDisplay = true
    }

    // ---------- Menu ----------

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for section in widget.sections where section.visible {
            for limit in section.limits {
                let reset = resetText(limit.resetsAt)
                let suffix = reset.isEmpty ? "" : " — " + reset
                menu.addItem(NSMenuItem(title: "\(section.name) · \(limit.label) : \(percentText(limit.percent))\(suffix)",
                                        action: nil, keyEquivalent: ""))
            }
            if let message = section.message {
                menu.addItem(NSMenuItem(title: "\(section.name) : \(message)", action: nil, keyEquivalent: ""))
            }
        }
        menu.addItem(.separator())

        add("Actualiser", #selector(refreshAll))
        add("Claude : se connecter / changer de compte", #selector(openLogin))
        menu.addItem(.separator())
        add("Afficher Claude", #selector(toggleClaude), checked: claude.visible)
        add("Afficher Codex", #selector(toggleCodex), checked: codex.visible)
        menu.addItem(.separator())
        add("Afficher le widget sur le bureau", #selector(toggleWidget), checked: showWidget)
        add("Toujours au premier plan", #selector(toggleTopMost), checked: alwaysOnTop)
        add("Lancer à l'ouverture de session", #selector(toggleLaunchAtLogin),
            checked: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add("Quitter", #selector(quit))
    }

    private func add(_ title: String, _ action: Selector, checked: Bool = false) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    @objc private func toggleClaude() {
        claude.visible.toggle()
        UserDefaults.standard.set(claude.visible, forKey: "showClaude")
        if claude.visible { pollNow() } else { finishPoll() }
        refreshDisplay()
    }

    @objc private func toggleCodex() {
        codex.visible.toggle()
        UserDefaults.standard.set(codex.visible, forKey: "showCodex")
        pollCodex()
        refreshDisplay()
    }

    @objc private func toggleWidget() {
        showWidget.toggle()
        applyWidgetVisibility()
    }

    @objc private func toggleTopMost() {
        alwaysOnTop.toggle()
        applyWindowLevel()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showProblem("Démarrage auto impossible : \(error.localizedDescription)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
