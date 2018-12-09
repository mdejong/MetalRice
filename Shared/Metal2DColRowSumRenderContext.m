//
//  MetalPrefixSumRenderContext.m
//
//  Copyright 2016 Mo DeJong.
//
//  See LICENSE for terms.
//
//  This module references Metal objects that are used to render
//  2D sum across columns and rows. There is 1 render context
//  for N render frames.

#include "Metal2DColRowSumRenderContext.h"

// Header shared between C code here, which executes Metal API commands, and .metal files, which
//   uses these types as inpute to the shaders
#import "AAPLShaderTypes.h"

#import "MetalRenderContext.h"
#import "Metal2DColRowSumRenderFrame.h"

// Private API

@interface Metal2DColRowSumRenderContext ()

//@property (readonly) size_t numBytesAllocated;

@end

// Main class performing the rendering
@implementation Metal2DColRowSumRenderContext

// Setup render pixpelines

- (void) setupRenderPipelines:(MetalRenderContext*)mrc
{
  NSString *shader;
  
  shader = self.computeKernelFunction;
  
  if (self.bytesPerThread == 0) {
    self.bytesPerThread = 128 / 4; // 32 threads in threadgroup
  }
  
  if (shader == nil) {
    shader = @"kernel_column_row_sum_2D_bytes_dim1024_threads32";
  }
  
  // FIXME: no reason to pass MTLPixelFormatR8Unorm to compute pipeline
  
  self.computePipelineState = [mrc makePipeline:MTLPixelFormatR8Unorm
                                  pipelineLabel:@"2DColRowSum Pipeline"
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
                 renderFrame:(Metal2DColRowSumRenderFrame*)renderFrame
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
      NSLog(@"input        : texture %3d x %3d", (int)txt.width, (int)txt.height);
    }
  }

  // Output texture, note that a texture can be defined for the frame
  // already and in this case the existing ref is simply validated
  // without allocating another texture.
  
  {
    id<MTLTexture> txt = renderFrame.outputTexture;
    
    if (txt != nil) {
      NSAssert(txt.width == width4, @"inputTexture width must be %d, it was %d", width4, (int)txt.width);
      NSAssert(txt.height == height, @"inputTexture height must be %d, it was %d", height, (int)txt.height);
      NSAssert(txt.pixelFormat == MTLPixelFormatBGRA8Unorm, @"inputTexture must be BGRA format pixels");
    } else {
      txt = [mrc makeBGRATexture:CGSizeMake(width4, height) pixels:NULL usage:MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite];
      
      renderFrame.outputTexture = txt;
    }
    
    if (debug) {
      NSLog(@"output      : texture %3d x %3d", (int)txt.width, (int)txt.height);
    }
  }
  
  // Compute threadgroup parameters
  
  int numBlocks = numBlocksInWidth * numBlocksInHeight;
  assert(numBlocks != 0);
  
  int numBytes = (width * height);
  
  // A block corresponds to one threadgroup
  
  // The number of threadgroups in the grid, in each dimension.
  MTLSize threadgroupsPerGrid;
  threadgroupsPerGrid.width = numBlocksInWidth;
  threadgroupsPerGrid.height = numBlocksInHeight;
  threadgroupsPerGrid.depth = 1;
  
  int numBytesEachThread = (int) self.bytesPerThread;
  int numBytesInEachThreadgroup = (int) (numBytes / numBlocks);
  int numThreadsEachThreadgroup = (int) (numBytesInEachThreadgroup / numBytesEachThread);
  
  {
    BOOL isPOT = (numThreadsEachThreadgroup & (numThreadsEachThreadgroup - 1)) == 0;
    assert(isPOT);
  }

  // The number of threads in one threadgroup, in each dimension.
  MTLSize threadsPerThreadgroup;
  /*
  if (numThreadsEachThreadgroup == 1) {
    threadsPerThreadgroup.width = 1;
    threadsPerThreadgroup.height = 1;
  } else {
    // One thread for each uchar4
    threadsPerThreadgroup.width = numThreadsEachThreadgroup / 2;
    threadsPerThreadgroup.height = numThreadsEachThreadgroup / 2;
  }
  */
  threadsPerThreadgroup.width = numThreadsEachThreadgroup; // One thread for each uchar4, else 1 to 1
  threadsPerThreadgroup.height = 1;
  threadsPerThreadgroup.depth = 1;
  
  if (debug) {
    NSLog(@"threadsPerThreadgroup : texture %3d x %3d : %d threads", (int)threadsPerThreadgroup.width, (int)threadsPerThreadgroup.height, (int)threadsPerThreadgroup.width*(int)threadsPerThreadgroup.height);
    NSLog(@"threadgroupsPerGrid   : texture %3d x %3d", (int)threadgroupsPerGrid.width, (int)threadgroupsPerGrid.height);
  }
  
  self.threadgroupsPerGrid = threadgroupsPerGrid;
  self.threadsPerThreadgroup = threadsPerThreadgroup;
  
  int blockDim4 = (int)threadsPerThreadgroup.width * (int)threadsPerThreadgroup.height;
  int gridDim4 = (int)threadgroupsPerGrid.width * (int)threadgroupsPerGrid.height;
  
  assert((blockDim4 * gridDim4 * numBytesEachThread) == numBytes);
  
  /*
  
  // Dimensions passed into shaders
  
  renderFrame.renderTargetDimensionsAndBlockDimensionsUniform = [mrc.device newBufferWithLength:sizeof(RenderTargetDimensionsAndBlockDimensionsUniform) options:MTLResourceStorageModeShared];
  
  {
    RenderTargetDimensionsAndBlockDimensionsUniform *ptr = renderFrame.renderTargetDimensionsAndBlockDimensionsUniform.contents;
    // pass numBlocksInWidth
    ptr->width = renderFrame.numBlocksInWidth;
    // pass numBlocksInHeight
    ptr->height = renderFrame.numBlocksInHeight;
    // pass (blockSide * blockSide) as a POT
    ptr->blockWidth = renderFrame.blockDim;
    ptr->blockHeight = renderFrame.blockDim;
  }
  
  */
   
  return;
}

#if defined(DEBUG)

#endif // DEBUG

- (void) renderColRowSum:(MetalRenderContext*)mrc
           commandBuffer:(id<MTLCommandBuffer>)commandBuffer
             renderFrame:(Metal2DColRowSumRenderFrame*)renderFrame
{
  const BOOL debug = FALSE;
  
  // 2D input and output textures
  
  id<MTLTexture> inputTexture = renderFrame.inputTexture;
  id<MTLTexture> outputTexture = renderFrame.outputTexture;
  
#if defined(DEBUG)
  // Input and Output buffers must be the exact same length
  
  int numBytes = (int) renderFrame.width * (int) renderFrame.height;
  
  if (debug) {
    printf("render2DPrefixSum %d x %d : %d bytes\n", (int)renderFrame.width, (int)renderFrame.height, numBytes);
    printf("render2DPrefixSum BGRA texture %d x %d\n", (int)inputTexture.width, (int)inputTexture.height);
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
    
    NSString *debugLabel = @"2DColRowSum";
    computeEncoder.label = debugLabel;
    [computeEncoder pushDebugGroup:debugLabel];
    
    [computeEncoder setComputePipelineState:self.computePipelineState];
    
    [computeEncoder setTexture:inputTexture atIndex:0];
    
    [computeEncoder setTexture:outputTexture atIndex:1];
    
    MTLSize threadgroupsPerGrid = self.threadgroupsPerGrid;
    MTLSize threadsPerThreadgroup = self.threadsPerThreadgroup;
    
    if (debug) {
      NSLog(@"render2DPrefixSum threadgroup %d x %d", (int)threadsPerThreadgroup.width, (int)threadsPerThreadgroup.height);
      NSLog(@"render2DPrefixSum grid %d x %d", (int)threadgroupsPerGrid.width, (int)threadgroupsPerGrid.height);
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

@end
