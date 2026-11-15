import Foundation
import Hummingbird
import Logging
import NIOCore

/// Serves the HLS output directory over HTTP so AVPlayer and AirPlay receivers can pull it.
public final class MediaHTTPServer: @unchecked Sendable {
    public let root: URL
    private var task: Task<Void, Error>?
    public private(set) var port: Int?
    let onRequest: (@Sendable (String) -> Void)?

    /// `onRequest` receives the path of every request, e.g. to show which segments a receiver fetched.
    public init(root: URL, onRequest: (@Sendable (String) -> Void)? = nil) {
        self.root = root
        self.onRequest = onRequest
    }

    /// Starts listening and returns the bound port (ephemeral when `port` is 0).
    /// Use "127.0.0.1" for local playback and "0.0.0.0" when a receiver on the LAN must reach it.
    @discardableResult
    public func start(host: String = "0.0.0.0", port requestedPort: Int = 0) async throws -> Int {
        var logger = Logger(label: "airstar.http")
        // Cancelling the server task logs a benign "Already closed" error during shutdown.
        logger.logLevel = .critical

        let router = Router()
        router.add(middleware: HLSHeadersMiddleware(onRequest: onRequest))
        router.add(middleware: FileMiddleware(root.path, searchForIndexHtml: false, logger: logger))

        let (portStream, portContinuation) = AsyncStream<Int>.makeStream()
        let app = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: requestedPort), serverName: "airstar-cli"),
            onServerRunning: { channel in
                portContinuation.yield(channel.localAddress?.port ?? requestedPort)
                portContinuation.finish()
            },
            logger: logger
        )
        task = Task {
            defer { portContinuation.finish() }
            try await app.runService(gracefulShutdownSignals: [])
        }
        var iterator = portStream.makeAsyncIterator()
        guard let bound = await iterator.next() else {
            if let task, case .failure(let error) = await task.result {
                throw AirstarError.connectionFailed("HTTP server failed to start: \(error)")
            }
            throw AirstarError.connectionFailed("HTTP server failed to start")
        }
        port = bound
        return bound
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// URL for `path` (relative to `root`) as seen from `host`.
    public func url(for path: String, host: String) -> URL? {
        guard let port else { return nil }
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(hostPart):\(port)/\(path)")
    }
}

/// Sets HLS content types, disables caching of the growing playlist, and adds CORS headers:
/// the Google Cast Default Media Receiver is a web app that fetches the stream cross-origin.
struct HLSHeadersMiddleware<Context: RequestContext>: RouterMiddleware {
    let onRequest: (@Sendable (String) -> Void)?

    static func addCORS(to headers: inout HTTPFields) {
        headers[.accessControlAllowOrigin] = "*"
        headers[.accessControlAllowMethods] = "GET, HEAD, OPTIONS"
        headers[.accessControlAllowHeaders] = "Range, Content-Type, Origin, Accept"
        headers[.accessControlExposeHeaders] = "Content-Length, Content-Range, Accept-Ranges"
    }

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        onRequest?(path)
        if request.method == .options {
            var preflight = Response(status: .noContent)
            Self.addCORS(to: &preflight.headers)
            return preflight
        }
        var response = try await next(request, context)
        Self.addCORS(to: &response.headers)
        if path.hasSuffix(".m3u8") {
            response.headers[.contentType] = "application/vnd.apple.mpegurl"
            response.headers[.cacheControl] = "no-cache, no-store"
        } else if path.hasSuffix(".ts") {
            response.headers[.contentType] = "video/mp2t"
        } else if path.hasSuffix(".m4s") {
            response.headers[.contentType] = "video/iso.segment"
        } else if path.hasSuffix(".mp4") {
            response.headers[.contentType] = "video/mp4"
        }
        return response
    }
}
