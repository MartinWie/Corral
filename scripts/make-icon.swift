// Builds Resources/app/AppIcon.icns from assets/icon-art.png (square, full bleed).
//   swift scripts/make-icon.swift [new-art.png]
// New art is re-encoded into assets/icon-art.png first, which drops the generator's C2PA and EXIF
// chunks (ImageIO writes back only the size and color space).
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let artURL = root.appendingPathComponent("assets/icon-art.png")

func load(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("cannot read \(url.lastPathComponent)") }
    return image
}

func context(_ px: Int) -> CGContext {
    CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func save(_ image: CGImage, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.lastPathComponent)") }
}

if CommandLine.arguments.count > 1 {
    let art = load(URL(fileURLWithPath: CommandLine.arguments[1]))
    let ctx = context(1024)
    ctx.interpolationQuality = .high
    ctx.draw(art, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    save(ctx.makeImage()!, artURL)
}

// macOS icon grid: 824 pt body centered on a 1024 canvas, soft drop shadow, faint top sheen and rim.
let art = load(artURL)
let ctx = context(1024)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.09, blue: 0.13, alpha: 1))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(art, in: body)
let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: [CGColor(gray: 1, alpha: 0.12), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.midY), options: [])
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1, dy: 1), cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.16))
ctx.setLineWidth(2)
ctx.strokePath()
let master = ctx.makeImage()!

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("CorralIcon-\(UUID().uuidString).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let small = context(px)
        small.interpolationQuality = .high
        small.draw(master, in: CGRect(x: 0, y: 0, width: px, height: px))
        save(small.makeImage()!, iconset.appendingPathComponent(scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/app/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Resources/app/AppIcon.icns")
