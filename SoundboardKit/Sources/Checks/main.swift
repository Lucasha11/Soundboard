import Foundation

// Unbuffered so progress is visible when output is piped to a file.
setvbuf(stdout, nil, _IONBF, 0)

// Gate checks for SoundboardKit. Exit 0 = pass, 1 = a gate is not met.
// Fail closed: a failing gate blocks the phase, it does not become a TODO
// (DG-AGENT-04).

GovernanceChecks.run()
StoreChecks.run()
VerifierChecks.run()
AudioChecks.run()
PlaybackChecks.run()
await VisualChecks.run()
await EndToEndChecks.run()

Check.report()
