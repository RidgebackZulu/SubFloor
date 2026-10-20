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
