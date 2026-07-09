# Clean-room Xiaomi / MI / POCO Enhancement Plan

## Goal

Improve EdgeLink behavior on Xiaomi-family Android devices without using Xiaomi private SDKs,
private protocols, copied source, reverse-engineered implementations, or signature-gated services.

The product direction is:

- EdgeLink remains the primary transport for pairing, relay, clipboard, notifications, SMS, file
  transfer, and screen viewing.
- Xiaomi / Redmi / POCO detection only changes capability hints, UI affordances, and safe platform
  workarounds.
- Official Xiaomi apps may be opened through public OS-level entrypoints when available, but EdgeLink
  must not depend on them.

## Clean-room Boundary

Allowed inputs:

- Public Android APIs such as `Build.MANUFACTURER`, `Build.BRAND`, `Build.MODEL`, package manager
  queries, `ContentResolver.call`, and exported system intents.
- Public macOS APIs such as URL scheme detection and `NSWorkspace.open`.
- Runtime behavior observed through normal app/shell calls, including success/failure/permission
  results.
- Our own protocol and implementation in this repo.

Disallowed inputs:

- Copying Xiaomi decompiled code, class structure, constants, native headers, packet formats, or
  private service protocols into EdgeLink.
- Binding to Xiaomi signature-gated or privileged services.
- Linking private Xiaomi frameworks or native libraries.
- Pretending to be a Xiaomi-signed package or whitelisted package.
- Making EdgeLink core features depend on a Xiaomi account, Xiaomi same-account trust, or Xiaomi
  private pairing state.

Practical rule: source files under `android/`, `mac/`, `worker/`, and `docs/protocol.md` should only
describe EdgeLink-owned behavior. Research notes can stay under `docs/`, but product code should use
neutral names like `DeviceProfile`, `VendorCapabilities`, and `OfficialFileTransferBridge`.

## Decisions

1. Add a Xiaomi-family device profile.
   - This is based on public device identity fields.
   - Brands: `xiaomi`, `redmi`, `poco`.
   - The profile is advisory. A false negative should only hide optional affordances.

2. Add a best-effort Android capability probe.
   - Only run it after the public device profile says the phone is Xiaomi-family.
   - Probe exported, public-facing OS components by normal `ContentResolver.call`.
   - Catch all expected failures and keep EdgeLink running.
   - Store only coarse booleans, not Xiaomi implementation details.

3. Extend EdgeLink metadata.
   - Pairing / registration should carry optional capability metadata.
   - The worker should store and return this metadata without interpreting private vendor details.
   - Secure session peers should know enough to choose UI affordances.

4. Add a Mac-side optional official transfer bridge.
   - Detect whether the official Xiaomi Mac app has registered a public URL scheme.
   - If the paired Android peer is Xiaomi-family and the URL scheme exists, show an optional action
     for sending local files through the official app.
   - Keep EdgeLink file transfer as the default path.

5. Keep screen-share workarounds inside EdgeLink.
   - Existing Xiaomi screen-share protection settings remain guarded by `WRITE_SECURE_SETTINGS`.
   - These should move behind the same Android `DeviceProfile` helper instead of scattered checks.

6. Add an EdgeLink-owned RPC control layer.
   - The Xiaomi stack having an RPC layer is only a product clue: complex device-link systems need
     request/response semantics, cancellation, errors, and timeouts.
   - EdgeLink must not implement Lyra compatibility, Lyra packet formats, Lyra method names, or Lyra
     service discovery.
   - Build a small RPC abstraction on top of the existing encrypted EdgeLink envelope.

## Data Model

Add shared capability structures in Android Kotlin, Swift, and worker TypeScript.

Suggested shape:

```json
{
  "device": {
    "manufacturer": "xiaomi",
    "brand": "poco",
    "model": "25102PCBEG",
    "family": "xiaomi"
  },
  "capabilities": {
    "xiaomiContinuityAvailable": true,
    "officialHyperConnectLikelyAvailable": true,
    "screenShareProtectionOverrideSupported": true
  }
}
```

Keep the schema versioned:

```json
{
  "metadataVersion": 1,
  "device": {},
  "capabilities": {}
}
```

Rules:

- Unknown fields must be ignored.
- Missing metadata must behave like `family = "generic"` and all vendor capabilities false.
- Metadata must not be part of the cryptographic device identity.
- Metadata can be refreshed after pairing through an encrypted EdgeLink envelope.

## EdgeLink RPC Control Layer

This is the clean-room answer to "Lyra RPC": build our own RPC layer because EdgeLink is already
growing one-off request/result pairs. The model is inspired only by the generic need for structured
calls between paired devices, not by Xiaomi's implementation.

Existing examples that would benefit from a shared RPC shape:

- `sms.send` / `sms.send.result`
- future file-transfer prepare / accept / progress calls
- device capability refresh
- diagnostics snapshot
- remote settings reads/writes
- screen-session capability negotiation

### Envelope Shape

Keep RPC inside the same E2EE secure frame and JSON envelope:

```json
{
  "t": "rpc.req",
  "b": {
    "id": "uuid",
    "method": "device.capabilities.get",
    "params": {},
    "deadlineMs": 5000
  }
}
```

```json
{
  "t": "rpc.res",
  "b": {
    "id": "uuid",
    "ok": true,
    "result": {
      "metadataVersion": 1
    }
  }
}
```

```json
{
  "t": "rpc.res",
  "b": {
    "id": "uuid",
    "ok": false,
    "error": {
      "code": "not_supported",
      "message": "Method is not supported on this peer"
    }
  }
}
```

Optional cancellation:

```json
{
  "t": "rpc.cancel",
  "b": {
    "id": "uuid",
    "reason": "superseded"
  }
}
```

Rules:

- `id` is generated by the requester and is unique per secure session.
- `method` uses EdgeLink-owned names, not vendor names.
- `params` and `result` must fit the existing secure frame limit unless a method explicitly opens a
  side channel.
- Unknown methods return `not_supported`.
- Duplicate `id` while a request is in flight returns `duplicate_request`.
- Responses after timeout are ignored but logged.
- Methods must declare whether they are idempotent.

### Method Namespaces

Start small:

- `device.metadata.get`
- `device.metadata.update`
- `device.capabilities.get`
- `diagnostics.snapshot`
- `transfer.prepare`
- `transfer.cancel`
- `settings.get`
- `settings.set`

Avoid vendor-shaped names such as `lyra.*`, `milink.*`, `handoff.*`, or `continuity.*` in product
code. Use capability semantics instead.

### Error Codes

Initial shared error codes:

- `not_supported`
- `bad_request`
- `unauthorized`
- `timeout`
- `busy`
- `cancelled`
- `payload_too_large`
- `internal_error`

Keep `message` debug-facing. UI should map `code` to local copy.

### Dispatchers

Add a tiny dispatcher on both sides:

- Android: `RpcClient`, `RpcServer`, `RpcMethodHandler`
- Mac: `RpcClient`, `RpcServer`, `RpcMethodHandler`

Responsibilities:

- encode/decode `rpc.req`, `rpc.res`, `rpc.cancel`
- track pending calls by id
- enforce timeout
- route methods to local handlers
- serialize responses on the same secure sender
- expose cancellation to long-running handlers

Do not let RPC own transport, pairing, encryption, or reconnection. It is only an application-layer
helper over the current secure envelope sender.

### Migration Path

Do not rewrite everything immediately.

1. Add RPC types and dispatchers with tests.
2. Add one low-risk method: `device.metadata.get`.
3. Use RPC for capability refresh after secure session establishment.
4. Migrate `sms.send` later only if the shared machinery proves useful.
5. Use RPC for file transfer negotiation before implementing large payload side channels.

## Protocol Work

1. Add metadata to device registration.
   - Android `DeviceRegistrationRequest`
   - Swift `DeviceRegistrationRequest`
   - Worker `DeviceRecord`
   - Registry public response

2. Add metadata to pairing.
   - `PairStartRequest`
   - `PairClaimRequest`
   - `PairConfirmRequest`
   - `PairingRecord`
   - `PinnedPeer`

3. Add an encrypted metadata refresh envelope.
   - Type: `peer.metadata`
   - Body:

```json
{
  "metadataVersion": 1,
  "device": {
    "manufacturer": "xiaomi",
    "brand": "poco",
    "model": "25102PCBEG",
    "family": "xiaomi"
  },
  "capabilities": {
    "xiaomiContinuityAvailable": true,
    "officialHyperConnectLikelyAvailable": true,
    "screenShareProtectionOverrideSupported": true
  }
}
```

4. Update `docs/protocol.md`.
   - Document metadata as advisory.
   - State that core behavior must not require vendor metadata.
   - Document the clean-room boundary for vendor-specific affordances.

5. Add RPC envelopes.
   - `rpc.req`
   - `rpc.res`
   - `rpc.cancel`
   - shared request/response/error bodies
   - timeout and duplicate-id behavior

## Android Work

### Device Profile

Add `AndroidDeviceProfile` under `android/app/src/main/kotlin/com/edgelink/app/` or
`android/app/src/main/kotlin/com/edgelink/core/`.

Responsibilities:

- Normalize `Build.MANUFACTURER`, `Build.BRAND`, `Build.MODEL`, `Build.PRODUCT`, and `Build.DEVICE`.
- Return `family = "xiaomi"` when manufacturer/brand contains `xiaomi`, `redmi`, or `poco`.
- Expose a stable serializable metadata object.
- Unit test casing and mixed brand/model inputs.

### Xiaomi Capability Probe

Add `XiaomiCapabilityProbe`.

Responsibilities:

- Run only when `AndroidDeviceProfile.family == "xiaomi"`.
- Use `ContentResolver.call` against public exported providers only.
- Probe:
  - basic continuity availability
  - optional official MiPlay / URL-circulate availability
- Catch `SecurityException`, `IllegalArgumentException`, `UnsupportedOperationException`,
  `NullPointerException`, and provider process failures.
- Log coarse results:
  - `device.android.vendor_probe family=xiaomi continuity=true`
  - never log private provider payloads or stack traces unless debug logging is explicitly enabled.

Implementation notes:

- Put provider authority/method/arg constants in this probe only.
- Return false on every failure.
- Time-bound the probe by running it off the main thread.
- Cache results for the current process and refresh on app start / pairing start.

### Screen-share Guard

Update `AndroidScreenShareProtectionGuard`:

- Gate Xiaomi-specific secure-setting writes behind `AndroidDeviceProfile.family == "xiaomi"`.
- Keep existing `WRITE_SECURE_SETTINGS` checks.
- Keep restore logic unchanged.
- Add tests around "generic device does not attempt Xiaomi settings".

### Metadata Flow

Update Android registration and pairing:

- Build metadata before registration.
- Send metadata during registration.
- Send metadata during pair reveal / confirm if pairing metadata is added there.
- Save peer metadata in `SharedPreferencesPairingStore`.
- Send `peer.metadata` after secure session establishment.

## Mac Work

### Peer Metadata

Add Swift equivalents:

- `DeviceMetadata`
- `DeviceProfile`
- `VendorCapabilities`

Update:

- registration request
- pairing wire structs
- pinned peer storage
- runtime state

The Mac should treat missing metadata as generic.

### Official Xiaomi Transfer Bridge

Add `OfficialXiaomiTransferBridge` or `XiaomiHyperConnectBridge`.

Responsibilities:

- Detect URL scheme availability for the official Mac app.
- Accept local file URLs only.
- Build the public URL handoff using normal macOS URL APIs.
- Open through `NSWorkspace`.
- Return clear errors:
  - app not installed
  - invalid file URL
  - open failed

UX rule:

- Show this only when:
  - paired peer metadata says Xiaomi-family, and
  - Mac URL scheme is available.
- Keep EdgeLink transfer primary.
- Make the label explicit, e.g. "Send with Xiaomi HyperConnect", so the user understands it leaves
  EdgeLink's transport.

### UI

Update Mac UI only after metadata plumbing is in place:

- Show a small peer capability line in diagnostics, not as marketing copy.
- Add optional command/menu item for official Xiaomi transfer.
- If unavailable, do not show a disabled control unless diagnostics mode is active.

## Worker Work

Update registry and pairing DOs:

- Accept optional `metadataVersion`, `device`, and `capabilities`.
- Validate size and shape.
- Store metadata as opaque JSON with a strict max size.
- Return metadata with public device records and pairing records.

Validation:

- Max metadata JSON size: 4 KB.
- Only allow JSON primitives, arrays, and objects.
- Reject metadata containing keys that look like secrets:
  - `token`
  - `password`
  - `secret`
  - `privateKey`
  - `session`
- Do not interpret Xiaomi-specific fields in the worker.

## Verification

Android tests:

- Device profile detects Xiaomi/Redmi/POCO case-insensitively.
- Generic devices do not run Xiaomi probe.
- Probe returns false on provider exceptions.
- Pairing store round-trips metadata.
- Screen-share guard skips Xiaomi setting writes on generic devices.
- RPC dispatcher routes a known method.
- RPC dispatcher returns `not_supported` for unknown methods.
- RPC client times out pending calls.

Mac tests:

- Metadata decodes with missing fields.
- URL bridge rejects non-file URLs.
- URL bridge detects unavailable scheme.
- Pinned peer metadata round-trips.
- RPC dispatcher routes a known method.
- RPC client ignores late responses after timeout.

Worker tests:

- Device registration accepts metadata.
- Metadata larger than 4 KB is rejected.
- Pairing stores host/client metadata.
- Unknown metadata fields survive round-trip.

Manual tests:

- Xiaomi/POCO device:
  - profile reports `family=xiaomi`.
  - capability probe returns expected booleans.
  - EdgeLink pairing still works if probe fails.
  - screen viewer starts and stops with restore behavior intact.

- Non-Xiaomi Android:
  - profile reports `family=generic`.
  - Xiaomi probe is not called.
  - no Xiaomi-specific UI is shown on Mac.

- Mac with official Xiaomi app installed:
  - bridge detects URL scheme.
  - optional transfer command opens official app.
  - EdgeLink transfer remains available.

- Mac without official Xiaomi app:
  - no official transfer command shown.
  - EdgeLink transfer remains available.

## Milestones

### M1: Metadata Foundation

- Add shared metadata structs.
- Update registration / worker storage.
- Update pinned peer stores.
- Add tests.

Done when Mac and Android can pair with metadata present and still pair with metadata absent.

### M1.5: EdgeLink RPC Foundation

- Add `rpc.req`, `rpc.res`, and `rpc.cancel` bodies.
- Add Android and Mac RPC dispatchers.
- Add `device.metadata.get` as the first method.
- Add timeout, unknown-method, and duplicate-id tests.

Done when metadata can be requested over the encrypted secure session without adding a one-off
envelope pair.

### M2: Android Xiaomi Profile And Probe

- Add `AndroidDeviceProfile`.
- Add `XiaomiCapabilityProbe`.
- Send metadata on registration and encrypted refresh.
- Move screen-share Xiaomi setting guard behind profile.

Done when a Xiaomi device reports capabilities and a generic device does not run vendor probes.

### M3: Mac Optional Official Transfer

- Add URL scheme detection.
- Add bridge for local file URLs.
- Add UI affordance only for Xiaomi-family peers.
- Add tests for bridge behavior.

Done when the Mac can launch official Xiaomi transfer without changing EdgeLink's own transport.

### M4: Polish And Diagnostics

- Add concise diagnostics logs.
- Add capability display in debug/diagnostics surfaces.
- Update `docs/protocol.md`.
- Add a short operator note for MI/POCO behavior.

Done when failures are understandable from logs without exposing private vendor details.

## Non-goals

- No Xiaomi protocol compatibility layer.
- No Lyra RPC compatibility layer.
- No Lyra method names, frame formats, native bindings, or service discovery.
- No MiLink Binder integration.
- No universal clipboard attachment to Xiaomi's session layer.
- No use of Xiaomi privileged permissions as a requirement.
- No private SDK linking.
- No device/account impersonation.

## Open Questions

- Should metadata be part of registration only, or also pairing reveal/confirm?
  - I prefer both registration and encrypted `peer.metadata`; pairing can carry a small snapshot but
    should not be the only refresh path.

- Should official Xiaomi transfer be a Mac-only command or part of generic file-send routing?
  - I prefer a Mac-only optional command first. It is clearer and lower risk.

- Should the Android probe request any normal Xiaomi-defined permission?
  - Not for M1/M2. Start with no new manifest permission. Add one only if we have a third-party APK
    test proving it changes useful behavior without privileged access.
