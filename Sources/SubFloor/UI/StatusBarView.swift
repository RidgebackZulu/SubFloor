// StatusBarView.swift
import Recording
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
            ForEach(StreamKind.allCases) { kind in
                if let s = model.recordingStatus[kind], s.isRecording {
                    Label("REC \(kind.label) \(RecordingFormat.bytes(s.bytesWritten))" + (s.filesWritten > 1 ? " · file \(s.filesWritten)" : "")
                          + (s.overrunBytes > 0 ? " · gaps" : ""), systemImage: "record.circle")
                        .foregroundStyle(.red)
                }
            }
            if !model.isRecordingAny {
                let iq = model.iqRingPlan?.effectivePreRollSeconds ?? model.recording.preRollSeconds
                Text("Pre-roll \(Int(model.recording.preRollSeconds)) s" + (iq < model.recording.preRollSeconds - 0.5 ? " (IQ \(Int(iq)) s)" : ""))
                    .help("Recordings start this long before the click")
            }
            if model.overloaded {
                Label("OVERLOAD", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
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
