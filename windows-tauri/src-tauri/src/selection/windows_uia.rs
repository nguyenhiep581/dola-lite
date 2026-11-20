use super::{
    clean_selection_rects, decode_utf16_bounded, sanitize_selection, union_of_bounds, Selection,
    SelectionRead, WatchAction, WatchTracker, MAX_SELECTION_CHARS,
};
use std::ffi::c_void;
use std::mem::size_of;
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};
use windows::core::*;
use windows::Win32::Foundation::{E_NOINTERFACE, E_NOTIMPL, HWND, POINT, RECT, S_OK};
use windows::Win32::System::Com::*;
use windows::Win32::System::Ole::*;
use windows::Win32::System::Variant::*;
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};
use windows::Win32::UI::WindowsAndMessaging::{
    GetAncestor, GetCursorPos, GetForegroundWindow, GetWindowRect, GetWindowThreadProcessId,
    IsWindowVisible, WindowFromPoint, GA_ROOT,
};

const POLL_INTERVAL: Duration = Duration::from_millis(200);
const POLL_BUDGET: Duration = Duration::from_millis(150);
const CURSOR_ACTIVE_WINDOW: Duration = Duration::from_millis(750);
const MAX_RANGE_COUNT: i32 = 32;
const MAX_RECT_VALUES: usize = 16_000;
const MAX_ANCESTOR_HOPS: usize = 24;
const TEXT_READ_LIMIT: i32 = (MAX_SELECTION_CHARS * 2 + 2) as i32;
const UIA_E_NOTSUPPORTED_CODE: u32 = 0x8004_0204;

struct ComApartment;

impl ComApartment {
    fn initialize() -> Result<Self> {
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok()? };
        Ok(Self)
    }
}

impl Drop for ComApartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}

struct SafeArrayGuard(*mut SAFEARRAY);
impl Drop for SafeArrayGuard {
    fn drop(&mut self) {
        if !self.0.is_null() {
            let _ = unsafe { SafeArrayDestroy(self.0) };
        }
    }
}

struct SafeArrayAccessGuard(*mut SAFEARRAY);
impl Drop for SafeArrayAccessGuard {
    fn drop(&mut self) {
        if !self.0.is_null() {
            let _ = unsafe { SafeArrayUnaccessData(self.0) };
        }
    }
}

enum ElementProbe {
    Found {
        selection: Selection,
        provider: IUIAutomationElement,
    },
    NoSelection,
    Password,
    Transient,
}

struct CachedProvider {
    foreground_hwnd: isize,
    foreground_pid: u32,
    element: IUIAutomationElement,
}

struct InputActivityState {
    last_point: Option<POINT>,
    last_input_tick: Option<u32>,
    last_active_at: Option<Instant>,
}

impl InputActivityState {
    fn new() -> Self {
        Self {
            last_point: None,
            last_input_tick: None,
            last_active_at: None,
        }
    }

    fn update(&mut self, pt: Option<POINT>, now: Instant) -> bool {
        let mut changed = false;
        if let Some(pt) = pt {
            let moved = self
                .last_point
                .map(|prev| prev.x != pt.x || prev.y != pt.y)
                .unwrap_or(true);
            if moved {
                self.last_point = Some(pt);
                changed = true;
            }
        }
        let mut lii = LASTINPUTINFO {
            cbSize: size_of::<LASTINPUTINFO>() as u32,
            dwTime: 0,
        };
        if unsafe { GetLastInputInfo(&mut lii) }.as_bool() {
            if self.last_input_tick != Some(lii.dwTime) {
                self.last_input_tick = Some(lii.dwTime);
                changed = true;
            }
        }
        if changed {
            self.last_active_at = Some(now);
            return true;
        }
        self.last_active_at
            .is_some_and(|t| now.saturating_duration_since(t) <= CURSOR_ACTIVE_WINDOW)
    }
}

fn build_cache_request(automation: &IUIAutomation) -> Option<IUIAutomationCacheRequest> {
    let req = unsafe { automation.CreateCacheRequest() }.ok()?;
    unsafe {
        let _ = req.AddProperty(UIA_ProcessIdPropertyId);
        let _ = req.AddProperty(UIA_IsPasswordPropertyId);
        let _ = req.AddProperty(UIA_IsTextPatternAvailablePropertyId);
        let _ = req.AddProperty(UIA_IsTextPattern2AvailablePropertyId);
        let _ = req.AddPattern(UIA_TextPatternId);
        let _ = req.AddPattern(UIA_TextChildPatternId);
    }
    Some(req)
}

pub fn spawn_selection_worker<F>(
    stop: Arc<AtomicBool>,
    pill_hwnd: isize,
    result_hwnd: isize,
    mut on_action: F,
) where
    F: FnMut(WatchAction) + Send + 'static,
{
    thread::Builder::new()
        .name("dola-uia-watcher".to_owned())
        .spawn(move || {
            let _ = unsafe {
                SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
            };
            let Ok(_com) = ComApartment::initialize() else {
                return;
            };
            let Ok(automation) = (unsafe {
                CoCreateInstance::<_, IUIAutomation2>(&CUIAutomation8, None, CLSCTX_INPROC_SERVER)
            }) else {
                return;
            };
            let _ = unsafe { automation.SetConnectionTimeout(500) };
            let _ = unsafe { automation.SetTransactionTimeout(500) };
            let _ = unsafe { automation.SetAutoSetFocus(false) };
            let walker = unsafe { automation.ControlViewWalker() }.ok();
            let cache_req = build_cache_request(&automation);

            let mut tracker = WatchTracker::new();
            let mut last_provider: Option<CachedProvider> = None;
            let mut input_activity = InputActivityState::new();
            while !stop.load(Ordering::Relaxed) {
                let now = Instant::now();
                let read = read_foreground_selection(
                    &automation,
                    walker.as_ref(),
                    cache_req.as_ref(),
                    pill_hwnd,
                    result_hwnd,
                    &mut last_provider,
                    &mut input_activity,
                    now,
                );
                let action = tracker.observe(read, Instant::now());
                if !matches!(action, WatchAction::None) {
                    on_action(action);
                }
                thread::sleep(POLL_INTERVAL);
            }
        })
        .ok();
}

fn is_unsupported_pattern_error(error: &Error) -> bool {
    let code = error.code();
    code == S_OK || code == E_NOINTERFACE || code.0 as u32 == UIA_E_NOTSUPPORTED_CODE
}

fn is_no_selection_error(error: &Error) -> bool {
    let code = error.code();
    code == S_OK || code == E_NOTIMPL || code.0 as u32 == UIA_E_NOTSUPPORTED_CODE
}

fn current_cursor_point() -> Option<POINT> {
    let mut pt = POINT::default();
    unsafe { GetCursorPos(&mut pt) }.ok().map(|()| pt)
}

fn point_inside_hwnd(hwnd: HWND, pt: POINT) -> bool {
    let mut rect = RECT::default();
    unsafe { GetWindowRect(hwnd, &mut rect) }.is_ok()
        && pt.x >= rect.left
        && pt.x < rect.right
        && pt.y >= rect.top
        && pt.y < rect.bottom
}

fn point_belongs_to_foreground(foreground: HWND, pt: POINT) -> bool {
    if !point_inside_hwnd(foreground, pt) {
        return false;
    }
    let hit_hwnd = unsafe { WindowFromPoint(pt) };
    if hit_hwnd == HWND::default() {
        return false;
    }
    hit_hwnd == foreground || unsafe { GetAncestor(hit_hwnd, GA_ROOT) } == foreground
}

fn cursor_over_own_floating_window(pt: POINT, pill_hwnd: isize, result_hwnd: isize) -> bool {
    for raw in [pill_hwnd, result_hwnd] {
        if raw != 0 {
            let hwnd = HWND(raw as _);
            if unsafe { IsWindowVisible(hwnd).as_bool() } && point_inside_hwnd(hwnd, pt) {
                return true;
            }
        }
    }
    false
}

#[allow(clippy::too_many_arguments)]
fn read_foreground_selection(
    automation: &IUIAutomation,
    walker: Option<&IUIAutomationTreeWalker>,
    cache_req: Option<&IUIAutomationCacheRequest>,
    pill_hwnd: isize,
    result_hwnd: isize,
    last_provider: &mut Option<CachedProvider>,
    input_activity: &mut InputActivityState,
    now: Instant,
) -> SelectionRead {
    let deadline = now + POLL_BUDGET;
    let foreground = unsafe { GetForegroundWindow() };
    if foreground == HWND::default() {
        *last_provider = None;
        return SelectionRead::NoSelection;
    }

    let mut foreground_pid = 0_u32;
    unsafe { GetWindowThreadProcessId(foreground, Some(&mut foreground_pid)) };
    if foreground_pid == 0 {
        *last_provider = None;
        return SelectionRead::NoSelection;
    }
    let own_pid = std::process::id();
    if foreground_pid == own_pid {
        return SelectionRead::OwnProcess;
    }

    let fg_hwnd = foreground.0 as isize;
    if last_provider
        .as_ref()
        .is_some_and(|c| c.foreground_hwnd != fg_hwnd || c.foreground_pid != foreground_pid)
    {
        *last_provider = None;
    }

    let cursor_pt = current_cursor_point();
    if let Some(pt) = cursor_pt {
        // When the user moves the cursor onto our non-activating Pill or Result
        // panel (e.g. after selecting in an Edge PDF or Jira frame), preserve the
        // current selection instead of emitting deselection under their cursor.
        if cursor_over_own_floating_window(pt, pill_hwnd, result_hwnd) {
            return SelectionRead::OwnProcess;
        }
    }
    let input_recently_active = input_activity.update(cursor_pt, now);
    let cursor = cursor_pt.map(|pt| (pt.x as f64, pt.y as f64));

    let transient = || SelectionRead::TransientError {
        foreground_process_id: Some(foreground_pid),
    };

    // Probe 1: Focused element + TextChildPattern + ControlView ancestor chain.
    // Handles standard controls AND complex React SPAs (Jira, Confluence, Notion)
    // where keyboard focus lands on a child Group/Button/Link inside a Document.
    let focused_result = match cache_req {
        Some(req) => unsafe { automation.GetFocusedElementBuildCache(req) },
        None => unsafe { automation.GetFocusedElement() },
    };
    match focused_result {
        Ok(focused) => {
            let pid_res = if cache_req.is_some() {
                unsafe { focused.CachedProcessId() }
            } else {
                unsafe { focused.CurrentProcessId() }
            };
            match pid_res {
                Ok(pid) if pid as u32 == own_pid => return SelectionRead::OwnProcess,
                Ok(pid) if pid > 0 => {
                    match probe_element_chain(
                        &focused,
                        pid as u32,
                        walker,
                        cache_req,
                        foreground_pid,
                        own_pid,
                        cursor,
                        deadline,
                    ) {
                        ElementProbe::Found {
                            selection,
                            provider,
                        } => {
                            *last_provider = Some(CachedProvider {
                                foreground_hwnd: fg_hwnd,
                                foreground_pid,
                                element: provider,
                            });
                            return SelectionRead::Selection(selection);
                        }
                        ElementProbe::Password => {
                            *last_provider = None;
                            return SelectionRead::NoSelection;
                        }
                        // Bail immediately on transient error (prevents timeout
                        // amplification on hung apps and password fail-open).
                        ElementProbe::Transient => return transient(),
                        ElementProbe::NoSelection => {}
                    }
                }
                Ok(_) => {}
                Err(_) => return transient(),
            }
        }
        Err(err) if err.code() == S_OK => {}
        Err(_) => return transient(),
    }

    if Instant::now() >= deadline {
        return transient();
    }

    // Probe 2: Element under the mouse cursor + TextChildPattern + ancestor chain.
    // Runs whenever any mouse/keyboard input occurred within 750ms (catching mouse
    // drags AND stationary double/triple-clicks in Edge PDF / unfocused Jira frames),
    // while avoiding idle ElementFromPoint RPCs when stationary (Probe 3 serves any
    // active cached provider directly).
    if input_recently_active {
        if let Some(pt) = cursor_pt {
            if point_belongs_to_foreground(foreground, pt) {
                let hit_result = match cache_req {
                    Some(req) => unsafe { automation.ElementFromPointBuildCache(pt, req) },
                    None => unsafe { automation.ElementFromPoint(pt) },
                };
                match hit_result {
                    Ok(hit) => {
                        let pid_res = if cache_req.is_some() {
                            unsafe { hit.CachedProcessId() }
                        } else {
                            unsafe { hit.CurrentProcessId() }
                        };
                        match pid_res {
                            Ok(pid) if pid as u32 == own_pid => return SelectionRead::OwnProcess,
                            Ok(pid) if pid > 0 => {
                                match probe_element_chain(
                                    &hit,
                                    pid as u32,
                                    walker,
                                    cache_req,
                                    foreground_pid,
                                    own_pid,
                                    cursor,
                                    deadline,
                                ) {
                                    ElementProbe::Found {
                                        selection,
                                        provider,
                                    } => {
                                        *last_provider = Some(CachedProvider {
                                            foreground_hwnd: fg_hwnd,
                                            foreground_pid,
                                            element: provider,
                                        });
                                        return SelectionRead::Selection(selection);
                                    }
                                    ElementProbe::Password => {
                                        *last_provider = None;
                                        return SelectionRead::NoSelection;
                                    }
                                    ElementProbe::Transient => return transient(),
                                    ElementProbe::NoSelection => {}
                                }
                            }
                            Ok(_) => {}
                            Err(_) => return transient(),
                        }
                    }
                    Err(err) if err.code() == S_OK => {}
                    Err(_) => return transient(),
                }
            }
        }
    }

    if Instant::now() >= deadline {
        return transient();
    }

    // Probe 3: Cached TextPattern provider scoped to the exact same top-level HWND.
    // Keeps an Edge PDF / Jira iframe selection stable even after the mouse stops
    // moving or moves away from the text without clearing the selection.
    if let Some(cached) = last_provider.as_ref() {
        match read_selection_from_element(
            &cached.element,
            None,
            false,
            foreground_pid,
            own_pid,
            cursor,
        ) {
            ElementProbe::Found { selection, .. } => {
                return SelectionRead::Selection(selection);
            }
            ElementProbe::Password | ElementProbe::NoSelection => {
                *last_provider = None;
                return SelectionRead::NoSelection;
            }
            ElementProbe::Transient => {
                *last_provider = None;
                return transient();
            }
        }
    }

    SelectionRead::NoSelection
}

#[allow(clippy::too_many_arguments)]
fn probe_element_chain(
    start: &IUIAutomationElement,
    start_pid: u32,
    walker: Option<&IUIAutomationTreeWalker>,
    cache_req: Option<&IUIAutomationCacheRequest>,
    foreground_pid: u32,
    own_pid: u32,
    cursor: Option<(f64, f64)>,
    deadline: Instant,
) -> ElementProbe {
    let use_cache = cache_req.is_some();

    match read_selection_from_element(
        start,
        Some(start_pid),
        use_cache,
        foreground_pid,
        own_pid,
        cursor,
    ) {
        ElementProbe::Found {
            selection,
            provider,
        } => {
            return ElementProbe::Found {
                selection,
                provider,
            };
        }
        ElementProbe::Password => return ElementProbe::Password,
        // Fail closed on Transient so password-check failures never fall through
        // to non-password ancestors and hung apps cannot amplify timeouts.
        ElementProbe::Transient => return ElementProbe::Transient,
        ElementProbe::NoSelection => {}
    }

    if Instant::now() >= deadline {
        return ElementProbe::Transient;
    }

    // Chromium/Edge leaf text nodes frequently expose TextChildPattern pointing
    // straight to the enclosing Document / Edit TextPattern container.
    let child_pattern_res = if use_cache {
        unsafe { start.GetCachedPatternAs::<IUIAutomationTextChildPattern>(UIA_TextChildPatternId) }
    } else {
        unsafe {
            start.GetCurrentPatternAs::<IUIAutomationTextChildPattern>(UIA_TextChildPatternId)
        }
    };
    if let Ok(child_pattern) = child_pattern_res {
        if let Ok(container) = unsafe { child_pattern.TextContainer() } {
            match read_selection_from_element(
                &container,
                None,
                false,
                foreground_pid,
                own_pid,
                cursor,
            ) {
                ElementProbe::Found {
                    selection,
                    provider,
                } => {
                    return ElementProbe::Found {
                        selection,
                        provider,
                    };
                }
                ElementProbe::Password => return ElementProbe::Password,
                ElementProbe::Transient => return ElementProbe::Transient,
                ElementProbe::NoSelection => {}
            }
        }
    }

    let Some(walker) = walker else {
        return ElementProbe::NoSelection;
    };

    let mut current = start.clone();
    for _ in 0..MAX_ANCESTOR_HOPS {
        if Instant::now() >= deadline {
            return ElementProbe::Transient;
        }
        let parent = match cache_req {
            Some(req) => unsafe { walker.GetParentElementBuildCache(&current, req) },
            None => unsafe { walker.GetParentElement(&current) },
        };
        let parent = match parent {
            Ok(p) => p,
            Err(_) => break,
        };
        let parent_pid = if use_cache {
            unsafe { parent.CachedProcessId() }
        } else {
            unsafe { parent.CurrentProcessId() }
        };
        let parent_pid = match parent_pid {
            Ok(pid) if pid > 0 => pid as u32,
            _ => break,
        };
        let same_host = parent_pid == foreground_pid || parent_pid == start_pid;
        if !same_host || parent_pid == own_pid {
            break;
        }
        match read_selection_from_element(
            &parent,
            Some(parent_pid),
            use_cache,
            foreground_pid,
            own_pid,
            cursor,
        ) {
            ElementProbe::Found {
                selection,
                provider,
            } => {
                return ElementProbe::Found {
                    selection,
                    provider,
                };
            }
            ElementProbe::Password => return ElementProbe::Password,
            ElementProbe::Transient => return ElementProbe::Transient,
            ElementProbe::NoSelection => {}
        }
        current = parent;
    }

    ElementProbe::NoSelection
}

fn read_selection_from_element(
    element: &IUIAutomationElement,
    known_pid: Option<u32>,
    use_cache: bool,
    foreground_pid: u32,
    own_pid: u32,
    cursor: Option<(f64, f64)>,
) -> ElementProbe {
    let element_pid = match known_pid {
        Some(pid) => pid,
        None => match if use_cache {
            unsafe { element.CachedProcessId() }
        } else {
            unsafe { element.CurrentProcessId() }
        } {
            Ok(pid) if pid > 0 => pid as u32,
            Ok(_) => return ElementProbe::NoSelection,
            Err(_) => return ElementProbe::Transient,
        },
    };
    if element_pid == own_pid {
        return ElementProbe::NoSelection;
    }

    let is_pw_res = if use_cache {
        unsafe { element.CachedIsPassword() }
    } else {
        unsafe { element.CurrentIsPassword() }
    };
    match is_pw_res {
        Ok(is_pw) if is_pw.as_bool() => return ElementProbe::Password,
        Ok(_) => {}
        Err(_) => return ElementProbe::Transient,
    }

    // Fast cached skip when neither TextPattern nor TextPattern2 is available
    // (avoids redundant cross-process pattern queries on non-text DOM nodes).
    let mut try_text2 = false;
    if use_cache {
        let has_text1 = unsafe {
            element.GetCachedPropertyValue(UIA_IsTextPatternAvailablePropertyId)
        }
        .ok()
        .is_none_or(|v| v.vt() != VT_BOOL || !matches!(bool::try_from(&v), Ok(false)));
        let has_text2 = unsafe {
            element.GetCachedPropertyValue(UIA_IsTextPattern2AvailablePropertyId)
        }
        .ok()
        .is_some_and(|v| v.vt() == VT_BOOL && matches!(bool::try_from(&v), Ok(true)));
        if !has_text1 && !has_text2 {
            return ElementProbe::NoSelection;
        }
        try_text2 = has_text2;
    }

    let text_pattern_res = if use_cache {
        unsafe { element.GetCachedPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId) }
    } else {
        unsafe { element.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId) }
    };

    let text_pattern = match text_pattern_res {
        Ok(pattern) => pattern,
        Err(err) if is_unsupported_pattern_error(&err) => {
            if !use_cache || try_text2 {
                match unsafe {
                    element.GetCurrentPatternAs::<IUIAutomationTextPattern2>(UIA_TextPattern2Id)
                } {
                    Ok(p2) => p2.into(),
                    Err(err2) if is_unsupported_pattern_error(&err2) => {
                        return ElementProbe::NoSelection;
                    }
                    Err(_) => return ElementProbe::Transient,
                }
            } else {
                return ElementProbe::NoSelection;
            }
        }
        Err(_) => return ElementProbe::Transient,
    };

    let ranges = match unsafe { text_pattern.GetSelection() } {
        Ok(ranges) => ranges,
        Err(err) if is_no_selection_error(&err) => return ElementProbe::NoSelection,
        Err(_) => return ElementProbe::Transient,
    };

    let range_count = match unsafe { ranges.Length() } {
        Ok(count) => count,
        Err(_) => return ElementProbe::Transient,
    };
    if range_count <= 0 {
        return ElementProbe::NoSelection;
    }

    let mut selected_parts = Vec::new();
    let mut collected_chars = 0_usize;
    let mut rectangles = Vec::new();
    for index in 0..range_count.min(MAX_RANGE_COUNT) {
        if collected_chars >= MAX_SELECTION_CHARS {
            break;
        }
        let range = match unsafe { ranges.GetElement(index) } {
            Ok(range) => range,
            Err(_) => return ElementProbe::Transient,
        };
        let part = match unsafe { range.GetText(TEXT_READ_LIMIT) } {
            Ok(text) => decode_utf16_bounded(&text, text.len() >= TEXT_READ_LIMIT as usize),
            Err(_) => return ElementProbe::Transient,
        };
        if part.trim().is_empty() {
            continue;
        }
        collected_chars = collected_chars.saturating_add(part.chars().count());
        selected_parts.push(part);

        if let Ok(Some(values)) = unsafe { read_rectangles(&range) } {
            rectangles.extend(values);
        }
    }

    let Some(text) = sanitize_selection(&selected_parts.join("\n")) else {
        return ElementProbe::NoSelection;
    };

    let rects = clean_selection_rects(&rectangles);
    let bounds = union_of_bounds(&rects);

    ElementProbe::Found {
        selection: Selection {
            foreground_process_id: foreground_pid,
            element_process_id: element_pid,
            text,
            bounds,
            rects,
            cursor,
        },
        provider: element.clone(),
    }
}

unsafe fn read_rectangles(range: &IUIAutomationTextRange) -> Result<Option<Vec<f64>>> {
    let raw = range.GetBoundingRectangles()?;
    if raw.is_null() {
        return Ok(None);
    }
    let _array = SafeArrayGuard(raw);

    if SafeArrayGetDim(raw) != 1
        || SafeArrayGetElemsize(raw) as usize != size_of::<f64>()
        || SafeArrayGetVartype(raw)? != VT_R8
    {
        return Ok(None);
    }
    let lower = SafeArrayGetLBound(raw, 1)?;
    let upper = SafeArrayGetUBound(raw, 1)?;
    let count = upper.saturating_sub(lower).saturating_add(1);
    if count <= 0 || count as usize > MAX_RECT_VALUES || count % 4 != 0 {
        return Ok(None);
    }

    let mut data: *mut c_void = ptr::null_mut();
    SafeArrayAccessData(raw, &mut data)?;
    let _access = SafeArrayAccessGuard(raw);
    if data.is_null() {
        return Ok(None);
    }

    let len = count as usize;
    let ptr = data.cast::<f64>();
    let mut copied = Vec::with_capacity(len);
    for index in 0..len {
        copied.push(ptr::read_unaligned(ptr.add(index)));
    }
    Ok(Some(copied))
}
