#import "HomographyLie.h"

#import <Eigen/Dense>
#import <unsupported/Eigen/MatrixFunctions>

using namespace Eigen;

@implementation HomographyLie

#pragma mark - Helpers

static Matrix3d arrayToMatrix3d(NSArray<NSNumber *> *arr) {
    Matrix3d H;
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
            H(r, c) = arr[r * 3 + c].doubleValue;
        }
    }
    return H;
}

static NSArray<NSNumber *> *matrix3dToArray(const Matrix3d &M) {
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:9];
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) {
            [out addObject:@(M(r, c))];
        }
    }
    return out;
}

#pragma mark - Public API

+ (NSArray<NSNumber *> *)logHomography:(NSArray<NSNumber *> *)homography {
    NSAssert(homography.count == 9, @"Homography must have 9 elements");

    Matrix3d H = arrayToMatrix3d(homography);

    // Normalize so H(2,2) == 1
    if (std::abs(H(2,2)) > 1e-12) {
        H /= H(2,2);
    }

    // Matrix logarithm (maps into sl(3))
    Matrix3d L = H.log();

    // Pack into 8D vector (drop L(2,2))
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:8];

    out[0] = @(L(0,0));
    out[1] = @(L(0,1));
    out[2] = @(L(0,2));
    out[3] = @(L(1,0));
    out[4] = @(L(1,1));
    out[5] = @(L(1,2));
    out[6] = @(L(2,0));
    out[7] = @(L(2,1));

    return out;
}

+ (NSArray<NSNumber *> *)expHomography:(NSArray<NSNumber *> *)vector {
    NSAssert(vector.count == 8, @"Log homography must have 8 elements");

    Matrix3d L;
    L <<
        vector[0].doubleValue, vector[1].doubleValue, vector[2].doubleValue,
        vector[3].doubleValue, vector[4].doubleValue, vector[5].doubleValue,
        vector[6].doubleValue, vector[7].doubleValue, 0.0;

    // Enforce trace(L) == 0 (sl(3))
    L(2,2) = - (L(0,0) + L(1,1));

    // Matrix exponential
    Matrix3d H = L.exp();

    // Normalize back to H(2,2) == 1
    if (std::abs(H(2,2)) > 1e-12) {
        H /= H(2,2);
    }

    return matrix3dToArray(H);
}

@end
