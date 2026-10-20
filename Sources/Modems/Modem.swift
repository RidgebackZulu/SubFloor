import Accelerate
import DSPCore
import Foundation
import SwiftUI
import Synchronization

public enum ModemInput: Sendable { case audio, iq }

public struct ModemInfo: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let input: ModemInput
    public let preferredMode: DemodMode?
    public let preferredBandwidth: Double?

    public init(id: String, name: String, input: ModemInput, preferredMode: DemodMode?, preferredBandwidth: Double?) {
        self.id = id
        self.name = name
        self.input = input
        self.preferredMode = preferredMode
        self.preferredBandwidth = preferredBandwidth
    }
}

/// What the receiver is doing when a buffer is delivered.
public struct ModemContext: Sendable {
    public var sampleRate: Double
    public var mode: DemodMode
    public var bandwidthHz: Double
    public var cwPitchHz: Double

    public init(sampleRate: Double, mode: DemodMode, bandwidthHz: Double, cwPitchHz: Double) {
        self.sampleRate = sampleRate
        self.mode = mode
        self.bandwidthHz = bandwidthHz
        self.cwPitchHz = cwPitchHz
    }
}

/// A decoder plug-in. `process` runs on the DSP thread; publish results to the main thread yourself.
/// To add a modem: create `Sources/Modems/<Name>/`, conform to `Modem`, append it to `ModemRegistry.all`.
public protocol Modem: AnyObject, Sendable {
    static var info: ModemInfo { get }
    init()
    func reset()
    func process(audio: UnsafeBufferPointer<Float>, context: ModemContext)
    func process(iq: UnsafeBufferPointer<DSPComplex>, context: ModemContext)
    @MainActor func makeOutputView() -> AnyView
}

public extension Modem {
    func process(audio: UnsafeBufferPointer<Float>, context: ModemContext) {}
    func process(iq: UnsafeBufferPointer<DSPComplex>, context: ModemContext) {}
}

public enum ModemRegistry {
    /// The single registration point for modems.
    public static let all: [any Modem.Type] = [
        CWDecoderModem.self,
    ]

    public static var infos: [ModemInfo] { all.map { $0.info } }

    public static func type(withID id: String) -> (any Modem.Type)? {
        all.first { $0.info.id == id }
    }
}

/// Holds the active modem and forwards DSP-thread buffers to it.
public final class ModemHost: @unchecked Sendable {
    private let active = Mutex<(any Modem)?>(nil)

    public init() {}

    public func set(_ modem: (any Modem)?) {
        modem?.reset()
        active.withLock { $0 = modem }
    }

    public var current: (any Modem)? { active.withLock { $0 } }

    public func process(audio: UnsafeBufferPointer<Float>, context: ModemContext) {
        guard let modem = current, type(of: modem).info.input == .audio else { return }
        modem.process(audio: audio, context: context)
    }

    public func process(iq: UnsafeBufferPointer<DSPComplex>, context: ModemContext) {
        guard let modem = current, type(of: modem).info.input == .iq else { return }
        modem.process(iq: iq, context: context)
    }
}
