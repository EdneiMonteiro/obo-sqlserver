(() => {
  "use strict";
  const data = JSON.parse(document.getElementById("presentation-data").textContent);
  const byId = (id) => document.getElementById(id);
  const allSlides = [...document.querySelectorAll("[data-slide]")];
  const allDocuments = [...document.querySelectorAll("[data-document]")];
  const normalize = (text) => text.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();
  let slideIndex = 0;
  let documentIndex = 0;
  let mode = "slides";
  let toastTimer;
  let diagramOrigin = null;
  let diagramNode = null;
  let zoom = 1;

  function notify(message) {
    clearTimeout(toastTimer);
    byId("toast").textContent = message;
    byId("toast").hidden = false;
    toastTimer = setTimeout(() => { byId("toast").hidden = true; }, 4500);
  }
  function closeMenu() {
    document.body.classList.remove("nav-open");
    byId("menu-toggle").setAttribute("aria-expanded", "false");
    byId("nav-backdrop").hidden = true;
  }
  function showMenu() {
    document.body.classList.add("nav-open");
    byId("menu-toggle").setAttribute("aria-expanded", "true");
    byId("nav-backdrop").hidden = false;
    byId("sidebar").querySelector("[aria-current]")?.focus();
  }
  function updateNavigation() {
    const inLibrary = mode === "library";
    const collection = inLibrary ? data.documents : data.slides;
    const index = inLibrary ? documentIndex : slideIndex;
    byId("previous").disabled = index === 0;
    byId("next").disabled = index === collection.length - 1;
    byId("position").textContent = inLibrary ? `Documento ${index + 1} / ${collection.length}` :
      `${mode === "reader" ? "Leitura" : "Slide"} ${String(index + 1).padStart(2, "0")} / ${data.slides.length}`;
    byId("progress").max = collection.length;
    byId("progress").value = index + 1;
    byId("chapter-label").textContent = inLibrary ? "Biblioteca de documentação" :
      data.chapters.find((chapter) => chapter.id === data.slides[slideIndex].chapter).title;
    byId("reader-toggle").setAttribute("aria-pressed", String(mode === "reader"));
    byId("nav-slides").setAttribute("aria-pressed", String(!inLibrary));
    byId("nav-documents").setAttribute("aria-pressed", String(inLibrary));
    byId("slide-navigation").hidden = inLibrary;
    byId("document-navigation").hidden = !inLibrary;
    for (const link of document.querySelectorAll("[data-nav-slide],[data-nav-document]")) {
      const current = inLibrary ? link.dataset.navDocument === data.documents[documentIndex].id :
        link.dataset.navSlide === data.slides[slideIndex].id;
      if (current) link.setAttribute("aria-current", "page");
      else link.removeAttribute("aria-current");
    }
  }
  function route() {
    const parts = location.hash.slice(1).split("/");
    const kind = parts[0];
    const id = parts[1];
    let destination;
    if (kind === "doc") {
      const found = data.documents.findIndex((entry) => entry.id === id);
      if (found < 0) { notify("Documento não encontrado. Voltando ao roteiro."); location.hash = "#slide/inicio"; return; }
      mode = "library";
      documentIndex = found;
      destination = parts[2] ? byId(`${id}--${parts[2]}`) : byId(`${id}-label`);
    } else {
      const found = data.slides.findIndex((entry) => entry.id === (id || "inicio"));
      if (found < 0 || (kind && kind !== "slide" && kind !== "read")) {
        notify("Destino não encontrado. Voltando ao início."); location.hash = "#slide/inicio"; return;
      }
      mode = kind === "read" ? "reader" : "slides";
      slideIndex = found;
      destination = byId(`title-${data.slides[slideIndex].id}`);
    }
    document.body.dataset.mode = mode;
    byId("deck").hidden = mode === "library";
    byId("library").hidden = mode !== "library";
    allSlides.forEach((slide, index) => {
      slide.hidden = mode !== "reader" && index !== slideIndex;
      slide.classList.toggle("is-current", index === slideIndex);
    });
    allDocuments.forEach((entry, index) => { entry.hidden = index !== documentIndex; });
    updateNavigation();
    closeMenu();
    if (byId("search-dialog").open) byId("search-dialog").close();
    if (mode === "slides") window.scrollTo({ top: 0, behavior: "instant" });
    else if (destination) destination.scrollIntoView({ block: "start", behavior: "instant" });
    destination?.focus({ preventScroll: true });
    const current = document.querySelector(mode === "library" ?
      "[data-nav-document][aria-current]" : "[data-nav-slide][aria-current]");
    current?.scrollIntoView({ block: "nearest", behavior: "instant" });
  }
  function move(delta) {
    if (mode === "library") {
      documentIndex = Math.max(0, Math.min(data.documents.length - 1, documentIndex + delta));
      location.hash = `#doc/${data.documents[documentIndex].id}`;
    } else {
      slideIndex = Math.max(0, Math.min(data.slides.length - 1, slideIndex + delta));
      location.hash = `#${mode === "reader" ? "read" : "slide"}/${data.slides[slideIndex].id}`;
    }
  }

  byId("previous").addEventListener("click", () => move(-1));
  byId("next").addEventListener("click", () => move(1));
  byId("reader-toggle").addEventListener("click", () => {
    location.hash = `#${mode === "reader" ? "slide" : "read"}/${data.slides[slideIndex].id}`;
  });
  byId("nav-slides").addEventListener("click", () => { location.hash = `#slide/${data.slides[slideIndex].id}`; });
  byId("nav-documents").addEventListener("click", () => { location.hash = `#doc/${data.documents[documentIndex].id}`; });
  byId("notes-toggle").addEventListener("click", () => {
    const enabled = document.body.dataset.notes !== "true";
    document.body.dataset.notes = String(enabled);
    byId("notes-toggle").setAttribute("aria-pressed", String(enabled));
  });
  byId("menu-toggle").addEventListener("click", () => document.body.classList.contains("nav-open") ? closeMenu() : showMenu());
  byId("nav-backdrop").addEventListener("click", closeMenu);
  byId("fullscreen").addEventListener("click", async () => {
    try {
      if (document.fullscreenElement) await document.exitFullscreen();
      else await document.documentElement.requestFullscreen();
    } catch { notify("Tela cheia não está disponível neste navegador. Use o atalho F11."); }
  });
  byId("print").addEventListener("click", () => {
    document.body.dataset.print = byId("print-scope").value;
    window.print();
  });
  byId("print-scope").addEventListener("change", () => { document.body.dataset.print = byId("print-scope").value; });

  const entries = data.search.map((entry) => ({
    ...entry, normalized: normalize(entry.title + " " + entry.text), normalizedTitle: normalize(entry.title)
  }));
  function search() {
    const query = normalize(byId("search-input").value.trim());
    const list = byId("search-results");
    list.replaceChildren();
    if (query.length < 2) { byId("search-count").textContent = "Digite ao menos 2 caracteres. A busca é local e não envia dados."; return; }
    const terms = query.split(/\s+/);
    const results = entries.filter((entry) => terms.every((term) => entry.normalized.includes(term)))
      .sort((a, b) => Number(b.normalizedTitle.includes(query)) - Number(a.normalizedTitle.includes(query)));
    byId("search-count").textContent = `${results.length} resultados · exibindo até 40`;
    for (const entry of results.slice(0, 40)) {
      const item = document.createElement("li");
      const link = document.createElement("a");
      link.href = entry.href;
      const type = document.createElement("small");
      type.textContent = entry.type;
      const title = document.createElement("strong");
      title.textContent = entry.title;
      const snippet = document.createElement("p");
      const clean = entry.text.replace(/[`#*|>]/g, "").replace(/\s+/g, " ").trim();
      const match = normalize(clean).indexOf(terms[0]);
      const start = Math.max(0, match - 65);
      snippet.textContent = `${start ? "…" : ""}${clean.slice(start, start + 210)}${clean.length > start + 210 ? "…" : ""}`;
      link.append(type, title, snippet);
      item.append(link);
      list.append(item);
    }
  }
  function openSearch() {
    byId("search-dialog").showModal();
    search();
    byId("search-input").focus();
  }
  byId("search-open").addEventListener("click", openSearch);
  byId("search-input").addEventListener("input", search);
  document.querySelectorAll("[data-close]").forEach((button) => {
    button.addEventListener("click", () => byId(button.dataset.close).close());
  });
  document.addEventListener("click", async (event) => {
    const internalLink = event.target.closest('a[href^="#"]');
    if (internalLink) {
      if (byId("search-dialog").open) byId("search-dialog").close();
      if (internalLink.hash === location.hash) route();
      closeMenu();
    }
    const copy = event.target.closest(".copy-button");
    if (copy) {
      const code = copy.closest(".code-block").querySelector("code");
      try {
        if (!navigator.clipboard?.writeText) throw new Error("Clipboard unavailable");
        await navigator.clipboard.writeText(code.textContent);
        notify("Texto copiado. Substitua os placeholders e confira o destino antes de executar.");
      } catch {
        const range = document.createRange();
        range.selectNodeContents(code);
        window.getSelection().removeAllRanges();
        window.getSelection().addRange(range);
        notify("Área de transferência indisponível. Texto selecionado: use Ctrl+C.");
      }
    }
    const zoomButton = event.target.closest("[data-zoom]");
    if (zoomButton) {
      const figure = document.querySelector(`[data-diagram="${zoomButton.dataset.zoom}"]`);
      diagramNode = figure.querySelector("svg");
      diagramOrigin = diagramNode.parentElement;
      byId("diagram-title").textContent = figure.querySelector("figcaption").childNodes[0].textContent.trim();
      byId("diagram-holder").append(diagramNode);
      zoom = 1;
      byId("diagram-holder").style.width = "100%";
      byId("diagram-dialog").showModal();
    }
  });
  function adjustZoom(delta) {
    zoom = Math.max(.5, Math.min(4, zoom + delta));
    byId("diagram-holder").style.width = `${zoom * 100}%`;
  }
  byId("zoom-in").addEventListener("click", () => adjustZoom(.25));
  byId("zoom-out").addEventListener("click", () => adjustZoom(-.25));
  byId("zoom-reset").addEventListener("click", () => { zoom = 1; byId("diagram-holder").style.width = "100%"; });
  byId("diagram-dialog").addEventListener("close", () => {
    if (diagramNode && diagramOrigin) diagramOrigin.append(diagramNode);
    diagramNode = null;
    diagramOrigin = null;
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && document.body.classList.contains("nav-open")) { closeMenu(); return; }
    if (byId("search-dialog").open || byId("diagram-dialog").open) return;
    const editing = event.target.closest("input,textarea,select,[contenteditable=true]");
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") {
      event.preventDefault(); openSearch(); return;
    }
    if (editing || event.ctrlKey || event.metaKey || event.altKey) return;
    if (event.key === "/") { event.preventDefault(); openSearch(); }
    else if (event.key.toLowerCase() === "n") byId("notes-toggle").click();
    else if (event.key === "ArrowRight" || event.key === "PageDown") { event.preventDefault(); move(1); }
    else if (event.key === "ArrowLeft" || event.key === "PageUp") { event.preventDefault(); move(-1); }
    else if (event.key === "Home") { event.preventDefault(); move(-9999); }
    else if (event.key === "End") { event.preventDefault(); move(9999); }
  });
  window.addEventListener("hashchange", route);
  if (!location.hash) history.replaceState(null, "", "#slide/inicio");
  route();
  document.body.dataset.ready = "true";
})();
