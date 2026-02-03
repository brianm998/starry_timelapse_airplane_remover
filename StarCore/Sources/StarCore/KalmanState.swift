import Foundation

struct KalmanState {
    var x: [Double]    // position (8)
    var v: [Double]    // velocity (8)
    var P: [[Double]]  // covariance (16x16)
}
