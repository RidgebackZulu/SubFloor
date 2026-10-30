import Testing
@testable import Transcription

@Suite struct EnvFileTests {
    @Test func plainValue() {
        #expect(EnvFile.openRouterKey(in: "OPENROUTER=abc\n") == "abc")
        #expect(EnvFile.openRouterKey(in: "OPENROUTER_API_KEY=abc") == "abc")
    }

    @Test func exportAndQuotes() {
        #expect(EnvFile.openRouterKey(in: "export OPENROUTER=\"abc\"") == "abc")
        #expect(EnvFile.openRouterKey(in: "OPENROUTER_API_KEY='abc'") == "abc")
        #expect(EnvFile.openRouterKey(in: "  export   OPENROUTER =  abc  ") == "abc")
    }

    @Test func commentsSkipped() {
        #expect(EnvFile.openRouterKey(in: "# OPENROUTER=nope\nOTHER=1\nOPENROUTER=abc") == "abc")
    }

    @Test func emptyValueIsNil() {
        #expect(EnvFile.openRouterKey(in: "OPENROUTER=\n") == nil)
        #expect(EnvFile.openRouterKey(in: "OPENROUTER=\"\"") == nil)
    }

    @Test func firstNonEmptyWins() {
        #expect(EnvFile.openRouterKey(in: "OPENROUTER=\nOPENROUTER_API_KEY=second\nOPENROUTER=third") == "second")
    }

    @Test func otherKeysOnlyIsNil() {
        #expect(EnvFile.openRouterKey(in: "OPENAI_API_KEY=abc\nFOO=bar") == nil)
        #expect(EnvFile.openRouterKey(in: "") == nil)
    }
}
