use crate::commands::{open_history_window, open_settings_window, AppState};
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, Runtime};
use tauri_plugin_autostart::ManagerExt;

const ID_STATUS: &str = "tray_status";
const ID_SETTINGS: &str = "tray_settings";
const ID_HISTORY: &str = "tray_history";
const ID_AUTOSTART: &str = "tray_autostart";
const ID_QUIT: &str = "tray_quit";

pub struct TrayHandles<R: Runtime> {
    pub status_item: MenuItem<R>,
    pub autostart_item: CheckMenuItem<R>,
}

pub fn build_tray<R: Runtime>(app: &AppHandle<R>) -> tauri::Result<TrayHandles<R>> {
    let status_text = {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap();
        if settings.has_api_key() {
            format!("API đã cấu hình — {}", settings.configuration().model)
        } else {
            "Chưa cấu hình API key".to_owned()
        }
    };
    let autostart_enabled = app.autolaunch().is_enabled().unwrap_or(false);

    let title_item = MenuItem::with_id(app, "tray_title", "Dola Lite", false, None::<&str>)?;
    let status_item = MenuItem::with_id(app, ID_STATUS, &status_text, false, None::<&str>)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let settings_item =
        MenuItem::with_id(app, ID_SETTINGS, "Cài đặt API…", true, Some("CmdOrCtrl+,"))?;
    let history_item = MenuItem::with_id(app, ID_HISTORY, "Lịch sử…", true, None::<&str>)?;
    let autostart_item = CheckMenuItem::with_id(
        app,
        ID_AUTOSTART,
        "Khởi động cùng Windows",
        true,
        autostart_enabled,
        None::<&str>,
    )?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let quit_item = MenuItem::with_id(app, ID_QUIT, "Thoát", true, Some("CmdOrCtrl+Q"))?;

    let menu = Menu::with_items(
        app,
        &[
            &title_item,
            &status_item,
            &sep1,
            &settings_item,
            &history_item,
            &autostart_item,
            &sep2,
            &quit_item,
        ],
    )?;

    let mut builder = TrayIconBuilder::with_id("main-tray")
        .menu(&menu)
        .tooltip("Dola Lite")
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id.as_ref() {
            ID_SETTINGS => open_settings_window(app),
            ID_HISTORY => open_history_window(app),
            ID_AUTOSTART => {
                let manager = app.autolaunch();
                let current = manager.is_enabled().unwrap_or(false);
                if current {
                    let _ = manager.disable();
                } else {
                    let _ = manager.enable();
                }
                refresh_tray_labels(app);
            }
            ID_QUIT => {
                let state = app.state::<AppState>();
                state.shutdown();
                app.exit(0);
            }
            _ => {}
        });

    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    builder.build(app)?;

    Ok(TrayHandles {
        status_item,
        autostart_item,
    })
}

pub fn refresh_tray_labels<R: Runtime>(app: &AppHandle<R>) {
    let Some(handles) = app.try_state::<TrayHandles<R>>() else {
        return;
    };
    let status_text = {
        let state = app.state::<AppState>();
        let settings = state.settings.lock().unwrap();
        if settings.has_api_key() {
            format!("API đã cấu hình — {}", settings.configuration().model)
        } else {
            "Chưa cấu hình API key".to_owned()
        }
    };
    let _ = handles.status_item.set_text(status_text);
    let autostart_enabled = app.autolaunch().is_enabled().unwrap_or(false);
    let _ = handles.autostart_item.set_checked(autostart_enabled);
}
