//! Windowed presentation via winit 0.30's [`ApplicationHandler`] + a wgpu surface.
//!
//! The winit event loop **must run on the main thread** (required on macOS). The network / decode
//! work runs on a worker thread that posts decoded frames through a [`FrameProducer`]: it replaces a
//! single-slot mailbox (dropping any stale frame rather than growing a queue — docs/04 § Present's
//! "drop to the newest" policy) and wakes the loop with a user event to request a redraw.

use std::sync::{Arc, Mutex};

use sidewire_media::DecodedFrame;
use winit::application::ApplicationHandler;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy};
use winit::window::{Window, WindowId};

use crate::renderer::{Renderer, RendererError};

/// A single-slot latest-frame mailbox. The worker overwrites it; the render thread takes it.
type FrameMailbox = Arc<Mutex<Option<DecodedFrame>>>;

/// User events that wake the event loop from the worker thread.
#[derive(Debug, Clone, Copy)]
pub enum AppEvent {
    /// A fresh frame is waiting in the mailbox — request a redraw.
    Frame,
    /// The session/worker ended — close the window.
    Close,
}

/// Errors running the windowed presenter.
#[derive(Debug, thiserror::Error)]
pub enum WindowError {
    #[error("event loop error: {0}")]
    EventLoop(#[from] winit::error::EventLoopError),
    #[error(transparent)]
    Renderer(#[from] RendererError),
}

/// The worker's handle for posting decoded frames to the window. Cheaply cloneable; `Send`.
#[derive(Clone)]
pub struct FrameProducer {
    mailbox: FrameMailbox,
    proxy: EventLoopProxy<AppEvent>,
}

impl FrameProducer {
    /// Post the latest decoded frame, dropping any previous unrendered frame (newest-wins), and wake
    /// the event loop to redraw. Returns `false` once the event loop has closed (the window was
    /// shut) so a producing loop knows to stop.
    pub fn post(&self, frame: DecodedFrame) -> bool {
        if let Ok(mut slot) = self.mailbox.lock() {
            *slot = Some(frame);
        }
        self.proxy.send_event(AppEvent::Frame).is_ok()
    }

    /// Ask the window to close (session ended).
    pub fn close(&self) {
        let _ = self.proxy.send_event(AppEvent::Close);
    }
}

/// Run a video window on this (main) thread, spawning `worker` on a background thread with a
/// [`FrameProducer`]. Blocks until the window closes. Must be called from the main thread (macOS).
pub fn run<F>(title: impl Into<String>, worker: F) -> Result<(), WindowError>
where
    F: FnOnce(FrameProducer) + Send + 'static,
{
    let event_loop = EventLoop::<AppEvent>::with_user_event().build()?;
    let proxy = event_loop.create_proxy();
    let mailbox: FrameMailbox = Arc::new(Mutex::new(None));
    let producer = FrameProducer {
        mailbox: mailbox.clone(),
        proxy,
    };
    std::thread::spawn(move || worker(producer));

    let mut app = VideoApp::new(title.into(), mailbox);
    event_loop.run_app(&mut app)?;
    Ok(())
}

/// GPU resources bound to a live window surface.
struct Gpu {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    config: wgpu::SurfaceConfiguration,
    /// The **non-sRGB** format the render pass writes through. The YUV→RGB shader outputs
    /// already-gamma-encoded R'G'B' meant to be stored verbatim; rendering through an sRGB view would
    /// apply the linear→sRGB OETF a second time (washed-out video). See `new_async`.
    render_format: wgpu::TextureFormat,
    renderer: Renderer,
}

impl Gpu {
    fn new(window: Arc<Window>) -> Result<Gpu, RendererError> {
        pollster::block_on(Self::new_async(window))
    }

    async fn new_async(window: Arc<Window>) -> Result<Gpu, RendererError> {
        let size = window.inner_size();
        let instance = wgpu::Instance::default();
        let surface = instance
            .create_surface(window)
            .expect("create wgpu surface");
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: Some(&surface),
                force_fallback_adapter: false,
            })
            .await
            .ok_or(RendererError::NoAdapter)?;
        let (device, queue) = adapter
            .request_device(
                &wgpu::DeviceDescriptor {
                    label: Some("sidewire-window-device"),
                    ..Default::default()
                },
                None,
            )
            .await?;

        let caps = surface.get_capabilities(&adapter);
        // The shader outputs already-encoded R'G'B' (see `render_format`), so we must store it
        // verbatim through a non-sRGB view. `caps.formats` ordering is backend-specific — an sRGB
        // variant can be first on Linux/Vulkan — so pick a non-sRGB format explicitly rather than
        // trusting `formats[0]`. If only sRGB formats are offered, keep the sRGB swapchain but render
        // through its non-sRGB sibling (added to `view_formats`).
        let surface_format = caps
            .formats
            .iter()
            .copied()
            .find(|f| !f.is_srgb())
            .or_else(|| caps.formats.first().copied())
            .unwrap_or(wgpu::TextureFormat::Bgra8Unorm);
        let render_format = surface_format.remove_srgb_suffix();
        let view_formats = if render_format == surface_format {
            vec![]
        } else {
            vec![render_format]
        };
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format: surface_format,
            width: size.width.max(1),
            height: size.height.max(1),
            present_mode: wgpu::PresentMode::AutoVsync,
            alpha_mode: caps
                .alpha_modes
                .first()
                .copied()
                .unwrap_or(wgpu::CompositeAlphaMode::Auto),
            view_formats,
            desired_maximum_frame_latency: 2,
        };
        surface.configure(&device, &config);

        let renderer = Renderer::new(&device, &queue, render_format);
        Ok(Gpu {
            surface,
            device,
            config,
            render_format,
            renderer,
        })
    }

    fn resize(&mut self, width: u32, height: u32) {
        self.config.width = width.max(1);
        self.config.height = height.max(1);
        self.surface.configure(&self.device, &self.config);
    }

    /// Render `frame` to the next surface texture.
    fn render(&mut self, frame: &DecodedFrame) {
        let surface_tex = match self.surface.get_current_texture() {
            Ok(t) => t,
            Err(wgpu::SurfaceError::Outdated | wgpu::SurfaceError::Lost) => {
                self.surface.configure(&self.device, &self.config);
                return;
            }
            Err(_) => return,
        };
        // Force the non-sRGB view so the shader's already-encoded output is stored verbatim (no
        // double gamma), even when the swapchain format itself is sRGB.
        let view = surface_tex
            .texture
            .create_view(&wgpu::TextureViewDescriptor {
                format: Some(self.render_format),
                ..Default::default()
            });
        self.renderer
            .render(&view, (self.config.width, self.config.height), frame);
        surface_tex.present();
    }
}

/// The winit application: owns the window + GPU once resumed, and the frame mailbox.
struct VideoApp {
    title: String,
    mailbox: FrameMailbox,
    window: Option<Arc<Window>>,
    gpu: Option<Gpu>,
}

impl VideoApp {
    fn new(title: String, mailbox: FrameMailbox) -> VideoApp {
        VideoApp {
            title,
            mailbox,
            window: None,
            gpu: None,
        }
    }

    /// Render the latest mailbox frame, if any and if the GPU is ready.
    fn draw_latest(&mut self) {
        let frame = self.mailbox.lock().ok().and_then(|mut s| s.take());
        if let (Some(gpu), Some(frame)) = (self.gpu.as_mut(), frame) {
            gpu.render(&frame);
        }
    }
}

impl ApplicationHandler<AppEvent> for VideoApp {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }
        let attrs = Window::default_attributes()
            .with_title(self.title.clone())
            .with_inner_size(winit::dpi::LogicalSize::new(960.0, 720.0));
        let window = match event_loop.create_window(attrs) {
            Ok(w) => Arc::new(w),
            Err(e) => {
                log::error!("failed to create window: {e}");
                event_loop.exit();
                return;
            }
        };
        match Gpu::new(window.clone()) {
            Ok(gpu) => self.gpu = Some(gpu),
            Err(e) => {
                log::error!("failed to init GPU: {e}");
                event_loop.exit();
                return;
            }
        }
        self.window = Some(window);
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: AppEvent) {
        match event {
            AppEvent::Frame => {
                if let Some(w) = &self.window {
                    w.request_redraw();
                }
            }
            AppEvent::Close => event_loop.exit(),
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::CloseRequested => event_loop.exit(),
            WindowEvent::Resized(size) => {
                if let Some(gpu) = self.gpu.as_mut() {
                    gpu.resize(size.width, size.height);
                }
                if let Some(w) = &self.window {
                    w.request_redraw();
                }
            }
            WindowEvent::RedrawRequested => self.draw_latest(),
            _ => {}
        }
    }
}
