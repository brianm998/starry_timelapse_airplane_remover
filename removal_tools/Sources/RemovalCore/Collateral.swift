import Foundation

public struct ChangedComponent: Codable, Sendable {
    public var minX: Int, minY: Int, maxX: Int, maxY: Int
    public var area: Int
    public var peakDifference: Double
}

public enum Collateral {
    /// A mask of pixels within `width/2 + margin` of any object.
    public static func footprint(width: Int, height: Int, objects: [LabelObject], margin: Double) -> [Bool] {
        var mask = [Bool](repeating: false, count: width * height)
        for o in objects {
            let poly = o.polyline
            let reach = o.width / 2 + margin
            let b = Geometry.bounds(of: poly, margin: reach, width: width, height: height)
            if b.x1 < b.x0 || b.y1 < b.y0 { continue }
            for y in b.y0...b.y1 { for x in b.x0...b.x1 {
                if Geometry.distance(from: Point(x: Double(x), y: Double(y)), toPolyline: poly) <= reach {
                    mask[y * width + x] = true
                }
            } }
        }
        return mask
    }

    /// Connected components (8-neighbour) of pixels where any channel differs, outside `footprint`.
    public static func changedComponents(input: Raster, output: Raster, footprint: [Bool]) -> [ChangedComponent] {
        precondition(input.width == output.width && input.height == output.height && input.channels == output.channels)
        let w = input.width, h = input.height, c = input.channels
        var diff = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) where !footprint[i] {
            var m: Float = 0
            for k in 0..<c { m = max(m, abs(input.data[i * c + k] - output.data[i * c + k])) }
            diff[i] = m
        }
        var seen = [Bool](repeating: false, count: w * h)
        var comps: [ChangedComponent] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where diff[start] > 0 && !seen[start] {
            seen[start] = true
            stack.append(start)
            var comp = ChangedComponent(minX: w, minY: h, maxX: 0, maxY: 0, area: 0, peakDifference: 0)
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                comp.area += 1
                comp.minX = min(comp.minX, x); comp.maxX = max(comp.maxX, x)
                comp.minY = min(comp.minY, y); comp.maxY = max(comp.maxY, y)
                comp.peakDifference = max(comp.peakDifference, Double(diff[i]))
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                    let j = ny * w + nx
                    if diff[j] > 0 && !seen[j] { seen[j] = true; stack.append(j) }
                } }
            }
            comps.append(comp)
        }
        return comps.sorted { $0.area > $1.area }
    }

    /// Differential mode, outside the footprints: fraction of pixels with |output - base| > 6σ.
    public static func differentialOutside(output: Plane, base: Plane, footprint: [Bool]) -> (fraction: Double, sigma: Double) {
        let d = output.minus(base)
        let sigma = Stats.madSigma(d.data)
        var bad = 0, n = 0
        for i in 0..<d.data.count where !footprint[i] {
            n += 1
            if abs(d.data[i]) > 6 * sigma { bad += 1 }
        }
        return (n > 0 ? Double(bad) / Double(n) : 0, Double(sigma))
    }
}
