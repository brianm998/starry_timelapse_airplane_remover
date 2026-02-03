import Foundation

public final class HomographyKalman {
    let dim = 8

    // Tunables (start conservative)
    let processNoisePos = 1e-4  // smoothness (lower = stiffer)
    let processNoiseVel = 1e-6  // how fast camera can accelerate
    let measurementNoise = 1e-2 // trust in star matches

    func initialState(from h: [Double]) -> KalmanState {
        let x = h
        let v = Array(repeating: 0.0, count: dim)

        let P = identity(2 * dim, scale: 1e-1)
        return KalmanState(x: x, v: v, P: P)
    }

    func predict(_ s: KalmanState) -> KalmanState {
        var x = s.x
        var v = s.v

        // x = x + v
        for i in 0..<dim { x[i] += v[i] }

        var P = s.P
        addProcessNoise(&P)

        return KalmanState(x: x, v: v, P: P)
    }

    func update(_ s: KalmanState, measurement z: [Double], weight: Double) -> KalmanState {
        // Simple diagonal H, R (practical + stable)
        var x = s.x
        let v = s.v

        let R = measurementNoise / weight

        for i in 0..<dim {
            let K = s.P[i][i] / (s.P[i][i] + R)
            x[i] += K * (z[i] - x[i])
        }

        return KalmanState(x: x, v: v, P: s.P)
    }

    private func addProcessNoise(_ P: inout [[Double]]) {
        for i in 0..<dim {
            P[i][i] += processNoisePos
            P[i+dim][i+dim] += processNoiseVel
        }
    }
}

func rtsSmooth(_ states: [KalmanState]) -> [KalmanState] {
    guard states.count > 1 else { return states }

    var smoothed = states
    for i in stride(from: states.count - 2, through: 0, by: -1) {
        for j in 0..<8 {
            let delta = smoothed[i+1].x[j] - states[i].x[j]
            smoothed[i].x[j] += 0.5 * delta
        }
    }
    return smoothed
}

@inline(__always)
func identity(_ size: Int, scale: Double = 1.0) -> [[Double]] {
    precondition(size > 0)
    var m = Array(
        repeating: Array(repeating: 0.0, count: size),
        count: size
    )
    for i in 0..<size {
        m[i][i] = scale
    }
    return m
}
