// The iOS part of app_icon.py in Swift, for Macs without numpy and Pillow (the owner's Mac
// has no arm64 Pillow). It ports render() for the opaque iOS master (tile, no corner radius),
// Pillow's LANCZOS resize and a plain PNG writer. The output matches app_icon.py pixel for
// pixel, so keep the two in step: a change to the artwork goes into both.
//
//   swiftc -O tool/art/render_icon.swift -o <dir>/render_icon
//   <dir>/render_icon ios <repo_root> [out_dir]     every iOS icon in Contents.json
//   <dir>/render_icon render <size> <ss> <disc_scale> <out.png> [bg_lo bg_hi]
//   <dir>/render_icon resize <master.png> <size> <out.png>
//   <dir>/render_icon compare <a.png> <b.png>       exits 1 if any pixel differs
//
// Without out_dir, `ios` overwrites the icons in the repository. PNG bytes differ from
// Pillow's even when the pixels match, so compare first and copy only what changed.
import CoreGraphics
import Compression
import Foundation
import ImageIO

// MARK: - The artwork (app_icon.py), in the same floating-point order as numpy

func clip(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
  let t = clip((x - e0) / (e1 - e0), 0.0, 1.0)
  return t * t * (3 - 2 * t)
}

/// np.interp: linear between the stops, held at the ends.
func interp(_ x: Double, _ xp: [Double], _ fp: [Double]) -> Double {
  let last = xp.count - 1
  if x < xp[0] { return fp[0] }
  if x >= xp[last] { return fp[last] }
  var j = 0
  while x >= xp[j + 1] { j += 1 }
  if xp[j] == x { return fp[j] }
  let slope = (fp[j + 1] - fp[j]) / (xp[j + 1] - xp[j])
  return slope * (x - xp[j]) + fp[j]
}

func sdRoundRect(
  _ x: Double, _ y: Double, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ r: Double
) -> Double {
  let qx = abs(x - (x0 + x1) / 2) - ((x1 - x0) / 2 - r)
  let qy = abs(y - (y0 + y1) / 2) - ((y1 - y0) / 2 - r)
  return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
}

/// Signed distance (in icon units, 0..1) of the white microphone glyph.
func micSdf(_ x: Double, _ y: Double) -> Double {
  let head = sdRoundRect(x, y, 0.38, 0.19, 0.62, 0.595, 0.12)
  // U-shaped holder around the lower half of the head
  let cx = 0.5, cy = 0.47, r = 0.178, t = 0.044
  let ring = abs(hypot(x - cx, y - cy) - r) - t / 2
  let arms = min(
    sdRoundRect(x, y, cx - r - t / 2, 0.44, cx - r + t / 2, cy + 0.001, t / 2),
    sdRoundRect(x, y, cx + r - t / 2, 0.44, cx + r + t / 2, cy + 0.001, t / 2))
  let holder = min(y >= cy ? ring : 1.0, arms)
  let stem = sdRoundRect(x, y, 0.477, cy + r, 0.523, 0.775, 0.004)
  let base = sdRoundRect(x, y, 0.37, 0.765, 0.63, 0.812, 0.008)
  var d = min(head, holder, stem, base)
  // 3 x 3 grille dots punched out of the head
  for yy in [0.245, 0.295, 0.345] {
    for xx in [0.44, 0.5, 0.56] {
      d = max(d, -(hypot(x - xx, y - yy) - 0.02))
    }
  }
  return d
}

/// For every pixel, how many pixels up-left along the 45 degree diagonal the nearest covered
/// pixel of [mask] is (min-plus doubling). Bottom-right first, so each step reads old values.
func diagonalDistance(_ mask: [Bool], _ n: Int, _ maxSteps: Int) -> [Double] {
  var d = mask.map { $0 ? 0.0 : 1e9 }
  var s = 1
  while s < maxSteps {
    for i in stride(from: n - 1, through: s, by: -1) {
      for j in stride(from: n - 1, through: s, by: -1) {
        let v = d[(i - s) * n + j - s] + Double(s)
        if v < d[i * n + j] { d[i * n + j] = v }
      }
    }
    s *= 2
  }
  return d
}

let tileStops: [[Double]] = [[255, 231, 194], [243, 227, 195], [245, 228, 197]]
let redAt: [Double] = [0.03, 0.35, 0.62, 0.84, 0.97]
let redStops: [[Double]] = [[192, 176, 132, 70, 56], [30, 29, 32, 38, 50], [46, 42, 44, 44, 52]]
let toneStops: [[Double]] = [[250, 226], [240, 229], [242, 231]]

/// render(size, ss, tile=True, tile_radius=0, disc_scale, bg_window=(bgLo, bgHi)), as RGB.
func render(size: Int, ss: Int, discScale: Double, bgLo: Double, bgHi: Double) -> [UInt8] {
  let n = size * ss
  let nd = Double(n)
  let px = 1.0 / nd
  let apx = px / discScale
  func coord(_ i: Int) -> Double { (Double(i) + 0.5) / nd }
  func art(_ v: Double) -> Double { (v - 0.5) / discScale + 0.5 }

  var m = [Double](repeating: 0, count: n * n)
  for i in 0..<n {
    let ay = art(coord(i))
    for j in 0..<n { m[i * n + j] = micSdf(art(coord(j)), ay) }
  }
  let reach = 0.55 * nd * discScale
  let dist = diagonalDistance(m.map { $0 < 0 }, n, Int(reach) + 1)

  var prem = [SIMD3<Double>](repeating: .zero, count: n * n)
  var alpha = [Double](repeating: 0, count: n * n)
  for i in 0..<n {
    let y = coord(i)
    let ay = art(y)
    for j in 0..<n {
      let ax = art(coord(j))
      let p = i * n + j
      var rgb = SIMD3<Double>.zero
      var al = 0.0
      func over(_ src: SIMD3<Double>, _ a: Double) {
        let outA = a + al * (1 - a)
        rgb = (src * a + rgb * (al * (1 - a))) / (outA > 1e-6 ? outA : 1)
        al = outA
      }
      // the tile, without corners: iOS rounds them
      let gy = bgLo + (bgHi - bgLo) * y
      let g = SIMD3(
        interp(gy, [0, 0.5, 1], tileStops[0]), interp(gy, [0, 0.5, 1], tileStops[1]),
        interp(gy, [0, 0.5, 1], tileStops[2]))
      over(g * (0.86 + 0.14 * 1.0), 1.0)
      // red disc with a sideways falloff and the long shadow
      let dd = hypot(ax - 0.5, ay - 0.5) - 0.465
      let a = clip(0.5 - dd / apx, 0, 1)
      var red = SIMD3(
        interp(ay, redAt, redStops[0]), interp(ay, redAt, redStops[1]),
        interp(ay, redAt, redStops[2]))
      red = red * (0.86 + 0.14 * (1 - smoothstep(0.1, 0.47, abs(ax - 0.5))))
      let shadow = dist[p] <= reach ? 1 - 0.45 * clip(dist[p] / reach, 0, 1) : 0.0
      red = red * (1 - 0.32 * shadow)
      over(red, a)
      // white microphone
      let glyph = clip(0.5 - m[p] / apx, 0, 1)
      let tone = SIMD3(
        interp(ay, [0.18, 0.8], toneStops[0]), interp(ay, [0.18, 0.8], toneStops[1]),
        interp(ay, [0.18, 0.8], toneStops[2]))
      over(tone, glyph * a)
      prem[p] = rgb * al
      alpha[p] = al
    }
  }

  // Box downsample of the premultiplied colour. numpy sums alpha a sub-row at a time and
  // the colour in memory order; rounding is half to even.
  var out = [UInt8](repeating: 0, count: size * size * 3)
  let count = Double(ss * ss)
  for oy in 0..<size {
    for ox in 0..<size {
      var aSum = 0.0
      var pSum = SIMD3<Double>.zero
      for sy in 0..<ss {
        var row = 0.0
        for sx in 0..<ss {
          let p = (oy * ss + sy) * n + ox * ss + sx
          row += alpha[p]
          pSum += prem[p]
        }
        aSum += row
      }
      let aD = aSum / count
      let rgbD = (pSum / count) / (aD > 1e-6 ? aD : 1)
      for c in 0..<3 {
        out[(oy * size + ox) * 3 + c] = UInt8(clip(rgbD[c], 0, 255).rounded(.toNearestOrEven))
      }
    }
  }
  return out
}

// MARK: - Pillow's LANCZOS resize (Resample.c, 8 bits per channel)

func lanczos(_ x: Double) -> Double {
  func sinc(_ x: Double) -> Double {
    if x == 0.0 { return 1.0 }
    let v = x * Double.pi
    return sin(v) / v
  }
  return -3.0 <= x && x < 3.0 ? sinc(x) * sinc(x / 3) : 0.0
}

/// Per output pixel: the first input pixel, how many, and 22-bit fixed-point weights.
func coefficients(_ inSize: Int, _ outSize: Int) -> [(Int, Int, [Int])] {
  let scale = Double(inSize) / Double(outSize)
  let filterscale = max(scale, 1.0)
  let support = 3.0 * filterscale
  let ss = 1.0 / filterscale
  return (0..<outSize).map { xx in
    let center = (Double(xx) + 0.5) * scale
    let xmin = max(Int(center - support + 0.5), 0)
    let xmax = min(Int(center + support + 0.5), inSize) - xmin
    var k = [Double](repeating: 0, count: xmax)
    var ww = 0.0
    for x in 0..<xmax {
      k[x] = lanczos((Double(x + xmin) - center + 0.5) * ss)
      ww += k[x]
    }
    let fixed = k.map { w -> Int in
      let v = ww != 0.0 ? w / ww : w
      return v < 0 ? Int(-0.5 + v * 4194304.0) : Int(0.5 + v * 4194304.0)
    }
    return (xmin, xmax, fixed)
  }
}

func clip8(_ v: Int) -> UInt8 { UInt8(min(max(v >> 22, 0), 255)) }

/// Image.resize((size, size), Image.LANCZOS) of a square RGB image.
func resize(_ src: [UInt8], from inSize: Int, to size: Int) -> [UInt8] {
  if size == inSize { return src }
  let kx = coefficients(inSize, size)
  var temp = [UInt8](repeating: 0, count: inSize * size * 3)
  for y in 0..<inSize {
    for (xx, (xmin, xmax, k)) in kx.enumerated() {
      for c in 0..<3 {
        var s = 1 << 21
        for x in 0..<xmax { s += Int(src[(y * inSize + x + xmin) * 3 + c]) * k[x] }
        temp[(y * size + xx) * 3 + c] = clip8(s)
      }
    }
  }
  let ky = coefficients(inSize, size)
  var out = [UInt8](repeating: 0, count: size * size * 3)
  for (yy, (ymin, ymax, k)) in ky.enumerated() {
    for xx in 0..<size {
      for c in 0..<3 {
        var s = 1 << 21
        for y in 0..<ymax { s += Int(temp[((y + ymin) * size + xx) * 3 + c]) * k[y] }
        out[(yy * size + xx) * 3 + c] = clip8(s)
      }
    }
  }
  return out
}

// MARK: - PNG in and out

/// The decoded bytes as stored, without any colour conversion: (width, height, RGBA).
func loadPNG(_ path: String) -> (Int, Int, [UInt8]) {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let data = image.dataProvider?.data as Data?
  else { fatalError("can't read \(path)") }
  let bpp = image.bitsPerPixel / 8
  precondition(image.bitsPerComponent == 8 && (bpp == 3 || bpp == 4), "\(path): not 8-bit RGB")
  var order = [0, 1, 2, 3]  // where R, G, B, A are in a pixel
  if bpp == 4 {
    let info = image.alphaInfo
    if [.first, .premultipliedFirst, .noneSkipFirst].contains(info) { order = [1, 2, 3, 0] }
    if image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little {
      order = order.map { 3 - $0 }
    }
  }
  let opaque = bpp == 3 || [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
  let (w, h) = (image.width, image.height)
  var out = [UInt8](repeating: 255, count: w * h * 4)
  let bytes = [UInt8](data)
  for y in 0..<h {
    for x in 0..<w {
      let p = y * image.bytesPerRow + x * bpp
      for c in 0..<(opaque ? 3 : 4) { out[(y * w + x) * 4 + c] = bytes[p + order[c]] }
    }
  }
  return (w, h, out)
}

let crcTable: [UInt32] = (0..<256).map { n in
  var c = UInt32(n)
  for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
  return c
}

func bigEndian(_ v: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: v >> $0) } }

/// An 8-bit RGB PNG with only IHDR, IDAT and IEND: no colour profile or gamma to shift it.
func writePNG(_ path: String, size: Int, rgb: [UInt8]) {
  var raw = [UInt8]()
  raw.reserveCapacity((size * 3 + 1) * size)
  for y in 0..<size {
    raw.append(0)
    raw.append(contentsOf: rgb[(y * size * 3)..<((y + 1) * size * 3)])
  }
  var deflated = [UInt8](repeating: 0, count: raw.count + raw.count / 2 + 1024)
  let n = compression_encode_buffer(&deflated, deflated.count, raw, raw.count, nil, COMPRESSION_ZLIB)
  precondition(n > 0, "compression failed")
  var a: UInt32 = 1
  var b: UInt32 = 0
  for byte in raw {
    a = (a + UInt32(byte)) % 65521
    b = (b + a) % 65521
  }
  let zlib = [0x78, 0x9C] + deflated[0..<n] + bigEndian(b << 16 | a)

  var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  func chunk(_ type: String, _ body: [UInt8]) {
    let typed = Array(type.utf8) + body
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in typed { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    png += bigEndian(UInt32(body.count)) + typed + bigEndian(crc ^ 0xFFFF_FFFF)
  }
  chunk("IHDR", bigEndian(UInt32(size)) + bigEndian(UInt32(size)) + [8, 2, 0, 0, 0])
  chunk("IDAT", zlib)
  chunk("IEND", [])
  try! Data(png).write(to: URL(fileURLWithPath: path))
}

func rgbOf(_ rgba: [UInt8]) -> [UInt8] {
  rgba.enumerated().filter { $0.offset % 4 != 3 }.map { $0.element }
}

// MARK: - Commands

let args = CommandLine.arguments
func usage() -> Never {
  print(
    """
    usage: render_icon ios <repo_root> [out_dir]
           render_icon render <size> <ss> <disc_scale> <out.png> [bg_lo bg_hi]
           render_icon resize <master.png> <size> <out.png>
           render_icon compare <a.png> <b.png>
    """)
  exit(2)
}

switch args.count > 1 ? args[1] : "" {
case "ios" where args.count >= 3:
  let set = "\(args[2])/ios/Runner/Assets.xcassets/AppIcon.appiconset"
  let outDir = args.count > 3 ? args[3] : set
  let json = try! JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: "\(set)/Contents.json"))) as! [String: Any]
  // What Android's adaptive icon shows inside its 72 dp mask: the middle of the 108 dp
  // layers, so the disc is 0.64 * 108 / 72 = 0.96 and the tile's gradient runs from 18 dp
  // to 90 dp. iOS then rounds the corners.
  let master = render(size: 1024, ss: 2, discScale: 0.96, bgLo: 18.0 / 108, bgHi: 90.0 / 108)
  var done = Set<String>()
  for image in json["images"] as! [[String: Any]] {
    guard let name = image["filename"] as? String, done.insert(name).inserted else { continue }
    let points = Double((image["size"] as! String).split(separator: "x")[0])!
    let scale = Double((image["scale"] as! String).dropLast())!
    let px = Int((points * scale).rounded(.toNearestOrEven))
    writePNG("\(outDir)/\(name)", size: px, rgb: resize(master, from: 1024, to: px))
    print("\(name): \(px) px")
  }
case "render" where args.count == 6 || args.count == 8:
  let size = Int(args[2])!
  let rgb = render(
    size: size, ss: Int(args[3])!, discScale: Double(args[4])!,
    bgLo: args.count == 8 ? Double(args[6])! : 0.0, bgHi: args.count == 8 ? Double(args[7])! : 1.0)
  writePNG(args[5], size: size, rgb: rgb)
case "resize" where args.count == 5:
  let (w, h, rgba) = loadPNG(args[2])
  precondition(w == h, "the master must be square")
  let size = Int(args[3])!
  writePNG(args[4], size: size, rgb: resize(rgbOf(rgba), from: w, to: size))
case "compare" where args.count == 4:
  let (wa, ha, a) = loadPNG(args[2])
  let (wb, hb, b) = loadPNG(args[3])
  guard wa == wb && ha == hb else {
    print("sizes differ: \(wa)x\(ha) and \(wb)x\(hb)")
    exit(1)
  }
  var differing = 0
  var worst = 0
  for p in 0..<(wa * ha) {
    let d = (0..<4).map { abs(Int(a[p * 4 + $0]) - Int(b[p * 4 + $0])) }.max()!
    if d > 0 { differing += 1 }
    worst = max(worst, d)
  }
  print("\(differing) of \(wa * ha) pixels differ, by at most \(worst)")
  exit(differing == 0 ? 0 : 1)
default:
  usage()
}
