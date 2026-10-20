"""Bounded long-text splitting without model libraries or private text."""

import importlib.util
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("_chunking_text", ROOT / "omnivoice/utils/text.py")
TEXT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TEXT)


class TextChunkingTests(unittest.TestCase):
    def split(self, text, limit, minimum=3):
        chunks = TEXT.chunk_text_punctuation(text, limit, minimum)
        self.assertTrue(chunks)
        self.assertTrue(all(chunk.strip() == chunk and chunk for chunk in chunks))
        self.assertEqual(re.sub(r"\s+", "", "".join(chunks)), re.sub(r"\s+", "", text))
        return chunks

    def test_long_sentence_without_punctuation_splits_at_words(self):
        text = " ".join(["alpha", "beta", "gamma", "delta"] * 30)
        chunks = self.split(text, 40)
        self.assertGreater(len(chunks), 15)
        self.assertTrue(all(len(chunk) <= 40 for chunk in chunks))
        self.assertEqual(" ".join(chunks).split(), text.split())

    def test_unbroken_cjk_and_long_words_have_a_bounded_fallback(self):
        for text in ("一段没有标点的连续中文文本" * 20, "A" * 1000):
            with self.subTest(text=text[:15]):
                chunks = self.split(text, 37)
                self.assertTrue(all(len(chunk) <= 37 for chunk in chunks))
                self.assertEqual("".join(chunks), text)

    def test_inline_control_and_pronunciation_spans_are_indivisible(self):
        for tag in ("[laughter]", "[B EY1 S]", "[unknown.with punctuation]", "[" + "A " * 30 + "]"):
            text = "first second " + tag + " third fourth fifth sixth seventh eighth ninth"
            with self.subTest(tag=tag):
                chunks = self.split(text, 15)
                self.assertTrue(any(tag in chunk for chunk in chunks))
                self.assertTrue(all(chunk.count("[") == chunk.count("]") for chunk in chunks))
                self.assertEqual(sum(chunk.count(tag) for chunk in chunks), 1)
                self.assertTrue(all(len(chunk) <= 15 or chunk == tag for chunk in chunks))

    def test_existing_short_sentences_and_abbreviations_keep_grouping(self):
        self.assertEqual(
            TEXT.chunk_text_punctuation("Mr. Jones! Hello. Bye.", 15), ["Mr. Jones!", "Hello. Bye."]
        )
        self.assertEqual(TEXT.chunk_text_punctuation("Short input.", 40), ["Short input."])

    def test_multidot_abbreviations_are_not_split_at_their_first_period(self):
        chunks = self.split("use i.e. examples e.g. details", 6)
        self.assertTrue(any("i.e." in chunk for chunk in chunks))
        self.assertTrue(any("e.g." in chunk for chunk in chunks))

    def test_small_final_fragment_does_not_break_the_limit(self):
        chunks = self.split("1234567890 12", 10)
        self.assertTrue(all(len(chunk) <= 10 for chunk in chunks))

    def test_long_whitespace_blocks_do_not_glue_neighboring_words(self):
        for whitespace in (" " * 20, "\n" * 20, " \t\n" * 20):
            text = "alpha" + whitespace + "beta gamma"
            with self.subTest(whitespace=repr(whitespace)):
                chunks = self.split(text, 10)
                self.assertTrue(all(len(chunk) <= 10 for chunk in chunks))
                self.assertEqual(" ".join(chunks).split(), text.split())

    def test_empty_or_whitespace_text_remains_empty(self):
        self.assertEqual(TEXT.chunk_text_punctuation("", 10), [])
        self.assertEqual(TEXT.chunk_text_punctuation(" \n\t", 10), [])

    def test_invalid_chunk_limits_fail_explicitly(self):
        for limit in (0, -1, True, 1.5, "5"):
            with self.subTest(limit=limit), self.assertRaises(ValueError):
                TEXT.chunk_text_punctuation("Text.", limit)


if __name__ == "__main__":
    unittest.main()
