import CheckSuites
import Foundation

// Unbuffered so progress is visible when output is piped to a file.
setvbuf(stdout, nil, _IONBF, 0)

// Gate checks for SoundboardKit. Exit 0 = pass, 1 = a gate is not met.
// Fail closed: a failing gate blocks the phase, it does not become a TODO
// (DG-AGENT-04).
//
// The same suites also run under `swift test`, via the SoundboardKitTests
// target. This executable exists alongside it because it needs no test host
// and prints a readable line per assertion, which is what a phase gate is
// read for.

await AllSuites.run()

AllSuites.report()
