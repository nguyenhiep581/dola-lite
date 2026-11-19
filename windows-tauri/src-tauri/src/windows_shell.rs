use tauri::{Runtime, WebviewWindow};

/// Holds a process-lifetime Win32 named mutex to prevent duplicate tray icons
/// and competing UIA watchers when Dola Lite is launched more than once.
pub struct SingleInstanceGuard {
    #[cfg(windows)]
    handle: windows::Win32::Foundation::HANDLE,
}

#[cfg(windows)]
unsafe impl Send for SingleInstanceGuard {}
#[cfg(windows)]
unsafe impl Sync for SingleInstanceGuard {}

impl SingleInstanceGuard {
    #[cfg(windows)]
    pub fn acquire() -> Option<Self> {
        use windows::core::PCWSTR;
        use windows::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS};
        use windows::Win32::System::Threading::CreateMutexW;

        let name: Vec<u16> = "Local\\DolaLiteSingleInstance"
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let handle = unsafe { CreateMutexW(None, false, PCWSTR(name.as_ptr())) }.ok()?;
        if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
            let _ = unsafe { CloseHandle(handle) };
            return None;
        }
        Some(Self { handle })
    }

    #[cfg(not(windows))]
    pub fn acquire() -> Option<Self> {
        Some(Self {})
    }
}

#[cfg(windows)]
impl Drop for SingleInstanceGuard {
    fn drop(&mut self) {
        use windows::Win32::Foundation::CloseHandle;
        let _ = unsafe { CloseHandle(self.handle) };
    }
}

/// Configures a floating Tauri window on Windows as non-activating so showing
/// or clicking the quick-action pill does not steal focus from the source app.
#[cfg(windows)]
pub fn configure_non_activating_window<R: Runtime>(window: &WebviewWindow<R>) {
    use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
    use windows::Win32::UI::Shell::{DefSubclassProc, SetWindowSubclass};
    use windows::Win32::UI::WindowsAndMessaging::{
        GetWindowLongPtrW, SetWindowLongPtrW, GWL_EXSTYLE, MA_NOACTIVATE, WM_MOUSEACTIVATE,
        WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
    };

    const SUBCLASS_ID: usize = 0xD01A_0001;

    unsafe extern "system" fn no_activate_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
        _uid: usize,
        _ref_data: usize,
    ) -> LRESULT {
        if msg == WM_MOUSEACTIVATE {
            return LRESULT(MA_NOACTIVATE as isize);
        }
        DefSubclassProc(hwnd, msg, wparam, lparam)
    }

    // Update tao's internal FOCUSABLE flag so subsequent window operations do
    // not strip WS_EX_NOACTIVATE when recomputing GWL_EXSTYLE.
    let _ = window.set_focusable(false);

    let Ok(raw_hwnd) = window.hwnd() else {
        return;
    };
    let hwnd = HWND(raw_hwnd.0);
    unsafe {
        let ex_style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let next = ex_style | (WS_EX_NOACTIVATE.0 as isize) | (WS_EX_TOOLWINDOW.0 as isize);
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, next);
        let _ = SetWindowSubclass(hwnd, Some(no_activate_proc), SUBCLASS_ID, 0);
    }
}

#[cfg(not(windows))]
pub fn configure_non_activating_window<R: Runtime>(window: &WebviewWindow<R>) {
    let _ = window.set_focusable(false);
}

/// Shows a floating window on Windows without activating or stealing focus from
/// the source application (`SW_SHOWNOACTIVATE`).
#[cfg(windows)]
pub fn show_window_no_activate<R: Runtime>(window: &WebviewWindow<R>) {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{ShowWindow, SW_SHOWNOACTIVATE};

    if let Ok(raw_hwnd) = window.hwnd() {
        let _ = unsafe { ShowWindow(HWND(raw_hwnd.0), SW_SHOWNOACTIVATE) };
    } else {
        let _ = window.show();
    }
}

#[cfg(not(windows))]
pub fn show_window_no_activate<R: Runtime>(window: &WebviewWindow<R>) {
    let _ = window.show();
}

/// Writes UTF-16 text to the Windows clipboard via Win32 APIs (only called on
/// explicit user Copy button clicks — never used for selection capture).
#[cfg(windows)]
pub fn set_clipboard_text(text: &str) -> Result<(), String> {
    use std::ptr;
    use std::thread;
    use std::time::Duration;
    use windows::Win32::Foundation::{GlobalFree, HANDLE, HGLOBAL};
    use windows::Win32::System::DataExchange::{
        CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
    };
    use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
    use windows::Win32::System::Ole::CF_UNICODETEXT;

    let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    let byte_len = wide.len() * std::mem::size_of::<u16>();

    unsafe {
        let mut opened = false;
        for attempt in 0..5 {
            if OpenClipboard(None).is_ok() {
                opened = true;
                break;
            }
            if attempt < 4 {
                thread::sleep(Duration::from_millis(10));
            }
        }
        if !opened {
            return Err("Không mở được clipboard Windows.".to_owned());
        }

        struct ClipboardGuard;
        impl Drop for ClipboardGuard {
            fn drop(&mut self) {
                let _ = unsafe { CloseClipboard() };
            }
        }
        let _clip = ClipboardGuard;

        EmptyClipboard().map_err(|_| "Không xóa được bộ đệm clipboard.".to_owned())?;
        let hmem: HGLOBAL = GlobalAlloc(GMEM_MOVEABLE, byte_len)
            .map_err(|_| "Không cấp phát được bộ nhớ clipboard.".to_owned())?;
        let dst = GlobalLock(hmem);
        if dst.is_null() {
            let _ = GlobalFree(Some(hmem));
            return Err("Không khóa được bộ nhớ clipboard.".to_owned());
        }
        ptr::copy_nonoverlapping(wide.as_ptr(), dst.cast::<u16>(), wide.len());
        let _ = GlobalUnlock(hmem);

        if SetClipboardData(CF_UNICODETEXT.0 as u32, Some(HANDLE(hmem.0))).is_err() {
            let _ = GlobalFree(Some(hmem));
            return Err("Không ghi được văn bản vào clipboard.".to_owned());
        }
    }
    Ok(())
}

#[cfg(not(windows))]
pub fn set_clipboard_text(_text: &str) -> Result<(), String> {
    Ok(())
}
