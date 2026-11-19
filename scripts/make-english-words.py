#!/usr/bin/env python3
"""Rebuild Resources/english-words.txt from the public-domain Webster's Second list.

macOS ships this list at /usr/share/dict/web2. The 1934 copyright has lapsed
(see /usr/share/dict/README). Output is lowercase A–Z words, length 1...20.
"""

from pathlib import Path

source = Path("/usr/share/dict/web2")
out = Path(__file__).resolve().parents[1] / "Resources" / "english-words.txt"

# Headwords that are only obscure dialect and steal a common Hangul reading.
# `sody` is a US dialect of soda; on 두벌식 those keys are 내요.
exclude = {"sody"}

words = set()
for line in source.read_text(encoding="utf-8", errors="replace").splitlines():
    word = line.strip()
    if word.isalpha() and 1 <= len(word) <= 20 and word.lower() not in exclude:
        words.add(word.lower())

out.write_text("\n".join(sorted(words)) + "\n", encoding="utf-8")
print(f"wrote {len(words)} words to {out}")
