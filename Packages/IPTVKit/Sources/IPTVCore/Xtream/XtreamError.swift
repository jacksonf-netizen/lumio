import Foundation

/// Everything that can go wrong talking to a provider, with messages fit to show the user.
/// Messages never contain credentials.
public enum XtreamError: Error, Equatable, Sendable {
    case unauthorized
    case accountExpired(Date?)
    case accountNotActive(status: String)
    case forbidden
    case notFound
    case maxConnectionsReached
    case rateLimited
    case server(statusCode: Int)
    case httpStatus(Int)
    case timeout
    case offline
    case cannotConnect(host: String?)
    case invalidResponse(String)
    case decoding(String)
    case cancelled

    /// Whether retrying later might succeed without the user changing anything.
    public var isTransient: Bool {
        switch self {
        case .timeout, .offline, .cannotConnect, .server, .rateLimited, .maxConnectionsReached: true
        default: false
        }
    }
}

extension XtreamError: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .unauthorized:
            "The provider rejected the username or password."
        case .accountExpired(let date):
            if let date {
                "This account expired on \(date.formatted(date: .abbreviated, time: .omitted))."
            } else {
                "This account has expired."
            }
        case .accountNotActive(let status):
            "This account is not active (status: \(status))."
        case .forbidden:
            "The provider refused access (HTTP 403). The account may be blocked, or the provider may not accept this app's user-agent."
        case .notFound:
            "The provider returned \"not found\" (HTTP 404). The stream or page may no longer exist."
        case .maxConnectionsReached:
            "The provider says all connections for this account are in use."
        case .rateLimited:
            "The provider is limiting requests (HTTP 429). Try again shortly."
        case .server(let code):
            "The provider's server had an error (HTTP \(code))."
        case .httpStatus(let code):
            "Unexpected response from the provider (HTTP \(code))."
        case .timeout:
            "The provider didn't respond in time."
        case .offline:
            "You appear to be offline."
        case .cannotConnect(let host):
            "Couldn't connect to \(host ?? "the server"). Check the server URL."
        case .invalidResponse(let detail):
            "The provider sent a response this app doesn't understand (\(detail))."
        case .decoding(let detail):
            "Couldn't read the provider's data (\(detail))."
        case .cancelled:
            "Cancelled."
        }
    }

    /// Maps an HTTP status code to an error, or nil for success.
    static func from(statusCode: Int) -> XtreamError? {
        switch statusCode {
        case 200..<300: nil
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 429: .rateLimited
        // Non-standard codes some panels use when the connection limit is hit.
        case 456, 458, 509: .maxConnectionsReached
        case 500..<600: .server(statusCode: statusCode)
        default: .httpStatus(statusCode)
        }
    }

    /// Maps transport errors to user-meaningful cases.
    static func from(_ error: Error) -> XtreamError {
        if let error = error as? XtreamError { return error }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed,
                 .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return .cannotConnect(host: urlError.failingURL?.host)
            case .userAuthenticationRequired: return .unauthorized
            default: return .invalidResponse(urlError.code.rawValue.description)
            }
        }
        if let decoding = error as? DecodingError {
            return .decoding(Self.describe(decoding))
        }
        return .invalidResponse(String(describing: type(of: error)))
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context): "corrupt data at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .keyNotFound(let key, _): "missing \(key.stringValue)"
        case .typeMismatch(_, let context): "unexpected type at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .valueNotFound(_, let context): "missing value at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        @unknown default: "unknown"
        }
    }
}
