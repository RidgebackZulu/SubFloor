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
