import Foundation

public struct Point: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum Geometry {
    /// Distance from p to segment a–b.
    public static func distance(from p: Point, toSegment a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        var t = len2 == 0 ? 0 : ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = min(1, max(0, t))
        let cx = a.x + t * dx, cy = a.y + t * dy
        return ((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)).squareRoot()
    }

    public static func length(_ pts: [Point]) -> Double {
        var l = 0.0
        for i in 1..<max(1, pts.count) { l += hypot(pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y) }
        return l
    }

    /// The part of a polyline between arc lengths s0 and s1, as its own polyline.
    public static func subPolyline(_ pts: [Point], from s0: Double, to s1: Double) -> [Point] {
        var out: [Point] = []
        var acc = 0.0
        for i in 1..<max(1, pts.count) {
            let a = pts[i-1], b = pts[i]
            let seg = hypot(b.x - a.x, b.y - a.y)
            let segEnd = acc + seg
            if segEnd > s0 && acc < s1 && seg > 0 {
                let t0 = max(0, (s0 - acc) / seg), t1 = min(1, (s1 - acc) / seg)
                let p0 = Point(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0)
                let p1 = Point(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1)
                if out.isEmpty { out.append(p0) }
                out.append(p1)
            }
            acc = segEnd
        }
        return out
    }

    public static func distance(from p: Point, toPolyline pts: [Point]) -> Double {
        if pts.count == 1 { return hypot(p.x - pts[0].x, p.y - pts[0].y) }
        var best = Double.infinity
        for i in 1..<max(1, pts.count) {
            best = min(best, distance(from: p, toSegment: pts[i-1], pts[i]))
        }
        return best
    }

    /// Even-odd point-in-polygon.
    public static func contains(polygon: [Point], _ p: Point) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Integer pixel bounds of a polyline grown by `margin`, clamped to the image.
    public static func bounds(of pts: [Point], margin: Double, width: Int, height: Int)
        -> (x0: Int, y0: Int, x1: Int, y1: Int)
    {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let x0 = max(0, Int((xs.min() ?? 0) - margin)), x1 = min(width - 1, Int((xs.max() ?? 0) + margin) + 1)
        let y0 = max(0, Int((ys.min() ?? 0) - margin)), y1 = min(height - 1, Int((ys.max() ?? 0) + margin) + 1)
        return (x0, y0, x1, y1)
    }
}
