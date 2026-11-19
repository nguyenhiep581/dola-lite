import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { formatTimestamp, renderMarkdownInto } from "../lib/markdown";
import { HistoryEntry, HistoryListResponse, SKILL_LABELS } from "../types/ipc";
import { createHistoryRow } from "./result";

export function mountHistoryView(root: HTMLElement): void {
  let entries: HistoryEntry[] = [];
  let selectedId: string | null = null;

  const layout = document.createElement("div");
  layout.className = "history-window";

  // Left sidebar
  const sidebar = document.createElement("aside");
  sidebar.className = "history-sidebar";

  const sidebarHeader = document.createElement("div");
  sidebarHeader.className = "history-sidebar-header";
  const sidebarTitle = document.createElement("span");
  sidebarTitle.className = "history-sidebar-title";
  sidebarTitle.textContent = "Lịch sử";
  const countEl = document.createElement("span");
  countEl.className = "history-sidebar-count";
  const sidebarSpacer = document.createElement("div");
  sidebarSpacer.className = "footer-spacer";
  const clearBtn = document.createElement("button");
  clearBtn.type = "button";
  clearBtn.className = "btn btn-quiet";
  clearBtn.textContent = "Xóa tất cả";
  sidebarHeader.append(sidebarTitle, countEl, sidebarSpacer, clearBtn);

  const listEl = document.createElement("div");
  listEl.className = "history-sidebar-list";

  sidebar.append(sidebarHeader, listEl);

  const vDivider = document.createElement("div");
  vDivider.className = "history-vertical-divider";

  // Right detail pane
  const detail = document.createElement("main");
  detail.className = "history-detail";

  const detailHeader = document.createElement("div");
  detailHeader.className = "history-detail-header";
  const detailTitle = document.createElement("h1");
  detailTitle.className = "history-detail-title";
  detailTitle.textContent = "Chưa có lịch sử";

  const copyBtn = document.createElement("button");
  copyBtn.type = "button";
  copyBtn.className = "btn";
  copyBtn.textContent = "Sao chép";
  copyBtn.disabled = true;

  const deleteBtn = document.createElement("button");
  deleteBtn.type = "button";
  deleteBtn.className = "btn";
  deleteBtn.textContent = "Xóa";
  deleteBtn.disabled = true;

  detailHeader.append(detailTitle, copyBtn, deleteBtn);

  const statusBanner = document.createElement("p");
  statusBanner.className = "status-banner";
  statusBanner.hidden = true;

  const metaCard = document.createElement("div");
  metaCard.className = "history-meta-card";
  metaCard.hidden = true;
  const metaInfo = document.createElement("div");
  metaInfo.className = "history-meta-info";
  const metaSource = document.createElement("div");
  metaSource.className = "history-meta-source";
  metaCard.append(metaInfo, metaSource);

  const editorCard = document.createElement("div");
  editorCard.className = "history-editor-card";
  const mdRoot = document.createElement("div");
  mdRoot.className = "md-root";
  editorCard.appendChild(mdRoot);

  detail.append(detailHeader, statusBanner, metaCard, editorCard);
  layout.append(sidebar, vDivider, detail);
  root.replaceChildren(layout);

  function setStatus(message: string, kind: "neutral" | "success" | "warning" | "error" = "neutral"): void {
    statusBanner.textContent = message;
    statusBanner.hidden = message.length === 0;
    statusBanner.className =
      kind === "neutral" ? "status-banner" : `status-banner is-${kind}`;
  }

  function renderList(): void {
    countEl.textContent = entries.length > 0 ? `(${entries.length})` : "";
    clearBtn.disabled = entries.length === 0;
    listEl.replaceChildren();

    if (entries.length === 0) {
      const empty = document.createElement("div");
      empty.className = "empty-state";
      empty.textContent = "Các bản dịch, tóm tắt và giải thích hoàn tất sẽ xuất hiện ở đây.";
      listEl.appendChild(empty);
      return;
    }

    entries.forEach((entry, index) => {
      const row = createHistoryRow(entry, entry.id === selectedId, () => {
        setStatus("");
        selectEntry(entry);
      });
      listEl.appendChild(row);
      if (index < entries.length - 1) {
        const div = document.createElement("div");
        div.className = "history-divider";
        listEl.appendChild(div);
      }
    });
  }

  function selectEntry(entry: HistoryEntry | null): void {
    selectedId = entry?.id ?? null;
    renderList();
    if (!entry) {
      detailTitle.textContent = "Chưa có lịch sử";
      metaCard.hidden = true;
      mdRoot.replaceChildren();
      copyBtn.disabled = true;
      deleteBtn.disabled = true;
      return;
    }
    detailTitle.textContent = SKILL_LABELS[entry.skill];
    metaInfo.textContent = `Lưu lúc ${formatTimestamp(entry.created_at)}  —  ${entry.model}`;
    metaSource.textContent = `Gốc: ${entry.source_preview}`;
    metaCard.hidden = false;
    renderMarkdownInto(mdRoot, entry.result_text);
    editorCard.scrollTop = 0;
    copyBtn.disabled = false;
    deleteBtn.disabled = false;
  }

  async function reload(): Promise<void> {
    const res = await invoke<HistoryListResponse>("get_history");
    entries = res.entries;
    if (res.has_read_error) {
      setStatus("Không đọc được lịch sử cũ. Lưu mục mới sẽ thay thế tệp lịch sử bị lỗi.", "warning");
    } else {
      setStatus("");
    }
    const next = entries.find((e) => e.id === selectedId) ?? entries[0] ?? null;
    selectEntry(next);
  }

  copyBtn.addEventListener("click", async () => {
    const entry = entries.find((e) => e.id === selectedId);
    if (!entry) return;
    try {
      await invoke("copy_to_clipboard", { text: entry.result_text });
      setStatus("Đã sao chép kết quả vào clipboard.", "success");
    } catch (error) {
      setStatus(String(error), "error");
    }
  });

  deleteBtn.addEventListener("click", async () => {
    if (!selectedId) return;
    try {
      await invoke("delete_history_entry", { id: selectedId });
      await reload();
      setStatus("Đã xóa mục khỏi lịch sử.");
    } catch (error) {
      setStatus(String(error), "error");
    }
  });

  clearBtn.addEventListener("click", async () => {
    if (entries.length === 0) return;
    if (!window.confirm("Xóa toàn bộ lịch sử? Thao tác này không thể hoàn tác.")) return;
    try {
      await invoke("clear_history");
      await reload();
      setStatus("Đã xóa toàn bộ lịch sử.");
    } catch (error) {
      setStatus(String(error), "error");
    }
  });

  void listen("history:open", () => {
    void reload();
  });

  void reload();
}
