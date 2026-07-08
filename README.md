# EdgeLink

EdgeLink is a clean-room device link system in the spirit of KDE Connect:

- macOS host: menu bar background app
- Android client: primary control UI
- Cloudflare Workers and Durable Objects: identity registry, pairing rendezvous, and blind relay
- End-to-end encryption above every transport

This repository is intentionally initialized without KDE Connect source code or Git history.
`/Users/jianruicheng/GitHub/kdeconnect-kde-upstream` may be used only as a read-only concept reference.

## M0 Scope

- Clean monorepo scaffold
- Protocol source of truth in `docs/protocol.md`
- Reproducible crypto test vectors in `docs/test-vectors/`
- Cloudflare Worker hello route and Durable Object skeletons
- macOS and Android source layout ready for pairing and crypto tests

## Names

- Android package: `com.edgelink.app`
- Swift shared package/module: `EdgeLinkKit`
- Worker project: `edgelink-worker`
- Bonjour service: `_edgelink._tcp`
- Mac bundle ID: `com.edgelink.mac`
