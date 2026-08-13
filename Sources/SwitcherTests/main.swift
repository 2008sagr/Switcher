import Foundation

let filter = CommandLine.arguments.dropFirst().first

let suites: [(String, [TestCase])] = [
    ("LayoutConverterTests", layoutConverterTests),
]

exit(runSuites(suites, filter: filter))
