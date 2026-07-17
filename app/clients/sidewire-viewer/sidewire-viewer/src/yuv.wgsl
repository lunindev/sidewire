// YUV -> RGB full-screen present shader with aspect-fit letterboxing.
//
// Supports YUV420P (three R8 planes: Y, U, V) and NV12 (R8 Y + RG8 interleaved UV). The color
// conversion is **BT.709 limited (video) range** — a sensible default for screen-content H.264/HEVC
// (docs/04-media-pipeline.md). Full-range vs limited-range can be refined later; the coefficients
// are named constants below.
//
// The video quad is scaled by `uni.scale` (clip-space fraction) to the aspect-fit rect and centered;
// the render pass clears to black first, so the uncovered margin is the letterbox bar.

struct Uniforms {
    // Clip-space half-extent of the video quad: (1,1) = full screen. Shrinks one axis to letterbox.
    scale: vec2<f32>,
    // 0 = YUV420P (sample plane1.r = U, plane2.r = V); 1 = NV12 (sample plane1.r = U, plane1.g = V).
    format: u32,
    _pad: u32,
};

@group(0) @binding(0) var<uniform> uni: Uniforms;
@group(0) @binding(1) var samp: sampler;
@group(0) @binding(2) var tex_y: texture_2d<f32>;
@group(0) @binding(3) var tex_u: texture_2d<f32>;  // U (420p) or interleaved UV (NV12)
@group(0) @binding(4) var tex_v: texture_2d<f32>;  // V (420p); unused for NV12

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
    // Full-screen quad as two triangles. Clip-space +y is up; texture uv (0,0) is top-left, so the
    // top of the image (uv.y = 0) maps to clip +y.
    var positions = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, -1.0), vec2<f32>(1.0, 1.0),
        vec2<f32>(-1.0, -1.0), vec2<f32>(1.0, 1.0), vec2<f32>(-1.0, 1.0),
    );
    var uvs = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 1.0), vec2<f32>(1.0, 0.0),
        vec2<f32>(0.0, 1.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 0.0),
    );
    var out: VsOut;
    out.pos = vec4<f32>(positions[vi] * uni.scale, 0.0, 1.0);
    out.uv = uvs[vi];
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let y = textureSample(tex_y, samp, in.uv).r;
    var cb: f32;
    var cr: f32;
    if (uni.format == 1u) {
        let uv = textureSample(tex_u, samp, in.uv);
        cb = uv.r;
        cr = uv.g;
    } else {
        cb = textureSample(tex_u, samp, in.uv).r;
        cr = textureSample(tex_v, samp, in.uv).r;
    }

    // Limited-range normalization: Y' in [16,235]/255, Cb/Cr in [16,240]/255 centered at 128.
    let yl = (y - 16.0 / 255.0) * (255.0 / 219.0);
    let u = (cb - 128.0 / 255.0) * (255.0 / 224.0);
    let v = (cr - 128.0 / 255.0) * (255.0 / 224.0);

    // BT.709 YCbCr -> RGB.
    let r = yl + 1.5748 * v;
    let g = yl - 0.1873 * u - 0.4681 * v;
    let b = yl + 1.8556 * u;

    return vec4<f32>(clamp(vec3<f32>(r, g, b), vec3<f32>(0.0), vec3<f32>(1.0)), 1.0);
}
