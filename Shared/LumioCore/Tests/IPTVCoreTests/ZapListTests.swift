import Testing
@testable import IPTVCore

@Suite("Zapping")
struct ZapListTests {
    struct Item: Identifiable, Sendable, Equatable {
        var id: String
        var number: Int?
    }

    let list = [Item(id: "a", number: 101), Item(id: "b", number: 102), Item(id: "c", number: nil)]

    @Test func upAndDownWrapAround() {
        var zap = ZapList<Item>()
        zap.watch(list[0], in: list)
        #expect(zap.channel(by: 1)?.id == "b")
        #expect(zap.channel(by: -1)?.id == "c")
        zap.watch(list[2])
        #expect(zap.channel(by: 1)?.id == "a")
        #expect(zap.channel(by: 4)?.id == "a")
    }

    @Test func numbersPickTheNumberedChannelThenThePosition() {
        var zap = ZapList<Item>()
        zap.watch(list[0], in: list)
        #expect(zap.channel(number: 102, numberOf: \.number)?.id == "b")
        #expect(zap.channel(number: 3, numberOf: \.number)?.id == "c")
        #expect(zap.channel(number: 999, numberOf: \.number) == nil)
    }

    @Test func previousIsTheChannelBeforeAndAListIsKeptUntilReplaced() {
        var zap = ZapList<Item>()
        zap.watch(list[0], in: list)
        zap.watch(list[1])
        #expect(zap.previous?.id == "a")
        zap.watch(list[1])
        #expect(zap.previous?.id == "a")
        #expect(zap.channels.count == 3)
        zap.watch(Item(id: "solo"), in: [])
        #expect(zap.channels.count == 3)
    }

    @Test func aChannelWithNoListZapsToItself() {
        var zap = ZapList<Item>()
        zap.watch(list[1])
        #expect(zap.channel(by: 1)?.id == "b")
    }
}
