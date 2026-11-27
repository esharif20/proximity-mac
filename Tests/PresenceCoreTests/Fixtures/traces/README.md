# synthetic

Synthetic presence traces, one JSON `TraceLine` per line (see `Sources/PresenceCore/Types.swift`).
They hold numbers only. No images, audio or real device identifiers.

Each `<name>.jsonl` has a `<name>.truth.jsonl` beside it with the ground-truth label changes,
`{"t": seconds, "atDesk": Bool}`. Lines starting with `#` are comments.
