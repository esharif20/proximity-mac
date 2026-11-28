# Glossary

**Present**: the person is at the desk, close to the screen. Either they used the keyboard or mouse recently, or a presence source saw them within the Desk radius.

**Desk radius**: the distance from the screen inside which a person counts as Present. Defaults to 1.2 m. A person in bed or walking behind is outside it.

**Checking**: no input for a while, so the Mac looks to see whether the person is still there.

**Away**: nobody has been Present for long enough. The screens are off and the Mac watches for the person to come back.

**Grace countdown**: the short notice shown on every screen before Screens Off. Any input or a Command cancels it.

**Screens Off**: every display, built-in and external, goes dark while the Mac stays awake and the session stays exactly as it was. _Avoid_: sleep, when you mean this.

**System Sleep**: the whole Mac sleeping. Proximity Mac never does this, because a sleeping Mac can't hear or see the person come back.

**Hold**: the screens stay on regardless of presence, either for a set number of minutes or until "go to sleep" or the person returns to the desk.

**Command**: a short spoken instruction that starts with the Trigger word, for example "Screen, keep it on for 10 minutes".

**Trigger word**: the word every Command starts with, so speech from a video or a call doesn't count. Defaults to "Screen".

**Presence source**: anything that reports Observations about whether a person is near: the camera now, a radar or a phone later.

**Observation**: one reading from a Presence source: whether a person was seen, their distance and whether they face the screen. Never an image or a sound.

**Calibration**: recording the size of the person's face while they sit normally, so distances are measured for them.

**Trace**: a recorded sequence of timed events, used to test and measure the decisions without a camera.

**Setup**: the first-run walkthrough that shows the camera's view with the vision drawn on top, measures the Desk radius from where the person sits, leans back and lies in bed, tests a Command, and optionally enrols the Owner.

**Owner**: the person whose Face signature is enrolled. With "Only wake for me" on, only the Owner's face wakes the screens from Away.

**Face signature**: a short list of numbers (a face embedding) computed from the Owner's face during Setup. It is kept only in the Mac's Keychain, never as an image, and can be deleted in Settings. _Avoid_: Face ID, which is Apple's 3D system.
