import Foundation

@MainActor
final class EdgeLinkURLRouter {
    static let shared = EdgeLinkURLRouter()

    private var handler: ((URL) -> Void)?
    private var pendingURLs: [URL] = []

    private init() {}

    func setHandler(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        let pending = pendingURLs
        pendingURLs.removeAll()
        pending.forEach(handler)
    }

    func open(_ urls: [URL]) {
        urls.forEach(open)
    }

    func open(_ url: URL) {
        guard let handler else {
            pendingURLs.append(url)
            return
        }
        handler(url)
    }
}
