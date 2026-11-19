import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { PillShowEvent, Skill, SKILL_LABELS } from "../types/ipc";

const PILL_SKILLS: Array<{ skill: Skill; svg: string }> = [
  {
    skill: "translate",
    svg: `<svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M2.5 3.5h6M5.5 2v1.5M3.5 3.5c.4 2.4 2.1 4.4 4.3 5.5M7.4 3.5C6.8 6 5.1 7.9 2.5 9M8.5 13.5l2.7-7 2.7 7M9.3 11.4h3.8" stroke="currentColor" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  },
  {
    skill: "summarize",
    svg: `<svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M2.5 4h11M2.5 8h8.5M2.5 12h6" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>`,
  },
  {
    skill: "explain",
    svg: `<svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden="true"><path d="M8 2.2a4 4 0 0 0-2.2 7.3c.5.4.8.9.8 1.5h2.8c0-.6.3-1.1.8-1.5A4 4 0 0 0 8 2.2Z" stroke="currentColor" stroke-width="1.35" stroke-linejoin="round"/><path d="M6.4 13.3h3.2" stroke="currentColor" stroke-width="1.35" stroke-linecap="round"/></svg>`,
  },
];

export function mountPillView(root: HTMLElement): void {
  document.body.classList.add("transparent-window");
  let currentText = "";

  const shell = document.createElement("div");
  shell.className = "pill-shell";

  const bar = document.createElement("div");
  bar.className = "pill-bar";
  bar.setAttribute("role", "toolbar");
  bar.setAttribute("aria-label", "Hành động nhanh Dola Lite");

  for (const item of PILL_SKILLS) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "pill-btn";
    button.title = SKILL_LABELS[item.skill];
    button.setAttribute("aria-label", SKILL_LABELS[item.skill]);

    const icon = document.createElement("span");
    icon.innerHTML = item.svg;
    const label = document.createElement("span");
    label.textContent = SKILL_LABELS[item.skill];
    button.append(icon, label);

    button.addEventListener("click", () => {
      if (!currentText) return;
      void invoke("run_skill", { skill: item.skill, text: currentText });
    });
    bar.appendChild(button);
  }

  shell.appendChild(bar);
  root.replaceChildren(shell);

  void listen<PillShowEvent>("pill:show", (event) => {
    currentText = event.payload.text;
  });

  window.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      void invoke("dismiss_pill");
    }
  });
}
