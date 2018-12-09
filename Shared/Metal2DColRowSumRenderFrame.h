//
//  Metal2DColRowSumRenderFrame.h
//
//  Copyright 2016 Mo DeJong.
//
//  See LICENSE for terms.
//
//  This module references Metal objects that are used to render
//  a 2D sum, first column 0 is summed along the Y axis, then
//  each row is summed. There can be N render frames
//  associates with a single render context.

//@import MetalKit;
#include <MetalKit/MetalKit.h>

@class Metal2DColRowSumSumRenderContext;

@interface Metal2DColRowSumRenderFrame : NSObject

// A prefix sum only works with POT, so the width and height
// must be properly set so that width x height is always
// in terms of a multiple of blockDim.

@property (nonatomic, assign) NSUInteger width;
@property (nonatomic, assign) NSUInteger height;

@property (nonatomic, assign) NSUInteger numBlocksInWidth;
@property (nonatomic, assign) NSUInteger numBlocksInHeight;

// The square dimensions of a block at the original image dimensions

@property (nonatomic, assign) NSUInteger blockDim;

// The original input image order in block order

@property (nonatomic, retain) id<MTLTexture> inputTexture;
@property (nonatomic, retain) id<MTLTexture> outputTexture;

#if defined(DEBUG)

//@property (nonatomic, retain) id<MTLTexture> debugRenderXYoffsetTexture;

#endif // DEBUG

// Buffers passed into shaders

//@property (nonatomic, retain) id<MTLBuffer> renderTargetDimensionsAndBlockDimensionsUniform;

@end
