import type { ZadurEditorAPI } from "./api";
import type { EditorSettings } from "./settings";

/**
 * Browser-only harness (when not hosted by the Swift app): a small toolbar to
 * load the sample, change settings and run the stress test.
 */
export async function startDevHarness(api: ZadurEditorAPI) {
  const bar = document.getElementById("devbar");
  if (!bar) return;
  bar.hidden = false;
  bar.innerHTML = `
    <strong>Zadur · Editor-Prototyp</strong>
    <label>Schrift
      <select data-setting="font">
        <option value="serif">Serif</option><option value="sans">Sans</option><option value="mono">Mono</option>
      </select>
    </label>
    <label>Größe <input data-setting="fontSize" type="number" min="12" max="32" step="1" value="19"></label>
    <label>Anführungszeichen
      <select data-setting="quotes">
        <option value="guillemets">»Buch«</option><option value="de">„Deutsch“</option><option value="en">“English”</option>
      </select>
    </label>
    <label><input data-setting="showComments" type="checkbox" checked> Kommentare</label>
    <label><input data-setting="focusMode" type="checkbox"> Fokus</label>
    <button type="button" data-action="sample">Beispiel laden</button>
    <button type="button" data-action="stress">Stresstest 15k Wörter</button>
    <output id="dev-stats"></output>`;

  const out = bar.querySelector<HTMLOutputElement>("#dev-stats")!;

  bar.addEventListener("change", (event) => {
    const input = event.target as HTMLInputElement | HTMLSelectElement;
    const key = input.dataset.setting as keyof EditorSettings | undefined;
    if (!key) return;
    const value =
      input instanceof HTMLInputElement && input.type === "checkbox"
        ? input.checked
        : input instanceof HTMLInputElement && input.type === "number"
          ? Number(input.value)
          : input.value;
    api.setSettings({ [key]: value } as Partial<EditorSettings>);
  });

  bar.addEventListener("click", async (event) => {
    const action = (event.target as HTMLElement).dataset.action;
    if (action === "sample") await loadSample(api);
    if (action === "stress") {
      const result = api.loadStressTest(15_000);
      if (result) {
        out.title = JSON.stringify(result);
        console.info("[zadur] stress test", result);
      }
    }
  });

  window.setInterval(() => {
    const { words, characters } = api.stats();
    out.textContent = `${words.toLocaleString("de")} Wörter · ${characters.toLocaleString("de")} Zeichen`;
  }, 500);

  await loadSample(api);
  api.focus();
}

async function loadSample(api: ZadurEditorAPI) {
  const response = await fetch("samples/szene.md");
  api.load(await response.text());
}
