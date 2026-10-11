import Foundation

/// Seam compositing for locally generated photo borders, shared by the Apple
/// Fast Clean Up helper and its synthetic tests. This is a Swift port of the
/// FLUX helpers' `KleinColorMatch.py`: match the generated border to the source
/// in perceptual OKLab, then join the two with a four-band Laplacian blend so
/// fine detail switches over a narrow band while lighting changes spread out.
/// It never touches a model, the file system, or Core Image.
let expansionCompositorVersion = 1

/// Interleaved RGB floats, rows top-down, sRGB-encoded in 0...1.
struct FloatRGBImage: Equatable {
    let width: Int
    let height: Int
    var data: [Float]

    init(width: Int, height: Int, data: [Float]) {
        precondition(data.count == width * height * 3, "Pixel data must contain width × height RGB triples.")
        self.width = width; self.height = height; self.data = data
    }

    init(width: Int, height: Int, fill: (Float, Float, Float) = (0, 0, 0)) {
        self.width = width; self.height = height
        data = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) { data[3 * i] = fill.0; data[3 * i + 1] = fill.1; data[3 * i + 2] = fill.2 }
    }

    @inline(__always) func index(_ x: Int, _ y: Int) -> Int { (y * width + x) * 3 }

    func pixel(_ x: Int, _ y: Int) -> (Float, Float, Float) {
        let i = index(x, y); return (data[i], data[i + 1], data[i + 2])
    }

    /// The source placed at (left, top) with its edge pixels replicated outward.
    func padded(toWidth canvasWidth: Int, height canvasHeight: Int, left: Int, top: Int) -> FloatRGBImage {
        var out = FloatRGBImage(width: canvasWidth, height: canvasHeight)
        out.data.withUnsafeMutableBufferPointer { o in
            data.withUnsafeBufferPointer { s in
                for y in 0..<canvasHeight {
                    let sy = min(max(y - top, 0), height - 1)
                    for x in 0..<canvasWidth {
                        let sx = min(max(x - left, 0), width - 1)
                        let si = (sy * width + sx) * 3, oi = (y * canvasWidth + x) * 3
                        o[oi] = s[si]; o[oi + 1] = s[si + 1]; o[oi + 2] = s[si + 2]
                    }
                }
            }
        }
        return out
    }
}

struct CompositorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - OKLab

@inline(__always) private func srgbToLinear(_ c: Float) -> Float {
    c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
}

@inline(__always) private func linearToSRGB(_ c: Float) -> Float {
    // Clip before the fractional power; this only matters once a corrected color
    // leaves the sRGB gamut.
    c <= 0.0031308 ? c * 12.92 : 1.055 * powf(max(c, 0), 1 / 2.4) - 0.055
}

@inline(__always) func rgbToOKLab(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
    let R = srgbToLinear(r), G = srgbToLinear(g), B = srgbToLinear(b)
    let l = cbrtf(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B)
    let m = cbrtf(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B)
    let s = cbrtf(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
}

@inline(__always) func okLabToRGB(_ L: Float, _ a: Float, _ b: Float) -> (Float, Float, Float) {
    let l_ = L + 0.3963377774 * a + 0.2158037573 * b
    let m_ = L - 0.1055613458 * a - 0.0638541728 * b
    let s_ = L - 0.0894841775 * a - 1.2914855480 * b
    let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
    let R = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    let G = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    let B = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return (min(max(linearToSRGB(R), 0), 1), min(max(linearToSRGB(G), 0), 1), min(max(linearToSRGB(B), 0), 1))
}

private func toOKLab(_ image: FloatRGBImage) -> [Float] {
    var lab = [Float](repeating: 0, count: image.data.count)
    lab.withUnsafeMutableBufferPointer { o in
        image.data.withUnsafeBufferPointer { s in
            var i = 0
            while i < s.count {
                let (L, a, b) = rgbToOKLab(s[i], s[i + 1], s[i + 2])
                o[i] = L; o[i + 1] = a; o[i + 2] = b
                i += 3
            }
        }
    }
    return lab
}

// MARK: - Border color harmonization

private func median(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}

/// Gaussian smoothing of a per-position Lab profile along the boundary.
private func smoothProfile(_ line: [(Float, Float, Float)], sigma: Float) -> [(Float, Float, Float)] {
    let radius = max(1, Int(ceil(3 * sigma)))
    var kernel = (-radius...radius).map { expf(-Float($0 * $0) / (2 * sigma * sigma)) }
    let total = kernel.reduce(0, +)
    kernel = kernel.map { $0 / total }
    let count = line.count
    var output = [(Float, Float, Float)](repeating: (0, 0, 0), count: count)
    for position in 0..<count {
        var L: Float = 0, a: Float = 0, b: Float = 0
        for (k, weight) in kernel.enumerated() {
            let sample = line[min(max(position + k - radius, 0), count - 1)]
            L += sample.0 * weight; a += sample.1 * weight; b += sample.2 * weight
        }
        output[position] = (L, a, b)
    }
    return output
}

@inline(__always) private func smoothstep(_ t: Float) -> Float {
    let x = min(max(t, 0), 1)
    return x * x * (3 - 2 * x)
}

struct BorderColorMatch {
    var image: FloatRGBImage
    var report: [String: Any]
}

/// Match the generated border (and its optional regenerated overlap) to the
/// source, then restore the source interior beyond `restoreInset`. Both images
/// are at model resolution; `left`/`top` locate the source in the canvas.
func harmonizeBorder(generated: FloatRGBImage, source: FloatRGBImage, left: Int, top: Int, restoreInset: Int) throws -> BorderColorMatch {
    let width = source.width, height = source.height
    let canvasWidth = generated.width, canvasHeight = generated.height
    let right = left + width, bottom = top + height
    guard min(width, height) >= 1, left >= 0, top >= 0, right <= canvasWidth, bottom <= canvasHeight else {
        throw CompositorError(message: "The source rectangle must fit inside the generated canvas.")
    }
    guard restoreInset >= 0, Float(restoreInset) < Float(min(width, height)) / 2 else {
        throw CompositorError(message: "The generated overlap must leave a protected source interior.")
    }
    let canvasLab = toOKLab(generated)
    let sourceLab = toOKLab(source)
    var field = [Float](repeating: 0, count: canvasLab.count)
    // A narrow strip avoids sampling unrelated scenery. Spatial smoothing removes
    // texture from the correction, so generated detail remains intact.
    let strip = max(1, min(8, Int((Float(min(width, height)) * 0.025).rounded())))
    let sigma = max(1.5, Float(min(width, height)) * 0.025)
    typealias Profile = [(Float, Float, Float)]
    var profiles: [String: Profile] = [:]
    var boundaries: [String: (reference: Profile, edge: Profile, sampler: ([Float]) -> Profile)] = [:]

    @inline(__always) func lab(_ buffer: [Float], _ stride: Int, _ x: Int, _ y: Int) -> (Float, Float, Float) {
        let i = (y * stride + x) * 3; return (buffer[i], buffer[i + 1], buffer[i + 2])
    }
    /// Median Lab across a strip of pixels for each position along an edge.
    func medianProfile(_ buffer: [Float], stride: Int, xRange: Range<Int>, yRange: Range<Int>, alongX: Bool) -> Profile {
        let positions = alongX ? xRange : yRange
        return positions.map { position -> (Float, Float, Float) in
            var Ls: [Float] = [], As: [Float] = [], Bs: [Float] = []
            for other in (alongX ? yRange : xRange) {
                let (x, y) = alongX ? (position, other) : (other, position)
                let v = lab(buffer, stride, x, y); Ls.append(v.0); As.append(v.1); Bs.append(v.2)
            }
            return (median(Ls), median(As), median(Bs))
        }
    }
    func profile(_ name: String, reference: Profile, edge: Profile, sampler: @escaping ([Float]) -> Profile) -> Profile {
        let raw = zip(reference, edge).map { ($0.0 - $1.0, $0.1 - $1.1, $0.2 - $1.2) }
        var delta = smoothProfile(raw, sigma: sigma)
        // Lighting differences often come from new scenery (for example a tree
        // against fog), rather than a grade. Smooth luminance more broadly and
        // limit its adjustment so those differences do not become bright bands.
        let luminance = smoothProfile(raw, sigma: sigma * 3)
        for i in delta.indices {
            delta[i] = (min(max(luminance[i].0, -0.12), 0.12), min(max(delta[i].1, -0.25), 0.25), min(max(delta[i].2, -0.25), 0.25))
        }
        profiles[name] = delta
        boundaries[name] = (reference, edge, sampler)
        return delta
    }

    if left > 0 {
        let count = min(strip, left, width)
        let delta = profile("left",
            reference: medianProfile(sourceLab, stride: width, xRange: 0..<count, yRange: 0..<height, alongX: false),
            edge: medianProfile(canvasLab, stride: canvasWidth, xRange: (left - count)..<left, yRange: top..<bottom, alongX: false),
            sampler: { medianProfile($0, stride: canvasWidth, xRange: (left - count)..<left, yRange: top..<bottom, alongX: false) })
        for y in top..<bottom { for x in 0..<left { let i = (y * canvasWidth + x) * 3; let d = delta[y - top]; field[i] = d.0; field[i + 1] = d.1; field[i + 2] = d.2 } }
    }
    if right < canvasWidth {
        let count = min(strip, canvasWidth - right, width)
        let delta = profile("right",
            reference: medianProfile(sourceLab, stride: width, xRange: (width - count)..<width, yRange: 0..<height, alongX: false),
            edge: medianProfile(canvasLab, stride: canvasWidth, xRange: right..<(right + count), yRange: top..<bottom, alongX: false),
            sampler: { medianProfile($0, stride: canvasWidth, xRange: right..<(right + count), yRange: top..<bottom, alongX: false) })
        for y in top..<bottom { for x in right..<canvasWidth { let i = (y * canvasWidth + x) * 3; let d = delta[y - top]; field[i] = d.0; field[i + 1] = d.1; field[i + 2] = d.2 } }
    }
    if top > 0 {
        let count = min(strip, top, height)
        let delta = profile("top",
            reference: medianProfile(sourceLab, stride: width, xRange: 0..<width, yRange: 0..<count, alongX: true),
            edge: medianProfile(canvasLab, stride: canvasWidth, xRange: left..<right, yRange: (top - count)..<top, alongX: true),
            sampler: { medianProfile($0, stride: canvasWidth, xRange: left..<right, yRange: (top - count)..<top, alongX: true) })
        for y in 0..<top { for x in left..<right { let i = (y * canvasWidth + x) * 3; let d = delta[x - left]; field[i] = d.0; field[i + 1] = d.1; field[i + 2] = d.2 } }
    }
    if bottom < canvasHeight {
        let count = min(strip, canvasHeight - bottom, height)
        let delta = profile("bottom",
            reference: medianProfile(sourceLab, stride: width, xRange: 0..<width, yRange: (height - count)..<height, alongX: true),
            edge: medianProfile(canvasLab, stride: canvasWidth, xRange: left..<right, yRange: bottom..<(bottom + count), alongX: true),
            sampler: { medianProfile($0, stride: canvasWidth, xRange: left..<right, yRange: bottom..<(bottom + count), alongX: true) })
        for y in bottom..<canvasHeight { for x in left..<right { let i = (y * canvasWidth + x) * 3; let d = delta[x - left]; field[i] = d.0; field[i + 1] = d.1; field[i + 2] = d.2 } }
    }

    // Continue each side continuously into its corners. Corrections stay active
    // at the outermost pixels; no halo is left by distance decay.
    func corner(xRange: Range<Int>, yRange: Range<Int>, horizontal: (Float, Float, Float), vertical: (Float, Float, Float), xReverse: Bool, yReverse: Bool) {
        let cornerWidth = xRange.count, cornerHeight = yRange.count
        guard cornerWidth > 0, cornerHeight > 0 else { return }
        for (yi, y) in yRange.enumerated() {
            let dy = Float(yReverse ? cornerHeight - yi : yi + 1)
            for (xi, x) in xRange.enumerated() {
                let dx = Float(xReverse ? cornerWidth - xi : xi + 1)
                let weight = dx / (dx + dy)
                let i = (y * canvasWidth + x) * 3
                field[i] = horizontal.0 * weight + vertical.0 * (1 - weight)
                field[i + 1] = horizontal.1 * weight + vertical.1 * (1 - weight)
                field[i + 2] = horizontal.2 * weight + vertical.2 * (1 - weight)
            }
        }
    }
    if let l = profiles["left"], let t = profiles["top"] { corner(xRange: 0..<left, yRange: 0..<top, horizontal: l[0], vertical: t[0], xReverse: true, yReverse: true) }
    if let r = profiles["right"], let t = profiles["top"] { corner(xRange: right..<canvasWidth, yRange: 0..<top, horizontal: r[0], vertical: t[t.count - 1], xReverse: false, yReverse: true) }
    if let l = profiles["left"], let b = profiles["bottom"] { corner(xRange: 0..<left, yRange: bottom..<canvasHeight, horizontal: l[l.count - 1], vertical: b[0], xReverse: true, yReverse: false) }
    if let r = profiles["right"], let b = profiles["bottom"] { corner(xRange: right..<canvasWidth, yRange: bottom..<canvasHeight, horizontal: r[r.count - 1], vertical: b[b.count - 1], xReverse: false, yReverse: false) }

    if !profiles.isEmpty {
        // Keep a shared white-balance correction across the whole border, but do
        // not project each local tree/sky lighting mismatch to the outer canvas.
        let sideMedians = profiles.values.map { p in (median(p.map { $0.0 }), median(p.map { $0.1 }), median(p.map { $0.2 })) }
        let global = (median(sideMedians.map { $0.0 }), median(sideMedians.map { $0.1 }), median(sideMedians.map { $0.2 }))
        let xReach = max(8, Float(max(left, canvasWidth - right)) * 0.32)
        let yReach = max(8, Float(max(top, canvasHeight - bottom)) * 0.32)
        for y in 0..<canvasHeight {
            let fy = Float(y)
            let dy = max(max(Float(top) - fy - 0.5, fy - Float(bottom) + 0.5), 0)
            for x in 0..<canvasWidth {
                let fx = Float(x)
                let dx = max(max(Float(left) - fx - 0.5, fx - Float(right) + 0.5), 0)
                let influence = expf(-sqrtf((dx / xReach) * (dx / xReach) + (dy / yReach) * (dy / yReach)))
                let i = (y * canvasWidth + x) * 3
                field[i] = global.0 + (field[i] - global.0) * influence
                field[i + 1] = global.1 + (field[i + 1] - global.1) * influence
                field[i + 2] = global.2 + (field[i + 2] - global.2) * influence
            }
        }
        for y in top..<bottom { for x in left..<right { let i = (y * canvasWidth + x) * 3; field[i] = 0; field[i + 1] = 0; field[i + 2] = 0 } }
    }

    if restoreInset > 0, !profiles.isEmpty {
        // Carry the SAME color correction across the photograph boundary.
        // Correcting only the outside, then pasting raw generated overlap inside,
        // creates a color step that no subsequent inner feather can remove.
        for y in top..<bottom {
            let yy = Float(y - top) + 0.5
            for x in left..<right {
                let xx = Float(x - left) + 0.5
                var weighted: (Float, Float, Float) = (0, 0, 0)
                var total: Float = 0, opacity: Float = 0
                func accumulate(_ distance: Float, _ sourceIndex: Int) {
                    let fade = 1 - smoothstep(distance / Float(restoreInset))
                    let weight = fade / (distance * distance)
                    weighted.0 += field[sourceIndex] * weight
                    weighted.1 += field[sourceIndex + 1] * weight
                    weighted.2 += field[sourceIndex + 2] * weight
                    total += weight; opacity = max(opacity, fade)
                }
                if left > 0 { accumulate(xx, (y * canvasWidth + left - 1) * 3) }
                if right < canvasWidth { accumulate(Float(width) - xx, (y * canvasWidth + right) * 3) }
                if top > 0 { accumulate(yy, ((top - 1) * canvasWidth + x) * 3) }
                if bottom < canvasHeight { accumulate(Float(height) - yy, (bottom * canvasWidth + x) * 3) }
                let i = (y * canvasWidth + x) * 3
                let scale = opacity / max(total, 1e-12)
                field[i] = weighted.0 * scale; field[i + 1] = weighted.1 * scale; field[i + 2] = weighted.2 * scale
            }
        }
    }

    var corrected = FloatRGBImage(width: canvasWidth, height: canvasHeight)
    var maxCorrection: (Float, Float, Float) = (0, 0, 0)
    corrected.data.withUnsafeMutableBufferPointer { o in
        var i = 0
        while i < canvasLab.count {
            maxCorrection = (max(maxCorrection.0, abs(field[i])), max(maxCorrection.1, abs(field[i + 1])), max(maxCorrection.2, abs(field[i + 2])))
            let (r, g, b) = okLabToRGB(canvasLab[i] + field[i], canvasLab[i + 1] + field[i + 1], canvasLab[i + 2] + field[i + 2])
            o[i] = r; o[i + 1] = g; o[i + 2] = b
            i += 3
        }
    }
    let inset = restoreInset
    for y in (top + inset)..<(bottom - inset) {
        for x in (left + inset)..<(right - inset) {
            let ci = corrected.index(x, y), si = source.index(x - left, y - top)
            corrected.data[ci] = source.data[si]; corrected.data[ci + 1] = source.data[si + 1]; corrected.data[ci + 2] = source.data[si + 2]
        }
    }
    var before: [String: Double] = [:], after: [String: Double] = [:]
    if !boundaries.isEmpty {
        let correctedLab = toOKLab(corrected)
        for (name, boundary) in boundaries {
            let actual = boundary.sampler(correctedLab)
            func meanDistance(_ edge: Profile) -> Double {
                Double(zip(boundary.reference, edge).map { sqrtf(($0.0 - $1.0) * ($0.0 - $1.0) + ($0.1 - $1.1) * ($0.1 - $1.1) + ($0.2 - $1.2) * ($0.2 - $1.2)) }.reduce(0, +)) / Double(edge.count)
            }
            before[name] = meanDistance(boundary.edge)
            after[name] = meanDistance(actual)
        }
    }
    let report: [String: Any] = [
        "version": expansionCompositorVersion, "space": "OKLab", "source_preserved": inset == 0,
        "source_restore_inset_pixels": inset, "continuous_overlap_correction": inset > 0,
        "strip_pixels": strip, "profile_sigma_pixels": Double(sigma),
        "correction_max_oklab": [Double(maxCorrection.0), Double(maxCorrection.1), Double(maxCorrection.2)],
        "boundary_delta_before": before, "boundary_delta_after": after
    ]
    return BorderColorMatch(image: corrected, report: report)
}

// MARK: - Gaussian blur (three box passes, edge replicated)

private func boxSizes(sigma: Float, passes: Int) -> [Int] {
    // Standard "boxes for Gauss" sizes whose repeated application approximates
    // a Gaussian with the requested standard deviation.
    let n = Float(passes)
    let ideal = sqrtf(12 * sigma * sigma / n + 1)
    var lower = Int(floorf(ideal))
    if lower % 2 == 0 { lower -= 1 }
    let upper = lower + 2
    let m = (12 * sigma * sigma - n * Float(lower * lower) - 4 * n * Float(lower) - 3 * n) / (-4 * Float(lower) - 4)
    let threshold = Int(m.rounded())
    return (0..<passes).map { $0 < threshold ? lower : upper }
}

private func boxBlurLine(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, count: Int, stride: Int, radius: Int) {
    // Running sum with edge replication; O(count) regardless of radius.
    let window = Float(2 * radius + 1)
    var sum: Float = 0
    for k in -radius...radius { sum += input[min(max(k, 0), count - 1) * stride] }
    for i in 0..<count {
        output[i * stride] = sum / window
        let leaving = input[min(max(i - radius, 0), count - 1) * stride]
        let entering = input[min(max(i + radius + 1, 0), count - 1) * stride]
        sum += entering - leaving
    }
}

func gaussianBlur(_ image: FloatRGBImage, sigma: Float) -> FloatRGBImage {
    guard sigma > 0 else { return image }
    let width = image.width, height = image.height
    var current = image.data
    var scratch = [Float](repeating: 0, count: current.count)
    for size in boxSizes(sigma: sigma, passes: 3) {
        let radius = (size - 1) / 2
        guard radius > 0 else { continue }
        current.withUnsafeBufferPointer { c in
            scratch.withUnsafeMutableBufferPointer { s in
                for y in 0..<height { for channel in 0..<3 {
                    let base = y * width * 3 + channel
                    boxBlurLine(c.baseAddress! + base, s.baseAddress! + base, count: width, stride: 3, radius: radius)
                } }
            }
        }
        scratch.withUnsafeBufferPointer { s in
            current.withUnsafeMutableBufferPointer { c in
                for x in 0..<width { for channel in 0..<3 {
                    let base = x * 3 + channel
                    boxBlurLine(s.baseAddress! + base, c.baseAddress! + base, count: height, stride: width * 3, radius: radius)
                } }
            }
        }
    }
    return FloatRGBImage(width: width, height: height, data: current)
}

// MARK: - Multiband seam blend

struct SeamBlend {
    var image: FloatRGBImage
    var report: [String: Any]
}

/// Blend detail narrowly and illumination broadly into the generated border.
///
/// The four Laplacian bands sum back to the original image. They are blended
/// with separate masks, rather than blurring the final photograph. Beyond the
/// inner inset the source is exact; far outside the band the generation is
/// exact. Run at model resolution, before restoring full-resolution source pixels.
func blendOverlap(generated: FloatRGBImage, source: FloatRGBImage, left: Int, top: Int, inset: Int, outerReach: Int = 64) throws -> SeamBlend {
    let w = source.width, h = source.height, ow = generated.width, oh = generated.height
    guard left >= 0, top >= 0, left + w <= ow, top + h <= oh, inset > 0, Float(inset) < Float(min(w, h)) / 2, outerReach > 0 else {
        throw CompositorError(message: "Invalid multiband seam geometry.")
    }
    // Extend source colors into the added canvas only as low-frequency context.
    // High-frequency border detail continues to come from the generated scene.
    let padded = source.padded(toWidth: ow, height: oh, left: left, top: top)
    let radii: [Float] = [2, 8, 24]
    var originals = [padded], candidates = [generated]
    for radius in radii {
        originals.append(gaussianBlur(padded, sigma: radius))
        candidates.append(gaussianBlur(generated, sigma: radius))
    }
    let reaches: [Float] = [0, Float(outerReach) / 8, Float(outerReach) / 3, Float(outerReach)]
    var result = FloatRGBImage(width: ow, height: oh)
    result.data.withUnsafeMutableBufferPointer { out in
        for y in 0..<oh {
            let fy = Float(y)
            let dy = min(fy - Float(top) + 0.5, Float(top + h) - fy - 0.5)
            for x in 0..<ow {
                let fx = Float(x)
                let distance = min(min(fx - Float(left) + 0.5, Float(left + w) - fx - 0.5), dy)
                let i = (y * ow + x) * 3
                var r: Float = 0, g: Float = 0, b: Float = 0
                for band in 0..<4 {
                    let alpha = smoothstep((distance + reaches[band]) / (Float(inset) + reaches[band]))
                    let o = originals[band].data, c = candidates[band].data
                    let oNext = band < 3 ? originals[band + 1].data : nil, cNext = band < 3 ? candidates[band + 1].data : nil
                    let a0 = o[i] - (oNext?[i] ?? 0), a1 = o[i + 1] - (oNext?[i + 1] ?? 0), a2 = o[i + 2] - (oNext?[i + 2] ?? 0)
                    let b0 = c[i] - (cNext?[i] ?? 0), b1 = c[i + 1] - (cNext?[i + 1] ?? 0), b2 = c[i + 2] - (cNext?[i + 2] ?? 0)
                    r += a0 * alpha + b0 * (1 - alpha); g += a1 * alpha + b1 * (1 - alpha); b += a2 * alpha + b2 * (1 - alpha)
                }
                out[i] = min(max(r, 0), 1); out[i + 1] = min(max(g, 0), 1); out[i + 2] = min(max(b, 0), 1)
                // Explicit invariants also avoid any floating-point rounding at the limits.
                if distance <= -Float(outerReach) {
                    out[i] = generated.data[i]; out[i + 1] = generated.data[i + 1]; out[i + 2] = generated.data[i + 2]
                }
            }
        }
    }
    for y in (top + inset)..<(top + h - inset) {
        for x in (left + inset)..<(left + w - inset) {
            let ri = result.index(x, y), si = source.index(x - left, y - top)
            result.data[ri] = source.data[si]; result.data[ri + 1] = source.data[si + 1]; result.data[ri + 2] = source.data[si + 2]
        }
    }
    let report: [String: Any] = ["method": "laplacian-four-band", "inner_model_pixels": inset,
        "outer_lighting_model_pixels": outerReach, "gaussian_radii_model_pixels": radii.map { Int($0) },
        "original_interior_preserved": true, "final_image_blurred": false]
    return SeamBlend(image: result, report: report)
}
