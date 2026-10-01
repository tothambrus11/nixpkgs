import Foundation
import Lib

let url = URL(fileURLWithPath: "/tmp")
let greeter = Greeter(home: url)
let message: String = greeter.greet("Nix")
print(message)
let broken: Int = "not an int"
