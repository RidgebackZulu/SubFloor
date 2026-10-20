import Testing
@testable import SubFloorCore

@Suite struct SpectrumHitTestTests {
    private let width = 1_000.0

    private func hit(_ x: Double, _ y: Double, tab: (lower: Double, upper: Double)? = (0.4, 0.6),
                     box: (lower: Double, upper: Double)? = (0.4, 0.6),
                     edges: (lower: Double, upper: Double)? = nil) -> SpectrumHit {
        SpectrumHitTest.hit(x: x, y: y, width: width, grabTab: tab, box: box, passbandEdges: edges)
    }

    @Test func tabOnTopStripBodyBelow() {
        #expect(hit(500, 5) == .boxGrabTab)
        #expect(hit(401, SpectrumHitTest.tabHeight - 1) == .boxGrabTab)
        #expect(hit(500, SpectrumHitTest.tabHeight) == .boxBody)
        #expect(hit(400, 300) == .boxBody)
        #expect(hit(600, 300) == .boxBody)
        #expect(hit(399, 300) == .elsewhere)
        #expect(hit(601, 5) == .elsewhere)
    }

    @Test func narrowBoxGetsAMinimumWidthTab() {
        // Zoomed out: the box is 2 points wide, the tab still the minimum width, centred on it.
        let tab = SpectrumHitTest.tabExtent(lower: 499, upper: 501)
        #expect(abs((tab.upper - tab.lower) - SpectrumHitTest.minTabWidth) < 1e-9)
        #expect(abs((tab.upper + tab.lower) / 2 - 500) < 1e-9)
        let narrow = (lower: 0.499, upper: 0.501)
        #expect(hit(500 + SpectrumHitTest.minTabWidth / 2 - 1, 5, tab: narrow, box: narrow) == .boxGrabTab)
        #expect(hit(500 - SpectrumHitTest.minTabWidth / 2 + 1, 5, tab: narrow, box: narrow) == .boxGrabTab)
        #expect(hit(500 + SpectrumHitTest.minTabWidth / 2 + 1, 5, tab: narrow, box: narrow) == .elsewhere)
        #expect(hit(510, 300, tab: narrow, box: narrow) == .elsewhere)
        // A wide box: the tab spans it.
        let wide = SpectrumHitTest.tabExtent(lower: 100, upper: 700)
        #expect(wide.lower == 100 && wide.upper == 700)
    }

    @Test func orderTabThenEdgeThenBody() {
        let edges = (lower: 0.45, upper: 0.48)
        // An edge under the tab: the tab wins.
        #expect(hit(450, 5, edges: edges) == .boxGrabTab)
        // Below the tab, an edge inside the box wins over the body.
        #expect(hit(452, 300, edges: edges) == .passbandEdge(upper: false))
        #expect(hit(478, 300, edges: edges) == .passbandEdge(upper: true))
        #expect(hit(465, 300, edges: edges) == .boxBody)
        // Both edges within reach: upper first.
        #expect(hit(452, 300, edges: (lower: 0.451, upper: 0.453)) == .passbandEdge(upper: true))
        // No box.
        #expect(hit(478, 300, tab: nil, box: nil, edges: edges) == .passbandEdge(upper: true))
        #expect(hit(465, 300, tab: nil, box: nil, edges: edges) == .elsewhere)
        #expect(hit(500, 5, tab: nil, box: nil) == .elsewhere)
    }

    @Test func tabWithoutBodyStillGrabs() {
        // An inactive box: no body (clicks tune the VFO), but it can be dragged back.
        #expect(hit(500, 5, box: nil) == .boxGrabTab)
        #expect(hit(500, 300, box: nil) == .elsewhere)
    }
}
