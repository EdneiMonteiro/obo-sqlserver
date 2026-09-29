import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import crypto from "node:crypto";
import MarkdownIt from "markdown-it";
import { chromium } from "playwright";
import { chapters, documentOrder, slides } from "./slides.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", "..");
const output = path.join(root, "docs", "apresentacao.html");
const md = new MarkdownIt({ html: false, linkify: false, typographer: false });
const escape = md.utils.escapeHtml;
const normalize = (text) => text.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();
const slug = (text) => normalize(text).replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const sourceId = (name) => `document-${slug(name)}`;
const sha = (text) => crypto.createHash("sha256").update(text).digest("hex");
const json = (value) => JSON.stringify(value).replace(/</g, "\\u003c");
const read = async (name) => (await fs.readFile(path.join(root, ...name.split("/")), "utf8")).replace(/\r\n/g, "\n");

async function markdownFiles(directory) {
  const entries = await fs.readdir(path.join(root, directory), { withFileTypes: true });
  const found = [];
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name, "en"))) {
    if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
    const relative = `${directory}/${entry.name}`;
    if (entry.isDirectory()) found.push(...await markdownFiles(relative));
    else if (entry.name.endsWith(".md")) found.push(relative);
  }
  return found;
}

const allMarkdown = ["README.md", "CONTRIBUTING.md", "DISCLAIMER.md", "SUPPORT.md", ...await markdownFiles("docs")];
const ordered = [...new Set([...documentOrder, ...allMarkdown])];
for (const name of documentOrder) {
  if (!allMarkdown.includes(name)) throw new Error(`Document listed in the presentation is missing: ${name}`);
}
const sources = new Map();
for (const name of [...ordered, "LICENSE", "CITATION.cff"]) {
  const raw = await read(name);
  sources.set(name, {
    name, raw, id: sourceId(name), markdown: name.endsWith(".md"),
    title: raw.match(/^#\s+(.+)$/m)?.[1] ?? (name === "LICENSE" ? "Licença MIT" : "Metadados de citação"),
    legacy: name.startsWith("docs/legacy/")
  });
}

function projectTarget(href, from) {
  const [pathname, fragment = ""] = href.split("#");
  if (!pathname) return { name: from, fragment };
  const name = path.posix.normalize(path.posix.join(path.posix.dirname(from), decodeURIComponent(pathname)));
  if (name.startsWith("../") || name.startsWith("/") || name.split("/").some((part) =>
    part === ".local" || part === ".git" || part === "node_modules" || part.startsWith(".env")) ||
      /\.(pem|key|pfx)$/i.test(name) || /\.local\./i.test(name)) {
    throw new Error(`Private or out-of-repository link refused in ${from}`);
  }
  return { name, fragment };
}

// Include locally linked code/configuration as escaped reference text, never execute it.
for (const source of [...sources.values()]) {
  if (!source.markdown) continue;
  const tokens = md.parse(source.raw, {});
  for (const token of tokens.flatMap((item) => item.children ?? [])) {
    if (token.type !== "link_open") continue;
    const href = token.attrGet("href");
    if (/^(https?:|mailto:)/i.test(href) || href.startsWith("#")) continue;
    const { name } = projectTarget(href, source.name);
    if (name === "docs/apresentacao.html" || sources.has(name)) continue;
    const raw = await read(name);
    sources.set(name, { name, raw, id: sourceId(name), title: name, markdown: false, reference: true });
  }
}

function headings(source) {
  const used = new Map();
  const tokens = md.parse(source.raw, {});
  return tokens.flatMap((token, index) => {
    if (token.type !== "heading_open") return [];
    const title = tokens[index + 1].content;
    const base = slug(title);
    const count = used.get(base) ?? 0;
    used.set(base, count + 1);
    return [{ title, level: Number(token.tag.slice(1)), line: token.map[0],
      key: count ? `${base}-${count}` : base, sourceId: source.id }];
  });
}
for (const source of sources.values()) source.headings = source.markdown ? headings(source) : [];

function section(name, heading) {
  const source = sources.get(name);
  if (!source?.markdown) throw new Error(`Unknown Markdown source: ${name}`);
  if (!heading) return source.raw;
  const start = source.headings.find((entry) => normalize(entry.title) === normalize(heading));
  if (!start) throw new Error(`Section not found: ${name} -> ${heading}`);
  const end = source.headings.find((entry) => entry.line > start.line && entry.level <= start.level);
  return source.raw.split("\n").slice(start.line + 1, end?.line).join("\n");
}

function excerpt(spec) {
  const text = section(spec.file, spec.heading);
  const tokens = md.parse(text, {});
  if (spec.kind === "table") {
    const token = tokens.find((item) => item.type === "table_open");
    if (!token) throw new Error(`Table not found: ${spec.file} -> ${spec.heading}`);
    return text.split("\n").slice(...token.map).join("\n");
  }
  if (spec.command) {
    const groups = [];
    for (const token of tokens.filter((item) => item.type === "fence" && item.info.trim() === "powershell")) {
      const lines = token.content.split("\n");
      for (let i = 0; i < lines.length; i++) {
        if (!lines[i].trimStart().startsWith(spec.command)) continue;
        let command = lines[i];
        while (lines[i].trimEnd().endsWith("`") && i + 1 < lines.length) command += "\n" + lines[++i];
        if (spec.includes && !command.includes(spec.includes)) continue;
        if (spec.excludes && command.includes(spec.excludes)) continue;
        groups.push(command);
      }
    }
    if (!groups.length) throw new Error(`Command not found in ${spec.file}: ${spec.command}`);
    return `\`\`\`powershell\n${groups[0]}\n\`\`\``;
  }
  const fence = tokens.find((item) => item.type === "fence" && item.info !== "mermaid");
  if (!fence) throw new Error(`Code block not found: ${spec.file} -> ${spec.heading}`);
  return `\`\`\`${fence.info}\n${fence.content}\`\`\``;
}

const diagramSources = new Map();
for (const source of sources.values()) {
  if (source.markdown) diagramSources.set(source.name, md.parse(source.raw, {}).filter((token) =>
    token.type === "fence" && token.info.trim() === "mermaid").map((token) => token.content));
}
const browser = await chromium.launch({ headless: true });
const diagrams = [];
let page;
try {
  page = await browser.newPage();
  await page.setContent("<!doctype html><html><body></body></html>");
  await page.addScriptTag({ path: path.join(here, "node_modules", "mermaid", "dist", "mermaid.min.js") });
  await page.evaluate(() => mermaid.initialize({
    startOnLoad: false, securityLevel: "strict", deterministicIds: true,
    theme: "base", fontFamily: "Segoe UI, Arial, sans-serif",
    themeVariables: {
      primaryColor: "#edf4fc", primaryTextColor: "#10283e", primaryBorderColor: "#82a7bd",
      lineColor: "#3d718a", secondaryColor: "#d9f5ed", tertiaryColor: "#eee8fa",
      fontSize: "18px"
    },
    flowchart: { htmlLabels: false, useMaxWidth: true, curve: "basis" },
    sequence: { useMaxWidth: true, mirrorActors: false, wrap: true }
  }));

  async function diagram(code, label) {
    const id = `mermaid-${diagrams.length}`;
    const svg = await page.evaluate(async ({ id, code }) => {
      await mermaid.parse(code);
      return (await mermaid.render(id, code)).svg;
    }, { id, code });
    if (!svg.includes("<svg") || /<script[\s>]/i.test(svg)) throw new Error(`Invalid rendered diagram: ${label}`);
    diagrams.push({ id, label, hash: sha(code) });
    return `<figure class="diagram" data-diagram="${id}"><figcaption>${escape(label)}
      <button type="button" class="quiet zoom-button" data-zoom="${id}" aria-label="Ampliar diagrama: ${escape(label)}">Ampliar ↗</button>
      </figcaption><div class="diagram-frame">${svg}</div></figure>`;
  }

  const pendingDiagrams = [];
  md.renderer.rules.fence = (tokens, index, options, env) => {
    const token = tokens[index];
    if (token.info.trim() === "mermaid") {
      const marker = `<!--DIAGRAM:${pendingDiagrams.length}-->`;
      pendingDiagrams.push({ marker, code: token.content, label: `Diagrama · ${env.title}` });
      return marker;
    }
    return `<div class="code-block"><div class="code-bar"><span>${escape(token.info || "texto")}</span>
      <button type="button" class="copy-button quiet">Copiar</button></div>
      <pre tabindex="0"><code>${escape(token.content)}</code></pre></div>`;
  };
  md.renderer.rules.heading_open = (tokens, index, options, env, renderer) => {
    if (env.source) {
      const entry = env.source.headings.find((heading) => heading.line === tokens[index].map[0]);
      if (entry) tokens[index].attrSet("id", `${env.source.id}--${entry.key}`);
    }
    return renderer.renderToken(tokens, index, options);
  };
  md.renderer.rules.link_open = (tokens, index, options, env, renderer) => {
    const token = tokens[index];
    const href = token.attrGet("href");
    if (/^(https?:|mailto:)/i.test(href)) {
      token.attrSet("target", "_blank");
      token.attrSet("rel", "noopener noreferrer");
      token.attrSet("class", "external-link");
      token.attrSet("title", "Referência externa. Abre em outra aba.");
    } else {
      const { name, fragment } = projectTarget(href, env.file);
      if (name === "docs/apresentacao.html") token.attrSet("href", "#slide/inicio");
      else {
        const target = sources.get(name);
        if (!target) throw new Error(`Unresolved offline link in ${env.file}: ${href}`);
        const heading = fragment ? target.headings.find((item) => item.key === slug(fragment)) : null;
        token.attrSet("href", `#doc/${target.id}${heading ? `/${heading.key}` : ""}`);
      }
    }
    return renderer.renderToken(tokens, index, options);
  };
  md.renderer.rules.image = (tokens, index) => {
    const token = tokens[index];
    if (/^https:\/\/img\.shields\.io\//.test(token.attrGet("src"))) {
      return `<span class="source-badge">${escape(token.content)}</span>`;
    }
    throw new Error("Document contains an image that must be explicitly embedded for offline delivery.");
  };
  const render = (text, file, full = false) => md.render(text, {
    file, title: sources.get(file)?.title ?? "Roteiro",
    source: full ? sources.get(file) : null
  });

  const renderedSlides = [];
  const ids = new Set();
  for (const [index, slide] of slides.entries()) {
    if (!/^[a-z0-9-]+$/.test(slide.id) || ids.has(slide.id)) throw new Error(`Invalid/duplicate slide ID: ${slide.id}`);
    ids.add(slide.id);
    const chapter = chapters.find((item) => item.id === slide.chapter);
    if (!chapter) throw new Error(`Unknown chapter: ${slide.chapter}`);
    const files = [...new Set([...(slide.sources ?? []), slide.diagram?.file, slide.excerpt?.file, slide.code?.file].filter(Boolean))];
    for (const file of files) if (!sources.has(file)) throw new Error(`Missing slide source: ${file}`);
    const sourceLinks = files.map((file) => `<a href="#doc/${sources.get(file).id}">${escape(sources.get(file).title)}</a>`).join("");
    let content = "";
    if (slide.diagram) {
      const code = diagramSources.get(slide.diagram.file)?.[slide.diagram.index];
      if (!code) throw new Error(`Missing diagram: ${slide.id}`);
      content += await diagram(code, slide.title);
    }
    if (slide.code) content += render(excerpt(slide.code), slide.code.file);
    if (slide.excerpt) content += `<div class="table-scroll" tabindex="0" aria-label="Tabela de referência">${render(excerpt(slide.excerpt), slide.excerpt.file)}</div>`;
    if (slide.cards) content += `<div class="cards cards-${slide.cards.length}">${slide.cards.map((card, cardIndex) =>
      `<section class="card"><span class="card-index">${String(cardIndex + 1).padStart(2, "0")}${card.label ? ` / ${escape(card.label)}` : ""}</span>
      <h3>${escape(card.title)}</h3><p>${escape(card.text)}</p></section>`).join("")}</div>`;
    if (slide.steps) content += `<ol class="steps">${slide.steps.map(([title, text]) =>
      `<li><div><h3>${escape(title)}</h3><p>${escape(text)}</p></div></li>`).join("")}</ol>`;
    if (slide.body) content += `<div class="slide-prose">${render(slide.body, files[0])}</div>`;
    if (slide.callouts) content += `<ul class="pills">${slide.callouts.map((text) => `<li>${escape(text)}</li>`).join("")}</ul>`;
    if (slide.checklist) content += `<div class="checklist" role="group" aria-label="Checklist da reunião">${slide.checklist.map((text, item) =>
      `<label><input type="checkbox" id="check-${index}-${item}"><span>${escape(text)}</span></label>`).join("")}</div>
      <p class="muted">As marcações não são gravadas.</p>`;
    renderedSlides.push(`<article class="slide ${slide.kind === "cover" ? "cover" : ""}" id="slide-${slide.id}"
      data-slide="${slide.id}" data-chapter="${slide.chapter}" aria-labelledby="title-${slide.id}">
      <header class="slide-heading"><p class="eyebrow">${String(chapters.indexOf(chapter) + 1).padStart(2, "0")} / ${escape(chapter.title)}
      ${slide.badge ? `<span class="scope-badge">${escape(slide.badge)}</span>` : ""}</p>
      <h1 id="title-${slide.id}" tabindex="-1">${escape(slide.title).replace(/\n/g, "<br>")}</h1>
      ${slide.lead ? `<p class="lead">${escape(slide.lead)}</p>` : ""}</header>
      <div class="slide-content">${content}</div>
      <aside class="presenter-note"><strong>Notas técnicas</strong><p>${escape(slide.notes)}</p></aside>
      <footer class="slide-sources"><span>DOCUMENTOS</span>${sourceLinks}</footer></article>`);
  }

  const renderedDocuments = [];
  const search = [];
  for (const source of sources.values()) {
    const content = source.markdown ? render(source.raw, source.name, true)
      : `<div class="code-block"><pre tabindex="0"><code>${escape(source.raw)}</code></pre></div>`;
    renderedDocuments.push(`<article class="document" id="${source.id}" data-document="${source.id}"
      data-source="${escape(source.name)}" data-source-hash="${sha(source.raw)}" aria-labelledby="${source.id}-label">
      <header class="document-heading"><p class="eyebrow">${source.reference ? "ARTEFATO DE REFERÊNCIA" : source.legacy ? "DOCUMENTAÇÃO LEGADA" : "DOCUMENTAÇÃO COMPLETA"}</p>
      <h1 id="${source.id}-label" tabindex="-1">${escape(source.title)}</h1><p class="source-path">${escape(source.name)}</p></header>
      <div class="document-content">${content}</div></article>`);
    if (!source.markdown) {
      search.push({ type: "Artefato", title: source.title, text: source.raw, href: `#doc/${source.id}` });
      continue;
    }
    const boundaries = source.headings.filter((item) => item.level <= 2);
    for (const [index, heading] of boundaries.entries()) {
      const text = source.raw.split("\n").slice(heading.line, boundaries[index + 1]?.line).join("\n");
      search.push({ type: source.legacy ? "Legado" : "Documento", title: `${source.title} · ${heading.title}`,
        text, href: `#doc/${source.id}/${heading.key}` });
    }
  }
  for (const slide of slides) search.unshift({
    type: "Slide", title: slide.title.replace(/\n/g, " "),
    text: [slide.lead, slide.body, slide.notes, ...(slide.cards ?? []).flatMap((card) => [card.title, card.text]),
      ...(slide.steps ?? []).flat(), ...(slide.checklist ?? [])].filter(Boolean).join(" "),
    href: `#slide/${slide.id}`
  });
  let material = renderedSlides.join("\n") + "</section><section id=\"library\" class=\"library\">" + renderedDocuments.join("\n") + "</section>";
  for (const item of pendingDiagrams) material = material.replace(item.marker, await diagram(item.code, item.label));
  material = material.replace(/^[ \t]+$/gm, "");

  const css = await fs.readFile(path.join(here, "style.css"), "utf8");
  const runtime = (await fs.readFile(path.join(here, "runtime.js"), "utf8"))
    .replace(/\r\n/g, "\n").replace(/<\/script/gi, "<\\/script");
  const inputs = [];
  for (const source of sources.values()) inputs.push({ path: source.name, sha256: sha(source.raw), kind: source.markdown ? "markdown" : "reference" });
  for (const name of ["build.mjs", "slides.mjs", "style.css", "runtime.js", "package.json", "package-lock.json"]) {
    inputs.push({ path: `tools/presentation/${name}`, sha256: sha((await fs.readFile(path.join(here, name), "utf8")).replace(/\r\n/g, "\n")), kind: "generator" });
  }
  const version = sha(JSON.stringify(inputs)).slice(0, 12);
  const manifest = { version, slides: slides.length, chapters: chapters.length,
    markdownDocuments: allMarkdown.length, referenceFiles: [...sources.values()].filter((source) => !source.markdown).length,
    diagrams: diagrams.length, inputs };
  const scriptHash = crypto.createHash("sha256").update(runtime).digest("base64");
  const slideNavigation = chapters.map((chapter, index) => `<section class="nav-chapter">
    <h2><span>${String(index + 1).padStart(2, "0")}</span>${escape(chapter.title)}</h2>
    ${slides.filter((slide) => slide.chapter === chapter.id).map((slide) =>
      `<a href="#slide/${slide.id}" data-nav-slide="${slide.id}"><span>${String(slides.indexOf(slide) + 1).padStart(2, "0")}</span>${escape(slide.title.replace(/\n/g, " "))}</a>`).join("")}</section>`).join("");
  const documentNavigation = [...sources.values()].map((source) =>
    `<a href="#doc/${source.id}" data-nav-document="${source.id}"><span>${source.reference ? "↳" : source.legacy ? "L" : "D"}</span>${escape(source.title)}</a>`).join("");
  const csp = `default-src 'none'; script-src 'sha256-${scriptHash}'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; font-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'`;
  const html = `<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<meta name="referrer" content="no-referrer"><meta name="color-scheme" content="light">
<title>Lab OBO: AKS, BFF e Azure SQL</title>
<meta name="description" content="Arquitetura, autenticação, implantação e testes do lab OBO com AKS, BFF e Azure SQL.">
<style>${css}</style></head>
<body data-mode="reader" data-print="deck">
<a class="skip-link" href="#main">Ir para o conteúdo</a>
<button id="nav-backdrop" class="nav-backdrop" aria-label="Fechar índice" hidden></button>
<aside id="sidebar" class="sidebar" aria-label="Navegação da apresentação">
  <a class="brand" href="#slide/inicio"><span class="brand-mark" aria-hidden="true">OBO</span><span>DOCUMENTOS<br><strong>PROTEGIDOS</strong></span></a>
  <p class="brand-caption">REFERÊNCIA DE IMPLEMENTAÇÃO</p>
  <div class="nav-tabs" role="group" aria-label="Tipo de navegação">
    <button id="nav-slides" type="button" aria-pressed="true">Roteiro</button>
    <button id="nav-documents" type="button" aria-pressed="false">Documentação</button>
  </div>
  <nav id="slide-navigation" class="nav-scroll" aria-label="Capítulos e slides">${slideNavigation}</nav>
  <nav id="document-navigation" class="nav-scroll" aria-label="Documentos completos" hidden>${documentNavigation}</nav>
  <div class="sidebar-footer"><span class="online-dot" aria-hidden="true"></span> HTML offline · sem telemetria<br>
  <small>${slides.length} slides · ${allMarkdown.length} documentos · versão ${version}</small></div>
</aside>
<div class="workspace">
  <header class="toolbar">
    <button id="menu-toggle" class="tool menu-toggle" type="button" aria-controls="sidebar" aria-expanded="false">☰ Índice</button>
    <div class="breadcrumbs"><span>LAB DE REFERÊNCIA</span><strong id="chapter-label">Objetivo e limites</strong></div>
    <div class="toolbar-actions">
      <button id="search-open" class="tool" type="button" aria-haspopup="dialog">⌕ <span>Buscar</span><kbd>/</kbd></button>
      <button id="reader-toggle" class="tool" type="button" aria-pressed="false">Leitura</button>
      <button id="notes-toggle" class="tool" type="button" aria-pressed="false" title="Notas técnicas (N)">Notas</button>
      <button id="fullscreen" class="tool" type="button">Tela cheia</button>
      <label class="print-picker"><span class="sr-only">Conteúdo para impressão</span><select id="print-scope">
        <option value="deck">Imprimir roteiro</option><option value="docs">Imprimir documentação</option><option value="current">Imprimir slide atual</option>
      </select></label><button id="print" class="tool" type="button">Imprimir</button>
    </div>
  </header>
  <main id="main" tabindex="-1"><noscript><p class="notice">JavaScript está desativado: o roteiro permanece legível. Ative-o para navegação e biblioteca.</p></noscript>
    <section id="deck" class="deck" aria-label="Roteiro de apresentação">${material}
  </main>
  <footer class="navigation-bar"><button id="previous" class="nav-button" type="button">← Anterior</button>
    <div class="progress-block"><span id="position" aria-live="polite">Roteiro completo</span><progress id="progress" max="${slides.length}" value="1"></progress></div>
    <button id="next" class="nav-button primary" type="button">Próximo →</button></footer>
</div>
<dialog id="search-dialog" class="search-dialog" aria-labelledby="search-title">
  <div class="dialog-heading"><h2 id="search-title">Pesquisar no roteiro e nas fontes</h2><button class="tool" data-close="search-dialog" aria-label="Fechar busca">Fechar ×</button></div>
  <label for="search-input" class="sr-only">Termo de busca</label><input id="search-input" type="search" placeholder="Ex.: OBO, permissões, Private Endpoint..." autocomplete="off">
  <p id="search-count" class="muted" aria-live="polite"></p><ul id="search-results"></ul>
</dialog>
<dialog id="diagram-dialog" class="diagram-dialog" aria-labelledby="diagram-title">
  <div class="dialog-heading"><h2 id="diagram-title">Diagrama</h2><div class="dialog-actions">
    <button id="zoom-out" class="tool" aria-label="Reduzir diagrama">−</button><button id="zoom-reset" class="tool">Ajustar</button>
    <button id="zoom-in" class="tool" aria-label="Aumentar diagrama">+</button><button class="tool" data-close="diagram-dialog" aria-label="Fechar diagrama">Fechar ×</button>
  </div></div><div id="diagram-viewport"><div id="diagram-holder"></div></div>
</dialog>
<div id="toast" role="status" aria-live="polite" class="toast" hidden></div>
<script id="presentation-data" type="application/json">${json({
    chapters, slides: slides.map(({ id, chapter, title }) => ({ id, chapter, title })),
    documents: [...sources.values()].map(({ id, title, name }) => ({ id, title, name })), search, manifest
  })}</script>
<script>${runtime}</script></body></html>`;
  await fs.writeFile(output, html);
  console.log(JSON.stringify({ output: "docs/apresentacao.html", bytes: Buffer.byteLength(html), ...manifest, inputs: inputs.length }, null, 2));
} finally {
  await browser.close();
}
