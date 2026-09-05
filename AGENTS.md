# EdgeLink Agent Notes

這份文件只放 EdgeLink 專案特有的工作規則、驗證方式與已確認的陷阱。遇到規則衝突時，以 Jason 當前明確要求為準；涉及中斷連線、覆蓋安裝或刪除資料的動作，仍要先確認範圍並在完成後驗證結果。

## 規則標記

- `[MUST]`：完成工作前必須遵守。
- `[MUST NOT]`：除非 Jason 明確要求，否則不得做。
- `[DEFAULT]`：沒有更具體指示時，採用這個流程。
- `[OBSERVED]`：有日期、版本或測試範圍的現場觀察，不要擴大解讀成永久規則。
- `[DISRUPTIVE]`：會中斷連線、停止程序或改變使用中系統狀態。
- `[MUTATING]`：會寫入、覆蓋、註冊、刪除或重啟系統狀態。

## Definition of done

### 程式碼與專案設定

- `[MUST]` macOS code、`mac/project.yml` 或 Mac 測試變更完成前，必須通過完整 Mac 測試套件：

  ```sh
  cd mac && xcodebuild -project EdgeLink.xcodeproj -scheme EdgeLinkMacTests -configuration Debug -derivedDataPath /private/tmp/edgelink-test-dd test -parallel-testing-enabled YES -maximum-parallel-testing-workers 4
  ```

- 測試與執行中的 `/Applications/EdgeLinkMac.app` 共存：`XiaomiMirrorMediaLoadTests` 透過 `XiaomiMirrorRTSPDiagnosticSource.officialMPTClientPortOverride` 把 MPT sink 綁到 test port block（prod 固定用 UDP 15550），不需要先 quit app。

- `[MUST]` 新增測試檔後，先在 `mac/` 執行 `xcodegen generate`，再跑完整測試；否則新檔可能不會被 Xcode project 收進去。
- `[MUST]` Android code、Gradle 設定或 Android 測試變更完成前，至少在 `android/` 執行：

  ```sh
  ./gradlew test
  ```

- `[MUST]` 同時改到 Mac、Android、relay protocol 或跨裝置流程時，兩端測試都要通過，並補跑相關的 adb / device validation。
- `[DEFAULT]` 純文件、研究資料或診斷紀錄整理，不需要為了形式跑完整產品測試；但要確認 diff、路徑與引用沒有錯。
- `[MUST NOT]` 在相關測試全部通過前，不得把 build 部署到 `/Applications`。
- `[DEFAULT]` 部署是獨立的驗證或安裝動作，不是每次 build 後自動執行的收尾步驟。

## Build、簽署與本機安裝

- `[MUST]` `mac/project.yml` 是 Xcode signing 設定的 source of truth。修改後，從 `mac/` 執行 `xcodegen generate`。
- `[MUST]` 本機安裝的 macOS app 使用 Apple Development Team ID `MW4GWYGX56`。
- `[MUTATING]` 安裝到 `/Applications` 使用 `ditto`，不要用 Finder 拖曳：

  ```sh
  ditto /private/tmp/edgelink-derived-data/Build/Products/Debug/EdgeLinkMac.app /Applications/EdgeLinkMac.app
  ```

- `[MUST NOT]` 不要直接從 DerivedData 或 `/private/tmp` 啟動 `EdgeLinkMac.app`；測試 signed app 時，一律使用 `/Applications/EdgeLinkMac.app`。
- `[DEFAULT]` 如果真的需要直接啟動 debug build，先給 debug build 不同的 bundle ID suffix，避免污染正式 app 的 LaunchServices、通知或 Keychain 狀態。

## Android 與裝置診斷

- `[DEFAULT]` 開始 adb 診斷前，先用 `adb devices` 確認 USB 裝置與連線狀態。手機目前通常已連線，且 adb root 可用，但不要把這件事當成無條件保證。
- `[OBSERVED]` 2026-08-12：手機上 Shizuku 以 uid 0（root）運行，因此 `EdgeLinkShizukuService` 內可直接執行需 root 的操作（例如 `su 1000 -c ...` 進 uid 1000 keystore namespace 存取 `lyra_store_manager` alias），不需要另外假設只有 shell（uid 2000）權限。
- Android diagnostics log：

  ```sh
  adb shell "run-as com.edgelink.app tail -60 files/diagnostics.log"
  ```

- Mac diagnostics log：

  ```sh
  tail -200 ~/Library/Application\ Support/EdgeLink/diagnostics.log
  ```

- TeleService relay、`RelayLog` 與 call-relay flow 在 radio buffer，不是在一般 main buffer：

  ```sh
  adb logcat -b radio -d
  ```

- `[DISRUPTIVE]` Debug probe 會殺掉 live mirror session。只有在已接受中斷、或為了取得必要證據時才執行；完成後要重新連線：

  ```sh
  adb shell am broadcast -a com.edgelink.app.DEBUG_PROBE_MILINK -p com.edgelink.app [--es command xiaomi.mi_connect.networkingProbe]
  ```

- `[OBSERVED]` 2026-08-05 起 call-relay / mirror fake-remote inject 已全面拆除（commit `b67642533` 前後），`debug.edgelink.relay_*`、`debug.edgelink.mirror_fake_*` 等 prop 在程式碼中已不存在；TeleService relayCall 走自然註冊。目前 Android tree 唯一仍讀取的 debug prop 是 `debug.edgelink.mirror_wifi_gate`（手動除錯開關，production 不設定）。

- `[OBSERVED]` 2026-08-13：Android Telecom 像 CallKit 一樣統一第三方 VoIP 通話——LINE 等 app 註冊 self-managed ConnectionService 後，其通話會送達所有 bound InCallService（含 `EdgeLinkInCallService`），曾導致 LINE 來電觸發 Mac incoming-call UI。`PhoneCallReportPolicy` 只放行 SIM telephony（`PhoneAccount.CAPABILITY_SIM_SUBSCRIPTION`，或 account package 為 `com.android.phone`/`com.android.server.telecom`）；非 telephony call 不送 `phone.call_status`、不參與 idle/DTMF/activeCall 判定。分類是 per-call sticky upgrade（details 後補齊時轉 reportable，不 downgrade）。

- lyra-debug CLI（pcap / parse / keys）：

  ```sh
  xcodebuild -project mac/EdgeLink.xcodeproj -scheme LyraDebug -configuration Debug build
  ```

  binary 通常在：

  ```text
  ~/Library/Developer/Xcode/DerivedData/EdgeLink-*/Build/Products/Debug/lyra-debug
  ```

- Phone-side APKs for jadx research：

  ```text
  /system/priv-app/TeleService/TeleService.apk
  /product/priv-app/Mirror/Mirror.apk
  ```

  既有 decompile 在 `captures/`，例如 `captures/xiaomi-mirror-device/jadx/` 與 `captures/mi-connect-service/jadx/`。

- lyra store seed 工具的原始 source（root 種 identity-cred/ticket 進 `storage.lyra`，搭配 `su 1000` + app_process + keystore alias `lyra_store_manager`）：

  ```text
  captures/lyra-live/lyraseed/Seed.java（+ 已編譯 classes.dex）
  captures/mi-connect-service/jadx/sources/com/xiaomi/continuity/netbus/utils/AesUtils.java（AES/GCM/NoPadding、pack=BE32 ctLen|ct|BE32 ivLen|iv）
  ```

  可用 invocation（2026-08-03 驗證）：

  ```sh
  adb shell "su 1000 -c 'CLASSPATH=/data/local/tmp/seed.dex:/product/app/MiConnectService/MiConnectService.apk app_process / Seed dump > /data/local/tmp/seed.out 2>&1; echo exit=\$?'"
  adb shell "su -c 'head -60 /data/local/tmp/seed.out'"
  ```

  `[OBSERVED]` 2026-08-03：shell 只顯示 `Killed`（exit=137）時，根因通常是 dex 拋 uncaught exception（例如只放 seed.dex 沒帶 MiConnectService.apk → `ClassNotFoundException: AesUtils`）後被 RuntimeInit 的 KillApplicationHandler SIGKILL，不是 OOM/SELinux；看 logcat 的 AndroidRuntime 才是真相。CLASSPATH 必須含 APK、必須 `su 1000`（root 跑會 `DECRYPT_FAILED`）、輸出導檔再讀。

- 擷取 pcap 時：

  ```sh
  adb shell "nohup tcpdump -i wlan0 -s 0 -w /sdcard/x.pcap host <mac-ip> >/dev/null 2>&1 & echo \$!"
  ```

  記下輸出的 PID。停止時優先執行 `adb shell kill <pid>`；只有在已確認沒有其他擷取工作時，才使用 `adb shell pkill tcpdump`。完成後再 `adb pull` pcap。

## Xiaomi mirror：已確認的保護邊界

- `[MUST NOT]` 不要預設去修改 dim、brightness、power 或 Hangup-related code，包括 `AndroidScreenPowerGuard`、MIUI Hangup / synergy power-key paths。
- `[OBSERVED]` 截至 2026-07-28，在目前 Xiaomi mirror path 中，virtual display 即使亮度為 `2.44E-4`、處於 DIM，甚至 screen off，影片仍會持續流動；這符合官方 Hangup 行為。
- `[OBSERVED]` 2026-08-16：已拆除所有 dim/keep-awake workaround（`AndroidScreenPowerGuard` 的亮度 dim 與 mirror keep-awake provider、Xposed hook 的 `edgeLinkKeepAwake` 分支、controller 的 `miLinkScreenPowerGuard` 與 `screenDimmingAccessGranted` plumbing）。官方鏡像走 Hangup 虛擬螢幕，實體螢幕狀態不影響 encoder，這些 workaround 已無用途。`AndroidScreenPowerGuard` 現在只做 WebRTC 螢幕分享路徑的 screensaver 停用 + FGS。不要把它們加回來。
- `[OBSERVED]` 靜態畫面時 encoder 產生 zero frames 是目前已知的正常行為，不要直接當成 video stall。
- `[OBSERVED]` 2026-08-11：HyperOS（myron）上 `KeyguardManager.isDeviceLocked` 在 SCREEN_ON 後約 300ms 會回報 `false`，即使 swipe-up lockscreen 還在畫面上；Mac 端信任這個 fresh「unlocked」push 會直接播鎖定畫面、不跳 Touch ID。lock reporter 已改用 `isKeyguardLocked`（lockscreen 顯示中即為 true）。另外 duo.screen authEvent 可能整個不送達（relay-rebuilt channel 上 mitrustservice 未回應），`MacTrustManager.authEventTimeout`（預設 60s）是解鎖等待的上限，不要移除。
- `[OBSERVED]` 2026-08-11：手機的 relay-path channel client（HeteroChannel quick-conn）在 mitrust channel 上講 official `82 58` packet format，不是 `81 04`；`LyraVirtualChannelPipe` 已支援兩種格式，收到 82 58 後 send 端也切 official（`sendOfficial` auto-detect）。測試用 `forceOfficialFormat`（pipe）與 `LyraCastRole.mitrustSpeaksOfficial` 建模。
- `[OBSERVED]` 2026-08-11：手機螢幕關閉時 milink 會停送 keepalive（`send ignore, screen is off`），relay-fed loopback phys conn 約 4s 後 `kcp trans timeout` 被拆；此時落入的 cast dial 會 wedge（phys sync 有回、logi 層不動），10-30s 後自愈。WiFi 關掉時 `IsNetworkConnected type=0x100 → 0`，wifi 類 link addr 全被 `DeleteDisableMediumTypes` 過濾，trustservice 回撥 mitrust channel 直接 15011「no device link addr」。Mac 端對策：mirror flow channel timeout 後自動 drop wedged session 重撥一次（`channelTimeoutMaxAutoRetries`）。
- `[OBSERVED]` 2026-08-12：手機 trustservice 在 mitrust ceremony 後約 40s 閒置自動拆 channel（52014）；下次解鎖要重建，且 phone 的 score-based reuse 可能挑到 announcer 的 phys conn。`LyraMeshAnnouncer` 已會把 mitrustservice sync_info adopt 進 `LyraCastTrustSession.activeTrustSession`（同 `LyraMeshResponder`），注意該分支必須排在 `LyraRelayCallSession.activeRelaySession` 的 unchecked fallback 之前，否則會被吃掉。Mirror app 對 cast channel 有約 5s 閒置 auto-release（`checkAndSetAutoReleaseRunnable`）；empty extras 的 `MiTrustService/SDK JSONException` 是正常噪音。
- `[OBSERVED]` 2026-08-12：Android cloud mirror bridge 在 relay 斷線時刻意保留（避免 encoder wedge），但需要 `MIRROR_BRIDGE_ZOMBIE_TIMEOUT_MS`（5min）watchdog 回收——否則 Mac 消失後 TURN 會對空 stream 數小時、佔住 RTSP source 讓後續 LAN mirror 被 `peer_closed`。watchdog 在 handshake_ok 解除、Mac sleeping 時不 arm。
- `[OBSERVED]` 2026-08-13：mirror 未串流時先做 Touch ID 解鎖，手機螢幕 timeout（~15-30s）會重新 arm keyguard，mirror 姍姍來遲只看到 locked=true（re-lock race）。Mac 側修法：`MacTrustManager.lastUnlockSuccessAt` + lock reporter 的 unlocked push（`lastExternalUnlockAt`）確認 unlock 生效後，`XiaomiMirrorFlowController` 在 staleRelockGrace（60s）內遇到 locked 解析時自動重送 562（多一次 Touch ID prompt），每次 unlock_success 只自動重試一次。
- `[OBSERVED]` 2026-08-13：562 auth in-flight 時 relay flap 殺掉 cast session，舊 session 的 `finishLocked` deferred `trustManager.stop()` 會清掉 pending auth wait（並可能踩掉重建 session 的 status query）→ 手機在重建 channel 上重驅 mitrust ceremony 完成後 authEvent 被靜默丟棄，mirror 卡 解鎖中。修法：unlock wait 是 phone-global，`MacTrustManager.stop()`/`start()` 保留 `awaitingAuthEvent` 與 `.authenticating`（timeout 繼續 bound）；`finishLocked` 在已有新 session 接管時跳过 stop；flow controller 在 `.unlocking` 遇到 channel release 也重建。手機端對應行為：pending unlock 會在下一條 fresh phys conn 上重新 adopt mitrustservice。
- `[OBSERVED]` 2026-08-13：串流中手機螢幕 timeout 重新 arm keyguard 時，lock reporter 的 locked=true push 以前不改 trust state → Mac 繼續串流鎖定畫面、無 mask。現在 `notifyExternalLockState(locked: true)` 在 `.ready(locked: false)` 時轉回 `.ready(locked: true)` 並清 `unlockConfirmed`（`.authenticating` 中不動，避免踩掉 authEventTimeout 的 state guard）。另外 flow controller 的 stale-relock 自動重送必須驗證 `trustManager.state` 當下仍是 `.ready(locked: true)`——state event 走 Task hop，queued 舊事件在 `start()` 已重置為 .queryingStatus 後送達，照它行動會讓 `unlockRequested` 的 fallback 對健康 channel 發 redial（可能 redial_timeout 卡死）。
- `[OBSERVED]` 2026-08-13：secure session 走 relay 且手機同時在 LAN 時，mirror 的 media/cast dial 過去看 `lyraRelayBridge != nil` 就全域走 TURN（RTT ~100ms、每 ~30s cloudflare stall loop）。修法：`LyraRelayTransportGlue.preferRelayMirrorTransport(relayBridgeAvailable:lanPhoneReachable:)`——LAN 可達（miShare discovery endpoints 非空）一律優先 LAN direct；recovery/close 路徑改用 `xiaomiMirrorMediaOnCloudBridge`（active session 的實際 transport，`lan_direct` 現在也會在 cast-OPEN LAN 分支標記），不再用 bridge 存在與否推論。
- `[OBSERVED]` 2026-08-13 15:01（pure relay，已含 79ca00318 的 build）：relay 承載的 mitrust adoption 儀式本身完整跑完——sync_info → ticket-reuse auth 被手機回 alert type=5「bad server notify message」（AccountPair cred wall，LAN 成功組也有，純噪音）→ KeyAgree fallback → logi → responseOfPeerPort——然後完全靜默：手機 bridge 的 reverse listener 沒學到 advertised port（snooper 漏了 responseOfPeerPort，當時 relay session 正好 mid-ceremony rebuild / KCP reassembly gap reset），手機 channel client 撥進死路，~10s kcp trans timeout → authEvent code=1。也就是說 79ca00318 修好 Mac 端 pipe 註冊後，失敗點移到 phone-side snooper 這層。修法：Mac 在送 responseOfPeerPort 之前先用 `relay.channel.listen` envelope（body `{p: port}`，走 secure session，worker 不看 envelope type 不用改）out-of-band 通知手機 bridge 綁 reverse listener（`LyraRelayTransportBridge.announceChannelListener` / Android `bindReverseChannel`），不再依賴 lossy snoop；舊手機忽略未知 envelope 行為不變。Mock：`LyraCastRole.mitrustChannelDialUnreachable`（snoop miss 的 dead-end dial）+ harness factory 依 `announcedChannelListeners` 與 `phoneHandlesChannelListen` gate；E2E `testTrustUnlockOverCloudRelayWhenChannelDialUnreachable`（legacy phone → code=1 → retryable locked mask）與 `...ButAnnounced`（listen-capable phone → unlock 成功）。
- `[OBSERVED]` 2026-08-13：雙棲手機（secure session 走 relay、mirror 走 LAN）unlock 間歇 code=1 的根因：手機 trustservice 的 score-based reuse 把 mitrustservice adoption 打到 relay-fed 的 announcer phys conn，而 LAN cast session 的 `handleMitrustPeerPortRequest` 只看自己的 `relayBridge`（nil → 建 LAN UDP socket）；手機 channel client 綁在 adoption conn 的 transport 上，dial 走 relay bridge → Mac bridge 無該 port 的 pipe → datagram 全掉 → 562 kcp trans timeout ~10s → authEvent code=1。選哪條 phys conn 半隨機，所以成敗交替。修法：channel transport 跟隨 adoption conn（`mitrustAdoptedViaRelay` + `LyraCastTrustSession.activeRelayBridge` hook，announcer 傳 `viaRelay: !(socket is LyraMeshSocket)`），teardown 用 `srvChannelBridge`（實際擁有 pipe 的 bridge）。伴生的 `mitrust_alert_rx type=5 "bad server notify message"` 是 AccountPair cred wall 的預期拒絕（成功組也有），與 code=1 無因果；mock（`LyraCastRole.mitrustUnlockTimeout` watchdog + `LyraMirrorOverRelayTests.testTrustUnlockWhenRelayFedAdoptionMeetsLANCastSession`）不建模 alert 也完整重現了 code=1。
- `[OBSERVED]` 2026-08-13：同日下午另一次 code=1 的根因不同——手機 Mirror app 的 ~5s 閒置 auto-release 拆掉 cast channel（52014），session 照設計 redial，但 cast channel supervisor 的 `stuckBuilding` 分支（session >30s 且 channel 未 ready）在 redial 第 2 秒強殺整個 session，手機的 mitrust logi conn/channel 還綁在已死的 socket 上（phys heartbeat 17s timeout 16032），in-flight 562 落空 → code=1。`stuckBuilding` 分支已刪除（flow controller 的 `channelReadyTimeout`/`redialResponseTimeout`/session 30s watchdog 已覆蓋 wedged dial）；supervisor 保留 streaming 中的靜默 channel probe+rebuild 與 idle 時的 pairing status query。
- `[OBSERVED]` 2026-08-13 05:53：殘餘 code=1 的 zombie mitrust channel 窗口——idle auto-release → redial 無人應答 → redial_timeout → session fail 拆掉 mitrust server channel，但手機的 mitrust channel client 要等 phys heartbeat ~17-20s 才發現 conn 已死；窗口內的 562 打進 zombie → quickAuth shared auth timeout ~10s → authEvent code=1。修法（Mac 側）：`LyraCastTrustSession.finishLocked`/`teardownPhysAfterAuth` 在 `socket.stop()` 前對收養的 mitrustservice conn（`srvConnId`）主動送 logi disconnect（frameType 4、payload {1: 52011}，官方 server→phone 先例），手機立刻拆 channel client，下次 562 走 fresh adoption。注意 `NWConnection.send` 是非同步的，同 queue turn 內 stop socket 會丟掉還沒送出的 disconnect——有送 disconnect 時 stop 延 0.2s flush beat，且 `onFinish` 跟著延後（rebuild 靠 onFinish 同步，晚到的 stop 不能殺新 dial）；無 mitrust conn 的路徑維持同步 stop 不變。語意修正：`MacTrustManager.handleAuthEvent` 的 code=1（`terminalAlt`）是 transport timeout 不是解鎖被拒，回 `.ready(locked: true)`（lock mask 可重試），不再 `.failed` → connectFailed。Mock：`LyraCastRole.mitrustChannelClientLive`（562 重用 live channel）+ 收到 disconnect 即清；E2E `testTrustUnlockAfterSessionRebuildClearsZombieMitrustChannel`。
- `[OBSERVED]` 2026-08-21：手機→Mac MiShare（相簿分享）「連線失敗」的根因與 2026-08-12 mitrustservice 同類——手機的 score-based reuse 把 `com.xiaomi.hyperConnect:miLyraShareTransfer` 的 LOGI_CONN_SYNC_INFO 打到 Mac 的 announcer phys conn（而非手機自己 dial 43181 的 mesh conn），`LyraMeshAnnouncer` 的 foreign-conn chain 沒有這條 route → `announcer_stray_conn` 丟棄 → 手機 15s kcp timeout（33006）。修法：`LyraMeshResponder.shared`（attach 時註冊）+ `handleAnnouncerLogiConn`/`handleAnnouncerPayloadV2` 讓 responder 從 announcer socket adopt 這條 receive conn（sync-auth/upgrade/encrypted response 走 announcer 的 `reply`；responseOfPeerPort 與 sync announce 等無 reply context 的 send 改用 adoption 時 capture 的 announcer `send` override——responder 自己的 socket 對該 endpoint 沒有 inbound connection）。announcer 端 insertion 必須排在 `LyraRelayCallSession.activeRelaySession` 的 unchecked fallback 之前，packType-5 分支排在 announce-payload 解密之前（未 adopt 或解密失敗一律回 false，announce sync payload 不受影響）。Mock：`LyraMiShareSenderRole`（LyraServerKit，完整 receive flow：sync_info → P256 upgrade → encrypted request → responseAck → requestOfPeerPort，另含檔案傳輸：channel connect/negotiation → express handshake → file request → stream begin → express TCP streamlets → EOF → complete，wire format 與 `LyraFileSendSession` 相同；inline 小檔走 file-message field 4，大檔走 stream、chunk 由 generator 按需產生所以可覆蓋 10GB）；E2E `LyraMiShareReceiveTests`（baseline 直連 responder socket + announcer-conn dial 重現 + inline 小檔 / 8MB stream / 10GB stream 收檔驗證，收檔目錄以 `LyraMeshResponder.miShareDownloadDirectoryOverride` 導到 temp dir）。同日 xctest SIGSEGV：`LyraMeshSocket.send(frame:to:port:)`/`stop()` 原本可在任意 thread 直接 mutate `sessionStates`/`outboundConnections`（channel-socket queue → responder → announcer send 與 mesh queue receive loop 競爭 dictionary）；現在 mutating entry points 一律經 `onQueue`（dispatchSpecific 偵測，已在 queue 上的 handler 直跑避免 deadlock）confine 到 socket queue。
- `[OBSERVED]` 2026-08-22：Mac→手機 MiShare（互傳另一邊）也有完整 mock——`LyraMiShareReceiverRole`（LyraServerKit，phone 側接收端：phys sync/cookie 走 `LyraPhoneMeshServer` 內建，role 回答 sync_info（Curve25519 cred）→ family-5 server hello（CS/SC channel key）→ encrypted `.response` → requestOfPeerPort 時開真的 `LyraChannelSocket` listener 回 responseOfPeerPort → channel 上送 express handshake（TCP listener + 16-byte data key）→ accept(tag 2) → rcvBegin(event 4) → 收 express TCP AES-GCM streamlets → rcvEnd(event 5) → done(tag 8)，wire format 完全比照 `LyraMeshResponder` 收檔路徑；`chunkValidator(streamId, offset, data)` 逐 chunk 驗證內容與 offset，不 buffer 全檔）。E2E `LyraMiShareSendTests` 跑 production `LyraFileSendSession`（已編進 test target）：小檔（兩個 64KB chunk 逐 byte 比對）、雙檔（multi-stream 排序 + 每 stream offset 歸零）、10GB sparse 檔（APFS sparse 只實寫 3 個 1MB pattern segment——檔頭、4GB 邊界、檔尾——其餘讀回零，validator 逐 chunk 重算預期值驗證 64-bit offset）。這個測試同時暴露並修掉一個 production bug：`LyraFileSendSession` 的 30s liveness watchdog 原本只算 inbound traffic，純送出的 stream 超過 30s（10GB 在真實 LAN 上一定超過）會在傳輸中被自己 `逾時` 殺掉；現在 `sendNextChunk` 每送一個 chunk 也算 progress。另一個 mock 側教訓：production 在 8 條 express TCP connection 上 round-robin 送 chunk，loopback 高負載下 streamlet（甚至 EOF）會跨 connection 亂序到達，接收端不能假設 offset 嚴格遞增——比照 `LyraMeshResponder` 的 seek-write，按 offset 記帳、EOF 等尾包補齊才算完成。同日完整套件另抓到一個 mock 基建 race：`LyraDevRepoOracle` 在 dual-transport 測試被兩條 mesh pipe（不同 queue）共享，無鎖的 `records`/`deviceKeys` dictionary 寫入競爭 SIGSEGV（`testDualTransportAnnounceRegistersSingleDevice` 0.000s 暴斃）；oracle 內部 state 現在一律經 `NSRecursiveLock`，公開集合改 computed copy（`oracle.records[...]` 讀法不變）。
- `[OBSERVED]` 2026-08-27：手機→Mac MiShare「傳送失敗」的第三個根因——真機的 miLyraShareTransfer encrypted conn request 在同一個 `LogiConnInnerFrame` 帶兩個 payload field：field 2 `.request`（338B）＋ field 8 `.authHandshake`（62B feature/capability block，含 28-char task id）。`LogiConnInnerFrame(parsing:)` 原本 last-payload-wins，`payload` 被 `.authHandshake` 蓋掉，`LyraMeshResponder.handleEncryptedLogiConn` 的 `if case .request` 不成立 → Mac 完全靜默（`mesh_logi_response` 從未出現）→ 手機 15s kcp timeout 送 sync_auth_status 15033 → 傳送失敗。修法：`LogiConnInnerFrame` 新增 `payloads: [LogiConnInnerPayload]`（wire order 全保留；`payload` 維持 last-wins 相容，`init(frameType:payloads:)` 與 `serialized()` 會寫出多 payload），responder encrypted path 改掃 `payloads` 找 `.request`/`.responseAck`。Mock：`LyraMiShareSenderRole.appendsAuthHandshakeToConnRequest`（預設 true，按 live capture 重建 62B block；flip 可驗 legacy 單 payload），E2E `testMiShareReceiveWhenConnRequestCarriesAuthHandshakeTrailer`＋`testMiShareReceiveWithLegacySinglePayloadConnRequest`，frame 層 `testLogiConnInnerFrameKeepsAllPayloads`。注意同類風險：`LogiConnInnerFrame(parsing:)` 的 `.payload` 消費者還有 ~20 處（`LyraFileSendSession` 的 `.response` 判斷等），若真機在那些方向也帶 trailing fields 會同樣被蓋——遇到再補，勿預設全面改寫。
- `[OBSERVED]` 2026-08-27（同日第二輪）：修好 multi-payload 後真機仍 15s timeout（sync_auth_status 15006）——根因是 conn response 內容，不是 key。官方 `LogiConnProtocol::SetConnResponseFrame`（micontinuity_sdk 0x15f490）永遠寫 field 3（confirm flag）= 1，且當 request 的 private_data field 5 帶 tcp_tunnel_profile 時 response 必須帶 `TunnelCapacity{f1:1}`（field 4）；手機在 `LogiStateRequestRemoteConfirm` 跑 `CheckTunnelCapacity`（0x1a305c），缺 cap → 15066。我們原本送的是空 `.response`。注意除錯陷阱：試過改用 SC（serverRandom+clientRandom）方向 key 加密 response，手機秒回 15071「logical conn secret decrypt failed」——證明 session key 只有一把（CS，clientRandom+serverRandom，雙向同 key，`KeyAgreeHandshake::GenerateSessionKey`）。修法：`LyraMeshResponder.parseLogiConnRequest` 記錄 `requestTunnelProfiled`（privateData field 5 非空），`sendLogiConnResponse` 送官方形狀 `{f3:1, f4:TunnelCapacity{08 01}}`（無 profile 時只有 f3）。Mock 同步改嚴：`LyraMiShareSenderRole` 的 conn request 帶 live capture 的 29B tunnel profile block，`.response` 必須含 field 4 cap 否則判 failed（重現 CheckTunnelCapacity）；`LyraMiShareReceiverRole`（Mac→手機方向，其 request 本就帶 profile）回答也改官方形狀。
- `[OBSERVED]` 2026-08-27（同日第三輪）：前兩修上機後，真機的 miLyraShareTransfer sync_info 完全到不了 responder——手機的 score-based reuse 這次把 dial 打到 **cast trust session 自己的 socket**（mirror flow 在 session connect 時建立的 trust session；stage=ready），`LyraCastTrustSession.handleLogiConn` 的 `.syncInfo` catch-all（`handleSyncInfoResponse`）在 stage != .syncAuth 時 log `trust_sync_info_ignored` 直接吞掉 → 手機又一樣 15s kcp timeout（33006）連線失敗。這是 2026-08-21 announcer adoption 的第三個變種。修法：`LyraCastTrustSession.handleLogiConn` 最前面先把 frame offer 給 `LyraMeshResponder.shared.handleAnnouncerLogiConn`（gate 精確：adopted connId 或 miLyraShareTransfer sync_info 才吃），packType-5 同樣先 offer `handleAnnouncerPayloadV2`；無 reply context 的 send（responseOfPeerPort）必須走該 socket 的 inbound connection（`sendInboundAsync(toEndpointDescription:)`，source 是 listener port）——用 `send(frame:to:port:)` 會從 ephemeral port 出去，手機 socket 直接不收（實測：frame 從未出現在 phone mesh server）。E2E：`LyraMiShareReceiveTests.testMiShareReceiveWhenPhoneDialsOnCastTrustSocket`（真 `LyraCastTrustSession` + sender role dial cast port，含收檔驗證）。
- `[OBSERVED]` 2026-08-27（同日第四輪）：TunnelCapacity 上機後真機仍 15s timeout（sync_auth_status 15006，request 後整整 15s）——`{f3:1, f4:cap}` 的 response 仍被手機無視。重讀 `SetConnResponseFrame`（0x15f490）disasm：官方 response **永遠**寫 f1（accept code）＋ f2（server UserInfo string）＋ f3=1，f4 cap 只是 profiled 時的附加；f2 UserInfo schema 與手機接受的 mitrust response 相同（f1=1, f2=package, f3=**自己的** 95-char node id, f5=29B system_data, f6=1, f8=medium）。我們前三輪的 response 完全沒帶 f1/f2。修法：`sendLogiConnResponse` 送 `{f1:0, f2:serverUserInfo(package:"com.miui.mishare.connectivity", nodeId: 與 mitrust 同一個 persisted `xiaomiTrustLocalNodeIdHex`), f3:1, f4:cap（profiled 時）}`；response pack 的完整 hex 也進 log（比照 upgrade_response）方便下一輪對 wire。Mock 再改嚴：`LyraMiShareSenderRole` 的 `.response` 除 cap 外還必須含 f2 UserInfo（內層 f2 package + f3 node id 非空）否則判 failed 且不回 responseAck（重現手機沉默）；`LyraMiShareReceiverRole` 回答同步改官方形狀。除錯教訓：手機 miShare client stack 在 logcat 完全無聲（pid 20749 與 app process 都無 lyra-conn-logi 輸出），「response 有沒有被 dispatch」只能從 Mac 端有無收到 responseAck 推論；下一輪若仍失敗，開 tcpdump 驗證 response datagram 是否真到達手機。
- `[OBSERVED]` 2026-08-27（同日第五輪，真機打通）：前三輪修復 + `836316183` 的 type 21 呈現上機後，手機→Mac MiShare 完整成功——16MB 照片 `onChannelTransferProgressUpdate transProgress=16776379/16776379`、頻道乾淨 release。**真根因是 medium 路由**：手機 MiShare `s2/p.e(RemoteDevice)` 按 KEY_DEVICE_TYPE 分流——`j3/i.v()` 收 11–17（Apple 家族）且要過 `e()` 閘門（discovery_medium_type mask 0x20002）才走 wlan；`j3/i.L()` 收 ==21（PC class）無條件走 Q()/wlanConnect(medium 128)；其他（我們舊的 type 4）走 P()/p2pConnect(medium 32)，LAN phys conn 只當 bootstrap，要求對端做 WiFi-P2P SoftAP medium upgrade，Mac 無此協定 → 手機 FSM 卡 `kMediumUpgradeAsClient` 15 秒 → 內部 15004 → 回報 15006 → `mapP2pConflict` 映射 -3014 → errCode 35「裝置正忙」（誤導性訊息）。成功 log 特徵：`RequestConnection {medium_type=80(wifi_lan), remote-device-type:uint32=21}`、`judge_result={upgrade=0, reuse exist phys connect}`、`before=8(kLocalConfirm) after=9(kConnected)`；失敗組則是 `{medium_type=20(p2p), judge_result={upgrade=1}}`。「confirm=1」與 `ConfirmConnection accept=0` 是 client 自主確認流程的正常參數，不是被拒。type 21 在手機列表顯示固定字串「筆記本/小米筆記型電腦」（`pc_xiaomi_device_model_name`，verdor_id=34 決定）；顯示「MacBook Pro」需要 type 14 過 Apple 閘門 + discovery 層 key_discovery_medium_type 位元，屬 optional 支線。Regression mock：`LyraMiShareSenderRole.routingMode`（`.wlanRouting` 新預設＝type 21 直通應全綠；`.p2pRouting` 建模 type 4 wedge——收到合法 conn response 後不進 express，改送 medium-upgrade ClientIntroduction 包在 `.upgrade` frameType 6 裡等 Ack，`mediumUpgradeTimeout`（預設 2s，真機 ~15s）後 fail），E2E `testMiShareReceiveOverWlanRoutingCompletesTransfer`＋`testMiShareReceiveWithLegacyP2pRoutingWedgesOnMediumUpgrade`（斷言 Mac 不誤傷既有 conn、channel port 不發、fail reason 是 medium upgrade）。medium upgrade 協議符號在 `captures/mi-connect-service/index/symbols.txt`：`ConnMediumUpgradeProtocol::ConvertToPb/ConvertFromPb`（0x009970dc / 0x00996b44）、`LogiStateRequestMediumUpgradeAsServer` 系列（若未來要官方相容 SoftAP server 才用）、protobuf `LogiConnClientIntroductionFrame`（device_id/need_ack/mac 三欄位，見 PrintFrame format strings）。
- `[DEFAULT]` 只有在新的可重現證據明確指向這些區域，或 Jason 明確要求重新調查時，才重新評估上述邊界。先補證據，再改 code。
- `[OBSERVED]` 2026-08-28：鏡像 Mac UI 卡「connecting」的雙層根因都與**手機 8/27 韌體更新**有關（Mac 端 8/12 後 mirror media path 無 commit，`git log` 排除自傷）。第一層：手機官方路由把 PES 加密**打開**了（AES-128-CBC、常數 SPKI-prefix key、per-PES IV 從 PES private data；音訊 private kind 同步從 0x03 變 0x07，欄位 layout 相同），而 `mptSinkPESDecryptionEnabled = true` 是在 receiver init **之後**才寫、從未同步到已建構的 demuxer → demuxer 一直拿密文找 Annex-B start code → 零 AU、`decodedFrames=0` 永遠、UI 卡 connecting。修法：property 加 `didSet` 同步 demuxer（`startOfficialMirrorMediaReceiver(pesDecryption:)` 參數只給測試重現暗流用）、audio parser 收 `ff07`。之前為何能動：8/27 前手機送**明文**，flag 不同步的 bug 無害。第二層：解密修好上機後 video 仍黑（VT `-12909`、audio 正常）——離線重播證明**解密位元流完全合法**（ffmpeg 全解 384/385 frames、`AVAssetReader` 卻 0 frames）：Apple **硬體** HEVC decoder 對手機新韌體（x265 風格，SPS compat=0x60000000）每一幀都回 `-12909`，**軟體** decoder 全解。修法：`XiaomiMirrorHEVCDecoder` 連續 4 次 `-12909` 後以 `kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: false` 重建 session（`usesSoftwareDecoder` sticky），既有 IDR-request 流程負責 resync。迴歸防護：fixture `Tests/EdgeLinkMacTests/Resources/phone-hw-reject-hevc.265`（真機 capture 最小集：params AU + params+IDR AU + trail AU，standalone 驗證 HW 全拒/SW 全解；test target resources 走 `project.yml` folder reference + `xcodegen generate`），E2E `testOfficialReceiverFallsBackToSoftwareDecoderWhenHardwareRejectsPhoneStream`。`FakePhoneMPTMediaSource(preEncodedAUs:)` 可餵預編碼 AU 繞過 VT encoder。除錯教訓：zero-byte-density 找 CABAC 垃圾起點不可靠（CABAC 本身高熵）、「ffmpeg probe 過」只代表 header 層；判 VT 對內容相容性要用 AVAssetReader（走 VT）vs ffmpeg（自帶 decoder）對照，快很多。
- `[OBSERVED]` 2026-08-28（同日第二輪，「綠色方塊」真根因）：SW fallback 上機後 video 仍綠——**解密長度錯了：手機只加密每個 PES payload 的前 256 bytes（`mEncrypDataLen`），其餘是明文**。我們的 full-payload CBC 解密把 256 之後的明文當密文解 → 前 256B 正確（slice header + 1-2 條 CTU row）→ CABAC 在第 ~1.5 row desync → decoder 丟棄整個 slice → 畫面 = 頂部一條真內容 + 其餘純綠（Y=0,U=0,V=0 → RGB(0,135,0)）。官方實現在 `小米互聯服務.app` 的 `distribute_camera_sdk`（ATSParser.cpp）：`AES_ctx_set_iv`（per-PES IV）+ `AES_CBC_decrypt_buffer(ctx, buf, min(encLen, aligned(payload)))`，encLen 來自 `wfd_content_SP_protection: 4 1 256 3 1 1 1 1` 的第三個值 256（我們自己协商的！）；encLen==0 或 > payload 時解整個 aligned payload。修法：`MiplayPESCrypto.decryptPESScope/encryptPESScope`（只加解密前 256B，tail 原樣），demuxer 與 E2E fake muxer 改用。驗證：partial-256 重播 live capture = **0 warnings / 1308 幀**（full-decrypt 124 warnings），audio PCM smoothness 139（真音訊；舊法 21000=噪音）。除錯教訓：(1) ffmpeg 對無法開啟/解碼的輸入也是 stderr 安靜 → warning-count oracle 必須同時看 rc + 幀數，否則 0-warning 是假陰性；(2) 孤立解碼單一 TRAIL slice 會被 ffmpeg 跳過（無 reference 不進 CABAC）→ all-cipher 也 0 warning，同樣是假陰性；(3) wrong-IV 只毀 block 0（CBC 特性），「換 IV 就好」的多個假陽性都是 slice 在 header 就被丟棄；(4) 逐方案 warning 數對解密方案不敏感（~100-130 恆定）＝錯誤來源不是 crypto 時的強訊號；(5) `/tmp` capture 檔會被新 session 覆蓋，長時間實驗要先 `md5` 鎖定；(6) 抓手機現行 APK 對比 md5（`/product/app/MiConnectService/MiConnectService.apk` 本輪有變但僅 discovery 無關；Mirror.apk 未變）。VT-HW 對本 stream 的 -12909 是同一根因的表現（HW 對截斷/損壞 slice 直接拒絕），SW fallback 保留作安全網但正常情況不觸發。
- `[OBSERVED]` 2026-08-28（同日第三輪，audio 無聲真根因）：video 修好後 mirror 有畫面無聲，Mac log `audio_private_parse_failed failures=180950/180951 firstBytes=ff 06 ...`。**8/27 韌體把 private audio 改成 ff07 每 session 只送一次 format record、資料全走 ff06**（七月能動是因為舊韌體送明文 ff03 format + ff02 data，parser 見 commit `0ca7050f8`），且 ff07/ff06 在固定 header 與 PCM 之間都插了 session-ID 欄位（u32 長度含自身 4 bytes，值 36 = 4 + 32-char ASCII id 如 `be35dae8...`）——所以 PCM 起點是 ff07=68、ff06=54，不是舊假設的 32/18；舊 parser 連 ff07 都會把 36B id 誤當 PCM 開頭。ff06 layout（4MB capture 3241 筆完全一致）：`ff 06`、u32@2=16、u32@6=declaredBytes(1240)、u32@10=0、u32@14=privatePTS（**微秒**，每筆 +6458 ≈ 310 frames@48k）、u32@18=id 欄長、32-char id、PCM 1240B（48k/2ch/16bit 310 frames，格式不隨 record 帶，用 primed/fallback）。修法（`XiaomiMirrorMPTPrivateAudioPlayer.parsePrivatePayload`）：新增 case 0x06；ff03/ff07 在 offset 32 偵測 session-ID 欄位（僅當 `count == 32 + idLen + declared` 完全吻合才信任，舊無 TLV record 不受影響）；safety gate 的 declaredBytes 檢查延伸到 ff06。Mock：`MirrorPrivateAudioTests` 的 `makeFF07Packet`/`makeFF06Packet` 按 capture 重建（含 TLV），回歸 `testFF07FormatRecordThenFF06StreamAllParses`（一筆 ff07 + 50 筆 ff06 全 parse 全過 gate——修前 ff06 全 nil）。Capture 存 `captures/audio-ff06-20260828/`（audio-private md5 `c6ea983d299c81f71f3114bbe40f8a10`）。除錯教訓：audio PES 解密（256B scope）本來就正確到達 parser——capture 裡是明文結構；「parse failed」先看 firstBytes 是不是預期 kind，不要先懷疑 crypto。
- `[OBSERVED]` 2026-09-02：Mac 撥號只在同 WiFi 能用、hotspot/relay 下「送了但手機沒反應」的雙層根因。第一層（transport）：`LyraRelayCallDialer` 原本寫死 LAN UDP `LyraMeshSocket()`，relay 模式下仍對**過期 WiFi endpoint** 發 phys_sync（live：`relaydial.start to=10.5.49.21:[8 ports]` → 全黑 → 20s timeout），因為「LAN 可達」被 pinned/persisted endpoint 騙過（同一窗口 cast 側也在 `channel_ensure endpoints=9 relay=false` 空轉），而 relay-fed loopback（`127.0.0.1:39749`）其實活著。修法：`startNativeRelayDial` 在 `lyraRelayBridge != nil`＋`reportedPhoneMeshPort()` 已知＋`XiaomiMiShareDiscovery.hasLivePhonePeer()`（120s freshness，只看 mDNS live peer，不吃 history/pin）為 false 時走 relay——dialer 新增 per-dial `meshTransport`/`channelTransport` injection（比照 `LyraMeshAnnouncer`/`LyraCastTrustSession`），mesh 與 channel 各取 `LyraRelayTransportBridge.dialFlowIndexFloor`（1_000_000_001）以上的 fresh random flow（手機 bridge 對每個 index 綁獨立 UDP socket，mesh service 只理新 source endpoint）。Mac bridge 加 `channelFlow(index:)`（indexed Mac-dialed channel pipes，flow 0 仍是 cast/legacy 共用）；Android `AndroidLyraRelayTransportBridge` 加對稱的 `extraChannelFlows`（新 index 只退休前一條 dial channel flow），且 mesh flow 的 fresh-dial replacement 改為**同 partition 才互殺**——否則 relay 下撥號會殺掉 streaming 中 cast dial 的 socket（反過來亦然）。第二層（outcome 被吃）：完全無人回應時 20s timeout 落在 `.idle`，而 `stopLocked()` 對 `.idle` 視為「無在途」不報 outcome → `dialPhone` 的 bridge-dial fallback 永不觸發、UI 永遠「撥號中」、手機端零訊息（TeleService radio 全程無 make_call）。修法：timeout handler 先 `reportOutcome(false)` 再 `stopLocked()`。Mock：`LyraRelayPhoneCallRole.channelPipe`（relay pipe 模式的 dial-channel server，pipe 自己跑 KCP/negotiation/81-04）。E2E `LyraRelayDialOverRelayTests`：`testDialOverCloudRelay`（全鏈路 over relay session pair）、`testDialOverCloudRelayKeepsSharedChannelFlowIntact`（flow 0 隔離）、`testDialTimeoutFromIdleReportsOutcome`（已驗修前紅、修後綠）；Android 單測 `dialChannelFlowKeepsCastChannelFlowIntact`＋`dialMeshFlowDoesNotRetireCastMeshFlow`。除錯教訓：`relaydial.timeout state=idle` 這行本身就是「連 phys sync 都沒人回」的指紋；判斷手機在不在 LAN 不能用 cached endpoint 數量，要看有無 mDNS live peer。
- `[OBSERVED]` 2026-09-03（Mac 撥號通話音訊，六輪修法全部真機驗證）：音訊觸發鏈 = cast trust channel 上的 SimpleEventMessage（23=KeyData 雙向 ECDH、24=call start、31=sink start、25=stop），媒體 = 手機 MirrorCallService source 下行 + 手機 sink 拉 Mac KeyData 廣播的 endpoint 上行；relay 模式下 Android `AndroidCallRelayBridge` 用 loopback 接手機 source/sink、走 `phone.relay.media` base64 envelope。**(a) 雙撥/保留**：`LyraRelayCallDialer.redialForRelayedAudio` 的 +1.2s/+2.2s 重撥在新韌體落在通話 active 之後 → 變真第二通（一保留一掛錯）；整個 redial 已拆（含 `LyraRelayCallSession` 的 callState==3 觸發），`callEnded()` 保留。**(b) 7102 讓位**：`XiaomiMirrorRTSPDiagnosticSource` 預設佔 Mac TCP 7102，`startPhoneRelaySession` 前必須先停它（`phonerelay.mac.diagnostic_source_stopped`），`startXiaomiMirrorRTSPDiagnosticSourceIfNeeded` 有 `phoneRelaySessionRunning` guard。**(c) driver 狀態化**：`LyraMirrorCallRelaySession` 加 NSLock statics `pendingCallActive`/`preferRelayAdvertise`（driver 寫、晚建的 session 在 `start()` 套用；exactly-once gate 曾把整通電話的音訊丟掉）；`sendCallStartIfReadyLocked` 必須用 `advertisedEndpointLocked()`——只看實例變數時 preferRelayAdvertise 下 port=nil，24/31 被靜默丟棄（「全路徑無聲」主因）；`ensureCastTrustChannel` 的 glue 輸入從 `!endpoints.isEmpty` 改成 `hasLivePhonePeer()`（pinned/歷史端點會在手機離網後黑洞 phys sync 30s）。**(d) call_status 不是心跳**：通話穩定後 details_changed 串流會停，mid-call channel 死亡靠 `MirrorCallTriggerDriver.handleSessionFinished(callOngoing:)`（wired 在 session.onFinish）主動 ensure；新 session `start()` 對孤兒手機 source 先送 25 再 24/31（`phoneMirrorCallEngaged` static；缺 25 會讓手機 source 卡死、下一通 SETUP 吃 400）。**(e) getUnUsedPort +3 walk**：手機 MirrorCallService 的 `getUnUsedPort`（`captures/xiaomi-mirror-device/jadx/.../G.java:744`）在 7102 被佔時 +3 走到 7105/7108/7111，Android bridge 只打 7102 → ECONNREFUSED 到掛斷。修法：Mac 在 event-23 學到 `phoneKeyData` 後送 `PhoneRelayMediaBody(kind:"source_rtsp", dataBase64: base64("host:port"))`（bridge active 即送 + `sink_rtsp_listening` 補送），Android `LocalMiLinkRTSPBridge.addSourceEndpointHint`（@Volatile，`connectRTSPWithRetry` 每輪優先打 hinted endpoint）；無 schema 變更，測試在 `AndroidCallRelayBridgeTest.kt`。**(f) 原位 redial 永遠不會被回答（真根因）**：`LyraCastTrustSession.redialCastChannel` 送的是**新 logiConnId + 無 sync_info 的加密 logi request**——手機對該 connId 沒有金鑰狀態（keys 是 phys-conn upgrade 時建立的，新 connId 沒走 sync_info 註冊），在任何 conn 上都只能丟棄。實證 3/3 redial 黑洞滿 6s `redial_timeout`（一次 phys conn 還在收 keepalive、一次 dial 還經 `adoptedSend` 跑到剛收養的 mitrustservice conn——不同 phys conn、不同 keys），而每次成功恢復都是 timeout 後的 fresh session（LAN ~2s）。relay 通話的音訊就死在這 6 秒：手機 `MirrorCallService.startAudioSource` 落在撥號後第 10 秒，user 第 7 秒無聲掛斷。修法：redialCastChannel **fail fast**（`trust_channel_redial_unsupported` → finish → onFinish → rebuild；`redialResponseTimeout`/`armRedialTimeout` 已刪），teardown 仍送 mitrust 52011 disconnect（zombie 防護不變）；`handleSessionFinished` 改**無節流** ensure（fail-fast 在 redial 後 0.2s 觸發，走節流會被剛消耗的 `lastChannelActionAt` 再卡 ~3s）。E2E `LyraMirrorCallRelayTests.testChannelRedialFailsFastSoRuntimeRebuildsFreshSession`（修前紅：3s 等不到 finish；修後綠，且 assert 無 cast dial 漏進 adopted conn、52011 disconnect 照送、fresh session ready + key exchange）。除錯教訓：(1) relay 通話的音訊預算要算整條觸發鏈（撥號 → channel ready → keys → 手機 startAudioSource），接通後 7 秒無聲 user 就會掛——修前 10s、修後預期接通後 ~1-3s；(2) 「手機沒回答」先看 request 本身在新 connId 上有沒有金鑰狀態，不要先懷疑 transport；(3) 手機 logcat 的 `MirrorCallService: startAudioSource/getUnUsedPort port=` 是 source 端真相，`InCall ... isMirrorCallActive` 可輔助。

- `[OBSERVED]` 2026-09-05（Mac 撥號「對方完全聽不到」三層根因，mock 紅燈復現後修復）：**第一層（手機 flap）**：通話中手機 Mirror app 的 5s 閒置 auto-release 反覆拆 cast channel（`trust_logi_disconnect {1:52011}`，每 ~7s 一次）——MirrorCallService 從不註冊 channel keeper（jadx `o2/n.java` `checkAndSetAutoReleaseRunnable`；52011/52014 都是「正常釋放」碼，`p2/h.a()`），只能容忍不能消除。**第二層（Mac 自傷）**：09-03(d) 的 orphan stop 不分場合——重建 session 的 `start()` 對 `phoneMirrorCallEngaged` 一律送 event-25，而 jadx 實錘**重複 23/24/31 是 idempotent no-op（`G.W/X` 的 `f10036j/f10035i` guard），唯獨 25 會把健康的手機 source+sink 全拆（`G.Z`）**，於是每 7s 的 flap 都把通話媒體殺一次。修法：`LyraMirrorCallRelaySession` 加 `pendingCallId`/`engagementCallId` statics（driver 的 `setCallActive` closure 寫 phone.call_status 的 callId；24/31 出線時 stamp），`start()` 只在 identity 不同或未知時送 25（同通話 rebuild 送 23 重 key + 24/31 no-op 即可）。**第三層（Android bridge 一死不起）**：手機被 25 拆掉 sink 後 RST RTSP TCP → `SocketException: Connection reset` 逃出 `LocalMiLinkRTSPSinkServer.readLoop`（只接 SocketTimeoutException）→ `sinkServerJob` 拖垮整個 `coroutineScope`（local_rtsp 下行 + sink server 全滅）→ `bridge_failed`，且 bridge 只在 dial/answer 時啟動、無 mid-call 重啟。歷史 log 顯示同簽名（`Socket closed`/`Connection reset`）自 09-02 起每通長電話都死。修法：handleClient 逐 client 接 IOException（`sink_rtsp_client_ended`）繼續 accept，sinkServerJob 再包一層隔離（`sink_rtsp_server_failed`，`if (isActive)` 防 clean stop 誤報）。**payload 根因**：relay 上行原本是 48kHz 明文 AAC/TS，但手機 sink 沒有 event-23 ECDH key 根本不起動（jadx `startAudioSink, mKey is null`）且永遠解密——官方 dialect 是 LPCM 8k mono、ff02 0x83 private TS、AESPART（前 min(256,len)&~15 bytes AES-128-CBC、per-PES IV 在 PES_private_data）。relay 上行改由 `LyraMirrorCallAudioSource` 的 relay mode 產生（`relayPacketHandler`，無 listener/RTCP——bridge 自己送 SR），Android bridge 的 SELECT_PARAMETERS 改官方 M4（`wfd_audio_codecs_v2: 0 3` + `wfd_type_encryp: 4 1 1 1 1`）；`PhoneRelayAudioController` 的 AAC 上行已刪（下行 player 保留），`PhoneRelayMedia.swift` 的 AAC encoder/TS muxer 保留給 EdgeLinkKit 測試向量。**路線選擇**：LAN 可達（`hasLivePhonePeer()`，use-time 重評估 + discovery snapshot 變化觸發 `handlePhonePeerReachabilityChanged`）時 advertise en0+本地 source port 走 LAN-direct，不再因 cloud bridge 啟動就強制 127.0.0.1:15550（09-05 現場：手機在 LAN 卻被 advertise loopback，媒體全走雲橋）。Mock/測試：Mac `LyraMirrorCallRelayTests` 新增 `testMidCallChannelReleaseRebuildSkipsOrphanStopAndKeepsPhoneMedia`（3 次 52011 flap → 0 次 25、media 不斷）、`testStaleEngagementFromPreviousCallStillGetsOrphanStop`（保留 09-03(d)）、`testRelayUplinkSpeaksOfficialMirrorCallDialect`（AESPART 解密回注入 PCM）、`testPreferRelayAdvertiseWithLANReachablePhoneKeepsLANAdvertise` + driver 層 `testLANReachablePhoneKeepsLANAdvertiseWhenCloudBridgeEngages`；mock role 加 `simpleEventLog`/`ingestRelayedUplinkRTP`/loopback-sink 建模。Android `AndroidCallRelayBridgeTest` 新增 `sinkServerSurvivesClientResetAndAcceptsReconnect`（真 loopback + SO_LINGER(0) RST）、`sinkServerNegotiatesOfficialMirrorCallDialect`、`rtpSummaryTreatsHighBitFirstByteAsRTP`；sink server 改 internal + `log`/`fingerprint`/`boundPort` seams。除錯教訓：(1) `rtpSummary` 的 `data[0].toInt() shr 6` sign-extension 讓所有合法 RTP（0x80 開頭）都 log 成 `format=unknown`——log 層 bug 會誤導根因排查，`AndroidMiLinkMirrorMediaBridge` 的同名複本已併；(2) `AndroidDistAudioUplinkForwarder`（TCP 19307）自 08-08 CallUplinkInjector 拆除後就無 listener，每通電話都 `aacFrames=0 pcmBytesSent=0` 空轉——歸檔 log 的「0 AAC frames」不是失敗證據，死代碼已刪；(3) distaudio openSpeaker/openMicrophone 這通有建立但下行是**用正確 key 加密的全零 PCM**（`downlink_pcm_implausible` prefix=00…00 + 非零 cipherHead = 手機端 DistAudio source 在錄 silence，不是 crypto/格式錯）——distaudio 與 MirrorCallService 是兩個獨立 stack（jadx 無路由切換），通話上行承載仍是 MirrorCallService sink；(4) 手機 RTSP sink 每 ~9s 重連的歷史 pattern 就是 channel flap + orphan-stop churn 的指紋，不是 sink 自己不穩。部署後待真機驗證：實際通話的雙向可聽度。
- `[OBSERVED]` 2026-09-05（同日第二輪，手機端 relay 閘門與 answered pin——部署前段修復後 12:15 真機仍全靜音的總根因）：jadx（`captures/teleservice/jadx/.../relay/phonecall/`）+ root 實驗定位三層閘門全在 TeleService：(1) `RelayServiceFilterUtils.updateFilteredServiceInfo` 的 filtered relay map 只收 deviceType 2/4/11（PAD/PC/IPHONE），我們的 14（MACBOOK）被丟掉；唯一豁免是 `pref_device_answered` pin（TeleService 預設 SharedPreferences、DE storage、永久）——pin 的 deviceId 在 map 裡就不看 type 直接入冊。(2) `createRelayChannel` 只對 filtered map 內裝置建 channel（「No relay service created」→ 手機推給我們的 RING/update_call_state 全部 408 黑洞，Mac 端 `LyraMirrorCallRelaySession.setCallActive` 觸發鏈跟著斷）。(3) 通話音訊路由（`DistAudioDeviceProvider.connectDistAudioDevice`）只在 `setDeviceInRelay` 且通話 ACTIVE（或之後轉 ACTIVE 時 `mConnectRelayAudio` 補切）時執行。pin 的唯一合法寫入點是 `RelayMessageHandler.handleRelayOperate(operateType==0)` 的 `saveDeviceAnswered`——官方語意「relay 來電在該裝置上被接聽」；gate 要求該號碼已有 relayed connection（手機送過 RING 且收到 200，`EXTRA_CALL_RELAYED`），且 **`isDeviceInRelay()` 時 operate(0) 走 already-in-relay 分支：release extras + 回 500、不存 pin——撥號場景絕對不要送 operate(0)**（dial 時 deviceInRelay 已是我們，送了會觸發 `releaseRelayExtra` 清掉 answered extras，適得其反）。**bootstrap 死路（已知限制）**：type 14 沒有 pin 就永遠收不到 RING、operate gate 必失敗——pin 無法在無 root 的新手機上首次取得（本次用 root 直接寫 SharedPreferences 驗證：advertise relayCall + pin → `Answered device is 721572C3` / `Filtered device size 1`；deviceType 來自 `TrustedDeviceInfo.getDeviceType()`（整機層），service data 無法偽造，改 type 11 是 product-level 決策、暫不動）。修法（mock 紅燈先行後上 production）：Mac 接聽來電（`EdgeLinkRuntime.handleIncomingCallUIAnswer`）時經 `LyraRelayCallSession.noteIncomingCallAnswered(address:)` 在 relayCall channel 上送 `relay://operate:<id>/request?{"operateType":0,"address":<號碼>,"requestDeviceId":<我們>}`（pin 續期 + `EXTRA_RELAY_ANSWERED` + `onAnswer`）；`xiaomiRelayCallAdvertise` 改**預設開**（四處讀取點：LyraMeshAnnouncer/LyraSyncReply/LyraMeshResponder/EdgeLinkRuntime 的 relayCallAdvertiseEnabled；f7a9466bc 時代的「advertise 破壞 cast channel」回歸已由 08-21 的 announcer insertion-order 規則取代，全套件含 mirror E2E 在預設開下全綠）。Mock：`LyraRelayCallRole` 建模 ring 200→relayed、operate gate（無 relayed connection 回 500 不 pin；already-in-relay 回 500）、`answeredDeviceId` pin；E2E `LyraPhoneServerIntegrationTests.testIncomingCallAnswerSendsOperateAnswerAndPhonePinsDevice`（ring→接聽→operate(0)→pin→200）、`testOperateAnswerWithoutRingRejectedAndNotPinned`、`testRelayCallAdvertisedByDefault`（防預設被改回）。**通話中穩定性注意**：`onServiceOffline`（我們的 announce flap/app 重啟）在 deviceId == deviceInRelay 時會 `releaseRelayExtra` 清 answered（13:33 實測 offline reason:1 → Filtered size 0）——announce 穩定性直接影響通話音訊存活。**仍未驗證**：pin 入冊後 Mac 撥號的 `EXTRA_RELAY_ANSWERED` 是否保留（12:15 它從 placeCall 的 true 變 false，清除機制未定位——嫌疑：`onChannelRelease`→`releaseRelayExtra`、`maybeRelayCall` size>1 分支的 `forceReleaseRelayCall`，或 Telecom/InCallUI 層（未 decompile）；`InCallUI isCallRelayedAnswered` 的判定點同理）。等下一通真機電話驗證：answered 保留 + `isMirrorCallActive` 翻 true + 雙向音訊。

## Xiaomi HyperConnect 研究資料

- `[DEFAULT]` 研究 `/Applications/小米互聯服務.app` 前，先讀現有 indexed artifact：

  ```text
  captures/xiaomi-hyperconnect/3.0.300-285/index/
  ```

- 先看：

  ```text
  index/SUMMARY.md
  index/metadata/app-info.json
  index/metadata/frameworks.tsv
  index/metadata/macho-binaries.tsv
  index/search/interesting-strings.txt
  ```

- binary-specific details 在 `index/macho/<safe-binary-name>/`，包括 `rabin-*`、`otool-*`、`objc-headers/` 與 `swift-headers/`。
- `[MUST NOT]` 不要預設重新 extract 或 decompile `/Applications/小米互聯服務.app`。只有以下情況才重跑 `tools/extract-xiaomi-hyperconnect.sh`：
  - indexed artifact 不存在；
  - 已安裝 app 版本改變；
  - Jason 明確要求 refresh extraction。
- `[MUST NOT]` 不要把複製的 Xiaomi binaries 或 generated reverse-engineering output commit。`captures/` 是刻意 ignored 的本機研究資料，只能作為 clean-room 參考。
- workflow notes 在 `cleanroom/xiaomi-hyperconnect/README.md`。

## Keychain identity 與舊 call UI

- Incoming-call UI 在主 app 的 `MacIncomingCallPresenter`。
- 舊的 Mac Catalyst helper `EdgeLinkCallUI.app` 已移除，不要 rebuild 或 reinstall 它。
- `[MUTATING]` 如果 `/Applications/EdgeLinkCallUI.app` 仍存在，先確認它確實是已移除的舊 helper，再刪除或移出；不要碰其他 app。
- `[OBSERVED]` 重複出現 Keychain password prompt，通常代表 identity item 是由舊的 ad-hoc 或 DerivedData build 建立。
- `[MUST NOT]` 不要刪除既有 Keychain identity item；這會改變 device ID，並可能破壞 pairing。
- `[DEFAULT]` 先確認目前 signed build 已安裝到 `/Applications`，再啟動穩定的 `/Applications/EdgeLinkMac.app`，讓 `KeychainIdentityStore` 自己 migration 到目前簽署的 app。

## macOS Notification Center sender icon

如果 EdgeLink notification 在 Notification Center 顯示空白 sender icon，先查 LaunchServices，不要先改 `UNNotificationContent`、attachments、`LSUIElement`、request identifiers 或 private notification APIs。Notification Center 是透過 posting bundle ID 的 LaunchServices record 與 IconServices 解析 sender icon。

### 診斷

- 用以下命令檢查所有 `com.edgelink.mac` registrations，特別看 `path`、`icons` 與 `activityTypes`：

  ```sh
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump
  ```

- 正常狀態應該是：
  - 只有一個 `com.edgelink.mac` registration 指向 `/Applications/EdgeLinkMac.app`；
  - 該 app 有 `Contents/Resources/AppIcon.icns`；
  - `CFBundleIconName = AppIcon`；
  - 該 record 附有 `NOTIFICATION#MW4GWYGX56:com.edgelink.mac`。

### 修復

- DerivedData 與 `/private/tmp/edgelink-*` build 可能以同一 bundle ID 留下額外 registration，且 stale copy 可能沒有 icon resources。
- `[MUTATING]` 只 unregister 從 `lsregister -dump` 確認出的 stale EdgeLink path：

  ```sh
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -u <stale-app-path>
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/EdgeLinkMac.app
  ```

- `[MUTATING]` 完成 registration 修復後，重啟目前使用者的 `usernoted` 與 `NotificationCenter`，讓它們重建 sender-icon state。這不需要修改 notification delivery flow。
- 如果 registry 已乾淨但舊空白 icon 仍存在，才增加 `CFBundleVersion`，重新 build、用 `ditto` 安裝，再 register `/Applications` copy。
- `[MUST NOT]` 不要直接從 DerivedData 或 `/private/tmp` 啟動 app 來驗證通知 icon。

## 變更前後的基本檢查

- `[DEFAULT]` 修改前先看 `git status`，保留 Jason 現有的未提交變更。
- `[MUST]` 任何會中斷 session、覆蓋 app、改 LaunchServices、重啟系統程序或刪除 app 的動作，都要先確認目標，再做 post-check。
- `[MUST]` 回報完成時，說清楚：改了什麼、跑了哪些測試、哪些驗證沒有跑，以及是否真的部署到 `/Applications`。
