import Foundation
import XCTest
@testable import WhisperCore

final class MultipartFormDataTests: XCTestCase {
    func testEmptyFormContainsOnlyClosingBoundary() {
        let form = MultipartFormData(boundary: "Boundary")

        XCTAssertTrue(form.isEmpty)
        XCTAssertEqual(form.count, 0)
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=Boundary")
        XCTAssertEqual(String(decoding: form.body, as: UTF8.self), "--Boundary--\r\n")
    }

    func testTextFieldEncodingUsesRequiredCRLFLayout() {
        var form = MultipartFormData(boundary: "B")
        form.appendField(name: "model", value: "whisper-1")

        XCTAssertEqual(
            String(decoding: form.encoded(), as: UTF8.self),
            "--B\r\n"
                + "Content-Disposition: form-data; name=\"model\"\r\n"
                + "\r\n"
                + "whisper-1\r\n"
                + "--B--\r\n"
        )
        XCTAssertEqual(form.count, 1)
    }

    func testFieldsAndFilePreserveAppendOrderAndBinaryBytes() {
        let bytes = Data([0x00, 0x0D, 0x0A, 0xFF])
        var form = MultipartFormData(boundary: "XYZ")
        form.appendField(name: "language", value: "uk")
        form.appendFile(
            name: "file",
            filename: "sample.wav",
            mimeType: "audio/wav",
            data: bytes
        )

        var expected = Data(
            ("--XYZ\r\n"
                + "Content-Disposition: form-data; name=\"language\"\r\n"
                + "\r\n"
                + "uk\r\n"
                + "--XYZ\r\n"
                + "Content-Disposition: form-data; name=\"file\"; filename=\"sample.wav\"\r\n"
                + "Content-Type: audio/wav\r\n"
                + "\r\n").utf8
        )
        expected.append(bytes)
        expected.append(contentsOf: "\r\n--XYZ--\r\n".utf8)

        XCTAssertEqual(form.body, expected)
        XCTAssertEqual(form.count, 2)
    }

    func testRepeatedEncodingIsIdempotent() {
        var form = MultipartFormData(boundary: "Stable")
        form.append("value", name: "field")

        let first = form.body
        XCTAssertEqual(form.body, first)
        XCTAssertEqual(form.encode(), first)
        XCTAssertEqual(form.encoded(), first)
        XCTAssertEqual(
            occurrences(of: Data("--Stable--\r\n".utf8), in: first),
            1
        )
    }

    func testHeaderParametersAreEscapedWithoutAddingHeaderLines() {
        var form = MultipartFormData(boundary: "Safe")
        form.appendFile(
            name: "na\"me\r\nx",
            filename: "a\\b\"\n.wav",
            mimeType: "audio/wav\r\nX-Evil: yes",
            data: Data()
        )

        let body = String(decoding: form.body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"na\\\"me%0D%0Ax\""))
        XCTAssertTrue(body.contains("filename=\"a\\\\b\\\"%0A.wav\""))
        XCTAssertTrue(body.contains("Content-Type: audio/wavX-Evil: yes\r\n"))
        XCTAssertFalse(body.contains("\r\nX-Evil:"))
    }

    func testEmptyMIMETypeFallsBackToBinary() {
        var form = MultipartFormData(boundary: "B")
        form.appendFile(
            name: "file",
            filename: "blob",
            mimeType: "",
            data: Data([1])
        )

        XCTAssertTrue(
            String(decoding: form.body, as: UTF8.self)
                .contains("Content-Type: application/octet-stream\r\n")
        )
    }

    func testConvenienceOverloadsProduceTheSameEncoding() {
        var canonical = MultipartFormData(boundary: "B")
        canonical.append(Data("one".utf8), name: "field")
        canonical.appendFile(
            name: "file",
            filename: "a.wav",
            mimeType: "audio/wav",
            data: Data([1, 2, 3])
        )

        var compatibility = MultipartFormData(boundary: "B")
        compatibility.append(Data("one".utf8), withName: "field")
        compatibility.append(
            Data([1, 2, 3]),
            withName: "file",
            fileName: "a.wav",
            mimeType: "audio/wav"
        )

        XCTAssertEqual(canonical.body, compatibility.body)
    }

    func testGeneratedBoundaryIsHeaderSafe() {
        let form = MultipartFormData()

        XCTAssertFalse(form.boundary.isEmpty)
        XCTAssertFalse(form.boundary.contains("\r"))
        XCTAssertFalse(form.boundary.contains("\n"))
        XCTAssertTrue(form.contentType.hasSuffix(form.boundary))
    }

    private func occurrences(of needle: Data, in haystack: Data) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }

        var count = 0
        var index = haystack.startIndex
        while index <= haystack.index(haystack.endIndex, offsetBy: -needle.count) {
            let end = haystack.index(index, offsetBy: needle.count)
            if haystack[index..<end].elementsEqual(needle) {
                count += 1
                index = end
            } else {
                index = haystack.index(after: index)
            }
        }
        return count
    }
}
