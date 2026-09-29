"use strict";

const byId = (id) => document.getElementById(id);
let csrfToken = null;
const status = (message) => { byId("status").textContent = message; };

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    credentials: "same-origin",
    cache: "no-store",
    redirect: "error",
    headers: { ...options.headers, ...(csrfToken ? { "x-csrf-token": csrfToken } : {}) }
  });
  if (!response.ok) {
    const descriptions = { 400: "Entrada invalida ou sessao expirada.", 401: "Entre novamente.", 403: "Acesso negado: voce nao e o destinatario.", 404: "Documento nao encontrado.", 413: "Arquivo muito grande." };
    const correlation = response.headers.get("x-correlation-id");
    throw new Error((descriptions[response.status] ?? `Falha HTTP ${response.status}.`) + (correlation ? ` Correlacao: ${correlation}` : ""));
  }
  return response.status === 204 ? null : response.json();
}

async function refreshSession() {
  const session = await api("/bff/session");
  csrfToken = session.csrfToken ?? null;
  byId("login").hidden = session.authenticated;
  byId("logout").hidden = !session.authenticated;
  byId("identity").hidden = !session.authenticated;
  byId("workspace").hidden = !session.authenticated;
  for (const [id, value] of [["user-name", session.name], ["tenant", session.tenantId], ["object", session.objectId]]) {
    byId(id).textContent = value ?? "";
  }
  if (session.authenticated) {
    byId("send").elements.tenant.value = session.tenantId;
    byId("send").elements.receiver.value = session.objectId;
  }
  status(session.authenticated ? "Sessao autenticada. Nenhum access token e entregue a SPA." : "Entre para enviar ou receber um documento.");
}

async function run(form, action) {
  const button = form.querySelector("button");
  button.disabled = true;
  try { await action(); }
  catch (error) { status(error.message); }
  finally { button.disabled = false; }
}

byId("send").addEventListener("submit", (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  void run(form, async () => {
    const file = form.elements.file.files[0];
    if (!file || file.size === 0 || file.size > 10 * 1024 * 1024) throw new Error("Escolha um arquivo entre 1 byte e 10 MiB.");
    const bytes = new Uint8Array(await file.arrayBuffer());
    let binary = "";
    for (let offset = 0; offset < bytes.length; offset += 8192) {
      binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
    }
    status("Enviando...");
    const result = await api("/api/documents", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        receiverTenantId: form.elements.tenant.value.trim(),
        receiverObjectId: form.elements.receiver.value.trim(),
        fileName: file.name,
        contentType: file.type || "application/octet-stream",
        payloadBase64: btoa(binary)
      })
    });
    byId("created").textContent = `Documento: ${result.documentId}`;
    byId("read").elements.document.value = result.documentId;
    form.elements.file.value = "";
    status("Documento criptografado e gravado.");
  });
});

byId("read").addEventListener("submit", (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  void run(form, async () => {
    const id = form.elements.document.value.trim();
    if (!/^[0-9a-f-]{36}$/i.test(id)) throw new Error("ID de documento invalido.");
    status("Consultando autorizacao e documento...");
    const document = await api(`/api/documents/${encodeURIComponent(id)}`);
    const bytes = Uint8Array.from(atob(document.payloadBase64), (character) => character.charCodeAt(0));
    const url = URL.createObjectURL(new Blob([bytes], { type: "application/octet-stream" }));
    const link = window.document.createElement("a");
    link.href = url;
    link.download = document.fileName.replace(/[\\/:*?"<>|]/g, "_");
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    status(`Documento recebido: ${document.fileName}`);
  });
});

byId("logout").addEventListener("click", async () => {
  try {
    await api("/bff/logout", { method: "POST" });
    csrfToken = null;
    byId("created").textContent = "";
    byId("send").reset();
    byId("read").reset();
    await refreshSession();
  } catch (error) { status(error.message); }
});

void refreshSession().catch((error) => status(error.message));
