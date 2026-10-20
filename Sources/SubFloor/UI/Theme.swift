// Theme.swift
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.36, green: 0.84, blue: 1.0)
    static let vfo = Color(red: 1.0, green: 0.72, blue: 0.28)
    static let passband = vfo.opacity(0.12)
    static let spectrumBackground = Color(red: 0.035, green: 0.047, blue: 0.067)
    static let grid = Color.white.opacity(0.07)
    /// The modem box (green) and the modem cursor (amber, warmer than the VFO).
    static let modemBox = Color(red: 0.30, green: 0.86, blue: 0.47)
    static let modemCursor = Color(red: 1.0, green: 0.78, blue: 0.16)
    static let readout = Font.system(size: 30, weight: .medium, design: .monospaced)
}

extension Color {
    init?(hex: String?) {
        guard let hex, let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
