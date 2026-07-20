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
