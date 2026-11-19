use std::sync::Mutex;

pub const CREDENTIAL_TARGET: &str = "DolaLite/OpenAIAPIKey";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecretStoreError {
    StorageFailure,
    InvalidData,
}

impl std::fmt::Display for SecretStoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::StorageFailure => {
                write!(f, "Không đọc/ghi được API key trong Windows Credential Manager.")
            }
            Self::InvalidData => {
                write!(f, "API key đã lưu không đọc được. Hãy lưu lại key trong Cài đặt API.")
            }
        }
    }
}

pub trait SecretStore: Send + Sync {
    fn read(&self) -> Result<Option<String>, SecretStoreError>;
    fn save(&self, api_key: &str) -> Result<(), SecretStoreError>;
    fn delete(&self) -> Result<(), SecretStoreError>;
}

/// In-memory store used in unit tests and non-Windows dev builds.
#[derive(Default)]
pub struct MemorySecretStore {
    value: Mutex<Option<String>>,
}

impl MemorySecretStore {
    #[cfg(test)]
    pub fn with_key(key: &str) -> Self {
        Self {
            value: Mutex::new(Some(key.to_owned())),
        }
    }
}

impl SecretStore for MemorySecretStore {
    fn read(&self) -> Result<Option<String>, SecretStoreError> {
        Ok(self.value.lock().unwrap().clone())
    }

    fn save(&self, api_key: &str) -> Result<(), SecretStoreError> {
        *self.value.lock().unwrap() = Some(api_key.to_owned());
        Ok(())
    }

    fn delete(&self) -> Result<(), SecretStoreError> {
        *self.value.lock().unwrap() = None;
        Ok(())
    }
}

#[cfg(windows)]
pub struct WindowsCredentialStore;

#[cfg(windows)]
impl WindowsCredentialStore {
    fn wide_target() -> Vec<u16> {
        CREDENTIAL_TARGET
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect()
    }
}

#[cfg(windows)]
impl SecretStore for WindowsCredentialStore {
    fn read(&self) -> Result<Option<String>, SecretStoreError> {
        use std::ptr;
        use windows::core::PCWSTR;
        use windows::Win32::Foundation::{ERROR_NOT_FOUND, WIN32_ERROR};
        use windows::Win32::Security::Credentials::{
            CredFree, CredReadW, CREDENTIALW, CRED_TYPE_GENERIC,
        };

        let target = Self::wide_target();
        let mut cred_ptr: *mut CREDENTIALW = ptr::null_mut();
        let ok = unsafe {
            CredReadW(
                PCWSTR(target.as_ptr()),
                CRED_TYPE_GENERIC,
                Some(0),
                &mut cred_ptr,
            )
        };
        if let Err(err) = ok {
            if WIN32_ERROR::from_error(&err) == Some(ERROR_NOT_FOUND) {
                return Ok(None);
            }
            return Err(SecretStoreError::StorageFailure);
        }
        if cred_ptr.is_null() {
            return Ok(None);
        }

        struct CredGuard(*mut CREDENTIALW);
        impl Drop for CredGuard {
            fn drop(&mut self) {
                if !self.0.is_null() {
                    unsafe { CredFree(self.0.cast()) };
                }
            }
        }
        let _guard = CredGuard(cred_ptr);

        let cred = unsafe { &*cred_ptr };
        if cred.CredentialBlob.is_null() || cred.CredentialBlobSize == 0 {
            return Ok(None);
        }
        let bytes = unsafe {
            std::slice::from_raw_parts(cred.CredentialBlob, cred.CredentialBlobSize as usize)
        };
        let value = std::str::from_utf8(bytes)
            .map_err(|_| SecretStoreError::InvalidData)?
            .trim()
            .to_owned();
        if value.is_empty() {
            Ok(None)
        } else {
            Ok(Some(value))
        }
    }

    fn save(&self, api_key: &str) -> Result<(), SecretStoreError> {
        use windows::core::PWSTR;
        use windows::Win32::Security::Credentials::{
            CredWriteW, CREDENTIALW, CRED_MAX_CREDENTIAL_BLOB_SIZE, CRED_PERSIST_LOCAL_MACHINE,
            CRED_TYPE_GENERIC,
        };

        let mut blob = api_key.as_bytes().to_vec();
        if blob.len() > CRED_MAX_CREDENTIAL_BLOB_SIZE as usize {
            return Err(SecretStoreError::InvalidData);
        }
        let mut target = Self::wide_target();
        let mut user: Vec<u16> = "DolaLite"
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let cred = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: PWSTR(target.as_mut_ptr()),
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            UserName: PWSTR(user.as_mut_ptr()),
            ..Default::default()
        };
        unsafe { CredWriteW(&cred, 0) }.map_err(|_| SecretStoreError::StorageFailure)
    }

    fn delete(&self) -> Result<(), SecretStoreError> {
        use windows::core::PCWSTR;
        use windows::Win32::Foundation::{ERROR_NOT_FOUND, WIN32_ERROR};
        use windows::Win32::Security::Credentials::{CredDeleteW, CRED_TYPE_GENERIC};

        let target = Self::wide_target();
        match unsafe { CredDeleteW(PCWSTR(target.as_ptr()), CRED_TYPE_GENERIC, Some(0)) } {
            Ok(()) => Ok(()),
            Err(err) if WIN32_ERROR::from_error(&err) == Some(ERROR_NOT_FOUND) => Ok(()),
            Err(_) => Err(SecretStoreError::StorageFailure),
        }
    }
}

pub fn default_secret_store() -> Box<dyn SecretStore> {
    #[cfg(windows)]
    {
        Box::new(WindowsCredentialStore)
    }
    #[cfg(not(windows))]
    {
        Box::new(MemorySecretStore::default())
    }
}
