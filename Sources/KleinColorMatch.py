"""Match locally generated border colors to a source photo without changing it.

FLUX can apply a different white balance/grade to the generated area. Measure
that drift on each side in perceptual OKLab, smooth it along the boundary, and
carry a shared white-balance correction all the way to the outside edge.
Local seam refinements fade into that baseline so differences in new scenery
do not become stripes. Generated texture and luminance detail are retained.
"""
from __future__ import annotations

import numpy as np
from PIL import Image

VERSION = 2


def _to_oklab(rgb):
    rgb = np.asarray(rgb, dtype=np.float32) / 255.0
    linear = np.where(rgb <= .04045, rgb / 12.92, ((rgb + .055) / 1.055) ** 2.4)
    lms = linear @ np.array([[.4122214708, .2119034982, .0883024619],
                             [.5363325363, .6806995451, .2817188376],
                             [.0514459929, .1073969566, .6299787005]], np.float32)
    return np.cbrt(lms) @ np.array([[.2104542553, 1.9779984951, .0259040371],
                                   [.7936177850, -2.4285922050, .7827717662],
                                   [-.0040720468, .4505937099, -.8086757660]], np.float32)


def _from_oklab(lab):
    lms = lab @ np.array([[1, 1, 1], [.3963377774, -.1055613458, -.0894841775],
                          [.2158037573, -.0638541728, -1.2914855480]], np.float32)
    linear = lms ** 3 @ np.array([[4.0767416621, -1.2684380046, -.0041960863],
                                 [-3.3077115913, 2.6097574011, -.7034186147],
                                 [.2309699292, -.3413193965, 1.7076147010]], np.float32)
    # Clip before the fractional power, including when np.where evaluates both
    # branches. Clipping occurs only when the adjusted color leaves sRGB gamut.
    rgb = np.where(linear <= .0031308, linear * 12.92,
                   1.055 * np.maximum(linear, 0) ** (1 / 2.4) - .055)
    return np.rint(np.clip(rgb, 0, 1) * 255).astype(np.uint8)


def _smooth_profile(line, sigma):
    radius = max(1, int(np.ceil(3 * sigma)))
    locations = np.arange(-radius, radius + 1, dtype=np.float32)
    kernel = np.exp(-locations ** 2 / (2 * sigma ** 2))
    kernel /= kernel.sum()
    padded = np.pad(line, ((radius, radius), (0, 0)), mode="edge")
    output = np.zeros_like(line)
    for offset, weight in enumerate(kernel):
        output += padded[offset:offset + len(line)] * weight
    return output


def harmonize_border(generated, source, left, top, *, restore_inset=0):
    """Match the border and its optional overlap, then restore the source interior.

    Both images must already be color-managed sRGB and supplied at MODEL size.
    `left` and `top` locate the unscaled source in the generated canvas. No model
    imports, filesystem operations, or inference occur here.
    """
    if int(left) != left or int(top) != top:
        raise ValueError("The source offset must be an integer pixel coordinate.")
    left, top = int(left), int(top)
    source = source.convert("RGB")
    generated = generated.convert("RGB")
    width, height = source.size
    canvas_width, canvas_height = generated.size
    right, bottom = left + width, top + height
    if min(width, height) < 1 or left < 0 or top < 0 or right > canvas_width or bottom > canvas_height:
        raise ValueError("The source rectangle must fit inside the generated canvas.")
    if type(restore_inset) is not int or not 0 <= restore_inset < min(width, height) / 2:
        raise ValueError("The generated overlap must leave a protected source interior.")

    pixels = np.asarray(generated)
    original = np.asarray(source)
    canvas_lab = _to_oklab(pixels)
    source_lab = _to_oklab(original)
    field = np.zeros_like(canvas_lab)
    # A narrow strip avoids sampling unrelated scenery. Spatial smoothing removes
    # texture from the correction, so generated detail remains intact.
    strip = max(1, min(8, round(min(width, height) * .025)))
    sigma = max(1.5, min(width, height) * .025)
    profiles = {}
    boundaries = {}

    def profile(name, inside, outside, axis):
        reference = np.median(inside, axis=axis)
        generated_edge = np.median(outside, axis=axis)
        delta = _smooth_profile(reference - generated_edge, sigma)
        # Lighting differences often come from new scenery (for example a tree
        # against fog), rather than a grade. Smooth luminance more broadly and
        # limit its adjustment so those differences do not become bright bands.
        delta[:, 0] = _smooth_profile((reference - generated_edge)[:, :1], sigma * 3)[:, 0]
        # Avoid extreme offsets caused by unrelated content or pathological
        # model output, without the old 48/255 RGB cap that left purple borders.
        delta[:, 0] = np.clip(delta[:, 0], -.12, .12)
        delta[:, 1:] = np.clip(delta[:, 1:], -.25, .25)
        profiles[name] = delta
        boundaries[name] = (reference, generated_edge, outside.shape, axis)
        return delta

    if left:
        count = min(strip, left, width)
        delta = profile("left", source_lab[:, :count], canvas_lab[top:bottom, left-count:left], 1)
        field[top:bottom, :left] = delta[:, None]
    if right < canvas_width:
        count = min(strip, canvas_width-right, width)
        delta = profile("right", source_lab[:, -count:], canvas_lab[top:bottom, right:right+count], 1)
        field[top:bottom, right:] = delta[:, None]
    if top:
        count = min(strip, top, height)
        delta = profile("top", source_lab[:count], canvas_lab[top-count:top, left:right], 0)
        field[:top, left:right] = delta[None]
    if bottom < canvas_height:
        count = min(strip, canvas_height-bottom, height)
        delta = profile("bottom", source_lab[-count:], canvas_lab[bottom:bottom+count, left:right], 0)
        field[bottom:, left:right] = delta[None]

    def corner(xslice, yslice, horizontal, vertical, x_reverse, y_reverse):
        corner_width = xslice.stop - xslice.start
        corner_height = yslice.stop - yslice.start
        if not corner_width or not corner_height:
            return
        dx = np.arange(1, corner_width + 1, dtype=np.float32)
        dy = np.arange(1, corner_height + 1, dtype=np.float32)
        if x_reverse:
            dx = dx[::-1]
        if y_reverse:
            dy = dy[::-1]
        # Continue each side continuously into its corners. Corrections stay
        # active at the outermost pixels; no purple halo is left by distance decay.
        weight = dx[None, :] / (dx[None, :] + dy[:, None])
        field[yslice, xslice] = horizontal[None, None] * weight[..., None] + vertical[None, None] * (1-weight[..., None])

    if left and top:
        corner(slice(0, left), slice(0, top), profiles["left"][0], profiles["top"][0], True, True)
    if right < canvas_width and top:
        corner(slice(right, canvas_width), slice(0, top), profiles["right"][0], profiles["top"][-1], False, True)
    if left and bottom < canvas_height:
        corner(slice(0, left), slice(bottom, canvas_height), profiles["left"][-1], profiles["bottom"][0], True, False)
    if right < canvas_width and bottom < canvas_height:
        corner(slice(right, canvas_width), slice(bottom, canvas_height), profiles["right"][-1], profiles["bottom"][-1], False, False)

    # Keep a shared white-balance correction across the whole border, but do
    # not project each local tree/sky lighting mismatch to the outer canvas.
    if profiles:
        global_delta = np.median(np.stack([np.median(p, axis=0) for p in profiles.values()]), axis=0)
        yy, xx = np.indices((canvas_height, canvas_width), dtype=np.float32)
        dx = np.maximum(np.maximum(left - xx - .5, xx - right + .5), 0)
        dy = np.maximum(np.maximum(top - yy - .5, yy - bottom + .5), 0)
        x_reach = max(8, max(left, canvas_width-right) * .32)
        y_reach = max(8, max(top, canvas_height-bottom) * .32)
        influence = np.exp(-np.sqrt((dx/x_reach)**2 + (dy/y_reach)**2))[..., None]
        field = global_delta + (field-global_delta) * influence
        field[top:bottom, left:right] = 0

    if restore_inset and profiles:
        # Carry the SAME color correction across the photograph boundary.
        # Correcting only the outside, then pasting raw generated overlap inside,
        # creates a color step that no subsequent inner feather can remove.
        xx = np.arange(width, dtype=np.float32)[None, :] + .5
        yy = np.arange(height, dtype=np.float32)[:, None] + .5
        weighted = np.zeros((height, width, 3), np.float32)
        total = np.zeros((height, width), np.float32)
        opacity = np.zeros((height, width), np.float32)
        edges = []
        if left:
            edges.append((xx, field[top:bottom, left-1][:, None]))
        if right < canvas_width:
            edges.append((width-xx, field[top:bottom, right][:, None]))
        if top:
            edges.append((yy, field[top-1, left:right][None]))
        if bottom < canvas_height:
            edges.append((height-yy, field[bottom, left:right][None]))
        for distance, delta in edges:
            t = np.clip(distance / restore_inset, 0, 1)
            fade = 1 - t*t*(3-2*t)
            weight = fade / (distance*distance)
            weighted += delta * weight[..., None]
            total += weight
            opacity = np.maximum(opacity, fade)
        field[top:bottom, left:right] = weighted / np.maximum(total[..., None], 1e-12) * opacity[..., None]

    corrected = _from_oklab(canvas_lab + field)
    inset = restore_inset
    corrected[top+inset:bottom-inset, left+inset:right-inset] = original[inset:height-inset, inset:width-inset]
    report = {"version": VERSION, "space": "OKLab", "source_preserved": inset == 0,
              "source_restore_inset_pixels": inset, "continuous_overlap_correction": inset > 0,
              "strip_pixels": strip, "profile_sigma_pixels": sigma,
              "correction_max_oklab": np.max(np.abs(field), axis=(0, 1)).astype(float).tolist(),
              "boundary_delta_before": {}, "boundary_delta_after": {}}
    corrected_lab = _to_oklab(corrected)
    for name, (reference, edge, shape, axis) in boundaries.items():
        if name == "left":
            sampled = corrected_lab[top:bottom, left-shape[1]:left]
        elif name == "right":
            sampled = corrected_lab[top:bottom, right:right+shape[1]]
        elif name == "top":
            sampled = corrected_lab[top-shape[0]:top, left:right]
        else:
            sampled = corrected_lab[bottom:bottom+shape[0], left:right]
        actual_edge = np.median(sampled, axis=axis)
        report["boundary_delta_before"][name] = float(np.mean(np.linalg.norm(reference-edge, axis=1)))
        report["boundary_delta_after"][name] = float(np.mean(np.linalg.norm(reference-actual_edge, axis=1)))
    return Image.fromarray(corrected), report


def blend_overlap(generated, source, left, top, inset, outer_reach=64):
    """Blend detail narrowly and illumination broadly into the generated border.

    The four Laplacian bands sum back to the original image. They are blended
    with separate masks, rather than blurring the final photograph. Beyond the
    inner inset the source is exact; far outside the band the generation is exact.
    Run at model resolution, before restoring full-resolution source pixels.
    """
    from PIL import ImageFilter
    source = source.convert("RGB")
    generated = generated.convert("RGB")
    w, h = source.size
    ow, oh = generated.size
    if any(type(value) is not int for value in (left, top, inset, outer_reach)) or \
            left < 0 or top < 0 or left+w > ow or top+h > oh or not 0 < inset < min(w, h)/2 or outer_reach <= 0:
        raise ValueError("Invalid multiband seam geometry.")
    # Extend source colors into the added canvas only as low-frequency context.
    # High-frequency border detail continues to come from the generated scene.
    padded = Image.fromarray(np.pad(np.asarray(source), ((top, oh-top-h), (left, ow-left-w), (0, 0)), mode="edge"))
    originals = [np.asarray(padded, dtype=np.float32)]
    candidates = [np.asarray(generated, dtype=np.float32)]
    radii = (2, 8, 24)
    for radius in radii:
        originals.append(np.asarray(padded.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32))
        candidates.append(np.asarray(generated.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32))
    yy, xx = np.indices((oh, ow), dtype=np.float32)
    distance = np.minimum(np.minimum(xx-left+.5, left+w-xx-.5),
                          np.minimum(yy-top+.5, top+h-yy-.5))
    result = np.zeros_like(candidates[0])
    reaches = (0, outer_reach/8, outer_reach/3, outer_reach)
    for index, reach in enumerate(reaches):
        a = originals[index] - (originals[index+1] if index < 3 else 0)
        b = candidates[index] - (candidates[index+1] if index < 3 else 0)
        alpha = np.clip((distance+reach)/(inset+reach), 0, 1)
        alpha = (alpha*alpha*(3-2*alpha))[..., None]
        result += a*alpha + b*(1-alpha)
    result = np.rint(result).clip(0, 255).astype(np.uint8)
    # Explicit invariants also avoid any floating-point rounding at the limits.
    result[top+inset:top+h-inset, left+inset:left+w-inset] = np.asarray(source)[inset:h-inset, inset:w-inset]
    exterior = distance <= -outer_reach
    result[exterior] = np.asarray(generated)[exterior]
    return Image.fromarray(result), {"method": "laplacian-four-band", "inner_model_pixels": inset,
        "outer_lighting_model_pixels": outer_reach, "gaussian_radii_model_pixels": list(radii),
        "original_interior_preserved": True, "final_image_blurred": False}
