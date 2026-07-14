"""
graphql_lex.py — minimal GraphQL lexer for mutation detection.

Scans a GraphQL document for a top-level 'mutation' keyword.

Design
  1. _tokenize(text) -> Iterator[str]  [generator]
       Yields names and punctuators; silently consumes string literals,
       block strings, comments, and numbers so their content can't fool
       the classifier.  Raises LexError on anything outside the GraphQL
       lexical grammar (invalid characters, unterminated strings, etc.).

  2. contains_mutation(query_str) -> bool
       Iterates the token stream tracking brace depth.  Returns True as
       soon as the 'mutation' keyword appears at depth 0, without reading
       any further.  Returns False if the document ends without one.

Known false positive: 'mutation' used as an operation *name* or fragment
*name* at depth 0 (e.g. 'query mutation { … }') is indistinguishable from
the operation keyword without structural parsing.  This is acceptable —
nobody names their query "mutation", and a false positive merely blocks a
read (fail-closed).

LexError on lex failures only; structural oddities (SDL, missing body, etc.)
are not validated — GitHub will reject them before any side-effect occurs.
"""

from __future__ import annotations
from typing import Iterator


class LexError(Exception):
    """Raised on any lex failure.  Callers should treat this as deny."""


# ── Tokeniser ─────────────────────────────────────────────────────────────────

_PUNCT_CHARS = frozenset('!$&():=@[]{}|')


def _tokenize(text: str) -> Iterator[str]:
    """
    Lazily lex *text*, yielding one token at a time.

    Yielded: names/keywords and punctuators.
    Silently consumed: string literals (regular + block), line comments,
    number literals, whitespace, commas, Unicode BOM.
    Raises LexError on invalid characters, unterminated strings, bad numbers.
    """
    i = 0
    n = len(text)

    while i < n:
        c = text[i]

        # Insignificant: whitespace, BOM, comma
        if c in ' \t\n\r\x0c\x0b,\ufeff':
            i += 1

        # Line comment
        elif c == '#':
            while i < n and text[i] not in '\n\r':
                i += 1

        # Block string  """…"""  (escape inside: \""")
        elif text[i:i + 3] == '"""':
            i += 3
            while True:
                if i >= n:
                    raise LexError("unterminated block string literal")
                if text[i:i + 4] == '\\"""':   # escaped triple-quote
                    i += 4
                elif text[i:i + 3] == '"""':    # closing delimiter
                    i += 3
                    break
                else:
                    i += 1

        # Regular string  "…"  (no raw newlines; backslash escapes)
        elif c == '"':
            i += 1
            while True:
                if i >= n:
                    raise LexError("unterminated string literal (reached end of input)")
                ch = text[i]
                if ch in '\n\r':
                    raise LexError("unterminated string literal (newline inside string)")
                if ch == '\\':
                    i += 2
                elif ch == '"':
                    i += 1
                    break
                else:
                    i += 1

        # Spread  ...
        elif c == '.':
            if text[i:i + 3] != '...':
                raise LexError(f"unexpected '.' at offset {i}: only '...' is valid")
            yield '...'
            i += 3

        # Single-character punctuators
        elif c in _PUNCT_CHARS:
            yield c
            i += 1

        # Names
        elif c.isalpha() or c == '_':
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == '_'):
                j += 1
            yield text[i:j]
            i = j

        # Numbers (consumed, not yielded)
        elif c.isdigit() or (c == '-' and i + 1 < n and text[i + 1].isdigit()):
            if c == '-':
                i += 1
            while i < n and text[i].isdigit():
                i += 1
            if i < n and text[i] == '.' and i + 1 < n and text[i + 1].isdigit():
                i += 1
                while i < n and text[i].isdigit():
                    i += 1
            if i < n and text[i] in 'eE':
                i += 1
                if i < n and text[i] in '+-':
                    i += 1
                if i >= n or not text[i].isdigit():
                    raise LexError("invalid number: expected digit after exponent")
                while i < n and text[i].isdigit():
                    i += 1

        else:
            raise LexError(f"unexpected character {c!r} at offset {i}")


# ── Classifier ────────────────────────────────────────────────────────────────

def contains_mutation(query_str: str) -> bool:
    """
    Return True if 'mutation' appears as a top-level token (brace depth 0).
    Return False if the document ends without one.
    Raise LexError on any lex failure (callers must treat this as deny).
    """
    depth = 0
    for tok in _tokenize(query_str):
        if tok == '{':
            depth += 1
        elif tok == '}':
            depth -= 1
        elif tok == 'mutation' and depth == 0:
            return True
    return False
