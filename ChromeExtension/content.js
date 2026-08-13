(async () => {
  const [
    { mapTextRange },
    { resolveSpeechBoundary },
    {
      captureSafeFormSelection,
      isSensitiveSelectionControl,
      rangeTouchesSensitiveControl
    }
  ] = await Promise.all([
    import(chrome.runtime.getURL("shared/range-map.js")),
    import(chrome.runtime.getURL("shared/tokenizer.js")),
    import(chrome.runtime.getURL("shared/selection-security.js"))
  ]);

  const HIGHLIGHT_NAME = "optionvoice-current-token";
  const ROOT_ID = "optionvoice-extension-root";
  const captures = new Map();
  let session = null;
  let shadowRoot = null;
  let rootHost = null;
  let currentRange = null;
  let previousPageHighlight;
  let ownsHighlight = false;
  let locationSnapshot = location.href;
  let scheduledPosition = 0;
  let scheduledValidation = 0;
  let sessionObserver = null;

  const send = (message) => chrome.runtime.sendMessage(message).catch(() => null);

  function textNodesForRange(range) {
    const nodes = [];
    const root = range.commonAncestorContainer;
    if (root.nodeType === Node.TEXT_NODE) {
      return [root];
    }

    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      try {
        if (range.intersectsNode(node)) {
          nodes.push(node);
        }
      } catch {
        // A page mutation can detach a node between TreeWalker steps.
      }
    }
    return nodes;
  }

  function captureDocumentSelection(selectionId) {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
      return null;
    }

    const sourceRange = selection.getRangeAt(0).cloneRange();
    if (rangeTouchesSensitiveControl(sourceRange)) {
      return null;
    }
    const nodes = textNodesForRange(sourceRange);
    const segments = [];

    for (const node of nodes) {
      let nodeStart = node === sourceRange.startContainer ? sourceRange.startOffset : 0;
      let nodeEnd = node === sourceRange.endContainer ? sourceRange.endOffset : node.data.length;
      nodeStart = Math.max(0, Math.min(node.data.length, nodeStart));
      nodeEnd = Math.max(nodeStart, Math.min(node.data.length, nodeEnd));
      if (nodeEnd === nodeStart) {
        continue;
      }

      const part = node.data.slice(nodeStart, nodeEnd);
      segments.push({
        node,
        nodeStart,
        nodeEnd,
        originalText: part
      });
    }

    const renderedText = selection.rangeCount === 1 ? selection.toString() : "";
    let searchOffset = 0;
    let alignedWithRenderedText = Boolean(renderedText);
    for (const segment of segments) {
      const index = renderedText.indexOf(segment.originalText, searchOffset);
      if (index < 0 || renderedText.slice(searchOffset, index).trim()) {
        alignedWithRenderedText = false;
        break;
      }
      segment.textStart = index;
      segment.textEnd = index + segment.originalText.length;
      searchOffset = segment.textEnd;
    }

    if (!alignedWithRenderedText || renderedText.slice(searchOffset).trim()) {
      return null;
    }
    const text = renderedText;
    if (!text.trim() || segments.length === 0) {
      return null;
    }

    const capture = {
      selectionId,
      text,
      segments,
      locale: document.documentElement.lang || navigator.language || ""
    };
    captures.clear();
    captures.set(selectionId, capture);
    return capture;
  }

  function captureFormSelection(selectionId) {
    const element = document.activeElement;
    const capture = captureSafeFormSelection(
      element,
      selectionId,
      element?.lang || document.documentElement.lang || navigator.language || ""
    );
    if (!capture) {
      return null;
    }
    captures.clear();
    captures.set(selectionId, capture);
    return capture;
  }

  function captureSelection(selectionId) {
    if (isSensitiveSelectionControl(document.activeElement)) {
      return null;
    }
    return captureDocumentSelection(selectionId) || captureFormSelection(selectionId);
  }

  function ensureUI() {
    if (rootHost?.isConnected && shadowRoot) {
      return shadowRoot;
    }

    rootHost = document.createElement("div");
    rootHost.id = ROOT_ID;
    rootHost.setAttribute("data-optionvoice-owned", "");
    rootHost.style.cssText = "all:initial!important;display:block!important;position:static!important";
    shadowRoot = rootHost.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent = `
        :host { color-scheme: light dark; }
        .transport {
          align-items: center;
          backdrop-filter: blur(18px) saturate(1.2);
          background: color-mix(in srgb, Canvas 88%, transparent);
          border: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
          border-radius: 14px;
          bottom: max(18px, env(safe-area-inset-bottom));
          box-shadow: 0 10px 34px rgb(0 0 0 / 20%);
          color: CanvasText;
          display: flex;
          font: 500 13px/1.2 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          gap: 4px;
          left: 50%;
          max-width: calc(100vw - 28px);
          padding: 6px;
          position: fixed;
          transform: translateX(-50%);
          z-index: 2147483647;
        }
        button {
          align-items: center;
          appearance: none;
          background: transparent;
          border: 0;
          border-radius: 9px;
          color: inherit;
          cursor: pointer;
          display: inline-flex;
          font: inherit;
          height: 34px;
          justify-content: center;
          min-width: 34px;
          padding: 0 8px;
        }
        button:hover { background: color-mix(in srgb, CanvasText 9%, transparent); }
        button:focus-visible { outline: 2px solid Highlight; outline-offset: 1px; }
        .play { background: CanvasText; color: Canvas; font-size: 15px; }
        .play:hover { background: color-mix(in srgb, CanvasText 86%, Canvas); }
        .stop { font-size: 12px; }
        .label {
          min-width: 70px;
          overflow: hidden;
          padding: 0 7px;
          text-overflow: ellipsis;
          white-space: nowrap;
        }
        .progress {
          color: color-mix(in srgb, CanvasText 62%, transparent);
          font-variant-numeric: tabular-nums;
          min-width: 34px;
          text-align: right;
        }
        .caret {
          background: #3275e8;
          border-radius: 2px;
          box-shadow: 0 0 0 1px rgb(255 255 255 / 60%);
          display: none;
          left: 0;
          pointer-events: none;
          position: fixed;
          top: 0;
          width: 3px;
          z-index: 2147483646;
        }
        .overlays {
          inset: 0;
          pointer-events: none;
          position: fixed;
          z-index: 2147483645;
        }
        .overlay {
          background: rgb(76 141 237 / 38%);
          border-bottom: 2px solid #2168d5;
          border-radius: 3px;
          position: fixed;
        }
        @media (prefers-color-scheme: dark) {
          .caret { background: #78aaff; box-shadow: 0 0 0 1px rgb(0 0 0 / 55%); }
          .overlay { background: rgb(82 143 238 / 34%); border-color: #78aaff; }
        }
        @media (prefers-reduced-motion: reduce) {
          *, *::before, *::after { scroll-behavior: auto !important; transition: none !important; }
        }
    `;

    const createElement = (tag, {
      className,
      text,
      attributes = {},
      data = {}
    } = {}) => {
      const element = document.createElement(tag);
      if (className) {
        element.className = className;
      }
      if (text !== undefined) {
        element.textContent = text;
      }
      for (const [name, value] of Object.entries(attributes)) {
        element.setAttribute(name, value);
      }
      for (const [name, value] of Object.entries(data)) {
        element.dataset[name] = value;
      }
      return element;
    };

    const overlays = createElement("div", {
      className: "overlays",
      attributes: { "aria-hidden": "true" }
    });
    const caret = createElement("div", {
      className: "caret",
      attributes: { "aria-hidden": "true" }
    });
    const transport = createElement("div", {
      className: "transport",
      attributes: { role: "toolbar", "aria-label": "Управление чтением" }
    });
    const back = createElement("button", {
      text: "−10",
      attributes: {
        type: "button",
        "aria-label": "Назад на 10 слов",
        title: "Назад на 10 слов"
      },
      data: { action: "skip", amount: "-10" }
    });
    const play = createElement("button", {
      className: "play",
      text: "Ⅱ",
      attributes: { type: "button", "aria-label": "Пауза", title: "Пауза" },
      data: { action: "toggle" }
    });
    const forward = createElement("button", {
      text: "+10",
      attributes: {
        type: "button",
        "aria-label": "Вперёд на 10 слов",
        title: "Вперёд на 10 слов"
      },
      data: { action: "skip", amount: "10" }
    });
    const label = createElement("span", {
      className: "label",
      text: "Подготовка…",
      attributes: { role: "status", "aria-live": "polite" }
    });
    const progress = createElement("span", {
      className: "progress",
      text: "0%",
      attributes: { "aria-label": "Прогресс чтения" }
    });
    const stop = createElement("button", {
      className: "stop",
      text: "■",
      attributes: { type: "button", "aria-label": "Остановить чтение", title: "Остановить" },
      data: { action: "stop" }
    });
    transport.append(back, play, forward, label, progress, stop);
    shadowRoot.append(style, overlays, caret, transport);
    shadowRoot.addEventListener("click", (event) => {
      const button = event.target.closest("button[data-action]");
      if (!button || !session) {
        return;
      }
      const action = button.dataset.action;
      if (action === "toggle") {
        void send({
          type: "VR_CONTROL",
          action: session.playback === "paused" ? "resume" : "pause"
        });
      } else if (action === "skip") {
        void send({
          type: "VR_CONTROL",
          action: "skip",
          amount: Number(button.dataset.amount)
        });
      } else if (action === "stop") {
        void send({ type: "VR_CONTROL", action: "stop" });
      }
    });
    document.documentElement.append(rootHost);
    return shadowRoot;
  }

  function updateUI() {
    if (!session) {
      return;
    }
    const root = ensureUI();
    const toggle = root.querySelector('[data-action="toggle"]');
    const label = root.querySelector(".label");
    const progress = root.querySelector(".progress");
    const paused = session.playback === "paused";
    toggle.textContent = paused ? "▶" : "Ⅱ";
    toggle.setAttribute("aria-label", paused ? "Продолжить" : "Пауза");
    toggle.title = paused ? "Продолжить" : "Пауза";
    label.textContent = {
      buffering: "Подготовка…",
      paused: "Пауза",
      speaking: "Чтение"
    }[session.playback] || "Чтение";
    const percent = session.text.length
      ? Math.min(100, Math.round((session.offset / session.text.length) * 100))
      : 0;
    progress.textContent = `${percent}%`;
  }

  function clearVisuals() {
    if (globalThis.CSS?.highlights && ownsHighlight) {
      if (previousPageHighlight) {
        CSS.highlights.set(HIGHLIGHT_NAME, previousPageHighlight);
      } else {
        CSS.highlights.delete(HIGHLIGHT_NAME);
      }
      previousPageHighlight = undefined;
      ownsHighlight = false;
    }
    shadowRoot?.querySelector(".overlays")?.replaceChildren();
    const caret = shadowRoot?.querySelector(".caret");
    if (caret) {
      caret.style.display = "none";
    }
    currentRange = null;
  }

  function removeUI() {
    clearVisuals();
    rootHost?.remove();
    rootHost = null;
    shadowRoot = null;
  }

  function restorePage() {
    removeEventListener("scroll", scheduleReposition, true);
    removeEventListener("resize", scheduleReposition);
    if (scheduledPosition) {
      cancelAnimationFrame(scheduledPosition);
      scheduledPosition = 0;
    }
    if (scheduledValidation) {
      cancelAnimationFrame(scheduledValidation);
      scheduledValidation = 0;
    }
    sessionObserver?.disconnect();
    sessionObserver = null;
    clearVisuals();
    removeUI();
    captures.clear();
    session = null;
  }

  function createDomRange(capture, mapped) {
    const startSegment = capture.segments[mapped.start.segmentIndex];
    const endSegment = capture.segments[mapped.end.segmentIndex];
    if (!startSegment?.node.isConnected || !endSegment?.node.isConnected) {
      return null;
    }
    const range = document.createRange();
    range.setStart(startSegment.node, mapped.start.nodeOffset);
    range.setEnd(endSegment.node, mapped.end.nodeOffset);
    return range;
  }

  function paintFallback(range) {
    const root = ensureUI();
    const overlays = root.querySelector(".overlays");
    overlays.replaceChildren();
    for (const rect of range.getClientRects()) {
      if (!rect.width || !rect.height) {
        continue;
      }
      const overlay = document.createElement("span");
      overlay.className = "overlay";
      overlay.style.left = `${rect.left}px`;
      overlay.style.top = `${rect.top}px`;
      overlay.style.width = `${rect.width}px`;
      overlay.style.height = `${rect.height}px`;
      overlays.append(overlay);
    }
  }

  function positionVisuals() {
    scheduledPosition = 0;
    if (!currentRange || !session) {
      return;
    }
    const rect = currentRange.getBoundingClientRect();
    if (!rect.width && !rect.height) {
      return;
    }
    const caret = ensureUI().querySelector(".caret");
    caret.style.display = "block";
    caret.style.left = `${Math.max(0, rect.left - 2)}px`;
    caret.style.top = `${rect.top}px`;
    caret.style.height = `${Math.max(12, rect.height)}px`;
    if (!globalThis.CSS?.highlights) {
      paintFallback(currentRange);
    }
  }

  function scheduleReposition() {
    if (!scheduledPosition) {
      scheduledPosition = requestAnimationFrame(positionVisuals);
    }
  }

  function nearestScrollContainer(node) {
    let element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
    while (element && element !== document.documentElement) {
      const style = getComputedStyle(element);
      const scrollable = /(auto|scroll|overlay)/.test(style.overflowY)
        && element.scrollHeight > element.clientHeight + 1;
      if (scrollable) {
        return element;
      }
      element = element.parentElement;
    }
    return null;
  }

  function revealRange(range) {
    const rect = range.getBoundingClientRect();
    const margin = Math.min(120, innerHeight * 0.2);
    if (rect.top >= margin && rect.bottom <= innerHeight - margin) {
      return;
    }
    const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
    const behavior = reducedMotion ? "auto" : "smooth";
    const scrollContainer = nearestScrollContainer(range.startContainer);
    if (scrollContainer) {
      const containerRect = scrollContainer.getBoundingClientRect();
      scrollContainer.scrollBy({
        top: rect.top - containerRect.top - scrollContainer.clientHeight * 0.42,
        left: 0,
        behavior
      });
      if (containerRect.bottom < margin || containerRect.top > innerHeight - margin) {
        scrollContainer.scrollIntoView({
          block: "center",
          inline: "nearest",
          behavior
        });
      }
    } else {
      scrollBy({
        top: rect.top - innerHeight * 0.42,
        left: 0,
        behavior
      });
    }
    setTimeout(scheduleReposition, reducedMotion ? 0 : 320);
  }

  function showBoundary(offset, length) {
    if (!session) {
      return;
    }
    const resolved = resolveSpeechBoundary(session.text, offset, length, session.capture.locale);
    if (resolved.end <= resolved.start || session.capture.segments.length === 0) {
      session.offset = resolved.start;
      updateUI();
      return;
    }
    const mapped = mapTextRange(
      session.capture.segments.map(({ textStart, textEnd, nodeStart, nodeEnd }) => ({
        textStart,
        textEnd,
        nodeStart,
        nodeEnd
      })),
      resolved.start,
      resolved.end - resolved.start,
      session.text.length
    );
    if (!mapped) {
      return;
    }

    let range;
    try {
      range = createDomRange(session.capture, mapped);
    } catch {
      const failedSessionId = session.sessionId;
      restorePage();
      void send({
        type: "VR_PAGE_NAVIGATED",
        sessionId: failedSessionId
      });
      return;
    }
    if (!range) {
      const failedSessionId = session.sessionId;
      restorePage();
      void send({
        type: "VR_PAGE_NAVIGATED",
        sessionId: failedSessionId
      });
      return;
    }

    clearVisuals();
    currentRange = range;
    if (globalThis.CSS?.highlights && typeof Highlight === "function") {
      if (!ownsHighlight) {
        previousPageHighlight = CSS.highlights.get(HIGHLIGHT_NAME);
        ownsHighlight = true;
      }
      CSS.highlights.set(HIGHLIGHT_NAME, new Highlight(range));
    } else {
      paintFallback(range);
    }
    session.offset = resolved.start;
    positionVisuals();
    updateUI();
    revealRange(range);
  }

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!message || typeof message !== "object") {
      return false;
    }
    if (message.type === "VR_CAPTURE_SELECTION") {
      const capture = captureSelection(message.selectionId);
      sendResponse(capture
        ? {
            text: capture.text,
            language: capture.locale,
            url: location.href,
            title: document.title
          }
        : { text: "" });
      return false;
    }
    if (message.type === "VR_SESSION_START") {
      const capture = captures.get(message.selectionId);
      if (!capture) {
        sendResponse({ ok: false, error: "Selection snapshot expired." });
        return false;
      }
      session = {
        sessionId: message.sessionId,
        selectionId: message.selectionId,
        capture,
        text: capture.text,
        offset: 0,
        playback: message.playback || "buffering"
      };
      addEventListener("scroll", scheduleReposition, true);
      addEventListener("resize", scheduleReposition);
      observeSession();
      updateUI();
      sendResponse({ ok: true });
      return false;
    }
    if (message.type === "VR_BOUNDARY" && message.sessionId === session?.sessionId) {
      showBoundary(message.offset, message.length);
      return false;
    }
    if (message.type === "VR_STATUS_PUSH" && message.status?.sessionId === session?.sessionId) {
      session.playback = message.status.playback;
      updateUI();
      return false;
    }
    if (message.type === "VR_SESSION_END" && (!message.sessionId || message.sessionId === session?.sessionId)) {
      restorePage();
      return false;
    }
    return false;
  });

  function navigationCleanup() {
    if (!session) {
      return;
    }
    const navigatedSessionId = session.sessionId;
    restorePage();
    void send({
      type: "VR_PAGE_NAVIGATED",
      sessionId: navigatedSessionId
    });
  }

  function validateSessionSnapshot() {
    scheduledValidation = 0;
    if (!session) {
      return;
    }
    if (location.href !== locationSnapshot) {
      locationSnapshot = location.href;
      navigationCleanup();
      return;
    }
    const captureChanged = session.capture.segments.some(({
      node,
      nodeStart,
      nodeEnd,
      originalText
    }) => (
      !node.isConnected
      || nodeEnd > node.data.length
      || nodeStart > nodeEnd
      || node.data.slice(nodeStart, nodeEnd) !== originalText
    )) || (
      session.capture.control && !session.capture.control.element.isConnected
    );
    if (captureChanged) {
      navigationCleanup();
    }
  }

  function observeSession() {
    sessionObserver?.disconnect();
    locationSnapshot = location.href;
    sessionObserver = new MutationObserver(() => {
      if (!scheduledValidation) {
        scheduledValidation = requestAnimationFrame(validateSessionSnapshot);
      }
    });
    sessionObserver.observe(document.documentElement, {
      childList: true,
      characterData: true,
      subtree: true
    });
  }

  addEventListener("pagehide", navigationCleanup, { capture: true });
  addEventListener("popstate", navigationCleanup);
  addEventListener("hashchange", navigationCleanup);
})().catch((error) => {
  console.warn("Whisper content script failed to start:", error);
});
