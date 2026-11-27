# 3. Every sensor is a Presence source; only the engine decides

The camera is the only sensor in v1, but a radar module or a phone's Bluetooth signal may follow. Every sensor implements `PresenceSource` and reports `Observation`s (person seen, distance, facing). The pure `PresenceEngine` turns events into effects, and it alone decides. This keeps the decision logic testable with recorded traces and lets a new sensor arrive without touching the engine. The trade-off is that a sensor can only say what an `Observation` can carry. New fields there are a contract change the Lead makes.
