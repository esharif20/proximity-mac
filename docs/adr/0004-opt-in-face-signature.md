# 4. An opt-in Face signature, kept in the Keychain

## Status
Accepted (product owner, 2026-11-28).

## Context
When the screens are off, anyone who comes close to the desk wakes them, for example a parent leaning over it. The product owner wants only themselves to wake the screens, and is fine storing a face signature to do it. Apple Vision has no face identity API. A webcam has no depth sensor, so this can never be as strong as Face ID.

## Decision
- Use SFace (OpenCV Zoo, Apache-2.0, 99.4% on LFW), converted to Core ML and shipped inside the app, so the no-network promise holds. Credit it in NOTICE. InsightFace weights are non-commercial and EdgeFace's licence is unclear, so both are ruled out.
- Setup enrols 15 to 20 aligned face crops at varied poses into a Face signature (embeddings only). It is stored as one item in the login Keychain, never synced to iCloud, and deleted from Settings. Ad-hoc signed builds can't use the data protection keychain (errSecMissingEntitlement), so "this device only" and "only while unlocked" are not enforced: a Time Machine restore or Migration Assistant can carry the item to another Mac. Move to `kSecUseDataProtectionKeychain` once builds are team-signed. No crop or frame is ever written anywhere.
- Recognition runs only when "Only wake for me" or "Voice needs me" is on, a signature exists, and the camera already sees a close face. A match needs 3 consecutive frames over the threshold.
- A mismatch never turns screens off. Recognition gates only waking from Away, and Commands when "Voice needs me" is on. Keyboard and mouse input always wakes the screens, which macOS does itself.
- Both switches are off by default, for everyone who downloads the app.

## Consequences
- A false reject costs a keypress. A false accept is what the threshold is tuned against.
- A photo of the Owner can probably pass. This guards against family walking by, not an attacker, so no liveness check.
