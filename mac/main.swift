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

enum Mood { case normal, panic, sleepy }

// Une image de l'animation : la grille de pixels et son decalage (en pixels de mascotte).
struct MascotFrame {
    var cells: [[Character]]
    var dx = 0
    var dy = 0

    init(_ rows: [String]) { cells = rows.map { Array($0) } }
    mutating func row(_ index: Int, _ text: String) { cells[index] = Array(text) }
    mutating func put(_ row: Int, _ col: Int, _ character: Character) { cells[row][col] = character }
    mutating func replace(_ from: Character, with to: Character) {
        cells = cells.map { line in line.map { $0 == from ? to : $0 } }
    }
}

// Petites mascottes en pixel art (10 x 8), dessinees par le code. Ce ne sont pas les logos officiels.
// '#' corps, 'x' interieur, 'o' details, 'w' texte clair, 'b' goutte, 'z' sommeil, 'r' alerte, '.' transparent.
struct Mascot {
    static let width = 10

    let body: NSColor
    let inner: NSColor
    let detail: NSColor
    let animate: (Int, Mood) -> MascotFrame
    let blink: (inout MascotFrame) -> Void // clignement de la pose fixe (barre de menu au repos)

    static let light = NSColor(srgbRed: 201 / 255, green: 209 / 255, blue: 217 / 255, alpha: 1)
    static let sweat = NSColor(srgbRed: 127 / 255, green: 179 / 255, blue: 255 / 255, alpha: 1)
    static let sleep = NSColor(srgbRed: 166 / 255, green: 163 / 255, blue: 154 / 255, alpha: 1)
    static let alert = NSColor(srgbRed: 226 / 255, green: 88 / 255, blue: 76 / 255, alpha: 1)
    static let jumpHeights = [1, -1, -2, -2, -1, 0] // accroupi, saut, atterrissage

    static let claude = Mascot(
        body: NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1),
        inner: NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1),
        detail: NSColor(srgbRed: 31 / 255, green: 30 / 255, blue: 29 / 255, alpha: 1),
        animate: Mascot.claudeFrame,
        blink: { $0.row(3, "..######..") })

    static let codex = Mascot(
        body: NSColor(srgbRed: 138 / 255, green: 180 / 255, blue: 248 / 255, alpha: 1),
        inner: NSColor(srgbRed: 27 / 255, green: 39 / 255, blue: 51 / 255, alpha: 1),
        detail: NSColor(srgbRed: 232 / 255, green: 234 / 255, blue: 237 / 255, alpha: 1),
        animate: Mascot.codexFrame,
        blink: { Mascot.hideCursor(&$0) })

    static let claudeBase = ["....##....", "...####...", "..######..", "..#o##o#..",
                             "..######..", "..######..", "...####...", "..#....#.."]
    static let codexBase = [".########.", ".#xxxxxx#.", ".#oxxxxx#.", ".#xoxxxx#.",
                            ".#oxxoox#.", ".#xxxxxx#.", ".########.", "...#..#..."]

    static func walk(_ f: inout MascotFrame, _ t: Int, legs: String) {
        if (t / 4) % 2 == 1 {
            f.row(7, legs)
            f.dy = -1
        }
    }

    // Petit Zzz qui monte, en boucle.
    static func snore(_ f: inout MascotFrame, _ frame: Int, col: Int) {
        let z = (frame / 4) % 4
        if z < 3 { f.put(2 - z, z == 0 ? col - 1 : col, "z") }
        f.dy = (frame / 8) % 2 == 0 ? 0 : 1 // respiration lente
    }

    // Boucle d'environ 11 secondes : marche, clignement, regards, saut, salut, sourire.
    // Au-dela de 90 % elle panique (tremblement, goutte de sueur) ; sous 5 % elle dort.
    static func claudeFrame(_ frame: Int, _ mood: Mood) -> MascotFrame {
        var f = MascotFrame(claudeBase)
        if frame == 0 { return f }

        switch mood {
        case .panic:
            f.dx = frame % 2
            f.row(5, "..###o##..")
            let drop = frame % 4
            if drop < 3 { f.put(1 + drop, 8, "b") }
            if frame % 2 == 1 { f.row(7, "...#..#...") }
            return f
        case .sleepy:
            f.row(3, "..######..")
            snore(&f, frame, col: 9)
            return f
        case .normal:
            break
        }

        let t = frame % 96
        if t < 24 { walk(&f, t, legs: "...#..#...") }
        else if t < 26 { f.row(3, "..######..") }                  // clignement
        else if t < 34 { }
        else if t < 40 { f.row(3, "..o##o##..") }                  // regarde a gauche
        else if t < 46 { f.row(3, "..##o##o..") }                  // regarde a droite
        else if t < 50 { }
        else if t < 56 { f.dy = jumpHeights[t - 50] }              // saut
        else if t < 68 {
            let up = ((t - 56) / 2) % 2 == 0                         // salut de la main
            f.row(2, up ? "..######.#" : "..######..")
            f.row(3, up ? "..#o##o##." : "..#o##o###")
        }
        else if t < 76 { f.row(5, "..##oo##..") }                  // sourire
        else { walk(&f, t, legs: "...#..#...") }
        return f
    }

    static func hideCursor(_ f: inout MascotFrame) {
        f.put(4, 5, "x")
        f.put(4, 6, "x")
    }

    static func screenOff(_ f: inout MascotFrame) {
        for row in 1...5 { f.row(row, ".#xxxxxx#.") }
    }

    // Boucle d'environ 10 secondes : curseur, frappe, lignes de resultat, marche, saut, ecran qui clignote.
    // Au-dela de 90 % l'ecran vire au rouge ; sous 5 % il se met en veille.
    static func codexFrame(_ frame: Int, _ mood: Mood) -> MascotFrame {
        var f = MascotFrame(codexBase)
        if frame == 0 { return f }

        switch mood {
        case .panic:
            f.dx = frame % 2
            if frame % 4 < 2 { f.replace("x", with: "r") }
            if frame % 2 == 1 { f.row(7, "..#....#..") }
            return f
        case .sleepy:
            screenOff(&f)
            snore(&f, frame, col: 9)
            return f
        case .normal:
            break
        }

        let t = frame % 80
        if t < 16 {
            if (t / 4) % 2 == 1 { hideCursor(&f) }
        } else if t < 28 {
            let typed = min(3, (t - 16) / 2)                        // frappe de quelques caracteres
            for col in 3...7 { f.put(4, col, "x") }
            for i in 0..<typed { f.put(4, 4 + i, "w") }
            if t < 24 || t % 4 < 2 { f.put(4, 4 + typed, "o") }
        } else if t < 40 {
            f.row(1, ".#wwwwxx#.")                                  // lignes de resultat
            f.row(2, ".#xxxxxx#.")
            f.row(3, ".#wwwxwx#.")
            f.row(4, ".#xxxxxx#.")
            f.row(5, ".#wwxxxx#.")
        } else if t < 56 {
            walk(&f, t, legs: "..#....#..")
            if (t / 4) % 2 == 1 { hideCursor(&f) }
        } else if t < 62 {
            f.dy = jumpHeights[t - 56]
        } else if t < 64 {
            screenOff(&f)
        } else if (t / 4) % 2 == 1 {
            hideCursor(&f)
        }
        return f
    }

    static func mood(of limits: [Limit]) -> Mood {
        guard let highest = limits.map({ $0.percent }).max() else { return .normal }
        if highest >= 90 { return .panic }
        if highest <= 5 { return .sleepy }
        return .normal
    }

    // Dessine dans un repere ou y descend (vue retournee). frame avance toutes les 120 ms ; 0 donne la pose fixe.
    func draw(at origin: NSPoint, pixel: CGFloat, frame: Int = 0, mood: Mood = .normal, blink: Bool = false) {
        var f = animate(frame, mood)
        if blink { self.blink(&f) }
        for (row, line) in f.cells.enumerated() {
            for (col, character) in line.enumerated() {
                let color: NSColor?
                switch character {
                case "#": color = body
                case "x": color = inner
                case "o": color = detail
                case "w": color = Mascot.light
                case "b": color = Mascot.sweat
                case "z": color = Mascot.sleep
                case "r": color = Mascot.alert
                default: color = nil
                }
                if let color = color {
                    color.setFill()
                    NSRect(x: origin.x + CGFloat(col + f.dx) * pixel, y: origin.y + CGFloat(row + f.dy) * pixel,
                           width: pixel, height: pixel).fill()
                }
            }
        }
    }

    // Image de la barre de menu : une marge de 2 pixels en haut (saut) et de 1 en bas et a droite
    // (respiration, tremblement) pour que les animations ne soient jamais coupees.
    static let imagePixels = (width: width + 1, height: 11, top: 2)

    func image(pixel: CGFloat, frame: Int = 0, mood: Mood = .normal, blink: Bool = false) -> NSImage {
        let mascot = self
        let size = NSSize(width: CGFloat(Self.imagePixels.width) * pixel, height: CGFloat(Self.imagePixels.height) * pixel)
        return NSImage(size: size, flipped: true) { _ in
            mascot.draw(at: NSPoint(x: 0, y: CGFloat(Self.imagePixels.top) * pixel), pixel: pixel, frame: frame, mood: mood,
                        blink: blink)
            return true
        }
    }
}

// Verifie sur GitHub si une version plus recente est publiee. Rien d'autre n'est envoye.
enum Updates {
    static let version = "1.0.0"
    static let releasesURL = URL(string: "https://github.com/ParvaCamer/session-ai-usage-widget/releases/latest")!
    static let apiURL = URL(string: "https://api.github.com/repos/ParvaCamer/session-ai-usage-widget/releases/latest")!
    static let arrow = ["..###..", "..###..", "..###..", "#######", ".#####.", "..###..", "...#...", "#######"]

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let l = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}

// Une partie du widget par outil suivi.
final class Section {
    let name: String
    let mascot: Mascot
    var visible = true
    var limits: [Limit] = []
    var message: String? = "Chargement…"
    var loginNeeded = false
    var lastOk: Date?

    init(name: String, mascot: Mascot) {
        self.name = name
        self.mascot = mascot
    }
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
    var animationFrame = 0
    var onClick: ((NSPoint) -> Void)?
    var updateVersion: String?
    private(set) var updateHit = NSRect.zero
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
        if !dragged { onClick?(convert(event.locationInWindow, from: nil)) }
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

        if updateVersion != nil { drawUpdateArrow() }
    }

    // Fleche de telechargement en haut a droite, qui rebondit doucement. Un clic ouvre la page des versions.
    private func drawUpdateArrow() {
        let pixel: CGFloat = 2
        let width = CGFloat(Updates.arrow[0].count) * pixel
        let left = bounds.width - Self.pad - width
        let top = Self.pad + 2 + ((animationFrame / 4) % 2 == 1 ? pixel : 0)
        NSColor(srgbRed: 111 / 255, green: 207 / 255, blue: 151 / 255, alpha: 1).setFill()
        for (row, line) in Updates.arrow.enumerated() {
            for (col, character) in line.enumerated() where character == "#" {
                NSRect(x: left + CGFloat(col) * pixel, y: top + CGFloat(row) * pixel, width: pixel, height: pixel).fill()
            }
        }
        updateHit = NSRect(x: left - 6, y: Self.pad - 6, width: width + 12, height: 9 * pixel + 12)
    }

    private func drawSection(_ section: Section, x: CGFloat, y top: CGFloat, width: CGFloat) {
        section.mascot.draw(at: NSPoint(x: x, y: top + 1), pixel: 2, frame: animationFrame,
                            mood: Mascot.mood(of: section.limits))
        draw(section.name, font: .systemFont(ofSize: 12, weight: .semibold), color: Self.muted,
             in: NSRect(x: x + 24, y: top, width: width - 24, height: Self.headerHeight))
        var y = top + Self.headerHeight

        for limit in section.limits {
            drawRow(limit, x: x, y: y, width: width, normal: section.mascot.body)
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

    private func drawRow(_ limit: Limit, x: CGFloat, y: CGFloat, width: CGFloat, normal: NSColor) {
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

        let color = limit.percent >= 90 ? Self.danger : limit.percent >= 70 ? Self.warn : normal
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
    private let claude = Section(name: "Claude", mascot: .claude)
    private let codex = Section(name: "Codex", mascot: .codex)
    private var codexBusy = false
    private var lastRefresh = Date.distantPast
    private var animationTick = 0
    private var menuBarFrame = 0

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
        Timer.scheduledTimer(timeInterval: 0.12, target: self, selector: #selector(animate),
                             userInfo: nil, repeats: true)
        Timer.scheduledTimer(timeInterval: 6 * 3600, target: self, selector: #selector(checkForUpdate),
                             userInfo: nil, repeats: true)
        checkForUpdate()
        refreshDisplay()
        refreshAll()
    }

    @objc private func refreshAll() {
        lastRefresh = Date()
        startMenuBarBurst()
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

    // Nouvelles versions : au lancement puis toutes les 6 heures. Seul le numero de version est lu.
    @objc private func checkForUpdate() {
        var request = URLRequest(url: Updates.apiURL, timeoutInterval: 15)
        request.setValue("claude-usage-widget/\(Updates.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
            guard Updates.isNewer(latest, than: Updates.version) else { return }
            self?.performSelector(onMainThread: #selector(AppDelegate.updateFound(_:)), with: latest as NSString,
                                  waitUntilDone: false)
        }.resume()
    }

    @objc private func updateFound(_ version: NSString) {
        widget.updateVersion = version as String
        widget.needsDisplay = true
    }

    @objc private func openReleases() {
        NSWorkspace.shared.open(Updates.releasesURL)
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
        widget.onClick = { [weak self] point in self?.widgetClicked(at: point) }

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

    private func widgetClicked(at point: NSPoint) {
        if widget.updateVersion != nil && widget.updateHit.contains(point) {
            openReleases()
        } else if claude.visible && claude.loginNeeded {
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

    // Les mascottes ne bougent que la ou elles sont vraiment visibles a l'ecran.
    // Barre de menu : la boucle complete se joue a chaque actualisation (toutes les 2 minutes) ;
    // entre deux, la mascotte cligne simplement des yeux toutes les 4 secondes environ.
    private let menuBarBurstLength = 96 // une boucle complete de Claude, environ 11 secondes
    private let blinkEvery = 34         // en images de 120 ms
    private let blinkLength = 2
    private var menuBarBurstStart: Int?
    private var menuBarBlink = false

    private func startMenuBarBurst() {
        menuBarBurstStart = animationTick
    }

    @objc private func animate() {
        animationTick += 1
        if panel.isVisible, panel.occlusionState.contains(.visible) {
            widget.animationFrame = animationTick
            widget.needsDisplay = true
        }

        let previous = (frame: menuBarFrame, blink: menuBarBlink)
        if let start = menuBarBurstStart, animationTick - start < menuBarBurstLength {
            menuBarFrame = animationTick - start + 1
            menuBarBlink = false
        } else {
            menuBarBurstStart = nil
            menuBarFrame = 0
            menuBarBlink = animationTick % blinkEvery < blinkLength
        }

        // Pendant la boucle, une image sur deux (environ 4 fois par seconde) ; au repos, seulement quand l'image change.
        let changed = menuBarFrame != previous.frame || menuBarBlink != previous.blink
        let due = menuBarFrame == 0 ? changed : (menuBarFrame % 2 == 1 || menuBarFrame == menuBarBurstLength)
        if due, let window = statusItem.button?.window, window.occlusionState.contains(.visible) {
            updateMenuBar()
        }
    }

    // Barre de menu : la mascotte et le premier pourcentage de chaque outil affiche.
    private func updateMenuBar() {
        let pixel: CGFloat = 2
        let mascotSize = NSSize(width: CGFloat(Mascot.imagePixels.width) * pixel,
                                height: CGFloat(Mascot.imagePixels.height) * pixel)
        // Les pieds de la pose de repos restent a la meme hauteur qu'avant l'ajout des marges.
        let bottomMargin = CGFloat(Mascot.imagePixels.height - Mascot.imagePixels.top - 8) * pixel
        let title = NSMutableAttributedString()
        let font = NSFont.menuBarFont(ofSize: 0)
        for section in widget.sections where section.visible {
            guard let first = section.limits.first else { continue }
            if title.length > 0 { title.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            let attachment = NSTextAttachment()
            attachment.image = section.mascot.image(pixel: pixel, frame: menuBarFrame,
                                                    mood: Mascot.mood(of: section.limits), blink: menuBarBlink)
            attachment.bounds = NSRect(origin: NSPoint(x: 0, y: -3 - bottomMargin), size: mascotSize)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: " " + percentText(first.percent), attributes: [.font: font]))
        }
        if title.length > 0 {
            statusItem.button?.attributedTitle = title
        } else {
            statusItem.button?.title = claude.visible && claude.loginNeeded ? "Claude ?" : "Claude…"
        }
    }

    private func refreshDisplay() {
        updateMenuBar()

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

        if let version = widget.updateVersion {
            add("Télécharger la mise à jour v\(version)", #selector(openReleases))
            menu.addItem(.separator())
        }
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
