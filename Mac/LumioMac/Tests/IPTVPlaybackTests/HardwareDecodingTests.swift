import Testing
@testable import IPTVPlayback

@Suite("Hardware decoding")
struct HardwareDecodingTests {
    @Test func aLongWaitEndingInSoftwareIsAHang() {
        #expect(HardwareDecoding.hung(codec: "h264", decoder: "no", secondsToFirstFrame: 15))
        #expect(HardwareDecoding.hung(codec: "hevc", decoder: "no", secondsToFirstFrame: 5))
    }

    @Test func aSlowServerOrAnOddFormatIsnt() {
        // Slow to start but on VideoToolbox: the server was slow, not the decoder.
        #expect(!HardwareDecoding.hung(codec: "h264", decoder: "videotoolbox", secondsToFirstFrame: 12))
        // Quick fallback (VideoToolbox refused at once): nothing to avoid.
        #expect(!HardwareDecoding.hung(codec: "h264", decoder: "no", secondsToFirstFrame: 1))
        // Formats VideoToolbox doesn't decode are always software.
        #expect(!HardwareDecoding.hung(codec: "mpeg2video", decoder: "no", secondsToFirstFrame: 15))
        #expect(!HardwareDecoding.hung(codec: nil, decoder: "no", secondsToFirstFrame: 15))
    }
}
