import Accelerate

/// Anything that streams complex baseband samples. `centerFrequency` is the hardware frequency in Hz.
public protocol IQSource: AnyObject, Sendable {
    var name: String { get }
    var sampleRate: Double { get }
    var centerFrequency: Double { get }
    /// Starts streaming. `handler` is called on a source-owned thread with blocks of IQ.
    func start(_ handler: @escaping @Sendable (UnsafeBufferPointer<DSPComplex>) -> Void) throws
    func stop()
    func setCenterFrequency(_ hz: Double) throws
}
