const elements = {
  connection: document.querySelector("#connection"),
  connectionText: document.querySelector("#connection span:last-child"),
  state: document.querySelector("#state"),
  read: document.querySelector("#read"),
  back: document.querySelector("#back"),
  toggle: document.querySelector("#toggle"),
  forward: document.querySelector("#forward"),
  stop: document.querySelector("#stop"),
  seek: document.querySelector("#seek"),
  position: document.querySelector("#position"),
  connectionDetails: document.querySelector("details"),
  endpoint: document.querySelector("#endpoint"),
  pairingForm: document.querySelector("#pairing-form"),
  pairingCode: document.querySelector("#pairing-code"),
  pairingStatus: document.querySelector("#pairing-status"),
  pair: document.querySelector("#pair"),
  error: document.querySelector("#error")
};

let currentStatus = null;

async function request(message) {
  const response = await chrome.runtime.sendMessage(message);
  if (!response?.ok) {
    throw new Error(response?.error || "The extension did not respond.");
  }
  return response;
}

function showError(message) {
  elements.error.textContent = message || "";
  elements.error.hidden = !message;
}

function render(status) {
  currentStatus = status;
  const connected = status.bridge === "connected";
  elements.connection.className = connected
    ? "connected"
    : status.bridge === "error" || status.bridge === "pairing-error"
      ? "error-state"
      : "";
  elements.connectionText.textContent = {
    connected: "Whisper подключён",
    pairing: "Нужен код подключения",
    "pairing-error": "Код не подошёл",
    authenticating: "Проверка кода…",
    connecting: "Подключение…",
    disconnected: "Whisper не запущен",
    error: "Ошибка подключения"
  }[status.bridge] || "Whisper не запущен";
  elements.read.disabled = !connected;

  elements.state.textContent = {
    idle: "Готово",
    buffering: "Подготовка",
    speaking: "Чтение",
    paused: "Пауза"
  }[status.playback] || "Готово";

  const active = Boolean(status.sessionId);
  for (const control of [elements.back, elements.toggle, elements.forward, elements.stop]) {
    control.disabled = !active;
  }
  const paused = status.playback === "paused";
  elements.toggle.textContent = paused ? "▶" : "Ⅱ";
  elements.toggle.setAttribute("aria-label", paused ? "Продолжить" : "Пауза");
  elements.toggle.title = paused ? "Продолжить" : "Пауза";
  elements.seek.disabled = !active;
  elements.seek.max = Math.max(1, status.textLength || 0);
  if (document.activeElement !== elements.seek) {
    elements.seek.value = Math.min(status.offset || 0, status.textLength || 0);
  }
  const positionPercent = status.textLength
    ? Math.min(100, Math.round(((Number(elements.seek.value) || 0) / status.textLength) * 100))
    : 0;
  elements.position.value = `${positionPercent}%`;

  if (document.activeElement !== elements.endpoint) {
    elements.endpoint.value = status.settings.endpoint;
  }
  const pairingConfigured = Boolean(status.settings.pairingConfigured);
  if (!pairingConfigured || status.bridge === "pairing-error") {
    elements.connectionDetails.open = true;
  }
  elements.pairingStatus.textContent = pairingConfigured
    ? "Код сохранён"
    : "Не подключено";
  elements.pair.textContent = pairingConfigured ? "Обновить" : "Подключить";
  showError(status.error);
}

async function perform(action) {
  showError("");
  try {
    await action();
    const response = await request({ type: "VR_GET_STATUS" });
    render(response.status);
  } catch (error) {
    showError(error instanceof Error ? error.message : String(error));
  }
}

elements.read.addEventListener("click", () => {
  void perform(() => request({ type: "VR_SPEAK_SELECTION" }));
});

elements.back.addEventListener("click", () => {
  void perform(() => request({ type: "VR_CONTROL", action: "skip", amount: -10 }));
});

elements.forward.addEventListener("click", () => {
  void perform(() => request({ type: "VR_CONTROL", action: "skip", amount: 10 }));
});

elements.toggle.addEventListener("click", () => {
  const action = currentStatus?.playback === "paused" ? "resume" : "pause";
  void perform(() => request({ type: "VR_CONTROL", action }));
});

elements.stop.addEventListener("click", () => {
  void perform(() => request({ type: "VR_CONTROL", action: "stop" }));
});

elements.seek.addEventListener("input", () => {
  const textLength = currentStatus?.textLength || 0;
  const percent = textLength
    ? Math.min(100, Math.round((Number(elements.seek.value) / textLength) * 100))
    : 0;
  elements.position.value = `${percent}%`;
});

elements.seek.addEventListener("change", () => {
  void perform(() => request({
    type: "VR_CONTROL",
    action: "seek",
    offset: Number(elements.seek.value)
  }));
});

elements.endpoint.addEventListener("change", () => {
  void perform(() => request({
    type: "VR_UPDATE_SETTINGS",
    settings: { endpoint: elements.endpoint.value }
  }));
});

elements.pairingForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const pairingCode = elements.pairingCode.value;
  void perform(async () => {
    await request({
      type: "VR_UPDATE_SETTINGS",
      settings: { pairingCode }
    });
    elements.pairingCode.value = "";
  });
});

chrome.runtime.onMessage.addListener((message) => {
  if (message?.type === "VR_STATUS_PUSH") {
    render(message.status);
  }
});

void perform(async () => {
  const response = await request({ type: "VR_GET_STATUS" });
  render(response.status);
});
