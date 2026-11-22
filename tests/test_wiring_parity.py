"""Each plugin's hooks.json registers its hooks exactly as a maintainer's own settings.json does.

The maintainer's machine runs these files through symlinks registered in settings.json; colleagues run them as
plugins. This test keeps the two wirings from drifting. Point PARITY_SETTINGS at that settings.json to run it.
"""

import json
import os
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SETTINGS = os.environ.get("PARITY_SETTINGS")


def _regs(hooks: dict) -> set[tuple[str, str, str]]:
    out = set()
    for event, groups in hooks.items():
        for group in groups:
            for handler in group.get("hooks", []):
                script = next((t for t in handler.get("command", "").replace('"', " ").split() if "/hooks/" in t), "")
                if script:
                    out.add((event, group.get("matcher", ""), Path(script).name))
    return out


@pytest.mark.skipif(not SETTINGS, reason="set PARITY_SETTINGS to a settings.json that wires these hooks")
def test_plugin_wiring_matches_the_settings_wiring() -> None:
    settings = _regs(json.loads(Path(SETTINGS).read_text()).get("hooks", {}))
    problems = []
    for hooks_json in sorted(ROOT.glob("plugins/*/hooks/hooks.json")):
        plugin = _regs(json.loads(hooks_json.read_text())["hooks"])
        shipped = {p.name for p in hooks_json.parent.iterdir()}
        problems += [f"{hooks_json.parent.parent.name}: {r} not in settings" for r in plugin - settings
                     if hooks_json.parent.parent.name != "coding-standard"]
        problems += [f"{hooks_json.parent.parent.name}: settings wires {r}, plugin does not"
                     for r in settings - plugin if r[2] in shipped]
    assert not problems, "\n".join(problems)
