import SwiftUI
import StarCore
import logging

@MainActor @Observable
public final class OutlierWindowViewModel {

    public var isSidePanelShowing = false
    public var houghLineFinderArgs: HoughLineFinder.Args?

    public var lineInfo: [HoughLineFinder.LineInfo] = []

    public var selectedLines = Set<HoughLineFinder.LineInfo.ID>()

    public func didSelect(ids: Set<HoughLineFinder.LineInfo.ID>) {
        if ids.count == 1,
           selectedOutliers.count == 1
        {
            for value in ids {
                if let lineInfo = lineInfo.first(where: { $0.id == value }) {
                    Log.d("selected line \(lineInfo.line)")
                    Task {
                        await selectedOutliers[0].set(line: lineInfo)
                    }
                }
            }
        }
    }
    
    public func loadLineInfo() async {
        if selectedOutliers.count == 1 {
            let outlier = selectedOutliers[0]
            let finder = await outlier.lineFinder
            var data = finder.lineData
            data.sort { $0.intensityScore > $1.intensityScore }
            self.lineInfo = data
        }
    }
    
    /// Every optional column in the order of `gherkin/ui/vectors/outlierColumns.json`: the key the clients remember it by (the
    /// desktop's `outlierTableColumns` uses the same ones), the flag that shows it, and whether it shows until the user chooses.
    static let columns: [(key: String, flag: ReferenceWritableKeyPath<OutlierWindowViewModel, Bool>, isDefault: Bool)] = [
        ("name", \.showName, false),
        ("width", \.showWidth, true),
        ("height", \.showHeight, true),
        ("centerX", \.showCenterX, false),
        ("centerY", \.showCenterY, false),
        ("minX", \.showMinX, false),
        ("minY", \.showMinY, false),
        ("maxX", \.showMaxX, false),
        ("maxY", \.showMaxY, false),
        ("hypotenuse", \.showHypotenuse, true),
        ("aspectRatio", \.showAspectRatio, true),
        ("fillAmount", \.showFillAmount, true),
        ("surfaceAreaRatio", \.showSurfaceAreaRatio, true),
        ("averagebrightness", \.showAveragebrightness, true),
        ("medianBrightness", \.showMedianBrightness, true),
        ("maxBrightness", \.showMaxBrightness, true),
        ("numberOfNearbyOutliersInSameFrame", \.showNumberOfNearbyOutliersInSameFrame, true),
        ("maxHoughTransformCount", \.showMaxHoughTransformCount, true),
        ("pixelBorderAmount", \.showPixelBorderAmount, true),
        ("averageLineVariance", \.showAverageLineVariance, true),
        ("lineLength", \.showLineLength, true),
        ("nearbyDirectOverlapScore", \.showNearbyDirectOverlapScore, true),
        ("boundingBoxOverlapScore", \.showBoundingBoxOverlapScore, true),
        ("lineIntensityScore", \.showLineIntensityScore, true),
        ("linePixelScore", \.showLinePixelScore, true),
        ("borderBrightness", \.showBorderBrightness, true),
        ("bunchCount", \.showBunchCount, true),
        ("medianBunchSize", \.showMedianBunchSize, true),
        ("maxBunchSize", \.showMaxBunchSize, true),
        ("neighborLineThetaScore", \.showNeighborLineThetaScore, true),
        ("neighborLineRhoScore", \.showNeighborLineRhoScore, true),
        ("neighborLineSizeScore", \.showNeighborLineSizeScore, true),
        ("neighborLineBrightnessScore", \.showNeighborLineBrightnessScore, true),
        ("neighborLineDistanceScore", \.showNeighborLineDistanceScore, true),
        ("classificationScore", \.showClassificationScore, true),
    ]

    /// The keys that show for a saved choice: the vector's defaults when nothing was saved, and unknown keys ignored.
    static func shownKeys(saved: [String]?) -> Set<String> {
        guard let saved else { return Set(columns.filter { $0.isDefault }.map { $0.key }) }
        return Set(saved).intersection(columns.map { $0.key })
    }

    /// Where a change to the choice goes; the app's writes `outlierTableColumns` in `~/.star.userprefs.json`.
    @ObservationIgnored private let save: ([String]) -> Void
    @ObservationIgnored private var persistSuspended = false

    /// `savedColumns` is `outlierTableColumns` as it was read, and `save` is told the shown keys, in table order, after every change.
    /// The default reads and writes the app's preferences; the preferences are loaded before any view is made.
    init(savedColumns: [String]? = nil,
         save: (([String]) -> Void)? = nil)
    {
        self.save = save ?? { UserPreferencesStore.shared.preferences.outlierTableColumns = $0 }
        let saved = savedColumns ?? (save == nil ? UserPreferencesStore.shared.preferences.outlierTableColumns : nil)
        let shown = Self.shownKeys(saved: saved)
        persistSuspended = true
        for column in Self.columns { self[keyPath: column.flag] = shown.contains(column.key) }
        persistSuspended = false
        Task { houghLineFinderArgs = await constants.getHoughLineFinderArgs() }
    }

    /// The shown columns' keys, in table order.
    var shownColumnKeys: [String] {
        Self.columns.filter { self[keyPath: $0.flag] }.map { $0.key }
    }

    private func persist() {
        guard !persistSuspended else { return }
        save(shownColumnKeys)
    }

    public var selectedOutliers: [OutlierGroup] = []

    public var showName = false { didSet { persist() } }
    public var showCenterX = false { didSet { persist() } }
    public var showCenterY = false { didSet { persist() } }
    public var showWidth = true { didSet { persist() } }
    public var showHeight = true { didSet { persist() } }
    public var showMinX = false { didSet { persist() } }
    public var showMinY = false { didSet { persist() } }
    public var showMaxX = false { didSet { persist() } }
    public var showMaxY = false { didSet { persist() } }
    public var showHypotenuse = true { didSet { persist() } }
    public var showAspectRatio = true { didSet { persist() } }
    public var showFillAmount = true { didSet { persist() } }
    public var showSurfaceAreaRatio = true { didSet { persist() } }
    public var showAveragebrightness = true { didSet { persist() } }
    public var showMedianBrightness = true { didSet { persist() } }
    public var showMaxBrightness = true { didSet { persist() } }
    public var showNumberOfNearbyOutliersInSameFrame = true { didSet { persist() } }
    public var showMaxHoughTransformCount = true { didSet { persist() } }
    public var showPixelBorderAmount = true { didSet { persist() } }
    public var showAverageLineVariance = true { didSet { persist() } }
    public var showLineLength = true { didSet { persist() } }
    public var showNearbyDirectOverlapScore = true { didSet { persist() } }
    public var showBoundingBoxOverlapScore = true { didSet { persist() } }
    public var showLineIntensityScore = true { didSet { persist() } }
    public var showLinePixelScore = true { didSet { persist() } }
    public var showBorderBrightness = true { didSet { persist() } }
    public var showBunchCount = true { didSet { persist() } }
    public var showMedianBunchSize = true { didSet { persist() } }
    public var showMaxBunchSize = true { didSet { persist() } }
    public var showNeighborLineThetaScore = true { didSet { persist() } }
    public var showNeighborLineRhoScore = true { didSet { persist() } }
    public var showNeighborLineSizeScore = true { didSet { persist() } }
    public var showNeighborLineBrightnessScore = true { didSet { persist() } }
    public var showNeighborLineDistanceScore = true { didSet { persist() } }
    public var showClassificationScore = true { didSet { persist() } }
    
    public func selectAll() {
        setAll(to: true)
    }

    public func clearAll() {
        setAll(to: false)
    }

    /// Every flag at once, saved once.
    public func setAll(to value: Bool) {
        persistSuspended = true
        for column in Self.columns { self[keyPath: column.flag] = value }
        persistSuspended = false
        persist()
    }
}
