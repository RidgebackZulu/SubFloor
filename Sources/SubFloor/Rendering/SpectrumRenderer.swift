import MetalKit
import simd

struct DisplayState: Equatable {
    var startFraction: Double = 0
    var widthFraction: Double = 1
    /// Where the radio is tuned now (display Hz; NaN if unknown) and the captured span: the
    /// waterfall's older rows are shifted by how far the centre has moved since they were measured.
    var captureCenterHz = Double.nan
    var captureSpanHz: Double = 1
    var dbMin: Float = -130
    var dbMax: Float = -20
    var spectrumFraction: Float = 0.4
    var showPeak = false
    var colormap: Colormap = .turbo
}

struct Uniforms {
    var viewStartBin: Float
    var viewBinCount: Float
    var dbMin: Float
    var dbMax: Float
    var fftSize: UInt32
    var waterfallRows: UInt32
    var waterfallHead: UInt32
    var spectrumFraction: Float
    var viewSize: SIMD2<Float>
    var showPeak: UInt32
    var rowHeightPx: Float
    /// Bins to add to a screen bin to index the latest spectrum (it may predate a retune).
    var traceShiftBins: Float
}

/// Single full-screen pass: spectrum trace in the top band, scrolling waterfall below.
/// All zoom/pan is done with uniforms; the CPU only uploads one spectrum and one waterfall row per frame,
/// plus each row's shift in bins (`rowShiftBuffers`): a row measured at another capture centre is
/// drawn where its frequencies are now, so a retune slides the waterfall rather than smearing it.
@MainActor
final class SpectrumRenderer: NSObject, MTKViewDelegate {
    var displayProvider: (() -> DisplayState)?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let frames: SpectrumFrameStore
    private let inFlight = DispatchSemaphore(value: 3)
    private var averageBuffers: [MTLBuffer] = []
    private var peakBuffers: [MTLBuffer] = []
    private var waterfall: MTLBuffer!
    private var rowShiftBuffers: [MTLBuffer] = []
    /// The capture centre each waterfall row was measured at (NaN: unknown, drawn unshifted).
    private var rowCenters: [Double] = []
    private var latestCenter = Double.nan
    private var lutBuffer: MTLBuffer!
    private var lutColormap: Colormap?
    private var fftSize = 0
    private var rows = 0
    private var head = 0
    private var slot = 0
    private var sequence: UInt64 = 0
    private var latestAverage: [Float] = []
    private var latestPeak: [Float] = []
    /// What the last presented frame showed (nil before the first).
    private var drawn: (sequence: UInt64, state: DisplayState, size: CGSize, scale: CGFloat)?

    init?(device: MTLDevice, frames: SpectrumFrameStore) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: ShaderSource.spectrum, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreen")
        descriptor.fragmentFunction = library.makeFunction(name: "spectrumFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.frames = frames
        super.init()
        allocate(fftSize: 1024)
    }

    private func allocate(fftSize size: Int) {
        fftSize = size
        rows = min(2_048, max(256, (64 << 20) / (size * 2)))
        head = 0
        let empty = [Float](repeating: -200, count: size)
        averageBuffers = (0..<3).map { _ in device.makeBuffer(bytes: empty, length: size * 4, options: .storageModeShared)! }
        peakBuffers = (0..<3).map { _ in device.makeBuffer(bytes: empty, length: size * 4, options: .storageModeShared)! }
        waterfall = device.makeBuffer(length: rows * size * 2, options: .storageModeShared)!
        let w = waterfall.contents().bindMemory(to: Float16.self, capacity: rows * size)
        w.initialize(repeating: -200, count: rows * size)
        rowShiftBuffers = (0..<3).map { _ in device.makeBuffer(length: rows * 4, options: .storageModeShared)! }
        rowCenters = .init(repeating: .nan, count: rows)
        latestAverage = empty
        latestPeak = empty
    }

    /// Bins to add to a screen bin (in the current capture) to index a spectrum measured with the
    /// capture centred at `measuredAt`: the same frequency sits that many bins further along it.
    /// Zero when either centre is unknown.
    nonisolated static func shiftBins(measuredAt: Double, currentCenterHz: Double, binHz: Double) -> Float {
        guard measuredAt.isFinite, currentCenterHz.isFinite, binHz > 0 else { return 0 }
        return Float((currentCenterHz - measuredAt) / binHz)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let state = displayProvider?() ?? DisplayState()
        if lutColormap != state.colormap {
            let lut = state.colormap.lut()
            lutBuffer = device.makeBuffer(bytes: lut, length: lut.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
            lutColormap = state.colormap
        }

        if let frame = frames.readFrame(after: sequence, average: &latestAverage, peak: &latestPeak) {
            sequence = frame.sequence
            latestCenter = frame.centerHz
            if latestAverage.count != fftSize {
                let keepAverage = latestAverage, keepPeak = latestPeak
                allocate(fftSize: keepAverage.count)
                latestAverage = keepAverage
                latestPeak = keepPeak
            }
            head = (head + 1) % rows
            let row = waterfall.contents().bindMemory(to: Float16.self, capacity: rows * fftSize) + head * fftSize
            for i in 0..<fftSize { row[i] = Float16(latestAverage[i]) }
            rowCenters[head] = latestCenter
        }

        // Nothing new to show (no spectrum frame since, same view, same size): keep the last frame
        // on screen. Spectra arrive at the waterfall rate (30/s by default) but the view ticks at
        // 120 Hz, and every present commits a Core Animation transaction, which runs AppKit's and
        // SwiftUI's layout and render pass for the whole window.
        let scale = view.window?.backingScaleFactor ?? 2
        if let d = drawn, d.sequence == sequence, d.state == state, d.size == view.drawableSize, d.scale == scale {
            return
        }

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }
        inFlight.wait()
        slot = (slot + 1) % 3
        averageBuffers[slot].contents().copyMemory(from: latestAverage, byteCount: fftSize * 4)
        peakBuffers[slot].contents().copyMemory(from: latestPeak, byteCount: fftSize * 4)
        let binHz = state.captureSpanHz / Double(max(fftSize, 1))
        let shift = { Self.shiftBins(measuredAt: $0, currentCenterHz: state.captureCenterHz, binHz: binHz) }
        let shifts = rowShiftBuffers[slot].contents().bindMemory(to: Float.self, capacity: rows)
        for r in 0..<rows { shifts[r] = shift(rowCenters[r]) }

        let size = view.drawableSize
        var uniforms = Uniforms(
            viewStartBin: Float(state.startFraction * Double(fftSize)),
            viewBinCount: Float(state.widthFraction * Double(fftSize)),
            dbMin: state.dbMin, dbMax: state.dbMax,
            fftSize: UInt32(fftSize), waterfallRows: UInt32(rows), waterfallHead: UInt32(head),
            spectrumFraction: state.spectrumFraction,
            viewSize: SIMD2(Float(size.width), Float(size.height)),
            showPeak: state.showPeak ? 1 : 0,
            rowHeightPx: Float(scale),
            traceShiftBins: shift(latestCenter))

        let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(averageBuffers[slot], offset: 0, index: 0)
        encoder.setFragmentBuffer(peakBuffers[slot], offset: 0, index: 1)
        encoder.setFragmentBuffer(waterfall, offset: 0, index: 2)
        encoder.setFragmentBuffer(lutBuffer, offset: 0, index: 3)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 4)
        encoder.setFragmentBuffer(rowShiftBuffers[slot], offset: 0, index: 5)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.present(drawable)
        commands.commit()
        drawn = (sequence, state, size, scale)
    }
}
