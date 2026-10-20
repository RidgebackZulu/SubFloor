import CSDRplay

public struct SDRplayError: Error, CustomStringConvertible, Equatable, Sendable {
    public let code: Int?
    public let message: String
    public var description: String { message }

    init(_ err: sdrplay_api_ErrT, context: String) {
        let text = sdrplay_api_GetErrorString(err).map { String(cString: $0) } ?? "Unknown error"
        code = Int(err.rawValue)
        message = "\(context): \(text)"
    }

    public init(message: String) {
        code = nil
        self.message = message
    }

    public static let noDevice = SDRplayError(message: "No RSP1B or RSP1A found")
}

func check(_ err: sdrplay_api_ErrT, _ context: String) throws {
    if err != sdrplay_api_Success { throw SDRplayError(err, context: context) }
}
