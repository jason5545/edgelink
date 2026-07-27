# EdgeLink Cloudflare Relay 深度分析與即時媒體優化

日期：2026-07-27。範圍：Xiaomi 鏡像 cloudflare fallback 路線（`milink.mirror.media`）
與 PHONERELAY 通話音訊（`phone.relay.media`）共用的 Cloudflare WebSocket relay 段。
LAN direct 路線不在本文範圍。

## 0. TL;DR（含 2026-07-27 真機實測）

1. **最大單一延遲來源是 anycast 落點，而且是不對稱的**：真機實測
   Mac（HiNet）`colo=SIN`、手機（遠傳）`colo=TPE`。這是已知的
   **HiNet↔Cloudflare peering 爭議**：HiNet 對國內互連收高價，Cloudflare
   自 2016 年起把非 Enterprise 的 HiNet 流量導到海外 PoP（當年美西，現 SIN）。
   workers.dev 不在高階方案保障內，即使 Workers Paid 也一樣繞。
   遠傳等其它 ISP 與 CF 互連正常 → TPE。
2. **實測延遲（手機遠傳 4G/5G + Mac HiNet，cloudflare 鏡像，影片播放）**：
   - E2E secure RTT（Mac↔手機經 relay）：p50 ≈ **200ms**，p90 ≈ 764ms，max 2694ms
   - 媒體單向延遲 oneWayMs：p50 ≈ **115ms**，p90 ≈ **1099ms**，max 2503ms
   - 26fps frame interval 才 38ms；p90 的尾巴就是可見卡頓。
3. **Android 送端 backlog 持續增長**（55→273 payload / 2 分鐘）：
   5Mbps × 1.37（base64）≈ 6.9Mbps 上行需求，碰上 4G 上行波動就累積排队；
   backlog 直接變成額外单向延遲。這給「去 base64」（-27% 上行需求）一個量化理由。
4. **突破口**：`turn.cloudflare.com`（CF Realtime TURN anycast，141.101.90.1）
   從同一台 HiNet Mac ping = **6.6ms**——TURN 的 anycast 路由不受 workers.dev
   那套分流影響。WebRTC data channel over TURN 同時解決「繞路」與「TCP HoL」
   兩個問題，成為主力建議（§7 方案 E）。
5. 已落地 quick win：埋點（colo、secure RTT、時鐘偏移、單向媒體延遲）
   + batch delay 10ms→3ms。

## 1. 現行架構（事實整理）

```
手機 miplaycast ─KCP/UDP(loopback)─ AndroidMiLinkMirrorMediaBridge
   （終結 KCP，送出依序 RTP payload）
   → length-prefixed batch（u16be len || payload，≤ 6144 bytes payload）
   → base64 → JSON envelope {"t":"milink.mirror.media", b:{...,ts}}
   → ChaCha20-Poly1305 seal（≤64KB secure frame）
   → OkHttp WebSocket（binary message）
   → CF edge（anycast）→ RelayDO(idFromName(hostId)) → CF edge
   → URLSessionWebSocketTask → open() → JSON parse → base64 decode
   → handleCloudflareMirrorMedia → pushExternalRTPPayload → TS demux → HEVC → VT
```

關鍵參數（修改前 → 修改後）：

| 參數 | 位置 | 值 |
|---|---|---|
| `RTP_BATCH_MAX_PAYLOAD_BYTES` | AndroidMiLinkMirrorMediaBridge.kt:36 | 6144（不變） |
| `RTP_BATCH_MAX_DELAY_MS` | AndroidMiLinkMirrorMediaBridge.kt:37 | **10 → 3**（本次改） |
| `RTP_BATCH_QUEUE_CAPACITY` | 同上 | 1024 payload |
| secure frame 上限 | docs/protocol.md §5 | 64 KB |
| bitrate 協商 | 2026-07-27 優化 | 5 Mbps |

5 Mbps ≈ 625 KB/s ≈ 每秒 ~102 個 6KB batch ≈ 每 batch 涵蓋 ~9.6ms 媒體時間。
10ms delay 在高流量時幾乎不觸發（batch 先被 6144 bytes cap 填滿）；降為 3ms 只影響
低流量期（畫面近乎靜止時小封包不再多等 7ms），高流量行為不變。

## 2. 延遲預算分解

### 2.1 實測（2026-07-27，真機 relay 鏡像）

**網路落點實測**（`relay.ready` colo 埋點 + curl/ping）：

| 端 | 網路 | 落點 | RTT 實測 |
|---|---|---|---|
| Mac | HiNet 光世代 | **SIN**（`relay.transport.mac.ready colo=SIN`；cf-ray 亦 SIN） | workers.dev TCP ~67ms |
| 手機 | 遠傳 4G/5G（WiFi 關閉） | **TPE**（`relay.transport.ready colo=TPE`） | —（行動網路） |
| Mac → cloudflare.com（CF 自用段） | HiNet | TPE | 6.5ms |
| Mac → **turn.cloudflare.com** | HiNet | **TPE** | **6.6ms**（141.101.90.1，ping ×6） |

**為什麼 Mac 繞新加坡**：HiNet（AS3462）對國內互連高價收費，Cloudflare 自
2016-08 起（官方 blog「Bandwidth Costs Around the World」點名）把非 Enterprise
方案的 HiNet 流量導到海外低成本 PoP；當年是美西，現觀測為 SIN。workers.dev
IP 段（104.21.x/172.67.x）IPv4/IPv6 皆落 SIN；遠傳等其它台灣 ISP 與 CF 互連
正常 → TPE。TURN 的 anycast（141.101.90.x）走不同路由政策，HiNet 也落 TPE。

**relay 媒體延遲實測**（遠傳手機 → CF → HiNet Mac，影片播放，兩個 session 合計）：

| 指標 | n | min | p50 | p90 | p95 | max |
|---|---|---|---|---|---|---|
| E2E secure RTT（`relay.mac.secure_rtt`） | 20 | 176ms | 203ms | 764ms | — | 2694ms |
| 媒體單向 oneWayMs（`xiaomi.mirror.cloudflare.latency`） | 91 | -424* | 115ms | 1099ms | 1397ms | 2503ms |

\* 負值來自 offset 估計在 RTT 不對稱時的誤差（NTP midpoint 假設），
解讀時以 p50/p90 為準，不看 min。

**Android 送端拥塞證據**（`cloudflare_queue_health`）：backlog 隨時間單調增長
（55→273 payload / 2 分鐘，約 +2 payload/s）。上行需求 = 5Mbps × 1.37
（base64）+ 協定 overhead ≈ 7Mbps，碰上 4G 上行波動即累積；backlog 直接轉化為
額外單向延遲（273 payload ≈ 0.4s）。`batch_queue_full` 未出現（尚未到 1024 上限）。
新 session 開始 30 秒內即出現 3 次 `decoded_frame_stalled_beyond_threshold`
——「看影片不順」的直接對應。

### 2.2 延遲分解（以實測校準）

E2E RTT p50 ≈ 200ms 的拆解：

| 段 | 估計 | 依據 |
|---|---|---|
| 手機（遠傳）→ TPE edge | ~20-40ms | 行動網路 RAN 典型值 |
| TPE edge → RelayDO → SIN edge（回程到 Mac 側） | ~60-90ms | DO 在首次 `get()` 附近建立（手機先連 → 偏 TPE/同區）；SIN↔TPE 骨幹單向 ~30-45ms |
| SIN edge → Mac（HiNet） | ~33ms | Mac↔SIN RTT 67ms 的一半 |
| **合計** | **~115-165ms 單向 / ~200ms RTT** | 與實測 p50 吻合 |

尾巴（p90 1099ms）= 4G 上行波動時的 TCP 重傳 stall + Android backlog 累積。

### 2.3 為什麼「26fps 但看影片不順」

- p50 單向 115ms 本身只是「晚到」，不卡。卡的是 **p90 1099ms 的尾巴**：
  TCP 在 4G 上每次遺失重傳至少 1 RTT（200ms+，不穩時到秒級），期間所有後續
  byte 停等（in-order delivery）。26fps 下等於一次掉 5-25 個 frame 的媒體時間。
- Mac 端對 RTP gap 硬重置等 IDR，把 TCP stall 放大成可見凍結；實測新 session
  30 秒內 3 次 `decoded_frame_stalled_beyond_threshold` 印證。
- 這是「loss-tolerant 媒體被迫跑在 loss-intolerant transport 上」的結構性問題，
  不是 buffer 調參能解的；加上 HiNet 繞 SIN 讓 RTT 基線從 ~15ms 變 ~200ms，
  重傳代價等比例放大。

## 3. Worker 行為報告（`worker/src/relay-do.ts` 實讀）

- **配對模型**：`RelayDO(idFromName(hostId))` 一個 host 一個 DO。auth 用第一包
  text message（Ed25519 對 `deviceId:ts` 簽名，RegistryDO 驗），過了才收 binary。
  同 device 重連會 revoke 舊 socket（`closeReplacedRoleSockets`，先撤 attachment
  再 close，避免舊 socket 把 queued frame 送出去打亂對端 secure counter）。
- **轉發**：`webSocketMessage` 收到 binary → 對所有「已驗證、角色相反」的 socket
  `socket.send(message)`。**沒有應用層佇列、沒有 backpressure、沒有速率限制**；
  send 失敗就 close 該 peer（1011），不拖垮 sender。DO 只是記憶體內 fan-out，
  不落地、不排序、不看內容（E2EE，也只能看到 frame 大小與時間）。
- **Hibernation**：已用 `acceptWebSocket` + `serializeAttachment` + auto
  ping/pong（`{"t":"ping"}`→`{"t":"pong"}`）。鏡像期間流量持續，DO 不會 hibernate；
  閒置時 hibernate 省 duration 費用，attachment 復原後轉發照常。
- **CF 限制**（官方文件，2026-07 版本）：
  - DO **incoming WS message ≤ 128 KiB**；EdgeLink 單一 secure frame ≤ 64KB，安全。
  - DO 每 invocation CPU 上限 30s（每個 WS message 重置），轉發是 µs 級，遠低於。
  - Hibernation API 每 DO 最多 32,768 條 WS 連線；1:1 場景無關。
  - WS 連線時長無硬性上限；閒置連線靠 ping/pong 保活（OkHttp 15s、Mac 15s、
    DO auto-response 也有），實務上長連線穩定。
- **方案差異**：Durable Objects 需 Workers Paid（$5/mo 起，用量計費）；
  本專案已在用 DO，即已在 paid。WebSocket 轉發本身不收頻寬費，計費主要是
  DO duration（GB-s）+ requests。鏡像 1 小時 ≈ 36 萬個 6KB frame ≈ 每 frame 一次
  DO invocation → requests 量可觀但單價極低；duration 因 hibernation 只算活躍期。
- **落點**：DO 無法從內部知道自己的 colo；DO「建立在首次 `get()` 要求附近的
  機房」且不搬遷（可用 locationHint 或 jurisdiction 控制，本專案未設）。
  雙端都在台灣時 DO 幾乎確定在雙端 edge 附近（SIN 或 TPE）。本次已在
  `relay.ready` 帶 `colo`（`request.cf.colo`），雙端 log 可直接讀到各自 edge 落點。

## 4. 共用通道問題

媒體（Android→Mac，大流量）與控制/通知/keepalive（雙向，小封包）共用一條 WS：

- **Mac→Android 控制不受影響**：TCP 全雙工，反向 bytes 不排隊在媒體後面。
- **Android→Mac 方向的小封包會排隊**：notification、pong、battery 等 envelope
  與媒體共用 `SecureSessionClient.sendMutex` + 同一條 TCP stream。媒體 ~102
  msg/s，小封包最壞排在數個 8.4KB frame 之後；在 10-20Mbps 上行約 5-30ms
  額外延遲。pong 延遲超過 15s 才會誤判斷線——正常情況不會，但 4G 弱訊號 + 
  TCP stall 時會放大 pong 延遲，是 `pong_timeout` 斷線重連的潛在誘因。
- **是否要第二條連線**：值得做（Phase 1，見 §7），但優先級低於 transport 改造。
  做法：relay.auth 帶 `lane: "media"`，RelayDO 只轉給同 lane 的對端角色
  （attachment 已有擴充模式，auth body 加欄位即可，前向相容）。
  兩條 TCP 各自有 congestion state，控制訊息不再與媒體共享重傳命運。

## 5. 封裝開銷

每 6 KB 媒體 batch 的 wire 成本：

| 層 | 大小 | 備註 |
|---|---|---|
| RTP payload batch | 6,144 B | |
| base64 | 8,192 B (+33%) | |
| JSON envelope | ~8.4 KB | key/欄位 overhead |
| seal | +16 B tag + 4 B length | ChaCha20-Poly1305 |
| WS + TCP + TLS | +~100 B | |

- 頻寬膨脹 ~1.37x：5 Mbps 媒體 → relay 上 ~6.9 Mbps。在行動網路按量計費或
  弱訊號時是真成本。
- CPU：base64 encode/decode 6KB ≈ 數 µs，JSON parse 8KB ≈ 數十 µs，seal/open
  硬體加速後 <1ms。**CPU 不是瓶頸**，頻寬膨脹在弱網時才是。
- 改 binary frame 的空間：sealed plaintext 改為自訂 binary（magic + type +
  sessionId + seq + ts + raw batch），E2EE 位置不變（seal 照樣包在外面）。
  省 ~37% bytes 與 JSON/base64 CPU。需要 envelope codec 雙端同改 +
  `status.caps` 旗標協商（前向相容）。列入 Phase 1。

## 6. 量測方法（可重複使用）

本次新增的雙端埋點（log keyword → 含義）：

| log keyword | 端 | 含義 |
|---|---|---|
| `relay.transport.ready ... colo=` | Android | 手機 edge PoP |
| `relay.transport.mac.ready ... colo=` | Mac | Mac edge PoP |
| `relay.android.secure_rtt rttMs= offsetMs=` | Android | 經 relay 的 E2E RTT（每 5s） |
| `relay.mac.secure_rtt rttMs= offsetMs=` | Mac | 同上（Mac 主動 ping 時） |
| `xiaomi.mirror.cloudflare.latency oneWayMs= rttMs= offsetMs= bodyTs=` | Mac | **鏡像媒體單向延遲**（每 100 個 media envelope） |

原理：`status.ping` 帶 `t0`（wall clock ms），`status.pong` 回 `t0/ta/tb`；
兩端用 NTP 式 midpoint 算 RTT 與時鐘偏移 offset（androidClock − macClock）。
媒體 envelope 本來就帶 `body.ts`（Android `System.currentTimeMillis()`），
`oneWayMs = macNowMs − (body.ts − offsetMs)`。相容性：舊端忽略新欄位，
新端對舊端 pong（無 t0）自動跳過計算，不影響 keepalive 語義。

**真機量測步驟**：
1. 部署 worker（已部署，version b11d64f1，含 colo 修正）、安裝新 Mac build 到 /Applications、
   sideload 新 Android build。
2. 手機關 WiFi（或與 Mac 不同網），啟動鏡像 → 自動走 cloudflare fallback。
3. 播一段影片 60s，收集雙端 log：
   - Mac: `log stream` 或 diagnostics.log grep `colo=`、`secure_rtt`、`cloudflare.latency`、
     `cloudflare.stalled`、`rtp_batch_malformed`
   - Android: `adb logcat | grep EdgeLink` grep 同關鍵字 + `cloudflare_queue_health`
4. 分析：oneWayMs 分布（p50/p95/max）、secure_rtt 分布、stall 次數對應的
   RTT 尖峰。回放同樣內容對照 LAN direct。

## 7. 候選方案比較

| 方案 | 延遲改善 | NAT 穿透 | 雙端實作成本 | E2EE/envelope 相容 | 營運成本 | 結論 |
|---|---|---|---|---|---|---|
| **A. Custom domain 給 worker** | 可能無效：HiNet 分流針對非 Enterprise **方案**，自有 zone 非 Business+ 一樣可能被導海外 | 不變 | 低 | 相容 | 需域名 | **降級**：無現成 CF 域名，且對 HiNet 分流未必有效；不投資 |
| **B. TCP 調參**（batch 3ms 等） | 低流量期省 ≤7ms/batch | 不變 | 已完成 | 相容 | 無 | 已做；治本不了 jitter |
| **C. 媒體專用第二條 WS（lane）** | 控制訊息延遲隔離；媒體 jitter 不變 | 不變 | Worker + 雙端各 ~50 行 | auth body 加欄位，前向相容 | DO duration 略增 | 優先級低；E 上線後無必要 |
| **D. Binary media frame**（去 base64/JSON） | 上行需求 6.9→5.1Mbps（-26%），直接緩解實測到的 Android backlog 累積 | 不變 | 雙端 envelope codec 分支 + caps 旗標 | seal 位置不變；需 caps 協商 | 無 | **Phase 1 主力**：backlog 實測證明上行是緊的 |
| **E. KCP-over-TURN**（unreliable/unordered RTCDataChannel 承載**原始 KCP datagram**，不終結 KCP） | **同時解繞路與 HoL，且與小米官方媒體面同構**（libmpt 端到端，只是 UDP underlay 從 LAN 換成 TURN）：TURN anycast 實測 HiNet 6.6ms（vs workers.dev 67ms）；預估單向 p50 115→20-40ms；掉包由 libmpt fast retransmit ~1 RTT 修復，修不了才 skip（取代「TCP stall→等 IDR」秒級凍結） | TURN 專為穿 NAT 設計 | 雙端已有 WebRTC stack + 現成 `/v1/turn/credentials`；Mac 端直接重用 LAN direct 的 `MiplayKcpTransport` sink（datagram 進/出純組件）；手機 bridge 從「終結 KCP」改回「純 UDP 轉發」（更簡單） | 小米 TS 層 AES-CBC + WebRTC DTLS 雙層加密；signaling 走現有 secure envelope；7/27 的 KCP 終結是對 TCP 的正確妥協（double-ARQ meltdown），UDP 下撤回 | CF Realtime TURN $0.05/GB → 5Mbps ≈ **$0.11/小時** | **主力推薦**（6.6ms 實測 + 官方同構雙背書） |
| **F. 自建台灣 UDP relay（VPS）** | 雙端→VPS 各 ~5-15ms（TW 機房）→ 單向 ~10-30ms，最佳潛力 | 手機 UDP 出站通常可行；對稱 NAT 需 TURN 保底 | VPS 上 ~200 行 UDP forwarder；雙端需「secure datagram」格式（外顯 counter + replay window，protocol v2） | 保留 E2EE；nonce 需從隱含 counter 改外顯 | VPS $5-12/月（GCP/Azure/Linode Tokyo） | Phase 3 選項；比 E 更低的延遲上限，但要養一台機器 |
| **G. WebTransport (HTTP/3)** | 理論上同 F + datagram | 同 UDP | **不可行**：CF Workers 不支援 inbound WebTransport（workerd #6451 tracking 中）；macOS 原生無公開 WebTransport API，Android 亦無；須自建 QUIC server + 整合 QUIC stack | 需新協定層 | 同 F | **否決**（基礎設施與客戶端 API 都不成熟） |
| **H. Tailscale/overlay** | 直連成功時 ~0 relay；失敗走 DERP（≈F） | WireGuard 打洞強 | 兩台裝置裝 Tailscale + app 選路邏輯 | 媒體走 overlay UDP，需同 F 的 datagram 格式 | 免費額度內 | 不建議：依賴第三方帳號/服務，違反自架原則 |

### 建議 phasing

- **Phase 0（本次已落地）**：量測埋點 + batch delay 10→3ms。真機量一次，
  拿到 oneWayMs / secure_rtt / 雙端 colo 的實測分布。
- **Phase 1（小改，1-2 天）**：方案 D：binary media frame + `status.caps`
  旗標 `binaryMirrorMedia`。上行需求 -26%，直接對症實測到的 backlog 累積。
- **Phase 2（結構性解法，~1 週）**：方案 E，包裝為「libmpt 端到端 over TURN」，
  與小米官方媒體面同構（詳 §7 方案 E 與下方「KCP-over-TURN 包裝」）：
  手機 bridge 不終結 KCP，原始 KCP datagram 原封塞進 unreliable/unordered
  RTCDataChannel；Mac 端把 datagram 餵給 LAN direct 同一顆
  `MiplayKcpTransport` sink，ACK 沿 data channel 送回。signaling 與控制留在
  現有 secure channel；WS/TCP fallback 與 LAN direct 路線原樣保留。
  TURN 實測 HiNet 6.6ms，預估單向 p50 115→20-40ms。
  第一步先做最小驗證：雙端各開一條 data channel 跑 mirror media，
  用 §6 埋點對比 oneWayMs/stall 分布。
- **Phase 3（可選）**：方案 F，若 E 的 TURN 費用或實測落點不理想，
  用台灣 VPS 換最低延遲上限。

## 8. 本次改動清單（quick wins 已實作）

| 檔案 | 改動 |
|---|---|
| `worker/src/relay-do.ts`, `types.ts` | `relay.ready` 帶 `colo`（attachment 暫存 upgrade 時的 `request.cf.colo`）；前向相容 |
| `android/.../RelayTransport.kt` | ready log 帶 colo |
| `android/.../core/Envelope.kt` | 新增 `StatusPingBody`/`StatusPongBody`（全 optional，相容舊端） |
| `android/.../EdgeLinkController.kt` | ping 帶 t0；pong 回 t0/ta/tb；收 pong 算 RTT/offset 並 log `relay.android.secure_rtt` |
| `android/.../AndroidMiLinkMirrorMediaBridge.kt` | `RTP_BATCH_MAX_DELAY_MS` 10→3 |
| `mac/.../RelayTransport.swift` | ready log 帶 colo |
| `mac/.../Envelope.swift` | 新增 `StatusPingBody`/`StatusPongBody` |
| `mac/.../CommandDispatcher.swift` | ping/pong 帶時間戳；onStatusPong 改帶 body |
| `mac/.../EdgeLinkRuntime.swift` | ping 帶 t0；pong 算 RTT/offset（`RelayClockSyncBox` 跨執行緒安全）並 log `relay.mac.secure_rtt` |
| `mac/.../XiaomiMirrorRTSPDiagnosticSource.swift` | 每 100 個 media envelope log `xiaomi.mirror.cloudflare.latency oneWayMs=` |

驗證：worker `tsc --noEmit` 通過並已部署（version b11d64f1，含 colo 修正）；
Mac `xcodebuild` BUILD SUCCEEDED；Android `:app:compileDebugKotlin` 通過。

## 9. 待真機補數據

- [x] 手機端 `colo=` → **TPE**（遠傳）；Mac 端 → **SIN**（HiNet）。原因：HiNet↔CF
  peering 爭議，CF 把非 Enterprise HiNet 流量導海外（2016 年美西事件延續至今）。
- [x] `oneWayMs` / `secure_rtt` 分布 → §2.1：oneWay p50 115 / p90 1099ms；
  RTT p50 203 / max 2694ms
- [x] Android 送端 backlog → 單調增長（55→273/2min），上行 6.9Mbps 需求偏緊
- [x] TURN anycast 落點 → HiNet 實測 6.6ms（方案 E 可行性背書）
- [ ] batch 3ms 前後對比（本次量測已是 3ms；舊數據對照 2026-07-27 前 log）
- [ ] 方案 E 上線後同口径對比（oneWayMs p50/p90、stall 次數）

## 10. KCP-over-TURN 包裝（方案 E 定稿，2026-07-27）

設計原則：**不改變小米媒體面的任何一層語義，只換 UDP underlay**。

| 層 | 小米原版 | 現行 WS fallback | KCP-over-TURN |
|---|---|---|---|
| 媒體封裝 | RTP PT=33 / MPEG-TS / HEVC | 不變 | 不變 |
| 傳輸協定 | libmpt KCP over UDP | 手機終結 KCP → RTP payload → WS/TCP | **libmpt KCP 端到端** over TURN/UDP |
| 手機元件 | miplaycast / libmpt | 不動（loopback 本機段） | 不動（loopback 本機段） |

```
手機 miplaycast ─KCP/UDP(loopback)─ bridge（純 UDP 轉發，不終結 KCP）
   → KCP datagram 原封不動 → unreliable/unordered RTCDataChannel
   → TURN/UDP（HiNet 實測 6.6ms）
   → Mac：datagram 餵進 MiplayKcpTransport.receiveDatagram
        （LAN direct 同一顆 KCP sink）
   → ACK 經 onSendDatagram 沿 data channel 送回手機 → 注入 loopback
```

要點：

- 7/27 的「手機端終結 KCP」是對 **TCP** 的正確妥協（KCP ARQ + TCP 重傳 =
  double-ARQ meltdown）；UDP underlay 下撤回，恢復官方同構的端到端 KCP。
- relay 段對 libmpt 來說與 LAN 無異：會掉包、會亂序的 UDP，正是 KCP 設計來
  處理的。掉包由 fast retransmit（resend=10，660 pkt/s 下 ~15ms 觸發）在
  ~1 RTT（20-40ms）內修復；修不了才 skip，再由 Mac 端既有 RTP gap 邏輯接手。
  minrto=190ms 實務上吃不到（fast retransmit 主導）。
- Mac 端重用 `MiplayKcpTransport`（datagram 進 `receiveDatagram`、ACK 出
  `onSendDatagram`，21 個單測），sink 端零改動；手機 bridge 反而變簡單
  （拿掉 MiLinkMirrorKcpSink，變純轉發）。
- 加密：小米 TS 層 AES-CBC（不變）+ WebRTC DTLS（新增）；CF TURN 只看密文。
- KCP mtu=1400 與 data channel message 尺寸相容（SCTP/DTLS MTU ~1200-1500）。
- 能力協商：`status.caps` 加旗標；signaling 走現有 secure envelope 模式
  （參考 screen 路線 rtc.offer/answer/ice，mirror 用獨立 type 避免與
  edgelink-screen session 糾纏）。
- 降級順序：LAN direct → KCP-over-TURN → 現行 WS/TCP fallback（原樣保留）。
