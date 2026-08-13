import test from "node:test";
import assert from "node:assert/strict";

import {
  captureSafeFormSelection,
  isSensitiveSelectionControl,
  rangeTouchesSensitiveControl
} from "../shared/selection-security.js";

class MockElement {
  constructor(attributes = {}, parentElement = null) {
    this.attributes = new Map(Object.entries(attributes));
    this.parentElement = parentElement;
    this.nodeType = 1;
    this.isContentEditable = false;
    this.descendants = [];
  }

  getAttribute(name) {
    return this.attributes.has(name) ? this.attributes.get(name) : null;
  }

  getRootNode() {
    return { host: null };
  }

  querySelectorAll() {
    return this.descendants;
  }
}

class MockInput extends MockElement {
  constructor({
    attributes = {},
    parentElement = null,
    value = "",
    start = 0,
    end = 0,
    reads = null
  } = {}) {
    super(attributes, parentElement);
    this.mockValue = value;
    this.mockStart = start;
    this.mockEnd = end;
    this.reads = reads;
  }

  get selectionStart() {
    if (this.reads) this.reads.selectionStart += 1;
    return this.mockStart;
  }

  get selectionEnd() {
    if (this.reads) this.reads.selectionEnd += 1;
    return this.mockEnd;
  }

  get value() {
    if (this.reads) this.reads.value += 1;
    return this.mockValue;
  }
}

class MockTextArea extends MockInput {}

globalThis.HTMLInputElement = MockInput;
globalThis.HTMLTextAreaElement = MockTextArea;

test("password selections are rejected before any control content is read", () => {
  const reads = { selectionStart: 0, selectionEnd: 0, value: 0 };
  const password = new MockInput({
    attributes: { type: " PASSWORD " },
    value: "never expose this",
    start: 0,
    end: 17,
    reads
  });

  assert.equal(captureSafeFormSelection(password, "selection-1", "en"), null);
  assert.deepEqual(reads, { selectionStart: 0, selectionEnd: 0, value: 0 });
});

test("credential and payment autocomplete tokens are rejected", () => {
  for (const autocomplete of [
    "current-password",
    "new-password",
    "one-time-code",
    "section-login username webauthn",
    "cc-number",
    "cc-csc"
  ]) {
    const control = new MockInput({
      attributes: { type: "text", autocomplete },
      value: "sensitive",
      start: 0,
      end: 9
    });
    assert.equal(
      captureSafeFormSelection(control, "selection-2", "en"),
      null,
      `expected autocomplete=${autocomplete} to be blocked`
    );
  }
});

test("credential-like field metadata and explicit privacy markers are rejected", () => {
  const passwordAlias = new MockInput({
    attributes: { type: "text", id: "accountPasswordConfirmation" }
  });
  const localizedPassword = new MockInput({
    attributes: { type: "text", placeholder: "Введите пароль" }
  });
  const privateWrapper = new MockElement({ "data-private": "" });
  const nestedTextarea = new MockTextArea({ parentElement: privateWrapper });
  const explicitFalse = new MockInput({
    attributes: { type: "text", "data-sensitive": "false", name: "notes" }
  });

  assert.equal(isSensitiveSelectionControl(passwordAlias), true);
  assert.equal(isSensitiveSelectionControl(localizedPassword), true);
  assert.equal(isSensitiveSelectionControl(nestedTextarea), true);
  assert.equal(isSensitiveSelectionControl(explicitFalse), false);
});

test("ordinary text inputs and textareas keep selection capture", () => {
  const input = new MockInput({
    attributes: { type: "search", autocomplete: "off", name: "query" },
    value: "read this query",
    start: 5,
    end: 9
  });
  const textarea = new MockTextArea({
    attributes: { placeholder: "Введите текст" },
    value: "Обычный русский текст",
    start: 0,
    end: 7
  });

  const inputCapture = captureSafeFormSelection(input, "selection-3", "en-US");
  const textareaCapture = captureSafeFormSelection(textarea, "selection-4", "ru");

  assert.equal(inputCapture.text, "this");
  assert.equal(inputCapture.control.element, input);
  assert.equal(inputCapture.locale, "en-US");
  assert.equal(textareaCapture.text, "Обычный");
  assert.equal(textareaCapture.locale, "ru");
});

test("ordinary document selections remain readable", () => {
  const root = new MockElement();
  const paragraph = new MockElement({}, root);
  const start = { nodeType: 3, parentElement: paragraph };
  const end = { nodeType: 3, parentElement: paragraph };
  root.descendants = [paragraph];
  const range = {
    startContainer: start,
    endContainer: end,
    commonAncestorContainer: root,
    intersectsNode: () => true
  };

  assert.equal(rangeTouchesSensitiveControl(range), false);
});

test("document selections touching a sensitive editor are rejected without reading text", () => {
  const root = new MockElement();
  const paragraph = new MockElement({}, root);
  const secretEditor = new MockElement({
    contenteditable: "true",
    "aria-label": "API key"
  }, root);
  const start = { nodeType: 3, parentElement: paragraph };
  const end = { nodeType: 3, parentElement: paragraph };
  root.descendants = [paragraph, secretEditor];
  const range = {
    startContainer: start,
    endContainer: end,
    commonAncestorContainer: root,
    intersectsNode: (element) => element === paragraph || element === secretEditor
  };

  assert.equal(rangeTouchesSensitiveControl(range), true);
});

test("a range beginning inside a sensitive editor is rejected immediately", () => {
  const privateWrapper = new MockElement({ "data-sensitive": "true" });
  const editor = new MockElement({ contenteditable: "true" }, privateWrapper);
  const textNode = { nodeType: 3, parentElement: editor };
  const range = {
    startContainer: textNode,
    endContainer: textNode,
    commonAncestorContainer: textNode,
    intersectsNode: () => false
  };

  assert.equal(rangeTouchesSensitiveControl(range), true);
});

test("a selection nested below a sensitive contenteditable ancestor is rejected", () => {
  const secretEditor = new MockElement({
    contenteditable: "true",
    "aria-label": "API key"
  });
  const nestedSpan = new MockElement({}, secretEditor);
  const textNode = { nodeType: 3, parentElement: nestedSpan };
  const range = {
    startContainer: textNode,
    endContainer: textNode,
    commonAncestorContainer: textNode,
    intersectsNode: () => false
  };

  assert.equal(isSensitiveSelectionControl(nestedSpan), true);
  assert.equal(rangeTouchesSensitiveControl(range), true);
});
