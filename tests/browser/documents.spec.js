const { test, expect } = require("@playwright/test");
const { randomUUID } = require("node:crypto");

test("real Entra login, OBO round-trip, denied receiver, CSRF and token isolation", async ({ page, context, baseURL }) => {
  const startedAt = Date.now();
  test.setTimeout(0);
  if (!baseURL || !baseURL.startsWith("https://")) throw new Error("Set OBO_BASE_URL to the deployed HTTPS origin.");
  const origin = new URL(baseURL).origin;
  const leakedHeaders = [];
  page.on("request", (request) => {
    if (new URL(request.url()).origin === origin && request.headers().authorization) {
      leakedHeaders.push(new URL(request.url()).pathname);
    }
  });

  await page.goto("/");
  await page.getByRole("link", { name: "Entrar com Microsoft Entra ID" }).click();
  // The operator completes Entra login/MFA in this browser. No password automation or saved cookies.
  try {
    await page.locator("#workspace").waitFor({ state: "visible", timeout: 0 });
  } catch {
    throw new Error("Browser closed before Entra login completed. Retry without sharing credentials or authentication URLs.");
  }
  test.setTimeout(Date.now() - startedAt + 5 * 60 * 1000);
  const session = await page.evaluate(async () => (await fetch("/bff/session")).json());
  expect(session.authenticated).toBe(true);
  expect(Object.keys(session).sort()).toEqual(["authenticated", "csrfToken", "name", "objectId", "tenantId"].sort());
  const cookies = await context.cookies(baseURL);
  const cookie = cookies.find((item) => item.name === "__Host-obo-session");
  expect(cookie).toBeDefined();
  expect(cookie.httpOnly).toBe(true);
  expect(cookie.secure).toBe(true);
  expect(await page.evaluate(() => ({ local: localStorage.length, session: sessionStorage.length })))
    .toEqual({ local: 0, session: 0 });

  const csrf = await page.evaluate(async () => {
    const response = await fetch("/api/documents", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: "{}"
    });
    return response.status;
  });
  expect(csrf).toBe(400);

  const content = Buffer.from("OBO browser fixture " + randomUUID(), "utf8");
  await page.locator('input[name="file"]').setInputFiles({ name: "fixture.txt", mimeType: "text/plain", buffer: content });
  await page.getByRole("button", { name: "Criptografar e enviar" }).click();
  await expect(page.locator("#created")).toContainText("Documento:", { timeout: 90000 });
  const downloadPromise = page.waitForEvent("download", { timeout: 90000 });
  await page.getByRole("button", { name: "Ler e baixar" }).click();
  const download = await downloadPromise;
  const chunks = [];
  for await (const chunk of await download.createReadStream()) chunks.push(chunk);
  expect(Buffer.concat(chunks).equals(content)).toBe(true);
  await download.delete();

  await page.locator('input[name="receiver"]').fill(randomUUID());
  await page.locator('input[name="file"]').setInputFiles({ name: "denied.txt", mimeType: "text/plain", buffer: content });
  const oldDocument = await page.locator('input[name="document"]').inputValue();
  await page.getByRole("button", { name: "Criptografar e enviar" }).click();
  await expect(page.locator('input[name="document"]')).not.toHaveValue(oldDocument, { timeout: 90000 });
  await page.getByRole("button", { name: "Ler e baixar" }).click();
  await expect(page.locator("#status")).toContainText("Acesso negado", { timeout: 90000 });
  expect(leakedHeaders).toEqual([]);

  await page.getByRole("button", { name: "Sair desta aplicacao" }).click();
  await expect(page.locator("#workspace")).toBeHidden();
  expect(await page.evaluate(async () => (await fetch("/bff/session")).json())).toEqual({ authenticated: false });
});
