import Foundation
import Testing
@testable import Spectra

/// `Storage.safe` guards every file name Spectra writes on disk or on a NAS
/// share (SMB-rejected characters, path separators, leading dots, length).
struct StorageSanitizationTests {

    @Test func stripsPathSeparators() {
        #expect(Storage.safe("AC/DC", fallback: "x") == "AC_DC")
    }

    @Test func stripsSMBRejectedCharacters() {
        #expect(Storage.safe("a:b*c?d\"e<f>g|h\\i", fallback: "x") == "a_b_c_d_e_f_g_h_i")
    }

    @Test func trimsWhitespace() {
        #expect(Storage.safe("  padded  ", fallback: "x") == "padded")
    }

    @Test func removesLeadingDots() {
        #expect(Storage.safe(".hidden", fallback: "x") == "hidden")
        #expect(Storage.safe("..dots", fallback: "x") == "dots")
    }

    @Test func fallsBackOnEmptyOrNil() {
        #expect(Storage.safe("", fallback: "fallback") == "fallback")
        #expect(Storage.safe("///", fallback: "fallback") == "fallback")
        #expect(Storage.safe(nil, fallback: "fallback") == "fallback")
    }

    @Test func boundsLengthTo120() {
        let long = String(repeating: "a", count: 130)
        #expect(Storage.safe(long, fallback: "x")?.count == 120)
    }
}
