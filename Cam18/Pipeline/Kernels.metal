// Core Image kernels for Cam18.
// Built with MTL_COMPILER_FLAGS = -fcikernel and MTLLINKER_FLAGS = -cikernel
// (see project.yml), and loaded from default.metallib by `Kernels.swift`.
//
// All kernels expect perceptual (sRGB-gamma) values in 0...1; the pipeline
// converts from Core Image's linear working space before applying looks.

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

static inline float cam18_luma(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

static inline float cam18_hash(float2 p, float seed) {
    float3 p3 = fract(float3(p.xyx) * 0.1031 + seed * 0.0137);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

/// Smooth value noise in -0.5...0.5.
static inline float cam18_valueNoise(float2 p, float seed) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = cam18_hash(i, seed);
    float b = cam18_hash(i + float2(1.0, 0.0), seed);
    float c = cam18_hash(i + float2(0.0, 1.0), seed);
    float d = cam18_hash(i + float2(1.0, 1.0), seed);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) - 0.5;
}

extern "C" {
namespace coreimage {

/// Film grain. `cellSize` is in pixels of the image being rendered, so the
/// pipeline scales it with resolution and preview and stills match.
/// Grain is strongest in the midtones and mostly monochrome.
float4 cam18_grain(sample_t s, float amount, float cellSize, float seed, destination dest) {
    float2 p = dest.coord() / max(cellSize, 0.5);
    // Two octaves give a less regular, more film-like clump structure.
    float n = cam18_valueNoise(p, seed) * 0.7 + cam18_valueNoise(p * 2.13 + 17.0, seed + 3.0) * 0.45;
    float chroma = cam18_valueNoise(p * 1.37 + 5.0, seed + 7.0);
    float l = clamp(cam18_luma(s.rgb), 0.0, 1.0);
    float w = 0.25 + 3.0 * l * (1.0 - l);
    float3 g = float3(n) + float3(chroma, -chroma * 0.5, chroma * 0.2) * 0.15;
    float3 c = s.rgb + g * amount * 0.22 * w;
    return float4(clamp(c, 0.0, 1.0), s.a);
}

/// Keeps only the bright parts of the image with a soft threshold.
float4 cam18_highlights(sample_t s, float threshold, float softness) {
    float l = cam18_luma(s.rgb);
    float w = smoothstep(threshold, threshold + max(softness, 0.001), l);
    return float4(s.rgb * w, s.a);
}

/// Screen-blends a tinted glow layer over the base image.
float4 cam18_screenTint(sample_t base, sample_t glow, float3 tint, float amount) {
    float3 g = clamp(glow.rgb * tint * amount, 0.0, 1.0);
    float3 c = 1.0 - (1.0 - clamp(base.rgb, 0.0, 1.0)) * (1.0 - g);
    return float4(c, base.a);
}

/// Split toning: adds `shadowTint` to the shadows and `highlightTint` to the
/// highlights, preserving luminance roughly.
float4 cam18_splitTone(sample_t s, float3 shadowTint, float3 highlightTint, float amount) {
    float l = cam18_luma(s.rgb);
    float sw = 1.0 - smoothstep(0.0, 0.55, l);
    float hw = smoothstep(0.45, 1.0, l);
    float3 c = s.rgb + amount * (sw * shadowTint + hw * highlightTint);
    return float4(clamp(c, 0.0, 1.0), s.a);
}

/// Skin-tone likelihood (YCbCr ellipse) multiplied by a person mask.
/// Returns the mask in all channels.
float4 cam18_skinMask(sample_t s, sample_t person) {
    float3 c = clamp(s.rgb, 0.0, 1.0);
    float y = cam18_luma(c);
    float cb = 0.5 - 0.168736 * c.r - 0.331264 * c.g + 0.5 * c.b;
    float cr = 0.5 + 0.5 * c.r - 0.418688 * c.g - 0.081312 * c.b;
    float2 d = float2((cb - 0.405) / 0.085, (cr - 0.585) / 0.075);
    float m = 1.0 - smoothstep(0.65, 1.15, length(d));
    m *= smoothstep(0.10, 0.22, y) * (1.0 - smoothstep(0.96, 1.0, y));
    m *= clamp(person.r, 0.0, 1.0);
    return float4(m, m, m, 1.0);
}

/// Edge-preserving (bilateral) smoothing over a 7x7 tap grid spread across
/// `radius` pixels. `sigmaRange` controls how much of an edge is preserved.
float4 cam18_bilateral(sampler src, float radius, float sigmaRange, destination dest) {
    float2 dc = dest.coord();
    float4 center = src.sample(src.transform(dc));
    float stepSize = radius / 3.0;
    float invRange = 1.0 / (2.0 * sigmaRange * sigmaRange);
    float4 sum = float4(0.0);
    float wsum = 0.0;
    for (int j = -3; j <= 3; j++) {
        for (int i = -3; i <= 3; i++) {
            float2 o = float2(float(i), float(j));
            float4 c = src.sample(src.transform(dc + o * stepSize));
            float3 diff = c.rgb - center.rgb;
            float w = exp(-dot(o, o) / 4.5) * exp(-dot(diff, diff) * invRange);
            sum += c * w;
            wsum += w;
        }
    }
    return sum / max(wsum, 1e-4);
}

/// Linear mix between two images: amount 0 returns `a`, 1 returns `b`.
float4 cam18_mix(sample_t a, sample_t b, float amount) {
    return mix(a, b, amount);
}

}
}
