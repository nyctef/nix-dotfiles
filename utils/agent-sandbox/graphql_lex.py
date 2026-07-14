"""
graphql_lex.py — minimal GraphQL document lexer for operation-type detection.

Purpose: determine whether a GraphQL request document contains any mutation
operation, for use in the agent sandbox egress policy.  We do not execute,
validate, or fully parse the document — we only classify top-level operation
keywords.

Two-stage design
  1. _tokenize(text) -> Iterator[str]
       Generator that yields tokens on demand from the raw document string.
       String literals (regular and block/triple-quoted) and comments are
       consumed but not emitted, so keywords inside them cannot fool the
       classifier.  Numbers are consumed but not emitted.  Everything that is
       not valid GraphQL raises LexError immediately (fail-closed).

  2. contains_mutation(query_str) -> bool
       Wraps the generator in a one-token peek stream (_Tokens) and walks
       only as far as needed: returns True the moment a top-level 'mutation'
       keyword is seen, without lexing or parsing anything that follows.
       For a document that opens with 'mutation', this reads exactly one
       token from the generator.  Raises LexError on any unexpected token or
       malformed structure; callers treat that as a deny decision.

Supported top-level definition forms (GraphQL June 2018 spec):
  { SelectionSet }                              shorthand anonymous query
  query/subscription [Name] [Vars] [Dirs] {}    read operation
  mutation          [Name] [Vars] [Dirs] {}     write operation -> True
  fragment Name on TypeName [Dirs] {}           fragment definition (skipped)

Type-system / SDL definitions (type, schema, directive, extend, …) are
intentionally not handled and raise LexError (fail-closed).
"""

from __future__ import annotations
from typing import Iterator


class LexError(Exception):
    """Raised on any lex or parse failure.  Callers should treat this as deny."""


# ── Stage 1: Tokeniser (generator) ───────────────────────────────────────────

# Single-character punctuators defined by the GraphQL spec (§2.1.8).
# '...' (spread/ellipsis) is three characters and is handled separately.
_PUNCT_CHARS = frozenset('!$&():=@[]{}|')


def _tokenize(text: str) -> Iterator[str]:
    """
    Lazily lex *text*, yielding one token at a time.

    Yielded tokens:
      Names / keywords  — their literal text, e.g. 'mutation', 'on', 'User'
      Punctuators       — their literal text: { } ( ) [ ] @ ! $ & | : = ...

    Silently consumed (not yielded):
      String literals   — regular ("…") and block (triple-quoted); content
                          is discarded so embedded keywords can't fool callers
      Line comments     — # … <newline>; discarded entirely
      Number literals   — int or float; discarded (only appear inside value
                          positions that the top-level parser skips entirely)
      Insignificant     — spaces, tabs, newlines, commas, Unicode BOM

    Raises LexError on:
      Any character outside the GraphQL lexical grammar
      A lone '.' or '..' that is not part of '...'
      An unterminated string or block-string literal
      A number literal with a malformed exponent
    """
    i = 0
    n = len(text)

    while i < n:
        c = text[i]

        # ── Insignificant: whitespace, BOM, comma (spec §2.1.6–7) ────────
        if c in ' \t\n\r\x0c\x0b,\ufeff':
            i += 1

        # ── Line comment: # … until end of line (spec §2.1.3) ────────────
        elif c == '#':
            while i < n and text[i] not in '\n\r':
                i += 1

        # ── Block string: """…"""   escape inside: \""" (spec §2.9.4) ────
        elif text[i:i + 3] == '"""':
            i += 3
            while True:
                if i >= n:
                    raise LexError("unterminated block string literal")
                # Escaped triple-quote: \""" represents """ in the value.
                # Must be checked BEFORE the plain closing """ test.
                if text[i:i + 4] == '\\"""':
                    i += 4
                elif text[i:i + 3] == '"""':
                    i += 3  # closing delimiter
                    break
                else:
                    i += 1

        # ── Regular string: "…"  no raw newlines; backslash escapes (§2.9)
        elif c == '"':
            i += 1
            while True:
                if i >= n:
                    raise LexError("unterminated string literal (reached end of input)")
                ch = text[i]
                if ch in '\n\r':
                    raise LexError("unterminated string literal (raw newline inside string)")
                if ch == '\\':
                    i += 2  # skip the escape character and the following char
                elif ch == '"':
                    i += 1  # closing quote
                    break
                else:
                    i += 1

        # ── Spread operator: ...  (spec §2.1.8) ──────────────────────────
        elif c == '.':
            if text[i:i + 3] != '...':
                raise LexError(
                    f"unexpected '.' at offset {i}:"
                    f" only '...' (spread) is valid GraphQL"
                )
            yield '...'
            i += 3

        # ── Single-character punctuators (spec §2.1.8) ───────────────────
        elif c in _PUNCT_CHARS:
            yield c
            i += 1

        # ── Names: [_A-Za-z][_0-9A-Za-z]*  (spec §2.1.9) ────────────────
        elif c.isalpha() or c == '_':
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == '_'):
                j += 1
            yield text[i:j]
            i = j

        # ── Number literals (int or float, optional leading minus) ────────
        # Consumed but NOT yielded — numbers only appear inside value
        # positions that the top-level parser skips via _skip_balanced.
        elif c.isdigit() or (c == '-' and i + 1 < n and text[i + 1].isdigit()):
            if c == '-':
                i += 1
            # Integer part
            while i < n and text[i].isdigit():
                i += 1
            # Optional fractional part: . Digit+
            if i < n and text[i] == '.' and i + 1 < n and text[i + 1].isdigit():
                i += 1
                while i < n and text[i].isdigit():
                    i += 1
            # Optional exponent part: (e|E) [+-] Digit+
            if i < n and text[i] in 'eE':
                i += 1
                if i < n and text[i] in '+-':
                    i += 1
                if i >= n or not text[i].isdigit():
                    raise LexError("invalid number literal: expected digit after exponent sign")
                while i < n and text[i].isdigit():
                    i += 1
            # intentionally not yielded

        # ── Anything else is outside the GraphQL grammar ──────────────────
        else:
            raise LexError(f"unexpected character {c!r} at offset {i}")


# ── Stage 2: Top-level operation classifier ───────────────────────────────────

class _Tokens:
    """
    One-token look-ahead wrapper around the _tokenize generator.

    peek()    — return the next token without consuming it (None = EOF)
    consume() — return and consume the next token (None = EOF)
    expect(t) — consume and return the next token, raising LexError if it
                is not *t* or if EOF is reached
    """

    def __init__(self, gen: Iterator[str]) -> None:
        self._gen = gen
        self._buf: str | None = None
        self._empty = False      # True once the generator is exhausted

    def _advance(self) -> None:
        try:
            self._buf = next(self._gen)
        except StopIteration:
            self._buf = None
            self._empty = True

    def peek(self) -> str | None:
        if self._buf is None and not self._empty:
            self._advance()
        return self._buf

    def consume(self) -> str | None:
        tok = self.peek()
        self._buf = None
        return tok

    def expect(self, tok: str) -> str:
        got = self.consume()
        if got != tok:
            desc = repr(got) if got is not None else "EOF"
            raise LexError(f"expected {tok!r}, got {desc}")
        return got


def _is_name(tok: str | None) -> bool:
    """
    Return True for any valid GraphQL Name token (including reserved words
    used as names, since GraphQL allows that in most positions).
    """
    if not tok:
        return False
    first = tok[0]
    return (first.isalpha() or first == '_') and all(
        ch.isalnum() or ch == '_' for ch in tok
    )


def _skip_balanced(stream: _Tokens, open_tok: str, close_tok: str) -> None:
    """
    Skip a balanced bracket block.  The caller has already consumed *open_tok*;
    this function consumes tokens until the matching *close_tok* is found.

    Only the specified open/close pair contributes to depth — other bracket
    types inside are passed through.  This is correct because each pair
    ({ }, ( )) is handled with a separate call.

    Raises LexError if EOF is reached before the block is closed.
    """
    depth = 1
    while depth:
        tok = stream.consume()
        if tok is None:
            raise LexError(f"unterminated {open_tok!r} block (no matching {close_tok!r})")
        if tok == open_tok:
            depth += 1
        elif tok == close_tok:
            depth -= 1


def _skip_directives(stream: _Tokens) -> None:
    """Skip zero or more @directiveName or @directiveName(args…) sequences."""
    while stream.peek() == '@':
        stream.consume()  # '@'
        if not _is_name(stream.peek()):
            got = repr(stream.peek()) if stream.peek() is not None else "EOF"
            raise LexError(f"expected directive name after '@', got {got}")
        stream.consume()  # directive name
        if stream.peek() == '(':
            stream.consume()  # '('
            _skip_balanced(stream, '(', ')')


def _skip_operation_tail(stream: _Tokens) -> None:
    """
    Skip the tail of a non-mutation operation definition (after its keyword):
      [Name]  [VariableDefinitions]  [Directives]  SelectionSet
    """
    # Optional operation name.
    # GraphQL allows any Name here, including reserved words used as names
    # (e.g. 'query mutation { … }' is a query *named* "mutation").
    # Punctuators ({, (, @) are never names, so _is_name disambiguates.
    if _is_name(stream.peek()):
        stream.consume()
    # Optional variable definitions: ( … )
    if stream.peek() == '(':
        stream.consume()  # '('
        _skip_balanced(stream, '(', ')')
    # Optional directives
    _skip_directives(stream)
    # Mandatory selection set
    if stream.peek() != '{':
        got = repr(stream.peek()) if stream.peek() is not None else "EOF"
        raise LexError(f"expected '{{' for operation body, got {got}")
    stream.consume()  # '{'
    _skip_balanced(stream, '{', '}')


def contains_mutation(query_str: str) -> bool:
    """
    Return True if any top-level operation in *query_str* is a mutation.
    Return False if all top-level operations are queries or subscriptions.

    Consumes the token stream lazily: for a document whose first definition
    is a mutation, only that one keyword token is read from the generator.

    Raises LexError if:
      - The document cannot be lexed (invalid characters, unterminated strings)
      - A top-level definition is structurally malformed
      - An unexpected top-level token is encountered (e.g. SDL keywords)

    Callers MUST treat LexError as a deny decision (fail-closed).
    """
    stream = _Tokens(_tokenize(query_str))

    while stream.peek() is not None:
        tok = stream.consume()

        if tok == '{':
            # Shorthand query: { SelectionSet } — implicitly a query operation.
            _skip_balanced(stream, '{', '}')

        elif tok in ('query', 'subscription'):
            _skip_operation_tail(stream)

        elif tok == 'mutation':
            return True  # found one — stop immediately, no further lexing needed

        elif tok == 'fragment':
            # Fragment name: required; must not be the keyword 'on'.
            if not _is_name(stream.peek()) or stream.peek() == 'on':
                got = repr(stream.peek()) if stream.peek() is not None else "EOF"
                raise LexError(f"expected fragment name (not 'on'), got {got}")
            stream.consume()  # fragment name
            stream.expect('on')
            if not _is_name(stream.peek()):
                got = repr(stream.peek()) if stream.peek() is not None else "EOF"
                raise LexError(f"expected type name after 'on', got {got}")
            stream.consume()  # type condition
            _skip_directives(stream)
            if stream.peek() != '{':
                got = repr(stream.peek()) if stream.peek() is not None else "EOF"
                raise LexError(f"expected '{{' for fragment body, got {got}")
            stream.consume()  # '{'
            _skip_balanced(stream, '{', '}')

        else:
            raise LexError(
                f"unexpected top-level token {tok!r} — expected 'query', 'mutation',"
                f" 'subscription', 'fragment', or '{{' (shorthand query)."
                f" Type-system / SDL definitions are not supported."
            )

    return False
