# Matt skills snapshot provenance

This directory vendors an exact snapshot of Matt Pocock's public skills repository.

- Source: https://github.com/mattpocock/skills
- Commit: `84fdeffd12f2ee307994d1eb6feb48173b6e0502`
- Source roots: `skills/productivity/` and `skills/engineering/`
- Destination roots: `custom-skills/matt/productivity/` and `custom-skills/matt/engineering/`
- Snapshot inventory: 76 files from the two source roots, plus the upstream `LICENSE`.
- License: the upstream MIT license is retained verbatim at `custom-skills/matt/LICENSE`.
- Hash evidence: `SNAPSHOT.sha256` records the source path, destination path, byte count, source SHA-256, and destination SHA-256 for every copied file.

Reproduce the snapshot from the pinned commit with:

```sh
git archive 84fdeffd12f2ee307994d1eb6feb48173b6e0502 skills/productivity skills/engineering LICENSE | tar -x
```

Copy `skills/productivity/` to `custom-skills/matt/productivity/`, copy `skills/engineering/` to `custom-skills/matt/engineering/`, and copy `LICENSE` to `custom-skills/matt/LICENSE`.

Verify every source and destination pair with `cmp` and the matching rows in `SNAPSHOT.sha256`.

The copied upstream files are byte-preserved and are not adapted for Firstmate.
