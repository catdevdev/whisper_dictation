const toInteger = (value, fallback = 0) => {
  const number = Number(value);
  return Number.isFinite(number) ? Math.trunc(number) : fallback;
};

export function clampTextRange(offset, length, textLength) {
  const limit = Math.max(0, toInteger(textLength));
  const start = Math.min(limit, Math.max(0, toInteger(offset)));
  const requestedLength = Math.max(0, toInteger(length));
  const end = Math.min(limit, start + requestedLength);
  return { start, end, length: end - start };
}

export function normalizeSegments(segments) {
  if (!Array.isArray(segments)) {
    throw new TypeError("segments must be an array");
  }

  let previousEnd = 0;
  return segments.map((segment, index) => {
    const textStart = toInteger(segment.textStart, previousEnd);
    const textEnd = toInteger(segment.textEnd, textStart);
    const nodeStart = toInteger(segment.nodeStart);
    const nodeEnd = toInteger(segment.nodeEnd, nodeStart + (textEnd - textStart));

    if (textStart < previousEnd || textEnd < textStart) {
      throw new RangeError(`segment ${index} overlaps the preceding segment`);
    }
    if (nodeStart < 0 || nodeEnd < nodeStart || nodeEnd - nodeStart !== textEnd - textStart) {
      throw new RangeError(`segment ${index} has inconsistent node offsets`);
    }

    previousEnd = textEnd;
    return { textStart, textEnd, nodeStart, nodeEnd };
  });
}

function locateStart(segments, absoluteOffset) {
  for (let index = 0; index < segments.length; index += 1) {
    const segment = segments[index];
    if (absoluteOffset >= segment.textStart && absoluteOffset < segment.textEnd) {
      return {
        segmentIndex: index,
        nodeOffset: segment.nodeStart + absoluteOffset - segment.textStart
      };
    }
  }

  const last = segments.at(-1);
  if (last && absoluteOffset >= last.textEnd) {
    return { segmentIndex: segments.length - 1, nodeOffset: last.nodeEnd };
  }
  const nextIndex = segments.findIndex((segment) => segment.textStart > absoluteOffset);
  if (nextIndex >= 0) {
    return {
      segmentIndex: nextIndex,
      nodeOffset: segments[nextIndex].nodeStart
    };
  }
  return null;
}

function locateEnd(segments, absoluteOffset) {
  for (let index = 0; index < segments.length; index += 1) {
    const segment = segments[index];
    if (absoluteOffset > segment.textStart && absoluteOffset <= segment.textEnd) {
      return {
        segmentIndex: index,
        nodeOffset: segment.nodeStart + absoluteOffset - segment.textStart
      };
    }
  }

  const first = segments[0];
  if (first && absoluteOffset <= first.textStart) {
    return { segmentIndex: 0, nodeOffset: first.nodeStart };
  }
  for (let index = segments.length - 1; index >= 0; index -= 1) {
    const segment = segments[index];
    if (segment.textEnd < absoluteOffset) {
      return { segmentIndex: index, nodeOffset: segment.nodeEnd };
    }
  }
  return null;
}

export function mapTextRange(segmentsInput, offset, length, totalTextLength) {
  const segments = normalizeSegments(segmentsInput);
  if (segments.length === 0) {
    return null;
  }

  const mappedTextEnd = segments.at(-1).textEnd;
  const textLength = Math.max(mappedTextEnd, toInteger(totalTextLength, mappedTextEnd));
  const clamped = clampTextRange(offset, length, textLength);
  const start = locateStart(segments, clamped.start);
  const end = clamped.length === 0
    ? start && { ...start }
    : locateEnd(segments, clamped.end);

  if (!start || !end) {
    return null;
  }
  const startAfterEnd = start.segmentIndex > end.segmentIndex
    || (
      start.segmentIndex === end.segmentIndex
      && start.nodeOffset > end.nodeOffset
    );
  const safeEnd = startAfterEnd ? { ...start } : end;

  return {
    start,
    end: safeEnd,
    textStart: clamped.start,
    textEnd: clamped.end,
    length: clamped.length
  };
}
