#pragma once
#include "ExpansionMotion.h"
#include <simd/simd.h>

namespace spatial {

constexpr float maxMotionStrength = 4.f;
constexpr float maxCameraExcursion = 2.f;

struct MotionTraversal {
    float progress;
    float strength;
    float orbitBlend;
    float orbitAngle;
    float orbitAspect;
};

inline MotionTraversal motionTraversal(float progress, float strength) {
    const float t = std::isfinite(progress) ? std::clamp(progress, 0.f, 1.f) : 0.f;
    const float amount = std::isfinite(strength) ? std::clamp(strength, 0.f, maxMotionStrength) : 0.f;
    if (amount <= maxCameraExcursion) return {t, amount, 0.f, 0.f, 0.f};

    // Ease into a complete elliptical orbit above the old limit. Extra strength
    // widens the return arc inside a bounded viewing range instead of retracing
    // the outbound path. The short blend preserves continuity when the live
    // strength slider crosses 2x; from 2.5x onward every path closes its circle.
    const float blend = std::min(1.f, (amount - maxCameraExcursion) / .5f);
    return {t, maxCameraExcursion, blend*blend*(3.f-2.f*blend),
            float(2*M_PI) * t, .30f + .25f * std::max(0.f, (amount-2.5f)/1.5f)};
}

struct CameraMotion {
    vector_float3 eye;
    float zoom;
};

inline vector_float3 cameraPathOffset(unsigned pattern, float t) {
    const float eased = t*t*(3-2*t), sweep = 2*eased-1;
    const float arch = sinf(t*M_PI);
    vector_float3 offset;
    switch (pattern % 6) {
        case 0: offset={ .065f*sweep, .018f*arch, .015f*arch}; break;
        case 1: offset={-.065f*sweep,-.018f*arch, .015f*arch}; break;
        case 2: offset={ .020f*sweep,-.010f*sweep,-.015f+.045f*eased}; break;
        case 3: offset={-.020f*sweep, .012f*sweep, .030f-.050f*eased}; break;
        case 4: offset={ .045f*sweep, .028f*sweep, .010f*arch}; break;
        default:offset={ .012f*arch, .045f*sweep, .012f*arch}; break;
    }
    return offset;
}

inline CameraMotion cameraMotion(unsigned pattern, float progress, float depth, float strength,
                                 float expansionPercent = 0.f, float zoomOutPercent = 0.f) {
    const auto traversal = motionTraversal(progress, strength);
    const float t = traversal.progress;
    auto offset = cameraPathOffset(pattern, t);
    float lensProgress = t;
    if (traversal.orbitBlend > 0.f) {
        const auto start = cameraPathOffset(pattern, 0.f);
        const auto end = cameraPathOffset(pattern, 1.f);
        const auto center = (start + end) * .5f;
        const auto radius = (end - start) * .5f;
        // Pans orbit in the image plane. Push/pull paths tilt through depth.
        // A smaller perpendicular radius stays inside the source's useful
        // viewing range while keeping the return half visibly distinct.
        const vector_float3 normal = (pattern % 6 == 2 || pattern % 6 == 3)
            ? vector_float3{0.f, 1.f, 0.f} : vector_float3{0.f, 0.f, 1.f};
        const auto across = simd_normalize(simd_cross(radius, normal)) * simd_length(radius) * traversal.orbitAspect;
        const float cosine = cosf(traversal.orbitAngle), sine = sinf(traversal.orbitAngle);
        const auto orbit = center - radius * cosine + across * sine;
        offset += (orbit - offset) * traversal.orbitBlend;
        // Keep expanded-image lens movement in phase with the orbit and make
        // its full-circle seam continuous too.
        lensProgress += ((1.f-cosine)*.5f - t) * traversal.orbitBlend;
    }
    auto eye = offset * depth * traversal.strength;
    float zoom = 1.06f;
    if (expansionPercent > 0.f) {
        const auto expanded = expansionMotion(pattern, lensProgress, traversal.strength, expansionPercent, zoomOutPercent);
        eye *= expanded.travelScale;
        zoom = expanded.zoom;
    }
    return {eye, zoom};
}

} // namespace spatial
