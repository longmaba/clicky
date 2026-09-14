// Run against a staged site. Playwright is a development-only dependency.
// See CONTRIBUTING.md for setup; no browser automation ships with the page.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { chromium, webkit } = require("playwright");

const site = process.env.CLICKY_SITE_URL || "http://127.0.0.1:8765/";
const output = path.resolve("build/website-checks");
fs.mkdirSync(output, { recursive: true });

async function instrument(page) {
  await page.addInitScript(() => {
    window.audioStarts = [];
    const start = AudioBufferSourceNode.prototype.start;
    AudioBufferSourceNode.prototype.start = function (...args) {
      window.audioStarts.push({
        time: performance.now(),
        duration: this.buffer.duration,
      });
      return start.apply(this, args);
    };
  });
}
const count = (page) => page.evaluate(() => audioStarts.length);
const ready = (page) =>
  page.waitForFunction(() =>
    document
      .querySelector("#audio-status")
      .textContent.startsWith("Type anywhere on this page."),
  );
async function oneStroke(page, key) {
  const before = await count(page);
  await page.keyboard.press(key);
  await page.waitForFunction((n) => audioStarts.length === n + 1, before);
  await page.waitForTimeout(80);
  assert.equal(await count(page), before + 1, `${key} must play one stroke`);
}

(async () => {
  const reports = [];
  for (const [name, browserType] of Object.entries({ chromium, webkit })) {
    const browser = await browserType.launch();
    try {
      const context = await browser.newContext({
        viewport: { width: 1440, height: 1000 },
      });
      const page = await context.newPage();
      const errors = [];
      page.on("pageerror", (error) => errors.push(error.message));
      await instrument(page);
      await page.goto(site, { waitUntil: "networkidle" });
      await ready(page);
      assert.equal(await count(page), 0, "Loading the page must stay silent");
      assert.equal(await page.locator("#typing-enabled").count(), 0);
      assert.ok(await page.locator("#typing-field").isEnabled());
      assert.equal(
        await page.evaluate(() => document.activeElement.tagName),
        "BODY",
      );
      await oneStroke(page, "a"); // First interaction: no click, toggle, or input focus.
      assert.ok(
        await page
          .locator("#keystroke-feedback")
          .evaluate((x) => x.classList.contains("is-visible")),
      );
      assert.equal(await page.locator("#keystroke-label").textContent(), "A");
      const beforeRepeat = await count(page);
      await page.keyboard.down("b");
      await page.keyboard.down("b");
      await page.keyboard.up("b");
      assert.equal(await count(page), beforeRepeat + 1);
      const beforeCombo = await count(page);
      await page.keyboard.press("Shift+c");
      assert.equal(await count(page), beforeCombo + 2);

      await page.locator("#typing-field").focus();
      const beforeField = await count(page);
      await page.keyboard.type("hello");
      assert.equal(await count(page), beforeField + 5);
      assert.equal(await page.locator("#typing-field").inputValue(), "hello");
      await page.keyboard.press("ControlOrMeta+a");
      assert.deepEqual(
        await page
          .locator("#typing-field")
          .evaluate((x) => [x.selectionStart, x.selectionEnd]),
        [0, 5],
      );

      const profiles = await page
        .locator("[data-profile]")
        .evaluateAll((xs) => xs.map((x) => x.dataset.profile));
      for (const id of profiles) {
        await page.locator(`[data-profile="${id}"]`).click();
        await ready(page);
        assert.equal(
          await page
            .locator(`[data-profile="${id}"]`)
            .getAttribute("aria-pressed"),
          "true",
        );
        assert.notEqual(
          await page.evaluate(() => document.activeElement.id),
          "typing-field",
        );
        await oneStroke(page, "d");
      }

      for (const selector of ["#preview-button", '[data-code="KeyG"]']) {
        await page.locator(selector).focus();
        for (const key of ["Enter", "NumpadEnter", "Space"])
          await oneStroke(page, key);
        const beforeHeldEnter = await count(page);
        await page.keyboard.down("NumpadEnter");
        await page.waitForTimeout(100);
        await page.keyboard.down("NumpadEnter");
        await page.keyboard.up("NumpadEnter");
        await page.waitForTimeout(100);
        assert.equal(await count(page), beforeHeldEnter + 1);
      }

      await page.locator("#volume").focus();
      const volume = Number(await page.locator("#volume").inputValue());
      await oneStroke(page, "ArrowRight");
      assert.equal(
        Number(await page.locator("#volume").inputValue()),
        volume + 1,
      );
      await page.locator("#volume").fill("0");
      const muted = await count(page);
      await page.locator("#typing-field").focus();
      await page.keyboard.press("m");
      assert.equal(await count(page), muted);
      assert.equal(await page.locator("#typing-light").textContent(), "MUTED");
      assert.equal(await page.locator("#keystroke-label").textContent(), "M");
      await page.locator("#preview-button").click();
      assert.match(await page.locator("#audio-status").textContent(), /muted/);
      assert.equal(await count(page), muted);
      await page.locator("#volume").fill("40");
      await page.locator("#typing-field").focus();
      await oneStroke(page, "n");

      // Exercise loss-of-focus cleanup, then resume without a new enable step.
      await page.evaluate(() => window.dispatchEvent(new Event("blur")));
      await page.waitForTimeout(100);
      assert.equal(await page.locator("#typing-field").inputValue(), "");
      assert.equal(await page.locator("#keystroke-label").textContent(), "");
      await page.locator("#typing-field").focus();
      await oneStroke(page, "r");
      await page.locator(".nav-donate").click();
      await oneStroke(page, "x");
      assert.ok(await page.locator("#donate-dialog").evaluate((x) => x.open));
      await page.keyboard.press("Escape");
      assert.ok(
        !(await page.locator("#donate-dialog").evaluate((x) => x.open)),
      );

      for (const width of [320, 390, 1440]) {
        await page.setViewportSize({ width, height: 1000 });
        await page.locator("footer").scrollIntoViewIfNeeded();
        await page.keyboard.press("z");
        await page.waitForTimeout(190);
        const bounds = await page.locator("#keystroke-feedback").boundingBox();
        assert.ok(bounds.x >= 0 && bounds.x + bounds.width <= width);
        assert.ok(bounds.y >= 0 && bounds.y + bounds.height <= 1000);
        assert.equal(
          await page.evaluate(() => document.documentElement.scrollWidth),
          width,
        );
        assert.equal(
          await page
            .locator("#keystroke-feedback")
            .evaluate((x) => getComputedStyle(x).pointerEvents),
          "none",
        );
        await page.screenshot({
          path: path.join(output, `${name}-${width}.png`),
        });
      }
      await page.emulateMedia({ reducedMotion: "reduce" });
      await page.keyboard.press("z");
      assert.equal(
        await page
          .locator("#keystroke-feedback")
          .evaluate((x) => getComputedStyle(x).animationName),
        "none",
      );
      assert.equal(errors.length, 0, errors.join("\n"));
      await context.close();

      // Typing during a slow initial download must not play a delayed burst.
      const slowContext = await browser.newContext();
      const slowPage = await slowContext.newPage();
      await instrument(slowPage);
      let releaseSamples;
      const sampleGate = new Promise((resolve) => {
        releaseSamples = resolve;
      });
      await slowPage.route("**/sounds/**/*.wav", async (route) => {
        await sampleGate;
        await route.continue();
      });
      await slowPage.goto(site, { waitUntil: "domcontentloaded" });
      await slowPage.keyboard.type("fast");
      assert.equal(await count(slowPage), 0);
      releaseSamples();
      await ready(slowPage);
      await slowPage.waitForTimeout(150);
      assert.equal(
        await count(slowPage),
        0,
        "Old keys must not replay after loading",
      );
      await oneStroke(slowPage, "f");
      await slowContext.close();
      reports.push({
        browser: name,
        profiles: profiles.length,
        pageWideDefault: true,
        noAutoplay: true,
        firstKeyWithoutClick: true,
        noRepeatedOrDoubleActivation: true,
        nativeTextAndSelection: true,
        volumeMute: true,
        resumesAfterBlur: true,
        visibleWhileScrolled: true,
        reducedMotion: true,
        noDelayedLoadingBurst: true,
        errors,
      });
      console.log(`${name}: page-wide keyboard checks passed`);
    } finally {
      await browser.close();
    }
  }
  fs.writeFileSync(
    path.join(output, "report.json"),
    JSON.stringify(reports, null, 2) + "\n",
  );
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
