# Everyone-mode ("所有人 10 分鐘") discovery path — end-to-end map

Clean-room research, 2026-07-25. Research only; no product code changes.
Sources: `captures/mishare/jadx` (MiShare.apk), `captures/mi-connect-service/index`
(Android `libmicontinuity.so`, arm64), `mac/Sources/EdgeLinkKit/XiaomiMiShareDiscoveryPayload.swift`.

Companion to `docs/lyra-netbus-notes.md` (which covers the same-account/mesh path).

## TL;DR

Our `_lyra-mdns` ad passes the **continuity-networking (same-account, restricted-WLAN)
trust gate**, but the everyone-mode UI is fed by a **completely separate native stack**
(`lyra::netbus::disc`, "L1") plus a separate Java listener (`i2.t` /
`LyraDiffAccountShare`, serviceId `"00270525"`). That stack matches discovered devices
to discovery requests **by service id carried inside the adv data** (AppData service
map keyed by the low byte of the service id, `0x25` for `00270525`). Our AppData
contains **no service entry at all**, so the L1 layer has no reason to deliver
`onDeviceFound("00270525", …)` to MiShare. Separately, our uid-hash replay makes us a
**same-account** device, and same-account devices are expected to surface via the
mesh TDIF service-sync path (`i2.e0`), which requires a `miLyraShare` service
announce we never send. Both paths are therefore silent — exactly the observed behavior.

---

## (A) Everyone-mode Java call chain

Entry: share page scan → `i2.g0` ("LyraShare", implements `g2.c`)
constructed in `com/miui/mishare/connectivity/MiShareService.java:1207`.

- `i2/g0.java:135`: `f9947c = c0.j() ? new t(ctx, dVar) : new h0(ctx, dVar)`.
  - `i2.c0.j()` = hasFeature(GLOBAL_PERMISSION_MISHARE) + service bundle + BLE ext adv.
  - `i2.h0` is a **no-op stub** — if `c0.j()` is false there is no everyone-mode discovery.
- `g0.g(freq, from)` (startDiscover) calls **both**:
  - `i2.e0.l()` — same-account path: `NetworkingManager.addServiceListener`
    with `ServiceFilter{name="miLyraShare", deviceTypeFilter={1,2,4,21 (+11..17 if Apple
    interop)}, mediumTypeFilter={2,32,128,65536}}` (`i2/e0.java:141-158`).
  - `i2.t.l(freq)` — **everyone-mode L1 path** (`i2/t.java`, "LyraDiffAccountShare"):
    - serviceId = **`"00270525"`** (constructor, `i2/t.java:108`).
    - `i2/t.java:90-104` inner `d extends i2.l` (`DefaultLyraL1Discover`):
      `dataType = NORMAL`, `mediumType = mergeType(2,4,131072)`
      = **BLE | MDNS | BLE_APPLE = 131078** (see `MediumType.java`: 2=BLE, 4=MDNS,
      128=WIFI_LAN, 256=WIFI_LAN_1, 65536=WIFI_RESTRICT, 131072=BLE_APPLE).
    - `i2/l.java:82`: `NetBusManager.startDiscovery("00270525", StartDiscoveryOptionsV2{
      mediumType=131078, dataType=NORMAL, frequency, waitForEnvSatisfied=true})`.
    - Simultaneously `t` advertises via `i2.k0` composite: `a` (medium 2/BLE,
      data=`i2.i.j(ctx)` = BitSet{turbo,doubleP2P,appleSupport}), `b` (medium 4/MDNS,
      extData=`f0.f()`={1}), `c` (medium 131072/BLE_APPLE, empty) — i.e. a phone in
      everyone mode advertises the `00270525` service over BLE **and MDNS**.

Delivery & filter chain:

1. `i2/f.java` (`DefaultDiscoveryListener`) `onDeviceFound(serviceId, DeviceInfo)`
   → `l(t0.a(deviceInfo, "00270525"), null)`.
2. `i2/t0.java:18-20` `a(DeviceInfo, sId)` → `RemoteDevice` with extras:
   `connection_lyra=true`, `KEY_NICKNAME=deviceName`, `KEY_DEVICE_TYPE=deviceType`,
   `key_discovery_medium_type=discoveryMediumTypes`,
   `KEY_SAME_ACCOUNT/KEY_GLOBAL_DEVICE = (myUidHash == uidHash)` (`j3.i.I`),
   `KEY_DISCOVER_SOURCE=3`, `KEY_SERVICE_ID=sId`. **Fields that matter:
   deviceId, deviceName, deviceType, discoveryMediumTypes, uidHash.**
3. `i2/f.java:117` `l(RemoteDevice, DiscoveryData)`:
   - **Gate 1** `u.d(deviceType, mediumType)` (`i2/u.java`): device is INVALID unless
     - `deviceType == 4` (PC), or
     - `deviceType ∈ {1,2}` (phone/pad), or
     - `deviceType ∈ {11..17}` (`j3.i.v`) **and** `(mediumType & 131078) != 0`, or
     - `deviceType == 21` and `(mediumType & 4) != 0`.
     → our Mac (dt=14) needs `discoveryMediumTypes ∩ {BLE, MDNS, BLE_APPLE} ≠ ∅`.
     Drop log: `DefaultDiscoveryListener: invalid deviceType: %d, mediumType = %d`.
   - Gate 2 (phone types only): turbo BitSet merge via `f0.b` / cached `j3.i.u/R/V/X`.
   - `q.g(device)` → `MiShareService.g` → `h2/b.java` DeviceListManager `.e()`.
4. `h2/e.java:141` `c(RemoteDevice)`: dedupes by DiscoverSource priority — same-account
   (src=1) beats L1 (src=3); only the best source for a device id is shown.
   **No same-account filtering here** — an L1-reported device with
   `KEY_SAME_ACCOUNT=true` would still show (as long as no src=1 entry exists).

NFC/OneHop side path (not our concern but mapped): `i2.s0` ("OneHopShare") and `i2.d0`
("LyraNfcShare") use serviceId **`"00370E2E"`**, mediums `mergeType(4,2)` /
`131072` (BLE_APPLE discovery for Apple devices, `d0$c`).

## (B) Native chain (libmicontinuity.so, arm64)

### B.1 Two separate discovery stacks

| | Same-account (works for us) | Everyone-mode L1 (silent for us) |
|---|---|---|
| Native | `lyra::continuity::networking::*` | `lyra::netbus::disc::*` |
| Entry | `RestrictedMdnsNetworkingWorker` → `RestrictedWlanHandler::HandleDeviceFound` 0xba47a0 | `DiscoveryPlatformMdns::OnDeviceFound` 0x941360 |
| Trust | **gated**: `DiscoveryManager::OnReceiveData` 0xb67ed0, drop at 0xb68924 "device %s not trust" | **no trust check found** (see B.2) |
| Repo | DevRepo (`DeviceManager::AddDeviceInfo`) → `NetworkingManager` service listeners | netbus `DiscoveryDataNormal` → `JniDiscoveryListener` |
| Java | `i2.e0` (miLyraShare filter) | `i2.t` (00270525) |

### B.2 The L1 path does NOT go through the continuity trust gate

- `continuity::networking::DiscoveryManager::OnDeviceFound(uint, DeviceInfo const&)`
  0xb66998 (1536B, disasm verified): mutex → device-id map lookup → builds
  `NetworkingDeviceInfo` (0x178B) → conversion via virtual (cbz → error log) →
  listener call `[x21+0x30] vtable[0]`. **No `IsTrusted`/`IsTrustedDevice` call.**
- `DiscoveryListenerManagerImpl::IsTrusted` 0xb66198 is only consulted by the
  continuity **NetworkingManager** listener fan-out (same-account service sync),
  not by netbus L1.
- `JniDiscoveryListener::OnDeviceFound(JNIEnv*, uint serviceKey, DeviceInfo*)`
  0x885c34: iterates registered Java listeners comparing the uint key; no trust logic.

### B.3 serviceId ↔ mDNS ad association (the likely drop)

- Java `"00270525"` → native uint32 `0x00270525` (logged as `service_id=%08X`,
  e.g. "turn down the frequency by power policy, service_id=%08X").
- The netbus adv-data protocol parses the mDNS AppData blob
  (`DiscoveryProtocolBase::ParseAdvertisingData` 0x93daec):
  `[u16le flags][u8 deviceType][u32be deviceId][account block][TLVs…]`.
  - Account block length is driven by bits 1/2 of the flags u16
    (`ParseAccount` 0x93de78): u16 uid hash + optional u16/u24 extra.
  - TLVs: `[type u8][len u8][value]` (`DiscoveryProtocolMdns::GetTypeLength`
    0x940304; per-type handler `HandleAdvDataProtType` 0x93e0cc, switch on type
    0..10: connect-info→+0x54, device-name, u32/u64 fields, …).
  - **Services live in `AdvDataProtData+0x98 = map<uint8, AdvDataProtServiceData>`,
    keyed by TLV type byte** (`DiscoveryProtocolMdns::ParseServiceData` 0x940590).
    The key is the **low byte of the service id** (`0x25` for `0x00270525`,
    `0x2E` for `0x00370E2E`).
- Fan-out is per `ServiceConfig` (a startDiscovery request); note
  `DiscoveryManager::OnNewServiceId(uint)` 0x9079fc and
  `DiscoveryDataBase::ServiceConfig::OnDeviceFound` 0x918d88 — the layer tracks
  which service ids an adv introduces.
- Our AppData (`XiaomiMiShareDiscoveryPayload.swift`) decodes under this format as:
  header `02 41 0e <id4>` (flags=0x4102, type=14), account `58 1f 00 05`
  (flags bit1=1 → 4 bytes), then TLVs `0a 03 01 <port>` (connect info),
  `01 01 20`, `23 00`, `23 02 xx xx`, `02 <len> <name>` (device name).
  **No TLV type `0x25` → no `00270525` service → the L1 discovery for MiShare has
  nothing to match.** (The phone's own everyone-mode advertising adds this service
  entry via `netbus::adv::AdvertisingManager` from `startAdvertising("00270525",…)`
  with the 1–4 byte BitSet payload from `i2.f0.e/g`.)
- Secondary risk: if the account-block consumption is 4 bytes, the first "TLV"
  would actually start at `19 3f` (type 0x19 len 0x3f > remaining 22 bytes) —
  i.e. depending on how flags bits are interpreted, our AppData may fail parsing
  outright (error `0x32cb`, lyra-disc log). The phone's own ad has the same flag
  bytes, so either the real parser treats it differently than my reading, or
  phone ads carry additional bytes that realign the TLV walk. **Resolve on-device
  via lyra-disc parse-error logs (H2 below).**

### B.4 RestrictedWlan* = same-account-only side path

- `RestrictedWlanHandler::HandleDeviceFound` 0xba47a0 + `RestrictedDiscovery::*` +
  `RestrictedMdnsNetworkingWorker` implement the **WIFI_RESTRICT (65536)** same-account
  WLAN sync. This is the path our ad took (uid-hash replay → trusted_types=1 →
  `DeviceManager::AddDeviceInfo`).
- `i2/e0.java:194`: devices with `mediumTypes == 65536` are **skipped** unless
  Apple (v(type)) or PC (`F(type)` = 4/21): "Only Apple and pc device support
  restricted WLAN." So even the same-account listener would accept us as dt=14 —
  but only once the `miLyraShare` service is **online** in the DevRepo, which
  requires the mesh TDIF service announce we never send.

### B.5 `DiscoveryPlatformMdns::OnDeviceFound` 0x941360 (TXT → DeviceInfo)

- Whitelists the mock_mdns `DeviceInfo+0x60` medium against
  {0x20,0x40,0x80,0x100,0x2000,0x4000,0x8000,0x100000} (wifi family; our 0x100
  passes) → else "unsupported medium type, ignore".
- Converts mediums via `NetbusUtils::GetValidConnMediumType` 0xc63e84
  (validated against a runtime list; returns 0 if invalid).
- Copies instance name (≤40B) as device id; dedupes per (device, medium-mask) in
  a map → dup: "disabled device_id=%s, ignore".
- Does **not** parse TXT AppData itself; adv-data parsing is done by the
  DiscoveryProtocolMdns layer above it. `DiscoveryDataType.NORMAL` L1 requests use
  the same OnDeviceFound + a later `onReceiveData` carrying the per-service
  `DiscoveryData` bytes (BitSet at Java = turbo/doubleP2P flags, `i2.f0.b`).

## (C) Drop-point hypotheses (ranked)

1. **H1 — service-id mismatch (most likely).** Our AppData has no `0x25` service
   TLV, so netbus L1 never associates our device with discovery config
   `00270525`; `JniDiscoveryListener::OnDeviceFound` is never called.
   Evidence: ParseServiceData keyed by TLV type byte; `OnNewServiceId`; our
   AppData builder emits no service TLV; the Xposed bypass works precisely because
   it fabricates the *service-online* event.
2. **H2 — AppData parse rejection.** The flags-driven account block (4 bytes)
   misaligns the TLV walk (`19 3f` → len 0x3f overshoots) → `ParseAdvertisingData`
   returns 0x32cb and the device is dropped in lyra-disc with a parse error.
   Same bytes as the phone's own ad, so either tolerated or the phone's ad has
   extra trailing structure; only a live lyra-disc log settles it.
3. **H3 — same-account suppression.** Our uid hash == phone's own →
   `KEY_SAME_ACCOUNT=true`; the everyone-mode path may natively suppress
   same-account devices (they're expected via e0/mesh). No direct filter found in
   Java; if present it's in `DiscoveryDataNormal` account handling. Testable by
   changing our uid hash to a random value.
4. **H4 — Java medium filter.** If the mDNS find surfaces
   `discoveryMediumTypes = WIFI_LAN(128)/WIFI_LAN_1(256)` instead of MDNS(4),
   `i2.u.d(14, mt)` drops with "invalid deviceType". Would be visible in MiShare
   logcat; considered less likely (the platform reports MDNS as discovery medium).

## (D) Minimal Mac-side fix

1. **Add the MiShare service entry to our mDNS AppData**: a TLV for service key
   `0x25` with the 1–4 byte service payload the phone itself uses
   (`i2.f0.e/g`: BitSet{turbo=m1.v, doubleP2P=false, appleSupport=true} — e.g.
   `{0x05}` when Apple interop is on, or the 9-byte `g()` form `{1,0,romHi,romLo,18,mfrHi,mfrLo,1,3}`).
   Exact wire encoding must be captured from a real phone whose share page is open
   in everyone mode (its AppData will gain the `0x25` TLV; our existing
   `XiaomiMiShareDiscovery` listener already records phone AppData).
2. **If H3 confirmed**: stop replaying the phone's uid hash in the L1-facing
   identity; use a fresh random uid hash (sacrifices the same-account trust path,
   which is currently useless to us anyway since we don't announce services).
3. Not needed: BLE/BLE_APPLE advertising (mediums 2/131072 are alternates in the
   same mask; MDNS=4 alone satisfies the Java filter once the service id matches).

## (E) On-device experiment plan

Setup: `adb logcat` (this ROM routes module logs via VectorLegacyBridge; native via
`ContinuityRuntimeNative.nativeSetLogLevel(1)`), Mac ad running, phone 互傳 page
open in 所有人 mode (this triggers `g0.g()` → both e0 and t discovery).

Capture & interpret:

| # | Log (tag / text) | Meaning |
|---|---|---|
| 1 | `DefaultLyraL1Discover: startDiscovery, discoveryOptionsV2 = … mediumType=131078` | L1 everyone-mode discovery actually running. Absent ⇒ `c0.j()` false or page not scanning; fix test setup, not the ad. |
| 2 | `DefaultDiscoveryListener: onDeviceFound() called with: serviceId = [00270525], deviceId = [<our id>]` | **Native L1 delivered us.** If present and UI still empty → Java-side (H3/H4). If absent → native drop (H1/H2). |
| 3 | `DefaultDiscoveryListener: invalid deviceType: 14, mediumType = <N>` | H4 confirmed; N tells which medium surfaced. |
| 4 | `RemoteDeviceTransformer: isMyDevice:true` (tag printed in t0.a) | Confirms uid-replay seen as same-account; with UI absent → supports H3. |
| 5 | lyra-disc: `appdata` / error `0x32cb`(=13003) / `ParseAdvertisingData` errors near our device id | H2 confirmed → realign AppData TLVs. |
| 6 | lyra-disc: `OnNewServiceId` / `service_id=00270525` lines mentioning our device id | Service match worked → problem is downstream (Java). |
| 7 | lyra-mdns-core / lyra-mdns-jni: TXT dump of our ad (`AppData=`, `appdata_len=`) | Confirms the ad bytes the phone parsed (guard against TXT truncation/encoding bugs). |
| 8 | `LyraSameAccountShare: onServiceOnline / onDeviceAddOrUpdate` | Should be absent for us (no mesh service announce) — confirms the same-account path is unused. |

Experiments (in order):

1. **Baseline** (current ad): expect no (2). Note which of (5)/(6) appear → H1 vs H2.
2. **Phone AppData delta**: with our Mac listener running, open the phone's own
   互傳 page in 所有人 mode and diff its `_lyra-mdns` AppData before/after
   (`XiaomiMiShareDiscovery` logs, or `dns-sd`/`adb shell cmd mdns`). The delta is
   the exact service TLV to clone (answers F1 encoding without guessing).
3. **Ad + cloned `0x25` TLV**: expect (2) to appear, then device in UI.
4. **Random uid hash variant** (if 3 still fails and (4) showed isMyDevice:true):
   distinguishes H3.
5. If (2) appears but UI empty with no (3): inspect `DeviceListManager`/
   `LyraDiscoverSourceHelper` logs for dedupe against a stale same-account entry.

## Reference: key addresses (libmicontinuity.so arm64)

- `netbus::disc::DiscoveryPlatformMdns::OnDeviceFound` 0x941360
- `netbus::common::NetbusUtils::GetValidConnMediumType` 0xc63e84
- `netbus::disc::DiscoveryProtocolBase::ParseAdvertisingData` 0x93daec
- `…::ParseAccount` 0x93de78, `…::HandleAdvDataProtType` 0x93e0cc
- `netbus::disc::DiscoveryProtocolMdns::GetTypeLength` 0x940304,
  `::ParseServiceData` 0x940590, `::ParseConnectInfo` 0x940498
- `netbus::disc::DiscoveryDataNormal::RealtimeDiscoveryCheck` 0x922fbc,
  `::NotifyLostChangeFoundReceive` 0x928400, `::GetDeviceInfo` 0x926000,
  `::SetNotifyOnDeviceFound` 0x92a5cc, `::IsDiscoveryDistanceValid` 0x9280bc
- `netbus::disc::DiscoveryManager::OnNewServiceId` (thunk 0x9079fc)
- `netbus::disc::JniDiscoveryListener::OnDeviceFound` 0x885c34
- `continuity::networking::DiscoveryManager::OnDeviceFound` 0xb66998 (no trust gate)
- `continuity::networking::DiscoveryManager::OnReceiveData` 0xb67ed0
  (trust gate, drop 0xb68924)
- `continuity::networking::RestrictedWlanHandler::HandleDeviceFound` 0xba47a0
