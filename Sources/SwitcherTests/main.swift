import Foundation

let filter = CommandLine.arguments.dropFirst().first

let suites: [(String, [TestCase])] = [
    ("KeyboardLayoutTableTests", keyboardLayoutTableTests),
    ("LayoutMapperTests", layoutMapperTests),
    ("TrigramModelTests", trigramModelTests),
    ("LayoutDetectorCalibrationTests", layoutDetectorCalibrationTests),
    ("LanguagePriorTests", languagePriorTests),
]

exit(runSuites(suites, filter: filter))
