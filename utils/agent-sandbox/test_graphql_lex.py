"""
Unit tests for graphql_lex.py.

Run with:  python -m pytest test_graphql_lex.py -v
       or: python -m unittest test_graphql_lex -v
"""

import unittest
from graphql_lex import LexError, _tokenize, contains_mutation


# ── Tokeniser tests ───────────────────────────────────────────────────────────

class TestTokenize(unittest.TestCase):

    # ── Basics ────────────────────────────────────────────────────────────────

    def test_empty_string(self):
        self.assertEqual(list(_tokenize("")), [])

    def test_whitespace_only(self):
        self.assertEqual(list(_tokenize("   \t\n\r  ")), [])

    def test_comma_is_insignificant(self):
        # commas are whitespace in GraphQL
        self.assertEqual(list(_tokenize("a,b,c")), ["a", "b", "c"])

    def test_unicode_bom_ignored(self):
        self.assertEqual(list(_tokenize("\ufeffquery")), ["query"])

    # ── Names ─────────────────────────────────────────────────────────────────

    def test_single_name(self):
        self.assertEqual(list(_tokenize("viewer")), ["viewer"])

    def test_multiple_names(self):
        self.assertEqual(list(_tokenize("query mutation fragment")), ["query", "mutation", "fragment"])

    def test_name_with_underscore(self):
        self.assertEqual(list(_tokenize("__typename")), ["__typename"])

    def test_name_with_digits(self):
        self.assertEqual(list(_tokenize("field2")), ["field2"])

    def test_keywords_are_names(self):
        # All keywords are valid names in GraphQL
        for kw in ("query", "mutation", "subscription", "fragment", "on",
                   "true", "false", "null"):
            self.assertIn(kw, list(_tokenize(kw)))

    # ── Punctuators ───────────────────────────────────────────────────────────

    def test_braces(self):
        self.assertEqual(list(_tokenize("{}")), ["{", "}"])

    def test_parens(self):
        self.assertEqual(list(_tokenize("()")), ["(", ")"])

    def test_brackets(self):
        self.assertEqual(list(_tokenize("[]")), ["[", "]"])

    def test_single_char_punctuators(self):
        self.assertEqual(
            list(_tokenize("! $ & : = @ | ")),
            ["!", "$", "&", ":", "=", "@", "|"],
        )

    def test_spread_operator(self):
        self.assertEqual(list(_tokenize("...")), ["..."])

    def test_spread_inside_selection(self):
        self.assertEqual(
            list(_tokenize("{ ...F }")),
            ["{", "...", "F", "}"],
        )

    # ── Comments ──────────────────────────────────────────────────────────────

    def test_comment_entirely_stripped(self):
        self.assertEqual(list(_tokenize("# this is a comment")), [])

    def test_comment_before_token(self):
        self.assertEqual(list(_tokenize("# comment\nquery")), ["query"])

    def test_comment_after_token(self):
        self.assertEqual(list(_tokenize("query # comment")), ["query"])

    def test_comment_containing_mutation_keyword(self):
        # 'mutation' inside a comment must not be detected
        self.assertEqual(list(_tokenize("# mutation\nquery")), ["query"])

    def test_comment_does_not_absorb_next_line(self):
        result = list(_tokenize("# line1\nfoo\n# line2\nbar"))
        self.assertEqual(result, ["foo", "bar"])

    # ── String literals (regular) ─────────────────────────────────────────────

    def test_empty_string_literal(self):
        self.assertEqual(list(_tokenize('""')), [])

    def test_string_literal_stripped(self):
        self.assertEqual(list(_tokenize('"hello world"')), [])

    def test_string_containing_mutation_keyword(self):
        self.assertEqual(list(_tokenize('"mutation"')), [])

    def test_string_with_escaped_quote(self):
        self.assertEqual(list(_tokenize(r'"say \"hello\""')), [])

    def test_string_with_escaped_backslash(self):
        self.assertEqual(list(_tokenize(r'"path\\file"')), [])

    def test_string_with_escaped_unicode(self):
        self.assertEqual(list(_tokenize(r'"\u0041"')), [])

    def test_string_adjacent_to_name(self):
        # Names on either side of a string are still yielded
        self.assertEqual(list(_tokenize('foo "ignored" bar')), ["foo", "bar"])

    def test_unterminated_string_eof(self):
        with self.assertRaises(LexError):
            list(_tokenize('"unclosed'))

    def test_unterminated_string_newline(self):
        # Raw newline inside a regular string is illegal
        with self.assertRaises(LexError):
            list(_tokenize('"unclosed\n"'))

    def test_unterminated_string_carriage_return(self):
        with self.assertRaises(LexError):
            list(_tokenize('"unclosed\r"'))

    # ── Block string literals ─────────────────────────────────────────────────

    def test_empty_block_string(self):
        self.assertEqual(list(_tokenize('""""""')), [])

    def test_block_string_simple(self):
        self.assertEqual(list(_tokenize('"""hello"""')), [])

    def test_block_string_multiline(self):
        self.assertEqual(list(_tokenize('"""line1\nline2\nline3"""')), [])

    def test_block_string_containing_mutation_keyword(self):
        self.assertEqual(list(_tokenize('"""mutation"""')), [])

    def test_block_string_containing_double_quote(self):
        self.assertEqual(list(_tokenize('"""say "hi" please"""')), [])

    def test_block_string_escaped_triple_quote(self):
        # \""" inside a block string is the escape for a literal """
        self.assertEqual(list(_tokenize('"""has \\"""escaped"""')), [])

    def test_block_string_adjacent_to_name(self):
        self.assertEqual(list(_tokenize('foo """ignored""" bar')), ["foo", "bar"])

    def test_unterminated_block_string(self):
        with self.assertRaises(LexError):
            list(_tokenize('"""unclosed'))

    def test_unterminated_block_string_two_quotes(self):
        with self.assertRaises(LexError):
            list(_tokenize('"""unclosed""'))

    # ── Number literals ───────────────────────────────────────────────────────

    def test_integer_not_yielded(self):
        self.assertEqual(list(_tokenize("42")), [])

    def test_zero_not_yielded(self):
        self.assertEqual(list(_tokenize("0")), [])

    def test_negative_integer_not_yielded(self):
        self.assertEqual(list(_tokenize("-42")), [])

    def test_float_not_yielded(self):
        self.assertEqual(list(_tokenize("3.14")), [])

    def test_float_exponent_not_yielded(self):
        self.assertEqual(list(_tokenize("1.5e10")), [])

    def test_float_uppercase_exponent(self):
        self.assertEqual(list(_tokenize("2.0E+3")), [])

    def test_float_negative_exponent(self):
        self.assertEqual(list(_tokenize("1e-5")), [])

    def test_number_in_argument(self):
        # Numbers inside arguments are skipped; surrounding tokens still yielded
        self.assertEqual(
            list(_tokenize("{ foo(n: 42) }")),
            ["{", "foo", "(", "n", ":", ")", "}"],
        )

    def test_invalid_exponent_raises(self):
        with self.assertRaises(LexError):
            list(_tokenize("1e"))  # no digit after exponent

    # ── Error cases ───────────────────────────────────────────────────────────

    def test_lone_dot_raises(self):
        with self.assertRaises(LexError):
            list(_tokenize("."))

    def test_two_dots_raises(self):
        with self.assertRaises(LexError):
            list(_tokenize(".."))

    def test_dot_then_name_raises(self):
        with self.assertRaises(LexError):
            list(_tokenize(".field"))

    def test_unknown_char_caret(self):
        with self.assertRaises(LexError):
            list(_tokenize("^"))

    def test_unknown_char_tilde(self):
        with self.assertRaises(LexError):
            list(_tokenize("~"))

    def test_unknown_char_percent(self):
        with self.assertRaises(LexError):
            list(_tokenize("%"))

    def test_unknown_char_mid_document(self):
        with self.assertRaises(LexError):
            list(_tokenize("query { foo^ }"))

    def test_lone_minus_raises(self):
        # '-' not followed by a digit is not valid GraphQL
        with self.assertRaises(LexError):
            list(_tokenize("query - foo"))

    # ── Realistic combined cases ──────────────────────────────────────────────

    def test_simple_query_tokens(self):
        result = list(_tokenize("query { viewer { login } }"))
        self.assertEqual(result, ["query", "{", "viewer", "{", "login", "}", "}"])

    def test_query_with_variable_tokens(self):
        result = list(_tokenize("query($id: ID!) { user(id: $id) { name } }"))
        self.assertEqual(result, [
            "query", "(", "$", "id", ":", "ID", "!", ")",
            "{", "user", "(", "id", ":", "$", "id", ")", "{", "name", "}", "}",
        ])

    def test_mutation_tokens(self):
        result = list(_tokenize("mutation { createFoo { id } }"))
        self.assertEqual(result, ["mutation", "{", "createFoo", "{", "id", "}", "}"])

    def test_directive_tokens(self):
        result = list(_tokenize("query @skip(if: true) { viewer { login } }"))
        self.assertEqual(result, [
            "query", "@", "skip", "(", "if", ":", "true", ")",
            "{", "viewer", "{", "login", "}", "}",
        ])


# ── contains_mutation tests ───────────────────────────────────────────────────

class TestContainsMutation(unittest.TestCase):

    # ── Queries → False ───────────────────────────────────────────────────────

    def test_shorthand_query(self):
        self.assertFalse(contains_mutation("{ viewer { login } }"))

    def test_explicit_query_keyword(self):
        self.assertFalse(contains_mutation("query { viewer { login } }"))

    def test_named_query(self):
        self.assertFalse(contains_mutation("query GetUser { user { id } }"))

    def test_subscription(self):
        # Subscriptions are reads; treated the same as queries.
        self.assertFalse(contains_mutation("subscription { newMessages { id } }"))

    def test_named_subscription(self):
        self.assertFalse(contains_mutation("subscription OnMessage { newMessages { id } }"))

    def test_query_with_variable(self):
        self.assertFalse(contains_mutation(
            "query($id: ID!) { user(id: $id) { name } }"
        ))

    def test_query_with_nonnull_list_variable(self):
        self.assertFalse(contains_mutation(
            "query($ids: [ID!]!) { users(ids: $ids) { name } }"
        ))

    def test_query_with_default_scalar(self):
        self.assertFalse(contains_mutation(
            'query($limit: Int = 10) { items(limit: $limit) { id } }'
        ))

    def test_query_with_default_input_object(self):
        # Default value is an input object literal: { … } — must not confuse the
        # balanced-brace skipper for the operation body.
        self.assertFalse(contains_mutation(
            'query($opts: Opts = {page: 1, size: 20}) { items(opts: $opts) { id } }'
        ))

    def test_query_with_directive(self):
        self.assertFalse(contains_mutation(
            "query @live { viewer { login } }"
        ))

    def test_query_with_directive_with_arg(self):
        self.assertFalse(contains_mutation(
            "query @skip(if: false) { viewer { login } }"
        ))

    def test_query_with_multiple_directives(self):
        self.assertFalse(contains_mutation(
            "query @live @defer { viewer { login } }"
        ))

    def test_query_with_name_and_variables_and_directive(self):
        self.assertFalse(contains_mutation(
            "query GetUser($id: ID!) @log { user(id: $id) { name email } }"
        ))

    def test_multiple_queries(self):
        self.assertFalse(contains_mutation(
            "query Q1 { a { b } } query Q2 { c { d } }"
        ))

    def test_shorthand_then_named_query(self):
        self.assertFalse(contains_mutation(
            "{ viewer { login } } query Named { repo { id } }"
        ))

    # ── Fragments → False (no mutation operation) ─────────────────────────────

    def test_fragment_alone(self):
        self.assertFalse(contains_mutation(
            "fragment UserFields on User { login email }"
        ))

    def test_fragment_and_query(self):
        self.assertFalse(contains_mutation(
            "fragment F on User { name } query { viewer { ...F } }"
        ))

    def test_query_then_fragment(self):
        self.assertFalse(contains_mutation(
            "query { viewer { ...F } } fragment F on User { name }"
        ))

    def test_fragment_with_directive(self):
        self.assertFalse(contains_mutation(
            "fragment F on User @live { name }"
        ))

    # ── 'mutation' keyword appearing as non-operation → False ─────────────────

    def test_mutation_as_field_name_in_query(self):
        # 'mutation' is a valid GraphQL field name; it can appear inside a query
        # selection set.  The tokeniser yields it, but at depth > 0 (inside the
        # selection-set brace block) the top-level parser never sees it.
        self.assertFalse(contains_mutation("query { mutation { id } }"))

    def test_mutation_as_nested_field(self):
        self.assertFalse(contains_mutation(
            "query { viewer { mutation { id } } }"
        ))

    def test_mutation_as_operation_name(self):
        # 'query mutation { … }' is technically a query named "mutation", but we
        # can't distinguish that from the keyword without structural parsing.
        # Acceptable false positive — fail-closed, and nobody names queries "mutation".
        self.assertTrue(contains_mutation("query mutation { viewer { login } }"))

    def test_mutation_in_string_argument(self):
        self.assertFalse(contains_mutation(
            'query { foo(arg: "mutation createFoo { id }") { id } }'
        ))

    def test_mutation_in_block_string_argument(self):
        self.assertFalse(contains_mutation(
            'query { foo(desc: """mutation CreateFoo { id }""") { id } }'
        ))

    def test_mutation_in_line_comment(self):
        self.assertFalse(contains_mutation(
            "# mutation DoThing { createFoo { id } }\nquery { viewer { login } }"
        ))

    def test_mutation_as_fragment_name(self):
        # 'mutation' at depth 0 as a fragment name is a false positive.
        # Acceptable — fail-closed, and nobody names fragments "mutation".
        self.assertTrue(contains_mutation(
            "fragment mutation on User { login } query { viewer { ...mutation } }"
        ))

    def test_mutation_as_type_condition(self):
        # Type condition after 'on' can also be 'Mutation' (a schema type name)
        self.assertFalse(contains_mutation(
            "fragment F on Mutation { createFoo { id } }"
        ))

    # ── Mutations → True ──────────────────────────────────────────────────────

    def test_anonymous_mutation(self):
        self.assertTrue(contains_mutation("mutation { createFoo { id } }"))

    def test_named_mutation(self):
        self.assertTrue(contains_mutation("mutation CreateFoo { createFoo { id } }"))

    def test_mutation_with_variable(self):
        self.assertTrue(contains_mutation(
            "mutation($id: ID!) { deleteFoo(id: $id) { success } }"
        ))

    def test_mutation_with_nonnull_list_variable(self):
        self.assertTrue(contains_mutation(
            "mutation($ids: [ID!]!) { deleteMany(ids: $ids) { count } }"
        ))

    def test_mutation_with_input_object_variable(self):
        self.assertTrue(contains_mutation(
            "mutation($input: CreateFooInput!) { createFoo(input: $input) { id } }"
        ))

    def test_mutation_with_directive(self):
        self.assertTrue(contains_mutation(
            "mutation @live { createFoo { id } }"
        ))

    def test_mutation_with_name_and_variables_and_directive(self):
        self.assertTrue(contains_mutation(
            "mutation CreateFoo($input: CreateFooInput!) @log { createFoo(input: $input) { id } }"
        ))

    def test_query_then_mutation(self):
        # The mutation follows a query — must still be detected.
        self.assertTrue(contains_mutation(
            "query { viewer { login } } mutation { createFoo { id } }"
        ))

    def test_mutation_then_query(self):
        # Short-circuits on the first mutation.
        self.assertTrue(contains_mutation(
            "mutation { createFoo { id } } query { viewer { login } }"
        ))

    def test_fragment_then_mutation(self):
        self.assertTrue(contains_mutation(
            "fragment F on Foo { id } mutation { createFoo { ...F } }"
        ))

    def test_mutation_after_two_queries(self):
        self.assertTrue(contains_mutation(
            "query Q1 { a { b } } query Q2 { c { d } } mutation M { e { f } }"
        ))

    def test_mutation_with_deeply_nested_body(self):
        # Deeply nested braces; depth tracking must count them all.
        self.assertTrue(contains_mutation(
            "mutation { a { b { c { d { e { id } } } } } }"
        ))

    def test_mutation_with_input_object_argument(self):
        # Inline input object in the argument list contains { } — must not
        # confuse the brace depth tracker for the operation body.
        # (Not applicable here since we return True at 'mutation' immediately,
        #  but good to confirm no crash.)
        self.assertTrue(contains_mutation(
            'mutation { createFoo(input: {title: "hi", count: 3}) { id } }'
        ))

    # ── Fail-closed: LexError on lex failures ───────────────────────────────
    # Structural oddities (missing body, SDL, etc.) are not validated — they
    # just return False, and GitHub will reject the malformed document itself.
    # Only the lexer's error cases propagate as LexError.

    def test_invalid_character_in_document(self):
        with self.assertRaises(LexError):
            contains_mutation("query { foo^ }")

    def test_unterminated_string_in_query(self):
        with self.assertRaises(LexError):
            contains_mutation('query { foo(x: "unclosed) { id } }')

    def test_unterminated_block_string_in_query(self):
        with self.assertRaises(LexError):
            contains_mutation('query { foo(x: """unclosed) { id } }')


if __name__ == "__main__":
    unittest.main()
