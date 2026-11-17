import Foundation

public enum ProxyHTTPClient {
    public static func fetch(_ url: URL, limit: Int = 5 * 1024 * 1024, timeout: TimeInterval = 60) async throws -> Data {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw ProxyFailure("请输入有效的 HTTP 或 HTTPS 地址")
        }
        let delegate = BoundedDownload(limit: limit)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "") {
            config.connectionProxyDictionary = [:]
        }
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("clash.meta/Aurora", forHTTPHeaderField: "User-Agent")
        return try await delegate.download(session: session, request: request)
    }
}

private final class BoundedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private var data = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var failure: Error?
    init(limit: Int) { self.limit = limit }

    func download(session: URLSession, request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.dataTask(with: request).resume()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            failure = ProxyFailure("下载失败：服务器未返回成功状态")
            completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= limit else {
            failure = ProxyFailure("下载文件超过大小限制")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= limit else {
            failure = ProxyFailure("下载文件超过大小限制"); dataTask.cancel(); return
        }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure { continuation?.resume(throwing: failure) }
        else if error != nil { continuation?.resume(throwing: ProxyFailure("下载失败，请检查网络或订阅地址")) }
        else { continuation?.resume(returning: data) }
        continuation = nil
    }
}
