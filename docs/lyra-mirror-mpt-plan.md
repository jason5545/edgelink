# 方案二：鏡像媒體走 mpt KCP — 研究結論與實作計畫

日期：2026-07-27。來源：三路逆向/盤點（Mac micontinuity_sdk、手機 Mirror.apk/mi_connect、
現有 EdgeLink 程式碼）。mpt wire format 細節見 `docs/lyra-mpt-wire-format.md`。

## 重要架構修正

原本假設「官方鏡像媒體走 lyra::netbus::mpt」。真機/逆向證據修正為：

- **控制面走 Lyra**：service `com.xiaomi.mirror:cast`（trust 48），Mac createChannel("cast")
  → channel 上 event-23 KeyData（ECDH P-256 換 key）→ `ScreenActionMessage{OPEN_MIRROR_SCREEN}`
  → 手機起 source → `ScreenConfigurationChangedMessage{ON_CREATE, port}`。
- **媒體面不走 micont mpt**：手機 miplaycast = RTSP server（bind 手機 LAN IP，port 7236+displayId），
  Mac = RTSP client **直接 LAN TCP** 連入；RTP 媒體走 **libmirror-jni 私有 libmpt**
  （KCP over UDP，ports/userid 在 RTSP SETUP 協商）。libmpt 與 micont `netbus::mpt`
  是兩個獨立 stack（同為 KCP，conv 是否同為 0x12345678 待抓包）。
- **封裝**：RTP PT=33 / MPEG-TS / H.264+HEVC + AAC；TS payload AES-CBC-128
  （key/IV 來自 event-23 ECDH：shared[0:16]=key+authKey、shared[16:32]=IV，與 LogiConn
  KeyAgree 的 channel 加密是獨立兩層）。RTSP 層另有 authKey challenge（type=3）。

結論：「方案二」= 讓我們的鏡像跟官方同構 = **Lyra 控制通道 + LAN direct RTSP/TCP +
libmpt KCP/UDP 媒體**，徹底取代 Cloudflare relay。LAN direct 模式在 codebase 已存在
（diagnostic 包裝），本計畫是把它主路線化並補強。

## 現有資產（重用）

- `XiaomiMirrorRTSPDiagnosticSource.swift`：完整官方 RTSP sink（OPTIONS/auth、
  GET_PARAMETER、主動 SETUP `RTP/AVP/MPT`、PLAY、keepalive）+ **完整 MPT KCP sink**
  （conv 動態建立、PUSH/ACK/WASK/WINS、亂序緩衝、ACK batching）+ RTP→MPEG-TS demux
  → HEVC AU 組裝 → VideoToolbox decode → render。decode/render **零 gap**。
- LAN direct 已接入 runtime：`EdgeLinkRuntime.swift:4025-4044`
  （`xiaomiMirrorLanDirectSelected` → 停 cloudflare receiver → 直連 source endpoint）。
- 觸發鏈不變：`milink.command` + Xposed fake-remote 系列 hook（繼續需要）；
  差別只在 `armMirrorScreenRemote` 的 peerHost/peerPort 指向 LAN 而非 127.0.0.1。

## Gap list

1. **MPT transport 抽層**：完整 KCP sink 困在 App 層 diagnostic source（private、
   與 RTSP diagnostic 耦合）。抽到 EdgeLinkKit，補 server 端多 conv accept、
   （若需要 Mac 主動發 PUSH）傳送端重傳。LyraMeshSocket/LyraChannelSocket 的
   KCP-lite 不適合擴充。
2. **lan_direct 主路線化**：目前 cloudflare 與 lan_direct 並存（selection 依
   LAN probe）。要把 LAN 可用時固定走 direct、cloudflare 降為純 fallback，
   並把 direct 模式從「diagnostic」命名/生命週期中正式化。
3. **Cloudflare 路保留為已驗證 fallback**：`milink.mirror.media` envelope、
   `AndroidMiLinkMirrorMediaBridge` 不退役。主路線 = LAN direct；fallback 時必須
   確認 Cloudflare 走得通（見下方「已落地」的 penalty/健康追蹤機制）。
4. **（可選，官方控制面）**用 Lyra cast channel（event-23 KeyData、ScreenActionMessage）
   取代 Shizuku/Xposed arming — 工作量大，需逆 Mirror.apk proto；現階段觸發鏈已可用，
   列為後續獨立項。
5. **待真機補完**：libmpt KCP conv 驗證、authMsg/authKey 演算法（目前用自訂
   `EdgeLinkMirrorK!`，靠 hook 放行）、MPT vs UDP 選擇條件、AP client isolation
   下的降級策略（15056 前科）。

## Phasing

- **Phase 1（主線，已落地 2026-07-27）**：
  - MPT KCP 抽到 `mac/Sources/EdgeLinkKit/Miplay/MiplayKcpTransport.swift`
    （pure Foundation、datagram I/O closure 抽象、21 個單元測試，EdgeLinkKit 146 tests 全綠）；
    `XiaomiMirrorRTSPDiagnosticSource` 改用之（-537 行），public 表面不變。
  - lan_direct 主路線化（原本 phone 端已 LAN-first，本輪補上 Mac 端升級/降級狀態機）：
    `EdgeLinkRuntime` 追蹤 `xiaomiMirrorActiveMediaTransport`；lan_direct session
    連續 2 次零媒體（datagrams/pushReceived == 0）→ 進入 10 分鐘 penalty，
    期間 `addXiaomiMirrorLANProbeArgs` 抑制 lanProbePort → 手機自動選 cloudflare；
    lan_direct 有 decoded frames 即重置。cloudflare session 零媒體時 log
    `screen_media_transport_no_media transport=cloudflare` 供稽核。
  - 待真機驗證：LAN 主路線穩定性 + 斷 LAN/UDP 時 cloudflare fallback 走得通。
- **Phase 2**：Cloudflare 路**不退役**；改為維護 fallback 品質（對照 LAN 的
  jitter/latency 指標、fallback 演練）。
- **Phase 3（可選）**：Lyra cast channel 官方控制面，逐步退役 Xposed arming。
