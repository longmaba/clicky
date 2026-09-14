(() => {
  "use strict";

  const config = window.CLICKY_CONFIG || {};
  const repository =
    config.repositoryUrl || "https://github.com/longmaba/clicky";
  const profiles = [
    {
      id: "thocky",
      name: "Thocky",
      subtitle: "Warm, rounded knocks",
      color: "#C68B54",
    },
    {
      id: "marbly",
      name: "Marbly",
      subtitle: "Smooth, glassy resonance",
      color: "#AD9ACE",
    },
    {
      id: "silent",
      name: "Silent",
      subtitle: "A soft, quiet touch",
      color: "#94A7AD",
    },
    {
      id: "poppy",
      name: "Poppy",
      subtitle: "Bright little pops",
      color: "#E8A05B",
    },
    {
      id: "clicky",
      name: "Clicky",
      subtitle: "Crisp, tactile clicks",
      color: "#D3BB6F",
    },
    {
      id: "bubble-wrap",
      name: "Bubble Wrap",
      subtitle: "Playful, hollow pops",
      color: "#C493B5",
    },
    {
      id: "clacky",
      name: "Clacky",
      subtitle: "Sharp, lively taps",
      color: "#DA8276",
    },
    {
      id: "creamy",
      name: "Creamy",
      subtitle: "Soft, buttery texture",
      color: "#DCCCA0",
    },
    {
      id: "deep-thock",
      name: "Deep Thock",
      subtitle: "Low, resonant knocks",
      color: "#82A799",
    },
    {
      id: "office",
      name: "Office",
      subtitle: "Familiar everyday typing",
      color: "#7FA1C3",
    },
  ];
  const $ = (selector) => document.querySelector(selector);
  const $$ = (selector) => [...document.querySelectorAll(selector)];
  const status = $("#audio-status");
  const preview = $("#preview-button");
  const typingField = $("#typing-field");
  const keyboard = $("#keyboard");
  const orbit = $("#keyboard-orbit");
  const workbench = $(".sound-workbench");
  let activeProfile = profiles[0];
  let context;
  let gain;
  let playbackSession = 0;
  let pendingKeyAttempt = 0;
  let feedbackTimer;
  let sampleNumber = 0;
  let pulseTimer;
  let lastAudioAttempt = 0;
  const buffers = new Map();
  const decodedBuffers = new Map();
  const activeVoices = new Set();
  const pressedTimers = new Map();

  $$("[data-repository]").forEach((link) => {
    link.href = repository;
  });
  $$("[data-license]").forEach((link) => {
    link.href = `${repository}/blob/main/LICENSE`;
  });
  $$("[data-version]").forEach((label) => {
    label.textContent = `v${config.version || "0.1.4"}`;
  });
  $$(".download-link").forEach((link) => {
    link.href = config.downloadUrl || `${repository}#build-and-open`;
    link.querySelector("[data-download-label]").textContent = config.downloadUrl
      ? "Download for Mac"
      : "Build for Mac";
  });
  if (config.downloadUrl)
    $(".platform-line:not(.planned) span:last-child").textContent =
      "Available for Mac";
  $$("[data-attribution]").forEach((link) => {
    link.href = `${repository}/blob/main/THIRD_PARTY_NOTICES.md`;
  });

  const donateDialog = $("#donate-dialog");
  let donateTrigger;
  $$("[data-donate]").forEach((button) => {
    button.addEventListener("click", () => {
      if (config.donateUrl && config.donationsEnabled) {
        window.location.assign(config.donateUrl);
        return;
      }
      donateTrigger = button;
      donateDialog.showModal();
      $("#dialog-close").focus();
    });
  });
  $("#dialog-close").addEventListener("click", () => donateDialog.close());
  donateDialog.addEventListener("click", (event) => {
    const bounds = donateDialog.getBoundingClientRect();
    if (
      event.target === donateDialog &&
      (event.clientX < bounds.left ||
        event.clientX > bounds.right ||
        event.clientY < bounds.top ||
        event.clientY > bounds.bottom)
    )
      donateDialog.close();
  });
  donateDialog.addEventListener("close", () => donateTrigger?.focus());

  profiles.forEach((profile, index) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "profile-button";
    button.dataset.profile = profile.id;
    button.setAttribute("aria-pressed", String(index === 0));
    const swatch = document.createElement("span");
    swatch.className = "profile-swatch";
    swatch.style.background = profile.color;
    swatch.setAttribute("aria-hidden", "true");
    const label = document.createElement("span");
    label.textContent = profile.name;
    const check = document.createElement("span");
    check.className = "profile-check";
    check.setAttribute("aria-hidden", "true");
    check.textContent = index === 0 ? "✓" : "";
    button.append(swatch, label, check);
    button.addEventListener("click", () => selectProfile(profile, index));
    $("#profile-list").append(button);
  });

  async function selectProfile(profile, index) {
    activeProfile = profile;
    playbackSession++;
    lastAudioAttempt++;
    sampleNumber = 0;
    document.documentElement.style.setProperty("--accent", profile.color);
    $$(".active-profile-name").forEach((label) => {
      label.textContent = profile.name;
    });
    $("#profile-subtitle").textContent = profile.subtitle;
    $("#profile-number").textContent = String(index + 1).padStart(2, "0");
    preview.setAttribute("aria-label", `Preview ${profile.name} sound`);
    $$(".profile-button").forEach((button) => {
      const selected = button.dataset.profile === profile.id;
      button.setAttribute("aria-pressed", String(selected));
      button.querySelector(".profile-check").textContent = selected ? "✓" : "";
    });
    await prepareProfile(profile);
  }

  // Decode silently ahead of typing. Only a user gesture resumes playback;
  // creating the context and loading WAVs never starts a source.
  async function audioContext(resume = true) {
    if (!context) {
      const AudioContextClass =
        window.AudioContext || window.webkitAudioContext;
      if (!AudioContextClass) throw new Error("unsupported");
      context = new AudioContextClass({ latencyHint: "interactive" });
      gain = context.createGain();
      gain.gain.value = Number($("#volume").value) / 100;
      const limiter = context.createDynamicsCompressor();
      limiter.threshold.value = -3;
      limiter.knee.value = 3;
      limiter.ratio.value = 12;
      limiter.attack.value = 0.001;
      limiter.release.value = 0.06;
      gain.connect(limiter);
      limiter.connect(context.destination);
    }
    if (resume && context.state !== "running") await context.resume();
    return context;
  }

  async function loadSample(profile, number = 1) {
    const key = `${profile.id}/${number}`;
    if (!buffers.has(key)) {
      const pending = (async () => {
        const audio = await audioContext(false);
        const response = await fetch(
          `./sounds/${profile.id}/${String(number).padStart(2, "0")}.wav`,
          { cache: "force-cache" },
        );
        if (!response.ok) throw new Error("missing-sample");
        const buffer = await audio.decodeAudioData(
          await response.arrayBuffer(),
        );
        decodedBuffers.set(key, buffer);
        return buffer;
      })();
      buffers.set(key, pending);
      pending.catch(() => buffers.delete(key));
    }
    return buffers.get(key);
  }

  function audioError(error) {
    status.textContent =
      error.message === "unsupported"
        ? "Your browser does not support this audio playground. You can still explore Clicky on GitHub."
        : "Audio previews are unavailable in this copy of the site. The Mac app includes all ten profiles.";
  }

  function playBuffer(buffer, modifier = false) {
    if (!context || context.state !== "running" || document.hidden) return;
    if (activeVoices.size >= 24) {
      const oldest = activeVoices.values().next().value;
      activeVoices.delete(oldest);
      oldest.stop();
    }
    const source = context.createBufferSource();
    source.buffer = buffer;
    // Mirrors Soft modifiers in the native app; no delayed chord detection.
    const voiceGain = context.createGain();
    // Match the native app's +6.02 dB keyboard calibration while retaining
    // each recording's relative level, including the quieter Silent profile.
    voiceGain.gain.value = 2 * (modifier ? 0.25 : 1);
    source.connect(voiceGain);
    voiceGain.connect(gain);
    source.onended = () => {
      activeVoices.delete(source);
      source.disconnect();
      voiceGain.disconnect();
    };
    activeVoices.add(source);
    source.start();
  }

  function pulse() {
    clearTimeout(pulseTimer);
    workbench.classList.remove("is-playing");
    void workbench.offsetWidth;
    workbench.classList.add("is-playing");
    pulseTimer = setTimeout(
      () => workbench.classList.remove("is-playing"),
      220,
    );
  }

  async function playSample(profile = activeProfile, modifier = false) {
    const attempt = ++lastAudioAttempt;
    const session = playbackSession;
    if (Number($("#volume").value) === 0) {
      status.textContent = "Sound is muted. Raise Volume to hear your keys.";
      return;
    }
    try {
      const audio = await audioContext();
      const buffer = await loadSample(profile, 1);
      // A slow initial fetch should never release a burst of queued keystrokes.
      if (
        attempt !== lastAudioAttempt ||
        session !== playbackSession ||
        document.hidden ||
        profile !== activeProfile ||
        audio.state !== "running"
      )
        return;
      playBuffer(buffer, modifier);
      status.textContent = `${profile.name} · ${profile.subtitle.toLowerCase()}. Type anywhere on this page.`;
    } catch (error) {
      audioError(error);
    }
  }

  preview.addEventListener("click", async () => {
    preview.disabled = true;
    status.textContent = `Loading ${activeProfile.name}…`;
    animateKey("KeyA");
    try {
      await playSample();
    } finally {
      preview.disabled = false;
    }
  });

  $("#volume").addEventListener("input", (event) => {
    const value = Number(event.target.value);
    if (value === 0) {
      playbackSession++;
      lastAudioAttempt++;
    }
    updateTypingStatus();
    status.textContent =
      value === 0
        ? "Sound is muted. Key effects stay on."
        : "Type anywhere on this page. Set Volume to 0 to mute.";
    $("#volume-value").textContent = `${value}%`;
    event.target.style.background = `linear-gradient(to right,var(--ink) 0%,var(--ink) ${value}%,#cfc7b8 ${value}%,#cfc7b8 100%)`;
    if (gain && context)
      gain.gain.setTargetAtTime(value / 100, context.currentTime, 0.015);
  });

  function updateTypingStatus() {
    const muted = Number($("#volume").value) === 0;
    $("#typing-light").textContent = muted ? "MUTED" : "ON";
    $("#typing-light").classList.toggle("active", !muted);
  }

  async function prepareProfile(profile = activeProfile) {
    status.textContent = `Preparing ${profile.name}… Key effects are already on.`;
    try {
      await Promise.all(
        Array.from({ length: 6 }, (_, index) => loadSample(profile, index + 1)),
      );
      if (profile !== activeProfile) return;
      updateTypingStatus();
      status.textContent =
        "Type anywhere on this page. Set Volume to 0 to mute. If Clicky is running, mute the app while trying the demo.";
    } catch (error) {
      if (profile === activeProfile) audioError(error);
    }
  }

  function playTypingStroke(code) {
    lastAudioAttempt++;
    if (Number($("#volume").value) === 0) return;
    const profile = activeProfile;
    const number = (sampleNumber++ % 6) + 1;
    const buffer =
      decodedBuffers.get(`${profile.id}/${number}`) ||
      decodedBuffers.get(`${profile.id}/1`);
    const session = playbackSession;
    const attempt = ++pendingKeyAttempt;
    const started = performance.now();
    const modifier = /^(Shift|Control|Alt|Meta|Fn)/.test(code);
    // Resume in the physical event handler, including the first key on the page.
    // Never queue keystrokes behind downloads or an autoplay permission prompt.
    const resumed = audioContext();
    if (context?.state === "running" && buffer) {
      playBuffer(buffer, modifier);
      return;
    }
    resumed
      .then(() => {
        if (
          !buffer ||
          attempt !== pendingKeyAttempt ||
          session !== playbackSession ||
          profile !== activeProfile ||
          document.hidden ||
          !document.hasFocus() ||
          performance.now() - started > 120
        )
          return;
        playBuffer(buffer, modifier);
      })
      .catch(audioError);
  }

  function delegatesAudioActivation(event) {
    return (
      ["Enter", "NumpadEnter", "Space"].includes(event.code) &&
      !event.altKey &&
      !event.ctrlKey &&
      !event.metaKey &&
      event.target instanceof Element &&
      event.target.matches("#preview-button, .keycap")
    );
  }

  document.addEventListener(
    "keydown",
    (event) => {
      if (!event.isTrusted || document.hidden) return;
      // Audio preview buttons already own their native Enter/Space activation.
      // Keep that activation to one stroke, including when Enter is held down.
      if (delegatesAudioActivation(event)) {
        if (event.repeat) event.preventDefault();
        return;
      }
      if (event.repeat || !event.code || event.code === "Unidentified") return;
      animateKey(event.code);
      playTypingStroke(event.code);
      // No preventDefault, value inspection, input/change listeners, or text history.
      // Browser shortcuts, selection, composition, and form controls stay native.
    },
    true,
  );
  document.addEventListener("keyup", (event) => releaseKey(event.code), true);

  const rows = [
    [
      ["esc", "Escape", 1, "warm"],
      ["1", "Digit1"],
      ["2", "Digit2"],
      ["3", "Digit3"],
      ["4", "Digit4"],
      ["5", "Digit5"],
      ["6", "Digit6"],
      ["7", "Digit7"],
      ["8", "Digit8"],
      ["9", "Digit9"],
      ["0", "Digit0"],
      ["−", "Minus"],
      ["=", "Equal"],
      ["delete", "Backspace", 1.8],
    ],
    [
      ["tab", "Tab", 1.45],
      ["Q", "KeyQ"],
      ["W", "KeyW"],
      ["E", "KeyE"],
      ["R", "KeyR"],
      ["T", "KeyT"],
      ["Y", "KeyY"],
      ["U", "KeyU"],
      ["I", "KeyI"],
      ["O", "KeyO"],
      ["P", "KeyP"],
      ["[", "BracketLeft"],
      ["]", "BracketRight"],
      ["\\", "Backslash", 1.35],
    ],
    [
      ["caps", "CapsLock", 1.7],
      ["A", "KeyA"],
      ["S", "KeyS"],
      ["D", "KeyD"],
      ["F", "KeyF"],
      ["G", "KeyG"],
      ["H", "KeyH"],
      ["J", "KeyJ"],
      ["K", "KeyK"],
      ["L", "KeyL"],
      [";", "Semicolon"],
      ["'", "Quote"],
      ["return", "Enter", 2.1, "warm"],
    ],
    [
      ["shift", "ShiftLeft", 2.15],
      ["Z", "KeyZ"],
      ["X", "KeyX"],
      ["C", "KeyC"],
      ["V", "KeyV"],
      ["B", "KeyB"],
      ["N", "KeyN"],
      ["M", "KeyM"],
      [",", "Comma"],
      [".", "Period"],
      ["/", "Slash"],
      ["shift", "ShiftRight", 2.65],
    ],
    [
      ["fn", "Fn", 1.15],
      ["control", "ControlLeft", 1.2],
      ["option", "AltLeft", 1.2],
      ["⌘", "MetaLeft", 1.3],
      ["", "Space", 6.45, "dark"],
      ["⌘", "MetaRight", 1.3],
      ["option", "AltRight", 1.2],
      ["←", "ArrowLeft", 1],
      ["↑", "ArrowUp", 1],
      ["→", "ArrowRight", 1],
    ],
  ];
  const keyMap = new Map();
  const keyButtons = [];
  rows.forEach((row, rowIndex) => {
    const rowElement = document.createElement("div");
    rowElement.className = "keyboard-row";
    row.forEach(([label, code, size = 1, tone = ""], columnIndex) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `keycap${size > 1.3 || label.length > 3 ? " key-wide" : ""}${tone ? ` key-${tone}` : ""}`;
      button.style.setProperty("--key-size", size);
      button.textContent = label;
      button.dataset.code = code;
      button.dataset.row = String(rowIndex);
      button.dataset.column = String(columnIndex);
      button.tabIndex = keyButtons.length === 0 ? 0 : -1;
      button.setAttribute(
        "aria-label",
        `${code === "Space" ? "Space" : code.startsWith("Meta") ? "Command" : label}, preview sound`,
      );
      button.addEventListener("click", (event) => {
        // Pointer interactions are resolved after drag detection; keyboard activation remains native.
        if (event.detail === 0) {
          animateKey(code);
          playSample(activeProfile, /^(Shift|Control|Alt|Meta|Fn)/.test(code));
        }
      });
      button.addEventListener("keydown", (event) => {
        if (
          ![
            "ArrowLeft",
            "ArrowRight",
            "ArrowUp",
            "ArrowDown",
            "Home",
            "End",
          ].includes(event.key)
        )
          return;
        event.preventDefault();
        let target;
        if (event.key === "ArrowLeft")
          target = keyButtons[Math.max(0, keyButtons.indexOf(button) - 1)];
        if (event.key === "ArrowRight")
          target =
            keyButtons[
              Math.min(keyButtons.length - 1, keyButtons.indexOf(button) + 1)
            ];
        if (event.key === "Home") target = keyButtons[0];
        if (event.key === "End") target = keyButtons[keyButtons.length - 1];
        if (event.key === "ArrowUp" || event.key === "ArrowDown") {
          const targetRow = Math.max(
            0,
            Math.min(
              rows.length - 1,
              rowIndex + (event.key === "ArrowDown" ? 1 : -1),
            ),
          );
          const targetCode =
            rows[targetRow][
              Math.min(columnIndex, rows[targetRow].length - 1)
            ][1];
          target = keyMap.get(targetCode);
        }
        if (target) {
          button.tabIndex = -1;
          target.tabIndex = 0;
          target.focus();
        }
      });
      keyMap.set(code, button);
      keyButtons.push(button);
      rowElement.append(button);
    });
    keyboard.append(rowElement);
  });

  function animateKey(code) {
    const label =
      keyMap.get(code)?.textContent ||
      {
        Space: "space",
        ArrowDown: "↓",
        Backquote: "`",
        CapsLock: "caps",
      }[code] ||
      code.replace(/^(Key|Digit|Numpad)/, "").replace(/(Left|Right)$/, "");
    $("#keystroke-label").textContent = label || "space";
    $("#keystroke-feedback").classList.remove("is-visible");
    void $("#keystroke-feedback").offsetWidth;
    $("#keystroke-feedback").classList.add("is-visible");
    clearTimeout(feedbackTimer);
    feedbackTimer = setTimeout(() => {
      $("#keystroke-feedback").classList.remove("is-visible");
      $("#keystroke-label").textContent = "";
    }, 650);
    pulse();
    const button = keyMap.get(code);
    if (!button) return;
    clearTimeout(pressedTimers.get(code));
    button.classList.add("is-pressed");
    pressedTimers.set(
      code,
      setTimeout(() => releaseKey(code), 160),
    );
  }
  function releaseKey(code) {
    clearTimeout(pressedTimers.get(code));
    pressedTimers.delete(code);
    keyMap.get(code)?.classList.remove("is-pressed");
  }
  function clearKeys() {
    keyMap.forEach((_, code) => releaseKey(code));
  }

  let rotation = { x: 28, y: -4, z: -7 };
  let drag;
  function applyRotation() {
    orbit.style.transform = `translate(-50%, -50%) rotateX(${rotation.x}deg) rotateY(${rotation.y}deg) rotateZ(${rotation.z}deg) scale(var(--keyboard-scale))`;
  }
  keyboard.addEventListener("pointerdown", (event) => {
    if (event.button !== 0 || !event.isPrimary) return;
    event.preventDefault();
    drag = {
      pointer: event.pointerId,
      x: event.clientX,
      y: event.clientY,
      initial: { ...rotation },
      moved: false,
      key: event.target.closest(".keycap"),
    };
    keyboard.setPointerCapture(event.pointerId);
    if (drag.key) drag.key.classList.add("is-pressed");
  });
  keyboard.addEventListener("pointermove", (event) => {
    if (!drag || drag.pointer !== event.pointerId) return;
    const dx = event.clientX - drag.x;
    const dy = event.clientY - drag.y;
    if (!drag.moved && Math.hypot(dx, dy) < 5) return;
    drag.moved = true;
    drag.key?.classList.remove("is-pressed");
    orbit.classList.add("dragging");
    keyboard.style.cursor = "grabbing";
    rotation = {
      x: Math.max(5, Math.min(56, drag.initial.x - dy * 0.22)),
      y: Math.max(-28, Math.min(28, drag.initial.y + dx * 0.2)),
      z: drag.initial.z,
    };
    applyRotation();
  });
  function finishDrag(event, cancelled = false) {
    if (!drag || event.pointerId !== drag.pointer) return;
    if (!cancelled && !drag.moved && drag.key) {
      const code = drag.key.dataset.code;
      animateKey(code);
      playSample(activeProfile, /^(Shift|Control|Alt|Meta|Fn)/.test(code));
    } else drag.key?.classList.remove("is-pressed");
    if (keyboard.hasPointerCapture(event.pointerId))
      keyboard.releasePointerCapture(event.pointerId);
    drag = null;
    orbit.classList.remove("dragging");
    keyboard.style.cursor = "";
  }
  keyboard.addEventListener("pointerup", (event) => finishDrag(event));
  keyboard.addEventListener("pointercancel", (event) =>
    finishDrag(event, true),
  );
  keyboard.addEventListener("lostpointercapture", (event) => {
    if (drag) finishDrag(event, true);
  });
  $("#rotation-reset").addEventListener("click", () => {
    rotation = { x: 28, y: -4, z: -7 };
    applyRotation();
  });

  function pausePage() {
    playbackSession++;
    pendingKeyAttempt++;
    lastAudioAttempt++;
    typingField.value = "";
    clearKeys();
    clearTimeout(pulseTimer);
    workbench.classList.remove("is-playing");
    clearTimeout(feedbackTimer);
    $("#keystroke-feedback").classList.remove("is-visible");
    $("#keystroke-label").textContent = "";
    activeVoices.forEach((voice) => {
      try {
        voice.stop();
      } catch (_) {}
    });
    activeVoices.clear();
    context?.suspend().catch(() => {});
  }

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) pausePage();
  });
  window.addEventListener("blur", pausePage);
  window.addEventListener("pagehide", pausePage);
  prepareProfile();
})();
