import AppKit

@MainActor
enum MarkdownLite {
    static func attributed(_ text: String) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        var codeBlock = false
        let lines = text.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                codeBlock.toggle()
                continue
            }
            var line = raw
            var attributes = base
            if codeBlock {
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)
                output.append(NSAttributedString(string: line, attributes: attributes))
            } else {
                if line.hasPrefix("### ") { line.removeFirst(4); attributes[.font] = NSFont.systemFont(ofSize: 14, weight: .semibold) }
                else if line.hasPrefix("## ") { line.removeFirst(3); attributes[.font] = NSFont.systemFont(ofSize: 15, weight: .semibold) }
                else if line.hasPrefix("# ") { line.removeFirst(2); attributes[.font] = NSFont.systemFont(ofSize: 17, weight: .semibold) }
                if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
                output.append(inline(line, base: attributes))
            }
            if index < lines.count - 1 { output.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        return output
    }

    private static func inline(_ text: String, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        guard let regex = try? NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*|`([^`\n]+)`"#) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let source = text as NSString
        var offset = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result.append(NSAttributedString(string: source.substring(with: NSRange(location: offset, length: match.range.location - offset)), attributes: base))
            var attributes = base
            let range: NSRange
            if match.range(at: 1).location != NSNotFound {
                range = match.range(at: 1)
                attributes[.font] = NSFont.systemFont(ofSize: 14, weight: .semibold)
            } else {
                range = match.range(at: 2)
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)
            }
            result.append(NSAttributedString(string: source.substring(with: range), attributes: attributes))
            offset = NSMaxRange(match.range)
        }
        result.append(NSAttributedString(string: source.substring(from: offset), attributes: base))
        return result
    }
}
