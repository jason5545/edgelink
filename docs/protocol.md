# EdgeLink Protocol v1

這份文件是 EdgeLink 協定的唯一真相來源。Swift、Kotlin、Worker 只能依這裡實作；
`kdeconnect-kde-upstream` 只能讀概念，不能複製 GPL 程式碼或沿用它的 Git 歷史。

## 1. 安全邊界

EdgeLink 的端到端加密層放在 transport 之上。LAN socket 與 relay WebSocket 都只是
`ByteChannel`，握手與加密 frame 在兩種通道上跑完全相同的 bytes。

Cloudflare Workers / Durable Objects 可以看到：

- deviceId
- 連線狀態
- frame 大小
- frame 時間

Cloudflare 不應該能解密 payload。即使 Worker 被攻擊者控制，最多只能中斷、延遲、
丟棄、重放或嘗試 MITM；MITM 會被 SAS 數字比對或釘選公鑰驗證擋下。

## 2. Device ID

Device ID 是 9 位十進位數字字串，範圍 `100000000` 到 `999999999`。

範例：

```json
"949758990"
```

UI 顯示時每三位一組：

```text
949 758 990
```

Device ID 是路由識別碼，不是秘密，也不是憑證。知道 ID 不能配對、不能連線、不能解密：

- 配對只在 host 開啟 5 分鐘配對視窗時受理。
- 配對必須通過 SAS 人眼比對確認。
- Relay 連線必須通過該 deviceId 綁定公鑰的 Ed25519 簽章。
- E2EE 握手驗的是本地釘選公鑰，不信任 Worker 即時回報的 ID 對應。

### Register

Endpoint:

```http
POST /v1/device/register
```

Request:

```json
{
  "pubkey": "<base64 Ed25519 public key>",
  "name": "Jason's Mac",
  "platform": "macos"
}
```

Response:

```json
{
  "deviceId": "949758990"
}
```

`RegistryDO` 使用 `idFromName("global")` 做單例配發。它隨機產生 9 位數字，若 storage
已有 `device:<id>` 就重試。裝置必須把 deviceId 與身分金鑰一起持久化；重灌 app 代表
新金鑰與新 ID。

## 3. Pairing

配對不用 QR code，也不用相機。信任錨點是兩邊螢幕顯示同一組 6 位 SAS，使用者看一眼，
Android 點確認，Mac 點接受。

### Pairing Window

Mac 開始配對：

```http
POST /v1/pair/start
```

```json
{
  "hostId": "949758990"
}
```

Worker 建立或喚醒 `PairingDO(idFromName(hostId))`，開啟 5 分鐘視窗。視窗外的 claim
一律拒絕。

Android 輸入 Mac ID 後 claim：

```http
POST /v1/pair/claim
```

```json
{
  "hostId": "949758990",
  "clientId": "137245816"
}
```

PairingDO 只盲轉 pair 訊息，不解密、不替任一端做信任判斷。

雙方掛 PairingDO WebSocket：

```http
GET /v1/pair/ws?hostId=949758990
Upgrade: websocket
```

WebSocket 只在 pairing window 尚未過期時接受。

### Commitment

所有公鑰與 nonce 都是 raw bytes；JSON 中使用標準 base64。

Mac 先送 commitment：

```json
{
  "t": "pair.commit",
  "b": {
    "commit": "<base64 SHA256(hostPk || nonceH)>"
  }
}
```

Android reveal：

```json
{
  "t": "pair.reveal_client",
  "b": {
    "clientId": "137245816",
    "clientPk": "<base64 Ed25519 public key>",
    "nonceC": "<base64 32 random bytes>",
    "name": "Pixel 9"
  }
}
```

Mac reveal：

```json
{
  "t": "pair.reveal_host",
  "b": {
    "hostId": "949758990",
    "hostPk": "<base64 Ed25519 public key>",
    "nonceH": "<base64 32 random bytes>",
    "name": "Jason's Mac"
  }
}
```

Android 必須驗證：

```text
SHA256(hostPk || nonceH) == commit
```

### SAS

雙方計算：

```text
digest = SHA256(hostPk || clientPk || nonceH || nonceC)
SAS = digest mod 1000000
```

`digest mod 1000000` 不要求 BigInt。平台實作應使用 byte 迭代：

```text
remainder = 0
for byte in digest:
  remainder = (remainder * 256 + byte) % 1000000
```

結果補滿 6 位並顯示成 `000 000` 格式。單次 MITM 猜中機率是 `10^-6`。

使用者在兩邊確認後，雙方釘選對方 Ed25519 public key 到本地 storage。SAS 不符、逾時、
任一端取消，都整段重來，不做部分重試。

測試向量：`docs/test-vectors/pairing-sas-v1.json`

## 4. Handshake

每台裝置有一把長期 Ed25519 身分金鑰。每次連線使用新的 X25519 ephemeral key，
完成 3-message signed ECDH：

1. Initiator -> Responder: `hs.hello`
2. Responder -> Initiator: `hs.ack`
3. Initiator -> Responder: `hs.confirm`

Android 連 Mac 的常見情境中，Android 是 initiator，Mac 是 responder。

### Message Shape

```json
{
  "t": "hs.hello",
  "b": {
    "deviceId": "137245816",
    "ephPk": "<base64 X25519 public key>",
    "nonce": "<base64 32 random bytes>",
    "sig": "<base64 Ed25519 signature>"
  }
}
```

`hs.ack` 欄位相同，但由 responder 簽；`hs.confirm` 只需要 `sig`。

驗簽必須使用配對時釘選的 Ed25519 public key，不能只相信 Worker 或 peer 宣稱的 deviceId。

### Canonical Signature Bytes

簽章不直接簽 JSON，避免欄位排序與序列化差異。

`peerRecord`：

```text
u16be(len(deviceIdUtf8)) || deviceIdUtf8 ||
u16be(32) || ephPkRaw ||
u16be(32) || nonceRaw
```

Signature inputs：

```text
helloSigInput   = utf8("EdgeLink hs.v1 hello\n")   || clientPeerRecord
ackSigInput     = utf8("EdgeLink hs.v1 ack\n")     || clientPeerRecord || hostPeerRecord
confirmSigInput = utf8("EdgeLink hs.v1 confirm\n") || clientPeerRecord || hostPeerRecord || helloSig || ackSig
```

`clientPeerRecord` 是 initiator；`hostPeerRecord` 是 responder。

### Key Schedule

```text
sharedSecret = X25519(initiatorEphSk, responderEphPk)
transcriptHash = SHA256(
  utf8("EdgeLink hs.v1 transcript\n") ||
  clientPeerRecord || helloSig ||
  hostPeerRecord || ackSig ||
  confirmSig
)
okm = HKDF-SHA256(
  ikm = sharedSecret,
  salt = transcriptHash,
  info = utf8("EdgeLink secure channel v1"),
  length = 64
)
initiatorToResponderKey = okm[0..32)
responderToInitiatorKey = okm[32..64)
```

每次重連都重新握手並換新 ephemeral key。不要持久化 session key。

測試向量：`docs/test-vectors/handshake-channel-v1.json`

## 5. Secure Frame

握手後所有 frame：

```text
u32be(ciphertextAndTagLength) || ciphertextAndTag
```

AEAD：

- Algorithm: ChaCha20-Poly1305
- Key: direction-specific 32-byte key
- Nonce: `u32be(0) || u64be(counter)`
- Counter: 每個方向各自從 0 開始遞增，不可重用
- AAD:
  - initiator -> responder: `utf8("EdgeLink frame v1 i2r")`
  - responder -> initiator: `utf8("EdgeLink frame v1 r2i")`

單一 frame 上限：64 KB。超過上限的資料走未來的 side channel，不塞控制通道。

## 6. Envelope

解密後 payload 是 UTF-8 JSON：

```json
{"t":"input.pointer","b":{"dx":5,"dy":-2,"btn":null}}
{"t":"input.key","b":{"key":"a","mods":["cmd"]}}
{"t":"input.text","b":{"text":"你好"}}
{"t":"clipboard.set","b":{"text":"...","ts":1751941000,"hash":"..."}}
{"t":"status.ping","b":{}}
```

規則：

- `t` 是短字串 type。
- `b` 一律存在；沒有內容時是 `{}`。
- MVP 使用 JSON；若之後滑鼠或檔案傳輸量太大，再新增 CBOR 或 side channel。
- 滑鼠移動以 16ms 合併 delta，一則 envelope 是一個 batch。
- 大檔案不要進控制通道。

## 7. Transports

### Relay

Mac 對 `/v1/connect?hostId=<hostId>` 維持 WebSocket。M1 會加入 Ed25519 授權：

```json
{
  "deviceId": "949758990",
  "ts": 1751941000,
  "sig": "<base64 Ed25519 over deviceId || ts>"
}
```

`RelayDO(idFromName(hostDeviceId))` 只在兩端已配對時橋接。RelayDO 必須使用
Hibernatable WebSockets API：`state.acceptWebSocket()` 與 `webSocketMessage()`。

### LAN

M5 再做。Mac 使用 `_edgelink._tcp` Bonjour；Android 使用 `NsdManager`，並提供手動 IP
備援。連上 LAN 後仍跑同一套 handshake 與 secure frame。

LAN 不需要 TLS，因為信任與加密在 EdgeLink secure channel 層。

## 8. Platform Notes

macOS：

- 身分金鑰存 Keychain。
- CryptoKit：Ed25519、X25519、HKDF、ChaChaPoly。
- `CGEventKeyboardSetUnicodeString` 用於文字輸入，避免鍵盤配置問題。

Android：

- 身分金鑰種子存 EncryptedSharedPreferences，由 Android Keystore 包裝 master key。
- libsodium / Lazysodium：Ed25519、X25519、HKDF-SHA256、ChaCha20-Poly1305。
- 配對畫面使用自製大按鍵數字鍵盤，不叫系統鍵盤。

Cloudflare：

- Worker 原生 fetch router。
- `RegistryDO`、`PairingDO`、`RelayDO` 三個 Durable Object class。
- PairingDO claim 要限速；Relay frame 上限 64 KB。
