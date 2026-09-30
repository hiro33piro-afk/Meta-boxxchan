// End-to-end test of the web UI in headless Chromium:
// boots MiniOS from the page, types on the emulated keyboard and checks
// the result on the serial console panel.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { chromium } from "playwright";
import { serve } from "../tools/serve.mjs";

const PORT = 18080;
let server;
let browser;
let page;
const errors = [];

before(async () => {
    server = await serve(PORT);
    browser = await chromium.launch();
    page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(`http://localhost:${PORT}/`);
});

after(async () => {
    await browser?.close();
    server?.close();
});

test("shows the OS list", async () => {
    const names = await page.locator(".os-card .os-name").allTextContents();
    assert.ok(names.includes("MiniOS"));
    assert.ok(names.length >= 5);
});

test("boots MiniOS and runs a command from the keyboard", async () => {
    await page.click("#quick-start");
    await page.waitForSelector("#overlay", { state: "hidden", timeout: 30000 });
    await page.locator("#serial-panel summary").click();
    await page.waitForFunction(() => document.querySelector("#serial-output").textContent.includes("minios>"), null, { timeout: 30000 });

    await page.locator("#screen").click();
    await page.keyboard.type("calc 50 - 8", { delay: 30 });
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => document.querySelector("#serial-output").textContent.includes("= 42"), null, { timeout: 10000 });

    assert.equal(await page.locator("#status").getAttribute("data-state"), "running");
    assert.match(page.url(), /\?os=minios/);
});

test("serial console input", async () => {
    await page.fill("#serial-input", "echo from-serial");
    await page.press("#serial-input", "Enter");
    await page.waitForFunction(() => /from-serial\n/.test(document.querySelector("#serial-output").textContent), null, { timeout: 10000 });
});

test("pause and resume", async () => {
    await page.click("#btn-pause");
    await page.waitForFunction(() => document.querySelector("#status").dataset.state === "paused");
    await page.click("#btn-pause");
    await page.waitForFunction(() => document.querySelector("#status").dataset.state === "running");
});

test("save and restore state", async () => {
    await page.fill("#serial-input", "echo before-save");
    await page.press("#serial-input", "Enter");
    const [download] = await Promise.all([
        page.waitForEvent("download"),
        page.click("#btn-save"),
    ]);
    assert.match(download.suggestedFilename(), /minios-state\.bin/);
    const statePath = await download.path();

    await page.fill("#serial-input", "clear");
    await page.press("#serial-input", "Enter");
    await page.click("#serial-clear");

    await page.setInputFiles("#state-input", statePath);
    await page.waitForFunction(() => document.querySelector("#toast").textContent.includes("復元しました"), null, { timeout: 10000 });
    await page.fill("#serial-input", "echo after-restore");
    await page.press("#serial-input", "Enter");
    await page.waitForFunction(() => document.querySelector("#serial-output").textContent.includes("after-restore\n"), null, { timeout: 10000 });
    // The screen shows the restored contents from before "clear".
    assert.match(await page.locator("#screen").innerText(), /before-save/);
});

test("screenshot", async () => {
    if (process.env.SCREENSHOT) await page.screenshot({ path: process.env.SCREENSHOT });
    const [download] = await Promise.all([
        page.waitForEvent("download"),
        page.click("#btn-screenshot"),
    ]);
    assert.match(download.suggestedFilename(), /\.png$/);
});

test("power off returns to the welcome screen", async () => {
    await page.click("#btn-stop");
    await page.waitForSelector("#welcome", { state: "visible" });
    assert.equal(await page.locator("#status").getAttribute("data-state"), "idle");
    assert.deepEqual(errors, []);
});
