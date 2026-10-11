import Testing
@testable import TVCore

@Test func screenSeekingUsesFrozenOriginAndClampsToMediaBounds() throws {
    let scrub = try #require(PlaybackScrub(position: 100, duration: 300, width: 1000))
    #expect(scrub.target(translation: 250) == 130)
    #expect(scrub.target(translation: -250) == 70)
    #expect(scrub.target(translation: -1000) == 0)
    #expect(scrub.target(translation: 2000) == 220)
    let nearEnd = try #require(PlaybackScrub(position: 290, duration: 300, width: 500))
    #expect(nearEnd.target(translation: 100) == 300)
    #expect(nearEnd.target(translation: .nan) == 290)
    #expect(scrub.target(translation: 250) == PlaybackScrub(position: 100, duration: 300, width: 500)?.target(translation: 125))
}

@Test func screenSeekingRejectsUnknownMediaAndVerticalOrAccidentalDrags() {
    #expect(PlaybackScrub(position: 30, duration: .infinity, width: 500) == nil)
    #expect(PlaybackScrub(position: .nan, duration: 300, width: 500) == nil)
    #expect(PlaybackScrub(position: 30, duration: 0, width: 500) == nil)
    #expect(PlaybackScrub(position: 30, duration: 300, width: 0) == nil)
    #expect(!PlaybackScrub.isHorizontal(x: 5, y: 0))
    #expect(!PlaybackScrub.isHorizontal(x: 20, y: 100))
    #expect(!PlaybackScrub.isHorizontal(x: 50, y: 50))
    #expect(PlaybackScrub.isHorizontal(x: 100, y: 5))
    #expect(PlaybackScrub.isHorizontal(x: -100, y: 5))
}
