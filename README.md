# MacLink for macOS

Native macOS application for connecting an Android phone to a Mac over the local
network.

## Technology

- Swift 6
- SwiftUI
- Swift Concurrency
- Network.framework and Bonjour
- CryptoKit and Keychain Services

## Development status

The project has a native application shell and can advertise a sandboxed local
TCP listener through Bonjour as `_maclink._tcp`. Pairing, secure transport, and
feature synchronization are not implemented yet.

The shared system design is maintained in the parent `MacLink` directory:
`ARCHITECTURE.md`, `PROTOCOL.md`, and `SECURITY.md`.

## Requirements

- macOS 15 or newer
- Xcode 26 or newer

## Build

Open `MacLink.xcodeproj` in Xcode or run:

```sh
xcodebuild -project MacLink.xcodeproj -scheme MacLink -configuration Debug build
```
