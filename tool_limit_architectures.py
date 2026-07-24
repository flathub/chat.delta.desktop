#!/usr/bin/env python3
"""Narrow pnpm's supportedArchitectures to the ones the flatpak build targets.

Since pnpm 10 this setting lives in pnpm-workspace.yaml instead of the "pnpm" key
of package.json, and pnpm silently ignores it in the old location.

Both the recording run (generate.sh) and the offline install inside the flatpak
sandbox have to narrow it the exact same way: whatever the recording run pulls in
is all the offline cache will ever contain, so if the sandbox asks for more, the
replay proxy answers 404 and the install fails.
"""

import re
import sys
from pathlib import Path

BLOCK = """supportedArchitectures:
  os:
    - linux
  cpu:
    - x64
    - arm64
"""

path = Path(sys.argv[1] if len(sys.argv) > 1 else "pnpm-workspace.yaml")
text = path.read_text()

# matches the `supportedArchitectures:` key plus its indented body
block = re.compile(r"^supportedArchitectures:\n(?:[ \t]+.*\n)*", re.MULTILINE)

if block.search(text):
    text = block.sub(BLOCK, text, count=1)
    print(f"narrowed supportedArchitectures in {path}")
else:
    text = text.rstrip("\n") + "\n\n" + BLOCK
    print(f"added supportedArchitectures to {path}")

path.write_text(text)
