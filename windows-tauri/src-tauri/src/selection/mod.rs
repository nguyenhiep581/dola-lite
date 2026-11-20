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
    /// Cursor-independent bounding box used by `WatchTracker` for selection
    /// identity and drag stability.
    pub bounds: Option<Bounds>,
    /// Cleaned per-range bounding rectangles (filtered for NaN/degenerate/origin
    /// outliers) used once at Pill placement time to filter off-monitor `sr-only`
    /// spans without polluting `WatchTracker` stability.
    pub rects: Vec<Bounds>,
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

const MAX_STORED_RECTS: usize = 512;

/// Parses and cleans raw `[x, y, width, height, ...]` values from UIA
/// `GetBoundingRectangles()`, dropping non-finite/non-positive rects, extreme
/// CSS `sr-only` coordinates (`<-8000` / `>32000`), and degenerate `(0, 0)`
/// origin spans emitted by Chromium/GitHub whenever real rects exist.
pub fn clean_selection_rects(values: &[f64]) -> Vec<Bounds> {
    let mut rects = Vec::new();
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
            || x < -8_000.0
            || y < -8_000.0
            || x > 32_000.0
            || y > 32_000.0
        {
            continue;
        }
        rects.push(Bounds {
            x,
            y,
            width,
            height,
        });
    }
    if rects.is_empty() {
        return rects;
    }
    let has_non_origin = rects.iter().any(|r| r.x.abs() > 1.0 || r.y.abs() > 1.0);
    if has_non_origin {
        rects.retain(|r| r.x.abs() > 1.0 || r.y.abs() > 1.0);
    }
    if rects.len() > MAX_STORED_RECTS {
        // Keep the first half and tail rects so both the start and cursor-end
        // of large multi-token syntax-highlighted selections remain represented.
        let head = MAX_STORED_RECTS / 2;
        let tail_start = rects.len() - (MAX_STORED_RECTS - head);
        let mut trimmed = Vec::with_capacity(MAX_STORED_RECTS);
        trimmed.extend_from_slice(&rects[..head]);
        trimmed.extend_from_slice(&rects[tail_start..]);
        return trimmed;
    }
    rects
}

pub fn union_of_bounds(rects: &[Bounds]) -> Option<Bounds> {
    if rects.is_empty() {
        return None;
    }
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for r in rects {
        min_x = min_x.min(r.x);
        min_y = min_y.min(r.y);
        max_x = max_x.max(r.x + r.width);
        max_y = max_y.max(r.y + r.height);
    }
    Some(Bounds {
        x: min_x,
        y: min_y,
        width: max_x - min_x,
        height: max_y - min_y,
    })
}

/// Cursor-independent union of cleaned UIA bounding rectangles.
pub fn union_bounds(values: &[f64]) -> Option<Bounds> {
    union_of_bounds(&clean_selection_rects(values))
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

fn bounds_intersects_any_monitor(rect: Bounds, monitors: &[MonitorWorkArea]) -> bool {
    if monitors.is_empty() {
        return true;
    }
    monitors.iter().any(|m| {
        let right = rect.x + rect.width.max(1.0);
        let bottom = rect.y + rect.height.max(1.0);
        let m_right = m.bounds.x + m.bounds.width;
        let m_bottom = m.bounds.y + m.bounds.height;
        rect.x < m_right && right > m.bounds.x && rect.y < m_bottom && bottom > m.bounds.y
    })
}

fn target_monitor_for_point(x: f64, y: f64, monitors: &[MonitorWorkArea]) -> MonitorWorkArea {
    monitors
        .iter()
        .copied()
        .find(|m| {
            x >= m.bounds.x
                && x <= m.bounds.x + m.bounds.width
                && y >= m.bounds.y
                && y <= m.bounds.y + m.bounds.height
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
        })
}

/// Computes a clamped top-left physical pixel position and physical dimensions
/// for the Pill popover from per-range selection rectangles, filtering out
/// off-monitor rects (such as CSS `sr-only` / scrolled-out spans) per rect and
/// collapsing oversized multi-paragraph / ultra-wide selections toward the
/// cursor ONCE at placement time (without affecting `WatchTracker` stability).
pub fn compute_floating_rect_from_rects(
    logical_w: f64,
    logical_h: f64,
    rects: &[Bounds],
    fallback_anchor: Option<Bounds>,
    cursor: Option<(f64, f64)>,
    monitors: &[MonitorWorkArea],
) -> (i32, i32, u32, u32) {
    let in_monitor: Vec<Bounds> = rects
        .iter()
        .copied()
        .filter(|r| bounds_intersects_any_monitor(*r, monitors))
        .collect();
    let base_anchor = union_of_bounds(&in_monitor)
        .or_else(|| fallback_anchor.filter(|b| bounds_intersects_any_monitor(*b, monitors)));

    let placed_anchor = match (base_anchor, cursor) {
        (Some(u), Some((cx, cy))) => {
            let mid_x = u.x + u.width / 2.0;
            let mid_y = u.y + u.height / 2.0;
            let target = target_monitor_for_point(mid_x, mid_y, monitors);
            let scale = if target.scale_factor.is_finite() && target.scale_factor > 0.0 {
                target.scale_factor
            } else {
                1.0
            };
            let clamped_x = cx.clamp(u.x, u.x + u.width);
            let clamped_y = cy.clamp(u.y, u.y + u.height);
            let dist = ((cx - clamped_x).powi(2) + (cy - clamped_y).powi(2)).sqrt();
            // For tall multi-line or overly wide selections where the user just
            // dragged with the mouse nearby, anchor cleanly right at the cursor.
            // Keep `u` intact for keyboard selections when the cursor is far away.
            if (u.height > 220.0 * scale || u.width > 600.0 * scale) && dist <= 140.0 * scale {
                Some(Bounds {
                    x: cx,
                    y: cy - 12.0 * scale,
                    width: 1.0,
                    height: 24.0 * scale,
                })
            } else {
                Some(u)
            }
        }
        (other, _) => other,
    };

    compute_floating_rect(logical_w, logical_h, placed_anchor, cursor, monitors)
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
    let valid_anchor = anchor.filter(|b| bounds_intersects_any_monitor(*b, monitors));
    let rect = valid_anchor.unwrap_or_else(|| {
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

    let target = target_monitor_for_point(mid_x, mid_y, monitors);

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

/// Opens the Result Panel cleanly in-place anchored directly to the Pill's
/// physical rectangle (centered horizontally on the Pill, top-aligned with the
/// Pill's top edge, clamped cleanly inside the target monitor's work area).
/// This prevents the tall Result Panel from jumping to the opposite side of a
/// multi-line selection or flying to arbitrary coordinates.
pub fn compute_result_rect(
    logical_w: f64,
    logical_h: f64,
    anchor_rect: Option<Bounds>,
    cursor: Option<(f64, f64)>,
    monitors: &[MonitorWorkArea],
) -> (i32, i32, u32, u32) {
    let valid_anchor = anchor_rect.filter(|b| bounds_intersects_any_monitor(*b, monitors));
    let (anchor_mid_x, anchor_top_y, anchor_mid_y) = match valid_anchor {
        Some(rect) => (rect.x + rect.width / 2.0, rect.y, rect.y + rect.height / 2.0),
        None => {
            let (cx, cy) = cursor.unwrap_or((300.0, 200.0));
            (cx, cy, cy)
        }
    };

    let target = target_monitor_for_point(anchor_mid_x, anchor_mid_y, monitors);
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

    let x = (anchor_mid_x - window_w / 2.0).clamp(min_x, max_x);
    let y = anchor_top_y.clamp(min_y, max_y);
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
            rects: vec![],
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

    #[test]
    fn filters_chromium_origin_and_sr_only_outliers_without_polluting_tracker() {
        let monitors = [MonitorWorkArea {
            bounds: Bounds {
                x: 0.0,
                y: 0.0,
                width: 1920.0,
                height: 1040.0,
            },
            scale_factor: 1.0,
        }];
        // Real selection at (500, 400) polluted by a (0, 0) span AND a CSS sr-only (-9999, 400) span.
        let polluted = [
            0.0, 0.0, 12.0, 18.0, -9999.0, 400.0, 10.0, 18.0, 500.0, 400.0, 220.0, 20.0,
        ];
        let rects = clean_selection_rects(&polluted);
        assert_eq!(
            rects,
            vec![Bounds {
                x: 500.0,
                y: 400.0,
                width: 220.0,
                height: 20.0,
            }]
        );
        // Bounds are strictly cursor-independent (safe for WatchTracker).
        assert_eq!(union_bounds(&polluted), Some(rects[0]));

        // Even an off-monitor rect at x = -2000 (not dropped by -8000 cutoff) is filtered
        // per-rect against monitors before Pill placement, never flinging the Pill left.
        let with_off_monitor = vec![
            Bounds {
                x: -2000.0,
                y: 400.0,
                width: 10.0,
                height: 18.0,
            },
            Bounds {
                x: 500.0,
                y: 400.0,
                width: 220.0,
                height: 20.0,
            },
        ];
        let (px, py, pw, ph) = compute_floating_rect_from_rects(
            336.0,
            68.0,
            &with_off_monitor,
            None,
            Some((680.0, 410.0)),
            &monitors,
        );
        assert_eq!((px, py, pw, ph), (442, 322, 336, 68));

        // Tall 500px selection collapses near the cursor ONLY at Pill placement time.
        let tall = vec![Bounds {
            x: 400.0,
            y: 100.0,
            width: 300.0,
            height: 500.0,
        }];
        let (tx, ty, _, _) = compute_floating_rect_from_rects(
            336.0,
            68.0,
            &tall,
            None,
            Some((620.0, 580.0)),
            &monitors,
        );
        // Anchored near cursor (620, 568) rather than y=100: mid_x=620.5 -> x=453, y=568-68-10=490.
        assert_eq!((tx, ty), (453, 490));

        // Keyboard selection with unrelated faraway cursor preserves valid on-screen bounds!
        let single_line = vec![Bounds {
            x: 500.0,
            y: 400.0,
            width: 220.0,
            height: 20.0,
        }];
        let (kx, ky, _, _) = compute_floating_rect_from_rects(
            336.0,
            68.0,
            &single_line,
            None,
            Some((1800.0, 950.0)),
            &monitors,
        );
        assert_eq!((kx, ky), (442, 322));
    }

    #[test]
    fn result_rect_opens_in_place_at_pill_location_and_clamps_smoothly() {
        let monitors = [MonitorWorkArea {
            bounds: Bounds {
                x: 0.0,
                y: 0.0,
                width: 1920.0,
                height: 1040.0,
            },
            scale_factor: 1.0,
        }];
        let pill = Bounds {
            x: 600.0,
            y: 300.0,
            width: 336.0,
            height: 68.0,
        };
        let (x, y, w, h) = compute_result_rect(400.0, 360.0, Some(pill), None, &monitors);
        // Centered on pill (mid_x = 768 -> x = 568), top-aligned at y = 300.
        assert_eq!((x, y, w, h), (568, 300, 400, 360));

        // Near bottom edge: slides up only enough to stay above taskbar, keeping same x.
        let low_pill = Bounds {
            x: 600.0,
            y: 920.0,
            width: 336.0,
            height: 68.0,
        };
        let (lx, ly, lw, lh) = compute_result_rect(400.0, 360.0, Some(low_pill), None, &monitors);
        assert_eq!((lx, ly, lw, lh), (568, 670, 400, 360));
    }
}
