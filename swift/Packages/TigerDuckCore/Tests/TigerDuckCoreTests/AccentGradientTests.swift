import Foundation
import Testing
import TigerDuckCore

struct AccentGradientTests {
    @Test func oneColourIsAnAccentWithoutAGradient() {
        let accent = AccentGradient(color: 0x5856D6)

        #expect(accent.stops == [0x5856D6])
        #expect(accent.first == 0x5856D6)
        #expect(!accent.isGradient)
    }

    @Test func anAccentHasOneToFiveStops() {
        #expect(AccentGradient(stops: []) == nil)
        #expect(AccentGradient(stops: Array(repeating: 0x007AFF, count: 6)) == nil)
        for count in 1...5 {
            let accent = AccentGradient(stops: Array(repeating: 0x007AFF, count: count))
            #expect(accent?.stops.count == count)
            #expect(accent?.isGradient == (count > 1))
        }
    }

    @Test func aChangeThatLeavesNoStopOrASixthIsUndone() throws {
        var accent = try #require(AccentGradient(stops: [0x111111, 0x222222, 0x333333, 0x444444, 0x555555]))
        #expect(!accent.canAddStop)
        accent.stops.append(0x666666)
        #expect(accent.stops == [0x111111, 0x222222, 0x333333, 0x444444, 0x555555])

        var single = AccentGradient(color: 0x111111)
        #expect(single.canAddStop)
        single.stops.removeAll()
        #expect(single.stops == [0x111111])
    }

    @Test func stopsCanBeAddedRemovedMovedAndReplaced() throws {
        var accent = try #require(AccentGradient(stops: [0x111111, 0x222222]))
        accent.stops.append(0x333333)
        accent.stops.swapAt(0, 2)
        accent.stops[1] = 0x444444
        accent.stops.remove(at: 0)

        #expect(accent.stops == [0x444444, 0x111111])
    }

    @Test func aStopKeepsOnlyItsRGB() throws {
        var accent = try #require(AccentGradient(stops: [0xFF5856D6, 0x007AFF]))
        accent.stops[1] = 0x7F34C759

        #expect(accent.stops == [0x5856D6, 0x34C759])
        #expect(AccentGradient(color: 0xFF5856D6).first == 0x5856D6)
    }

    @Test func aLinearGradientHasEightDirectionsAndThereAreFourStyles() {
        #expect(AccentGradient.Direction.allCases.count == 8)
        #expect(AccentGradient.Style.allCases == [.linear, .radial, .angular, .mesh])
        #expect(AccentGradient(color: 0).style == .linear)
        #expect(AccentGradient(color: 0).direction == .topLeftToBottomRight)
    }

    @Test(arguments: AccentGradient.Style.allCases, AccentGradient.Direction.allCases)
    func anAccentSurvivesEncoding(style: AccentGradient.Style, direction: AccentGradient.Direction) throws {
        let accent = try #require(AccentGradient(stops: [0x4B48D1, 0x9442C7, 0xD61F45], style: style, direction: direction))

        let decoded = try JSONDecoder().decode(AccentGradient.self, from: JSONEncoder().encode(accent))

        #expect(decoded == accent)
    }

    @Test(arguments: [
        #"{"stops":[],"style":"linear","direction":"leftToRight"}"#,
        #"{"stops":[1,2,3,4,5,6],"style":"linear","direction":"leftToRight"}"#,
        #"{"stops":[1,2],"style":"diamond","direction":"leftToRight"}"#,
        #"{"stops":[1,2],"style":"linear"}"#,
    ])
    func aStoredValueOutsideTheRulesDoesNotDecode(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AccentGradient.self, from: Data(json.utf8))
        }
    }

    @Test func theAccentFromBeforeGradientsIsItsOneColour() {
        let saved = AccentGradient.saved(nil, accentHex: 0x5856D6)

        #expect(saved == AccentGradient(color: 0x5856D6))
    }

    @Test func aGradientCountsWhileItsFirstStopIsTheSavedAccent() throws {
        let gradient = try #require(AccentGradient(stops: [0x4B48D1, 0xD61F45], style: .mesh))

        #expect(AccentGradient.saved(gradient, accentHex: 0x4B48D1) == gradient)
        #expect(AccentGradient.saved(gradient, accentHex: 0x7F4B48D1) == gradient)
        #expect(AccentGradient.saved(gradient, accentHex: 0x007AFF) == AccentGradient(color: 0x007AFF))
        #expect(AccentGradient.saved(AccentGradient(color: 0x4B48D1), accentHex: 0x007AFF) == AccentGradient(color: 0x007AFF))
    }

    @Test func aMeshPutsEachStopOnItsSpot() throws {
        let four = try #require(AccentGradient(stops: [0xFF0000, 0x00FF00, 0x0000FF, 0x000000], style: .mesh))
        let five = try #require(AccentGradient(stops: [0xFF0000, 0x00FF00, 0x0000FF, 0x000000, 0xFFFFFF], style: .mesh))

        #expect(four.meshColors.count == 9)
        #expect([four.meshColors[0], four.meshColors[2], four.meshColors[8], four.meshColors[6]] == four.stops)
        #expect(five.meshColors[4] == 0xFFFFFF)
        #expect(AccentGradient(color: 0x5856D6).meshColors == Array(repeating: 0x5856D6, count: 9))
    }

    @Test func aMeshBlendsBetweenItsSpots() throws {
        let two = try #require(AccentGradient(stops: [0x000000, 0xFEFEFE], style: .mesh))

        #expect(two.meshColors[0] == 0x000000)
        #expect(two.meshColors[8] == 0xFEFEFE)
        #expect(two.meshColors[4] == 0x7F7F7F)
    }
}
