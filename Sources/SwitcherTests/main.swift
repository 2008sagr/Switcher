import Foundation

let filter = CommandLine.arguments.dropFirst().first

let suites: [(String, [TestCase])] = [
    ("LayoutConverterTests", layoutConverterTests),
    ("KeyboardLayoutTableTests", keyboardLayoutTableTests),
]

exit(runSuites(suites, filter: filter))
