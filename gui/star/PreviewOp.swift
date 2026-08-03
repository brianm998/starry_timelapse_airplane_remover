import Foundation
import logging
import StarCore

final class PreviewOp: AsyncOperation, @unchecked Sendable {

    let frameView: FrameViewModel
    let imageAccessor: ImageAccessor
    let frameIndex: Int
    let type: FrameViewMode
    let size: ImageDisplaySize
    let errorClosure: (String) -> Void

    init(
      frameView: FrameViewModel,
      imageAccessor: ImageAccessor,
      frameIndex: Int,
      type: FrameViewMode,
      size: ImageDisplaySize,
      rawImageBytes: UInt64 = 0,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frameView = frameView
        self.imageAccessor = imageAccessor
        self.frameIndex = frameIndex
        self.type = type
        self.size = size
        self.errorClosure = errorClosure
        super.init(for: .preview, rawImageBytes: rawImageBytes)
    }

    override func asyncExecute() async {
        do {
            Log.d("frame \(frameIndex) starting")

            if imageAccessor.urlForImage(
                 frameIndex: frameIndex,
                 ofType: type,
                 atSize: .original
               ) != nil,
               imageAccessor.urlForImage(
                 frameIndex: frameIndex,
                 ofType: type,
                 atSize: size
               ) == nil
            {
                Log.d("frame \(frameIndex) making scaling original of type \(type) to size \(size)")
                // have original, missing smaller size
                try await imageAccessor.makeMissingImage(
                  frameIndex: frameIndex,
                  ofType: type,
                  andSize: size
                )
                Task { @MainActor in
                    frameView.reloadID = UUID()
                }
            }

            Log.d("frame \(frameIndex) done")
        } catch {
            let str = localized("ui.preview_creation_error", frameIndex, error)
            Log.e(str)
            errorClosure(str)
        }
    }
}
