import CAsahiro
import Foundation

struct CoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct TaskEvent: Decodable {
    let type: String
    let text: String?
    let fraction: Double?
    let detail: String?
    let ok: Bool?
    let error: String?
    let cancelled: Bool?
}

// thin bridge over the rust static library, everything crosses as json
enum Core {
    static let snakeDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func raw(_ request: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: request)
        let text = String(decoding: body, as: UTF8.self)
        guard let ptr = text.withCString({ asahiro_call($0) }) else {
            throw CoreError(message: "core returned nothing")
        }
        defer { asahiro_free(ptr) }
        let response = Data(bytes: ptr, count: strlen(ptr))
        guard let obj = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw CoreError(message: "malformed core response")
        }
        if obj["ok"] as? Bool == true {
            return try JSONSerialization.data(withJSONObject: obj["data"] ?? NSNull(), options: .fragmentsAllowed)
        }
        throw CoreError(message: obj["error"] as? String ?? "unknown error")
    }

    static func call<T: Decodable>(_ request: [String: Any], as type: T.Type, decoder: JSONDecoder = snakeDecoder) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try decoder.decode(T.self, from: raw(request))
        }.value
    }

    static func run(_ request: [String: Any]) async throws {
        _ = try await Task.detached(priority: .userInitiated) { try raw(request) }.value
    }

    private final class Handler {
        let onEvent: (TaskEvent) -> Void
        init(_ onEvent: @escaping (TaskEvent) -> Void) { self.onEvent = onEvent }
    }

    // events arrive on a background thread, the handler is released after "finished"
    static func spawn(_ request: [String: Any], onEvent: @escaping (TaskEvent) -> Void) -> UInt64 {
        let body = (try? JSONSerialization.data(withJSONObject: request)) ?? Data("{}".utf8)
        let text = String(decoding: body, as: UTF8.self)
        let ctx = Unmanaged.passRetained(Handler(onEvent)).toOpaque()
        return text.withCString { cstr in
            asahiro_spawn(cstr, { ctx, json in
                guard let ctx, let json else { return }
                let handler = Unmanaged<Handler>.fromOpaque(ctx)
                let data = Data(bytes: json, count: strlen(json))
                guard let event = try? JSONDecoder().decode(TaskEvent.self, from: data) else { return }
                handler.takeUnretainedValue().onEvent(event)
                if event.type == "finished" {
                    handler.release()
                }
            }, ctx)
        }
    }

    static func cancel(_ id: UInt64) {
        asahiro_cancel(id)
    }
}
