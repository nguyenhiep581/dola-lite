mod core {
    use serde::Serialize;
    use std::time::{Duration, Instant};

    pub(crate) const STABLE_FOR: Duration = Duration::from_millis(300);
    pub(crate) const ERROR_LOG_INTERVAL: Duration = Duration::from_secs(2);
    pub(crate) const MAX_SELECTION_CHARS: usize = 10_000;

    pub(crate) const USAGE: &str =
        "Usage: dolalite-uia-spike [--watch] [--print-text] [--verbose] [--help]";

    #[derive(Clone, Debug, Default, PartialEq, Eq)]
    pub(crate) struct CliOptions {
        pub(crate) watch: bool,
        pub(crate) verbose: bool,
        pub(crate) print_text: bool,
        pub(crate) help: bool,
    }

    impl CliOptions {
        pub(crate) fn parse<I, S>(args: I) -> Result<Self, String>
        where
            I: IntoIterator<Item = S>,
            S: AsRef<str>,
        {
            let mut options = Self::default();
            for arg in args {
                match arg.as_ref() {
                    "--watch" => options.watch = true,
                    "--verbose" => options.verbose = true,
                    "--print-text" => options.print_text = true,
                    "--help" | "-h" => options.help = true,
                    other => {
                        return Err(format!("Unknown argument: {other}\n{USAGE}"));
                    }
                }
            }
            Ok(options)
        }
    }

    #[derive(Clone, Debug, PartialEq, Serialize)]
    pub(crate) struct Bounds {
        pub(crate) x: f64,
        pub(crate) y: f64,
        pub(crate) width: f64,
        pub(crate) height: f64,
    }

    #[derive(Clone, Debug, PartialEq)]
    pub(crate) struct Selection {
        pub(crate) foreground_process_id: u32,
        pub(crate) element_process_id: u32,
        pub(crate) text: String,
        pub(crate) bounds: Option<Bounds>,
    }

    #[derive(Serialize)]
    pub(crate) struct SelectionEvent<'a> {
        pub(crate) event: &'static str,
        pub(crate) foreground_process_id: u32,
        pub(crate) element_process_id: u32,
        pub(crate) length: usize,
        pub(crate) bounds: &'a Option<Bounds>,
        #[serde(skip_serializing_if = "Option::is_none")]
        pub(crate) text: Option<&'a str>,
    }

    #[derive(Clone, Debug, PartialEq)]
    pub(crate) enum SelectionRead {
        Selection(Selection),
        NoSelection,
        TransientError {
            foreground_process_id: Option<u32>,
            message: String,
        },
    }

    #[derive(Clone, Debug, PartialEq)]
    pub(crate) enum WatchAction {
        None,
        EmitSelection(Selection),
        EmitDeselection,
        LogError(String),
    }

    #[derive(Default)]
    pub(crate) struct WatchTracker {
        candidate_anchor: Option<Selection>,
        last_observed: Option<Selection>,
        candidate_since: Option<Instant>,
        last_emitted: Option<Selection>,
        last_error_at: Option<Instant>,
        missing_since: Option<Instant>,
    }

    impl WatchTracker {
        pub(crate) fn new() -> Self {
            Self::default()
        }

        pub(crate) fn observe(
            &mut self,
            read: SelectionRead,
            now: Instant,
            verbose: bool,
        ) -> WatchAction {
            match read {
                SelectionRead::TransientError {
                    foreground_process_id,
                    message,
                } => {
                    self.candidate_anchor = None;
                    self.last_observed = None;
                    self.candidate_since = None;

                    // If the user switched to a different foreground process
                    // (e.g., an elevated/UIPI-blocked or unresponsive app), do
                    // not freeze on the old process's selection forever.
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
                        // A transient error within the same app is not evidence
                        // that the user cleared the selection.
                        self.missing_since = None;
                    }

                    let should_log = self
                        .last_error_at
                        .map(|last| now.saturating_duration_since(last) >= ERROR_LOG_INTERVAL)
                        .unwrap_or(true);
                    if verbose && should_log {
                        self.last_error_at = Some(now);
                        WatchAction::LogError(message)
                    } else {
                        WatchAction::None
                    }
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
                        // Reset stability both when cumulative drift exceeds
                        // the identity tolerance AND when consecutive polls
                        // show steady movement (> 0.5 px per poll, e.g. slow
                        // smooth scrolling).
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

    pub(crate) fn union_bounds(values: &[f64]) -> Option<Bounds> {
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

    pub(crate) fn same_selection_identity(left: &Selection, right: &Selection) -> bool {
        if left.foreground_process_id != right.foreground_process_id
            || left.element_process_id != right.element_process_id
            || left.text != right.text
        {
            return false;
        }

        match (&left.bounds, &right.bounds) {
            (Some(left), Some(right)) => {
                (left.x - right.x).abs() <= 2.0
                    && (left.y - right.y).abs() <= 2.0
                    && (left.width - right.width).abs() <= 2.0
                    && (left.height - right.height).abs() <= 2.0
            }
            (None, None) => true,
            _ => false,
        }
    }

    pub(crate) fn sanitize_selection(source: &str) -> Option<String> {
        let trimmed = source.trim();
        if trimmed.chars().count() < 2 {
            return None;
        }
        Some(trimmed.chars().take(MAX_SELECTION_CHARS).collect())
    }

    pub(crate) fn decode_utf16_bounded(units: &[u16], truncated_at_limit: bool) -> String {
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

    pub(crate) fn serialize_selection_event(
        selection: &Selection,
        print_text: bool,
    ) -> Result<String, serde_json::Error> {
        let event = SelectionEvent {
            event: "selection",
            foreground_process_id: selection.foreground_process_id,
            element_process_id: selection.element_process_id,
            length: selection.text.chars().count(),
            bounds: &selection.bounds,
            text: print_text.then_some(selection.text.as_str()),
        };
        serde_json::to_string(&event)
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn sample_selection(text: &str, x: f64, y: f64) -> Selection {
            Selection {
                foreground_process_id: 42,
                element_process_id: 42,
                text: text.to_owned(),
                bounds: Some(Bounds {
                    x,
                    y,
                    width: 30.0,
                    height: 10.0,
                }),
            }
        }

        #[test]
        fn unions_visible_line_rectangles() {
            let bounds = union_bounds(&[10.0, 20.0, 30.0, 8.0, 5.0, 35.0, 40.0, 9.0]).unwrap();
            assert_eq!(
                bounds,
                Bounds {
                    x: 5.0,
                    y: 20.0,
                    width: 40.0,
                    height: 24.0
                }
            );
        }

        #[test]
        fn ignores_invalid_or_empty_rectangles() {
            assert!(union_bounds(&[0.0, 0.0, 0.0, 10.0]).is_none());
            assert!(union_bounds(&[f64::NAN, 0.0, 10.0, 10.0]).is_none());
        }

        #[test]
        fn geometry_jitter_does_not_change_selection_identity() {
            let first = sample_selection("selected text", 10.0, 20.0);
            let moved_rect = sample_selection("selected text", 10.5, 20.0);
            assert!(same_selection_identity(&first, &moved_rect));
        }

        #[test]
        fn same_text_selected_elsewhere_is_a_new_selection() {
            let first = sample_selection("same text", 10.0, 20.0);
            let elsewhere = sample_selection("same text", 90.0, 120.0);
            assert!(!same_selection_identity(&first, &elsewhere));
        }

        #[test]
        fn trims_shortens_and_rejects_too_short_selections() {
            assert_eq!(sanitize_selection("  a\n "), None);
            assert_eq!(sanitize_selection("  hello  ").as_deref(), Some("hello"));
            let long = "x".repeat(MAX_SELECTION_CHARS + 5);
            assert_eq!(
                sanitize_selection(&long).unwrap().chars().count(),
                MAX_SELECTION_CHARS
            );
        }

        #[test]
        fn parses_known_flags_and_rejects_unknown_flags() {
            let parsed = CliOptions::parse(["--watch", "--print-text", "--verbose"]).unwrap();
            assert_eq!(
                parsed,
                CliOptions {
                    watch: true,
                    verbose: true,
                    print_text: true,
                    help: false,
                }
            );
            assert!(CliOptions::parse(["--help"]).unwrap().help);
            assert!(CliOptions::parse(["--print_text"]).is_err());
        }

        #[test]
        fn debounces_selection_and_deselection_and_preserves_state_on_transient_errors() {
            let mut tracker = WatchTracker::new();
            let t0 = Instant::now();
            let sel = sample_selection("hello", 10.0, 20.0);

            assert_eq!(
                tracker.observe(SelectionRead::Selection(sel.clone()), t0, true),
                WatchAction::None
            );
            assert_eq!(
                tracker.observe(
                    SelectionRead::Selection(sel.clone()),
                    t0 + Duration::from_millis(200),
                    true
                ),
                WatchAction::None
            );
            assert_eq!(
                tracker.observe(
                    SelectionRead::Selection(sel.clone()),
                    t0 + Duration::from_millis(300),
                    true
                ),
                WatchAction::EmitSelection(sel.clone())
            );
            // Already emitted -> stays silent.
            assert_eq!(
                tracker.observe(
                    SelectionRead::Selection(sel.clone()),
                    t0 + Duration::from_millis(500),
                    true
                ),
                WatchAction::None
            );

            // Transient error within the same foreground app logs once (throttled)
            // and does not trigger deselection.
            assert_eq!(
                tracker.observe(
                    SelectionRead::TransientError {
                        foreground_process_id: Some(42),
                        message: "timeout".to_owned(),
                    },
                    t0 + Duration::from_millis(600),
                    true
                ),
                WatchAction::LogError("timeout".to_owned())
            );
            assert_eq!(
                tracker.observe(
                    SelectionRead::TransientError {
                        foreground_process_id: Some(42),
                        message: "timeout".to_owned(),
                    },
                    t0 + Duration::from_millis(800),
                    true
                ),
                WatchAction::None
            );

            // Deselection only fires after STABLE_FOR of consecutive NoSelection.
            assert_eq!(
                tracker.observe(
                    SelectionRead::NoSelection,
                    t0 + Duration::from_millis(1000),
                    true
                ),
                WatchAction::None
            );
            assert_eq!(
                tracker.observe(
                    SelectionRead::NoSelection,
                    t0 + Duration::from_millis(1200),
                    true
                ),
                WatchAction::None
            );
            assert_eq!(
                tracker.observe(
                    SelectionRead::NoSelection,
                    t0 + Duration::from_millis(1300),
                    true
                ),
                WatchAction::EmitDeselection
            );
        }

        #[test]
        fn slow_bounds_drift_resets_debounce_instead_of_spamming() {
            let mut tracker = WatchTracker::new();
            let t0 = Instant::now();

            let initial = sample_selection("scrolling text", 10.0, 20.0);
            assert_eq!(
                tracker.observe(SelectionRead::Selection(initial.clone()), t0, false),
                WatchAction::None
            );
            assert_eq!(
                tracker.observe(
                    SelectionRead::Selection(initial),
                    t0 + Duration::from_millis(300),
                    false
                ),
                WatchAction::EmitSelection(sample_selection("scrolling text", 10.0, 20.0))
            );

            // Smooth scrolling even at 1.0 px every 200 ms must NOT emit while still moving.
            for (step, x) in [11.0, 12.0, 13.0, 14.0, 15.0].into_iter().enumerate() {
                let moving = sample_selection("scrolling text", x, 20.0);
                assert_eq!(
                    tracker.observe(
                        SelectionRead::Selection(moving),
                        t0 + Duration::from_millis(500 + (step as u64) * 200),
                        false
                    ),
                    WatchAction::None
                );
            }
            let settled = sample_selection("scrolling text", 15.0, 20.0);
            // Once settled for STABLE_FOR (300 ms), emit the new position once.
            assert_eq!(
                tracker.observe(
                    SelectionRead::Selection(settled.clone()),
                    t0 + Duration::from_millis(1600),
                    false
                ),
                WatchAction::EmitSelection(settled)
            );
        }

        #[test]
        fn transient_error_in_different_foreground_app_emits_deselection() {
            let mut tracker = WatchTracker::new();
            let t0 = Instant::now();
            let sel = sample_selection("notepad text", 10.0, 20.0);

            assert_eq!(
                tracker.observe(SelectionRead::Selection(sel.clone()), t0, false),
                WatchAction::None
            );
            assert_eq!(
                tracker.observe(
                    SelectionRead::Selection(sel),
                    t0 + Duration::from_millis(300),
                    false
                ),
                WatchAction::EmitSelection(sample_selection("notepad text", 10.0, 20.0))
            );

            // User switches to an elevated/UIPI-blocked app (PID 999 != 42).
            assert_eq!(
                tracker.observe(
                    SelectionRead::TransientError {
                        foreground_process_id: Some(999),
                        message: "access denied".to_owned(),
                    },
                    t0 + Duration::from_millis(500),
                    false
                ),
                WatchAction::None
            );
            assert_eq!(
                tracker.observe(
                    SelectionRead::TransientError {
                        foreground_process_id: Some(999),
                        message: "access denied".to_owned(),
                    },
                    t0 + Duration::from_millis(800),
                    false
                ),
                WatchAction::EmitDeselection
            );
        }

        #[test]
        fn decode_utf16_bounded_drops_split_trailing_high_surrogate() {
            // "😀" is [0xD83D, 0xDE00]; truncating after a second emoji's high surrogate
            // should drop the lone 0xD83D instead of appending U+FFFD.
            let units = [0xD83D, 0xDE00, 0xD83D];
            assert_eq!(decode_utf16_bounded(&units, true), "😀");
            assert_eq!(decode_utf16_bounded(&units, false), "😀\u{FFFD}");
        }

        #[test]
        fn selection_event_omits_text_by_default_and_includes_when_opted_in() {
            let sel = sample_selection("secret phrase", 10.0, 20.0);
            let redacted = serialize_selection_event(&sel, false).unwrap();
            assert!(!redacted.contains("secret phrase"));
            assert!(redacted.contains("\"length\":13"));

            let verbose = serialize_selection_event(&sel, true).unwrap();
            assert!(verbose.contains("\"text\":\"secret phrase\""));
        }
    }
}

#[cfg(not(windows))]
fn main() {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    match core::CliOptions::parse(&args) {
        Ok(options) if options.help => {
            println!("{}", core::USAGE);
        }
        Ok(_) => {
            eprintln!("This UI Automation proof of concept must be built and run on Windows.");
            std::process::exit(1);
        }
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(2);
        }
    }
}

#[cfg(windows)]
mod windows_spike {
    use crate::core::{
        decode_utf16_bounded, sanitize_selection, serialize_selection_event, union_bounds,
        CliOptions, Selection, SelectionRead, WatchAction, WatchTracker, MAX_SELECTION_CHARS,
        USAGE,
    };
    use std::{
        env,
        ffi::c_void,
        io::{self, Write},
        mem::size_of,
        ptr, thread,
        time::{Duration, Instant},
    };
    use windows::{
        core::*,
        Win32::{
            Foundation::{E_NOINTERFACE, E_NOTIMPL, HWND, S_OK},
            System::{Com::*, Ole::*, Variant::*},
            UI::{
                Accessibility::*,
                HiDpi::{
                    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
                },
                WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId},
            },
        },
    };

    const POLL_INTERVAL: Duration = Duration::from_millis(200);
    const MAX_RANGE_COUNT: i32 = 32;
    const MAX_RECT_VALUES: usize = 16_000;
    // Allow up to 2 UTF-16 code units per non-BMP Unicode scalar value plus 2
    // spare units so astral characters (emoji / CJK Ext B) are not under-read.
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

    pub(super) fn run() -> Result<()> {
        let args = env::args().skip(1).collect::<Vec<_>>();
        let options = match CliOptions::parse(&args) {
            Ok(options) => options,
            Err(message) => {
                eprintln!("{message}");
                std::process::exit(2);
            }
        };
        if options.help {
            println!("{USAGE}");
            return Ok(());
        }

        // Request Per-Monitor V2 DPI awareness so UIA bounding rectangles align
        // with physical screen coordinates on scaled/multi-monitor setups.
        let _ = unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };

        let _com = ComApartment::initialize()?;
        // CUIAutomation8 implements IUIAutomation2 (timeouts & AutoSetFocus);
        // the legacy CUIAutomation CLSID only implements IUIAutomation and fails
        // QueryInterface for IUIAutomation2 with E_NOINTERFACE.
        let automation: IUIAutomation2 =
            unsafe { CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER)? };
        // Bound slow third-party accessibility providers so the diagnostic loop
        // can keep responding and never runs on an app UI thread.
        unsafe {
            automation.SetConnectionTimeout(500)?;
            automation.SetTransactionTimeout(500)?;
            automation.SetAutoSetFocus(false)?;
        }

        if options.watch {
            eprintln!("UIA selection spike is running. Select text in another app; Ctrl+C exits.");
        }
        eprintln!(
            "Text output is disabled by default. Pass --print-text to print selected content. Clipboard is not accessed."
        );

        if !options.watch {
            match read_foreground_selection(&automation) {
                SelectionRead::Selection(selection) => {
                    emit_selection(&selection, options.print_text)?
                }
                SelectionRead::NoSelection => println!("{{\"event\":\"no_selection\"}}"),
                SelectionRead::TransientError { message, .. } => {
                    eprintln!("UI Automation query failed: {message}");
                    println!("{{\"event\":\"unavailable\"}}");
                }
            }
            return Ok(());
        }

        let mut tracker = WatchTracker::new();
        loop {
            let read = read_foreground_selection(&automation);
            match tracker.observe(read, Instant::now(), options.verbose) {
                WatchAction::None => {}
                WatchAction::EmitSelection(selection) => {
                    emit_selection(&selection, options.print_text)?;
                }
                WatchAction::EmitDeselection => {
                    emit_deselection()?;
                }
                WatchAction::LogError(error) => {
                    eprintln!("UI Automation query failed: {error}");
                }
            }

            thread::sleep(POLL_INTERVAL);
        }
    }

    fn is_unsupported_pattern_error(error: &Error) -> bool {
        let code = error.code();
        // UIA GetCurrentPatternAs commonly returns S_OK + NULL when a pattern
        // is unsupported, which windows-rs projects as Err(Error::empty()) with
        // code == S_OK.
        code == S_OK || code == E_NOINTERFACE || code.0 as u32 == UIA_E_NOTSUPPORTED_CODE
    }

    fn is_no_selection_error(error: &Error) -> bool {
        let code = error.code();
        code == S_OK || code == E_NOTIMPL || code.0 as u32 == UIA_E_NOTSUPPORTED_CODE
    }

    fn transient_error(foreground_pid: u32, error: Error) -> SelectionRead {
        SelectionRead::TransientError {
            foreground_process_id: Some(foreground_pid),
            message: error.to_string(),
        }
    }

    fn read_foreground_selection(automation: &IUIAutomation) -> SelectionRead {
        let foreground = unsafe { GetForegroundWindow() };
        if foreground == HWND::default() {
            return SelectionRead::NoSelection;
        }

        let mut foreground_pid = 0_u32;
        unsafe { GetWindowThreadProcessId(foreground, Some(&mut foreground_pid)) };
        if foreground_pid == 0 || foreground_pid == std::process::id() {
            return SelectionRead::NoSelection;
        }

        let focused = match unsafe { automation.GetFocusedElement() } {
            Ok(element) => element,
            // GetFocusedElement returns S_OK + NULL (projected as Error::empty()
            // with code == S_OK) when no UIA element currently has focus (e.g.,
            // desktop, taskbar, or empty chrome).
            Err(error) if error.code() == S_OK => return SelectionRead::NoSelection,
            Err(error) => return transient_error(foreground_pid, error),
        };

        let focused_pid = match unsafe { focused.CurrentProcessId() } {
            Ok(pid) if pid > 0 => pid as u32,
            Ok(_) => return SelectionRead::NoSelection,
            Err(error) => return transient_error(foreground_pid, error),
        };
        // Do not require the focused provider's PID to match the foreground
        // top-level window PID: browsers and Electron often use a renderer
        // process for the focused UIA element.
        if focused_pid == std::process::id() {
            return SelectionRead::NoSelection;
        }
        match unsafe { focused.CurrentIsPassword() } {
            Ok(is_password) if is_password.as_bool() => return SelectionRead::NoSelection,
            Ok(_) => {}
            Err(error) => return transient_error(foreground_pid, error),
        }

        if let Ok(available) =
            unsafe { focused.GetCurrentPropertyValue(UIA_IsTextPatternAvailablePropertyId) }
        {
            // Guard on VT_BOOL because TryFrom<&VARIANT> for bool calls
            // VariantToBoolean, which coerces VT_EMPTY / VT_NULL to Ok(false).
            if available.vt() == VT_BOOL && matches!(bool::try_from(&available), Ok(false)) {
                return SelectionRead::NoSelection;
            }
        }

        let text_pattern = match unsafe {
            focused.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)
        } {
            Ok(pattern) => pattern,
            Err(error) if is_unsupported_pattern_error(&error) => {
                return SelectionRead::NoSelection;
            }
            Err(error) => return transient_error(foreground_pid, error),
        };
        let ranges = match unsafe { text_pattern.GetSelection() } {
            Ok(ranges) => ranges,
            Err(error) if is_no_selection_error(&error) => return SelectionRead::NoSelection,
            Err(error) => return transient_error(foreground_pid, error),
        };
        let range_count = match unsafe { ranges.Length() } {
            Ok(count) => count,
            Err(error) => return transient_error(foreground_pid, error),
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
                Err(error) => return transient_error(foreground_pid, error),
            };
            let part = match unsafe { range.GetText(TEXT_READ_LIMIT) } {
                Ok(text) => decode_utf16_bounded(&text, text.len() >= TEXT_READ_LIMIT as usize),
                Err(error) => return transient_error(foreground_pid, error),
            };
            if part.trim().is_empty() {
                continue;
            }
            collected_chars = collected_chars.saturating_add(part.chars().count());
            selected_parts.push(part);

            // Bounds are optional. A rectangle failure must not discard
            // text that the focused provider successfully exposed.
            if let Ok(Some(values)) = unsafe { read_rectangles(&range) } {
                rectangles.extend(values);
            }
        }

        let Some(text) = sanitize_selection(&selected_parts.join("\n")) else {
            return SelectionRead::NoSelection;
        };
        let bounds = union_bounds(&rectangles);

        SelectionRead::Selection(Selection {
            foreground_process_id: foreground_pid,
            element_process_id: focused_pid,
            text,
            bounds,
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
        // Declared after SafeArrayGuard so SafeArrayUnaccessData always runs
        // before SafeArrayDestroy, including on early return or panic.
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

    fn emit_selection(selection: &Selection, print_text: bool) -> Result<()> {
        let json = serialize_selection_event(selection, print_text)
            .map_err(|error| Error::new(HRESULT(0x80004005_u32 as i32), error.to_string()))?;
        let stdout = io::stdout();
        let mut output = stdout.lock();
        output
            .write_all(json.as_bytes())
            .map_err(|error| Error::new(HRESULT(0x80004005_u32 as i32), error.to_string()))?;
        output
            .write_all(b"\n")
            .map_err(|error| Error::new(HRESULT(0x80004005_u32 as i32), error.to_string()))?;
        output
            .flush()
            .map_err(|error| Error::new(HRESULT(0x80004005_u32 as i32), error.to_string()))?;
        Ok(())
    }

    fn emit_deselection() -> Result<()> {
        let stdout = io::stdout();
        let mut output = stdout.lock();
        output
            .write_all(b"{\"event\":\"deselection\"}\n")
            .map_err(|error| Error::new(HRESULT(0x80004005_u32 as i32), error.to_string()))?;
        output
            .flush()
            .map_err(|error| Error::new(HRESULT(0x80004005_u32 as i32), error.to_string()))?;
        Ok(())
    }
}

#[cfg(windows)]
fn main() -> windows::core::Result<()> {
    windows_spike::run()
}
