import Testing

@testable import Greeter

@Test func greetsByName() {
    #expect(greet("Nixpkgs") == "Hello, Nixpkgs!")
}
