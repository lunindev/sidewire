// Draws the remote pointer as a small arrow, positioned at the Source's out-of-band CURSOR feed.
// The Source sets showsCursor=false and does NOT bake a pointer into the video, so without this the
// remote pointer is invisible on the Display. Two instances give a cheap drop shadow (instance 0,
// offset + dark) so the arrow reads on any background; instance 1 is the white fill.

struct Instance {
    scale: vec2<f32>,  // half-extent in clip space (x, y)
    offset: vec2<f32>, // clip-space offset from the tip (drop shadow)
    color: vec4<f32>,
};

struct CursorUniform {
    tip: vec2<f32>,    // clip-space position of the pointer hotspot (the arrow tip)
    _pad: vec2<f32>,
    inst: array<Instance, 2>,
};

@group(0) @binding(0) var<uniform> u: CursorUniform;

struct VSOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) color: vec4<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> VSOut {
    // A minimal pointer: a right triangle whose hotspot is the top-left tip at local (0,0).
    // Local coords use a top-left, y-DOWN convention (like the wire's normalized cursor); the
    // vertex converts to clip space (y up) below.
    var local = array<vec2<f32>, 3>(
        vec2<f32>(0.0, 0.0),
        vec2<f32>(0.0, 1.0),
        vec2<f32>(0.7, 0.7),
    );
    let inst = u.inst[ii];
    let l = local[vi];
    let x = u.tip.x + inst.offset.x + l.x * inst.scale.x;
    let y = u.tip.y + inst.offset.y - l.y * inst.scale.y; // local y is down; clip y is up
    var out: VSOut;
    out.pos = vec4<f32>(x, y, 0.0, 1.0);
    out.color = inst.color;
    return out;
}

@fragment
fn fs_main(in: VSOut) -> @location(0) vec4<f32> {
    return in.color;
}
