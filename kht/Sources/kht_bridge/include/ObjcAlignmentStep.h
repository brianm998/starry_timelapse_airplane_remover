#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ObjCAlignmentStep) {
  ObjCAlignmentStepStart = 0,
  ObjCAlignmentStepBaseKeypointDetection = 1,
  ObjCAlignmentStepBaseKeypointDetectionComplete = 2,
  ObjCAlignmentStepLoadingNeighbors = 3,
  ObjCAlignmentStepNeighborKeypointDetection = 4,
  ObjCAlignmentStepNeighborKeypointMatch = 5,
  ObjCAlignmentStepAligningNeighbor = 6,
  ObjCAlignmentStepLoadingNeighbor = 7,
  ObjCAlignmentStepComplete = 8,
};

