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
        float traceShiftBins;
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
                                     constant Uniforms &u [[buffer(4)]],
                                     device const float *rowShift [[buffer(5)]]) {
        float px = in.uv.x * u.viewSize.x;
        float py = in.uv.y * u.viewSize.y;
        float binsPerPx = u.viewBinCount / u.viewSize.x;
        float b0 = u.viewStartBin + floor(px) * binsPerPx;
        float b1 = b0 + max(binsPerPx, 1.0);
        float range = max(u.dbMax - u.dbMin, 1.0);
        float specH = u.spectrumFraction * u.viewSize.y;
        float4 background = float4(0.035, 0.047, 0.067, 1.0);

        float n = float(u.fftSize);

        if (py < specH) {
            // The latest spectrum may have been measured before a retune: index it where it was.
            float t0 = b0 + u.traceShiftBins, t1 = b1 + u.traceShiftBins;
            if (t1 <= 0.0 || t0 >= n) { return background; }
            float v = clamp((columnMax(average, u.fftSize, t0, t1) - u.dbMin) / range, 0.0, 1.0);
            float vPrev = clamp((columnMax(average, u.fftSize, t0 - binsPerPx, t0) - u.dbMin) / range, 0.0, 1.0);
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
                float pv = clamp((columnMax(peak, u.fftSize, t0, t1) - u.dbMin) / range, 0.0, 1.0);
                if (abs(py - (1.0 - pv) * specH) < 0.8) { color = float4(1.0, 0.75, 0.30, 0.9); }
            }
            if (py >= top && py <= bottom) { color = float4(0.45, 0.88, 1.0, 1.0); }
            if (specH - py < 1.0) { color = float4(1.0, 1.0, 1.0, 0.12); }
            return color;
        }

        uint row = uint((py - specH) / max(u.rowHeightPx, 1.0));
        if (row >= u.waterfallRows) { return background; }
        uint ringRow = (u.waterfallHead + u.waterfallRows - row) % u.waterfallRows;
        // A row measured at another capture centre: its bins sit `rowShift` bins along; past its
        // edges there is nothing measured.
        float w0 = b0 + rowShift[ringRow], w1 = b1 + rowShift[ringRow];
        if (w1 <= 0.0 || w0 >= n) { return background; }
        float db = columnMaxHalf(waterfall + ringRow * u.fftSize, u.fftSize, w0, w1);
        float v = clamp((db - u.dbMin) / range, 0.0, 1.0);
        return lut[uint(v * 255.0)];
    }
    """#
}
