const { test, expect } = require("@playwright/test");
const fs = require("node:fs/promises");
const path = require("node:path");

test("SPA handles upload/download, denied receiver and logout without browser OAuth", async ({ page }) => {
  const browserErrors = [];
  page.on("pageerror", (error) => browserErrors.push(error.message));
  page.on("console", (message) => {
    if (message.text().includes("Pattern attribute")) browserErrors.push(message.text());
  });
  const id = "11111111-1111-4111-8111-111111111111";
  const tenant = "22222222-2222-4222-8222-222222222222";
  const object = "33333333-3333-4333-8333-333333333333";
  const bytes = Buffer.from("Fixture: plaintext round-trip, not a constant size check.");
  let authenticated = true;
  let uploaded;
  let forbidden = false;
  await page.route("https://ui.example.test/**", async (route) => {
    const request = route.request();
    expect(request.headers().authorization).toBeUndefined();
    const pathname = new URL(request.url()).pathname;
    if (pathname === "/bff/session") {
      return route.fulfill({ json: authenticated ? { authenticated, tenantId: tenant, objectId: object, name: "<script>not executable</script>", csrfToken: "csrf-fixture" } : { authenticated } });
    }
    if (pathname === "/bff/logout") {
      expect(request.headers()["x-csrf-token"]).toBe("csrf-fixture");
      authenticated = false;
      return route.fulfill({ status: 204 });
    }
    if (pathname === "/api/documents") {
      expect(request.headers()["x-csrf-token"]).toBe("csrf-fixture");
      uploaded = request.postDataJSON();
      return route.fulfill({ status: 201, json: { documentId: id } });
    }
    if (pathname.startsWith("/api/documents/")) {
      return forbidden
        ? route.fulfill({ status: 403, json: { error: "denied" } })
        : route.fulfill({ json: { documentId: id, fileName: "fixture.txt", payloadBase64: bytes.toString("base64") } });
    }
    const asset = { "/": "index.html", "/app.js": "app.js", "/styles.css": "styles.css" }[pathname];
    if (!asset) return route.fulfill({ status: 404 });
    const body = await fs.readFile(path.join(__dirname, "..", "..", "src", "spa", asset));
    return route.fulfill({ body, contentType: asset.endsWith(".html") ? "text/html" : asset.endsWith(".js") ? "text/javascript" : "text/css" });
  });
  await page.goto("/");
  await expect(page.locator("#workspace")).toBeVisible();
  for (const name of ["tenant", "receiver", "document"]) {
    const input = page.locator(`input[name="${name}"]`);
    await input.fill("not-a-guid");
    expect(await input.evaluate((element) => element.validity.patternMismatch)).toBe(true);
    await input.fill(name === "tenant" ? tenant : name === "receiver" ? object : id);
    expect(await input.evaluate((element) => element.checkValidity())).toBe(true);
  }
  await expect(page.locator("#user-name")).toHaveText("<script>not executable</script>");
  await page.locator('input[name="file"]').setInputFiles({ name: "fixture.txt", mimeType: "text/plain", buffer: bytes });
  await page.getByRole("button", { name: "Criptografar e enviar" }).click();
  await expect(page.locator("#created")).toContainText(id);
  expect(uploaded.receiverObjectId).toBe(object);
  expect(Buffer.from(uploaded.payloadBase64, "base64").equals(bytes)).toBe(true);
  const downloadPromise = page.waitForEvent("download");
  await page.getByRole("button", { name: "Ler e baixar" }).click();
  const download = await downloadPromise;
  const chunks = [];
  for await (const chunk of await download.createReadStream()) chunks.push(chunk);
  expect(Buffer.concat(chunks).equals(bytes)).toBe(true);
  await download.delete();
  forbidden = true;
  await page.getByRole("button", { name: "Ler e baixar" }).click();
  await expect(page.locator("#status")).toContainText("Acesso negado");
  await page.getByRole("button", { name: "Sair desta aplicacao" }).click();
  await expect(page.locator("#workspace")).toBeHidden();
  expect(await page.evaluate(() => localStorage.length + sessionStorage.length)).toBe(0);
  expect(browserErrors).toEqual([]);
});
