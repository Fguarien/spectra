import Foundation
import Testing
@testable import Spectra

struct ProviderKindTests {

    @Test func allThreeProvidersAreWired() {
        #expect(ProviderKind.allCases.count == 3)
        for kind in ProviderKind.allCases {
            #expect(kind.isImplemented)
        }
    }

    @Test func labelsAreUserFacing() {
        #expect(ProviderKind.plex.label == "Plex")
        #expect(ProviderKind.local.label == "Local Files")
        #expect(ProviderKind.youtubeMusic.label == "YouTube Music")
    }
}
