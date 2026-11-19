/**
 * Safe DOM-only Markdown renderer matching macOS MarkdownLite:
 * headings (#, ##, ###), bullet lists (- / *), **bold**, `inline code`, and ```fenced``` blocks.
 * Never assigns untrusted HTML strings to innerHTML.
 */
export function renderMarkdownInto(container: HTMLElement, text: string): void {
  const fragment = document.createDocumentFragment();
  const lines = text.split("\n");
  let inCodeBlock = false;
  let codeLines: string[] = [];

  const flushCodeBlock = () => {
    if (codeLines.length === 0) return;
    const pre = document.createElement("pre");
    pre.className = "md-code-block";
    const code = document.createElement("code");
    code.textContent = codeLines.join("\n");
    pre.appendChild(code);
    fragment.appendChild(pre);
    codeLines = [];
  };

  for (const raw of lines) {
    if (raw.trim().startsWith("```")) {
      if (inCodeBlock) {
        flushCodeBlock();
        inCodeBlock = false;
      } else {
        inCodeBlock = true;
      }
      continue;
    }

    if (inCodeBlock) {
      codeLines.push(raw);
      continue;
    }

    if (raw.trim() === "") {
      const spacer = document.createElement("div");
      spacer.className = "md-gap";
      fragment.appendChild(spacer);
      continue;
    }

    let line = raw;
    let element: HTMLElement;
    if (line.startsWith("### ")) {
      line = line.slice(4);
      element = document.createElement("h4");
      element.className = "md-h3";
    } else if (line.startsWith("## ")) {
      line = line.slice(3);
      element = document.createElement("h3");
      element.className = "md-h2";
    } else if (line.startsWith("# ")) {
      line = line.slice(2);
      element = document.createElement("h2");
      element.className = "md-h1";
    } else if (line.startsWith("- ") || line.startsWith("* ")) {
      line = "• " + line.slice(2);
      element = document.createElement("p");
      element.className = "md-bullet";
    } else {
      element = document.createElement("p");
      element.className = "md-p";
    }

    appendInlineNodes(element, line);
    fragment.appendChild(element);
  }

  if (inCodeBlock) {
    flushCodeBlock();
  }

  container.replaceChildren(fragment);
}

const INLINE_PATTERN = /\*\*([^*\n]+)\*\*|`([^`\n]+)`/g;

function appendInlineNodes(target: HTMLElement, text: string): void {
  INLINE_PATTERN.lastIndex = 0;
  let offset = 0;
  let match: RegExpExecArray | null;

  while ((match = INLINE_PATTERN.exec(text)) !== null) {
    if (match.index > offset) {
      target.appendChild(document.createTextNode(text.slice(offset, match.index)));
    }
    if (match[1] !== undefined) {
      const strong = document.createElement("strong");
      strong.textContent = match[1];
      target.appendChild(strong);
    } else if (match[2] !== undefined) {
      const code = document.createElement("code");
      code.className = "md-inline-code";
      code.textContent = match[2];
      target.appendChild(code);
    }
    offset = match.index + match[0].length;
  }

  if (offset < text.length) {
    target.appendChild(document.createTextNode(text.slice(offset)));
  }
}

export function formatTimestamp(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return iso;
  return new Intl.DateTimeFormat("vi-VN", {
    day: "2-digit",
    month: "2-digit",
    year: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}
