//
//  MetalRice2RenderContext.h
//
//  Copyright 2018 Mo DeJong.
//
//  See LICENSE for terms.
//
//  This module references Metal objects that are used to render
//  rice values read from a stream that is broken up into
//  32 sub streams.

//@import MetalKit;
#include <MetalKit/MetalKit.h>

@class MetalRenderContext;
@class MetalRice2RenderFrame;

@interface MetalRice2RenderContext : NSObject

// Name of Metal kernel function to use (initialized by default)

@property (nonatomic, copy) NSString *computeKernelFunction;

// Special case render when another 32 bit array pointer is passed in

@property (nonatomic, assign) BOOL computeKernelPassArg32;

// The number of bytes that each thread maps to

@property (nonatomic, assign) NSUInteger bytesPerThread;

// Computed shader dimensions

@property (nonatomic, assign) MTLSize threadgroupsPerGrid;
@property (nonatomic, assign) MTLSize threadsPerThreadgroup;

// Metal compute pipeline

@property (nonatomic, retain) id<MTLComputePipelineState> computePipelineState;

#if defined(DEBUG)
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
                 renderFrame:(MetalRice2RenderFrame*)renderFrame;

// Specific render operations

- (void) renderRice:(MetalRenderContext*)mrc
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer
             renderFrame:(MetalRice2RenderFrame*)renderFrame;

- (void) ensureBitsBuffCapacity:(MetalRenderContext*)mrc
                       numBytes:(int)numBytes
                    renderFrame:(MetalRice2RenderFrame*)renderFrame;

@end
