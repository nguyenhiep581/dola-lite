use std::sync::atomic::AtomicBool;
#[cfg(windows)]
use std::sync::atomic::AtomicIsize;
#[cfg(windows)]
use std::sync::Arc;
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

/// Disables Windows 11 DWM outer corner rounding and the faint 1px DWM border
/// around transparent frameless WebView2 windows so CSS shapes float cleanly.
#[cfg(windows)]
pub fn configure_frameless_transparent_window<R: Runtime>(window: &WebviewWindow<R>) {
    use std::ffi::c_void;
    use std::mem::size_of;
    use windows::Win32::Foundation::HWND;
    use windows::Win32::Graphics::Dwm::{
        DwmSetWindowAttribute, DWMWCP_DONOTROUND, DWMWA_BORDER_COLOR, DWMWA_COLOR_NONE,
        DWMWA_WINDOW_CORNER_PREFERENCE, DWM_WINDOW_CORNER_PREFERENCE,
    };

    let Ok(raw_hwnd) = window.hwnd() else {
        return;
    };
    let hwnd = HWND(raw_hwnd.0);
    let corner = DWMWCP_DONOTROUND;
    let border = DWMWA_COLOR_NONE;
    unsafe {
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            (&corner as *const DWM_WINDOW_CORNER_PREFERENCE).cast::<c_void>(),
            size_of::<DWM_WINDOW_CORNER_PREFERENCE>() as u32,
        );
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_BORDER_COLOR,
            (&border as *const u32).cast::<c_void>(),
            size_of::<u32>() as u32,
        );
    }
}

#[cfg(not(windows))]
pub fn configure_frameless_transparent_window<R: Runtime>(_window: &WebviewWindow<R>) {}

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

    configure_frameless_transparent_window(window);

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

/// Captures the raw Win32 `HWND` once on the UI thread during `setup()` so
/// background threads never invoke `WebviewWindow::hwnd()` (which posts a
/// synchronous UI-thread round-trip and `RedrawWindow` in `tauri-runtime-wry`).
#[cfg(windows)]
pub fn capture_hwnd<R: Runtime>(window: &WebviewWindow<R>) -> isize {
    window.hwnd().map(|h| h.0 as isize).unwrap_or(0)
}

#[cfg(not(windows))]
pub fn capture_hwnd<R: Runtime>(_window: &WebviewWindow<R>) -> isize {
    0
}

/// Atomically moves, resizes, raises topmost, and shows the non-activating Pill
/// window without stealing focus. Must be called on the UI thread.
#[cfg(windows)]
pub fn show_pill_at_on_main_thread(hwnd_raw: isize, x: i32, y: i32, w: i32, h: i32) {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{
        SetWindowPos, HWND_TOPMOST, SWP_NOACTIVATE, SWP_SHOWWINDOW,
    };

    if hwnd_raw == 0 {
        return;
    }
    let hwnd = HWND(hwnd_raw as _);
    unsafe {
        let _ = SetWindowPos(
            hwnd,
            Some(HWND_TOPMOST),
            x,
            y,
            w,
            h,
            SWP_NOACTIVATE | SWP_SHOWWINDOW,
        );
    }
}

#[cfg(not(windows))]
pub fn show_pill_at_on_main_thread(_hwnd_raw: isize, _x: i32, _y: i32, _w: i32, _h: i32) {}

/// Atomically moves, resizes (synchronously while suppressing resize persistence),
/// raises topmost, shows, and foregrounds the Result Panel without invoking
/// `tao::Window::set_focus()`'s synthetic Left-Alt (`SendInput`) fallback.
/// Must be called on the UI thread.
#[cfg(windows)]
pub fn show_result_at_on_main_thread(
    hwnd_raw: isize,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    ignoring_resize: &AtomicBool,
) {
    use std::sync::atomic::Ordering;
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{
        SetForegroundWindow, SetWindowPos, HWND_TOPMOST, SWP_SHOWWINDOW,
    };

    if hwnd_raw == 0 {
        return;
    }
    let hwnd = HWND(hwnd_raw as _);
    ignoring_resize.store(true, Ordering::SeqCst);
    unsafe {
        let _ = SetWindowPos(hwnd, Some(HWND_TOPMOST), x, y, w, h, SWP_SHOWWINDOW);
    }
    ignoring_resize.store(false, Ordering::SeqCst);
    unsafe {
        let _ = SetForegroundWindow(hwnd);
    }
}

#[cfg(not(windows))]
pub fn show_result_at_on_main_thread(
    _hwnd_raw: isize,
    _x: i32,
    _y: i32,
    _w: i32,
    _h: i32,
    _ignoring_resize: &AtomicBool,
) {
}

/// Reliably hides a floating window on the UI thread via Win32 `ShowWindow(SW_HIDE)`,
/// skipping already-hidden windows and avoiding `tao`'s stale `WindowFlags::VISIBLE`
/// no-op / async `WindowMessage::Hide` race. Must be called on the UI thread.
#[cfg(windows)]
pub fn hide_hwnd_on_main_thread(hwnd_raw: isize) {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{IsWindowVisible, ShowWindow, SW_HIDE};

    if hwnd_raw == 0 {
        return;
    }
    let hwnd = HWND(hwnd_raw as _);
    unsafe {
        if IsWindowVisible(hwnd).as_bool() {
            let _ = ShowWindow(hwnd, SW_HIDE);
        }
    }
}

#[cfg(not(windows))]
pub fn hide_hwnd_on_main_thread(_hwnd_raw: isize) {}

/// Returns true when the given cached top-level `HWND` is currently visible.
#[cfg(windows)]
pub fn is_hwnd_visible(hwnd_raw: isize) -> bool {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::IsWindowVisible;

    hwnd_raw != 0 && unsafe { IsWindowVisible(HWND(hwnd_raw as _)).as_bool() }
}

#[cfg(not(windows))]
pub fn is_hwnd_visible(_hwnd_raw: isize) -> bool {
    false
}

/// Returns true when the given cached top-level `HWND` is currently the Win32
/// foreground window (distinguishing WebView2 child focus shifts / resize drags
/// from genuine focus loss to another top-level window).
#[cfg(windows)]
pub fn is_hwnd_foreground(hwnd_raw: isize) -> bool {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow;

    hwnd_raw != 0 && unsafe { GetForegroundWindow() == HWND(hwnd_raw as _) }
}

#[cfg(not(windows))]
pub fn is_hwnd_foreground(_hwnd_raw: isize) -> bool {
    false
}

/// Spawns an event-driven Raw Input (`RIDEV_INPUTSINK`) message-only window on
/// a lightweight background thread to detect clicks outside the floating Pill /
/// Result windows and global Escape presses immediately — zero polling, zero
/// UI-thread wakeups while idle, zero missed fast taps, and zero global hooks.
#[cfg(windows)]
pub fn spawn_raw_input_watcher<R, FClick, FEsc>(
    app: tauri::AppHandle<R>,
    pill_hwnd: isize,
    result_hwnd: isize,
    stop: Arc<AtomicBool>,
    raw_input_hwnd_slot: Arc<AtomicIsize>,
    on_outside_click: FClick,
    on_escape: FEsc,
) where
    R: Runtime,
    FClick: Fn(&tauri::AppHandle<R>) + Send + 'static,
    FEsc: Fn(&tauri::AppHandle<R>) + Send + 'static,
{
    use std::mem::size_of;
    use std::sync::atomic::Ordering;
    use std::thread;
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
    use windows::Win32::UI::Input::KeyboardAndMouse::VK_ESCAPE;
    use windows::Win32::UI::Input::{
        GetRawInputData, RegisterRawInputDevices, HRAWINPUT, RAWINPUT, RAWINPUTDEVICE,
        RAWINPUTHEADER, RIDEV_INPUTSINK, RID_INPUT, RIM_TYPEKEYBOARD, RIM_TYPEMOUSE,
    };
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetCursorPos,
        GetMessageW, GetWindowLongPtrW, GetWindowRect, IsWindowVisible, PostQuitMessage,
        RegisterClassW, SetWindowLongPtrW, GWLP_USERDATA, HWND_MESSAGE, MSG, RI_KEY_BREAK,
        RI_MOUSE_BUTTON_4_DOWN, RI_MOUSE_BUTTON_5_DOWN, RI_MOUSE_LEFT_BUTTON_DOWN,
        RI_MOUSE_MIDDLE_BUTTON_DOWN, RI_MOUSE_RIGHT_BUTTON_DOWN, WINDOW_EX_STYLE, WINDOW_STYLE,
        WM_CLOSE, WM_DESTROY, WM_INPUT, WNDCLASSW,
    };

    const HID_USAGE_PAGE_GENERIC: u16 = 0x01;
    const HID_USAGE_GENERIC_MOUSE: u16 = 0x02;
    const HID_USAGE_GENERIC_KEYBOARD: u16 = 0x06;
    const ANY_MOUSE_BUTTON_DOWN: u16 = (RI_MOUSE_LEFT_BUTTON_DOWN
        | RI_MOUSE_RIGHT_BUTTON_DOWN
        | RI_MOUSE_MIDDLE_BUTTON_DOWN
        | RI_MOUSE_BUTTON_4_DOWN
        | RI_MOUSE_BUTTON_5_DOWN) as u16;

    struct RawInputContext<R: Runtime> {
        app: tauri::AppHandle<R>,
        pill_hwnd: isize,
        result_hwnd: isize,
        raw_input_hwnd_slot: Arc<AtomicIsize>,
        on_outside_click: Box<dyn Fn(&tauri::AppHandle<R>) + Send>,
        on_escape: Box<dyn Fn(&tauri::AppHandle<R>) + Send>,
    }

    fn hwnd_contains_point(hwnd_raw: isize, pt: POINT) -> bool {
        if hwnd_raw == 0 {
            return false;
        }
        let hwnd = HWND(hwnd_raw as _);
        let mut rect = RECT::default();
        unsafe { GetWindowRect(hwnd, &mut rect) }.is_ok()
            && pt.x >= rect.left
            && pt.x < rect.right
            && pt.y >= rect.top
            && pt.y < rect.bottom
    }

    unsafe extern "system" fn raw_input_wnd_proc<R: Runtime>(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        match msg {
            WM_INPUT => {
                let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *const RawInputContext<R>;
                if !ptr.is_null() {
                    let ctx = &*ptr;
                    let pill_vis =
                        ctx.pill_hwnd != 0 && IsWindowVisible(HWND(ctx.pill_hwnd as _)).as_bool();
                    let res_vis = ctx.result_hwnd != 0
                        && IsWindowVisible(HWND(ctx.result_hwnd as _)).as_bool();
                    if pill_vis || res_vis {
                        let mut raw = RAWINPUT::default();
                        let mut size = size_of::<RAWINPUT>() as u32;
                        let copied = GetRawInputData(
                            HRAWINPUT(lparam.0 as _),
                            RID_INPUT,
                            Some((&mut raw as *mut RAWINPUT).cast()),
                            &mut size,
                            size_of::<RAWINPUTHEADER>() as u32,
                        );
                        if copied != u32::MAX && copied >= size_of::<RAWINPUTHEADER>() as u32 {
                            if raw.header.dwType == RIM_TYPEKEYBOARD.0 {
                                let kb = raw.data.keyboard;
                                let is_key_down = (kb.Flags & RI_KEY_BREAK as u16) == 0;
                                if is_key_down && kb.VKey == VK_ESCAPE.0 {
                                    (ctx.on_escape)(&ctx.app);
                                }
                            } else if raw.header.dwType == RIM_TYPEMOUSE.0 {
                                let button_flags = raw.data.mouse.Anonymous.Anonymous.usButtonFlags;
                                if (button_flags & ANY_MOUSE_BUTTON_DOWN) != 0 {
                                    let mut pt = POINT::default();
                                    if GetCursorPos(&mut pt).is_ok() {
                                        let in_pill =
                                            pill_vis && hwnd_contains_point(ctx.pill_hwnd, pt);
                                        let in_res =
                                            res_vis && hwnd_contains_point(ctx.result_hwnd, pt);
                                        if !in_pill && !in_res {
                                            (ctx.on_outside_click)(&ctx.app);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                DefWindowProcW(hwnd, msg, wparam, lparam)
            }
            WM_CLOSE => {
                let _ = DestroyWindow(hwnd);
                LRESULT(0)
            }
            WM_DESTROY => {
                let ptr = SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0) as *mut RawInputContext<R>;
                if !ptr.is_null() {
                    let ctx = Box::from_raw(ptr);
                    ctx.raw_input_hwnd_slot.store(0, Ordering::Release);
                }
                PostQuitMessage(0);
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    thread::Builder::new()
        .name("dola-raw-input".to_owned())
        .spawn(move || {
            let class_name: Vec<u16> = "DolaLiteRawInputSink"
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect();
            let wc = WNDCLASSW {
                lpfnWndProc: Some(raw_input_wnd_proc::<R>),
                lpszClassName: PCWSTR(class_name.as_ptr()),
                ..Default::default()
            };
            unsafe {
                let _ = RegisterClassW(&wc);
            }

            let Ok(msg_hwnd) = (unsafe {
                CreateWindowExW(
                    WINDOW_EX_STYLE(0),
                    PCWSTR(class_name.as_ptr()),
                    PCWSTR::null(),
                    WINDOW_STYLE(0),
                    0,
                    0,
                    0,
                    0,
                    Some(HWND_MESSAGE),
                    None,
                    None,
                    None,
                )
            }) else {
                return;
            };

            let ctx = Box::new(RawInputContext {
                app,
                pill_hwnd,
                result_hwnd,
                raw_input_hwnd_slot: raw_input_hwnd_slot.clone(),
                on_outside_click: Box::new(on_outside_click),
                on_escape: Box::new(on_escape),
            });
            unsafe {
                SetWindowLongPtrW(msg_hwnd, GWLP_USERDATA, Box::into_raw(ctx) as isize);
            }
            raw_input_hwnd_slot.store(msg_hwnd.0 as isize, Ordering::SeqCst);

            if stop.load(Ordering::SeqCst) {
                let _ = unsafe { DestroyWindow(msg_hwnd) };
                return;
            }

            let devices = [
                RAWINPUTDEVICE {
                    usUsagePage: HID_USAGE_PAGE_GENERIC,
                    usUsage: HID_USAGE_GENERIC_MOUSE,
                    dwFlags: RIDEV_INPUTSINK,
                    hwndTarget: msg_hwnd,
                },
                RAWINPUTDEVICE {
                    usUsagePage: HID_USAGE_PAGE_GENERIC,
                    usUsage: HID_USAGE_GENERIC_KEYBOARD,
                    dwFlags: RIDEV_INPUTSINK,
                    hwndTarget: msg_hwnd,
                },
            ];
            if unsafe { RegisterRawInputDevices(&devices, size_of::<RAWINPUTDEVICE>() as u32) }
                .is_err()
            {
                let _ = unsafe { DestroyWindow(msg_hwnd) };
                return;
            }

            let mut msg = MSG::default();
            while unsafe { GetMessageW(&mut msg, None, 0, 0) }.0 > 0 {
                unsafe {
                    DispatchMessageW(&msg);
                }
            }
        })
        .ok();
}

/// Requests clean shutdown of the Raw Input message-only window thread.
#[cfg(windows)]
pub fn shutdown_raw_input_watcher(raw_input_hwnd: &AtomicIsize) {
    use std::sync::atomic::Ordering;
    use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
    use windows::Win32::UI::WindowsAndMessaging::{PostMessageW, WM_CLOSE};

    let hwnd_raw = raw_input_hwnd.swap(0, Ordering::SeqCst);
    if hwnd_raw != 0 {
        let _ = unsafe { PostMessageW(Some(HWND(hwnd_raw as _)), WM_CLOSE, WPARAM(0), LPARAM(0)) };
    }
}

#[cfg(not(windows))]
pub fn shutdown_raw_input_watcher(_raw_input_hwnd: &std::sync::atomic::AtomicIsize) {}

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
