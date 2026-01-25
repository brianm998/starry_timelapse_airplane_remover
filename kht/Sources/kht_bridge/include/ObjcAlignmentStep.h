#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ObjCAlignmentStep) {
  ObjCAlignmentStepStart = 0,
  ObjCAlignmentStepBaseKeypointDetection = 1,
  ObjCAlignmentStepBaseKeypointDetectionComplete = 2,
  ObjCAlignmentStepNeighborKeypointDetection = 3,
  ObjCAlignmentStepNeighborKeypointMatch = 4,
  ObjCAlignmentStepAligningNeighbor = 5,
  ObjCAlignmentStepLoadingNeighbor = 6,
  ObjCAlignmentStepComplete = 7,
};

