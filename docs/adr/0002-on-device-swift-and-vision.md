# 2. Swift with Apple Vision, entirely on-device

Presence detection uses Apple's Vision framework from a native Swift app. Vision runs face and body detection on the Neural Engine at a few milliseconds per frame. Python with OpenCV or MediaPipe would ship a 150 to 300 MB runtime and run on the CPU. Rust or C++ would add build complexity and still need Apple's camera, display and menu-bar APIs. Nothing leaves the Mac: no network code exists, frames and audio stay in memory, and logs hold numbers only. The cost is that the app only runs on macOS 26 or later, which SpeechAnalyzer needs too.
