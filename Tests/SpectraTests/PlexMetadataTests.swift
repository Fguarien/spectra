import Foundation
import Testing
@testable import Spectra

/// The Plex-shaped interchange model: derived keys, codec resolution and
/// cross-account identity used by "All Libraries".
struct PlexMetadataTests {

    @Test func codecFallsBackFromContainerToAudioCodec() {
        let withContainer = PlexMetadata(ratingKey: "1", title: "t", type: "track",
                                         filePath: "/tmp/a.flac", fileContainer: "FLAC")
        #expect(withContainer.codec == "flac")
        #expect(withContainer.firstPartKey == "/tmp/a.flac")

        let audioOnly = PlexMetadata(ratingKey: "2", title: "t", type: "track",
                                     filePath: "/tmp/b.mp3", fileContainer: nil)
        #expect(audioOnly.codec == nil)   // no Media part carries a codec
    }

    @Test func libraryKeyIsTheMetadataPath() {
        let m = PlexMetadata(ratingKey: "123", title: "t", type: "track")
        #expect(m.libraryKey == "/library/metadata/123")
    }

    @Test func identityIsScopedByAccount() {
        let a = PlexMetadata(ratingKey: "7", title: "t", type: "track").tagged("plex")
        let b = PlexMetadata(ratingKey: "7", title: "t", type: "track").tagged("local")
        let c = PlexMetadata(ratingKey: "7", title: "t", type: "track").tagged("plex")
        #expect(a.id == "plex|7")
        #expect(a != b)
        #expect(a == c)
    }

    @Test func nativeCodecDetection() {
        #expect(AudioCapability.canPlayNatively("FLAC"))
        #expect(AudioCapability.canPlayNatively("mp3"))
        #expect(AudioCapability.canPlayNatively(nil))       // optimistic
        #expect(!AudioCapability.canPlayNatively("ape"))
        #expect(!AudioCapability.canPlayNatively("wma"))
    }
}
