import test from "node:test";
import assert from "node:assert/strict";

import {
  resolveSpeechBoundary,
  tokenAt,
  tokenize
} from "../shared/tokenizer.js";

test("tokenizes multilingual text using UTF-16 offsets", () => {
  const text = "Hello, мир 👋🏽!";
  const tokens = tokenize(text, "ru");
  assert.equal(tokens.map((token) => token.text).join(""), "Hello,мир👋🏽!");
  const emoji = tokens.find((token) => token.text.includes("👋"));
  assert.deepEqual(
    { start: emoji.start, end: emoji.end },
    { start: text.indexOf("👋"), end: text.indexOf("👋") + "👋🏽".length }
  );
});

test("finds a token at an offset or the nearest following token", () => {
  const tokens = tokenize("one   two", "en");
  assert.equal(tokenAt(tokens, 1).text, "one");
  assert.equal(tokenAt(tokens, 4).text, "two");
  assert.equal(tokenAt(tokens, 99).text, "two");
});

test("uses an explicit speech range without retokenizing it", () => {
  assert.deepEqual(resolveSpeechBoundary("alpha beta", 2, 4, "en"), {
    start: 2,
    end: 6
  });
});

test("expands a zero-length boundary to the current spoken token", () => {
  assert.deepEqual(resolveSpeechBoundary("alpha beta", 7, 0, "en"), {
    start: 6,
    end: 10
  });
});

test("clamps malformed or oversized boundary values", () => {
  assert.deepEqual(resolveSpeechBoundary("abc", -9, 50, "en"), {
    start: 0,
    end: 3
  });
});
