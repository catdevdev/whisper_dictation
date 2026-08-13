const SENSITIVE_AUTOCOMPLETE_TOKENS = new Set([
  "username",
  "current-password",
  "new-password",
  "one-time-code",
  "webauthn",
  "cc-name",
  "cc-given-name",
  "cc-additional-name",
  "cc-family-name",
  "cc-number",
  "cc-exp",
  "cc-exp-month",
  "cc-exp-year",
  "cc-csc",
  "cc-type",
  "transaction-amount",
  "transaction-currency"
]);

const SENSITIVE_FIELD_PATTERN = /(?:^|\s)(?:password|passwd|pwd|passcode|pin|otp|2fa|mfa|one time code|security code|security answer|cvv|cvc|card number|credit card|secret|api key|private key|access token|auth token|refresh token|bearer token|username|user name|login|пароль|пин|одноразовый код|код безопасности|секрет|имя пользователя|пін|одноразовий код|код безпеки|ім я користувача)(?:$|\s)/u;

function attribute(element, name) {
  if (!element || typeof element.getAttribute !== "function") {
    return null;
  }
  const value = element.getAttribute(name);
  return typeof value === "string" ? value.trim() : null;
}

function normalizedFieldMetadata(element) {
  return ["name", "id", "aria-label", "placeholder", "data-testid"]
    .map((name) => attribute(element, name) || "")
    .join(" ")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

function hasExplicitSensitiveMarker(element) {
  const falseValues = new Set(["0", "false", "no", "off"]);
  const markerNames = [
    "data-sensitive",
    "data-private",
    "data-secret",
    "data-password"
  ];
  for (const name of markerNames) {
    const value = attribute(element, name);
    if (value !== null && !falseValues.has(value.toLowerCase())) {
      return true;
    }
  }
  return false;
}

function parentOrShadowHost(element) {
  const rootHost = typeof element?.getRootNode === "function"
    ? element.getRootNode()?.host
    : null;
  return element?.parentElement || rootHost || null;
}

function isFormTextControl(element) {
  const Input = globalThis.HTMLInputElement;
  const TextArea = globalThis.HTMLTextAreaElement;
  return (typeof Input === "function" && element instanceof Input)
    || (typeof TextArea === "function" && element instanceof TextArea);
}

function isTextEntryControl(element) {
  if (isFormTextControl(element)) {
    return true;
  }
  const contentEditable = attribute(element, "contenteditable");
  return element?.isContentEditable === true
    || (contentEditable !== null && contentEditable.toLowerCase() !== "false")
    || attribute(element, "role")?.toLowerCase() === "textbox";
}

function isDirectlySensitiveSelectionControl(element) {
  if (hasExplicitSensitiveMarker(element)) {
    return true;
  }
  if (!isTextEntryControl(element)) {
    return false;
  }

  const Input = globalThis.HTMLInputElement;
  if (
    typeof Input === "function"
    && element instanceof Input
    && attribute(element, "type")?.toLowerCase() === "password"
  ) {
    return true;
  }

  const autocompleteTokens = (attribute(element, "autocomplete") || "")
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean);
  if (autocompleteTokens.some((token) => SENSITIVE_AUTOCOMPLETE_TOKENS.has(token))) {
    return true;
  }

  const metadata = normalizedFieldMetadata(element);
  return Boolean(metadata && SENSITIVE_FIELD_PATTERN.test(metadata));
}

export function isSensitiveSelectionControl(element) {
  const visited = new Set();
  for (let candidate = element; candidate && !visited.has(candidate);) {
    visited.add(candidate);
    if (isDirectlySensitiveSelectionControl(candidate)) {
      return true;
    }
    candidate = parentOrShadowHost(candidate);
  }
  return false;
}

function elementForNode(node) {
  return node?.nodeType === 1 ? node : node?.parentElement || null;
}

export function rangeTouchesSensitiveControl(range) {
  if (!range) {
    return false;
  }
  if (
    isSensitiveSelectionControl(elementForNode(range.startContainer))
    || isSensitiveSelectionControl(elementForNode(range.endContainer))
  ) {
    return true;
  }

  const root = range.commonAncestorContainer;
  const elements = [];
  if (root?.nodeType === 1) {
    elements.push(root);
  }
  if (typeof root?.querySelectorAll === "function") {
    elements.push(...root.querySelectorAll("*"));
  }
  for (const element of elements) {
    if (!isSensitiveSelectionControl(element)) {
      continue;
    }
    try {
      if (range.intersectsNode(element)) {
        return true;
      }
    } catch {
      // A detached page node cannot contribute readable selection text.
    }
  }
  return false;
}

export function captureSafeFormSelection(element, selectionId, locale) {
  if (!isFormTextControl(element) || isSensitiveSelectionControl(element)) {
    return null;
  }
  const start = element.selectionStart;
  const end = element.selectionEnd;
  if (start == null || end == null || start === end) {
    return null;
  }
  const text = element.value.slice(start, end);
  if (!text.trim()) {
    return null;
  }
  return {
    selectionId,
    text,
    segments: [],
    control: { element, start, end },
    locale
  };
}
