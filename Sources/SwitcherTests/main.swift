import Foundation

let filter = CommandLine.arguments.dropFirst().first

let suites: [(String, [TestCase])] = [
    ("KeyboardLayoutTableTests", keyboardLayoutTableTests),
    ("LayoutMapperTests", layoutMapperTests),
    ("TrigramModelTests", trigramModelTests),
    ("LayoutDetectorCalibrationTests", layoutDetectorCalibrationTests),
    ("LanguagePriorTests", languagePriorTests),
    ("GuardRulesTests", guardRulesTests),
    ("KeystrokeBufferTests", keystrokeBufferTests),
    ("EventTapControllerTests", eventTapControllerTests),
    ("ClipboardGuardTests", clipboardGuardTests),
]

exit(runSuites(suites, filter: filter))
