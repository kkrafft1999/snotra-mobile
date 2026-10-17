# Snotra mobile

An iPhone app for [Snotra Agent](https://github.com/kkrafft1999/snotra): when you step away from your desk, it lets you follow and drive the chats running on your desktop. You can switch workspaces and chats, watch an answer come in live, write a message, stop a run, and answer a tool approval once.

**Status:** not implemented yet. This repository holds the app once work starts.

## How it works

- **The phone is a mirror.** Every chat stays on the desktop, which runs and stores it. The app keeps a chat in memory only, never on disk.
- **Pairing in person.** You pair a phone by scanning the QR code the desktop shows, or by typing the key shown next to it, and then confirming on the desktop.
- **End-to-end encrypted.** Messages travel through a blind relay in Firebase that cannot read them.
- **One user.** Exactly one phone per desktop installation. It is a second way in for the same person, never for someone else.

The concept, which is the basis for building the app, is [`docs/mobile-remote-concept.md`](docs/mobile-remote-concept.md), with the diagram [`docs/mobile-remote-architecture.svg`](docs/mobile-remote-architecture.svg). The work is tracked in the epic [kkrafft1999/snotra#1081](https://github.com/kkrafft1999/snotra/issues/1081). The protocol belongs to the desktop and will be specified in the Snotra repository; this app follows a pinned protocol version and its test vectors.

## Stack

- Swift and SwiftUI, iPhone first
- CryptoKit for the end-to-end encryption, the Secure Enclave and the Keychain for the keys
- VisionKit for the QR scan, LocalAuthentication for Face ID
- The Firebase iOS SDK (Realtime Database) as the transport

## License

[Apache License 2.0](LICENSE), like Snotra Agent.
