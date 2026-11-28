# Spike: the phone link over Bluetooth

The phone link uses the Bluetooth signal of the person's phone or watch as one more presence source. Two questions decide whether it can work:

1. Does the Mac keep recognising the same phone over hours, when iPhones change their Bluetooth address to avoid tracking?
2. Is the signal steady enough to tell "at the desk" from "at the bed or the door"?

## Address rotation

Bluetooth Low Energy devices may advertise from a private address. iPhones and Apple Watches use a resolvable private address that changes about every 15 minutes. Android phones do the same.

CoreBluetooth on macOS never shows the address. It gives each peripheral a `CBPeripheral.identifier`, a UUID the Mac makes up for that address and keeps in its own cache. If the address changes and the Mac cannot resolve it, the phone shows up under a new identifier and the old one is never seen again.

The Mac can resolve a private address when it holds the device's identity key. For Apple devices signed in to the same Apple ID as the Mac, macOS gets that key through iCloud, resolves every rotated address to the device's real one and keeps the same identifier. BLEUnlock (github.com/ts1/BLEUnlock, "Notes on MAC address") relies on exactly this and says the address of other devices, Android included, cannot be resolved.

What this means for the app:

- A phone or watch on the person's own Apple ID: the identifier saved in `PhoneLink.identifier` stays valid across rotations and restarts.
- Anything else: the link works for up to about 15 minutes and then goes quiet. The engine sees no readings, as if the phone were out of range, so the phone link must never be the only thing that keeps the screens on or wakes them.
- Only devices that advertise a name are listed in Setup. Apple devices on the same Apple ID do; that also keeps the list short.

## Signal

RSSI from one advert jumps by 10 dB or more when a hand or a body blocks the antenna. `BLESource` scans with duplicates allowed, so it hears every advert rather than one per scan, and reports the median of the last 5 readings about every 2 s. Setup records a near and a far level and refuses to save the link if they are less than 8 dB apart.

## Privacy

Scanning is passive: the Mac only listens to adverts and never connects. The device name is shown in Setup and Settings but never put in an Observation, a trace or a log.
