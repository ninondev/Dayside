// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Typed transport only. Domain decisions live in the linked Rust library.
nonisolated enum RustCore {
    private struct Request<Input: Encodable>: Encodable {
        let operation: String
        let payload: Input
    }
    private struct Response<Output: Decodable>: Decodable {
        let value: Output
        enum CodingKeys: String, CodingKey { case value, error }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let message = try container.decodeIfPresent(String.self, forKey: .error) {
                throw DecodingError.dataCorruptedError(forKey: .error, in: container, debugDescription: message)
            }
            value = try container.decode(Output.self, forKey: .value)
        }
    }

    struct EmptyResponse: Error { let operation: String }

    static func invoke<Input: Encodable, Output: Decodable>(
        _ operation: String, _ input: Input, as: Output.Type = Output.self
    ) -> Output {
        do {
            return try attempt(operation, input, as: Output.self)
        } catch {
            preconditionFailure("Rust core transport failed for \(operation): \(error)")
        }
    }

    /// Same transport, but Rust errors and decoding failures are thrown instead of trapping. Paths fed by
    /// arbitrary user text (「听懂时间」) use this and treat a failure as "not understood" .
    static func attempt<Input: Encodable, Output: Decodable>(
        _ operation: String, _ input: Input, as: Output.Type = Output.self
    ) throws -> Output {
        #if DEBUG && os(macOS)
        let performanceStart = PerformanceRustCalls.begin()
        defer { PerformanceRustCalls.end(operation, started: performanceStart) }
        #endif
        let encoded = try JSONEncoder().encode(Request(operation: operation, payload: input))
        let output = encoded.withUnsafeBytes { bytes in
            mt_core_call(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        defer { mt_core_free(output) }
        guard let pointer = output.data, output.len > 0 else { throw EmptyResponse(operation: operation) }
        let data = Data(bytes: pointer, count: output.len)
        return try JSONDecoder().decode(Response<Output>.self, from: data).value
    }
}

/// Lossless JSON payload used by the preference adapter and reducers.
nonisolated enum CoreJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([CoreJSON]), object([String: CoreJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Int64.self) { self = .integer(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([CoreJSON].self) { self = .array(value) }
        else if let value = try? c.decode([String: CoreJSON].self) { self = .object(value) }
        // Foundation accepts JSON numbers beyond Double. Treat that field as absent,
        // retaining neighboring settings and ignoring unrecognized oversized fields.
        else { self = .null }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    init<T: Encodable>(_ value: T) {
        do { self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value)) }
        catch { preconditionFailure("Cannot encode core DTO: \(error)") }
    }
    func decode<T: Decodable>(_ type: T.Type = T.self) -> T {
        do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
        catch { preconditionFailure("Cannot decode core DTO: \(error)") }
    }
    subscript(_ key: String) -> CoreJSON {
        guard case .object(let fields) = self else { return .null }
        return fields[key] ?? .null
    }
}
