//
//  MetalCropToTextureRenderFrame.h
//
//  Copyright 2016 Mo DeJong.
//
//  See LICENSE for terms.
//
//  This module references Metal objects that are used to crop
//  BGRA pixels to an original image width and height and
//  convert grayscale pixels to full BGRA pixels.

//@import MetalKit;
#include <MetalKit/MetalKit.h>

@class MetalCropToTextureRenderContext;

@interface MetalCropToTextureRenderFrame : NSObject

@property (nonatomic, assign) NSUInteger width;
@property (nonatomic, assign) NSUInteger height;

@property (nonatomic, assign) NSUInteger numBlocksInWidth;
@property (nonatomic, assign) NSUInteger numBlocksInHeight;

// The square dimensions of a block at the original image dimensions

@property (nonatomic, assign) NSUInteger blockDim;

@property (nonatomic, retain) id<MTLBuffer> renderTargetDimensionsAndBlockDimensionsUniform;

// The 2D input texture

@property (nonatomic, retain) id<MTLTexture> inputTexture;

// The rendered 2D output

@property (nonatomic, retain) id<MTLTexture> outputTexture;

#if defined(DEBUG)

#endif // DEBUG

@end
