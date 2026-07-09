# macOS 通知同步來源調查

這份文件記錄 EdgeLink 在 Mac -> Android 通知同步上實際能用的介面。調查時只看
framework、service、schema 與權限邊界，不讀本機通知內容。

## 採用路線

EdgeLink 的 local build 採用 `usernoted` SQLite DB backend 做 Mac -> Android 通知鏡射，預設開啟。
這不是 App Store / sandbox 路線，而是 Jason 本機使用情境下的 non-sandbox helper 能力。

這個 backend 需要 macOS Full Disk Access 授權給 `/Applications/EdgeLinkMac.app`。沒有授權時，
`usernoted` DB 會被 TCC 擋下，log 會出現 `notification.mac.db.* error=open(23)`；授權並重啟
app 後，正常會看到 `notification.mac.db.initial_baseline`。

實作邊界：

- 不接 entitlement-gated private XPC
- schema 或解析失敗只寫 log，不影響 relay
- 啟動時以目前最新通知作 baseline，不回放歷史通知
- 保守輪詢，用 notification UUID 去重
- 只鏡射 `presented = 1` 的紀錄；`delivered_date` 代表 usernoted 收到，不代表 Mac 真的顯示給使用者
- 解析到的通知資料不進密碼學信任模型

## 公開 API

`UNUserNotificationCenter.current()` 的範圍是目前 app。它可以：

- 要求通知授權
- 排程本 app 的 local notification request
- 列出或移除本 app pending / delivered notifications
- 收到本 app 通知顯示與使用者回應的 delegate callback

它沒有 Android `NotificationListenerService` 那種跨 app notification listener。

`NotificationCenter.framework` 與 `UserNotificationsUI.framework` 在 macOS SDK 裡也沒有可用來
觀察任意第三方通知的公開 header。

## 私有 XPC / Mach Services

本機有 `usernoted`、`usernotificationsd`、`NotificationCenter.app`，launchd namespace 內可見
這些 service：

- `com.apple.usernoted.client`
- `com.apple.usernoted.notificationcenter`
- `com.apple.usernotifications.listener`
- `com.apple.notificationcenterui.main`

`usernoted` 與 `NotificationCenter.app` 的字串裡能看到私有 protocol / entitlement 線索：

- `didDeliverNotification`
- `didRemoveDeliveredNotifications`
- `com.apple.private.usernotifications.forwarding`
- `com.apple.private.notificationcenter.server`
- `com.apple.private.notificationcenter`

binary 內也有 entitlement denial 訊息。這是 Apple 內部介面，不是 EdgeLink 主線可以穩定依賴的
API。

## Notification Center 資料庫

這台機器上的 Notification Center 狀態在：

```text
~/Library/Group Containers/group.com.apple.usernoted/db2/db
```

SQLite schema 包含：

```text
app(identifier, badge)
record(uuid, data, delivered_date, presented, ...)
requests(list)
delivered(list)
displayed(list)
categories(categories)
```

通知 payload 存在 opaque blob。非 sandbox 的本機 app 在這台機器上可以讀檔，但這不是公開
API。格式可能隨 macOS 更新改變，也需要處理 WAL / in-flight state，debug 時還會碰到很高的
隱私成本。

這條路是目前 Mac -> Android 鏡射採用的本機 backend。它能用，但仍然不是公開平台 API；
macOS 更新若改 schema，需要把 parser 跟著修。

## Accessibility Scraping

`NotificationCenter.app` 裡有 `AXNotificationCenterBanner`、`AXNotificationCenterAlert` 等
accessibility identifier。System Events 也能看見 Notification Center windows，所以理論上可用
Accessibility 讀取畫面上可見的 banner，或使用者打開通知中心後的列表。

這不適合主線：

- 只能看見目前 UI 上存在的通知
- UI 關閉、動畫中、堆疊變化時會漏
- 依賴 localized / private view hierarchy
- 會增加 Accessibility / Screen Recording 權限摩擦
- 可能搶焦點，跟 EdgeLink 遠端操控的用途互相干擾

Accessibility 可以當 debug probe，不當 notification sync backend。
