pub mod commands;
pub mod history;
pub mod provider;
pub mod selection;
pub mod settings;
pub mod tray;
pub mod windows_shell;

use commands::{
    cancel_and_hide_result, cancel_request, clear_history, close_settings_window,
    copy_to_clipboard, delete_api_key, delete_history_entry, dismiss_pill, dismiss_result,
    dismiss_settings, fetch_models, get_history, get_settings, open_settings_window,
    retry_last_skill, run_skill, save_result_size, save_settings, set_autostart, set_pinned,
    test_connection, AppState,
};
use history::HistoryStore;
use settings::secrets::default_secret_store;
use settings::SettingsStore;
use std::sync::atomic::Ordering;
use tauri::{Manager, WindowEvent};
use tauri_plugin_autostart::MacosLauncher;
use windows_shell::SingleInstanceGuard;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let Some(_single_instance) = SingleInstanceGuard::acquire() else {
        return;
    };

    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            None,
        ))
        .setup(|app| {
            let data_dir = app
                .path()
                .app_data_dir()
                .unwrap_or_else(|_| std::env::temp_dir().join("DolaLite"));
            let settings_store = SettingsStore::new(data_dir.clone(), default_secret_store());
            let has_key = settings_store.has_api_key();
            let history_store = HistoryStore::new(data_dir);

            let state = AppState::new(settings_store, history_store);
            let stop_flag = state.stop_flag.clone();
            app.manage(state);

            let tray_handles = tray::build_tray(app.handle())?;
            app.manage(tray_handles);

            if let Some(pill) = app.get_webview_window("pill") {
                windows_shell::configure_non_activating_window(&pill);
            }

            // Keep utility windows alive on close (hide instead of destroying webviews)
            // and persist logical Result Panel dimensions accurately across HiDPI monitors.
            for label in ["settings", "history", "result"] {
                if let Some(win) = app.get_webview_window(label) {
                    let win_clone = win.clone();
                    let app_handle = app.handle().clone();
                    win.on_window_event(move |event| match event {
                        WindowEvent::CloseRequested { api, .. } => {
                            api.prevent_close();
                            match label {
                                "settings" => close_settings_window(&app_handle),
                                "result" => cancel_and_hide_result(&app_handle),
                                _ => {
                                    let _ = win_clone.hide();
                                }
                            }
                        }
                        WindowEvent::Resized(physical) if label == "result" => {
                            let state = app_handle.state::<AppState>();
                            if state.ignoring_result_resize.load(Ordering::SeqCst)
                                || !win_clone.is_visible().unwrap_or(false)
                            {
                                return;
                            }
                            let scale = win_clone.scale_factor().unwrap_or(1.0);
                            if scale.is_finite() && scale > 0.0 {
                                let logical_w = physical.width as f64 / scale;
                                let logical_h = physical.height as f64 / scale;
                                let _ = state
                                    .settings
                                    .lock()
                                    .unwrap()
                                    .save_result_size(logical_w, logical_h);
                            }
                        }
                        _ => {}
                    });
                }
            }

            #[cfg(windows)]
            {
                let handle = app.handle().clone();
                selection::windows_uia::spawn_selection_worker(stop_flag, move |action| {
                    match action {
                        selection::WatchAction::EmitSelection(sel) => {
                            commands::handle_selection_detected(&handle, sel);
                        }
                        selection::WatchAction::EmitDeselection => {
                            commands::handle_deselection(&handle);
                        }
                        selection::WatchAction::None => {}
                    }
                });
            }
            #[cfg(not(windows))]
            let _ = stop_flag;

            if !has_key {
                open_settings_window(app.handle());
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_settings,
            save_settings,
            delete_api_key,
            fetch_models,
            test_connection,
            set_autostart,
            get_history,
            delete_history_entry,
            clear_history,
            set_pinned,
            dismiss_pill,
            dismiss_result,
            dismiss_settings,
            cancel_request,
            save_result_size,
            copy_to_clipboard,
            retry_last_skill,
            run_skill,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Dola Lite");
}
