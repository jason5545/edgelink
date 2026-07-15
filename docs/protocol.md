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
  "hostId": "949758990",
  "hostPk": "<base64 Ed25519 public key>",
  "name": "Jason's Mac"
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
  "clientId": "137245816",
  "clientPk": "<base64 Ed25519 public key>",
  "name": "Pixel 9"
}
```

PairingDO 只盲轉 pair 訊息，不解密、不替任一端做信任判斷。

雙方掛 PairingDO WebSocket：

```http
GET /v1/pair/ws?hostId=949758990
Upgrade: websocket
```

WebSocket 只在 pairing window 尚未過期時接受。

### Confirmation

SAS 相同時，Android 與 Mac 都要各自呼叫：

```http
POST /v1/pair/confirm
```

Host confirmation:

```json
{
  "role": "host",
  "hostId": "949758990",
  "clientId": "137245816",
  "hostPk": "<base64 Ed25519 public key>",
  "clientPk": "<base64 Ed25519 public key>",
  "hostName": "Jason's Mac",
  "clientName": "Pixel 9"
}
```

Client confirmation has the same fields with `"role": "client"`。

PairingDO stores each side's confirmation. Pairing is complete only when both confirmations refer to
the same `hostId/clientId/hostPk/clientPk`. On completion, PairingDO stores the pair in RelayDO and
broadcasts:

```json
{"t":"pair.complete","b":{"hostId":"949758990","clientId":"137245816"}}
```

### Commitment

所有公鑰與 nonce 都是 raw bytes；JSON 中使用標準 base64。

Android 的 PairingDO WebSocket 連上後先送一個 readiness 訊息，通知 Mac 可以送 commitment。
這個訊息不是信任資料，只是避免 Mac 在 Android WebSocket 尚未接上時送出的 commitment 被盲轉掉包：

```json
{
  "t": "pair.ready",
  "b": {
    "deviceId": "137245816"
  }
}
```

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

測試向量中的 signature bytes 是一組固定 transcript 範例。平台測試必須驗證這些 signature
能由對應 public key 驗過，並用這些 bytes 計算 transcript hash；但不要求每個 Ed25519
implementation 對同一訊息產生逐 byte 相同的 signature。

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
{"t":"input.pointer","b":{"dx":5,"dy":-2,"scrollX":null,"scrollY":null,"btn":null}}
{"t":"input.key","b":{"key":"a","mods":["cmd"]}}
{"t":"input.text","b":{"text":"你好"}}
{"t":"screen.start","b":{}}
{"t":"screen.meta","b":{"w":1080,"h":2400,"scale":1.0,"dpi":420}}
{"t":"ctrl.pointer","b":{"x":540,"y":1200,"action":"down","wheelDy":null}}
{"t":"ctrl.key","b":{"key":"Escape","down":true,"mods":[]}}
{"t":"ctrl.text","b":{"text":"你好"}}
{"t":"ctrl.global","b":{"action":"back"}}
{"t":"rtc.offer","b":{"sdp":"v=0\r\n..."}}
{"t":"rtc.answer","b":{"sdp":"v=0\r\n..."}}
{"t":"rtc.ice","b":{"mid":"0","index":0,"candidate":"candidate:..."}}
{"t":"clipboard.set","b":{"text":"...","ts":1751941000,"hash":"..."}}
{"t":"notification.post","b":{"id":"android:0|com.chat|42","sourceDeviceId":"137245816","sourcePlatform":"android","app":"Chat","bundle":"com.chat","iconPngBase64":"iVBORw0KGgo...","title":"Alice","text":"晚上吃什麼","subtitle":null,"ts":1751941000}}
{"t":"notification.remove","b":{"id":"android:0|com.chat|42","sourceDeviceId":"137245816"}}
{"t":"status.ping","b":{}}
```

規則：

- `t` 是短字串 type。
- `b` 一律存在；沒有內容時是 `{}`。
- MVP 使用 JSON；若之後滑鼠或檔案傳輸量太大，再新增 CBOR 或 side channel。
- 滑鼠移動以 16ms 合併 delta，一則 envelope 是一個 batch。
- 大檔案不要進控制通道。

### Screen Session

螢幕會話與既有遠端輸入是角色反轉的另一條路：

- 既有 `input.*` 是 Android -> Mac，語意是 trackpad / keyboard，指標使用 delta。
- 新增 `screen.*`、`ctrl.*` 是 Mac -> Android 螢幕控制，指標使用 Android 裝置像素空間的絕對座標。
- 兩組 envelope 並存，不互相取代，也不要重用 `input.pointer` 來表示螢幕點擊。

螢幕會話啟停與 WebRTC signaling 仍走現有 secure frame，也就是 E2EE envelope、
64 KB frame 上限、relay/LAN 兩種 transport 共用。Mac 送 `screen.start` 要求 Android
開始或重接螢幕串流；Mac 送 `screen.stop` 結束 WebRTC 串流。Android 可保留 foreground
MediaProjection service 與既有 virtual display，讓下一次 `screen.start` 不必重新消耗一次性
permission token。Android 開始投影後回：

Android 端在活躍螢幕串流開始後可持有 wake lock 防止螢幕鎖定、暫時停用 screensaver/daydream
避免進入 wall clock，並在約 5 秒後暫時把系統亮度降到最低；收到 `screen.stop`、relay 斷線、或
projection 結束時必須恢復原本亮度與 screensaver 設定。亮度寫入需要 Android `WRITE_SETTINGS`
special app access；screensaver 寫入需要 `WRITE_SECURE_SETTINGS`。未授權時不應阻擋螢幕串流。

部分 Android / OEM build 會在整螢幕 MediaProjection 期間隱藏通知或受保護內容。Android app 的
「投放隱私保護」是本機 opt-in policy：建立 MediaProjection 前，EdgeLink 會 snapshot 並覆寫 Android
`disable_screen_share_protections_for_apps_and_notifications` 與 Xiaomi
`screen_project_private_on`；真正結束 MediaProjection 後才還原。`screen.stop` 只結束 WebRTC 串流並
保留 warm projection，因此不能在這個時間點還原。投放進行中切換 policy 會釋放現有 projection，
下一次 `screen.start` 才能保證 Android 與 OEM policy 都使用新值。

這些系統 key 只控制投放畫面的隱私行為，不取代 notification sync。不同 Android / OEM build 仍可能
不支援其中一顆 key，寫入後也必須 read-back 驗證；無法完整套用時不應阻擋螢幕串流。

通知轉發必須走 `NotificationListenerService` 本身：螢幕分享開始後 Android 端會主動 resync active
notifications，分享期間短週期 polling active notifications，並在 secure session 建立後再補抓一次。
這讓 notification sync 不依賴系統是否把通知 banner 顯示在被 capture 的畫面上。

```json
{"t":"screen.meta","b":{"w":1080,"h":2400,"scale":1.0,"dpi":420}}
```

`screen.meta.b.w` / `h` 是 Android 回報的裝置像素尺寸；`ctrl.pointer.b.x` / `y`
必須使用同一個座標空間。`scale` 保留給視窗顯示比例與未來密度換算，`dpi` 是 Android
display density DPI。

Mac -> Android 控制 envelope：

- `screen.start` b:`{}`
- `screen.stop` b:`{}`
- `screen.viewerVisibility` b:`{"visible":bool}`
- `ctrl.pointer` b:`{"x":int,"y":int,"action":"down|move|up|rightUp|wheel","wheelDy":int?}`
- `ctrl.key` b:`{"key":string,"down":bool,"mods":[string]}`
- `ctrl.text` b:`{"text":string}`
- `ctrl.global` b:`{"action":"back|home|recents|power"}`

`ctrl.*` 與 `screen.viewerVisibility` envelope 的 JSON 格式不因傳輸路徑而改變。WebRTC
session 建立後，Android 會開 `edgelink-control` data channel；Mac 若看到該 channel
open，優先把 `ctrl.pointer`、`ctrl.key`、`ctrl.text`、`ctrl.global`、
`screen.viewerVisibility` 以 binary `RTCDataBuffer` 送入 channel。channel 尚未 open 或送出
失敗時，Mac 必須 fallback 到既有 secure frame。

`screen.viewerVisibility.b.visible` 表示 Mac 端 phone viewer 視窗是否至少部分可見；視窗被
order out、關閉、或 AppKit occlusion state 顯示完全遮住時送 `false`。Android 收到 `true`
時可使用較高螢幕串流 bitrate，收到 `false` 時應降到背景 profile。重新建立 Android screen
session 時預設 `visible=true`。

Android -> Mac metadata envelope：

- `screen.meta` b:`{"w":int,"h":int,"scale":double,"dpi":int}`

`ctrl.pointer.action == "wheel"` 時 `wheelDy` 表示垂直滾輪量；其他 action 可省略或設為
`null`。`rightUp` 表示右鍵釋放語意，Android 端以長按 gesture 對應。

### WebRTC Media Plane

螢幕畫面與音訊不進 secure frame 的 64 KB 控制通道。媒體使用 WebRTC：

- Android 螢幕是 video track。
- Android app 播放音訊 -> Mac 是 audio track。
- Mac 麥克風 -> Android 喇叭是另一條 audio track。
- 媒體封包走 P2P DTLS-SRTP；NAT 穿不過時走 TURN。

Mac 麥克風 audio track 必須由使用者明確啟用；EdgeLinkMac 目前用「通話麥克風」開關啟用
`edgelink-mac-microphone` track，並沿用 `edgelink-screen` WebRTC session 送到 Android。
這條 track 是通話音訊路徑的 Mac -> Android 半邊骨架，不代表 Xiaomi PHONERELAY 已經接上。

SDP / ICE signaling 仍是 secure frame envelope，雙向傳送：

- `rtc.offer` b:`{"sdp":string}`
- `rtc.answer` b:`{"sdp":string}`
- `rtc.ice` b:`{"mid":string,"index":int,"candidate":string}`

這裡只定義 signaling envelope；WebRTC library、MediaProjection、AudioPlaybackCapture、
AccessibilityService 的平台實作不屬於本章協定格式。

### Notification Sync

`notification.post` 與 `notification.remove` 是雙向 envelope。接收端用 `id + sourceDeviceId`
建立本機顯示用 identifier，讓 remove 可以取消之前由 EdgeLink 顯示的遠端通知。

`notification.post.iconPngBase64` 是選填的 app 圖示，內容為 Base64 編碼 PNG。Android 會把來源 app
的 adaptive/legacy icon rasterize 成 64 x 64 PNG；macOS 將它加為 notification attachment。舊版接收端
可忽略此欄位，未提供或圖示無效時仍照常顯示文字通知。

Android 可以用 `NotificationListenerService` 讀系統通知；為了 app 不在前景時也能同步，
Android 端由 foreground service 持有 relay / secure session。Android 必須過濾 EdgeLink
自己顯示的通知，避免遠端通知被 listener 再送回去造成迴圈。

macOS app 用 `UserNotifications` 顯示遠端通知。Mac -> Android 鏡射使用本機
`usernoted` SQLite DB backend，這是 local non-sandbox build 的能力，不是 App Store/public
API 路線；不接 entitlement-gated private XPC。Mac notification source 調查見
`docs/macos-notifications.md`。

### SMS Sync

SMS 不走一般 notification payload，避免 Android / OEM 對 OTP 類通知的 listener redaction
讓簡訊內容消失。Android 端使用三個 runtime permission：

- `RECEIVE_SMS`：用 `SMS_RECEIVED_ACTION` 接新進簡訊
- `READ_SMS`：從 inbox 做有限補漏，預設最多送最近 50 筆未同步訊息
- `SEND_SMS`：接收 Mac 的 `sms.send` 後用 `SmsManager` 送出

這版不要求 EdgeLink 成為預設 SMS app，也不寫入系統簡訊資料庫、不改已讀狀態。

Debug APK 另外提供本機測試通道，用來驗證 Android -> relay -> Mac 的 SMS pipeline，
不需要真的收一則電信簡訊，也不會寫入系統簡訊資料庫或推進 inbox backfill marker：

```sh
tools/inject-debug-sms.sh 123720 "EdgeLink local SMS test"
```

這個入口只存在 `debug` source set，release build 不會註冊
`com.edgelink.app.DEBUG_INJECT_SMS` receiver。

`sms.message` 由 Android 送到 Mac：

```json
{
  "t": "sms.message",
  "b": {
    "id": "sms:inbox:42",
    "sourceDeviceId": "119946699",
    "sourcePlatform": "android",
    "address": "123720",
    "text": "message body",
    "direction": "inbound",
    "isBackfill": false,
    "ts": 1783510253
  }
}
```

`sms.send` 由 Mac 送到 Android：

```json
{
  "t": "sms.send",
  "b": {
    "requestId": "uuid",
    "to": "0912345678",
    "text": "message body"
  }
}
```

`sms.send.result` 由 Android 回覆 Mac。`success=true` 代表訊息已交給 Android
`SmsManager` 排入送出，不代表電信商已送達。

```json
{
  "t": "sms.send.result",
  "b": {
    "requestId": "uuid",
    "to": "0912345678",
    "success": true,
    "error": null,
    "ts": 1783510254
  }
}
```

## 7. Transports

### Relay

Mac 對 `/v1/connect?hostId=<hostId>` 維持 WebSocket。連上後第一包 text message 必須是
Ed25519 授權：

```json
{
  "t": "relay.auth",
  "b": {
    "hostId": "949758990",
    "deviceId": "949758990",
    "ts": 1751941000,
    "sig": "<base64 Ed25519 signature>"
  }
}
```

`ts` 是 Unix seconds。Signature input 不簽 JSON，而是：

```text
utf8("EdgeLink relay auth v1\n" || deviceId || "\n" || ts)
```

RegistryDO 用 register 時綁定的 Ed25519 public key 驗簽，允許 5 分鐘 clock skew。
`RelayDO(idFromName(hostDeviceId))` 允許 host 自己連線；client 必須已完成配對才可連線。
RelayDO 通過驗證後回：

```json
{"t":"relay.ready","b":{"role":"host"}}
```

之後只轉送 binary frame。未驗證 socket 傳 binary frame 會被關閉。RelayDO 必須使用
Hibernatable WebSockets API：`state.acceptWebSocket()`、`serializeAttachment()` 與
`webSocketMessage()`。

兩端要同時維持 relay transport 與 secure channel 活性。WebSocket ping/pong 用來避免
裝置到 Worker 的連線被閒置中斷；握手後的 secure channel 另外用
`status.ping` / `status.pong` 做端到端 keepalive。任一端超過 15 秒沒有收到
secure pong，應主動關閉目前 channel，交由 reconnect loop 建新連線與新 handshake。

### TURN Credentials

媒體層需要跨網路時，app 不持有 TURN server 的永久 shared secret。兩端用跟 relay WebSocket
相同的 Ed25519 身分簽章向 Worker 換短效 credential：

`POST /v1/turn/credentials`

```json
{
  "hostId": "949758990",
  "deviceId": "949758990",
  "ts": 1751941000,
  "sig": "<base64 Ed25519 signature>"
}
```

`sig` 的輸入仍是：

```text
utf8("EdgeLink relay auth v1\n" || deviceId || "\n" || ts)
```

Worker 會把 request route 到 `RelayDO(idFromName(hostId))`，只有 host 本身或已配對的 client
可以取得 TURN credential。回傳內容可直接塞給 WebRTC `RTCConfiguration.iceServers`：

```json
{
  "urls": ["turn:172.238.24.219:3478?transport=udp"],
  "username": "1751941600:949758990:949758990",
  "credential": "<base64 HMAC-SHA1 password>",
  "credentialType": "password",
  "ttlSeconds": 600,
  "issuedAt": 1751941000,
  "expiresAt": 1751941600,
  "realm": "edgelink-turn-tokyo",
  "role": "host",
  "iceServers": [
    {
      "urls": ["turn:172.238.24.219:3478?transport=udp"],
      "username": "1751941600:949758990:949758990",
      "credential": "<base64 HMAC-SHA1 password>",
      "credentialType": "password"
    }
  ]
}
```

credential 到期前 app 可以重取；永久 TURN shared secret 只存在 coturn 與 Worker secret store。

### LAN

M5 再做。Mac 使用 `_edgelink._tcp` Bonjour；Android 使用 `NsdManager`，並提供手動 IP
備援。連上 LAN 後仍跑同一套 handshake 與 secure frame。

LAN 不需要 TLS，因為信任與加密在 EdgeLink secure channel 層。

## 8. Platform Notes

macOS：

- 身分金鑰存 Keychain。
- CryptoKit：Ed25519、X25519、HKDF、ChaChaPoly。
- `CGEventKeyboardSetUnicodeString` 用於文字輸入，避免鍵盤配置問題。
- `UserNotifications` 僅用於顯示遠端通知；macOS 不提供讀取其他 app 通知的公開 API。

Android：

- 身分金鑰種子存 EncryptedSharedPreferences，由 Android Keystore 包裝 master key。
- libsodium / Lazysodium：Ed25519、X25519、HKDF-SHA256、ChaCha20-Poly1305。
- 配對畫面使用自製大按鍵數字鍵盤，不叫系統鍵盤。
- Foreground service 持有長連線；`NotificationListenerService` 只負責把本機通知事件交給
  現有 secure session。

Cloudflare：

- Worker 原生 fetch router。
- `RegistryDO`、`PairingDO`、`RelayDO` 三個 Durable Object class。
- PairingDO claim 要限速；Relay frame 上限 64 KB。
