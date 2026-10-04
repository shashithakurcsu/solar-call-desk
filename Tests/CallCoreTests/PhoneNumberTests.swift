import XCTest
@testable import CallCore

final class PhoneNumberTests: XCTestCase {
    func testNormalizesOnlySupportedFormatting() throws {
        let number = try PhoneNumber("  +1 (312) 555-0123  ")
        XCTAssertEqual(number.normalized, "+13125550123")
        XCTAssertEqual(try PhoneNumber("+44.20.7946.0123").normalized, "+442079460123")
        XCTAssertEqual(number.masked, "+•••••••0123")
        XCTAssertEqual(number.description, number.masked)
        XCTAssertFalse(number.description.contains("312"))
    }

    func testAcceptsEightAndFifteenDigitBoundaries() throws {
        XCTAssertEqual(try PhoneNumber("+12345678").normalized, "+12345678")
        XCTAssertEqual(try PhoneNumber("+123456789012345").normalized, "+123456789012345")
    }

    func testRejectsLocalNumbersAndInvalidLength() {
        assertRejected("3125550123", as: .mustUseInternationalFormat)
        assertRejected("0013125550123", as: .mustUseInternationalFormat)
        assertRejected("+1234567", as: .invalidLength)
        assertRejected("+1234567890123456", as: .invalidLength)
        assertRejected("+", as: .invalidLength)
        assertRejected("+0123456789", as: .invalidCountryCode)
        assertRejected("   ", as: .empty)
    }

    func testRejectsURLsExtensionsAndDialCodes() {
        let unsafeValues = [
            "tel:+13125550123", "https://example.com/+13125550123",
            "+13125550123;ext=1", "+13125550123x123", "+13125550123,123",
            "+13125550123;123", "+13125550123#", "*67+13125550123",
            "+13125550123?call", "+13125550123%0A", "++13125550123"
        ]
        for value in unsafeValues { assertRejected(value, as: .invalidCharacters) }
    }

    func testRejectsControlsAndUnicodeLookalikes() {
        let unsafeValues = [
            "+13125550123\n", "\t+13125550123", "+1312\r5550123",
            "+13125550123\0", "+１３１２５５５０１２３", "+١٣١٢٥٥٥٠١٢٣",
            "+1\u{00A0}3125550123", "+1\u{200B}3125550123", "＋13125550123"
        ]
        for value in unsafeValues { assertRejected(value, as: .invalidCharacters) }
    }

    private func assertRejected(
        _ input: String,
        as expected: PhoneNumber.ValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try PhoneNumber(input), file: file, line: line) { error in
            XCTAssertEqual(error as? PhoneNumber.ValidationError, expected, file: file, line: line)
        }
    }
}
