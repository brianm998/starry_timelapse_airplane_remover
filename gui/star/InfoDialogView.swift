import SwiftUI

import StarCore
struct InfoDialogView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    
    var body: some View {
        @Bindable var viewModel = viewModel
        return ZStack {
            Rectangle()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(.gray)
              .opacity(0.5)


            VStack {
                Spacer()
                  .frame(maxHeight: 200)
                HStack {
                    Spacer()
                      .frame(maxWidth: 200)
                    VStack(spacing: 0) {
                        InfoBanner()
                        VStack {
                        Text(localized("ui.information_about_star"))
                          .font(.largeTitle)
                          .foregroundColor(.white)
                        
                        HStack(alignment: .top) {
                            VerticalStarPicker("",
                                               selection: $viewModel.currentInfoType) { value, _, _ in
                                Text(value.shortName).tag(value)
                                  .font(.title)
                                //.foregroundColor(.white)
                            }
                              .font(.title)

                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    if viewModel.currentInfoType == .about {
                                        ArtImage(.wordmark)
                                        HStack(spacing: 8) {
                                            ArtImage(.realBefore)
                                            Image(systemName: "arrow.right").foregroundColor(.secondary)
                                            ArtImage(.realAfter)
                                        }
                                    }
                                    if viewModel.currentInfoType == .howTo {
                                        WorkflowStrip()
                                        ForEach(Array(InfoType.howToSteps.enumerated()), id: \.offset) { _, step in
                                            HowToStepRow(step: step)
                                        }
                                    }
                                    if viewModel.currentInfoType == .about {
                                        ForEach(Array(InfoType.aboutKeys.enumerated()), id: \.offset) { _, key in
                                            Text(localized(key))
                                              .font(.title)
                                              .foregroundColor(.white)
                                            if key == InfoType.aboutLicenseKey {
                                                Link(STAR_SOURCE_URL, destination: URL(string: STAR_SOURCE_URL)!)
                                                  .font(.title)
                                            }
                                        }
                                    } else if viewModel.currentInfoType == .detailed {
                                        Text(InfoType.detailedOpening)
                                          .font(.title)
                                          .foregroundColor(.white)
                                        ForEach(Array(InfoType.detailedSections.enumerated()), id: \.offset) { _, section in
                                            Text(section.heading)
                                              .font(.headline)
                                              .foregroundColor(.white)
                                            Text(section.body)
                                              .font(.title)
                                              .foregroundColor(.white)
                                            ArtImage(section.art)
                                        }
                                        ForEach(Array(InfoType.detailedClosing.enumerated()), id: \.offset) { _, paragraph in
                                            Text(paragraph)
                                              .font(.title)
                                              .foregroundColor(.white)
                                        }
                                    } else if viewModel.currentInfoType != .howTo {
                                        Text(viewModel.currentInfoType.infoText)
                                          .font(.title)
                                          .foregroundColor(.white)
                                    }
                                }
                            }
                        }

                        Button() {
                            viewModel.showInfoDialog = false
                        } label: {
                            Text(localized("ui.close"))
                              .buttonStyle(ShrinkingButton())
                        }
                          }
                          .padding(20)
                    }
                      .background(Color.starDialogBackground)
                      .clipShape(RoundedRectangle(cornerRadius: 20))

                    Spacer()
                      .frame(maxWidth: 200)
                }
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer()
                  .frame(maxHeight: 200)
            }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Where the source code lives (the repository is public).
let STAR_SOURCE_URL = "https://github.com/brianm998/starry_timelapse_airplane_remover"

/// One section of the Detailed tab: the catalogue keys of its heading and body, and the stage picture that follows them.
struct DetailedSection {
    let titleKey: String
    let bodyKey: String
    let art: StarArt

    var heading: String { localized(titleKey) }
    var body: String { localized(bodyKey) }

    /// The section's words as one string, heading first.
    var text: String { heading + "\n" + body }
}

public enum InfoType: CaseIterable {
    case about
    case howTo
    case detailed

    /// The About tab's paragraphs, in order; the source link goes after `aboutLicenseKey`.
    static let aboutKeys = [
        "ui.info_about_name",
        "ui.info_about_purpose",
        "ui.info_about_license",
        "ui.info_about_what_it_does",
        "ui.info_about_video_formats",
        "ui.info_about_image_formats",
    ]
    static let aboutLicenseKey = "ui.info_about_license"

    /// The How To tab's five steps, in order.
    static let howToSteps: [HowToStep] = [
        HowToStep(art: .howtoImport, titleKey: "ui.info_how_to_import_title", bodyKey: "ui.info_how_to_import_body",
                  placeholderKeys: ["ui.load_video", "ui.load_image_sequence"]),
        HowToStep(art: .howtoQuestions, titleKey: "ui.info_how_to_questions_title", bodyKey: "ui.info_how_to_questions_body",
                  placeholderKeys: ["ui.processing_settings"]),
        HowToStep(art: .howtoProcess, titleKey: "ui.info_how_to_process_title", bodyKey: "ui.info_how_to_process_body",
                  placeholderKeys: ["ui.start_processing"]),
        HowToStep(art: .review, titleKey: "ui.info_how_to_review_title", bodyKey: "ui.info_how_to_review_body",
                  placeholderKeys: []),
        HowToStep(art: .rendering, titleKey: "ui.info_how_to_render_title", bodyKey: "ui.info_how_to_render_body",
                  placeholderKeys: ["ui.render_video", "ui.load_config"]),
    ]

    var shortName: String {
        switch self {
        case .about:
            return localized("ui.about")
        case .howTo:
            return localized("ui.how_to")
        case .detailed:
            return localized("ui.detailed")
        }
    }

    /// The catalogue key of the Detailed tab's opening line, before the first section.
    static let detailedOpeningKey = "ui.info_detailed_intro"

    /// The Detailed tab's ten sections, in order; each is drawn as its heading, its body and its stage picture.
    static let detailedSections: [DetailedSection] = [
        DetailedSection(titleKey: "ui.info_detailed_horizon_title", bodyKey: "ui.info_detailed_horizon_body", art: .stageHorizon),
        DetailedSection(titleKey: "ui.info_detailed_neighbors_title", bodyKey: "ui.info_detailed_neighbors_body", art: .stageNeighbors),
        DetailedSection(titleKey: "ui.info_detailed_aligned_title", bodyKey: "ui.info_detailed_aligned_body", art: .stageAligned),
        DetailedSection(titleKey: "ui.info_detailed_condensed_title", bodyKey: "ui.info_detailed_condensed_body", art: .stageCondensed),
        DetailedSection(titleKey: "ui.info_detailed_subtraction_title", bodyKey: "ui.info_detailed_subtraction_body", art: .stageSubtraction),
        DetailedSection(titleKey: "ui.info_detailed_blobs_title", bodyKey: "ui.info_detailed_blobs_body", art: .stageBlobs),
        DetailedSection(titleKey: "ui.info_detailed_blob_processing_title", bodyKey: "ui.info_detailed_blob_processing_body", art: .stageBlobProcessing),
        DetailedSection(titleKey: "ui.info_detailed_classification_title", bodyKey: "ui.info_detailed_classification_body", art: .stageClassification),
        DetailedSection(titleKey: "ui.info_detailed_removal_mask_title", bodyKey: "ui.info_detailed_removal_mask_body", art: .stageRemovalMask),
        DetailedSection(titleKey: "ui.info_detailed_final_title", bodyKey: "ui.info_detailed_final_body", art: .stageFinal),
    ]

    /// The catalogue key of the paragraphs after the last section, joined by a blank line.
    static let detailedClosingKey = "ui.info_detailed_closing"

    /// The Detailed tab's opening line.
    static var detailedOpening: String { localized(detailedOpeningKey) }

    /// The paragraphs after the last section.
    static var detailedClosing: [String] {
        localized(detailedClosingKey).components(separatedBy: "\n\n")
    }

    /// The Detailed tab as one string: the opening, the sections and the closing.
    static var detailedText: String {
        ([detailedOpening] + detailedSections.map { $0.text } + detailedClosing).joined(separator: "\n\n")
    }

    var infoText: String {
        switch self {
        case .about:
            return InfoType.aboutKeys.map { localized($0) }.joined(separator: "\n\n")
        case .howTo:
            return InfoType.howToSteps.map { "\($0.heading)\n\($0.body)" }.joined(separator: "\n\n")
        case .detailed:
            return InfoType.detailedText
        }
    }
}

/// One step of the How To tab: its robot, its heading and paragraph keys, and the keys of the button
/// labels that fill the paragraph's `{0}`, `{1}`.
struct HowToStep {
    let art: StarArt
    let titleKey: String
    let bodyKey: String
    let placeholderKeys: [String]

    var heading: String { localized(titleKey) }
    var body: String { StarLocalization.shared.string(forKey: bodyKey, placeholderKeys.map { localized($0) }) }
}

struct HowToStepRow: View {
    let step: HowToStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtImage(step.art)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.heading)
                  .font(.title)
                  .bold()
                  .foregroundColor(.white)
                Text(step.body)
                  .font(.title3)
                  .foregroundColor(.white)
            }
        }
    }
}

extension Color {
    /// The ground every dialog is drawn on. Equal to the desktop client's `StarColors.prefsCard`
    /// (`Color(0.12f, 0.12f, 0.12f)`, #1F1F1F) in star-desktop/.../ui/theme/StarColors.kt.
    static let starDialogBackground = Color(.sRGB, white: 0.12, opacity: 1)
}

extension View {
    /// Draws a sheet, popover or card in the star dialog style: the grey dialog ground, white
    /// text by default, and the dark appearance so controls are drawn for a dark ground.
    ///
    /// A sheet otherwise takes the system's light window background, and everything in it is
    /// white text. `.environment(\.colorScheme, .dark)` is used rather than
    /// `.preferredColorScheme`, which would propagate up to the presenting window.
    func starDialogStyle() -> some View {
        self
          .background(Color.starDialogBackground)
          .foregroundColor(.white)
          .environment(\.colorScheme, .dark)
    }
}

/// art_robot_and_dog cropped to the band that keeps the robot and dog whole, at the dialog's width.
struct InfoBanner: View {
    var body: some View {
        let art = StarArt.robotAndDog
        let top = WelcomeArt.bannerTop * art.size.height
        Image(art.rawValue)
          .resizable()
          .interpolation(.high)
          .frame(width: art.size.width, height: art.size.height)
          .offset(y: -top)
          .frame(width: WelcomeArt.bannerWidth, height: WelcomeArt.bannerHeight, alignment: .top)
          .clipped()
          .accessibilityHidden(true)
    }
}

/// The six steps of the workflow, in order, as the How To tab's strip shows them.
let workflowStripSteps: [StarArt] = [.stepImport, .stepHorizon, .stepAlign, .stepMerge, .stepReview, .stepRender]

/// A row of the six step tiles joined by arrows drawn in code. Art only: it adds no strings.
struct WorkflowStrip: View {
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(workflowStripSteps.enumerated()), id: \.offset) { index, step in
                if index > 0 {
                    Image(systemName: "arrow.right")
                      .foregroundColor(.secondary)
                      .frame(width: 16)
                      .accessibilityHidden(true)
                }
                ArtImage(step)
            }
        }
    }
}
