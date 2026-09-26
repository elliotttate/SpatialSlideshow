#pragma once
#include <algorithm>
#include <cmath>

namespace spatial {

struct ExpansionMotion {
    float travelScale;
    float zoom;
};

// p is the fraction added to EACH source edge, not total added width.
// The input is defensive because expansion.json is an optional scene sidecar.
inline float expansionFraction(float percentPerEdge) {
    return std::isfinite(percentPerEdge) ? std::clamp(percentPerEdge / 100.f, 0.f, .20f) : 0.f;
}

inline ExpansionMotion expansionMotion(unsigned pattern, float progress, float strength, float percentPerEdge, float zoomOutPercent = 0.f) {
    constexpr float baseZoom = 1.06f;
    const float p = expansionFraction(percentPerEdge);
    const float weight = std::isfinite(strength) ? std::clamp(strength, 0.f, 1.f) : 0.f;
    if (p == 0.f) return {1.f, baseZoom};
    // Compensate for the larger input canvas even at zero motion. The original
    // photograph keeps the same on-screen size; generated borders are camera
    // travel room, rather than the default visible composition.
    const float framingZoom = baseZoom * (1.f + 2.f * p);
    if (weight == 0.f) return {1.f, framingZoom};
    const float t = std::isfinite(progress) ? std::clamp(progress, 0.f, 1.f) : 0.f;
    const float eased = t * t * (3 - 2 * t);

    // Push and pull move from the original composition to a modestly tighter
    // view. At 20% extension the extra lens zoom is 6%, not a reveal of the
    // entire 40%-larger canvas. Pans breathe through 35% of this zoom range.
    float phase;
    switch (pattern % 6) {
        case 2: phase = eased; break;
        case 3: phase = 1.f - eased; break;
        default: phase = .35f * 4.f * eased * (1.f - eased); break;
    }
    // The original eye calculation already multiplies by strength. This
    // additional gain is bounded at 1.6x and fades away with gentle strength.
    // An explicit allowance widens the starting view, then converges toward
    // the original composition. Never reveal beyond the generated canvas.
    const float allowance = std::isfinite(zoomOutPercent)
        ? std::clamp(zoomOutPercent / 100.f, 0.f, 2.f * p) : 0.f;
    const float zoom = framingZoom * (1.f + .3f * p * weight * phase);
    return {1.f + 3.f * p * weight, zoom / (1.f + allowance * weight * (1.f - phase))};
}

struct ExpansionMotionRange {
    float travelScale;
    float minZoom;
    float maxZoom;
};

inline ExpansionMotionRange expansionMotionRange(unsigned pattern, float strength, float percentPerEdge, float zoomOutPercent = 0.f) {
    const auto start = expansionMotion(pattern, 0.f, strength, percentPerEdge, zoomOutPercent);
    const auto middle = expansionMotion(pattern, .5f, strength, percentPerEdge, zoomOutPercent);
    const auto end = expansionMotion(pattern, 1.f, strength, percentPerEdge, zoomOutPercent);
    return {start.travelScale, std::min({start.zoom, middle.zoom, end.zoom}),
            std::max({start.zoom, middle.zoom, end.zoom})};
}

} // namespace spatial
