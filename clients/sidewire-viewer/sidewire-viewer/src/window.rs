//! Windowed presentation via winit 0.30's [`ApplicationHandler`] + a wgpu surface, plus M3 input
//! capture + borderless fullscreen.
//!
//! The winit event loop **must run on the main thread** (required on macOS). The network / decode
//! work runs on a worker thread that posts decoded frames through a [`FrameProducer`]: it replaces a
//! single-slot mailbox (dropping any stale frame rather than growing a queue — docs/04 § Present's
//! "drop to the newest" policy) and wakes the loop with a user event to request a redraw.
//!
//! M3: the main thread also feeds every window event to an [`InputTranslator`] and forwards the
//! resulting `InputEventRecord`s to the worker over an mpsc channel (which the session drains and
//! sends as INPUT frames). `F11` toggles borderless fullscreen; `Escape` exits it (and, being
//! reserved-local, is never forwarded — docs/02 § INPUT, mirroring `InputCapture.swift`).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};

use sidewire_media::DecodedFrame;
use sidewire_proto::InputEventRecord;
use winit::application::ApplicationHandler;
use winit::event::{ElementState, KeyEvent, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop, EventLoopProxy};
use winit::keyboard::{KeyCode, PhysicalKey};
use winit::window::{Fullscreen, Window, WindowId};

use crate::input::InputTranslator;
use crate::renderer::{Renderer, RendererError};

/// A single-slot latest-frame mailbox. The worker overwrites it; the render thread takes it.
type FrameMailbox = Arc<Mutex<Option<DecodedFrame>>>;

/// Capacity of the captured-input channel (window → session). A session drains it every ~5 ms, so it
/// only backs up while no session is active; `try_send` drops when full, bounding memory.
const INPUT_CHANNEL_CAPACITY: usize = 1024;

/// User events that wake the event loop from the worker thread.
#[derive(Debug, Clone, Copy)]
pub enum AppEvent {
    /// A fresh frame is waiting in the mailbox — request a redraw.
    Frame,
    /// A Source session ended — reset the input translator's per-session state (held buttons /
    /// modifiers / suppressed keys) before the next Source connects, so nothing stuck leaks across
    /// (mirrors `InputCapture.stop()`).
    ResetInput,
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
    /// Set by the window when it closes, so the worker's (re)listen loop knows to stop even while
    /// blocked between sessions (it can't observe a closed event loop through `post`).
    stop: Arc<AtomicBool>,
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

    /// Ask the window to reset the input translator's per-session state (call at a session boundary,
    /// before re-listening, so a button/modifier/key held when the last Source dropped doesn't leak
    /// into the next session).
    pub fn reset_input(&self) {
        let _ = self.proxy.send_event(AppEvent::ResetInput);
    }

    /// True once the window has closed. The Display's re-listen loop checks this between sessions so
    /// it stops accepting new Source connections when the user closes the window (docs/03 § reconnect
    /// — the Display re-listens on a drop; the Source is the reconnecting dialer).
    pub fn should_stop(&self) -> bool {
        self.stop.load(Ordering::Relaxed)
    }
}

/// Run a video window on this (main) thread, spawning `worker` on a background thread with a
/// [`FrameProducer`] (to post decoded frames) and a `Receiver<InputEventRecord>` (captured input to
/// send). Blocks until the window closes. Must be called from the main thread (macOS).
pub fn run<F>(title: impl Into<String>, worker: F) -> Result<(), WindowError>
where
    F: FnOnce(FrameProducer, Receiver<InputEventRecord>) + Send + 'static,
{
    let event_loop = EventLoop::<AppEvent>::with_user_event().build()?;
    let proxy = event_loop.create_proxy();
    let mailbox: FrameMailbox = Arc::new(Mutex::new(None));
    let stop = Arc::new(AtomicBool::new(false));
    let producer = FrameProducer {
        mailbox: mailbox.clone(),
        proxy,
        stop: stop.clone(),
    };
    // Bounded so an open window with no session draining (between Source connections) can't grow the
    // queue without limit; `try_send` on the capture path drops when full. The session drains it
    // every ~5 ms, so it only ever fills while idle — where dropping captured input is correct.
    let (input_tx, input_rx) = sync_channel::<InputEventRecord>(INPUT_CHANNEL_CAPACITY);
    std::thread::spawn(move || worker(producer, input_rx));

    let mut app = VideoApp::new(title.into(), mailbox, input_tx, stop);
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
        let surface = instance.create_surface(window)?;
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

    /// The rendered video rect (aspect-fit letterbox, target/physical px) from the most recent
    /// render, for M3 pointer-coordinate normalization (docs/02 § INPUT).
    fn video_rect(&self) -> crate::renderer::VideoRect {
        self.renderer.video_rect()
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

/// The winit application: owns the window + GPU once resumed, the frame mailbox, and the M3 input
/// capture state (translator + the channel to the worker + fullscreen flag).
struct VideoApp {
    title: String,
    mailbox: FrameMailbox,
    window: Option<Arc<Window>>,
    gpu: Option<Gpu>,
    /// Captured input goes here; the worker's session drains it and sends INPUT frames. Bounded so an
    /// open window with no active session draining (between Source connections) cannot grow it without
    /// limit — `try_send` drops when full (see `window_event`).
    input_tx: SyncSender<InputEventRecord>,
    translator: InputTranslator,
    fullscreen: bool,
    /// The most recently rendered frame, retained so a resize / fullscreen toggle on a static screen
    /// (no new VIDEO arriving) still repaints at the new size AND refreshes the letterbox video rect
    /// for input mapping — otherwise clicks map against a stale rect (see `draw_latest`).
    last_frame: Option<DecodedFrame>,
    /// Shared with the worker so its (re)listen loop stops when the window closes.
    stop: Arc<AtomicBool>,
}

impl VideoApp {
    fn new(
        title: String,
        mailbox: FrameMailbox,
        input_tx: SyncSender<InputEventRecord>,
        stop: Arc<AtomicBool>,
    ) -> VideoApp {
        VideoApp {
            title,
            mailbox,
            window: None,
            gpu: None,
            input_tx,
            translator: InputTranslator::new(),
            fullscreen: false,
            last_frame: None,
            stop,
        }
    }

    /// Render the current frame — a fresh one from the mailbox if present, else the last one — and
    /// refresh the translator's video rect so pointer normalization tracks the current letterbox
    /// (docs/02 § INPUT). Re-rendering the retained frame is what lets a resize / fullscreen toggle on
    /// a **static screen** (no new VIDEO for seconds) repaint at the new size and re-derive the rect;
    /// gating the rect refresh on a fresh mailbox frame would strand it and mismap every click.
    fn draw_latest(&mut self) {
        if let Some(f) = self.mailbox.lock().ok().and_then(|mut s| s.take()) {
            self.last_frame = Some(f);
        }
        let rect = {
            let (gpu, frame) = match (self.gpu.as_mut(), self.last_frame.as_ref()) {
                (Some(g), Some(f)) => (g, f),
                _ => return, // no GPU yet, or nothing rendered so far
            };
            gpu.render(frame);
            gpu.video_rect()
        };
        self.translator.set_video_rect(rect);
    }

    /// Signal the worker to stop and exit the event loop (window closing).
    fn shutdown(&mut self, event_loop: &ActiveEventLoop) {
        self.stop.store(true, Ordering::Relaxed);
        event_loop.exit();
    }

    fn set_fullscreen(&mut self, on: bool) {
        if let Some(window) = &self.window {
            window.set_fullscreen(on.then(|| Fullscreen::Borderless(None)));
            self.fullscreen = on;
        }
    }

    /// Handle viewer control keys before translation. Returns `true` if the key was consumed as a
    /// window control (so it is NOT forwarded as input):
    /// * `F11` toggles borderless fullscreen — consumed (never forwarded);
    /// * `Escape` exits fullscreen — NOT consumed here, so it still flows to the translator, which
    ///   drops it as reserved-local (keeping its key-state balanced, mirroring `InputCapture.swift`).
    fn handle_window_hotkey(&mut self, key: &KeyEvent) -> bool {
        let code = match key.physical_key {
            PhysicalKey::Code(c) => c,
            PhysicalKey::Unidentified(_) => return false,
        };
        match code {
            KeyCode::F11 => {
                // Only the initial press toggles — `key.repeat` filters the auto-repeat stream so
                // holding F11 doesn't flicker in/out of fullscreen.
                if key.state == ElementState::Pressed && !key.repeat {
                    self.set_fullscreen(!self.fullscreen);
                }
                true
            }
            KeyCode::Escape => {
                if key.state == ElementState::Pressed && self.fullscreen {
                    self.set_fullscreen(false);
                }
                false
            }
            _ => false,
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
        // Seed the input translator's fallback normalization area with the initial window size.
        let size = window.inner_size();
        self.translator
            .set_window_size(size.width as f32, size.height as f32);
        self.window = Some(window);
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: AppEvent) {
        match event {
            AppEvent::Frame => {
                if let Some(w) = &self.window {
                    w.request_redraw();
                }
            }
            AppEvent::ResetInput => self.translator.reset(),
            AppEvent::Close => self.shutdown(event_loop),
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        match &event {
            WindowEvent::CloseRequested => {
                self.shutdown(event_loop);
                return;
            }
            WindowEvent::Resized(size) => {
                if let Some(gpu) = self.gpu.as_mut() {
                    gpu.resize(size.width, size.height);
                }
                self.translator
                    .set_window_size(size.width as f32, size.height as f32);
                if let Some(w) = &self.window {
                    w.request_redraw();
                }
                return;
            }
            WindowEvent::RedrawRequested => {
                self.draw_latest();
                return;
            }
            // Viewer controls (F11 toggle) are consumed here; Escape returns `false` from the hotkey
            // handler so it falls through to the translator, which drops it (reserved-local) keeping
            // its key state balanced.
            WindowEvent::KeyboardInput { event: key, .. } if self.handle_window_hotkey(key) => {
                return;
            }
            _ => {}
        }
        // Pointer / wheel / modifiers / non-hotkey keys → translate + forward to the worker. Bounded
        // channel: drop when full (no session draining) or disconnected — never block the UI thread.
        if let Some(record) = self.translator.translate(&event) {
            match self.input_tx.try_send(record) {
                Ok(()) | Err(TrySendError::Full(_)) => {}
                Err(TrySendError::Disconnected(_)) => {}
            }
        }
    }
}
