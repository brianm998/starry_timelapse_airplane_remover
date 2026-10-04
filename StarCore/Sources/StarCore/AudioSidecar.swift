import Foundation
import logging

/// The sound of an imported video, kept beside its frames so that a render can put it back.
///
/// `decodeVideo` takes a video apart into frames and a sound file, and rendering joins them again.
/// Two things used to go wrong, both over audio that was not AAC (PCM, which is what editors and
/// many cameras write, AC-3, FLAC, Opus, ...):
///
///  1. The file was always `audio.aac`, written with `-acodec copy`, and an `.aac` file holds
///     nothing but AAC.  ffmpeg refused, `decodeVideo` threw, and the whole import failed over
///     the sound track.
///  2. Whatever the file held was then copied into the render, which only works in a container
///     that accepts that codec.  WebM takes Opus and Vorbis only (so AAC failed there), QuickTime
///     refuses FLAC and Opus, and ffmpeg will write PCM into an MP4 that almost nothing can play.
///
/// So now:
///
///  - the sound is kept in its own codec, untouched, wherever that is possible: AAC as
///    `audio.aac`, as before, and anything else in `audio.mka`, a Matroska audio file, which takes
///    every codec.  If even that fails it is re-encoded to AAC, and if that fails too the import
///    carries on without sound: the frames are what the import is for.
///  - a render asks ffmpeg what its output container accepts and takes the first of: the sound as
///    it is, AAC, Opus (which is what WebM wants), or no sound.  A render never fails over its audio.
public enum AudioSidecar {

    /// AAC as it came (ADTS, which is all a `.aac` file can hold), and where audio is re-encoded
    /// to when its own codec cannot be kept.
    public static let aacFilename = "audio.aac"

    /// Any other codec, copied untouched into a Matroska audio file.
    public static let losslessFilename = "audio.mka"

    // MARK: - ffmpeg, as closures so tests need none

    /// What this file needs from ffmpeg and ffprobe.
    struct Tools: Sendable {
        /// The codec of the first audio stream in a file (`aac`, `pcm_s16le`, ...), or nil if it has
        /// none or ffprobe could not say.
        var audioCodec: @Sendable (_ path: String) -> String?

        /// Runs ffmpeg with these arguments; true if it succeeded.
        var ffmpeg: @Sendable (_ arguments: [String]) -> Bool

        static let bundled = Tools(
          audioCodec: { path in
              let output = try? shellOut(to: ToolPaths.ffprobe, arguments: [
                  "-v", "error", "-select_streams", "a:0",
                  "-show_entries", "stream=codec_name",
                  "-of", "default=noprint_wrappers=1:nokey=1",
                  path,
              ])
              let name = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
              return name.isEmpty ? nil : name
          },
          ffmpeg: { arguments in
              var all = ["-hide_banner", "-nostdin", "-loglevel", "error"]
              all += arguments
              do {
                  _ = try shellOut(to: ToolPaths.ffmpeg, arguments: all)
                  return true
              } catch {
                  Log.d("ffmpeg \(arguments.joined(separator: " ")) failed: \(error)")
                  return false
              }
          })
    }

    // MARK: - finding it

    /// The sound file `decodeVideo` left in a decoded folder, or nil if there is none.  An empty file
    /// is not one: a failed run of ffmpeg leaves those.
    public static func path(in directory: String) -> String? {
        for name in [losslessFilename, aacFilename] {
            let path = "\(directory)/\(name)"
            if isUsable(path) { return path }
        }
        return nil
    }

    private static func isUsable(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey])
        return (values?.fileSize ?? 0) > 0
    }

    // MARK: - importing

    /// Keeps the first audio stream of `input` in `directory`, and returns the name of the file, or
    /// nil if it could not be kept.  Never throws: see the type's comment.
    static func extract(from input: String, into directory: String, tools: Tools = .bundled) -> String? {
        let fileManager = FileManager.default

        // A sound file left by an earlier import of something else into this folder must not be
        // mistaken for this one's.
        for name in [losslessFilename, aacFilename] {
            try? fileManager.removeItem(atPath: "\(directory)/\(name)")
        }

        let codec = tools.audioCodec(input)

        // In order of preference: untouched, then re-encoded.
        var attempts: [(file: String, codecArguments: [String], what: String)] = []
        if codec == "aac" {
            attempts.append((aacFilename, ["-c:a", "copy"], "AAC as it is"))
        }
        attempts.append((losslessFilename, ["-c:a", "copy"], "\(codec ?? "its own codec") as it is, in Matroska"))
        attempts.append((aacFilename, ["-c:a", "aac", "-b:a", "320k"], "re-encoded to AAC"))

        for attempt in attempts {
            let path = "\(directory)/\(attempt.file)"
            var arguments = ["-y", "-i", input, "-map", "0:a:0", "-vn"]
            arguments += attempt.codecArguments
            arguments.append(path)

            if tools.ffmpeg(arguments), isUsable(path) {
                Log.i("kept the audio of \(input) as \(attempt.file): \(attempt.what)")
                return attempt.file
            }
            // a run that failed leaves an empty or half-written file
            try? fileManager.removeItem(atPath: path)
        }

        Log.w("could not keep the audio of \(input); importing it without sound")
        return nil
    }

    // MARK: - rendering

    /// How to put the sound in `directory` into a render, for the output ffmpeg will be given:
    /// `formatArguments` is its `-f <muxer>` if it will be told one, and `outputExtension` is the
    /// output file's extension if the muxer is to be chosen by that instead.
    public static func plan(in directory: String,
                            formatArguments: [String],
                            outputExtension: String) -> AudioPlan
    {
        plan(in: directory, formatArguments: formatArguments, outputExtension: outputExtension, tools: .bundled)
    }

    static func plan(in directory: String,
                     formatArguments: [String],
                     outputExtension: String,
                     tools: Tools) -> AudioPlan
    {
        guard let sidecar = path(in: directory) else {
            return .none("there is no sound file beside the frames")
        }
        let codec = tools.audioCodec(sidecar)
        let container = Container(formatArguments: formatArguments, outputExtension: outputExtension)

        // In order of preference.  AAC and Opus are skipped when the sound already is that, as
        // re-encoding it would be pointless and, if the copy was refused, so would be the result.
        var candidates: [(codecArguments: [String], what: String)] = []
        if container.playsCopied(codec) {
            candidates.append((["-c:a", "copy"], "the original \(codec ?? "audio"), copied as it is"))
        }
        if codec != "aac" {
            candidates.append((["-c:a", "aac", "-b:a", "320k"], "re-encoded to AAC"))
        }
        if codec != "opus" {
            // the encoder ffmpeg has built in, which it still calls experimental
            candidates.append((["-c:a", "opus", "-strict", "-2", "-b:a", "192k"], "re-encoded to Opus"))
        }

        for candidate in candidates {
            if accepts(candidate.codecArguments, sidecar: sidecar,
                       formatArguments: formatArguments, outputExtension: outputExtension, tools: tools)
            {
                let plan = AudioPlan(inputArguments: ["-i", sidecar],
                                     codecArguments: candidate.codecArguments,
                                     summary: candidate.what)
                Log.i("audio for the render: \(plan.summary)")
                return plan
            }
        }

        let plan = AudioPlan.none("this container takes neither \(codec ?? "the audio"), AAC nor Opus")
        Log.w("audio for the render: \(plan.summary); rendering without sound")
        return plan
    }

    /// Whether ffmpeg can write half a second of the sound with these options into the output it
    /// will be asked for.  A container that cannot hold a codec says so when it writes the header,
    /// before any frame is encoded, so this is quick and costs a render nothing.
    private static func accepts(_ codecArguments: [String],
                                sidecar: String,
                                formatArguments: [String],
                                outputExtension: String,
                                tools: Tools) -> Bool
    {
        let ext = outputExtension.isEmpty ? "tmp" : outputExtension
        let trial = FileManager.default.temporaryDirectory
          .appendingPathComponent("star-audio-trial-\(UUID().uuidString).\(ext)")
          .path
        defer { try? FileManager.default.removeItem(atPath: trial) }

        var arguments = ["-y", "-i", sidecar, "-map", "0:a:0", "-t", "0.5"]
        arguments += codecArguments
        arguments += formatArguments
        arguments.append(trial)
        return tools.ffmpeg(arguments)
    }

    // MARK: - containers

    /// The one family of containers where what ffmpeg will write is wider than what plays.
    enum Container: Equatable {
        case mp4Family
        case other

        private static let mp4Formats: Set<String> = ["mp4", "ipod", "psp", "3gp", "3g2", "f4v", "ismv"]
        private static let mp4Extensions: Set<String> = ["mp4", "m4v", "m4a", "3gp", "3g2", "f4v"]

        init(formatArguments: [String], outputExtension: String) {
            if let flag = formatArguments.firstIndex(of: "-f"), flag + 1 < formatArguments.count {
                self = Self.mp4Formats.contains(formatArguments[flag + 1]) ? .mp4Family : .other
            } else {
                self = Self.mp4Extensions.contains(outputExtension.lowercased()) ? .mp4Family : .other
            }
        }

        /// Whether copying `codec` into this container is a good idea, as opposed to merely
        /// possible.  ffmpeg writes PCM, FLAC, Opus and MP2 into an MP4, but QuickTime, browsers and
        /// phones mostly do not play the result, so there only what does play is copied.  Elsewhere
        /// ffmpeg's own answer is enough, and `nil`, a codec that could not be identified, gets
        /// the benefit of the doubt.
        func playsCopied(_ codec: String?) -> Bool {
            guard self == .mp4Family, let codec else { return true }
            return ["aac", "mp3", "ac3", "eac3", "alac"].contains(codec)
        }
    }
}

/// What a render does about the sound of the video it was made from.
public struct AudioPlan: Equatable, Sendable {
    /// The ffmpeg arguments that add the sound as an input (`-i <file>`), or nothing.
    public let inputArguments: [String]

    /// The ffmpeg output arguments for the sound stream (`-c:a copy`, ...), or nothing.
    public let codecArguments: [String]

    /// One line on what happens and why, for the log.
    public let summary: String

    /// False if the render goes without sound.
    public var hasAudio: Bool { !inputArguments.isEmpty }

    /// A render without sound, and why.
    public static func none(_ reason: String) -> AudioPlan {
        AudioPlan(inputArguments: [], codecArguments: [], summary: "no sound: \(reason)")
    }
}
