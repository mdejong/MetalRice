//
//  MetalRiceRenderFrame.h
//
//  Copyright 2016 Mo DeJong.
//
//  See LICENSE for terms.
//
//  This module references Metal objects that are used to render
//  rice prefix values read from a stream that is broken up into
//  32 sub streams.

//@import MetalKit;
#include <MetalKit/MetalKit.h>

@class MetalRiceRenderContext;

@interface MetalRiceRenderFrame : NSObject

// A prefix sum only works with POT, so the width and height
// must be properly set so that width x height is always
// in terms of a multiple of blockDim.

@property (nonatomic, assign) NSUInteger width;
@property (nonatomic, assign) NSUInteger height;

@property (nonatomic, assign) NSUInteger numBlocksInWidth;
@property (nonatomic, assign) NSUInteger numBlocksInHeight;

// The square dimensions of a block at the original image dimensions

@property (nonatomic, assign) NSUInteger blockDim;

// Output of the prefix render is prefix bytes in 2D image order

@property (nonatomic, retain) id<MTLTexture> outputTexture;

// Collection of prefix bit start offsets and other constant parameters for the shader

@property (nonatomic, retain) id<MTLBuffer> riceRenderUniform;

// This buffer contains rice encoded bits packed into uint32_t values

@property (nonatomic, retain) id<MTLBuffer> bitsBuff;

// This buffer is written as blocks of prefix values are processed, it tracks
// the number of escape values that appear in one block.

@property (nonatomic, retain) id<MTLBuffer> escapePerBlockCounts;

// Block K lookup table, indexed by blocki

@property (nonatomic, retain) id<MTLBuffer> blockOptimalKTable;

// uint32_t bit offset lookup indexed by blocki+tid

@property (nonatomic, retain) id<MTLBuffer> blockOffsetTableBuff;

// uint32_t output buffer for values like blocki emitted by shader

@property (nonatomic, retain) id<MTLBuffer> out32Buff;

#if defined(DEBUG)
#endif // DEBUG

// Buffers passed into shaders

//@property (nonatomic, retain) id<MTLBuffer> renderTargetDimensionsAndBlockDimensionsUniform;

@end
