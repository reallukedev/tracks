#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The player's moving backgrounds, drawn as fills. Each takes the size it's drawn at and a
// phase in seconds, which `BackdropClock` keeps: it runs while the music plays and glides to
// a stop when it's paused. Every one keeps white type readable on it, whatever the cover:
// see `readable`.
//
// SwiftUI draws them on iPhone. The Mac draws them itself, at the end of this file, each frame
// straight to a Metal layer (see `BackdropCanvas`): a SwiftUI update there lays out the whole
// window again, every frame.

namespace backdrop {

float hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Value noise, 0 to 1, smooth between whole numbers.
float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x),
               mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

// Three octaves: broad shapes with a little detail, nothing busy.
float fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    const float2x2 turn = float2x2(1.6, 1.2, -1.2, 1.6);
    for (int octave = 0; octave < 3; octave++) {
        value += amplitude * noise(p);
        p = turn * p;
        amplitude *= 0.5;
    }
    return value;
}

float2x2 rotation(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return float2x2(c, -s, s, c);
}

float luma(float3 colour) {
    return dot(colour, float3(0.2126, 0.7152, 0.0722));
}

// A little richer, as Music's backgrounds are, then kept under `ceiling`: dark colours stay
// as they are and bright ones come down softly, keeping their hue (yellows lean to gold), so
// a white cover gives a pale grey field that white type still reads on rather than a glare.
float3 readable(float3 colour, float richness, float ceiling) {
    float grey = luma(colour);
    colour = max(float3(0.0), mix(float3(grey), colour, richness));
    grey = luma(colour);
    if (grey > 0.0001) {
        float softened = ceiling * (1.0 - exp(-grey / ceiling));
        // Yellow brought down keeping its hue turns olive, the colour of mud. Leaned toward
        // amber as it deepens, it stays gold, as a lamp's light does.
        float high = max(max(colour.r, colour.g), 0.001);
        float yellow = saturate((min(colour.r, colour.g) - colour.b) / high);
        colour.g *= 1.0 - 0.2 * yellow * (1.0 - softened / grey);
        colour *= softened / max(luma(colour), 0.0001);
    }
    return colour;
}

// Centred, the longer side running -0.5 to 0.5, so a square cover fills any shape.
float2 centred(float2 position, float2 size) {
    return (position - size * 0.5) / max(size.x, size.y);
}

}

// Living Cover: the cover itself, flowing. Three copies of it, softened and turning slowly
// at their own speeds, as Music's animated backgrounds are made, drift through a field that
// warps like ink in water, and blend into one another where it folds.
//
// It feels the music (see `LivingCoverFeel`). `phases` are where each copy's turn is, the
// deep one turning with the bass, the middle with the mids and the top with the highs, and
// where the warp's flow is, which keeps the music's tempo, surging on each kick. `feel` is the
// bass's swell, which leans the cover in; the kick, a push out from the middle; the stir,
// which turns the middle more than the edges, as a spoon turns ink; and the glint of the
// cymbals in the highlights. `mood` is the music's depth, its colours richer as it gets loud;
// how much the flow folds, more for a crowded mix; a quiet passage's slow breath; and the
// highlights' warmth. `lift` opens the cover out as the music jumps to loud. With every phase
// the same time and the rest zero, it flows calmly on its own.
namespace backdrop {

half4 livingCover(float2 position, float2 size, float4 phases, float4 feel, float4 mood, float lift, texture2d<half> cover) {
    constexpr sampler art(address::mirrored_repeat, filter::linear);
    float swell = feel.x, thump = feel.y, twist = feel.z, glint = feel.w;
    float depth = mood.x, churn = mood.y, breath = mood.z, warmth = mood.w;
    float t = phases.w;

    float2 p = backdrop::centred(position, size);
    float near = exp(-dot(p, p) * 4.0);
    p *= 1.0 - 0.12 * swell - 0.05 * breath - 0.06 * thump - 0.2 * thump * near + 0.12 * lift;
    p = backdrop::rotation(0.35 * twist * near) * p;

    // Two warps, each through the last, drifting on their own.
    float2 q = float2(backdrop::fbm(p * 1.5 + float2(0.0, t * 0.07)),
                      backdrop::fbm(p * 1.5 + float2(5.2, 1.3) - t * 0.06));
    float2 r = float2(backdrop::fbm(p * 1.5 + 3.0 * q + float2(1.7, 9.2) + t * 0.05),
                      backdrop::fbm(p * 1.5 + 3.0 * q + float2(8.3, 2.8) - t * 0.045));
    float2 warp = (r - 0.5) * (0.5 + 0.28 * churn + 0.08 * depth) * (1.0 - 0.3 * lift);

    float2 a = backdrop::rotation(phases.x * 0.02) * p * 0.8 + warp;
    float2 b = backdrop::rotation(-phases.y * 0.025 + 2.1) * (p + float2(0.14, -0.1)) * 1.2 + warp * 1.3;
    float2 c = backdrop::rotation(phases.z * 0.015 + 4.2) * (p - float2(0.12, 0.16)) * 0.55 - warp * 0.8;
    float3 first = float3(cover.sample(art, 0.5 + a).rgb);
    float3 second = float3(cover.sample(art, 0.5 + b).rgb);
    float3 third = float3(cover.sample(art, 0.5 + c).rgb);

    float blend = smoothstep(0.3, 0.7, backdrop::fbm(p * 1.2 + q * 2.0 + t * 0.03));
    float over = smoothstep(0.35, 0.75, backdrop::fbm(p * 1.4 - r * 2.0 + 7.1 - t * 0.025));
    float3 colour = mix(mix(first, second, blend), third, over * 0.7);

    // A touch more contrast, so its colours stand apart rather than meet in grey, and a
    // little deeper toward the edges, as a room is lit from the middle. Loud, both a little
    // more: the colours deepen as a chorus does, and richer still as the music lifts.
    colour = max(float3(0.0), (colour - 0.3) * (1.1 + 0.1 * depth) + 0.3);
    colour *= 1.0 - (0.14 + 0.08 * depth) * smoothstep(0.3, 0.8, length(p));
    colour = backdrop::readable(colour, 1.45 + 0.3 * depth + 0.3 * lift, 0.47);

    // Only the highlights take the song's warmth and the cymbals' glint, so the deep
    // colours under the words stay where they are.
    float highlight = smoothstep(0.18, 0.42, backdrop::luma(colour));
    float3 tint = warmth > 0.0 ? float3(1.06, 1.0, 0.9) : float3(0.93, 0.99, 1.07);
    colour *= mix(float3(1.0), tint, abs(warmth) * 0.55 * highlight);
    float speck = backdrop::noise(p * 13.0 + float2(t * 0.5, -t * 0.4)) * backdrop::noise(p * 9.0 - float2(t * 0.3, t * 0.45));
    colour *= 1.0 + glint * 0.4 * speck * speck * highlight;

    colour *= 1.0 + 0.1 * thump + 0.04 * swell + 0.06 * lift;
    return half4(half3(colour), 1.0h);
}

}

[[ stitchable ]] half4 livingCover(float2 position, float2 size, float4 phases, float4 feel, float4 mood, float lift, texture2d<half> cover) {
    return backdrop::livingCover(position, size, phases, feel, mood, lift, cover);
}

// Reeded Glass: the cover behind a pane of ribbed glass. Each reed is a lens that shows a
// narrow slice of what's behind, flipped and squeezed, with light along its crest and shade
// in the groove beside it. Behind the glass the cover drifts slowly, so the slices shift as
// if you were walking past.
namespace backdrop {

half4 reededGlass(float2 position, float2 size, float time, float reed, texture2d<half> cover) {
    constexpr sampler art(address::mirrored_repeat, filter::linear);
    float across = position.x / reed;
    float cell = floor(across);
    float local = fract(across) - 0.5;

    // What this point of the reed sees: the slice around the reed's middle, reversed.
    float seen = (cell + 0.5 - local * 2.4) * reed;
    float2 p = backdrop::centred(float2(seen, position.y + local * local * reed * 0.6), size);

    float t = time;
    p = backdrop::rotation(sin(t * 0.045) * 0.14) * p;
    p *= 0.72 + 0.06 * sin(t * 0.06);
    p += float2(sin(t * 0.037) * 0.16, cos(t * 0.029) * 0.1);
    float3 colour = float3(cover.sample(art, 0.5 + p).rgb);

    // Light on each reed's rounded face, brightest just left of its middle; shade where two
    // reeds meet.
    float lit = (local + 0.2) / 0.16;
    float crest = exp(-lit * lit);
    float groove = smoothstep(0.34, 0.5, abs(local));
    colour = colour * (0.92 - 0.3 * groove) + 0.09 * crest;

    // Down the pane, a soft sheen that drifts with the cover.
    float sheen = 0.5 + 0.5 * sin(position.y / size.y * 3.0 + t * 0.08);
    colour += 0.025 * sheen;

    colour = backdrop::readable(colour, 1.2, 0.48);
    return half4(half3(colour), 1.0h);
}

}

[[ stitchable ]] half4 reededGlass(float2 position, float2 size, float time, float reed, texture2d<half> cover) {
    return backdrop::reededGlass(position, size, time, reed, cover);
}

// Aurora: curtains of light in the cover's colours over a night sky of its darkest. Each
// curtain has a bright lower hem and a long glow above it, rippling along the sky, made of
// fine vertical rays that shimmer. Their hems hang at `hem`, a part of the height, and their
// glow reaches up by `tail`: high, where the cover is, so the sky below stays dark for the
// song's name and the controls.
namespace backdrop {

half4 aurora(float2 position, float2 size, float time, float hem, float tail, half4 first, half4 second, half4 third, half4 sky) {
    float2 uv = position / size;
    float x = position.x / max(size.x, size.y) * 1.6;
    float t = time;

    float3 night = float3(sky.rgb);
    float3 colour = mix(night * 1.25, night * 0.35, smoothstep(0.0, 1.0, uv.y));
    float3 curtains[3] = { float3(first.rgb), float3(second.rgb), float3(third.rgb) };

    for (int index = 0; index < 3; index++) {
        float i = float(index);
        float edge = hem + i * 0.085
            + 0.06 * sin(x * 2.1 + t * 0.16 + i * 2.3)
            + 0.08 * (backdrop::fbm(float2(x * 1.3 + t * 0.06 + i * 3.1, i * 1.7)) - 0.5);
        float d = uv.y - edge;
        float glow = d < 0.0 ? exp(d * tail) : exp(-d * 34.0);
        float rays = 0.3 + 0.7 * pow(backdrop::fbm(float2(x * 16.0 + i * 20.0, t * 0.12 + i)), 1.4);
        // Each curtain thins and gathers along the sky, over time.
        float presence = smoothstep(0.15, 0.75, 0.5 + 0.5 * sin(x * 1.1 - t * 0.09 + i * 1.9));
        colour += curtains[index] * glow * rays * (0.35 + 0.65 * presence) * 0.85;
    }

    colour = backdrop::readable(colour, 1.1, 0.55);
    return half4(half3(colour), 1.0h);
}

}

[[ stitchable ]] half4 aurora(float2 position, float2 size, float time, float hem, float tail, half4 first, half4 second, half4 third, half4 sky) {
    return backdrop::aurora(position, size, time, hem, tail, first, second, third, sky);
}

// Any picture made readable in the same way, for Artwork's blurred cover.
[[ stitchable ]] half4 readableColour(float2 position, half4 colour, float richness, float ceiling) {
    float alpha = max(float(colour.a), 0.001);
    float3 kept = backdrop::readable(float3(colour.rgb) / alpha, richness, ceiling);
    return half4(half3(kept * alpha), colour.a);
}

// MARK: - Drawn by the Mac
//
// The same pictures, drawn straight to a Metal layer. Each takes its inputs as a list of
// float4s: the first is always the view's size in points, the pixels to a point it's drawn
// at, and whether to dither.

struct BackdropPixel {
    float4 position [[position]];
};

// One triangle that covers the whole view.
vertex BackdropPixel backdropVertex(uint id [[vertex_id]]) {
    float2 corner = float2((id << 1) & 2, id & 2);
    BackdropPixel out;
    out.position = float4(corner * float2(2, -2) + float2(-1, 1), 0, 1);
    return out;
}

namespace backdrop {

// A pixel's place in points, as SwiftUI's shaders are given it.
float2 point(BackdropPixel in, constant float4 *u) {
    return in.position.xy / u[0].z;
}

// SwiftUI's `dithersColor`: a little noise, so slow gradients don't band.
half4 dithered(half4 colour, float2 pixel) {
    float noise = hash(pixel + 0.5) - 0.5;
    return half4(colour.rgb + half(noise / 255.0), colour.a);
}

// Light, premultiplied, for a view that adds it to what's behind with `plusLighter`.
half4 lit(float3 colour, float alpha) {
    return half4(half3(colour * alpha), half(alpha));
}

// Distance from a rounded rectangle's edge, centred on the origin, negative inside.
float roundedBox(float2 p, float2 extent, float radius) {
    radius = min(radius, min(extent.x, extent.y));
    float2 q = abs(p) - extent + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float erf(float x) {
    float x2 = x * x;
    float a = 0.147;
    float inner = -x2 * (4.0 / M_PI_F + a * x2) / (1.0 + a * x2);
    return sign(x) * sqrt(1.0 - exp(inner));
}

// A line `width` across, `d` from its middle, softened as by a blur of `radius`.
float softLine(float d, float width, float radius) {
    float sigma = max(radius, 0.001) * 0.5;
    float k = 1.0 / (sigma * M_SQRT2_F);
    return 0.5 * (erf((d + width * 0.5) * k) - erf((d - width * 0.5) * k));
}

}

fragment half4 livingCoverFragment(BackdropPixel in [[stage_in]], constant float4 *u [[buffer(0)]], texture2d<half> cover [[texture(0)]]) {
    half4 colour = backdrop::livingCover(backdrop::point(in, u), u[0].xy, u[1], u[2], u[3], u[4].x, cover);
    return backdrop::dithered(colour, in.position.xy);
}

fragment half4 reededGlassFragment(BackdropPixel in [[stage_in]], constant float4 *u [[buffer(0)]], texture2d<half> cover [[texture(0)]]) {
    half4 colour = backdrop::reededGlass(backdrop::point(in, u), u[0].xy, u[1].x, u[1].y, cover);
    return backdrop::dithered(colour, in.position.xy);
}

fragment half4 auroraFragment(BackdropPixel in [[stage_in]], constant float4 *u [[buffer(0)]]) {
    half4 colour = backdrop::aurora(backdrop::point(in, u), u[0].xy, u[1].x, u[1].y, u[1].z, half4(u[2]), half4(u[3]), half4(u[4]), half4(u[5]));
    return backdrop::dithered(colour, in.position.xy);
}

// A square picture filling the view, scaled by `u[1].x` and turned by `u[1].y` radians about
// the middle, then moved by `u[1].zw` points, as SwiftUI's `scaleEffect`, `rotationEffect` and
// `offset` place it. Where it doesn't reach, `u[2]`.
float4 placed(float2 p, constant float4 *u, texture2d<half> picture) {
    constexpr sampler art(address::clamp_to_edge, filter::linear);
    float2 size = u[0].xy;
    float2 middle = size * 0.5;
    float side = max(size.x, size.y) * u[3].x;
    float2 q = p - middle - u[1].zw;
    float c = cos(u[1].y), s = sin(u[1].y);
    q = float2(c * q.x + s * q.y, -s * q.x + c * q.y) / u[1].x;
    float2 uv = q / side + 0.5;
    if (any(uv < 0.0) || any(uv > 1.0)) return float4(u[2].rgb, -1.0);
    return float4(picture.sample(art, uv));
}

// Artwork: the soft cover, large and turning, made readable.
fragment half4 artworkFragment(BackdropPixel in [[stage_in]], constant float4 *u [[buffer(0)]], texture2d<half> picture [[texture(0)]]) {
    float4 colour = placed(backdrop::point(in, u), u, picture);
    float3 kept = colour.a < 0.0 ? colour.rgb : backdrop::readable(colour.rgb, 1.3, 0.5);
    return backdrop::dithered(half4(half3(kept), 1.0h), in.position.xy);
}

// Bloom: the soft cover, huge and turning, richer by `u[4].y` and lifted by `u[4].x`, as
// SwiftUI's `saturation` and `brightness` do it.
fragment half4 bloomFragment(BackdropPixel in [[stage_in]], constant float4 *u [[buffer(0)]], texture2d<half> picture [[texture(0)]]) {
    float4 colour = placed(backdrop::point(in, u), u, picture);
    if (colour.a < 0.0) return half4(0.0h);
    float grey = backdrop::luma(colour.rgb);
    float3 rich = mix(float3(grey), colour.rgb, u[4].y) + u[4].x;
    return backdrop::dithered(half4(half3(saturate(rich)), 1.0h), in.position.xy);
}

// MARK: Mesh gradients

// A mesh of up to four by four points, each with a colour, as SwiftUI's `MeshGradient` draws
// it with `smoothsColors`: each patch between four points a smooth surface, its tangents from
// the points around. `m[0]` is the columns, the rows and the steps each patch is cut into;
// `m[1]` the size and pixels to a point; `m[2...17]` the points, in parts of the size, row by
// row; `m[18...33]` their colours, not premultiplied.
struct MeshPixel {
    float4 position [[position]];
    float4 colour;
    // Where in the mesh, in parts of the size, before any scaling.
    float2 unit;
};

namespace backdrop {

float4 meshValue(constant float4 *m, int base, int columns, int rows, int x, int y) {
    return m[base + clamp(y, 0, rows - 1) * columns + clamp(x, 0, columns - 1)];
}

float4 meshAcross(constant float4 *m, int base, int columns, int rows, int x, int y) {
    if (x == 0) return meshValue(m, base, columns, rows, 1, y) - meshValue(m, base, columns, rows, 0, y);
    if (x == columns - 1) return meshValue(m, base, columns, rows, x, y) - meshValue(m, base, columns, rows, x - 1, y);
    return (meshValue(m, base, columns, rows, x + 1, y) - meshValue(m, base, columns, rows, x - 1, y)) * 0.5;
}

float4 meshDown(constant float4 *m, int base, int columns, int rows, int x, int y) {
    if (y == 0) return meshValue(m, base, columns, rows, x, 1) - meshValue(m, base, columns, rows, x, 0);
    if (y == rows - 1) return meshValue(m, base, columns, rows, x, y) - meshValue(m, base, columns, rows, x, y - 1);
    return (meshValue(m, base, columns, rows, x, y + 1) - meshValue(m, base, columns, rows, x, y - 1)) * 0.5;
}

// A patch's surface at `s`, `t`, through its four corners and their tangents.
float4 meshPatch(constant float4 *m, int base, int columns, int rows, int x, int y, float s, float t) {
    float4 hs = float4(2 * s * s * s - 3 * s * s + 1, -2 * s * s * s + 3 * s * s, s * s * s - 2 * s * s + s, s * s * s - s * s);
    float4 ht = float4(2 * t * t * t - 3 * t * t + 1, -2 * t * t * t + 3 * t * t, t * t * t - 2 * t * t + t, t * t * t - t * t);
    float4 value = 0;
    for (int j = 0; j < 2; j++) {
        for (int i = 0; i < 2; i++) {
            float wv = hs[i] * ht[j];
            float wa = hs[2 + i] * ht[j];
            float wd = hs[i] * ht[2 + j];
            value += wv * meshValue(m, base, columns, rows, x + i, y + j)
                + wa * meshAcross(m, base, columns, rows, x + i, y + j)
                + wd * meshDown(m, base, columns, rows, x + i, y + j);
        }
    }
    return value;
}

}

// The mesh cut into triangles, `m[0].z` steps to a patch each way; `m[1].w` scales it about the
// middle, as `scaleEffect` does.
vertex MeshPixel meshVertex(uint id [[vertex_id]], constant float4 *m [[buffer(0)]]) {
    int columns = int(m[0].x), rows = int(m[0].y), steps = int(m[0].z);
    int across = (columns - 1) * steps;
    int quad = int(id) / 6;
    int corner = int(id) % 6;
    int2 offsets[6] = { int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 0), int2(1, 1), int2(0, 1) };
    int2 cell = int2(quad % across, quad / across) + offsets[corner];
    float2 place = float2(cell) / float(steps);
    int x = min(int(place.x), columns - 2);
    int y = min(int(place.y), rows - 2);
    float2 local = place - float2(x, y);
    float2 unit = backdrop::meshPatch(m, 2, columns, rows, x, y, local.x, local.y).xy;
    float4 colour = saturate(backdrop::meshPatch(m, 18, columns, rows, x, y, local.x, local.y));
    float2 shown = 0.5 + (unit - 0.5) * m[1].w;
    MeshPixel out;
    out.position = float4(shown.x * 2 - 1, 1 - shown.y * 2, 0, 1);
    out.colour = colour;
    out.unit = unit;
    return out;
}

// Stage's Flow: the mesh, opaque, with the kick as light from the middle, `u[2].x` strong at
// the middle and gone `u[2].y` points out, added as `plusLighter` adds it.
fragment half4 flowFragment(MeshPixel in [[stage_in]], constant float4 *m [[buffer(0)]], constant float4 *u [[buffer(1)]]) {
    float2 p = in.position.xy / m[1].z;
    float reach = saturate(length(p - m[1].xy * 0.5) / u[0].y);
    float3 colour = in.colour.rgb + u[0].x * (1.0 - reach);
    return backdrop::dithered(half4(half3(saturate(colour)), 1.0h), in.position.xy);
}

// Stage's glow: the mesh as light, faded out toward its edge as an elliptical gradient from
// `u[0].x` to `u[0].y` of the size fades it, `u[0].z` strong.
fragment half4 glowFragment(MeshPixel in [[stage_in]], constant float4 *u [[buffer(1)]]) {
    float reach = length(in.unit - 0.5);
    float mask = 1.0 - saturate((reach - u[0].x) / (u[0].y - u[0].x));
    return backdrop::lit(in.colour.rgb, in.colour.a * mask * u[0].z);
}

// MARK: Stage's visualizer

// Bars: `u[1].x` capsules across, each its height in `heights`, rising from the foot in a
// gradient from the cover's light `u[2]` (a little brighter on the kick, `u[1].y`) to white.
fragment half4 barsFragment(BackdropPixel in [[stage_in]], constant float4 *u [[buffer(0)]], constant float *heights [[buffer(1)]]) {
    float2 size = u[0].xy;
    float2 p = backdrop::point(in, u);
    int count = int(u[1].x);
    float pitch = size.x / float(count);
    float width = pitch * 0.56;
    int index = clamp(int(p.x / pitch), 0, count - 1);
    float shaped = pow(min(1.0, max(0.0, heights[index]) * 1.2), 1.35);
    float height = width + shaped * (size.y - width);
    float2 middle = float2(float(index) * pitch + pitch * 0.5, size.y - height * 0.5);
    float edge = backdrop::roundedBox(p - middle, float2(width, height) * 0.5, width * 0.5);
    float cover = saturate(0.5 - edge * u[0].z);
    float t = saturate((size.y - p.y) / (size.y * 0.85));
    float4 light = float4(u[2].rgb, u[2].a * (0.75 + 0.15 * u[1].y));
    float4 colour = mix(light, float4(1.0, 1.0, 1.0, 0.92), t);
    return backdrop::lit(colour.rgb, colour.a * cover);
}

// The waveform: `u[1].x` moments, newest last, each a thin capsule `u[1].z` wide every `u[1].w`
// points from the right, moved on by `u[1].y` of a step; mirrored about the middle, faded at
// the ends.
fragment half4 waveformFragment(BackdropPixel in [[stage_in]], constant float4 *u [[buffer(0)]], constant float *samples [[buffer(1)]]) {
    float2 size = u[0].xy;
    float2 p = backdrop::point(in, u);
    int count = int(u[1].x);
    float shift = u[1].y, width = u[1].z, pitch = u[1].w;
    float back = (size.x - width - p.x) / pitch - shift;
    float cover = 0.0;
    for (int k = int(floor(back)); k <= int(floor(back)) + 1; k++) {
        if (k < 0 || k >= count) continue;
        float level = saturate(samples[count - 1 - k]);
        float height = width + pow(level, 0.85) * (size.y - width);
        float left = size.x - (float(k) + shift) * pitch - width;
        float2 middle = float2(left + width * 0.5, size.y * 0.5);
        float edge = backdrop::roundedBox(p - middle, float2(width, height) * 0.5, width * 0.5);
        cover = max(cover, saturate(0.5 - edge * u[0].z));
    }
    float x = p.x / size.x;
    float fade = saturate(x / 0.28) * saturate((1.0 - x) / 0.04);
    return backdrop::lit(float3(1.0), 0.85 * cover * fade);
}

namespace backdrop {

// The cover's colours round it, `stops` of them with the first again at the end, turned to
// start at `angle`, as SwiftUI's conic gradient lays them.
float3 conic(float2 offset, float angle, constant float4 *stops, int count) {
    float turn = fract((atan2(offset.y, offset.x) - angle) / (2.0 * M_PI_F));
    float place = turn * float(count - 1);
    int index = min(int(place), count - 2);
    return mix(stops[index].rgb, stops[index + 1].rgb, place - float(index));
}

// One stroke of light round the cover, softened, as premultiplied colour.
float4 haloStroke(float edge, float outset, float width, float blur, float3 colour, float opacity) {
    float amount = softLine(edge - outset, width, blur) * opacity;
    return float4(colour * amount, amount);
}

float4 over(float4 top, float4 under) {
    return top + under * (1.0 - top.a);
}

}

// The halo: light round a cover `u[1].x` points across with corners `u[1].y`, centred, as
// strokes softened by blurs; `u[1].z` how full the music is, `u[1].w` the beat's bloom, `u[2].x`
// the turning. `u[2].y` colours from `u[3]`, the first again at the end. Worked out at half
// size, as SwiftUI drew it, and faded toward the view's edge.
fragment half4 haloFragment(BackdropPixel in [[stage_in]], constant float4 *u [[buffer(0)]]) {
    float2 size = u[0].xy * 0.5;
    float2 p = backdrop::point(in, u) * 0.5;
    float side = u[1].x * 0.5;
    float radius = u[1].y * 0.5;
    float level = u[1].z, bloom = u[1].w, phase = u[2].x;
    int count = int(u[2].y);
    float2 offset = p - size * 0.5;
    float edge = backdrop::roundedBox(offset, float2(side * 0.5), radius);
    float3 turning = backdrop::conic(offset, phase * 0.35, u + 3, count);
    float3 opposite = backdrop::conic(offset, -phase * 0.22 + 2.0, u + 3, count);

    float spread = side * (0.1 + 0.08 * level + 0.08 * bloom);
    float4 wide = backdrop::haloStroke(edge, spread * 0.5, spread * 2.0, side * 0.1 + spread * 0.6, opposite, 0.35 + 0.35 * level + 0.3 * bloom);
    float4 close = backdrop::haloStroke(edge, side * 0.02, side * (0.05 + 0.03 * bloom), side * 0.035, turning, 0.55 + 0.25 * level + 0.2 * bloom);
    float lineOpacity = 0.6 + 0.4 * max(level, bloom);
    float4 line = backdrop::over(
        backdrop::haloStroke(edge, 1.0, 1.0, 1.2, float3(1.0), 0.5),
        backdrop::haloStroke(edge, 1.0, 2.5, 1.2, turning, 1.0)
    ) * lineOpacity;
    float4 light = backdrop::over(line, backdrop::over(close, wide));

    float reach = length(backdrop::point(in, u) / u[0].xy - 0.5) / 0.5;
    float mask = 1.0 - saturate((reach - 0.55) / 0.45);
    return half4(light * mask);
}

// MARK: Halo, the background

// Halo: light from behind the cover. Worked out at a third of the size, as SwiftUI drew it:
// `u[1]` the light's middle and the cover's half side, in those points, and the shorter side;
// `u[2]` how loud, the bass, the kick and a new song's bloom; `u[3].x` how far the colours
// have turned, `u[3].y` how many colours the rays take, `u[3].z` the rays' softening. Then the
// field, the wash's two colours, the glow's and the bloom's (not premultiplied), and the rays'
// colours. Each band's ray in `bands`, low notes at the top, mirrored.
fragment half4 haloBackdropFragment(BackdropPixel in [[stage_in]], constant float4 *u [[buffer(0)]], constant float *bands [[buffer(1)]]) {
    float2 p = backdrop::point(in, u) / 3.0;
    float2 centre = u[1].xy;
    float edge = u[1].z, side = u[1].w;
    float loudness = u[2].x, bass = u[2].y, kick = u[2].z, bloom = u[2].w;
    float sweep = u[3].x;
    int colours = int(u[3].y);
    float soft = u[3].z;
    float2 offset = p - centre;
    float distance = length(offset);

    float3 colour = u[4].rgb;

    // The wash, laid over the field.
    float wash = side * (0.95 + 0.12 * loudness + 0.05 * kick);
    if (distance < wash) {
        float t = distance / wash;
        float4 inner = float4(u[5].rgb * u[5].a, u[5].a);
        float4 middle = float4(u[6].rgb * u[6].a, u[6].a);
        float4 washed = t < 0.5 ? mix(inner, middle, t * 2.0) : mix(middle, float4(0.0), (t - 0.5) * 2.0);
        colour = washed.rgb + colour * (1.0 - washed.a);
    }

    // The rays, added to one another and laid over it as one softened layer.
    float4 rays = 0.0;
    const int spokes = 48;
    for (int index = 0; index < spokes; index++) {
        float level = bands[index < 24 ? index : 47 - index];
        float angle = float(index) / float(spokes) * 2.0 * M_PI_F - M_PI_F * 0.5;
        float2 direction = float2(cos(angle), sin(angle));
        float reach = 1.0 - 0.75 * max(0.0, direction.y);
        float rayLength = edge * (0.22 + 0.85 * level) * reach;
        float halfWidth = edge * 0.25;
        float2 local = p - (centre + direction * (edge * 0.92 + rayLength * 0.3));
        float2 along = float2(dot(local, direction), dot(local, float2(-direction.y, direction.x)));
        float inside = length(along / float2(rayLength, halfWidth));
        // The ellipse's edge, softened by the layer's blur: about two of its deviations each way.
        float blur = min(0.9, 2.0 * soft / halfWidth);
        float cover = 1.0 - smoothstep(1.0 - blur, 1.0 + blur, inside);
        if (cover <= 0.0) continue;
        float fall = saturate(1.0 - length(along) / rayLength);
        float hue = fract(float(index) / float(spokes) + sweep);
        int pick = int(hue * float(colours)) % colours;
        float alpha = (0.14 + 0.34 * level) * fall * cover;
        rays += float4(u[9 + pick].rgb * alpha, alpha);
    }
    rays = min(rays, float4(1.0));
    colour = rays.rgb + colour * (1.0 - rays.a);

    // Light right behind the cover, and a new song's bloom, added.
    float glow = edge * (1.15 + 0.4 * bass + 0.3 * kick);
    if (distance < glow) {
        float t = saturate((distance - edge * 0.5) / (glow - edge * 0.5));
        colour += u[7].rgb * u[7].a * (1.0 - t);
    }
    if (bloom > 0.0) {
        float radius = edge * 0.9 + side * (1.0 - bloom) * 1.1;
        float t = saturate(distance / radius);
        colour += u[8].rgb * u[8].a * (1.0 - t);
    }
    return backdrop::dithered(half4(half3(saturate(colour)), 1.0h), in.position.xy);
}
