import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { formatTimestamp, renderMarkdownInto } from "../lib/markdown";
import {
  HistoryEntry,
  HistoryListResponse,
  ResultChunkEvent,
  ResultErrorEvent,
  ResultFinishedEvent,
  ResultStartEvent,
  SKILL_LABELS,
} from "../types/ipc";

const ICON_PIN = `<svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M6 2.5h4l-.6 3.5 2.1 2.2v1H4.5v-1l2.1-2.2L6 2.5ZM8 9.2V14" stroke="currentColor" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
const ICON_COPY = `<svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true"><rect x="5.5" y="5.5" width="7.5" height="8" rx="1.5" stroke="currentColor" stroke-width="1.35"/><path d="M10.5 5.5V4A1.5 1.5 0 0 0 9 2.5H4A1.5 1.5 0 0 0 2.5 4v5A1.5 1.5 0 0 0 4 10.5h1.5" stroke="currentColor" stroke-width="1.35"/></svg>`;
const ICON_CHECK = `<svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M3.2 8.4 6.5 11.7 12.8 4.8" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
const ICON_HISTORY = `<svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M3 8a5 5 0 1 0 1.4-3.5L3 6M3 3v3h3M8 5.2V8l2 1.2" stroke="currentColor" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
const ICON_CLOSE = `<svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" stroke-width="1.45" stroke-linecap="round"/></svg>`;

export function mountResultView(root: HTMLElement): void {
  document.body.classList.add("transparent-window");

  let activeGeneration = "";
  let fullText = "";
  let isStreaming = false;
  let isPinned = false;
  let isHistoryOpen = false;
  let selectedHistoryId: string | null = null;
  let waitingPhrase = "Đang chuẩn bị…";
  let startedAt = 0;
  let elapsedTimer: number | null = null;
  let renderScheduled = false;
  let copyTimer: number | null = null;

  const shell = document.createElement("div");
  shell.className = "result-shell";

  const card = document.createElement("div");
  card.className = "result-card";

  // Header
  const header = document.createElement("div");
  header.className = "result-header";

  const titleEl = document.createElement("div");
  titleEl.className = "result-drag-region";
  titleEl.setAttribute("data-tauri-drag-region", "");
  titleEl.textContent = "Dola Lite";

  const actions = document.createElement("div");
  actions.className = "result-actions";

  const pinBtn = makeIconButton(ICON_PIN, "Giữ cửa sổ mở");
  const copyBtn = makeIconButton(ICON_COPY, "Sao chép kết quả");
  copyBtn.disabled = true;
  const historyBtn = makeIconButton(ICON_HISTORY, "Lịch sử");
  const closeBtn = makeIconButton(ICON_CLOSE, "Đóng");

  actions.append(pinBtn, copyBtn, historyBtn, closeBtn);
  header.append(titleEl, actions);

  // Body
  const body = document.createElement("div");
  body.className = "result-body";

  const spinnerWrap = document.createElement("div");
  spinnerWrap.className = "result-spinner";
  spinnerWrap.hidden = true;
  const spinnerRing = document.createElement("div");
  spinnerRing.className = "spinner-ring";
  spinnerWrap.appendChild(spinnerRing);

  const mdRoot = document.createElement("div");
  mdRoot.className = "md-root";

  body.append(spinnerWrap, mdRoot);

  // Inline history tray
  const historyTray = document.createElement("section");
  historyTray.className = "inline-history";
  historyTray.hidden = true;

  const trayHeader = document.createElement("div");
  trayHeader.className = "inline-history-header";
  const trayTitle = document.createElement("span");
  trayTitle.textContent = "Lịch sử gần đây";
  const trayCount = document.createElement("span");
  trayCount.className = "inline-history-count";
  trayHeader.append(trayTitle, trayCount);

  const trayList = document.createElement("div");
  trayList.className = "inline-history-list";

  historyTray.append(trayHeader, trayList);

  // Footer
  const footer = document.createElement("div");
  footer.className = "result-footer";
  const statusEl = document.createElement("div");
  statusEl.className = "result-status";
  const retryBtn = document.createElement("button");
  retryBtn.type = "button";
  retryBtn.className = "btn";
  retryBtn.textContent = "Thử lại";
  retryBtn.hidden = true;
  footer.append(statusEl, retryBtn);

  card.append(header, body, historyTray, footer);
  shell.appendChild(card);
  root.replaceChildren(shell);

  function stopElapsed(): void {
    if (elapsedTimer !== null) {
      window.clearInterval(elapsedTimer);
      elapsedTimer = null;
    }
  }

  function startElapsed(): void {
    stopElapsed();
    startedAt = Date.now();
    statusEl.className = "result-status";
    statusEl.textContent = waitingPhrase;
    elapsedTimer = window.setInterval(() => {
      if (!isStreaming || fullText.length > 0) return;
      const secs = Math.floor((Date.now() - startedAt) / 1000);
      statusEl.textContent = `${waitingPhrase} ${secs}s`;
    }, 1000);
  }

  function resetCopyFeedback(): void {
    if (copyTimer !== null) {
      window.clearTimeout(copyTimer);
      copyTimer = null;
    }
    copyBtn.innerHTML = ICON_COPY;
    copyBtn.title = "Sao chép kết quả";
    copyBtn.setAttribute("aria-label", "Sao chép kết quả");
    copyBtn.classList.remove("is-active");
  }

  function renderContent(): void {
    renderScheduled = false;
    const nearBottom = body.scrollHeight - body.scrollTop - body.clientHeight <= 28;
    renderMarkdownInto(mdRoot, fullText);
    if (nearBottom) {
      body.scrollTop = body.scrollHeight;
    }
  }

  function scheduleRender(): void {
    if (renderScheduled) return;
    renderScheduled = true;
    window.setTimeout(renderContent, 40);
  }

  function setPinnedUI(pinned: boolean): void {
    isPinned = pinned;
    pinBtn.classList.toggle("is-active", pinned);
    const label = pinned ? "Bỏ ghim kết quả" : "Giữ cửa sổ mở";
    pinBtn.title = label;
    pinBtn.setAttribute("aria-label", label);
  }

  async function refreshInlineHistory(): Promise<void> {
    const response = await invoke<HistoryListResponse>("get_history");
    trayCount.textContent = response.entries.length > 0 ? `${response.entries.length} mục` : "";
    trayList.replaceChildren();
    if (response.entries.length === 0) {
      const empty = document.createElement("div");
      empty.className = "empty-state";
      empty.textContent = "Chưa có lịch sử hoàn tất";
      trayList.appendChild(empty);
      return;
    }

    response.entries.forEach((entry, index) => {
      const row = createHistoryRow(entry, entry.id === selectedHistoryId, () => {
        void selectHistoryEntry(entry);
      });
      trayList.appendChild(row);
      if (index < response.entries.length - 1) {
        const div = document.createElement("div");
        div.className = "history-divider";
        trayList.appendChild(div);
      }
    });
  }

  async function selectHistoryEntry(entry: HistoryEntry): Promise<void> {
    await invoke("cancel_request");
    stopElapsed();
    resetCopyFeedback();
    activeGeneration = "";
    isStreaming = false;
    spinnerWrap.hidden = true;
    selectedHistoryId = entry.id;
    titleEl.textContent = SKILL_LABELS[entry.skill];
    fullText = entry.result_text;
    renderMarkdownInto(mdRoot, fullText);
    body.scrollTop = 0;
    statusEl.className = "result-status";
    statusEl.textContent = `Đã lưu lúc ${formatTimestamp(entry.created_at)} (${entry.model})`;
    retryBtn.hidden = true;
    copyBtn.disabled = fullText.length === 0;
    await refreshInlineHistory();
  }

  // Controls
  pinBtn.addEventListener("click", () => {
    const next = !isPinned;
    setPinnedUI(next);
    void invoke("set_pinned", { pinned: next });
  });

  copyBtn.addEventListener("click", async () => {
    if (!fullText) return;
    try {
      await invoke("copy_to_clipboard", { text: fullText });
      resetCopyFeedback();
      copyBtn.innerHTML = ICON_CHECK;
      copyBtn.title = "Đã sao chép";
      copyBtn.setAttribute("aria-label", "Đã sao chép");
      copyBtn.classList.add("is-active");
      copyTimer = window.setTimeout(resetCopyFeedback, 1400);
    } catch (error) {
      statusEl.className = "result-status is-error";
      statusEl.textContent = String(error);
    }
  });

  historyBtn.addEventListener("click", async () => {
    isHistoryOpen = !isHistoryOpen;
    historyTray.hidden = !isHistoryOpen;
    historyBtn.classList.toggle("is-active", isHistoryOpen);
    const label = isHistoryOpen ? "Ẩn lịch sử" : "Lịch sử";
    historyBtn.title = label;
    historyBtn.setAttribute("aria-label", label);
    if (isHistoryOpen) {
      await refreshInlineHistory();
    }
  });

  function resetPanelState(): void {
    activeGeneration = "";
    isStreaming = false;
    stopElapsed();
    resetCopyFeedback();
    spinnerWrap.hidden = true;
    isHistoryOpen = false;
    historyTray.hidden = true;
    historyBtn.classList.remove("is-active");
    setPinnedUI(false);
  }

  closeBtn.addEventListener("click", () => {
    resetPanelState();
    void invoke("dismiss_result");
  });

  retryBtn.addEventListener("click", () => {
    void invoke("retry_last_skill");
  });

  window.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      closeBtn.click();
    }
  });

  void listen("result:dismiss", () => {
    resetPanelState();
  });

  // Backend streaming events
  void listen<ResultStartEvent>("result:start", (event) => {
    const { generation, skill } = event.payload;
    activeGeneration = generation;
    fullText = "";
    isStreaming = true;
    selectedHistoryId = null;
    setPinnedUI(false);
    resetCopyFeedback();
    isHistoryOpen = false;
    historyTray.hidden = true;
    historyBtn.classList.remove("is-active");
    titleEl.textContent = SKILL_LABELS[skill];
    const verb = SKILL_LABELS[skill].charAt(0).toLowerCase() + SKILL_LABELS[skill].slice(1);
    waitingPhrase = `Đang ${verb}…`;
    mdRoot.replaceChildren();
    spinnerWrap.hidden = false;
    retryBtn.hidden = true;
    copyBtn.disabled = true;
    startElapsed();
  });

  void listen<ResultChunkEvent>("result:chunk", (event) => {
    if (event.payload.generation !== activeGeneration) return;
    fullText += event.payload.chunk;
    spinnerWrap.hidden = true;
    stopElapsed();
    statusEl.className = "result-status";
    statusEl.textContent = "Đang trả lời…";
    copyBtn.disabled = false;
    scheduleRender();
  });

  void listen<ResultFinishedEvent>("result:finished", (event) => {
    if (event.payload.generation !== activeGeneration) return;
    isStreaming = false;
    spinnerWrap.hidden = true;
    stopElapsed();
    renderContent();
    copyBtn.disabled = fullText.length === 0;
    if (event.payload.history_warning) {
      statusEl.className = "result-status is-warning";
      statusEl.textContent = event.payload.history_warning;
    } else {
      statusEl.className = "result-status";
      statusEl.textContent = "Đã hoàn tất";
    }
  });

  void listen<ResultErrorEvent>("result:error", (event) => {
    if (event.payload.generation !== activeGeneration) return;
    isStreaming = false;
    spinnerWrap.hidden = true;
    stopElapsed();
    renderContent();
    statusEl.className = "result-status is-error";
    statusEl.textContent = event.payload.message;
    retryBtn.hidden = false;
    copyBtn.disabled = fullText.length === 0;
  });
}

function makeIconButton(svg: string, title: string): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "icon-btn";
  button.title = title;
  button.setAttribute("aria-label", title);
  button.innerHTML = svg;
  return button;
}

export function createHistoryRow(
  entry: HistoryEntry,
  selected: boolean,
  onClick: () => void,
): HTMLButtonElement {
  const row = document.createElement("button");
  row.type = "button";
  row.className = selected ? "history-row is-selected" : "history-row";
  row.setAttribute(
    "aria-label",
    `${SKILL_LABELS[entry.skill]}, ${formatTimestamp(entry.created_at)}, ${entry.source_preview}`,
  );

  const preview = document.createElement("div");
  preview.className = "history-row-preview";
  preview.textContent = entry.source_preview;

  const meta = document.createElement("div");
  meta.className = "history-row-meta";

  const skill = document.createElement("span");
  skill.className = "history-row-skill";
  skill.textContent = SKILL_LABELS[entry.skill];

  const date = document.createElement("span");
  date.className = "history-row-date";
  date.textContent = formatTimestamp(entry.created_at);

  meta.append(skill, date);
  row.append(preview, meta);
  row.addEventListener("click", onClick);
  return row;
}
