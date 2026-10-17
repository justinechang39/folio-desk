export type Theme = "orange" | "nord" | "dracula" | "solarized";
export type Mode = "system" | "light" | "dark";
export type Appearance = { theme: Theme; mode: Mode };
export const defaultAppearance: Appearance = {
  theme: "orange",
  mode: "system",
};
type Colors = {
  ink: string;
  muted: string;
  surface: string;
  raised: string;
  desk: string;
  line: string;
  accent: string;
  onAccent: string;
  selected: string;
  hover: string;
};
export const themes: {
  id: Theme;
  label: string;
  light: Colors;
  dark: Colors;
}[] = [
  {
    id: "orange",
    label: "Orange",
    light: {
      ink: "#302b28",
      muted: "#70665f",
      surface: "#f9f8f6",
      raised: "#ffffff",
      desk: "#e9e6e2",
      line: "#d9d2cb",
      accent: "#b84b08",
      onAccent: "#ffffff",
      selected: "#ffead9",
      hover: "#ede7e1",
    },
    dark: {
      ink: "#f1ece7",
      muted: "#b9afa6",
      surface: "#282726",
      raised: "#33302e",
      desk: "#202124",
      line: "#49413b",
      accent: "#ffab70",
      onAccent: "#38200e",
      selected: "#55331d",
      hover: "#3d3530",
    },
  },
  {
    id: "nord",
    label: "Nord",
    light: {
      ink: "#2e3440",
      muted: "#4c566a",
      surface: "#eceff4",
      raised: "#ffffff",
      desk: "#d8dee9",
      line: "#bbc5d5",
      accent: "#366a84",
      onAccent: "#ffffff",
      selected: "#d3e9ef",
      hover: "#e5e9f0",
    },
    dark: {
      ink: "#eceff4",
      muted: "#b8c3d5",
      surface: "#2e3440",
      raised: "#3b4252",
      desk: "#242933",
      line: "#4c566a",
      accent: "#88c0d0",
      onAccent: "#242933",
      selected: "#3c5364",
      hover: "#434c5e",
    },
  },
  {
    id: "dracula",
    label: "Dracula",
    light: {
      ink: "#282a36",
      muted: "#636079",
      surface: "#f7f5fa",
      raised: "#ffffff",
      desk: "#e7e3ee",
      line: "#d2cadd",
      accent: "#7448a8",
      onAccent: "#ffffff",
      selected: "#eee0fc",
      hover: "#eae4f1",
    },
    dark: {
      ink: "#f8f8f2",
      muted: "#c0b8d1",
      surface: "#282a36",
      raised: "#343746",
      desk: "#21222c",
      line: "#505268",
      accent: "#bd93f9",
      onAccent: "#282a36",
      selected: "#493960",
      hover: "#44475a",
    },
  },
  {
    id: "solarized",
    label: "Solarized",
    light: {
      ink: "#384f56",
      muted: "#586e75",
      surface: "#fdf6e3",
      raised: "#fffbf0",
      desk: "#eee8d5",
      line: "#d3ceba",
      accent: "#a04f00",
      onAccent: "#ffffff",
      selected: "#f4e1bf",
      hover: "#eee8d5",
    },
    dark: {
      ink: "#eee8d5",
      muted: "#93a1a1",
      surface: "#073642",
      raised: "#10414b",
      desk: "#002b36",
      line: "#31545c",
      accent: "#e8a649",
      onAccent: "#002b36",
      selected: "#41432b",
      hover: "#17434d",
    },
  },
];
export function restoreAppearance(value: unknown): Appearance {
  const raw = value as Partial<Appearance> | null;
  return {
    theme: themes.some((t) => t.id === raw?.theme) ? raw!.theme! : "orange",
    mode: ["system", "light", "dark"].includes(raw?.mode ?? "")
      ? raw!.mode!
      : "system",
  };
}
export function themeVariables(
  appearance: Appearance,
  systemDark: boolean,
): Record<string, string> {
  const mode =
    appearance.mode === "system"
      ? systemDark
        ? "dark"
        : "light"
      : appearance.mode;
  const palette = themes.find((t) => t.id === appearance.theme)![mode];
  return Object.fromEntries(
    Object.entries(palette).map(([key, value]) => [
      `--${key.replace(/[A-Z]/g, (c) => "-" + c.toLowerCase())}`,
      value,
    ]),
  );
}
