import Foundation
import Testing
@testable import Spectra

/// `RadioBuilder.parsePicks` must tolerate LLM answers wrapped in prose or a
/// code fence, deduplicate picks and drop out-of-range indices.
struct RadioBuilderParsingTests {

    @Test func parsesCleanJSON() async {
        let picks = await RadioBuilder.parsePicks(#"{"picks":[3,1,2],"reason":"ok"}"#, count: 5)
        #expect(picks == [3, 1, 2])
    }

    @Test func parsesJSONWrappedInProseAndFence() async {
        let content = "Here you go:\n```json\n{\"picks\":[0,4]}\n```\nHope that flows!"
        let picks = await RadioBuilder.parsePicks(content, count: 5)
        #expect(picks == [0, 4])
    }

    @Test func deduplicatesAndFiltersOutOfRange() async {
        let picks = await RadioBuilder.parsePicks(#"{"picks":[1,1,9,-1,"2"]}"#, count: 5)
        #expect(picks == [1, 2])
    }

    @Test func returnsNilWithoutJSON() async {
        #expect(await RadioBuilder.parsePicks("no json here", count: 5) == nil)
    }

    @Test func returnsNilOnEmptyPicks() async {
        #expect(await RadioBuilder.parsePicks(#"{"picks":[]}"#, count: 5) == nil)
    }

    @Test func returnsNilWhenPicksKeyMissing() async {
        #expect(await RadioBuilder.parsePicks(#"{"other":1}"#, count: 5) == nil)
    }
}
