// Minimal stand-in for @raycast/utils, used only by scripts/export-fixtures.ts.
// esbuild aliases "@raycast/utils" to this file. Nothing here is shipped.

function unsupported(name: string): never {
  throw new Error(`@raycast/utils stub: ${name}() is not available outside Raycast`);
}

// errors.ts imports this at module scope but only calls it from UI paths, which
// the exporter never reaches.
export async function showFailureToast(): Promise<never> {
  return unsupported("showFailureToast");
}

export async function runAppleScript(): Promise<never> {
  return unsupported("runAppleScript");
}

export function useCachedPromise(): never {
  return unsupported("useCachedPromise");
}
