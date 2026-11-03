import AppKit

// Compares every PNG in <before> with the one of the same name in <after>. Writes <out>/report.tsv
// (name, status, differing pixels, bounding box) and, for each pair that differs, a strip of the
// before, the after and the differences in red into <out>/diffs. Exit status 1 if any pair differs.
// Usage: parity-diff <before-dir> <after-dir> <out-dir>

struct Bitmap {
    let width: Int, height: Int
    let pixels: [UInt8]

    init?(_ url: URL) {
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        width = cg.width
        height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = data
    }
}

let args = CommandLine.arguments
let before = URL(fileURLWithPath: args[1]), after = URL(fileURLWithPath: args[2]), out = URL(fileURLWithPath: args[3])
let diffs = out.appending(path: "diffs")
try? FileManager.default.createDirectory(at: diffs, withIntermediateDirectories: true)
let names = Set((try? FileManager.default.contentsOfDirectory(atPath: before.path)) ?? []).union(
    (try? FileManager.default.contentsOfDirectory(atPath: after.path)) ?? []
).filter { $0.hasSuffix(".png") }.sorted()

var report = "name\tstatus\tpixels\tbox\n"
var different = 0, same = 0
for name in names {
    guard let a = Bitmap(before.appending(path: name)), let b = Bitmap(after.appending(path: name)) else {
        report += "\(name)\tmissing\t\t\n"
        different += 1
        continue
    }
    guard a.width == b.width, a.height == b.height else {
        report += "\(name)\tsize\t\(a.width)x\(a.height) vs \(b.width)x\(b.height)\t\n"
        different += 1
        continue
    }
    var count = 0, minX = Int.max, minY = Int.max, maxX = 0, maxY = 0
    var mask = [Bool](repeating: false, count: a.width * a.height)
    for i in 0..<(a.width * a.height) {
        let o = i * 4
        // A channel more than 2 apart: anything a person could see.
        if abs(Int(a.pixels[o]) - Int(b.pixels[o])) > 2 || abs(Int(a.pixels[o + 1]) - Int(b.pixels[o + 1])) > 2
            || abs(Int(a.pixels[o + 2]) - Int(b.pixels[o + 2])) > 2
        {
            count += 1
            mask[i] = true
            let x = i % a.width, y = i / a.width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    if count == 0 {
        report += "\(name)\tsame\t0\t\n"
        same += 1
        continue
    }
    different += 1
    report += "\(name)\tdiffers\t\(count)\t\(minX),\(minY) \(maxX - minX + 1)x\(maxY - minY + 1)\n"
    // Before | after | differences, side by side.
    let w = a.width, h = a.height
    var strip = [UInt8](repeating: 255, count: w * 3 * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let s = (y * w + x) * 4
            for (panel, source) in [a.pixels, b.pixels].enumerated() {
                let d = (y * w * 3 + panel * w + x) * 4
                strip[d] = source[s]; strip[d + 1] = source[s + 1]; strip[d + 2] = source[s + 2]; strip[d + 3] = 255
            }
            let d = (y * w * 3 + 2 * w + x) * 4
            if mask[y * w + x] {
                strip[d] = 255; strip[d + 1] = 0; strip[d + 2] = 0
            } else {
                let grey = UInt8((Int(b.pixels[s]) + Int(b.pixels[s + 1]) + Int(b.pixels[s + 2])) / 6 + 128)
                strip[d] = grey; strip[d + 1] = grey; strip[d + 2] = grey
            }
            strip[d + 3] = 255
        }
    }
    let provider = CGDataProvider(data: Data(strip) as CFData)!
    if let cg = CGImage(
        width: w * 3, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 12,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    {
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: diffs.appending(path: name))
    }
}
try? report.write(to: out.appending(path: "report.tsv"), atomically: true, encoding: .utf8)
print("\(names.count) cases: \(same) identical, \(different) different. Report: \(out.path)/report.tsv")
exit(different == 0 ? 0 : 1)
