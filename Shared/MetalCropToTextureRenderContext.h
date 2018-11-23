//
//  MetalCropToTextureRenderContext.h
//
//  Copyright 2018 Mo DeJong.
//
//  See LICENSE for terms.
//
//  This module references Metal objects that are used to crop
//  2D texture data to an original size.

//@import MetalKit;
#include <MetalKit/MetalKit.h>

@class MetalRenderContext;
@class MetalCropToTextureRenderFrame;

@interface MetalCropToTextureRenderContext : NSObject

// Name of fragment shader function

@property (nonatomic, copy) NSString *fragmentKernelFunction;

// fragment pipeline

@property (nonatomic, retain) id<MTLRenderPipelineState> pipelineState;

#if defined(DEBUG)
#endif // DEBUG

// Setup render pixpelines

- (void) setupRenderPipelines:(MetalRenderContext*)mrc;

// Render textures initialization
// renderSize : indicates the size of the entire texture containing block by block values
// blockSize  : indicates the size of the block to be operated on
// renderFrame : holds textures used while rendering

- (void) setupRenderTextures:(MetalRenderContext*)mrc
                  renderSize:(CGSize)renderSize
                   blockSize:(CGSize)blockSize
                 renderFrame:(MetalCropToTextureRenderFrame*)renderFrame;

// Specific render operations

- (void) renderCropToTexture:(MetalRenderContext*)mrc
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer
             renderFrame:(MetalCropToTextureRenderFrame*)renderFrame;

@end
