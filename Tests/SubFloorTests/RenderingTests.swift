import Metal
import Testing
@testable import SubFloor

@Suite struct RenderingTests {
    @Test func lutsAreWellFormed() {
        for map in Colormap.allCases {
            let lut = map.lut()
            #expect(lut.count == 256)
            for c in lut {
                #expect((0...1).contains(c.x) && (0...1).contains(c.y) && (0...1).contains(c.z))
                #expect(c.w == 1)
            }
        }
    }

    @Test func grayscaleEndpoints() {
        let lut = Colormap.grayscale.lut()
        #expect(lut[0] == SIMD4<Float>(0, 0, 0, 1))
        #expect(lut[255] == SIMD4<Float>(1, 1, 1, 1))
    }

    @Test func uniformsLayoutMatchesMetal() {
        #expect(MemoryLayout<Uniforms>.stride == 56)
    }

    @Test func waterfallRowsShiftByTheRetune() {
        // Retuned up 10 kHz with 100 Hz bins: a row from before is indexed 100 bins further along
        // (its bin 100 + b is the frequency now at screen bin b).
        #expect(SpectrumRenderer.shiftBins(measuredAt: 7_000_000, currentCenterHz: 7_010_000, binHz: 100) == 100)
        #expect(SpectrumRenderer.shiftBins(measuredAt: 7_010_000, currentCenterHz: 7_000_000, binHz: 100) == -100)
        #expect(SpectrumRenderer.shiftBins(measuredAt: .nan, currentCenterHz: 7_000_000, binHz: 100) == 0)
        #expect(SpectrumRenderer.shiftBins(measuredAt: 7_000_000, currentCenterHz: .nan, binHz: 100) == 0)
    }

    @Test @MainActor func shaderCompilesAndPipelineBuilds() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        #expect(SpectrumRenderer(device: device, frames: SpectrumFrameStore()) != nil)
    }
}
