#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailRecipientTokensTests {
    @Test func aCommaOrSemicolonFinishesARecipient() {
        #expect(MailRecipientTokens.consume("a@x.com,") == (["a@x.com"], ""))
        #expect(MailRecipientTokens.consume("a@x.com;b@y") == (["a@x.com"], "b@y"))
        #expect(MailRecipientTokens.consume("a@x.com, b@y.com,") == (["a@x.com", "b@y.com"], ""))
    }

    @Test func aSpaceAfterAnAddressFinishesIt() {
        #expect(MailRecipientTokens.consume("a@x.com ") == (["a@x.com"], ""))
        #expect(MailRecipientTokens.consume("a@x.com b") == (["a@x.com"], "b"))
    }

    /// A name comes before its address, and may itself contain spaces.
    @Test func aSpaceInANameDoesNot() {
        #expect(MailRecipientTokens.consume("王 大明 ") == ([], "王 大明 "))
        #expect(MailRecipientTokens.consume("Bob Chen <bob@x.com> ") == (["Bob Chen <bob@x.com>"], ""))
        #expect(MailRecipientTokens.consume("\"Chen, Bob\" <b").finished.isEmpty)
        #expect(MailRecipientTokens.consume("<bob@x.com , ").finished.isEmpty)
    }

    @Test func separatorsAloneFinishNothing() {
        #expect(MailRecipientTokens.consume(" ") == ([], ""))
        #expect(MailRecipientTokens.consume(",") == ([], ""))
        #expect(MailRecipientTokens.consume(", ,") == ([], ""))
    }

    /// The view model keeps one comma-separated string; the bubbles are only its display.
    @Test func theFieldComposesToWhatTheViewModelParses() {
        #expect(MailRecipientTokens.compose(["a@x.com", "Bob <b@y.com>"], draft: "c@") == "a@x.com, Bob <b@y.com>, c@")
        #expect(MailRecipientTokens.compose([], draft: " ") == "")
        #expect(MailRecipientTokens.compose(["a@x.com"], draft: "") == "a@x.com")
    }

    /// A reply's prefilled recipients split on commas only: a space there belongs to a name.
    @Test func aPrefilledValueBecomesBubbles() {
        #expect(MailRecipientTokens.tokens(of: "王 大明 <w@x.com>, b@y.com") == ["王 大明 <w@x.com>", "b@y.com"])
        #expect(MailRecipientTokens.tokens(of: "\"Chen, Bob\" <b@y.com>") == ["\"Chen, Bob\" <b@y.com>"])
        #expect(MailRecipientTokens.tokens(of: "").isEmpty)
    }

    @Test func aBubbleIsMarkedByTheSameRuleTheSendUses() {
        #expect(MailComposeViewModel.sendableAddress("a@x.com") != nil)
        #expect(MailComposeViewModel.sendableAddress("not an address") == nil)
        #expect(MailComposeViewModel.sendableAddress("王@例子.台灣") == nil)
    }

    @Test func aReadRecipientShowsAsText() {
        let list = MailRecipient.parse(["\"王大明\" <w@x.com>", "b@y.com", "undisclosed-recipients:"], ownAddress: nil)
        #expect(list.map(\.displayText) == ["王大明 <w@x.com>", "b@y.com", "undisclosed-recipients:"])
    }
}
#endif
