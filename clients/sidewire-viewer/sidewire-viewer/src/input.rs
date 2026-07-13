//! Translate winit [`WindowEvent`]s into platform-neutral `sidewire_proto::InputEventRecord`s
//! (docs/02 § INPUT), for the Display → Source input channel.
//!
//! This is the Rust port of the Display's `Sidewire/Input/InputCapture.swift` +
//! `Sidewire/Input/KeyMapping.swift`. It matches their semantics exactly:
//!
//! * pointer coordinates are normalized `0..1` into the **rendered video rect** (the aspect-fit
//!   letterbox, [`crate::renderer::VideoRect`]) and clamped, so clicks land on-target when the
//!   stream aspect differs from the window; before a video rect is known it falls back to the full
//!   window. **No Y-flip** — winit's top-left origin already matches the wire (unlike AppKit, which
//!   the Mac has to flip);
//! * scroll deltas cross in **pixels** (docs/02 § INPUT);
//! * modifiers are the HID boot-protocol byte, reporting the **left-hand** bit when winit can't tell
//!   left from right (`ModifiersState` is device-independent);
//! * **⌘/Super combos and Escape stay LOCAL** — never forwarded — so the user keeps control of the
//!   Display machine and can always exit fullscreen; suppression is kept key-balanced (a keyUp whose
//!   keyDown was withheld is withheld too), exactly as `InputCapture.swift` does.
//!
//! [`InputTranslator`] holds all mutable state (button/modifier/click + the current video rect) and
//! exposes a pure [`InputTranslator::translate`], so the mapping is unit-testable without a window.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use sidewire_proto::{hid_modifier, InputEventRecord, InputEventType};
use winit::event::{ElementState, MouseButton, MouseScrollDelta, WindowEvent};
use winit::keyboard::{KeyCode, ModifiersState, PhysicalKey};

use crate::renderer::VideoRect;

pub mod keymap;
use keymap::ESCAPE_USAGE;

/// A winit `LineDelta` scroll tick is converted to this many pixels on the wire (docs/02 § INPUT:
/// deltas are pixels). macOS delivers pixel-precise deltas directly; a mouse wheel on Windows/Linux
/// often arrives as discrete lines, so we approximate one line ≈ this many pixels. The value matches
/// the common ~3-line × ~40 px platform default down to a single-line step used widely by winit apps.
pub const LINE_SCROLL_PX: f32 = 30.0;

/// Two presses of the same button within this window (and near the same spot) count as a
/// double-click (`clickCount = 2`), a triple as `3`, … — the OS computes this for AppKit, so we
/// reproduce it here (mirrors `NSEvent.clickCount`).
const DOUBLE_CLICK_INTERVAL: Duration = Duration::from_millis(400);

/// Max pointer travel (physical px) between two presses still counted as the same click sequence.
const DOUBLE_CLICK_SLOP_PX: f64 = 6.0;

/// One recorded button press, for the double-click multiplicity counter.
#[derive(Clone, Copy)]
struct LastPress {
    button: u8,
    at: Instant,
    x: f64,
    y: f64,
    count: u8,
}

/// Stateful translator from winit window events to `InputEventRecord`s. Create one per window; feed
/// it every [`WindowEvent`] and forward each `Some` result to the session's input channel.
pub struct InputTranslator {
    /// Current HID boot-protocol modifier byte (docs/02 § INPUT), maintained from `ModifiersChanged`.
    modifiers: u8,
    /// Latest pointer position in **physical** pixels (winit top-left origin). winit delivers the
    /// position only via `CursorMoved`, so button/scroll/key events reuse the last known position
    /// (mirrors `InputCapture.swift` reading `event.locationInWindow` for every event).
    cursor: (f64, f64),
    left_down: bool,
    right_down: bool,
    /// The aspect-fit rendered video rect (target/physical px). `None` until the first frame renders.
    video_rect: Option<VideoRect>,
    /// Fallback normalization area (the full window, physical px) used before a video rect is known.
    window_size: (f32, f32),
    last_press: Option<LastPress>,
    /// HID usages whose `keyDown` we withheld (⌘-combo / Esc): their `keyUp` must be withheld too.
    suppressed_keys: HashSet<u16>,
    /// HID usages whose `keyDown` we forwarded: a later suppression must not swallow their `keyUp`.
    forwarded_keys: HashSet<u16>,
}

impl Default for InputTranslator {
    fn default() -> Self {
        Self {
            modifiers: 0,
            cursor: (0.0, 0.0),
            left_down: false,
            right_down: false,
            video_rect: None,
            window_size: (0.0, 0.0),
            last_press: None,
            suppressed_keys: HashSet::new(),
            forwarded_keys: HashSet::new(),
        }
    }
}

impl InputTranslator {
    pub fn new() -> Self {
        Self::default()
    }

    /// Update the rendered video rect (from [`crate::renderer::Renderer::video_rect`]) after each
    /// render/resize so pointer normalization tracks the letterbox.
    pub fn set_video_rect(&mut self, rect: VideoRect) {
        self.video_rect = Some(rect);
    }

    /// Update the fallback (full-window) normalization area, in physical pixels.
    pub fn set_window_size(&mut self, width: f32, height: f32) {
        self.window_size = (width, height);
    }

    /// The current HID modifier byte (for diagnostics/tests).
    pub fn modifiers(&self) -> u8 {
        self.modifiers
    }

    /// Reset all per-session mutable state — held buttons, the modifier byte, the click sequence, and
    /// the suppressed/forwarded key sets — at a session boundary. Mirrors `InputCapture.stop()`
    /// ("don't carry a half-pressed key across sessions"): otherwise a button/modifier held when one
    /// Source drops would leak into the next (e.g. the first move reads as a drag, or a stuck GUI bit
    /// silently swallows every key as reserved-local). The video rect / window size are display
    /// geometry, not session state, so they are intentionally left intact.
    pub fn reset(&mut self) {
        self.left_down = false;
        self.right_down = false;
        self.modifiers = 0;
        self.last_press = None;
        self.suppressed_keys.clear();
        self.forwarded_keys.clear();
    }

    /// Translate one window event into an input record, or `None` if the event produces no wire
    /// event (a reserved-local key, an unmapped key, a dropped mouse button, or a state-only update
    /// like `ModifiersChanged`).
    pub fn translate(&mut self, event: &WindowEvent) -> Option<InputEventRecord> {
        match event {
            WindowEvent::CursorMoved { position, .. } => {
                self.cursor = (position.x, position.y);
                let ty = if self.left_down {
                    InputEventType::MouseDragged
                } else if self.right_down {
                    InputEventType::RightMouseDragged
                } else {
                    InputEventType::MouseMove
                };
                Some(self.pointer_record(ty))
            }
            WindowEvent::MouseInput { state, button, .. } => self.mouse_button(*state, *button),
            WindowEvent::MouseWheel { delta, .. } => Some(self.scroll(*delta)),
            WindowEvent::ModifiersChanged(mods) => {
                self.update_modifiers(mods.state());
                None
            }
            WindowEvent::KeyboardInput { event, .. } => {
                let code = match event.physical_key {
                    PhysicalKey::Code(c) => c,
                    PhysicalKey::Unidentified(_) => return None,
                };
                self.keyboard(code, event.state)
            }
            _ => None,
        }
    }

    // MARK: - Pointer

    fn mouse_button(
        &mut self,
        state: ElementState,
        button: MouseButton,
    ) -> Option<InputEventRecord> {
        let pressed = state == ElementState::Pressed;
        let (button_number, event_type) = match button {
            MouseButton::Left => {
                self.left_down = pressed;
                if pressed {
                    (0u8, InputEventType::MouseDown)
                } else {
                    (0u8, InputEventType::MouseUp)
                }
            }
            MouseButton::Right => {
                self.right_down = pressed;
                if pressed {
                    (1u8, InputEventType::RightMouseDown)
                } else {
                    (1u8, InputEventType::RightMouseUp)
                }
            }
            // Middle / back / forward / other buttons are dropped for M3 (only left/right cross the
            // wire, matching the Mac's InputCapture which forwards only .leftMouse*/.rightMouse*).
            _ => return None,
        };
        let mut record = self.pointer_record(event_type);
        record.button_number = button_number;
        record.click_count = if pressed {
            self.click_count(button_number)
        } else {
            // AppKit sets clickCount on the release too (equal to the matching press) so a
            // double-click drag-select resolves on the Source — mirror it (InputCapture.swift sets
            // clickCount on .leftMouseUp/.rightMouseUp as well as the downs).
            self.last_press
                .filter(|p| p.button == button_number)
                .map(|p| p.count)
                .unwrap_or(1)
        };
        Some(record)
    }

    /// Compute the click multiplicity for a press of `button` at the current cursor (double-click =
    /// 2, …), reproducing `NSEvent.clickCount`.
    fn click_count(&mut self, button: u8) -> u8 {
        let now = Instant::now();
        let (x, y) = self.cursor;
        let count = match self.last_press {
            Some(prev)
                if prev.button == button
                    && now.duration_since(prev.at) <= DOUBLE_CLICK_INTERVAL
                    && (prev.x - x).hypot(prev.y - y) <= DOUBLE_CLICK_SLOP_PX =>
            {
                prev.count.saturating_add(1)
            }
            _ => 1,
        };
        self.last_press = Some(LastPress {
            button,
            at: now,
            x,
            y,
            count,
        });
        count
    }

    fn scroll(&mut self, delta: MouseScrollDelta) -> InputEventRecord {
        let (dx, dy) = match delta {
            // Already pixel-precise (trackpads, hi-res wheels) — use verbatim (docs/02: pixels).
            MouseScrollDelta::PixelDelta(p) => (p.x as f32, p.y as f32),
            // Discrete wheel lines — approximate to pixels so the Source scrolls a sensible amount.
            MouseScrollDelta::LineDelta(x, y) => (x * LINE_SCROLL_PX, y * LINE_SCROLL_PX),
        };
        let mut record = self.pointer_record(InputEventType::ScrollWheel);
        record.delta_x = dx;
        record.delta_y = dy;
        record
    }

    // MARK: - Keyboard

    fn keyboard(&mut self, code: KeyCode, state: ElementState) -> Option<InputEventRecord> {
        let usage = keymap::hid_usage(code)?; // unmapped → drop (never sent as ambiguous 0)
        let pressed = state == ElementState::Pressed;

        if keymap::is_modifier_usage(usage) {
            // The ⌘/Super key is reserved for local shortcuts: never forward its own press/release
            // (otherwise the Source would be left with GUI stuck down and no combo to release it —
            // mirrors InputCapture.swift's Command-key rule). Other modifiers cross as flagsChanged.
            if keymap::is_gui_usage(usage) {
                return None;
            }
            let mut record = self.pointer_record(InputEventType::FlagsChanged);
            record.key_code = usage;
            return Some(record);
        }

        // A normal key. Reserved-local if Escape, or any key pressed while ⌘/Super is held.
        let reserved = usage == ESCAPE_USAGE || self.super_held();
        if pressed {
            if reserved {
                // Withhold the keyDown; remember it so the matching keyUp is withheld too — but only
                // if this key's keyDown was not already forwarded (⌘ arriving mid-auto-repeat).
                if !self.forwarded_keys.contains(&usage) {
                    self.suppressed_keys.insert(usage);
                }
                return None;
            }
            self.forwarded_keys.insert(usage);
            let mut record = self.pointer_record(InputEventType::KeyDown);
            record.key_code = usage;
            Some(record)
        } else {
            // Release: mirror the keyDown decision by usage (⌘ may already be gone on release).
            if self.suppressed_keys.remove(&usage) {
                return None;
            }
            self.forwarded_keys.remove(&usage);
            let mut record = self.pointer_record(InputEventType::KeyUp);
            record.key_code = usage;
            Some(record)
        }
    }

    fn update_modifiers(&mut self, state: ModifiersState) {
        // winit's ModifiersState is device-independent (no left/right), so report the left-hand bit
        // for each active modifier (docs/02 § INPUT; mirrors KeyMapping.hidModifiers). Caps Lock is
        // not a modifier bit — it crosses as a normal keyDown of usage 0x39.
        let mut m = 0u8;
        if state.control_key() {
            m |= hid_modifier::LEFT_CONTROL;
        }
        if state.shift_key() {
            m |= hid_modifier::LEFT_SHIFT;
        }
        if state.alt_key() {
            m |= hid_modifier::LEFT_ALT;
        }
        if state.super_key() {
            m |= hid_modifier::LEFT_GUI;
        }
        self.modifiers = m;
    }

    fn super_held(&self) -> bool {
        self.modifiers & hid_modifier::LEFT_GUI != 0
    }

    // MARK: - Shared record construction

    /// A record of `ty` carrying the current modifier byte and the current cursor normalized into
    /// the video rect. All wire events carry the current pointer coords + modifier byte, exactly as
    /// `InputCapture.handleEvent` fills every `InputEventRecord`.
    fn pointer_record(&self, ty: InputEventType) -> InputEventRecord {
        let (x, y) = self.normalized_cursor();
        InputEventRecord {
            event_type: ty,
            button_number: 0,
            click_count: 0,
            modifiers: self.modifiers,
            x,
            y,
            delta_x: 0.0,
            delta_y: 0.0,
            key_code: 0,
        }
    }

    /// Normalize the current cursor into the rendered video rect (0..1, clamped). Falls back to the
    /// full window before a video rect is known. No Y-flip (winit top-left origin == wire).
    fn normalized_cursor(&self) -> (f32, f32) {
        let rect = self.effective_rect();
        if rect.width <= 0.0 || rect.height <= 0.0 {
            return (0.0, 0.0);
        }
        let nx = ((self.cursor.0 as f32 - rect.x) / rect.width).clamp(0.0, 1.0);
        let ny = ((self.cursor.1 as f32 - rect.y) / rect.height).clamp(0.0, 1.0);
        (nx, ny)
    }

    fn effective_rect(&self) -> VideoRect {
        match self.video_rect {
            Some(r) if r.width > 0.0 && r.height > 0.0 => r,
            _ => VideoRect {
                x: 0.0,
                y: 0.0,
                width: self.window_size.0,
                height: self.window_size.1,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use winit::dpi::PhysicalPosition;
    use winit::event::{DeviceId, ElementState, MouseButton, MouseScrollDelta, TouchPhase};
    use winit::keyboard::{KeyCode, ModifiersState};

    /// A 400×300 video rect offset to (100,50) in a window, for coordinate-mapping assertions.
    fn translator_with_rect() -> InputTranslator {
        let mut t = InputTranslator::new();
        t.set_video_rect(VideoRect {
            x: 100.0,
            y: 50.0,
            width: 400.0,
            height: 300.0,
        });
        t
    }

    fn cursor_moved(x: f64, y: f64) -> WindowEvent {
        WindowEvent::CursorMoved {
            device_id: DeviceId::dummy(),
            position: PhysicalPosition::new(x, y),
        }
    }

    fn mouse_input(state: ElementState, button: MouseButton) -> WindowEvent {
        WindowEvent::MouseInput {
            device_id: DeviceId::dummy(),
            state,
            button,
        }
    }

    fn mouse_wheel(delta: MouseScrollDelta) -> WindowEvent {
        WindowEvent::MouseWheel {
            device_id: DeviceId::dummy(),
            delta,
            phase: TouchPhase::Moved,
        }
    }

    #[test]
    fn cursor_move_normalizes_into_video_rect() {
        let mut t = translator_with_rect();
        // Center of the rect → (0.5, 0.5). No Y-flip.
        let r = t.translate(&cursor_moved(300.0, 200.0)).unwrap();
        assert_eq!(r.event_type, InputEventType::MouseMove);
        assert!((r.x - 0.5).abs() < 1e-6, "x={}", r.x);
        assert!((r.y - 0.5).abs() < 1e-6, "y={}", r.y);
    }

    #[test]
    fn cursor_outside_rect_clamps() {
        let mut t = translator_with_rect();
        // Far above-left of the rect → clamps to (0,0).
        let r = t.translate(&cursor_moved(0.0, 0.0)).unwrap();
        assert_eq!((r.x, r.y), (0.0, 0.0));
        // Far below-right → clamps to (1,1).
        let r = t.translate(&cursor_moved(9999.0, 9999.0)).unwrap();
        assert_eq!((r.x, r.y), (1.0, 1.0));
    }

    #[test]
    fn move_while_left_button_held_is_a_drag() {
        let mut t = translator_with_rect();
        assert!(t
            .translate(&mouse_input(ElementState::Pressed, MouseButton::Left))
            .is_some());
        let r = t.translate(&cursor_moved(300.0, 200.0)).unwrap();
        assert_eq!(r.event_type, InputEventType::MouseDragged);
        // Releasing returns to plain moves.
        t.translate(&mouse_input(ElementState::Released, MouseButton::Left));
        let r = t.translate(&cursor_moved(310.0, 200.0)).unwrap();
        assert_eq!(r.event_type, InputEventType::MouseMove);
    }

    #[test]
    fn right_button_down_up_maps_and_numbers() {
        let mut t = translator_with_rect();
        let down = t
            .translate(&mouse_input(ElementState::Pressed, MouseButton::Right))
            .unwrap();
        assert_eq!(down.event_type, InputEventType::RightMouseDown);
        assert_eq!(down.button_number, 1);
        let up = t
            .translate(&mouse_input(ElementState::Released, MouseButton::Right))
            .unwrap();
        assert_eq!(up.event_type, InputEventType::RightMouseUp);
        assert_eq!(up.button_number, 1);
    }

    #[test]
    fn left_button_down_up_maps_and_numbers() {
        let mut t = translator_with_rect();
        let down = t
            .translate(&mouse_input(ElementState::Pressed, MouseButton::Left))
            .unwrap();
        assert_eq!(down.event_type, InputEventType::MouseDown);
        assert_eq!(down.button_number, 0);
        assert_eq!(down.click_count, 1);
        let up = t
            .translate(&mouse_input(ElementState::Released, MouseButton::Left))
            .unwrap();
        assert_eq!(up.event_type, InputEventType::MouseUp);
        assert_eq!(up.button_number, 0);
    }

    #[test]
    fn two_quick_presses_are_a_double_click() {
        let mut t = translator_with_rect();
        let first = t
            .translate(&mouse_input(ElementState::Pressed, MouseButton::Left))
            .unwrap();
        assert_eq!(first.click_count, 1);
        // Release, then a second press at the same spot immediately → clickCount 2.
        t.translate(&mouse_input(ElementState::Released, MouseButton::Left));
        let second = t
            .translate(&mouse_input(ElementState::Pressed, MouseButton::Left))
            .unwrap();
        assert_eq!(second.click_count, 2);
    }

    #[test]
    fn middle_button_is_dropped() {
        let mut t = translator_with_rect();
        assert!(t
            .translate(&mouse_input(ElementState::Pressed, MouseButton::Middle))
            .is_none());
    }

    #[test]
    fn scroll_pixel_delta_passes_through() {
        let mut t = translator_with_rect();
        let r = t
            .translate(&mouse_wheel(MouseScrollDelta::PixelDelta(
                PhysicalPosition::new(12.0, -7.0),
            )))
            .unwrap();
        assert_eq!(r.event_type, InputEventType::ScrollWheel);
        assert_eq!(r.delta_x, 12.0);
        assert_eq!(r.delta_y, -7.0);
    }

    #[test]
    fn scroll_line_delta_scales_to_pixels() {
        let mut t = translator_with_rect();
        let r = t
            .translate(&mouse_wheel(MouseScrollDelta::LineDelta(0.0, -2.0)))
            .unwrap();
        assert_eq!(r.event_type, InputEventType::ScrollWheel);
        assert_eq!(r.delta_x, 0.0);
        assert_eq!(r.delta_y, -2.0 * LINE_SCROLL_PX);
    }

    #[test]
    fn mapped_key_down_up_carries_usage_and_modifiers() {
        let mut t = translator_with_rect();
        // Hold Shift → the modifier byte reflects it (left-hand bit).
        t.update_modifiers(ModifiersState::SHIFT);
        let down = t.keyboard(KeyCode::KeyA, ElementState::Pressed).unwrap();
        assert_eq!(down.event_type, InputEventType::KeyDown);
        assert_eq!(down.key_code, 0x04);
        assert_eq!(down.modifiers, hid_modifier::LEFT_SHIFT);
        let up = t.keyboard(KeyCode::KeyA, ElementState::Released).unwrap();
        assert_eq!(up.event_type, InputEventType::KeyUp);
        assert_eq!(up.key_code, 0x04);
    }

    #[test]
    fn non_gui_modifier_key_is_flags_changed() {
        let mut t = translator_with_rect();
        let r = t
            .keyboard(KeyCode::ShiftLeft, ElementState::Pressed)
            .unwrap();
        assert_eq!(r.event_type, InputEventType::FlagsChanged);
        assert_eq!(r.key_code, 0xE1);
    }

    #[test]
    fn unmapped_key_produces_no_record() {
        let mut t = translator_with_rect();
        assert!(t
            .keyboard(KeyCode::PrintScreen, ElementState::Pressed)
            .is_none());
    }

    #[test]
    fn modifiers_report_left_hand_bits() {
        let mut t = InputTranslator::new();
        t.update_modifiers(ModifiersState::CONTROL | ModifiersState::ALT | ModifiersState::SUPER);
        assert_eq!(
            t.modifiers(),
            hid_modifier::LEFT_CONTROL | hid_modifier::LEFT_ALT | hid_modifier::LEFT_GUI
        );
    }

    #[test]
    fn escape_is_reserved_local_and_balanced() {
        let mut t = translator_with_rect();
        assert!(t.keyboard(KeyCode::Escape, ElementState::Pressed).is_none());
        // Its keyUp is withheld too — the remote never sees a half-stroke.
        assert!(t
            .keyboard(KeyCode::Escape, ElementState::Released)
            .is_none());
        assert!(t.suppressed_keys.is_empty(), "suppression cleared on keyUp");
        assert!(t.forwarded_keys.is_empty());
    }

    #[test]
    fn super_combo_is_reserved_local_and_balanced() {
        let mut t = translator_with_rect();
        // The GUI key itself never forwards.
        assert!(t
            .keyboard(KeyCode::SuperLeft, ElementState::Pressed)
            .is_none());
        // ⌘ held → any combo key is withheld, keyUp too.
        t.update_modifiers(ModifiersState::SUPER);
        assert!(t.keyboard(KeyCode::KeyC, ElementState::Pressed).is_none());
        assert!(t.keyboard(KeyCode::KeyC, ElementState::Released).is_none());
        assert!(t.suppressed_keys.is_empty());
        assert!(t.forwarded_keys.is_empty());
    }

    #[test]
    fn forwarded_key_still_gets_its_keyup_when_super_arrives_midway() {
        let mut t = translator_with_rect();
        // C pressed with no ⌘ → forwarded.
        assert!(t.keyboard(KeyCode::KeyC, ElementState::Pressed).is_some());
        // ⌘ arrives while C is held.
        t.update_modifiers(ModifiersState::SUPER);
        // C released: the remote still needs the keyUp (its keyDown was forwarded).
        let up = t.keyboard(KeyCode::KeyC, ElementState::Released).unwrap();
        assert_eq!(up.event_type, InputEventType::KeyUp);
        assert_eq!(up.key_code, 0x06);
    }

    #[test]
    fn falls_back_to_window_before_video_rect_known() {
        let mut t = InputTranslator::new();
        t.set_window_size(200.0, 100.0);
        let r = t.translate(&cursor_moved(100.0, 50.0)).unwrap();
        assert!((r.x - 0.5).abs() < 1e-6);
        assert!((r.y - 0.5).abs() < 1e-6);
    }
}
