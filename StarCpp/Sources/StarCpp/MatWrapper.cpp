// MatWrapper.cpp — Pure C++ implementation of MatWrapper C API
#include "MatWrapper.h"
#include "MatWrapperImpl.hpp"
#include "logging_impl.hpp"

#include <opencv2/opencv.hpp>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <string>
#include <algorithm>
#include <filesystem>
#include <system_error>
#include <fcntl.h>
#ifdef _WIN32
  // MSVC ships POSIX-flavoured file I/O in <io.h>, but uses underscore-prefixed
  // names (_open / _close / _commit) and has no fsync. Map the POSIX names we
  // use below onto the MSVC equivalents so the call sites stay portable.
  #include <io.h>
  static inline int fsync(int fd) { return _commit(fd); }
  #ifndef open
    #define open  _open
  #endif
  #ifndef close
    #define close _close
  #endif
#else
  #include <unistd.h>
#endif

// Static member definitions
std::atomic<uint64_t> MatWrapperImpl::totalBytes_{0};
std::atomic<uint64_t> MatWrapperImpl::totalInstances_{0};

static cv::Mat ensure8U(const cv::Mat& input) {
    if (input.depth() == CV_8U) return input;
    cv::Mat output;
    double minVal, maxVal;
    cv::minMaxLoc(input, &minVal, &maxVal);
    if (minVal == maxVal) {
        output = cv::Mat::zeros(input.size(), CV_MAKETYPE(CV_8U, input.channels()));
    } else {
        input.convertTo(output, CV_MAKETYPE(CV_8U, input.channels()),
                        255.0 / (maxVal - minVal),
                        -minVal * 255.0 / (maxVal - minVal));
    }
    return output;
}

// Helper: create a MatWrapperRef from a freshly produced cv::Mat that the caller is
// about to drop, sharing its buffer rather than copying it. Never pass a live
// wrapper's mat here — use MatWrapperImpl's deep constructor for that.
static MatWrapperRef wrap(const cv::Mat& mat) {
    return new MatWrapperImpl(MatWrapperImpl::Adopt{}, mat);
}

// --- Create / Destroy ---

MatWrapperRef mat_wrapper_load(const char *filename) {
    try {
        cv::Mat img = cv::imread(std::string(filename), cv::IMREAD_UNCHANGED);
        if (img.empty()) {
            Log_w("Failed to load image from filename %s", filename);
            return nullptr;
        }
        Log_d("Loaded from filename %s", filename);
        return wrap(img);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    } catch (...) {
        Log_e("Unknown exception loading %s", filename);
    }
    return nullptr;
}

MatWrapperRef mat_wrapper_clone(MatWrapperRef ref) {
    if (!ref) return nullptr;
    try {
        return new MatWrapperImpl(ref->mat);
    } KHT_CATCH_LOG("mat_wrapper_clone")
    return nullptr;
}

// Shares ref's buffer rather than copying it — see the contract in MatWrapper.h.
MatWrapperRef mat_wrapper_alias(MatWrapperRef ref) {
    if (!ref) return nullptr;
    try {
        return new MatWrapperImpl(MatWrapperImpl::Adopt{}, ref->mat);
    } KHT_CATCH_LOG("mat_wrapper_alias")
    return nullptr;
}

void mat_wrapper_release(MatWrapperRef ref) {
    delete ref;
}

MatWrapperRef mat_wrapper_create(int64_t width, int64_t height, int cvType,
                                 size_t bytesPerRow, void *data,
                                 bool takeOwnership) {
    try {
        if (takeOwnership) {
            cv::Mat mat((int)height, (int)width, cvType, data, bytesPerRow);
            return new MatWrapperImpl(mat); // clones
        } else {
            return new MatWrapperImpl((int)height, (int)width, cvType, data, bytesPerRow);
        }
    } KHT_CATCH_LOG("mat_wrapper_create")
    return nullptr;
}

// --- Properties ---

int64_t    mat_wrapper_rows(MatWrapperRef ref) { return ref ? ref->mat.rows : 0; }
int64_t    mat_wrapper_cols(MatWrapperRef ref) { return ref ? ref->mat.cols : 0; }
int64_t    mat_wrapper_channels(MatWrapperRef ref) { return ref ? ref->mat.channels() : 0; }
int        mat_wrapper_type(MatWrapperRef ref) { return ref ? ref->mat.type() : 0; }
size_t     mat_wrapper_step(MatWrapperRef ref) { return ref ? ref->mat.step : 0; }
size_t     mat_wrapper_data_length(MatWrapperRef ref) { return ref ? ref->mat.total() * ref->mat.elemSize() : 0; }
size_t     mat_wrapper_length_in_bytes(MatWrapperRef ref) { return mat_wrapper_data_length(ref); }
bool       mat_wrapper_is_empty(MatWrapperRef ref) { return !ref || ref->mat.empty(); }
const void *mat_wrapper_data_ptr(MatWrapperRef ref) { return ref ? ref->mat.data : nullptr; }

int64_t mat_wrapper_bits_per_pixel(MatWrapperRef ref) {
    return ref ? (int64_t)(ref->mat.elemSize() * 8) : 0;
}

int64_t mat_wrapper_bits_per_component(MatWrapperRef ref) {
    return ref ? (int64_t)(ref->mat.elemSize1() * 8) : 0;
}

bool mat_wrapper_owns_data(MatWrapperRef ref) {
    return ref && ref->mat.u != nullptr;
}

// --- Operations ---

bool mat_wrapper_write_to(MatWrapperRef ref, const char *filename) {
    if (!ref) return false;
    try {
        Log_d("writeTo: %s", filename);
        std::string fname(filename);

        // Extract extension for temp file
        std::string extension, base;
        size_t dotPos = fname.find_last_of('.');
        size_t slashPos = fname.find_last_of("/\\");
        if (dotPos != std::string::npos && (slashPos == std::string::npos || dotPos > slashPos)) {
            extension = fname.substr(dotPos + 1);
            base = fname.substr(0, dotPos);
        } else {
            base = fname;
        }

        std::string tmp = extension.empty() ? fname + ".tmp" : base + ".tmp." + extension;

        if (ref->mat.empty()) {
            Log_w("not writing empty mat to %s", filename);
            return false;
        }

        // imwrite returns false rather than throwing for some failures (an unsupported
        // extension, an encoder that could not be initialised), so the return value has to
        // be checked as well as the exception caught. A full disk usually throws, but not
        // always — and either way the caller has to be told.
        if (!cv::imwrite(tmp, ref->mat)) {
            Log_e("writeTo: imwrite failed for %s", filename);
            std::error_code ignored;
            std::filesystem::remove(tmp, ignored);
            return false;
        }

        int fd = open(tmp.c_str(), O_RDONLY);
        if (fd >= 0) { fsync(fd); close(fd); }

        // std::filesystem::rename replaces an existing destination atomically
        // on every platform we support (POSIX rename(2) does this natively;
        // the MS STL implements it via MoveFileExW with MOVEFILE_REPLACE_EXISTING).
        // POSIX rename(3) would also replace, but Windows' CRT rename(3) fails
        // with EEXIST if the destination already exists — which is why we don't
        // use the plain C call here.
        std::error_code ec;
        std::filesystem::rename(tmp, fname, ec);
        if (ec) {
            Log_e("writeTo: rename failed for %s: %s", filename, ec.message().c_str());
            std::error_code ignored;
            std::filesystem::remove(tmp, ignored);
            return false;
        }
        return true;
    } catch (const cv::Exception &e) {
        // Where a full disk usually lands: libtiff fails to write, OpenCV turns that into
        // a cv::Exception. Caught and logged here since it must not cross the extern "C"
        // boundary — but until this returned a value, that log line was the only trace and
        // the Swift caller carried on as though the frame had been written.
        Log_e("writeTo: %s OpenCV Exception: %s", filename, e.what());
    } catch (...) {
        Log_e("writeTo: %s unknown exception", filename);
    }
    return false;
}

bool mat_wrapper_save_jpeg(MatWrapperRef ref, uint32_t quality, const char *filename) {
    if (!ref) return false;
    try {
        cv::Mat eightBit = ensure8U(ref->mat);
        std::vector<int> params = {cv::IMWRITE_JPEG_QUALITY, (int)quality};
        if (!cv::imwrite(std::string(filename), eightBit, params)) {
            Log_e("saveJpeg: imwrite failed for %s", filename);
            return false;
        }
        return true;
    } KHT_CATCH_LOG("mat_wrapper_save_jpeg")
    return false;
}

MatWrapperRef mat_wrapper_bottom_crop(MatWrapperRef ref, int n) {
    if (!ref) return nullptr;
    try {
        int newHeight = ref->mat.rows - n;
        if (newHeight <= 0) {
            Log_w("invalid newHeight %d", newHeight);
            return wrap(cv::Mat());
        }
        cv::Rect roi(0, n, ref->mat.cols, newHeight);
        return wrap(ref->mat(roi));
    } KHT_CATCH_LOG("mat_wrapper_bottom_crop")
    return nullptr;
}

MatWrapperRef mat_wrapper_up_scale(MatWrapperRef ref, uint64_t width, uint64_t height) {
    if (!ref) return nullptr;
    try {
        cv::Mat output;
        cv::resize(ref->mat, output, cv::Size((int)width, (int)height), 0, 0, cv::INTER_CUBIC);
        return wrap(output);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef mat_wrapper_down_scale(MatWrapperRef ref, uint64_t width, uint64_t height) {
    if (!ref) return nullptr;
    try {
        cv::Mat output;
        cv::resize(ref->mat, output, cv::Size((int)width, (int)height), 0, 0, cv::INTER_AREA);
        return wrap(output);
    } catch (const cv::Exception &e) {
        Log_e("OpenCV Exception: %s", e.what());
    }
    return nullptr;
}

MatWrapperRef mat_wrapper_ensure_eight_bit(MatWrapperRef ref) {
    if (!ref) return nullptr;
    try {
        return wrap(ensure8U(ref->mat));
    } KHT_CATCH_LOG("mat_wrapper_ensure_eight_bit")
    return nullptr;
}

// Convert to single-channel 8-bit grayscale — required for horizon masks
MatWrapperRef mat_wrapper_ensure_gray_8u(MatWrapperRef ref) {
    if (!ref) return nullptr;
    try {
        cv::Mat result = ensure8U(ref->mat);
        if (result.channels() > 1) {
            cv::Mat gray;
            if (result.channels() == 4)      cv::cvtColor(result, gray, cv::COLOR_BGRA2GRAY);
            else if (result.channels() == 3) cv::cvtColor(result, gray, cv::COLOR_BGR2GRAY);
            else                             gray = result;   // shouldn't happen, but be safe
            return wrap(gray);
        }
        return wrap(result);
    } KHT_CATCH_LOG("mat_wrapper_ensure_gray_8u")
    return nullptr;
}

MatWrapperRef mat_wrapper_add_white_rows_on_top(MatWrapperRef ref, int rows) {
    if (!ref) return nullptr;
    try {
        cv::Scalar white;
        int ch = ref->mat.channels();
        if (ch == 1) white = cv::Scalar(255);
        else if (ch == 3) white = cv::Scalar(255, 255, 255);
        else if (ch == 4) white = cv::Scalar(255, 255, 255, 255);
        else white = cv::Scalar(255);

        cv::Mat result;
        cv::copyMakeBorder(ref->mat, result, rows, 0, 0, 0, cv::BORDER_CONSTANT, white);
        return wrap(result);
    } KHT_CATCH_LOG("mat_wrapper_add_white_rows_on_top")
    return nullptr;
}

bool mat_wrapper_is_16_bits(MatWrapperRef ref) {
    return ref && ref->mat.depth() == CV_16U;
}

bool mat_wrapper_is_8_bits(MatWrapperRef ref) {
    return ref && ref->mat.depth() == CV_8U;
}

// Both of these return a NEW ref that the caller owns and releases, but when no
// conversion is needed it shares the existing pixels rather than copying them.  Deep
// copying a conversion that does nothing cost a full frame — 241MB at 42MP, and
// finishSelective calls ensure16Bits twice per merge.
//
// Sharing is the semantic these already had one level up: PixelatedImage.ensure16Bits
// returns `self` when the mat is already 16-bit, so callers have always had to tolerate
// getting the same pixels back.  The clone was only ever reached by the two sites that
// bypass that property and call through MatWrapper directly.
//
// As with mat_wrapper_alias, neither handle may be mutated afterwards.  Nothing does:
// mat_wrapper_data_ptr is const, and the one Swift accessor that casts it away
// (MatWrapper.mutableBuffer) has no callers.
MatWrapperRef mat_wrapper_ensure_16_bits(MatWrapperRef ref) {
    if (!ref) return nullptr;
    try {
        if (ref->mat.depth() != CV_16U) {
            cv::Mat img16;
            ref->mat.convertTo(img16, CV_16U, 256.0);
            return wrap(img16);
        }
        return mat_wrapper_alias(ref);
    } KHT_CATCH_LOG("mat_wrapper_ensure_16_bits")
    return nullptr;
}

MatWrapperRef mat_wrapper_ensure_8_bits(MatWrapperRef ref) {
    if (!ref) return nullptr;
    try {
        if (ref->mat.depth() != CV_8U) {
            cv::Mat img8;
            ref->mat.convertTo(img8, CV_8U, 1.0/256.0);
            return wrap(img8);
        }
        return mat_wrapper_alias(ref);
    } KHT_CATCH_LOG("mat_wrapper_ensure_8_bits")
    return nullptr;
}

double mat_wrapper_at_double(MatWrapperRef ref, int row, int col) {
    if (!ref) return 0.0;
    try {
        return ref->mat.at<double>(row, col);
    } KHT_CATCH_LOG("mat_wrapper_at_double")
    return 0.0;
}

// --- Homography ---

bool mat_wrapper_get_homography_values(MatWrapperRef ref, double *out9) {
    if (!ref || ref->mat.empty() || ref->mat.rows != 3 || ref->mat.cols != 3 || ref->mat.type() != CV_64F)
        return false;
    try {
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 3; c++)
                out9[r * 3 + c] = ref->mat.at<double>(r, c);
        return true;
    } KHT_CATCH_LOG("mat_wrapper_get_homography_values")
    return false;
}

MatWrapperRef mat_wrapper_from_homography_values(const double *values9) {
    try {
        cv::Mat H(3, 3, CV_64F);
        for (int r = 0, i = 0; r < 3; r++)
            for (int c = 0; c < 3; c++, i++)
                H.at<double>(r, c) = values9[i];
        return wrap(H);
    } KHT_CATCH_LOG("mat_wrapper_from_homography_values")
    return nullptr;
}

// --- Matrix split/combine ---

int mat_wrapper_split(MatWrapperRef ref, int tileWidth, int tileHeight,
                      double overlapPercent, CImageMatrixElement **outElements) {
    if (!ref || outElements == nullptr) return 0;
    try {
        int stepX = (int)(tileWidth * (1.0 - overlapPercent));
        int stepY = (int)(tileHeight * (1.0 - overlapPercent));
        if (stepX <= 0 || stepY <= 0) return 0;

        // Count tiles
        int count = 0;
        for (int y = 0; y < ref->mat.rows; y += stepY)
            for (int x = 0; x < ref->mat.cols; x += stepX)
                count++;

        auto *elems = (CImageMatrixElement *)malloc(sizeof(CImageMatrixElement) * count);
        int idx = 0;
        for (int y = 0; y < ref->mat.rows; y += stepY) {
            for (int x = 0; x < ref->mat.cols; x += stepX) {
                int w = std::min(tileWidth, ref->mat.cols - x);
                int h = std::min(tileHeight, ref->mat.rows - y);
                cv::Rect roi(x, y, w, h);
                elems[idx].x = x;
                elems[idx].y = y;
                elems[idx].width = w;
                elems[idx].height = h;
                elems[idx].image = wrap(ref->mat(roi));
                idx++;
            }
        }

        *outElements = elems;
        return count;
    } KHT_CATCH_LOG("mat_wrapper_split")
    return 0;
}

void mat_wrapper_free_split(CImageMatrixElement *elements, int count) {
    if (!elements) return;
    for (int i = 0; i < count; i++) {
        mat_wrapper_release(elements[i].image);
    }
    free(elements);
}

MatWrapperRef mat_wrapper_combine(const CImageMatrixElement *elements, int count) {
    if (!elements || count <= 0) return nullptr;
    try {
        int maxX = 0, maxY = 0;
        for (int i = 0; i < count; i++) {
            maxX = std::max(maxX, elements[i].x + elements[i].width);
            maxY = std::max(maxY, elements[i].y + elements[i].height);
        }

        const cv::Mat& first = elements[0].image->mat;
        cv::Mat combined(maxY, maxX, first.type(), cv::Scalar::all(0));

        for (int i = 0; i < count; i++) {
            const cv::Mat& tile = elements[i].image->mat;
            cv::Rect roi(elements[i].x, elements[i].y, elements[i].width, elements[i].height);
            tile.copyTo(combined(roi));
        }

        return wrap(combined);
    } KHT_CATCH_LOG("mat_wrapper_combine")
    return nullptr;
}

// --- CV type helper ---

int mat_wrapper_cv_type_for(int bitsPerComponent, int componentsPerPixel) {
    if (bitsPerComponent == 8) {
        if (componentsPerPixel == 1) return CV_8UC1;
        if (componentsPerPixel == 3) return CV_8UC3;
        if (componentsPerPixel == 4) return CV_8UC4;
    } else if (bitsPerComponent == 16) {
        if (componentsPerPixel == 1) return CV_16UC1;
        if (componentsPerPixel == 3) return CV_16UC3;
        if (componentsPerPixel == 4) return CV_16UC4;
    } else if (bitsPerComponent == 32) {
        if (componentsPerPixel == 1) return CV_32FC1;
    }
    return -1;
}

// --- Memory tracking ---

uint64_t mat_wrapper_total_bytes(void) {
    return MatWrapperImpl::totalBytes_.load(std::memory_order_relaxed);
}

uint64_t mat_wrapper_total_instances(void) {
    return MatWrapperImpl::totalInstances_.load(std::memory_order_relaxed);
}
