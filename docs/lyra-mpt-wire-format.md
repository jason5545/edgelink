# lyra::netbus::mpt (MiplayTransport) wire format 逆向報告

來源：`captures/xiaomi-hyperconnect/3.0.300-285`，macOS micontinuity_sdk.framework **arm64 slice**。
所有位址為 arm64 vaddr（= 索引 rabin-symbols.txt 第三欄）。分析日期 2026-07-27。

結論摘要：mpt = lyra netbus 的 **TransType 4 (kcp)** transport governor。底層是標準 KCP
（自訂改良版，struct 擴充至 0x228 bytes）跑在 UDP 上，conv 固定 `0x12345678`。
**mpt 本身不加任何 header、不加密、無 FEC**。優先級只是本機多佇列排程，不上線。
加密在上層（SocketPacket AES-256-GCM / payload-v2 GCM，見 lyra-netbus-notes.md）。

---

## (a) Session 建立時序

### 結構體（從結構存取偏移逆出）

```c
// lyra::netbus::trans_manager::TransAddr (0x48 bytes)
struct TransAddr {
    uint32_t    trans_type;   // +0x00  mpt 要求 == 4 (TransType::kcp)
    uint8_t     _pad[4];
    IpPointAddr local;        // +0x08
    IpPointAddr remote;       // +0x28
};

// lyra::netbus::trans_manager::IpPointAddr (0x20 bytes)
struct IpPointAddr {
    std::string ip;           // +0x00 (libc++ string, 0x18)
    uint16_t    port;         // +0x18 (host byte order)
    uint16_t    _pad;
    uint32_t    ip_u32;       // +0x1c (ToStr 印成 "IP(<u32>)")
};

// TransType enum (MiplayTransportUtils::ToStr 字串表 0x9c5f00):
//   0=none 1=ble 2=bt 3=coap 4=kcp 5=tcp
```

證據：
- `IsTrasTypeVaild` 0x72de8: `ldr w8,[x0]; cmp w8,4`
- `IsPortVaild` 0x72df8: `ldrh w8,[x0,0x18]`
- `IsAddressVaild`/`IsHostVaild` 0x72d38/0x72d80: string 於 +0/+8/+0x17
- `IsRemoteAddressVaild` 0x72da0: remote 在 TransAddr+0x28（port at +0x40）
- `AddressConvert` 0x73304: `SocketAddress::SetIP(string@+0); SetPort(ldrh [+0x18])`
- `ToStr(IpPointAddr)` 0x7335c: 讀 +0x1c u32、+0x18 port

### 時序

```
伺服器側 (通道層 ServerChannelListener)                客戶側 (ClientChannelListener)
─────────────────────────────────────────────        ─────────────────────────────────
OnRequestSocketPort(...)                        (ChannelProtocol RequestOfPeerPort, type 2)
  └─ MiplayRoster::RegisterServer 0x472b8
       └─ MiplayTransportManager::CreateMptServer 0x6da9c
            ├─ IsTrasTypeVaild(type==4) + IsLocalHostValid
            ├─ AddressConvert(TransAddr.local → SocketAddress)
            └─ MiplayTransportServer::CreateSocket 0x6fe78
                 └─ AsyncKcpSocket::CreateServer 0x74328/0x73da8
                      ├─ SocketFactory vtable+0x18 CreateSocket(family, type=2 SOCK_DGRAM)
                      ├─ SetDefaultSocketOpt: RCVBUF/SNDBUF 嘗試 0x600000 (6MB) 遞減
                      ├─ memorize_port (static atomic u16 @0xa23108):
                      │    非 0 → 強制沿用上次 port（SetPort 0x73fec）
                      └─ Bind(local addr)
  ← OnCreateServerSuccess(handle, bound_addr) → 把 port 放進
    ChannelProtocol ResponseOfPeerPort (type 3, f3=socket_port, 60B)
                                                   │
                                                   ▼
                              ClientChannelListener::ConnectSocketServer 0x3bd8c
                                └─ MiplayRoster::RegisterClient 0x477f0
                                     └─ MiplayTransportManager::ConnectMptServer 0x6de74
                                          ├─ IsRemoteAddressVaild (TransAddr+0x28)
                                          └─ MiplayTransportClient::CreateSocket 0x6c2a4
                                               └─ AsyncKcpSocket::CreateClient 0x73d48/0x73664
                                                    └─ UDP socket, Bind(local 可 nil→ephemeral)
                                                   │
                              第一個 UDP datagram = KCP PUSH (sn=0) ─────►
─────────────────────────────────────────────        │
Server: AsyncKcpSocket::OnReadEvent → Server::OnPacket 0x70c8c
  ├─ 已有 session(以來源 SocketAddress 查 map@this+0x120) → Session::Input
  └─ 新來源 → CheckPrivateProtocol(data,len) 0x6b4f4
       ├─ len < 25 → 丟棄 (err 0x80f2)
       └─ CheckFirstPacket 0x72afc:
            *(u32*)data == 0x12345678 (conv) 且 *(u32*)(data+0xc) == 0 (sn)
            否則丟棄 (err 0x80f3)
       → 建立 MiplayTransportSession(0x178 bytes)，SetTransAddr(local, remote)，
         插入 handle map (this+0xf8) 與 addr map (this+0x120)，
         OnNewConnectionConnected(handle, TransAddr) → ITransGovCallback::OnClientConnected
       → Session::Input(data, len)
```

重點：
- **沒有任何 mpt 層 handshake/magic**。server 對新來源只驗 `conv==0x12345678`、
  `len≥25`、**首包 KCP sn 必須為 0**（`CheckFirstPacket` 0x72b28 讀 [data+0xc]=sn）。
  之後以 (來源 IP, port) 作為 session key。
- **port 交換不走 mpt**，走 micont channel 層的 ChannelProtocol（16B header）
  RequestOfPeerPort(type 2)/ResponseOfPeerPort(type 3)，server 端 port 由
  `CreateMptServer` bind 後經 `OnCreateServerSuccess` 回報，放在 Response f3。
- 錯誤碼：0x80ea=TransAddr 無效，0x80ed=socket 建立失敗，0x80f1=ikcp_create 失敗，
  0x80f2=首包太短，0x80f3=首包 conv/sn 錯，0x80f4=狀態非 connected 就 SendPacket。

## (b) 封包 byte-level 格式

### KCP segment（唯一的外層格式，24B header，little-endian）

由 `_ikcp_flush` (0x241d14) 的 encode 確認為逐 byte 寫出的標準 KCP header：

```
+0   u32le conv   = 0x12345678 (固定, ikcp_create @0x71e34)
+4   u8     cmd   = 0x51 PUSH / 0x52 ACK
+5   u8     frg
+6   u16le  wnd
+8   u32le  ts
+0xc u32le  sn    (首包必須為 0)
+0x10 u32le una
+0x14 u32le len
+0x18 payload (len bytes) — 上層資料原封不動
```

- **SendPacket → 線上無任何額外 header**：`Session::Send` 0x726fc 直接 tail-call
  `ikcp_send(kcp, buf, len, x, prio, payload_id)`。prio/payload_id 只存在
  KCP segment struct 本機欄位（seg+0x30=payload_id 給 sent-callback，seg+0x50 亦然），
  不進 wire bytes。
- 收方向：`Session::Input` 0x7272c → `ikcp_input`；若 kcp 內部計數 ≥ 0x3b(59)
  立即 `ikcp_flush`（快 ACK）。`Session::Receive` 0x72778 用 `ikcp_peeksize`+`ikcp_recv`
  組回完整 KCP message，包進 BufferData（前 0x20 bytes 為 BufferData header），
  經 callback vtable+0x30 上拋。
- 無 FEC、無加密、無壓縮（ikcp_flush 無 FEC 區段；binary 無 fec symbol；
  KCP output callback `CreateKcpSession::$_0` 0x72b44 → Base::OnSendRequire 0x6ad2c
  → AsyncKcpSocket::SendMessage 0x7488c 直接送 UDP）。

## (c) KCP 參數表（全部在 CreateKcpSession 0x71dbc）

| 設定 | 值 | 證據位址 |
|---|---|---|
| conv | `0x12345678` | 0x71e34 `mov w0,0x5678; movk w0,0x1234,lsl16` → ikcp_create |
| nodelay | 1 | 0x71e60 ikcp_nodelay(kcp,1,5000,10,0) |
| interval | 5000 ms（clamp [10,5000]，setter 0x243408）| 同上 arg3=0x1388 |
| resend | 10 | 同上 arg4=0xa |
| nc (no-congestion) | 0 | 同上 arg5 |
| cwndsize | 32 | 0x71e70 ikcp_cwndsize(0x20) |
| mincwndsize | 16 | 0x71eec ikcp_mincwndsize(0x10) |
| rcvwndsize | 4096 | 0x71fac ikcp_rcvwndsize(0x1000)（setter clamp min 0x80）|
| sndwndsize | 4096 | 0x72038 ikcp_sndwndsize(0x1000) |
| minrto | 190 ms | 0x720c4 ikcp_minrto(0xbe)（clamp [50,1000]）|
| maxrto | 1000 ms | 0x72150 ikcp_maxrto(0x3e8) |
| ssthresh | 800 | 0x721dc ikcp_ssthresh(0x320) |
| mtu | 1400 | 0x72268 ikcp_setmtu(0x578)（clamp [50,64000]）|
| kcp+0x1dc | 0x73000 (471040) | 0x72338 自訂欄位（用途待確認，疑似頻寬/預算）|
| socket buf | RCVBUF/SNDBUF 嘗試 6MB 遞減 | SetDefaultSocketOpt 0x73ab4 |

驅動方式：這版 KCP **不用 ikcp_update**（LOCAL _ikcp_update 0x243130 無 xref）。
由 `Server/Client::ExecUpdate` 0x70bac/0x6ca80 定期對每個 session 呼叫
`Update→ikcp_flush`，取回傳最小值重排 timer，預設上限 0x1388=5000ms。
`SetSessionMinFastTimeout`（MiplayRoster 0x482fc）可壓低單一 session 的 flush 間隔。

Callbacks（CreateKcpSession 尾段）：output=$_0(0x72b44)、qos=$_1(0x72b7c)、
sent=$_2(0x72ba0)、dead=$_3(0x72bf4)、clock=$_4(0x72c3c)，另 kcp+0x200=$_5(0x72c64)。
struct 擴充欄位：+0x1e8 clock / +0x1f0 sent / +0x1f8 dead / +0x200 自訂 / +0x208 qos /
+0x210~0x220 allocator 三聯（ikcp 0x240c84）。

注意：binary 內還有第二份 KCP（`_mtp_ikcp_*` 0x329xxx），只被 `MTP_NET_Connection*`
（MiPlay 投屏協定棧）使用，與 lyra::netbus::mpt 無關，勿混淆。

### MptPrioLevel

- `SendPacket(int, BufferDataPtr, callback, MptPrioLevel, int)` 的 prio 進
  `ikcp_send` 第 5 參數，在 0x241028 被 clamp：`prio > 1 → 0`，即**有效值只有 0/1**，
  用來選 kcp 內部 per-priority send queue（queue head 在 kcp+0xf0+prio*16）。
- 但多佇列旗標 kcp+0x1d8 預設為 0（ikcp_create 0x24060c），此 Mac 版本未見開啟處
  → 實務上 prio 無作用，**wire 上無 priority 欄位**。enum 名稱無字串殘留，語義待確認。

## (d) 與 micont channel 的關係

mpt 在 Mac binary 中只有兩個使用入口（xref 實測）：

1. **通道 socket 資料面（ChannelImplBySocket）**：
   - server: `ServerChannelListener::OnRequestSocketPort` 內 lambda (0x5deec)
     → `MiplayRoster::RegisterServer`
   - client: `ClientChannelListener::ConnectSocketServer` (0x3bd8c)
     → `MiplayRoster::RegisterClient`
   - 送資料: `ChannelImplBySocket::CallSendData` / `SendBytes` (0x32ec4, 0x33e08)
     → `MiplayRoster::Send` → `MiplayTransportManager::SendPacket`
   - key 安裝: `ClientChannelListener::OnDataReceived` lambda (0x40d9c)
     → `MiplayRoster::SetSocketPacketSync`（對應 notes 的 54B/42B TLV 協商流程）
   - 即 lyra-netbus-notes「socket channel」路徑：ChannelProtocol 16B header 的
     RequestOfPeerPort(type 2)/ResponseOfPeerPort(type 3) 先走 LogiConn，
     完成後才開 mpt socket。

2. **mesh/phys conn 傳輸（TransType kcp）**：`MiplayTransportGovernor`
   （GetTransType=4, 0x6d3e8）是 TransManager 註冊的 governor；TransAddr type==4
   的 CreateServer/ConnectServer 都導到 mpt。手機 mesh UDP socket 觀察到的
   KCP conv 0x12345678 與此一致。

**LogiConnUpgradeFrame（inner frame_type=7）與 mpt 無直接關係**：它屬於
`LogiConnHandler::DoLogiConnMediumUpgradeStagePrepare` /
`DoMediumUpgradeConnectServer` (0x138fc4) / `DoMediumUpgradeStartServer` (0x1399b4)
的 **phys medium 升級**流程（經 `LogiConnServerQuery/ServerAvailableFrame` 交換
client_config/server_config），目的是升級 LogiConn 底層 medium，不觸發 mpt
session 建立。channel 層「什麼時候用 mpt 而非 SocketChannel-over-LogiConn」的判斷
在通道建立時由 ChannelInfo/medium 決定——只要走 ChannelImplBySocket（需獨立
socket 的通道）就用 mpt；細節的觸發條件在 ClientChannelListener::NewChannel
(0x3bbe4) / OnChannelCreated，非 upgrade frame。**待手機端確認**：手機側是否
在 medium upgrade 後也用新 medium 重建 mpt（Mac 端未見此路徑）。

## (e) QoS / governor / capacity

### TransQosInfo（Base::OnQos 0x6b1b0 → ITransGovCallback::OnQosInfo）

由 ikcp qos-callback 帶出，欄位名稱取自
`RtmChannelListener::ConstructChannelFeatureInfo` 0x53860 的字串表：

```c
struct TransQosInfo {      // 全部 u32
    int32_t handle;                  // +0x00 session handle
    uint32_t transferRttSmooth;      // +0x04
    uint32_t transferRttMin;         // +0x08
    uint32_t transferRttAvg;         // +0x0c
    uint32_t transferRttMax;         // +0x10
    uint32_t transferWindowSend;     // +0x14
    uint32_t transferRttWindowsWait; // +0x18
    uint32_t transferBlockTime;      // +0x1c
    // transferThroughputKbps 字串存在(0x8c429c)，疑似 +0x20，待確認
};
```
（IKCPQOS 原始結構由自訂 KCP 內部統計填入，Base::OnQos 做了一次 8B lane 對調後複製。）

### TransGovRecvParam（OnDataReceived 第二參數）

從 `MiplayCallbackWrapper::OnDataReceived` 0x43ab4 欄位存取：

```c
struct TransGovRecvParam {
    int32_t                  session_handle;  // +0x00
    std::shared_ptr<BufferData> data;         // +0x08 (0x10)
};
```

### SetTransCapacity

- 呼叫鏈：`ChannelImplBySocket::SetTransCapacity` 0x319d8
  → `MiplayRoster::SetTransCapacity` 0x49348
  → `MiplayTransportBase::SetTransCapacity` 0x6b508。
- **格式不是 JSON**，是單一 scenario 名稱字串，查靜態 map
  `{"SCENARIO_CTR_KEYBOARD_MOUSE" → wmm_level 0xf4 (244)}`（map 初始化 0x6b638-0x6b69c，
  key 字串 0x8c6150）；查到且值 != -1 就呼叫
  `AsyncKcpSocket::SetWmmLevel` 0x749bc → 對 UDP socket 設 option 4（WMM/QoS 等級）。
  查不到只 log。**不影響 wire format**。

## (f) 加密結論

- mpt data path **完全 plaintext over KCP/UDP**：`Session::Send`→`ikcp_send`→
  output cb→`AsyncKcpSocket::SendMessage`→UDP，全程無 AES 呼叫。
- 加密在上層：(1) socket channel 的 SocketPacket AES-256-GCM
  （`MiplayRoster::SetSocketPacket(Sync/Async)`，key 來自 channel 協商）；
  (2) LogiConn payload-v2 GCM。兩者都在 mpt payload 之內，對 mpt 透明。

## 待手機端確認清單

1. kcp+0x1dc = 0x73000 自訂欄位語義（疑似速率/預算；Mac 端只有寫入點，無讀出語義）。
2. MptPrioLevel 0/1 的名稱與手機端是否真的啟用多佇列（kcp+0x1d8）。
3. TransQosInfo 是否有第 9 欄位 transferThroughputKbps（+0x20）。
4. 手機側 phys medium upgrade（LogiConnUpgradeFrame）完成後，是否會在新 medium
   上重建 mpt phys 連線（Mac 端未見此觸發）。
5. 手機 mpt server 是否也要求首包 sn==0（由 Android libmicontinuity.so 的
   CheckFirstPacket 對應函式確認，Mac 端為 0x72afc）。
