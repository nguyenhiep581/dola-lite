use crate::provider::ProviderError;
use serde_json::Value;

pub const MAXIMUM_EVENT_BYTES: usize = 1_048_576;

/// Byte-incremental SSE decoder matching macOS APISSEDecoder:
/// supports LF/CRLF/CR, leading UTF-8 BOM, comments, multiline data fields,
/// Chat Completions (`choices[].delta.content`), and Responses (`response.output_text.delta`).
#[derive(Default)]
pub struct SseDecoder {
    line: Vec<u8>,
    data_lines: Vec<String>,
    event_bytes: usize,
    previous_was_cr: bool,
    first_line: bool,
    event_type: Option<String>,
    is_terminal: bool,
    has_visible_content: bool,
}

impl SseDecoder {
    pub fn new() -> Self {
        Self {
            first_line: true,
            ..Self::default()
        }
    }

    pub fn is_terminal(&self) -> bool {
        self.is_terminal
    }

    pub fn append(&mut self, bytes: &[u8]) -> Result<Vec<String>, ProviderError> {
        let mut output = Vec::new();
        for &byte in bytes {
            if self.is_terminal {
                break;
            }
            if self.previous_was_cr {
                self.previous_was_cr = false;
                if byte == b'\n' {
                    continue;
                }
            }
            if byte == b'\r' || byte == b'\n' {
                self.consume_line(&mut output)?;
                self.previous_was_cr = byte == b'\r';
            } else {
                if self.line.len() >= MAXIMUM_EVENT_BYTES {
                    return Err(ProviderError::ResponseTooLarge);
                }
                self.line.push(byte);
            }
        }
        Ok(output)
    }

    pub fn finish(&mut self) -> Result<(), ProviderError> {
        if !self.is_terminal {
            return Err(if self.has_visible_content {
                ProviderError::IncompleteResponse
            } else {
                ProviderError::EmptyResponse
            });
        }
        if !self.has_visible_content {
            return Err(ProviderError::EmptyResponse);
        }
        Ok(())
    }

    fn consume_line(&mut self, output: &mut Vec<String>) -> Result<(), ProviderError> {
        let mut value =
            String::from_utf8(std::mem::take(&mut self.line)).map_err(|_| ProviderError::MalformedStream)?;
        if self.first_line {
            self.first_line = false;
            if let Some(stripped) = value.strip_prefix('\u{FEFF}') {
                value = stripped.to_owned();
            }
        }
        if value.is_empty() {
            return self.consume_event(output);
        }
        if value.starts_with(':') {
            return Ok(());
        }
        let (field, content) = match value.split_once(':') {
            Some((f, rest)) => (f, rest.strip_prefix(' ').unwrap_or(rest)),
            None => (value.as_str(), ""),
        };
        match field {
            "data" => {
                self.event_bytes = self.event_bytes.saturating_add(content.len() + 1);
                if self.event_bytes > MAXIMUM_EVENT_BYTES {
                    return Err(ProviderError::ResponseTooLarge);
                }
                self.data_lines.push(content.to_owned());
            }
            "event" => self.event_type = Some(content.to_owned()),
            _ => {}
        }
        Ok(())
    }

    fn consume_event(&mut self, output: &mut Vec<String>) -> Result<(), ProviderError> {
        let data_lines = std::mem::take(&mut self.data_lines);
        let event_type = self.event_type.take();
        self.event_bytes = 0;

        if event_type.as_deref() == Some("error") {
            return Err(ProviderError::ServerError);
        }
        if data_lines.is_empty() {
            return Ok(());
        }

        let payload = data_lines.join("\n");
        if payload.trim() == "[DONE]" {
            self.is_terminal = true;
            return Ok(());
        }

        let object: Value =
            serde_json::from_str(&payload).map_err(|_| ProviderError::MalformedStream)?;
        let map = object.as_object().ok_or(ProviderError::MalformedStream)?;
        if map.get("error").is_some_and(|v| !v.is_null()) {
            return Err(ProviderError::ServerError);
        }

        if let Some(event_name) = map.get("type").and_then(Value::as_str) {
            self.consume_responses_event(event_name, map, output)
        } else if map.contains_key("choices") {
            self.consume_chat_event(map, output)
        } else {
            Err(ProviderError::MalformedStream)
        }
    }

    fn consume_responses_event(
        &mut self,
        event_name: &str,
        map: &serde_json::Map<String, Value>,
        output: &mut Vec<String>,
    ) -> Result<(), ProviderError> {
        match event_name {
            "response.output_text.delta" => {
                let delta = map
                    .get("delta")
                    .and_then(Value::as_str)
                    .ok_or(ProviderError::MalformedStream)?;
                if !delta.is_empty() {
                    if !delta.trim().is_empty() {
                        self.has_visible_content = true;
                    }
                    output.push(delta.to_owned());
                }
                Ok(())
            }
            "response.completed" => {
                self.is_terminal = true;
                Ok(())
            }
            "response.incomplete" => {
                let reason = map
                    .get("response")
                    .and_then(|r| r.get("incomplete_details"))
                    .and_then(|d| d.get("reason"))
                    .and_then(Value::as_str);
                if reason == Some("max_output_tokens") {
                    return Err(ProviderError::TruncatedResponse);
                }
                self.is_terminal = true;
                Ok(())
            }
            "response.failed" => Err(ProviderError::ServerError),
            _ => Ok(()),
        }
    }

    fn consume_chat_event(
        &mut self,
        map: &serde_json::Map<String, Value>,
        output: &mut Vec<String>,
    ) -> Result<(), ProviderError> {
        let choices = map
            .get("choices")
            .and_then(Value::as_array)
            .ok_or(ProviderError::MalformedStream)?;

        let Some(choice) = choices
            .iter()
            .find(|c| c.get("index").and_then(Value::as_i64).unwrap_or(0) == 0)
        else {
            return Ok(());
        };

        if let Some(delta) = choice.get("delta").and_then(Value::as_object) {
            if let Some(content) = delta.get("content").filter(|v| !v.is_null()) {
                let text = content.as_str().ok_or(ProviderError::MalformedStream)?;
                if !text.is_empty() {
                    if !text.trim().is_empty() {
                        self.has_visible_content = true;
                    }
                    output.push(text.to_owned());
                }
            }
        }

        if let Some(reason) = choice.get("finish_reason").filter(|v| !v.is_null()) {
            let reason = reason.as_str().ok_or(ProviderError::MalformedStream)?;
            if reason.is_empty() {
                return Err(ProviderError::MalformedStream);
            }
            if reason == "length" {
                return Err(ProviderError::TruncatedResponse);
            }
            if reason == "error" {
                return Err(ProviderError::ServerError);
            }
            self.is_terminal = true;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_chat_deltas_across_arbitrary_utf8_boundaries() {
        let mut decoder = SseDecoder::new();
        let stream = concat!(
            "\u{FEFF}: keepalive\r\n",
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Xin \"}}]}\r\n\r\n",
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"chào 👋\"}}]}\n\n",
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n"
        );
        let mut chunks = Vec::new();
        for chunk in stream.as_bytes().chunks(3) {
            chunks.extend(decoder.append(chunk).unwrap());
        }
        decoder.finish().unwrap();
        assert_eq!(chunks.concat(), "Xin chào 👋");
    }

    #[test]
    fn decodes_responses_and_ignores_reasoning_events() {
        let mut decoder = SseDecoder::new();
        let stream = concat!(
            "data: {\"type\":\"response.reasoning.delta\",\"delta\":\"secret thought\"}\n\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Kết quả\"}\n\n",
            "data: {\"type\":\"response.completed\"}\n\n"
        );
        let chunks = decoder.append(stream.as_bytes()).unwrap();
        decoder.finish().unwrap();
        assert_eq!(chunks, vec!["Kết quả"]);
    }

    #[test]
    fn rejects_truncation_and_incomplete_eof() {
        let mut trunc = SseDecoder::new();
        let err = trunc.append(
            b"data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"},\"finish_reason\":\"length\"}]}\n\n",
        );
        assert_eq!(err, Err(ProviderError::TruncatedResponse));

        let mut eof = SseDecoder::new();
        let _ = eof
            .append(b"data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}\n\n")
            .unwrap();
        assert_eq!(eof.finish(), Err(ProviderError::IncompleteResponse));
    }
}
