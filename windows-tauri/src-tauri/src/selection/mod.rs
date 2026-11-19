#[cfg(windows)]
pub mod windows_uia;

use serde::Serialize;
use std::time::{Duration, Instant};

pub const STABLE_FOR: Duration = Duration::from_millis(300);
pub const MAX_SELECTION_CHARS: usize = 10_000;

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Bounds {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Selection {
    pub foreground_process_id: u32,
    pub element_process_id: u32,
    pub text: String,
    pub bounds: Option<Bounds>,
    pub cursor: Option<(f64, f64)>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum SelectionRead {
    Selection(Selection),
    NoSelection,
    /// Foreground window or focused element belongs to Dola Lite itself.
    /// Ignored by WatchTracker so focusing the Result Panel never cancels or hides it.
    OwnProcess,
    TransientError {
        foreground_process_id: Option<u32>,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub enum WatchAction {
    None,
    EmitSelection(Selection),
    EmitDeselection,
}

#[derive(Default)]
pub struct WatchTracker {
    candidate_anchor: Option<Selection>,
    last_observed: Option<Selection>,
    candidate_since: Option<Instant>,
    last_emitted: Option<Selection>,
    missing_since: Option<Instant>,
}

impl WatchTracker {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn observe(&mut self, read: SelectionRead, now: Instant) -> WatchAction {
        match read {
            SelectionRead::OwnProcess => {
                // Focusing Dola Lite's own Result Panel / Pill / Settings must not
                // treat the user's previous selection as cleared.
                self.candidate_anchor = None;
                self.last_observed = None;
                self.candidate_since = None;
                self.missing_since = None;
                WatchAction::None
            }
            SelectionRead::TransientError {
                foreground_process_id,
            } => {
                self.candidate_anchor = None;
                self.last_observed = None;
                self.candidate_since = None;

                let switched_foreground = matches!(
                    (&self.last_emitted, foreground_process_id),
                    (Some(emitted), Some(pid)) if pid != emitted.foreground_process_id
                );
                if switched_foreground {
                    let since = *self.missing_since.get_or_insert(now);
                    if now.saturating_duration_since(since) >= STABLE_FOR {
                        self.last_emitted = None;
                        self.missing_since = None;
                        return WatchAction::EmitDeselection;
                    }
                } else {
                    self.missing_since = None;
                }
                WatchAction::None
            }
            SelectionRead::NoSelection => {
                self.candidate_anchor = None;
                self.last_observed = None;
                self.candidate_since = None;
                if self.last_emitted.is_some() {
                    let since = *self.missing_since.get_or_insert(now);
                    if now.saturating_duration_since(since) >= STABLE_FOR {
                        self.last_emitted = None;
                        self.missing_since = None;
                        return WatchAction::EmitDeselection;
                    }
                }
                WatchAction::None
            }
            SelectionRead::Selection(selection) => {
                self.missing_since = None;
                let matches_anchor = self
                    .candidate_anchor
                    .as_ref()
                    .map(|anchor| same_selection_identity(anchor, &selection))
                    .unwrap_or(false);
                let steady_motion = self
                    .last_observed
                    .as_ref()
                    .map(|prev| bounds_step_exceeds(prev, &selection, 0.5))
                    .unwrap_or(false);
                if !matches_anchor || steady_motion {
                    self.candidate_anchor = Some(selection.clone());
                    self.candidate_since = Some(now);
                }
                self.last_observed = Some(selection.clone());

                let already_emitted = self
                    .last_emitted
                    .as_ref()
                    .map(|last| same_selection_identity(last, &selection))
                    .unwrap_or(false);
                let stable = self
                    .candidate_since
                    .map(|since| now.saturating_duration_since(since) >= STABLE_FOR)
                    .unwrap_or(false);
                if stable && !already_emitted {
                    self.last_emitted = Some(selection.clone());
                    WatchAction::EmitSelection(selection)
                } else {
                    WatchAction::None
                }
            }
        }
    }
}

fn bounds_step_exceeds(left: &Selection, right: &Selection, threshold: f64) -> bool {
    match (&left.bounds, &right.bounds) {
        (Some(a), Some(b)) => {
            (a.x - b.x).abs() > threshold
                || (a.y - b.y).abs() > threshold
                || (a.width - b.width).abs() > threshold
                || (a.height - b.height).abs() > threshold
        }
        (None, None) => false,
        _ => true,
    }
}

pub fn same_selection_identity(left: &Selection, right: &Selection) -> bool {
    if left.foreground_process_id != right.foreground_process_id
        || left.element_process_id != right.element_process_id
        || left.text != right.text
    {
        return false;
    }
    match (&left.bounds, &right.bounds) {
        (Some(a), Some(b)) => {
            (a.x - b.x).abs() <= 2.0
                && (a.y - b.y).abs() <= 2.0
                && (a.width - b.width).abs() <= 2.0
                && (a.height - b.height).abs() <= 2.0
        }
        (None, None) => true,
        _ => false,
    }
}

pub fn union_bounds(values: &[f64]) -> Option<Bounds> {
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    let mut found = false;

    for rect in values.chunks_exact(4) {
        let [x, y, width, height] = [rect[0], rect[1], rect[2], rect[3]];
        let right = x + width;
        let bottom = y + height;
        if !x.is_finite()
            || !y.is_finite()
            || !width.is_finite()
            || !height.is_finite()
            || !right.is_finite()
            || !bottom.is_finite()
            || width <= 0.0
            || height <= 0.0
        {
            continue;
        }
        min_x = min_x.min(x);
        min_y = min_y.min(y);
        max_x = max_x.max(right);
        max_y = max_y.max(bottom);
        found = true;
    }

    found.then_some(Bounds {
        x: min_x,
        y: min_y,
        width: max_x - min_x,
        height: max_y - min_y,
    })
}

pub fn sanitize_selection(source: &str) -> Option<String> {
    let trimmed = source.trim();
    if trimmed.chars().count() < 2 {
        return None;
    }
    Some(trimmed.chars().take(MAX_SELECTION_CHARS).collect())
}

pub fn decode_utf16_bounded(units: &[u16], truncated_at_limit: bool) -> String {
    let slice = if truncated_at_limit
        && units
            .last()
            .is_some_and(|code_unit| (0xD800..=0xDBFF).contains(code_unit))
    {
        &units[..units.len() - 1]
    } else {
        units
    };
    String::from_utf16_lossy(slice)
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MonitorWorkArea {
    pub bounds: Bounds,
    pub scale_factor: f64,
}

/// Computes a clamped top-left physical pixel position and physical dimensions
/// on the monitor work area containing the selection anchor (or cursor fallback),
/// supporting negative virtual-screen coordinates and mixed-DPI displays.
pub fn compute_floating_rect(
    logical_w: f64,
    logical_h: f64,
    anchor: Option<Bounds>,
    cursor: Option<(f64, f64)>,
    monitors: &[MonitorWorkArea],
) -> (i32, i32, u32, u32) {
    let rect = anchor.unwrap_or_else(|| {
        let (cx, cy) = cursor.unwrap_or((300.0, 200.0));
        Bounds {
            x: cx,
            y: cy,
            width: 0.0,
            height: 0.0,
        }
    });
    let mid_x = rect.x + rect.width / 2.0;
    let mid_y = rect.y + rect.height / 2.0;

    let target = monitors
        .iter()
        .copied()
        .find(|m| {
            mid_x >= m.bounds.x
                && mid_x <= m.bounds.x + m.bounds.width
                && mid_y >= m.bounds.y
                && mid_y <= m.bounds.y + m.bounds.height
        })
        .or_else(|| monitors.first().copied())
        .unwrap_or(MonitorWorkArea {
            bounds: Bounds {
                x: 0.0,
                y: 0.0,
                width: 1920.0,
                height: 1080.0,
            },
            scale_factor: 1.0,
        });

    let scale = if target.scale_factor.is_finite() && target.scale_factor > 0.0 {
        target.scale_factor
    } else {
        1.0
    };
    let margin = (10.0 * scale).round();
    let max_allowed_w = (target.bounds.width - margin * 2.0).max(1.0);
    let max_allowed_h = (target.bounds.height - margin * 2.0).max(1.0);
    let window_w = (logical_w * scale).min(max_allowed_w);
    let window_h = (logical_h * scale).min(max_allowed_h);

    let min_x = target.bounds.x + margin;
    let max_x = (target.bounds.x + target.bounds.width - margin - window_w).max(min_x);
    let min_y = target.bounds.y + margin;
    let max_y = (target.bounds.y + target.bounds.height - margin - window_h).max(min_y);

    // Windows screen coordinates grow downward: prefer placing just above the
    // selection, falling back below if near the top edge of the work area.
    let gap = 10.0 * scale;
    let above_y = rect.y - window_h - gap;
    let below_y = rect.y + rect.height + gap;
    let preferred_y = if above_y >= min_y { above_y } else { below_y };

    let x = (mid_x - window_w / 2.0).clamp(min_x, max_x);
    let y = preferred_y.clamp(min_y, max_y);
    (
        x.round() as i32,
        y.round() as i32,
        window_w.round().max(1.0) as u32,
        window_h.round().max(1.0) as u32,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamps_floating_position_on_negative_mixed_dpi_secondary_monitor() {
        let monitors = [
            MonitorWorkArea {
                bounds: Bounds {
                    x: 0.0,
                    y: 0.0,
                    width: 1920.0,
                    height: 1040.0,
                },
                scale_factor: 1.5,
            },
            MonitorWorkArea {
                bounds: Bounds {
                    x: -1280.0,
                    y: 0.0,
                    width: 1280.0,
                    height: 984.0,
                },
                scale_factor: 1.0,
            },
        ];
        let (x, y, w, h) = compute_floating_rect(
            310.0,
            46.0,
            Some(Bounds {
                x: -1270.0,
                y: 12.0,
                width: 40.0,
                height: 20.0,
            }),
            None,
            &monitors,
        );
        // Uses secondary monitor's 1.0 scale, clamps x to -1270, drops below selection.
        assert_eq!((x, y, w, h), (-1270, 42, 310, 46));
    }

    #[test]
    fn tracker_ignores_own_process_focus_and_deselects_across_uipi_app_switch() {
        let mut tracker = WatchTracker::new();
        let t0 = Instant::now();
        let sel = Selection {
            foreground_process_id: 10,
            element_process_id: 10,
            text: "hello world".to_owned(),
            bounds: Some(Bounds {
                x: 50.0,
                y: 50.0,
                width: 80.0,
                height: 18.0,
            }),
            cursor: None,
        };
        assert_eq!(
            tracker.observe(SelectionRead::Selection(sel.clone()), t0),
            WatchAction::None
        );
        assert_eq!(
            tracker.observe(
                SelectionRead::Selection(sel.clone()),
                t0 + Duration::from_millis(300)
            ),
            WatchAction::EmitSelection(sel)
        );
        // Focusing Dola Lite's own Result Panel must NEVER emit deselection.
        assert_eq!(
            tracker.observe(SelectionRead::OwnProcess, t0 + Duration::from_millis(400)),
            WatchAction::None
        );
        assert_eq!(
            tracker.observe(SelectionRead::OwnProcess, t0 + Duration::from_millis(900)),
            WatchAction::None
        );
        // Switching to another app (UIPI-blocked PID 99) DOES emit deselection after STABLE_FOR.
        assert_eq!(
            tracker.observe(
                SelectionRead::TransientError {
                    foreground_process_id: Some(99),
                },
                t0 + Duration::from_millis(1000)
            ),
            WatchAction::None
        );
        assert_eq!(
            tracker.observe(
                SelectionRead::TransientError {
                    foreground_process_id: Some(99),
                },
                t0 + Duration::from_millis(1300)
            ),
            WatchAction::EmitDeselection
        );
    }
}
