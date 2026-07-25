import AppKit
import EdgeLinkKit
import SwiftUI

struct ClipboardHistoryWindow: View {
    @ObservedObject var runtime: EdgeLinkRuntime

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(runtime.clipboardHistoryItems, id: \.id) { item in
                        ClipboardHistoryRow(
                            item: item,
                            isLocal: item.sourceDeviceId == runtime.localDeviceId,
                            isFetching: runtime.fetchingClipboardBlobId == item.id
                        ) {
                            runtime.handleClipboardHistoryItemClick(item)
                        }
                    }

                    if runtime.clipboardHistoryItems.isEmpty {
                        Text("尚無剪貼簿歷史")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                if !runtime.clipboardHistoryStatus.isEmpty {
                    Text(runtime.clipboardHistoryStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    runtime.refreshClipboardHistory()
                } label: {
                    Label("重新整理", systemImage: "arrow.clockwise")
                }
            }
            .padding(10)
        }
        .frame(minWidth: 360, minHeight: 420)
        .onAppear {
            runtime.refreshClipboardHistory()
        }
    }
}

private struct ClipboardHistoryRow: View {
    let item: ClipboardHistoryItemBody
    let isLocal: Bool
    let isFetching: Bool
    let onClick: () -> Void

    private var kind: ClipboardKind {
        ClipboardKind(rawValue: item.kind) ?? .text
    }

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 10) {
                thumbnailView
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(primaryLine)
                        .font(.body)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 6) {
                        Text(Date(timeIntervalSince1970: TimeInterval(item.ts)), style: .time)
                        Text(isLocal ? String(localized: "本機") : String(localized: "手機"))
                            .foregroundStyle(.tertiary)
                        if kind == .image && isFetching {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let base64 = item.thumbnailBase64,
           let data = Data(base64Encoded: base64),
           let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(2)
        } else {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var iconName: String {
        switch kind {
        case .image: return "photo"
        case .html: return "globe"
        case .file: return "doc"
        case .text: return "doc.plaintext"
        }
    }

    private var primaryLine: String {
        if let text = item.text, !text.isEmpty {
            return text
        }
        switch kind {
        case .image: return String(localized: "圖片")
        case .file: return String(localized: "檔案")
        default: return String(localized: "（無文字）")
        }
    }
}
