import Foundation

/// The digital modes SubFloor can decode. Raw values are stable identifiers
/// (persisted in settings), `label` is the user-facing name.
public enum ModeID: String, CaseIterable, Codable, Sendable, Identifiable {
    case cw, psk31, rtty, ft8, wspr

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .cw: "CW"
        case .psk31: "PSK31"
        case .rtty: "RTTY"
        case .ft8: "FT8"
        case .wspr: "WSPR"
        }
    }

    /// True for modes decoded per fixed time slot (FT8, WSPR) rather than as a stream.
    public var isSlotMode: Bool {
        switch self {
        case .ft8, .wspr: true
        case .cw, .psk31, .rtty: false
        }
    }

    /// Audio width, in Hz, of the passband the mode listens to around its tracked signal.
    public var listenWidthHz: Double {
        switch self {
        case .cw: 250
        case .psk31: 150
        case .rtty: 400
        case .ft8: 100
        case .wspr: 50
        }
    }

    /// How far, in Hz, a decoder may pull its frequency while locked on a signal.
    public var lockRangeHz: Double {
        switch self {
        case .cw: 25
        case .psk31: 15
        case .rtty: 30
        case .ft8: 10
        case .wspr: 5
        }
    }
}

/// User-selected modem configuration.
public struct ModemSettings: Sendable, Equatable {
    /// Selected mode; nil means the modem is off.
    public var mode: ModeID?
    public var autoDetect = false
    public var audioWide = false
    public var slotModesEnabled = true

    public init(mode: ModeID? = nil, autoDetect: Bool = false, audioWide: Bool = false, slotModesEnabled: Bool = true) {
        self.mode = mode
        self.autoDetect = autoDetect
        self.audioWide = audioWide
        self.slotModesEnabled = slotModesEnabled
    }
}

/// A point-in-time description of one tracked signal, for display.
public struct SignalSnapshot: Sendable, Equatable, Identifiable {
    public var id: Int
    public var frequencyHz: Double
    public var snrDb: Float
    public var mode: ModeID?
    public var submode: String
    public var isQuiet: Bool
    public var isCursor: Bool

    public init(id: Int, frequencyHz: Double, snrDb: Float, mode: ModeID?, submode: String, isQuiet: Bool, isCursor: Bool) {
        self.id = id
        self.frequencyHz = frequencyHz
        self.snrDb = snrDb
        self.mode = mode
        self.submode = submode
        self.isQuiet = isQuiet
        self.isCursor = isCursor
    }
}

/// New text produced by the decoder of one tracked signal.
public struct DecodedText: Sendable, Equatable {
    public var trackID: Int
    public var text: String

    public init(trackID: Int, text: String) {
        self.trackID = trackID
        self.text = text
    }
}

/// One decoded message from a slot mode (FT8, WSPR).
public struct SlotDecode: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var mode: ModeID
    public var slotStart: Date
    public var frequencyHz: Double
    public var snrDb: Float
    public var timeOffset: Double
    public var message: String

    public init(id: UUID = UUID(), mode: ModeID, slotStart: Date, frequencyHz: Double, snrDb: Float, timeOffset: Double, message: String) {
        self.id = id
        self.mode = mode
        self.slotStart = slotStart
        self.frequencyHz = frequencyHz
        self.snrDb = snrDb
        self.timeOffset = timeOffset
        self.message = message
    }
}

/// Decodes one tracked signal from narrowband audio. Not thread-safe; owned by one thread at a time.
public protocol SignalDecoder: AnyObject {
    var frequencyHz: Double { get }
    var submode: String { get }
    /// Consumes audio and returns any newly decoded text.
    func process(_ audio: UnsafeBufferPointer<Float>) -> String
    func constellation() -> [SIMD2<Float>]
    func reset()
}

/// A continuously decoded mode (CW, PSK31, RTTY).
public protocol StreamingModem {
    static var id: ModeID { get }
    static func makeDecoder(frequencyHz: Double, sampleRate: Double) -> any SignalDecoder
}

/// A mode decoded once per fixed time slot (FT8, WSPR).
public protocol SlotModem {
    static var id: ModeID { get }
    static var slotSeconds: Double { get }
    static func decode(samples: [Float], sampleRate: Double, slotStart: Date, audioBand: ClosedRange<Double>) -> [SlotDecode]
}

/// Registry of the available modems. Each modem task appends its type here.
public enum ModemCatalog {
    public static var streaming: [any StreamingModem.Type] { [CWModem.self, PSK31Modem.self, RTTYModem.self] }
    public static var slot: [any SlotModem.Type] { [WSPRModem.self] }

    public static func streaming(_ id: ModeID) -> (any StreamingModem.Type)? {
        streaming.first { $0.id == id }
    }

    public static func slot(_ id: ModeID) -> (any SlotModem.Type)? {
        slot.first { $0.id == id }
    }
}
