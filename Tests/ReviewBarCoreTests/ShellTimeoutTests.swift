import Testing
import Foundation
@testable import ReviewBarCore

@Test func captureGivesUpOnHungCommand() throws {
    let start = Date()
    #expect(throws: Shell.RunError.self) { try Shell.capture(["/bin/sleep", "30"], timeout: 1) }
    #expect(Date().timeIntervalSince(start) < 5)
}
