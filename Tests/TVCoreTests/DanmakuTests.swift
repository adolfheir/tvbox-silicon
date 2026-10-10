import Foundation
import Testing
@testable import TVCore

@Test func danmakuRejectsMalformedRowsAndDoesNotConfuseColorWithFontSize() throws {
    let data = Data(#"""
    {"comments":[
      {"p":"2.52,5,16711680,user","m":"红色顶部"},
      {"p":"1.0,1,65280,user","m":"绿色滚动"},
      {"p":"1.0,1,65280,user","m":"绿色滚动"},
      {"p":"-1,1,0,user","m":"invalid"},
      {"p":"nan,1,0,user","m":"invalid"},
      {"p":"3,7,0,user","m":"unsupported advanced animation"},
      {"p":"3,4,255,user","m":"   "},
      {"p":"4,4,255,user","m":"蓝色底部"}]}
    """#.utf8)
    let comments = try DanmakuParser.parse(data)
    #expect(comments.count == 3)
    #expect(comments.map(\.time) == [1, 2.52, 4])
    #expect(comments.map(\.color) == [0x00ff00, 0xff0000, 0x0000ff])
    #expect(comments.map(\.mode) == [.scroll, .top, .bottom])
    #expect(throws: (any Error).self) { try DanmakuParser.parse(Data("<html>error</html>".utf8)) }
    #expect(throws: (any Error).self) { try DanmakuParser.parse(Data(repeating: 0, count: DanmakuParser.maximumBytes + 1)) }
}

@Test func danmakuTracksMediaTimeAcrossPauseSeekAndOffsetWithoutStaleComments() {
    let comments = [0.0, 10, 20].map { DanmakuComment(time: $0, mode: 1, color: 0xffffff, text: "测试弹幕")! }
    let timeline = DanmakuTimeline(comments: comments, width: 800, lanes: 3, fontSize: 20)
    #expect(timeline.visible(at: 1).map(\.comment.time) == [0])
    #expect(timeline.visible(at: 1).map(\.comment.time) == [0]) // Paused clock.
    #expect(timeline.visible(at: 21).map(\.comment.time) == [20]) // Forward seek.
    #expect(timeline.visible(at: 2).map(\.comment.time) == [0]) // Backward seek.
    #expect(timeline.visible(at: 21 - 2).isEmpty) // Positive delay.
    #expect(timeline.visible(at: .nan).isEmpty)
}

@Test func danmakuDropsOvercrowdedCommentsAndKeepsFixedLanesSeparate() {
    let comments = (0..<200).map { DanmakuComment(time: 1, mode: 1, color: 0xffffff, text: "弹幕\($0)")! }
        + [DanmakuComment(time: 1, mode: 5, color: 0xffffff, text: "顶部")!,
           DanmakuComment(time: 1, mode: 4, color: 0xffffff, text: "底部")!]
    let timeline = DanmakuTimeline(comments: comments, width: 800, lanes: 4, fontSize: 22)
    #expect(timeline.visible(at: 2).count == 6)
    #expect(timeline.visible(at: 6).allSatisfy { $0.comment.mode == .scroll })
    #expect(timeline.visible(at: 100).isEmpty)
}

@Test func danmakuAcceptsSelfHostedPrefixWithoutDuplicatingAPIVersion() throws {
    let client = try DanmakuClient(address: "https://example.com/private-prefix/api/v2/")
    #expect(client.server.absoluteString == "https://example.com/private-prefix")
    #expect(throws: (any Error).self) { try DanmakuClient(address: "https://example.com/?token=example") }
    #expect(throws: (any Error).self) { try DanmakuClient(address: "https://name:password@example.com") }
}

@Test func bilibiliXMLKeepsColorAndEscapedTextAndRejectsEntityDefinitions() throws {
    let data = Data(#"<?xml version="1.0"?><i><d p="2.5,1,25,16711680,0,0,user,1">A &amp; B</d><d p="4,4,25,255,0,0,u,2">底部</d></i>"#.utf8)
    let comments = try DanmakuParser.parse(data)
    #expect(comments.count == 2)
    #expect(comments.first?.color == 0xff0000)
    #expect(comments.first?.text == "A & B")
    #expect(comments.last?.mode == .bottom)
    #expect(throws: (any Error).self) { try DanmakuParser.parse(Data("<!DOCTYPE i [<!ENTITY x 'text'>]><i/>".utf8)) }
    #expect(throws: (any Error).self) { try DanmakuParser.parse(Data("<i><d>broken".utf8)) }
}
