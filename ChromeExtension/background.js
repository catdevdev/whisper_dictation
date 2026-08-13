import {
  DEFAULT_ENDPOINT,
  MAX_MESSAGE_BYTES,
  MAX_TEXT_LENGTH,
  PROTOCOL_VERSION,
  WebSocketBridge,
  normalizeEndpoint,
  normalizePairingCode
} from "./bridge.js";

const PLAYBACK_STATES = new Set(["idle", "buffering", "speaking", "paused"]);
const newId = () => crypto.randomUUID();

let settings = {
  endpoint: DEFAULT_ENDPOINT,
  pairingCode: ""
};

let status = {
  bridge: "pairing",
  playback: "idle",
  sessionId: null,
  selectionId: null,
  tabId: null,
  offset: 0,
  length: 0,
  textLength: 0,
  error: null
};

let bridge;
let captureQueue = Promise.resolve();
const textEncoder = new TextEncoder();

const ready = chrome.storage.local
  .setAccessLevel({ accessLevel: "TRUSTED_CONTEXTS" })
  .then(() => chrome.storage.local.get(["endpoint", "pairingCode"]))
  .then((stored) => {
    try {
      settings.endpoint = normalizeEndpoint(stored.endpoint || DEFAULT_ENDPOINT);
    } catch {
      settings.endpoint = DEFAULT_ENDPOINT;
    }
    try {
      settings.pairingCode = normalizePairingCode(stored.pairingCode, {
        allowEmpty: true
      });
    } catch {
      settings.pairingCode = "";
      status.error = "Сохранённый код неверен. Подключите Whisper заново.";
    }

    bridge = new WebSocketBridge({
      endpoint: settings.endpoint,
      pairingCode: settings.pairingCode,
      onMessage: handleBridgeMessage,
      onStatus: (bridgeStatus, error) => {
        status.bridge = bridgeStatus;
        status.error = error || (bridgeStatus === "connected" ? null : status.error);
        publishStatus();
        if (bridgeStatus !== "connected" && status.sessionId) {
          void stopActiveSession("bridge-disconnected", false);
        }
      }
    });
    bridge.start();
  });

function publicSettings() {
  return {
    endpoint: settings.endpoint,
    pairingConfigured: Boolean(settings.pairingCode)
  };
}

function publicStatus() {
  return {
    ...status,
    settings: publicSettings()
  };
}

function publishStatus() {
  const message = { type: "VR_STATUS_PUSH", status: publicStatus() };
  void chrome.runtime.sendMessage(message).catch(() => {});
  if (status.tabId != null) {
    void chrome.tabs.sendMessage(status.tabId, message).catch(() => {});
  }
}

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id) {
    throw new Error("No active Chrome tab is available.");
  }
  return tab;
}

function sendBridgeError(code, message, requestId) {
  bridge?.send({
    type: "error",
    protocol: PROTOCOL_VERSION,
    code,
    message,
    requestId: requestId || null,
    recoverable: true
  });
}

async function stopActiveSession(reason = "replaced", notifyApp = true) {
  const previous = { ...status };
  if (previous.sessionId && notifyApp) {
    bridge.send({
      type: "control",
      protocol: PROTOCOL_VERSION,
      sessionId: previous.sessionId,
      action: "stop",
      reason
    });
  }
  if (previous.tabId != null) {
    await chrome.tabs.sendMessage(previous.tabId, {
      type: "VR_SESSION_END",
      sessionId: previous.sessionId,
      reason
    }).catch(() => {});
  }
  if (
    status.sessionId !== previous.sessionId
    || status.selectionId !== previous.selectionId
    || status.tabId !== previous.tabId
  ) {
    return false;
  }
  status = {
    ...status,
    playback: "idle",
    sessionId: null,
    selectionId: null,
    tabId: null,
    offset: 0,
    length: 0,
    textLength: 0
  };
  publishStatus();
  return true;
}

function bridgeMessage(message) {
  const encodedBytes = textEncoder.encode(JSON.stringify(message)).byteLength;
  if (encodedBytes > MAX_MESSAGE_BYTES) {
    throw new RangeError("The selected text is too large for the local bridge.");
  }
  return message;
}

function captureSelection(options = {}) {
  const operation = captureQueue.then(
    () => captureSelectionInternal(options),
    () => captureSelectionInternal(options)
  );
  captureQueue = operation.catch(() => {});
  return operation;
}

async function captureSelectionInternal({ requestId = newId(), autoplay = true } = {}) {
  await ready;
  if (status.bridge !== "connected") {
    throw new Error("Запустите Whisper и попробуйте снова.");
  }
  const tab = await activeTab();
  if (autoplay && status.sessionId) {
    await stopActiveSession("replaced");
  }
  const selectionId = newId();
  let capture;
  try {
    capture = await chrome.tabs.sendMessage(tab.id, {
      type: "VR_CAPTURE_SELECTION",
      selectionId
    });
  } catch {
    throw new Error("This page cannot be read. Try a normal web page and reload it once.");
  }

  const text = typeof capture?.text === "string" ? capture.text : "";
  if (!text.trim()) {
    throw new Error("Select some text in the active page first.");
  }
  if (text.length > MAX_TEXT_LENGTH) {
    throw new Error(`The selection is too long. The limit is ${MAX_TEXT_LENGTH.toLocaleString()} characters.`);
  }

  const limited = (value, length) => String(value || "").slice(0, length);
  const context = {
    tabId: tab.id,
    url: limited(tab.url || capture.url, 4_096),
    title: limited(tab.title || capture.title, 512),
    language: limited(capture.language, 64)
  };

  const selectionMessage = bridgeMessage({
    type: "selection",
    protocol: PROTOCOL_VERSION,
    requestId,
    selectionId,
    text,
    context
  });

  if (!autoplay) {
    const selectionSent = bridge.send(selectionMessage);
    if (!selectionSent) {
      throw new Error("Whisper отключился. Попробуйте снова.");
    }
    return { selectionId, textLength: text.length, context };
  }

  const sessionId = newId();
  const speakMessage = bridgeMessage({
    type: "speak",
    protocol: PROTOCOL_VERSION,
    requestId,
    sessionId,
    selectionId,
    text,
    // The document locale describes the UI, not necessarily the selection.
    // Whisper detects the spoken language from the selected text itself.
    language: null,
    context
  });

  let pageSessionStarted = false;
  try {
    const sessionStart = await chrome.tabs.sendMessage(tab.id, {
      type: "VR_SESSION_START",
      sessionId,
      selectionId,
      playback: "buffering"
    });
    if (!sessionStart?.ok) {
      throw new Error(sessionStart?.error || "The page selection expired.");
    }
    pageSessionStarted = true;
    if (status.bridge !== "connected") {
      throw new Error("Whisper отключился. Попробуйте снова.");
    }

    status = {
      ...status,
      playback: "buffering",
      sessionId,
      selectionId,
      tabId: tab.id,
      offset: 0,
      length: 0,
      textLength: text.length,
      error: null
    };

    const selectionSent = bridge.send(selectionMessage);
    if (!selectionSent) {
      throw new Error("Whisper отключился. Попробуйте снова.");
    }
    const speakSent = bridge.send(speakMessage);
    if (!speakSent) {
      throw new Error("Whisper отключился. Попробуйте снова.");
    }
  } catch (error) {
    if (status.sessionId === sessionId) {
      await stopActiveSession("start-failed", false);
    } else if (pageSessionStarted) {
      await chrome.tabs.sendMessage(tab.id, {
        type: "VR_SESSION_END",
        sessionId,
        reason: "start-failed"
      }).catch(() => {});
    }
    throw error;
  }
  publishStatus();
  return { sessionId, selectionId, textLength: text.length, context };
}

async function controlPlayback(action, details = {}) {
  await ready;
  if (!status.sessionId) {
    throw new Error("Nothing is currently being read.");
  }
  const allowed = new Set(["pause", "resume", "stop", "skip", "seek"]);
  if (!allowed.has(action)) {
    throw new TypeError("Unsupported playback control.");
  }
  const seekOffset = action === "seek"
    ? Math.max(0, Math.min(status.textLength, Math.trunc(Number(details.offset) || 0)))
    : null;

  const sent = bridge.send({
    type: "control",
    protocol: PROTOCOL_VERSION,
    sessionId: status.sessionId,
    action,
    ...(action === "skip"
      ? {
          amount: Math.max(-100, Math.min(100, Math.trunc(Number(details.amount) || 0))),
          unit: "token"
        }
      : {}),
    ...(action === "seek"
      ? {
          offset: seekOffset,
          unit: "utf16"
        }
      : {})
  });
  if (!sent) {
    await stopActiveSession("bridge-disconnected", false);
    throw new Error("Whisper отключился.");
  }

  if (action === "stop") {
    await stopActiveSession("user", false);
  } else if (action === "seek") {
    status.offset = seekOffset;
    status.length = 0;
    publishStatus();
  }
}

async function updateSettings(next) {
  await ready;
  if (
    status.sessionId
    && (next.endpoint !== undefined || next.pairingCode !== undefined)
  ) {
    await stopActiveSession("connection-settings-changed");
  }
  if (next.endpoint !== undefined) {
    settings.endpoint = bridge.setEndpoint(next.endpoint);
  }
  if (next.pairingCode !== undefined) {
    settings.pairingCode = bridge.setPairingCode(
      normalizePairingCode(next.pairingCode, { allowEmpty: true })
    );
    status.error = null;
  }
  await chrome.storage.local.set({
    endpoint: settings.endpoint,
    pairingCode: settings.pairingCode
  });
  publishStatus();
  return publicSettings();
}

function validSession(message) {
  return Boolean(status.sessionId && message.sessionId === status.sessionId);
}

const boundedString = (value, maxLength = 128) => (
  typeof value === "string" && value.length > 0 && value.length <= maxLength
);

function validateBridgeMessage(message) {
  if (!boundedString(message.type, 48)) {
    return "type must be a non-empty string.";
  }
  if (message.protocol !== PROTOCOL_VERSION) {
    return "protocol must be 1.";
  }

  switch (message.type) {
    case "pong":
      return Number.isFinite(message.timestamp) ? null : "pong.timestamp must be a number.";
    case "requestSelection":
      if (!boundedString(message.requestId)) {
        return "requestSelection.requestId is required.";
      }
      return message.autoplay === undefined || typeof message.autoplay === "boolean"
        ? null
        : "requestSelection.autoplay must be a boolean.";
    case "state":
      if (!boundedString(message.sessionId)) {
        return "state.sessionId is required.";
      }
      return PLAYBACK_STATES.has(message.state)
        ? null
        : "state.state is not supported.";
    case "boundary":
      if (!boundedString(message.sessionId)) {
        return "boundary.sessionId is required.";
      }
      if (!Number.isFinite(message.offset) || message.offset < 0 || !Number.isInteger(message.offset)) {
        return "boundary.offset must be a non-negative integer.";
      }
      return Number.isFinite(message.length) && message.length >= 0 && Number.isInteger(message.length)
        ? null
        : "boundary.length must be a non-negative integer.";
    case "ended":
      if (!boundedString(message.sessionId)) {
        return "ended.sessionId is required.";
      }
      return message.reason === undefined || boundedString(message.reason, 80)
        ? null
        : "ended.reason is invalid.";
    case "error":
      if (message.sessionId !== undefined && !boundedString(message.sessionId)) {
        return "error.sessionId is invalid.";
      }
      if (message.requestId !== undefined && !boundedString(message.requestId)) {
        return "error.requestId is invalid.";
      }
      if (!boundedString(message.code, 80) || !boundedString(message.message, 2_000)) {
        return "error.code and error.message are required.";
      }
      return message.recoverable === undefined || typeof message.recoverable === "boolean"
        ? null
        : "error.recoverable must be a boolean.";
    default:
      return null;
  }
}

function handleBridgeMessage(message) {
  const validationError = validateBridgeMessage(message);
  if (validationError) {
    sendBridgeError(
      message.protocol === PROTOCOL_VERSION ? "invalid_message" : "unsupported_protocol",
      validationError,
      typeof message.requestId === "string" ? message.requestId : undefined
    );
    return;
  }

  switch (message.type) {
    case "pong":
      break;
    case "requestSelection":
      void captureSelection({
        requestId: typeof message.requestId === "string" ? message.requestId : newId(),
        autoplay: message.autoplay !== false
      }).catch((error) => {
        sendBridgeError("selection_unavailable", error.message, message.requestId);
        status.error = error.message;
        publishStatus();
      });
      break;
    case "state":
      if (!validSession(message)) {
        return;
      }
      if (message.state === "idle") {
        void stopActiveSession("idle", false);
        return;
      }
      status.playback = message.state;
      status.error = null;
      publishStatus();
      break;
    case "boundary":
      if (!validSession(message)) {
        return;
      }
      if (message.offset > status.textLength || message.length > status.textLength - message.offset) {
        sendBridgeError("invalid_boundary", "The boundary is outside the active text.");
        return;
      }
      status.offset = message.offset;
      status.length = message.length;
      if (status.tabId != null) {
        const boundarySessionId = status.sessionId;
        const boundaryTabId = status.tabId;
        void chrome.tabs.sendMessage(boundaryTabId, {
          type: "VR_BOUNDARY",
          sessionId: boundarySessionId,
          offset: status.offset,
          length: status.length
        }).catch(() => {
          if (
            status.sessionId === boundarySessionId
            && status.tabId === boundaryTabId
          ) {
            void stopActiveSession("page-unavailable");
          }
        });
      }
      publishStatus();
      break;
    case "ended":
      if (validSession(message)) {
        void stopActiveSession(message.reason || "completed", false);
      }
      break;
    case "error":
      if (message.sessionId && !validSession(message)) {
        return;
      }
      status.error = typeof message.message === "string" ? message.message : "The reader reported an error.";
      if (message.sessionId) {
        void stopActiveSession("error", false);
      } else {
        publishStatus();
      }
      break;
    default:
      sendBridgeError("unknown_message", `Unknown message type: ${String(message.type)}`, message.requestId);
  }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message !== "object" || message.type === "VR_STATUS_PUSH") {
    return false;
  }

  const respond = async () => {
    await ready;
    switch (message.type) {
      case "VR_GET_STATUS":
        return { ok: true, status: publicStatus() };
      case "VR_SPEAK_SELECTION":
        return { ok: true, result: await captureSelection() };
      case "VR_CONTROL":
        await controlPlayback(message.action, message);
        return { ok: true };
      case "VR_UPDATE_SETTINGS":
        if (sender.tab) {
          throw new Error("Connection settings can only be changed from the extension popup.");
        }
        return { ok: true, settings: await updateSettings(message.settings || {}) };
      case "VR_PAGE_NAVIGATED":
        if (
          sender.tab?.id === status.tabId
          && message.sessionId === status.sessionId
        ) {
          await stopActiveSession("navigation");
        }
        return { ok: true };
      default:
        return { ok: false, error: "Unknown extension message." };
    }
  };

  void respond()
    .then(sendResponse)
    .catch((error) => {
      status.error = error instanceof Error ? error.message : String(error);
      publishStatus();
      sendResponse({ ok: false, error: status.error });
    });
  return true;
});

chrome.commands.onCommand.addListener((command) => {
  void ready.then(async () => {
    if (command === "speak-selection") {
      await captureSelection();
    } else if (command === "toggle-playback" && status.sessionId) {
      await controlPlayback(status.playback === "paused" ? "resume" : "pause");
    }
  }).catch((error) => {
    status.error = error.message;
    publishStatus();
  });
});

chrome.tabs.onRemoved.addListener((tabId) => {
  if (tabId === status.tabId) {
    void stopActiveSession("tab-closed");
  }
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (
    tabId === status.tabId
    && (changeInfo.status === "loading" || typeof changeInfo.url === "string")
  ) {
    void stopActiveSession("navigation");
  }
});
