import Foundation
import RemovalCore
import StarCore

/// `--temp`: says why Star left a failing object in, from the outlier data of a run made with `-w --keep-temp-files`.
/// The three answers the removal check can't give itself:
///   * not detected:   no outlier group touches the trail (Star never saw it, or filed it as dust)
///   * misclassified:  groups touch it and every one was decided keep (the classifier's score is listed)
///   * not removed although decided remove: the groups were decided remove, so the trail should have been painted over
/// It reads StarCore's own loaders, so it sees what Star saw. Diagnosis only: it never changes pass or fail.
enum TrailDiagnostics {
    /// A group counts as touching the trail when this many of its pixels lie within the trail's footprint.
    static let minOverlap = 5

    static func annotate(_ report: inout Report, frameNames: [String], labels: LabelSet, temp: String) async throws {
        let cfg = try Config.read(fromJsonFilename: (temp as NSString).appendingPathComponent("config.json"))
        let outliers = (temp as NSString).appendingPathComponent("outliers")
        // automatic:false never builds outlier groups, so a run with that method has none to read: say so, don't fail
        guard FileManager.default.fileExists(atPath: outliers) else {
            for i in report.objects.indices where report.objects[i].status == "fail" {
                report.objects[i].diagnosis = "no outlier data in \(temp) (this clean method keeps none, or star was not run with --keep-temp-files)"
            }
            return
        }
        var cache: [Int: OutlierGroups] = [:]
        for i in report.objects.indices where report.objects[i].status == "fail" {
            let o = report.objects[i]
            guard let idx = frameNames.firstIndex(where: { LabelSet.baseName($0) == LabelSet.baseName(o.frame) }),
                  let label = labels.frames[o.frame]?.first(where: { $0.id == o.id }) else { continue }
            let groups: OutlierGroups
            if let g = cache[idx] { groups = g } else {
                let dir = (outliers as NSString).appendingPathComponent(String(idx))
                guard FileManager.default.fileExists(atPath: dir) else {
                    report.objects[i].diagnosis = "no outlier data for frame \(idx) in \(temp): not diagnosed"
                    continue
                }
                groups = try await OutlierGroups(at: idx, fromOutlierDir: dir, config: cfg)
                cache[idx] = groups
            }
            let reach = label.width / 2 + 10
            let poly = label.polyline
            var touching: [GroupTouch] = []
            for (isTrash, set) in [(false, await groups.getMembers()), (true, await groups.getTrash())] {
                for (id, group) in set {
                    let n = await overlap(group, poly: poly, reach: reach)
                    guard n >= minOverlap else { continue }
                    let reason = await group.shouldRemove()
                    touching.append(GroupTouch(id: id, pixels: n, decision: describe(reason), willRemove: reason?.willRemove, trash: isTrash))
                }
            }
            report.objects[i].diagnosis = Diagnosis.classify(touching, totalGroups: await groups.getMembers().count)
        }
    }

    /// Pixels of the group within `reach` of the polyline.
    static func overlap(_ group: OutlierGroup, poly: [Point], reach: Double) async -> Int {
        let b = group.bounds, w = b.width, pixels = group.pixels
        var n = 0
        for (i, v) in pixels.enumerated() where v != 0 {
            let p = Point(x: Double(b.min.x + i % w), y: Double(b.min.y + i / w))
            if Geometry.distance(from: p, toPolyline: poly) <= reach { n += 1 }
        }
        return n
    }

    static func describe(_ r: RemoveReason?) -> String {
        switch r {
        case .none: return "no decision"
        case .some(.userSelected(let v)): return "user \(v ? "remove" : "keep")"
        case .some(.fromClassifier(let s)): return String(format: "classifier %+.2f", s)
        }
    }
}
