import Foundation
import logging

public struct ToolPaths {

    private static var binaryDirURL: URL {
        guard let execURL = Bundle.main.executableURL else {
            fatalError("❌ Couldn’t find main executable URL")
        }

        return execURL.deletingLastPathComponent()
    }
    
    public static var ffmpeg: String {
        ToolPaths.binaryDirURL
          .appendingPathComponent("ffmpeg")
          .path
    }
    
    public static var ffprobe: String {
        ToolPaths.binaryDirURL
          .appendingPathComponent("ffprobe")
          .path
    }
}

