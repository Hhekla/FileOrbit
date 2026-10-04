// Minimal assertion adapter for this repository's XCTest sources when only Apple's
// Command Line Tools are installed. This is not XCTest and does not claim XCTest parity.
// Unsupported APIs fail compilation. Skips are reported and make the run incomplete (exit 2).
import Foundation

class XCTestCase {
    func setUp() {}
    func setUpWithError() throws {}
    func tearDown() {}
    func tearDownWithError() throws {}
}

struct XCTSkip: Error, CustomStringConvertible {
    let description: String
    init(_ message: String = "Skipped", file: StaticString = #filePath, line: UInt = #line) {
        description = "\(message) (\(file):\(line))"
    }
}

private struct StandaloneAssertionAbort: Error {}

final class StandaloneResults: @unchecked Sendable {
    static let shared = StandaloneResults()
    private let lock = NSLock()
    private var failures = 0
    private var passes = 0
    private var failedTests = 0
    private var skips = 0

    var failureCount: Int { lock.lock(); defer { lock.unlock() }; return failures }

    func fail(_ message: String, file: StaticString, line: UInt) {
        lock.lock(); defer { lock.unlock() }
        failures += 1
        print("  ASSERTION FAILED \(file):\(line): \(message)")
    }

    @MainActor
    func run(_ name: String, create: @MainActor () -> XCTestCase,
             body: @MainActor (XCTestCase) async throws -> Void) async {
        print("RUN  \(name)")
        fflush(stdout)
        let before = failureCount
        let started = Date()
        let test = create()
        var skipped: String?
        do {
            try test.setUpWithError()
            test.setUp()
            try await body(test)
        } catch let reason as XCTSkip {
            skipped = reason.description
        } catch is StandaloneAssertionAbort {
            // XCTUnwrap already recorded this failure, exactly once.
        } catch {
            fail("Unexpected error: \(error)", file: #filePath, line: #line)
        }
        do { test.tearDown(); try test.tearDownWithError() }
        catch { fail("Teardown error: \(error)", file: #filePath, line: #line) }
        let elapsed = String(format: "%.3fs", Date().timeIntervalSince(started))
        if failureCount > before {
            failedTests += 1
            print("FAIL \(name) (\(elapsed))")
        } else if let skipped {
            skips += 1
            print("SKIP \(name): \(skipped)")
        } else {
            passes += 1
            print("PASS \(name) (\(elapsed))")
        }
        fflush(stdout)
    }

    func finish(expected: Int) -> Int32 {
        let total = passes + failedTests + skips
        print("SUMMARY discovered=\(expected) executed=\(total) passed=\(passes) failed=\(failedTests) skipped=\(skips) assertion_failures=\(failureCount)")
        if total != expected || failedTests > 0 || failureCount > 0 { return 1 }
        if skips > 0 {
            print("INCOMPLETE: skipped tests are not a successful verification.")
            return 2
        }
        return 0
    }
}

private func brief<T>(_ value: T) -> String { String(String(describing: value).prefix(1_000)) }

func XCTFail(_ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    StandaloneResults.shared.fail(message(), file: file, line: line)
}

func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) throws -> T {
    do {
        guard let value = try expression() else {
            XCTFail("Expected a non-nil value. \(message())", file: file, line: line)
            throw StandaloneAssertionAbort()
        }
        return value
    } catch is StandaloneAssertionAbort { throw StandaloneAssertionAbort() }
    catch { XCTFail("Unwrap threw: \(error). \(message())", file: file, line: line); throw StandaloneAssertionAbort() }
}

func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    do { if try !expression() { XCTFail("Expected true. \(message())", file: file, line: line) } }
    catch { XCTFail("Boolean expression threw: \(error). \(message())", file: file, line: line) }
}

func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(try !expression(), message(), file: file, line: line)
}

func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                  _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if x != y { XCTFail("\(brief(x)) != \(brief(y)). \(message())", file: file, line: line) } }
    catch { XCTFail("Equality expression threw: \(error). \(message())", file: file, line: line) }
}

func XCTAssertEqual<T: FloatingPoint>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                      accuracy: T, _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath, line: UInt = #line) {
    do {
        let x = try a(), y = try b()
        if !(x == y || (accuracy >= 0 && abs(x - y) <= accuracy)) {
            XCTFail("\(x) != \(y), tolerance \(accuracy). \(message())", file: file, line: line)
        }
    } catch { XCTFail("Approximate equality threw: \(error). \(message())", file: file, line: line) }
}

func XCTAssertNotEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                     _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { if try a() == b() { XCTFail("Expected unequal values. \(message())", file: file, line: line) } }
    catch { XCTFail("Inequality expression threw: \(error). \(message())", file: file, line: line) }
}

func XCTAssertNil<T>(_ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() != nil { XCTFail("Expected nil. \(message())", file: file, line: line) } }
    catch { XCTFail("Nil expression threw: \(error). \(message())", file: file, line: line) }
}

func XCTAssertNotNil<T>(_ expression: @autoclosure () throws -> T?, _ message: @autoclosure () -> String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
    do { if try expression() == nil { XCTFail("Expected non-nil. \(message())", file: file, line: line) } }
    catch { XCTFail("Non-nil expression threw: \(error). \(message())", file: file, line: line) }
}

func XCTAssertLessThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                      _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if !(x < y) { XCTFail("\(brief(x)) is not < \(brief(y)). \(message())", file: file, line: line) } }
    catch { XCTFail("Comparison threw: \(error). \(message())", file: file, line: line) }
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                             _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    do { let x = try a(), y = try b(); if !(x <= y) { XCTFail("\(brief(x)) is not <= \(brief(y)). \(message())", file: file, line: line) } }
    catch { XCTFail("Comparison threw: \(error). \(message())", file: file, line: line) }
}

func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                         _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThan(try b(), try a(), message(), file: file, line: line)
}

func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                                                _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(try b(), try a(), message(), file: file, line: line)
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
                             file: StaticString = #filePath, line: UInt = #line, _ errorHandler: (Error) -> Void = { _ in }) {
    do { _ = try expression(); XCTFail("Expected an error. \(message())", file: file, line: line) }
    catch { errorHandler(error) }
}

func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression() }
    catch { XCTFail("Unexpected error: \(error). \(message())", file: file, line: line) }
}
