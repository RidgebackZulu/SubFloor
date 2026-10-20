import Foundation
import Testing
@testable import Modems

@Suite struct ModemSettingsTests {
    @Test func codableRoundTrip() throws {
        for settings in [ModemSettings(),
                         ModemSettings(mode: .psk31, autoDetect: true, audioWide: true, slotModesEnabled: false),
                         ModemSettings(mode: .wspr)] {
            let data = try JSONEncoder().encode(settings)
            #expect(try JSONDecoder().decode(ModemSettings.self, from: data) == settings)
        }
    }

    @Test func modeIsStoredByStableIdentifier() throws {
        let data = try JSONEncoder().encode(ModemSettings(mode: .rtty))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"rtty\""))
    }
}
