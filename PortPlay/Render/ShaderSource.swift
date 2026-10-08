import Foundation

/// The retro filter shaders, compiled when the app starts.
///
/// They live in a string instead of a .metal file because Xcode 26 ships its
/// Metal compiler as a separate download that GitHub's build machines don't have.
/// Compiling at launch takes a few milliseconds and needs nothing extra.
enum ShaderSource {
    static let metal = """
#include <metal_stdlib>
using namespace metal;

// A straight port of the WebGL filters in the Windows version (filters.js),
// so Scanlines and CRT look the same on every platform.

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Full screen quad from four vertices, drawn as a triangle strip.
// The viewport places it where the scaling mode wants the picture.
vertex VertexOut portplay_vertex(uint vid [[vertex_id]]) {
    const float2 positions[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0)
    };
    float2 p = positions[vid];
    VertexOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return out;
}

struct FilterUniforms {
    float2 srcSize;
    float lines;
    int mode;   // 0 clean, 1 scanlines, 2 CRT
};

// Bends the picture like the glass of an old tube TV
static float2 curve(float2 uv) {
    uv = uv * 2.0 - 1.0;
    float2 offset = abs(uv.yx) / float2(5.5, 4.5);
    uv = uv + uv * offset * offset;
    return uv * 0.5 + 0.5;
}

fragment float4 portplay_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler smp [[sampler(0)]],
    constant FilterUniforms &u [[buffer(0)]]
) {
    float2 uv = in.uv;

    if (u.mode == 0) {
        return float4(tex.sample(smp, uv).rgb, 1.0);
    }

    bool crt = u.mode == 2;

    if (crt) {
        uv = curve(uv);
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
    }

    float3 color = tex.sample(smp, uv).rgb;

    if (crt) {
        // Color bleed: red and blue smear slightly sideways, as on composite video
        float2 px = float2(1.0 / u.srcSize.x, 0.0);
        color.r = mix(color.r, tex.sample(smp, uv - px * 1.5).r, 0.45);
        color.b = mix(color.b, tex.sample(smp, uv + px * 1.5).b, 0.45);

        // Soft glow around bright areas
        float3 glow = tex.sample(smp, uv + px * 3.0).rgb + tex.sample(smp, uv - px * 3.0).rgb;
        color += glow * 0.06;
    }

    // Darken the gaps between lines, then lift the result back up
    float line = 0.5 + 0.5 * cos(uv.y * u.lines * 2.0 * M_PI_F);
    float strength = crt ? 0.42 : 0.35;
    color *= 1.0 - strength * (1.0 - line);
    color *= crt ? 1.28 : 1.18;

    if (crt) {
        // Red, green and blue phosphor stripes, one per physical pixel column
        float stripe = fmod(in.position.x, 3.0);
        float3 mask = float3(0.86);
        if (stripe < 1.0) mask.r = 1.08;
        else if (stripe < 2.0) mask.g = 1.08;
        else mask.b = 1.08;
        color *= mask;

        // Darker corners
        float vignette = 16.0 * uv.x * uv.y * (1.0 - uv.x) * (1.0 - uv.y);
        color *= pow(max(vignette, 0.0), 0.18);
    }

    return float4(clamp(color, 0.0, 1.0), 1.0);
}
"""
}
