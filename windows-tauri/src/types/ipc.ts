export type Skill = "translate" | "summarize" | "explain";
export type WireApi = "chat" | "responses";
export type ReasoningEffort = "low" | "medium" | "high";

export const SKILL_LABELS: Record<Skill, string> = {
  translate: "Dịch",
  summarize: "Tóm tắt",
  explain: "Giải thích",
};

export interface ApiConfiguration {
  base_url: string;
  model: string;
  reasoning_effort: ReasoningEffort;
  wire_api: WireApi;
}

export interface SettingsViewModel {
  configuration: ApiConfiguration;
  has_api_key: boolean;
  initialization_error: string | null;
  launch_at_login: boolean;
}

export interface SaveSettingsPayload {
  configuration: ApiConfiguration;
  api_key: string;
}

export interface ConnectionTestResult {
  received: boolean;
  elapsed_seconds: number;
}

export interface HistoryEntry {
  id: string;
  skill: Skill;
  created_at: string;
  model: string;
  source_text: string;
  source_preview: string;
  result_text: string;
}

export interface HistoryListResponse {
  entries: HistoryEntry[];
  has_read_error: boolean;
}

export interface SelectionBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ResultStartEvent {
  generation: string;
  skill: Skill;
  source_text: string;
}

export interface ResultChunkEvent {
  generation: string;
  chunk: string;
}

export interface ResultFinishedEvent {
  generation: string;
  history_warning: string | null;
}

export interface ResultErrorEvent {
  generation: string;
  message: string;
}

export interface PillShowEvent {
  text: string;
}
