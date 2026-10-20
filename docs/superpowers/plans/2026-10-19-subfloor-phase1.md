# SubFloor Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build SubFloor, a native macOS SDR receiver for the SDRplay RSP1B. It has a Metal spectrum and waterfall, AM/FM/SSB/CW audio, HamItUp support, bookmarks and a modular modem framework with a CW decoder.

**Architecture:** A single Swift package. The pure, unit-tested library targets are `DSPCore` (DSP), `SubFloorCore` (tuning, viewport and bookmark logic) and `Modems` (plugin protocol and CW). `SDRplayKit` is a thin wrapper over the C API. The executable `SubFloor` target holds the SwiftUI and Metal app. Data flows from an `IQSource` through an SPSC ring to a DSP thread. That thread feeds the spectrum frame store (read by the Metal renderer) and the `Receiver`, whose audio goes to the AVAudioEngine output and the active modem.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Metal/MetalKit, Accelerate/vDSP, AVAudioEngine, Synchronization (`Atomic`, `Mutex`), Swift Testing, SDRplay API 3.15.

**Spec:** `docs/superpowers/specs/2026-10-19-subfloor-design.md`

## Global Constraints

- Apple Silicon (arm64) only. Package deployment target `.macOS(.v15)`, developed and run on macOS 26.6. Xcode 26.2 / Swift 6.2 toolchain, `// swift-tools-version: 6.0`.
- SDRplay API 3.15 at `/usr/local/lib/libsdrplay_api.dylib`, headers `/usr/local/include/sdrplay_api*.h`. The dylib's install name is `@rpath/libsdrplay_api.so.3`, so every target that links it passes `-L/usr/local/lib -Xlinker -rpath -Xlinker /usr/local/lib`.
- RSP1B is `hwVer == 6`, RSP1A is `255`. Both use `rsp1aParams` / `rsp1aTunerParams`. Zero-IF only in phase 1.
- RSP1B frequency range is 1 kHz – 2 GHz. Sample rates are 2–10 MSPS, decimation is 1/2/4/8/16/32, and IF gain reduction is 20–59 dB. LNA states: 7 below 60 MHz, 10 from 60 to 1000 MHz, 9 from 1 to 2 GHz.
- The HamItUp LO defaults to 125 MHz. `hardwareHz = displayHz + LO` when the upconverter is enabled. The UI only ever shows display frequencies.
- Panning and zooming never retune the radio.
- Audio output is 48 kHz mono Float32.
- Dark mode by default.
- No heap allocation and no blocking locks on the IQ callback or audio render paths. Short uncontended `Mutex` sections are allowed on the DSP thread for config and frame hand-off.
- Bookmarks are stored at `~/Library/Application Support/SubFloor/bookmarks.json` and written atomically.
- New modems are added by creating `Sources/Modems/<Name>/` and appending one line to `ModemRegistry.all`.
- Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Run all commands from the repository root (the worktree root).

## Deviations from the spec (approved during planning; also update the spec in Task 1)

1. Shaders are embedded as a Swift string (`ShaderSource.swift`) and compiled with `makeLibrary(source:)`. They are not a bundled `.metal` resource.
2. The waterfall history is a ring `MTLBuffer` of `Float16` (rows × fftSize). It is not a texture, because Apple GPUs cap 2D textures at 16384 wide and FFTs reach 65536.
3. `SDRplayDevice` is a `final class` serialized by an `NSLock`, not an actor. The C callbacks need a stable, synchronously reachable context pointer.
4. Low-IF mode is dropped from phase 1. Zero-IF plus hardware decimation covers the rate range.
5. Frequency parser rule for input without a suffix: below 3000 → MHz, below 3,000,000 → kHz, otherwise Hz. Input with more than one `.` is treated as dot-grouped Hz (`14.074.000`).

## File map

```
Package.swift
Sources/CSDRplay/module.modulemap, shim.h           C API module
Sources/SDRplayKit/SDRplayError.swift               error mapping
Sources/SDRplayKit/SDRplaySettings.swift            hardware settings model
Sources/SDRplayKit/SDRplayDevice.swift              device lifecycle, streaming, updates, events
Sources/DSPCore/SPSCRing.swift                      lock-free ring
Sources/DSPCore/Window.swift                        window functions
Sources/DSPCore/SpectrumAnalyzer.swift              FFT → dB, averaging/peak
Sources/DSPCore/NCO.swift                           frequency shifter
Sources/DSPCore/FIR.swift                           FIR design, decimators, decimation plan
Sources/DSPCore/DemodMode.swift                     mode table
Sources/DSPCore/Demodulators.swift                  AM / FM / SSB demods
Sources/DSPCore/AudioProcessing.swift               AGC, linear resampler
Sources/DSPCore/Receiver.swift                      full channel chain → 48 kHz audio
Sources/DSPCore/IQSource.swift                      source protocol
Sources/DSPCore/MorseCode.swift                     Morse table + timeline
Sources/DSPCore/SyntheticSource.swift               demo signal generator
Sources/DSPCore/IQFileSource.swift                  WAV IQ playback
Sources/SubFloorCore/Frequency.swift                parser, formatter, upconverter, tuning planner, RSP1B limits
Sources/SubFloorCore/SpectrumViewport.swift         zoom/pan maths, ruler scale
Sources/SubFloorCore/Bookmarks.swift                model, store, search, defaults
Sources/Modems/Modem.swift                          protocol, info, context, registry, host
Sources/Modems/CW/CWDecoderCore.swift               pure CW decoding
Sources/Modems/CW/CWDecoderModem.swift              modem + SwiftUI output view
Sources/SubFloor/App/SubFloorApp.swift              @main, commands, settings scene
Sources/SubFloor/App/AppModel.swift                 @Observable app state + actions
Sources/SubFloor/App/KeyboardController.swift       global key handling
Sources/SubFloor/App/CPUUsage.swift                 process CPU meter
Sources/SubFloor/Engine/AudioOutput.swift           AVAudioEngine output
Sources/SubFloor/Engine/DSPEngine.swift             DSP thread + frame store
Sources/SubFloor/Rendering/ShaderSource.swift       Metal shader text
Sources/SubFloor/Rendering/Colormap.swift           LUTs
Sources/SubFloor/Rendering/SpectrumRenderer.swift   MTKViewDelegate
Sources/SubFloor/Rendering/SpectrumMTKView.swift    mouse/trackpad handling
Sources/SubFloor/UI/*.swift                         SwiftUI views
scripts/bundle.sh                                   release .app bundle
Tests/{DSPCoreTests,SubFloorCoreTests,SDRplayKitTests,ModemsTests}/
```

---

### Task 1: Package scaffold, SDRplay C module, error mapping

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/CSDRplay/module.modulemap`, `Sources/CSDRplay/shim.h`, `Sources/SDRplayKit/SDRplayError.swift`
- Modify: `docs/superpowers/specs/2026-10-19-subfloor-design.md` (record the deviations listed above)
- Test: `Tests/SDRplayKitTests/SDRplayErrorTests.swift`

**Interfaces:**
- Produces: `public struct SDRplayError: Error, CustomStringConvertible, Equatable, Sendable { code: Int?; message: String }`, `init(_ err: sdrplay_api_ErrT, context: String)`, `init(message:)`, `static let noDevice`, internal `func check(_ err: sdrplay_api_ErrT, _ context: String) throws`.

- [ ] **Step 1: Write `Package.swift` with only the targets this task needs**

```swift
// swift-tools-version: 6.0
import PackageDescription

let sdrplayLinker: [LinkerSetting] = [
    .unsafeFlags(["-L/usr/local/lib", "-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"])
]
let fastMath: [SwiftSetting] = [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]

let package = Package(
    name: "SubFloor",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CSDRplay", path: "Sources/CSDRplay"),
        .target(name: "SDRplayKit", dependencies: ["CSDRplay"], linkerSettings: sdrplayLinker),
        .testTarget(name: "SDRplayKitTests", dependencies: ["SDRplayKit", "CSDRplay"], linkerSettings: sdrplayLinker),
    ]
)
```

`Sources/CSDRplay/module.modulemap`:
```
module CSDRplay [system] {
    header "shim.h"
    link "sdrplay_api"
    export *
}
```

`Sources/CSDRplay/shim.h`:
```c
#include "/usr/local/include/sdrplay_api.h"
```

`.gitignore`:
```
.build/
build/
.swiftpm/
*.xcodeproj/xcuserdata/
DerivedData/
```

- [ ] **Step 2: Write the failing test**

`Tests/SDRplayKitTests/SDRplayErrorTests.swift`:
```swift
import Testing
import CSDRplay
@testable import SDRplayKit

@Test func errorMessageComesFromLibrary() {
    let error = SDRplayError(sdrplay_api_Fail, context: "Open")
    #expect(error.code == 1)
    #expect(error.message.hasPrefix("Open: "))
    #expect(error.message.count > "Open: ".count)
}

@Test func checkThrowsOnlyOnFailure() throws {
    try check(sdrplay_api_Success, "noop")
    #expect(throws: SDRplayError.self) { try check(sdrplay_api_InvalidParam, "bad") }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter SDRplayKitTests`
Expected: compile error, because `SDRplayError` is not defined.

- [ ] **Step 4: Implement `Sources/SDRplayKit/SDRplayError.swift`**

```swift
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter SDRplayKitTests`
Expected: 2 tests pass. This also proves the dylib links and loads through the rpath.

- [ ] **Step 6: Record the spec deviations**

Append a section `## 14. Planning-time decisions` to the spec, containing the five numbered deviations from this plan's "Deviations" section, verbatim. Also change the macOS line in §2 to: "macOS 26 target machine; package deployment target macOS 15 (needed for `Synchronization`)."

- [ ] **Step 7: Commit**

```bash
git add Package.swift .gitignore Sources/CSDRplay Sources/SDRplayKit Tests/SDRplayKitTests docs/superpowers/specs
git commit -m "feat: scaffold package and link SDRplay API

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: DSPCore SPSC ring buffer

**Files:**
- Modify: `Package.swift` (add the `DSPCore` and `DSPCoreTests` targets, and make `SDRplayKit` depend on `DSPCore`)
- Create: `Sources/DSPCore/SPSCRing.swift`
- Test: `Tests/DSPCoreTests/SPSCRingTests.swift`

**Interfaces:**
- Produces: `public final class SPSCRing<Element: BitwiseCopyable>: @unchecked Sendable` with `init(capacity: Int, fill: Element)`, `capacity`, `availableToRead`, `availableToWrite`, `write(_: UnsafeBufferPointer<Element>) -> Int`, `read(into: UnsafeMutableBufferPointer<Element>) -> Int`, `drain()`.

- [ ] **Step 1: Add targets to `Package.swift`**

Replace the `targets:` array with:
```swift
    targets: [
        .systemLibrary(name: "CSDRplay", path: "Sources/CSDRplay"),
        .target(name: "DSPCore", swiftSettings: fastMath),
        .target(name: "SDRplayKit", dependencies: ["CSDRplay", "DSPCore"], linkerSettings: sdrplayLinker),
        .testTarget(name: "DSPCoreTests", dependencies: ["DSPCore"]),
        .testTarget(name: "SDRplayKitTests", dependencies: ["SDRplayKit", "CSDRplay"], linkerSettings: sdrplayLinker),
    ]
```

- [ ] **Step 2: Write the failing tests**

`Tests/DSPCoreTests/SPSCRingTests.swift`:
```swift
import Testing
@testable import DSPCore

@Test func ringRoundTripsAcrossWrap() {
    let ring = SPSCRing<Float>(capacity: 8, fill: 0)
    var out = [Float](repeating: 0, count: 5)
    for round in 0..<5 {
        let input = (0..<5).map { Float(round * 10 + $0) }
        #expect(input.withUnsafeBufferPointer { ring.write($0) } == 5)
        #expect(out.withUnsafeMutableBufferPointer { ring.read(into: $0) } == 5)
        #expect(out == input)
    }
}

@Test func ringRejectsOverflowAndRoundsCapacity() {
    let ring = SPSCRing<Float>(capacity: 3, fill: 0)
    #expect(ring.capacity == 4)
    let input: [Float] = [1, 2, 3, 4, 5, 6]
    #expect(input.withUnsafeBufferPointer { ring.write($0) } == 4)
    #expect(ring.availableToWrite == 0)
    ring.drain()
    #expect(ring.availableToRead == 0)
}

@Test func ringPreservesOrderUnderConcurrency() async {
    let ring = SPSCRing<Int32>(capacity: 1024, fill: 0)
    let total: Int32 = 200_000
    let producer = Task.detached {
        var next: Int32 = 0
        var chunk = [Int32](repeating: 0, count: 100)
        while next < total {
            for i in chunk.indices { chunk[i] = next + Int32(i) }
            var offset = 0
            while offset < chunk.count {
                offset += chunk.withUnsafeBufferPointer { ring.write(UnsafeBufferPointer(rebasing: $0[offset...])) }
            }
            next += Int32(chunk.count)
        }
    }
    var expected: Int32 = 0
    var ok = true
    var buf = [Int32](repeating: 0, count: 256)
    while expected < total {
        let n = buf.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        for i in 0..<n where buf[i] != expected + Int32(i) { ok = false }
        expected += Int32(n)
        if n == 0 { await Task.yield() }
    }
    await producer.value
    #expect(ok)
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `swift test --filter DSPCoreTests`
Expected: compile error, `SPSCRing` not found. (SwiftPM also needs at least one source file in `Sources/DSPCore`; the next step creates it.)

- [ ] **Step 4: Implement `Sources/DSPCore/SPSCRing.swift`**

```swift
import Synchronization

/// Lock-free single-producer / single-consumer ring buffer.
/// Exactly one thread may write and exactly one thread may read at a time.
public final class SPSCRing<Element: BitwiseCopyable>: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Element>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    /// `capacity` is rounded up to a power of two.
    public init(capacity: Int, fill: Element) {
        var c = 1
        while c < capacity { c <<= 1 }
        self.capacity = c
        mask = c - 1
        storage = .allocate(capacity: c)
        storage.initialize(repeating: fill, count: c)
    }

    deinit { storage.deallocate() }

    public var availableToRead: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring)
    }

    public var availableToWrite: Int { capacity - availableToRead }

    /// Producer side. Writes as many elements as fit and returns the count written.
    @discardableResult
    public func write(_ src: UnsafeBufferPointer<Element>) -> Int {
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        let n = min(src.count, capacity - (w - r))
        guard n > 0, let base = src.baseAddress else { return 0 }
        let start = w & mask
        let first = min(n, capacity - start)
        (storage + start).update(from: base, count: first)
        if n > first { storage.update(from: base + first, count: n - first) }
        writeIndex.store(w + n, ordering: .releasing)
        return n
    }

    /// Consumer side. Reads up to `dst.count` elements and returns the count read.
    @discardableResult
    public func read(into dst: UnsafeMutableBufferPointer<Element>) -> Int {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(dst.count, w - r)
        guard n > 0, let base = dst.baseAddress else { return 0 }
        let start = r & mask
        let first = min(n, capacity - start)
        base.update(from: storage + start, count: first)
        if n > first { (base + first).update(from: storage, count: n - first) }
        readIndex.store(r + n, ordering: .releasing)
        return n
    }

    /// Consumer side: discards everything currently buffered.
    public func drain() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter DSPCoreTests`
Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/DSPCore Tests/DSPCoreTests
git commit -m "feat(dsp): add lock-free SPSC ring buffer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Windows, spectrum analyzer, averager

**Files:**
- Create: `Sources/DSPCore/Window.swift`, `Sources/DSPCore/SpectrumAnalyzer.swift`
- Test: `Tests/DSPCoreTests/TestSignals.swift`, `Tests/DSPCoreTests/SpectrumTests.swift`

**Interfaces:**
- Produces:
  - `public enum WindowKind: String, CaseIterable, Codable, Sendable { case blackmanHarris, hann, flatTop; var label: String; func coefficients(count:) -> [Float] }`
  - `public final class SpectrumAnalyzer { init(size: Int, window: WindowKind = .blackmanHarris); let size: Int; func process(_ iq: UnsafeBufferPointer<DSPComplex>, into db: UnsafeMutableBufferPointer<Float>) }`. Its output is FFT-shifted dBFS: index 0 is −fs/2 and index size/2 is DC. A unit complex tone reads 0 dB.
  - `public final class SpectrumAverager { init(size:alpha:); var alpha: Float; private(set) var average: [Float]; private(set) var peak: [Float]; func add(_: UnsafeBufferPointer<Float>); func resetPeak() }`
  - Test helper `enum TestSignals { tone(frequency:sampleRate:count:amplitude:) -> [DSPComplex]; power(of:at:sampleRate:) -> Double; dominates(_:at:sampleRate:over:by:) -> Bool; modulated(sampleRate:seconds:_:) -> [DSPComplex] }`

- [ ] **Step 1: Write the test helper and failing tests**

`Tests/DSPCoreTests/TestSignals.swift`:
```swift
import Foundation
import Accelerate
@testable import DSPCore

enum TestSignals {
    static func tone(frequency: Double, sampleRate: Double, count: Int, amplitude: Float = 1) -> [DSPComplex] {
        (0..<count).map { i in
            let p = 2 * Double.pi * frequency * Double(i) / sampleRate
            return DSPComplex(real: amplitude * Float(cos(p)), imag: amplitude * Float(sin(p)))
        }
    }

    /// Complex baseband built from an (amplitude, phase) function of time in seconds.
    static func modulated(sampleRate: Double, seconds: Double, _ f: (Double) -> (amp: Double, phase: Double)) -> [DSPComplex] {
        (0..<Int(sampleRate * seconds)).map { i in
            let (a, p) = f(Double(i) / sampleRate)
            return DSPComplex(real: Float(a * cos(p)), imag: Float(a * sin(p)))
        }
    }

    /// Goertzel power of a real signal at `frequency`, normalised by length².
    static func power(of x: ArraySlice<Float>, at frequency: Double, sampleRate: Double) -> Double {
        let c = 2 * cos(2 * Double.pi * frequency / sampleRate)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s0 = Double(v) + c * s1 - s2
            s2 = s1
            s1 = s0
        }
        return (s1 * s1 + s2 * s2 - c * s1 * s2) / Double(x.count * x.count)
    }

    static func dominates(_ x: ArraySlice<Float>, at f: Double, sampleRate: Double, over others: [Double], by ratio: Double = 10) -> Bool {
        let p = power(of: x, at: f, sampleRate: sampleRate)
        return p > 0 && others.allSatisfy { power(of: x, at: $0, sampleRate: sampleRate) * ratio < p }
    }
}
```

`Tests/DSPCoreTests/SpectrumTests.swift`:
```swift
import Testing
import Accelerate
@testable import DSPCore

private func spectrum(_ iq: [DSPComplex], size: Int) -> [Float] {
    let analyzer = SpectrumAnalyzer(size: size)
    var db = [Float](repeating: 0, count: size)
    iq.withUnsafeBufferPointer { src in db.withUnsafeMutableBufferPointer { analyzer.process(src, into: $0) } }
    return db
}

@Test func positiveToneLandsInExpectedBinAtZeroDB() {
    let n = 1024, fs = 1_000_000.0
    let db = spectrum(TestSignals.tone(frequency: fs / 8, sampleRate: fs, count: n), size: n)
    let peak = db.indices.max { db[$0] < db[$1] }!
    #expect(peak == n / 2 + n / 8)
    #expect(abs(db[peak]) < 0.5)
}

@Test func negativeToneLandsBelowDC() {
    let n = 2048, fs = 2_000_000.0
    let db = spectrum(TestSignals.tone(frequency: -fs / 4, sampleRate: fs, count: n), size: n)
    #expect(db.indices.max { db[$0] < db[$1] }! == n / 2 - n / 4)
}

@Test func windowsAreSymmetricAndPeakAtCentre() {
    for kind in WindowKind.allCases {
        let w = kind.coefficients(count: 65)
        #expect(abs(w[0] - w[64]) < 1e-6)
        #expect(w[32] == w.max())
    }
}

@Test func averagerSmoothsAndHoldsPeak() {
    let avg = SpectrumAverager(size: 2, alpha: 0.5)
    [Float(0), 0].withUnsafeBufferPointer { avg.add($0) }
    [Float(10), -10].withUnsafeBufferPointer { avg.add($0) }
    #expect(avg.average == [5, -5])
    #expect(avg.peak == [10, 0])
    avg.resetPeak()
    #expect(avg.peak == avg.average)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter DSPCoreTests`
Expected: compile errors, because `SpectrumAnalyzer`, `WindowKind` and `SpectrumAverager` are not defined.

- [ ] **Step 3: Implement `Sources/DSPCore/Window.swift`**

```swift
import Foundation

public enum WindowKind: String, CaseIterable, Codable, Sendable {
    case blackmanHarris, hann, flatTop

    public var label: String {
        switch self {
        case .blackmanHarris: "Blackman-Harris"
        case .hann: "Hann"
        case .flatTop: "Flat-top"
        }
    }

    public func coefficients(count n: Int) -> [Float] {
        let m = Double(max(n - 1, 1))
        return (0..<n).map { i in
            let x = 2 * Double.pi * Double(i) / m
            switch self {
            case .hann:
                return Float(0.5 - 0.5 * cos(x))
            case .blackmanHarris:
                return Float(0.35875 - 0.48829 * cos(x) + 0.14128 * cos(2 * x) - 0.01168 * cos(3 * x))
            case .flatTop:
                return Float(0.21557895 - 0.41663158 * cos(x) + 0.277263158 * cos(2 * x)
                             - 0.083578947 * cos(3 * x) + 0.006947368 * cos(4 * x))
            }
        }
    }
}
```

- [ ] **Step 4: Implement `Sources/DSPCore/SpectrumAnalyzer.swift`**

```swift
import Accelerate

/// Windowed complex FFT producing an FFT-shifted power spectrum in dBFS.
/// Output index 0 is −fs/2, index size/2 is DC. A unit-amplitude complex tone reads 0 dB.
public final class SpectrumAnalyzer {
    public let size: Int
    public let window: WindowKind
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let coefficients: [Float]
    private var re: [Float]
    private var im: [Float]
    private var power: [Float]
    private let normalization: Float

    public init(size: Int, window: WindowKind = .blackmanHarris) {
        precondition(size >= 16 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        self.window = window
        log2n = vDSP_Length(size.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        coefficients = window.coefficients(count: size)
        re = .init(repeating: 0, count: size)
        im = .init(repeating: 0, count: size)
        power = .init(repeating: 0, count: size)
        let sum = coefficients.reduce(0, +)
        normalization = 1 / (sum * sum)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    public func process(_ iq: UnsafeBufferPointer<DSPComplex>, into db: UnsafeMutableBufferPointer<Float>) {
        precondition(iq.count == size && db.count == size)
        let n = vDSP_Length(size)
        let half = size / 2
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                power.withUnsafeMutableBufferPointer { pp in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_ctoz(iq.baseAddress!, 2, &split, 1, n)
                    vDSP_vmul(rp.baseAddress!, 1, coefficients, 1, rp.baseAddress!, 1, n)
                    vDSP_vmul(ip.baseAddress!, 1, coefficients, 1, ip.baseAddress!, 1, n)
                    vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    vDSP_zvmags(&split, 1, pp.baseAddress!, 1, n)
                    var norm = normalization
                    vDSP_vsmul(pp.baseAddress!, 1, &norm, pp.baseAddress!, 1, n)
                    var floor: Float = 1e-20
                    vDSP_vthr(pp.baseAddress!, 1, &floor, pp.baseAddress!, 1, n)
                    var reference: Float = 1
                    vDSP_vdbcon(pp.baseAddress!, 1, &reference, pp.baseAddress!, 1, n, 0)
                    db.baseAddress!.update(from: pp.baseAddress! + half, count: half)
                    (db.baseAddress! + half).update(from: pp.baseAddress!, count: half)
                }
            }
        }
    }
}

/// Exponential averaging in the dB domain plus peak hold.
public final class SpectrumAverager {
    public var alpha: Float
    public private(set) var average: [Float]
    public private(set) var peak: [Float]
    private var primed = false

    public init(size: Int, alpha: Float = 0.5) {
        self.alpha = alpha
        average = .init(repeating: -200, count: size)
        peak = .init(repeating: -200, count: size)
    }

    public func add(_ frame: UnsafeBufferPointer<Float>) {
        precondition(frame.count == average.count)
        let n = vDSP_Length(frame.count)
        average.withUnsafeMutableBufferPointer { a in
            if !primed {
                a.baseAddress!.update(from: frame.baseAddress!, count: frame.count)
            } else {
                var c = alpha
                // a = a + c * (frame − a)
                vDSP_vintb(a.baseAddress!, 1, frame.baseAddress!, 1, &c, a.baseAddress!, 1, n)
            }
        }
        peak.withUnsafeMutableBufferPointer { p in
            if !primed {
                p.baseAddress!.update(from: frame.baseAddress!, count: frame.count)
            } else {
                vDSP_vmax(p.baseAddress!, 1, frame.baseAddress!, 1, p.baseAddress!, 1, n)
            }
        }
        primed = true
    }

    public func resetPeak() { peak = average }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter DSPCoreTests`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/DSPCore Tests/DSPCoreTests
git commit -m "feat(dsp): add windowed FFT spectrum analyzer and averager

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: NCO, FIR design, decimators, decimation plan

**Files:**
- Create: `Sources/DSPCore/NCO.swift`, `Sources/DSPCore/FIR.swift`
- Test: `Tests/DSPCoreTests/FilterTests.swift`

**Interfaces:**
- Produces:
  - `public struct NCO: Sendable { init(frequency: Double = 0, sampleRate: Double = 1); mutating func setFrequency(_ hz: Double, sampleRate: Double); mutating func mix(_ x: UnsafeMutableBufferPointer<DSPComplex>); mutating func mixReal(_ x: UnsafeBufferPointer<DSPComplex>, into output: inout [Float]) }`. Mixing multiplies by e^{+j2πft}.
  - `public enum FIRDesign { static func lowpass(taps: Int, cutoff: Double, window: WindowKind = .blackmanHarris) -> [Float]; static func tapCount(transition: Double, max: Int = 1023) -> Int }`. `cutoff` and `transition` are in cycles per sample.
  - `public final class FIRDecimator { init(taps: [Float], factor: Int); let factor: Int; func process(_ input: UnsafeBufferPointer<Float>, into output: inout [Float]) }`, which appends to `output`.
  - `public final class ComplexDecimator { init(taps: [Float], factor: Int); var factor: Int; func process(_ input: UnsafeBufferPointer<DSPComplex>, into output: inout [DSPComplex]) }`, which appends to `output`.
  - `public enum DecimationPlan { static func stages(inputRate: Double, minimumRate: Double) -> [Int] }`

- [ ] **Step 1: Write the failing tests**

`Tests/DSPCoreTests/FilterTests.swift`:
```swift
import Testing
import Foundation
import Accelerate
@testable import DSPCore

private func responseDB(_ h: [Float], at f: Double) -> Double {
    var re = 0.0, im = 0.0
    for (n, v) in h.enumerated() {
        re += Double(v) * cos(2 * .pi * f * Double(n))
        im -= Double(v) * sin(2 * .pi * f * Double(n))
    }
    return 10 * log10(re * re + im * im)
}

@Test func lowpassHasFlatPassbandAndDeepStopband() {
    let h = FIRDesign.lowpass(taps: 129, cutoff: 0.1)
    #expect(h.count == 129)
    #expect(abs(responseDB(h, at: 0)) < 0.01)
    #expect(abs(responseDB(h, at: 0.05)) < 0.1)
    #expect(responseDB(h, at: 0.2) < -60)
}

@Test func ncoShiftsToneToDC() {
    let fs = 1_000_000.0
    var x = TestSignals.tone(frequency: 100_000, sampleRate: fs, count: 4096)
    var nco = NCO(frequency: -100_000, sampleRate: fs)
    x.withUnsafeMutableBufferPointer { nco.mix($0) }
    #expect(x.allSatisfy { abs($0.real - 1) < 1e-3 && abs($0.imag) < 1e-3 })
}

@Test func decimatorIsBlockSizeIndependent() {
    let input = (0..<10_000).map { Float(sin(Double($0) * 0.0628)) + Float(sin(Double($0) * 1.9)) }
    let taps = FIRDesign.lowpass(taps: 65, cutoff: 0.1)
    var whole = [Float]()
    input.withUnsafeBufferPointer { FIRDecimator(taps: taps, factor: 4).process($0, into: &whole) }
    let chunked = FIRDecimator(taps: taps, factor: 4)
    var pieces = [Float]()
    var i = 0
    for size in [1, 7, 333, 1000, 17].cycled(until: input.count) {
        let end = min(input.count, i + size)
        input[i..<end].withUnsafeBufferPointer { chunked.process($0, into: &pieces) }
        i = end
        if i == input.count { break }
    }
    #expect(whole.count == pieces.count)
    #expect(zip(whole, pieces).allSatisfy { abs($0 - $1) < 1e-5 })
    #expect(abs(whole.count - input.count / 4) <= 16)
}

@Test func decimatorPassesLowToneAndRejectsHighTone() {
    let n = 20_000
    let low = (0..<n).map { Float(cos(2 * Double.pi * 0.01 * Double($0))) }
    let high = (0..<n).map { Float(cos(2 * Double.pi * 0.3 * Double($0))) }
    let taps = FIRDesign.lowpass(taps: 97, cutoff: 0.1)
    var outLow = [Float](), outHigh = [Float]()
    low.withUnsafeBufferPointer { FIRDecimator(taps: taps, factor: 4).process($0, into: &outLow) }
    high.withUnsafeBufferPointer { FIRDecimator(taps: taps, factor: 4).process($0, into: &outHigh) }
    #expect(abs((outLow[100..<4000].map { abs($0) }.max() ?? 0) - 1) < 0.01)
    #expect((outHigh[100..<4000].map { abs($0) }.max() ?? 1) < 0.001)
}

@Test func complexDecimatorKeepsInBandTone() {
    let fs = 1_000_000.0
    let x = TestSignals.tone(frequency: 10_000, sampleRate: fs, count: 40_000)
    let dec = ComplexDecimator(taps: FIRDesign.lowpass(taps: 129, cutoff: 0.05), factor: 8)
    var out = [DSPComplex]()
    x.withUnsafeBufferPointer { dec.process($0, into: &out) }
    #expect(abs(out.count - 5_000) <= 16)
    let mags = out[100..<4000].map { ($0.real * $0.real + $0.imag * $0.imag).squareRoot() }
    #expect(mags.allSatisfy { abs($0 - 1) < 0.01 })
}

@Test func decimationPlanStaysAboveMinimum() {
    #expect(DecimationPlan.stages(inputRate: 2_000_000, minimumRate: 24_000) == [8, 8])
    #expect(DecimationPlan.stages(inputRate: 10_000_000, minimumRate: 24_000) == [8, 8, 4])
    #expect(DecimationPlan.stages(inputRate: 2_000_000, minimumRate: 300_000) == [4])
    #expect(DecimationPlan.stages(inputRate: 48_000, minimumRate: 48_000) == [])
}

private extension Array {
    /// Repeats the array's elements until their running total reaches `limit`.
    func cycled(until limit: Int) -> [Element] where Element == Int {
        var out: [Int] = [], sum = 0, i = 0
        while sum < limit { out.append(self[i % count]); sum += self[i % count]; i += 1 }
        return out
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter DSPCoreTests`
Expected: compile errors, because `FIRDesign`, `NCO`, `FIRDecimator`, `ComplexDecimator` and `DecimationPlan` are not defined.

- [ ] **Step 3: Implement `Sources/DSPCore/NCO.swift`**

```swift
import Accelerate

/// Numerically controlled oscillator. Mixing multiplies by e^{+j2πft};
/// use a negative frequency to shift a signal at +f down to DC.
public struct NCO: Sendable {
    private var re: Float = 1
    private var im: Float = 0
    private var stepRe: Float = 1
    private var stepIm: Float = 0

    public init(frequency: Double = 0, sampleRate: Double = 1) {
        setFrequency(frequency, sampleRate: sampleRate)
    }

    public mutating func setFrequency(_ hz: Double, sampleRate: Double) {
        let w = 2 * Double.pi * hz / sampleRate
        stepRe = Float(cos(w))
        stepIm = Float(sin(w))
    }

    public mutating func mix(_ x: UnsafeMutableBufferPointer<DSPComplex>) {
        var r = re, i = im
        let sr = stepRe, si = stepIm
        for k in x.indices {
            let s = x[k]
            x[k] = DSPComplex(real: s.real * r - s.imag * i, imag: s.real * i + s.imag * r)
            let nr = r * sr - i * si
            i = r * si + i * sr
            r = nr
        }
        renormalize(r, i)
    }

    /// Appends Re{x · e^{+j2πft}} to `output`.
    public mutating func mixReal(_ x: UnsafeBufferPointer<DSPComplex>, into output: inout [Float]) {
        var r = re, i = im
        let sr = stepRe, si = stepIm
        for s in x {
            output.append(s.real * r - s.imag * i)
            let nr = r * sr - i * si
            i = r * si + i * sr
            r = nr
        }
        renormalize(r, i)
    }

    private mutating func renormalize(_ r: Float, _ i: Float) {
        let mag = (r * r + i * i).squareRoot()
        re = r / mag
        im = i / mag
    }
}
```

- [ ] **Step 4: Implement `Sources/DSPCore/FIR.swift`**

```swift
import Accelerate
import Foundation

public enum FIRDesign {
    /// Windowed-sinc low-pass with unity DC gain. `cutoff` is in cycles/sample (0…0.5).
    /// `taps` is forced odd so the filter is symmetric with integer delay.
    public static func lowpass(taps: Int, cutoff: Double, window: WindowKind = .blackmanHarris) -> [Float] {
        let n = taps | 1
        let w = window.coefficients(count: n)
        let mid = Double(n - 1) / 2
        let h = (0..<n).map { i -> Double in
            let x = Double(i) - mid
            let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
            return sinc * Double(w[i])
        }
        let sum = h.reduce(0, +)
        return h.map { Float($0 / sum) }
    }

    /// Taps for a transition band of `transition` cycles/sample (Blackman-Harris ≈ 6/N), odd, capped.
    public static func tapCount(transition: Double, max: Int = 1023) -> Int {
        Swift.min(max, Int((6.0 / transition).rounded(.up))) | 1
    }
}

/// Stateful decimating FIR for real samples, built on vDSP_desamp.
public final class FIRDecimator {
    public let factor: Int
    public let taps: [Float]
    private var buffer: [Float]
    private var filled: Int

    public init(taps: [Float], factor: Int) {
        precondition(!taps.isEmpty && factor >= 1 && taps.count >= factor)
        self.taps = taps
        self.factor = factor
        filled = taps.count - 1
        buffer = .init(repeating: 0, count: Swift.max(filled, 1))
    }

    public func process(_ input: UnsafeBufferPointer<Float>, into output: inout [Float]) {
        let p = taps.count
        let needed = filled + input.count
        if buffer.count < needed {
            buffer.append(contentsOf: repeatElement(0, count: needed - buffer.count))
        }
        let start = filled
        buffer.withUnsafeMutableBufferPointer { b in
            if let src = input.baseAddress { (b.baseAddress! + start).update(from: src, count: input.count) }
        }
        filled = needed
        let positions = filled - (p - 1)
        guard positions > 0 else { return }
        let outCount = (positions + factor - 1) / factor
        let outStart = output.count
        output.append(contentsOf: repeatElement(0, count: outCount))
        let factor = self.factor
        buffer.withUnsafeBufferPointer { b in
            taps.withUnsafeBufferPointer { t in
                output.withUnsafeMutableBufferPointer { o in
                    vDSP_desamp(b.baseAddress!, factor, t.baseAddress!, o.baseAddress! + outStart,
                                vDSP_Length(outCount), vDSP_Length(p))
                }
            }
        }
        let consumed = outCount * factor
        let remaining = filled - consumed
        buffer.withUnsafeMutableBufferPointer { b in
            memmove(b.baseAddress!, b.baseAddress! + consumed, remaining * MemoryLayout<Float>.stride)
        }
        filled = remaining
    }
}

/// Decimating FIR for complex samples (real taps applied to I and Q independently).
public final class ComplexDecimator {
    public var factor: Int { real.factor }
    private let real: FIRDecimator
    private let imag: FIRDecimator
    private var inRe: [Float] = []
    private var inIm: [Float] = []
    private var outRe: [Float] = []
    private var outIm: [Float] = []

    public init(taps: [Float], factor: Int) {
        real = FIRDecimator(taps: taps, factor: factor)
        imag = FIRDecimator(taps: taps, factor: factor)
    }

    public func process(_ input: UnsafeBufferPointer<DSPComplex>, into output: inout [DSPComplex]) {
        let n = input.count
        guard n > 0 else { return }
        if inRe.count < n {
            inRe = .init(repeating: 0, count: n)
            inIm = .init(repeating: 0, count: n)
        }
        inRe.withUnsafeMutableBufferPointer { re in
            inIm.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_ctoz(input.baseAddress!, 2, &split, 1, vDSP_Length(n))
            }
        }
        outRe.removeAll(keepingCapacity: true)
        outIm.removeAll(keepingCapacity: true)
        inRe.withUnsafeBufferPointer { real.process(UnsafeBufferPointer(rebasing: $0[0..<n]), into: &outRe) }
        inIm.withUnsafeBufferPointer { imag.process(UnsafeBufferPointer(rebasing: $0[0..<n]), into: &outIm) }
        let m = outRe.count
        guard m > 0 else { return }
        let start = output.count
        output.append(contentsOf: repeatElement(DSPComplex(real: 0, imag: 0), count: m))
        outRe.withUnsafeMutableBufferPointer { re in
            outIm.withUnsafeMutableBufferPointer { im in
                output.withUnsafeMutableBufferPointer { out in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    vDSP_ztoc(&split, 1, out.baseAddress! + start, 2, vDSP_Length(m))
                }
            }
        }
    }
}

public enum DecimationPlan {
    /// Integer stage factors (8, 4 or 2) that bring `inputRate` as low as possible while staying ≥ `minimumRate`.
    public static func stages(inputRate: Double, minimumRate: Double) -> [Int] {
        var rate = inputRate
        var out: [Int] = []
        while rate / 2 >= minimumRate {
            let f = rate / 8 >= minimumRate ? 8 : (rate / 4 >= minimumRate ? 4 : 2)
            out.append(f)
            rate /= Double(f)
        }
        return out
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter DSPCoreTests`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/DSPCore Tests/DSPCoreTests
git commit -m "feat(dsp): add NCO, FIR design and decimating filters

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 5: Demod modes, demodulators, AGC, resampler

**Files:**
- Create: `Sources/DSPCore/DemodMode.swift`, `Sources/DSPCore/Demodulators.swift`, `Sources/DSPCore/AudioProcessing.swift`
- Test: `Tests/DSPCoreTests/DemodulatorTests.swift`

**Interfaces:**
- Consumes: `NCO` (Task 4).
- Produces:
  - `public enum DemodMode: String, Codable, CaseIterable, Sendable, Identifiable { case am, nfm, wfm, usb, lsb, cw }`, with:
    - `label`, `defaultBandwidth`, `tuningStep`, `bandwidthStep`, `bandwidthRange`, `minimumChannelRate`
    - `func passbandOffset(bandwidth: Double) -> Double`. USB returns `100 + bw/2`, LSB returns `−(100 + bw/2)`, and every other mode returns 0.
  - `public protocol Demodulator: AnyObject { func demodulate(_ iq: UnsafeBufferPointer<DSPComplex>, into output: inout [Float]) }`
  - Demodulator classes:
    - `AMDemodulator()`
    - `FMDemodulator(sampleRate:deviation:deemphasisTau:)`
    - `SSBDemodulator(sampleRate:shiftHz:)`. Its output is Re{x·e^{+j2π·shift·t}}.
  - `public enum AGCSpeed: String, CaseIterable, Codable, Sendable { case off, fast, medium, slow; var label }`
  - `public struct AGC: Sendable { init(speed:sampleRate:); var speed; mutating func process(_ x: inout [Float], from start: Int) }`
  - `public struct LinearResampler: Sendable { init(inputRate:outputRate:); mutating func process(_ x: UnsafeBufferPointer<Float>, into output: inout [Float]) }`

- [ ] **Step 1: Write the failing tests**

`Tests/DSPCoreTests/DemodulatorTests.swift`:
```swift
import Testing
import Foundation
import Accelerate
@testable import DSPCore

@Test func amRecoversModulatingTone() {
    let fs = 48_000.0
    let iq = TestSignals.modulated(sampleRate: fs, seconds: 0.5) { t in (0.5 * (1 + 0.5 * cos(2 * .pi * 1000 * t)), 0) }
    var out = [Float]()
    iq.withUnsafeBufferPointer { AMDemodulator().demodulate($0, into: &out) }
    #expect(TestSignals.dominates(out[4800...], at: 1000, sampleRate: fs, over: [500, 1500, 2000]))
}

@Test func fmRecoversModulatingToneWithUnitScale() {
    let fs = 48_000.0, dev = 3_000.0, fm = 1_000.0
    let iq = TestSignals.modulated(sampleRate: fs, seconds: 0.5) { t in (1, dev / fm * sin(2 * .pi * fm * t)) }
    var out = [Float]()
    iq.withUnsafeBufferPointer { FMDemodulator(sampleRate: fs, deviation: 5_000, deemphasisTau: nil).demodulate($0, into: &out) }
    #expect(TestSignals.dominates(out[4800...], at: fm, sampleRate: fs, over: [500, 2000, 3000]))
    let peak = out[4800...].map { abs($0) }.max()!
    #expect(abs(peak - 0.6) < 0.05)   // 3 kHz deviation / 5 kHz full scale
}

@Test func ssbShiftsBasebandToneToAudio() {
    let fs = 24_000.0
    let iq = TestSignals.tone(frequency: -450, sampleRate: fs, count: 24_000)
    var out = [Float]()
    iq.withUnsafeBufferPointer { SSBDemodulator(sampleRate: fs, shiftHz: 1450).demodulate($0, into: &out) }
    #expect(TestSignals.dominates(out[2400...], at: 1000, sampleRate: fs, over: [450, 1450, 1900]))
}

@Test func resamplerProducesExpectedCountAndKeepsTone() {
    var r = LinearResampler(inputRate: 31_250, outputRate: 48_000)
    let x = (0..<31_250).map { Float(sin(2 * Double.pi * 440 * Double($0) / 31_250)) }
    var out = [Float]()
    for chunk in stride(from: 0, to: x.count, by: 1000) {
        x[chunk..<min(chunk + 1000, x.count)].withUnsafeBufferPointer { r.process($0, into: &out) }
    }
    #expect(abs(out.count - 48_000) <= 2)
    #expect(TestSignals.dominates(out[1000...], at: 440, sampleRate: 48_000, over: [220, 880, 1500]))
}

@Test func agcBringsQuietSignalToTarget() {
    var agc = AGC(speed: .fast, sampleRate: 48_000)
    var x = (0..<48_000).map { Float(0.001 * sin(2 * Double.pi * 700 * Double($0) / 48_000)) }
    agc.process(&x, from: 0)
    let peak = x[24_000...].map { abs($0) }.max()!
    #expect(peak > 0.15 && peak < 0.4)
}

@Test func ssbPassbandOffsets() {
    #expect(DemodMode.usb.passbandOffset(bandwidth: 2_700) == 1_450)
    #expect(DemodMode.lsb.passbandOffset(bandwidth: 2_700) == -1_450)
    #expect(DemodMode.cw.passbandOffset(bandwidth: 500) == 0)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter DSPCoreTests`
Expected: compile errors, because the new types are not defined.

- [ ] **Step 3: Implement `Sources/DSPCore/DemodMode.swift`**

```swift
public enum DemodMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case am, nfm, wfm, usb, lsb, cw

    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }

    public var defaultBandwidth: Double {
        switch self {
        case .am: 8_000
        case .nfm: 12_500
        case .wfm: 180_000
        case .usb, .lsb: 2_700
        case .cw: 500
        }
    }

    public var tuningStep: Double {
        switch self {
        case .am: 5_000
        case .nfm: 12_500
        case .wfm: 100_000
        case .usb, .lsb: 100
        case .cw: 10
        }
    }

    public var bandwidthStep: Double {
        switch self {
        case .am: 1_000
        case .nfm: 2_500
        case .wfm: 10_000
        case .usb, .lsb: 100
        case .cw: 50
        }
    }

    public var bandwidthRange: ClosedRange<Double> {
        switch self {
        case .am: 2_000...20_000
        case .nfm: 5_000...25_000
        case .wfm: 50_000...250_000
        case .usb, .lsb: 500...5_000
        case .cw: 50...3_000
        }
    }

    /// Lowest complex channel rate the receiver may decimate to for this mode.
    public var minimumChannelRate: Double { self == .wfm ? 300_000 : 24_000 }

    /// Offset from the VFO to the centre of the passband. SSB passbands start 100 Hz from the carrier.
    public func passbandOffset(bandwidth: Double) -> Double {
        switch self {
        case .usb: 100 + bandwidth / 2
        case .lsb: -(100 + bandwidth / 2)
        default: 0
        }
    }
}
```

- [ ] **Step 4: Implement `Sources/DSPCore/Demodulators.swift`**

```swift
import Accelerate
import Foundation

public protocol Demodulator: AnyObject {
    /// Converts channel-rate complex samples into real audio at the same rate, appending to `output`.
    func demodulate(_ iq: UnsafeBufferPointer<DSPComplex>, into output: inout [Float])
}

/// Envelope detector with a DC-blocking high-pass.
public final class AMDemodulator: Demodulator {
    private var previousIn: Float = 0
    private var previousOut: Float = 0

    public init() {}

    public func demodulate(_ iq: UnsafeBufferPointer<DSPComplex>, into output: inout [Float]) {
        for s in iq {
            let m = (s.real * s.real + s.imag * s.imag).squareRoot()
            let y = m - previousIn + 0.999 * previousOut
            previousIn = m
            previousOut = y
            output.append(y)
        }
    }
}

/// Quadrature discriminator. Output 1.0 corresponds to `deviation` Hz.
public final class FMDemodulator: Demodulator {
    private let scale: Float
    private let deemphasis: Float?
    private var previous = DSPComplex(real: 1, imag: 0)
    private var deemphasisState: Float = 0

    public init(sampleRate: Double, deviation: Double, deemphasisTau: Double?) {
        scale = Float(sampleRate / (2 * .pi * deviation))
        deemphasis = deemphasisTau.map { Float(exp(-1 / (sampleRate * $0))) }
    }

    public func demodulate(_ iq: UnsafeBufferPointer<DSPComplex>, into output: inout [Float]) {
        for s in iq {
            let re = s.real * previous.real + s.imag * previous.imag
            let im = s.imag * previous.real - s.real * previous.imag
            previous = s
            var y = atan2(im, re) * scale
            if let a = deemphasis {
                deemphasisState = a * deemphasisState + (1 - a) * y
                y = deemphasisState
            }
            output.append(y)
        }
    }
}

/// SSB / CW product detector: Re{x · e^{+j2π·shift·t}}.
public final class SSBDemodulator: Demodulator {
    private var nco: NCO

    public init(sampleRate: Double, shiftHz: Double) {
        nco = NCO(frequency: shiftHz, sampleRate: sampleRate)
    }

    public func demodulate(_ iq: UnsafeBufferPointer<DSPComplex>, into output: inout [Float]) {
        nco.mixReal(iq, into: &output)
    }
}
```

- [ ] **Step 5: Implement `Sources/DSPCore/AudioProcessing.swift`**

```swift
import Foundation

public enum AGCSpeed: String, CaseIterable, Codable, Sendable {
    case off, fast, medium, slow

    public var label: String { rawValue.capitalized }

    var decaySeconds: Double? {
        switch self {
        case .off: nil
        case .fast: 0.1
        case .medium: 0.5
        case .slow: 2.0
        }
    }
}

/// Peak-envelope audio AGC. With `.off` a fixed ×10 gain is applied.
public struct AGC: Sendable {
    public var speed: AGCSpeed {
        didSet { configure() }
    }
    public var target: Float = 0.25
    public var maxGain: Float = 10_000
    private let sampleRate: Double
    private var envelope: Float = 1e-4
    private var attack: Float = 0
    private var decay: Float = 0

    public init(speed: AGCSpeed, sampleRate: Double) {
        self.speed = speed
        self.sampleRate = sampleRate
        configure()
    }

    private mutating func configure() {
        attack = Float(1 - exp(-1 / (0.002 * sampleRate)))
        decay = Float(exp(-1 / ((speed.decaySeconds ?? 1) * sampleRate)))
    }

    public mutating func process(_ x: inout [Float], from start: Int) {
        guard start < x.count else { return }
        guard speed != .off else {
            for k in start..<x.count { x[k] *= 10 }
            return
        }
        var env = envelope
        for k in start..<x.count {
            let a = abs(x[k])
            env = a > env ? env + attack * (a - env) : env * decay
            x[k] *= min(maxGain, target / max(env, 1e-9))
        }
        envelope = env
    }
}

/// Streaming linear-interpolation resampler for band-limited audio.
public struct LinearResampler: Sendable {
    public let step: Double
    private var position: Double = 0
    private var previous: Float = 0

    public init(inputRate: Double, outputRate: Double) {
        step = inputRate / outputRate
    }

    public mutating func process(_ x: UnsafeBufferPointer<Float>, into output: inout [Float]) {
        let n = x.count
        guard n > 0 else { return }
        var pos = position
        while pos < Double(n) {
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let a = idx == 0 ? previous : x[idx - 1]
            output.append(a + (x[idx] - a) * frac)
            pos += step
        }
        position = pos - Double(n)
        previous = x[n - 1]
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter DSPCoreTests`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/DSPCore Tests/DSPCoreTests
git commit -m "feat(dsp): add AM/FM/SSB demodulators, AGC and resampler

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Receiver chain

**Files:**
- Create: `Sources/DSPCore/Receiver.swift`
- Test: `Tests/DSPCoreTests/ReceiverTests.swift`

**Interfaces:**
- Consumes: `NCO`, `FIRDesign`, `ComplexDecimator`, `FIRDecimator`, `DecimationPlan`, the demodulators, `AGC`, `LinearResampler`, `DemodMode`.
- Produces:
```swift
public final class Receiver: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public var inputRate: Double; public var offsetHz: Double; public var mode: DemodMode
        public var bandwidthHz: Double; public var cwPitchHz: Double; public var squelchDb: Float?; public var agc: AGCSpeed
        public init(inputRate: Double, offsetHz: Double, mode: DemodMode, bandwidthHz: Double,
                    cwPitchHz: Double = 700, squelchDb: Float? = nil, agc: AGCSpeed = .medium)
    }
    public static let audioRate: Double            // 48_000
    public private(set) var config: Config
    public private(set) var channelRate: Double
    public private(set) var signalDb: Float         // channel power, dBFS
    public var channelTap: ((UnsafeBufferPointer<DSPComplex>, Double) -> Void)?   // channel IQ + rate, for IQ modems
    public init(config: Config)
    public func update(_ config: Config)
    public func process(_ input: UnsafeBufferPointer<DSPComplex>, audio: inout [Float])   // appends 48 kHz audio
}
```

- [ ] **Step 1: Write the failing tests**

`Tests/DSPCoreTests/ReceiverTests.swift`:
```swift
import Testing
import Foundation
import Accelerate
@testable import DSPCore

private let fs = 2_000_000.0

private func run(_ config: Receiver.Config, _ iq: [DSPComplex]) -> [Float] {
    let rx = Receiver(config: config)
    var audio = [Float]()
    var i = 0
    while i < iq.count {     // realistic 10 ms blocks
        let end = min(iq.count, i + 20_000)
        iq[i..<end].withUnsafeBufferPointer { rx.process($0, audio: &audio) }
        i = end
    }
    return audio
}

private func config(_ mode: DemodMode, offset: Double = 50_000) -> Receiver.Config {
    Receiver.Config(inputRate: fs, offsetHz: offset, mode: mode, bandwidthHz: mode.defaultBandwidth)
}

@Test func outputRateIs48k() {
    let audio = run(config(.am), [DSPComplex](repeating: DSPComplex(real: 0.1, imag: 0), count: Int(fs)))
    #expect(abs(audio.count - 48_000) < 300)
}

@Test func amChannel() {
    let iq = TestSignals.modulated(sampleRate: fs, seconds: 0.5) { t in
        (0.5 * (1 + 0.5 * cos(2 * .pi * 1_000 * t)), 2 * .pi * 50_000 * t)
    }
    let audio = run(config(.am), iq)
    #expect(TestSignals.dominates(audio[4_800...], at: 1_000, sampleRate: 48_000, over: [500, 1_500, 2_000, 3_000]))
}

@Test func nfmChannel() {
    let iq = TestSignals.modulated(sampleRate: fs, seconds: 0.5) { t in
        (0.5, 2 * .pi * 50_000 * t + 3_000 / 1_000 * sin(2 * .pi * 1_000 * t))
    }
    let audio = run(config(.nfm), iq)
    #expect(TestSignals.dominates(audio[4_800...], at: 1_000, sampleRate: 48_000, over: [500, 2_000, 3_000]))
}

@Test func wfmChannel() {
    let iq = TestSignals.modulated(sampleRate: fs, seconds: 0.5) { t in
        (0.5, 2 * .pi * 200_000 * t + 50_000 / 1_000 * sin(2 * .pi * 1_000 * t))
    }
    let audio = run(config(.wfm, offset: 200_000), iq)
    #expect(TestSignals.dominates(audio[4_800...], at: 1_000, sampleRate: 48_000, over: [500, 2_000, 3_000]))
}

@Test func usbChannel() {
    let iq = TestSignals.tone(frequency: 51_000, sampleRate: fs, count: Int(fs / 2), amplitude: 0.1)
    let audio = run(config(.usb), iq)
    #expect(TestSignals.dominates(audio[4_800...], at: 1_000, sampleRate: 48_000, over: [450, 1_450, 2_000]))
}

@Test func lsbChannelRejectsUpperSideband() {
    let lower = run(config(.lsb), TestSignals.tone(frequency: 49_000, sampleRate: fs, count: Int(fs / 2), amplitude: 0.1))
    #expect(TestSignals.dominates(lower[4_800...], at: 1_000, sampleRate: 48_000, over: [450, 1_450, 2_000]))
    // A tone on the wrong sideband must be far weaker than the right one (AGC disabled to compare levels).
    var c = config(.lsb); c.agc = .off
    let right = run(c, TestSignals.tone(frequency: 49_000, sampleRate: fs, count: Int(fs / 2), amplitude: 0.1))
    let wrong = run(c, TestSignals.tone(frequency: 51_000, sampleRate: fs, count: Int(fs / 2), amplitude: 0.1))
    let pr = TestSignals.power(of: right[4_800...], at: 1_000, sampleRate: 48_000)
    let pw = TestSignals.power(of: wrong[4_800...], at: 1_000, sampleRate: 48_000)
    #expect(pw * 1_000 < pr)
}

@Test func cwCarrierBecomesPitchTone() {
    let iq = TestSignals.tone(frequency: 50_000, sampleRate: fs, count: Int(fs / 2), amplitude: 0.1)
    let audio = run(config(.cw), iq)
    #expect(TestSignals.dominates(audio[4_800...], at: 700, sampleRate: 48_000, over: [350, 1_000, 1_400]))
}

@Test func squelchMutesSilence() {
    var c = config(.nfm); c.squelchDb = -60
    let audio = run(c, [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: 200_000))
    #expect(!audio.isEmpty && audio.allSatisfy { $0 == 0 })
}

@Test func retuningOffsetDoesNotRebuildChain() {
    let rx = Receiver(config: config(.usb))
    let rate = rx.channelRate
    var c = rx.config; c.offsetHz = 10_000
    rx.update(c)
    #expect(rx.channelRate == rate && rx.config.offsetHz == 10_000)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ReceiverTests`
Expected: compile error, because `Receiver` is not defined.

- [ ] **Step 3: Implement `Sources/DSPCore/Receiver.swift`**

```swift
import Accelerate
import Foundation

/// One demodulated channel: NCO → decimating stages → channel filter → demod → audio filter → 48 kHz → AGC → squelch.
public final class Receiver: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        public var inputRate: Double
        public var offsetHz: Double
        public var mode: DemodMode
        public var bandwidthHz: Double
        public var cwPitchHz: Double
        public var squelchDb: Float?
        public var agc: AGCSpeed

        public init(inputRate: Double, offsetHz: Double, mode: DemodMode, bandwidthHz: Double,
                    cwPitchHz: Double = 700, squelchDb: Float? = nil, agc: AGCSpeed = .medium) {
            self.inputRate = inputRate
            self.offsetHz = offsetHz
            self.mode = mode
            self.bandwidthHz = bandwidthHz
            self.cwPitchHz = cwPitchHz
            self.squelchDb = squelchDb
            self.agc = agc
        }
    }

    public static let audioRate = 48_000.0

    public private(set) var config: Config
    public private(set) var channelRate: Double = 0
    public private(set) var signalDb: Float = -200
    public var channelTap: ((UnsafeBufferPointer<DSPComplex>, Double) -> Void)?

    private var nco = NCO()
    private var stages: [ComplexDecimator] = []
    private var channelFilter = ComplexDecimator(taps: [1], factor: 1)
    private var demod: any Demodulator = AMDemodulator()
    private var audioFilter = FIRDecimator(taps: [1], factor: 1)
    private var resampler = LinearResampler(inputRate: 48_000, outputRate: 48_000)
    private var agc = AGC(speed: .medium, sampleRate: 48_000)
    private var squelchOpen = true
    private var work: [DSPComplex] = []
    private var work2: [DSPComplex] = []
    private var demodOut: [Float] = []
    private var filtered: [Float] = []

    public init(config: Config) {
        self.config = config
        rebuild()
    }

    public func update(_ new: Config) {
        let rebuildNeeded = new.inputRate != config.inputRate || new.mode != config.mode
            || new.bandwidthHz != config.bandwidthHz || new.cwPitchHz != config.cwPitchHz
        config = new
        if rebuildNeeded {
            rebuild()
        } else {
            retune()
            agc.speed = new.agc
        }
    }

    private func retune() {
        let shift = config.offsetHz + config.mode.passbandOffset(bandwidth: config.bandwidthHz)
        nco.setFrequency(-shift, sampleRate: config.inputRate)
    }

    private func rebuild() {
        let mode = config.mode
        let bw = config.bandwidthHz
        let minimumRate = max(mode.minimumChannelRate, bw * (mode == .wfm ? 1.25 : 3))
        var rate = config.inputRate
        stages = DecimationPlan.stages(inputRate: rate, minimumRate: minimumRate).map { f in
            let df = Double(f)
            rate /= df
            let taps = FIRDesign.lowpass(taps: FIRDesign.tapCount(transition: 0.38 / df, max: 255), cutoff: 0.45 / df)
            return ComplexDecimator(taps: taps, factor: f)
        }
        channelRate = rate

        let half = bw / 2
        let channelTaps = FIRDesign.lowpass(
            taps: FIRDesign.tapCount(transition: max(half * 0.25, 200) / rate, max: 511),
            cutoff: half / rate)
        channelFilter = ComplexDecimator(taps: channelTaps, factor: 1)

        var audioCutoff: Double
        switch mode {
        case .am:
            demod = AMDemodulator()
            audioCutoff = half
        case .nfm:
            demod = FMDemodulator(sampleRate: rate, deviation: 5_000, deemphasisTau: nil)
            audioCutoff = 4_000
        case .wfm:
            demod = FMDemodulator(sampleRate: rate, deviation: 75_000, deemphasisTau: 75e-6)
            audioCutoff = 15_000
        case .usb, .lsb:
            let shift = mode.passbandOffset(bandwidth: bw)
            demod = SSBDemodulator(sampleRate: rate, shiftHz: shift)
            audioCutoff = abs(shift) + half
        case .cw:
            demod = SSBDemodulator(sampleRate: rate, shiftHz: config.cwPitchHz)
            audioCutoff = config.cwPitchHz + half
        }
        audioCutoff = min(audioCutoff, 20_000)
        let audioFactor = max(1, Int(rate / Self.audioRate))
        let audioTaps = FIRDesign.lowpass(
            taps: max(FIRDesign.tapCount(transition: max(500, audioCutoff * 0.2) / rate, max: 511), audioFactor | 1),
            cutoff: audioCutoff / rate)
        audioFilter = FIRDecimator(taps: audioTaps, factor: audioFactor)
        resampler = LinearResampler(inputRate: rate / Double(audioFactor), outputRate: Self.audioRate)
        agc = AGC(speed: config.agc, sampleRate: Self.audioRate)
        squelchOpen = true
        retune()
    }

    public func process(_ input: UnsafeBufferPointer<DSPComplex>, audio: inout [Float]) {
        work.removeAll(keepingCapacity: true)
        work.append(contentsOf: input)
        work.withUnsafeMutableBufferPointer { nco.mix($0) }
        for stage in stages {
            work2.removeAll(keepingCapacity: true)
            work.withUnsafeBufferPointer { stage.process($0, into: &work2) }
            swap(&work, &work2)
        }
        work2.removeAll(keepingCapacity: true)
        work.withUnsafeBufferPointer { channelFilter.process($0, into: &work2) }
        guard !work2.isEmpty else { return }

        work2.withUnsafeBufferPointer { channel in
            var meanSquare: Float = 0
            channel.withMemoryRebound(to: Float.self) { floats in
                vDSP_measqv(floats.baseAddress!, 1, &meanSquare, vDSP_Length(floats.count))
            }
            signalDb = 10 * log10(max(2 * meanSquare, 1e-20))
            channelTap?(channel, channelRate)
        }
        if let threshold = config.squelchDb {
            squelchOpen = squelchOpen ? signalDb > threshold - 2 : signalDb > threshold
        } else {
            squelchOpen = true
        }

        demodOut.removeAll(keepingCapacity: true)
        work2.withUnsafeBufferPointer { demod.demodulate($0, into: &demodOut) }
        filtered.removeAll(keepingCapacity: true)
        demodOut.withUnsafeBufferPointer { audioFilter.process($0, into: &filtered) }
        let start = audio.count
        filtered.withUnsafeBufferPointer { resampler.process($0, into: &audio) }
        agc.process(&audio, from: start)
        if !squelchOpen {
            for k in start..<audio.count { audio[k] = 0 }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ReceiverTests`
Expected: 9 tests pass. If the LSB rejection test fails narrowly, check that the NCO sign in `retune()` is `-(offset + passbandOffset)`. Do not loosen the 30 dB ratio.

- [ ] **Step 5: Commit**

```bash
git add Sources/DSPCore/Receiver.swift Tests/DSPCoreTests/ReceiverTests.swift
git commit -m "feat(dsp): add receiver channel chain with squelch and AGC

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: IQ sources and Morse code

**Files:**
- Create: `Sources/DSPCore/IQSource.swift`, `Sources/DSPCore/MorseCode.swift`, `Sources/DSPCore/SyntheticSource.swift`, `Sources/DSPCore/IQFileSource.swift`
- Test: `Tests/DSPCoreTests/SourceTests.swift`

**Interfaces:**
- Consumes: `SpectrumAnalyzer` (tests only).
- Produces:
  - IQ source protocol:
    ```swift
    public protocol IQSource: AnyObject, Sendable {
        var name: String { get }
        var sampleRate: Double { get }
        var centerFrequency: Double { get }
        func start(_ handler: @escaping @Sendable (UnsafeBufferPointer<DSPComplex>) -> Void) throws
        func stop()
        func setCenterFrequency(_ hz: Double) throws
    }
    ```
  - `public enum MorseCode`, with:
    - `static let table: [Character: String]`
    - `static let reverse: [String: Character]`
    - `static func timeline(for: String) -> [MorseCode.Element]`, where `Element { on: Bool; units: Int }`
    - `static func dotSeconds(wpm:) -> Double`
  - `public final class SyntheticSource: IQSource, @unchecked Sendable`, with:
    - `init(sampleRate: Double = 2_000_000, centerFrequency: Double = 14_100_000, signals: [Signal] = demoSignals)`
    - `var antennaOffset: Double`
    - `func setSampleRate(_:)`
    - internal `func makeBlock(count: Int) -> [DSPComplex]`
    - `Signal { frequency, amplitude, kind }`, with `Kind` one of `.carrier`, `.am(toneHz:)`, `.fm(toneHz:deviation:)`, `.ssbTone(audioHz:)` or `.cw(text:wpm:)`
    - `static let demoSignals`
  - `public final class IQFileSource: IQSource, @unchecked Sendable { init(url: URL, centerFrequency: Double) throws; static func parseWAVHeader(_ data: Data) throws -> WAVLayout }`
  - `public enum IQFileError: Error { case notWAV, unsupported(String) }`

- [ ] **Step 1: Write the failing tests**

`Tests/DSPCoreTests/SourceTests.swift`:
```swift
import Testing
import Foundation
import Accelerate
@testable import DSPCore

@Test func morseTimelineUsesParisTiming() {
    let t = MorseCode.timeline(for: "E T")
    #expect(t.map(\.on) == [true, false, true])
    #expect(t.map(\.units) == [1, 7, 3])
    #expect(MorseCode.reverse[".-"] == "A")
    #expect(abs(MorseCode.dotSeconds(wpm: 20) - 0.06) < 1e-9)
}

@Test func syntheticCarrierAppearsAtOffset() {
    let source = SyntheticSource(sampleRate: 1_024_000, centerFrequency: 10_000_000,
                                 signals: [.init(frequency: 10_128_000, amplitude: 0.5, kind: .carrier)])
    source.noiseAmplitude = 0
    let block = source.makeBlock(count: 1024)
    let analyzer = SpectrumAnalyzer(size: 1024)
    var db = [Float](repeating: 0, count: 1024)
    block.withUnsafeBufferPointer { b in db.withUnsafeMutableBufferPointer { analyzer.process(b, into: $0) } }
    #expect(db.indices.max { db[$0] < db[$1] }! == 512 + 128)
}

@Test func syntheticAntennaOffsetModelsUpconverter() {
    let source = SyntheticSource(sampleRate: 1_024_000, centerFrequency: 135_000_000,
                                 signals: [.init(frequency: 10_128_000, amplitude: 0.5, kind: .carrier)])
    source.noiseAmplitude = 0
    source.antennaOffset = 125_000_000
    let block = source.makeBlock(count: 1024)
    #expect(block.contains { abs($0.real) > 0.1 })
}

@Test func wavHeaderAndSamplesParse() throws {
    let frames = 1000
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * 4))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(250_000); u32(250_000 * 4); u16(4); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * 4))
    for i in 0..<frames { u16(UInt16(bitPattern: Int16(i))); u16(UInt16(bitPattern: Int16(-i))) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("subfloor-test-\(UUID()).wav")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let source = try IQFileSource(url: url, centerFrequency: 7_100_000)
    #expect(source.sampleRate == 250_000)
    #expect(source.frameCount == frames)
    let block = source.readFrames(at: 10, count: 2)
    #expect(abs(block[0].real - 10 / 32768) < 1e-7 && abs(block[0].imag + 10 / 32768) < 1e-7)
}

@Test func wavRejectsGarbage() {
    #expect(throws: IQFileError.self) { try IQFileSource.parseWAVHeader(Data("not a wav file at all....".utf8)) }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter SourceTests`
Expected: compile errors.

- [ ] **Step 3: Implement `Sources/DSPCore/IQSource.swift`**

```swift
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
```

- [ ] **Step 4: Implement `Sources/DSPCore/MorseCode.swift`**

```swift
public enum MorseCode {
    public struct Element: Equatable, Sendable {
        public let on: Bool
        public let units: Int
    }

    public static let table: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.", "G": "--.", "H": "....",
        "I": "..", "J": ".---", "K": "-.-", "L": ".-..", "M": "--", "N": "-.", "O": "---", "P": ".--.",
        "Q": "--.-", "R": ".-.", "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-",
        "Y": "-.--", "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-", "5": ".....",
        "6": "-....", "7": "--...", "8": "---..", "9": "----.",
        ".": ".-.-.-", ",": "--..--", "?": "..--..", "/": "-..-.", "=": "-...-", "+": ".-.-.", "-": "-....-",
    ]

    public static let reverse: [String: Character] = Dictionary(uniqueKeysWithValues: table.map { ($1, $0) })

    /// PARIS-timed key timeline: dit 1, dah 3, element gap 1, character gap 3, word gap 7.
    public static func timeline(for text: String) -> [Element] {
        var out: [Element] = []
        for (wi, word) in text.uppercased().split(separator: " ").enumerated() {
            if wi > 0 { out.append(Element(on: false, units: 7)) }
            for (ci, ch) in word.enumerated() {
                guard let code = table[ch] else { continue }
                if ci > 0 { out.append(Element(on: false, units: 3)) }
                for (ei, e) in code.enumerated() {
                    if ei > 0 { out.append(Element(on: false, units: 1)) }
                    out.append(Element(on: true, units: e == "." ? 1 : 3))
                }
            }
        }
        return out
    }

    public static func dotSeconds(wpm: Double) -> Double { 1.2 / wpm }
}
```

- [ ] **Step 5: Implement `Sources/DSPCore/SyntheticSource.swift`**

```swift
import Accelerate
import Foundation

/// Generates a band of test signals in real time, so the app works without hardware.
/// Signal frequencies are antenna frequencies; `antennaOffset` models an upconverter LO.
public final class SyntheticSource: IQSource, @unchecked Sendable {
    public struct Signal: Sendable {
        public enum Kind: Sendable {
            case carrier
            case am(toneHz: Double)
            case fm(toneHz: Double, deviation: Double)
            case ssbTone(audioHz: Double)
            case cw(text: String, wpm: Double)
        }
        public var frequency: Double
        public var amplitude: Float
        public var kind: Kind
        public init(frequency: Double, amplitude: Float, kind: Kind) {
            self.frequency = frequency
            self.amplitude = amplitude
            self.kind = kind
        }
    }

    public static let demoSignals: [Signal] = [
        .init(frequency: 14_030_000, amplitude: 0.02, kind: .cw(text: "CQ CQ DE SUBFLOOR K", wpm: 20)),
        .init(frequency: 14_074_000 + 1_500, amplitude: 0.004, kind: .carrier),
        .init(frequency: 14_200_000, amplitude: 0.01, kind: .ssbTone(audioHz: 1_000)),
        .init(frequency: 13_650_000, amplitude: 0.05, kind: .am(toneHz: 600)),
        .init(frequency: 14_500_000, amplitude: 0.02, kind: .fm(toneHz: 1_000, deviation: 3_000)),
        .init(frequency: 10_000_000, amplitude: 0.05, kind: .am(toneHz: 1_000)),
        .init(frequency: 7_200_000, amplitude: 0.01, kind: .ssbTone(audioHz: -800)),
        .init(frequency: 144_390_000, amplitude: 0.03, kind: .fm(toneHz: 1_200, deviation: 3_500)),
        .init(frequency: 98_100_000, amplitude: 0.1, kind: .fm(toneHz: 440, deviation: 60_000)),
    ]

    public let name = "Demo signal"
    public var noiseAmplitude: Float = 0.001
    public var antennaOffset: Double {
        get { lock.withLock { _antennaOffset } }
        set { lock.withLock { _antennaOffset = newValue } }
    }
    public var sampleRate: Double { lock.withLock { _sampleRate } }
    public var centerFrequency: Double { lock.withLock { _center } }

    private let signals: [Signal]
    private let lock = NSLock()
    private var _sampleRate: Double
    private var _center: Double
    private var _antennaOffset: Double = 0
    private let queue = DispatchQueue(label: "subfloor.synthetic", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var sampleIndex = 0
    private var phases: [Double]
    private var envelopes: [Float]
    private var keyPatterns: [[Bool]]
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15

    public init(sampleRate: Double = 2_000_000, centerFrequency: Double = 14_100_000, signals: [Signal] = demoSignals) {
        _sampleRate = sampleRate
        _center = centerFrequency
        self.signals = signals
        phases = .init(repeating: 0, count: signals.count)
        envelopes = .init(repeating: 0, count: signals.count)
        keyPatterns = signals.map { signal in
            guard case .cw(let text, _) = signal.kind else { return [] }
            var units: [Bool] = []
            for e in MorseCode.timeline(for: text) { units += Array(repeating: e.on, count: e.units) }
            return units + Array(repeating: false, count: 21)   // 3-word gap before repeating
        }
    }

    public func setSampleRate(_ hz: Double) { lock.withLock { _sampleRate = hz } }
    public func setCenterFrequency(_ hz: Double) throws { lock.withLock { _center = hz } }

    public func start(_ handler: @escaping @Sendable (UnsafeBufferPointer<DSPComplex>) -> Void) throws {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [unowned self] in
            let block = makeBlock(count: Int(sampleRate / 100))
            block.withUnsafeBufferPointer { handler($0) }
        }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func noise() -> Float {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        let a = Float(rng & 0xFFFF) / 65_535
        let b = Float((rng >> 16) & 0xFFFF) / 65_535
        return (a + b - 1) * noiseAmplitude
    }

    func makeBlock(count: Int) -> [DSPComplex] {
        let (fs, center) = lock.withLock { (_sampleRate, _center - _antennaOffset) }
        var block = (0..<count).map { _ in DSPComplex(real: noise(), imag: noise()) }
        for (si, signal) in signals.enumerated() {
            let offset = signal.frequency - center
            guard abs(offset) < fs / 2 else { continue }
            let w = 2 * Double.pi * offset / fs
            var phase = phases[si]
            var env = envelopes[si]
            for k in 0..<count {
                let t = Double(sampleIndex + k) / fs
                var amp = signal.amplitude
                var ph = phase
                switch signal.kind {
                case .carrier:
                    break
                case .am(let tone):
                    amp *= Float(1 + 0.6 * sin(2 * .pi * tone * t))
                case .fm(let tone, let deviation):
                    ph += deviation / tone * sin(2 * .pi * tone * t)
                case .ssbTone(let audio):
                    ph += 2 * .pi * audio * t
                case .cw(_, let wpm):
                    let pattern = keyPatterns[si]
                    let unit = Int(t / MorseCode.dotSeconds(wpm: wpm)) % pattern.count
                    env += ((pattern[unit] ? 1 : 0) - env) * 0.002
                    amp *= env
                }
                block[k].real += amp * Float(cos(ph))
                block[k].imag += amp * Float(sin(ph))
                phase += w
            }
            phases[si] = phase.truncatingRemainder(dividingBy: 2 * .pi)
            envelopes[si] = env
        }
        sampleIndex += count
        return block
    }
}
```

- [ ] **Step 6: Implement `Sources/DSPCore/IQFileSource.swift`**

```swift
import Accelerate
import Foundation

public enum IQFileError: Error, CustomStringConvertible {
    case notWAV
    case unsupported(String)
    public var description: String {
        switch self {
        case .notWAV: "Not a WAV file"
        case .unsupported(let why): "Unsupported WAV: \(why)"
        }
    }
}

/// Loops a stereo (I/Q) WAV recording in real time. 16-bit PCM and 32-bit float are supported.
public final class IQFileSource: IQSource, @unchecked Sendable {
    public struct WAVLayout: Equatable, Sendable {
        public var sampleRate: Double
        public var isFloat: Bool
        public var dataOffset: Int
        public var dataLength: Int
        public var bytesPerFrame: Int { isFloat ? 8 : 4 }
    }

    public let name: String
    public let sampleRate: Double
    public let centerFrequency: Double
    public var frameCount: Int { layout.dataLength / layout.bytesPerFrame }

    private let data: Data
    private let layout: WAVLayout
    private let queue = DispatchQueue(label: "subfloor.iqfile", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var position = 0

    public init(url: URL, centerFrequency: Double) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        layout = try Self.parseWAVHeader(data)
        sampleRate = layout.sampleRate
        self.centerFrequency = centerFrequency
        name = url.lastPathComponent
    }

    public static func parseWAVHeader(_ data: Data) throws -> WAVLayout {
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }.littleEndian }
        func u16(_ o: Int) -> UInt16 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) }.littleEndian }
        func tag(_ o: Int) -> String { String(decoding: data[data.startIndex + o ..< data.startIndex + o + 4], as: UTF8.self) }
        guard data.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw IQFileError.notWAV }
        var offset = 12
        var format: (rate: Double, isFloat: Bool)?
        while offset + 8 <= data.count {
            let id = tag(offset)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            if id == "fmt " {
                var audioFormat = u16(body)
                if audioFormat == 0xFFFE { audioFormat = u16(body + 24) }
                let channels = u16(body + 2)
                let bits = u16(body + 14)
                guard channels == 2 else { throw IQFileError.unsupported("\(channels) channels (need 2: I and Q)") }
                switch (audioFormat, bits) {
                case (1, 16): format = (Double(u32(body + 4)), false)
                case (3, 32): format = (Double(u32(body + 4)), true)
                default: throw IQFileError.unsupported("format \(audioFormat), \(bits)-bit")
                }
            } else if id == "data" {
                guard let format else { throw IQFileError.unsupported("data before fmt chunk") }
                return WAVLayout(sampleRate: format.rate, isFloat: format.isFloat,
                                 dataOffset: body, dataLength: min(size, data.count - body))
            }
            offset = body + size + (size & 1)
        }
        throw IQFileError.notWAV
    }

    func readFrames(at frame: Int, count: Int) -> [DSPComplex] {
        var out = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: count)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress! + layout.dataOffset + frame * layout.bytesPerFrame
            out.withUnsafeMutableBufferPointer { o in
                o.withMemoryRebound(to: Float.self) { floats in
                    if layout.isFloat {
                        floats.baseAddress!.update(from: base.assumingMemoryBound(to: Float.self), count: count * 2)
                    } else {
                        vDSP_vflt16(base.assumingMemoryBound(to: Int16.self), 1, floats.baseAddress!, 1, vDSP_Length(count * 2))
                        var scale: Float = 1 / 32_768
                        vDSP_vsmul(floats.baseAddress!, 1, &scale, floats.baseAddress!, 1, vDSP_Length(count * 2))
                    }
                }
            }
        }
        return out
    }

    public func start(_ handler: @escaping @Sendable (UnsafeBufferPointer<DSPComplex>) -> Void) throws {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [unowned self] in
            var remaining = Int(sampleRate / 100)
            while remaining > 0 {
                let n = min(remaining, frameCount - position)
                let block = readFrames(at: position, count: n)
                block.withUnsafeBufferPointer { handler($0) }
                position = (position + n) % frameCount
                remaining -= n
            }
        }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Recordings have a fixed centre; retuning is a no-op.
    public func setCenterFrequency(_ hz: Double) throws {}
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter DSPCoreTests`
Expected: all DSPCore tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/DSPCore Tests/DSPCoreTests
git commit -m "feat(dsp): add IQ source protocol, synthetic and WAV sources, Morse table

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 8: Frequency parsing, formatting, upconverter, tuning planner, RSP1B limits

**Files:**
- Modify: `Package.swift` (add the `SubFloorCore` target, which depends on `DSPCore`, and the `SubFloorCoreTests` target)
- Create: `Sources/SubFloorCore/Frequency.swift`
- Test: `Tests/SubFloorCoreTests/FrequencyTests.swift`

**Interfaces:**
- Produces:
  - `FrequencyParser`: `public enum FrequencyParser { static func parse(_ text: String) -> Double? }`. It returns whole Hz.
  - `FrequencyFormatter`: `public enum FrequencyFormatter { static func grouped(_:) -> String; static func readoutDigits(_:) -> [Int]; static func short(_:) -> String; static func rate(_:) -> String }`
    - `grouped` formats as `"14.074.000"`
    - `readoutDigits` returns 10 digits
    - `short` formats as `"14.074 MHz"`
    - `rate` formats as `"2.000 MSPS"`
  - `Upconverter`: `public struct Upconverter: Codable, Equatable, Sendable { var enabled: Bool; var loHz: Double; func hardware(fromDisplay:) -> Double; func display(fromHardware:) -> Double }`
  - `TuningPlanner`: `public enum TuningPlanner { static let usableFraction: Double; static func dcOffset(sampleRate:) -> Double; static func center(forVFO:sampleRate:) -> Double; static func retuneIfNeeded(vfo:center:sampleRate:) -> Double? }`
  - `RSP1B`: `public enum RSP1B { static let frequencyRange; static let sampleRates: [Double]; static let decimations: [Int]; static let ifGainReductionRange: ClosedRange<Int>; static func lnaStateCount(forHz:) -> Int; static func ifBandwidthKHz(sampleRate:decimation:) -> Int; static func clampHardware(_:) -> Double }`

- [ ] **Step 1: Add the targets**

In `Package.swift` `targets:`, add these after `DSPCore`:
```swift
        .target(name: "SubFloorCore", dependencies: ["DSPCore"]),
```
and add this to the test targets:
```swift
        .testTarget(name: "SubFloorCoreTests", dependencies: ["SubFloorCore", "DSPCore"]),
```

- [ ] **Step 2: Write the failing tests**

`Tests/SubFloorCoreTests/FrequencyTests.swift`:
```swift
import Testing
@testable import SubFloorCore

@Test(arguments: [
    ("14.074", 14_074_000.0), ("7074k", 7_074_000), ("7074", 7_074_000), ("144.39m", 144_390_000),
    ("144390", 144_390_000), ("125000000", 125_000_000), ("1.2g", 1_200_000_000), ("14.074.000", 14_074_000),
    ("7.074 MHz", 7_074_000), ("7074kHz", 7_074_000), ("10,000,000", 10_000_000), (" 14 ", 14_000_000),
])
func parsesFrequency(_ input: String, _ expected: Double) {
    #expect(FrequencyParser.parse(input) == expected)
}

@Test(arguments: ["", "m", "abc", "-5", "0", "1.2.3k"])
func rejectsInvalidFrequency(_ input: String) {
    #expect(FrequencyParser.parse(input) == nil)
}

@Test func formatsFrequencies() {
    #expect(FrequencyFormatter.grouped(14_074_000) == "14.074.000")
    #expect(FrequencyFormatter.grouped(1_200_000_000) == "1.200.000.000")
    #expect(FrequencyFormatter.grouped(999) == "999")
    #expect(FrequencyFormatter.readoutDigits(14_074_000) == [0, 0, 1, 4, 0, 7, 4, 0, 0, 0])
    #expect(FrequencyFormatter.short(14_074_000) == "14.074 MHz")
    #expect(FrequencyFormatter.short(1_200_000_000) == "1.2 GHz")
    #expect(FrequencyFormatter.short(500_000) == "500 kHz")
    #expect(FrequencyFormatter.short(700) == "700 Hz")
    #expect(FrequencyFormatter.rate(2_000_000) == "2.000 MSPS")
    #expect(FrequencyFormatter.rate(500_000) == "500.0 kSPS")
}

@Test func upconverterMapsDisplayAndHardware() {
    let up = Upconverter(enabled: true)
    #expect(up.hardware(fromDisplay: 7_100_000) == 132_100_000)
    #expect(up.display(fromHardware: 132_100_000) == 7_100_000)
    let off = Upconverter(enabled: false)
    #expect(off.hardware(fromDisplay: 7_100_000) == 7_100_000)
}

@Test func tuningPlannerRetunesOnlyOutsideUsableSpan() {
    let fs = 2_000_000.0
    #expect(TuningPlanner.center(forVFO: 14_074_000, sampleRate: fs) == 13_974_000)
    #expect(TuningPlanner.retuneIfNeeded(vfo: 14_500_000, center: 14_100_000, sampleRate: fs) == nil)
    #expect(TuningPlanner.retuneIfNeeded(vfo: 15_100_000, center: 14_100_000, sampleRate: fs) == 15_000_000)
}

@Test func rsp1bLimits() {
    #expect(RSP1B.lnaStateCount(forHz: 14_000_000) == 7)
    #expect(RSP1B.lnaStateCount(forHz: 144_000_000) == 10)
    #expect(RSP1B.lnaStateCount(forHz: 1_296_000_000) == 9)
    #expect(RSP1B.ifBandwidthKHz(sampleRate: 2_000_000, decimation: 1) == 1536)
    #expect(RSP1B.ifBandwidthKHz(sampleRate: 8_000_000, decimation: 1) == 8000)
    #expect(RSP1B.ifBandwidthKHz(sampleRate: 2_000_000, decimation: 4) == 300)
    #expect(RSP1B.clampHardware(3_000_000_000) == 2_000_000_000)
    #expect(RSP1B.clampHardware(10) == 1_000)
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `swift test --filter SubFloorCoreTests`
Expected: compile errors.

- [ ] **Step 4: Implement `Sources/SubFloorCore/Frequency.swift`**

```swift
import Foundation

public enum FrequencyParser {
    /// Accepts "14.074", "7074k", "144.39m", "1.2g", "125000000", "14.074.000", "7.074 MHz".
    /// Without a suffix: < 3000 → MHz, < 3 000 000 → kHz, otherwise Hz.
    public static func parse(_ text: String) -> Double? {
        var s = text.lowercased().filter { !" ,_".contains($0) }
        if s.hasSuffix("hz") { s.removeLast(2) }
        var multiplier: Double?
        if let last = s.last, let m = ["k": 1e3, "m": 1e6, "g": 1e9][last] {
            multiplier = m
            s.removeLast()
        }
        guard !s.isEmpty else { return nil }
        if s.filter({ $0 == "." }).count > 1 {
            guard multiplier == nil else { return nil }
            s.removeAll { $0 == "." }
            multiplier = 1
        }
        guard s.allSatisfy({ $0.isNumber || $0 == "." }), let v = Double(s), v > 0, v.isFinite else { return nil }
        let hz: Double
        if let multiplier { hz = v * multiplier }
        else if v < 3_000 { hz = v * 1e6 }
        else if v < 3_000_000 { hz = v * 1e3 }
        else { hz = v }
        return hz.rounded()
    }
}

public enum FrequencyFormatter {
    /// Dot-grouped whole Hz: 14074000 → "14.074.000".
    public static func grouped(_ hz: Double) -> String {
        let digits = String(Int(max(0, hz).rounded()))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(".") }
            out.append(ch)
        }
        return out
    }

    /// Ten zero-padded digits (GHz … Hz) for the big readout.
    public static func readoutDigits(_ hz: Double) -> [Int] {
        var v = Int(max(0, min(hz, 9_999_999_999)).rounded())
        var out = [Int](repeating: 0, count: 10)
        for i in stride(from: 9, through: 0, by: -1) {
            out[i] = v % 10
            v /= 10
        }
        return out
    }

    public static func short(_ hz: Double) -> String {
        func g(_ v: Double) -> String { String(format: "%.7g", v) }
        switch abs(hz) {
        case 1e9...: return "\(g(hz / 1e9)) GHz"
        case 1e6...: return "\(g(hz / 1e6)) MHz"
        case 1e3...: return "\(g(hz / 1e3)) kHz"
        default: return "\(g(hz)) Hz"
        }
    }

    public static func rate(_ sps: Double) -> String {
        sps >= 1e6 ? String(format: "%.3f MSPS", sps / 1e6) : String(format: "%.1f kSPS", sps / 1e3)
    }
}

/// HamItUp-style upconverter: the radio is tuned LO Hz above the antenna (display) frequency.
public struct Upconverter: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var loHz: Double

    public init(enabled: Bool = false, loHz: Double = 125_000_000) {
        self.enabled = enabled
        self.loHz = loHz
    }

    public func hardware(fromDisplay hz: Double) -> Double { enabled ? hz + loHz : hz }
    public func display(fromHardware hz: Double) -> Double { enabled ? hz - loHz : hz }
}

public enum TuningPlanner {
    /// How far from centre (as a fraction of the sample rate) the VFO may go before the radio retunes.
    public static let usableFraction = 0.45

    /// After a retune the VFO sits this far above centre, away from the zero-IF DC spike.
    public static func dcOffset(sampleRate: Double) -> Double { sampleRate * 0.05 }

    public static func center(forVFO vfo: Double, sampleRate: Double) -> Double {
        vfo - dcOffset(sampleRate: sampleRate)
    }

    /// A new centre when `vfo` has left the usable span around `center`; otherwise nil.
    public static func retuneIfNeeded(vfo: Double, center: Double, sampleRate: Double) -> Double? {
        abs(vfo - center) > sampleRate * usableFraction ? self.center(forVFO: vfo, sampleRate: sampleRate) : nil
    }
}

public enum RSP1B {
    public static let frequencyRange: ClosedRange<Double> = 1_000...2_000_000_000
    public static let sampleRates: [Double] = [2e6, 3e6, 4e6, 5e6, 6e6, 7e6, 8e6, 9e6, 10e6]
    public static let decimations = [1, 2, 4, 8, 16, 32]
    public static let ifGainReductionRange = 20...59

    public static func lnaStateCount(forHz hz: Double) -> Int {
        switch hz {
        case ..<60e6: 7
        case ..<1_000e6: 10
        default: 9
        }
    }

    /// Largest analogue IF filter (kHz, matching `sdrplay_api_Bw_MHzT`) that fits the output rate.
    public static func ifBandwidthKHz(sampleRate: Double, decimation: Int) -> Int {
        let out = sampleRate / Double(decimation)
        return [8000, 7000, 6000, 5000, 1536, 600, 300, 200].first { Double($0) * 1_000 <= out } ?? 200
    }

    public static func clampHardware(_ hz: Double) -> Double {
        min(max(hz, frequencyRange.lowerBound), frequencyRange.upperBound)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter SubFloorCoreTests`
Expected: all pass. (`"1.2.3k"` returns nil because of the "more than one dot with a suffix" rule. `"-5"` returns nil because of the digits-only check.)

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/SubFloorCore Tests/SubFloorCoreTests
git commit -m "feat(core): add frequency parsing, formatting, upconverter and RSP1B limits

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Spectrum viewport and ruler scale

**Files:**
- Create: `Sources/SubFloorCore/SpectrumViewport.swift`
- Test: `Tests/SubFloorCoreTests/ViewportTests.swift`

**Interfaces:**
- Produces:
  - `SpectrumViewport`:
    ```swift
    public struct SpectrumViewport: Equatable, Sendable {
        public private(set) var captureCenterHz: Double, captureSpanHz: Double, centerHz: Double, spanHz: Double
        public var minimumSpanHz: Double { get }      // captureSpan / 2000, ≥ 200 Hz
        public init(captureCenterHz: Double, captureSpanHz: Double)
        public var lowerHz: Double { get }; public var upperHz: Double { get }
        public var startFractionOfCapture: Double { get }; public var widthFractionOfCapture: Double { get }
        public func fraction(ofHz: Double) -> Double; public func hz(atFraction: Double) -> Double
        public mutating func zoom(by factor: Double, anchorFraction: Double)   // factor < 1 zooms in
        public mutating func pan(byFraction: Double)                          // + moves toward higher Hz
        public mutating func reset()
        public mutating func setCapture(centerHz: Double, spanHz: Double)     // keeps zoom where possible
        public mutating func ensureVisible(_ hz: Double)
    }
    ```
  - `RulerScale`: `public enum RulerScale { static func step(span: Double, width: Double) -> Double; static func ticks(lower:upper:step:) -> [Double]; static func label(_ hz: Double, step: Double) -> String }`

- [ ] **Step 1: Write the failing tests**

`Tests/SubFloorCoreTests/ViewportTests.swift`:
```swift
import Testing
@testable import SubFloorCore

private func make() -> SpectrumViewport { SpectrumViewport(captureCenterHz: 14_000_000, captureSpanHz: 2_000_000) }

@Test func startsShowingFullCapture() {
    let v = make()
    #expect(v.lowerHz == 13_000_000 && v.upperHz == 15_000_000)
    #expect(v.startFractionOfCapture == 0 && v.widthFractionOfCapture == 1)
}

@Test func zoomKeepsAnchorFrequencyUnderCursor() {
    var v = make()
    let anchor = v.hz(atFraction: 0.25)
    v.zoom(by: 0.5, anchorFraction: 0.25)
    #expect(v.spanHz == 1_000_000)
    #expect(abs(v.hz(atFraction: 0.25) - anchor) < 1e-6)
}

@Test func zoomAndPanAreClampedToCapture() {
    var v = make()
    v.zoom(by: 10, anchorFraction: 0.5)
    #expect(v.spanHz == 2_000_000)
    v.zoom(by: 1e-9, anchorFraction: 0.5)
    #expect(v.spanHz == v.minimumSpanHz)
    v.zoom(by: 100_000, anchorFraction: 0.5)
    v.zoom(by: 0.1, anchorFraction: 0.5)
    v.pan(byFraction: 100)
    #expect(v.upperHz == 15_000_000)
    v.pan(byFraction: -100)
    #expect(v.lowerHz == 13_000_000)
}

@Test func recaptureKeepsSpanAndEnsuresVisibility() {
    var v = make()
    v.zoom(by: 0.1, anchorFraction: 0.5)
    v.setCapture(centerHz: 20_000_000, spanHz: 2_000_000)
    #expect(v.spanHz == 200_000)
    #expect(v.lowerHz >= 19_000_000 && v.upperHz <= 21_000_000)
    v.ensureVisible(20_900_000)
    #expect(v.lowerHz <= 20_900_000 && v.upperHz >= 20_900_000)
}

@Test func rulerScaleChoosesNiceSteps() {
    #expect(RulerScale.step(span: 2_000_000, width: 1_100) == 200_000)
    #expect(RulerScale.step(span: 10_000, width: 1_100) == 1_000)
    #expect(RulerScale.ticks(lower: 14_010_000, upper: 14_050_000, step: 20_000) == [14_020_000, 14_040_000])
    #expect(RulerScale.label(14_200_000, step: 200_000) == "14.2")
    #expect(RulerScale.label(14_074_000, step: 1_000) == "14.074")
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ViewportTests`
Expected: compile errors.

- [ ] **Step 3: Implement `Sources/SubFloorCore/SpectrumViewport.swift`**

```swift
import Foundation

/// The visible slice of the captured span. Pure view state: changing it never retunes the radio.
public struct SpectrumViewport: Equatable, Sendable {
    public private(set) var captureCenterHz: Double
    public private(set) var captureSpanHz: Double
    public private(set) var centerHz: Double
    public private(set) var spanHz: Double

    public init(captureCenterHz: Double, captureSpanHz: Double) {
        self.captureCenterHz = captureCenterHz
        self.captureSpanHz = captureSpanHz
        centerHz = captureCenterHz
        spanHz = captureSpanHz
    }

    public var minimumSpanHz: Double { max(captureSpanHz / 2_000, 200) }
    public var lowerHz: Double { centerHz - spanHz / 2 }
    public var upperHz: Double { centerHz + spanHz / 2 }
    private var captureLowerHz: Double { captureCenterHz - captureSpanHz / 2 }
    public var startFractionOfCapture: Double { (lowerHz - captureLowerHz) / captureSpanHz }
    public var widthFractionOfCapture: Double { spanHz / captureSpanHz }

    public func fraction(ofHz hz: Double) -> Double { (hz - lowerHz) / spanHz }
    public func hz(atFraction f: Double) -> Double { lowerHz + f * spanHz }

    public mutating func zoom(by factor: Double, anchorFraction: Double) {
        let anchorHz = hz(atFraction: anchorFraction)
        spanHz = min(max(spanHz * factor, minimumSpanHz), captureSpanHz)
        centerHz = anchorHz - anchorFraction * spanHz + spanHz / 2
        clamp()
    }

    public mutating func pan(byFraction f: Double) {
        centerHz += f * spanHz
        clamp()
    }

    public mutating func reset() {
        centerHz = captureCenterHz
        spanHz = captureSpanHz
    }

    public mutating func setCapture(centerHz newCenter: Double, spanHz newSpan: Double) {
        let offset = centerHz - captureCenterHz
        captureCenterHz = newCenter
        captureSpanHz = newSpan
        spanHz = min(max(spanHz, minimumSpanHz), newSpan)
        centerHz = newCenter + offset
        clamp()
    }

    public mutating func ensureVisible(_ hz: Double) {
        let margin = spanHz * 0.05
        if hz < lowerHz + margin { centerHz = hz - margin + spanHz / 2 }
        if hz > upperHz - margin { centerHz = hz + margin - spanHz / 2 }
        clamp()
    }

    private mutating func clamp() {
        let lo = captureLowerHz + spanHz / 2
        let hi = captureCenterHz + captureSpanHz / 2 - spanHz / 2
        centerHz = min(max(centerHz, lo), hi)
    }
}

public enum RulerScale {
    /// A 1/2/5 × 10ⁿ step giving roughly one label per 110 points.
    public static func step(span: Double, width: Double) -> Double {
        let target = span / max(width / 110, 1)
        let magnitude = pow(10, floor(log10(target)))
        for m in [1.0, 2, 5] where m * magnitude >= target { return m * magnitude }
        return 10 * magnitude
    }

    public static func ticks(lower: Double, upper: Double, step: Double) -> [Double] {
        Array(stride(from: (lower / step).rounded(.up) * step, through: upper, by: step))
    }

    /// MHz label with just enough decimals for `step`.
    public static func label(_ hz: Double, step: Double) -> String {
        let decimals = max(0, Int(ceil(-log10(step / 1e6) - 1e-9)))
        var s = String(format: "%.\(decimals)f", hz / 1e6)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ViewportTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SubFloorCore Tests/SubFloorCoreTests
git commit -m "feat(core): add spectrum viewport zoom/pan model and ruler scale

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Bookmarks model, store and search

**Files:**
- Create: `Sources/SubFloorCore/Bookmarks.swift`
- Test: `Tests/SubFloorCoreTests/BookmarkTests.swift`

**Interfaces:**
- Consumes: `DemodMode` (DSPCore), `FrequencyFormatter`.
- Produces:
  - `Bookmark`: `public struct Bookmark: Codable, Identifiable, Hashable, Sendable { id: UUID; name; frequencyHz; mode: DemodMode; bandwidthHz; upconverter: Bool; group: String?; colorHex: String?; init(id: UUID = UUID(), name:frequencyHz:mode:bandwidthHz:upconverter: = false, group: = nil, colorHex: = nil) }`
  - `BookmarkStore`: `public final class BookmarkStore`, with:
    - `init(url:)`
    - `static var defaultURL: URL`
    - `enum LoadResult { loaded, createdDefaults, recoveredFromCorrupt }`
    - `func load() -> ([Bookmark], LoadResult)`
    - `func save(_:) throws`
    - `static func write(_:to:) throws`
    - `static func read(from:) throws -> [Bookmark]`
    - `static let defaults: [Bookmark]`
  - `BookmarkSearch`: `public enum BookmarkSearch { static func filter(_:query:) -> [Bookmark] }`

- [ ] **Step 1: Write the failing tests**

`Tests/SubFloorCoreTests/BookmarkTests.swift`:
```swift
import Testing
import Foundation
import DSPCore
@testable import SubFloorCore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("subfloor-\(UUID())/bookmarks.json")
}

@Test func firstLoadCreatesDefaults() {
    let store = BookmarkStore(url: tempURL())
    let (bookmarks, result) = store.load()
    #expect(result == .createdDefaults)
    #expect(bookmarks == BookmarkStore.defaults)
    #expect(bookmarks.contains { $0.upconverter })
}

@Test func saveThenLoadRoundTrips() throws {
    let url = tempURL()
    let store = BookmarkStore(url: url)
    let b = Bookmark(name: "Test", frequencyHz: 7_074_000, mode: .usb, bandwidthHz: 2_700, upconverter: true, group: "G", colorHex: "#FF8800")
    try store.save([b])
    let (loaded, result) = BookmarkStore(url: url).load()
    #expect(result == .loaded)
    #expect(loaded == [b])
}

@Test func corruptFileIsMovedAsideAndDefaultsRestored() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ nope".utf8).write(to: url)
    let (loaded, result) = BookmarkStore(url: url).load()
    #expect(result == .recoveredFromCorrupt)
    #expect(loaded == BookmarkStore.defaults)
    let corrupt = url.deletingLastPathComponent().appendingPathComponent("bookmarks.corrupt.json")
    #expect(FileManager.default.fileExists(atPath: corrupt.path))
}

@Test func searchMatchesAllTokensCaseInsensitively() {
    let names = BookmarkSearch.filter(BookmarkStore.defaults, query: "ft8 20").map(\.name)
    #expect(names == ["20m FT8"])
    #expect(BookmarkSearch.filter(BookmarkStore.defaults, query: "").count == BookmarkStore.defaults.count)
    #expect(BookmarkSearch.filter(BookmarkStore.defaults, query: "hamitup").allSatisfy(\.upconverter))
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter BookmarkTests`
Expected: compile errors.

- [ ] **Step 3: Implement `Sources/SubFloorCore/Bookmarks.swift`**

```swift
import DSPCore
import Foundation

public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var frequencyHz: Double
    public var mode: DemodMode
    public var bandwidthHz: Double
    public var upconverter: Bool
    public var group: String?
    public var colorHex: String?

    public init(id: UUID = UUID(), name: String, frequencyHz: Double, mode: DemodMode, bandwidthHz: Double,
                upconverter: Bool = false, group: String? = nil, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.frequencyHz = frequencyHz
        self.mode = mode
        self.bandwidthHz = bandwidthHz
        self.upconverter = upconverter
        self.group = group
        self.colorHex = colorHex
    }
}

private struct BookmarkFile: Codable {
    var version = 1
    var bookmarks: [Bookmark]
}

public final class BookmarkStore {
    public enum LoadResult: Equatable, Sendable { case loaded, createdDefaults, recoveredFromCorrupt }

    public let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SubFloor/bookmarks.json")
    }

    public func load() -> ([Bookmark], LoadResult) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (Self.defaults, .createdDefaults) }
        do {
            return (try Self.read(from: url), .loaded)
        } catch {
            let aside = url.deletingLastPathComponent().appendingPathComponent("bookmarks.corrupt.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            return (Self.defaults, .recoveredFromCorrupt)
        }
    }

    public func save(_ bookmarks: [Bookmark]) throws { try Self.write(bookmarks, to: url) }

    public static func write(_ bookmarks: [Bookmark], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(BookmarkFile(bookmarks: bookmarks)).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> [Bookmark] {
        try JSONDecoder().decode(BookmarkFile.self, from: Data(contentsOf: url)).bookmarks
    }

    public static let defaults: [Bookmark] = [
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "WWV 10 MHz", frequencyHz: 10_000_000, mode: .am, bandwidthHz: 8_000, group: "Time"),
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "20m FT8", frequencyHz: 14_074_000, mode: .usb, bandwidthHz: 2_700, group: "Digital"),
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "40m FT8", frequencyHz: 7_074_000, mode: .usb, bandwidthHz: 2_700, group: "Digital"),
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "20m CW", frequencyHz: 14_030_000, mode: .cw, bandwidthHz: 500, group: "CW"),
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, name: "2m APRS", frequencyHz: 144_390_000, mode: .nfm, bandwidthHz: 12_500, group: "VHF"),
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, name: "FM Broadcast 98.1", frequencyHz: 98_100_000, mode: .wfm, bandwidthHz: 180_000, group: "Broadcast"),
        Bookmark(id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, name: "40m SSB (HamItUp)", frequencyHz: 7_200_000, mode: .lsb, bandwidthHz: 2_700, upconverter: true, group: "HF via HamItUp", colorHex: "#FF9F43"),
    ]
}

public enum BookmarkSearch {
    /// Keeps bookmarks whose name, group, mode, frequency or "hamitup" tag contain every whitespace-separated token.
    public static func filter(_ bookmarks: [Bookmark], query: String) -> [Bookmark] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return bookmarks }
        return bookmarks.filter { b in
            let haystack = [b.name, b.group ?? "", b.mode.rawValue, FrequencyFormatter.short(b.frequencyHz),
                            String(Int(b.frequencyHz)), b.upconverter ? "hamitup upconverter" : ""]
                .joined(separator: " ").lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SubFloorCoreTests`
Expected: all pass. The "ft8 20" query matches "20m FT8" only, because "40m FT8" contains no "20". Check that `14.074 MHz` doesn't let `20` sneak into "40m FT8": its frequency string `7074000` has no "20", so it doesn't.

- [ ] **Step 5: Commit**

```bash
git add Sources/SubFloorCore Tests/SubFloorCoreTests
git commit -m "feat(core): add bookmark model, atomic JSON store and search

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: SDRplay device wrapper

**Files:**
- Create: `Sources/SDRplayKit/SDRplaySettings.swift`, `Sources/SDRplayKit/SDRplayDevice.swift`
- Test: `Tests/SDRplayKitTests/SDRplayDeviceTests.swift`

**Interfaces:**
- Consumes: `SDRplayError`, `check` (Task 1), `IQSource` (Task 7).
- Produces:
  - `HardwareAGC`: `public enum HardwareAGC: String, CaseIterable, Codable, Sendable { case off, hz5, hz50, hz100; var label: String }`
  - `SDRplaySettings`: `public struct SDRplaySettings: Codable, Equatable, Sendable`, with these fields:
    - `sampleRate = 2_000_000`
    - `decimation = 1`
    - `ifBandwidthKHz = 1536`
    - `lnaState = 3`
    - `ifGainReductionDb = 40`
    - `agc: HardwareAGC = .off`
    - `biasT`, `rfNotch`, `dabNotch` (all `false`)
    - `ppm = 0`
    - `var outputRate: Double`
  - `SDRplayEvent`: `public enum SDRplayEvent: Sendable { case overload(detected: Bool), deviceRemoved, deviceFailure, gainChanged(Double) }`
  - `SDRplayDevice`: `public final class SDRplayDevice: IQSource, @unchecked Sendable`, with:
    - `static func open() throws -> SDRplayDevice`
    - `serial`
    - `settings`
    - `var onEvent: (@Sendable (SDRplayEvent) -> Void)?`
    - `func apply(_ settings: SDRplaySettings) throws`
    - `func close()`
    - the `IQSource` members

- [ ] **Step 1: Write the tests**

The device-independent mapping tests always run. The hardware test runs only when `SUBFLOOR_HW=1`.

`Tests/SDRplayKitTests/SDRplayDeviceTests.swift`:
```swift
import Testing
import Foundation
import CSDRplay
import DSPCore
@testable import SDRplayKit

@Test func agcMapsToApiValues() {
    #expect(HardwareAGC.off.api == sdrplay_api_AGC_DISABLE)
    #expect(HardwareAGC.hz5.api == sdrplay_api_AGC_5HZ)
    #expect(HardwareAGC.hz50.api == sdrplay_api_AGC_50HZ)
    #expect(HardwareAGC.hz100.api == sdrplay_api_AGC_100HZ)
}

@Test func settingsOutputRateAccountsForDecimation() {
    var s = SDRplaySettings()
    s.sampleRate = 8_000_000
    s.decimation = 4
    #expect(s.outputRate == 2_000_000)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SUBFLOOR_HW"] == "1"))
func streamsFromRealRSP() async throws {
    let device = try SDRplayDevice.open()
    defer { device.close() }
    let counter = SampleCounter()
    try device.setCenterFrequency(100_000_000)
    try device.start { counter.add($0.count) }
    try await Task.sleep(for: .milliseconds(700))
    device.stop()
    #expect(counter.value > 500_000)
}

private final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ n: Int) { lock.withLock { total += n } }
    var value: Int { lock.withLock { total } }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter SDRplayKitTests`
Expected: compile errors.

- [ ] **Step 3: Implement `Sources/SDRplayKit/SDRplaySettings.swift`**

```swift
import CSDRplay

public enum HardwareAGC: String, CaseIterable, Codable, Sendable {
    case off, hz5, hz50, hz100

    public var label: String {
        switch self {
        case .off: "Off"
        case .hz5: "5 Hz"
        case .hz50: "50 Hz"
        case .hz100: "100 Hz"
        }
    }

    var api: sdrplay_api_AgcControlT {
        switch self {
        case .off: sdrplay_api_AGC_DISABLE
        case .hz5: sdrplay_api_AGC_5HZ
        case .hz50: sdrplay_api_AGC_50HZ
        case .hz100: sdrplay_api_AGC_100HZ
        }
    }
}

public struct SDRplaySettings: Codable, Equatable, Sendable {
    public var sampleRate: Double = 2_000_000
    public var decimation: Int = 1
    public var ifBandwidthKHz: Int = 1536
    public var lnaState: Int = 3
    public var ifGainReductionDb: Int = 40
    public var agc: HardwareAGC = .off
    public var biasT = false
    public var rfNotch = false
    public var dabNotch = false
    public var ppm: Double = 0

    public init() {}

    public var outputRate: Double { sampleRate / Double(decimation) }
}

public enum SDRplayEvent: Sendable {
    case overload(detected: Bool)
    case deviceRemoved
    case deviceFailure
    case gainChanged(Double)
}
```

- [ ] **Step 4: Implement `Sources/SDRplayKit/SDRplayDevice.swift`**

```swift
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter SDRplayKitTests`
Expected: 4 tests pass and 1 is skipped (the hardware test).

If an RSP1B is plugged in, also run: `SUBFLOOR_HW=1 swift test --filter streamsFromRealRSP`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SDRplayKit Tests/SDRplayKitTests
git commit -m "feat(sdrplay): add RSP1B device wrapper with streaming, updates and events

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Modem framework and CW decoder

**Files:**
- Modify: `Package.swift` (add the `Modems` target, which depends on `DSPCore`, and the `ModemsTests` target)
- Create: `Sources/Modems/Modem.swift`, `Sources/Modems/CW/CWDecoderCore.swift`, `Sources/Modems/CW/CWDecoderModem.swift`
- Test: `Tests/ModemsTests/CWDecoderTests.swift`

**Interfaces:**
- Consumes: `DemodMode`, `MorseCode` (DSPCore).
- Produces:
  - Modem types:
    ```swift
    public enum ModemInput: Sendable { case audio, iq }
    public struct ModemInfo: Sendable, Identifiable { id, name, input, preferredMode: DemodMode?, preferredBandwidth: Double? }
    public struct ModemContext: Sendable { sampleRate: Double; mode: DemodMode; bandwidthHz: Double; cwPitchHz: Double }
    public protocol Modem: AnyObject, Sendable {
        static var info: ModemInfo { get }
        init()
        func reset()
        func process(audio: UnsafeBufferPointer<Float>, context: ModemContext)
        func process(iq: UnsafeBufferPointer<DSPComplex>, context: ModemContext)
        @MainActor func makeOutputView() -> AnyView
    }
    public enum ModemRegistry { static let all: [any Modem.Type]; static var infos: [ModemInfo]; static func type(withID:) -> (any Modem.Type)? }
    public final class ModemHost: @unchecked Sendable { func set(_: (any Modem)?); func process(audio:context:); func process(iq:context:) }
    ```
  - `CWDecoderCore`: `public final class CWDecoderCore { init(sampleRate: Double = 48_000, pitchHz: Double = 700); var pitchHz: Double; private(set) var wpm: Double; private(set) var level: Float; func process(_ x: UnsafeBufferPointer<Float>) -> String; func reset() }`
  - `CWDecoderModel`: `@Observable public final class CWDecoderModel: @unchecked Sendable { text, wpm, level, clear() }`
  - `CWDecoderModem`: `public final class CWDecoderModem: Modem`

- [ ] **Step 1: Add the targets**

In `Package.swift`, add:
```swift
        .target(name: "Modems", dependencies: ["DSPCore"]),
```
and add this test target:
```swift
        .testTarget(name: "ModemsTests", dependencies: ["Modems", "DSPCore"]),
```

- [ ] **Step 2: Write the failing tests**

`Tests/ModemsTests/CWDecoderTests.swift`:
```swift
import Testing
import Foundation
import DSPCore
@testable import Modems

/// Keyed 700 Hz tone with leading/trailing silence and light noise.
private func morseAudio(_ text: String, wpm: Double, pitch: Double = 700, rate: Double = 48_000) -> [Float] {
    let unit = Int(MorseCode.dotSeconds(wpm: wpm) * rate)
    var keyed: [Bool] = Array(repeating: false, count: Int(0.3 * rate))
    for e in MorseCode.timeline(for: text) { keyed += Array(repeating: e.on, count: e.units * unit) }
    keyed += Array(repeating: false, count: Int(1.0 * rate))
    var seed: UInt64 = 42
    return keyed.enumerated().map { i, on in
        seed = seed &* 6364136223846793005 &+ 1
        let noise = Float(Int64(bitPattern: seed >> 11) % 1000) / 100_000
        return (on ? 0.5 * Float(sin(2 * Double.pi * pitch * Double(i) / rate)) : 0) + noise
    }
}

@Test(arguments: [15.0, 20.0, 25.0])
func decodesMorseAtSpeed(_ wpm: Double) {
    let core = CWDecoderCore()
    let audio = morseAudio("CQ TEST 73", wpm: wpm)
    var text = ""
    for start in stride(from: 0, to: audio.count, by: 4_800) {
        audio[start..<min(start + 4_800, audio.count)].withUnsafeBufferPointer { text += core.process($0) }
    }
    #expect(text.trimmingCharacters(in: .whitespaces) == "CQ TEST 73")
    #expect(abs(core.wpm - wpm) < wpm * 0.15)
}

@Test func registryFindsCWModem() {
    #expect(ModemRegistry.type(withID: "cw") != nil)
    #expect(ModemRegistry.infos.map(\.id).contains("cw"))
    #expect(CWDecoderModem.info.preferredMode == .cw)
}

@Test func hostForwardsAudioToActiveModem() {
    let host = ModemHost()
    let probe = ProbeModem()
    host.set(probe)
    let context = ModemContext(sampleRate: 48_000, mode: .cw, bandwidthHz: 500, cwPitchHz: 700)
    [Float](repeating: 0, count: 128).withUnsafeBufferPointer { host.process(audio: $0, context: context) }
    #expect(probe.received == 128)
    host.set(nil)
    [Float](repeating: 0, count: 128).withUnsafeBufferPointer { host.process(audio: $0, context: context) }
    #expect(probe.received == 128)
}

private final class ProbeModem: Modem, @unchecked Sendable {
    static let info = ModemInfo(id: "probe", name: "Probe", input: .audio, preferredMode: nil, preferredBandwidth: nil)
    var received = 0
    init() {}
    func reset() {}
    func process(audio: UnsafeBufferPointer<Float>, context: ModemContext) { received += audio.count }
    @MainActor func makeOutputView() -> AnyView { AnyView(EmptyView()) }
}
```
The `AnyView` and `EmptyView` in the probe need SwiftUI. Add `import SwiftUI` at the top of the test file.

- [ ] **Step 3: Run them to verify they fail**

Run: `swift test --filter ModemsTests`
Expected: compile errors.

- [ ] **Step 4: Implement `Sources/Modems/Modem.swift`**

```swift
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
```

- [ ] **Step 5: Implement `Sources/Modems/CW/CWDecoderCore.swift`**

```swift
import DSPCore
import Foundation

/// Goertzel tone detector + adaptive threshold + timing classifier.
/// Tracks speed from element lengths; emits characters on 2-dot gaps and spaces on 5-dot gaps.
public final class CWDecoderCore {
    public var pitchHz: Double { didSet { configure() } }
    public let sampleRate: Double
    public private(set) var wpm: Double = 20
    public private(set) var level: Float = 0

    private let blockSize: Int
    private var coefficient = 0.0
    private var s1 = 0.0, s2 = 0.0, filled = 0
    private var noiseFloor = 1e-6
    private var peak = 1e-3
    private var keyDown = false
    private var runBlocks = 0
    private var dotMs = 60.0
    private var symbol = ""
    private var charPending = false
    private var wordPending = false

    public init(sampleRate: Double = 48_000, pitchHz: Double = 700) {
        self.sampleRate = sampleRate
        self.pitchHz = pitchHz
        blockSize = Int(sampleRate * 0.005)
        configure()
    }

    private func configure() { coefficient = 2 * cos(2 * .pi * pitchHz / sampleRate) }

    private var blockMs: Double { Double(blockSize) / sampleRate * 1_000 }

    public func reset() {
        s1 = 0; s2 = 0; filled = 0
        noiseFloor = 1e-6; peak = 1e-3
        keyDown = false; runBlocks = 0; dotMs = 60; wpm = 20
        symbol = ""; charPending = false; wordPending = false
    }

    /// Feeds audio and returns any newly decoded text.
    public func process(_ x: UnsafeBufferPointer<Float>) -> String {
        var out = ""
        for v in x {
            let s0 = Double(v) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
            filled += 1
            if filled == blockSize {
                let power = max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2)
                step(magnitude: power.squareRoot() / Double(blockSize), out: &out)
                s1 = 0; s2 = 0; filled = 0
            }
        }
        return out
    }

    private func step(magnitude m: Double, out: inout String) {
        if m > peak { peak = m } else { peak += (m - peak) * 0.002 }
        if m < noiseFloor { noiseFloor = m } else { noiseFloor += (m - noiseFloor) * 0.002 }
        let span = peak - noiseFloor
        let threshold = noiseFloor + span * (keyDown ? 0.4 : 0.6)
        let down = m > threshold && peak > noiseFloor * 4
        level = Float(min(1, max(0, (m - noiseFloor) / max(span, 1e-12))))

        if down == keyDown {
            runBlocks += 1
            if !keyDown { checkGap(out: &out) }
            return
        }
        if keyDown { classifyMark(Double(runBlocks) * blockMs) }
        keyDown = down
        runBlocks = 1
    }

    private func classifyMark(_ ms: Double) {
        guard ms >= dotMs * 0.3 else { return }
        if ms < dotMs * 2 {
            symbol += "."
            dotMs += (ms - dotMs) * 0.3
        } else {
            symbol += "-"
            dotMs += (ms / 3 - dotMs) * 0.3
        }
        dotMs = min(max(dotMs, 20), 240)
        wpm = 1_200 / dotMs
        charPending = true
        wordPending = true
    }

    private func checkGap(out: inout String) {
        let ms = Double(runBlocks) * blockMs
        if charPending && ms > dotMs * 2 {
            if !symbol.isEmpty { out.append(MorseCode.reverse[symbol] ?? "*") }
            symbol = ""
            charPending = false
        }
        if wordPending && ms > dotMs * 5 {
            out.append(" ")
            wordPending = false
        }
    }
}
```

- [ ] **Step 6: Implement `Sources/Modems/CW/CWDecoderModem.swift`**

```swift
import DSPCore
import Foundation
import Observation
import SwiftUI

/// Main-thread state for the CW output view. Mutated only on the main queue.
@Observable
public final class CWDecoderModel: @unchecked Sendable {
    public private(set) var text = ""
    public private(set) var wpm: Double = 0
    public private(set) var level: Float = 0

    func append(_ newText: String, wpm: Double, level: Float) {
        if !newText.isEmpty {
            text += newText
            if text.count > 10_000 { text.removeFirst(text.count - 10_000) }
        }
        self.wpm = wpm
        self.level = level
    }

    public func clear() { text = "" }
}

public final class CWDecoderModem: Modem, @unchecked Sendable {
    public static let info = ModemInfo(id: "cw", name: "CW Decoder", input: .audio, preferredMode: .cw, preferredBandwidth: 500)

    public let model = CWDecoderModel()
    private let core = CWDecoderCore()
    private var pending = ""
    private var samplesSinceFlush = 0

    public init() {}

    public func reset() { core.reset() }

    public func process(audio: UnsafeBufferPointer<Float>, context: ModemContext) {
        if core.pitchHz != context.cwPitchHz { core.pitchHz = context.cwPitchHz }
        pending += core.process(audio)
        samplesSinceFlush += audio.count
        guard samplesSinceFlush >= Int(context.sampleRate / 10) else { return }
        let text = pending, wpm = core.wpm, level = core.level, model = model
        pending = ""
        samplesSinceFlush = 0
        DispatchQueue.main.async { model.append(text, wpm: wpm, level: level) }
    }

    @MainActor public func makeOutputView() -> AnyView { AnyView(CWDecoderView(model: model)) }
}

struct CWDecoderView: View {
    let model: CWDecoderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Label(model.wpm > 0 ? String(format: "%.0f WPM", model.wpm) : "— WPM", systemImage: "metronome")
                    .monospacedDigit()
                Gauge(value: Double(model.level)) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(.green)
                    .frame(width: 120)
                Spacer()
                Button("Clear") { model.clear() }.controlSize(.small)
            }
            .font(.callout)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.text.isEmpty ? "Listening…" : model.text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(model.text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("end")
                }
                .onChange(of: model.text) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .padding(12)
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter ModemsTests`
Expected: all pass (5 test cases, including the 3 parameterised speeds). If one speed fails by a single character, debug with `print` of `symbol` timings. Do not relax the expected string.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/Modems Tests/ModemsTests
git commit -m "feat(modems): add modular modem framework and CW decoder

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 13: Audio output, DSP engine and a runnable app shell

**Files:**
- Modify: `Package.swift` (add the `SubFloor` executable target)
- Create:
  - `Sources/SubFloor/Engine/AudioOutput.swift`
  - `Sources/SubFloor/Engine/DSPEngine.swift`
  - `Sources/SubFloor/App/SubFloorApp.swift` (temporary minimal window; replaced in Task 16)
  - `Sources/SubFloor/App/CPUUsage.swift`
- Test: manual run (`swift run SubFloor`), plus the existing unit tests.

**Interfaces:**
- Consumes: `SPSCRing`, `SpectrumAnalyzer`, `SpectrumAverager`, `Receiver`, `IQSource`, `WindowKind` (DSPCore); `ModemHost` and `ModemContext` (Modems).
- Produces:
  - `SpectrumSettings`: `struct SpectrumSettings: Codable, Equatable, Sendable { fftSize = 8192; window: WindowKind = .blackmanHarris; framesPerSecond = 30.0; averaging: Float = 0.5 }`
  - `SpectrumFrameStore`: `final class SpectrumFrameStore: @unchecked Sendable { func publish(average: [Float], peak: [Float]); func read(after: UInt64, average: inout [Float], peak: inout [Float]) -> UInt64? }`
  - `AudioOutput`: `final class AudioOutput: @unchecked Sendable { let underruns: Atomic<Int>; func start() throws; func stop(); func push(_: UnsafeBufferPointer<Float>) }`
  - `DSPEngine`: `final class DSPEngine: @unchecked Sendable`, with:
    - `let frames: SpectrumFrameStore`
    - `let audio: AudioOutput`
    - `let modems: ModemHost`
    - `let stats: Mutex<EngineStats>`
    - `func start(source: any IQSource, receiver: Receiver.Config, spectrum: SpectrumSettings, volume: Float) throws`
    - `func stop()`
    - `func update(receiver:)`
    - `func update(spectrum:)`
    - `func update(volume:)`
    - `func resetPeak()`
  - `EngineStats`: `struct EngineStats: Sendable { var signalDb: Float = -200; var droppedSamples = 0 }`
  - `CPUUsage`: `struct CPUUsage { mutating func sample() -> Double }`, which returns the percentage of one core.

- [ ] **Step 1: Add the executable target**

In `Package.swift`, add:
```swift
        .executableTarget(
            name: "SubFloor",
            dependencies: ["DSPCore", "SubFloorCore", "SDRplayKit", "Modems"],
            swiftSettings: fastMath,
            linkerSettings: sdrplayLinker),
```

- [ ] **Step 2: Implement `Sources/SubFloor/Engine/AudioOutput.swift`**

```swift
import AVFoundation
import DSPCore
import Synchronization

/// 48 kHz mono output fed from an SPSC ring. Re-primes to ~50 ms after an underrun.
final class AudioOutput: @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let targetLatency = 2_400

    let underruns = Atomic<Int>(0)
    private let ring = SPSCRing<Float>(capacity: 48_000, fill: 0)
    private let primed = Atomic<Bool>(false)
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let data = buffers[0].mData else { return noErr }
            render(UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frameCount)))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
    }

    private func render(_ out: UnsafeMutableBufferPointer<Float>) {
        if !primed.load(ordering: .acquiring) {
            guard ring.availableToRead >= Self.targetLatency else {
                out.update(repeating: 0)
                return
            }
            primed.store(true, ordering: .releasing)
        }
        let n = ring.read(into: out)
        if n < out.count {
            UnsafeMutableBufferPointer(rebasing: out[n...]).update(repeating: 0)
            underruns.add(1, ordering: .relaxed)
            primed.store(false, ordering: .releasing)
        }
    }

    /// DSP thread. Drops a block when the buffer is already 4× the latency target, bounding drift.
    func push(_ samples: UnsafeBufferPointer<Float>) {
        guard ring.availableToRead < Self.targetLatency * 4 else { return }
        ring.write(samples)
    }

    func start() throws {
        if !engine.isRunning { try engine.start() }
    }

    func stop() {
        engine.stop()
        ring.drain()
        primed.store(false, ordering: .releasing)
    }
}
```

- [ ] **Step 3: Implement `Sources/SubFloor/Engine/DSPEngine.swift`**

```swift
import Accelerate
import DSPCore
import Foundation
import Modems
import Synchronization

struct SpectrumSettings: Codable, Equatable, Sendable {
    var fftSize = 8192
    var window: WindowKind = .blackmanHarris
    var framesPerSecond = 30.0
    var averaging: Float = 0.5
}

struct EngineStats: Sendable {
    var signalDb: Float = -200
    var droppedSamples = 0
}

/// Latest averaged + peak spectrum, copied in by the DSP thread and out by the renderer.
final class SpectrumFrameStore: @unchecked Sendable {
    private struct Frame {
        var sequence: UInt64 = 0
        var average: [Float] = []
        var peak: [Float] = []
    }

    private let state = Mutex(Frame())

    func publish(average: [Float], peak: [Float]) {
        state.withLock { f in
            if f.average.count != average.count {
                f.average = average
                f.peak = peak
            } else {
                f.average.withUnsafeMutableBufferPointer { d in average.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: $0.count) } }
                f.peak.withUnsafeMutableBufferPointer { d in peak.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: $0.count) } }
            }
            f.sequence &+= 1
        }
    }

    /// Copies the latest frame if it is newer than `sequence`; returns its sequence number.
    func read(after sequence: UInt64, average: inout [Float], peak: inout [Float]) -> UInt64? {
        state.withLock { f in
            guard f.sequence != sequence, !f.average.isEmpty else { return nil }
            if average.count != f.average.count {
                average = f.average
                peak = f.peak
            } else {
                average.withUnsafeMutableBufferPointer { d in f.average.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: $0.count) } }
                peak.withUnsafeMutableBufferPointer { d in f.peak.withUnsafeBufferPointer { d.baseAddress!.update(from: $0.baseAddress!, count: $0.count) } }
            }
            return f.sequence
        }
    }
}

/// Owns the IQ ring and the DSP thread: spectrum frames, receiver audio, modem feed.
final class DSPEngine: @unchecked Sendable {
    let frames = SpectrumFrameStore()
    let audio = AudioOutput()
    let modems = ModemHost()
    let stats = Mutex(EngineStats())

    private struct Pending {
        var receiver: Receiver.Config?
        var spectrum: SpectrumSettings?
        var volume: Float?
        var resetPeak = false
    }

    private let ring = SPSCRing<DSPComplex>(capacity: 1 << 22, fill: DSPComplex(real: 0, imag: 0))
    private let wake = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private let pending = Mutex(Pending())
    private var exited: DispatchSemaphore?
    private var source: (any IQSource)?

    func start(source: any IQSource, receiver: Receiver.Config, spectrum: SpectrumSettings, volume: Float) throws {
        stop()
        ring.drain()
        pending.withLock { $0 = Pending() }
        self.source = source
        let done = DispatchSemaphore(value: 0)
        exited = done
        running.store(true, ordering: .releasing)
        let thread = Thread { [unowned self] in
            run(receiver: receiver, spectrum: spectrum, volume: volume)
            done.signal()
        }
        thread.name = "SubFloor DSP"
        thread.qualityOfService = .userInteractive
        thread.start()
        try audio.start()
        let ring = ring, wake = wake, stats = stats
        do {
            try source.start { block in
                let written = ring.write(block)
                if written < block.count { stats.withLock { $0.droppedSamples += block.count - written } }
                wake.signal()
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        source?.stop()
        source = nil
        if running.exchange(false, ordering: .acquiringAndReleasing) {
            wake.signal()
            exited?.wait()
        }
        exited = nil
        audio.stop()
    }

    func update(receiver: Receiver.Config) { pending.withLock { $0.receiver = receiver } }
    func update(spectrum: SpectrumSettings) { pending.withLock { $0.spectrum = spectrum } }
    func update(volume: Float) { pending.withLock { $0.volume = volume } }
    func resetPeak() { pending.withLock { $0.resetPeak = true } }

    private func run(receiver config: Receiver.Config, spectrum initial: SpectrumSettings, volume initialVolume: Float) {
        let sampleRate = config.inputRate
        let receiver = Receiver(config: config)
        let modems = modems
        receiver.channelTap = { iq, rate in
            modems.process(iq: iq, context: ModemContext(sampleRate: rate, mode: config.mode,
                                                         bandwidthHz: config.bandwidthHz, cwPitchHz: config.cwPitchHz))
        }
        var settings = initial
        var volume = initialVolume
        var analyzer = SpectrumAnalyzer(size: settings.fftSize, window: settings.window)
        var averager = SpectrumAverager(size: settings.fftSize, alpha: settings.averaging)
        var history = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: settings.fftSize)
        var linear = history
        var db = [Float](repeating: -200, count: settings.fftSize)
        var historyPos = 0
        var sinceFrame = 0
        var block = [DSPComplex](repeating: DSPComplex(real: 0, imag: 0), count: 1 << 16)
        var audioOut = [Float]()
        audioOut.reserveCapacity(1 << 15)

        while running.load(ordering: .acquiring) {
            let changes = pending.withLock { p -> Pending in
                let c = p
                p = Pending()
                return c
            }
            if let r = changes.receiver { receiver.update(r) }
            if let v = changes.volume { volume = v }
            if let s = changes.spectrum, s != settings {
                if s.fftSize != settings.fftSize || s.window != settings.window {
                    analyzer = SpectrumAnalyzer(size: s.fftSize, window: s.window)
                    averager = SpectrumAverager(size: s.fftSize, alpha: s.averaging)
                    history = .init(repeating: DSPComplex(real: 0, imag: 0), count: s.fftSize)
                    linear = history
                    db = .init(repeating: -200, count: s.fftSize)
                    historyPos = 0
                }
                averager.alpha = s.averaging
                settings = s
            }
            if changes.resetPeak { averager.resetPeak() }

            let n = block.withUnsafeMutableBufferPointer { ring.read(into: $0) }
            if n == 0 {
                _ = wake.wait(timeout: .now() + .milliseconds(20))
                continue
            }

            // Spectrum: keep the most recent fftSize samples; emit frames at framesPerSecond.
            let size = settings.fftSize
            block.withUnsafeBufferPointer { b in
                history.withUnsafeMutableBufferPointer { h in
                    var i = max(0, n - size)
                    while i < n {
                        let k = min(n - i, size - historyPos)
                        (h.baseAddress! + historyPos).update(from: b.baseAddress! + i, count: k)
                        historyPos = (historyPos + k) % size
                        i += k
                    }
                }
            }
            sinceFrame += n
            if sinceFrame >= max(size, Int(sampleRate / settings.framesPerSecond)) {
                sinceFrame = 0
                linear.withUnsafeMutableBufferPointer { l in
                    history.withUnsafeBufferPointer { h in
                        let tail = size - historyPos
                        l.baseAddress!.update(from: h.baseAddress! + historyPos, count: tail)
                        (l.baseAddress! + tail).update(from: h.baseAddress!, count: historyPos)
                    }
                }
                linear.withUnsafeBufferPointer { src in db.withUnsafeMutableBufferPointer { analyzer.process(src, into: $0) } }
                db.withUnsafeBufferPointer { averager.add($0) }
                frames.publish(average: averager.average, peak: averager.peak)
            }

            // Audio.
            audioOut.removeAll(keepingCapacity: true)
            block.withUnsafeBufferPointer { receiver.process(UnsafeBufferPointer(rebasing: $0[0..<n]), audio: &audioOut) }
            guard !audioOut.isEmpty else { continue }
            let rx = receiver.config
            let context = ModemContext(sampleRate: Receiver.audioRate, mode: rx.mode, bandwidthHz: rx.bandwidthHz, cwPitchHz: rx.cwPitchHz)
            audioOut.withUnsafeBufferPointer { modems.process(audio: $0, context: context) }
            audioOut.withUnsafeMutableBufferPointer { a in
                var gain = volume
                vDSP_vsmul(a.baseAddress!, 1, &gain, a.baseAddress!, 1, vDSP_Length(a.count))
                var count = Int32(a.count)
                vvtanhf(a.baseAddress!, a.baseAddress!, &count)
            }
            audioOut.withUnsafeBufferPointer { audio.push($0) }
            let signal = receiver.signalDb
            stats.withLock { $0.signalDb = signal }
        }
    }
}
```

Note: the `channelTap` closure captures the initial `config`, so a mode change made later still reports the original mode to IQ modems. This is acceptable in phase 1 because no IQ modems exist yet. Leave a one-line `// Context is the start-time config; refresh when IQ modems arrive.` comment above it.

- [ ] **Step 4: Implement `Sources/SubFloor/App/CPUUsage.swift`**

```swift
import Darwin
import Foundation

/// Process CPU time as a percentage of one core since the previous sample.
struct CPUUsage {
    private var lastCPU: Double = 0
    private var lastWall = Date()

    mutating func sample() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        let now = Date()
        defer { lastCPU = cpu; lastWall = now }
        let wall = now.timeIntervalSince(lastWall)
        return wall > 0 ? (cpu - lastCPU) / wall * 100 : 0
    }
}
```

- [ ] **Step 5: Add a temporary minimal app at `Sources/SubFloor/App/SubFloorApp.swift` to prove audio and engine end to end**

```swift
import AppKit
import DSPCore
import SwiftUI

@main
struct SubFloorApp: App {
    @State private var engine = EngineSmokeTest()

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup("SubFloor") {
            Text("Engine smoke test — you should hear a 1 kHz USB tone (14.200 MHz demo signal).")
                .padding(40)
                .onAppear { engine.start() }
        }
    }
}

@MainActor @Observable
final class EngineSmokeTest {
    let engine = DSPEngine()
    let source = SyntheticSource(centerFrequency: 14_100_000)

    func start() {
        let rx = Receiver.Config(inputRate: source.sampleRate, offsetHz: 100_000, mode: .usb, bandwidthHz: 2_700)
        try? engine.start(source: source, receiver: rx, spectrum: SpectrumSettings(), volume: 0.4)
    }
}
```

- [ ] **Step 6: Build and run**

Run: `swift build && swift run SubFloor`
Expected: a window opens and a steady 1 kHz tone plays. Quit with ⌘Q.

Run: `swift test`
Expected: every test still passes.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/SubFloor
git commit -m "feat(app): add DSP engine thread, audio output and smoke-test app

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Metal spectrum and waterfall renderer

**Files:**
- Create:
  - `Sources/SubFloor/Rendering/ShaderSource.swift`
  - `Sources/SubFloor/Rendering/Colormap.swift`
  - `Sources/SubFloor/Rendering/SpectrumRenderer.swift`
  - `Sources/SubFloor/Rendering/SpectrumMTKView.swift`
- Modify: `Sources/SubFloor/App/SubFloorApp.swift` (show the renderer in the smoke-test window)

**Interfaces:**
- Consumes: `SpectrumFrameStore` (Task 13).
- Produces:
  - `Colormap`: `enum Colormap: String, CaseIterable, Codable, Sendable { case turbo, viridis, grayscale; var label: String; func lut() -> [SIMD4<Float>] }`, which returns 256 entries.
  - `DisplayState`: `struct DisplayState: Equatable { startFraction, widthFraction: Double; dbMin, dbMax: Float; spectrumFraction: Float; showPeak: Bool; colormap: Colormap }`
  - `SpectrumRenderer`: `@MainActor final class SpectrumRenderer: NSObject, MTKViewDelegate { init?(device: MTLDevice, frames: SpectrumFrameStore); var displayProvider: (() -> DisplayState)? }`
  - `SpectrumInteraction`: `struct SpectrumInteraction`, with these `@MainActor` closures:
    - `zoom(factor, anchorFraction)`
    - `pan(deltaFraction)`
    - `click(fraction)`
    - `reset()`
    - `hover(CGPoint?)`, where the point is given in unit fractions with y = 0 at the top
    - `passbandEdges() -> (lower: Double, upper: Double)?`
    - `dragEdge(upper, fraction)`
  - `SpectrumMTKView`: `final class SpectrumMTKView: MTKView { var interaction: SpectrumInteraction? }`

- [ ] **Step 1: Implement `Sources/SubFloor/Rendering/ShaderSource.swift`**

```swift
/// Compiled at runtime with `MTLDevice.makeLibrary(source:options:)`.
enum ShaderSource {
    static let spectrum = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float viewStartBin;
        float viewBinCount;
        float dbMin;
        float dbMax;
        uint fftSize;
        uint waterfallRows;
        uint waterfallHead;
        float spectrumFraction;
        float2 viewSize;
        uint showPeak;
        float rowHeightPx;
    };

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut fullscreen(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    // Max over the bins that fall inside one pixel column (bounded work per pixel).
    static float columnMax(device const float *data, uint n, float b0, float b1) {
        int i0 = clamp(int(floor(b0)), 0, int(n) - 1);
        int i1 = clamp(int(ceil(b1)) - 1, i0, int(n) - 1);
        i1 = min(i1, i0 + 512);
        float m = -1000.0;
        for (int i = i0; i <= i1; i++) { m = max(m, data[i]); }
        return m;
    }

    static float columnMaxHalf(device const half *data, uint n, float b0, float b1) {
        int i0 = clamp(int(floor(b0)), 0, int(n) - 1);
        int i1 = clamp(int(ceil(b1)) - 1, i0, int(n) - 1);
        i1 = min(i1, i0 + 512);
        float m = -1000.0;
        for (int i = i0; i <= i1; i++) { m = max(m, float(data[i])); }
        return m;
    }

    fragment float4 spectrumFragment(VOut in [[stage_in]],
                                     device const float *average [[buffer(0)]],
                                     device const float *peak [[buffer(1)]],
                                     device const half *waterfall [[buffer(2)]],
                                     constant float4 *lut [[buffer(3)]],
                                     constant Uniforms &u [[buffer(4)]]) {
        float px = in.uv.x * u.viewSize.x;
        float py = in.uv.y * u.viewSize.y;
        float binsPerPx = u.viewBinCount / u.viewSize.x;
        float b0 = u.viewStartBin + floor(px) * binsPerPx;
        float b1 = b0 + max(binsPerPx, 1.0);
        float range = max(u.dbMax - u.dbMin, 1.0);
        float specH = u.spectrumFraction * u.viewSize.y;
        float4 background = float4(0.035, 0.047, 0.067, 1.0);

        if (py < specH) {
            float v = clamp((columnMax(average, u.fftSize, b0, b1) - u.dbMin) / range, 0.0, 1.0);
            float vPrev = clamp((columnMax(average, u.fftSize, b0 - binsPerPx, b0) - u.dbMin) / range, 0.0, 1.0);
            float y = (1.0 - v) * specH;
            float yPrev = (1.0 - vPrev) * specH;
            float top = min(y, yPrev) - 0.75;
            float bottom = max(y, yPrev) + 0.75;
            float4 color = background;
            if (py > y) {
                float t = (py - y) / max(specH - y, 1.0);
                color = mix(float4(0.20, 0.55, 0.85, 0.38), float4(0.05, 0.12, 0.22, 0.20), t);
                color = float4(mix(background.rgb, color.rgb, color.a), 1.0);
            }
            if (u.showPeak != 0) {
                float pv = clamp((columnMax(peak, u.fftSize, b0, b1) - u.dbMin) / range, 0.0, 1.0);
                if (abs(py - (1.0 - pv) * specH) < 0.8) { color = float4(1.0, 0.75, 0.30, 0.9); }
            }
            if (py >= top && py <= bottom) { color = float4(0.45, 0.88, 1.0, 1.0); }
            if (specH - py < 1.0) { color = float4(1.0, 1.0, 1.0, 0.12); }
            return color;
        }

        uint row = uint((py - specH) / max(u.rowHeightPx, 1.0));
        if (row >= u.waterfallRows) { return background; }
        uint ringRow = (u.waterfallHead + u.waterfallRows - row) % u.waterfallRows;
        float db = columnMaxHalf(waterfall + ringRow * u.fftSize, u.fftSize, b0, b1);
        float v = clamp((db - u.dbMin) / range, 0.0, 1.0);
        return lut[uint(v * 255.0)];
    }
    """#
}
```

- [ ] **Step 2: Implement `Sources/SubFloor/Rendering/Colormap.swift`**

```swift
import simd

enum Colormap: String, CaseIterable, Codable, Sendable {
    case turbo, viridis, grayscale

    var label: String { rawValue.capitalized }

    func lut() -> [SIMD4<Float>] {
        (0..<256).map { i in
            let t = Float(i) / 255
            switch self {
            case .turbo: return Self.turbo(t)
            case .viridis: return Self.viridis(t)
            case .grayscale: return SIMD4(t, t, t, 1)
            }
        }
    }

    private static func turbo(_ x: Float) -> SIMD4<Float> {
        let r = 0.13572138 + x * (4.61539260 + x * (-42.66032258 + x * (132.13108234 + x * (-152.94239396 + x * 59.28637943))))
        let g = 0.09140261 + x * (2.19418839 + x * (4.84296658 + x * (-14.18503333 + x * (4.27729857 + x * 2.82956604))))
        let b = 0.10667330 + x * (12.64194608 + x * (-60.58204836 + x * (110.36276771 + x * (-89.90310912 + x * 27.34824973))))
        return SIMD4(simd_clamp(r, 0, 1), simd_clamp(g, 0, 1), simd_clamp(b, 0, 1), 1)
    }

    private static func viridis(_ t: Float) -> SIMD4<Float> {
        let c0 = SIMD3<Float>(0.2777273272234177, 0.005407344544966578, 0.3340998053353061)
        let c1 = SIMD3<Float>(0.1050930431085774, 1.404613529898575, 1.384590162594685)
        let c2 = SIMD3<Float>(-0.3308618287255563, 0.214847559468213, 0.09509516302823659)
        let c3 = SIMD3<Float>(-4.634230498983486, -5.799100973351585, -19.33244095627987)
        let c4 = SIMD3<Float>(6.228269936347081, 14.17993336680509, 56.69055260068105)
        let c5 = SIMD3<Float>(4.776384997670288, -13.74514537774601, -65.35303263337234)
        let c6 = SIMD3<Float>(-5.435455855934631, 4.645852612178535, 26.3124352495832)
        let c = c0 + t * (c1 + t * (c2 + t * (c3 + t * (c4 + t * (c5 + t * c6)))))
        let clamped = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return SIMD4(clamped, 1)
    }
}
```

- [ ] **Step 3: Implement `Sources/SubFloor/Rendering/SpectrumRenderer.swift`**

```swift
import MetalKit
import simd

struct DisplayState: Equatable {
    var startFraction: Double = 0
    var widthFraction: Double = 1
    var dbMin: Float = -130
    var dbMax: Float = -20
    var spectrumFraction: Float = 0.4
    var showPeak = false
    var colormap: Colormap = .turbo
}

private struct Uniforms {
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
}

/// Single full-screen pass: spectrum trace in the top band, scrolling waterfall below.
/// All zoom/pan is done with uniforms; the CPU only uploads one spectrum and one waterfall row per frame.
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
    private var lutBuffer: MTLBuffer!
    private var lutColormap: Colormap?
    private var fftSize = 0
    private var rows = 0
    private var head = 0
    private var slot = 0
    private var sequence: UInt64 = 0
    private var latestAverage: [Float] = []
    private var latestPeak: [Float] = []

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
        latestAverage = empty
        latestPeak = empty
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let state = displayProvider?() ?? DisplayState()
        if lutColormap != state.colormap {
            let lut = state.colormap.lut()
            lutBuffer = device.makeBuffer(bytes: lut, length: lut.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
            lutColormap = state.colormap
        }

        if let seq = frames.read(after: sequence, average: &latestAverage, peak: &latestPeak) {
            sequence = seq
            if latestAverage.count != fftSize {
                let keepAverage = latestAverage, keepPeak = latestPeak
                allocate(fftSize: keepAverage.count)
                latestAverage = keepAverage
                latestPeak = keepPeak
            }
            head = (head + 1) % rows
            let row = waterfall.contents().bindMemory(to: Float16.self, capacity: rows * fftSize) + head * fftSize
            for i in 0..<fftSize { row[i] = Float16(latestAverage[i]) }
        }

        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }
        inFlight.wait()
        slot = (slot + 1) % 3
        averageBuffers[slot].contents().copyMemory(from: latestAverage, byteCount: fftSize * 4)
        peakBuffers[slot].contents().copyMemory(from: latestPeak, byteCount: fftSize * 4)

        let size = view.drawableSize
        var uniforms = Uniforms(
            viewStartBin: Float(state.startFraction * Double(fftSize)),
            viewBinCount: Float(state.widthFraction * Double(fftSize)),
            dbMin: state.dbMin, dbMax: state.dbMax,
            fftSize: UInt32(fftSize), waterfallRows: UInt32(rows), waterfallHead: UInt32(head),
            spectrumFraction: state.spectrumFraction,
            viewSize: SIMD2(Float(size.width), Float(size.height)),
            showPeak: state.showPeak ? 1 : 0,
            rowHeightPx: Float(view.window?.backingScaleFactor ?? 2))

        let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(averageBuffers[slot], offset: 0, index: 0)
        encoder.setFragmentBuffer(peakBuffers[slot], offset: 0, index: 1)
        encoder.setFragmentBuffer(waterfall, offset: 0, index: 2)
        encoder.setFragmentBuffer(lutBuffer, offset: 0, index: 3)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 4)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.present(drawable)
        commands.commit()
    }
}
```

If the compiler rejects the `MTKViewDelegate` conformance under strict concurrency (a nonisolated requirement satisfied by a main-actor method), write `@preconcurrency MTKViewDelegate` in the inheritance clause instead. MTKView always calls `draw(in:)` on the main thread.

- [ ] **Step 4: Implement `Sources/SubFloor/Rendering/SpectrumMTKView.swift`**

```swift
import AppKit
import MetalKit

struct SpectrumInteraction {
    var zoom: @MainActor (_ factor: Double, _ anchorFraction: Double) -> Void
    var pan: @MainActor (_ deltaFraction: Double) -> Void
    var click: @MainActor (_ fraction: Double) -> Void
    var reset: @MainActor () -> Void
    var hover: @MainActor (_ unitPoint: CGPoint?) -> Void
    var passbandEdges: @MainActor () -> (lower: Double, upper: Double)?
    var dragEdge: @MainActor (_ upper: Bool, _ fraction: Double) -> Void
}

/// Mouse/trackpad: click tunes, drag pans, pinch or ⌥-scroll (or a plain mouse wheel) zooms,
/// two-finger scroll pans, passband edges drag to set bandwidth, double-click resets the view.
final class SpectrumMTKView: MTKView {
    var interaction: SpectrumInteraction?

    private enum Drag {
        case none
        case pending(start: CGPoint)
        case pan(last: CGPoint)
        case edge(upper: Bool)
    }

    private var drag: Drag = .none
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// Point in view coordinates with y measured from the top.
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    private func fraction(_ p: CGPoint) -> Double { Double(p.x / max(bounds.width, 1)) }
    private func unit(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / max(bounds.width, 1), y: p.y / max(bounds.height, 1)) }

    private func edgeHit(_ p: CGPoint) -> Bool? {
        guard let edges = interaction?.passbandEdges() else { return nil }
        if abs(p.x - edges.upper * bounds.width) < 5 { return true }
        if abs(p.x - edges.lower * bounds.width) < 5 { return false }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard let interaction else { return }
        let x = fraction(point(event))
        if event.modifierFlags.contains(.option) || !event.hasPreciseScrollingDeltas {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            interaction.zoom(exp(-Double(delta)), x)
        } else {
            let dx = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            interaction.pan(-Double(dx / max(bounds.width, 1)))
        }
    }

    override func magnify(with event: NSEvent) {
        interaction?.zoom(1 / (1 + Double(event.magnification)), fraction(point(event)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        if let upper = edgeHit(p) {
            drag = .edge(upper: upper)
        } else {
            drag = .pending(start: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        switch drag {
        case .pending(let start) where hypot(p.x - start.x, p.y - start.y) > 3:
            interaction?.pan(-Double((p.x - start.x) / max(bounds.width, 1)))
            drag = .pan(last: p)
        case .pan(let last):
            interaction?.pan(-Double((p.x - last.x) / max(bounds.width, 1)))
            drag = .pan(last: p)
        case .edge(let upper):
            interaction?.dragEdge(upper, fraction(p))
        default:
            break
        }
        interaction?.hover(unit(p))
    }

    override func mouseUp(with event: NSEvent) {
        if case .pending = drag {
            if event.clickCount == 2 {
                interaction?.reset()
            } else {
                interaction?.click(fraction(point(event)))
            }
        }
        drag = .none
    }

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        (edgeHit(p) != nil ? NSCursor.resizeLeftRight : NSCursor.crosshair).set()
        interaction?.hover(unit(p))
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        interaction?.hover(nil)
    }
}
```

- [ ] **Step 5: Show the renderer in the smoke-test window**

In `SubFloorApp.swift`, replace the `Text(...)` with a minimal representable that only draws:
```swift
            SmokeSpectrum(frames: engine.engine.frames)
                .frame(minWidth: 900, minHeight: 500)
                .onAppear { engine.start() }
```
and add the representable to the same file:
```swift
import MetalKit

struct SmokeSpectrum: NSViewRepresentable {
    let frames: SpectrumFrameStore
    final class Coordinator { var renderer: SpectrumRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> SpectrumMTKView {
        let view = SpectrumMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120
        context.coordinator.renderer = SpectrumRenderer(device: view.device!, frames: frames)
        view.delegate = context.coordinator.renderer
        return view
    }
    func updateNSView(_ view: SpectrumMTKView, context: Context) {}
}
```

- [ ] **Step 6: Build and run**

Run: `swift run SubFloor`
Expected:
- A cyan spectrum trace sits on top and a Turbo waterfall scrolls below.
- The demo carriers are visible: the AM station at 13.65 MHz, CW at 14.03, the FT8 line, the USB tone at 14.2, and NFM at 14.5.
- The tone is still audible.

Then check the frame rate: open Activity Monitor and confirm SubFloor's CPU stays well under 30%.

- [ ] **Step 7: Commit**

```bash
git add Sources/SubFloor
git commit -m "feat(render): add Metal spectrum + waterfall renderer and interactive MTKView

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 15: AppModel — radio state, tuning, sources, bookmarks, modems, persistence

**Files:**
- Create: `Sources/SubFloor/App/AppModel.swift`

**Interfaces:**
- Consumes: everything above.
- Produces (`@MainActor @Observable final class AppModel`), used by every view in Task 16:
  - Supporting types: `Banner { kind: .info/.warning/.error; message; action: BannerAction? }`, `BannerAction { retry, reduceGain }`, `SourceKind { sdrplay, synthetic, file }`, `HoverReadout { point: CGPoint; hz: Double; db: Float? }`
  - Radio state (read-only from views):
    - `isRunning`, `sourceKind`, `preferredSource`, `deviceName`
    - `centerHz`, `vfoHz`, `mode`, `bandwidthHz`
    - `upconverter`, `hardware: SDRplaySettings`
    - `sampleRate`, `lnaStateCount`, `passbandRange`, `passbandEdgeFractions`
  - Settable properties: `cwPitchHz`, `squelchEnabled`, `squelchDb`, `agcSpeed`, `volume`, `spectrum`, `dbMin`, `dbMax`, `colormap`, `showPeak`, `spectrumFraction`, `showBookmarks`, `quickTuneVisible`, `banner`
  - View and stats state: `viewport`, `hover`, `bookmarks`, `activeModem`, `activeModemID`, `signalDb`, `underruns`, `cpuPercent`, `displayState`, `visibleBookmarks`
  - Actions:
    - Run control: `start()`, `stop()`, `toggleRun()`, `retry()`, `perform(_ action: BannerAction)`, `useSource(_:)`, `openIQFile()`
    - Tuning: `tune(to:)`, `setVFO(_:)`, `stepVFO(_:)`, `setMode(_:)`, `cycleMode(_:)`, `setBandwidth(_:)`
    - Upconverter and hardware: `setUpconverter(_:)`, `setUpconverterLO(_:)`, `updateHardware(_:)`
    - Spectrum interaction: `zoom(by:anchor:)`, `pan(byFraction:)`, `resetView()`, `click(atFraction:)`, `dragPassbandEdge(upper:fraction:)`, `hover(at:)`
    - Bookmarks: `select(_ bookmark:)`, `addBookmark()`, `deleteBookmark(_ id:)`, `importBookmarks()`, `exportBookmarks()`
    - Modems: `activateModem(id:)`

- [ ] **Step 1: Implement `Sources/SubFloor/App/AppModel.swift`**

```swift
import AppKit
import DSPCore
import Modems
import Observation
import SDRplayKit
import SubFloorCore
import SwiftUI
import UniformTypeIdentifiers

enum BannerAction: Equatable { case retry, reduceGain }

struct Banner: Identifiable, Equatable {
    enum Kind { case info, warning, error }
    let id = UUID()
    var kind: Kind
    var message: String
    var action: BannerAction?
}

enum SourceKind: String, CaseIterable, Identifiable, Codable {
    case sdrplay = "RSP1B", synthetic = "Demo", file = "IQ File"
    var id: String { rawValue }
}

struct HoverReadout: Equatable {
    var point: CGPoint     // unit coordinates, y = 0 at top of the spectrum+waterfall area
    var hz: Double
    var db: Float?
}

private struct SessionState: Codable {
    var vfoHz: Double
    var centerHz: Double
    var mode: DemodMode
    var bandwidthHz: Double
    var upconverter: Upconverter
    var hardware: SDRplaySettings
    var spectrum: SpectrumSettings
    var dbMin: Float
    var dbMax: Float
    var colormap: Colormap
    var showBookmarks: Bool
    var volume: Float
    var agcSpeed: AGCSpeed
    var cwPitchHz: Double
    var preferredSource: SourceKind
}

@MainActor @Observable
final class AppModel {
    // MARK: Radio (display frequencies)
    private(set) var isRunning = false
    private(set) var sourceKind: SourceKind = .synthetic
    private(set) var preferredSource: SourceKind = .sdrplay
    private(set) var deviceName = "Not started"
    private(set) var centerHz: Double = 14_100_000
    private(set) var vfoHz: Double = 14_200_000
    private(set) var mode: DemodMode = .usb
    private(set) var bandwidthHz: Double = 2_700
    private(set) var upconverter = Upconverter()
    private(set) var hardware = SDRplaySettings()
    var cwPitchHz: Double = 700 { didSet { pushReceiver() } }
    var squelchEnabled = false { didSet { pushReceiver() } }
    var squelchDb: Float = -80 { didSet { pushReceiver() } }
    var agcSpeed: AGCSpeed = .medium { didSet { pushReceiver() } }
    var volume: Float = 0.5 { didSet { engine.update(volume: volume) } }

    // MARK: Display
    var spectrum = SpectrumSettings() { didSet { engine.update(spectrum: spectrum) } }
    private(set) var viewport = SpectrumViewport(captureCenterHz: 14_100_000, captureSpanHz: 2_000_000)
    var dbMin: Float = -130
    var dbMax: Float = -20
    var colormap: Colormap = .turbo
    var showPeak = false
    var spectrumFraction: CGFloat = 0.4
    private(set) var hover: HoverReadout?

    // MARK: Bookmarks, modems, UI
    private(set) var bookmarks: [Bookmark] = []
    var showBookmarks = true
    private(set) var activeModem: (any Modem)?
    var activeModemID: String? { activeModem.map { type(of: $0).info.id } }
    var banner: Banner?
    var quickTuneVisible = false
    private(set) var signalDb: Float = -200
    private(set) var underruns = 0
    private(set) var cpuPercent: Double = 0

    let engine = DSPEngine()
    private var sdrplay: SDRplayDevice?
    private let synthetic = SyntheticSource()
    private var fileSource: IQFileSource?
    private let bookmarkStore = BookmarkStore(url: BookmarkStore.defaultURL)
    private var statsTimer: Timer?
    private var cpu = CPUUsage()
    private var lastSavedSession: Data?

    init() {
        let (loaded, result) = bookmarkStore.load()
        bookmarks = loaded
        if result == .recoveredFromCorrupt {
            banner = Banner(kind: .warning, message: "The bookmarks file was unreadable. It was moved to bookmarks.corrupt.json and the defaults were restored.")
        }
        restoreSession()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
    }

    // MARK: Derived

    private var activeSource: any IQSource {
        switch sourceKind {
        case .sdrplay: sdrplay ?? synthetic
        case .synthetic: synthetic
        case .file: fileSource ?? synthetic
        }
    }

    var sampleRate: Double { sourceKind == .file ? (fileSource?.sampleRate ?? hardware.outputRate) : hardware.outputRate }

    var lnaStateCount: Int { RSP1B.lnaStateCount(forHz: upconverter.hardware(fromDisplay: centerHz)) }

    var passbandRange: ClosedRange<Double> {
        let c = vfoHz + mode.passbandOffset(bandwidth: bandwidthHz)
        return (c - bandwidthHz / 2)...(c + bandwidthHz / 2)
    }

    var passbandEdgeFractions: (lower: Double, upper: Double)? {
        (viewport.fraction(ofHz: passbandRange.lowerBound), viewport.fraction(ofHz: passbandRange.upperBound))
    }

    var displayState: DisplayState {
        DisplayState(startFraction: viewport.startFractionOfCapture, widthFraction: viewport.widthFractionOfCapture,
                     dbMin: dbMin, dbMax: dbMax, spectrumFraction: Float(spectrumFraction),
                     showPeak: showPeak, colormap: colormap)
    }

    var visibleBookmarks: [Bookmark] {
        guard showBookmarks else { return [] }
        return bookmarks.filter { $0.frequencyHz >= viewport.lowerHz && $0.frequencyHz <= viewport.upperHz }
    }

    private var receiverConfig: Receiver.Config {
        Receiver.Config(inputRate: sampleRate, offsetHz: vfoHz - centerHz, mode: mode, bandwidthHz: bandwidthHz,
                        cwPitchHz: cwPitchHz, squelchDb: squelchEnabled ? squelchDb : nil, agc: agcSpeed)
    }

    private func pushReceiver() { engine.update(receiver: receiverConfig) }

    // MARK: Run control

    func toggleRun() { isRunning ? stop() : start() }

    func start() {
        stop()
        var kind = preferredSource
        if kind == .sdrplay && sdrplay == nil {
            do {
                let device = try SDRplayDevice.open()
                device.onEvent = { [weak self] event in
                    guard let self else { return }
                    Task { @MainActor in self.handle(event) }
                }
                sdrplay = device
            } catch {
                banner = Banner(kind: .warning, message: "No RSP found — demo signal. \(error)", action: .retry)
                kind = .synthetic
            }
        }
        if kind == .file && fileSource == nil { kind = .synthetic }
        sourceKind = kind

        switch kind {
        case .sdrplay:
            do { try sdrplay?.apply(hardware) } catch { banner = Banner(kind: .error, message: "\(error)") }
        case .synthetic:
            synthetic.setSampleRate(hardware.outputRate)
        case .file:
            if let fileSource { centerHz = fileSource.centerFrequency }
        }
        if kind != .file {
            centerHz = clampedCenter(centerHz)
            retuneHardware()
        }
        if abs(vfoHz - centerHz) > sampleRate * TuningPlanner.usableFraction { vfoHz = centerHz + TuningPlanner.dcOffset(sampleRate: sampleRate) }
        viewport.setCapture(centerHz: centerHz, spanHz: sampleRate)
        do {
            try engine.start(source: activeSource, receiver: receiverConfig, spectrum: spectrum, volume: volume)
            isRunning = true
            deviceName = activeSource.name
        } catch {
            banner = Banner(kind: .error, message: "Could not start: \(error)", action: .retry)
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
    }

    func retry() {
        banner = nil
        if preferredSource == .sdrplay, let device = sdrplay {
            stop()
            device.close()
            sdrplay = nil
        }
        start()
    }

    func perform(_ action: BannerAction) {
        switch action {
        case .retry: retry()
        case .reduceGain:
            updateHardware { $0.ifGainReductionDb = min($0.ifGainReductionDb + 6, RSP1B.ifGainReductionRange.upperBound) }
            banner = nil
        }
    }

    func useSource(_ kind: SourceKind) {
        if kind == .file && fileSource == nil {
            openIQFile()
            return
        }
        preferredSource = kind
        if isRunning || kind != .sdrplay { start() }
    }

    func openIQFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.message = "Choose a stereo I/Q WAV recording"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let center = Self.centerFrequency(fromFileName: url.lastPathComponent) ?? centerHz
        do {
            fileSource = try IQFileSource(url: url, centerFrequency: center)
            preferredSource = .file
            vfoHz = center
            start()
        } catch {
            banner = Banner(kind: .error, message: "Could not open \(url.lastPathComponent): \(error)")
        }
    }

    /// Picks "…_14074000Hz_…" style centre frequencies out of SDR#/SDRuno file names.
    static func centerFrequency(fromFileName name: String) -> Double? {
        guard let match = name.firstMatch(of: /(\d{4,})Hz/) else { return nil }
        return Double(match.1)
    }

    private func handle(_ event: SDRplayEvent) {
        switch event {
        case .overload(let detected):
            if detected {
                banner = Banner(kind: .warning, message: "ADC overload — reduce gain.", action: .reduceGain)
            } else if banner?.action == .reduceGain {
                banner = nil
            }
        case .deviceRemoved, .deviceFailure:
            stop()
            sdrplay?.close()
            sdrplay = nil
            banner = Banner(kind: .error, message: event == .deviceRemoved ? "RSP1B disconnected." : "RSP1B reported a failure.", action: .retry)
        case .gainChanged:
            break
        }
    }

    // MARK: Tuning

    /// Direct tune (typed frequency, quick-tune, bookmark): retunes hardware and resets the view.
    func tune(to displayHz: Double) {
        let hz = clampedDisplay(displayHz)
        vfoHz = hz
        if sourceKind == .file {
            vfoHz = min(max(hz, centerHz - sampleRate * 0.45), centerHz + sampleRate * 0.45)
        } else {
            centerHz = clampedCenter(TuningPlanner.center(forVFO: hz, sampleRate: sampleRate))
            retuneHardware()
        }
        viewport.setCapture(centerHz: centerHz, spanHz: sampleRate)
        viewport.reset()
        pushReceiver()
    }

    /// VFO move inside the spectrum (click, drag, keys). Retunes only if the VFO leaves the usable span.
    func setVFO(_ displayHz: Double) {
        var hz = clampedDisplay(displayHz)
        if sourceKind == .file {
            hz = min(max(hz, centerHz - sampleRate * 0.45), centerHz + sampleRate * 0.45)
        } else if let newCenter = TuningPlanner.retuneIfNeeded(vfo: hz, center: centerHz, sampleRate: sampleRate) {
            centerHz = clampedCenter(newCenter)
            retuneHardware()
            viewport.setCapture(centerHz: centerHz, spanHz: sampleRate)
        }
        vfoHz = hz
        viewport.ensureVisible(hz)
        pushReceiver()
    }

    func stepVFO(_ steps: Int) {
        let step = mode.tuningStep
        setVFO(((vfoHz / step).rounded() + Double(steps)) * step)
    }

    func setMode(_ newMode: DemodMode) {
        guard newMode != mode else { return }
        mode = newMode
        bandwidthHz = newMode.defaultBandwidth
        pushReceiver()
    }

    func cycleMode(_ delta: Int) {
        let all = DemodMode.allCases
        let i = all.firstIndex(of: mode)!
        setMode(all[(i + delta + all.count) % all.count])
    }

    func setBandwidth(_ hz: Double) {
        bandwidthHz = min(max(hz, mode.bandwidthRange.lowerBound), mode.bandwidthRange.upperBound).rounded()
        pushReceiver()
    }

    func setUpconverter(_ enabled: Bool) {
        guard enabled != upconverter.enabled else { return }
        upconverter.enabled = enabled
        centerHz = clampedCenter(centerHz)
        retuneHardware()
    }

    func setUpconverterLO(_ hz: Double) {
        upconverter.loHz = hz
        retuneHardware()
    }

    private func clampedDisplay(_ hz: Double) -> Double {
        let lo = max(upconverter.display(fromHardware: RSP1B.frequencyRange.lowerBound), 1_000)
        let hi = upconverter.display(fromHardware: RSP1B.frequencyRange.upperBound)
        return min(max(hz, lo), hi)
    }

    private func clampedCenter(_ hz: Double) -> Double {
        upconverter.display(fromHardware: RSP1B.clampHardware(upconverter.hardware(fromDisplay: hz)))
    }

    private func retuneHardware() {
        guard sourceKind != .file else { return }
        synthetic.antennaOffset = upconverter.enabled ? upconverter.loHz : 0
        do {
            try activeSource.setCenterFrequency(upconverter.hardware(fromDisplay: centerHz))
        } catch {
            banner = Banner(kind: .error, message: "Tune failed: \(error)")
        }
        if !upconverter.enabled && vfoHz < 50_000 {
            banner = Banner(kind: .info, message: "Below 50 kHz the RSP1B is weak — enable HamItUp if it is connected.")
        }
        let maxLNA = lnaStateCount - 1
        if hardware.lnaState > maxLNA { updateHardware { $0.lnaState = maxLNA } }
    }

    // MARK: Hardware settings

    func updateHardware(_ change: (inout SDRplaySettings) -> Void) {
        var s = hardware
        change(&s)
        s.lnaState = min(max(s.lnaState, 0), lnaStateCount - 1)
        s.ifGainReductionDb = min(max(s.ifGainReductionDb, RSP1B.ifGainReductionRange.lowerBound), RSP1B.ifGainReductionRange.upperBound)
        s.ifBandwidthKHz = RSP1B.ifBandwidthKHz(sampleRate: s.sampleRate, decimation: s.decimation)
        let rateChanged = s.outputRate != hardware.outputRate
        hardware = s
        if rateChanged {
            if isRunning { start() } else {
                synthetic.setSampleRate(s.outputRate)
                viewport.setCapture(centerHz: centerHz, spanHz: sampleRate)
            }
            return
        }
        do { try sdrplay?.apply(s) } catch { banner = Banner(kind: .error, message: "\(error)") }
    }

    // MARK: Spectrum interaction (never retunes except through setVFO)

    func zoom(by factor: Double, anchor: Double) { viewport.zoom(by: factor, anchorFraction: anchor) }
    func pan(byFraction f: Double) { viewport.pan(byFraction: f) }
    func resetView() { viewport.reset() }

    func click(atFraction f: Double) {
        let step = min(mode.tuningStep, mode == .wfm ? 100_000 : 1_000)
        setVFO((viewport.hz(atFraction: f) / step).rounded() * step)
    }

    func dragPassbandEdge(upper: Bool, fraction f: Double) {
        let hz = viewport.hz(atFraction: f)
        switch mode {
        case .usb: setBandwidth(hz - vfoHz - 100)
        case .lsb: setBandwidth(vfoHz - 100 - hz)
        default: setBandwidth(2 * abs(hz - vfoHz))
        }
    }

    func hover(at unit: CGPoint?) {
        guard let unit else { hover = nil; return }
        let sf = Double(spectrumFraction)
        let db: Float? = Double(unit.y) <= sf ? dbMax - Float(Double(unit.y) / sf) * (dbMax - dbMin) : nil
        hover = HoverReadout(point: unit, hz: viewport.hz(atFraction: Double(unit.x)), db: db)
    }

    // MARK: Bookmarks

    func select(_ bookmark: Bookmark) {
        setUpconverter(bookmark.upconverter)
        mode = bookmark.mode
        bandwidthHz = bookmark.bandwidthHz
        tune(to: bookmark.frequencyHz)
    }

    func addBookmark() {
        bookmarks.append(Bookmark(name: "\(FrequencyFormatter.short(vfoHz)) \(mode.label)", frequencyHz: vfoHz, mode: mode,
                                  bandwidthHz: bandwidthHz, upconverter: upconverter.enabled, group: "Saved"))
        saveBookmarks()
    }

    func deleteBookmark(_ id: Bookmark.ID) {
        bookmarks.removeAll { $0.id == id }
        saveBookmarks()
    }

    func importBookmarks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let incoming = try BookmarkStore.read(from: url)
            let existing = Set(bookmarks.map(\.id))
            bookmarks += incoming.filter { !existing.contains($0.id) }
            saveBookmarks()
        } catch {
            banner = Banner(kind: .error, message: "Import failed: \(error.localizedDescription)")
        }
    }

    func exportBookmarks() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SubFloor Bookmarks.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try BookmarkStore.write(bookmarks, to: url) } catch {
            banner = Banner(kind: .error, message: "Export failed: \(error.localizedDescription)")
        }
    }

    private func saveBookmarks() {
        do { try bookmarkStore.save(bookmarks) } catch {
            banner = Banner(kind: .error, message: "Could not save bookmarks: \(error.localizedDescription)")
        }
    }

    // MARK: Modems

    func activateModem(id: String?) {
        guard let id, let type = ModemRegistry.type(withID: id) else {
            activeModem = nil
            engine.modems.set(nil)
            return
        }
        let modem = type.init()
        activeModem = modem
        engine.modems.set(modem)
        if let preferred = type.info.preferredMode {
            setMode(preferred)
            if let bw = type.info.preferredBandwidth { setBandwidth(bw) }
        }
    }

    // MARK: Stats & persistence

    private func refreshStats() {
        signalDb = engine.stats.withLock { $0.signalDb }
        underruns = engine.audio.underruns.load(ordering: .relaxed)
        cpuPercent = cpu.sample()
        saveSessionIfChanged()
    }

    private func saveSessionIfChanged() {
        let state = SessionState(vfoHz: vfoHz, centerHz: centerHz, mode: mode, bandwidthHz: bandwidthHz, upconverter: upconverter,
                                 hardware: hardware, spectrum: spectrum, dbMin: dbMin, dbMax: dbMax, colormap: colormap,
                                 showBookmarks: showBookmarks, volume: volume, agcSpeed: agcSpeed, cwPitchHz: cwPitchHz,
                                 preferredSource: preferredSource == .file ? .sdrplay : preferredSource)
        guard let data = try? JSONEncoder().encode(state), data != lastSavedSession else { return }
        UserDefaults.standard.set(data, forKey: "session")
        lastSavedSession = data
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: "session"),
              let s = try? JSONDecoder().decode(SessionState.self, from: data) else { return }
        vfoHz = s.vfoHz; centerHz = s.centerHz; mode = s.mode; bandwidthHz = s.bandwidthHz
        upconverter = s.upconverter; hardware = s.hardware; spectrum = s.spectrum
        dbMin = s.dbMin; dbMax = s.dbMax; colormap = s.colormap; showBookmarks = s.showBookmarks
        volume = s.volume; agcSpeed = s.agcSpeed; cwPitchHz = s.cwPitchHz; preferredSource = s.preferredSource
        lastSavedSession = data
    }
}

extension SDRplayEvent: Equatable {
    public static func == (a: SDRplayEvent, b: SDRplayEvent) -> Bool {
        switch (a, b) {
        case (.deviceRemoved, .deviceRemoved), (.deviceFailure, .deviceFailure): true
        case let (.overload(x), .overload(y)): x == y
        case let (.gainChanged(x), .gainChanged(y)): x == y
        default: false
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: the build succeeds. AppModel isn't wired into a view until Task 16. Fix any strict-concurrency diagnostics in place, keeping the same structure. For example, if `Timer`'s closure warns, keep the `MainActor.assumeIsolated` pattern.

- [ ] **Step 3: Commit**

```bash
git add Sources/SubFloor/App/AppModel.swift
git commit -m "feat(app): add AppModel for tuning, sources, bookmarks, modems and persistence

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: SwiftUI interface

**Files:**
- Create:
  - `Sources/SubFloor/UI/Theme.swift`
  - `Sources/SubFloor/UI/ContentView.swift`
  - `Sources/SubFloor/UI/TopBarView.swift`
  - `Sources/SubFloor/UI/FrequencyReadout.swift`
  - `Sources/SubFloor/UI/SidebarView.swift`
  - `Sources/SubFloor/UI/SpectrumArea.swift`
  - `Sources/SubFloor/UI/ModemPanelView.swift`
  - `Sources/SubFloor/UI/StatusBarView.swift`
  - `Sources/SubFloor/UI/QuickTuneView.swift`
  - `Sources/SubFloor/UI/BannerView.swift`
  - `Sources/SubFloor/UI/Controls.swift`
- Modify: `Sources/SubFloor/App/SubFloorApp.swift` (the real app replaces the smoke test)

**Interfaces:**
- Consumes: `AppModel` (Task 15), `SpectrumRenderer`, `SpectrumMTKView`, `SpectrumInteraction` (Task 14).
- Produces: `ContentView`, which is the window root and expects `AppModel` in the environment.

- [ ] **Step 1: `Sources/SubFloor/UI/Theme.swift` and `Sources/SubFloor/UI/Controls.swift`**

```swift
// Theme.swift
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.36, green: 0.84, blue: 1.0)
    static let vfo = Color(red: 1.0, green: 0.72, blue: 0.28)
    static let passband = vfo.opacity(0.12)
    static let spectrumBackground = Color(red: 0.035, green: 0.047, blue: 0.067)
    static let grid = Color.white.opacity(0.07)
    static let readout = Font.system(size: 30, weight: .medium, design: .monospaced)
}

extension Color {
    init?(hex: String?) {
        guard let hex, let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
```

```swift
// Controls.swift
import AppKit
import SwiftUI

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range).controlSize(.small)
        }
    }
}

/// Thin vertical slider used on the spectrum's right edge.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let h = geo.size.height
                let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.08)).frame(width: 4)
                    Capsule().fill(Theme.accent.opacity(0.7)).frame(width: 4, height: max(4, h * f))
                    Circle().fill(.white).frame(width: 12, height: 12).shadow(radius: 2).offset(y: -(h * f) + 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let nf = 1 - min(max(g.location.y / h, 0), 1)
                    value = range.lowerBound + nf * (range.upperBound - range.lowerBound)
                })
            }
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text("\(Int(value))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }
    }
}

/// Captures scroll-wheel ticks and clicks for an overlaid SwiftUI view.
struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (Int) -> Void
    var onClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onClick = onClick
    }

    final class CatcherView: NSView {
        var onScroll: (Int) -> Void = { _ in }
        var onClick: () -> Void = {}
        private var accumulated: CGFloat = 0

        override func scrollWheel(with event: NSEvent) {
            if event.hasPreciseScrollingDeltas {
                accumulated += event.scrollingDeltaY
                while abs(accumulated) >= 12 {
                    onScroll(accumulated > 0 ? 1 : -1)
                    accumulated -= accumulated > 0 ? 12 : -12
                }
            } else if event.scrollingDeltaY != 0 {
                onScroll(event.scrollingDeltaY > 0 ? 1 : -1)
            }
        }

        override func mouseDown(with event: NSEvent) { onClick() }
    }
}
```

- [ ] **Step 2: `Sources/SubFloor/UI/FrequencyReadout.swift`**

```swift
import SubFloorCore
import SwiftUI

/// "0.014.074.000" readout: scroll over any digit to step it, click to type a frequency.
struct FrequencyReadout: View {
    let hz: Double
    var onCommit: (Double) -> Void
    var onStep: (Double) -> Void

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing {
            TextField("Frequency", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.readout)
                .frame(width: 250)
                .focused($focused)
                .onSubmit {
                    if let v = FrequencyParser.parse(text) { onCommit(v) }
                    editing = false
                }
                .onExitCommand { editing = false }
                .onChange(of: focused) { if !focused { editing = false } }
                .onAppear {
                    text = FrequencyFormatter.grouped(hz)
                    focused = true
                }
        } else {
            let digits = FrequencyFormatter.readoutDigits(hz)
            let firstSignificant = digits.firstIndex { $0 != 0 } ?? 9
            HStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { i in
                    if i == 1 || i == 4 || i == 7 {
                        Text(".").foregroundStyle(i <= firstSignificant ? .tertiary : .secondary)
                    }
                    Text("\(digits[i])")
                        .foregroundStyle(i < firstSignificant ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .overlay(ScrollCatcher(onScroll: { onStep(hz + Double($0) * pow(10, Double(9 - i))) },
                                               onClick: { editing = true }))
                }
                Text(" Hz").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            .font(Theme.readout)
            .monospacedDigit()
            .help("Scroll a digit to step it · click to type (14.074, 7074k, 144.39m)")
        }
    }
}
```

- [ ] **Step 3: `Sources/SubFloor/UI/TopBarView.swift`**

```swift
import DSPCore
import SubFloorCore
import SwiftUI

struct TopBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            DeviceChip()
            Button { model.toggleRun() } label: {
                Image(systemName: model.isRunning ? "stop.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Run / Stop (Space)")

            FrequencyReadout(hz: model.vfoHz, onCommit: { model.tune(to: $0) }, onStep: { model.setVFO($0) })

            VStack(alignment: .leading, spacing: 2) {
                Text("CENTER").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Text(FrequencyFormatter.short(model.centerHz)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                ForEach(DemodMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            BandwidthControl()

            Toggle(isOn: Binding(get: { model.upconverter.enabled }, set: { model.setUpconverter($0) })) {
                Label("HamItUp", systemImage: "arrow.up.arrow.down")
            }
            .toggleStyle(.button)
            .tint(.orange)
            .help("Upconverter mode: radio tuned \(FrequencyFormatter.short(model.upconverter.loHz)) above the display frequency")

            Button { model.addBookmark() } label: { Image(systemName: "star") }
                .help("Bookmark this frequency (⌘D)")
            Button { model.quickTuneVisible = true } label: { Image(systemName: "magnifyingglass") }
                .help("Quick tune (⌘L or /)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct DeviceChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.isRunning ? (model.sourceKind == .sdrplay ? Color.green : Color.orange) : Color.gray)
                .frame(width: 8, height: 8)
            Text(model.isRunning ? model.deviceName : "Stopped").font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.white.opacity(0.06)))
        .help(model.sourceKind == .sdrplay ? "SDRplay RSP1B" : "No RSP — demo or file source")
    }
}

private struct BandwidthControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Text("BW").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(FrequencyFormatter.short(model.bandwidthHz)).monospacedDigit().frame(minWidth: 64, alignment: .trailing)
            Stepper("", value: Binding(get: { model.bandwidthHz }, set: { model.setBandwidth($0) }),
                    in: model.mode.bandwidthRange, step: model.mode.bandwidthStep)
                .labelsHidden()
        }
        .help("Filter bandwidth — or drag the passband edges on the spectrum")
    }
}
```

- [ ] **Step 4: `Sources/SubFloor/UI/SidebarView.swift`**

```swift
import AppKit
import DSPCore
import SDRplayKit
import SubFloorCore
import SwiftUI

struct SidebarView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                RadioSection()
                DisplaySection()
                AudioSection()
                BookmarksSection()
            }
            .padding(14)
        }
        .background(.ultraThinMaterial)
    }
}

private struct RadioSection: View {
    @Environment(AppModel.self) private var model

    private func hw<T>(_ keyPath: WritableKeyPath<SDRplaySettings, T>) -> Binding<T> {
        Binding(get: { model.hardware[keyPath: keyPath] }, set: { v in model.updateHardware { $0[keyPath: keyPath] = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Radio")
            Picker("Source", selection: Binding(get: { model.preferredSource }, set: { model.useSource($0) })) {
                ForEach(SourceKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            LabeledContent("Sample rate") {
                Picker("", selection: hw(\.sampleRate)) {
                    ForEach(RSP1B.sampleRates, id: \.self) { Text(String(format: "%g MSPS", $0 / 1e6)).tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            LabeledContent("Decimation") {
                Picker("", selection: hw(\.decimation)) {
                    ForEach(RSP1B.decimations, id: \.self) { Text("÷\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            LabeledContent("Bandwidth") {
                Text(FrequencyFormatter.rate(model.sampleRate)).monospacedDigit().foregroundStyle(.secondary)
            }
            LabeledContent("LNA state") {
                Stepper("\(model.hardware.lnaState) / \(model.lnaStateCount - 1)", value: hw(\.lnaState), in: 0...(model.lnaStateCount - 1))
                    .monospacedDigit()
            }
            SliderRow(title: "IF gain reduction",
                      value: Binding(get: { Double(model.hardware.ifGainReductionDb) }, set: { v in model.updateHardware { $0.ifGainReductionDb = Int(v.rounded()) } }),
                      range: 20...59, text: "\(model.hardware.ifGainReductionDb) dB")
                .disabled(model.hardware.agc != .off)
            LabeledContent("Hardware AGC") {
                Picker("", selection: hw(\.agc)) {
                    ForEach(HardwareAGC.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            Toggle("Bias-T", isOn: hw(\.biasT))
            Toggle("FM broadcast notch", isOn: hw(\.rfNotch))
            Toggle("DAB notch", isOn: hw(\.dabNotch))
        }
    }
}

private struct DisplaySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Display")
            LabeledContent("FFT size") {
                Picker("", selection: $model.spectrum.fftSize) {
                    ForEach([1024, 2048, 4096, 8192, 16384, 32768, 65536], id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            LabeledContent("Window") {
                Picker("", selection: $model.spectrum.window) {
                    ForEach(WindowKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 130)
            }
            SliderRow(title: "Waterfall speed", value: $model.spectrum.framesPerSecond, range: 5...120,
                      text: "\(Int(model.spectrum.framesPerSecond)) lines/s")
            SliderRow(title: "Averaging",
                      value: Binding(get: { Double(1 - model.spectrum.averaging) }, set: { model.spectrum.averaging = Float(max(0.02, 1 - $0)) }),
                      range: 0...0.98, text: String(format: "%.0f%%", (1 - model.spectrum.averaging) * 100))
            LabeledContent("Colormap") {
                Picker("", selection: $model.colormap) {
                    ForEach(Colormap.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            HStack {
                Toggle("Peak hold", isOn: $model.showPeak)
                Spacer()
                Button("Reset") { model.engine.resetPeak() }.controlSize(.small)
            }
            LabeledContent("Resolution") {
                Text(FrequencyFormatter.short(model.sampleRate / Double(model.spectrum.fftSize)) + " / bin")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

private struct AudioSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Audio")
            SliderRow(title: "Volume", value: Binding(get: { Double(model.volume) }, set: { model.volume = Float($0) }),
                      range: 0...1, text: "\(Int(model.volume * 100))%")
            Picker("AGC", selection: $model.agcSpeed) {
                ForEach(AGCSpeed.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Squelch", isOn: $model.squelchEnabled)
                Spacer()
                Text("\(Int(model.squelchDb)) dB").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(model.squelchDb) }, set: { model.squelchDb = Float($0) }), in: -140...0)
                .controlSize(.small)
                .disabled(!model.squelchEnabled)
            SignalMeter(db: model.signalDb, threshold: model.squelchEnabled ? model.squelchDb : nil)
            if model.mode == .cw {
                SliderRow(title: "CW pitch", value: $model.cwPitchHz, range: 300...1200, text: "\(Int(model.cwPitchHz)) Hz")
            }
        }
    }
}

private struct SignalMeter: View {
    let db: Float
    let threshold: Float?

    var body: some View {
        GeometryReader { geo in
            let f = { (v: Float) in CGFloat(min(max((v + 140) / 140, 0), 1)) * geo.size.width }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule().fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: f(db))
                    .animation(.linear(duration: 0.2), value: db)
                if let threshold {
                    Rectangle().fill(.white).frame(width: 2).offset(x: f(threshold) - 1)
                }
            }
        }
        .frame(height: 6)
        .help(String(format: "Channel power %.0f dBFS", db))
    }
}

private struct BookmarksSection: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        let filtered = BookmarkSearch.filter(model.bookmarks, query: search)
        let groups = Dictionary(grouping: filtered) { $0.group ?? "Ungrouped" }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader("Bookmarks")
                Spacer()
                Toggle(isOn: $model.showBookmarks) {
                    Image(systemName: model.showBookmarks ? "eye" : "eye.slash")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help("Show bookmarks on the spectrum (⌘B)")
                Menu {
                    Button("Add Current Frequency") { model.addBookmark() }
                    Divider()
                    Button("Import…") { model.importBookmarks() }
                    Button("Export…") { model.exportBookmarks() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
            }
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            ForEach(groups.keys.sorted(), id: \.self) { group in
                Text(group).font(.caption2.weight(.medium)).foregroundStyle(.tertiary).padding(.top, 4)
                ForEach(groups[group]!) { BookmarkRow(bookmark: $0) }
            }
        }
    }
}

private struct BookmarkRow: View {
    @Environment(AppModel.self) private var model
    let bookmark: Bookmark
    @State private var hovering = false

    var body: some View {
        Button { model.select(bookmark) } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: bookmark.colorHex) ?? Theme.accent).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bookmark.name).lineLimit(1)
                    Text("\(FrequencyFormatter.short(bookmark.frequencyHz)) · \(bookmark.mode.label)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                if bookmark.upconverter {
                    Image(systemName: "arrow.up.arrow.down").font(.caption2).foregroundStyle(.orange).help("Uses HamItUp")
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.white.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Delete", role: .destructive) { model.deleteBookmark(bookmark.id) }
        }
    }
}
```

- [ ] **Step 5: `Sources/SubFloor/UI/SpectrumArea.swift`**

```swift
import MetalKit
import SubFloorCore
import SwiftUI

struct SpectrumArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                FrequencyRuler().frame(height: 34)
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        SpectrumView()
                        SpectrumOverlay().allowsHitTesting(false)
                        SplitHandle(height: geo.size.height)
                    }
                    .coordinateSpace(name: "spectrum")
                }
            }
            DBRangeControls().frame(width: 36)
        }
        .background(Theme.spectrumBackground)
    }
}

private struct SpectrumView: NSViewRepresentable {
    @Environment(AppModel.self) private var model

    final class Coordinator { var renderer: SpectrumRenderer? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SpectrumMTKView {
        let view = SpectrumMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0.035, green: 0.047, blue: 0.067, alpha: 1)
        if let device = view.device, let renderer = SpectrumRenderer(device: device, frames: model.engine.frames) {
            let model = model
            renderer.displayProvider = { model.displayState }
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }
        return view
    }

    func updateNSView(_ view: SpectrumMTKView, context: Context) {
        let model = model
        view.interaction = SpectrumInteraction(
            zoom: { model.zoom(by: $0, anchor: $1) },
            pan: { model.pan(byFraction: $0) },
            click: { model.click(atFraction: $0) },
            reset: { model.resetView() },
            hover: { model.hover(at: $0) },
            passbandEdges: { model.passbandEdgeFractions },
            dragEdge: { model.dragPassbandEdge(upper: $0, fraction: $1) })
    }
}

/// dB grid, frequency grid, passband, VFO line and hover crosshair, drawn above the Metal view.
private struct SpectrumOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Canvas { ctx, size in
            let vp = model.viewport
            let specH = size.height * model.spectrumFraction
            let range = max(model.dbMax - model.dbMin, 1)
            let x = { (hz: Double) in CGFloat(vp.fraction(ofHz: hz)) * size.width }

            let dbStep: Float = range > 100 ? 20 : 10
            var db = (model.dbMin / dbStep).rounded(.up) * dbStep
            while db <= model.dbMax {
                let y = CGFloat(1 - (db - model.dbMin) / range) * specH
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                           with: .color(Theme.grid), lineWidth: 1)
                ctx.draw(Text("\(Int(db))").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.35)),
                         at: CGPoint(x: 4, y: y - 7), anchor: .leading)
                db += dbStep
            }
            let step = RulerScale.step(span: vp.spanHz, width: size.width)
            for tick in RulerScale.ticks(lower: vp.lowerHz, upper: vp.upperHz, step: step) {
                ctx.stroke(Path { $0.move(to: CGPoint(x: x(tick), y: 0)); $0.addLine(to: CGPoint(x: x(tick), y: specH)) },
                           with: .color(Theme.grid), lineWidth: 1)
            }

            let pb = model.passbandRange
            let x0 = x(pb.lowerBound), x1 = x(pb.upperBound)
            ctx.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)), with: .color(Theme.passband))
            for edge in [x0, x1] {
                ctx.stroke(Path { $0.move(to: CGPoint(x: edge, y: 0)); $0.addLine(to: CGPoint(x: edge, y: specH)) },
                           with: .color(Theme.vfo.opacity(0.45)), lineWidth: 1)
            }
            let xv = x(model.vfoHz)
            ctx.stroke(Path { $0.move(to: CGPoint(x: xv, y: 0)); $0.addLine(to: CGPoint(x: xv, y: size.height)) },
                       with: .color(Theme.vfo), lineWidth: 1.5)

            if let hover = model.hover {
                let p = CGPoint(x: hover.point.x * size.width, y: hover.point.y * size.height)
                ctx.stroke(Path { $0.move(to: CGPoint(x: p.x, y: 0)); $0.addLine(to: CGPoint(x: p.x, y: size.height)) },
                           with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if hover.db != nil {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: p.y)); $0.addLine(to: CGPoint(x: size.width, y: p.y)) },
                               with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                let label = FrequencyFormatter.grouped(hover.hz) + (hover.db.map { String(format: "   %.1f dB", $0) } ?? "")
                let text = ctx.resolve(Text(label).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white))
                let ts = text.measure(in: size)
                let origin = CGPoint(x: min(p.x + 10, size.width - ts.width - 12), y: max(p.y - ts.height - 10, 4))
                ctx.fill(Path(roundedRect: CGRect(origin: origin, size: ts).insetBy(dx: -6, dy: -3), cornerRadius: 5),
                         with: .color(.black.opacity(0.65)))
                ctx.draw(text, at: origin, anchor: .topLeading)
            }
        }
    }
}

/// Drag to resize the spectrum / waterfall split.
private struct SplitHandle: View {
    @Environment(AppModel.self) private var model
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .offset(y: height * model.spectrumFraction - 4)
            .onHover { inside in (inside ? NSCursor.resizeUpDown : NSCursor.arrow).set() }
            .gesture(DragGesture(coordinateSpace: .named("spectrum")).onChanged { g in
                model.spectrumFraction = min(max(g.location.y / height, 0.15), 0.85)
            })
    }
}

/// Frequency labels, bookmark flags and a minimap of the captured span.
private struct FrequencyRuler: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let vp = model.viewport
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let step = RulerScale.step(span: vp.spanHz, width: size.width)
                    for tick in RulerScale.ticks(lower: vp.lowerHz, upper: vp.upperHz, step: step) {
                        let x = CGFloat(vp.fraction(ofHz: tick)) * size.width
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: size.height - 10)); $0.addLine(to: CGPoint(x: x, y: size.height - 4)) },
                                   with: .color(.white.opacity(0.35)), lineWidth: 1)
                        ctx.draw(Text(RulerScale.label(tick, step: step)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.6)),
                                 at: CGPoint(x: x, y: size.height - 17))
                    }
                    let start = vp.startFractionOfCapture * size.width
                    let width = max(vp.widthFractionOfCapture * size.width, 3)
                    ctx.fill(Path(CGRect(x: 0, y: size.height - 3, width: size.width, height: 3)), with: .color(.white.opacity(0.06)))
                    ctx.fill(Path(CGRect(x: start, y: size.height - 3, width: width, height: 3)), with: .color(Theme.accent.opacity(0.6)))
                }
                ForEach(model.visibleBookmarks) { bookmark in
                    BookmarkFlag(bookmark: bookmark)
                        .position(x: CGFloat(vp.fraction(ofHz: bookmark.frequencyHz)) * geo.size.width, y: 9)
                }
            }
        }
        .background(Color.black.opacity(0.35))
    }
}

private struct BookmarkFlag: View {
    @Environment(AppModel.self) private var model
    let bookmark: Bookmark

    var body: some View {
        let color = Color(hex: bookmark.colorHex) ?? Theme.accent
        Button { model.select(bookmark) } label: {
            HStack(spacing: 3) {
                Image(systemName: bookmark.upconverter ? "arrow.up.arrow.down" : "flag.fill").font(.system(size: 8, weight: .bold))
                Text(bookmark.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(.black)
            .background(Capsule().fill(color.opacity(0.9)))
        }
        .buttonStyle(.plain)
        .help("\(bookmark.name) — \(FrequencyFormatter.short(bookmark.frequencyHz)) \(bookmark.mode.label)\(bookmark.upconverter ? " via HamItUp" : "")")
    }
}

private struct DBRangeControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            VerticalSlider(value: Binding(get: { Double(model.dbMax) }, set: { v in
                let r = model.dbMax - model.dbMin
                model.dbMax = Float(v)
                model.dbMin = Float(v) - r
            }), range: -100...20, label: "REF")
            VerticalSlider(value: Binding(get: { Double(model.dbMax - model.dbMin) }, set: { model.dbMin = model.dbMax - Float($0) }),
                           range: 20...160, label: "RNG")
        }
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.25))
    }
}
```

- [ ] **Step 6: Implement the `ModemPanelView`, `StatusBarView`, `QuickTuneView` and `BannerView` files**

```swift
// ModemPanelView.swift
import Modems
import SwiftUI

struct ModemPanelView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                SectionHeader("Modem")
                Picker("", selection: Binding(get: { model.activeModemID }, set: { model.activateModem(id: $0) })) {
                    Text("None").tag(String?.none)
                    ForEach(ModemRegistry.infos) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .frame(width: 180)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if expanded, let modem = model.activeModem {
                modem.makeOutputView()
                    .frame(height: 170)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(.bar)
    }
}
```

```swift
// StatusBarView.swift
import SubFloorCore
import SwiftUI

struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 18) {
            Text(FrequencyFormatter.rate(model.sampleRate))
            Text("FFT \(model.spectrum.fftSize)")
            Text("RBW \(FrequencyFormatter.short(model.sampleRate / Double(model.spectrum.fftSize)))")
            Text(String(format: "Signal %.0f dBFS", model.signalDb))
            Spacer()
            if model.upconverter.enabled {
                Label("HamItUp \(FrequencyFormatter.short(model.upconverter.loHz))", systemImage: "arrow.up.arrow.down").foregroundStyle(.orange)
            }
            Text(String(format: "CPU %.0f%%", model.cpuPercent))
            Text("Underruns \(model.underruns)").foregroundStyle(model.underruns > 0 ? .orange : .secondary)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
```

```swift
// QuickTuneView.swift
import SubFloorCore
import SwiftUI

/// Spotlight-style panel: type a frequency or part of a bookmark name, press Return.
struct QuickTuneView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @FocusState private var focused: Bool

    private var parsed: Double? { FrequencyParser.parse(query) }
    private var matches: [Bookmark] { Array(BookmarkSearch.filter(model.bookmarks, query: query).prefix(8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.accent)
                TextField("Frequency or bookmark — 14.074, 7074k, ft8 20", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit(commit)
            }
            .padding(16)
            if let hz = parsed {
                Divider()
                Label("Tune to \(FrequencyFormatter.grouped(hz)) Hz", systemImage: "arrow.right.circle.fill")
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.15))
            }
            if !query.isEmpty && !matches.isEmpty {
                Divider()
                ForEach(Array(matches.enumerated()), id: \.element.id) { index, bookmark in
                    Button { model.select(bookmark); close() } label: {
                        HStack {
                            Text(bookmark.name)
                            Spacer()
                            Text("\(FrequencyFormatter.short(bookmark.frequencyHz)) · \(bookmark.mode.label)")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(parsed == nil && index == 0 ? Theme.accent.opacity(0.15) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        .onAppear { focused = true }
        .onExitCommand(perform: close)
    }

    private func commit() {
        if let hz = parsed { model.tune(to: hz) } else if let first = matches.first { model.select(first) }
        close()
    }

    private func close() { model.quickTuneVisible = false }
}
```

```swift
// BannerView.swift
import SwiftUI

struct BannerView: View {
    @Environment(AppModel.self) private var model
    let banner: Banner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(banner.message).lineLimit(2)
            if let action = banner.action {
                Button(action == .retry ? "Retry" : "Reduce gain") { model.perform(action) }
                    .controlSize(.small)
            }
            Button { model.banner = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.4)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private var icon: String {
        switch banner.kind {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch banner.kind {
        case .info: Theme.accent
        case .warning: .orange
        case .error: .red
        }
    }
}
```

- [ ] **Step 7: `Sources/SubFloor/UI/ContentView.swift`**

```swift
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            SidebarView().frame(width: 280)
            Divider()
            VStack(spacing: 0) {
                TopBarView()
                Divider()
                SpectrumArea()
                ModemPanelView()
                StatusBarView()
            }
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner)
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if model.quickTuneVisible {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { model.quickTuneVisible = false }
                    QuickTuneView().padding(.top, 120)
                }
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: model.banner)
        .animation(.snappy(duration: 0.15), value: model.quickTuneVisible)
        .frame(minWidth: 1180, minHeight: 720)
        .onAppear { model.start() }
    }
}
```

- [ ] **Step 8: Replace `Sources/SubFloor/App/SubFloorApp.swift` with the real app (keyboard and commands are wired in Task 17)**

```swift
import AppKit
import SwiftUI

@main
struct SubFloorApp: App {
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance = "dark"

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    private var scheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "system": nil
        default: .dark
        }
    }

    var body: some Scene {
        WindowGroup("SubFloor") {
            ContentView()
                .environment(model)
                .preferredColorScheme(scheme)
                .tint(Theme.accent)
                .onAppear { NSApp.activate() }
        }
        .defaultSize(width: 1440, height: 900)
    }
}
```

- [ ] **Step 9: Build and exercise the UI with the demo source**

Run: `swift build && swift run SubFloor`

Expected: the full window opens, dark by default. A "No RSP found — demo signal" banner appears if no RSP is connected. Then verify each of these by hand:
1. Click the CW trace at 14.030 MHz, then choose CW mode. You should hear a 700 Hz keyed tone.
2. Pinch, or ⌥-scroll, to zoom around the cursor. Two-finger scroll pans. The CENTER readout must **not** change while panning or zooming.
3. Drag a passband edge and check that BW updates.
4. Scroll over the 1 kHz digit of the readout and check that it steps by 1 kHz.
5. Click the readout, type `14.2`, press Return, and check that you hear a 1 kHz USB tone.
6. Click the "20m CW" bookmark flag on the ruler and check that it tunes there.
7. Set Modem to CW Decoder at 14.030 MHz and check that "CQ CQ DE SUBFLOOR K" scrolls past.
8. Turn on HamItUp and check that the display frequency stays the same while the demo signals are still present (thanks to the antenna offset).
9. Change the FFT size to 65536 and check that the display stays smooth.

- [ ] **Step 10: Commit**

```bash
git add Sources/SubFloor
git commit -m "feat(ui): add SwiftUI interface with spectrum overlay, sidebar, modem panel and quick tune

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 17: Keyboard, menu commands, settings, bundling, README and final verification

**Files:**
- Create: `Sources/SubFloor/App/KeyboardController.swift`, `Sources/SubFloor/UI/SettingsView.swift`, `scripts/bundle.sh`
- Modify: `Sources/SubFloor/App/SubFloorApp.swift`, `README.md`

**Interfaces:**
- Consumes: `AppModel`.
- Produces: `@MainActor final class KeyboardController { static let shared; func install(model:) }`, `struct RadioCommands: Commands`, `struct SettingsView: View`

- [ ] **Step 1: `Sources/SubFloor/App/KeyboardController.swift`**

```swift
import AppKit

/// App-wide keys that work whenever no text field is being edited:
/// ←/→ step VFO (⇧ ×10), [ / ] cycle mode, Space run/stop, / quick tune.
@MainActor
final class KeyboardController {
    static let shared = KeyboardController()
    private var monitor: Any?

    func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model else { return event }
            let handled = MainActor.assumeIsolated { Self.handle(event, model: model) }
            return handled ? nil : event
        }
    }

    private static func handle(_ event: NSEvent, model: AppModel) -> Bool {
        if NSApp.keyWindow?.firstResponder is NSText || model.quickTuneVisible { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return false }
        let multiplier = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: model.stepVFO(-multiplier); return true
        case 124: model.stepVFO(multiplier); return true
        case 49: model.toggleRun(); return true
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "[": model.cycleMode(-1); return true
        case "]": model.cycleMode(1); return true
        case "/": model.quickTuneVisible = true; return true
        default: return false
        }
    }
}
```

- [ ] **Step 2: `Sources/SubFloor/UI/SettingsView.swift`**

```swift
import SubFloorCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance = "dark"
    @State private var loText = ""

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("Dark").tag("dark")
                Text("Light").tag("light")
                Text("System").tag("system")
            }
            .pickerStyle(.segmented)
            Section("HamItUp upconverter") {
                TextField("LO frequency", text: $loText)
                    .onSubmit { if let hz = FrequencyParser.parse(loText) { model.setUpconverterLO(hz) } }
                Text("Radio is tuned to display frequency + LO when HamItUp mode is on. Default 125 MHz.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Calibration") {
                Stepper(String(format: "Frequency correction %.1f ppm", model.hardware.ppm),
                        value: Binding(get: { model.hardware.ppm }, set: { v in model.updateHardware { $0.ppm = v } }),
                        in: -100...100, step: 0.1)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { loText = FrequencyFormatter.short(model.upconverter.loHz) }
    }
}
```

- [ ] **Step 3: Wire keyboard, commands and settings into `SubFloorApp.swift`**

In `body`, change `.onAppear { NSApp.activate() }` to:
```swift
                .onAppear {
                    KeyboardController.shared.install(model: model)
                    NSApp.activate()
                }
```
After `.defaultSize(...)`, add:
```swift
        .commands { RadioCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(scheme)
        }
```
At the end of the file, add:
```swift
struct RadioCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Radio") {
            Button(model.isRunning ? "Stop" : "Run") { model.toggleRun() }.keyboardShortcut("r")
            Button("Quick Tune…") { model.quickTuneVisible = true }.keyboardShortcut("l")
            Divider()
            Button("Add Bookmark") { model.addBookmark() }.keyboardShortcut("d")
            Button(model.showBookmarks ? "Hide Bookmarks on Spectrum" : "Show Bookmarks on Spectrum") {
                model.showBookmarks.toggle()
            }
            .keyboardShortcut("b")
            Divider()
            Button("Toggle HamItUp") { model.setUpconverter(!model.upconverter.enabled) }.keyboardShortcut("u")
            Button("Open IQ Recording…") { model.openIQFile() }.keyboardShortcut("o")
            Button("Reset Zoom") { model.resetView() }.keyboardShortcut("0")
        }
    }
}
```

- [ ] **Step 4: `scripts/bundle.sh` (run `chmod +x` on it afterwards)**

```bash
#!/bin/zsh
# Builds a release SubFloor.app in ./build with an ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/SubFloor"
APP=build/SubFloor.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SubFloor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SubFloor</string>
    <key>CFBundleIdentifier</key><string>app.subfloor.SubFloor</string>
    <key>CFBundleName</key><string>SubFloor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
```

- [ ] **Step 5: Update `README.md`**

````markdown
# SubFloor

A fast, native macOS (Apple Silicon) receiver for the SDRplay RSP1B: Metal spectrum + waterfall,
AM/NFM/WFM/USB/LSB/CW audio, HamItUp upconverter mode, bookmarks, and plug-in modems (CW decoder included).

## Requirements
- macOS on Apple Silicon, Xcode 26 / Swift 6.2
- [SDRplay API 3.15](https://www.sdrplay.com/api/) installed (`/usr/local/lib/libsdrplay_api.dylib`)

## Build & run
```bash
swift run -c release SubFloor        # run from source
scripts/bundle.sh                    # build build/SubFloor.app
swift test                           # unit tests
SUBFLOOR_HW=1 swift test             # also run the RSP1B hardware smoke test
```
Without an RSP connected, SubFloor runs on a built-in demo signal around 14.1 MHz.

## Using it
| Action | How |
| --- | --- |
| Tune | Click the spectrum · scroll a readout digit · click readout and type `14.074`, `7074k`, `144.39m` |
| Quick tune | ⌘L or `/` — frequency or bookmark name (`ft8 20`) |
| Step VFO | ← / → (⇧ ×10) |
| Mode | Top bar, or `[` / `]` |
| Zoom / pan | Pinch or ⌥-scroll / two-finger scroll or drag — never retunes the radio |
| Bandwidth | Drag the passband edges |
| Bookmarks | ⌘D add · ⌘B show on spectrum · sidebar list |
| HamItUp | Top-bar toggle or ⌘U (LO set in Settings, default 125 MHz) |

## Adding a modem
1. Create `Sources/Modems/<Name>/<Name>Modem.swift` with a class conforming to `Modem`
   (`info`, `process(audio:context:)` or `process(iq:context:)`, `makeOutputView()`).
2. Append `<Name>Modem.self` to `ModemRegistry.all` in `Sources/Modems/Modem.swift`.
3. Add tests in `Tests/ModemsTests`.
````

- [ ] **Step 6: Full verification**

Run: `swift test`
Expected: every test passes, with the hardware test skipped.

Run: `scripts/bundle.sh && open build/SubFloor.app`
Expected: the app launches from the bundle.

Then check the following by hand:
- With an RSP1B connected, the device chip turns green and shows "RSP1B".
- Tune 10 MHz AM (WWV) or a local FM station, and confirm the audio is clean.
- Drag LNA up until an overload occurs. A banner should offer "Reduce gain".
- Unplug the USB cable. A "disconnected" banner should appear, and Retry should recover after you replug.
- ←/→, `[`/`]`, Space, `/`, ⌘L, ⌘D, ⌘B and ⌘U all work, and they don't fire while you're typing in a text field.
- Instruments (Time Profiler) at 2 MSPS with USB demod should show CPU below 15% of one core.

- [ ] **Step 7: Commit**

```bash
git add Sources/SubFloor scripts README.md
git commit -m "feat(app): add keyboard control, Radio menu, settings, app bundling and README

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Spec coverage check

| Spec requirement | Task(s) |
| --- | --- |
| RSP1B over USB via SDRplay API 3.15 | 1, 11 |
| Spectrum + waterfall, Metal, fast | 3, 13, 14 |
| Zoom/pan without retune | 9, 14, 15 |
| Gain controls, MSPS / decimation, notches, bias-T, AGC | 11, 15, 16 |
| AM/NFM/WFM/USB/LSB/CW audio, AGC, squelch, volume | 5, 6, 13, 16 |
| Fast frequency entry (digit scroll, typed, quick tune, keys) | 8, 16, 17 |
| HamItUp mode | 7, 8, 15, 16 |
| Bookmarks (incl. upconverter), show on spectrum, import/export | 10, 15, 16 |
| Modular modems + CW decoder | 12, 15, 16 |
| Demo + IQ file sources, error banners, overload/removal events | 7, 11, 15, 16 |
| Dark by default, elegant UI | 16, 17 |
| Tests per spec §13 | 2–12, 17 |
