import SubFloorCore
import SwiftUI

/// "0.014.074.000" readout: scroll over any digit to step it, click to type a frequency.
struct FrequencyReadout: View {
    let hz: Double
    var onCommit: (Double) -> Void
    var onDigitStep: (Int, Int) -> Void

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
                        .overlay(ScrollCatcher(onScroll: { onDigitStep(9 - i, $0) },
                                               onClick: { editing = true }))
                }
                Text(" Hz").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4)
            }
            .font(Theme.readout)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .help("Scroll a digit to step it · click to type (14.074, 7074k, 144.39m)")
        }
    }
}
