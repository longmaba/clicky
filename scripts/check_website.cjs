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
    const OriginalAudioContext = window.AudioContext || window.webkitAudioContext;
    const TrackedAudioContext = class extends OriginalAudioContext {
      constructor(...args) {
        super(...args);
        window.clickyAudioContext = this;
      }
    };
    window.AudioContext = TrackedAudioContext;
    const connect = AudioBufferSourceNode.prototype.connect;
    AudioBufferSourceNode.prototype.connect = function (target, ...args) {
      this.clickyTestGain = target;
      return connect.call(this, target, ...args);
    };
    const start = AudioBufferSourceNode.prototype.start;
    AudioBufferSourceNode.prototype.start = function (...args) {
      window.audioStarts.push({
        time: performance.now(),
        duration: this.buffer.duration,
        gain: this.clickyTestGain?.gain.value,
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
const manifests = new WeakMap();
const keyUsages = { Space: "7:44", Enter: "7:40", NumpadEnter: "7:88", Backspace: "7:42" };
async function selectedProfile(page) {
  if (!manifests.has(page))
    manifests.set(page, await page.evaluate(async () => (await fetch("./profiles.json")).json()));
  const id = await page.locator('[data-profile][aria-pressed="true"]').getAttribute("data-profile");
  return manifests.get(page).find((profile) => profile.id === id);
}
async function strokeCount(page, code) {
  const profile = await selectedProfile(page);
  const bank = profile.keySamples?.[keyUsages[code]] || profile;
  return bank.releaseSamples?.length ? 2 : 1;
}
async function expectCount(page, expected, message, settle = 160) {
  await page.waitForTimeout(settle);
  assert.equal(await count(page), expected, message);
}
async function expectGains(page, offset, expected, message) {
  const actual = await page.evaluate((offset) => audioStarts.slice(offset).map((entry) => entry.gain), offset);
  assert.equal(actual.length, expected.length, `${message}: phase count`);
  actual.forEach((gain, index) => assert.ok(Math.abs(gain - expected[index]) < 0.000001,
    `${message}: phase ${index + 1} gain ${gain}, expected ${expected[index]}`));
}
async function oneStroke(page, key) {
  const before = await count(page);
  const code = await page.evaluate((key) => {
    const target = document.activeElement;
    if (["Enter", "NumpadEnter", "Space"].includes(key) && target.matches("#preview-button, .keycap"))
      return target.dataset.code;
    return key;
  }, key);
  const phases = await strokeCount(page, code);
  await page.keyboard.press(key, { delay: 35 });
  await page.waitForFunction((n) => audioStarts.length === n, before + phases);
  await expectCount(page, before + phases, `${key} must play one complete stroke`);
}
async function oneMouseClick(page, selector, button = "left") {
  const before = await count(page);
  const phases = /preview-button|data-code/.test(selector)
    ? await strokeCount(page, await page.locator(selector).getAttribute("data-code")) : 1;
  await page.locator(selector).click({ button });
  await page.waitForFunction((n) => audioStarts.length === n, before + phases, { timeout: 3000 });
  await expectCount(page, before + phases, `${button} click on ${selector} must play once`);
}
async function onePointerClick(page, code) {
  await oneMouseClick(page, `[data-code="${code}"]`);
}

// Deliberately artificial, in-memory fixtures identify each phase by duration.
// They are served only by this test and never staged or shipped as recordings.
function fixtureWav(duration, frequency) {
  const rate = 48000;
  const frames = Math.round(duration * rate);
  const wav = Buffer.alloc(44 + frames * 2);
  wav.write("RIFF");
  wav.writeUInt32LE(wav.length - 8, 4);
  wav.write("WAVEfmt ", 8);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20);
  wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(rate, 24);
  wav.writeUInt32LE(rate * 2, 28);
  wav.writeUInt16LE(2, 32);
  wav.writeUInt16LE(16, 34);
  wav.write("data", 36);
  wav.writeUInt32LE(frames * 2, 40);
  for (let i = 0; i < frames; i++)
    wav.writeInt16LE(Math.round(500 * Math.sin(2 * Math.PI * frequency * i / rate)), 44 + i * 2);
  return wav;
}
async function releaseFixture(browser, errors, holdDownloads = false) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, hasTouch: true });
  const page = await context.newPage();
  page.on("pageerror", (error) => errors.push(error.message));
  await instrument(page);
  await page.route("**/profiles.json", async (route) => {
    const response = await route.fetch();
    const profiles = await response.json();
    for (const [id, suffix] of [["thocky", "a"], ["marbly", "b"]]) {
      const profile = profiles.find((entry) => entry.id === id);
      profile.samples = [`sounds/fixture-down-${suffix}.wav`];
      profile.releaseSamples = [`sounds/fixture-up-${suffix}.wav`];
      profile.gain = 1;
      delete profile.keySamples;
    }
    const thocky = profiles.find((entry) => entry.id === "thocky");
    thocky.keySamples = Object.fromEntries(Object.entries({ "7:44": "space", "7:40": "enter", "7:88": "enter", "7:42": "backspace" }).map(
      ([usage, category]) => [usage, {
        samples: [`sounds/fixture-${category}-down.wav`],
        releaseSamples: [`sounds/fixture-${category}-up.wav`],
      }],
    ));
    // A press-only profile remains a supported, explicit fallback.
    profiles.find((entry) => entry.id === "silent").releaseSamples = null;
    await route.fulfill({ response, json: profiles });
  });
  const fixtures = {
    "fixture-down-a.wav": fixtureWav(0.12, 300),
    "fixture-up-a.wav": fixtureWav(0.03, 600),
    "fixture-down-b.wav": fixtureWav(0.14, 350),
    "fixture-up-b.wav": fixtureWav(0.05, 700),
    "fixture-space-down.wav": fixtureWav(0.16, 300),
    "fixture-space-up.wav": fixtureWav(0.04, 600),
    "fixture-enter-down.wav": fixtureWav(0.18, 300),
    "fixture-enter-up.wav": fixtureWav(0.06, 600),
    "fixture-backspace-down.wav": fixtureWav(0.20, 300),
    "fixture-backspace-up.wav": fixtureWav(0.08, 600),
  };
  let releaseDownloads;
  const downloads = new Promise((resolve) => { releaseDownloads = resolve; });
  if (!holdDownloads) releaseDownloads();
  await page.route("**/sounds/fixture-*.wav", async (route) => {
    await downloads;
    await route.fulfill({
      contentType: "audio/wav", body: fixtures[new URL(route.request().url()).pathname.split("/").pop()],
    });
  });
  await page.goto(site, { waitUntil: holdDownloads ? "domcontentloaded" : "networkidle" });
  if (!holdDownloads) await ready(page);
  return { context, page, releaseDownloads };
}
async function checkReleaseFixtures(browser) {
  const errors = [];
  const { context, page } = await releaseFixture(browser, errors);
  try {
    assert.equal(await count(page), 0, "Fixture preparation must stay silent");
    await page.keyboard.down("a");
    await page.waitForFunction(() => audioStarts.length === 1);
    await expectCount(page, 1, "Holding past the animation timer must not release", 300);
    await page.evaluate(() => document.dispatchEvent(new KeyboardEvent("keyup", { code: "KeyA", bubbles: true })));
    await page.keyboard.down("a");
    await expectCount(page, 1, "Synthetic key-up and repeated down must not release or retrigger");
    await page.keyboard.up("a");
    await expectCount(page, 2, "Physical key-up consumes the saved release");
    await page.keyboard.up("a");
    await page.keyboard.up("q");
    await expectCount(page, 2, "Duplicate and orphan key-up must stay silent");
    assert.deepEqual(await page.evaluate(() => audioStarts.map((entry) => entry.duration)), [0.12, 0.03]);
    await expectGains(page, 0, [2, 1.4], "Keyboard release is 30% softer while press gain stays unchanged");

    for (const [key, down, up] of [["Space", 0.16, 0.04], ["Enter", 0.18, 0.06], ["NumpadEnter", 0.18, 0.06], ["Backspace", 0.20, 0.08]]) {
      await page.locator("#typing-field").focus();
      const before = await count(page);
      await page.keyboard.down(key);
      await page.waitForFunction((n) => audioStarts.length === n + 1, before);
      assert.equal(await page.evaluate(() => audioStarts.at(-1).duration), down, `${key} selects its own press bank`);
      await page.keyboard.up(key);
      await expectCount(page, before + 2, `${key} plays its own release bank`);
      assert.equal(await page.evaluate(() => audioStarts.at(-1).duration), up);
      await expectGains(page, before, [2, 1.4], `${key} preserves press gain and softens physical release`);
      if (key !== "NumpadEnter") {
        const pointerBefore = await count(page);
        await onePointerClick(page, key);
        assert.equal(await page.evaluate(() => audioStarts.at(-1).duration), up, `${key} pointer preview uses its category`);
        await expectGains(page, pointerBefore, [2, 1.4], `${key} pointer preview uses the softer release gain`);
        await page.locator(`[data-code="${key}"]`).focus();
        const keyboardBefore = await count(page);
        await oneStroke(page, "Enter");
        assert.equal(await page.evaluate(() => audioStarts.at(-1).duration), up, `${key} keyboard preview uses its category`);
        await expectGains(page, keyboardBefore, [2, 1.4], `${key} keyboard preview uses the softer release gain`);
      }
    }
    await page.locator("#preview-button").click();
    await page.waitForTimeout(160);
    assert.equal(await page.evaluate(() => audioStarts.at(-1).duration), 0.03, "Profile preview uses the generic bank");
    await page.locator("#typing-field").focus();
    let before = await count(page);
    await page.keyboard.down("Shift");
    await page.keyboard.down("b");
    await page.keyboard.down("c");
    await expectCount(page, before + 3, "Simultaneous keys only play presses while held");
    await page.keyboard.up("b");
    await page.keyboard.up("Shift");
    await page.keyboard.up("c");
    await expectCount(page, before + 6, "Each overlapping key releases independently");
    await expectGains(page, before, [0.5, 2, 2, 1.4, 0.35, 1.4],
      "Overlapping keys retain modifier volume and soften each release independently");

    await page.keyboard.down("d");
    await page.locator('[data-profile="marbly"]').click();
    await ready(page);
    before = await count(page);
    await page.keyboard.up("d");
    await expectCount(page, before + 1, "A held key keeps its original profile on release");
    assert.equal(await page.evaluate(() => audioStarts.at(-1).duration), 0.03);
    await page.locator("#typing-field").focus();
    await oneStroke(page, "e");
    assert.equal(await page.evaluate(() => audioStarts.at(-1).duration), 0.05);

    await page.keyboard.down("f");
    await page.locator("#volume").fill("0");
    await page.locator("#volume").fill("40");
    before = await count(page);
    await page.keyboard.up("f");
    await expectCount(page, before, "Muting discards the release even if unmuted before up");

    for (const reset of ["blur", "hidden", "suspend"]) {
      await page.locator("#typing-field").focus();
      await page.keyboard.down("g");
      before = await count(page);
      await page.evaluate((kind) => {
        if (kind === "blur") window.dispatchEvent(new Event("blur"));
        if (kind === "hidden") {
          Object.defineProperty(document, "hidden", { configurable: true, value: true });
          document.dispatchEvent(new Event("visibilitychange"));
          delete document.hidden;
        }
        if (kind === "suspend") clickyAudioContext.suspend().catch(() => {});
      }, reset);
      if (reset === "suspend") await page.waitForFunction(() => clickyAudioContext.state === "suspended");
      await page.keyboard.up("g");
      await expectCount(page, before, `${reset} discards pending release`);
      await page.keyboard.down("h");
      await page.waitForFunction((n) => audioStarts.length === n + 1, before);
      await page.keyboard.up("h");
      await expectCount(page, before + 2, `Typing resumes after ${reset}`);
    }

    before = await count(page);
    await page.locator("#preview-button").click();
    await expectCount(page, before + 2, "Preview plays a complete stroke");
    await expectGains(page, before, [2, 1.4], "Profile preview preserves press gain and softens release");
    const timing = await page.evaluate(() => audioStarts.at(-1).time - audioStarts.at(-2).time);
    assert.ok(timing >= 90 && timing < 500, `Preview hold should be 100 ms, got ${timing}`);
    before = await count(page);
    await page.locator("#preview-button").click();
    await page.keyboard.down("i");
    await expectCount(page, before + 2, "A new press cancels the delayed preview release");
    await page.keyboard.up("i");
    await expectCount(page, before + 3, "Physical release survives preview cancellation");

    before = await count(page);
    await page.locator('[data-code="KeyG"]').click();
    await page.locator('[data-code="KeyH"]').click();
    await expectCount(page, before + 3, "A replacement preview cancels the older release");
    before = await count(page);
    await page.locator("#preview-button").click();
    await page.evaluate(() => window.dispatchEvent(new Event("blur")));
    await expectCount(page, before + 1, "Losing focus cancels delayed preview releases");
    await page.locator("#typing-field").focus();
    await oneStroke(page, "p");

    for (const selector of ["#preview-button", '[data-code="KeyG"]']) {
      for (const key of ["Enter", "NumpadEnter", "Space"]) {
        await page.locator(selector).focus();
        const activationBefore = await count(page);
        await oneStroke(page, key);
        await expectGains(page, activationBefore, [2, 1.4], `${key} preview activation retains phase gain balance`);
        const hold = await page.evaluate(() => audioStarts.at(-1).time - audioStarts.at(-2).time);
        assert.ok(hold >= 90, "Keyboard-activated preview uses the simulated hold");
      }
    }
    before = await count(page);
    await page.locator('[data-code="ShiftLeft"]').click();
    await expectCount(page, before + 2, "Modifier keycap preview plays one pair");
    await expectGains(page, before, [0.5, 0.35], "Modifier preview combines soft modifier and softer release gains");
    before = await count(page);
    await page.locator("#preview-button").click();
    await page.locator("#volume").fill("0");
    await page.locator("#volume").fill("40");
    await expectCount(page, before + 1, "Mute cancels delayed preview release");

    before = await count(page);
    await page.locator('[data-code="Space"]').tap();
    await expectCount(page, before + 2, "Touch previews include the release");
    const bounds = await page.locator('[data-code="KeyG"]').boundingBox();
    const x = bounds.x + bounds.width / 2;
    const y = bounds.y + bounds.height / 2;
    before = await count(page);
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.move(x + 60, y + 30, { steps: 10 });
    await page.mouse.up();
    await expectCount(page, before, "Rotation drag never previews either phase");

    await page.locator('[data-profile="silent"]').click();
    await ready(page);
    await page.locator("#typing-field").focus();
    await oneStroke(page, "j");
    assert.equal(await strokeCount(page), 1, "Missing releases retain press-only playback");
    assert.deepEqual(errors, []);
  } finally {
    await context.close();
  }

  const loading = await releaseFixture(browser, errors, true);
  try {
    await loading.page.keyboard.type("fast");
    await loading.page.keyboard.down("a");
    assert.equal(await count(loading.page), 0);
    loading.releaseDownloads();
    await ready(loading.page);
    await loading.page.keyboard.up("a");
    await expectCount(loading.page, 0, "Loading cannot create a press or orphan release for old keys");
    await oneStroke(loading.page, "b");
    assert.deepEqual(errors, []);
  } finally {
    loading.releaseDownloads();
    await loading.context.close();
  }

  // Pending autoplay resumes may not manufacture a stroke after its key is up.
  const delayed = await releaseFixture(browser, errors);
  try {
    await delayed.page.evaluate(() => {
      const resume = clickyAudioContext.resume.bind(clickyAudioContext);
      clickyAudioContext.resume = () => new Promise((resolve, reject) =>
        setTimeout(() => resume().then(resolve, reject), 180));
    });
    await delayed.page.keyboard.press("k");
    await expectCount(delayed.page, 0, "Released keys cannot play after a delayed resume", 300);
    await oneStroke(delayed.page, "l");
    assert.deepEqual(errors, []);
  } finally {
    await delayed.context.close();
  }
}

const mouseReady = (page) => page.waitForFunction(() =>
  document.querySelector("#mouse-status").textContent.startsWith("Razer Orochi V2 ready."));
async function moveToMouseTarget(page) {
  await page.locator("#hero-title").scrollIntoViewIfNeeded();
  const bounds = await page.locator("#hero-title").boundingBox();
  await page.mouse.move(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
}
async function recordedMouseStroke(page, button = "left") {
  await moveToMouseTarget(page);
  const before = await count(page);
  await page.mouse.down({ button });
  // First interaction may have to resume Web Audio before the down starts.
  await page.waitForFunction((n) => audioStarts.length === n + 1, before);
  await page.mouse.up({ button });
  await expectCount(page, before + 2, `${button} mouse stroke plays exactly its two phases`);
}
async function mouseReleaseFixture(browser, errors, holdDownloads = false, failDownloads = false) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, hasTouch: true });
  const page = await context.newPage();
  page.on("pageerror", (error) => errors.push(error.message));
  await instrument(page);
  const left = { samples: ["sounds/mouse-fixture-left-down.wav"], releaseSamples: ["sounds/mouse-fixture-left-up.wav"] };
  const right = { samples: ["sounds/mouse-fixture-right-down.wav"], releaseSamples: ["sounds/mouse-fixture-right-up.wav"] };
  await page.route("**/mouse-profiles.json", (route) => route.fulfill({ json: [{
    id: "razer-orochi-v2", name: "Razer Orochi V2", subtitle: "Mouse phase test fixture", color: "E99244",
    ...left, keySamples: { "9:1": left, "9:2": right }, gain: 1, normalizationReference: false,
  }] }));
  const fixtures = {
    "mouse-fixture-left-down.wav": fixtureWav(0.11, 300),
    "mouse-fixture-left-up.wav": fixtureWav(0.025, 600),
    "mouse-fixture-right-down.wav": fixtureWav(0.13, 350),
    "mouse-fixture-right-up.wav": fixtureWav(0.045, 700),
  };
  let releaseDownloads;
  const downloads = new Promise((resolve) => { releaseDownloads = resolve; });
  if (!holdDownloads) releaseDownloads();
  await page.route("**/sounds/mouse-fixture-*.wav", async (route) => {
    await downloads;
    if (failDownloads) return route.fulfill({ status: 503, body: "Mouse fixture temporarily unavailable" });
    await route.fulfill({ contentType: "audio/wav", body: fixtures[new URL(route.request().url()).pathname.split("/").pop()] });
  });
  await page.goto(site, { waitUntil: "domcontentloaded" });
  await ready(page);
  await page.locator("#mouse-sound").selectOption("razer-orochi-v2");
  if (failDownloads) await page.waitForFunction(() => document.querySelector("#mouse-status").textContent.includes("could not load"));
  else if (!holdDownloads) await mouseReady(page);
  return { context, page, releaseDownloads };
}
async function checkMouseReleaseFixtures(browser) {
  const errors = [];
  const { context, page } = await mouseReleaseFixture(browser, errors);
  try {
    assert.equal(await count(page), 0, "Selecting a recorded mouse pack stays silent");
    for (const [button, durations] of [["left", [0.11, 0.025]], ["right", [0.13, 0.045]], ["middle", [0.11, 0.025]]]) {
      await moveToMouseTarget(page);
      const before = await count(page);
      await page.mouse.down({ button });
      await page.waitForFunction((n) => audioStarts.length === n + 1, before);
      await expectCount(page, before + 1, `${button} hold never simulates a release`, 300);
      await page.mouse.down({ button });
      await page.evaluate((button) => {
        const target = document.querySelector("#hero-title");
        const number = { left: 0, middle: 1, right: 2 }[button];
        target.dispatchEvent(new MouseEvent("mousedown", { button: number, bubbles: true }));
        target.dispatchEvent(new MouseEvent("mouseup", { button: number, bubbles: true }));
      }, button);
      await expectCount(page, before + 1, "Duplicate downs and synthetic ups cannot retrigger or release");
      await page.mouse.up({ button });
      await expectCount(page, before + 2, "A trusted mouse up consumes its saved release once");
      await page.mouse.up({ button });
      await expectCount(page, before + 2, "Orphan mouse ups stay silent");
      assert.deepEqual(await page.evaluate((offset) => audioStarts.slice(offset).map((entry) => entry.duration), before), durations,
        `${button} uses its own recordings, with generic left fallback for middle`);
      await expectGains(page, before, [0.625, 0.4375], `${button} mouse press stays unchanged and release is 30% softer`);
    }

    await moveToMouseTarget(page);
    let before = await count(page);
    await page.mouse.down({ button: "left" });
    await page.mouse.down({ button: "right" });
    await expectCount(page, before + 2, "Chorded mouse buttons have independent presses");
    await page.mouse.up({ button: "right" });
    await page.mouse.up({ button: "left" });
    await expectCount(page, before + 4, "Chorded mouse buttons release independently");
    assert.deepEqual(await page.evaluate((offset) => audioStarts.slice(offset).map((entry) => entry.duration), before), [0.11, 0.13, 0.045, 0.025]);
    await expectGains(page, before, [0.625, 0.625, 0.4375, 0.4375], "Chorded mouse releases share the softer balance");

    await page.mouse.down();
    await page.locator("#mouse-sound").selectOption("soft");
    before = await count(page);
    await page.mouse.up();
    await expectCount(page, before + 1, "A held mouse button keeps the release from its original pack");
    assert.equal(await page.evaluate(() => audioStarts.at(-1).duration), 0.025);
    await expectGains(page, before, [0.4375], "Saved mouse release retains its softer gain after changing packs");
    await oneMouseClick(page, "#hero-title");
    await page.locator("#mouse-sound").selectOption("razer-orochi-v2");
    await mouseReady(page);

    for (const mute of ["volume", "none"]) {
      await moveToMouseTarget(page);
      await page.mouse.down();
      before = await count(page);
      if (mute === "volume") {
        await page.locator("#volume").fill("0");
        await page.locator("#volume").fill("40");
      } else {
        await page.locator("#mouse-sound").selectOption("none");
        assert.ok(await page.locator("#mouse-preview").isDisabled());
        await page.locator("#mouse-sound").selectOption("razer-orochi-v2");
        await mouseReady(page);
      }
      await page.mouse.up();
      await expectCount(page, before, `${mute} discards the held release even when restored before up`);
      await recordedMouseStroke(page);
    }

    for (const reset of ["blur", "pagehide", "hidden", "suspend"]) {
      await moveToMouseTarget(page);
      await page.mouse.down();
      before = await count(page);
      await page.evaluate((kind) => {
        if (kind === "blur" || kind === "pagehide") window.dispatchEvent(new Event(kind));
        if (kind === "hidden") {
          Object.defineProperty(document, "hidden", { configurable: true, value: true });
          document.dispatchEvent(new Event("visibilitychange"));
          delete document.hidden;
        }
        if (kind === "suspend") clickyAudioContext.suspend().catch(() => {});
      }, reset);
      if (reset === "suspend") await page.waitForFunction(() => clickyAudioContext.state === "suspended");
      await page.mouse.up();
      await expectCount(page, before, `${reset} drops pending mouse release`);
      await recordedMouseStroke(page);
    }

    for (const activation of ["click", "tap", "Enter", "NumpadEnter", "Space"]) {
      before = await count(page);
      const preview = page.locator("#mouse-preview");
      if (activation === "click") await preview.click();
      else if (activation === "tap") await preview.tap();
      else {
        await preview.focus();
        await page.keyboard.down(activation);
        await page.keyboard.down(activation);
        await page.keyboard.up(activation);
      }
      await expectCount(page, before + 2, `${activation} mouse preview plays exactly one pair without keyboard typing`);
      const starts = await page.evaluate((offset) => audioStarts.slice(offset), before);
      assert.deepEqual(starts.map((entry) => entry.duration), [0.11, 0.025]);
      await expectGains(page, before, [0.625, 0.4375], `${activation} mouse preview preserves press gain and softens release`);
      assert.ok(starts[1].time - starts[0].time >= 90 && starts[1].time - starts[0].time < 500,
        "Mouse previews simulate a 100 ms hold");
    }

    before = await count(page);
    await page.locator("#mouse-preview").click();
    await moveToMouseTarget(page);
    await page.mouse.down();
    await expectCount(page, before + 2, "A physical mouse press cancels delayed preview release");
    await page.mouse.up();
    await expectCount(page, before + 3, "The physical mouse release survives preview cancellation");
    before = await count(page);
    await page.locator("#mouse-preview").click();
    await page.locator("#mouse-preview").click();
    await expectCount(page, before + 3, "A replacement mouse preview cancels the earlier delayed release");
    before = await count(page);
    await page.locator("#mouse-preview").click();
    await page.locator("#volume").fill("0");
    await page.locator("#volume").fill("40");
    await expectCount(page, before + 1, "Muting cancels pending mouse preview release");
    before = await count(page);
    await page.locator("#mouse-preview").click();
    await page.evaluate(() => window.dispatchEvent(new Event("blur")));
    await expectCount(page, before + 1, "Losing focus cancels pending mouse preview release");
    assert.deepEqual(errors, []);
  } finally { await context.close(); }

  const loading = await mouseReleaseFixture(browser, errors, true);
  try {
    await moveToMouseTarget(loading.page);
    await loading.page.mouse.down();
    await loading.page.mouse.up();
    await loading.page.mouse.down({ button: "right" });
    assert.equal(await count(loading.page), 0, "Mouse presses wait silently when recordings are unavailable");
    loading.releaseDownloads();
    await mouseReady(loading.page);
    await loading.page.mouse.up({ button: "right" });
    await expectCount(loading.page, 0, "Loading cannot manufacture mouse presses or orphan releases");
    await recordedMouseStroke(loading.page);
    assert.deepEqual(errors, []);
  } finally { loading.releaseDownloads(); await loading.context.close(); }

  const delayed = await mouseReleaseFixture(browser, errors);
  try {
    // Unlock audio before requesting suspension: WebKit may defer this transition
    // until its first activation. Keep the warm-up stroke in the count baseline.
    await recordedMouseStroke(delayed.page);
    const beforeDelay = await count(delayed.page);
    await delayed.page.evaluate(() => {
      if (clickyAudioContext.state !== "suspended") clickyAudioContext.suspend().catch(() => {});
    });
    await delayed.page.waitForFunction(() => clickyAudioContext.state === "suspended");
    await delayed.page.evaluate(() => {
      const resume = clickyAudioContext.resume.bind(clickyAudioContext);
      clickyAudioContext.resume = () => new Promise((resolve, reject) =>
        setTimeout(() => resume().then(resolve, reject), 180));
    });
    await moveToMouseTarget(delayed.page);
    await delayed.page.mouse.down();
    await delayed.page.mouse.up();
    await expectCount(delayed.page, beforeDelay, "Released mouse buttons cannot start after delayed audio resume", 300);
    await recordedMouseStroke(delayed.page);
    assert.deepEqual(errors, []);
  } finally { await delayed.context.close(); }

  const unavailable = await mouseReleaseFixture(browser, errors, false, true);
  try {
    await moveToMouseTarget(unavailable.page);
    await unavailable.page.mouse.down();
    await unavailable.page.mouse.up();
    await expectCount(unavailable.page, 0, "Unavailable mouse recordings do not create ghost sounds");
    await unavailable.page.locator("#mouse-sound").selectOption("soft");
    await oneMouseClick(unavailable.page, "#hero-title");
    assert.deepEqual(errors, []);
  } finally { await unavailable.context.close(); }
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
      // Wait only for the first press to start before releasing: autoplay resume
      // is asynchronous, and a key released before resume must not play later.
      await page.keyboard.down("a");
      await page.waitForFunction(() => audioStarts.length === 1);
      await page.keyboard.up("a");
      await expectCount(page, await strokeCount(page), "First physical key plays its complete stroke");
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
      assert.equal(await count(page), beforeRepeat + await strokeCount(page));
      const beforeCombo = await count(page);
      await page.keyboard.press("Shift+c");
      assert.equal(await count(page), beforeCombo + 2 * await strokeCount(page));

      await page.locator("#typing-field").focus();
      const beforeField = await count(page);
      await page.keyboard.type("hello");
      assert.equal(await count(page), beforeField + 5 * await strokeCount(page));
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
      assert.equal(profiles.length, (await page.evaluate(async () => (await fetch("./profiles.json")).json())).length);
      assert.equal(Number(await page.locator("[data-profile-count]").textContent()), profiles.length);
      const license = await page.request.get(new URL("licenses/kbsim-MIT.txt", site).href);
      assert.ok(license.ok(), "Bundled switch sound license must be published");
      assert.equal(await license.text(), fs.readFileSync(path.resolve("Assets/Licenses/kbsim-MIT.txt"), "utf8"), "Publish the complete, unchanged sound license");
      const mouseLicense = await page.request.get(new URL("licenses/Sadiquecat-CC0.txt", site).href);
      assert.ok(mouseLicense.ok(), "Recorded mouse sound license must be published");
      assert.equal(await mouseLicense.text(), fs.readFileSync(path.resolve("Assets/Licenses/Sadiquecat-CC0.txt"), "utf8"), "Publish the complete, unchanged mouse license");
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
        const profile = await selectedProfile(page);
        assert.equal(await page.locator("#profile-phases").textContent(), profile.releaseSamples?.length ? "Press + release" : "Press sound");
        if (profile.keySamples) {
          await page.locator("#typing-field").focus();
          for (const key of ["Space", "Enter", "NumpadEnter", "Backspace"])
            await oneStroke(page, key);
        }
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
        assert.equal(await count(page), beforeHeldEnter + await strokeCount(page));
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

      const longestName = manifests.get(page).reduce((longest, profile) =>
        profile.name.length > longest.name.length ? profile : longest);
      await page.locator(`[data-profile="${longestName.id}"]`).click();
      await ready(page);
      for (const width of [320, 390, 1440]) {
        await page.setViewportSize({ width, height: 1000 });
        await page.locator("#playground").screenshot({
          path: path.join(output, `${name}-catalog-${width}.png`),
          style: ".skip-link, #keystroke-feedback { visibility: hidden !important; }",
        });
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

      // Ordinary page clicks get one mouse sound, including the first gesture.
      // Existing audio controls retain their own activation and volume behavior.
      const mouseContext = await browser.newContext({
        viewport: { width: 1440, height: 1000 },
      });
      const mousePage = await mouseContext.newPage();
      mousePage.on("pageerror", (error) => errors.push(error.message));
      await instrument(mousePage);
      await mousePage.goto(site, { waitUntil: "networkidle" });
      await ready(mousePage);
      assert.equal(await count(mousePage), 0, "Loading mouse audio stays silent");
      for (const button of ["left", "right", "middle"]) {
        const beforeClick = await count(mousePage);
        await oneMouseClick(mousePage, "#hero-title", button);
        await expectGains(mousePage, beforeClick, [0.625], "Press-only Soft mouse clicks retain their original gain");
      }
      await oneMouseClick(mousePage, "#preview-button");
      const beforeVolume = await count(mousePage);
      await mousePage.locator("#volume").click();
      assert.equal(await count(mousePage), beforeVolume, "Volume clicks stay silent");
      await mousePage.locator("#volume").fill("0");
      for (const button of ["left", "right", "middle"])
        await mousePage.locator("#hero-title").click({ button });
      await mousePage.locator("#preview-button").click();
      await mousePage.locator('[data-code="Space"]').click();
      await mousePage.waitForTimeout(200);
      assert.equal(await count(mousePage), beforeVolume, "Muted clicks stay silent");
      await mousePage.locator("#volume").fill("40");
      await oneMouseClick(mousePage, "#hero-title");
      await mousePage.locator("#mouse-sound").selectOption("razer-orochi-v2");
      await mouseReady(mousePage);
      for (const button of ["left", "right", "middle"]) await recordedMouseStroke(mousePage, button);
      for (const width of [320, 1440]) {
        await mousePage.setViewportSize({ width, height: 1000 });
        await mousePage.locator(".mouse-controls").screenshot({ path: path.join(output, `${name}-mouse-${width}.png`) });
        assert.equal(await mousePage.evaluate(() => document.documentElement.scrollWidth), width,
          "Mouse sound controls fit the viewport");
      }
      await mouseContext.close();

      // Real pointer events must hit the visible keycaps throughout the 3D
      // keyboard, including its lower rows, before any keyboard activation.
      const pointerContext = await browser.newContext({
        viewport: { width: 1440, height: 1000 },
      });
      const pointerPage = await pointerContext.newPage();
      pointerPage.on("pageerror", (error) => errors.push(error.message));
      await instrument(pointerPage);
      await pointerPage.goto(site, { waitUntil: "networkidle" });
      await ready(pointerPage);
      await onePointerClick(pointerPage, "Space");
      const keyCodes = await pointerPage
        .locator(".keycap")
        .evaluateAll((keys) => keys.map((key) => key.dataset.code));
      for (const code of keyCodes) await onePointerClick(pointerPage, code);

      const key = pointerPage.locator('[data-code="KeyG"]');
      const bounds = await key.boundingBox();
      const center = {
        x: bounds.x + bounds.width / 2,
        y: bounds.y + bounds.height / 2,
      };
      const beforeDrag = await count(pointerPage);
      const beforeRotation = await pointerPage
        .locator("#keyboard-orbit")
        .evaluate((element) => getComputedStyle(element).transform);
      await pointerPage.mouse.move(center.x, center.y);
      await pointerPage.mouse.down();
      await pointerPage.mouse.move(center.x + 60, center.y + 30, { steps: 10 });
      await pointerPage.mouse.up();
      await pointerPage.waitForTimeout(200);
      assert.equal(await count(pointerPage), beforeDrag, "Dragging stays silent");
      assert.notEqual(
        await pointerPage
          .locator("#keyboard-orbit")
          .evaluate((element) => getComputedStyle(element).transform),
        beforeRotation,
      );
      await onePointerClick(pointerPage, "KeyG");
      await pointerPage.locator("#rotation-reset").click();
      await pointerPage.waitForTimeout(700);
      await pointerPage.screenshot({
        path: path.join(output, `${name}-pointer-1440.png`),
      });

      await pointerPage.setViewportSize({ width: 390, height: 1000 });
      for (const code of ["Escape", "KeyG", "ShiftLeft", "Space", "Fn"])
        await onePointerClick(pointerPage, code);
      await pointerPage.waitForTimeout(700);
      await pointerPage.screenshot({
        path: path.join(output, `${name}-pointer-390.png`),
      });
      assert.equal(errors.length, 0, errors.join("\n"));
      await pointerContext.close();

      const touchContext = await browser.newContext({
        viewport: { width: 390, height: 844 },
        hasTouch: true,
        isMobile: true,
      });
      const touchPage = await touchContext.newPage();
      await instrument(touchPage);
      await touchPage.goto(site, { waitUntil: "networkidle" });
      await ready(touchPage);
      await touchPage.locator("#hero-title").tap();
      await touchPage.waitForFunction(() => audioStarts.length === 1);
      await touchPage.waitForTimeout(150);
      assert.equal(await count(touchPage), 1, "Ordinary touch taps play once");
      await touchPage.locator('[data-code="Space"]').tap();
      await expectCount(touchPage, 1 + await strokeCount(touchPage), "Touch keycaps play one complete stroke");
      await touchContext.close();

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
      await slowPage.locator("#hero-title").click();
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
      await oneMouseClick(slowPage, "#hero-title");
      await slowContext.close();
      await checkReleaseFixtures(browser);
      await checkMouseReleaseFixtures(browser);
      reports.push({
        browser: name,
        profiles: profiles.length,
        pageWideDefault: true,
        noAutoplay: true,
        firstKeyWithoutClick: true,
        noRepeatedOrDoubleActivation: true,
        manifestDependentPhases: true,
        manifestCatalog: true,
        bundledSoundLicense: true,
        fixtureKeyCategories: true,
        fixturePhysicalReleases: true,
        fixturePreviewPairs: true,
        fixtureHeldProfileAndModifier: true,
        fixtureMuteAndReset: true,
        fixtureNoResumeGhosts: true,
        softerKeyboardReleases: true,
        softerModifierReleases: true,
        softerPreviewReleases: true,
        nativeTextAndSelection: true,
        volumeMute: true,
        resumesAfterBlur: true,
        visibleWhileScrolled: true,
        reducedMotion: true,
        noDelayedLoadingBurst: true,
        firstOrdinaryMouseClick: true,
        allMouseButtons: true,
        mouseVolumeMute: true,
        recordedMousePack: true,
        bundledMouseLicense: true,
        mouseButtonCategories: true,
        mousePhysicalReleases: true,
        mouseHeldPackPreserved: true,
        mouseMuteAndReset: true,
        mousePreviewPairs: true,
        mouseNoLoadingOrResumeGhosts: true,
        mouseLoadFailureFallback: true,
        softerMouseReleases: true,
        unchangedPressGains: true,
        releaseGainMultiplier: 0.7,
        firstPointerClick: true,
        pointerKeys: keyCodes.length,
        pointerWorksOnMobile: true,
        touchTapsPlayOnce: true,
        dragDoesNotPlaySound: true,
        errors,
      });
      console.log(`${name}: keyboard and pointer checks passed`);
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
