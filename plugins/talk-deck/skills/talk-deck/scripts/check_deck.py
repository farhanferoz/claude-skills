#!/usr/bin/env python3
"""Check a slide deck against the talk-deck rules. Exit 0 only if every slide passes.

Reads an HTML deck (slides are the elements matched by --slide-selector, default
"section") or a Markdown deck (slides separated by a line of exactly "---").

Per slide it checks:
  * the closed-slide word count against --max-slide-words (default 80). A closed
    slide is what a viewer reads without opening anything: everything except
    disclosure panels (--panel-selector, default "details"; its <summary> still
    counts as closed text) and ignored elements (--ignore-selector, default
    "script,style,template,[data-verbatim]"; mark real logs and quotes
    data-verbatim so they sit outside the caps and the number check);
  * each panel's word count against --max-panel-words (default 45);
  * every number token (for example 93%, 327k, 3.3) appears in the facts file with
    a date and a source (and, with --window-start, a date on or after that day).

Facts file: a Markdown table whose header row has the columns value, date, source
(any order, other columns allowed). A number matches a row when the row's value
cell holds the same token, with the same suffix: "93%" needs a row whose value
cell contains "93%".

Settings: every option can also sit in deck-check.json beside the deck (keys are
the option names with underscores, e.g. "max_slide_words"); a flag wins over the
file, the file over the defaults. A slide may carry its own cap: data-max-words
="130" on its element (HTML) or a comment <!-- max-words: 130 --> (Markdown).

A "word" is a whitespace-separated token with at least one letter or digit.
Exit codes: 0 all slides pass; 1 at least one rule broken; 2 the checker could
not run (unreadable deck, bad settings), with the remedy printed.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field, replace
from enum import Enum
from html.parser import HTMLParser
from pathlib import Path

# fact: the file name the checker looks for beside the deck
SETTINGS_FILE = "deck-check.json"
# fact: elements the HTML standard defines as having no end tag
HTML_VOID_TAGS = frozenset(
    "area base br col embed hr img input link meta source track wbr".split()
)
# fact: the always-visible label of an HTML <details> disclosure
DISCLOSURE_LABEL_TAG = "summary"
# fact: Markdown thematic break, the slide separator used by common deck tools
MARKDOWN_RULE = re.compile(r"^---\s*$")
NUMBER = re.compile(r"(?<![\w.])\d+(?:[,.]\d+)*(?:%|[kKMBx](?![A-Za-z0-9]))?(?!\w)")
# fact: ISO 8601 calendar date, with the day optional
ISO_DATE = re.compile(r"\d{4}-\d{2}(?:-\d{2})?")
# fact: ISO 8601 date with its day
ISO_DAY = re.compile(r"\d{4}-\d{2}-\d{2}")
# fact: the CSS simple-selector pieces supported (#id, .class, [attr], [attr=value])
SELECTOR_PART = re.compile(r"[.#][\w-]+|\[[\w-]+(?:=[^\]]+)?\]")
SELECTOR_TAG = re.compile(r"[A-Za-z][\w-]*")


class Rule(str, Enum):
    """Which deck rule a finding breaks."""

    NO_SLIDES = "no-slides"
    SLIDE_WORDS = "slide-words"
    PANEL_WORDS = "panel-words"
    NUMBER_NOT_IN_FACTS = "number-not-in-facts"
    NUMBER_NO_DATE = "number-no-date"
    NUMBER_NO_SOURCE = "number-no-source"
    NUMBER_STALE = "number-stale"


class CheckError(Exception):
    """The checker could not run; the message names the remedy."""


@dataclass(frozen=True)
class Settings:
    """Every tunable of a check; flags or deck-check.json change the defaults."""

    slide_selector: str = "section"
    panel_selector: str = "details"
    ignore_selector: str = "script,style,template,[data-verbatim]"
    max_slide_words: int = 80
    max_panel_words: int = 45
    # years and ISO dates are not claims
    ignore_pattern: str = r"\b(?:19|20)\d{2}(?:-\d{2}){0,2}\b"
    facts: Path | None = None
    window_start: str | None = None


@dataclass(frozen=True)
class Slide:
    index: int
    label: str
    body: str
    panels: tuple[str, ...]
    max_words: int | None = None


@dataclass(frozen=True)
class Fact:
    tokens: frozenset[str]
    date: str
    source: str


@dataclass(frozen=True)
class Finding:
    slide: Slide
    rule: Rule
    detail: str
    remedy: str


# ---------------------------------------------------------------- selectors


@dataclass(frozen=True)
class Selector:
    """One compound selector: tag, #id, .class, [attr], [attr=value]; no combinators."""

    tag: str | None = None
    ids: tuple[str, ...] = ()
    classes: tuple[str, ...] = ()
    attrs: tuple[tuple[str, str | None], ...] = ()

    def matches(self, tag: str, attrs: dict[str, str | None]) -> bool:
        if self.tag and self.tag != tag:
            return False
        have = set((attrs.get("class") or "").split())
        if not set(self.classes) <= have or any(attrs.get("id") != i for i in self.ids):
            return False
        return all(
            name in attrs and (value is None or attrs[name] == value)
            for name, value in self.attrs
        )


def parse_selectors(text: str) -> tuple[Selector, ...]:
    """Parse "a, .b, [c=d]" into selectors; combinators are refused."""
    out: list[Selector] = []
    for group in (g.strip() for g in text.split(",")):
        tag_match = SELECTOR_TAG.match(group)
        tag = tag_match.group(0) if tag_match else None
        rest = group[len(tag or "") :]
        parts = SELECTOR_PART.findall(rest)
        if not group or "".join(parts) != rest:
            raise CheckError(
                f"unsupported selector {group!r}: use a tag, #id, .class or "
                "[attr=value], joined without spaces (for example section.slide "
                "or [data-slide]); separate alternatives with commas"
            )
        ids = tuple(p[1:] for p in parts if p[0] == "#")
        classes = tuple(p[1:] for p in parts if p[0] == ".")
        attrs = tuple(
            (name, value.strip("\"'") if value else None)
            for name, _, value in (p[1:-1].partition("=") for p in parts if p[0] == "[")
        )
        out.append(Selector(tag, ids, classes, attrs))
    return tuple(out)


def selector_hit(
    selectors: Sequence[Selector], tag: str, attrs: dict[str, str | None]
) -> bool:
    return any(s.matches(tag, attrs) for s in selectors)


# ---------------------------------------------------------------- deck readers


@dataclass
class _Builder:
    attrs: dict[str, str | None]
    body: list[str] = field(default_factory=list)
    panels: list[list[str]] = field(default_factory=list)
    heading: str = ""
    nested: bool = False


@dataclass
class _Open:
    tag: str
    ignore: bool = False
    panel: list[str] | None = None
    slide: _Builder | None = None


class _HtmlDeck(HTMLParser):
    """Collects each slide's closed text and panel text (innermost slide wins)."""

    def __init__(self, settings: Settings) -> None:
        super().__init__(convert_charrefs=True)
        self.slide_sel = parse_selectors(settings.slide_selector)
        self.panel_sel = parse_selectors(settings.panel_selector)
        self.ignore_sel = parse_selectors(settings.ignore_selector)
        self.stack: list[_Open] = []
        self.slides: list[_Builder] = []

    def _current(self) -> _Builder | None:
        return next((e.slide for e in reversed(self.stack) if e.slide), None)

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in HTML_VOID_TAGS:
            return
        a = dict(attrs)
        entry = _Open(tag, ignore=selector_hit(self.ignore_sel, tag, a))
        parent = self._current()
        if selector_hit(self.slide_sel, tag, a):
            if parent:
                parent.nested = True
            entry.slide = _Builder(a)
            self.slides.append(entry.slide)
        elif parent and selector_hit(self.panel_sel, tag, a):
            entry.panel = []
            parent.panels.append(entry.panel)
        self.stack.append(entry)

    def handle_endtag(self, tag: str) -> None:
        if tag in HTML_VOID_TAGS:
            return
        while self.stack and self.stack.pop().tag != tag:
            pass

    def handle_data(self, data: str) -> None:
        slide = self._current()
        if slide is None or any(e.ignore for e in self.stack):
            return
        panel_at = max(
            (i for i, e in enumerate(self.stack) if e.panel is not None), default=-1
        )
        target = self.stack[panel_at].panel if panel_at >= 0 else None
        labelled = any(e.tag == DISCLOSURE_LABEL_TAG for e in self.stack[panel_at:])
        if target is not None and not labelled:
            target.append(data)
            return
        slide.body.append(data)
        if not slide.heading and any(
            re.fullmatch(r"h[1-6]", e.tag) for e in self.stack
        ):
            slide.heading = data.strip()


def read_html(text: str, settings: Settings) -> list[Slide]:
    parser = _HtmlDeck(settings)
    parser.feed(text)
    slides: list[Slide] = []
    for b in (
        b for b in parser.slides if not (b.nested and not "".join(b.body).strip())
    ):
        cap = b.attrs.get("data-max-words")
        slides.append(
            Slide(
                index=len(slides) + 1,
                label=b.attrs.get("id") or b.heading,
                body=" ".join(b.body),
                panels=tuple(" ".join(p) for p in b.panels),
                max_words=int(cap) if cap and cap.isdigit() else None,
            )
        )
    return slides


MD_PANEL = re.compile(r"<details\b[^>]*>(.*?)</details>", re.S | re.I)
MD_SUMMARY = re.compile(r"<summary\b[^>]*>(.*?)</summary>", re.S | re.I)
MD_COMMENT_CAP = re.compile(r"<!--\s*max-words:\s*(\d+)\s*-->")
MD_COMMENT = re.compile(r"<!--.*?-->", re.S)
MD_IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
MD_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
# fact: the number in an ordered-list marker is not a claim
MD_LIST_MARKER = re.compile(r"^\s*\d+[.)]\s+", re.M)
MD_FRONT_MATTER_LINE = re.compile(r"^[A-Za-z][\w-]*:")
MD_TAG = re.compile(r"<[^>]+>")


def read_markdown(text: str, settings: Settings) -> list[Slide]:
    chunks: list[list[str]] = [[]]
    for line in text.splitlines():
        if MARKDOWN_RULE.match(line):
            chunks.append([])
        else:
            chunks[-1].append(line)
    if (
        len(chunks) > 1
        and chunks[0] == []
        and chunks[1]
        and all(MD_FRONT_MATTER_LINE.match(x) or not x.strip() for x in chunks[1])
    ):
        chunks = chunks[2:]  # YAML front matter between two leading --- lines
    slides: list[Slide] = []
    for lines in chunks:
        raw = "\n".join(lines)
        if not raw.strip():
            continue
        cap = MD_COMMENT_CAP.search(raw)
        panels = tuple(
            MD_TAG.sub(" ", m.group(1))
            for m in MD_PANEL.finditer(MD_SUMMARY.sub("", raw))
        )
        closed = MD_PANEL.sub(lambda m: " ".join(MD_SUMMARY.findall(m.group(0))), raw)
        closed = MD_LIST_MARKER.sub(
            "", MD_LINK.sub(r"\1", MD_IMAGE.sub("", MD_COMMENT.sub("", closed)))
        )
        heading = next((x.lstrip("# ").strip() for x in lines if x.startswith("#")), "")
        slides.append(
            Slide(
                len(slides) + 1,
                heading,
                MD_TAG.sub(" ", closed),
                panels,
                int(cap.group(1)) if cap else None,
            )
        )
    return slides


READERS: dict[str, Callable[[str, Settings], list[Slide]]] = {
    ".html": read_html,
    ".htm": read_html,
    ".md": read_markdown,
    ".markdown": read_markdown,
}


# ---------------------------------------------------------------- facts


def _normal(token: str) -> str:
    return token.replace(",", "").lower()


def number_tokens(text: str, ignore: re.Pattern[str]) -> list[str]:
    """Number tokens a reader takes as claims, normalised, without dates and years."""
    return [_normal(m.group(0)) for m in NUMBER.finditer(ignore.sub(" ", text))]


def read_facts(path: Path, ignore: re.Pattern[str]) -> list[Fact]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as err:
        raise CheckError(
            f"cannot read the facts file {path}: {err}. "
            f'Pass --facts <file> or set "facts" in {SETTINGS_FILE}'
        ) from err
    facts: list[Fact] = []
    columns: dict[str, int] | None = None
    for line in text.splitlines():
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        names = [c.lower() for c in cells]
        if {"value", "date", "source"} <= set(names):
            columns = {n: names.index(n) for n in ("value", "date", "source")}
        elif (
            columns
            and not re.fullmatch(r"[\s:|-]*", line)
            and len(cells) > max(columns.values())
        ):
            date = ISO_DATE.search(cells[columns["date"]])
            facts.append(
                Fact(
                    frozenset(number_tokens(cells[columns["value"]], ignore)),
                    date.group(0) if date else "",
                    cells[columns["source"]],
                )
            )
    if columns is None:
        raise CheckError(
            f"{path} has no table with value, date and source columns. "
            "Write one row per number: | value | date | source |"
        )
    return facts


def _day(date: str) -> str:
    # fact: a month with no day counts as its last day, so it is never wrongly stale
    return date if ISO_DAY.fullmatch(date) else date + "-31"


def judge_number(
    token: str, facts: Sequence[Fact], window_start: str | None
) -> tuple[Rule, str] | None:
    """None if a facts row holds the token with a date and source (and is fresh)."""
    problems: list[tuple[Rule, str]] = []
    for f in (f for f in facts if token in f.tokens):
        if not f.date:
            problems.append((Rule.NUMBER_NO_DATE, "its facts row has no date"))
        elif not f.source:
            problems.append((Rule.NUMBER_NO_SOURCE, "its facts row has no source"))
        elif window_start and _day(f.date) < window_start:
            problems.append(
                (
                    Rule.NUMBER_STALE,
                    f"its facts row is dated {f.date}, before the window "
                    f"starting {window_start}",
                )
            )
        else:
            return None
    return (
        problems[0]
        if problems
        else (Rule.NUMBER_NOT_IN_FACTS, "it has no row in the facts file")
    )


# ---------------------------------------------------------------- checks


def count_words(text: str) -> int:
    return sum(1 for tok in text.split() if re.search(r"[A-Za-z0-9]", tok))


NUMBER_REMEDY = {
    Rule.NUMBER_NOT_IN_FACTS: "add a row | value | date | source | to the facts "
    "file, or remove the number from the slide",
    Rule.NUMBER_NO_DATE: "give its facts row an ISO date (YYYY-MM-DD)",
    Rule.NUMBER_NO_SOURCE: "name the source in its facts row",
    Rule.NUMBER_STALE: "re-measure inside the window and update the row, or move "
    "the number out of the results",
}


def check_slide(
    slide: Slide, settings: Settings, facts: Sequence[Fact], ignore: re.Pattern[str]
) -> list[Finding]:
    out: list[Finding] = []
    cap = slide.max_words if slide.max_words is not None else settings.max_slide_words
    words = count_words(slide.body)
    if words > cap:
        out.append(
            Finding(
                slide,
                Rule.SLIDE_WORDS,
                f"{words} closed-slide words, limit {cap}",
                "cut text or turn it into a picture; move detail into a "
                "click-to-open panel",
            )
        )
    for n, panel in enumerate(slide.panels, 1):
        words = count_words(panel)
        if words > settings.max_panel_words:
            out.append(
                Finding(
                    slide,
                    Rule.PANEL_WORDS,
                    f"panel {n}: {words} words, limit {settings.max_panel_words}",
                    "shorten the panel, or show the detail as a picture",
                )
            )
    seen: set[str] = set()
    for token in number_tokens(" ".join((slide.body, *slide.panels)), ignore):
        if token in seen:
            continue
        seen.add(token)
        if problem := judge_number(token, facts, settings.window_start):
            rule, why = problem
            out.append(
                Finding(slide, rule, f"number {token!r}: {why}", NUMBER_REMEDY[rule])
            )
    return out


def check_deck(path: Path, settings: Settings) -> tuple[list[Slide], list[Finding]]:
    reader = READERS.get(path.suffix.lower())
    if reader is None:
        raise CheckError(
            f"cannot read {path.name}: supported deck types are "
            f"{', '.join(sorted(READERS))}. Export the deck to HTML or Markdown first"
        )
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as err:
        raise CheckError(
            f"cannot read the deck {path}: {err}. Pass the path of an existing deck"
        ) from err
    try:
        ignore = re.compile(settings.ignore_pattern)
    except re.error as err:
        raise CheckError(
            f"ignore_pattern is not a valid regular expression ({err}). "
            f"Fix it in {SETTINGS_FILE} or --ignore-pattern"
        ) from err
    facts = read_facts(settings.facts, ignore) if settings.facts else []
    slides = reader(text, settings)
    if not slides:
        empty = Slide(0, path.name, "", ())
        return slides, [
            Finding(
                empty,
                Rule.NO_SLIDES,
                "no slides found",
                "check --slide-selector (HTML) or that slides are separated by "
                "lines of exactly '---' (Markdown)",
            )
        ]
    return slides, [f for s in slides for f in check_slide(s, settings, facts, ignore)]


# ---------------------------------------------------------------- command line


SETTING_FLAGS: dict[str, tuple[type, str]] = {
    "slide_selector": (str, "elements that are slides (HTML)"),
    "panel_selector": (
        str,
        "elements that are click-to-open panels (HTML, and <details> in Markdown)",
    ),
    "ignore_selector": (str, "elements outside the caps and number check (HTML)"),
    "max_slide_words": (int, "most words on a closed slide"),
    "max_panel_words": (int, "most words in one panel"),
    "ignore_pattern": (
        str,
        "regex for text that holds no claim (default: years and ISO dates)",
    ),
    "facts": (Path, "Markdown table of value | date | source rows, one per number"),
    "window_start": (str, "earliest date a number's facts row may carry (YYYY-MM-DD)"),
}


def load_settings(
    deck: Path, settings_path: Path | None, overrides: dict[str, object]
) -> Settings:
    base = Settings()
    path = settings_path or deck.parent / SETTINGS_FILE
    values: dict[str, object] = {}
    if path.exists():
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as err:
            raise CheckError(
                f"cannot read {path} as JSON ({err}). "
                "Fix the file or pass --settings <file>"
            ) from err
        unknown = set(raw) - set(SETTING_FLAGS)
        if unknown:
            raise CheckError(
                f"{path} has unknown keys {sorted(unknown)}. "
                f"Valid keys: {', '.join(SETTING_FLAGS)}"
            )
        for key, value in raw.items():
            kind = SETTING_FLAGS[key][0]
            if not isinstance(value, str if kind is Path else kind) or isinstance(
                value, bool
            ):
                raise CheckError(
                    f"{path}: {key!r} must be a {kind.__name__}. Fix the value"
                )
            values[key] = path.parent / value if kind is Path else value
    values.update({k: v for k, v in overrides.items() if v is not None})
    return replace(base, **values)  # type: ignore[arg-type]


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("deck", type=Path, help="deck to check: .html or .md")
    ap.add_argument(
        "--settings",
        type=Path,
        help=f"settings file (default: {SETTINGS_FILE} beside the deck, if present)",
    )
    for key, (kind, help_text) in SETTING_FLAGS.items():
        ap.add_argument(
            "--" + key.replace("_", "-"),
            dest=key,
            type=kind,
            default=None,
            help=help_text,
        )
    return ap.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        settings = load_settings(
            args.deck, args.settings, {k: getattr(args, k) for k in SETTING_FLAGS}
        )
        slides, findings = check_deck(args.deck, settings)
    except CheckError as err:
        print(f"ERROR {err}", file=sys.stderr)
        return 2
    print(f"{'slide':>5} {'closed words':>12} {'longest panel':>14}  label")
    for s in slides:
        longest = max((count_words(p) for p in s.panels), default=0)
        print(f"{s.index:>5} {count_words(s.body):>12} {longest:>14}  {s.label}")
    for f in findings:
        name = f"slide {f.slide.index}" + (
            f" ({f.slide.label})" if f.slide.label else ""
        )
        print(f"FAIL {name}: [{f.rule.value}] {f.detail}. Remedy: {f.remedy}")
    print("ALL PASS" if not findings else f"{len(findings)} FAILED")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
