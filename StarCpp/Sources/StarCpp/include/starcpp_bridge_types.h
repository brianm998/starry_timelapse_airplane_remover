// starcpp_bridge_types.h — All opaque handle types, enums, and simple structs
#pragma once

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- Opaque handle types ---
typedef struct MatWrapperImpl*      MatWrapperRef;
typedef struct OCVFeatureSetImpl*   OCVFeatureSetRef;
typedef struct BufferHolderImpl*    BufferHolderRef;

// --- Enums ---
// Named to match old ObjC NS_ENUM names so StarCore code doesn't need changes

typedef enum {
    AlignmentTypeSky   = 0,
    AlignmentTypeEarth = 1
} AlignmentType;

typedef enum {
    FeatureMatchMethodBruteForce = 0,
    FeatureMatchMethodKNNLowes   = 1,
    FeatureMatchMethodFLANN      = 2
} FeatureMatchMethod;

// Named AlignmentStateObjC to avoid conflict with StarCore's Swift AlignmentState enum
typedef enum {
    AlignmentStateObjCUnableToDetectKeypoints = 0,
    AlignmentStateObjCNotEnoughKeypoints      = 1,
    AlignmentStateObjCNoHomographyFound       = 2,
    AlignmentStateObjCHomographySuccess       = 3,
    AlignmentStateObjCUsedExistingHomography  = 4,
    AlignmentStateObjCNoAlignment             = 5,
    AlignmentStateObjCUnknown                 = 6
} AlignmentStateObjC;

// Named ObjCAlignmentStep to avoid conflict with StarCore's Swift AlignmentStep enum
typedef enum {
    ObjCAlignmentStepStart                       = 0,
    ObjCAlignmentStepBaseKeypointDetection       = 1,
    ObjCAlignmentStepBaseKeypointDetectionComplete = 2,
    ObjCAlignmentStepNeighborKeypointDetection   = 3,
    ObjCAlignmentStepNeighborKeypointMatch       = 4,
    ObjCAlignmentStepAligningNeighbor            = 5,
    ObjCAlignmentStepLoadingNeighbor             = 6,
    ObjCAlignmentStepComplete                    = 7
} ObjCAlignmentStep;

// --- Simple value structs ---

typedef struct {
    int64_t horizonTopY;
    int64_t horizonBottomY;
} HorizonResultData;

typedef struct {
    double theta;
    double rho;
    int    votes;
} KHTLine;

// C-level image matrix element (used by mat_wrapper_split/combine)
typedef struct {
    int32_t       x;
    int32_t       y;
    int32_t       width;
    int32_t       height;
    MatWrapperRef image;  // caller must release when done
} CImageMatrixElement;

typedef struct {
    MatWrapperRef    homography;     // nullable, caller must release
    double           deviation;
    AlignmentStateObjC alignmentState;
    int64_t          frameIndex;
} AlignmentWarpInfoData;

typedef struct {
    MatWrapperRef warpedFrame;    // nullable, caller must release
    MatWrapperRef warpedHorizon;  // nullable, caller must release
} WarpedImageResultData;

typedef struct {
    MatWrapperRef alignedMat;     // nullable, caller must release
    MatWrapperRef failedMat;      // nullable, caller must release
    MatWrapperRef horizonMask;    // nullable, caller must release
} AlignmentResultData;

// --- Callback types ---

// Image loader: given a filename, returns the loaded image or NULL.
//
// Synchronous by contract, and it has to stay that way.  `image_cache_load`
// is called from deep inside ImageAligner on whatever thread is running the
// merge — a Swift cooperative-pool thread, or an OpenCV GCD worker.  This
// used to take a completion callback and block on a condition variable until
// it fired, which only ever worked because the one registered loader happened
// to call the completion before returning.  A loader that completed on
// another thread would have parked the calling thread waiting for work that
// may well need the very pool it is holding.  Returning the value directly
// removes the option.
typedef MatWrapperRef (*ImageLoaderFunc)(const char *filename);

// Alignment progress callback
typedef void (*AlignmentUpdateFunc)(int frameIndex,
                                    AlignmentType alignmentType,
                                    ObjCAlignmentStep alignmentStep,
                                    int neighborNumber,
                                    void *context);

#ifdef __cplusplus
}
#endif
