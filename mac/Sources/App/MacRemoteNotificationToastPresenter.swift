import AppKit
import EdgeLinkKit
import SwiftUI

final class MacRemoteNotificationToastPresenter: @unchecked Sendable {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    private var displayedNotificationId: String?

    func show(_ body: NotificationPostBody, iconPNGData: Data?) {
        DispatchQueue.main.async { [weak self] in
            self?.showOnMain(body, iconPNGData: iconPNGData)
        }
    }

    func remove(id: String) {
        DispatchQueue.main.async { [weak self] in
            guard self?.displayedNotificationId == id else { return }
            self?.dismissOnMain()
        }
    }

    private func showOnMain(_ body: NotificationPostBody, iconPNGData: Data?) {
        dismissWorkItem?.cancel()

        let icon = iconPNGData.flatMap(NSImage.init(data:))
        let view = MacRemoteNotificationToastView(
            app: body.app,
            title: body.title,
            text: body.text,
            icon: icon
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.height)

        let panel = panel ?? makePanel()
        panel.contentView = hostingView
        displayedNotificationId = body.id
        position(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismissOnMain()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: workItem)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - Self.width - 14,
            y: visibleFrame.maxY - Self.height - 12
        ))
    }

    private func dismissOnMain() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        displayedNotificationId = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private static let width: CGFloat = 372
    private static let height: CGFloat = 104
}

private struct MacRemoteNotificationToastView: View {
    let app: String
    let title: String
    let text: String
    let icon: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.dashed")
                        .resizable()
                        .scaledToFit()
                        .padding(9)
                        .foregroundStyle(.secondary)
                }
            }
            .scaledToFit()
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(app)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(title.isEmpty ? app : title)
                    .font(.headline)
                    .lineLimit(1)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .frame(width: 372, height: 104, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.14))
        }
    }
}
