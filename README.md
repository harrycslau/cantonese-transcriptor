# cantonese-transcriptor
A cantonese transcriptor using ASR models which also support Mandarin and English

## Milestone 3: macOS App

### Prerequisites
- macOS 13.0+ on Apple Silicon
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) installed: `brew install xcodegen`

### Build
```bash
cd macos
xcodegen generate
xcodebuild -scheme Transcriptor -configuration Debug -derivedDataPath /tmp/transcriptor-derived build
```

### Run
1. Start the ASR helper (from project root, in a terminal):
   ```bash
   python3 helper/server.py
   ```
2. Open the built app:
   ```bash
   open /tmp/transcriptor-derived/Build/Products/Debug/Transcriptor.app
   ```
   Or open `macos/Transcriptor.xcodeproj` in Xcode and press Run.
3. Select a `.wav` file → Transcribe → view transcript and timing fields