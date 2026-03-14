# Build & Deploy Rules

After every successful `xcodebuild`, automatically install and relaunch the app:

```bash
killall -9 "iPad Mirror" 2>/dev/null; sleep 2
cp -Rf "/Users/light/Library/Developer/Xcode/DerivedData/iPadMirror-cxesrvkqgyiyjvdrdvbbeuxyhdfy/Build/Products/Debug/iPad Mirror.app/" "/Applications/iPad Mirror.app/"
open "/Applications/iPad Mirror.app"
```

Critical details:
- Must use `killall -9` (not plain `killall`) — the app doesn't respond to SIGTERM reliably
- Must use `cp -Rf` with trailing slashes — without `-f`, the binary isn't overwritten while cached
- Must `sleep 2` between kill and copy — the OS needs time to release the binary
- Always verify the binary was replaced if hotkey/behavior changes aren't taking effect: compare `md5` hashes of source and destination binaries
