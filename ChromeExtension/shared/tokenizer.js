const WORD_PATTERN = /[\p{L}\p{M}\p{N}]/u;
const FALLBACK_PATTERN = /[\p{L}\p{M}\p{N}]+(?:['’_-][\p{L}\p{M}\p{N}]+)*|[^\s]/gu;

function tokenKind(segment, isWordLike) {
  if (isWordLike || WORD_PATTERN.test(segment)) {
    return "word";
  }
  return "punctuation";
}

export function tokenize(text, locale) {
  const source = String(text ?? "");
  if (!source) {
    return [];
  }

  if (typeof Intl?.Segmenter === "function") {
    const segmenter = new Intl.Segmenter(locale || undefined, { granularity: "word" });
    const tokens = [];
    for (const part of segmenter.segment(source)) {
      if (!part.segment.trim()) {
        continue;
      }
      tokens.push({
        start: part.index,
        end: part.index + part.segment.length,
        text: part.segment,
        kind: tokenKind(part.segment, part.isWordLike)
      });
    }
    return tokens;
  }

  return [...source.matchAll(FALLBACK_PATTERN)].map((match) => ({
    start: match.index,
    end: match.index + match[0].length,
    text: match[0],
    kind: tokenKind(match[0], false)
  }));
}

export function tokenAt(tokens, offset) {
  if (!Array.isArray(tokens) || tokens.length === 0) {
    return null;
  }

  const position = Math.max(0, Number.isFinite(Number(offset)) ? Math.trunc(Number(offset)) : 0);
  const containing = tokens.find((token) => position >= token.start && position < token.end);
  if (containing) {
    return containing;
  }

  return tokens.find((token) => token.start >= position) ?? tokens.at(-1);
}

export function resolveSpeechBoundary(text, offset, length, locale) {
  const source = String(text ?? "");
  const safeOffset = Math.min(
    source.length,
    Math.max(0, Number.isFinite(Number(offset)) ? Math.trunc(Number(offset)) : 0)
  );
  const safeLength = Math.max(
    0,
    Number.isFinite(Number(length)) ? Math.trunc(Number(length)) : 0
  );

  if (safeLength > 0) {
    return {
      start: safeOffset,
      end: Math.min(source.length, safeOffset + safeLength)
    };
  }

  const token = tokenAt(tokenize(source, locale), safeOffset);
  return token
    ? { start: token.start, end: token.end }
    : { start: safeOffset, end: safeOffset };
}
