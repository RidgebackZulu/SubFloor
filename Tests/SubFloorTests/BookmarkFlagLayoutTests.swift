import AppKit
import Foundation
import SubFloorCore
import SwiftUI
import Testing
@testable import SubFloor

@MainActor
struct BookmarkFlagLayoutTests {
    private func flag(x: CGFloat, width: CGFloat = 100) -> BookmarkFlagLayout.Flag {
        BookmarkFlagLayout.Flag(id: UUID(), x: x, width: width)
    }

    @Test func flagsThatFitStayInTheFirstRow() {
        let flags = [flag(x: 100), flag(x: 300), flag(x: 500)]
        let placed = BookmarkFlagLayout.place(flags, viewWidth: 1000)
        for f in flags {
            #expect(placed[f.id] == .init(centerX: f.x, row: 0))
        }
    }

    @Test func overlappingFlagsStepDownAndNeverTouch() {
        let flags = (0..<12).map { flag(x: 200 + CGFloat($0) * 35, width: 90) }
        let placed = BookmarkFlagLayout.place(flags, viewWidth: 1000)
        for (i, a) in flags.enumerated() {
            for b in flags[(i + 1)...] {
                let pa = placed[a.id]!, pb = placed[b.id]!
                guard pa.row == pb.row else { continue }
                #expect(abs(pa.centerX - pb.centerX) >= 90 + 4)
            }
        }
        #expect(placed.values.map(\.row).max() == 2)
    }

    @Test func flagsAtOneFrequencyStackInListOrder() {
        let flags = [flag(x: 500), flag(x: 500), flag(x: 500)]
        let placed = BookmarkFlagLayout.place(flags, viewWidth: 1000)
        #expect(flags.map { placed[$0.id]!.row } == [0, 1, 2])
        #expect(flags.allSatisfy { placed[$0.id]!.centerX == 500 })
    }

    @Test func aFreedRowIsReused() {
        let a = flag(x: 100, width: 100), b = flag(x: 120, width: 100), c = flag(x: 300, width: 100)
        let placed = BookmarkFlagLayout.place([a, b, c], viewWidth: 1000)
        #expect(placed[b.id]?.row == 1)
        #expect(placed[c.id]?.row == 0)
    }

    @Test func aFlagAtAnEdgeStaysInViewAndStillCoversItsFrequency() {
        let left = flag(x: 5), right = flag(x: 995)
        let placed = BookmarkFlagLayout.place([left, right], viewWidth: 1000)
        #expect(placed[left.id]?.centerX == 50)
        #expect(placed[right.id]?.centerX == 950)
    }

    @Test func pastTheLastRowFlagsShareIt() {
        let flags = (0..<8).map { _ in flag(x: 500) }
        let placed = BookmarkFlagLayout.place(flags, viewWidth: 1000, maxRows: 3)
        #expect(flags.map { placed[$0.id]!.row } == [0, 1, 2, 2, 2, 2, 2, 2])
    }

    private final class SpectrumStandIn: NSView {}
    private struct SpectrumStandInView: NSViewRepresentable {
        func makeNSView(context: Context) -> SpectrumStandIn { SpectrumStandIn() }
        func updateNSView(_ view: SpectrumStandIn, context: Context) {}
    }

    /// The flags lie over the spectrum: only a flag takes the mouse, and between flags a click still reaches the view below.
    @Test func onlyAFlagTakesTheMouse() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorTests-\(UUID().uuidString)/bookmarks.json")
        let m = AppModel(bookmarkStore: BookmarkStore(url: url), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                         openRSP: { throw CancellationError() }, rspOpenTimeout: .seconds(10))
        let id = m.addBookmark(Bookmark(name: "here", frequencyHz: m.viewport.lowerHz + m.viewport.spanHz / 2, mode: .usb, bandwidthHz: 2_700))
        for other in m.bookmarks where other.id != id { m.deleteBookmark(other.id) }
        let size = NSSize(width: 1000, height: 300)
        let host = NSHostingView(rootView: ZStack { SpectrumStandInView(); BookmarkFlags().environment(m) })
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        // hitTest takes the superview's coordinates, y up.
        #expect(host.hitTest(NSPoint(x: 500, y: size.height - 8)) is ClickCatcher.CatcherView)
        #expect(host.hitTest(NSPoint(x: 100, y: size.height - 8)) is SpectrumStandIn)
        #expect(host.hitTest(NSPoint(x: 500, y: 100)) is SpectrumStandIn)
    }

    /// A scroll view centres content wider than itself, which cuts off its left side. Fails if a control grows past
    /// the sidebar, as the AGC picker did on macOS 27.
    @Test func sidebarContentFitsTheSidebar() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SubFloorTests-\(UUID().uuidString)/bookmarks.json")
        let m = AppModel(bookmarkStore: BookmarkStore(url: url), defaults: UserDefaults(suiteName: UUID().uuidString)!,
                         openRSP: { throw CancellationError() }, rspOpenTimeout: .seconds(10))
        let available = SidebarView.width - 2 * SidebarView.padding
        let host = NSHostingController(rootView: SidebarContent().environment(m))
        #expect(host.sizeThatFits(in: NSSize(width: available, height: 5000)).width <= available)
    }
}
