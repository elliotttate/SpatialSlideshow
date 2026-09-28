#include "../Sources/CameraMotion.h"
#include <simd/simd.h>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>

static uint32_t bits(float value) { uint32_t result; std::memcpy(&result, &value, sizeof(result)); return result; }
static bool close(float a, float b) { return std::abs(a - b) < 0.000001f; }

// Captured pre-expansion camera calculation. Compare the optional-modifier
// integration against it over every path, 181 frames, strengths, and depths.
static vector_float3 legacyEye(unsigned pattern, float progress, float depth, float strength) {
    float t = std::clamp(progress,0.f,1.f);
    float eased = t*t*(3-2*t), sweep = 2*eased-1;
    float arch = sinf(t*M_PI);
    vector_float3 offset;
    switch (pattern % 6) {
        case 0: offset={ .065f*sweep, .018f*arch, .015f*arch}; break;
        case 1: offset={-.065f*sweep,-.018f*arch, .015f*arch}; break;
        case 2: offset={ .020f*sweep,-.010f*sweep,-.015f+.045f*eased}; break;
        case 3: offset={-.020f*sweep, .012f*sweep, .030f-.050f*eased}; break;
        case 4: offset={ .045f*sweep, .028f*sweep, .010f*arch}; break;
        default:offset={ .012f*arch, .045f*sweep, .012f*arch}; break;
    }
    return offset * depth * strength;
}

int main() {
    unsigned compatibilitySamples = 0;
    for (unsigned pattern=0; pattern<6; ++pattern) for (int frame=0; frame<=180; ++frame)
        for (float strength : {0.f, .3f, .65f, 1.f, 1.8f, 2.f}) for (float depth : {.05f, 1.f, 3.725f, 100.f}) {
            float progress=frame/180.f;
            const auto oldEye=legacyEye(pattern,progress,depth,strength);
            const auto noExpansion=spatial::expansionMotion(pattern,progress,strength,0);
            auto optionalEye=oldEye;
            optionalEye *= noExpansion.travelScale;
            for (int axis=0;axis<3;++axis) assert(bits(optionalEye[axis])==bits(oldEye[axis]));
            assert(bits(noExpansion.zoom)==bits(1.06f));
            for (float percent : {0.f, 5.f, 20.f}) for (float allowance : {0.f, 10.f, 40.f}) {
                const auto modifier=spatial::expansionMotion(pattern,progress,strength,percent,allowance);
                const auto expected=oldEye * modifier.travelScale;
                const auto actual=spatial::cameraMotion(pattern,progress,depth,strength,percent,allowance);
                for (int axis=0;axis<3;++axis) assert(bits(actual.eye[axis])==bits(expected[axis]));
                assert(bits(actual.zoom)==bits(modifier.zoom));
            }
            ++compatibilitySamples;
        }
    printf("PASS no-expansion bit compatibility: %u camera samples\n", compatibilitySamples);
    const float amounts[]={0,5,10,20}, travel[]={1,1.15f,1.3f,1.6f}, zoom[]={1.06f,1.166f,1.272f,1.484f};
    for (int index=0;index<4;++index) {
        const float percent=amounts[index];
        const auto range=spatial::expansionMotionRange(2,1,percent);
        assert(close(range.travelScale,travel[index]));
        assert(close(range.minZoom,zoom[index]));
        assert(close(range.maxZoom,zoom[index]*(1.f+.003f*percent)));
        assert(close(range.minZoom / (1.f+.02f*percent), 1.06f)); // Same original subject scale at every expansion amount.
        for (int frame=0;frame<=100;++frame) {
            const float t=frame/100.f;
            const auto push=spatial::expansionMotion(2,t,1,percent);
            const auto pull=spatial::expansionMotion(3,1-t,1,percent);
            assert(close(push.zoom,pull.zoom));
            if(frame)assert(push.zoom>=spatial::expansionMotion(2,(frame-1)/100.f,1,percent).zoom);
            for(unsigned pattern=0;pattern<6;++pattern) {
                const auto stopped=spatial::expansionMotion(pattern,t,0,percent);
                assert(close(stopped.zoom,zoom[index]) && bits(stopped.travelScale)==bits(1.f));
                const auto gentle=spatial::expansionMotion(pattern,t,.5f,percent);
                const auto strong=spatial::expansionMotion(pattern,t,1,percent);
                assert(gentle.zoom<=strong.zoom && gentle.travelScale<=strong.travelScale);
                assert(strong.zoom>=1.06f && strong.zoom<=1.573041f && strong.travelScale<=1.600001f);
            }
        }
        for(unsigned pattern : {0u,1u,4u,5u}) {
            const auto start=spatial::expansionMotion(pattern,0,1,percent);
            const auto middle=spatial::expansionMotion(pattern,.5f,1,percent);
            const auto end=spatial::expansionMotion(pattern,1,1,percent);
            assert(close(start.zoom,zoom[index]) && close(end.zoom,zoom[index]));
            assert(close(middle.zoom,zoom[index]*(1.f+.35f*.003f*percent)));
        }
        printf("PASS amount %.0f%%: travel %.3fx, push zoom %.4f..%.4f\n",percent,range.travelScale,range.minZoom,range.maxZoom);
    }
    const auto capped=spatial::expansionMotion(2,1,1,99);
    const auto max=spatial::expansionMotion(2,1,1,20);
    assert(bits(capped.zoom)==bits(max.zoom) && bits(capped.travelScale)==bits(max.travelScale));
    for(float invalid : {-1.f,std::numeric_limits<float>::infinity(),std::numeric_limits<float>::quiet_NaN()}) {
        const auto amount=spatial::expansionMotion(2,.5f,1,invalid);
        const auto strength=spatial::expansionMotion(2,.5f,invalid,20);
        const auto progress=spatial::expansionMotion(2,invalid,1,20);
        assert(bits(amount.zoom)==bits(1.06f) && bits(amount.travelScale)==bits(1.f));
        assert(close(strength.zoom,1.484f) && bits(strength.travelScale)==bits(1.f));
        assert(std::isfinite(progress.zoom) && std::isfinite(progress.travelScale));
    }
    puts("PASS original subject scale across expansion amounts, reverse paths, gentle breathing, strength-zero stillness, strength scaling, finite guards, 20% cap");
    for (float percent : {2.f,5.f,10.f,20.f}) for (unsigned pattern=0;pattern<6;++pattern) {
        for (int frame=0;frame<=180;++frame) {
            const float t=frame/180.f;
            const auto baseline=spatial::expansionMotion(pattern,t,1,percent);
            const auto none=spatial::expansionMotion(pattern,t,1,percent,0);
            const auto half=spatial::expansionMotion(pattern,t,1,percent,percent);
            const auto full=spatial::expansionMotion(pattern,t,1,percent,2*percent);
            const auto capped=spatial::expansionMotion(pattern,t,1,percent,100);
            assert(bits(none.zoom)==bits(baseline.zoom));
            assert(none.zoom>=half.zoom && half.zoom>=full.zoom);
            assert(full.zoom>=1.06f-.000001f); // Never wider than the generated canvas.
            assert(close(full.zoom,capped.zoom));
            assert(bits(full.travelScale)==bits(none.travelScale));
            const auto reverse=spatial::expansionMotion(3,1-t,1,percent,percent);
            const auto push=spatial::expansionMotion(2,t,1,percent,percent);
            assert(close(push.zoom,reverse.zoom));
        }
        assert(close(spatial::expansionMotion(2,0,1,percent,2*percent).zoom,1.06f));
        assert(close(spatial::expansionMotion(2,1,1,percent,2*percent).zoom,
                     spatial::expansionMotion(2,1,1,percent,0).zoom));
        assert(close(spatial::expansionMotion(pattern,.5f,0,percent,40).zoom,1.06f*(1+.02f*percent)));
    }
    for(float invalid : {-10.f,std::numeric_limits<float>::infinity(),std::numeric_limits<float>::quiet_NaN()})
        assert(close(spatial::expansionMotion(2,.5f,1,20,invalid).zoom,spatial::expansionMotion(2,.5f,1,20).zoom));
    puts("PASS zero-allowance compatibility, monotonic widening, original zoom-in endpoint, canvas limit, reversal, stillness, invalid allowances");

    // Higher strengths must orbit, not visit the same points backwards.
    // Check all paths, both expansion extremes, closure, tangent continuity,
    // bounded excursion, and nonzero enclosed area.
    for (unsigned pattern=0;pattern<6;++pattern) for (float percent : {0.f,5.f,20.f}) {
        const auto start=spatial::cameraPathOffset(pattern,0);
        const auto end=spatial::cameraPathOffset(pattern,1);
        const auto center=(start+end)*.5f;
        const auto radius=(end-start)*.5f;
        double previousDistance=0;
        for (int step=50;step<=80;++step) {
            const float strength=step*.05f;
            auto last=spatial::cameraMotion(pattern,0,1,strength,percent,percent*2);
            const auto loopEnd=spatial::cameraMotion(pattern,1,1,strength,percent,percent*2);
            assert(simd_length(last.eye-loopEnd.eye)<.000001f && close(last.zoom,loopEnd.zoom));
            double distance=0;
            for (int frame=1;frame<=1200;++frame) {
                const float t=frame/1200.f;
                const auto value=spatial::cameraMotion(pattern,t,1,strength,percent,percent*2);
                const auto scale=spatial::expansionMotion(pattern,t,2,percent).travelScale;
                const auto orbitOffset=value.eye/(2*scale)-center;
                assert(simd_length(orbitOffset)<=simd_length(radius)+.000001f);
                assert(std::isfinite(value.zoom));
                distance+=simd_length(value.eye-last.eye);
                last=value;
            }
            assert(distance+0.00001>=previousDistance);
            previousDistance=distance;
        }
        const auto first=spatial::cameraMotion(pattern,0,1,4,percent,percent*2);
        const auto last=spatial::cameraMotion(pattern,1,1,4,percent,percent*2);
        const auto q1=spatial::cameraMotion(pattern,.25f,1,4,percent,percent*2);
        const auto q3=spatial::cameraMotion(pattern,.75f,1,4,percent,percent*2);
        assert(simd_length(first.eye-last.eye)<.000001f && close(first.zoom,last.zoom));
        assert(simd_length(q1.eye-q3.eye)>.02f); // Distinct sides of the loop.
        const float delta=.0001f;
        const auto after=spatial::cameraMotion(pattern,delta,1,4,percent,percent*2);
        const auto before=spatial::cameraMotion(pattern,1-delta,1,4,percent,percent*2);
        const auto outgoing=(after.eye-first.eye)/delta;
        const auto incoming=(last.eye-before.eye)/delta;
        assert(simd_dot(simd_normalize(outgoing),simd_normalize(incoming))>.999f);
        assert(simd_length(incoming)>.1f); // No turnaround pause at the seam.
        vector_float3 area={0,0,0};
        auto previous=first;
        for (int frame=1;frame<=1200;++frame) {
            const auto current=spatial::cameraMotion(pattern,frame/1200.f,1,4,percent,percent*2);
            area+=simd_cross(previous.eye,current.eye);
            previous=current;
        }
        assert(simd_length(area)>.01f);
        for (int frame=0;frame<=180;++frame) {
            const float t=frame/180.f;
            const auto low=spatial::cameraMotion(pattern,t,1,2,percent,percent*2);
            const auto high=spatial::cameraMotion(pattern,t,1,2.000001f,percent,percent*2);
            assert(simd_length(low.eye-high.eye)<.000001f && close(low.zoom,high.zoom));
            const auto full=spatial::cameraMotion(pattern,t,1,2.5f,percent,percent*2);
            const auto almost=spatial::cameraMotion(pattern,t,1,2.499999f,percent,percent*2);
            assert(simd_length(full.eye-almost.eye)<.000001f && close(full.zoom,almost.zoom));
        }
    }
    for(float invalid : {-1.f,std::numeric_limits<float>::infinity(),std::numeric_limits<float>::quiet_NaN()}) {
        const auto traversal=spatial::motionTraversal(invalid,invalid);
        assert(traversal.progress==0 && traversal.strength==0 && traversal.orbitBlend==0);
    }
    assert(close(spatial::motionTraversal(1,100).orbitAngle,2*M_PI));
    puts("PASS high-strength orbits: bounded excursion, distinct return arc, increasing arc length, closed full circle, continuous seam velocity, synchronized zoom, threshold continuity");
}
