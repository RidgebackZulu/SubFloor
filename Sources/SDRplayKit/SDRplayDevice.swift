import Accelerate
import CSDRplay
import DSPCore
import Foundation

/// An opened RSP1B (or RSP1A-family) device. All API calls are serialised by `lock`.
/// The C stream callback reaches this object through an unretained context pointer, so `close()`
/// (or deinit) must run before the object is released while streaming.
public final class SDRplayDevice: IQSource, @unchecked Sendable {
    private static let supportedHardware: Set<UInt8> = [6, 255]   // RSP1B, RSP1A

    public let name: String
    public let serial: String
    public private(set) var settings = SDRplaySettings()
    public private(set) var centerFrequency: Double = 100_000_000
    public var sampleRate: Double { settings.outputRate }
    public var onEvent: (@Sendable (SDRplayEvent) -> Void)?

    private var device: sdrplay_api_DeviceT
    private let params: UnsafeMutablePointer<sdrplay_api_DeviceParamsT>
    private var handler: (@Sendable (UnsafeBufferPointer<DSPComplex>) -> Void)?
    private var streaming = false
    private var closed = false
    private let lock = NSLock()
    private var scratchRe = [Float](repeating: 0, count: 1 << 16)
    private var scratchIm = [Float](repeating: 0, count: 1 << 16)
    private var scratchOut = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: 1 << 16)

    private init(device: sdrplay_api_DeviceT, params: UnsafeMutablePointer<sdrplay_api_DeviceParamsT>) {
        self.device = device
        self.params = params
        serial = withUnsafeBytes(of: device.SerNo) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        name = device.hwVer == 6 ? "RSP1B" : "RSP1A"
    }

    deinit { close() }

    public static func open() throws -> SDRplayDevice {
        try check(sdrplay_api_Open(), "Open SDRplay API (is the SDRplay service running?)")
        do {
            var version: Float = 0
            try check(sdrplay_api_ApiVersion(&version), "Read API version")
            guard abs(version - 3.15) < 0.001 else {
                throw SDRplayError(message: "SDRplay API \(version) installed; SubFloor is built for 3.15")
            }
            try check(sdrplay_api_LockDeviceApi(), "Lock device API")
            defer { _ = sdrplay_api_UnlockDeviceApi() }
            var devices = [sdrplay_api_DeviceT](repeating: sdrplay_api_DeviceT(), count: 16)
            var count: UInt32 = 0
            try check(sdrplay_api_GetDevices(&devices, &count, 16), "List devices")
            guard var chosen = devices.prefix(Int(count)).first(where: { supportedHardware.contains($0.hwVer) }) else {
                throw SDRplayError.noDevice
            }
            try check(sdrplay_api_SelectDevice(&chosen), "Select device (in use by another app?)")
            var params: UnsafeMutablePointer<sdrplay_api_DeviceParamsT>?
            try check(sdrplay_api_GetDeviceParams(chosen.dev, &params), "Read device parameters")
            guard let params else { throw SDRplayError(message: "Device returned no parameters") }
            return SDRplayDevice(device: chosen, params: params)
        } catch {
            _ = sdrplay_api_Close()
            throw error
        }
    }

    // MARK: IQSource

    public func start(_ handler: @escaping @Sendable (UnsafeBufferPointer<DSPComplex>) -> Void) throws {
        try lock.withLock {
            guard !streaming else { return }
            self.handler = handler
            try initialise()
        }
    }

    public func stop() {
        lock.withLock {
            guard streaming else { return }
            _ = sdrplay_api_Uninit(device.dev)
            streaming = false
        }
    }

    public func setCenterFrequency(_ hz: Double) throws {
        try lock.withLock {
            centerFrequency = hz
            params.pointee.rxChannelA.pointee.tunerParams.rfFreq.rfHz = hz
            try update([sdrplay_api_Update_Tuner_Frf], "Tune")
        }
    }

    // MARK: Settings

    public func apply(_ new: SDRplaySettings) throws {
        try lock.withLock {
            let old = settings
            settings = new
            write()
            guard streaming else { return }
            if new.sampleRate != old.sampleRate || new.decimation != old.decimation || new.ifBandwidthKHz != old.ifBandwidthKHz {
                _ = sdrplay_api_Uninit(device.dev)
                streaming = false
                try initialise()
                return
            }
            var reasons: [sdrplay_api_ReasonForUpdateT] = []
            if new.lnaState != old.lnaState || new.ifGainReductionDb != old.ifGainReductionDb { reasons.append(sdrplay_api_Update_Tuner_Gr) }
            if new.agc != old.agc { reasons.append(sdrplay_api_Update_Ctrl_Agc) }
            if new.biasT != old.biasT { reasons.append(sdrplay_api_Update_Rsp1a_BiasTControl) }
            if new.rfNotch != old.rfNotch { reasons.append(sdrplay_api_Update_Rsp1a_RfNotchControl) }
            if new.dabNotch != old.dabNotch { reasons.append(sdrplay_api_Update_Rsp1a_RfDabNotchControl) }
            if new.ppm != old.ppm { reasons.append(sdrplay_api_Update_Dev_Ppm) }
            if !reasons.isEmpty { try update(reasons, "Update settings") }
        }
    }

    public func close() {
        stop()
        lock.withLock {
            guard !closed else { return }
            closed = true
            _ = sdrplay_api_LockDeviceApi()
            _ = sdrplay_api_ReleaseDevice(&device)
            _ = sdrplay_api_UnlockDeviceApi()
            _ = sdrplay_api_Close()
        }
    }

    // MARK: Internals (call with `lock` held)

    private func initialise() throws {
        write()
        var callbacks = sdrplay_api_CallbackFnsT(StreamACbFn: sdrplayStream, StreamBCbFn: nil, EventCbFn: sdrplayEvent)
        try check(sdrplay_api_Init(device.dev, &callbacks, Unmanaged.passUnretained(self).toOpaque()), "Start streaming")
        streaming = true
    }

    private func write() {
        let dev = params.pointee.devParams!
        let ch = params.pointee.rxChannelA!
        dev.pointee.fsFreq.fsHz = settings.sampleRate
        dev.pointee.ppm = settings.ppm
        dev.pointee.rsp1aParams.rfNotchEnable = settings.rfNotch ? 1 : 0
        dev.pointee.rsp1aParams.rfDabNotchEnable = settings.dabNotch ? 1 : 0
        ch.pointee.rsp1aTunerParams.biasTEnable = settings.biasT ? 1 : 0
        ch.pointee.tunerParams.bwType = sdrplay_api_Bw_MHzT(rawValue: numericCast(settings.ifBandwidthKHz))
        ch.pointee.tunerParams.ifType = sdrplay_api_IF_Zero
        ch.pointee.tunerParams.rfFreq.rfHz = centerFrequency
        ch.pointee.tunerParams.gain.gRdB = Int32(settings.ifGainReductionDb)
        ch.pointee.tunerParams.gain.LNAstate = UInt8(settings.lnaState)
        ch.pointee.ctrlParams.decimation.enable = settings.decimation > 1 ? 1 : 0
        ch.pointee.ctrlParams.decimation.decimationFactor = UInt8(settings.decimation)
        ch.pointee.ctrlParams.agc.enable = settings.agc.api
        ch.pointee.ctrlParams.dcOffset.DCenable = 1
        ch.pointee.ctrlParams.dcOffset.IQenable = 1
    }

    private func update(_ reasons: [sdrplay_api_ReasonForUpdateT], _ context: String) throws {
        guard streaming else { return }
        let combined = sdrplay_api_ReasonForUpdateT(rawValue: reasons.reduce(0) { $0 | $1.rawValue })
        try check(sdrplay_api_Update(device.dev, sdrplay_api_Tuner_A, combined, sdrplay_api_Update_Ext1_None), context)
    }

    // MARK: Callbacks (API threads)

    fileprivate func deliver(_ xi: UnsafePointer<Int16>, _ xq: UnsafePointer<Int16>, _ n: Int) {
        guard let handler, n > 0, n <= scratchOut.count else { return }
        var scale: Float = 1 / 32_768
        let len = vDSP_Length(n)
        scratchRe.withUnsafeMutableBufferPointer { re in
            scratchIm.withUnsafeMutableBufferPointer { im in
                scratchOut.withUnsafeMutableBufferPointer { out in
                    vDSP_vflt16(xi, 1, re.baseAddress!, 1, len)
                    vDSP_vflt16(xq, 1, im.baseAddress!, 1, len)
                    vDSP_vsmul(re.baseAddress!, 1, &scale, re.baseAddress!, 1, len)
                    vDSP_vsmul(im.baseAddress!, 1, &scale, im.baseAddress!, 1, len)
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    vDSP_ztoc(&split, 1, out.baseAddress!, 2, len)
                    handler(UnsafeBufferPointer(start: out.baseAddress!, count: n))
                }
            }
        }
    }

    fileprivate func handleEvent(_ event: sdrplay_api_EventT, _ params: sdrplay_api_EventParamsT) {
        switch event {
        case sdrplay_api_PowerOverloadChange:
            let detected = params.powerOverloadParams.powerOverloadChangeType == sdrplay_api_Overload_Detected
            _ = sdrplay_api_Update(device.dev, sdrplay_api_Tuner_A, sdrplay_api_Update_Ctrl_OverloadMsgAck, sdrplay_api_Update_Ext1_None)
            onEvent?(.overload(detected: detected))
        case sdrplay_api_DeviceRemoved:
            onEvent?(.deviceRemoved)
        case sdrplay_api_DeviceFailure:
            onEvent?(.deviceFailure)
        case sdrplay_api_GainChange:
            onEvent?(.gainChanged(params.gainParams.currGain))
        default:
            break
        }
    }
}

private func sdrplayStream(_ xi: UnsafeMutablePointer<Int16>?, _ xq: UnsafeMutablePointer<Int16>?,
                           _ params: UnsafeMutablePointer<sdrplay_api_StreamCbParamsT>?, _ numSamples: UInt32,
                           _ reset: UInt32, _ context: UnsafeMutableRawPointer?) {
    guard let xi, let xq, let context else { return }
    Unmanaged<SDRplayDevice>.fromOpaque(context).takeUnretainedValue().deliver(xi, xq, Int(numSamples))
}

private func sdrplayEvent(_ eventId: sdrplay_api_EventT, _ tuner: sdrplay_api_TunerSelectT,
                          _ params: UnsafeMutablePointer<sdrplay_api_EventParamsT>?, _ context: UnsafeMutableRawPointer?) {
    guard let params, let context else { return }
    Unmanaged<SDRplayDevice>.fromOpaque(context).takeUnretainedValue().handleEvent(eventId, params.pointee)
}
