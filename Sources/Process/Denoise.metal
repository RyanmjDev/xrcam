#include <metal_stdlib>
using namespace metal;

/// Motion-adaptive temporal denoise.
///
/// Sensor noise is random from frame to frame; a locked-off scene is not.
/// Averaging a pixel with its own recent history therefore cancels the noise
/// while leaving stable detail untouched — which is why this works far better
/// than any spatial blur, which cannot tell noise from texture and softens
/// both.
///
/// The catch is motion: blending a moving edge with its past smears it into a
/// trail. So the blend is weighted per pixel by how much that pixel actually
/// changed. Small change is assumed to be noise and gets averaged hard; large
/// change is assumed to be real movement and passes through untouched.
struct DenoiseParams {
    float strength;   // 0 = passthrough, 1 = maximum history retention
    float threshold;  // change below this reads as noise
    float knee;       // width of the fade from "noise" to "motion"
};

kernel void temporalDenoise(texture2d<float, access::read>  current  [[texture(0)]],
                            texture2d<float, access::read>  previous [[texture(1)]],
                            texture2d<float, access::write> output   [[texture(2)]],
                            constant DenoiseParams &params           [[buffer(0)]],
                            uint2 gid                                [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }

    float4 cur = current.read(gid);
    float4 prev = previous.read(gid);

    // Magnitude of change across the plane's active channels. Chroma is
    // two-channel, luma one; unused channels read as zero and contribute
    // nothing.
    float change = max(abs(cur.r - prev.r), abs(cur.g - prev.g));

    // 0 where the pixel looks static, 1 where it is clearly moving.
    float motion = smoothstep(params.threshold,
                              params.threshold + params.knee,
                              change);

    // Retain history only in the static parts of the frame.
    float retain = params.strength * (1.0 - motion);

    output.write(mix(cur, prev, retain), gid);
}
