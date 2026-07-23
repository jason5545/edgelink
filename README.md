# EdgeLink

EdgeLink is a clean-room device link system in the spirit of KDE Connect:

- macOS host: menu bar background app
- Android client: primary control UI
- Cloudflare Workers and Durable Objects: identity registry, pairing rendezvous, and blind relay
- End-to-end encryption above every transport

This repository is intentionally initialized without KDE Connect source code or Git history.
`/Users/jianruicheng/GitHub/kdeconnect-kde-upstream` may be used only as a read-only concept reference.

## Current status

EdgeLink is past the initial scaffold. The macOS app, Android client, direct LAN transport,
encrypted Cloudflare relay, pairing, and device workflows are implemented and tested together.
The native EdgeLink protocol remains documented in [`docs/protocol.md`](docs/protocol.md), with
reproducible crypto vectors in [`docs/test-vectors/`](docs/test-vectors/).

## Xiaomi Lyra / Mi Share interoperability

EdgeLinkMac now implements the Xiaomi Lyra path directly instead of handing file transfers to the
official HyperConnect Mac app. In the verified Xiaomi/HyperOS setup, files can travel both ways:

- Xiaomi phone to Mac: accept Mi Share transfers and save them to
  `~/Downloads/EdgeLink-MiShare/`
- Mac to Xiaomi phone: choose files from the EdgeLink menu bar with
  **小米快傳傳檔給手機**

The clean-room implementation covers the full working path:

- `_lyra-mdns._udp.local.` discovery and advertisement
- KCP-based Lyra netbus mesh transport
- physical and logical connection setup, keepalive, and service announcement
- P-256 key agreement, HKDF-SHA256, and AES-256-GCM channel encryption
- Lyra channel negotiation and miexpress TLV/stream framing
- Mi Share request, response, completion, and file stream handling

The current phone-side discovery/trust path uses EdgeLink's Xposed bridge. It has been verified on
the project's Xiaomi/HyperOS test device over a WLAN that allows direct peer traffic; support is not
claimed for every Xiaomi ROM or Mi Share version.

Protocol evidence and the implementation record are in
[`docs/lyra-netbus-notes.md`](docs/lyra-netbus-notes.md). Xiaomi binaries and generated
reverse-engineering captures are not committed to this repository.

## Names

- Android package: `com.edgelink.app`
- Swift shared package/module: `EdgeLinkKit`
- Worker project: `edgelink-worker`
- Bonjour service: `_edgelink._tcp`
- Mac bundle ID: `com.edgelink.mac`
