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
    formatter.dateFormat = "EEE HH:mm"
    return "Réinitialisation " + formatter.string(from: date)
}

func percentText(_ value: Double) -> String { "\(Int(value.rounded())) %" }

// ---------- Vue du widget ----------

final class WidgetView: NSView {
    static let width: CGFloat = 236
    static let pad: CGFloat = 12
    static let rowHeight: CGFloat = 46
    static let footerHeight: CGFloat = 18
    static let messageHeight: CGFloat = 44

    var limits: [Limit] = []
    var message: String? = "Chargement…"
    var loginNeeded = false
    var lastOk: Date?
    var onClick: (() -> Void)?
    var contextMenu: NSMenu?

    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var dragged = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu }

    var preferredHeight: CGFloat {
        var height = Self.pad * 2
        if limits.isEmpty {
            height += Self.messageHeight
        } else {
            height += CGFloat(limits.count) * Self.rowHeight - 6
            if message != nil { height += Self.footerHeight }
        }
        return height
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

        for limit in limits {
            drawRow(limit, x: x, y: y, width: width)
            y += Self.rowHeight
        }

        if limits.isEmpty {
            let color: NSColor = loginNeeded ? Self.accent : Self.muted
            draw(message ?? "", font: .systemFont(ofSize: 12), color: color,
                 in: NSRect(x: x, y: y, width: width, height: Self.messageHeight))
        } else if let message = message {
            var text = message
            if let lastOk = lastOk {
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
    private let pollInterval: TimeInterval = 300
    private let watchdogInterval: TimeInterval = 30

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private let widget = WidgetView(frame: NSRect(x: 0, y: 0, width: WidgetView.width, height: 96))
    private let menu = NSMenu()

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

        buildPanel()
        buildBrowser()

        Timer.scheduledTimer(timeInterval: pollInterval, target: self, selector: #selector(pollNow),
                             userInfo: nil, repeats: true)
        Timer.scheduledTimer(timeInterval: 30, target: self, selector: #selector(repaint),
                             userInfo: nil, repeats: true)
        pollNow()
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
        guard !loginVisible, step == .none else { return }
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
        if widget.limits.isEmpty {
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
            widget.limits = rows
            widget.message = nil
            widget.loginNeeded = false
            widget.lastOk = Date()
            refreshDisplay()
        }
    }

    // ---------- Connexion ----------

    private func widgetClicked() {
        if widget.loginNeeded {
            openLogin()
        } else if -lastPoll.timeIntervalSinceNow > 10 {
            pollNow()
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
        widget.loginNeeded = false
        widget.message = text
        refreshDisplay()
    }

    private func showLoginNeeded(_ text: String) {
        widget.loginNeeded = true
        widget.limits = []
        widget.message = text
        refreshDisplay()
    }

    @objc private func repaint() {
        widget.needsDisplay = true
    }

    private func refreshDisplay() {
        if widget.limits.isEmpty {
            statusItem.button?.title = widget.loginNeeded ? "Claude ?" : "Claude…"
        } else {
            statusItem.button?.title = widget.limits.prefix(2).map { percentText($0.percent) }.joined(separator: " · ")
        }

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

        for limit in widget.limits {
            let reset = resetText(limit.resetsAt)
            let suffix = reset.isEmpty ? "" : " — " + reset
            menu.addItem(NSMenuItem(title: "\(limit.label) : \(percentText(limit.percent))\(suffix)", action: nil, keyEquivalent: ""))
        }
        if let message = widget.message {
            menu.addItem(NSMenuItem(title: message, action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())

        add("Actualiser", #selector(pollNow))
        add("Se connecter / changer de compte", #selector(openLogin))
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
