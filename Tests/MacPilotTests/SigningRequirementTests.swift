import Foundation
import Testing
@testable import MacPilot

/// Tripwires around the one thing that must never change silently: the
/// designated requirement every build embeds.
///
/// macOS uses that requirement to decide whether an update package is "the same
/// app" as the one already installed, so a build signed with a requirement the
/// installed app does not recognise can never be installed. That is exactly what
/// stranded every MacPilot below v1.1.355: releases carried one form of the
/// requirement while locally built apps carried another.
///
/// These tests read the packaging scripts on purpose. They are the guard against
/// a future change -- another machine, another agent, a well meant
/// "simplification" -- quietly reintroducing per-identity or per-host bytes, or
/// dropping the verification gate that catches it.
struct SigningRequirementTests {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/MacPilotTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
    }

    private func script(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test func designatedRequirementIsDefinedOnceAndPinsTheTeam() throws {
        let requirement = try script("Scripts/signing-requirement.sh")

        // One definition, one team, one bundle-identifier placeholder.
        #expect(requirement.components(separatedBy: "MACPILOT_SIGNING_TEAM_ID=").count == 2)
        #expect(requirement.contains(#"MACPILOT_SIGNING_TEAM_ID="U8U443D7ZL""#))
        #expect(requirement.contains("certificate leaf[subject.OU] = $MACPILOT_SIGNING_TEAM_ID"))
        #expect(requirement.contains(#"identifier \"$1\""#))
    }

    @Test func designatedRequirementStaysSatisfiableByEverySigningIdentity() throws {
        let requirement = try script("Scripts/signing-requirement.sh")

        // Developer ID only OID clauses and certificate-CN clauses are each
        // satisfied by exactly one kind of certificate. Pinning either one
        // splits the requirement bytes by signing identity: an Apple Development
        // build stops being "the same app" as a release, so the two can no
        // longer update into each other and privacy grants stop carrying over.
        #expect(!requirement.contains("field.1.2.840.113635.100.6.2.6"))
        #expect(!requirement.contains("field.1.2.840.113635.100.6.1.13"))
        #expect(!requirement.contains("subject.CN"))
    }

    @Test func updaterTeamMatchesThePinnedSigningTeam() throws {
        // The updater rejects packages signed by another team; it must agree
        // with the team the packaging scripts pin into the requirement.
        let requirement = try script("Scripts/signing-requirement.sh")

        #expect(UpdatePackageValidator.developerTeamIdentifier == "U8U443D7ZL")
        #expect(requirement.contains(
            #"MACPILOT_SIGNING_TEAM_ID="\#(UpdatePackageValidator.developerTeamIdentifier)""#
        ))
    }

    @Test func everyPackagingEntryPointVerifiesTheRequirement() throws {
        let build = try script("Scripts/build-app.sh")
        let distribute = try script("Scripts/distribute-app.sh")
        let workflow = try script(".github/workflows/build.yml")
        let verifier = try script("Scripts/verify-signing-requirement.sh")

        // Every path that can produce a package hands it to the verifier, and
        // the verifier takes its expectation from the single definition.
        #expect(build.contains(#"source "$ROOT/Scripts/signing-requirement.sh""#))
        #expect(build.contains("verify-signing-requirement.sh"))
        #expect(distribute.contains("verify-signing-requirement.sh"))
        #expect(workflow.contains("verify-signing-requirement.sh"))
        #expect(verifier.contains(#"source "$ROOT/Scripts/signing-requirement.sh""#))

        // No signing path may fall back to a requirement codesign derived by
        // itself, which is what made the bytes depend on the signing machine.
        #expect(!build.contains("SHARED_REQUIREMENT"))
    }
}
