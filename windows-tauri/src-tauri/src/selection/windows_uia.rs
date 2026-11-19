use super::{
    decode_utf16_bounded, sanitize_selection, union_bounds, Selection, SelectionRead, WatchAction,
    WatchTracker, MAX_SELECTION_CHARS,
};
use std::ffi::c_void;
use std::mem::size_of;
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};
use windows::core::*;
use windows::Win32::Foundation::{E_NOINTERFACE, E_NOTIMPL, HWND, POINT, S_OK};
use windows::Win32::System::Com::*;
use windows::Win32::System::Ole::*;
use windows::Win32::System::Variant::*;
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetCursorPos, GetForegroundWindow, GetWindowThreadProcessId,
};

const POLL_INTERVAL: Duration = Duration::from_millis(200);
const MAX_RANGE_COUNT: i32 = 32;
const MAX_RECT_VALUES: usize = 16_000;
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

pub fn spawn_selection_worker<F>(stop: Arc<AtomicBool>, mut on_action: F)
where
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

            let mut tracker = WatchTracker::new();
            while !stop.load(Ordering::Relaxed) {
                let read = read_foreground_selection(&automation);
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

fn current_cursor() -> Option<(f64, f64)> {
    let mut pt = POINT::default();
    unsafe { GetCursorPos(&mut pt) }
        .ok()
        .map(|()| (pt.x as f64, pt.y as f64))
}

fn read_foreground_selection(automation: &IUIAutomation) -> SelectionRead {
    let foreground = unsafe { GetForegroundWindow() };
    if foreground == HWND::default() {
        return SelectionRead::NoSelection;
    }

    let mut foreground_pid = 0_u32;
    unsafe { GetWindowThreadProcessId(foreground, Some(&mut foreground_pid)) };
    if foreground_pid == 0 {
        return SelectionRead::NoSelection;
    }
    if foreground_pid == std::process::id() {
        return SelectionRead::OwnProcess;
    }

    let transient = || SelectionRead::TransientError {
        foreground_process_id: Some(foreground_pid),
    };

    let focused = match unsafe { automation.GetFocusedElement() } {
        Ok(el) => el,
        Err(err) if err.code() == S_OK => return SelectionRead::NoSelection,
        Err(_) => return transient(),
    };

    let focused_pid = match unsafe { focused.CurrentProcessId() } {
        Ok(pid) if pid > 0 => pid as u32,
        Ok(_) => return SelectionRead::NoSelection,
        Err(_) => return transient(),
    };
    if focused_pid == std::process::id() {
        return SelectionRead::OwnProcess;
    }

    match unsafe { focused.CurrentIsPassword() } {
        Ok(is_pw) if is_pw.as_bool() => return SelectionRead::NoSelection,
        Ok(_) => {}
        Err(_) => return transient(),
    }

    if let Ok(available) =
        unsafe { focused.GetCurrentPropertyValue(UIA_IsTextPatternAvailablePropertyId) }
    {
        if available.vt() == VT_BOOL && matches!(bool::try_from(&available), Ok(false)) {
            return SelectionRead::NoSelection;
        }
    }

    let text_pattern = match unsafe {
        focused.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)
    } {
        Ok(pattern) => pattern,
        Err(err) if is_unsupported_pattern_error(&err) => return SelectionRead::NoSelection,
        Err(_) => return transient(),
    };

    let ranges = match unsafe { text_pattern.GetSelection() } {
        Ok(ranges) => ranges,
        Err(err) if is_no_selection_error(&err) => return SelectionRead::NoSelection,
        Err(_) => return transient(),
    };

    let range_count = match unsafe { ranges.Length() } {
        Ok(count) => count,
        Err(_) => return transient(),
    };
    if range_count <= 0 {
        return SelectionRead::NoSelection;
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
            Err(_) => return transient(),
        };
        let part = match unsafe { range.GetText(TEXT_READ_LIMIT) } {
            Ok(text) => decode_utf16_bounded(&text, text.len() >= TEXT_READ_LIMIT as usize),
            Err(_) => return transient(),
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
        return SelectionRead::NoSelection;
    };

    SelectionRead::Selection(Selection {
        foreground_process_id: foreground_pid,
        element_process_id: focused_pid,
        text,
        bounds: union_bounds(&rectangles),
        cursor: current_cursor(),
    })
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
