import Foundation

public struct Greeter {
    public let home: URL
    public init(home: URL) { self.home = home }
    public func greet(_ name: String) -> String { "Hello, \(name) from \(home.path)" }
}
