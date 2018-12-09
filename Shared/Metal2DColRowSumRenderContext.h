//
//  Metal2DColRowSumRenderContext.h
//
//  Copyright 2018 Mo DeJong.
//
//  See LICENSE for terms.
//
//  This module references Metal objects that are used to render
//  2D sum across columns and rows. There is 1 render context
//  for N render frames.

//@import MetalKit;
#include <MetalKit/MetalKit.h>

@class MetalRenderContext;
@class Metal2DColRowSumRenderFrame;

@interface Metal2DColRowSumRenderContext : NSObject

// Name of Metal kernel function to use (initialized by default)

@property (nonatomic, copy) NSString *computeKernelFunction;

// The number of bytes that each thread maps to

@property (nonatomic, assign) NSUInteger bytesPerThread;

// Computed shader dimensions

@property (nonatomic, assign) MTLSize threadgroupsPerGrid;
@property (nonatomic, assign) MTLSize threadsPerThreadgroup;

// Metal compute pipeline

@property (nonatomic, retain) id<MTLComputePipelineState> computePipelineState;

#if defined(DEBUG)

//@property (nonatomic, retain) id<MTLRenderPipelineState> debugRenderXYoffsetTexturePipelineState;

#endif // DEBUG

// Setup render pixpelines

- (void) setupRenderPipelines:(MetalRenderContext*)mrc;

// Render textures initialization
// renderSize : indicates the size of the entire texture containing block by block values
// blockSize  : indicates the size of the block to be summed
// renderFrame : holds textures used while rendering

- (void) setupRenderTextures:(MetalRenderContext*)mrc
                  renderSize:(CGSize)renderSize
                   blockSize:(CGSize)blockSize
                 renderFrame:(Metal2DColRowSumRenderFrame*)renderFrame;

// Specific render operations

- (void) renderColRowSum:(MetalRenderContext*)mrc
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer
             renderFrame:(Metal2DColRowSumRenderFrame*)renderFrame;

@end
