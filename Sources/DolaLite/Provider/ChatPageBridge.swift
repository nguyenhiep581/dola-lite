import Foundation

enum ChatPageBridge {
    /// Selector ứng viên cho node tin nhắn bot, theo thứ tự ưu tiên (từ spike Phase 0).
    static let botSelectors = [
        ".message-item-robot", ".robot-message", "[data-message-id]",
        ".msg-content", ".markdown-body", "[class*='robot']",
    ]

    /// JSON-escape prompt rồi nhúng vào JS.
    static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let raw = String(decoding: data, as: UTF8.self)   // ["..."]
        return String(raw.dropFirst().dropLast())          // "..."
    }

    /// Probe DOM: trả về editorTag (textarea/contenteditable/none) + botSelector khớp đầu tiên.
    /// KHÔNG probe login bằng DOM text: trang guest của dola.com vẫn render editor và body
    /// không chứa "Log in"/"Đăng nhập" (nút login là icon) → login detection bằng session
    /// cookie trong DolaWebViewManager.hasDolaSession.
    /// Lưu ý: interpolate mảng Swift trực tiếp — Array.description bọc từng phần tử bằng
    /// nháy kép, cho ra JS array hợp lệ; KHÔNG map thêm nháy đơn quanh selector vì
    /// querySelectorAll("'.x'") throw SyntaxError (đã verify bằng engine thật).
    static let probeScript = """
    (() => {
      const ed = document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
      const bots = \(botSelectors);
      let botSelector = null, botCount = 0;
      for (const s of bots) {
        const n = document.querySelectorAll(s);
        if (n.length) { botSelector = s; botCount = n.length; break; }
      }
      return JSON.stringify({editorTag: ed ? ed.tagName : 'none', botSelector, botCount});
    })()
    """

    /// Focus editor + ghi baseline số bot nodes TRƯỚC khi gửi. KHÔNG set text/Enter/click
    /// bằng synthetic DOM events — editor framework của dola chỉ nhận trusted input
    /// (Enter/click/pointer-seq/execCommand đều bị chặn) → prompt được gõ thật qua
    /// NSResponder (DolaWebViewManager.typePrompt).
    static let focusAndBaselineScript = """
    (() => {
      window.__dolaLite = {baseline: 0, lastText: '', stableCount: 0, selector: null};
      const S = window.__dolaLite;
      const bots = \(botSelectors);
      for (const s of bots) {
        const n = document.querySelectorAll(s);
        if (n.length) { S.selector = s; S.baseline = n.length; break; }
      }
      const ed = document.querySelector('textarea') || document.querySelector('[contenteditable="true"]');
      if (!ed) return 'NO_EDITOR';
      ed.focus();
      return 'FOCUSED';
    })()
    """

    /// Poll node bot thứ baseline+1; stable khi text không đổi 2 poll liên tiếp.
    static let pollScript = """
    (() => {
      const S = window.__dolaLite;
      if (!S) return JSON.stringify({exists:false, text:'', stable:false, found:false});
      const nodes = document.querySelectorAll(S.selector);
      if (nodes.length <= S.baseline) return JSON.stringify({exists:false, text:'', stable:false, found:false});
      const text = (nodes[S.baseline].innerText || '').trim();
      if (text === S.lastText) S.stableCount += 1; else S.stableCount = 0;
      S.lastText = text;
      return JSON.stringify({exists:true, text, stable: S.stableCount >= 2, found:true});
    })()
    """

    struct PollResult: Decodable {
        let exists: Bool
        let text: String
        let stable: Bool
        let found: Bool
    }

    static func parsePollResult(_ json: String) throws -> PollResult {
        try JSONDecoder().decode(PollResult.self, from: Data(json.utf8))
    }
}
