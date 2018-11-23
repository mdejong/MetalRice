//
//  MetalCropToTextureRenderContext.m
//
//  Copyright 2016 Mo DeJong.
//
//  See LICENSE for terms.
//
//  This module references Metal objects that are used to crop
//  2D texture data to an original size.

#include "MetalCropToTextureRenderContext.h"

// Header shared between C code here, which executes Metal API commands, and .metal files, which
//   uses these types as inpute to the shaders
#import "AAPLShaderTypes.h"

#import "MetalRenderContext.h"
#import "MetalCropToTextureRenderFrame.h"

// Private API

@interface MetalCropToTextureRenderContext ()

@end

// Main class performing the rendering
@implementation MetalCropToTextureRenderContext

// Setup render pixpelines

- (void) setupRenderPipelines:(MetalRenderContext*)mrc
{
  NSString *shader = self.fragmentKernelFunction;
    
  if (shader == nil) {
    shader = @"cropAndGrayscaleFromTexturesFragmentShader";
  }

  // Render from BGRA where 4 grayscale values are packed into
  // each pixel into BGRA pixels that are expanded to grayscale
  // and cropped to the original image dimensions.
  
  self.pipelineState = [mrc makePipeline:MTLPixelFormatBGRA8Unorm
                               pipelineLabel:@"CropToTexture Pipeline"
                              numAttachments:1
                          vertexFunctionName:@"vertexShader"
                        fragmentFunctionName:shader];

  NSAssert(self.pipelineState, @"pipelineState");
}

// Render textures initialization
// renderSize : indicates the size of the entire texture containing block by block values
// blockSize  : indicates the size of the block to be summed
// renderFrame : holds textures used while rendering

- (void) setupRenderTextures:(MetalRenderContext*)mrc
                  renderSize:(CGSize)renderSize
                   blockSize:(CGSize)blockSize
                 renderFrame:(MetalCropToTextureRenderFrame*)renderFrame
{
  const BOOL debug = TRUE;
  
  const int blockDim = RICE_SMALL_BLOCK_DIM;
  const int blockNumElements = blockDim * blockDim;
  
  // Calculate block dimension in H vs V, the horizontal
  // dimension takes into account that 4 bytes values can
  // be packed into a BGRA pixel.

  // blockSize passed in by caller must be square
  
  unsigned int blockDimW = blockSize.width;
  unsigned int blockDimH = blockSize.height;

  // blockSize must be a square when passed from caller
  assert(blockDimW == blockDimH);
  assert(blockDimW == blockDim);

  // blockDim is known to be a POT, this is the side length.
  // Note that this blockDim value does not include a width
  // adjustment to pack 4 byte vlaues into a BGRA pixel.
  
  //unsigned int blockDim = blockDimH;
  
  assert(blockDim > 1);
  BOOL isPOT = (blockDim & (blockDim - 1)) == 0;
  assert(isPOT);
  
  renderFrame.blockDim = blockDim;
  
  // Calculate width and height in terms of block dim multiples
  
  unsigned int width = renderSize.width;
  unsigned int height = renderSize.height;
  
  // Determine the number of blocks in the input image width
  // along with the number of blocks in the height. The input
  // image need not be a square.
  
#if defined(DEBUG)
  assert((width % blockDim) == 0);
  assert((height % blockDim) == 0);
#endif // DEBUG
  
  renderFrame.width = width;
  renderFrame.height = height;
  
  unsigned int numBlocksInWidth = width / blockDim;
  unsigned int numBlocksInHeight = height / blockDim;
  
  renderFrame.numBlocksInWidth = numBlocksInWidth;
  renderFrame.numBlocksInHeight = numBlocksInHeight;
  
  // The number of flat blocks that fits into (width * height) is
  // constant while the texture dimension is being reduced.
  
#if defined(DEBUG)
  assert(((width * height) % (blockDim * blockDim)) == 0);
  unsigned int numBlocksInImage = (width * height) / (blockDim * blockDim);
  assert(numBlocksInImage == (numBlocksInWidth * numBlocksInHeight));
#endif // DEBUG
  
  // Note that while the above logic calculates the number of blocks
  // in terms of the original 8x8 pixel blocks, the actual number of
  // pixels in the X dimension is determined by (blockDim / 4)

  // Output texture, note that a texture can be defined for the frame
  // already and in this case the existing ref is simply validated
  // without allocating another texture.
  
  int width4 = width / sizeof(uint32_t);

  {
    id<MTLTexture> txt = renderFrame.inputTexture;
    
    if (txt != nil) {
      NSAssert(txt.width == width4, @"inputTexture width must be %d, it was %d", width4, (int)txt.width);
      NSAssert(txt.height == height, @"inputTexture height must be %d, it was %d", height, (int)txt.height);
      NSAssert(txt.pixelFormat == MTLPixelFormatBGRA8Unorm, @"inputTexture must be BGRA format pixels");
    } else {
      txt = [mrc makeBGRATexture:CGSizeMake(width4, height) pixels:NULL usage:MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite];
      
      renderFrame.inputTexture = txt;
    }
    
    if (debug) {
      NSLog(@"input       : texture %3d x %3d", (int)txt.width, (int)txt.height);
    }
  }

  // Note that the output texture is in terms of the full width and height after the crop and expand
  
  {
    id<MTLTexture> txt = renderFrame.outputTexture;
    
    if (txt != nil) {
      NSAssert(txt.width == width, @"outputTexture width must be %d, it was %d", width, (int)txt.width);
      NSAssert(txt.height == height, @"outputTexture height must be %d, it was %d", height, (int)txt.height);
      NSAssert(txt.pixelFormat == MTLPixelFormatBGRA8Unorm, @"outputTexture must be BGRA format pixels");
    } else {
      txt = [mrc makeBGRATexture:CGSizeMake(width, height) pixels:NULL usage:MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite];
      
      renderFrame.outputTexture = txt;
    }
    
    if (debug) {
      NSLog(@"output      : texture %3d x %3d", (int)txt.width, (int)txt.height);
    }
  }

  // Dimensions passed into shaders
  
  renderFrame.renderTargetDimensionsAndBlockDimensionsUniform = [mrc.device newBufferWithLength:sizeof(RenderTargetDimensionsAndBlockDimensionsUniform) options:MTLResourceStorageModeShared];
  
  // RenderTargetDimensionsAndBlockDimensionsUniform
  
  {
    RenderTargetDimensionsAndBlockDimensionsUniform *ptr = renderFrame.renderTargetDimensionsAndBlockDimensionsUniform.contents;
    ptr->width = width;
    ptr->height = height;
    ptr->blockWidth = numBlocksInWidth;
    ptr->blockHeight = numBlocksInHeight;
  }
  
  return;
}

#if defined(DEBUG)

#endif // DEBUG

// Fragment shader render operation

- (void) renderCropToTexture:(MetalRenderContext*)mrc
               commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                 renderFrame:(MetalCropToTextureRenderFrame*)renderFrame
{
  const BOOL debug = FALSE;
  
#if defined(DEBUG)
  assert(mrc);
  assert(commandBuffer);
  assert(renderFrame);
#endif // DEBUG
  
  id<MTLRenderPipelineState> pipeline = self.pipelineState;

  id<MTLTexture> inputTexture = renderFrame.inputTexture;
  id<MTLTexture> outputTexture = renderFrame.outputTexture;
  
  NSString *label = @"CropToTexture";

  int blockWidth = (int) renderFrame.numBlocksInWidth;
  int blockHeight = (int) renderFrame.numBlocksInHeight;
  int blockDim = (int) renderFrame.blockDim;
  
#if defined(DEBUG)
  assert(blockDim == RICE_SMALL_BLOCK_DIM);
#endif // DEBUG

#if defined(DEBUG)
  // Input and Output buffers must be the exact same length
  
  int numBytes = (int) renderFrame.width * (int) renderFrame.height;
  
  if (debug) {
    NSLog(@"renderCropToTexture %d x %d : %d bytes", (int)renderFrame.width, (int)renderFrame.height, numBytes);
  }
#endif // DEBUG
  
  MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
  
  if (renderPassDescriptor != nil)
  {
    renderPassDescriptor.colorAttachments[0].texture = outputTexture;
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    
    id <MTLRenderCommandEncoder> renderEncoder =
    [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    renderEncoder.label = label;
    
    [renderEncoder pushDebugGroup:label];
    
    // Set the region of the drawable to which we'll draw.
    
    MTLViewport mtlvp = {0.0, 0.0, outputTexture.width, outputTexture.height, -1.0, 1.0 };
    [renderEncoder setViewport:mtlvp];
    
    [renderEncoder setRenderPipelineState:pipeline];
    
    [renderEncoder setVertexBuffer:mrc.identityVerticesBuffer
                            offset:0
                           atIndex:0];
    
    [renderEncoder setFragmentTexture:inputTexture
                              atIndex:0];
    
    [renderEncoder setFragmentBuffer:renderFrame.renderTargetDimensionsAndBlockDimensionsUniform
                              offset:0
                             atIndex:0];
    
    // Draw the 3 vertices of our triangle
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                      vertexStart:0
                      vertexCount:mrc.identityNumVertices];
    
    [renderEncoder popDebugGroup]; // RenderToTexture
    
    [renderEncoder endEncoding];
  }
}

@end
