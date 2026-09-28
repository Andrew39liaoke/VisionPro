import Foundation

public struct WHEPAnswer: Sendable {
    public let sdp: String
    public let resource: URL
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // Do not forward credentials to an untrusted redirect.
    }
}

public final class WHEPHTTPClient: Sendable {
    private let session: URLSession
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    public func iceServers(endpoint: StreamEndpoint, credential: StreamCredential) async throws -> [ICEServer] {
        let (_, response) = try await send(url: endpoint.url, method: "OPTIONS", credential: credential)
        try validate(response, allowed: [200, 204])
        return try ICELinkParser.parse(response.value(forHTTPHeaderField: "Link"))
    }

    public func offer(_ sdp: String, endpoint: StreamEndpoint, credential: StreamCredential) async throws -> WHEPAnswer {
        let (data, response) = try await send(url: endpoint.url, method: "POST", credential: credential,
                                            body: sdp, contentType: "application/sdp")
        try validate(response, allowed: [201])
        let resource = try endpoint.resolveSession(response.value(forHTTPHeaderField: "Location") ?? "")
        guard response.mimeType?.lowercased() == "application/sdp",
              let answer = String(data: data, encoding: .utf8), answer.hasPrefix("v=0"), answer.contains("m=video ") else {
            await delete(resource, credential: credential)
            throw StreamError.invalidResponse("应收到 application/sdp 视频 answer")
        }
        return WHEPAnswer(sdp: answer, resource: resource)
    }

    public func candidates(_ fragment: String, resource: URL, credential: StreamCredential) async throws {
        let (_, response) = try await send(url: resource, method: "PATCH", credential: credential,
                                          body: fragment, contentType: "application/trickle-ice-sdpfrag", ifMatch: "*")
        try validate(response, allowed: [204])
    }

    public func delete(_ resource: URL, credential: StreamCredential) async {
        _ = try? await send(url: resource, method: "DELETE", credential: credential)
    }

    private func send(url: URL, method: String, credential: StreamCredential,
                      body: String? = nil, contentType: String? = nil, ifMatch: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        request.setValue(credential.authorization, forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(ifMatch, forHTTPHeaderField: "If-Match")
        if method == "POST" { request.setValue("application/sdp", forHTTPHeaderField: "Accept") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw StreamError.invalidResponse("不是 HTTP 响应") }
        return (data, response)
    }

    private func validate(_ response: HTTPURLResponse, allowed: Set<Int>) throws {
        if [401, 403].contains(response.statusCode) { throw StreamError.authentication }
        guard allowed.contains(response.statusCode) else { throw StreamError.http(response.statusCode) }
    }
}
