import Testing
import CSDRplay
@testable import SDRplayKit

@Test func errorMessageComesFromLibrary() {
    let error = SDRplayError(sdrplay_api_Fail, context: "Open")
    #expect(error.code == 1)
    #expect(error.message.hasPrefix("Open: "))
    #expect(error.message.count > "Open: ".count)
}

@Test func checkThrowsOnlyOnFailure() throws {
    try check(sdrplay_api_Success, "noop")
    #expect(throws: SDRplayError.self) { try check(sdrplay_api_InvalidParam, "bad") }
}
