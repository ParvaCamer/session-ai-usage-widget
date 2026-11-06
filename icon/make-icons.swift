// Genere les icones de l'app a partir de la mascotte en pixel art du widget (ce n'est pas le logo officiel de Claude).
//   swift icon/make-icons.swift
// Produit mac/AppIcon.icns (via iconutil) et windows/ClaudeUsage.ico. Rien a installer : seulement macOS.
// Option : --preview chemin.png pour une planche de verification.

import AppKit

// Grille de 16 x 16 cases : la mascotte (10 x 8) au-dessus d'une jauge remplie a 70 %.
let mascot = ["....##....", "...####...", "..######..", "..#o##o#..",
              "..######..", "..######..", "...####...", "..#....#.."]
let mascotOrigin = (col: 3, row: 2)
let gauge = (col: 3, row: 12, width: 10, height: 2, filled: 7)

func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

let body = rgb(217, 119, 87)
let eyes = rgb(31, 30, 29)
let track = rgb(58, 56, 52)
let backgroundTop = rgb(46, 44, 41)
let backgroundBottom = rgb(26, 25, 23)
let edge = rgb(72, 70, 65)

enum Style { case mac, windows }

// Taille de la tuile : un multiple de 16 pour que chaque case tombe sur des pixels entiers.
// macOS laisse une marge autour de la tuile (comme les icones d'Apple) ; Windows la fait remplir l'image.
func tile(size: Int, style: Style) -> (origin: Int, cell: Int) {
    if style == .mac {
        let cell = Int(Double(size) * 0.8) / 16
        if cell * 16 >= Int(Double(size) * 0.6) { return ((size - cell * 16) / 2, cell) }
    }
    return (0, size / 16)
}

func render(size: Int, style: Style) -> CGImage {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Repere avec y vers le bas, comme la grille.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)

    let (origin, cell) = tile(size: size, style: style)
    let side = CGFloat(cell * 16)
    let rect = CGRect(x: CGFloat(origin), y: CGFloat(origin), width: side, height: side)
    let radius = side * (style == .mac ? 0.225 : 0.18)
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Ombre portee discrete sous la tuile, sur les grandes icones macOS.
    if style == .mac && size >= 128 {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: CGFloat(size) * 0.012), blur: CGFloat(size) * 0.025,
                          color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(shape)
        context.setFillColor(backgroundBottom)
        context.fillPath()
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [backgroundTop, backgroundBottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY),
                               options: [])
    context.restoreGState()

    if size >= 64 {
        let width = max(1, side / 160)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2), cornerWidth: radius,
                               cornerHeight: radius, transform: nil))
        context.setStrokeColor(edge)
        context.setLineWidth(width)
        context.strokePath()
    }

    // Pixels de la mascotte et de la jauge, alignes sur la grille, sans lissage.
    context.setShouldAntialias(false)
    func fill(col: Int, row: Int, width: Int = 1, height: Int = 1, color: CGColor) {
        context.setFillColor(color)
        context.fill(CGRect(x: origin + col * cell, y: origin + row * cell, width: width * cell, height: height * cell))
    }
    for (row, line) in mascot.enumerated() {
        for (col, character) in line.enumerated() where character != "." {
            fill(col: mascotOrigin.col + col, row: mascotOrigin.row + row, color: character == "o" ? eyes : body)
        }
    }
    fill(col: gauge.col, row: gauge.row, width: gauge.width, height: gauge.height, color: track)
    fill(col: gauge.col, row: gauge.row, width: gauge.filled, height: gauge.height, color: body)

    return context.makeImage()!
}

func png(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

// Image 32 bits au format BMP d'icone (lignes de bas en haut, puis un masque vide) : lue par tous les outils Windows.
func iconBitmap(_ image: CGImage) -> Data {
    let size = image.width
    let rep = NSBitmapImageRep(cgImage: image)
    var data = Data()
    func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    put32(40); put32(UInt32(size)); put32(UInt32(size * 2)); put16(1); put16(32)
    put32(0); put32(0); put32(0); put32(0); put32(0); put32(0)
    for y in stride(from: size - 1, through: 0, by: -1) {
        for x in 0..<size {
            let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            let a = c.alphaComponent
            // Couleurs non premultipliees, comme l'attend Windows.
            data.append(contentsOf: [UInt8((c.blueComponent * 255).rounded()), UInt8((c.greenComponent * 255).rounded()),
                                     UInt8((c.redComponent * 255).rounded()), UInt8((a * 255).rounded())])
        }
    }
    data.append(Data(count: ((size + 31) / 32) * 4 * size)) // masque ET : vide, la transparence vient de l'alpha
    return data
}

func writeIco(to url: URL) throws {
    let sizes = [16, 24, 32, 48, 64, 128, 256]
    let images = sizes.map { size -> Data in
        let image = render(size: size, style: .windows)
        return size == 256 ? png(image) : iconBitmap(image) // 256 : PNG, comme le fait Windows lui-meme
    }
    var data = Data()
    func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    put16(0); put16(1); put16(UInt16(sizes.count))
    var offset = 6 + 16 * sizes.count
    for (size, image) in zip(sizes, images) {
        data.append(contentsOf: [UInt8(size == 256 ? 0 : size), UInt8(size == 256 ? 0 : size), 0, 0])
        put16(1); put16(32); put32(UInt32(image.count)); put32(UInt32(offset))
        offset += image.count
    }
    images.forEach { data.append($0) }
    try data.write(to: url)
}

func writeIcns(to url: URL) throws {
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }
    for points in [16, 32, 128, 256, 512] {
        try png(render(size: points, style: .mac)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try png(render(size: points * 2, style: .mac))
            .write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
}

// Planche de verification : chaque taille macOS et Windows, sur fond clair puis sombre.
func writePreview(to url: URL) throws {
    let sizes = [16, 32, 64, 128, 256]
    let width = sizes.reduce(0) { $0 + $1 + 24 } + 24
    let height = (256 + 48) * 4
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for (band, (style, dark)) in [(Style.mac, false), (.mac, true), (.windows, false), (.windows, true)].enumerated() {
        let y = height - (band + 1) * (height / 4)
        context.setFillColor(dark ? rgb(30, 30, 30) : rgb(236, 236, 236))
        context.fill(CGRect(x: 0, y: y, width: width, height: height / 4))
        var x = 24
        for size in sizes {
            context.draw(render(size: size, style: style), in: CGRect(x: x, y: y + 24, width: size, height: size))
            x += size + 24
        }
    }
    try png(context.makeImage()!).write(to: url)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--preview"), index + 1 < arguments.count {
    try writePreview(to: URL(fileURLWithPath: arguments[index + 1]))
} else {
    try writeIcns(to: root.appendingPathComponent("mac/AppIcon.icns"))
    try writeIco(to: root.appendingPathComponent("windows/ClaudeUsage.ico"))
    print("OK : mac/AppIcon.icns et windows/ClaudeUsage.ico")
}
