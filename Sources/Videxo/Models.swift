import Foundation

// The answers of the client routes. Only the fields the API documents for a client token: it never
// sees a job's command, inputs, webhook, metadata or usage. A new field in an answer is ignored, and
// a new job state still reads.

/// What `POST /v1/client/uploads` answers: where to send the bytes, once.
public struct Upload: Decodable, Equatable, Sendable {
    public let id: String
    /// `videxo://uploads/<id>`: send this to your backend, which uses it as a job input.
    public let inputURL: String
    /// The one-time URL. It holds no API key, takes one PUT and works for one hour.
    public let uploadURL: URL
    public let uploadURLExpiresAt: Date
    public let expiresAt: Date
    public let maxSizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case id
        case inputURL = "input_url"
        case uploadURL = "upload_url"
        case uploadURLExpiresAt = "upload_url_expires_at"
        case expiresAt = "expires_at"
        case maxSizeBytes = "max_size_bytes"
    }
}

/// What the upload URL answers once every byte arrived.
public struct CompletedUpload: Decodable, Equatable, Sendable {
    public let id: String
    /// `videxo://uploads/<id>`: send this to your backend, which uses it as a job input.
    public let inputURL: String
    public let sizeBytes: Int
    public let sha256: String
    public let contentType: String
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case inputURL = "input_url"
        case sizeBytes = "size_bytes"
        case sha256
        case contentType = "content_type"
        case expiresAt = "expires_at"
    }
}

/// How far an upload has come, in bytes.
public struct UploadProgress: Equatable, Sendable {
    public let loaded: Int64
    public let total: Int64

    public init(loaded: Int64, total: Int64) {
        self.loaded = loaded
        self.total = total
    }

    /// From 0 to 1.
    public var fraction: Double { total > 0 ? min(1, Double(loaded) / Double(total)) : 0 }
}

/// A job's state. `queued` and `running` are active; the others are final. A state this version does
/// not know reads as itself and counts as active.
public struct JobState: RawRepresentable, Hashable, Decodable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public static let queued = JobState(rawValue: "queued")
    public static let running = JobState(rawValue: "running")
    public static let succeeded = JobState(rawValue: "succeeded")
    public static let failed = JobState(rawValue: "failed")
    public static let cancelled = JobState(rawValue: "cancelled")

    /// Whether the job has ended.
    public var isFinal: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

/// Why a job failed.
public struct JobError: Decodable, Equatable, Sendable {
    public let code: String
    /// The documented finer case of `code`, or nil.
    public let reason: String?
    /// What happened, for people; it may change.
    public let message: String
    /// Whether creating the same job again can succeed without a change.
    public let retryable: Bool
    public let logTail: String?

    enum CodingKeys: String, CodingKey {
        case code, reason, message, retryable
        case logTail = "log_tail"
    }
}

/// One output of a job.
public struct ClientJobOutput: Decodable, Equatable, Sendable {
    public let alias: String
    public let filename: String
    public let sizeBytes: Int
    public let contentType: String
    public let expiresAt: Date
    public let deletedAt: Date?
    /// A signed link that needs no token; nil after deletion or retention.
    public let downloadURL: URL?
    public let downloadURLExpiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case alias, filename
        case sizeBytes = "size_bytes"
        case contentType = "content_type"
        case expiresAt = "expires_at"
        case deletedAt = "deleted_at"
        case downloadURL = "download_url"
        case downloadURLExpiresAt = "download_url_expires_at"
    }
}

/// A job as a client token sees it.
public struct ClientJob: Decodable, Equatable, Sendable {
    public let id: String
    public let state: JobState
    /// From 0 to 1, when known.
    public let progress: Double?
    public let error: JobError?
    public let outputs: [ClientJobOutput]
    public let createdAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, state, progress, error, outputs
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

/// What `GET /v1/client/token` answers: what the token may still do.
public struct ClientTokenInfo: Decodable, Equatable, Sendable {
    public struct Uploads: Decodable, Equatable, Sendable {
        public let maxCount: Int
        public let maxSizeBytes: Int
        public let contentTypes: [String]
        /// Uploads created over the whole chain.
        public let used: Int

        enum CodingKeys: String, CodingKey {
            case maxCount = "max_count"
            case maxSizeBytes = "max_size_bytes"
            case contentTypes = "content_types"
            case used
        }
    }

    public struct Jobs: Decodable, Equatable, Sendable {
        public let read: [String]
    }

    public let id: String
    public let chainId: String
    public let expiresAt: Date
    public let uploads: Uploads?
    public let jobs: Jobs?

    enum CodingKeys: String, CodingKey {
        case id
        case chainId = "chain_id"
        case expiresAt = "expires_at"
        case uploads, jobs
    }
}

struct ClientJobList: Decodable {
    let data: [ClientJob]
}

/// The API's decoder: its dates are ISO 8601, with or without fractions of a second.
func apiDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        let fractions = ISO8601DateFormatter()
        fractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractions.date(from: text) ?? ISO8601DateFormatter().date(from: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date.")
        }
        return date
    }
    return decoder
}
