import "./styles/tokens.css";
import { mountHistoryView } from "./views/history";
import { mountPillView } from "./views/pill";
import { mountResultView } from "./views/result";
import { mountSettingsView } from "./views/settings";

const root = document.getElementById("app");
if (!root) {
  throw new Error("Missing #app mount point");
}

const view = new URLSearchParams(window.location.search).get("view") ?? "settings";

switch (view) {
  case "pill":
    mountPillView(root);
    break;
  case "result":
    mountResultView(root);
    break;
  case "history":
    mountHistoryView(root);
    break;
  case "settings":
  default:
    mountSettingsView(root);
    break;
}
