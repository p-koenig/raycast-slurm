// Minimal stand-in for @raycast/api, used only by scripts/export-fixtures.ts.
// esbuild aliases "@raycast/api" to this file so the extension's lib modules can
// be imported outside of the Raycast runtime. Nothing here is shipped.

function unsupported(name: string): never {
  throw new Error(`@raycast/api stub: ${name}() is not available outside Raycast`);
}

// format.ts only uses Color values as opaque tokens; the string values match the
// public @raycast/api enum so anything that leaks into a fixture stays readable.
export const Color = {
  Blue: "raycast-blue",
  Green: "raycast-green",
  Magenta: "raycast-magenta",
  Orange: "raycast-orange",
  Purple: "raycast-purple",
  Red: "raycast-red",
  Yellow: "raycast-yellow",
  PrimaryText: "raycast-primary-text",
  SecondaryText: "raycast-secondary-text",
} as const;

export type Color = (typeof Color)[keyof typeof Color];

// ssh.ts reads `controlPersist`; an empty object makes it fall back to "12h",
// which is exactly the shipped default.
export function getPreferenceValues<T = Record<string, unknown>>(): T {
  return {} as T;
}

const store = new Map<string, string>();

export const LocalStorage = {
  async getItem<T = string>(key: string): Promise<T | undefined> {
    return store.get(key) as T | undefined;
  },
  async setItem(key: string, value: string | number | boolean): Promise<void> {
    store.set(key, String(value));
  },
  async removeItem(key: string): Promise<void> {
    store.delete(key);
  },
  async clear(): Promise<void> {
    store.clear();
  },
  async allItems<T = Record<string, string>>(): Promise<T> {
    return Object.fromEntries(store) as T;
  },
};

export function showToast(): never {
  return unsupported("showToast");
}

export function launchCommand(): never {
  return unsupported("launchCommand");
}

export function updateCommandMetadata(): never {
  return unsupported("updateCommandMetadata");
}

export function open(): never {
  return unsupported("open");
}
