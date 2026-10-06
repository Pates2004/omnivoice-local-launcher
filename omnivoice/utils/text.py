#!/usr/bin/env python3
# Copyright    2026  Xiaomi Corp.        (authors:  Han Zhu)
#
# See ../../LICENSE for clarification regarding multiple authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Text processing utilities for TTS inference.

Provides:
- ``chunk_text_punctuation()``: Splits long text into model-friendly chunks at
  sentence boundaries, with abbreviation-aware punctuation splitting.
- ``add_punctuation()``: Appends missing end punctuation (Chinese or English).
- ``normalize_text()``: Optional text normalization (numbers, dates, currency,
  etc.) into their spoken form, while preserving inline control syntax.
"""

import importlib.util
import logging
import re
from typing import Callable, List, Optional

logger = logging.getLogger(__name__)


SPLIT_PUNCTUATION = set(".,;:!?。，；：！？")
CLOSING_MARKS = set("\"'“”‘’）]》>」】")

END_PUNCTUATION = {
    ";",
    ":",
    ",",
    ".",
    "!",
    "?",
    "…",
    ")",
    "]",
    "}",
    '"',
    "'",
    "“",
    "”",
    "‘",
    "’",
    "；",
    "：",
    "，",
    "。",
    "！",
    "？",
    "、",
    "……",
    "）",
    "】",
}


ABBREVIATIONS = {
    "Mr.",
    "Mrs.",
    "Ms.",
    "Dr.",
    "Prof.",
    "Sr.",
    "Jr.",
    "Rev.",
    "Fr.",
    "Hon.",
    "Pres.",
    "Gov.",
    "Capt.",
    "Gen.",
    "Sen.",
    "Rep.",
    "Col.",
    "Maj.",
    "Lt.",
    "Cmdr.",
    "Sgt.",
    "Cpl.",
    "Co.",
    "Corp.",
    "Inc.",
    "Ltd.",
    "Est.",
    "Dept.",
    "St.",
    "Ave.",
    "Blvd.",
    "Rd.",
    "Mt.",
    "Ft.",
    "No.",
    "Jan.",
    "Feb.",
    "Mar.",
    "Apr.",
    "Aug.",
    "Sep.",
    "Sept.",
    "Oct.",
    "Nov.",
    "Dec.",
    "i.e.",
    "e.g.",
    "vs.",
    "Vs.",
    "Etc.",
    "approx.",
    "fig.",
    "def.",
}


def chunk_text_punctuation(
    text: str,
    chunk_len: int,
    min_chunk_len: Optional[int] = None,
) -> List[str]:
    """
    Splits the input tokens list into chunks according to punctuations,
    avoiding splits on common abbreviations (e.g., Mr., No.).
    """

    # 1. Split the tokens according to punctuations.
    sentences = []
    current_sentence = []

    tokens_list = list(text)

    for token in tokens_list:
        # If the first token of current sentence is punctuation,
        # append it to the end of the previous sentence.
        if (
            len(current_sentence) == 0
            and len(sentences) != 0
            and (token in SPLIT_PUNCTUATION or token in CLOSING_MARKS)
        ):
            sentences[-1].append(token)
        # Otherwise, append the current token to the current sentence.
        else:
            current_sentence.append(token)

            # Split the sentence in positions of punctuations.
            if token in SPLIT_PUNCTUATION:
                is_abbreviation = False

                if token == ".":
                    temp_str = "".join(current_sentence).strip()
                    if temp_str:
                        last_word = temp_str.split()[-1]
                        if last_word in ABBREVIATIONS:
                            is_abbreviation = True

                if not is_abbreviation:
                    sentences.append(current_sentence)
                    current_sentence = []
    # Assume the last few tokens are also a sentence
    if len(current_sentence) != 0:
        sentences.append(current_sentence)

    # 2. Merge short sentences.
    merged_chunks = []
    current_chunk = []
    for sentence in sentences:
        if len(current_chunk) + len(sentence) <= chunk_len:
            current_chunk.extend(sentence)
        else:
            if len(current_chunk) > 0:
                merged_chunks.append(current_chunk)
            current_chunk = sentence

    if len(current_chunk) > 0:
        merged_chunks.append(current_chunk)

    # 4. Post-process: Check for undersized chunks and merge them
    #  with the previous chunk or next chunk (if it's the first chunk).
    if min_chunk_len is not None:
        first_chunk_short_flag = len(merged_chunks) > 0 and len(merged_chunks[0]) < min_chunk_len
        final_chunks = []
        for i, chunk in enumerate(merged_chunks):
            if i == 1 and first_chunk_short_flag:
                final_chunks[-1].extend(chunk)
            else:
                if len(chunk) >= min_chunk_len:
                    final_chunks.append(chunk)
                else:
                    if len(final_chunks) == 0:
                        final_chunks.append(chunk)
                    else:
                        final_chunks[-1].extend(chunk)
    else:
        final_chunks = merged_chunks

    chunk_strings = ["".join(chunk).strip() for chunk in final_chunks if "".join(chunk).strip()]
    return chunk_strings


def add_punctuation(text: str):
    """Add punctuation if there is not in the end of text"""
    text = text.strip()

    if not text:
        return text

    if text[-1] not in END_PUNCTUATION:
        is_chinese = any("\u4e00" <= char <= "\u9fff" for char in text)

        text += "。" if is_chinese else "."

    return text


# ---------------------------------------------------------------------------
# Optional text normalization (opt-in via ``generate(normalize_text=True)``)
# ---------------------------------------------------------------------------
#
# Arabic numerals, dates, currency, etc. are converted into their spoken form
# so the model reads them correctly (e.g. "2345" -> "twenty three forty five",
# "199" -> the Chinese reading). Chinese/English go through WeTextProcessing;
# any other language falls back to ``num2words`` for bare integers when
# available.
#
# The OmniVoice inline control syntax must survive normalization:
#   * bracketed non-verbal tags, e.g. ``[laughter]``, ``[sigh]``;
#   * bracketed CMU pronunciation overrides, e.g. ``[B EY1 S]`` -- the stress
#     digit would otherwise be read as a number;
#   * Chinese pinyin tone markers (uppercase pinyin + tone digit) -- likewise.
# Protected spans are held out and re-inserted verbatim around normalization.

# Any ``[...]`` span covers both non-verbal tags and CMU pronunciation.
_BRACKET_TAG_RE = re.compile(r"\[[^\[\]]*\]")
# Uppercase pinyin followed by a tone digit 1-5 (Chinese pronunciation control).
_PINYIN_TONE_RE = re.compile(r"[A-Z]+[1-5]")
_CJK_RE = re.compile(r"[\u4e00-\u9fff]")
_INTEGER_OR_COMPOUND_RE = re.compile(
    r"(?P<compound>(?<!\w)[+-]?\d+(?:(?:[.,:/-]|\s+(?=\d{3}\b))\d+)+(?!\w))"
    r"|(?P<integer>(?<![\w.,:/+\-$€£¥'’])[+-]?\d+(?!\w|[.,:/\-'’]\d|[%$€£¥]))"
)

_TN_INSTALL_MSG = (
    "Full Chinese/English normalization requires optional WeTextProcessing and a working pynini "
    "runtime. Native Windows pynini wheels are not bundled. Basic integer normalization uses "
    "num2words for its supported languages instead."
)


class TextNormalizationError(ValueError):
    """A normalization failure with a stable message key for localized interfaces."""

    def __init__(self, message_key, language, detail=None):
        self.message_key = message_key
        self.language = language
        messages = {
            "normalization_missing_dependency": (
                f"Text normalization dependencies are unavailable for language '{language}'. "
                "Basic normalization requires num2words; Chinese may require optional "
                "WeTextProcessing with a working pynini runtime."
            ),
            "normalization_unsupported_language": (
                f"Text normalization is not supported for language '{language}' by the installed "
                "normalization libraries."
            ),
            "normalization_failed": f"Text normalization failed for language '{language}'.",
        }
        super().__init__(detail or messages[message_key])


# Normalizer construction builds FSTs and is comparatively slow, so instances
# are cached per language for the lifetime of the process.
_ZH_NORMALIZER = None
_EN_NORMALIZER = None


def _get_zh_normalizer():
    global _ZH_NORMALIZER
    if _ZH_NORMALIZER is None:
        try:
            from tn.chinese.normalizer import Normalizer
        except ImportError as e:  # pragma: no cover - depends on optional extra
            raise ImportError(_TN_INSTALL_MSG) from e
        # Conservative flags: normalize numbers/symbols only. Keep interjections
        # and erhua (they are spoken), keep the user's original characters, and
        # do not delete or rewrite anything beyond numeric/symbolic tokens.
        _ZH_NORMALIZER = Normalizer(
            remove_interjections=False,
            remove_erhua=False,
            traditional_to_simple=False,
            remove_puncts=False,
            full_to_half=False,
        )
    return _ZH_NORMALIZER


def _get_en_normalizer():
    global _EN_NORMALIZER
    if _EN_NORMALIZER is None:
        try:
            from tn.english.normalizer import Normalizer
        except ImportError as e:  # pragma: no cover - depends on optional extra
            raise ImportError(_TN_INSTALL_MSG) from e
        _EN_NORMALIZER = Normalizer()
    return _EN_NORMALIZER


def _has_wetext(language):
    if (language == "zh" and _ZH_NORMALIZER is not None) or (
        language == "en" and _EN_NORMALIZER is not None
    ):
        return True
    try:
        return all(importlib.util.find_spec(name) is not None for name in ("tn", "pynini"))
    except (ImportError, ValueError):
        return False


def _check_num2words_support(language):
    try:
        from num2words import CONVERTER_CLASSES
    except (ImportError, OSError) as exc:
        raise TextNormalizationError("normalization_missing_dependency", language) from exc
    except Exception as exc:
        raise TextNormalizationError("normalization_failed", language) from exc
    if language in CONVERTER_CLASSES:
        return language
    locale = re.fullmatch(r"([a-z]{2})[_-]([a-z]{2,3})", language, flags=re.IGNORECASE)
    if locale:
        base, region = locale.groups()
        regional_code = f"{base.lower()}_{region.upper()}"
        if regional_code in CONVERTER_CLASSES:
            return regional_code
        if base.lower() in CONVERTER_CLASSES:
            return base.lower()
    key = (
        "normalization_missing_dependency"
        if language == "zh"
        else "normalization_unsupported_language"
    )
    raise TextNormalizationError(key, language)


def check_normalization_support(language: Optional[str]) -> str:
    """Return the usable normalization mode without constructing a WeText FST.

    Callers with no text should select an explicit language. None/Auto checks
    the API's non-CJK default (English); normalize_text resolves CJK from text.
    Optional native-library loading can still fail later with a localized error.
    """
    code = _resolve_lang_code(language, "")
    if code in {"zh", "en"} and _has_wetext(code):
        return "wetext"
    _check_num2words_support(code)
    return "num2words"


def _resolve_lang_code(language: Optional[str], text: str) -> str:
    """Map a language name/code to ``"zh"``/``"en"``/other code.

    When ``language`` is ``None``, empty or ``Auto``, detect Chinese vs. English
    by the presence of CJK characters. Other names/codes remain explicit.
    """
    if language is not None:
        code = language.strip().lower()
        if code and code not in {"none", "auto"}:
            if code in ("zh", "en"):
                return code
            try:
                from omnivoice.utils.lang_map import LANG_IDS, LANG_NAME_TO_ID

                if code in LANG_IDS:
                    return code
                if code in LANG_NAME_TO_ID:
                    return LANG_NAME_TO_ID[code]
            except Exception:  # pragma: no cover - lang_map should be importable
                pass
            return code  # assume it is already a language id, e.g. "ja", "de"
    return "zh" if _CJK_RE.search(text) else "en"


def _num2words_segment(text: str, lang: str) -> str:
    """Convert standalone integers, preserving compound numeric formats verbatim."""
    converter_language = _check_num2words_support(lang)
    try:
        from num2words import num2words
    except (ImportError, OSError) as exc:
        raise TextNormalizationError("normalization_missing_dependency", lang) from exc

    def _repl(match):
        if match.group("integer") is None:
            return match.group()
        try:
            value = int(match.group())
            # num2words 0.5.14's Polish converter cannot process a negative int,
            # even though it exposes the localized sign. Keep other languages'
            # native signed-number behavior and work around this upstream bug.
            if converter_language == "pl" and value < 0:
                from num2words import CONVERTER_CLASSES

                sign = CONVERTER_CLASSES["pl"].negword.strip()
                return f"{sign} {num2words(-value, lang=converter_language)}"
            return num2words(value, lang=converter_language)
        except NotImplementedError as exc:
            raise TextNormalizationError("normalization_unsupported_language", lang) from exc
        except Exception as exc:
            raise TextNormalizationError("normalization_failed", lang) from exc

    return _INTEGER_OR_COMPOUND_RE.sub(_repl, text)


def _normalize_segment(fn: Callable[[str], str], segment: str) -> str:
    """Normalize one non-protected segment while preserving surrounding whitespace.

    Leading/trailing whitespace is preserved explicitly because the underlying
    normalizers strip it, which would otherwise glue words to an adjacent
    protected span (e.g. ``the [B EY1 S] guitar`` -> ``the[B EY1 S]guitar``).
    """
    if not segment.strip():
        return segment
    lead = segment[: len(segment) - len(segment.lstrip())]
    trail = segment[len(segment.rstrip()) :]
    core = fn(segment.strip())
    return lead + core + trail


def _apply_with_protection(text: str, fn: Callable[[str], str], protect_pinyin: bool) -> str:
    """Run ``fn`` on ``text`` while holding out protected control spans."""
    spans = [m.span() for m in _BRACKET_TAG_RE.finditer(text)]
    if protect_pinyin:
        spans += [m.span() for m in _PINYIN_TONE_RE.finditer(text)]
    if not spans:
        return _normalize_segment(fn, text)

    # Merge overlapping/adjacent protected spans, then normalize the gaps.
    spans.sort()
    merged: List[List[int]] = []
    for start, end in spans:
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])

    out: List[str] = []
    last = 0
    for start, end in merged:
        if start > last:
            out.append(_normalize_segment(fn, text[last:start]))
        out.append(text[start:end])  # protected span, verbatim
        last = end
    if last < len(text):
        out.append(_normalize_segment(fn, text[last:]))
    return "".join(out)


def normalize_text(text: str, language: Optional[str] = None) -> str:
    """Normalize text using optional rich rules or a basic integer-only fallback.

    Chinese/English use WeTextProcessing when available. Otherwise supported
    languages use num2words for standalone integers only, leaving compound
    numeric formats (decimals, dates and times) and alphanumeric identifiers
    unchanged. Unsupported languages or missing dependencies raise an error.

    Inline OmniVoice control syntax is preserved: bracketed non-verbal tags
    (``[laughter]``) and CMU pronunciation overrides (``[B EY1 S]``) are passed
    through untouched, and Chinese pinyin tone markers (uppercase pinyin +
    tone digit) are protected so the tone digit is not read as a number.

    Args:
        text: Input text.
        language: Language code (``"en"``/``"zh"``) or full name (``"English"``).
            ``None`` or ``"Auto"`` detects Chinese vs. English by script, not other
            languages. User interfaces should require an explicit language.

    Returns:
        The normalized text.

    Raises:
        TextNormalizationError: Normalization is unavailable or failed.
    """
    if not text or not text.strip():
        return text

    code = _resolve_lang_code(language, text)
    try:
        mode = check_normalization_support(code)
        if mode == "wetext":
            try:
                normalizer = _get_zh_normalizer() if code == "zh" else _get_en_normalizer()
            except (ImportError, OSError):
                _check_num2words_support(code)
                mode = "num2words"
        normalize = (
            normalizer.normalize
            if mode == "wetext"
            else lambda segment: _num2words_segment(segment, code)
        )
        return _apply_with_protection(text, normalize, protect_pinyin=code == "zh")
    except TextNormalizationError:
        raise
    except Exception as exc:
        raise TextNormalizationError("normalization_failed", code) from exc
