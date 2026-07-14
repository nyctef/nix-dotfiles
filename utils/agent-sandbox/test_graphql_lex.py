"""
Unit tests for graphql_lex.py.

Run with:  python -m pytest test_graphql_lex.py -v
       or: python -m unittest test_graphql_lex -v
"""

import unittest
from graphql_lex import LexError, _tokenize, contains_mutation


# ── Tokeniser tests ───────────────────────────────────────────────────────────
# _tokenize only yields '{', '}', and the name 'mutation'.
# Everything else (other names, punctuators, numbers) is consumed silently.
# Unterminated strings raise LexError; everything else is skipped.

class TestTokenize(unittest.TestCase):

    # ── What IS yielded ───────────────────────────────────────────────────────

    def test_braces_yielded(self):
        self.assertEqual(list(_tokenize("{}")), ["{", "}"])

    def test_mutation_name_yielded(self):
        self.assertEqual(list(_tokenize("mutation")), ["mutation"])

    def test_mutation_among_other_names(self):
        # Other names are consumed but not yielded
        self.assertEqual(list(_tokenize("query mutation fragment")), ["mutation"])

    def test_realistic_mutation(self):
        result = list(_tokenize("mutation { createFoo { id } }"))
        self.assertEqual(result, ["mutation", "{", "{", "}", "}"])

    def test_realistic_query(self):
        # No 'mutation' token — only braces
        result = list(_tokenize("query { viewer { login } }"))
        self.assertEqual(result, ["{", "{", "}", "}"])

    # ── What is NOT yielded ───────────────────────────────────────────────────

    def test_empty_string(self):
        self.assertEqual(list(_tokenize("")), [])

    def test_whitespace(self):
        self.assertEqual(list(_tokenize("   \t\n\r  ")), [])

    def test_other_names_not_yielded(self):
        self.assertEqual(list(_tokenize("query viewer subscription fragment")), [])

    def test_punctuators_not_yielded(self):
        self.assertEqual(list(_tokenize("( ) [ ] @ ! $ & | : = ...")), [])

    def test_numbers_not_yielded(self):
        self.assertEqual(list(_tokenize("42 3.14 -7 1e10")), [])

    # ── String literals — content must not escape ─────────────────────────────

    def test_string_containing_mutation(self):
        self.assertEqual(list(_tokenize('"mutation"')), [])

    def test_string_containing_braces(self):
        self.assertEqual(list(_tokenize('"{  }"')), [])

    def test_string_with_escape(self):
        self.assertEqual(list(_tokenize(r'"say \"mutation\""')), [])

    def test_unterminated_string_eof(self):
        with self.assertRaises(LexError):
            list(_tokenize('"unclosed'))

    def test_unterminated_string_newline(self):
        with self.assertRaises(LexError):
            list(_tokenize('"unclosed\n"'))

    def test_unterminated_string_carriage_return(self):
        with self.assertRaises(LexError):
            list(_tokenize('"unclosed\r"'))

    # ── Block string literals — content must not escape ───────────────────────

    def test_block_string_containing_mutation(self):
        self.assertEqual(list(_tokenize('"""mutation"""')), [])

    def test_block_string_containing_braces(self):
        self.assertEqual(list(_tokenize('"""{ mutation }"""')), [])

    def test_block_string_escaped_triple_quote(self):
        # \""" is the escape for """ inside a block string; the block must
        # not be closed early, letting content escape into the token stream.
        self.assertEqual(list(_tokenize('"""has \\"""escaped"""')), [])

    def test_unterminated_block_string(self):
        with self.assertRaises(LexError):
            list(_tokenize('"""unclosed'))

    def test_unterminated_block_string_two_quotes(self):
        with self.assertRaises(LexError):
            list(_tokenize('"""unclosed""'))

    # ── Comments ──────────────────────────────────────────────────────────────

    def test_comment_stripped(self):
        self.assertEqual(list(_tokenize("# mutation { }")), [])

    def test_comment_does_not_absorb_next_line(self):
        # mutation on the line after the comment must still be detected
        self.assertEqual(list(_tokenize("# comment\nmutation")), ["mutation"])


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
        # Unknown characters are skipped; only unterminated strings raise.
        self.assertFalse(contains_mutation("query { foo^ }"))

    def test_unterminated_string_in_query(self):
        with self.assertRaises(LexError):
            contains_mutation('query { foo(x: "unclosed) { id } }')

    def test_unterminated_block_string_in_query(self):
        with self.assertRaises(LexError):
            contains_mutation('query { foo(x: """unclosed) { id } }')


if __name__ == "__main__":
    unittest.main()
