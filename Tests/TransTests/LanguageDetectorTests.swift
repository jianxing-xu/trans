import XCTest
@testable import Trans

final class LanguageDetectorTests: XCTestCase {
    func testChineseInputTargetsEnglish() {
        XCTAssertEqual(LanguageDetector.automaticTarget(for: "你好，world").code, "en")
    }

    func testEnglishInputTargetsChinese() {
        XCTAssertEqual(LanguageDetector.automaticTarget(for: "Hello, world.").code, "zh-Hans")
    }

    func testJapaneseKanaWithoutHanTargetsChinese() {
        XCTAssertEqual(LanguageDetector.automaticTarget(for: "こんにちは").code, "zh-Hans")
    }
}
