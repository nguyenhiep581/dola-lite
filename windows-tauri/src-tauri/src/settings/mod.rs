pub mod secrets;

use secrets::{SecretStore, SecretStoreError};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use url::Url;

pub const CHAT_WIRE: &str = "chat";
pub const RESPONSES_WIRE: &str = "responses";
pub const DEFAULT_BASE_URL: &str = "https://integrate.api.nvidia.com/v1";
pub const DEFAULT_MODEL: &str = "nvidia/nemotron-3.5-bolt-e4b";
pub const DEFAULT_EFFORT: &str = "high";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApiConfiguration {
    #[serde(default = "default_base_url")]
    pub base_url: String,
    #[serde(default = "default_model")]
    pub model: String,
    #[serde(default = "default_effort")]
    pub reasoning_effort: String,
    #[serde(default = "default_wire")]
    pub wire_api: String,
}

fn default_base_url() -> String {
    DEFAULT_BASE_URL.to_owned()
}
fn default_model() -> String {
    DEFAULT_MODEL.to_owned()
}
fn default_effort() -> String {
    DEFAULT_EFFORT.to_owned()
}
fn default_wire() -> String {
    CHAT_WIRE.to_owned()
}

impl Default for ApiConfiguration {
    fn default() -> Self {
        Self {
            base_url: default_base_url(),
            model: default_model(),
            reasoning_effort: default_effort(),
            wire_api: default_wire(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct PanelSize {
    pub width: f64,
    pub height: f64,
}

impl Default for PanelSize {
    fn default() -> Self {
        Self {
            width: 400.0,
            height: 360.0,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct PersistedSettings {
    #[serde(default)]
    configuration: ApiConfiguration,
    #[serde(default)]
    result_size: Option<PanelSize>,
}

#[derive(Debug, Clone)]
pub struct ApiCredentialsSnapshot {
    pub configuration: ApiConfiguration,
    pub api_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SettingsError {
    InvalidBaseUrl,
    InvalidModel,
    InvalidReasoningEffort,
    InvalidWireApi,
    MissingApiKey,
    InvalidApiKey,
    StorageFailure,
    InvalidCredentialData,
}

impl std::fmt::Display for SettingsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidBaseUrl => write!(
                f,
                "Địa chỉ API phải là URL HTTP hoặc HTTPS hợp lệ, không chứa tài khoản, query hay fragment."
            ),
            Self::InvalidModel => {
                write!(f, "Tên model không được để trống hoặc chứa ký tự điều khiển.")
            }
            Self::InvalidReasoningEffort => {
                write!(f, "Mức suy luận phải là low, medium hoặc high.")
            }
            Self::InvalidWireApi => {
                write!(f, "Kiểu API phải là Chat Completions hoặc Responses.")
            }
            Self::MissingApiKey => {
                write!(f, "Chưa có API key. Hãy mở Cài đặt API để nhập key.")
            }
            Self::InvalidApiKey => {
                write!(f, "API key không hợp lệ. Hãy nhập lại key trong Cài đặt API.")
            }
            Self::StorageFailure => {
                write!(f, "Không đọc/ghi được cấu hình hoặc API key. Hãy thử lại.")
            }
            Self::InvalidCredentialData => {
                write!(f, "API key đã lưu không đọc được. Hãy lưu lại key trong Cài đặt API.")
            }
        }
    }
}

impl From<SecretStoreError> for SettingsError {
    fn from(value: SecretStoreError) -> Self {
        match value {
            SecretStoreError::StorageFailure => Self::StorageFailure,
            SecretStoreError::InvalidData => Self::InvalidCredentialData,
        }
    }
}

impl ApiConfiguration {
    pub fn validated_base_url(&self) -> Result<String, SettingsError> {
        let trimmed = self.base_url.trim();
        if trimmed.is_empty() || trimmed.chars().any(char::is_control) {
            return Err(SettingsError::InvalidBaseUrl);
        }
        let parsed = Url::parse(trimmed).map_err(|_| SettingsError::InvalidBaseUrl)?;
        let scheme = parsed.scheme();
        if (scheme != "https" && scheme != "http")
            || parsed.host_str().map(str::is_empty).unwrap_or(true)
            || !parsed.username().is_empty()
            || parsed.password().is_some()
            || parsed.query().is_some()
            || parsed.fragment().is_some()
        {
            return Err(SettingsError::InvalidBaseUrl);
        }
        Ok(trimmed.trim_end_matches('/').to_owned())
    }

    pub fn validated(&self) -> Result<Self, SettingsError> {
        let base_url = self.validated_base_url()?;
        let model = self.model.trim().to_owned();
        if model.is_empty() || model.chars().any(char::is_control) {
            return Err(SettingsError::InvalidModel);
        }
        let wire_api = self.wire_api.trim().to_owned();
        if wire_api != CHAT_WIRE && wire_api != RESPONSES_WIRE {
            return Err(SettingsError::InvalidWireApi);
        }
        let reasoning_effort = self.reasoning_effort.trim().to_lowercase();
        if !matches!(reasoning_effort.as_str(), "low" | "medium" | "high") {
            return Err(SettingsError::InvalidReasoningEffort);
        }
        Ok(Self {
            base_url,
            model,
            reasoning_effort,
            wire_api,
        })
    }
}

pub fn validated_api_key(key: &str) -> Result<String, SettingsError> {
    let trimmed = key.trim();
    if trimmed.is_empty() {
        return Err(SettingsError::MissingApiKey);
    }
    if trimmed.chars().any(char::is_control) {
        return Err(SettingsError::InvalidApiKey);
    }
    Ok(trimmed.to_owned())
}

pub struct SettingsStore {
    file_path: PathBuf,
    secrets: Box<dyn SecretStore>,
    configuration: ApiConfiguration,
    result_size: PanelSize,
    result_size_dirty: bool,
    initialization_error: Option<String>,
}

impl SettingsStore {
    pub fn new(directory: PathBuf, secrets: Box<dyn SecretStore>) -> Self {
        let file_path = directory.join("settings.json");
        let mut store = Self {
            file_path,
            secrets,
            configuration: ApiConfiguration::default(),
            result_size: PanelSize::default(),
            result_size_dirty: false,
            initialization_error: None,
        };
        store.load();
        store
    }

    fn load(&mut self) {
        if !self.file_path.exists() {
            return;
        }
        match fs::read(&self.file_path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<PersistedSettings>(&bytes).ok())
        {
            Some(persisted) => {
                match persisted.configuration.validated() {
                    Ok(valid) => self.configuration = valid,
                    Err(_) => {
                        self.configuration = ApiConfiguration::default();
                        self.initialization_error = Some(
                            "Không đọc được cấu hình API đã lưu. Đang dùng cấu hình mặc định."
                                .to_owned(),
                        );
                    }
                }
                if let Some(size) = persisted.result_size {
                    if size.width.is_finite()
                        && size.height.is_finite()
                        && size.width >= 320.0
                        && size.height >= 240.0
                    {
                        self.result_size = size;
                    }
                }
            }
            None => {
                self.configuration = ApiConfiguration::default();
                self.initialization_error = Some(
                    "Không đọc được cấu hình API đã lưu. Đang dùng cấu hình mặc định.".to_owned(),
                );
            }
        }
    }

    pub fn configuration(&self) -> &ApiConfiguration {
        &self.configuration
    }

    pub fn result_size(&self) -> PanelSize {
        self.result_size
    }

    pub fn initialization_error(&self) -> Option<&str> {
        self.initialization_error.as_deref()
    }

    pub fn has_api_key(&self) -> bool {
        matches!(self.secrets.read(), Ok(Some(ref key)) if !key.trim().is_empty())
    }

    pub fn read_api_key(&self) -> Result<String, SettingsError> {
        let raw = self.secrets.read()?.ok_or(SettingsError::MissingApiKey)?;
        validated_api_key(&raw)
    }

    pub fn snapshot(&self) -> Result<ApiCredentialsSnapshot, SettingsError> {
        let configuration = self.configuration.validated()?;
        let api_key = self.read_api_key()?;
        Ok(ApiCredentialsSnapshot {
            configuration,
            api_key,
        })
    }

    pub fn save(&mut self, config: &ApiConfiguration, entered_key: &str) -> Result<(), SettingsError> {
        let valid_config = config.validated()?;
        let trimmed_key = entered_key.trim();
        let key_to_write = if trimmed_key.is_empty() {
            // Blank key field preserves an existing stored key.
            let _ = self.read_api_key()?;
            None
        } else {
            Some(validated_api_key(trimmed_key)?)
        };

        if let Some(ref key) = key_to_write {
            self.secrets.save(key)?;
        }

        let persisted = PersistedSettings {
            configuration: valid_config.clone(),
            result_size: Some(self.result_size),
        };
        write_json_atomic(&self.file_path, &persisted)?;
        self.configuration = valid_config;
        self.initialization_error = None;
        Ok(())
    }

    pub fn set_result_size_in_memory(&mut self, width: f64, height: f64) {
        if !width.is_finite() || !height.is_finite() || width < 100.0 || height < 100.0 {
            return;
        }
        let next = PanelSize {
            width: width.clamp(320.0, 1400.0).round(),
            height: height.clamp(240.0, 1000.0).round(),
        };
        if (next.width - self.result_size.width).abs() >= 1.0
            || (next.height - self.result_size.height).abs() >= 1.0
        {
            self.result_size = next;
            self.result_size_dirty = true;
        }
    }

    pub fn persist_result_size_if_dirty(&mut self) -> Result<(), SettingsError> {
        if !self.result_size_dirty {
            return Ok(());
        }
        let persisted = PersistedSettings {
            configuration: self.configuration.clone(),
            result_size: Some(self.result_size),
        };
        write_json_atomic(&self.file_path, &persisted)?;
        self.result_size_dirty = false;
        Ok(())
    }

    pub fn save_result_size(&mut self, width: f64, height: f64) -> Result<(), SettingsError> {
        self.set_result_size_in_memory(width, height);
        self.persist_result_size_if_dirty()
    }

    pub fn delete_api_key(&mut self) -> Result<(), SettingsError> {
        self.secrets.delete()?;
        Ok(())
    }
}

pub fn write_json_atomic<T: Serialize>(path: &Path, value: &T) -> Result<(), SettingsError> {
    let parent = path.parent().ok_or(SettingsError::StorageFailure)?;
    fs::create_dir_all(parent).map_err(|_| SettingsError::StorageFailure)?;
    let bytes = serde_json::to_vec_pretty(value).map_err(|_| SettingsError::StorageFailure)?;
    let tmp = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("data"),
        uuid::Uuid::new_v4()
    ));
    fs::write(&tmp, &bytes).map_err(|_| SettingsError::StorageFailure)?;
    if fs::rename(&tmp, path).is_err() {
        // On Windows, rename over an existing file can fail; replace cleanly.
        let _ = fs::remove_file(path);
        fs::rename(&tmp, path).map_err(|_| {
            let _ = fs::remove_file(&tmp);
            SettingsError::StorageFailure
        })?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use secrets::MemorySecretStore;

    #[test]
    fn validates_base_url_without_requiring_model() {
        let cfg = ApiConfiguration {
            base_url: " https://api.example.test/v1/// ".to_owned(),
            model: "   ".to_owned(),
            reasoning_effort: "high".to_owned(),
            wire_api: CHAT_WIRE.to_owned(),
        };
        assert_eq!(cfg.validated_base_url().unwrap(), "https://api.example.test/v1");
        assert_eq!(cfg.validated(), Err(SettingsError::InvalidModel));
    }

    #[test]
    fn rejects_unsafe_base_urls() {
        for bad in [
            "",
            "file:///tmp/key",
            "https://user:pass@api.example.test/v1",
            "https://api.example.test/v1?k=1",
            "https://api.example.test/v1#frag",
        ] {
            let cfg = ApiConfiguration {
                base_url: bad.to_owned(),
                ..Default::default()
            };
            assert_eq!(cfg.validated_base_url(), Err(SettingsError::InvalidBaseUrl));
        }
    }

    #[test]
    fn blank_key_preserves_existing_secret_and_round_trips() {
        let dir = std::env::temp_dir().join(format!("dola-settings-test-{}", uuid::Uuid::new_v4()));
        let mut store = SettingsStore::new(dir.clone(), Box::new(MemorySecretStore::with_key("secret-1")));
        let next = ApiConfiguration {
            base_url: "https://api.openai.com/v1".to_owned(),
            model: "gpt-4o-mini".to_owned(),
            reasoning_effort: "medium".to_owned(),
            wire_api: RESPONSES_WIRE.to_owned(),
        };
        store.save(&next, "   ").unwrap();
        assert_eq!(store.snapshot().unwrap().api_key, "secret-1");
        assert_eq!(store.configuration().model, "gpt-4o-mini");

        let reloaded = SettingsStore::new(dir.clone(), Box::new(MemorySecretStore::with_key("secret-1")));
        assert_eq!(reloaded.configuration(), &next);
        let _ = fs::remove_dir_all(&dir);
    }
}
