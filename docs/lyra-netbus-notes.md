# Lyra netbus protocol notes (Xiaomi Mi Share / HyperConnect interop)

Clean-room protocol spec recovered from binary evidence. Sources:
`captures/xiaomi-hyperconnect/3.0.300-285` (macOS micontinuity_sdk.framework, x86_64+arm64),
`captures/mi-connect-service` (Android libmicontinuity.so + jadx), live mDNS/socket
observation of a stock Xiaomi phone (HyperOS) on the local WLAN.

All offsets/addresses below refer to the arm64 slice of the Mac framework unless noted.

## Topology

- Discovery: mDNS `_lyra-mdns._udp.local.`, instance = 8-hex device id, TXT keys
  `AppData`, `MediumType`, `CH`, `DebugInfo`. SRV port is always 5353 (placeholder,
  not the data port).
- **AppData embeds the device's live mesh port.** Inside the AppData blob, the TLV-ish
  segment `07 0a 03 01 <2 bytes> 01 01 20` carries the mesh port big-endian.
  Live confirmation (2026-07-20): phone AppData `...07 0a 03 01 e8 97 01 01 20...`
  → 0xE897 = 59543, and `connect_service` (MiConnectService, pid) holds UDP *:59543.
  The phone's other AppData bytes (`23 02 a4 46`, `23 00`) not yet assigned.
- The phone runs NO TCP listener for netbus; its mesh socket is UDP (owned by
  connect_service). Mac must therefore run the mesh over UDP too (the Mac framework
  has `base_tools::AsyncUDPSocket`; TCP `AsyncTCPSocket` also exists for other media).
- Medium: ConnectMediumType.WLAN = 128 (0x80) is the Apple interop medium.

## Transport framing — TransPackMesh (mesh pack format)

`lyra::netbus::trans_manager::TransPackMesh::EncodeData` (0x240054) /
`OnDecodeData` (0x23fd20):

```
byte 0   : 0x01 | (packType << 3)      ; bits 0-2 flags (always 0x01), bits 3-7 packType
byte 1   : headerLen                   ; encode hardcodes 0x04; low nibble used on decode
byte 2-3 : total frame length          ; big-endian uint16, INCLUDES the 4-byte header
payload  : total - headerLen bytes     ; optional ext header (headerLen-4 bytes) then payload
```

- Encode limit: payload + 4 <= 0x10000 (payload max 65532).
- Decode: `packType = byte0 >> 3`; `extLen = (byte1 & 0xF) - 4` (must be >= 0, i.e.
  byte1 low nibble > 3); ext header copied out, remainder = payload.
- Error return 0x4653 on oversize/invalid.
- packType values observed in code: TransChannel keeps 3 TransDataBuffers indexed by
  pack type 0..2 (`TransChannel::GetTransBuffer` 0x2393bc: buffer at 0xe0 + type*0x20,
  fallback buffer at 0x100 for type >= 3). Semantic mapping TBD (likely 0=control,
  1=bytes, 2=file — matches micont::channel Packet types 1=bytes/2=file).

## Protocol stack inside a mesh payload

Payload = serialized protobuf `MiConnectFrame` (protobuf-lite, no reflection; field
numbers recovered from generated `_InternalSerialize` code).

```
MiConnectFrame {                       ; _InternalSerialize 0x20617c
  uint32 version        = 1;           ; varint, obj+0x18
  V0Frame frame_v0      = 2;           ; message, obj+0x10
}

V0Frame {                              ; _InternalSerialize 0x206dcc
  repeated LogiConnFrame logi_conn_frames = 1;   ; count +0x18, ptr +0x20
  PhysConnFrame phys_conn_frame             = 2; // optional, obj+0x28
}

LogiConnFrame {                        ; _InternalSerialize 0x1efaf4
  uint32 logi_conn_id   = 1;           ; +0x18
  uint32 local_net_id   = 2;           ; +0x1c  (name TBD)
  uint32 remote_net_id  = 3;           ; +0x20  (name TBD)
  bool   flag           = 4;           ; +0x24  (name TBD)
  bytes  inner          = 5;           ; +0x10, serialized LogiConnInnerFrame
}

PhysConnFrame {                        ; _InternalSerialize 0x208f90
  uint32 f1             = 1;           ; varint (id?)
  uint32 f2             = 2;           ; varint
  oneof payload {
    PhysConnSyncDeviceInfoRequestFrame  sync_device_info_request  = 3;
    PhysConnSyncDeviceInfoResponseFrame sync_device_info_response = 4;
    PhysConnUpdateDeviceInfoFrame       update_device_info        = 5;
    PhysConnUpdateNetworkInfoFrame      update_network_info       = 6;
    PhysConnKeepAliveRequestFrame       keep_alive_request        = 7;
    PhysConnKeepAliveResponseFrame      keep_alive_response       = 8;
    PhysConnDisconnectionRequestFrame   disconnect_request        = 9;
    PhysConnDisconnectionResponseFrame  disconnect_response       = 10;
  }
}

LogiConnInnerFrame {                   ; _InternalSerialize 0x1eebe8
  uint32 frame_type     = 1;           ; varint
  oneof payload {
    LogiConnRequestFrame      logi_conn_request        = 2;
    LogiConnResponseFrame     logi_conn_response       = 3;
    LogiConnResponseAckFrame  logi_conn_response_ack   = 4;
    LogiConnDisconnectFrame   logi_conn_disconnect     = 5;
    LogiConnSyncInfoFrame     logi_conn_sync_info      = 6;
    LogiConnUpgradeFrame      logi_conn_upgrade_frame  = 7;
    AuthHandshakeFrame        logi_conn_auth_handshake = 8;
  }
}
```

Inner message field detail (partially recovered, to be completed):
- LogiConnRequestFrame: varint fields 5,6,7 seen; has `options` (LogiConnRequestOptions)
  and `service_name` (string, xref "MiConnectProto.LogiConnRequestFrame.service_name").
- LogiConnResponseFrame: has `tunnel_capacity` (TunnelCapacity).
- LogiConnResponseAckFrame: has `options` (LogiConnResponseAckOptions).
- LogiConnSyncInfoFrame: varint field 7; has `uid_feature`, `service_name`.
- DeviceInfo: varint fields 5,7; has `device_state_info`, `wifi_capabilities`.
- AuthHandshakeFrame: exists (0x48c7cc), fields TBD.
- Aux messages: LogiConnRequestOptions (varint field 5; `tcp_tunnel_profile`),
  TcpTunnelProfile, TunnelCapacity, ConnectMediumServerConfig/ClientConfig,
  KcpConfig, WifiP2pConfig, WifiAwareConfig, LogiConnServerQuery/ServerAvailableFrame
  (server_query has `client_config`, server_available has `server_config`),
  PhysConnExtOptions, NetworkInfo, WifiInfo, UidFeatureInfo.

## Auth / trust (from Android libmicontinuity.so, captures/mi-connect-service/index)

- `LogiConnUtils::AuthRequired(TrustLevel)` (LC-AuthRequired.txt):
  `return trustLevel != 64 (0x40)`.
- `ChannelUtils::IsAuthed(TrustLevel)` (CHU-IsAuthed.txt):
  `return (level - 1) < 32` → levels 1..32 are "already authed" levels.
- MiShare services (miLyraShare, miLyraShareTransfer, miShareBasic, id 00270525)
  register with ServerChannelOptions(trustLevel=48 = EVERY_ONE) → AuthRequired(48)=true,
  so an auth handshake runs; TrustLevel2AuthType (CA-TrustLevel2AuthType.txt) maps
  levels to auth-type constants {2,4,6,8,0x10,0x20,0x26}; the EVERY_ONE mapping and
  whether a no-cred peer passes is still the open Phase-0 question
  (fallback: Xposed hook on the phone).
- Trust gate for discovery: devices surface to MiShare UI only via the trusted repo
  fed by same-account cloud list; gate log: "device %s not trust, not same account,
  do not report". Phase 0.3 plans an Xposed trust-injection to bypass.

## Socket layer

- `base_tools::AsyncUDPSocket` / `AsyncTCPSocket` (webrtc-style async sockets).
- KCP exists only under `lyra::netbus::mpt` (Miplay transport, 妙享) — likely NOT
  used for the MiShare mesh.
- `BasicPacketSocketFactory::CreateServerUdpSocket(addr, minPort, maxPort)` binds
  within a port range (mesh port is chosen at runtime, then published in AppData).

## Open questions

1. packType semantics (0/1/2) and whether LogiConn vs PhysConn frames use different
   packTypes or a single one.
2. MiConnectFrame.version value on the wire (probably 0).
3. Encryption: SOCKET_CHANNEL_KEY_LENGTH=32 suggests per-channel AES; whether mesh
   payloads or only channel payloads are encrypted, and key derivation (auth
   handshake output) — decode when implementing the channel layer.
4. Inner message full field maps (recover from _InternalSerialize as needed).
5. Whether the phone accepts a UDP mesh from a Mac AppData peer without any
   account — Phase 0.3 on-device test.
6. LogiConnFrame fields 2/3/4 semantics (net ids, flag) — confirm with live capture.

## Live-session findings (2026-07-20 evening)

### UDP mesh = KCP

The 24-byte outer header on the mesh UDP socket is a standard KCP header:
`conv=0x12345678` (fixed magic, validated by
`MiplayTransportSession::CheckFirstPacket`), `cmd` 0x51=IKCP_CMD_PUSH /
0x52=IKCP_CMD_ACK, `frg`, `wnd=0x1000`, `ts`, `sn`, `una`, `len`.
Payload = TransPackMesh frame as documented above. The phone KCP-ACKs our
replies → transport accepted; failures are application-layer.

### PhysConn sync exchange (observed live)

Phone → Mac: PhysConnFrame{1: phys_conn_id (random u32), 2: 1 (=role client),
3: PhysConnSyncDeviceInfoRequestFrame{1: ts_ms, 2: DeviceInfo, 3: 256, 5: 128,
6: NetworkInfo{1: 256, 2: 56, 3: 1, 5: ""}, 7: {}}}.
Expected reply (from `PhysConnProtocol::SetSyncDeviceInfoResponseFrame`
0x1d04e4 + `ConvertToPb` 0x1d0670 + response serializer 0x20b404):
MiConnectFrame.version=0; PhysConnFrame{1: same phys_conn_id, 2: 2 (role server),
4: PhysConnSyncDeviceInfoResponseFrame{1: ts_ms, 2: DeviceInfo, 3: u32, 4: string,
5: u32, 6: repeated NetworkInfo}}.

DeviceInfo field map (live + serializer):
2: device_id string, 3: device_type (1=phone, 14=MacBook), 4: uid hash ASCII
("61F2"), 5: varint flag=1, 6: display_name, 8: os version string ("OS3.0"),
9: conn_medium_types bitmask (phone: 0x410A3), 10: submsg {1: fixed32},
11: rom version string, 12: submsg {1: 1}.

### Trust injection works; link addr is the current blocker

- Xposed hook `hookMiShareLyraTrustInjection` (MiLinkPrivilegeXposedHook.kt)
  captures MiShare's ServiceListener via NetworkingManager.addServiceListener and
  injects synthetic onServiceOnline (config JSON
  /data/local/tmp/edgelink-mishare-inject.json). Phone MiShare UI lists our Mac. ✅
- The native stack also accepts our ad as same-account trusted because our AppData
  replays the phone's own uid-hash bytes ("61F2") — `trusted_types=1`,
  `DeviceManager::AddDeviceInfo` fires. ✅
- PhysConn sync request/response completes (KCP ACKs). ✅
- Channel open then fails: `onChannelCreateFailed err_code=15011`,
  `LogiStateRequestIdle::CheckConnReuseAndConflict: "logical conn no device
  link addr"` — the LogiConn layer has NO link address for us.
  Root cause: our mDNS ad lacks the `DebugInfo`/`MediumType`/`CH` TXT keys.
  Phone ads carry `DebugInfo={msg:hello, ifname:wlan0, v4:<obfuscated-ip>,
  v6:<obfuscated-ip>}` — the link addr comes from there.

### DebugInfo IP obfuscation — PrivacyUtils::EncryptIpAddr (libmicontinuity 0xeae9e8)

For the substring strictly between the first and last separator ('.' for v4,
':' for v6): every digit char c (0x30-0x39) is replaced with c-0x0D.
Example: "10.5.51.78" → "10." + "(.($" + ".78". A per-process random bit
(offset 0x1005a58) gates whether obfuscation is applied at all, so plain IPs
also appear in the wild — we can publish plain IPs first.

### Log access

- `adb logcat -d | grep "EdgeLinkMiLinkHook"` (module logs route through tag
  VectorLegacyBridge on this ROM's Vector Xposed variant — `logcat -s` does NOT work).
- Native lyra logs: tag prefixes lyra-*; verbose level via
  ContinuityRuntimeNative.nativeSetLogLevel(1), boosted from the
  com.xiaomi.mi_connect_service hook.
- Mac mesh diagnostics: ~/Library/Application Support/EdgeLink/diagnostics.log,
  keys xiaomi.mishare.mesh_rx / mesh_sync_request / mesh_sync_response.

## Live-session findings (2026-07-21)

### Environment gotchas

- **AP client isolation kills everything silently.** mDNS (multicast) passes, all
  peer unicast (KCP mesh, ping) is dropped → phys sync never arrives, and even the
  official 小米互联服务 app fails ("no trusted device" for clipboard, transfers fail).
  Verify with `adb shell ping <mac-ip>` before debugging protocol.
- The official Mac app does **not** advertise `_lyra-mdns` at all (Mac→phone
  visibility comes from BLE + same-account cloud/REMOTE). Its lyra discovery/
  advertising is **app_focus gated**: `DiscoveryPlatformBase::IsAllowDiscovery:81
  not allow, app_focus=0` — the window must be focused or it goes dark.
- Our ad now carries `DebugInfo` (plain IPs OK), `MediumType=256`, `CH=<wifi ch>`;
  phone ad also has a `TS=<ms>` key (not required from us).

### KCP session state (critical)

`LyraMeshDatagram` is standard KCP (conv 0x12345678, cmd 0x51 PUSH / 0x52 ACK).
**Every PUSH on a conv needs its own incrementing sn and correct una.** Early
builds sent sn=0/una=0 forever; the phone KCP-ACKed them but its app layer
silently discarded every PUSH after the first → looked like "app-layer rejection"
with retry loops. `LyraMeshSocket` now tracks per-connection `{nextSendSn,
recvUna}`, dedupes `sn < recvUna`, and sends KCP-ACK for each received PUSH.

### Phys-conn sync DeviceInfo (corrected, from official pcap ground truth)

- field 3 = const 1 (NOT device_type), field 5 = device_type (14=MacBook, 1=phone)
- field 8 = OS version string ("26.5.2"), field 9 = conn_medium_types
  (Mac 0x40082, phone 0x410a3 — we now send 0x40082)
- field 10 = submsg {1: fixed32 0x1001} (present in both phone and official Mac)
- field 11 = rom/app version ("5.1.174.10.6031221" mimics official)
- Response: no field 5; NetworkInfo = {1:256, 5:""} only.

### LogiConn establishment (works end-to-end)

1. Phys sync req/resp (packType 1), then LogiConnSyncInfo (packType 2,
   inner frame_type=5, field 6). Request: {1: session_id, 2: trust (48=EVERY_ONE),
   4: "com.xiaomi.hyperconnect:miLyraShareTransfer", 5: uid_feature{8B id, 32B hash}}.
   **Mirroring the request back** (same session/trust/uid_feature) is accepted.
2. Auth handshake rides inner **frame_type=6, field 7** =
   `MiConnectProto.AuthHandshakeFrame{f1: handshake_id, f2: HandshakeFrame}`.
   `HandshakeFrame{f1: family, f2: message_class, oneof}`:
   - families: 1=PasskeyPair, 2/6=AccountPair variants, 5=KeyAgree
     (`XxxHandshake::GetType()`; `HandshakeBase::MakeHandshakeMessage` stores
     GetType()→f1, MessageType→f2)
   - message_class: 1=alert, 4=AccountPair msg, 6=KeyAgree msg
   - oneof cases: 3=AlertFrame, 4=PasskeyEntryPair, 5=NumericComparisonPair,
     6=AccountPairFrame, 7=AuthFrame, 8=KeyAgreeFrame
   - PairFrame: {1: role (1=client/2=server), 2: client_notify, 3: server_notify,
     4/5: finished}
   - ClientNotify: {1: SupportedCipherSuites{1:1, 2: client_random(32B),
     3/4: cipher ids, 5: GenericPublicKey{1: type, 2: 65B P-256 X963 pubkey}},
     3: AuthExtParam{1:1}}
   - ServerNotify: {1: SelectedCipherSuite{1:1, 2: server_random(32B),
     3/4: selected ciphers, 5: server pubkey}, 3: SupportedCapacity{1:1},
     4: AuthExtParam{1:1}}
   - AlertFrame: {1: code, 2: message}; e.g. code 3 "bad message type"
     (wrong family/class), code 5 "bad server notify message" (content rejected).
3. Phone tries AccountPair family 2, then family 6 (fresh random+key each),
   then **falls back to KeyAgree family 5** (ciphers change 16,8 → 32,2).
   AccountPair server side requires an account long-term identity key
   (GenericPublicKey type ≥ 2 + identity memcmp in
   `HandshakeBase::ParseSelectedCipherSuite` Android 0xcf4708) — cred wall,
   expected; KeyAgree path has no such requirement.

### KeyAgree session key + channel encryption (fully solved)

- `KeyAgreeHandshake::GenerateSessionKey` (Android 0xd034a4):
  `CryptoUtil::Hkdf256` (0x859584, wraps mbedtls_hkdf SHA256):
  `key = HKDF(ikm=ECDH P-256 shared secret (32B X963), salt=<32-byte protocol
  constant 5ed5a3f836f6b54f7b1efad02714d5177b8a1f0f19e369cc0be8d98ba6297317>,
  info=clientRandom ‖ serverRandom)` → 32-byte AES-256 key.
- Encrypted LogiConn frames have `LogiConnFrame.flag (f4) = 1`; inner =
  `[12-byte GCM nonce][ciphertext][16-byte GCM tag]`, no AAD
  (`CryptoUtil::AesGcmEncrypt` 0x85a048: out = len+0x1c).
- Full open sequence (all encrypted after KeyAgree server notify):
  phone → LogiConnRequest (inner frame_type 1, field 2; service
  `com.xiaomi.hyperconnect:miLyraShareTransfer`, options contain client package
  `com.miui.mishare.connectivity`, 95-char colon-hex id, base64 token,
  tcp_tunnel_profile) → we reply LogiConnResponse (frame_type 2, field 3,
  **empty body works**) → phone → LogiConnResponseAck (frame_type 3, field 4,
  empty). Phone Java: `OnChannelConfirm` → `ConfirmChannel(accept=0)` →
  `LogiWorkflow: after=9(kConnected), res=0(success)`.
- Phone re-establishes the whole flow (phys sync → sync_info → auth → request)
  on a **channel-dedicated UDP source port**; each new endpoint needs fresh KCP
  state (already handled).

### Current blocker: post-connect silence (2026-07-21 end of session)

After ResponseAck the phone sends only phys keepalives for ~10s, then
LogiConnDisconnect (reason 29005) → UI 待接收 → 連接異常. The MiShare transfer
protocol (from MiShare.apk jadx `x2/d.java`) is `FileSendProtocol{tag, body}`
in channel Packets (type 1 = bytes, type 2 = file):
tags 1=FileSendRequest, 2=FileSendRequestResponse, 3/4=Cancel(+Resp),
5/6=Error(+Resp), 7/8=Complete(+Resp), 9=PreCheckMsgRequest, 10=PreCheckMsgResponse,
11=SendVerifyRequest, 12=SendVerifyResponse, 13=BasicChannelRequest,
14=BasicChannelResponse, 15=BackgroundWaitRequest.
The sender never emits the first Packet.

Hypotheses:
- A. Receiver must send a transfer-level accept/ready first (which message is TBD).
- B. (favored) Sender uses **DoubleConnection**: basic leg (service `miShareBasic`)
  + advance leg (`miLyraShareTransfer`). Our Xposed injection only advertises
  `miLyraShare`, and both observed LogiConns went to `miLyraShareTransfer`, so the
  basic leg likely never completes → sender state machine stalls.
  Evidence: receiver-side `a3/u.h0()` maps `miShareBasic` → DoubleConnection
  (s2.t) with advance `miLyraShareTransfer`; sender has
  `BasicChannelRequest{action:"create_advance_channel"}` (y2/e1.java Q0()).
  Next: extend `MiShareTrustInjection.kt` to inject multiple services
  (miLyraShare + miShareBasic), redeploy, then answer BasicChannelRequest with
  BasicChannelResponse (tag 14).

Ground-truth artifacts: `/tmp/official-lyra.pcap` (official phone→Mac success,
but already-encrypted same-account path), phone pid for mi_connect_service
logs 15069 (lyra-* tags).

### Live-session findings (2026-07-21, session 2)

- **Phys keepalive root cause found & fixed (hypotheses A/B above were wrong)**.
  Phone-side phys RX timer is 10s: `PhysConnHandler::OnTimerReceiveFunc keep
  alive timeout and close, elapsed=10700, timeout=10s` → code 16032 →
  LogiConnDisconnect. We never answered phys keepalives.
- **PhysConnFrame wire mapping corrected** (old enum was shifted by one for
  fields 6-10). Ground truth from official pcap + phone native logs
  (`PhysConnHandler::DoSendProtocolFrame frame_type=N`):
  - wire f3 = sync_device_info_request (frame_type 1), f4 = sync_device_info_response (2)
  - wire f5 = update_device_info (3)
  - wire f6 = keep_alive_request (4), wrapper field2=4, payload `{1: tick_varint, 2: 1}`
    sent every ~2.7-10s by BOTH sides (official Mac sends every ~5s)
  - wire f7 = keep_alive_response (5), wrapper field2=5, payload `{1: tick, 2: role, 3: tick2}`
  - wire f8 = disconnect_request (6), wrapper field2=6, payload `{1: unix_ms}`
  - wire f9 = disconnect_response (7), wrapper field2=7, payload `{1: unix_ms}`
  - (no update_network_info on wire; old "updateNetworkInfo" field-6 frames were
    actually keep_alive_requests)
- LyraMeshSocket now sends periodic field-6 keepalive every 5s per active
  inbound connection (started from `start()` — must NOT be started before
  `start()` because `stop()` cancels the timer). LyraMeshResponder answers
  field-6 with keepAliveResponse and field-8 with disconnectResponse.
  PhysConnFrame.serialized() now omits zero field1/field2 (matches official).
- Result: phys conn survives past 10s; phone now fails at **25s with 52008**
  (`ContinuityService.ConnectionManager onChannelCreateFailed channelId N code
  52008` → `MiShare miLyraShareTransfer:onConnectFailed 52008 nfcErr -3001`).
- **Xposed multi-service injection done** (module versionCode 4):
  `MiShareTrustInjection` supports `services` array in
  `/data/local/tmp/edgelink-mishare-inject.json` (miLyraShare + miShareBasic),
  keyed by the listener's registered service-filter name. Note: the MiShare
  app only ever registers a `miLyraShare` filter listener; miShareBasic is
  injected only if such a listener appears. Also: listener registration only
  fires when the 互傳 page/switch is (re)opened — force-stopping the app
  requires re-opening the page before injection works again.
- **Real blocker after keepalive fix: miexpress (ExpressChannel) handshake**.
  MiShare wraps the Lyra channel in miexpress (`com.xiaomi.miexpress`,
  native libmiexpress on phone, `miexpress.framework` inside official Mac
  app). Java flow: `createChannel(miLyraShareTransfer)` → Lyra kConnected →
  `onChannelConfirmV2` → then waits for **ExpressChannel handshake (HSHK)**
  → 25s → `ExpressChannelImpl::OnChannelCreateFailed [ECH N][MAIN][HSHK]`
  52008. Only after HSHK does `onChannelCreateSuccess` → `SendAndReceiver:
  onConnected` → PendingHandler gate opens → FileSendRequest. The phone never
  speaks first after ResponseAck; the **server (receiver) sends the first
  express frame**.
- **Express architecture** (from miexpress.framework disasm, arm64):
  - Lyra channel (cch1, service miLyraShareTransfer) = "event socket" carrying
    `TlvExpressFrame`s; bulk data goes over a second channel (cch2, "data
    socket") that the client opens to the server's advertised `data_port`
    (likely TCP-tunneled; cf. `MiConnectProto.TcpTunnelProfile`,
    `lyra.netbus.conn.tunnel.TunnelPortPairInfoFrame`,
    `TunnelActionFrameConnect.destination_address`).
  - Server flow: `ExpressServerChannel::ProtoHandshakeWithClient()` (0x318cc)
    → enqueues lambda (0x31a60): builds 16-byte random key (`rand()` bytes),
    name = `"ECH"+to_string(cch_id)`, calls
    `ExpressDataSocket::NewServer(name, &port, 8, key, timeout)` (0x21f88),
    then sends EVENT_HANDSHAKE frame via `ProtoSendChannelFrame` with filler
    (0x32004):
    `oneof.select(1)`, handshake child tag2 = `[server+0x1f0]` byte
    (enable_multilinks), child tag3 = data_port, child tag4 = 16B key string,
    child tag5 byte = 8.
  - Client flow: `ExpressClientChannel::ProtoHandshakeWithServer(lock,
    TlvHandshake)` (0x1d97c), logs `[HSHK]With server, ab=%d`, `Create cch2,
    server_ch_id=%d, cch_usrdata_sz=%d`, `cch_=%s:%d`.
- **TLV wire format** (miexpress::common::tlv):
  - Node header 8B: `u16be type | u16be tag | u32be length`.
  - Types: 1=byte(char), 3=int32, 4=int64, 5=string(raw bytes, no inner len),
    0x100=TlvNodes(container), 0x101=TlvOneOfNodes.
  - Ints big-endian; container payload = concatenated child nodes;
    oneof payload = `i16be selectedTag` + selected child node serialization.
  - `TlvExpressFrame` = TlvStructBase whose root is a TlvOneOfNodes
    (tag=0xffff, type 0x101) over the frame's item list; children include
    TlvHandshake(tag 1), TlvNodes(tag 2), plain node(tag 0), string node,
    byte node(tag 2), TlvStreamSnd, ...
  - **TlvHandshake = TlvNodes(tag=1, type 0x100), 6 children**:
    tag0 int32 (default 0), tag1 int32 (default 1), tag2 int32 = multilinks
    flag, tag3 int32 = data_port, tag4 string = 16-byte key, tag5 byte = 8.
  - EVENT_HANDSHAKE frame bytes =
    `01 01 ff ff <len32>` `00 01` `01 00 00 01 <len32>` + 6 child nodes.
- **Channel data on the logi conn**: no LOGI_CONN_DATA frame type exists;
  `LogiConnHandler` has separate entries `OnPhysReceiveLogiData` (control)
  and `OnPhysReceiveUserData` (app data). Encrypted LogiConnFrame
  (f4 flag=1, inner = [12B nonce][ct][16B tag]) carries either a
  LogiConnInnerFrame protobuf (control) or raw channel bytes (user data).
  Channel Packets (type 1 bytes / type 2 file) wrap
  `FileSendProtocol{tag, body}` and, at the express layer, are further
  wrapped inside TlvExpressFrames (`ProtoSendBytes`/`ProtoSendStream` fill
  TlvExpressFrame lambdas).
- Sender Java gate (why nothing was sent): `b3/e0` (LyraShareSender)
  `onFileProcessSuccess` queues t0 into `j3/k0` PendingHandler gate A;
  gate opens in `x2/m.N()` (onConnected) which fires only after
  `onChannelCreateSuccess`. Never reached → FileSendRequest never sent.
- Medium-type check: sender uses DoubleConnection proxy `s2.l` only if
  `j3.i.Y(device)` = extras `key_discovery_medium_type` ⊆ 0x20002; our
  injection uses medium_types=128 → simple proxy `s2.u` (so DoubleConnection
  hypothesis B is doubly dead).
- Next: after LogiConnResponseAck, send EVENT_HANDSHAKE TlvExpressFrame as
  encrypted channel data + listen for the cch2 data connection (need to
  determine whether cch2 is raw TCP or tunnel LogiConn), then the phone
  should complete HSHK and emit FileSendRequest.

### Live-session findings (2026-07-21, session 4)

- **The missing "channel-init" is NOT the 2172B announce** — the 2172B
  payload is just the periodic `TrustedDeviceInfoFrame` service announce on
  the long-lived mesh conn (both directions, sent regularly). The real gate
  is a **60-byte lyra-channel command on the channel's own LogiConn**:
  `ChannelProtocol` 16B header (`10 00 <type> 10 <totalLen16be> ...`) +
  `ChannelProto.ResponseOfPeerPort` (type 3): `{f1: peer_channel_id,
  f2: server_channel_id, f3: socket_port, f5: 1, f7: 32B server key}` =
  exactly 60B with a 32B key. On receive the phone does
  `ChannelHandler::HandleChannelCreate` → opens a MiplayTransport KCP socket
  to the given port (conv `0x12345678`, first datagram ≥25B, no app-level
  accept handshake).
- **The phone's channel_id + trans key ride inside the LogiConnRequest
  private_data** (quick-conn style; no explicit request frame is sent):
  private_data.f10 = embedded `RequestOfPeerPort` proto
  `{f1: channel_id, f4: 32B trans key (raw), f5: 32B random}`.
  private_data.f3 (95-char colon-hex 32B) is a DIFFERENT key — do not use it
  for the socket channel. When the phone does send an explicit
  `RequestOfPeerPort` (ChannelProtocol type 2, e.g. 99B with keys), it
  carries f1=channel_id, f4=key, f5=random — handle both paths.
- **Response f1 must equal the phone's channel_id** or the phone drops it:
  `ChannelClientHandler::HandleReceivePayload:453 ... code=52013
  "channel invalid id"`.
- **LogiConnFrame semantics (corrects earlier mapping)**: f1 = sender's
  local net id (u8, sequential per phys conn from 1), f2 = sender's remote
  net id, f3 = logi_conn_id (random u32), f4 = flag, f5 = inner.
  payload-v2 `[netId][flag]...`: netId = the RECEIVER's local net id
  (peer's f1). On reused phys conns the phone demuxes strictly
  (`LogiConnPhysReuse::OnPhysConnPayloadReceived:1093 ... local_id=0` drop);
  on fresh conns it tolerates any netId.
- **Socket channel data plane**: after the KCP connect, the phone sends a
  54-byte PLAINTEXT TLV negotiation (oneof tag 0, TlvNodes tag 0:
  `{i32 tag0 = server_channel_id, i32 tag1 = version 1, i32 tag2 = mtu
  0xff00}`; 78B with KCP header). Server must reply PLAINTEXT oneof tag 4
  (TlvNodes tag 4: `{i32 tag0 = server_channel_id, i32 tag1 = 0xff00}`,
  42B). Only after the reply does the phone install the SocketPacket key and
  fire OnChannelCreateSuccess.
- **Encrypted data framing (post-negotiation)**: ChannelFrame TLV (oneof
  tag 1 = data, TlvNodes tag 1 containing a string node with the raw payload,
  e.g. the 99B EVENT_HANDSHAKE) → fragment layer
  `[u16le flags=0x9882 (encrypted, bytes) / 0xB882 (plaintext body) / 0xD882
  (file)][u16be bodyLen][u16be offset][u16be totalCount][nonce 12B]
  [AES-256-GCM ct][tag 16B]` → SocketPacket
  `[0x81 0x04 len16be][nonce 12B][AES-256-GCM ct][tag 16B]` → KCP PUSH.
  GCM key = **the phone's 32B trans key** (request.f4 / private_data.f10.f4)
  for both layers and both directions (SetSocketPacketSync(session,
  impl+0x90) where impl+0x90 = ChannelInfo.key = client trans key).
  The response.f7 server key is only used for GenUserSecretKey
  (SHA256(salt ‖ f5-random ‖ server-key)) — not for socket data.
- Errors seen: 52008 = 25s channel negotiate timeout (no response sent);
  52013 = response.f1 wrong; 15056 = "logical conn medium type disable"
  (phone has no link addr for us — mDNS/network issue, not protocol);
  15011 = "logical conn no device link addr"; 16006 = phys conn timeout.
- Testing note: after network switches the Mac app must be restarted so the
  mDNS DebugInfo/A-record picks up the new en0 IP, or the phone never
  resolves a link addr (15056).



### Live-session findings (2026-07-21, session 3)

- **Channel-data wire format solved (payload-v2)**. TransDataType enum
  (Mac micontinuity `ConnectionUtils::ToStr(TransDataType)`):
  1=physical, 2=logical, 3=auth, 4=payload(encrypted), 5=payload-v2, 6=tunnel.
  TransPackMesh packType maps 1:1 (0x09=phys, 0x11=logi, 0x29=payload-v2).
  `DoLogiSendPayloadFrame` picks type 5 iff `GetSupportNoSecurity() != 0`
  else type 4. Phone logs show it uses `options={type=5(...)}`.
- **payload-v2 frame = `[netId&0xff][flag][nonce 12B][GCM ct][tag 16B]`**
  for encrypted (flag=1), wrapped as TransPackMesh packType 5 (0x29),
  `total = 4 + body` (multi-datagram reassembly supported — big frames are
  split across KCP PUSHes, continuation datagrams have no 0x29 header).
  Plaintext variant seen as `[netId][00][00][LogiConnFrame...]`
  (phone→official-Mac service announce). Encryption key = the LogiConn
  session key (same HKDF/AES-GCM as control frames, no AAD).
  Sender writes netId = `LogiConnContextPhys::GetRemoteLogiConnNetId` low
  byte — official pcap uses 0x01 in both directions.
- **CONFIRMED WORKING**: our 99-byte EVENT_HANDSHAKE reached the phone as
  `ConnectionManager::OnLogiConnClientPayloadReceived conn_id=.. data.len=99`
  (12:51:35.947 session) — decrypt + delivery OK. But it never reached
  `JChannelListenerAdapter::OnChannelReceive` → miexpress: the micont
  channel was still in "creating" state (OnChannelCreateSuccess never
  fired), so the packet was dropped/queued and HSHK timed out at 25s (52008).
- **Official-transfer ground truth (phone logcat, 2026-07-21 13:11)**:
  createChannel → OnChannelConfirm `[HSHK]Confirm INITIAL link` →
  `OnLogiConnClientPayloadReceived data.len=60` (conn A) + `data.len=2172`
  (main conn) → **OnChannelCreateSuccess** (48ms after confirm) →
  `OnChannelReceive pkt_type=1 pkt_length=99` = the EVENT_HANDSHAKE
  (miexpress-esevt logs `payload, tag=1`) → phone sends FileSendRequest
  (`DoLogiSendPayloadFrame data_size=3571` → wire 3601 = +30 overhead
  = [netId 1][flag 1][nonce 12][tag 16]) → Mac answers 53-byte packet
  (tag=2 = FileSendRequestResponse) → 54-byte (tag=4) → file data
  (`Send pkt_type=2`).
- So the missing piece before EVENT_HANDSHAKE: the receiver must first send
  a **~2KB "channel-init / service-announce" payload** (data.len=2172 on
  the main conn; official Mac→phone 2205-byte type-5 frame in pcap =
  2171B plaintext, encrypted). Only then does the phone's micont channel
  become "created" and accept packets for miexpress. The 60-byte payload on
  the second conn (72BAC981) is probably the other leg/service announce ack.
- The phone's own service announce (plaintext type-5, old pcap):
  `[01 00 00]` + LogiConnFrame{f1:1, f5: inner} where inner =
  FileSendProtocol-ish `{f1:1, f2: <service-list proto>}` listing
  miNfcShare / miShareBasic / WearGesture + device name + MAC + ids.
- miexpress event socket logs each TLV with its oneof tag
  (`miexpress-esevt: ExpressEventSocket::OnChannelReceive payload, tag=N`).
- Express client needs no handshake response; after EVENT_HANDSHAKE it
  immediately proceeds (FileSendRequest on the event channel as
  TlvExpressFrame tag=? — the 3571B frame).
- Next steps:
  1. Reverse the 2172-byte channel-init payload: disassemble official Mac
     micontinuity channel accept path (`ChannelServerHandler` /
     `OnLogiConnServerConnected` in /tmp/micontinuity_arm64) or capture
     official Mac→phone frames and diff against MiShare.apk proto classes
     (HeteroChannel*Frame protos exist in MiConnectProto strings).
  2. Send channel-init after LogiConnResponseAck, then EVENT_HANDSHAKE,
     then answer FileSendRequest (tag 1) with FileSendRequestResponse
     (tag 2) as encrypted payload-v2 packets.
- Also note: `express_handshake_sent` dataPort TCP listener works, but the
  phone never TCP-connects before HSHK completes — the data socket
  (`ExpressDataSocket::NewServer` = raw TCP bind+getsockname) is used only
  after the event-channel handshake.
