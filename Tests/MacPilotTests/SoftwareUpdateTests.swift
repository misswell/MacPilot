import Foundation
import Testing
@testable import MacPilot

struct SoftwareUpdateTests {
    @Test func comparesSemanticVersionsNumerically() throws {
        let current = try #require(SoftwareVersion("1.9.9"))
        let available = try #require(SoftwareVersion("v1.10.0"))

        #expect(current < available)
        #expect(SoftwareVersion("1.10") == SoftwareVersion("1.10.0"))
        #expect(SoftwareVersion("not-a-version") == nil)
    }

    @Test func decodesReleaseAndSelectsVerifiedMacArchive() throws {
        let json = """
        {
          "tag_name": "v1.2.3",
          "name": "MacPilot v1.2.3",
          "body": "Safer updates",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "source.zip",
              "browser_download_url": "https://example.com/source.zip",
              "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            },
            {
              "name": "MacPilot-1.2.3-macos.zip",
              "browser_download_url": "https://example.com/MacPilot-1.2.3-macos.zip",
              "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            }
          ]
        }
        """

        let release = try SoftwareRelease.decodeGitHubResponse(Data(json.utf8))

        #expect(release.version == SoftwareVersion("1.2.3"))
        #expect(release.releaseNotes == "Safer updates")
        #expect(release.archiveURL.absoluteString == "https://example.com/MacPilot-1.2.3-macos.zip")
        #expect(release.sha256 == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    }

    @Test func acceptsLegacyArchiveNameDuringRenameTransition() throws {
        let json = """
        {
          "tag_name": "v1.2.3",
          "body": "",
          "draft": false,
          "prerelease": false,
          "assets": [{
            "name": "OctoPilot-1.2.3-macos.zip",
            "browser_download_url": "https://example.com/OctoPilot-1.2.3-macos.zip",
            "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
          }]
        }
        """

        let release = try SoftwareRelease.decodeGitHubResponse(Data(json.utf8))

        #expect(release.archiveURL.lastPathComponent == "OctoPilot-1.2.3-macos.zip")
    }

    @Test func appIdentityKeepsLegacyBundleForMigration() {
        #expect(AppIdentity.bundleIdentifier == "com.misswell.macpilot")
        #expect(AppIdentity.knownBundleIdentifiers.contains("com.misswell.octopilot"))
        #expect(AppIdentity.archiveNames(for: "1.2.3") == [
            "MacPilot-1.2.3-macos.zip",
            "OctoPilot-1.2.3-macos.zip"
        ])
    }

    @Test func reportsAnUpdateOnlyForANewerVersion() throws {
        let release = SoftwareRelease(
            version: try #require(SoftwareVersion("2.0.0")),
            releaseNotes: "",
            archiveURL: try #require(URL(string: "https://example.com/update.zip")),
            sha256: String(repeating: "a", count: 64)
        )

        #expect(release.isNewer(than: "1.9.9"))
        #expect(!release.isNewer(than: "2.0"))
        #expect(!release.isNewer(than: "2.1.0"))
        #expect(!release.isNewer(than: "development"))
    }

    @Test func rejectsAnArchiveWithoutGitHubsDigest() throws {
        let json = """
        {
          "tag_name": "v1.2.3",
          "body": "",
          "draft": false,
          "prerelease": false,
          "assets": [{
            "name": "MacPilot-1.2.3-macos.zip",
            "browser_download_url": "https://example.com/update.zip",
            "digest": null
          }]
        }
        """

        do {
            _ = try SoftwareRelease.decodeGitHubResponse(Data(json.utf8))
            Issue.record("A release without a SHA-256 digest was accepted")
        } catch let error as SoftwareUpdateError {
            #expect(error == .missingVerifiedArchive)
        }
    }

    @Test func computesArchiveSHA256() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPilotTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("MacPilot".utf8).write(to: url, options: .atomic)

        #expect(try UpdatePackageValidator.sha256(of: url) == "b10258073cf5d4342e110670f209c169f6782b984152416bbdcd61d77a1dbdc7")
    }

    @Test func localizesUpdateActionsAndFailures() {
        #expect(AppText.value("downloadAndInstall", language: .simplifiedChinese) == "下载并安装")
        #expect(AppText.value("downloadAndInstall", language: .english) == "Download and Install")
        #expect(AppText.value("updateErrorLocation", language: .simplifiedChinese).contains("应用程序"))
        #expect(AppText.value("updateErrorLocation", language: .english).contains("Applications"))
    }
}
