import XCTest
@testable import Trans

final class SelectionBubbleLayoutTests: XCTestCase {
    func testResultUsesWordWrappingThatAlsoSupportsCJKBreaks() {
        XCTAssertEqual(
            SelectionResultTextStyle.paragraphStyle.lineBreakMode,
            .byWordWrapping
        )
    }

    func testShortChineseResultKeepsRoomForDragHandleOnFirstLine() {
        let text = "翻译结果"
        let measuredTextWidth = ceil(
            (text as NSString).size(
                withAttributes: SelectionResultTextStyle.attributes
            ).width
        )
        let bubbleWidth = SelectionResultTextStyle.bubbleWidth(
            for: text,
            maximumWidth: 200
        )
        let availableFirstLineWidth = bubbleWidth
            - (SelectionResultTextStyle.textContainerInset.width * 2)
            - SelectionResultTextStyle.firstLineAccessoryWidth

        XCTAssertGreaterThan(availableFirstLineWidth, measuredTextWidth)
        XCTAssertLessThan(bubbleWidth, 200)
    }
}
