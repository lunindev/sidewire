//! wgpu renderer: upload a decoded YUV frame as textures and convert YUV→RGB in a fragment shader,
//! drawing a full-screen quad with **aspect-fit letterboxing** (video centered, black bars).
//!
//! The letterbox geometry is load-bearing beyond looks: docs/02 § INPUT normalizes pointer
//! coordinates to the **rendered video rect**, so M3's input mapping needs the exact rect. It is
//! computed here and exposed via [`Renderer::video_rect`].
//!
//! Both [`PixelFormat::Yuv420p`] (three `R8` planes) and [`PixelFormat::Nv12`] (`R8` Y + `RG8` UV)
//! are supported — software decode yields the former, a future hardware path the latter. A single
//! pipeline handles both; a `format` uniform tells the shader which plane layout to sample.
//!
//! The renderer is windowing-agnostic: it renders into any [`wgpu::TextureView`] (a window surface
//! frame, or an offscreen texture for the headless test). It owns clones of the device/queue.

use sidewire_media::{DecodedFrame, PixelFormat};
use wgpu::util::DeviceExt;

/// The rendered video rectangle in target pixels (top-left origin) — the aspect-fit letterbox rect.
/// docs/02 § INPUT normalizes pointer coords to this rect.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VideoRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl VideoRect {
    /// Compute the aspect-fit rect for a `video_w × video_h` image centered in a `target_w ×
    /// target_h` surface, plus the clip-space scale `(sx, sy)` the vertex shader applies. `sx`/`sy`
    /// are the fraction of each half-axis the video quad occupies (1.0 = full).
    pub fn fit(video_w: f32, video_h: f32, target_w: f32, target_h: f32) -> (VideoRect, [f32; 2]) {
        if video_w <= 0.0 || video_h <= 0.0 || target_w <= 0.0 || target_h <= 0.0 {
            return (
                VideoRect {
                    x: 0.0,
                    y: 0.0,
                    width: target_w.max(0.0),
                    height: target_h.max(0.0),
                },
                [1.0, 1.0],
            );
        }
        let va = video_w / video_h;
        let ta = target_w / target_h;
        // If the video is wider than the target, fit width and bar top/bottom; else fit height.
        let (sx, sy) = if va > ta {
            (1.0, ta / va)
        } else {
            (va / ta, 1.0)
        };
        let width = sx * target_w;
        let height = sy * target_h;
        let rect = VideoRect {
            x: (target_w - width) * 0.5,
            y: (target_h - height) * 0.5,
            width,
            height,
        };
        (rect, [sx, sy])
    }
}

/// Errors setting up the renderer.
#[derive(Debug, thiserror::Error)]
pub enum RendererError {
    #[error("no compatible wgpu adapter found")]
    NoAdapter,
    #[error("wgpu device request failed: {0}")]
    RequestDevice(#[from] wgpu::RequestDeviceError),
    #[error("wgpu surface creation failed: {0}")]
    CreateSurface(#[from] wgpu::CreateSurfaceError),
}

/// The per-draw uniform: clip-space scale + the pixel format selector. `repr(C)` for a stable GPU
/// layout; 16 bytes (a uniform-buffer-friendly size).
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Uniforms {
    scale: [f32; 2],
    format: u32,
    _pad: u32,
}

/// The GPU textures for the current frame, recreated when the frame's size/format changes.
struct PlaneTextures {
    width: u32,
    height: u32,
    format: PixelFormat,
    /// Kept for per-frame `write_texture` uploads. The bind group internally retains the views
    /// (and thus these textures), so it stays valid without a separate `views` field.
    textures: Vec<wgpu::Texture>,
    bind_group: wgpu::BindGroup,
}

/// Renders decoded YUV frames to an RGB target with YUV→RGB conversion + letterboxing.
pub struct Renderer {
    device: wgpu::Device,
    queue: wgpu::Queue,
    pipeline: wgpu::RenderPipeline,
    bind_group_layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    uniform_buffer: wgpu::Buffer,
    /// A 1×1 R8 stand-in bound to the unused third plane slot for NV12.
    dummy_view: wgpu::TextureView,
    planes: Option<PlaneTextures>,
    video_rect: VideoRect,
    /// The device's `max_texture_dimension_2d`. A decoded frame larger than this in either axis is
    /// skipped rather than passed to `create_texture`, which would otherwise trip wgpu's uncaptured-
    /// error handler and panic the (main) render thread — reachable from an imperfect/hostile Source.
    max_dim: u32,
}

impl Renderer {
    /// Build a renderer over an existing device/queue, targeting `target_format` (the window surface
    /// format, or `Rgba8Unorm` for the offscreen test). Clones the device/queue handles.
    pub fn new(
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        target_format: wgpu::TextureFormat,
    ) -> Renderer {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("yuv-shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("yuv.wgsl").into()),
        });

        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("yuv-bind-group-layout"),
            entries: &[
                // 0: uniforms
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                // 1: sampler
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
                // 2,3,4: Y, U/UV, V textures
                texture_entry(2),
                texture_entry(3),
                texture_entry(4),
            ],
        });

        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("yuv-pipeline-layout"),
            bind_group_layouts: &[&bind_group_layout],
            push_constant_ranges: &[],
        });

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("yuv-pipeline"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: target_format,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("yuv-sampler"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            // Clamp so bilinear taps at the image edge don't wrap chroma.
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            ..Default::default()
        });

        let uniform_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("yuv-uniforms"),
            size: std::mem::size_of::<Uniforms>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // 1×1 R8 dummy for the unused third plane slot (NV12 only samples two planes).
        let dummy = device.create_texture_with_data(
            queue,
            &wgpu::TextureDescriptor {
                label: Some("yuv-dummy"),
                size: wgpu::Extent3d {
                    width: 1,
                    height: 1,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::R8Unorm,
                usage: wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            },
            wgpu::util::TextureDataOrder::default(),
            &[0u8],
        );
        let dummy_view = dummy.create_view(&wgpu::TextureViewDescriptor::default());

        Renderer {
            device: device.clone(),
            queue: queue.clone(),
            pipeline,
            bind_group_layout,
            sampler,
            uniform_buffer,
            dummy_view,
            planes: None,
            video_rect: VideoRect {
                x: 0.0,
                y: 0.0,
                width: 0.0,
                height: 0.0,
            },
            max_dim: device.limits().max_texture_dimension_2d,
        }
    }

    /// Create a fully headless renderer (its own device/queue, `Rgba8Unorm` target) for tests /
    /// offscreen render. Blocks on adapter+device acquisition. A wgpu adapter is available on this
    /// dev machine (Metal).
    pub fn new_headless() -> Result<Renderer, RendererError> {
        pollster::block_on(Self::new_headless_async())
    }

    async fn new_headless_async() -> Result<Renderer, RendererError> {
        let instance = wgpu::Instance::default();
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: None,
                force_fallback_adapter: false,
            })
            .await
            .ok_or(RendererError::NoAdapter)?;
        let (device, queue) = adapter
            .request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("sidewire-headless-device"),
                    ..Default::default()
                },
                None,
            )
            .await?;
        Ok(Renderer::new(
            &device,
            &queue,
            wgpu::TextureFormat::Rgba8Unorm,
        ))
    }

    /// The rendered video rect (aspect-fit letterbox) from the most recent [`Renderer::render`].
    pub fn video_rect(&self) -> VideoRect {
        self.video_rect
    }

    /// Upload `frame`'s planes and draw it (YUV→RGB, letterboxed) into `target`, whose size is
    /// `(target_w, target_h)` pixels. Recomputes and stores the video rect.
    pub fn render(
        &mut self,
        target: &wgpu::TextureView,
        target_size: (u32, u32),
        frame: &DecodedFrame,
    ) {
        // Guard against a frame that would exceed the GPU's texture-dimension limit: creating such a
        // texture trips wgpu's uncaptured-error handler (a panic on this thread). Skip it — keep the
        // previous frame on screen — rather than crash. (A well-behaved Source never sends this.)
        if frame.width == 0
            || frame.height == 0
            || frame.width > self.max_dim
            || frame.height > self.max_dim
        {
            log::warn!(
                "skipping frame with unsupported dimensions {}x{} (max {})",
                frame.width,
                frame.height,
                self.max_dim
            );
            return;
        }
        self.upload_frame(frame);

        let (rect, scale) = VideoRect::fit(
            frame.width as f32,
            frame.height as f32,
            target_size.0 as f32,
            target_size.1 as f32,
        );
        self.video_rect = rect;

        let uniforms = Uniforms {
            scale,
            format: match frame.format {
                PixelFormat::Yuv420p => 0,
                PixelFormat::Nv12 => 1,
            },
            _pad: 0,
        };
        self.queue
            .write_buffer(&self.uniform_buffer, 0, bytemuck::bytes_of(&uniforms));

        let bind_group = match &self.planes {
            Some(p) => &p.bind_group,
            None => return,
        };

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("yuv-encoder"),
            });
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("yuv-pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: target,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        // Clear to black: the uncovered margin is the letterbox bar.
                        load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, bind_group, &[]);
            pass.draw(0..6, 0..1);
        }
        self.queue.submit(std::iter::once(encoder.finish()));
    }

    /// Render `frame` into a fresh offscreen `Rgba8Unorm` texture of `width × height` and read the
    /// pixels back as tightly-packed RGBA (`width * height * 4` bytes, row-major, top-left origin).
    ///
    /// Non-sRGB target so the read-back bytes are `round(shader_output * 255)` — directly comparable
    /// to a CPU YUV→RGB reference. Used by the headless offscreen-render test; also handy for
    /// screenshots. Blocking (maps the readback buffer).
    pub fn render_to_rgba(&mut self, width: u32, height: u32, frame: &DecodedFrame) -> Vec<u8> {
        let target = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("offscreen-target"),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let view = target.create_view(&wgpu::TextureViewDescriptor::default());
        self.render(&view, (width, height), frame);

        // copy_texture_to_buffer requires bytes_per_row to be a multiple of 256.
        let unpadded = width * 4;
        let align = wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        let padded = unpadded.div_ceil(align) * align;
        let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("offscreen-readback"),
            size: (padded * height) as u64,
            usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("readback-encoder"),
            });
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &target,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &buffer,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(padded),
                    rows_per_image: Some(height),
                },
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        self.queue.submit(std::iter::once(encoder.finish()));

        let slice = buffer.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |r| {
            let _ = tx.send(r);
        });
        // Drive the GPU until the map completes.
        let _ = self.device.poll(wgpu::Maintain::Wait);
        rx.recv()
            .expect("map channel")
            .expect("map readback buffer");

        let mapped = slice.get_mapped_range();
        let mut out = Vec::with_capacity((unpadded * height) as usize);
        for row in 0..height {
            let start = (row * padded) as usize;
            out.extend_from_slice(&mapped[start..start + unpadded as usize]);
        }
        drop(mapped);
        buffer.unmap();
        out
    }

    /// (Re)create plane textures if the frame's size/format changed, then upload the pixel data.
    fn upload_frame(&mut self, frame: &DecodedFrame) {
        let need_new = match &self.planes {
            Some(p) => {
                p.width != frame.width || p.height != frame.height || p.format != frame.format
            }
            None => true,
        };
        if need_new {
            self.planes = Some(self.create_plane_textures(frame));
        }
        let planes = self.planes.as_ref().expect("planes just set");
        for (i, plane) in frame.planes.iter().enumerate() {
            let tex = &planes.textures[i];
            let (_bpp, tw, th) = plane_texture_dims(frame.format, i, frame.width, frame.height);
            self.queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: tex,
                    mip_level: 0,
                    origin: wgpu::Origin3d::ZERO,
                    aspect: wgpu::TextureAspect::All,
                },
                &plane.data,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(plane.stride as u32),
                    rows_per_image: Some(th),
                },
                wgpu::Extent3d {
                    width: tw,
                    height: th,
                    depth_or_array_layers: 1,
                },
            );
        }
    }

    fn create_plane_textures(&self, frame: &DecodedFrame) -> PlaneTextures {
        let mut textures = Vec::new();
        let mut views = Vec::new();
        for i in 0..frame.format.plane_count() {
            let (bpp, tw, th) = plane_texture_dims(frame.format, i, frame.width, frame.height);
            let tex_format = if bpp == 2 {
                wgpu::TextureFormat::Rg8Unorm
            } else {
                wgpu::TextureFormat::R8Unorm
            };
            let tex = self.device.create_texture(&wgpu::TextureDescriptor {
                label: Some("yuv-plane"),
                size: wgpu::Extent3d {
                    width: tw,
                    height: th,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: tex_format,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            });
            views.push(tex.create_view(&wgpu::TextureViewDescriptor::default()));
            textures.push(tex);
        }

        // Bind Y, plane1, plane2 (plane2 = dummy for NV12).
        let view_y = &views[0];
        let view_u = &views[1];
        let view_v = if views.len() >= 3 {
            &views[2]
        } else {
            &self.dummy_view
        };
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("yuv-bind-group"),
            layout: &self.bind_group_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: self.uniform_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(&self.sampler),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(view_y),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::TextureView(view_u),
                },
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: wgpu::BindingResource::TextureView(view_v),
                },
            ],
        });

        PlaneTextures {
            width: frame.width,
            height: frame.height,
            format: frame.format,
            textures,
            bind_group,
        }
    }
}

/// A filterable float `texture_2d` bind-group-layout entry at `binding`.
fn texture_entry(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Texture {
            sample_type: wgpu::TextureSampleType::Float { filterable: true },
            view_dimension: wgpu::TextureViewDimension::D2,
            multisampled: false,
        },
        count: None,
    }
}

/// `(bytes_per_sample, texture_width, texture_height)` for plane `i` of `format`. NV12's UV plane is
/// a 2-byte (RG8) texture of ceil(w/2) × ceil(h/2); 420p planes are 1-byte (R8).
fn plane_texture_dims(format: PixelFormat, i: usize, width: u32, height: u32) -> (u32, u32, u32) {
    let cw = width.div_ceil(2);
    let ch = height.div_ceil(2);
    match (format, i) {
        (_, 0) => (1, width, height),             // Y (R8)
        (PixelFormat::Yuv420p, _) => (1, cw, ch), // U or V (R8)
        (PixelFormat::Nv12, _) => (2, cw, ch),    // interleaved UV (RG8)
    }
}
