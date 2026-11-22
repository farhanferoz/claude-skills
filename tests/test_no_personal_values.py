"""No private name may appear in any tracked file.

The banned words are stored as sha256 hashes (tests/never_publish.sha256) so this public file does not publish them.
A maintainer can add plain-text words kept outside the repository with PERSONAL_WORDS_FILE=/path/to/words.txt.
"""

import hashlib
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOKEN = re.compile(r"[A-Za-z0-9_-]+")


def _banned() -> set[str]:
    lines = (ROOT / "tests" / "never_publish.sha256").read_text().splitlines()
    hashes = {line.strip() for line in lines if line.strip() and not line.startswith("#")}
    extra = os.environ.get("PERSONAL_WORDS_FILE")
    if extra:
        words = [w.strip().lower() for w in Path(extra).read_text().splitlines() if w.strip()]
        hashes |= {hashlib.sha256(w.encode()).hexdigest() for w in words}
    return hashes


def _tokens(text: str) -> set[str]:
    """Whole tokens plus their - and _ separated parts, lower-cased."""
    out: set[str] = set()
    for tok in TOKEN.findall(text.lower()):
        out.add(tok)
        out.update(p for p in re.split(r"[-_]", tok) if p)
    return out


def _tracked() -> list[Path]:
    names = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], cwd=ROOT, capture_output=True,
                           text=True, check=True).stdout.split()
    return [ROOT / n for n in names if (ROOT / n).is_file()]


def test_no_tracked_file_contains_a_banned_word() -> None:
    banned = _banned()
    hits = []
    for path in _tracked():
        if path.name == "never_publish.sha256":
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        for tok in _tokens(text) | _tokens(str(path.relative_to(ROOT))):
            if hashlib.sha256(tok.encode()).hexdigest() in banned:
                hits.append(f"{path.relative_to(ROOT)}: a banned word")
                break
    assert not hits, "remove or generalise these before publishing:\n" + "\n".join(hits)
