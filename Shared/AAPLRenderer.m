/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Implementation of renderer class which perfoms Metal setup and per frame rendering
*/

@import simd;
@import MetalKit;

#import "AAPLRenderer.h"
#import "AAPLImage.h"

// Header shared between C code here, which executes Metal API commands, and .metal files, which
//   uses these types as inpute to the shaders
#import "AAPLShaderTypes.h"

#import <CoreVideo/CoreVideo.h>

#import "Rice.h"

#import "InputImageRenderFrame.h"

//#import "Util.h"

#import "CGFrameBuffer.h"
#import "ImageData.h"

#import "MetalRenderContext.h"

#import "MetalRice2RenderContext.h"
#import "MetalRice2RenderFrame.h"

#import "MetalCropToTextureRenderContext.h"
#import "MetalCropToTextureRenderFrame.h"

#import "CombinedMetalRiceRenderFrame.h"

const static unsigned int blockDim = RICE_SMALL_BLOCK_DIM;

// The max number of command buffers in flight
#define MetalRenderContextMaxBuffersInFlight (3)

@interface AAPLRenderer ()

@property (nonatomic, retain) InputImageRenderFrame *inputImageRenderFrame;

@property (nonatomic, retain) MetalRenderContext *metalRenderContext;

@property (nonatomic, retain) MetalRice2RenderContext *metalRiceRenderContext;
@property (nonatomic, retain) MetalCropToTextureRenderContext *metalCropToTextureRenderContext;

@property (nonatomic, retain) NSMutableArray<CombinedMetalRiceRenderFrame*> *combinedFrames;

@property (nonatomic, retain) dispatch_semaphore_t inFlightSemaphore;

@property (nonatomic, assign) int renderFrameOffset;

@end

// Main class performing the rendering
@implementation AAPLRenderer
{
    // The device (aka GPU) we're using to render
    id <MTLDevice> _device;
  
#if defined(DEBUG)
#endif // DEBUG
  
    // Our render pipeline composed of our vertex and fragment shaders in the .metal shader file
    id<MTLRenderPipelineState> _renderFromTexturePipelineState;
  
    // The current size of our view so we can use this in our render pipeline
    vector_uint2 _viewportSize;
  
    int isCaptureRenderedTextureEnabled;

  NSData *_imageInputBytes;

  NSData *_blockByBlockReorder;

  NSData *_outBlockOrderSymbolsData;

  NSData *_blockInitData;
  
  NSMutableData *_blockOptimalKTable;
  NSMutableData *_halfBlockOptimalKTable;
  
  NSMutableData *_encodedRice2Bits;
  NSMutableData *_halfBlockOffsetTableData;
  
  int renderWidth;
  int renderHeight;
  
  int renderBlockWidth;
  int renderBlockHeight;
}

+ (NSString*) getResourcePath:(NSString*)resFilename
{
  NSBundle* appBundle = [NSBundle mainBundle];
  NSString* movieFilePath = [appBundle pathForResource:resFilename ofType:nil];
  NSAssert(movieFilePath, @"movieFilePath is nil");
  return movieFilePath;
}

// Query pixel contents of a texture and return as uint32_t
// values in a NSData*.

+ (NSData*) getTexturePixels:(id<MTLTexture>)texture
{
  // Copy texture data into debug framebuffer, note that this include 2x scale
  
  int width = (int) texture.width;
  int height = (int) texture.height;
  
  NSMutableData *mFramebuffer = [NSMutableData dataWithLength:width*height*sizeof(uint32_t)];
  
  [texture getBytes:(void*)mFramebuffer.mutableBytes
        bytesPerRow:width*sizeof(uint32_t)
      bytesPerImage:width*height*sizeof(uint32_t)
         fromRegion:MTLRegionMake2D(0, 0, width, height)
        mipmapLevel:0
              slice:0];
  
  return [NSData dataWithData:mFramebuffer];
}

- (void) setupRiceEncoding
{
  unsigned int width = self->renderWidth;
  unsigned int height = self->renderHeight;
  
  unsigned int blockWidth = self->renderBlockWidth;
  unsigned int blockHeight = self->renderBlockHeight;
  
  if ((0)) {
        printf("image order for %5d x %5d image\n", width, height);
      
      uint8_t* inBytes = (uint8_t*)_imageInputBytes.bytes;
      
        for ( int row = 0; row < height; row++ ) {
          for ( int col = 0; col < width; col++ ) {
              uint8_t byteVal = inBytes[(row * width) + col];
              printf("0x%02X ", byteVal);
          }
            
          printf("\n");
        }
        
        printf("image order done\n");
    }
  
  // To encode symbols with huffman block encoding, the order of the symbols
  // needs to be broken up so that the input ordering is in terms of blocks and
  // the partial blocks are handled in a way that makes it possible to process
  // the data with the shader. Note that this logic will split into fixed block
  // size with zero padding, so the output would need to be reordered back to
  // image order and then trimmed to width and height in order to match.
  
  int outBlockOrderSymbolsNumBytes = (blockDim * blockDim) * (blockWidth * blockHeight);
  
  const int numBlocks = blockWidth * blockHeight;
  
  // The blockOptimalKTableData contains an entry for each block and it also
  // includes an entry for each block that the base values would be broken
  // down into. This is tricky since the number of base values may not
  // be a multiple of the block length - 1.
    
    NSMutableData *blockOptimalKTableData = [NSMutableData data];
    
    //int blockOptimalNumBytesTable[numBlocks];
    
    // Format input pixels into blocks of blockDim x blockDim
    
    NSMutableData *outBlockOrderSymbolsData = [NSMutableData data];
    
    // Block deltas for 32x32 blocks, then reorder as 8x8 blocks for rice optimization

    // Dual stage block delta encoding, calculate deltas based on 32x32 blocks
    // and then split into 8x8 rice opt blocks.
    
    int numBigBlocksInWidth = blockWidth / 4;
    assert(numBigBlocksInWidth > 0);
    assert((blockWidth % 4) == 0);
  
    int numBigBlocksInHeight = blockHeight / 4;
    assert(numBigBlocksInHeight > 0);
    assert((blockHeight % 4) == 0);
  
    [Rice blockDeltaEncoding2Stage:(uint8_t*)_imageInputBytes.bytes
             inNumBytes:(int)_imageInputBytes.length
                  width:width
                 height:height
             blockWidth:numBigBlocksInWidth
            blockHeight:numBigBlocksInHeight
   outEncodedBlockBytes:outBlockOrderSymbolsData];

    assert(outBlockOrderSymbolsData.length == (numBigBlocksInWidth * numBigBlocksInHeight * RICE_LARGE_BLOCK_DIM * RICE_LARGE_BLOCK_DIM));
  const uint8_t *outBlockOrderSymbolsPtr = (uint8_t *) outBlockOrderSymbolsData.mutableBytes;

  _outBlockOrderSymbolsData = [NSData dataWithData:outBlockOrderSymbolsData];

  // Rice opt table calc
  
  int outNumBaseValues = 0;
  int outNumBlockValues = (int)outBlockOrderSymbolsData.length;
    
  [Rice optRiceK:outBlockOrderSymbolsData
blockOptimalKTableData:blockOptimalKTableData
   numBaseValues:&outNumBaseValues
  numBlockValues:&outNumBlockValues];

  // Save blockOptimalKTableData
  
  _blockOptimalKTable = [NSMutableData dataWithData:blockOptimalKTableData];
  
  if ((0)) {
    printf("deltas block order\n");
    
    for ( int blocki = 0; blocki < (blockWidth * blockHeight); blocki++ ) {
      printf("block %5d : ", blocki);
      
      const uint8_t *blockStartPtr = outBlockOrderSymbolsPtr + (blocki * (blockDim * blockDim));
      
      for (int i = 0; i < (blockDim * blockDim); i++) {
        printf("%5d ", blockStartPtr[i]);
      }
      printf("\n");
    }
    
    printf("deltas block order done\n");
  }
    
#if defined(DEBUG)
    if ((1)) {
        NSString *tmpDir = NSTemporaryDirectory();
        NSString *path = [tmpDir stringByAppendingPathComponent:@"block_deltas.bytes"];
        BOOL worked = [outBlockOrderSymbolsData writeToFile:path atomically:TRUE];
        assert(worked);
        NSLog(@"wrote %@ as %d bytes", path, (int)outBlockOrderSymbolsData.length);
    }
  
    if ((1)) {
        NSString *tmpDir = NSTemporaryDirectory();
        NSString *path = [tmpDir stringByAppendingPathComponent:@"block_deltas.png"];
        
        NSMutableArray *mArr = [NSMutableArray array];
        
        uint8_t *ptr = (uint8_t *) outBlockOrderSymbolsData.bytes;
        
        for (int i = 0; i < outBlockOrderSymbolsData.length; i++) {
            uint8_t bVal = ptr[i];
            [mArr addObject:@(bVal)];
        }
        
        [ImageData dumpArrayOfGrayscale:mArr width:blockWidth filename:path];
    }
    
  // Dump optimal k for block table, this is a table of byte values

  if ((1)) {
    // Note that there is 1 additional k value at the end of the table that corresponds to all the block base values
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *path = [tmpDir stringByAppendingPathComponent:@"block_optimal_k.bytes"];
    [blockOptimalKTableData writeToFile:path atomically:TRUE];
    NSLog(@"wrote %@ as %d bytes", path, (int)blockOptimalKTableData.length);
  }
    
    if ((1)) {
        NSString *tmpDir = NSTemporaryDirectory();
        NSString *path = [tmpDir stringByAppendingPathComponent:@"block_optimal_k.png"];
        
        NSMutableArray *mArr = [NSMutableArray array];
        
        uint8_t *ptr = (uint8_t *) blockOptimalKTableData.bytes;
        
        for (int i = 0; i < blockOptimalKTableData.length; i++) {
            uint8_t bVal = ptr[i];
            [mArr addObject:@(bVal)];
        }
        
        [ImageData dumpArrayOfGrayscale:mArr width:blockWidth filename:path];
    }
#endif // DEBUG

  // number of blocks must be an exact multiple of the block dimension
  
  assert((outBlockOrderSymbolsNumBytes % (blockDim * blockDim)) == 0);
  
  _encodedRice2Bits = [NSMutableData data];
  _halfBlockOffsetTableData = [NSMutableData data];
  
  // In rice bytes (data sent to encoder)
  
  if ((1)) {
    printf("in     num bytes  %8d\n", outBlockOrderSymbolsNumBytes);
    printf("numBlocks  %8d : %d x %d\n", (int)numBlocks, blockWidth, blockHeight);
  }
  
  int blockN = blockWidth * blockHeight;
  
  // Note that width and height are passed in terms of the zero padded size here.
  
  [Rice encodeRice2Stream:_outBlockOrderSymbolsData
                   blockN:blockN
                    width:blockWidth*blockDim
                   height:blockHeight*blockDim
        riceEncodedStream:_encodedRice2Bits
       blockOptimalKTable:_blockOptimalKTable
   halfBlockOptimalKTable:_halfBlockOptimalKTable
     halfBlockOffsetTable:_halfBlockOffsetTableData];

  // Out num rice bytes combines prefix and suffix in a single stream of bits
    
  if ((1)) {
    printf("in     num bytes  %8d\n", outBlockOrderSymbolsNumBytes);
    printf("rice   num bytes  %8d\n", (int)_encodedRice2Bits.length);
  }
  
  if ((1)) {
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *path = [tmpDir stringByAppendingPathComponent:@"block_encoded_rice_bits.bytes"];
    [_encodedRice2Bits writeToFile:path atomically:TRUE];
    NSLog(@"wrote %@ as %d bytes", path, (int)_encodedRice2Bits.length);
  }
  
  uint8_t *encodedRiceBytesPtr = _encodedRice2Bits.mutableBytes;
  int encodedRiceBytesNumBytes = (int) _encodedRice2Bits.length;
  
  // Allocate a buffer large enough to contain the suffix bit buffer as bytes for each frame
  
  for (int i = 0; i < MetalRenderContextMaxBuffersInFlight; i++) {
    CombinedMetalRiceRenderFrame *combinedRenderFrame = self.combinedFrames[i];
    
    assert(self.metalRiceRenderContext);
    
    [self.metalRiceRenderContext ensureBitsBuffCapacity:self.metalRenderContext
                                               numBytes:encodedRiceBytesNumBytes
                                            renderFrame:combinedRenderFrame.metalRiceRenderFrame];
  }
    
  if ((0)) {
    // Encoded rice symbols as hex?
    
    fprintf(stdout, "encodedRiceBytes\n");
    
    for (int i = 0; i < encodedRiceBytesNumBytes; i++) {
      int symbol = encodedRiceBytesPtr[i];
      
      fprintf(stdout, "%2X \n", symbol);
    }
    
    fprintf(stdout, "done encodedRiceBytes\n");
  }
  
  return;
}

// Initialize with the MetalKit view from which we'll obtain our metal device

- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView
{
    self = [super init];
    if(self)
    {
      isCaptureRenderedTextureEnabled = 0;
      
      mtkView.depthStencilPixelFormat = MTLPixelFormatInvalid;
      
      mtkView.preferredFramesPerSecond = 30;
      
      _device = mtkView.device;

      if (isCaptureRenderedTextureEnabled) {
        mtkView.framebufferOnly = false;
      }
      
      self.metalRenderContext = [[MetalRenderContext alloc] init];
      
      self.metalRiceRenderContext = [[MetalRice2RenderContext alloc] init];
      
      self.metalCropToTextureRenderContext = [[MetalCropToTextureRenderContext alloc] init];
      
      [self.metalRenderContext setupMetal:_device];

      [self.metalRiceRenderContext setupRenderPipelines:self.metalRenderContext];
      
      [self.metalCropToTextureRenderContext setupRenderPipelines:self.metalRenderContext];
      
      self.inFlightSemaphore = dispatch_semaphore_create(MetalRenderContextMaxBuffersInFlight);
      
      self.combinedFrames = [NSMutableArray array];
      self.renderFrameOffset = -1;
      
      for (int i = 0; i < MetalRenderContextMaxBuffersInFlight; i++) {
        CombinedMetalRiceRenderFrame *combinedRenderFrame = [[CombinedMetalRiceRenderFrame alloc] init];
        
        combinedRenderFrame.metalCropToTextureRenderFrame = [[MetalCropToTextureRenderFrame alloc] init];
        combinedRenderFrame.metalRiceRenderFrame = [[MetalRice2RenderFrame alloc] init];
        
        [self.combinedFrames addObject:combinedRenderFrame];
      }
      
      // Query size and byte data for input frame that will be rendered
      
      InputImageRenderFrameConfig hcfg;
      
//      hcfg = TEST_4x4_INCREASING1;
//      hcfg = TEST_4x4_INCREASING2;
//      hcfg = TEST_4x8_INCREASING1;
//      hcfg = TEST_2x8_INCREASING1;
//      hcfg = TEST_6x4_NOT_SQUARE;
//      hcfg = TEST_8x8_IDENT;
//      hcfg = TEST_16x8_IDENT;
//      hcfg = TEST_16x16_IDENT;
//      hcfg = TEST_16x16_IDENT1;
//      hcfg = TEST_16x16_IDENT2;
//      hcfg = TEST_16x16_IDENT3;
      
//      hcfg = TEST_16x16_DELTA_IDENT;
//      hcfg = TEST_32x32_DELTA_IDENT;
      
//      hcfg = TEST_8x8_IDENT_2048;
//      hcfg = TEST_8x8_IDENT_4096;

      //hcfg = TEST_LARGE_RANDOM;
      //hcfg = TEST_IMAGE1;
      //hcfg = TEST_IMAGE2;
      //hcfg = TEST_IMAGE3;
      hcfg = TEST_IMAGE4;  // 3145728 -> 1687605
      //hcfg = TEST_IMAGE_LENNA_B;   // 262144 -> 178570
      
      InputImageRenderFrame *renderFrame = [InputImageRenderFrame renderFrameForConfig:hcfg];
      
      self.inputImageRenderFrame = renderFrame;
      
      unsigned int width = renderFrame.renderWidth;
      unsigned int height = renderFrame.renderHeight;
      
      unsigned int blockWidth = width / blockDim;
      if ((width % blockDim) != 0) {
        blockWidth += 1;
      }
      
      unsigned int blockHeight = height / blockDim;
      if ((height % blockDim) != 0) {
        blockHeight += 1;
      }
      
      self->renderWidth = width;
      self->renderHeight = height;
      
      // If blockWidth x blockHeight is not as exact multiple
      // of 16 blocks (this is 4 x 4 blocks in a big block)
      // then determine how many padding blocks are nedded
      // for the rice encoding so that all input
      // streams are the same lenght.

      const int minNumBlocksInBigBlockDim = 4;
      const int minNumBlocksInBigBlock = (minNumBlocksInBigBlockDim * minNumBlocksInBigBlockDim);
      int numBlocksOver = (blockWidth * blockHeight) % minNumBlocksInBigBlock;
      
      if (numBlocksOver > 0) {
        // Expand a non-multiple of 4 width until it is a multiple of 4
        
        while ((blockWidth % minNumBlocksInBigBlockDim) != 0) {
          blockWidth++;
        }
        while ((blockHeight % minNumBlocksInBigBlockDim) != 0) {
          blockHeight++;
        }

        assert((blockWidth % minNumBlocksInBigBlockDim) == 0);
        assert((blockHeight % minNumBlocksInBigBlockDim) == 0);
        assert(((blockWidth * blockHeight) % minNumBlocksInBigBlock) == 0);
      }
      
      // In the case where a 4x stream
      
      renderFrame.renderBlockWidth = blockWidth;
      renderFrame.renderBlockHeight = blockHeight;
      
      self->renderBlockWidth = blockWidth;
      self->renderBlockHeight = blockHeight;
      
      // Init rice render frame in terms of 8x8 blocks
      
      {
        assert(renderFrame);
        
        // Note that the width and height here is in terms of big blocks, in
        // int the case that the image is smaller than one big block then
        // additional zero padding is required to adjust to the min block size.
        
        int bigBlockWidth = renderFrame.renderBlockWidth * blockDim;
        int bigBlockHeight = renderFrame.renderBlockHeight * blockDim;
        
        CGSize renderSize = CGSizeMake(bigBlockWidth, bigBlockHeight);
        CGSize blockSize = CGSizeMake(blockDim, blockDim);
        
        for (int i = 0; i < MetalRenderContextMaxBuffersInFlight; i++) {
          CombinedMetalRiceRenderFrame *combinedRenderFrame = self.combinedFrames[i];
          
          [self.metalRiceRenderContext setupRenderTextures:self.metalRenderContext
                                                renderSize:renderSize
                                                 blockSize:blockSize
                                               renderFrame:combinedRenderFrame.metalRiceRenderFrame];
        }
      }
            
      // Init crop render frame in terms of 8x8 blocks
      
      {
        int width = renderFrame.renderWidth;
        int height = renderFrame.renderHeight;
        
        int bigBlockWidth = renderFrame.renderBlockWidth * blockDim;
        int bigBlockHeight = renderFrame.renderBlockHeight * blockDim;
        
        CGSize renderSize = CGSizeMake(width, height);
        CGSize cropFromSize = CGSizeMake(bigBlockWidth, bigBlockHeight);
        CGSize blockSize = CGSizeMake(blockDim, blockDim);
        
        for (int i = 0; i < MetalRenderContextMaxBuffersInFlight; i++) {
          CombinedMetalRiceRenderFrame *combinedRenderFrame = self.combinedFrames[i];
          
          combinedRenderFrame.metalCropToTextureRenderFrame.inputTexture = combinedRenderFrame.metalRiceRenderFrame.outputTexture;
          
          [self.metalCropToTextureRenderContext setupRenderTextures:self.metalRenderContext
                                                         renderSize:renderSize
                                                       cropFromSize:cropFromSize
                                                          blockSize:blockSize
                                                        renderFrame:combinedRenderFrame.metalCropToTextureRenderFrame];
        }
      }
      
        NSError *error = NULL;
      
      id<MTLLibrary> defaultLibrary = self.metalRenderContext.defaultLibrary;

      {
        // Render to texture pipeline
        
        // Load the vertex function from the library
        id <MTLFunction> vertexFunction = [defaultLibrary newFunctionWithName:@"vertexShader"];

        // Load the fragment function from the library
        id <MTLFunction> fragmentFunction = [defaultLibrary newFunctionWithName:@"samplingPassThroughShader"];
      
      {
        // Set up a descriptor for creating a pipeline state object
        MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
        pipelineStateDescriptor.label = @"Render From Texture Pipeline";
        pipelineStateDescriptor.vertexFunction = vertexFunction;
        pipelineStateDescriptor.fragmentFunction = fragmentFunction;
        pipelineStateDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat;
        //pipelineStateDescriptor.stencilAttachmentPixelFormat =  mtkView.depthStencilPixelFormat; // MTLPixelFormatStencil8
        
        _renderFromTexturePipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                                                                 error:&error];
        if (!_renderFromTexturePipelineState)
        {
          // Pipeline State creation could fail if we haven't properly set up our pipeline descriptor.
          //  If the Metal API validation is enabled, we can find out more information about what
          //  went wrong.  (Metal API validation is enabled by default when a debug build is run
          //  from Xcode)
          NSLog(@"Failed to created pipeline state, error %@", error);
        }
      }
      }
      
      _imageInputBytes = renderFrame.inputData;
      
      [self setupRiceEncoding];
      
    } // end of init if block
  
    return self;
}

/// Called whenever view changes orientation or is resized
- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size
{
    // Save the size of the drawable as we'll pass these
    //   values to our vertex shader when we draw
    _viewportSize.x = size.width;
    _viewportSize.y = size.height;
}

/// Called whenever the view needs to render a frame
- (void)drawInMTKView:(nonnull MTKView *)view
{
  const BOOL debugDisplayFrameNumber = TRUE;
  
  CFTimeInterval debugDisplayFrameStartTime;
  
  if (debugDisplayFrameNumber) {
    debugDisplayFrameStartTime = CACurrentMediaTime();
  }
  
    //return;
  
  int blockWidth = self->renderBlockWidth;
  int blockHeight = self->renderBlockHeight;
  const int numBlocks = blockWidth * blockHeight;
  
  // Decode from prefix encoded bits and write output to Metal byte buffer
  
  int blockOrderSymbolsNumBytes = (blockDim * blockDim) * numBlocks;

  // Wait to ensure only MetalRenderContextMaxBuffersInFlight are getting proccessed by any stage
  // in the Metal pipeline (App, Metal, Drivers, GPU, etc)
  
  dispatch_semaphore_t inFlightSemaphore = self.inFlightSemaphore;
  dispatch_semaphore_wait(inFlightSemaphore, DISPATCH_TIME_FOREVER);
  
  // First invocation grabs self.combinedFrames[0]
  int asyncDecodeFrameOffset = self.renderFrameOffset + 1;
  asyncDecodeFrameOffset = (asyncDecodeFrameOffset % MetalRenderContextMaxBuffersInFlight);
  self.renderFrameOffset = asyncDecodeFrameOffset;
  CombinedMetalRiceRenderFrame *combinedRenderFrame = self.combinedFrames[asyncDecodeFrameOffset];
  
  if (debugDisplayFrameNumber) {
    printf("drawInMTKView frame[%3d]\n", asyncDecodeFrameOffset);
  }
  
  assert(combinedRenderFrame);
  assert(combinedRenderFrame.metalRiceRenderFrame);
  assert(combinedRenderFrame.metalCropToTextureRenderFrame);
  
  // Copy rice encoded bits into Metal buffer
  
  {
    id<MTLBuffer> bitsBuff = combinedRenderFrame.metalRiceRenderFrame.bitsBuff;
    assert(bitsBuff);
    uint8_t *outBitsBuffPtr = (uint8_t *) bitsBuff.contents;
    uint8_t *inBitsBuffPtr = (uint8_t *) _encodedRice2Bits.bytes;
    
    int inNumBytes = (int) bitsBuff.length;
    int outNumBytes = (int) _encodedRice2Bits.length;
    assert(inNumBytes == outNumBytes);
    memcpy(outBitsBuffPtr, inBitsBuffPtr, outNumBytes);
  }
  
  {
    // RiceRenderUniform
    
    assert(combinedRenderFrame.metalRiceRenderFrame.riceRenderUniform.length == sizeof(RiceRenderUniform));
    
    RiceRenderUniform *riceRenderUniformPtr = (RiceRenderUniform*) combinedRenderFrame.metalRiceRenderFrame.riceRenderUniform.contents;
    
    riceRenderUniformPtr->numBlocksInWidth = blockWidth;
    riceRenderUniformPtr->numBlocksInHeight = blockHeight;
  }
  
  // Copy block start bit table into current Metal output frame

  {
    int numOffsetsToCopy = (blockWidth * blockHeight) * 2;
    
    uint32_t *bitOffsetTableOutPtr = (uint32_t *) combinedRenderFrame.metalRiceRenderFrame.blockOffsetTableBuff.contents;
    uint32_t *bitOffsetTableInPtr = (uint32_t *) _halfBlockOffsetTableData.bytes;
    
    assert(_halfBlockOffsetTableData.length/sizeof(uint32_t) == numOffsetsToCopy);
    
    for (int i = 0; i < numOffsetsToCopy; i++) {
      uint32_t bitOffset = bitOffsetTableInPtr[i];
      bitOffsetTableOutPtr[i] = bitOffset;
    }
  }
  
  // Copy K table into Metal buffer
  
  {
    id<MTLBuffer> blockOptimalKTable = combinedRenderFrame.metalRiceRenderFrame.blockOptimalKTable;
    
    uint8_t *inPtr = (uint8_t *) _blockOptimalKTable.bytes;
    uint8_t *outPtr = (uint8_t *) blockOptimalKTable.contents;
    int inNumBytes = (int) _blockOptimalKTable.length;
    int outNumBytes = (int) blockOptimalKTable.length;
    assert(inNumBytes == outNumBytes);
    memcpy(outPtr, inPtr, outNumBytes);
  }
  
  
  // Create a new command buffer
  
  id <MTLCommandBuffer> commandBuffer = [self.metalRenderContext.commandQueue commandBuffer];
  commandBuffer.label = @"RenderBGRACommand";
  
  // Release semaphore
  
  __block dispatch_semaphore_t block_sema = inFlightSemaphore;
  
  [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer){
    dispatch_semaphore_signal(block_sema);
    
//#if defined(DEBUG)
    if (debugDisplayFrameNumber) {
      CFTimeInterval debugDisplayFrameEndTime;
      
      debugDisplayFrameEndTime = CACurrentMediaTime();
      
      CFTimeInterval elapsed = (debugDisplayFrameEndTime-debugDisplayFrameStartTime) * 1000;
      
      printf("Finished Metal render for frame %3d : render ms %.2f\n", asyncDecodeFrameOffset, elapsed);
    }
//#endif // DEBUG
  }];

  // Render
  
  [self.metalRiceRenderContext renderRice:self.metalRenderContext commandBuffer:commandBuffer renderFrame:combinedRenderFrame.metalRiceRenderFrame];

  id<MTLTexture> _render_texture = combinedRenderFrame.metalCropToTextureRenderFrame.outputTexture;

  // Crop copy and expand grayscale values packed into BGRA pixels to BGRA grayscale at 32bpp for each pixel
  
  [self.metalCropToTextureRenderContext renderCropToTexture:self.metalRenderContext commandBuffer:commandBuffer renderFrame:combinedRenderFrame.metalCropToTextureRenderFrame];
  
  // Render from 32BPP _render_texture into output view
  
  // Obtain a renderPassDescriptor generated from the view's drawable textures
  MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;
  
  if(renderPassDescriptor != nil)
  {
    // Create a render command encoder so we can render into something
    id <MTLRenderCommandEncoder> renderEncoder =
    [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    renderEncoder.label = @"RenderBGRACommandEncoder";
    
    [renderEncoder pushDebugGroup: @"RenderFromTexture"];
    
    // Set the region of the drawable to which we'll draw.
    MTLViewport mtlvp = {0.0, 0.0, _viewportSize.x, _viewportSize.y, -1.0, 1.0 };
    [renderEncoder setViewport:mtlvp];
    
    [renderEncoder setRenderPipelineState:_renderFromTexturePipelineState];
    
    [renderEncoder setVertexBuffer:self.metalRenderContext.identityVerticesBuffer
                            offset:0
                           atIndex:AAPLVertexInputIndexVertices];
    
    [renderEncoder setFragmentTexture:_render_texture
                              atIndex:AAPLTextureIndexes];
    
    // Draw the 3 vertices of our triangle
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                      vertexStart:0
                      vertexCount:self.metalRenderContext.identityNumVertices];
    
    [renderEncoder popDebugGroup]; // RenderFromTexture
    
    [renderEncoder endEncoding];
    
    // Schedule a present once the framebuffer is complete using the current drawable
    [commandBuffer presentDrawable:view.currentDrawable];
    
    if (isCaptureRenderedTextureEnabled) {
      // Finalize rendering here & push the command buffer to the GPU
      [commandBuffer commit];
      [commandBuffer waitUntilCompleted];
    }
    
    // Print output of render pass in stages
    
    const int assertOnValueDiff = 1;
    
    // Capture the render to texture state at the render to size
    if (isCaptureRenderedTextureEnabled) {
      // Query output texture
      
      id<MTLTexture> outTexture = _render_texture;
      
      // Copy texture data into debug framebuffer, note that this include 2x scale
      
      int width = (int) outTexture.width;
      int height = (int) outTexture.height;
      
      NSData *pixelsData = [self.class getTexturePixels:outTexture];
      uint32_t *pixelsPtr = ((uint32_t*) pixelsData.bytes);
      
      // Dump output words as BGRA
      
      if ((0)) {
        // Dump 24 bit values as int
        
        fprintf(stdout, "_render_texture\n");
        
        for ( int row = 0; row < height; row++ ) {
          for ( int col = 0; col < width; col++ ) {
            int offset = (row * width) + col;
            //uint32_t v = pixelsPtr[offset] & 0x00FFFFFF;
            //fprintf(stdout, "%5d ", v);
            //fprintf(stdout, "%6X ", v);
            uint32_t v = pixelsPtr[offset];
            fprintf(stdout, "0x%08X ", v);
          }
          fprintf(stdout, "\n");
        }
        
        fprintf(stdout, "done\n");
      }

      if ((0)) {
        // Dump 8bit B comp as int
        
        fprintf(stdout, "_render_texture\n");
        
        for ( int row = 0; row < height; row++ ) {
          for ( int col = 0; col < width; col++ ) {
            int offset = (row * width) + col;
            //uint32_t v = pixelsPtr[offset] & 0x00FFFFFF;
            //fprintf(stdout, "%5d ", v);
            //fprintf(stdout, "%6X ", v);
            uint32_t v = pixelsPtr[offset] & 0xFF;
            //fprintf(stdout, "0x%08X ", v);
            fprintf(stdout, "%3d ", v);
          }
          fprintf(stdout, "\n");
        }
        
        fprintf(stdout, "done\n");
      }
      
      if ((0)) {
        // Dump 24 bit values as int
        
        fprintf(stdout, "expected symbols\n");
        
        NSData *expectedData = _imageInputBytes;
        assert(expectedData);
        uint8_t *expectedDataPtr = (uint8_t *) expectedData.bytes;
        //const int numBytes = (int)expectedData.length * sizeof(uint8_t);
        
        for ( int row = 0; row < height; row++ ) {
          for ( int col = 0; col < width; col++ ) {
            int offset = (row * width) + col;
            //int v = expectedDataPtr[offset];
            //fprintf(stdout, "%6X ", v);
            
            uint32_t v = expectedDataPtr[offset] & 0xFF;
            fprintf(stdout, "%3d ", v);
          }
          fprintf(stdout, "\n");
        }
        
        fprintf(stdout, "done\n");
      }
      
      // Compare output to expected output
      
      if ((1)) {
        NSData *expectedData = _imageInputBytes;
        assert(expectedData);
        uint8_t *expectedDataPtr = (uint8_t *) expectedData.bytes;
        const int numBytes = (int)expectedData.length * sizeof(uint8_t);
        
        uint32_t *renderedPixelPtr = pixelsPtr;
        
        for ( int row = 0; row < height; row++ ) {
          for ( int col = 0; col < width; col++ ) {
            int offset = (row * width) + col;
            
            int expectedSymbol = expectedDataPtr[offset]; // read byte
            int renderedSymbol = renderedPixelPtr[offset] & 0xFF; // compare to just the B component
            
            if (renderedSymbol != expectedSymbol) {
              printf("renderedSymbol != expectedSymbol : %3d != %3d at (X,Y) (%3d,%3d) offset %d\n", renderedSymbol, expectedSymbol, col, row, offset);
              
              if (assertOnValueDiff) {
                assert(0);
              }

            }
          }
        }
        
        assert(numBytes == (width * height));
      }
      
      // end of capture logic
    }
    
    // Get pixel out of outTexture ?
    
    if (isCaptureRenderedTextureEnabled) {
      // Query output texture after resize
      
      id<MTLTexture> outTexture = renderPassDescriptor.colorAttachments[0].texture;
      
      // Copy texture data into debug framebuffer, note that this include 2x scale
      
      int width = _viewportSize.x;
      int height = _viewportSize.y;
      
      NSMutableData *mFramebuffer = [NSMutableData dataWithLength:width*height*sizeof(uint32_t)];
      
      [outTexture getBytes:(void*)mFramebuffer.mutableBytes
               bytesPerRow:width*sizeof(uint32_t)
             bytesPerImage:width*height*sizeof(uint32_t)
                fromRegion:MTLRegionMake2D(0, 0, width, height)
               mipmapLevel:0
                     slice:0];
      
      // Dump output words as BGRA
      
      if ((0)) {
        for ( int row = 0; row < height; row++ ) {
          uint32_t *rowPtr = ((uint32_t*) mFramebuffer.mutableBytes) + (row * width);
          for ( int col = 0; col < width; col++ ) {
            fprintf(stdout, "0x%08X ", rowPtr[col]);
          }
          fprintf(stdout, "\n");
        }
      }
    }
    
    // end of render
  }
  
  // Finalize rendering here & push the command buffer to the GPU
  if (!isCaptureRenderedTextureEnabled) {
    [commandBuffer commit];
  }
  
  return;
}

@end

