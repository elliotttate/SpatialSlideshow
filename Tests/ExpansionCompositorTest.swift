import Foundation

/// Synthetic checks for the Apple Fast Clean Up seam compositor. No model,
/// photo, or Core Image is involved; images are generated in memory.
@main
enum ExpansionCompositorTest {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message)") }
    }

    /// Deterministic image: a diagonal gradient, optionally with fine checker
    /// detail and noise so texture retention can be measured.
    static func textured(width: Int, height: Int, tint: (Float, Float, Float) = (0, 0, 0), seed: UInt32 = 1, detail: Bool = true) -> FloatRGBImage {
        var image = FloatRGBImage(width: width, height: height)
        var state = seed
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 1664525 &+ 1013904223
                let noise = detail ? Float(state >> 24) / 255 * 0.08 : 0
                let checker: Float = detail ? (((x / 3 + y / 3) % 2 == 0) ? 0.06 : -0.06) : 0
                let base = 0.35 + 0.3 * Float(x + y) / Float(width + height)
                let i = image.index(x, y)
                image.data[i] = min(max(base + checker + noise + tint.0, 0), 1)
                image.data[i + 1] = min(max(base * 0.9 + checker + noise + tint.1, 0), 1)
                image.data[i + 2] = min(max(base * 0.8 + checker + noise + tint.2, 0), 1)
            }
        }
        return image
    }

    /// A canvas whose border is the source's replicated edge plus a tint, with
    /// a regenerated band of `overlap` pixels inside the photograph also tinted.
    static func tintedCanvas(source: FloatRGBImage, left: Int, top: Int, right: Int, bottom: Int,
                             tint: (Float, Float, Float), overlap: Int) -> FloatRGBImage {
        let ow = source.width + left + right, oh = source.height + top + bottom
        var canvas = source.padded(toWidth: ow, height: oh, left: left, top: top)
        for y in 0..<oh {
            for x in 0..<ow {
                let dx = min(x - left, left + source.width - 1 - x), dy = min(y - top, top + source.height - 1 - y)
                guard min(dx, dy) < overlap else { continue }
                let i = canvas.index(x, y)
                canvas.data[i] = min(max(canvas.data[i] + tint.0, 0), 1)
                canvas.data[i + 1] = min(max(canvas.data[i + 1] + tint.1, 0), 1)
                canvas.data[i + 2] = min(max(canvas.data[i + 2] + tint.2, 0), 1)
            }
        }
        return canvas
    }

    static func meanRGB(_ image: FloatRGBImage, x: Range<Int>, y: Range<Int>) -> (Float, Float, Float) {
        var r: Float = 0, g: Float = 0, b: Float = 0, n: Float = 0
        for yy in y { for xx in x { let p = image.pixel(xx, yy); r += p.0; g += p.1; b += p.2; n += 1 } }
        return (r / n, g / n, b / n)
    }

    static func sameInterior(_ a: FloatRGBImage, _ source: FloatRGBImage, left: Int, top: Int, inset: Int) -> Bool {
        for y in inset..<(source.height - inset) {
            for x in inset..<(source.width - inset) where a.pixel(x + left, y + top) != source.pixel(x, y) { return false }
        }
        return true
    }

    static func main() {
        let source = textured(width: 240, height: 180)
        let smooth = textured(width: 240, height: 180, detail: false)
        let left = 48, top = 36, overlap = 12, inset = 16

        // 1. A tinted border is corrected through its outer edges and corners, and
        //    the correction continues across the overlap band without a step.
        do {
            let tint: (Float, Float, Float) = (0.10, -0.03, 0.12)
            let clean = smooth.padded(toWidth: smooth.width + 2 * left, height: smooth.height + 2 * top, left: left, top: top)
            let canvas = tintedCanvas(source: smooth, left: left, top: top, right: left, bottom: top, tint: tint, overlap: overlap)
            let result = try harmonizeBorder(generated: canvas, source: smooth, left: left, top: top, restoreInset: overlap)
            let before = (result.report["boundary_delta_before"] as? [String: Double]) ?? [:]
            let after = (result.report["boundary_delta_after"] as? [String: Double]) ?? [:]
            check(before.count == 4 && before.values.min()! > 0.05, "tinted border is measured on all four sides (\(before))")
            check(after.values.max()! < before.values.min()! * 0.05, "boundary color difference drops by more than 95% (\(after))")
            var worstCorner: Float = 0
            for (x, y) in [(0, 0), (canvas.width - 1, 0), (0, canvas.height - 1), (canvas.width - 1, canvas.height - 1), (0, canvas.height / 2), (canvas.width / 2, 0)] {
                let a = result.image.pixel(x, y), b = clean.pixel(x, y)
                worstCorner = max(worstCorner, abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
            }
            check(worstCorner < 0.02, "outer edges and corners return to the untinted border (worst \(worstCorner))")
            check(sameInterior(result.image, smooth, left: left, top: top, inset: overlap), "source interior beyond the overlap is exact")
            // Row means straddling the left boundary: inside overlap band vs just outside.
            let outside = meanRGB(result.image, x: (left - 4)..<left, y: top..<(top + smooth.height))
            let insideBand = meanRGB(result.image, x: left..<(left + 4), y: top..<(top + smooth.height))
            check(abs(outside.0 - insideBand.0) < 0.02 && abs(outside.2 - insideBand.2) < 0.02,
                  "no color step across the photograph boundary (\(outside) vs \(insideBand))")
            check((result.report["continuous_overlap_correction"] as? Bool) == true, "report marks overlap correction")
        } catch { check(false, "harmonizeBorder threw \(error)") }

        // 2. An already matching border is left unchanged, and generated texture
        //    survives a correction measured on a textured photograph.
        do {
            let canvas = smooth.padded(toWidth: smooth.width + 2 * left, height: smooth.height + 2 * top, left: left, top: top)
            let result = try harmonizeBorder(generated: canvas, source: smooth, left: left, top: top, restoreInset: 0)
            var worst: Float = 0
            for i in 0..<canvas.data.count { worst = max(worst, abs(canvas.data[i] - result.image.data[i])) }
            check(worst < 0.004, "matching border changes by at most rounding (\(worst))")
            check((result.report["source_preserved"] as? Bool) == true, "report marks source preserved without overlap")
            let tinted = tintedCanvas(source: source, left: left, top: top, right: left, bottom: top, tint: (0.08, 0, 0.08), overlap: 0)
            let corrected = try harmonizeBorder(generated: tinted, source: source, left: left, top: top, restoreInset: 0)
            func verticalDetail(_ image: FloatRGBImage) -> Float {
                var sum: Float = 0
                for y in top..<(top + source.height - 1) { sum += abs(image.pixel(20, y).0 - image.pixel(20, y + 1).0) }
                return sum / Float(source.height - 1)
            }
            check(verticalDetail(corrected.image) > verticalDetail(tinted) * 0.8, "border texture is retained while the tint is removed")
        } catch { check(false, "harmonizeBorder (matching) threw \(error)") }

        // 3. Multiband blend: exact interior, exact far exterior, smooth lighting
        //    transition and retained fine border texture.
        do {
            let lighter = textured(width: 240, height: 180, tint: (0.18, 0.18, 0.18), seed: 9)
            let canvas = lighter.padded(toWidth: source.width + 2 * left, height: source.height + 2 * top, left: left, top: top)
            let blend = try blendOverlap(generated: canvas, source: source, left: left, top: top, inset: inset, outerReach: 32)
            check(sameInterior(blend.image, source, left: left, top: top, inset: inset), "blend keeps the interior beyond the inset exact")
            var exteriorExact = true
            for y in 0..<2 { for x in 0..<canvas.width where blend.image.pixel(x, y) != canvas.pixel(x, y) { exteriorExact = false } }
            check(exteriorExact, "pixels beyond the outer reach are the untouched generation")
            // Column means across the left boundary should not jump between neighbors.
            var columnMeans: [Float] = []
            for x in (left - 32)..<(left + inset + 4) {
                columnMeans.append(meanRGB(blend.image, x: x..<(x + 1), y: (top + 20)..<(top + source.height - 20)).0)
            }
            var worstStep: Float = 0
            for i in 1..<columnMeans.count { worstStep = max(worstStep, abs(columnMeans[i] - columnMeans[i - 1])) }
            let rawStep = abs(meanRGB(canvas, x: (left - 1)..<left, y: top..<(top + source.height)).0
                              - meanRGB(source, x: 0..<1, y: 0..<source.height).0)
            check(worstStep < rawStep * 0.25, "largest neighboring column step \(worstStep) is well below the raw step \(rawStep)")
            // Fine checker texture must survive near the outer edge of the band.
            var texture: Float = 0
            for y in (top + 20)..<(top + source.height - 20) {
                texture += abs(blend.image.pixel(left - 20, y).0 - blend.image.pixel(left - 20, y + 1).0)
            }
            texture /= Float(source.height - 40)
            check(texture > 0.02, "generated fine texture retained in the border (\(texture))")
            check((blend.report["final_image_blurred"] as? Bool) == false, "report states the final image is not blurred")
        } catch { check(false, "blendOverlap threw \(error)") }

        // 4. Gaussian blur preserves a flat field and smooths an impulse symmetrically.
        do {
            var flat = FloatRGBImage(width: 40, height: 30, fill: (0.3, 0.5, 0.7))
            let blurredFlat = gaussianBlur(flat, sigma: 8)
            var worst: Float = 0
            for i in 0..<flat.data.count { worst = max(worst, abs(flat.data[i] - blurredFlat.data[i])) }
            check(worst < 1e-5, "blur of a flat image is flat (\(worst))")
            flat = FloatRGBImage(width: 41, height: 41)
            flat.data[flat.index(20, 20)] = 1
            let impulse = gaussianBlur(flat, sigma: 3)
            check(impulse.pixel(20, 20).0 > impulse.pixel(23, 20).0 && impulse.pixel(23, 20).0 > impulse.pixel(26, 20).0,
                  "blurred impulse decays with distance")
            check(abs(impulse.pixel(17, 20).0 - impulse.pixel(23, 20).0) < 1e-6 && abs(impulse.pixel(20, 17).0 - impulse.pixel(20, 23).0) < 1e-6,
                  "blurred impulse is symmetric")
        }

        // 5. Geometry that would leave no protected interior is rejected.
        do {
            let canvas = source.padded(toWidth: source.width + 2 * left, height: source.height + 2 * top, left: left, top: top)
            var rejected = 0
            for (l, t, i) in [(left, top, 90), (-1, top, 4), (left, top + 100, 4)] {
                if (try? blendOverlap(generated: canvas, source: source, left: l, top: t, inset: i)) == nil { rejected += 1 }
                if (try? harmonizeBorder(generated: canvas, source: source, left: l, top: t, restoreInset: i)) == nil { rejected += 1 }
            }
            check(rejected == 6, "invalid geometry rejected by both stages (\(rejected) of 6)")
        }

        // 6. One-sided padding and tiny images do not crash and keep the source.
        do {
            let tiny = textured(width: 9, height: 7, seed: 3)
            let canvas = tiny.padded(toWidth: 15, height: 7, left: 6, top: 0)
            let result = try harmonizeBorder(generated: canvas, source: tiny, left: 6, top: 0, restoreInset: 0)
            check(sameInterior(result.image, tiny, left: 6, top: 0, inset: 0) && result.image.width == 15, "one-sided tiny canvas handled")
        } catch { check(false, "tiny harmonizeBorder threw \(error)") }

        if failures == 0 { print("PASS expansion compositor") } else { print("\(failures) FAILURE(S)"); exit(1) }
    }
}
