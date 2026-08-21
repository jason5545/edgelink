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
- `[OBSERVED]` 2026-08-21：手機→Mac MiShare（相簿分享）「連線失敗」的根因與 2026-08-12 mitrustservice 同類——手機的 score-based reuse 把 `com.xiaomi.hyperConnect:miLyraShareTransfer` 的 LOGI_CONN_SYNC_INFO 打到 Mac 的 announcer phys conn（而非手機自己 dial 43181 的 mesh conn），`LyraMeshAnnouncer` 的 foreign-conn chain 沒有這條 route → `announcer_stray_conn` 丟棄 → 手機 15s kcp timeout（33006）。修法：`LyraMeshResponder.shared`（attach 時註冊）+ `handleAnnouncerLogiConn`/`handleAnnouncerPayloadV2` 讓 responder 從 announcer socket adopt 這條 receive conn（sync-auth/upgrade/encrypted response 走 announcer 的 `reply`；responseOfPeerPort 與 sync announce 等無 reply context 的 send 改用 adoption 時 capture 的 announcer `send` override——responder 自己的 socket 對該 endpoint 沒有 inbound connection）。announcer 端 insertion 必須排在 `LyraRelayCallSession.activeRelaySession` 的 unchecked fallback 之前，packType-5 分支排在 announce-payload 解密之前（未 adopt 或解密失敗一律回 false，announce sync payload 不受影響）。Mock：`LyraMiShareSenderRole`（LyraServerKit，完整 receive flow：sync_info → P256 upgrade → encrypted request → responseAck → requestOfPeerPort）；E2E `LyraMiShareReceiveTests`（baseline 直連 responder socket + announcer-conn dial 重現）。
- `[DEFAULT]` 只有在新的可重現證據明確指向這些區域，或 Jason 明確要求重新調查時，才重新評估上述邊界。先補證據，再改 code。

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
