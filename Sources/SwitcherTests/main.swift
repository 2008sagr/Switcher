import Foundation

let filter = CommandLine.arguments.dropFirst().first

let suites: [(String, [TestCase])] = [
    ("KeyboardLayoutTableTests", keyboardLayoutTableTests),
    ("LayoutMapperTests", layoutMapperTests),
]

exit(runSuites(suites, filter: filter))
