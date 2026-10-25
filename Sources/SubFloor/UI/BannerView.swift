// BannerView.swift
import SwiftUI

struct BannerView: View {
    @Environment(AppModel.self) private var model
    let banner: Banner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(banner.message).lineLimit(3)
            if let action = banner.action {
                Button(label(action)) { model.perform(action) }
                    .controlSize(.small)
                    .help(action == .copyServiceRestart ? AppModel.serviceRestartCommand : "")
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

    private func label(_ action: BannerAction) -> String {
        switch action {
        case .retry: "Retry"
        case .reduceGain: "Reduce gain"
        case .copyServiceRestart: "Copy restart command"
        }
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
