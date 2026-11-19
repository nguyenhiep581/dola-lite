import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  ApiConfiguration,
  ConnectionTestResult,
  ReasoningEffort,
  SettingsViewModel,
  WireApi,
} from "../types/ipc";

export function mountSettingsView(root: HTMLElement): void {
  const page = document.createElement("form");
  page.className = "settings-page";
  page.noValidate = true;

  const card = document.createElement("div");
  card.className = "form-card";

  const baseUrlInput = makeInput("url", "https://integrate.api.nvidia.com/v1");
  const modelInput = makeInput("text", "nvidia/nemotron-3.5-bolt-e4b");
  modelInput.setAttribute("list", "dola-model-datalist");
  const modelDataList = document.createElement("datalist");
  modelDataList.id = "dola-model-datalist";

  const fetchModelsBtn = document.createElement("button");
  fetchModelsBtn.type = "button";
  fetchModelsBtn.className = "btn";
  fetchModelsBtn.textContent = "Tải model";

  const keyInput = makeInput("text", "Nhập API key");
  keyInput.autocomplete = "off";
  keyInput.spellcheck = false;

  const wireSelect = document.createElement("select");
  wireSelect.className = "select-input";
  wireSelect.append(
    new Option("Chat Completions", "chat"),
    new Option("Responses (Xingchi)", "responses"),
  );

  const effortSelect = document.createElement("select");
  effortSelect.className = "select-input";
  effortSelect.append(
    new Option("low", "low"),
    new Option("medium", "medium"),
    new Option("high", "high"),
  );

  // Model row with button
  const modelGroup = document.createElement("div");
  modelGroup.className = "field-group";
  const modelLabel = document.createElement("label");
  modelLabel.className = "field-label";
  modelLabel.textContent = "Model";
  const modelRow = document.createElement("div");
  modelRow.className = "field-row";
  modelRow.append(modelInput, fetchModelsBtn);
  modelGroup.append(modelLabel, modelRow, modelDataList);

  // 2-column paired options row
  const optionsGrid = document.createElement("div");
  optionsGrid.className = "field-grid-2";
  optionsGrid.append(
    wrapField("Kiểu API", wireSelect),
    wrapField("Tóm tắt / Giải thích", effortSelect),
  );

  card.append(
    wrapField("Base URL", baseUrlInput),
    modelGroup,
    wrapField("API key", keyInput),
    optionsGrid,
  );

  // Launch at Windows login
  const autostartLabel = document.createElement("label");
  autostartLabel.className = "checkbox-row";
  const autostartCheckbox = document.createElement("input");
  autostartCheckbox.type = "checkbox";
  const autostartText = document.createElement("span");
  autostartText.textContent = "Khởi động Dola Lite cùng Windows";
  autostartLabel.append(autostartCheckbox, autostartText);

  const footnote = document.createElement("p");
  footnote.className = "footnote";
  footnote.textContent =
    "Dịch luôn dùng mức low để ưu tiên tốc độ. Để trống API key để giữ key đã lưu trong Windows Credential Manager.";

  const statusBanner = document.createElement("p");
  statusBanner.className = "status-banner";
  statusBanner.hidden = true;

  const divider = document.createElement("div");
  divider.className = "footer-divider";

  const footer = document.createElement("div");
  footer.className = "footer-bar";

  const deleteBtn = document.createElement("button");
  deleteBtn.type = "button";
  deleteBtn.className = "btn";
  deleteBtn.textContent = "Xóa key";

  const testBtn = document.createElement("button");
  testBtn.type = "button";
  testBtn.className = "btn";
  testBtn.textContent = "Kiểm tra kết nối";

  const spacer = document.createElement("div");
  spacer.className = "footer-spacer";

  const cancelBtn = document.createElement("button");
  cancelBtn.type = "button";
  cancelBtn.className = "btn";
  cancelBtn.textContent = "Hủy";

  const saveBtn = document.createElement("button");
  saveBtn.type = "submit";
  saveBtn.className = "btn btn-primary";
  saveBtn.textContent = "Lưu";

  footer.append(deleteBtn, testBtn, spacer, cancelBtn, saveBtn);
  page.append(card, autostartLabel, footnote, statusBanner, divider, footer);
  root.replaceChildren(page);

  let testGeneration = 0;
  let fetchGeneration = 0;

  function setStatus(message: string, kind: "neutral" | "success" | "warning" | "error" = "neutral"): void {
    statusBanner.textContent = message;
    statusBanner.hidden = message.length === 0;
    statusBanner.className =
      kind === "neutral" ? "status-banner" : `status-banner is-${kind}`;
  }

  function draftConfig(): ApiConfiguration {
    return {
      base_url: baseUrlInput.value,
      model: modelInput.value,
      wire_api: wireSelect.value as WireApi,
      reasoning_effort: effortSelect.value as ReasoningEffort,
    };
  }

  function invalidateAsyncOps(): void {
    testGeneration += 1;
    fetchGeneration += 1;
    testBtn.disabled = false;
    fetchModelsBtn.disabled = false;
    setStatus("");
  }

  async function loadSettings(): Promise<void> {
    const vm = await invoke<SettingsViewModel>("get_settings");
    baseUrlInput.value = vm.configuration.base_url;
    modelInput.value = vm.configuration.model;
    wireSelect.value = vm.configuration.wire_api;
    effortSelect.value = vm.configuration.reasoning_effort;
    keyInput.value = "";
    keyInput.placeholder = vm.has_api_key
      ? "Đã lưu key trên máy — nhập để thay đổi"
      : "Nhập API key";
    autostartCheckbox.checked = vm.launch_at_login;
    if (vm.initialization_error) {
      setStatus(vm.initialization_error, "warning");
    } else if (!vm.has_api_key) {
      setStatus("Chưa có API key. Nhập key để bắt đầu.");
    } else {
      setStatus("");
    }
  }

  baseUrlInput.addEventListener("input", invalidateAsyncOps);
  modelInput.addEventListener("input", invalidateAsyncOps);
  keyInput.addEventListener("input", invalidateAsyncOps);
  wireSelect.addEventListener("change", () => {
    testGeneration += 1;
    testBtn.disabled = false;
    setStatus("");
  });
  effortSelect.addEventListener("change", () => {
    testGeneration += 1;
    testBtn.disabled = false;
    setStatus("");
  });

  autostartCheckbox.addEventListener("change", async () => {
    const target = autostartCheckbox.checked;
    try {
      await invoke("set_autostart", { enabled: target });
      setStatus(
        target ? "Đã bật khởi động cùng Windows." : "Đã tắt khởi động cùng Windows.",
      );
    } catch (error) {
      autostartCheckbox.checked = !target;
      setStatus(String(error), "error");
    }
  });

  fetchModelsBtn.addEventListener("click", async () => {
    const gen = ++fetchGeneration;
    fetchModelsBtn.disabled = true;
    setStatus("Đang tải danh sách model…");
    try {
      const models = await invoke<string[]>("fetch_models", {
        configuration: draftConfig(),
        apiKey: keyInput.value,
      });
      if (gen !== fetchGeneration) return;
      modelDataList.replaceChildren(
        ...models.map((id) => {
          const opt = document.createElement("option");
          opt.value = id;
          return opt;
        }),
      );
      if (models.length === 0) {
        setStatus("Endpoint chưa trả về model nào. Bạn vẫn có thể nhập thủ công.", "warning");
      } else {
        setStatus(`Đã tải ${models.length} model — chọn trong danh sách hoặc nhập thủ công.`, "success");
      }
    } catch (error) {
      if (gen !== fetchGeneration) return;
      setStatus(String(error), "error");
    } finally {
      if (gen === fetchGeneration) fetchModelsBtn.disabled = false;
    }
  });

  testBtn.addEventListener("click", async () => {
    const gen = ++testGeneration;
    testBtn.disabled = true;
    setStatus("Đang gửi yêu cầu kiểm tra nhỏ…");
    try {
      const result = await invoke<ConnectionTestResult>("test_connection", {
        configuration: draftConfig(),
        apiKey: keyInput.value,
      });
      if (gen !== testGeneration) return;
      const timing = `${result.elapsed_seconds.toFixed(2)} giây`;
      if (result.received) {
        setStatus(`Kết nối thành công — tổng thời gian dịch mẫu: ${timing}.`, "success");
      } else {
        setStatus(`API chưa trả nội dung — thời gian chờ: ${timing}.`, "warning");
      }
    } catch (error) {
      if (gen !== testGeneration) return;
      setStatus(String(error), "error");
    } finally {
      if (gen === testGeneration) testBtn.disabled = false;
    }
  });

  deleteBtn.addEventListener("click", async () => {
    invalidateAsyncOps();
    try {
      await invoke("delete_api_key");
      keyInput.value = "";
      keyInput.placeholder = "Nhập API key";
      setStatus("Đã xóa API key. Nhập key mới rồi bấm Lưu.");
    } catch (error) {
      setStatus(String(error), "error");
    }
  });

  cancelBtn.addEventListener("click", () => {
    invalidateAsyncOps();
    keyInput.value = "";
    void invoke("dismiss_settings");
  });

  page.addEventListener("submit", async (event) => {
    event.preventDefault();
    invalidateAsyncOps();
    try {
      await invoke("save_settings", {
        payload: {
          configuration: draftConfig(),
          api_key: keyInput.value,
        },
      });
      keyInput.value = "";
      await getCurrentWindow().hide();
    } catch (error) {
      setStatus(String(error), "error");
    }
  });

  window.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      cancelBtn.click();
    }
  });

  void listen("settings:open", () => {
    invalidateAsyncOps();
    void loadSettings();
  });

  void listen("settings:closed", () => {
    invalidateAsyncOps();
    keyInput.value = "";
  });

  void loadSettings();
}

function makeInput(type: string, placeholder: string): HTMLInputElement {
  const input = document.createElement("input");
  input.type = type;
  input.className = "text-input";
  input.placeholder = placeholder;
  return input;
}

function wrapField(labelText: string, control: HTMLElement): HTMLElement {
  const group = document.createElement("div");
  group.className = "field-group";
  const label = document.createElement("label");
  label.className = "field-label";
  label.textContent = labelText;
  group.append(label, control);
  return group;
}
