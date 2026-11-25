import Foundation
// Just enough of XCTest to run Phone/Tests/BackgroundDownloadsTests.swift
// unchanged with the macOS command line tools, which ship no XCTest.
@MainActor class XCTestCase {
    required init() {}
    func setUp() async throws {}
    func tearDown() async throws {}
}
nonisolated(unsafe) var failures = 0
func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    failures += 1; print("    FAIL \(file):\(line) \(message)")
}
func XCTAssertTrue(_ v: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    if (try? v()) != true { XCTFail("not true. \(m())", file: file, line: line) }
}
func XCTAssertFalse(_ v: @autoclosure () throws -> Bool, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    if (try? v()) != false { XCTFail("not false. \(m())", file: file, line: line) }
}
func XCTAssertNil<T>(_ v: @autoclosure () throws -> T?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    if let x = try? v() { XCTFail("not nil: \(x). \(m())", file: file, line: line) }
}
func XCTAssertNotNil<T>(_ v: @autoclosure () throws -> T?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    if (try? v()) == nil { XCTFail("nil. \(m())", file: file, line: line) }
}
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    let x = try? a(), y = try? b()
    if x != y { XCTFail("\(String(describing: x)) != \(String(describing: y)). \(m())", file: file, line: line) }
}
struct Unwrapped: Error {}
func XCTUnwrap<T>(_ v: @autoclosure () throws -> T?, _ m: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let x = try v() else { XCTFail("unwrap nil. \(m())", file: file, line: line); throw Unwrapped() }
    return x
}
