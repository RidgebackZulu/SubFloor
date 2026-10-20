import Testing
@testable import SubFloor

@Suite struct SpectrumFrameStoreTests {
    @Test func emptyStoreReturnsNil() {
        let store = SpectrumFrameStore()
        var a = [Float](), p = [Float]()
        #expect(store.read(after: 0, average: &a, peak: &p) == nil)
    }

    @Test func publishAdvancesSequenceAndCopiesData() {
        let store = SpectrumFrameStore()
        var a = [Float](), p = [Float]()
        store.publish(average: [1, 2, 3], peak: [4, 5, 6])
        let s1 = store.read(after: 0, average: &a, peak: &p)
        #expect(s1 == 1)
        #expect(a == [1, 2, 3])
        #expect(p == [4, 5, 6])
        #expect(store.read(after: s1!, average: &a, peak: &p) == nil)
        store.publish(average: [7, 8, 9], peak: [1, 1, 1])
        let s2 = store.read(after: s1!, average: &a, peak: &p)
        #expect(s2 == 2)
        #expect(a == [7, 8, 9])
        #expect(p == [1, 1, 1])
    }

    @Test func readCopiesIntoCallerStorage() {
        let store = SpectrumFrameStore()
        var a = [Float](), p = [Float]()
        store.publish(average: [1, 2], peak: [1, 2])
        _ = store.read(after: 0, average: &a, peak: &p)
        a[0] = 99
        var b = [Float](), q = [Float]()
        _ = store.read(after: 0, average: &b, peak: &q)
        #expect(b == [1, 2])
    }
}
