//
//  MetalRice2RenderContext.m
//
//  Copyright 2016 Mo DeJong.
//
//  See LICENSE for terms.
//
//  This module references Metal objects that are used to render
//  rice prefix values read from a stream that is broken up into
//  32 sub streams.

#include "MetalRice2RenderContext.h"

// Header shared between C code here, which executes Metal API commands, and .metal files, which
//   uses these types as inpute to the shaders
#import "AAPLShaderTypes.h"

#import "MetalRenderContext.h"
#import "MetalRice2RenderFrame.h"

// Private API

@interface MetalRice2RenderContext ()

//@property (readonly) size_t numBytesAllocated;

@end

// Main class performing the rendering
@implementation MetalRice2RenderContext

// Setup render pixpelines

- (void) setupRenderPipelines:(MetalRenderContext*)mrc
{
  NSString *shader;
  
  shader = self.computeKernelFunction;
  
  if (self.bytesPerThread == 0) {
    self.bytesPerThread = 128 / 4; // 32 threads in threadgroup
  }
  
  if (shader == nil) {
    shader = @"kernel_render_rice2_undelta";
  }
  
  // FIXME: no reason to pass MTLPixelFormatR8Unorm to compute pipeline
  
  self.computePipelineState = [mrc makePipeline:MTLPixelFormatR8Unorm
                                  pipelineLabel:@"RenderRicePrefix Pipeline"
                             kernelFunctionName:shader];

  NSAssert(self.computePipelineState, @"computePipelineState");
}

// Render textures initialization
// renderSize : indicates the size of the entire texture containing block by block values
// blockSize  : indicates the size of the block to be summed
// renderFrame : holds textures used while rendering

- (void) setupRenderTextures:(MetalRenderContext*)mrc
                  renderSize:(CGSize)renderSize
                   blockSize:(CGSize)blockSize
                 renderFrame:(MetalRice2RenderFrame*)renderFrame
{
  const BOOL debug = TRUE;
  
  // Note that these width and height calculations are in terms of
  // byte pixels, the actual texture is allocated with uint32_t pixels.
  
  unsigned int width = renderSize.width;
  unsigned int height = renderSize.height;

  unsigned int blockWidth = blockSize.width;
  unsigned int blockHeight = blockSize.height;
  
  renderFrame.width = width;
  renderFrame.height = height;
  
  assert(blockWidth == blockHeight);
  
  // blockDim is the number of elements in a processing block.
  // For example, a 2x2 block has a blockDim of 4 while
  // a 2x4 block has a blockDim of 8. A blockDim is known to
  // be a POT, so it can be treated as such in shader code.
  
  unsigned int blockDim = blockSize.width * blockSize.height;
  
  assert(blockDim > 1);
  BOOL isPOT = (blockDim & (blockDim - 1)) == 0;
  assert(isPOT);
  
  renderFrame.blockDim = blockDim;
  
  // Determine the number of blocks in the input image width
  // along with the number of blocks in the height. The input
  // image need not be a square.
  
#if defined(DEBUG)
  assert((width % blockWidth) == 0);
  assert((height % blockHeight) == 0);
#endif // DEBUG
  
  unsigned int numBlocksInWidth = width / blockWidth;
  unsigned int numBlocksInHeight = height / blockHeight;
  
  renderFrame.numBlocksInWidth = numBlocksInWidth;
  renderFrame.numBlocksInHeight = numBlocksInHeight;
  
  // The number of flat blocks that fits into (width * height) is
  // constant while the texture dimension is being reduced.
  
#if defined(DEBUG)
  assert(((width * height) % blockDim) == 0);
  unsigned int numBlocksInImage = (width * height) / blockDim;
  assert(numBlocksInImage == (numBlocksInWidth * numBlocksInHeight));
#endif // DEBUG
  
  // Input texture, note that a texture can be defined for the frame
  // already and in this case the existing ref is simply validated
  // without allocating another texture.
  
  int width4 = width / sizeof(uint32_t);
  
  // Output texture, note that a texture can be defined for the frame
  // already and in this case the existing ref is simply validated
  // without allocating another texture.
  
  {
    id<MTLTexture> txt = renderFrame.outputTexture;
    
    if (txt != nil) {
      NSAssert(txt.width == width4, @"outputTexture width must be %d, it was %d", width4, (int)txt.width);
      NSAssert(txt.height == height, @"outputTexture height must be %d, it was %d", height, (int)txt.height);
      NSAssert(txt.pixelFormat == MTLPixelFormatBGRA8Unorm, @"outputTexture must be BGRA format pixels");
    } else {
      txt = [mrc makeBGRATexture:CGSizeMake(width4, height) pixels:NULL usage:MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite];
      
      renderFrame.outputTexture = txt;
    }
    
    if (debug) {
      NSLog(@"output      : texture %3d x %3d", (int)txt.width, (int)txt.height);
    }
  }
  
  // Allocate 1/32 block start bits buffer
  
  renderFrame.riceRenderUniform = [mrc.device newBufferWithLength:sizeof(RiceRenderUniform)
                                                             options:MTLResourceStorageModeShared];
  

  // 1 32 bit value for each block

  {
    const int numBytes = sizeof(uint32_t) * numBlocksInWidth * numBlocksInHeight;
    renderFrame.escapePerBlockCounts = [mrc.device newBufferWithLength:numBytes
                                                             options:MTLResourceStorageModeShared];
    //memset(renderFrame.escapePerBlockCounts.contents, 0, numBytes);
  }
  
  // Compute threadgroup parameters
  
  int numBlocks = numBlocksInWidth * numBlocksInHeight;
  
  assert(numBlocks != 0);

  // The total number of input bytes must be a multiple of 32x32
  
  const int bigBlocksDim = 4;
  
  assert((numBlocksInWidth % bigBlocksDim) == 0);
  assert((numBlocksInHeight % bigBlocksDim) == 0);
  
  int numBigBlocksInWidth = numBlocksInWidth / bigBlocksDim;
  int numBigBlocksInHeight = numBlocksInHeight / bigBlocksDim;
  
  assert(numBigBlocksInWidth > 0);
  assert(numBigBlocksInHeight > 0);
  
  int numBigBlocks = numBigBlocksInWidth * numBigBlocksInHeight;
  
  int numBytes = (width * height);
  int numBytesInBigBlock = (bigBlocksDim * bigBlocksDim) * blockDim; // blockDim already squared here
  assert((numBytesInBigBlock * numBigBlocks) == numBytes);
  
  // The number of threadgroups in the grid, in each dimension.
  MTLSize threadgroupsPerGrid;
  threadgroupsPerGrid.width = numBigBlocksInWidth;
  threadgroupsPerGrid.height = numBigBlocksInHeight;
  threadgroupsPerGrid.depth = 1;
    
  // The number of threads in one threadgroup, in each dimension.
  MTLSize threadsPerThreadgroup;
  threadsPerThreadgroup.width = 32; // One thread for each uchar4, else 1 to 1
  threadsPerThreadgroup.height = 1;
  threadsPerThreadgroup.depth = 1;
  
  if (debug) {
    NSLog(@"threadsPerThreadgroup : texture %3d x %3d : %d threads", (int)threadsPerThreadgroup.width, (int)threadsPerThreadgroup.height, (int)threadsPerThreadgroup.width*(int)threadsPerThreadgroup.height);
    NSLog(@"threadgroupsPerGrid   : texture %3d x %3d", (int)threadgroupsPerGrid.width, (int)threadgroupsPerGrid.height);
  }
  
  self.threadgroupsPerGrid = threadgroupsPerGrid;
  self.threadsPerThreadgroup = threadsPerThreadgroup;
  
  // K lookup table
  
  {
    const int numBytes = sizeof(uint8_t) * numBlocksInWidth * numBlocksInHeight + 1;
    renderFrame.blockOptimalKTable = [mrc.device newBufferWithLength:numBytes
                                                               options:MTLResourceStorageModeShared];
    
    if (debug) {
      NSLog(@"K table      : buffer %3d bytes", (int)numBytes);
    }
  }
  
  // Block (tid lookup) based bit offset into bit buffer, note that this buffer
  // is initialized with block offsets and then each is updated in the shader.
  
  {
    const int numBytes = sizeof(uint32_t) * (numBlocksInWidth * numBlocksInHeight * 2);
    renderFrame.blockOffsetTableBuff = [mrc.device newBufferWithLength:numBytes
                                                             options:MTLResourceStorageModeShared];
    
    if (debug) {
      NSLog(@"blockOffsetTableBuff : buffer %3d words", (int)numBytes/(int)sizeof(uint32_t));
    }
  }

  return;
}

#if defined(DEBUG)

#endif // DEBUG

- (void) renderRice:(MetalRenderContext*)mrc
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer
             renderFrame:(MetalRice2RenderFrame*)renderFrame
{
  const BOOL debug = TRUE;
  
  // 2D output textures
  
  id<MTLTexture> outputTexture = renderFrame.outputTexture;
  
#if defined(DEBUG)
  // Input and Output buffers must be the exact same length
  
  int numBytes = (int) renderFrame.width * (int) renderFrame.height;
  
  if (debug) {
    printf("renderRice2 %d x %d : %d bytes\n", (int)renderFrame.width, (int)renderFrame.height, numBytes);
    printf("renderRice2 BGRA texture %d x %d\n", (int)outputTexture.width, (int)outputTexture.height);
  }
#endif // DEBUG
  
#if defined(DEBUG)
  assert(mrc);
  assert(commandBuffer);
  assert(renderFrame);
#endif // DEBUG
  
  {
    id <MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
    
#if defined(DEBUG)
    assert(computeEncoder);
#endif // DEBUG
    
    NSString *debugLabel = @"Rice2";
    computeEncoder.label = debugLabel;
    [computeEncoder pushDebugGroup:debugLabel];
    
    [computeEncoder setComputePipelineState:self.computePipelineState];
    
    [computeEncoder setTexture:outputTexture atIndex:0];
    
    [computeEncoder setBuffer:renderFrame.riceRenderUniform offset:0 atIndex:0];
    [computeEncoder setBuffer:renderFrame.blockOffsetTableBuff offset:0 atIndex:1];
    [computeEncoder setBuffer:renderFrame.bitsBuff offset:0 atIndex:2];
    [computeEncoder setBuffer:renderFrame.blockOptimalKTable offset:0 atIndex:3];
    
    if (self.computeKernelPassArg32) {
      if (renderFrame.out32Buff == nil) {
        const int numBytes = ((int) renderFrame.width * (int) renderFrame.height) * sizeof(uint32_t);
        
        renderFrame.out32Buff = [mrc.device newBufferWithLength:numBytes
                                                                   options:MTLResourceStorageModeShared];
      }
      
      [computeEncoder setBuffer:renderFrame.out32Buff offset:0 atIndex:4];
    }
    
    MTLSize threadgroupsPerGrid = self.threadgroupsPerGrid;
    MTLSize threadsPerThreadgroup = self.threadsPerThreadgroup;
    
    if (debug) {
      NSLog(@"renderRice2 threadgroup %d x %d", (int)threadsPerThreadgroup.width, (int)threadsPerThreadgroup.height);
      NSLog(@"renderRice2 grid %d x %d", (int)threadgroupsPerGrid.width, (int)threadgroupsPerGrid.height);
    }
    
#if defined(DEBUG)
    assert(threadgroupsPerGrid.width != 0);
#endif // DEBUG
    
    [computeEncoder dispatchThreadgroups:threadgroupsPerGrid
                   threadsPerThreadgroup:threadsPerThreadgroup];
    
    [computeEncoder popDebugGroup];
    
    [computeEncoder endEncoding];
  }
}

- (void) ensureBitsBuffCapacity:(MetalRenderContext*)mrc
                       numBytes:(int)numBytes
                    renderFrame:(MetalRice2RenderFrame*)renderFrame
{
  int currentNumBytes = (int) renderFrame.bitsBuff.length;
  if (numBytes > currentNumBytes) {
    renderFrame.bitsBuff = [mrc.device newBufferWithLength:numBytes options:MTLResourceStorageModeShared];
  }
}

@end
