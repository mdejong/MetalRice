#import <Foundation/Foundation.h>

typedef enum {
  TEST_4x4_INCREASING1 = 0,
  TEST_4x4_INCREASING2,
  TEST_4x8_INCREASING1,
  TEST_2x8_INCREASING1,
  TEST_6x4_NOT_SQUARE,
  TEST_8x8_IDENT,
  TEST_16x8_IDENT,
  TEST_16x16_IDENT,
  TEST_16x16_IDENT1,
  TEST_16x16_IDENT2,
  TEST_16x16_IDENT3,
  TEST_16x16_DELTA_IDENT,
  TEST_32x32_DELTA_IDENT,
  TEST_8x8_IDENT_2048,
  TEST_8x8_IDENT_4096,
  TEST_LARGE_RANDOM,
  TEST_IMAGE1,
  TEST_IMAGE2,
  TEST_IMAGE3,
  TEST_IMAGE4,
  TEST_IMAGE_LENNA_B
} InputImageRenderFrameConfig;

// Header shared between C code here, which executes Metal API commands, and .metal files, which
//   uses these types as inpute to the shaders
#import "AAPLShaderTypes.h"

@interface InputImageRenderFrame : NSObject

@property (nonatomic, assign) int renderWidth;
@property (nonatomic, assign) int renderHeight;

@property (nonatomic, assign) int renderBlockWidth;
@property (nonatomic, assign) int renderBlockHeight;

@property (nonatomic, copy) NSData *inputData;

@property (nonatomic, assign) BOOL capture;

// Get a specific configuration given a InputImageRenderFrame identifier

+ (InputImageRenderFrame*) renderFrameForConfig:(InputImageRenderFrameConfig)config;

@end
