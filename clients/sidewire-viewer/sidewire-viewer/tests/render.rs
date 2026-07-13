//! Headless offscreen-render test for the wgpu YUV→RGB + letterbox path (no window/surface).
//!
//! Renders a known synthetic YUV420P frame to an offscreen RGBA texture, reads the pixels back, and
//! asserts (1) the center pixel's RGB matches an independent CPU BT.709 limited-range conversion of
//! the same Y/U/V within ±3, and (2) a pixel in the letterbox bar region is black. This validates
//! the color and geometry paths on a real wgpu adapter (available on this dev machine).

use sidewire_media::{DecodedFrame, PixelFormat, Plane};
use sidewire_viewer::renderer::{Renderer, VideoRect};

/// Build a solid-color YUV420P frame (`width × height`) with the given Y/U/V sample bytes.
fn solid_yuv420p(width: u32, height: u32, y: u8, u: u8, v: u8) -> DecodedFrame {
    let cw = width.div_ceil(2) as usize;
    let ch = height.div_ceil(2) as usize;
    DecodedFrame {
        width,
        height,
        format: PixelFormat::Yuv420p,
        planes: vec![
            Plane {
                data: vec![y; width as usize * height as usize],
                stride: width as usize,
                width: width as usize,
                height: height as usize,
            },
            Plane {
                data: vec![u; cw * ch],
                stride: cw,
                width: cw,
                height: ch,
            },
            Plane {
                data: vec![v; cw * ch],
                stride: cw,
                width: cw,
                height: ch,
            },
        ],
        pts_nanos: 0,
    }
}

/// Build a solid-color NV12 frame: R8 Y plane + a single RG8 interleaved UV plane (U in `.r`, V in
/// `.g`). Software decode never yields NV12 (a future hardware path does), so this is the only test
/// exercising the RG8 texture upload + the shader's NV12 branch.
fn solid_nv12(width: u32, height: u32, y: u8, u: u8, v: u8) -> DecodedFrame {
    let cw = width.div_ceil(2) as usize;
    let ch = height.div_ceil(2) as usize;
    // UV plane: cw samples per row, 2 bytes each (U,V), ch rows.
    let mut uv = Vec::with_capacity(cw * ch * 2);
    for _ in 0..(cw * ch) {
        uv.push(u);
        uv.push(v);
    }
    DecodedFrame {
        width,
        height,
        format: PixelFormat::Nv12,
        planes: vec![
            Plane {
                data: vec![y; width as usize * height as usize],
                stride: width as usize,
                width: width as usize,
                height: height as usize,
            },
            Plane {
                data: uv,
                stride: cw * 2,
                width: cw,
                height: ch,
            },
        ],
        pts_nanos: 0,
    }
}

/// The CPU reference for the shader's BT.709 limited-range YUV→RGB (must match `yuv.wgsl`).
fn yuv_to_rgb_ref(y: u8, u: u8, v: u8) -> [u8; 3] {
    let yl = (y as f32 / 255.0 - 16.0 / 255.0) * (255.0 / 219.0);
    let cu = (u as f32 / 255.0 - 128.0 / 255.0) * (255.0 / 224.0);
    let cv = (v as f32 / 255.0 - 128.0 / 255.0) * (255.0 / 224.0);
    let r = yl + 1.5748 * cv;
    let g = yl - 0.1873 * cu - 0.4681 * cv;
    let b = yl + 1.8556 * cu;
    [
        (r.clamp(0.0, 1.0) * 255.0).round() as u8,
        (g.clamp(0.0, 1.0) * 255.0).round() as u8,
        (b.clamp(0.0, 1.0) * 255.0).round() as u8,
    ]
}

fn pixel(rgba: &[u8], width: u32, x: u32, y: u32) -> [u8; 3] {
    let i = ((y * width + x) * 4) as usize;
    [rgba[i], rgba[i + 1], rgba[i + 2]]
}

fn close(a: [u8; 3], b: [u8; 3], tol: i32) -> bool {
    (0..3).all(|c| (a[c] as i32 - b[c] as i32).abs() <= tol)
}

#[test]
fn renders_known_yuv_with_letterbox() {
    // A distinctly non-gray color so a swapped-plane bug in the shader would be caught. These sample
    // values decode to a saturated-ish orange under BT.709 limited range.
    let (y, u, v) = (150u8, 60u8, 200u8);

    // Video is 4:3 (320×240); target is 2:1 (400×200) → the video fits height and is pillarboxed,
    // leaving black bars on the left/right.
    let (target_w, target_h) = (400u32, 200u32);
    let frame = solid_yuv420p(320, 240, y, u, v);

    let mut renderer = Renderer::new_headless().expect("headless wgpu (adapter must exist here)");
    let rgba = renderer.render_to_rgba(target_w, target_h, &frame);
    assert_eq!(rgba.len(), (target_w * target_h * 4) as usize);

    // The video rect must be pillarboxed. Assert against INDEPENDENTLY hand-computed numbers (not
    // VideoRect::fit, which would be a tautology): 320×240 (4:3) into 400×200 (2:1) fits height, so
    // height=200, width = 400·(4/3)/(2/1) = 266.67, x = (400−266.67)/2 = 66.67, y = 0.
    let rect = renderer.video_rect();
    assert!(
        (rect.height - 200.0).abs() < 0.02,
        "video fills target height, got {rect:?}"
    );
    assert!(
        (rect.width - 266.667).abs() < 0.05,
        "pillarboxed width, got {rect:?}"
    );
    assert!(
        (rect.x - 66.667).abs() < 0.05,
        "left bar width, got {rect:?}"
    );
    assert!(rect.y.abs() < 0.02, "no top bar, got {rect:?}");

    // Center pixel = the video color.
    let center = pixel(&rgba, target_w, target_w / 2, target_h / 2);
    let want = yuv_to_rgb_ref(y, u, v);
    assert!(
        close(center, want, 3),
        "center pixel {center:?} should match YUV→RGB reference {want:?} (±3)"
    );

    // A pixel well inside the left bar (x=3, before the video rect begins) must be black.
    assert!(rect.x > 4.0, "bar is wide enough to sample");
    let bar = pixel(&rgba, target_w, 3, target_h / 2);
    assert!(
        close(bar, [0, 0, 0], 2),
        "letterbox bar pixel {bar:?} should be black"
    );
}

#[test]
fn renders_nv12_frame() {
    // Same color as the YUV420P test, but delivered as NV12 — the center pixel must match the same
    // reference, proving the RG8 upload + shader NV12 branch decode U from .r and V from .g.
    let (y, u, v) = (150u8, 60u8, 200u8);
    let frame = solid_nv12(320, 240, y, u, v);

    let mut renderer = Renderer::new_headless().expect("headless wgpu");
    // Equal-aspect target (4:3) so the whole frame fills it — center is the video color.
    let rgba = renderer.render_to_rgba(320, 240, &frame);
    let center = pixel(&rgba, 320, 160, 120);
    let want = yuv_to_rgb_ref(y, u, v);
    assert!(
        close(center, want, 3),
        "NV12 center pixel {center:?} should match reference {want:?} (±3)"
    );
}

/// A YUV420P frame with **padded strides** (stride > width, as real ffmpeg planes have) and a
/// vertical split: the top half of Y is bright (235), the bottom half dark (16); chroma is neutral
/// (128). Exercises the padded-stride upload the solid frames don't, and pins orientation.
fn split_yuv420p_padded(width: u32, height: u32) -> DecodedFrame {
    let (w, h) = (width as usize, height as usize);
    let cw = width.div_ceil(2) as usize;
    let ch = height.div_ceil(2) as usize;
    let y_stride = w + 32; // visible width + alignment padding
    let c_stride = cw + 16;
    let mut y = vec![0u8; y_stride * h]; // padding bytes stay 0
    for (row, val) in (0..h).map(|r| (r, if r < h / 2 { 235u8 } else { 16u8 })) {
        for col in 0..w {
            y[row * y_stride + col] = val;
        }
    }
    let chroma = || {
        let mut c = vec![0u8; c_stride * ch];
        for row in 0..ch {
            for col in 0..cw {
                c[row * c_stride + col] = 128;
            }
        }
        c
    };
    DecodedFrame {
        width,
        height,
        format: PixelFormat::Yuv420p,
        planes: vec![
            Plane {
                data: y,
                stride: y_stride,
                width: w,
                height: h,
            },
            Plane {
                data: chroma(),
                stride: c_stride,
                width: cw,
                height: ch,
            },
            Plane {
                data: chroma(),
                stride: c_stride,
                width: cw,
                height: ch,
            },
        ],
        pts_nanos: 0,
    }
}

#[test]
fn renders_padded_stride_and_correct_orientation() {
    // 64×64 into a 64×64 target → fills it, no letterbox. Top half bright, bottom half dark.
    let frame = split_yuv420p_padded(64, 64);
    let mut renderer = Renderer::new_headless().expect("headless wgpu");
    let rgba = renderer.render_to_rgba(64, 64, &frame);

    // Neutral chroma + Y=235 → ~white; Y=16 → ~black (BT.709 limited). Sampled away from the mid
    // boundary so bilinear blending doesn't muddy the assertion.
    let top = pixel(&rgba, 64, 32, 12);
    let bottom = pixel(&rgba, 64, 32, 52);
    assert!(
        close(top, [255, 255, 255], 4),
        "top (Y=235) ~white, got {top:?}"
    );
    assert!(
        close(bottom, [0, 0, 0], 4),
        "bottom (Y=16) ~black, got {bottom:?}"
    );
    // If the image were vertically flipped, top would be dark — this pins orientation.
    assert!(
        top[0] as i32 > bottom[0] as i32 + 100,
        "top must be brighter than bottom (no vertical flip)"
    );
    // The stride padding (cols 64..95, value 0) must NOT bleed into the image: the right-edge column
    // of the top half is still bright, not padding. A stride bug (using width as bytes_per_row) would
    // misalign rows and darken/garble this.
    let top_right = pixel(&rgba, 64, 63, 12);
    assert!(
        close(top_right, [255, 255, 255], 8),
        "right-edge pixel ignores stride padding, got {top_right:?}"
    );
}

#[test]
fn letterbox_fit_is_symmetric() {
    // Wider-than-target video → fit width, bars top/bottom.
    let (rect, scale) = VideoRect::fit(1920.0, 1080.0, 1000.0, 1000.0);
    assert_eq!(scale[0], 1.0, "fits width");
    assert!(scale[1] < 1.0, "shrinks height");
    assert!(rect.y > 0.0 && rect.x == 0.0, "top/bottom bars");
    // Equal-aspect → no bars.
    let (rect2, scale2) = VideoRect::fit(320.0, 240.0, 640.0, 480.0);
    assert_eq!(scale2, [1.0, 1.0]);
    assert_eq!(rect2.x, 0.0);
    assert_eq!(rect2.y, 0.0);
    assert_eq!(rect2.width, 640.0);
    assert_eq!(rect2.height, 480.0);
}
