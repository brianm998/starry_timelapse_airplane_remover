// KHTBridge.cpp — Pure C++ implementation of Kernel Hough Transform bridge
#include "KHTBridge.h"
#include "MatWrapperImpl.hpp"
#include "logging_impl.hpp"

#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include "../kht/include/kht.hpp"

#include <cmath>
#include <cstdlib>

int kht_translate(MatWrapperRef image, KHTLine **outLines) {
    if (!image || !outLines) return 0;
    try {
        kht::ListOfLines lineList;
        cv::Mat im = image->mat.clone();
        int32_t height = im.rows, width = im.cols;

        cv::Mat eightBit, canny;
        im.convertTo(eightBit, CV_8U);
        cv::Canny(eightBit, canny, 80, 200, 3, true);
        kht::run_kht(lineList, canny.ptr(), width, height);

        int count = (int)lineList.size();
        if (count == 0) {
            *outLines = nullptr;
            return 0;
        }

        auto *lines = (KHTLine *)malloc(sizeof(KHTLine) * count);
        for (int i = 0; i < count; i++) {
            kht::Line line = lineList[i];
            double rho = line.rho;
            double theta = line.theta;
            if (rho < 0) {
                rho = -rho;
                theta = fmod(theta + 180, 360);
            }
            lines[i].theta = theta;
            lines[i].rho = rho;
            lines[i].votes = line.votes;
        }

        *outLines = lines;
        return count;
    } KHT_CATCH_LOG("kht_translate")
    return 0;
}

void kht_free_lines(KHTLine *lines) {
    free(lines);
}
