#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ObjCAlignmentStep) {
  ObjCAlignmentStepStart = 0,
  ObjCAlignmentStepBaseKeypointDetection = 1,
  ObjCAlignmentStepLoadingNeighbors = 2,
  ObjCAlignmentStepAligningNeighbor = 3,
  ObjCAlignmentStepComplete = 4,
};

