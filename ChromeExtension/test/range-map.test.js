import test from "node:test";
import assert from "node:assert/strict";

import {
  clampTextRange,
  mapTextRange,
  normalizeSegments
} from "../shared/range-map.js";

const segments = [
  { textStart: 0, textEnd: 5, nodeStart: 2, nodeEnd: 7 },
  { textStart: 5, textEnd: 11, nodeStart: 0, nodeEnd: 6 }
];

test("maps a range inside one DOM text node", () => {
  assert.deepEqual(mapTextRange(segments, 1, 3), {
    start: { segmentIndex: 0, nodeOffset: 3 },
    end: { segmentIndex: 0, nodeOffset: 6 },
    textStart: 1,
    textEnd: 4,
    length: 3
  });
});

test("maps a range across adjacent text nodes", () => {
  assert.deepEqual(mapTextRange(segments, 3, 5), {
    start: { segmentIndex: 0, nodeOffset: 5 },
    end: { segmentIndex: 1, nodeOffset: 3 },
    textStart: 3,
    textEnd: 8,
    length: 5
  });
});

test("keeps an end boundary on the preceding node", () => {
  const mapped = mapTextRange(segments, 0, 5);
  assert.deepEqual(mapped.end, { segmentIndex: 0, nodeOffset: 7 });
});

test("keeps a start boundary on the following node", () => {
  const mapped = mapTextRange(segments, 5, 2);
  assert.deepEqual(mapped.start, { segmentIndex: 1, nodeOffset: 0 });
});

test("maps a zero-length boundary to one valid DOM point", () => {
  const mapped = mapTextRange(segments, 5, 0);
  assert.deepEqual(mapped.start, { segmentIndex: 1, nodeOffset: 0 });
  assert.deepEqual(mapped.end, mapped.start);
});

test("clamps bridge offsets to the selected text", () => {
  assert.deepEqual(clampTextRange(-4, 99, 11), { start: 0, end: 11, length: 11 });
  assert.deepEqual(clampTextRange(50, 4, 11), { start: 11, end: 11, length: 0 });
});

test("rejects overlaps and inconsistent segment lengths", () => {
  assert.throws(
    () => normalizeSegments([
      { textStart: 0, textEnd: 2, nodeStart: 0, nodeEnd: 2 },
      { textStart: 1, textEnd: 2, nodeStart: 0, nodeEnd: 1 }
    ]),
    /overlaps/
  );
  assert.throws(
    () => normalizeSegments([{ textStart: 0, textEnd: 2, nodeStart: 0, nodeEnd: 1 }]),
    /inconsistent/
  );
});

test("maps around synthetic layout newlines without inventing DOM nodes", () => {
  const blockSegments = [
    { textStart: 0, textEnd: 5, nodeStart: 0, nodeEnd: 5 },
    { textStart: 7, textEnd: 12, nodeStart: 0, nodeEnd: 5 }
  ];
  const secondWord = mapTextRange(blockSegments, 7, 5, 12);
  assert.deepEqual(secondWord.start, { segmentIndex: 1, nodeOffset: 0 });
  assert.deepEqual(secondWord.end, { segmentIndex: 1, nodeOffset: 5 });

  const newlineOnly = mapTextRange(blockSegments, 5, 2, 12);
  assert.deepEqual(newlineOnly.start, { segmentIndex: 1, nodeOffset: 0 });
  assert.deepEqual(newlineOnly.end, newlineOnly.start);
});
