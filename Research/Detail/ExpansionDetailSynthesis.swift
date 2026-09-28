import Foundation

/// Restores full-resolution detail to a generated expansion border.
///
/// Local models generate the border near 768 pixels, so the upscaled result is
/// much softer and cleaner than the photograph beside it. The generation keeps
/// its structure and color; only the missing high-frequency layer (photograph
/// minus the photograph degraded exactly like the border) is copied from real
/// photograph locations. Guided PatchMatch with EM voting, coarse to fine, picks
/// those locations by matching the degraded structure, in the spirit of
/// Photoshop's deep-inpainting-guided Content-Aware Fill; patches touching the
/// photograph must also continue its detail. Photograph pixels are never written.
///
/// Job JSON: canvas_size [W, H], box [x, y, w, h] of known photograph pixels,
/// guide (W×H raw RGB8 upscaled generation), original and degraded (w×h raw
/// RGB8: the photograph and its degraded copy), output (W×H raw RGB8), optional
/// settings. Deterministic: work uses fixed bands with per-band random streams.
enum ExpansionDetailSynthesis {
    struct Settings {
        var patchRadius = 3
        var coarsestLongEdge = 800
        var coarseIterations = 4
        var middleIterations = 1
        var fineIterations = 0
        var coarseSweeps = 2
        var fineSweeps = 1
        var coarseGuideWeight = 4.0
        var fineGuideWeight = 1.5
        var seamRampPixels = 32.0
        var localSearchRadius = 8
        var seed: UInt64 = 8612

        init(_ json: [String: Any]) throws {
            func int(_ key: String, _ value: inout Int, _ range: ClosedRange<Int>) throws {
                guard let raw = json[key] else { return }
                guard let number = raw as? NSNumber, let parsed = Int(exactly: number.doubleValue), range.contains(parsed) else {
                    throw failure("Invalid detail synthesis setting \(key).")
                }
                value = parsed
            }
            func double(_ key: String, _ value: inout Double, _ range: ClosedRange<Double>) throws {
                guard let raw = json[key] else { return }
                guard let number = raw as? NSNumber, range.contains(number.doubleValue) else {
                    throw failure("Invalid detail synthesis setting \(key).")
                }
                value = number.doubleValue
            }
            try int("patch_radius", &patchRadius, 1...6)
            try int("coarsest_long_edge", &coarsestLongEdge, 64...4096)
            try int("coarse_iterations", &coarseIterations, 1...20)
            try int("middle_iterations", &middleIterations, 0...20)
            try int("fine_iterations", &fineIterations, 0...20)
            try int("coarse_sweeps", &coarseSweeps, 1...8)
            try int("fine_sweeps", &fineSweeps, 1...8)
            try int("local_search_radius", &localSearchRadius, 1...256)
            // Guide weights above 4 could overflow the 32-bit patch costs.
            try double("coarse_guide_weight", &coarseGuideWeight, 0...4)
            try double("fine_guide_weight", &fineGuideWeight, 0...4)
            try double("seam_ramp_pixels", &seamRampPixels, 1...4096)
            var seedValue = Int(seed)
            try int("seed", &seedValue, 0...Int(Int32.max))
            seed = UInt64(seedValue)
        }
    }

    static func run(jobPath: String) throws {
        let started = Date()
        guard let job = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: jobPath))) as? [String: Any],
              let canvas = job["canvas_size"] as? [Int], canvas.count == 2,
              let boxValues = job["box"] as? [Int], boxValues.count == 4,
              let guidePath = job["guide"] as? String, let originalPath = job["original"] as? String,
              let degradedPath = job["degraded"] as? String, let outputPath = job["output"] as? String else {
            throw failure("The detail synthesis job is incomplete.")
        }
        let settings = try Settings(job["settings"] as? [String: Any] ?? [:])
        let width = canvas[0], height = canvas[1]
        let box = Box(x0: boxValues[0], y0: boxValues[1], x1: boxValues[0] + boxValues[2], y1: boxValues[1] + boxValues[3])
        let minimum = 2 * settings.patchRadius + 2
        guard width > 0, height > 0, width <= 50_000, height <= 50_000, width * height <= 400_000_000,
              box.x0 >= 0, box.y0 >= 0, box.x1 <= width, box.y1 <= height,
              box.width >= minimum, box.height >= minimum else {
            throw failure("The detail synthesis geometry is invalid.")
        }
        guard !FileManager.default.fileExists(atPath: outputPath) else {
            throw failure("The detail synthesis output already exists.")
        }
        let guide = [UInt8](try Data(contentsOf: URL(fileURLWithPath: guidePath)))
        let original = [UInt8](try Data(contentsOf: URL(fileURLWithPath: originalPath)))
        let degraded = [UInt8](try Data(contentsOf: URL(fileURLWithPath: degradedPath)))
        guard guide.count == width * height * 3, original.count == box.width * box.height * 3,
              degraded.count == original.count else {
            throw failure("The detail synthesis images do not match the job dimensions.")
        }
        // Structure: the generation outside, the degraded photograph inside, so
        // both sides of every comparison have the same resolution. Detail: the
        // photograph's missing high frequencies, offset by 128; unknown starts flat.
        var structure = guide
        var detail = [UInt8](repeating: 128, count: guide.count)
        for y in 0..<box.height {
            for x in 0..<box.width {
                let o = ((box.y0 + y) * width + box.x0 + x) * 3, i = (y * box.width + x) * 3
                for c in 0..<3 {
                    structure[o + c] = degraded[i + c]
                    detail[o + c] = UInt8(clamping: Int(original[i + c]) - Int(degraded[i + c]) + 128)
                }
            }
        }
        let (synthesized, levels) = Synthesizer(settings: settings).synthesize(image: detail, guide: structure,
                                                                               width: width, height: height, box: box)
        var result = guide
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 3
                if x >= box.x0 && x < box.x1 && y >= box.y0 && y < box.y1 {
                    let i = ((y - box.y0) * box.width + x - box.x0) * 3
                    result[o] = original[i]; result[o + 1] = original[i + 1]; result[o + 2] = original[i + 2]
                } else {
                    for c in 0..<3 { result[o + c] = UInt8(clamping: Int(guide[o + c]) + Int(synthesized[o + c]) - 128) }
                }
            }
        }
        try Data(result).write(to: URL(fileURLWithPath: outputPath), options: .withoutOverwriting)
        let report: [String: Any] = ["method": "guided-detail-transfer", "levels": levels,
                                     "seconds": Date().timeIntervalSince(started)]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data([10]))
    }

    fileprivate static func failure(_ message: String) -> NSError {
        NSError(domain: "PhotoExpansion", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Half-open rectangle holding known photograph pixels.
private struct Box {
    let x0: Int, y0: Int, x1: Int, y1: Int
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
    /// The next pyramid level keeps only pixels averaged entirely from the photograph.
    var halved: Box { Box(x0: (x0 + 1) / 2, y0: (y0 + 1) / 2, x1: x1 / 2, y1: y1 / 2) }
}

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func offset(_ radius: Int) -> Int { Int(next() % UInt64(2 * radius + 1)) - radius }
}

/// Pointers for one pyramid level. Costs are weighted sums of squared RGB
/// differences in 1/16 units: photograph appearance plus the guide term.
private struct Level {
    let width: Int, height: Int, radius: Int
    let box: Box
    let image: UnsafeMutablePointer<UInt8>
    let guide: UnsafePointer<UInt8>
    let nnf: UnsafeMutablePointer<Int32>
    let cost: UnsafeMutablePointer<Int32>
    let guideWeight: Double
    let rampPixels: Double

    /// Patch centers whose window contains at least one pixel to synthesize.
    @inline(__always) func inDomain(_ x: Int, _ y: Int) -> Bool {
        x < box.x0 + radius || x >= box.x1 - radius || y < box.y0 + radius || y >= box.y1 - radius
    }
    @inline(__always) func isKnown(_ x: Int, _ y: Int) -> Bool {
        x >= box.x0 && x < box.x1 && y >= box.y0 && y < box.y1
    }
    /// Source patches must lie entirely inside the photograph.
    @inline(__always) func source(_ x: Int, _ y: Int) -> Int32 {
        let sx = min(max(x, box.x0 + radius), box.x1 - radius - 1)
        let sy = min(max(y, box.y0 + radius), box.y1 - radius - 1)
        return Int32(sy * width + sx)
    }
    /// Next to the seam, agreement with the photograph dominates the guide.
    @inline(__always) func guideUnits(_ x: Int, _ y: Int) -> Int {
        let distance = Double(max(box.x0 - x, x - box.x1 + 1, box.y0 - y, y - box.y1 + 1, 0))
        let t = min(distance / rampPixels, 1)
        return Int((guideWeight * t * t * (3 - 2 * t) * 16).rounded())
    }

    func distance(_ px: Int, _ py: Int, _ q: Int32, guideUnits alpha: Int, limit: Int) -> Int {
        let r = radius, side = 2 * r + 1, q = Int(q)
        if px >= r && py >= r && px < width - r && py < height - r {
            var sum = 0
            for dy in -r...r {
                var ip = ((py + dy) * width + px - r) * 3
                var iq = (q + dy * width - r) * 3
                for _ in 0..<side {
                    let a0 = Int(image[ip]) &- Int(image[iq]), a1 = Int(image[ip + 1]) &- Int(image[iq + 1])
                    let a2 = Int(image[ip + 2]) &- Int(image[iq + 2])
                    let g0 = Int(guide[ip]) &- Int(guide[iq]), g1 = Int(guide[ip + 1]) &- Int(guide[iq + 1])
                    let g2 = Int(guide[ip + 2]) &- Int(guide[iq + 2])
                    sum = sum &+ 16 &* (a0 &* a0 &+ a1 &* a1 &+ a2 &* a2) &+ alpha &* (g0 &* g0 &+ g1 &* g1 &+ g2 &* g2)
                    ip &+= 3
                    iq &+= 3
                }
                if sum >= limit { return sum }
            }
            return sum
        }
        // Canvas edges: normalize the partial window to a full patch.
        var sum = 0, count = 0
        for dy in -r...r where py + dy >= 0 && py + dy < height {
            for dx in -r...r where px + dx >= 0 && px + dx < width {
                let ip = ((py + dy) * width + px + dx) * 3, iq = (q + dy * width + dx) * 3
                for c in 0..<3 {
                    let a = Int(image[ip + c]) - Int(image[iq + c]), g = Int(guide[ip + c]) - Int(guide[iq + c])
                    sum += 16 * a * a + alpha * g * g
                }
                count += 1
            }
        }
        return sum * side * side / max(count, 1)
    }

    func computeCosts() {
        DispatchQueue.concurrentPerform(iterations: height) { y in
            for x in 0..<width where inDomain(x, y) {
                let p = y * width + x
                cost[p] = Int32(clamping: distance(x, y, nnf[p], guideUnits: guideUnits(x, y), limit: Int.max))
            }
        }
    }

    /// One PatchMatch pass. Bands are processed in parallel and only read their
    /// own rows of the nearest-neighbor field, so results never depend on timing.
    func sweep(forward: Bool, bandOffset: Int, bandHeight: Int, searchRadius: Int, seed: UInt64) {
        var starts = [0]
        var boundary = bandOffset > 0 ? bandOffset : bandHeight
        while boundary < height { starts.append(boundary); boundary += bandHeight }
        starts.append(height)
        let step = forward ? 1 : -1
        starts.withUnsafeBufferPointer { bands in
            DispatchQueue.concurrentPerform(iterations: bands.count - 1) { band in
                var random = SplitMix64(state: seed &+ UInt64(band) &* 0xD1B5_4A32_D192_ED03)
                let first = bands[band], last = bands[band + 1]
                var y = forward ? first : last - 1
                while y >= first && y < last {
                    var x = forward ? 0 : width - 1
                    while x >= 0 && x < width {
                        if inDomain(x, y) {
                            improve(x, y, step: step, bandRows: first..<last, searchRadius: searchRadius, random: &random)
                        }
                        x += step
                    }
                    y += step
                }
            }
        }
    }

    @inline(__always) private func improve(_ x: Int, _ y: Int, step: Int, bandRows: Range<Int>, searchRadius: Int,
                                           random: inout SplitMix64) {
        let p = y * width + x
        let alpha = guideUnits(x, y)
        var best = nnf[p], bestCost = Int(cost[p])
        // Propagate the neighbors' matches, shifted to this pixel.
        if x - step >= 0 && x - step < width && inDomain(x - step, y) {
            let q = Int(nnf[p - step])
            let candidate = source(q % width + step, q / width)
            if candidate != best {
                let d = distance(x, y, candidate, guideUnits: alpha, limit: bestCost)
                if d < bestCost { best = candidate; bestCost = d }
            }
        }
        if bandRows.contains(y - step) && inDomain(x, y - step) {
            let q = Int(nnf[p - step * width])
            let candidate = source(q % width, q / width + step)
            if candidate != best {
                let d = distance(x, y, candidate, guideUnits: alpha, limit: bestCost)
                if d < bestCost { best = candidate; bestCost = d }
            }
        }
        var radius = searchRadius
        while radius >= 1 {
            let bx = Int(best) % width, by = Int(best) / width
            let candidate = source(bx + random.offset(radius), by + random.offset(radius))
            if candidate != best {
                let d = distance(x, y, candidate, guideUnits: alpha, limit: bestCost)
                if d < bestCost { best = candidate; bestCost = d }
            }
            radius /= 2
        }
        nnf[p] = best
        cost[p] = Int32(clamping: bestCost)
    }

    /// Replace every unknown pixel by the average of the photograph pixels that
    /// all overlapping patches assign to it.
    func vote(into output: UnsafeMutablePointer<UInt8>) {
        let r = radius
        DispatchQueue.concurrentPerform(iterations: height) { y in
            for x in 0..<width {
                let o = (y * width + x) * 3
                if isKnown(x, y) {
                    output[o] = image[o]; output[o + 1] = image[o + 1]; output[o + 2] = image[o + 2]
                    continue
                }
                var red = 0, green = 0, blue = 0, count = 0
                for dy in -r...r where y + dy >= 0 && y + dy < height {
                    for dx in -r...r where x + dx >= 0 && x + dx < width {
                        // Centered at (x+dx, y+dy); this pixel sits at offset (-dx, -dy) in its source patch.
                        let s = (Int(nnf[(y + dy) * width + x + dx]) - dy * width - dx) * 3
                        red += Int(image[s]); green += Int(image[s + 1]); blue += Int(image[s + 2])
                        count += 1
                    }
                }
                let half = count / 2
                output[o] = UInt8((red + half) / count)
                output[o + 1] = UInt8((green + half) / count)
                output[o + 2] = UInt8((blue + half) / count)
            }
        }
    }
}

private struct Synthesizer {
    let settings: ExpansionDetailSynthesis.Settings

    private static func halve(_ pixels: [UInt8], _ width: Int, _ height: Int) -> [UInt8] {
        let w = (width + 1) / 2, h = (height + 1) / 2
        var result = [UInt8](repeating: 0, count: w * h * 3)
        pixels.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { destination in
                let s = source.baseAddress!, d = destination.baseAddress!
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let y0 = 2 * y, y1 = min(2 * y + 1, height - 1)
                    for x in 0..<w {
                        let x0 = 2 * x, x1 = min(2 * x + 1, width - 1)
                        for c in 0..<3 {
                            let sum = Int(s[(y0 * width + x0) * 3 + c]) + Int(s[(y0 * width + x1) * 3 + c])
                                + Int(s[(y1 * width + x0) * 3 + c]) + Int(s[(y1 * width + x1) * 3 + c])
                            d[(y * w + x) * 3 + c] = UInt8((sum + 2) / 4)
                        }
                    }
                }
            }
        }
        return result
    }

    func synthesize(image: [UInt8], guide: [UInt8], width: Int, height: Int, box: Box) -> ([UInt8], [[String: Any]]) {
        let r = settings.patchRadius
        // Pyramid, finest first. The coarsest level approximates the model's own
        // resolution, where the guide is sharp enough to decide the layout.
        var images = [image], guides = [guide], sizes = [(width, height)], boxes = [box]
        while max(sizes.last!.0, sizes.last!.1) > settings.coarsestLongEdge {
            let next = boxes.last!.halved
            guard next.width >= 2 * r + 2, next.height >= 2 * r + 2 else { break }
            let (w, h) = sizes.last!
            images.append(Self.halve(images.last!, w, h))
            guides.append(Self.halve(guides.last!, w, h))
            sizes.append(((w + 1) / 2, (h + 1) / 2))
            boxes.append(next)
        }
        let coarsest = sizes.count - 1
        var previousField: [Int32] = [], previousSize = (0, 0), previousBox = box
        var reports: [[String: Any]] = []
        for level in stride(from: coarsest, through: 0, by: -1) {
            let started = Date()
            let (w, h) = sizes[level]
            let fraction = coarsest == 0 ? 0 : Double(level) / Double(coarsest)
            let weight = settings.fineGuideWeight + (settings.coarseGuideWeight - settings.fineGuideWeight) * fraction
            var field = [Int32](repeating: 0, count: w * h), costs = [Int32](repeating: 0, count: w * h)
            var scratch = [UInt8](repeating: 0, count: w * h * 3)
            let iterations = level == coarsest ? settings.coarseIterations : (level == 0 ? settings.fineIterations : settings.middleIterations)
            let sweeps = level == coarsest ? settings.coarseSweeps : settings.fineSweeps
            let searchRadius = level == coarsest ? max(w, h) : settings.localSearchRadius
            images[level].withUnsafeMutableBufferPointer { imageBuffer in
                guides[level].withUnsafeBufferPointer { guideBuffer in
                    field.withUnsafeMutableBufferPointer { fieldBuffer in
                        costs.withUnsafeMutableBufferPointer { costBuffer in
                            scratch.withUnsafeMutableBufferPointer { scratchBuffer in
                                let current = Level(width: w, height: h, radius: r, box: boxes[level],
                                                    image: imageBuffer.baseAddress!, guide: guideBuffer.baseAddress!,
                                                    nnf: fieldBuffer.baseAddress!, cost: costBuffer.baseAddress!,
                                                    guideWeight: weight,
                                                    rampPixels: max(1, settings.seamRampPixels / pow(2, Double(level))))
                                if level == coarsest {
                                    // Unknown detail starts flat; begin at the nearest photograph patch.
                                    DispatchQueue.concurrentPerform(iterations: h) { y in
                                        for x in 0..<w where current.inDomain(x, y) { current.nnf[y * w + x] = current.source(x, y) }
                                    }
                                } else {
                                    let (cw, ch) = previousSize, coarseBox = previousBox
                                    previousField.withUnsafeBufferPointer { coarseField in
                                        DispatchQueue.concurrentPerform(iterations: h) { y in
                                            for x in 0..<w where current.inDomain(x, y) {
                                                let cx = min(x / 2, cw - 1), cy = min(y / 2, ch - 1)
                                                var qx = cx, qy = cy
                                                let inside = cx >= coarseBox.x0 + r && cx < coarseBox.x1 - r
                                                    && cy >= coarseBox.y0 + r && cy < coarseBox.y1 - r
                                                if !inside {
                                                    let q = Int(coarseField[cy * cw + cx])
                                                    qx = q % cw; qy = q / cw
                                                }
                                                current.nnf[y * w + x] = current.source(2 * qx + x - 2 * cx, 2 * qy + y - 2 * cy)
                                            }
                                        }
                                    }
                                    current.vote(into: scratchBuffer.baseAddress!)
                                    imageBuffer.baseAddress!.update(from: scratchBuffer.baseAddress!, count: w * h * 3)
                                }
                                let bandHeight = max(8, h / (4 * ProcessInfo.processInfo.activeProcessorCount))
                                for iteration in 0..<iterations {
                                    current.computeCosts()
                                    for sweep in 0..<sweeps {
                                        let pass = iteration * sweeps + sweep
                                        let seed = settings.seed ^ (UInt64(level) << 48) ^ (UInt64(iteration) << 32) ^ (UInt64(sweep) << 16)
                                        current.sweep(forward: pass % 2 == 0, bandOffset: (pass % 2) * (bandHeight / 2),
                                                      bandHeight: bandHeight, searchRadius: searchRadius, seed: seed)
                                    }
                                    current.vote(into: scratchBuffer.baseAddress!)
                                    imageBuffer.baseAddress!.update(from: scratchBuffer.baseAddress!, count: w * h * 3)
                                }
                            }
                        }
                    }
                }
            }
            previousField = field
            previousSize = (w, h)
            previousBox = boxes[level]
            reports.append(["size": [w, h], "iterations": iterations, "guide_weight": weight,
                            "seconds": Date().timeIntervalSince(started)])
            if level > 0 { images[level] = []; guides[level] = [] }
        }
        return (images[0], reports)
    }
}
