import Foundation

enum UploadError: LocalizedError {
    case badBaseURL
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badBaseURL: return "서버 주소가 올바르지 않아요. 설정(⚙️)에서 확인해 주세요."
        case .httpStatus(let code): return "서버 응답 오류 (HTTP \(code)). 서버가 켜져 있는지 확인해 주세요."
        }
    }
}

/// 그로잉컷 공유 서버 클라이언트
struct UploadClient {
    let base: URL

    init(baseURL: String) throws {
        guard let url = URL(string: baseURL), url.scheme != nil else {
            throw UploadError.badBaseURL
        }
        base = url
    }

    private struct PutResponse: Decodable {
        let ok: Bool
        let expiresAt: Double?
    }

    /// 업로드 성공 시 서버 기준 만료 시각을 돌려준다
    @discardableResult
    func putPhoto(_ data: Data, id: String) async throws -> Date? {
        try await put(path: "/api/s/\(id)/photo", contentType: "image/jpeg") { request in
            try await URLSession.shared.upload(for: request, from: data)
        }
    }

    @discardableResult
    func putVideo(_ fileURL: URL, id: String) async throws -> Date? {
        try await put(path: "/api/s/\(id)/video", contentType: "video/mp4") { request in
            try await URLSession.shared.upload(for: request, fromFile: fileURL)
        }
    }

    func health() async -> Bool {
        guard let url = URL(string: "/api/health", relativeTo: base) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }

    private func put(
        path: String,
        contentType: String,
        send: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> Date? {
        guard let url = URL(string: path, relativeTo: base) else { throw UploadError.badBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw UploadError.httpStatus(-1) }
        guard (200..<300).contains(http.statusCode) else { throw UploadError.httpStatus(http.statusCode) }

        if let decoded = try? JSONDecoder().decode(PutResponse.self, from: data),
           let ms = decoded.expiresAt {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return nil
    }
}
