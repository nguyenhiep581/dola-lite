use crate::history::{HistoryEntry, HistoryListResponse, HistoryStore};
use crate::provider::{
    build_http_client, fetch_models as provider_fetch_models, stream_skill,
    test_connection as provider_test_connection, ConnectionTestResult, Skill,
};
use crate::selection::{compute_floating_rect, Bounds, MonitorWorkArea, Selection};
use crate::settings::{ApiConfiguration, ApiCredentialsSnapshot, SettingsStore};
use crate::tray::refresh_tray_labels;
use crate::windows_shell::{
    hide_hwnd_on_main_thread, is_hwnd_foreground, is_hwnd_visible, set_clipboard_text,
    show_pill_at_on_main_thread, show_result_at_on_main_thread, shutdown_raw_input_watcher,
};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
use std::sync::{Arc, Mutex};
use tauri::async_runtime::JoinHandle;
use tauri::{AppHandle, Emitter, Manager, Runtime, State};
use tauri_plugin_autostart::ManagerExt;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize)]
pub struct SettingsViewModel {
    pub configuration: ApiConfiguration,
    pub has_api_key: bool,
    pub initialization_error: Option<String>,
    pub launch_at_login: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveSettingsPayload {
    pub configuration: ApiConfiguration,
    pub api_key: String,
}

#[derive(Debug, Clone, Serialize)]
struct PillShowEvent {
    text: String,
}

#[derive(Debug, Clone, Serialize)]
struct ResultStartEvent {
    generation: String,
    skill: Skill,
    source_text: String,
}

#[derive(Debug, Clone, Serialize)]
struct ResultChunkEvent {
    generation: String,
    chunk: String,
}

#[derive(Debug, Clone, Serialize)]
struct ResultFinishedEvent {
    generation: String,
    history_warning: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
struct ResultErrorEvent {
    generation: String,
    message: String,
}

#[derive(Default)]
pub struct CoordinatorState {
    pub active_generation: Option<String>,
    pub active_task: Option<JoinHandle<()>>,
    pub last_selection: Option<Selection>,
    pub retry_request: Option<(Skill, String)>,
    pub is_pinned: bool,
    pub suspended: bool,
}

pub struct AppState {
    pub settings: Mutex<SettingsStore>,
    pub history: Mutex<HistoryStore>,
    pub coordinator: Mutex<CoordinatorState>,
    pub http_client: Client,
    pub stop_flag: Arc<AtomicBool>,
    pub ignoring_result_resize: AtomicBool,
    pub pill_hwnd: AtomicIsize,
    pub result_hwnd: AtomicIsize,
    pub raw_input_hwnd: Arc<AtomicIsize>,
}

impl AppState {
    pub fn new(settings: SettingsStore, history: HistoryStore) -> Self {
        let http_client = build_http_client().expect("HTTP client initialization");
        Self {
            settings: Mutex::new(settings),
            history: Mutex::new(history),
            coordinator: Mutex::new(CoordinatorState::default()),
            http_client,
            stop_flag: Arc::new(AtomicBool::new(false)),
            ignoring_result_resize: AtomicBool::new(false),
            pill_hwnd: AtomicIsize::new(0),
            result_hwnd: AtomicIsize::new(0),
            raw_input_hwnd: Arc::new(AtomicIsize::new(0)),
        }
    }

    pub fn shutdown(&self) {
        self.stop_flag.store(true, Ordering::SeqCst);
        shutdown_raw_input_watcher(&self.raw_input_hwnd);
        let mut coord = self.coordinator.lock().unwrap();
        coord.active_generation = None;
        if let Some(task) = coord.active_task.take() {
            task.abort();
        }
    }
}

fn hide_pill_window<R: Runtime>(app: &AppHandle<R>) {
    let hwnd = app.state::<AppState>().pill_hwnd.load(Ordering::Acquire);
    let _ = app.run_on_main_thread(move || {
        hide_hwnd_on_main_thread(hwnd);
    });
}

fn monitor_work_areas<R: Runtime>(app: &AppHandle<R>) -> Vec<MonitorWorkArea> {
    app.available_monitors()
        .unwrap_or_default()
        .into_iter()
        .map(|m| {
            let work = m.work_area();
            MonitorWorkArea {
                bounds: Bounds {
                    x: work.position.x as f64,
                    y: work.position.y as f64,
                    width: work.size.width as f64,
                    height: work.size.height as f64,
                },
                scale_factor: m.scale_factor(),
            }
        })
        .collect()
}

pub fn handle_selection_detected<R: Runtime>(app: &AppHandle<R>, selection: Selection) {
    let state = app.state::<AppState>();
    let (suspended, is_pinned) = {
        let mut coord = state.coordinator.lock().unwrap();
        coord.last_selection = Some(selection.clone());
        (coord.suspended, coord.is_pinned)
    };
    if suspended {
        return;
    }

    if !is_pinned {
        cancel_and_hide_result(app);
    }

    let pill_hwnd = state.pill_hwnd.load(Ordering::Acquire);
    let app_handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        let state = app_handle.state::<AppState>();
        {
            let coord = state.coordinator.lock().unwrap();
            if coord.suspended || coord.last_selection.is_none() {
                return;
            }
        }
        let monitors = monitor_work_areas(&app_handle);
        let (x, y, w, h) =
            compute_floating_rect(336.0, 68.0, selection.bounds, selection.cursor, &monitors);
        if let Some(pill) = app_handle.get_webview_window("pill") {
            let _ = pill.emit("pill:show", PillShowEvent { text: selection.text });
        }
        show_pill_at_on_main_thread(pill_hwnd, x, y, w as i32, h as i32);
    });
}

pub fn handle_deselection<R: Runtime>(app: &AppHandle<R>) {
    let state = app.state::<AppState>();
    let is_pinned = {
        let mut coord = state.coordinator.lock().unwrap();
        coord.last_selection = None;
        coord.is_pinned
    };
    hide_pill_window(app);
    if !is_pinned {
        cancel_and_hide_result(app);
    }
}

pub fn handle_outside_click<R: Runtime>(app: &AppHandle<R>) {
    let state = app.state::<AppState>();
    if is_hwnd_visible(state.pill_hwnd.load(Ordering::Acquire)) {
        hide_pill_window(app);
    }
    let result_hwnd = state.result_hwnd.load(Ordering::Acquire);
    if !is_hwnd_visible(result_hwnd) {
        return;
    }
    let is_pinned = state.coordinator.lock().unwrap().is_pinned;
    if !is_pinned {
        cancel_and_hide_result(app);
    }
}

pub fn handle_escape_pressed<R: Runtime>(app: &AppHandle<R>) {
    let state = app.state::<AppState>();
    if is_hwnd_visible(state.pill_hwnd.load(Ordering::Acquire)) {
        hide_pill_window(app);
    }
    let result_hwnd = state.result_hwnd.load(Ordering::Acquire);
    if !is_hwnd_visible(result_hwnd) {
        return;
    }
    let is_pinned = state.coordinator.lock().unwrap().is_pinned;
    if !is_pinned || is_hwnd_foreground(result_hwnd) {
        cancel_and_hide_result(app);
    }
}

pub fn open_settings_window<R: Runtime>(app: &AppHandle<R>) {
    {
        let state = app.state::<AppState>();
        let mut coord = state.coordinator.lock().unwrap();
        coord.suspended = true;
    }
    hide_pill_window(app);
    if let Some(win) = app.get_webview_window("settings") {
        let _ = win.emit("settings:open", ());
        let _ = win.center();
        let _ = win.show();
        let _ = win.set_focus();
    }
}

pub fn close_settings_window<R: Runtime>(app: &AppHandle<R>) {
    {
        let state = app.state::<AppState>();
        let mut coord = state.coordinator.lock().unwrap();
        coord.suspended = false;
    }
    if let Some(win) = app.get_webview_window("settings") {
        let _ = win.emit("settings:closed", ());
        let _ = win.hide();
    }
}

pub fn open_history_window<R: Runtime>(app: &AppHandle<R>) {
    if let Some(win) = app.get_webview_window("history") {
        let _ = win.emit("history:open", ());
        let _ = win.center();
        let _ = win.show();
        let _ = win.set_focus();
    }
}

pub fn cancel_and_hide_result<R: Runtime>(app: &AppHandle<R>) {
    let state = app.state::<AppState>();
    let result_hwnd = state.result_hwnd.load(Ordering::Acquire);
    {
        let mut coord = state.coordinator.lock().unwrap();
        coord.active_generation = None;
        coord.is_pinned = false;
        if let Some(task) = coord.active_task.take() {
            task.abort();
        }
    }
    let app_handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(win) = app_handle.get_webview_window("result") {
            let _ = win.emit("result:dismiss", ());
        }
        hide_hwnd_on_main_thread(result_hwnd);
    });
}

#[tauri::command]
pub fn get_settings(app: AppHandle, state: State<'_, AppState>) -> SettingsViewModel {
    let settings = state.settings.lock().unwrap();
    let launch_at_login = app.autolaunch().is_enabled().unwrap_or(false);
    SettingsViewModel {
        configuration: settings.configuration().clone(),
        has_api_key: settings.has_api_key(),
        initialization_error: settings.initialization_error().map(str::to_owned),
        launch_at_login,
    }
}

#[tauri::command]
pub fn save_settings(
    app: AppHandle,
    state: State<'_, AppState>,
    payload: SaveSettingsPayload,
) -> Result<(), String> {
    {
        let mut settings = state.settings.lock().unwrap();
        settings
            .save(&payload.configuration, &payload.api_key)
            .map_err(|e| e.to_string())?;
    }
    {
        let mut coord = state.coordinator.lock().unwrap();
        coord.suspended = false;
    }
    refresh_tray_labels(&app);
    Ok(())
}

#[tauri::command]
pub fn delete_api_key(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    {
        let mut settings = state.settings.lock().unwrap();
        settings.delete_api_key().map_err(|e| e.to_string())?;
    }
    refresh_tray_labels(&app);
    Ok(())
}

#[tauri::command]
pub async fn fetch_models(
    state: State<'_, AppState>,
    configuration: ApiConfiguration,
    api_key: String,
) -> Result<Vec<String>, String> {
    let key = {
        let trimmed = api_key.trim().to_owned();
        if trimmed.is_empty() {
            state
                .settings
                .lock()
                .unwrap()
                .read_api_key()
                .map_err(|e| e.to_string())?
        } else {
            trimmed
        }
    };
    provider_fetch_models(&state.http_client, &configuration, &key)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn test_connection(
    state: State<'_, AppState>,
    configuration: ApiConfiguration,
    api_key: String,
) -> Result<ConnectionTestResult, String> {
    let valid_config = configuration.validated().map_err(|e| e.to_string())?;
    let key = {
        let trimmed = api_key.trim().to_owned();
        if trimmed.is_empty() {
            state
                .settings
                .lock()
                .unwrap()
                .read_api_key()
                .map_err(|e| e.to_string())?
        } else {
            trimmed
        }
    };
    let snapshot = ApiCredentialsSnapshot {
        configuration: valid_config,
        api_key: key,
    };
    provider_test_connection(&state.http_client, &snapshot).await
}

#[tauri::command]
pub fn set_autostart(app: AppHandle, enabled: bool) -> Result<(), String> {
    let manager = app.autolaunch();
    let result = if enabled {
        manager.enable()
    } else {
        manager.disable()
    };
    result.map_err(|_| "Không thể cập nhật mục khởi động cùng Windows.".to_owned())?;
    refresh_tray_labels(&app);
    Ok(())
}

#[tauri::command]
pub fn get_history(state: State<'_, AppState>) -> HistoryListResponse {
    state.history.lock().unwrap().list()
}

#[tauri::command]
pub fn delete_history_entry(state: State<'_, AppState>, id: String) -> Result<(), String> {
    state
        .history
        .lock()
        .unwrap()
        .remove(&id)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn clear_history(state: State<'_, AppState>) -> Result<(), String> {
    state
        .history
        .lock()
        .unwrap()
        .remove_all()
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn set_pinned(state: State<'_, AppState>, pinned: bool) {
    state.coordinator.lock().unwrap().is_pinned = pinned;
}

#[tauri::command]
pub fn dismiss_pill(app: AppHandle) {
    hide_pill_window(&app);
}

#[tauri::command]
pub fn dismiss_settings(app: AppHandle) {
    close_settings_window(&app);
}

#[tauri::command]
pub fn dismiss_result(app: AppHandle) {
    cancel_and_hide_result(&app);
}

#[tauri::command]
pub fn cancel_request(state: State<'_, AppState>) {
    let mut coord = state.coordinator.lock().unwrap();
    coord.active_generation = None;
    coord.retry_request = None;
    if let Some(task) = coord.active_task.take() {
        task.abort();
    }
}

#[tauri::command]
pub fn save_result_size(state: State<'_, AppState>, width: f64, height: f64) {
    let _ = state.settings.lock().unwrap().save_result_size(width, height);
}

#[tauri::command]
pub fn copy_to_clipboard(text: String) -> Result<(), String> {
    set_clipboard_text(&text)
}

#[tauri::command]
pub fn retry_last_skill(app: AppHandle, state: State<'_, AppState>) {
    let retry = state.coordinator.lock().unwrap().retry_request.clone();
    if let Some((skill, text)) = retry {
        run_skill(app, state, skill, text);
    }
}

#[tauri::command]
pub fn run_skill(app: AppHandle, state: State<'_, AppState>, skill: Skill, text: String) {
    let (snapshot, panel_size) = {
        let settings = state.settings.lock().unwrap();
        if !settings.has_api_key() {
            drop(settings);
            open_settings_window(&app);
            return;
        }
        match settings.snapshot() {
            Ok(snap) => (snap, settings.result_size()),
            Err(_) => {
                drop(settings);
                open_settings_window(&app);
                return;
            }
        }
    };

    hide_pill_window(&app);

    let generation = Uuid::new_v4().to_string();
    let selection_anchor = {
        let mut coord = state.coordinator.lock().unwrap();
        if let Some(prev) = coord.active_task.take() {
            prev.abort();
        }
        coord.active_generation = Some(generation.clone());
        coord.retry_request = Some((skill, text.clone()));
        coord.is_pinned = false;
        coord.last_selection.clone()
    };

    if let Some(result_win) = app.get_webview_window("result") {
        let _ = result_win.emit(
            "result:start",
            ResultStartEvent {
                generation: generation.clone(),
                skill,
                source_text: text.clone(),
            },
        );
    }

    let result_hwnd = state.result_hwnd.load(Ordering::Acquire);
    let gen_for_show = generation.clone();
    let app_for_show = app.clone();
    let _ = app.run_on_main_thread(move || {
        let state = app_for_show.state::<AppState>();
        let is_current = state
            .coordinator
            .lock()
            .unwrap()
            .active_generation
            .as_deref()
            == Some(gen_for_show.as_str());
        if is_current {
            let monitors = monitor_work_areas(&app_for_show);
            let (x, y, w, h) = compute_floating_rect(
                panel_size.width,
                panel_size.height,
                selection_anchor.as_ref().and_then(|s| s.bounds),
                selection_anchor.as_ref().and_then(|s| s.cursor),
                &monitors,
            );
            show_result_at_on_main_thread(
                result_hwnd,
                x,
                y,
                w as i32,
                h as i32,
                &state.ignoring_result_resize,
            );
        }
    });

    let app_handle = app.clone();
    let client = state.http_client.clone();
    let model_name = snapshot.configuration.model.clone();
    let gen_for_task = generation.clone();
    let source_for_history = text.clone();

    let handle = tauri::async_runtime::spawn(async move {
        let gen_chunk = gen_for_task.clone();
        let app_chunk = app_handle.clone();
        let outcome = stream_skill(&client, &snapshot, skill, &text, move |chunk| {
            let state = app_chunk.state::<AppState>();
            let is_current = state
                .coordinator
                .lock()
                .unwrap()
                .active_generation
                .as_deref()
                == Some(gen_chunk.as_str());
            if is_current {
                if let Some(win) = app_chunk.get_webview_window("result") {
                    let _ = win.emit(
                        "result:chunk",
                        ResultChunkEvent {
                            generation: gen_chunk.clone(),
                            chunk: chunk.to_owned(),
                        },
                    );
                }
            }
        })
        .await;

        let state = app_handle.state::<AppState>();
        let is_current = state
            .coordinator
            .lock()
            .unwrap()
            .active_generation
            .as_deref()
            == Some(gen_for_task.as_str());
        if !is_current {
            return;
        }

        match outcome {
            Ok(full_text) => {
                let mut history_warning = None;
                if !full_text.trim().is_empty() {
                    let entry = HistoryEntry::new(skill, model_name, source_for_history, full_text);
                    if let Err(err) = state.history.lock().unwrap().add(entry) {
                        history_warning = Some(err.to_string());
                    }
                }
                if let Some(win) = app_handle.get_webview_window("result") {
                    let _ = win.emit(
                        "result:finished",
                        ResultFinishedEvent {
                            generation: gen_for_task.clone(),
                            history_warning,
                        },
                    );
                }
            }
            Err(err) => {
                if let Some(win) = app_handle.get_webview_window("result") {
                    let _ = win.emit(
                        "result:error",
                        ResultErrorEvent {
                            generation: gen_for_task.clone(),
                            message: err.to_string(),
                        },
                    );
                }
            }
        }

        let mut coord = state.coordinator.lock().unwrap();
        if coord.active_generation.as_deref() == Some(gen_for_task.as_str()) {
            coord.active_task = None;
        }
    });

    let mut coord = state.coordinator.lock().unwrap();
    if coord.active_generation.as_deref() == Some(generation.as_str()) {
        coord.active_task = Some(handle);
    } else {
        handle.abort();
    }
}
