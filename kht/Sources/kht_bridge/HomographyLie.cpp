// HomographyLie.cpp — Pure C++ Lie group operations using Eigen
#include "HomographyLie.h"
#include "logging_impl.hpp"

#include <Eigen/Dense>
#include <unsupported/Eigen/MatrixFunctions>
#include <cmath>

using namespace Eigen;

void homography_lie_log(const double *homography9, double *out8) {
    try {
        Matrix3d H;
        for (int r = 0; r < 3; ++r)
            for (int c = 0; c < 3; ++c)
                H(r, c) = homography9[r * 3 + c];

        if (std::abs(H(2,2)) > 1e-12) H /= H(2,2);

        Matrix3d L = H.log();

        out8[0] = L(0,0);
        out8[1] = L(0,1);
        out8[2] = L(0,2);
        out8[3] = L(1,0);
        out8[4] = L(1,1);
        out8[5] = L(1,2);
        out8[6] = L(2,0);
        out8[7] = L(2,1);
    } KHT_CATCH_LOG("homography_lie_log")
}

void homography_lie_exp(const double *vector8, double *out9) {
    try {
        Matrix3d L;
        L << vector8[0], vector8[1], vector8[2],
             vector8[3], vector8[4], vector8[5],
             vector8[6], vector8[7], 0.0;

        L(2,2) = -(L(0,0) + L(1,1));

        Matrix3d H = L.exp();

        if (std::abs(H(2,2)) > 1e-12) H /= H(2,2);

        for (int r = 0; r < 3; ++r)
            for (int c = 0; c < 3; ++c)
                out9[r * 3 + c] = H(r, c);
    } KHT_CATCH_LOG("homography_lie_exp")
}
