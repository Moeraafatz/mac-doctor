//
//  MacDoctor/Services/PublicIPService.swift
//  Mac Doctor
//
//  On-demand public IP lookup. Never called automatically — only triggered
//  when the user taps "Show" in the Network tab. Uses an ephemeral URLSession
//  with no cookies or persistent cache.
//

import Foundation

struct PublicIPService: PublicIPLookingUp {
    private static let endpoints: [URL] = [
        URL(string: "https://api.ipify.org")!,
        URL(string: "https://icanhazip.com")!
    ]

    func fetchPublicIP() async -> PublicIPState {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil

        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        for url in Self.endpoints {
            guard !Task.isCancelled else { return .hidden }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("text/plain", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode)
                else {
                    continue
                }

                let text = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if HostValidator.isValidIP(text) {
                    AppLog.network.info("PublicIPService: fetched public IP on user request")
                    return .visible(text)
                }
            } catch {
                if (error as? CancellationError) != nil || (error as NSError).code == NSURLErrorCancelled {
                    return .hidden
                }
                AppLog.network.error(
                    "PublicIPService: lookup failed for \(url.host ?? "endpoint", privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return .failed("Unavailable")
    }
}
