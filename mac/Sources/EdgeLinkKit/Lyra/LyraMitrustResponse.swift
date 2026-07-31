import Foundation

// Builders for the mitrustservice LOGI_CONN_RESPONSE UserInfo and the
// responseOfPeerPort body, matching the decrypted official Mac↔phone capture
// (captures/lyra-live/20260731-101022/parse4-final.txt).
public enum LyraMitrustResponse {
    // Official UserInfo f5 system_data blob (29B).
    public static let systemData = Data([
        0x01, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x15, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0xff, 0x00,
        0x00, 0x06, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01
    ])

    // Official f8 medium/capability values.
    public static let mediumRecentApps: UInt64 = 8
    public static let mediumCast: UInt64 = 136

    // Server UserInfo: f1=1, f2=package, f3=own 95-char colon-hex 32B node id,
    // f5=system_data, f6=1, f8=medium.
    public static func serverUserInfo(
        package: String,
        nodeIdColonHex: String,
        medium: UInt64 = mediumCast
    ) -> Data {
        var info = Data()
        LyraProtoWriter.appendVarintField(1, value: 1, to: &info)
        LyraProtoWriter.appendLengthDelimitedField(2, value: Data(package.utf8), to: &info)
        LyraProtoWriter.appendLengthDelimitedField(3, value: Data(nodeIdColonHex.utf8), to: &info)
        LyraProtoWriter.appendLengthDelimitedField(5, value: systemData, to: &info)
        LyraProtoWriter.appendVarintField(6, value: 1, to: &info)
        LyraProtoWriter.appendVarintField(8, value: medium, to: &info)
        return info
    }

    // LogiConnResponseFrame: f1=status 0, f2=UserInfo, f3=1 (official schema).
    public static func logiConnResponse(userInfo: Data) -> Data {
        var frame = Data()
        LyraProtoWriter.appendVarintField(1, value: 0, to: &frame)
        LyraProtoWriter.appendLengthDelimitedField(2, value: userInfo, to: &frame)
        LyraProtoWriter.appendVarintField(3, value: 1, to: &frame)
        return frame
    }

    // responseOfPeerPort body: f1=client channel id (echo of the request's
    // f1 — the phone's ChannelClientHandler compares this against its
    // mChannelId and rejects with 52013 "channel invalid id" on mismatch),
    // f2=server channel id (omitted when 0, like official), f3=port, f5=1,
    // f7=32B key.
    public static func peerPortResponseBody(
        clientChannelId: UInt64,
        serverChannelId: UInt64,
        port: UInt16,
        serverKey: Data
    ) -> Data {
        var body = Data()
        LyraProtoWriter.appendVarintField(1, value: clientChannelId, to: &body)
        if serverChannelId != 0 {
            LyraProtoWriter.appendVarintField(2, value: serverChannelId, to: &body)
        }
        LyraProtoWriter.appendVarintField(3, value: UInt64(port), to: &body)
        LyraProtoWriter.appendVarintField(5, value: 1, to: &body)
        LyraProtoWriter.appendLengthDelimitedField(7, value: serverKey, to: &body)
        return body
    }
}
