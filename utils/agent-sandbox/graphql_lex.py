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

def _tokenize(text: str) -> Iterator[str]:
    """
    Lazily lex *text*, yielding only the tokens contains_mutation needs:
    '{', '}', and the name 'mutation'.  Everything else is consumed silently.

    String literals and block strings are consumed as a unit so their
    content cannot contribute '{', '}', or 'mutation' to the stream.
    Raises LexError on unterminated strings (the one case where incorrect
    boundary detection would let content escape into the token stream).
    """
    i = 0
    n = len(text)

    while i < n:
        c = text[i]

        # Block string  """…"""  (escape inside: \""")
        # Must be checked before the single-" branch.
        if text[i:i + 3] == '"""':
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
                if text[i] in '\n\r':
                    raise LexError("unterminated string literal (newline inside string)")
                if text[i] == '\\':
                    i += 2
                elif text[i] == '"':
                    i += 1
                    break
                else:
                    i += 1

        # Line comment
        elif c == '#':
            while i < n and text[i] not in '\n\r':
                i += 1

        # The two tokens used for depth tracking
        elif c == '{':
            yield '{'
            i += 1
        elif c == '}':
            yield '}'
            i += 1

        # Names — only yield 'mutation'; consume all others
        elif c.isalpha() or c == '_':
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == '_'):
                j += 1
            if text[i:j] == 'mutation':
                yield 'mutation'
            i = j

        # Everything else (whitespace, punctuation, numbers, …): skip
        else:
            i += 1


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
