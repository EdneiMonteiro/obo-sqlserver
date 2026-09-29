import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import os from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import { chromium } from "playwright";
import MarkdownIt from "markdown-it";
import { slides, chapters } from "./slides.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", "..");
const output = path.join(root, "docs", "apresentacao.html");
const url = pathToFileURL(output).href;
const text = await fs.readFile(output, "utf8");
const data = JSON.parse(text.match(/<script id="presentation-data" type="application\/json">([\s\S]*?)<\/script>/)[1]);
const normalized = (value) => value.replace(/\s+/g, " ").trim();
const md = new MarkdownIt({ html: false });
let browser;

before(async () => { browser = await chromium.launch({ headless: true }); });
after(async () => { await browser?.close(); });

async function withPage(action, viewport = { width: 1440, height: 900 }) {
  const context = await browser.newContext({ viewport, offline: true });
  const page = await context.newPage();
  const errors = [];
  const requests = [];
  page.on("pageerror", (error) => errors.push(error.message));
  page.on("request", (request) => {
    if (/^https?:/.test(request.url())) requests.push(request.url());
  });
  try {
    await page.goto(url);
    await page.waitForFunction(() => document.body.dataset.ready === "true", null, { timeout: 5000 });
    await action(page, context);
    assert.deepEqual(errors, [], "Presentation emitted JavaScript errors");
    assert.deepEqual(requests, [], "Opening/using the presentation made network requests");
  } finally { await context.close(); }
}

async function go(page, hash) {
  await page.evaluate((value) => { location.hash = value; }, hash);
  if (hash.startsWith("#doc/")) {
    const id = hash.split("/")[1];
    await page.locator(`[data-document="${id}"]`).waitFor({ state: "visible" });
  } else {
    const id = hash.split("/")[1];
    await page.locator(`[data-slide="${id}"]`).waitFor({ state: "visible" });
  }
  await page.evaluate(() => new Promise(requestAnimationFrame));
  if (hash.startsWith("#slide/")) {
    await page.waitForFunction((id) => Number(getComputedStyle(document.querySelector(`[data-slide="${id}"]`)).opacity) >= .99, hash.split("/")[1]);
  }
}

async function capture(page, name) {
  if (!process.env.PRESENTATION_SCREENSHOT_DIR) return;
  await fs.mkdir(process.env.PRESENTATION_SCREENSHOT_DIR, { recursive: true });
  await page.screenshot({ path: path.join(process.env.PRESENTATION_SCREENSHOT_DIR, name), animations: "disabled" });
}

test("artifact is fresh and contains every Markdown document plus legal metadata", async () => {
  const docs = [];
  async function visit(relative) {
    for (const entry of await fs.readdir(path.join(root, relative), { withFileTypes: true })) {
      if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
      const name = `${relative}/${entry.name}`;
      if (entry.isDirectory()) await visit(name);
      else if (name.endsWith(".md")) docs.push(name);
    }
  }
  await visit("docs");
  const expected = ["README.md", "CONTRIBUTING.md", "DISCLAIMER.md", "SUPPORT.md", ...docs].sort();
  assert.deepEqual(data.manifest.inputs.filter((entry) => entry.kind === "markdown").map((entry) => entry.path).sort(), expected);
  for (const input of data.manifest.inputs) {
    const current = (await fs.readFile(path.join(root, ...input.path.split("/")), "utf8")).replace(/\r\n/g, "\n");
    assert.equal(crypto.createHash("sha256").update(current).digest("hex"), input.sha256,
      `Outdated presentation source: ${input.path}. Run npm run build.`);
    assert.ok(!/(\.local|node_modules|kubeconfig)/i.test(input.path));
  }
  assert.ok(data.documents.some((entry) => entry.name === "LICENSE"));
  assert.ok(data.documents.some((entry) => entry.name === "CITATION.cff"));
  assert.equal(data.slides.length, slides.length);
  assert.equal(data.chapters.length, chapters.length);
  assert.ok(data.slides.length >= 30);
  assert.ok(!/<(?:img|script|link|iframe)[^>]+(?:src|href)=["']https?:/i.test(text), "Remote dependency in artifact");
});

test("presentation text uses technical titles without slogans or prose dashes", async () => {
  for (const slide of slides) {
    const copy = JSON.stringify({
      title: slide.title, lead: slide.lead, body: slide.body, notes: slide.notes,
      cards: slide.cards, steps: slide.steps, checklist: slide.checklist
    });
    assert.ok(!/[\u2013\u2014]/u.test(copy), `Prose dash in slide: ${slide.id}`);
    assert.ok(!slide.title.endsWith("?"), `Rhetorical title: ${slide.id}`);
    assert.equal(Object.hasOwn(slide, "takeaway"), false, `Slogan block returned: ${slide.id}`);
  }
  for (const input of data.manifest.inputs.filter((entry) => entry.kind === "markdown")) {
    const copy = await fs.readFile(path.join(root, ...input.path.split("/")), "utf8");
    assert.ok(!/[\u2013\u2014]/u.test(copy), `Prose dash in ${input.path}`);
  }
});

test("file opens offline, has valid routes, unique IDs and accessible controls", async () => {
  await withPage(async (page) => {
    assert.equal(await page.title(), "Lab OBO: AKS, BFF e Azure SQL");
    assert.equal(await page.locator("[data-slide]:visible").count(), 1);
    assert.equal(await page.locator("[data-slide=inicio] h1").count(), 1);
    const report = await page.evaluate(() => {
      const ids = [...document.querySelectorAll("[id]")].map((entry) => entry.id);
      const duplicateIds = ids.filter((id, index) => ids.indexOf(id) !== index);
      const slideIds = new Set([...document.querySelectorAll("[data-slide]")].map((entry) => entry.dataset.slide));
      const docIds = new Set([...document.querySelectorAll("[data-document]")].map((entry) => entry.dataset.document));
      const broken = [...document.querySelectorAll('a[href^="#"]')].filter((link) => {
        const [kind, id, heading] = link.hash.slice(1).split("/");
        if (kind === "slide") return !slideIds.has(id);
        if (kind === "doc") return !docIds.has(id) || (heading && !document.getElementById(`${id}--${heading}`));
        return !document.getElementById(kind);
      }).map((link) => link.getAttribute("href"));
      const unnamedButtons = [...document.querySelectorAll("button")].filter((button) =>
        !button.textContent.trim() && !button.getAttribute("aria-label")).length;
      const unsafeExternal = [...document.querySelectorAll('a[href^="http"]')].filter((link) =>
        link.target !== "_blank" || !link.rel.includes("noopener")).length;
      return { duplicateIds, broken, unnamedButtons, unsafeExternal };
    });
    assert.deepEqual(report, { duplicateIds: [], broken: [], unnamedButtons: 0, unsafeExternal: 0 });
    await capture(page, "presentation-cover.png");
  });
});

test("a standalone copy works without the repository or a web server", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "obo-presentation-"));
  const file = path.join(directory, "guia do cliente.html");
  const context = await browser.newContext({ offline: true });
  const page = await context.newPage();
  try {
    await fs.copyFile(output, file);
    await page.goto(pathToFileURL(file).href);
    await page.waitForFunction(() => document.body.dataset.ready === "true");
    await page.getByRole("button", { name: "Documentação", exact: true }).click();
    await page.locator("[data-document]:visible").waitFor();
    const target = data.documents.find((entry) => entry.name === "docs/deploy.md");
    await page.evaluate((id) => { location.hash = `#doc/${id}`; }, target.id);
    await page.locator(`[data-document="${target.id}"]`).waitFor({ state: "visible" });
    assert.ok((await page.locator(`[data-document="${target.id}"]`).textContent()).includes("SenderObjectIds"));
    assert.ok(page.url().startsWith(pathToFileURL(file).href));
  } finally {
    await context.close();
    await fs.unlink(file);
    await fs.rmdir(directory);
  }
});

test("all slides render without horizontal viewport overflow", async () => {
  await withPage(async (page) => {
    for (const slide of slides) {
      await go(page, `#slide/${slide.id}`);
      const box = await page.locator(`[data-slide="${slide.id}"]`).boundingBox();
      assert.ok(box && box.width > 300 && box.height > 200, `No rendered slide: ${slide.id}`);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 2);
      assert.equal(overflow, false, `Horizontal overflow: ${slide.id}`);
      const heading = await page.locator(`[data-slide="${slide.id}"] h1`).boundingBox();
      assert.ok(heading && heading.height > 15, `Missing visible title: ${slide.id}`);
    }
    await go(page, "#slide/visao-geral");
    await capture(page, "presentation-architecture.png");
    await go(page, "#slide/ids");
    await capture(page, "presentation-identities.png");
  });
});

test("library preserves all source paragraphs and code, not just summaries", async () => {
  await withPage(async (page) => {
    for (const document of data.documents) {
      const source = (await fs.readFile(path.join(root, ...document.name.split("/")), "utf8")).replace(/\r\n/g, "\n");
      const content = normalized(await page.locator(`#${document.id} .document-content`).textContent());
      if (!document.name.endsWith(".md")) {
        assert.ok(content.includes(normalized(source)), `Reference truncated: ${document.name}`);
        continue;
      }
      for (const token of md.parse(source, {})) {
        if (token.type === "inline") {
          const fragment = normalized(token.children.map((item) => {
            if (item.type === "text" || item.type === "code_inline" || item.type === "image") return item.content;
            if (item.type === "softbreak" || item.type === "hardbreak") return " ";
            return "";
          }).join(""));
          if (fragment) assert.ok(content.includes(fragment), `Missing source text in ${document.name}: ${fragment.slice(0, 90)}`);
        }
        if (token.type === "fence" && token.info.trim() !== "mermaid") {
          assert.ok(content.includes(normalized(token.content)), `Code block truncated: ${document.name}`);
        }
      }
    }
    await page.getByRole("button", { name: "Documentação", exact: true }).click();
    await page.locator("[data-document]:visible").waitFor();
    assert.equal(await page.locator("[data-document]:visible").count(), 1);
  });
});

test("keyboard, reading mode, presenter notes and local search work", async () => {
  await withPage(async (page) => {
    await page.keyboard.press("ArrowRight");
    await page.locator("[data-slide=roteiro]").waitFor({ state: "visible" });
    await page.keyboard.press("ArrowLeft");
    await page.locator("[data-slide=inicio]").waitFor({ state: "visible" });
    await page.getByRole("button", { name: "Leitura", exact: true }).click();
    await page.waitForFunction(() => document.body.dataset.mode === "reader");
    assert.equal(await page.locator("[data-slide]:visible").count(), slides.length);
    await page.getByRole("button", { name: "Notas", exact: true }).click();
    assert.equal(await page.locator(".presenter-note:visible").count(), slides.length);
    await page.getByRole("button", { name: "Leitura", exact: true }).click();
    await page.waitForFunction(() => document.body.dataset.mode === "slides");
    await page.keyboard.press("/");
    await page.locator("#search-dialog").waitFor({ state: "visible" });
    await page.locator("#search-input").fill("recuperação");
    assert.ok(await page.locator("#search-results a").count() > 0);
    const hash = new URL(page.url()).hash;
    await page.locator("#search-input").press("ArrowRight");
    assert.equal(new URL(page.url()).hash, hash, "Typing in search navigated slides");
    await page.locator("#search-input").fill("termo-que-nao-existe-xyz");
    assert.equal(await page.locator("#search-results a").count(), 0);
    await page.locator("#search-input").fill("permissões");
    await page.locator("#search-results a").first().click();
    await page.locator("#search-dialog").waitFor({ state: "hidden" });
    assert.notEqual(new URL(page.url()).hash, hash);
  });
});

test("diagram zoom renders real SVG and restores it when closed", async () => {
  await withPage(async (page) => {
    await go(page, "#slide/visao-geral");
    const figure = page.locator("[data-slide=visao-geral] figure");
    assert.ok(await figure.locator("svg path").count() > 0);
    await figure.getByRole("button", { name: /Ampliar diagrama/ }).click();
    const svg = page.locator("#diagram-holder svg");
    await svg.waitFor({ state: "visible" });
    const before = await svg.boundingBox();
    await page.getByRole("button", { name: "Aumentar diagrama", exact: true }).click();
    const after = await svg.boundingBox();
    assert.ok(after.width > before.width + 20);
    await page.keyboard.press("Escape");
    await figure.locator("svg").waitFor({ state: "visible" });
    assert.equal(await page.locator("#diagram-holder svg").count(), 0);
  });
});

test("copy controls report a safe selection fallback without changing the system clipboard", async () => {
  await withPage(async (page) => {
    await go(page, "#slide/contrato-http");
    await page.evaluate(() => Object.defineProperty(navigator, "clipboard", { configurable: true, value: undefined }));
    await page.locator("[data-slide=contrato-http] .copy-button").click();
    assert.ok((await page.locator("#toast").textContent()).includes("Texto selecionado"));
    assert.ok((await page.evaluate(() => getSelection().toString())).includes("POST /api/documents"));
  });
});

test("compact desktop and mobile stay usable without horizontal page scrolling", async () => {
  await withPage(async (page) => {
    const cover = await page.locator("[data-slide=inicio]").boundingBox();
    const footer = await page.locator(".navigation-bar").boundingBox();
    assert.ok(cover.y + cover.height <= footer.y + 2, "Cover requires scrolling behind navigation at 1366x768");
    await capture(page, "presentation-compact.png");
  }, { width: 1366, height: 768 });
  await withPage(async (page) => {
    await page.getByRole("button", { name: /Índice/ }).click();
    assert.equal(await page.locator("#menu-toggle").getAttribute("aria-expanded"), "true");
    await page.locator('[data-nav-slide="participantes"]').click();
    await page.locator("[data-slide=participantes]").waitFor({ state: "visible" });
    assert.equal(await page.locator("#menu-toggle").getAttribute("aria-expanded"), "false");
    for (const slide of slides) {
      await go(page, `#slide/${slide.id}`);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 2), false, `Mobile overflow: ${slide.id}`);
    }
    await go(page, "#slide/participantes");
    await capture(page, "presentation-mobile.png");
  }, { width: 390, height: 844 });
});

test("print modes expose the complete selected material, with no external requests", async () => {
  await withPage(async (page) => {
    await page.evaluate(() => { window.print = () => { window.printedScope = document.body.dataset.print; }; });
    await page.getByRole("button", { name: "Imprimir", exact: true }).click();
    assert.equal(await page.evaluate(() => window.printedScope), "deck");
    await page.emulateMedia({ media: "print" });
    assert.equal(await page.locator("[data-slide]:visible").count(), slides.length);
    assert.equal(await page.locator(".sidebar:visible").count(), 0);
    await page.emulateMedia({ media: "screen" });
    await page.locator("#print-scope").selectOption("docs");
    await page.getByRole("button", { name: "Imprimir", exact: true }).click();
    assert.equal(await page.evaluate(() => window.printedScope), "docs");
    await page.emulateMedia({ media: "print" });
    assert.equal(await page.locator("[data-document]:visible").count(), data.documents.length);
    assert.equal(await page.locator("[data-slide]:visible").count(), 0);
    await page.emulateMedia({ media: "screen" });
    await page.locator("#print-scope").selectOption("current");
    await page.emulateMedia({ media: "print" });
    assert.equal(await page.locator("[data-slide]:visible").count(), 1);
  });
});
