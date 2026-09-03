import Foundation

/// 通話中 IVR 即時送鍵的純函式邏輯；獨立成檔（同時編進 EdgeLinkMac 與
/// EdgeLinkMacTests）以便單元測試，不依賴 EdgeLinkRuntime。
enum LiveDTMF {
    /// `current` 以 `previous` 為前綴時，回傳新增部分（經 `sanitizeDTMFSequence`
    /// 正規化）；刪除、整段取代、新增為空或含非法字元時回傳 nil。
    static func liveDTMFDelta(previous: String, current: String) -> String? {
        guard current.hasPrefix(previous) else {
            return nil
        }
        let appended = String(current.dropFirst(previous.count))
        guard !appended.isEmpty else {
            return nil
        }
        return sanitizeDTMFSequence(appended)
    }

    /// DTMF sequence 正規化：全形 ＊＃， 轉半形、`p`/`P`/`，` 轉 `,`（停頓）、
    /// 空白與 `-` 略過；其他字元、空結果、超過 32 字元、或全為 `,` 皆回傳 nil。
    static func sanitizeDTMFSequence(_ raw: String) -> String? {
        var normalized = ""
        for character in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            switch character {
            case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "#", ",":
                normalized.append(character)
            case "＊":
                normalized.append("*")
            case "＃":
                normalized.append("#")
            case "，", "p", "P":
                normalized.append(",")
            case " ", "\t", "\n", "\r", "-":
                continue
            default:
                return nil
            }
        }
        guard !normalized.isEmpty,
              normalized.count <= 32,
              normalized.contains(where: { $0.isNumber || $0 == "*" || $0 == "#" }),
              normalized.allSatisfy({ $0.isNumber || $0 == "*" || $0 == "#" || $0 == "," }) else {
            return nil
        }
        return normalized
    }
}
