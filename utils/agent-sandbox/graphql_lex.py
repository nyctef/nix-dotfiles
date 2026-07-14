"""
graphql_lex.py — minimal GraphQL document lexer for operation-type detection.

Purpose: determine whether a GraphQL request document contains any mutation
operation, for use in the agent sandbox egress policy.  We do not execute,
validate, or fully parse the document — we only classify top-level operation
keywords.

Two-stage design
  1. _tokenize(text) -> list[str]
       Lexes the raw document string into a flat token list.
       String literals (regular and block/triple-quoted) and comments are
       consumed but not emitted, so keywords inside them cannot fool the
       classifier.  Numbers are consumed but not emitted.  Everything that is
       not valid GraphQL raises LexError immediately (fail-closed).

  2. contains_mutation(query_str) -> bool
       Walks the token list, parsing only the top-level definition skeleton:
       operation keyword / optional name / optional variable block / optional
       directives / body block.  Returns True the moment any mutation
       operation is found.  Raises LexError on any unexpected token or
       malformed structure; callers treat that as a deny decision.

Supported top-level definition forms (GraphQL June 2018 spec):
  { SelectionSet }                              shorthand anonymous query
  query/subscription [Name] [Vars] [Dirs] {}    read operation
  mutation          [Name] [Vars] [Dirs] {}     write operation -> True
  fragment Name on TypeName [Dirs] {}           fragment definition (skipped)

Type-system / SDL definitions (type, schema, directive, extend, …) are
intentionally not handled and raise LexError (fail-closed).
"""


class LexError(Exception):
    """Raised on any lex or parse failure.  Callers should treat this as deny."""


# ── Stage 1: Tokeniser ────────────────────────────────────────────────────────

# Single-character punctuators defined by the GraphQL spec (§2.1.8).
# '...' (spread/ellipsis) is three characters and is handled separately.
_PUNCT_CHARS = frozenset('!$&():=@[]{}|')


def _tokenize(text: str) -> list[str]:
    """
    Lex *text* into a flat list of string tokens.

    Emitted tokens:
      Names / keywords  — their literal text, e.g. 'mutation', 'on', 'User'
      Punctuators       — their literal text: { } ( ) [ ] @ ! $ & | : = ...

    Silently consumed (not emitted):
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
    tokens: list[str] = []
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
                    f"unexpected '{'.' * (3 - text[i:i+3].count('.'))}' at offset {i}:"
                    f" only '...' (spread) is valid GraphQL"
                )
            tokens.append('...')
            i += 3

        # ── Single-character punctuators (spec §2.1.8) ───────────────────
        elif c in _PUNCT_CHARS:
            tokens.append(c)
            i += 1

        # ── Names: [_A-Za-z][_0-9A-Za-z]*  (spec §2.1.9) ────────────────
        elif c.isalpha() or c == '_':
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == '_'):
                j += 1
            tokens.append(text[i:j])
            i = j

        # ── Number literals (int or float, optional leading minus) ────────
        # Consumed but NOT emitted — numbers only appear inside value
        # positions that the top-level parser skips with _skip_balanced.
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
            # intentionally not appended to tokens

        # ── Anything else is outside the GraphQL grammar ──────────────────
        else:
            raise LexError(f"unexpected character {c!r} at offset {i}")

    return tokens


# ── Stage 2: Top-level operation classifier ───────────────────────────────────

def _is_name(tok: str) -> bool:
    """
    Return True for any valid GraphQL Name token.

    This includes keywords used as names (e.g. 'on', 'query', 'mutation')
    since GraphQL allows all keywords as identifier names in most positions.
    """
    if not tok:
        return False
    first = tok[0]
    return (first.isalpha() or first == '_') and all(
        ch.isalnum() or ch == '_' for ch in tok
    )


def _skip_balanced(tokens: list[str], i: int, open_tok: str, close_tok: str) -> int:
    """
    Skip a balanced bracket block.  tokens[i] must equal *open_tok*.
    Returns the index immediately after the matching *close_tok*.

    Only tracks the specified open/close pair — other bracket types inside
    are passed through, which is correct because we handle each pair
    (parens for variable definitions, braces for selection sets) with
    separate calls to this function.

    Raises LexError if the block is unterminated.
    """
    if i >= len(tokens) or tokens[i] != open_tok:
        got = repr(tokens[i]) if i < len(tokens) else "EOF"
        raise LexError(f"expected {open_tok!r}, got {got}")
    depth = 1
    i += 1
    while i < len(tokens):
        t = tokens[i]
        if t == open_tok:
            depth += 1
        elif t == close_tok:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise LexError(
        f"unterminated {open_tok!r} block (no matching {close_tok!r})"
    )


def _skip_directives(tokens: list[str], i: int) -> int:
    """
    Skip zero or more directive applications: @name or @name(args…).
    Returns the updated index.
    Raises LexError if '@' is not followed by a valid name.
    """
    while i < len(tokens) and tokens[i] == '@':
        i += 1  # consume '@'
        if i >= len(tokens) or not _is_name(tokens[i]):
            got = repr(tokens[i]) if i < len(tokens) else "EOF"
            raise LexError(f"expected directive name after '@', got {got}")
        i += 1  # consume directive name
        if i < len(tokens) and tokens[i] == '(':
            i = _skip_balanced(tokens, i, '(', ')')
    return i


def _skip_operation_tail(tokens: list[str], i: int) -> int:
    """
    Skip the tail of a non-mutation operation definition after its keyword:
      [Name]  [VariableDefinitions]  [Directives]  SelectionSet

    Returns the index after the closing brace of the SelectionSet.
    Raises LexError if the structure is malformed.
    """
    # Optional operation name.
    # GraphQL allows any Name here, including reserved words used as names
    # (e.g. 'query mutation { … }' is a query *named* "mutation").
    # We distinguish a name from what follows by checking _is_name: the next
    # token after a name would be '(' for variables, '{' for the body, or
    # '@' for directives — none of which satisfy _is_name.
    if i < len(tokens) and _is_name(tokens[i]):
        i += 1

    # Optional variable definitions: ( … )
    if i < len(tokens) and tokens[i] == '(':
        i = _skip_balanced(tokens, i, '(', ')')

    # Optional directives
    i = _skip_directives(tokens, i)

    # Mandatory selection set: { … }
    if i >= len(tokens) or tokens[i] != '{':
        got = repr(tokens[i]) if i < len(tokens) else "EOF"
        raise LexError(f"expected '{{' for operation body, got {got}")
    return _skip_balanced(tokens, i, '{', '}')


def contains_mutation(query_str: str) -> bool:
    """
    Return True if any top-level operation in *query_str* is a mutation.
    Return False if all top-level operations are queries or subscriptions.

    Raises LexError if:
      - The document cannot be lexed (invalid characters, unterminated strings)
      - A top-level definition is structurally malformed
      - An unexpected top-level token is encountered (e.g. SDL keywords)

    Callers MUST treat LexError as a deny decision (fail-closed).
    """
    tokens = _tokenize(query_str)
    i = 0
    n = len(tokens)

    while i < n:
        tok = tokens[i]

        if tok == '{':
            # Shorthand query: { SelectionSet } — implicitly a query operation.
            i = _skip_balanced(tokens, i, '{', '}')

        elif tok in ('query', 'subscription'):
            # Read operation (subscriptions are treated as reads).
            i = _skip_operation_tail(tokens, i + 1)

        elif tok == 'mutation':
            # Found a mutation — no need to parse further.
            return True

        elif tok == 'fragment':
            i += 1
            # Fragment name: required; must not be the keyword 'on'
            # (spec says fragment names must not be 'on').
            if i >= n or not _is_name(tokens[i]) or tokens[i] == 'on':
                got = repr(tokens[i]) if i < n else "EOF"
                raise LexError(f"expected fragment name (not 'on'), got {got}")
            i += 1  # consume fragment name
            # 'on' keyword
            if i >= n or tokens[i] != 'on':
                got = repr(tokens[i]) if i < n else "EOF"
                raise LexError(f"expected 'on' after fragment name, got {got}")
            i += 1  # consume 'on'
            # Named type (type condition)
            if i >= n or not _is_name(tokens[i]):
                got = repr(tokens[i]) if i < n else "EOF"
                raise LexError(f"expected type name after 'on', got {got}")
            i += 1  # consume type name
            # Optional directives
            i = _skip_directives(tokens, i)
            # Mandatory selection set
            if i >= n or tokens[i] != '{':
                got = repr(tokens[i]) if i < n else "EOF"
                raise LexError(f"expected '{{' for fragment body, got {got}")
            i = _skip_balanced(tokens, i, '{', '}')

        else:
            raise LexError(
                f"unexpected top-level token {tok!r} — expected 'query', 'mutation',"
                f" 'subscription', 'fragment', or '{{' (shorthand query)."
                f" Type-system / SDL definitions are not supported."
            )

    return False
