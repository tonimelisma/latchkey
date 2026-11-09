import Foundation
import Testing

@testable import Latchkey

/// The new-version notice (spec 001 FR-669): which GitHub release counts as newer.
struct ReleaseCheckTests {
    private func feed(_ releases: [(tag: String, draft: Bool, pre: Bool)]) -> Data {
        let items = releases.map {
            """
            {"tag_name":"\($0.tag)","draft":\($0.draft),"prerelease":\($0.pre),\
            "html_url":"https://github.com/tonimelisma/latchkey/releases/tag/\($0.tag)"}
            """
        }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    @Test func offersTheHighestNewerMacRelease() throws {
        let data = feed([
            ("linux-0.1.9", false, false), ("mac-0.8.150", false, false), ("mac-0.8.152", false, false),
            ("mac-0.8.151", false, false),
        ])
        let notice = try #require(ReleaseCheck.notice(from: data, current: "0.8.146"))
        #expect(notice.version == "0.8.152")
        #expect(notice.page.absoluteString == "https://github.com/tonimelisma/latchkey/releases/tag/mac-0.8.152")
    }

    @Test func nothingWhenCurrentIsNewestOrNewer() {
        let data = feed([("mac-0.8.146", false, false), ("mac-0.8.99", false, false)])
        #expect(ReleaseCheck.notice(from: data, current: "0.8.146") == nil)
        #expect(ReleaseCheck.notice(from: data, current: "0.9.0") == nil)
    }

    @Test func ignoresDraftsPrereleasesAndOtherPrograms() {
        let data = feed([
            ("mac-0.9.0", true, false), ("mac-0.9.1", false, true), ("linux-9.0.0", false, false),
            ("server-v9.0.0", false, false), ("mac-oops", false, false),
        ])
        #expect(ReleaseCheck.notice(from: data, current: "0.8.146") == nil)
    }

    @Test func comparesNumbersNotText() {
        #expect(ReleaseCheck.isNewer("0.8.150", than: "0.8.99"))
        #expect(ReleaseCheck.isNewer("1.0", than: "0.9.9"))
        #expect(ReleaseCheck.isNewer("0.8.10.1", than: "0.8.10"))
        #expect(!ReleaseCheck.isNewer("0.8.10", than: "0.8.10.0"))
        #expect(!ReleaseCheck.isNewer("0.8.9", than: "0.8.10"))
        #expect(!ReleaseCheck.isNewer("?", than: "0.8.10"))
        #expect(!ReleaseCheck.isNewer("0.8.10", than: "?"))  // an unknown own version offers nothing
    }

    @Test func unreadableFeedOffersNothing() {
        #expect(ReleaseCheck.notice(from: Data("not json".utf8), current: "0.8.1") == nil)
        #expect(ReleaseCheck.notice(from: Data(#"{"message":"rate limited"}"#.utf8), current: "0.8.1") == nil)
    }

    @Test func onlyGitHubPagesAreOpened() {
        let data = Data(
            #"[{"tag_name":"mac-0.9.0","draft":false,"prerelease":false,"html_url":"https://evil.example/x"}]"#.utf8)
        let notice = ReleaseCheck.notice(from: data, current: "0.8.1")
        #expect(notice?.page.absoluteString == "https://github.com/tonimelisma/latchkey/releases/tag/mac-0.9.0")
    }
}
