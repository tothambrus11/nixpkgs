import XCTest

@testable import Greeter

final class GreeterXCTests: XCTestCase {
    func testGreetsByName() {
        XCTAssertEqual(greet("Nixpkgs"), "Hello, Nixpkgs!")
    }
}
