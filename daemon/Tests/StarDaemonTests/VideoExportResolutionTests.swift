import XCTest
import StarCore
import StarDaemonMessages
@testable import stard

/// `VideoExport` itself is tested in StarCore (`VideoExportTests`); this is the one piece that needs the daemon's own request handling.
final class VideoExportResolutionTests: XCTestCase {

    func testTheRequestedHeightSurvivesTheFallbackToTheOpenedVideosSettings() {
        var request = Star_V1_VideoEncodeSettings()   // no codec: the fallback path
        request.outputHeight = 720
        let opened = VideoInfo(frameRate: .fps_24, codec: .prores, encoder: .prores,
                               pixelFormat: .yuv444p10le, muxer: .mov, hasAudio: false)
        let config = Config(outputPath: "/o", imageSequenceName: "seq", imageSequencePath: "/s",
                            writeOutlierGroupFiles: false, writeFramePreviewFiles: false,
                            writeFrameProcessedPreviewFiles: false, writeFrameThumbnailFiles: false)
        let info = ExportHandlers.videoInfo(for: request, opened: opened, config: config)
        XCTAssertEqual(info.resolution, .p720)
    }
}
