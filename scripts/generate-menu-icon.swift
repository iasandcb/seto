// Run from the repository root: swift scripts/generate-menu-icon.swift
import AppKit
import CoreText

// Center the glyph's visible outline, rather than its line box/baseline.
// A vector template lets macOS choose the foreground color for each appearance.
let font = CTFontCreateWithName("AppleSDGothicNeo-SemiBold" as CFString, 16, nil)
var character: UniChar = 0xC138 // 세
var glyph: CGGlyph = 0
precondition(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
let outline = CTFontCreatePathForGlyph(font, glyph, nil)!
let bounds = outline.boundingBoxOfPath
let scale = min(14 / bounds.width, 13 / bounds.height)
var transform = CGAffineTransform(
    a: scale, b: 0, c: 0, d: scale,
    tx: (22 - bounds.width * scale) / 2 - bounds.minX * scale,
    ty: (16 - bounds.height * scale) / 2 - bounds.minY * scale
)
let centered = outline.copy(using: &transform)!
let destination = URL(fileURLWithPath: "Resources/SetoMenu.pdf")
var page = CGRect(x: 0, y: 0, width: 22, height: 16)
let pdf = CGContext(destination as CFURL, mediaBox: &page, nil)!
pdf.beginPDFPage(nil)
pdf.setFillColor(CGColor(gray: 0, alpha: 1))
pdf.addPath(centered)
pdf.fillPath()
pdf.endPDFPage()
pdf.closePDF()

// Optional enlarged light/dark preview, outside the app bundle.
if CommandLine.arguments.count > 1 {
    let context = CGContext(data: nil, width: 352, height: 128, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: 8, y: 8)
    for dark in [false, true] {
        context.saveGState()
        context.translateBy(x: dark ? 22 : 0, y: 0)
        context.setFillColor(CGColor(gray: dark ? 0.12 : 0.96, alpha: 1))
        context.fill(page)
        context.setFillColor(CGColor(gray: dark ? 1 : 0, alpha: 1))
        context.addPath(centered)
        context.fillPath()
        context.restoreGState()
    }
    let preview = NSBitmapImageRep(cgImage: context.makeImage()!)
    try preview.representation(using: .png, properties: [:])!.write(
        to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
