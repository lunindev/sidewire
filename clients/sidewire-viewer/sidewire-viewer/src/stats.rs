//! Latency instrumentation for the decode→present path.
//!
//! **Honest scope (docs/02 § VIDEO, docs/11):** true cross-machine *glass-to-glass* latency cannot
//! be measured here. The wire PTS epoch is the Source's arbitrary monotonic capture clock — it has
//! no defined relation to this machine's clock and no wall-clock anchor — and there is no live Mac
//! Source yet. What M2 *can* measure are **local** deltas on the receive→decode→present pipeline
//! (all on one clock) plus the parsed wire PTS surfaced for a future jitter buffer / HUD. Real
//! glass-to-glass numbers arrive on hardware (M3+).

use std::collections::VecDeque;
use std::time::Duration;

/// Timings for one frame's trip through the local pipeline. All durations are on this machine's
/// monotonic clock; `wire_pts_nanos` is the Source's capture PTS (a different, arbitrary epoch).
#[derive(Debug, Clone, Copy)]
pub struct FrameStats {
    /// The frame's wire PTS in nanoseconds (docs/02 § VIDEO subheader); 0 = unspecified.
    pub wire_pts_nanos: u64,
    /// VIDEO frame received → decoder produced the frame.
    pub recv_to_decode: Duration,
    /// Decoded frame → handed to the renderer / presented.
    pub decode_to_present: Duration,
}

impl FrameStats {
    /// The local receive→present latency (the sum of the two local deltas we can actually measure).
    pub fn local_latency(&self) -> Duration {
        self.recv_to_decode + self.decode_to_present
    }
}

/// A small rolling window of [`FrameStats`] for a HUD / periodic log line. Not a jitter buffer —
/// purely instrumentation.
#[derive(Debug, Default)]
pub struct LatencyTracker {
    window: VecDeque<FrameStats>,
    capacity: usize,
    total_frames: u64,
}

impl LatencyTracker {
    /// A tracker keeping the last `capacity` frames (min 1).
    pub fn new(capacity: usize) -> LatencyTracker {
        LatencyTracker {
            window: VecDeque::new(),
            capacity: capacity.max(1),
            total_frames: 0,
        }
    }

    /// Record one frame's stats.
    pub fn record(&mut self, stats: FrameStats) {
        if self.window.len() == self.capacity {
            self.window.pop_front();
        }
        self.window.push_back(stats);
        self.total_frames += 1;
    }

    /// Total frames recorded since start.
    pub fn total_frames(&self) -> u64 {
        self.total_frames
    }

    /// The most recently recorded frame's stats, if any.
    pub fn last(&self) -> Option<&FrameStats> {
        self.window.back()
    }

    /// Mean local receive→present latency over the current window, or `None` if empty.
    pub fn mean_local_latency(&self) -> Option<Duration> {
        if self.window.is_empty() {
            return None;
        }
        let sum: Duration = self.window.iter().map(|s| s.local_latency()).sum();
        Some(sum / self.window.len() as u32)
    }

    /// A one-line human summary for the periodic stat log.
    pub fn summary_line(&self) -> String {
        match (self.last(), self.mean_local_latency()) {
            (Some(last), Some(mean)) => format!(
                "frames={} pts={}ns decode={:.2}ms present={:.2}ms local_latency(mean)={:.2}ms",
                self.total_frames,
                last.wire_pts_nanos,
                last.recv_to_decode.as_secs_f64() * 1e3,
                last.decode_to_present.as_secs_f64() * 1e3,
                mean.as_secs_f64() * 1e3,
            ),
            _ => format!("frames={} (no timing yet)", self.total_frames),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rolls_over_and_averages() {
        let mut t = LatencyTracker::new(2);
        t.record(FrameStats {
            wire_pts_nanos: 1,
            recv_to_decode: Duration::from_millis(2),
            decode_to_present: Duration::from_millis(1),
        });
        t.record(FrameStats {
            wire_pts_nanos: 2,
            recv_to_decode: Duration::from_millis(4),
            decode_to_present: Duration::from_millis(1),
        });
        t.record(FrameStats {
            wire_pts_nanos: 3,
            recv_to_decode: Duration::from_millis(6),
            decode_to_present: Duration::from_millis(1),
        });
        // Capacity 2: only the last two frames count. local latencies = 5ms, 7ms → mean 6ms.
        assert_eq!(t.total_frames(), 3);
        assert_eq!(t.mean_local_latency(), Some(Duration::from_millis(6)));
        assert_eq!(t.last().unwrap().wire_pts_nanos, 3);
    }
}
