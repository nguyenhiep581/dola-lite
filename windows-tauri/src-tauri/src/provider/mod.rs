pub mod sse;

use crate::settings::{
    validated_api_key, ApiConfiguration, ApiCredentialsSnapshot, SettingsError, RESPONSES_WIRE,
};
use futures_util::StreamExt;
use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, AUTHORIZATION, CONTENT_TYPE, USER_AGENT};
use reqwest::{Client, redirect};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sse::SseDecoder;
use std::collections::BTreeSet;
use std::time::{Duration, Instant};

pub const ALLOWED_CLIENT_USER_AGENT: &str = "codex_cli_rs/0.42.0";
const MAXIMUM_MODELS_RESPONSE_BYTES: usize = 1_048_576;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(90);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Skill {
    Translate,
    Summarize,
    Explain,
}

impl Skill {
    pub fn system_prompt(self) -> &'static str {
        match self {
            Self::Translate => concat!(
                "You are an expert English-Vietnamese translator.\n\n",
                "Translate the user's text naturally.\n\n",
                "Requirements:\n",
                "- The source text may be in any language; always translate it into Vietnamese.\n",
                "- Preserve the original meaning.\n",
                "- Use natural, fluent Vietnamese.\n",
                "- Avoid literal word-by-word translation.\n",
                "- Preserve technical terminology consistently.\n",
                "- Preserve Markdown, HTML, JSON and placeholders.\n",
                "- Never omit information.\n",
                "- Do not summarize or explain.\n",
                "- Maintain the original tone and style.\n\n",
                "Return only the Vietnamese translation."
            ),
            Self::Summarize => concat!(
                "You are an expert content summarizer.\n\n",
                "Summarize the user's text accurately and clearly.\n\n",
                "Requirements:\n",
                "- Identify and preserve the main ideas and key information.\n",
                "- Remove repetition, unnecessary details, and irrelevant examples.\n",
                "- Preserve important facts, names, dates, numbers, technical terms, and conclusions.\n",
                "- Do not introduce information that is not present in the source.\n",
                "- Maintain the original meaning, intent, and tone.\n",
                "- Use clear, natural, concise language.\n",
                "- Organize the summary into bullet points when appropriate.\n",
                "- Highlight important decisions, conclusions, and action items if present.\n",
                "- If the source contains uncertainty or conflicting information, preserve it rather than making assumptions.\n\n",
                "Length:\n",
                "- Produce a concise summary, approximately 20–30% of the original length.\n",
                "- For very short text, provide a proportionally shorter summary.\n\n",
                "Language:\n",
                "- Write the summary in Vietnamese.\n\n",
                "Output:\n",
                "- Return only the summary.\n",
                "- Do not include introductory phrases such as \"Here is the summary\"."
            ),
            Self::Explain => concat!(
                "You are a patient teacher who explains complex concepts in simple language.\n\n",
                "Explain the user's text as if you were teaching someone with no prior knowledge of the topic.\n\n",
                "Rules:\n",
                "- Use simple, everyday language.\n",
                "- Avoid unnecessary technical jargon.\n",
                "- Break complicated ideas into smaller steps.\n",
                "- Use relatable examples and analogies.\n",
                "- Explain unfamiliar concepts before using them.\n",
                "- Preserve the original meaning and important details.\n",
                "- Do not oversimplify to the point of becoming inaccurate.\n",
                "- Do not add unsupported information.\n\n",
                "Structure — dùng đúng các đề mục sau bằng tiếng Việt:\n",
                "1. **Nôm na:** giải thích ý chính.\n",
                "2. **Cách hoạt động:** chia nhỏ khái niệm thành các bước đơn giản (nếu áp dụng được).\n",
                "3. **Ví dụ:** một ví dụ thực tế dễ liên tưởng.\n",
                "4. **Điều cần nhớ:** tóm lại điều người đọc cần ghi nhớ.\n\n",
                "Respond in Vietnamese. Return only the explanation."
            ),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderError {
    Settings(SettingsError),
    Unauthorized,
    Forbidden,
    RateLimited,
    ServerUnavailable,
    HttpStatus(u16),
    Timeout,
    Network,
    InvalidResponse,
    MalformedStream,
    ResponseTooLarge,
    ServerError,
    EmptyResponse,
    IncompleteResponse,
    TruncatedResponse,
}

impl From<SettingsError> for ProviderError {
    fn from(value: SettingsError) -> Self {
        Self::Settings(value)
    }
}

impl ProviderError {
    pub fn from_status(status: u16) -> Option<Self> {
        match status {
            200..=299 => None,
            401 => Some(Self::Unauthorized),
            403 => Some(Self::Forbidden),
            429 => Some(Self::RateLimited),
            500..=599 => Some(Self::ServerUnavailable),
            other => Some(Self::HttpStatus(other)),
        }
    }

    pub fn from_reqwest(err: &reqwest::Error) -> Self {
        if err.is_timeout() {
            Self::Timeout
        } else {
            Self::Network
        }
    }
}

impl std::fmt::Display for ProviderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Settings(err) => write!(f, "{err}"),
            Self::Unauthorized => write!(
                f,
                "API key không hợp lệ hoặc đã hết hạn. Hãy kiểm tra Cài đặt API."
            ),
            Self::Forbidden => write!(
                f,
                "Nhà cung cấp từ chối yêu cầu (HTTP 403). Hãy kiểm tra quyền của key, model và ứng dụng khách."
            ),
            Self::RateLimited => {
                write!(f, "Đã vượt giới hạn yêu cầu API. Vui lòng thử lại sau.")
            }
            Self::ServerUnavailable => {
                write!(f, "Máy chủ API đang gặp sự cố. Vui lòng thử lại sau.")
            }
            Self::HttpStatus(code) => write!(
                f,
                "Yêu cầu API thất bại (HTTP {code}). Hãy kiểm tra cấu hình API."
            ),
            Self::Timeout => {
                write!(f, "Hết thời gian chờ phản hồi từ API. Vui lòng thử lại.")
            }
            Self::Network => {
                write!(f, "Không thể kết nối đến API. Hãy kiểm tra mạng và địa chỉ API.")
            }
            Self::InvalidResponse => write!(f, "API trả về phản hồi không hợp lệ."),
            Self::MalformedStream => {
                write!(f, "Không đọc được luồng phản hồi từ API. Vui lòng thử lại.")
            }
            Self::ResponseTooLarge => {
                write!(f, "Luồng phản hồi từ API vượt giới hạn xử lý.")
            }
            Self::ServerError => write!(
                f,
                "API báo lỗi khi tạo phản hồi. Hãy kiểm tra cấu hình và thử lại."
            ),
            Self::EmptyResponse => {
                write!(f, "API không trả về nội dung. Vui lòng thử lại.")
            }
            Self::IncompleteResponse => write!(
                f,
                "Kết nối API kết thúc trước khi phản hồi hoàn tất. Vui lòng thử lại."
            ),
            Self::TruncatedResponse => {
                write!(f, "Phản hồi bị cắt do đạt giới hạn độ dài của model.")
            }
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ConnectionTestResult {
    pub received: bool,
    pub elapsed_seconds: f64,
}

pub fn build_http_client() -> Result<Client, ProviderError> {
    // Disallow redirects so Authorization headers are never forwarded to another host.
    Client::builder()
        .redirect(redirect::Policy::none())
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|_| ProviderError::Network)
}

pub struct BuiltRequest {
    pub url: String,
    pub headers: HeaderMap,
    pub body: Option<Vec<u8>>,
}

pub fn build_stream_request(
    snapshot: &ApiCredentialsSnapshot,
    skill: Skill,
    text: &str,
) -> Result<BuiltRequest, ProviderError> {
    let config = snapshot.configuration.validated()?;
    let key = validated_api_key(&snapshot.api_key)?;
    let path = if config.wire_api == RESPONSES_WIRE {
        "/responses"
    } else {
        "/chat/completions"
    };
    let url = format!("{}{path}", config.base_url);

    let mut headers = HeaderMap::new();
    headers.insert(USER_AGENT, HeaderValue::from_static(ALLOWED_CLIENT_USER_AGENT));
    headers.insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer {key}")).map_err(|_| SettingsError::InvalidApiKey)?,
    );
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers.insert(ACCEPT, HeaderValue::from_static("text/event-stream"));

    let payload = if config.wire_api == RESPONSES_WIRE {
        let effort = if skill == Skill::Translate {
            "low"
        } else {
            config.reasoning_effort.as_str()
        };
        json!({
            "model": config.model,
            "stream": true,
            "instructions": skill.system_prompt(),
            "input": text,
            "reasoning": { "effort": effort }
        })
    } else {
        json!({
            "model": config.model,
            "stream": true,
            "messages": [
                { "role": "system", "content": skill.system_prompt() },
                { "role": "user", "content": text }
            ]
        })
    };

    let body = serde_json::to_vec(&payload).map_err(|_| ProviderError::InvalidResponse)?;
    Ok(BuiltRequest {
        url,
        headers,
        body: Some(body),
    })
}

pub fn build_models_request(
    configuration: &ApiConfiguration,
    api_key: &str,
) -> Result<BuiltRequest, ProviderError> {
    let base_url = configuration.validated_base_url()?;
    let key = validated_api_key(api_key)?;
    let url = format!("{base_url}/models");

    let mut headers = HeaderMap::new();
    headers.insert(USER_AGENT, HeaderValue::from_static(ALLOWED_CLIENT_USER_AGENT));
    headers.insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer {key}")).map_err(|_| SettingsError::InvalidApiKey)?,
    );
    headers.insert(ACCEPT, HeaderValue::from_static("application/json"));

    Ok(BuiltRequest {
        url,
        headers,
        body: None,
    })
}

pub fn parse_models_payload(bytes: &[u8]) -> Result<Vec<String>, ProviderError> {
    let payload: Value =
        serde_json::from_slice(bytes).map_err(|_| ProviderError::InvalidResponse)?;
    let entries = payload
        .get("data")
        .and_then(Value::as_array)
        .ok_or(ProviderError::InvalidResponse)?;
    let mut ids = BTreeSet::new();
    for entry in entries {
        if let Some(id) = entry.get("id").and_then(Value::as_str) {
            let trimmed = id.trim();
            if !trimmed.is_empty() && !trimmed.chars().any(char::is_control) {
                ids.insert(trimmed.to_owned());
            }
        }
    }
    Ok(ids.into_iter().collect())
}

pub async fn fetch_models(
    client: &Client,
    configuration: &ApiConfiguration,
    api_key: &str,
) -> Result<Vec<String>, ProviderError> {
    let built = build_models_request(configuration, api_key)?;
    let response = client
        .get(&built.url)
        .headers(built.headers)
        .send()
        .await
        .map_err(|err| ProviderError::from_reqwest(&err))?;

    if let Some(err) = ProviderError::from_status(response.status().as_u16()) {
        return Err(err);
    }

    let mut bytes = Vec::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|err| ProviderError::from_reqwest(&err))?;
        if bytes.len().saturating_add(chunk.len()) > MAXIMUM_MODELS_RESPONSE_BYTES {
            return Err(ProviderError::ResponseTooLarge);
        }
        bytes.extend_from_slice(&chunk);
    }
    parse_models_payload(&bytes)
}

pub async fn stream_skill<F>(
    client: &Client,
    snapshot: &ApiCredentialsSnapshot,
    skill: Skill,
    text: &str,
    mut on_chunk: F,
) -> Result<String, ProviderError>
where
    F: FnMut(&str),
{
    let built = build_stream_request(snapshot, skill, text)?;
    let response = client
        .post(&built.url)
        .headers(built.headers)
        .body(built.body.unwrap_or_default())
        .send()
        .await
        .map_err(|err| ProviderError::from_reqwest(&err))?;

    if let Some(err) = ProviderError::from_status(response.status().as_u16()) {
        return Err(err);
    }

    let mut decoder = SseDecoder::new();
    let mut full = String::new();
    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|err| ProviderError::from_reqwest(&err))?;
        for delta in decoder.append(&chunk)? {
            full.push_str(&delta);
            on_chunk(&delta);
        }
        if decoder.is_terminal() {
            break;
        }
    }
    decoder.finish()?;
    Ok(full)
}

pub async fn test_connection(
    client: &Client,
    snapshot: &ApiCredentialsSnapshot,
) -> Result<ConnectionTestResult, String> {
    let sample = "A clear, natural translation should preserve the original meaning while remaining concise and easy to understand.";
    let started = Instant::now();
    match stream_skill(client, snapshot, Skill::Translate, sample, |_| {}).await {
        Ok(text) => Ok(ConnectionTestResult {
            received: !text.trim().is_empty(),
            elapsed_seconds: started.elapsed().as_secs_f64(),
        }),
        Err(err) => Err(format!(
            "{err} (chờ {:.2} giây).",
            started.elapsed().as_secs_f64()
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::CHAT_WIRE;

    #[test]
    fn builds_models_request_when_model_is_blank() {
        let cfg = ApiConfiguration {
            base_url: "https://api.example.test/v1/".to_owned(),
            model: "  ".to_owned(),
            reasoning_effort: "high".to_owned(),
            wire_api: CHAT_WIRE.to_owned(),
        };
        let req = build_models_request(&cfg, "secret-key").unwrap();
        assert_eq!(req.url, "https://api.example.test/v1/models");
        assert_eq!(req.headers.get(AUTHORIZATION).unwrap(), "Bearer secret-key");
    }

    #[test]
    fn parses_deduplicated_sorted_models() {
        let raw = br#"{"data":[{"id":"z-model"},{"id":"a-model"},{"id":"z-model"},{"id":"  "}]}"#;
        assert_eq!(
            parse_models_payload(raw).unwrap(),
            vec!["a-model".to_owned(), "z-model".to_owned()]
        );
    }

    #[test]
    fn translate_uses_low_reasoning_on_responses_wire() {
        let snap = ApiCredentialsSnapshot {
            configuration: ApiConfiguration {
                base_url: "https://api.example.test/v1".to_owned(),
                model: "m".to_owned(),
                reasoning_effort: "high".to_owned(),
                wire_api: RESPONSES_WIRE.to_owned(),
            },
            api_key: "key".to_owned(),
        };
        let req = build_stream_request(&snap, Skill::Translate, "hello").unwrap();
        let body: Value = serde_json::from_slice(req.body.as_deref().unwrap()).unwrap();
        assert_eq!(body["reasoning"]["effort"], "low");

        let req_explain = build_stream_request(&snap, Skill::Explain, "hello").unwrap();
        let body_explain: Value =
            serde_json::from_slice(req_explain.body.as_deref().unwrap()).unwrap();
        assert_eq!(body_explain["reasoning"]["effort"], "high");
    }
}
