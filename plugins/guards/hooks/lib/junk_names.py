"""The junk-file-name rule, shared by clutter_guard.sh (blocks the write) and
scripts/end_of_work_audit.py (finds what got through anyway).

A junk PREFIX alone is not junk. `scratch-pad-design.md` — a design document
about a scratchpad — was blocked by the old rule, and so would `debug-logging
.md` or `temp-sensor.c`: real deliverables whose names happen to start with one
of these words (live-fired 2026-08-11). What distinguishes a dump from a
document is the REST of the name: `tmp_notes.md` and `debug-dump.py` say
nothing beyond the prefix, while a descriptive name carries two or more words
after it. So the prefix rule requires a non-descriptive remainder.
"""
import re


def is_junk(base: str) -> bool:
    stem = base.rsplit(".", 1)[0]
    prefixed = re.match(r"^(tmp|temp|scratch|debug)[_-](.*)$", stem)
    remainder_words = [w for w in re.split(r"[_-]+", prefixed.group(2)) if w] if prefixed else []
    return bool(
        (prefixed and len(remainder_words) <= 1)
        or base.endswith(".tmp")
        or re.match(r"^(out|output|dump|log)\.(txt|log|json)$", base)
        or base == "nohup.out"                      # the classic stray dump
        or re.match(r"^core\.\d+$", base)           # and the classic stray crash file
    )
