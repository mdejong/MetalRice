//
//  Metal2DColRowSumRenderContextTests.m
//
//  Created by Mo DeJong on 8/26/18.
//  Copyright © 2018 Apple. All rights reserved.
//

#import <XCTest/XCTest.h>

#import "MetalRenderContext.h"

#import "Metal2DColRowSumRenderContext.h"
#import "Metal2DColRowSumRenderFrame.h"

#import "prefix_sum.h"

#import "Util.h"

#import "zigzag.h"

@interface Metal2DColRowSumRenderContextTests : XCTestCase

@end

@implementation Metal2DColRowSumRenderContextTests

- (void)setUp {
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

// Query a texture that contains byte values and return in
// a buffer of uint8_t typed values.

+ (NSData*) getTextureBytes:(id<MTLTexture>)texture
{
  int width = (int) texture.width;
  int height = (int) texture.height;
  
  NSMutableData *mFramebuffer = [NSMutableData dataWithLength:width*height*sizeof(uint8_t)];
  
  [texture getBytes:(void*)mFramebuffer.mutableBytes
        bytesPerRow:width*sizeof(uint8_t)
      bytesPerImage:width*height*sizeof(uint8_t)
         fromRegion:MTLRegionMake2D(0, 0, width, height)
        mipmapLevel:0
              slice:0];
  
  return [NSData dataWithData:mFramebuffer];
}

// Dump texture that contains simple grayscale pixel values

- (void) dump8BitTexture:(id<MTLTexture>)outTexture
                   label:(NSString*)label
{
  // Copy texture data into debug framebuffer, note that this include 2x scale
  
  int width = (int) outTexture.width;
  int height = (int) outTexture.height;
  
  NSData *bytesData = [self.class getTextureBytes:outTexture];
  uint8_t *bytesPtr = (uint8_t*) bytesData.bytes;
  
  // Dump output words as bytes
  
  if ((1)) {
    fprintf(stdout, "%s as bytes\n", [label UTF8String]);
    
    for ( int row = 0; row < height; row++ ) {
      for ( int col = 0; col < width; col++ ) {
        int offset = (row * width) + col;
        uint8_t v = bytesPtr[offset];
        fprintf(stdout, "%3d ", v);
      }
      fprintf(stdout, "\n");
    }
    
    fprintf(stdout, "done\n");
  }
}

// Return contents of 8 bit texture as NSArray number values

- (NSArray*) arrayFrom8BitTexture:(id<MTLTexture>)outTexture
{
  // Copy texture data into debug framebuffer, note that this include 2x scale
  
  int width = (int) outTexture.width;
  int height = (int) outTexture.height;
  
  NSData *bytesData = [self.class getTextureBytes:outTexture];
  uint8_t *bytesPtr = (uint8_t*) bytesData.bytes;
  
  // Dump output words as bytes
  
  NSMutableArray *mArr = [NSMutableArray array];
  
  {
    for ( int row = 0; row < height; row++ ) {
      for ( int col = 0; col < width; col++ ) {
        int offset = (row * width) + col;
        uint8_t v = bytesPtr[offset];
        
        [mArr addObject:@(v)];
      }
    }
  }
  
  return mArr;
}

// Adaptor that fills a texture from byte values in an NSArray

- (void) fill8BitTexture:(id<MTLTexture>)texture
              bytesArray:(NSArray*)bytesArray
                     mrc:(MetalRenderContext*)mrc
{
  int width = (int) texture.width;
  int height = (int) texture.height;
  
  NSMutableData *mData = [NSMutableData data];
  [mData setLength:width*height*sizeof(uint8_t)];
  uint8_t *bytePtr = mData.mutableBytes;
  
  for ( int row = 0; row < height; row++ ) {
    for ( int col = 0; col < width; col++ ) {
      int offset = (row * width) + col;
      NSNumber *byteNum = bytesArray[offset];
      uint8_t bVal = (uint8_t) [byteNum unsignedCharValue];
      bytePtr[offset] = bVal;
    }
  }
  
  [mrc fill8bitTexture:texture bytes:bytePtr];
}

// Test simplified col and then row sum operation

- (void)testRowSumRender32x32OneBlockSimple {
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  Metal2DColRowSumRenderContext *mRenderContext = [[Metal2DColRowSumRenderContext alloc] init];
  
  // Use previous delta logic that operates directly on byte values with no zigzag
  
  mRenderContext.computeKernelFunction = @"kernel_column_row_sum_2D_bytes_dim1024_threads32_nozigzag";
  
  [mRenderContext setupRenderPipelines:mrc];
  
  int maxNumThreadsPerThreadgroup = mRenderContext.computePipelineState.maxTotalThreadsPerThreadgroup;
  NSUInteger numThreadsInSIMDGroup = mRenderContext.computePipelineState.threadExecutionWidth;
  
  //mfpsRenderContext.bytesPerThread = 128; // 8 threads, 1 for each row
  
  // The total number of input bytes is (2048 * 1536) / (32 * 32)
  
  //const int blockDim = 32 * 32;
  
  const int width1D = 32;
  
  const int width = 32 * 32;
  const int height = 1;
  
  const int totalNumberOfBytes = width * height;
  
  //const int totalNumberOfBytes = (2048 * 1536);
  //int totalNumBlocks = totalNumberOfBytes / blockDim;
  
  // Create deltas for 2D template
  
  uint8_t inTemplateBytes2D[width1D*width1D];
  
  {
    int width = width1D;
    int height = width1D;

    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        inTemplateBytes2D[offset] = 0;
      }
    }
    
    // (1,0) +1
    {
      int row = 0;
      int col = 1;
      int val = 1;
      int offset = (row * width) + col;
      inTemplateBytes2D[offset] = val;
    }
    
    // (0,1) +1
    {
      int row = 1;
      int col = 0;
      int val = 1;
      int offset = (row * width) + col;
      inTemplateBytes2D[offset] = val;
    }
    
    // (1,1) -1
    {
      int row = 1;
      int col = 1;
      int val = 255;
      int offset = (row * width) + col;
      inTemplateBytes2D[offset] = val;
    }
    
    // (0,2) -1
    {
      int row = 2;
      int col = 0;
      int val = 255;
      int offset = (row * width) + col;
      inTemplateBytes2D[offset] = val;
    }
  }
  
  uint8_t outTemplateBytes2D[width1D*width1D];
  
  {
    const int width = width1D;
    const int height = width1D;
    
    int sum = 0;
    
    int col = 0;
    
    for (int row = 0; row < height; row++) {
      int offset = (row * width) + col;
      uint8_t val = inTemplateBytes2D[offset];
      sum += val;
      outTemplateBytes2D[offset] = sum;
      
      int colSum = sum;
      
      for (int col = 1; col < width; col++) {
        int offset = (row * width) + col;
        uint8_t val = inTemplateBytes2D[offset];
        colSum += val;
        outTemplateBytes2D[offset] = colSum;
      }
    }
  }
  
  if (1)
  {
    int width = width1D;
    int height = width1D;
    
    printf("inTemplateBytes2D: %d x %d\n", width, height);
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = inTemplateBytes2D[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  if (1)
  {
    int width = width1D;
    int height = width1D;
    
    printf("outTemplateBytes2D: %d x %d\n", width, height);
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = outTemplateBytes2D[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  NSMutableData *mInputByteBuffer = [NSMutableData dataWithLength:totalNumberOfBytes];
  NSMutableData *mOutputByteBuffer = [NSMutableData dataWithLength:totalNumberOfBytes];
  
  uint8_t *inPtr = mInputByteBuffer.mutableBytes;
  uint8_t *outPtr = mOutputByteBuffer.mutableBytes;
  
  int numLoopsToFillAllBytes = totalNumberOfBytes / width;
  
  // Fill each row with delta values
  
  for (int blocki = 0; blocki < numLoopsToFillAllBytes; blocki++) {
    memcpy(inPtr, inTemplateBytes2D, width);
    inPtr += width;
    
    memcpy(outPtr, outTemplateBytes2D, width);
    outPtr += width;
  }
  
  if (0) {
    uint8_t *ptr = mInputByteBuffer.mutableBytes;
    for (int i = 0; i < 256; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
  }
  
  if (1) {
    uint8_t *ptr = mOutputByteBuffer.mutableBytes;
    for (int i = 0; i < 256; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
  }
  
  // Setup frame, a render context will render into this frame
  
  Metal2DColRowSumRenderFrame *mRenderFrame = [[Metal2DColRowSumRenderFrame alloc] init];
  
  CGSize renderSize = CGSizeMake(width1D, width1D);
  CGSize blockSize = CGSizeMake(width1D, width1D);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  id<MTLTexture> inputTexture = mRenderFrame.inputTexture;
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  {
    // Size must be width/4 x height
    
    int textureWidth = (int) inputTexture.width;
    int textureHeight = (int) inputTexture.height;
    
    assert(textureWidth == width1D/4);
    assert(textureHeight == width1D);
    
    assert(textureWidth == outputTexture.width);
    assert(textureHeight == outputTexture.height);
  }
  
  // Copy bytes into inputTexture as 32 bit words
  
  {
    uint32_t *wordPtr = (uint32_t*) mInputByteBuffer.mutableBytes;
    [mrc fillBGRATexture:inputTexture pixels:wordPtr];
  }
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  // Dump output of render process
  
  BOOL dump = TRUE;
  
  if (dump && 0) {
    NSLog(@"inputTexture:");
    
    NSData *inputData = [mrc getBGRATexturePixels:inputTexture];
    uint8_t *ptr = (uint8_t *) inputData.bytes;
    for (int i = 0; i < inputData.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
  }
  
  if (dump && 0) {
    NSLog(@"outputTexture:");
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int i = 0; i < outputData.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
    fflush(stdout);
  }
  
  if (1)
  {
    NSLog(@"inputTexture:");
    
    const int width = width1D;
    const int height = width1D;
    
    NSData *inputData = [mrc getBGRATexturePixels:inputTexture];
    uint8_t *ptr = (uint8_t *) inputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  if (1)
  {
    NSLog(@"expected outputBuffer:");
    
    const int width = width1D;
    const int height = width1D;
    
    uint8_t *ptr = (uint8_t *) mOutputByteBuffer.mutableBytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  if (1)
  {
    NSLog(@"outputTexture:");
    
    const int width = width1D;
    const int height = width1D;
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
  }
  
  {
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *outputDataPtr = (uint8_t *) outputData.bytes;
    
    XCTAssert(mOutputByteBuffer.length == totalNumberOfBytes);
    XCTAssert(outputData.length == totalNumberOfBytes);
    
    int same = 1;
    
    if (1)
    {
      int numMismatched = 0;
      
      uint8_t *expectedBytesPtr = mOutputByteBuffer.mutableBytes;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint8_t outputVal = outputDataPtr[offset];
          uint8_t expectedVal = expectedBytesPtr[offset];
          if (outputVal != expectedVal && numMismatched < 10) {
            printf("output[%3d,%3d] mismatch : output != expected : %d != %d\n", col, row, outputVal, expectedVal);
            same = 0;
            numMismatched += 1;
          }
        }
      }
    }
    
    
    XCTAssert(same == 1);
    
    NSLog(@"validated %d bytes", (int)mOutputByteBuffer.length);
  }
}

// Test simplified col and then row sum operation where the delta values are zigzag encoded

- (void)testRowSumRender32x32OneBlockSimpleWithZigZag {
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  Metal2DColRowSumRenderContext *mRenderContext = [[Metal2DColRowSumRenderContext alloc] init];
    
  [mRenderContext setupRenderPipelines:mrc];
  
  int maxNumThreadsPerThreadgroup = mRenderContext.computePipelineState.maxTotalThreadsPerThreadgroup;
  NSUInteger numThreadsInSIMDGroup = mRenderContext.computePipelineState.threadExecutionWidth;
  
  //mfpsRenderContext.bytesPerThread = 128; // 8 threads, 1 for each row
  
  // The total number of input bytes is (2048 * 1536) / (32 * 32)
  
  //const int blockDim = 32 * 32;
  
  const int width1D = 32;
  
  const int width = 32 * 32;
  const int height = 1;
  
  const int totalNumberOfBytes = width * height;
  
  //const int totalNumberOfBytes = (2048 * 1536);
  //int totalNumBlocks = totalNumberOfBytes / blockDim;
  
  // Create deltas for 2D template
  
  uint8_t inTemplateBytes2D[width1D*width1D];
  
  {
    int width = width1D;
    int height = width1D;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        inTemplateBytes2D[offset] = 0;
      }
    }
    
    // (1,0) +1
    {
      int row = 0;
      int col = 1;
      int val = 1;
      int offset = (row * width) + col;
      inTemplateBytes2D[offset] = val;
    }
    
    // (0,1) +1
    {
      int row = 1;
      int col = 0;
      int val = 1;
      int offset = (row * width) + col;
      inTemplateBytes2D[offset] = val;
    }
    
    // (1,1) -1
    {
      int row = 1;
      int col = 1;
      int val = -1;
      int offset = (row * width) + col;
      inTemplateBytes2D[offset] = val;
    }
    
    // (0,2) -1
    {
      int row = 2;
      int col = 0;
      int val = -1;
      int offset = (row * width) + col;
      inTemplateBytes2D[offset] = val;
    }
  }
  
  uint8_t outTemplateBytes2D[width1D*width1D];
  
  {
    const int width = width1D;
    const int height = width1D;
    
    int sum = 0;
    
    int col = 0;
    
    for (int row = 0; row < height; row++) {
      int offset = (row * width) + col;
      uint8_t val = inTemplateBytes2D[offset];
      sum += val;
      outTemplateBytes2D[offset] = sum;
      
      int colSum = sum;
      
      for (int col = 1; col < width; col++) {
        int offset = (row * width) + col;
        uint8_t val = inTemplateBytes2D[offset];
        colSum += val;
        outTemplateBytes2D[offset] = colSum;
      }
    }
  }
  
  if (1)
  {
    int width = width1D;
    int height = width1D;
    
    printf("inTemplateBytes2D: %d x %d\n", width, height);
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = inTemplateBytes2D[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  if (1)
  {
    int width = width1D;
    int height = width1D;
    
    printf("outTemplateBytes2D: %d x %d\n", width, height);
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = outTemplateBytes2D[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  NSMutableData *mInputByteBuffer = [NSMutableData dataWithLength:totalNumberOfBytes];
  NSMutableData *mOutputByteBuffer = [NSMutableData dataWithLength:totalNumberOfBytes];
  
  uint8_t *inPtr = mInputByteBuffer.mutableBytes;
  uint8_t *outPtr = mOutputByteBuffer.mutableBytes;
  
  int numLoopsToFillAllBytes = totalNumberOfBytes / width;
  
  // Fill each row with delta values
  
  for (int blocki = 0; blocki < numLoopsToFillAllBytes; blocki++) {
    // As values are copied, convert each value other than (0,0) to zigzag
    //memcpy(inPtr, inTemplateBytes2D, width);
    
    for (int i = 0; i < width; i++) {
      if (i == 0) {
        // nop
        inPtr[i] = inTemplateBytes2D[i];
      } else {
        // zigzag encode
        inPtr[i] = zigzag_num_neg_to_offset(inTemplateBytes2D[i]);
      }
    }
    inPtr += width;
    
    memcpy(outPtr, outTemplateBytes2D, width);
    outPtr += width;
  }
  
  if (0) {
    uint8_t *ptr = mInputByteBuffer.mutableBytes;
    for (int i = 0; i < 256; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
  }
  
  if (1) {
    uint8_t *ptr = mOutputByteBuffer.mutableBytes;
    for (int i = 0; i < 256; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
  }
  
  // Setup frame, a render context will render into this frame
  
  Metal2DColRowSumRenderFrame *mRenderFrame = [[Metal2DColRowSumRenderFrame alloc] init];
  
  CGSize renderSize = CGSizeMake(width1D, width1D);
  CGSize blockSize = CGSizeMake(width1D, width1D);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  id<MTLTexture> inputTexture = mRenderFrame.inputTexture;
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  {
    // Size must be width/4 x height
    
    int textureWidth = (int) inputTexture.width;
    int textureHeight = (int) inputTexture.height;
    
    assert(textureWidth == width1D/4);
    assert(textureHeight == width1D);
    
    assert(textureWidth == outputTexture.width);
    assert(textureHeight == outputTexture.height);
  }
  
  // Copy bytes into inputTexture as 32 bit words
  
  {
    uint32_t *wordPtr = (uint32_t*) mInputByteBuffer.mutableBytes;
    [mrc fillBGRATexture:inputTexture pixels:wordPtr];
  }
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  // Dump output of render process
  
  BOOL dump = TRUE;
  
  if (dump && 0) {
    NSLog(@"inputTexture:");
    
    NSData *inputData = [mrc getBGRATexturePixels:inputTexture];
    uint8_t *ptr = (uint8_t *) inputData.bytes;
    for (int i = 0; i < inputData.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
  }
  
  if (dump && 0) {
    NSLog(@"outputTexture:");
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int i = 0; i < outputData.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
    fflush(stdout);
  }
  
  if (1)
  {
    NSLog(@"inputTexture:");
    
    const int width = width1D;
    const int height = width1D;
    
    NSData *inputData = [mrc getBGRATexturePixels:inputTexture];
    uint8_t *ptr = (uint8_t *) inputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  if (1)
  {
    NSLog(@"expected outputBuffer:");
    
    const int width = width1D;
    const int height = width1D;
    
    uint8_t *ptr = (uint8_t *) mOutputByteBuffer.mutableBytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  if (1)
  {
    NSLog(@"outputTexture:");
    
    const int width = width1D;
    const int height = width1D;
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
  }
  
  {
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *outputDataPtr = (uint8_t *) outputData.bytes;
    
    XCTAssert(mOutputByteBuffer.length == totalNumberOfBytes);
    XCTAssert(outputData.length == totalNumberOfBytes);
    
    int same = 1;
    
    if (1)
    {
      int numMismatched = 0;
      
      uint8_t *expectedBytesPtr = mOutputByteBuffer.mutableBytes;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint8_t outputVal = outputDataPtr[offset];
          uint8_t expectedVal = expectedBytesPtr[offset];
          if (outputVal != expectedVal && numMismatched < 10) {
            printf("output[%3d,%3d] mismatch : output != expected : %d != %d\n", col, row, outputVal, expectedVal);
            same = 0;
            numMismatched += 1;
          }
        }
      }
    }
    
    
    XCTAssert(same == 1);
    
    NSLog(@"validated %d bytes", (int)mOutputByteBuffer.length);
  }
}

// Optimized 2D sum, column then row sums with 2D input/output textures.

- (void)testPerformanceRowSumRender1024OneBlock {
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  Metal2DColRowSumRenderContext *mRenderContext = [[Metal2DColRowSumRenderContext alloc] init];
  
  // Use previous delta logic that operates directly on byte values with no zigzag
  
  mRenderContext.computeKernelFunction = @"kernel_column_row_sum_2D_bytes_dim1024_threads32_nozigzag";
  
  [mRenderContext setupRenderPipelines:mrc];
  
  int maxNumThreadsPerThreadgroup = mRenderContext.computePipelineState.maxTotalThreadsPerThreadgroup;
  NSUInteger numThreadsInSIMDGroup = mRenderContext.computePipelineState.threadExecutionWidth;
  
  //mfpsRenderContext.bytesPerThread = 128; // 8 threads, 1 for each row
  
  // The total number of input bytes is (2048 * 1536) / (32 * 32)
  
  //const int blockDim = 32 * 32;
  
  const int width1D = 32;
  
  const int width = 32 * 32;
  const int height = 1;
  
  const int totalNumberOfBytes = width * height;
  
  //const int totalNumberOfBytes = (2048 * 1536);
  //int totalNumBlocks = totalNumberOfBytes / blockDim;
  
  // Create deltas for 2D template
  
  uint8_t inTemplateBytes2D[width1D*width1D];
  
  {
    int width = width1D;
    int height = width1D;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        // Col 0 is a delta from the offset value above
        int offset = (row * width) + col;
        
        if (col == 0) {
          inTemplateBytes2D[offset] = row;
        } else {
          inTemplateBytes2D[offset] = col;
        }
      }
    }
  }
  
  uint8_t outTemplateBytes2D[width1D*width1D];
  
  {
    int width = width1D;
    int height = width1D;
    
    int sum = 0;
    
    int col = 0;
    
    for (int row = 0; row < height; row++) {
      int offset = (row * width) + col;
      uint8_t val = inTemplateBytes2D[offset];
      sum += val;
      outTemplateBytes2D[offset] = sum;
      
      int colSum = sum;
      
      for (int col = 1; col < width; col++) {
        int offset = (row * width) + col;
        uint8_t val = inTemplateBytes2D[offset];
        colSum += val;
        outTemplateBytes2D[offset] = colSum;
      }
    }
  }
  
  if (1)
  {
    int width = width1D;
    int height = width1D;
    
    printf("inTemplateBytes2D: %d x %d\n", width, height);
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = inTemplateBytes2D[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  if (1)
  {
    int width = width1D;
    int height = width1D;
    
    printf("outTemplateBytes2D: %d x %d\n", width, height);
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = outTemplateBytes2D[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  NSMutableData *mInputByteBuffer = [NSMutableData dataWithLength:totalNumberOfBytes];
  NSMutableData *mOutputByteBuffer = [NSMutableData dataWithLength:totalNumberOfBytes];
  
  uint8_t *inPtr = mInputByteBuffer.mutableBytes;
  uint8_t *outPtr = mOutputByteBuffer.mutableBytes;
  
  int numLoopsToFillAllBytes = totalNumberOfBytes / width;
  
  // Fill each row with delta values
  
  for (int blocki = 0; blocki < numLoopsToFillAllBytes; blocki++) {
    memcpy(inPtr, inTemplateBytes2D, width);
    inPtr += width;
    
    memcpy(outPtr, outTemplateBytes2D, width);
    outPtr += width;
  }
  
  if (0) {
    uint8_t *ptr = mInputByteBuffer.mutableBytes;
    for (int i = 0; i < 256; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
  }
  
  if (1) {
    uint8_t *ptr = mOutputByteBuffer.mutableBytes;
    for (int i = 0; i < 256; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
  }
  
  // Setup frame, a render context will render into this frame
  
  Metal2DColRowSumRenderFrame *mRenderFrame = [[Metal2DColRowSumRenderFrame alloc] init];
  
  CGSize renderSize = CGSizeMake(width1D, width1D);
  CGSize blockSize = CGSizeMake(width1D, width1D);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];

  id<MTLTexture> inputTexture = mRenderFrame.inputTexture;
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  {
    // Size must be width/4 x height
    
    int textureWidth = (int) inputTexture.width;
    int textureHeight = (int) inputTexture.height;
    
    assert(textureWidth == width1D/4);
    assert(textureHeight == width1D);
    
    assert(textureWidth == outputTexture.width);
    assert(textureHeight == outputTexture.height);
  }
  
  // Copy bytes into inputTexture as 32 bit words
  
  {
    uint32_t *wordPtr = (uint32_t*) mInputByteBuffer.mutableBytes;
    [mrc fillBGRATexture:inputTexture pixels:wordPtr];
  }
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  // Dump output of render process
  
  BOOL dump = TRUE;
  
  if (dump && 0) {
    NSLog(@"inputTexture:");
    
    NSData *inputData = [mrc getBGRATexturePixels:inputTexture];
    uint8_t *ptr = (uint8_t *) inputData.bytes;
    for (int i = 0; i < inputData.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
  }
  
  if (dump && 0) {
    NSLog(@"outputTexture:");
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int i = 0; i < outputData.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
    fflush(stdout);
  }
  
  if (1)
  {
    NSLog(@"inputTexture:");
    
    const int width = width1D;
    const int height = width1D;
    
    NSData *inputData = [mrc getBGRATexturePixels:inputTexture];
    uint8_t *ptr = (uint8_t *) inputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  if (1)
  {
    NSLog(@"expected outputBuffer:");
    
    const int width = width1D;
    const int height = width1D;
    
    uint8_t *ptr = (uint8_t *) mOutputByteBuffer.mutableBytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  if (1)
  {
    NSLog(@"outputTexture:");
    
    const int width = width1D;
    const int height = width1D;
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
  }
  
  {
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *outputDataPtr = (uint8_t *) outputData.bytes;
    
    XCTAssert(mOutputByteBuffer.length == totalNumberOfBytes);
    XCTAssert(outputData.length == totalNumberOfBytes);
    
    int same = 1;
    
    if (1)
    {
      int numMismatched = 0;
      
      uint8_t *expectedBytesPtr = mOutputByteBuffer.mutableBytes;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint8_t outputVal = outputDataPtr[offset];
          uint8_t expectedVal = expectedBytesPtr[offset];
          if (outputVal != expectedVal && numMismatched < 10) {
            printf("output[%3d,%3d] mismatch : output != expected : %d != %d\n", col, row, outputVal, expectedVal);
            same = 0;
            numMismatched += 1;
          }
        }
      }
    }

    XCTAssert(same == 1);
    
    NSLog(@"validated %d bytes", (int)mOutputByteBuffer.length);
  }

  [self measureBlock:^{
    // Get a metal command buffer, render compute invocation into it
    
    CFTimeInterval start = CACurrentMediaTime();
    
    id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
    
#if defined(DEBUG)
    assert(commandBuffer);
#endif // DEBUG
    
    commandBuffer.label = @"XCTestRenderCommandBuffer";
    
    // Put the code you want to measure the time of here.
    
    [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
    
    // Wait for commands to be rendered
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    CFTimeInterval stop = CACurrentMediaTime();
    
    NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  }];
  
}

/*

// Optimized 2D sum, column then row sums with 2D input/output textures.
// This test case features 2 input blocks, note that the threadgroup
// shape must take the original input texture shape into account
// so this 2x1 input is rendered with 2x1 threadgroups.

- (void)testPerformanceRowSumRender1024TwoBlocksH {
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  Metal2DColRowSumRenderContext *mRenderContext = [[Metal2DColRowSumRenderContext alloc] init];
  
  [mRenderContext setupRenderPipelines:mrc];
  
  int maxNumThreadsPerThreadgroup = mRenderContext.computePipelineState.maxTotalThreadsPerThreadgroup;
  NSUInteger numThreadsInSIMDGroup = mRenderContext.computePipelineState.threadExecutionWidth;
  
  const int width1D = 32;

  const int width2D = 64;
  const int height2D = 32;
  
  const int width = width2D;
  const int height = height2D;
  
  // The total number of input bytes is (2048 * 1536)
  const int totalNumberOfBytes = width2D * height2D;
  
  // Create deltas for 2D template
  
  const int templateNumBytes = width1D * width1D;
  uint8_t inTemplateBytes2D[templateNumBytes];
  
  {
    const int width = width1D;
    const int height = width1D;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        // Col 0 is a delta from the offset value above
        int offset = (row * width) + col;
        
        if (col == 0) {
          inTemplateBytes2D[offset] = row;
        } else {
          inTemplateBytes2D[offset] = col;
        }
      }
    }
  }
  
  uint8_t outTemplateBytes2D[templateNumBytes];
  
  {
    const int width = width1D;
    const int height = width1D;
    
    int sum = 0;
    
    int col = 0;
    
    for (int row = 0; row < height; row++) {
      int offset = (row * width) + col;
      uint8_t val = inTemplateBytes2D[offset];
      sum += val;
      outTemplateBytes2D[offset] = sum;
      
      int colSum = sum;
      
      for (int col = 1; col < width; col++) {
        int offset = (row * width) + col;
        uint8_t val = inTemplateBytes2D[offset];
        colSum += val;
        outTemplateBytes2D[offset] = colSum;
      }
    }
  }
  
  if (1)
  {
    printf("inTemplateBytes2D:\n");
    
    const int width = width1D;
    const int height = width1D;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = inTemplateBytes2D[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  if (1)
  {
    printf("outTemplateBytes2D:\n");
    
    const int width = width1D;
    const int height = width1D;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = outTemplateBytes2D[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  NSMutableData *mInputByteBuffer = [NSMutableData dataWithLength:totalNumberOfBytes];
  NSMutableData *mOutputByteBuffer = [NSMutableData dataWithLength:totalNumberOfBytes];
  
  uint8_t *inPtr = mInputByteBuffer.mutableBytes;
  uint8_t *outPtr = mOutputByteBuffer.mutableBytes;
  
  int numLoopsToFillAllBytes = totalNumberOfBytes / templateNumBytes;
  assert(numLoopsToFillAllBytes*templateNumBytes == totalNumberOfBytes);
  
  // Note that this buffer is being filled in block by block
  // order, but the data needs to be transformed into image
  // order so that 2D reading logic can read the pixels in
  // the proper order from (X,Y).
  
  for (int blocki = 0; blocki < numLoopsToFillAllBytes; blocki++) {
    // Copy inTemplateBytes2D but add blocki to each value
    
    memcpy(inPtr, inTemplateBytes2D, templateNumBytes);
    // Copy blocki values over the first value
    inPtr[0] = blocki;
    inPtr += templateNumBytes;
    
    // Copy but add blocki to each output
    
    //memcpy(outPtr, outTemplateBytes2D, (width1D*width1D));
    
    for (int i=0; i < templateNumBytes; i++) {
      outPtr[i] = outTemplateBytes2D[i] + blocki;
    }
    
    outPtr += templateNumBytes;
    
    if (0) {
      int height = 32;
      int width = 32;
      
      printf("rewrite blocki IN %d\n", blocki);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int val = (inPtr - templateNumBytes)[offset];
          printf("%3d ", val);
        }
        printf("\n");
        fflush(stdout);
      }
      
      printf("done rewrite blocki %d\n", blocki);
      fflush(stdout);
    }
    
    if (0) {
      int height = 32;
      int width = 32;
      
      printf("rewrite blocki OUT %d\n", blocki);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int val = (outPtr - templateNumBytes)[offset];
          printf("%3d ", val);
        }
        printf("\n");
        fflush(stdout);
      }
      
      printf("done rewrite blocki %d\n", blocki);
      fflush(stdout);
    }
  }

  if ((1)) {
    inPtr = mInputByteBuffer.mutableBytes;
    outPtr = mOutputByteBuffer.mutableBytes;
    
    NSMutableArray *mInBlockOrderBytes = [NSMutableArray array];
    
    for (int i = 0; i < totalNumberOfBytes; i++) {
      [mInBlockOrderBytes addObject:@(inPtr[i])];
    }
    
    NSMutableArray *mOutBlockOrderBytes = [NSMutableArray array];
    
    for (int i = 0; i < totalNumberOfBytes; i++) {
      [mOutBlockOrderBytes addObject:@(outPtr[i])];
    }

    NSArray *flatInImageOrderBytes = [Util flattenBlocksOfSize:width1D values:mInBlockOrderBytes numBlocksInWidth:width2D/width1D];

    for (int i = 0; i < totalNumberOfBytes; i++) {
      NSNumber *num = flatInImageOrderBytes[i];
      int numi = [num unsignedCharValue];
      inPtr[i] = numi;
    }
    
    NSArray *flatOutImageOrderBytes = [Util flattenBlocksOfSize:width1D values:mOutBlockOrderBytes numBlocksInWidth:width2D/width1D];
    
    for (int i = 0; i < totalNumberOfBytes; i++) {
      NSNumber *num = flatOutImageOrderBytes[i];
      int numi = [num unsignedCharValue];
      outPtr[i] = numi;
    }
  }
  
  if (1) {
    printf("mInputByteBuffer contains %d bytes\n", (int)mInputByteBuffer.length);
    
    uint8_t *ptr = mInputByteBuffer.mutableBytes;
    for (int i = 0; i < mInputByteBuffer.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
      
      if (((i+1) % width2D) == 0) {
        printf("\n");
      }
    }
    printf("\n");
    printf("\n");
  }
  
  if (1) {
    printf("mOutputByteBuffer contains %d bytes\n", (int)mOutputByteBuffer.length);
    
    uint8_t *ptr = mOutputByteBuffer.mutableBytes;
    for (int i = 0; i < mOutputByteBuffer.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
      
      if (((i+1) % width2D) == 0) {
        printf("\n");
      }
    }
    printf("\n");
    printf("\n");
  }
  
  // Setup frame, a render content will render into this frame
  
  Metal2DColRowSumRenderFrame *mRenderFrame = [[Metal2DColRowSumRenderFrame alloc] init];
  
  CGSize renderSize = CGSizeMake(width2D, height2D);
  CGSize blockSize = CGSizeMake(width1D, width1D);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  id<MTLTexture> inputTexture = mRenderFrame.inputTexture;
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  {
    // Size must be width/4 x height
    
    int textureWidth = (int) inputTexture.width;
    int textureHeight = (int) inputTexture.height;
    
    assert(textureWidth == width2D/4);
    assert(textureHeight == height2D);
    
    assert(textureWidth == outputTexture.width);
    assert(textureHeight == outputTexture.height);
  }
  
  // Copy bytes into inputTexture as 32 bit words
  
  {
    uint32_t *wordPtr = (uint32_t*) mInputByteBuffer.mutableBytes;
    [mrc fillBGRATexture:inputTexture pixels:wordPtr];
  }
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  // Dump output of render process
  
  BOOL dump = TRUE;
  
  if (dump && 0) {
    NSLog(@"inputTexture:");
    
    NSData *inputData = [mrc getBGRATexturePixels:inputTexture];
    uint8_t *ptr = (uint8_t *) inputData.bytes;
    for (int i = 0; i < inputData.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
  }
  
  if (dump && 0) {
    NSLog(@"outputTexture:");
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int i = 0; i < outputData.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
    fflush(stdout);
  }
  
  if (1)
  {
    const int width = width2D;
    const int height = height2D;
    
    NSLog(@"inputTexture: %dx%d", width, height);
    
    NSData *inputData = [mrc getBGRATexturePixels:inputTexture];
    uint8_t *ptr = (uint8_t *) inputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  if (1)
  {
    const int width = width2D;
    const int height = height2D;
    
    NSLog(@"expected outputBuffer:");
    
    uint8_t *ptr = (uint8_t *) mOutputByteBuffer.mutableBytes;
    
    XCTAssert(mOutputByteBuffer.length == (width * height));
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  if (1)
  {
    const int width = width2D;
    const int height = height2D;
    
    printf("outputTexture: %dx%d\n", width, height);
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    
    XCTAssert(outputData.length == (width * height));
    
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      printf("row[%3d]: ", row);
      
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  {
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *outputDataPtr = (uint8_t *) outputData.bytes;
    
    XCTAssert(mOutputByteBuffer.length == totalNumberOfBytes);
    XCTAssert(outputData.length == totalNumberOfBytes);

    XCTAssert(outputTexture.width*4 == width2D);
    XCTAssert(outputTexture.height == height2D);
    
    uint8_t *expectedOutputPtr = (uint8_t *) mOutputByteBuffer.mutableBytes;
    
    //int same = memcmp(outputDataPtr, mOutputByteBuffer.mutableBytes, mOutputByteBuffer.length);
    //XCTAssert(same == 0);
    
    int same = 1;
    
    if (1)
    {
      const int width = width2D;
      const int height = height2D;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      //uint8_t *ptr = (uint8_t *) outputData.bytes;
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int outputVal = outputDataPtr[offset];
          int expectedVal = expectedOutputPtr[offset];
          if (outputVal != expectedVal) {
            printf("output[%3d,%3d] mismatch : output != expected : %d != %d\n", col, row, outputVal, expectedVal);
            same = 0;
          }
        }
      }
    }
    
    XCTAssert(same == 1);
    
    NSLog(@"validated %d bytes", (int)mOutputByteBuffer.length);
  }
  
  [self measureBlock:^{
    // Get a metal command buffer, render compute invocation into it
    
    CFTimeInterval start = CACurrentMediaTime();
    
    id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
    
#if defined(DEBUG)
    assert(commandBuffer);
#endif // DEBUG
    
    commandBuffer.label = @"XCTestRenderCommandBuffer";
    
    // Put the code you want to measure the time of here.
    
    [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
    
    // Wait for commands to be rendered
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    CFTimeInterval stop = CACurrentMediaTime();
    
    NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  }];
  
}

// Optimized 2D sum, column then row sums with 2D input/output textures.
// This test case features 2 input blocks, note that the threadgroup
// shape must take the original input texture shape into account
// so this 1x2 input is rendered with 1x2 threadgroups.

- (void)testPerformanceRowSumRender1024TwoBlocksV {
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  Metal2DColRowSumRenderContext *mRenderContext = [[Metal2DColRowSumRenderContext alloc] init];
  
  [mRenderContext setupRenderPipelines:mrc];
  
  int maxNumThreadsPerThreadgroup = mRenderContext.computePipelineState.maxTotalThreadsPerThreadgroup;
  NSUInteger numThreadsInSIMDGroup = mRenderContext.computePipelineState.threadExecutionWidth;
  
  const int width1D = 32;
  
  const int width2D = 32;
  const int height2D = 64;
  
  const int width = width2D;
  const int height = height2D;
  
  // The total number of input bytes is (2048 * 1536)
  const int totalNumberOfBytes = width2D * height2D;
  
  // Create deltas for 2D template
  
  const int templateNumBytes = width1D * width1D;
  uint8_t inTemplateBytes2D[templateNumBytes];
  
  {
    const int width = width1D;
    const int height = width1D;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        // Col 0 is a delta from the offset value above
        int offset = (row * width) + col;
        
        if (col == 0) {
          inTemplateBytes2D[offset] = row;
        } else {
          inTemplateBytes2D[offset] = col;
        }
      }
    }
  }
  
  uint8_t outTemplateBytes2D[templateNumBytes];
  
  {
    const int width = width1D;
    const int height = width1D;
    
    int sum = 0;
    
    int col = 0;
    
    for (int row = 0; row < height; row++) {
      int offset = (row * width) + col;
      uint8_t val = inTemplateBytes2D[offset];
      sum += val;
      outTemplateBytes2D[offset] = sum;
      
      int colSum = sum;
      
      for (int col = 1; col < width; col++) {
        int offset = (row * width) + col;
        uint8_t val = inTemplateBytes2D[offset];
        colSum += val;
        outTemplateBytes2D[offset] = colSum;
      }
    }
  }
  
  if (1)
  {
    printf("inTemplateBytes2D:\n");
    
    const int width = width1D;
    const int height = width1D;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = inTemplateBytes2D[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  if (1)
  {
    printf("outTemplateBytes2D:\n");
    
    const int width = width1D;
    const int height = width1D;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = outTemplateBytes2D[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  NSMutableData *mInputByteBuffer = [NSMutableData dataWithLength:totalNumberOfBytes];
  NSMutableData *mOutputByteBuffer = [NSMutableData dataWithLength:totalNumberOfBytes];
  
  uint8_t *inPtr = mInputByteBuffer.mutableBytes;
  uint8_t *outPtr = mOutputByteBuffer.mutableBytes;
  
  int numLoopsToFillAllBytes = totalNumberOfBytes / templateNumBytes;
  assert(numLoopsToFillAllBytes*templateNumBytes == totalNumberOfBytes);
  
  // Note that this buffer is being filled in block by block
  // order, but the data needs to be transformed into image
  // order so that 2D reading logic can read the pixels in
  // the proper order from (X,Y).
  
  for (int blocki = 0; blocki < numLoopsToFillAllBytes; blocki++) {
    // Copy inTemplateBytes2D but add blocki to each value
    
    memcpy(inPtr, inTemplateBytes2D, templateNumBytes);
    // Copy blocki values over the first value
    inPtr[0] = blocki;
    inPtr += templateNumBytes;
    
    // Copy but add blocki to each output
    
    //memcpy(outPtr, outTemplateBytes2D, (width1D*width1D));
    
    for (int i=0; i < templateNumBytes; i++) {
      outPtr[i] = outTemplateBytes2D[i] + blocki;
    }
    
    outPtr += templateNumBytes;
    
    if (0) {
      int height = 32;
      int width = 32;
      
      printf("rewrite blocki IN %d\n", blocki);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int val = (inPtr - templateNumBytes)[offset];
          printf("%3d ", val);
        }
        printf("\n");
        fflush(stdout);
      }
      
      printf("done rewrite blocki %d\n", blocki);
      fflush(stdout);
    }
    
    if (0) {
      int height = 32;
      int width = 32;
      
      printf("rewrite blocki OUT %d\n", blocki);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int val = (outPtr - templateNumBytes)[offset];
          printf("%3d ", val);
        }
        printf("\n");
        fflush(stdout);
      }
      
      printf("done rewrite blocki %d\n", blocki);
      fflush(stdout);
    }
  }
  
  if ((1)) {
    inPtr = mInputByteBuffer.mutableBytes;
    outPtr = mOutputByteBuffer.mutableBytes;
    
    NSMutableArray *mInBlockOrderBytes = [NSMutableArray array];
    
    for (int i = 0; i < totalNumberOfBytes; i++) {
      [mInBlockOrderBytes addObject:@(inPtr[i])];
    }
    
    NSMutableArray *mOutBlockOrderBytes = [NSMutableArray array];
    
    for (int i = 0; i < totalNumberOfBytes; i++) {
      [mOutBlockOrderBytes addObject:@(outPtr[i])];
    }
    
    NSArray *flatInImageOrderBytes = [Util flattenBlocksOfSize:width1D values:mInBlockOrderBytes numBlocksInWidth:width2D/width1D];
    
    for (int i = 0; i < totalNumberOfBytes; i++) {
      NSNumber *num = flatInImageOrderBytes[i];
      int numi = [num unsignedCharValue];
      inPtr[i] = numi;
    }
    
    NSArray *flatOutImageOrderBytes = [Util flattenBlocksOfSize:width1D values:mOutBlockOrderBytes numBlocksInWidth:width2D/width1D];
    
    for (int i = 0; i < totalNumberOfBytes; i++) {
      NSNumber *num = flatOutImageOrderBytes[i];
      int numi = [num unsignedCharValue];
      outPtr[i] = numi;
    }
  }
  
  if (1) {
    printf("mInputByteBuffer contains %d bytes\n", (int)mInputByteBuffer.length);
    
    uint8_t *ptr = mInputByteBuffer.mutableBytes;
    for (int i = 0; i < mInputByteBuffer.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
      
      if (((i+1) % width2D) == 0) {
        printf("\n");
      }
    }
    printf("\n");
    printf("\n");
  }
  
  if (1) {
    printf("mOutputByteBuffer contains %d bytes\n", (int)mOutputByteBuffer.length);
    
    uint8_t *ptr = mOutputByteBuffer.mutableBytes;
    for (int i = 0; i < mOutputByteBuffer.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
      
      if (((i+1) % width2D) == 0) {
        printf("\n");
      }
    }
    printf("\n");
    printf("\n");
  }
  
  // Setup frame, a render content will render into this frame
  
  Metal2DColRowSumRenderFrame *mRenderFrame = [[Metal2DColRowSumRenderFrame alloc] init];
  
  CGSize renderSize = CGSizeMake(width2D, height2D);
  CGSize blockSize = CGSizeMake(width1D, width1D);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  id<MTLTexture> inputTexture = mRenderFrame.inputTexture;
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  {
    // Size must be width/4 x height
    
    int textureWidth = (int) inputTexture.width;
    int textureHeight = (int) inputTexture.height;
    
    assert(textureWidth == width2D/4);
    assert(textureHeight == height2D);
    
    assert(textureWidth == outputTexture.width);
    assert(textureHeight == outputTexture.height);
  }
  
  // Copy bytes into inputTexture as 32 bit words
  
  {
    uint32_t *wordPtr = (uint32_t*) mInputByteBuffer.mutableBytes;
    [mrc fillBGRATexture:inputTexture pixels:wordPtr];
  }
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  // Dump output of render process
  
  BOOL dump = TRUE;
  
  if (dump && 0) {
    NSLog(@"inputTexture:");
    
    NSData *inputData = [mrc getBGRATexturePixels:inputTexture];
    uint8_t *ptr = (uint8_t *) inputData.bytes;
    for (int i = 0; i < inputData.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
  }
  
  if (dump && 0) {
    NSLog(@"outputTexture:");
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int i = 0; i < outputData.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
    fflush(stdout);
  }
  
  if (1)
  {
    const int width = width2D;
    const int height = height2D;
    
    NSLog(@"inputTexture: %dx%d", width, height);
    
    NSData *inputData = [mrc getBGRATexturePixels:inputTexture];
    uint8_t *ptr = (uint8_t *) inputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  if (1)
  {
    const int width = width2D;
    const int height = height2D;
    
    NSLog(@"expected outputBuffer:");
    
    uint8_t *ptr = (uint8_t *) mOutputByteBuffer.mutableBytes;
    
    XCTAssert(mOutputByteBuffer.length == (width * height));
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  if (1)
  {
    const int width = width2D;
    const int height = height2D;
    
    printf("outputTexture: %dx%d\n", width, height);
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    
    XCTAssert(outputData.length == (width * height));
    
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      printf("row[%3d]: ", row);
      
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  {
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *outputDataPtr = (uint8_t *) outputData.bytes;
    
    XCTAssert(mOutputByteBuffer.length == totalNumberOfBytes);
    XCTAssert(outputData.length == totalNumberOfBytes);
    
    XCTAssert(outputTexture.width*4 == width2D);
    XCTAssert(outputTexture.height == height2D);
    
    uint8_t *expectedOutputPtr = (uint8_t *) mOutputByteBuffer.mutableBytes;
    
    //int same = memcmp(outputDataPtr, mOutputByteBuffer.mutableBytes, mOutputByteBuffer.length);
    //XCTAssert(same == 0);
    
    int same = 1;
    
    if (1)
    {
      const int width = width2D;
      const int height = height2D;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      //uint8_t *ptr = (uint8_t *) outputData.bytes;
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int outputVal = outputDataPtr[offset];
          int expectedVal = expectedOutputPtr[offset];
          if (outputVal != expectedVal) {
            printf("output[%3d,%3d] mismatch : output != expected : %d != %d\n", col, row, outputVal, expectedVal);
            same = 0;
          }
        }
      }
    }
    
    XCTAssert(same == 1);
    
    NSLog(@"validated %d bytes", (int)mOutputByteBuffer.length);
  }
  
  [self measureBlock:^{
    // Get a metal command buffer, render compute invocation into it
    
    CFTimeInterval start = CACurrentMediaTime();
    
    id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
    
#if defined(DEBUG)
    assert(commandBuffer);
#endif // DEBUG
    
    commandBuffer.label = @"XCTestRenderCommandBuffer";
    
    // Put the code you want to measure the time of here.
    
    [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
    
    // Wait for commands to be rendered
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    CFTimeInterval stop = CACurrentMediaTime();
    
    NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  }];
  
}

// Optimized 2D sum, column then row sums with 2D input/output textures.
// This test case features 2 input blocks, note that the threadgroup
// shape must take the original input texture shape into account
// so this 1x2 input is rendered with 1x2 threadgroups.

- (void)testPerformanceRowSumRender1024FullScreenBlocks {
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  Metal2DColRowSumRenderContext *mRenderContext = [[Metal2DColRowSumRenderContext alloc] init];
  
  [mRenderContext setupRenderPipelines:mrc];
  
  int maxNumThreadsPerThreadgroup = mRenderContext.computePipelineState.maxTotalThreadsPerThreadgroup;
  NSUInteger numThreadsInSIMDGroup = mRenderContext.computePipelineState.threadExecutionWidth;
  
  const int width1D = 32;
  
  const int width2D = 2048;
  const int height2D = 1536;
  
  //const int width = width2D;
  //const int height = height2D;
  
  // The total number of input bytes is (2048 * 1536)
  const int totalNumberOfBytes = width2D * height2D;
  
  // Create deltas for 2D template
  
  const int templateNumBytes = width1D * width1D;
  uint8_t inTemplateBytes2D[templateNumBytes];
  
  {
    const int width = width1D;
    const int height = width1D;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        // Col 0 is a delta from the offset value above
        int offset = (row * width) + col;
        
        if (col == 0) {
          inTemplateBytes2D[offset] = row;
        } else {
          inTemplateBytes2D[offset] = col;
        }
      }
    }
  }
  
  uint8_t outTemplateBytes2D[templateNumBytes];
  
  {
    const int width = width1D;
    const int height = width1D;
    
    int sum = 0;
    
    int col = 0;
    
    for (int row = 0; row < height; row++) {
      int offset = (row * width) + col;
      uint8_t val = inTemplateBytes2D[offset];
      sum += val;
      outTemplateBytes2D[offset] = sum;
      
      int colSum = sum;
      
      for (int col = 1; col < width; col++) {
        int offset = (row * width) + col;
        uint8_t val = inTemplateBytes2D[offset];
        colSum += val;
        outTemplateBytes2D[offset] = colSum;
      }
    }
  }
  
  if (0)
  {
    printf("inTemplateBytes2D:\n");
    
    const int width = width1D;
    const int height = width1D;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = inTemplateBytes2D[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  if (0)
  {
    printf("outTemplateBytes2D:\n");
    
    const int width = width1D;
    const int height = width1D;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = outTemplateBytes2D[offset];
        printf("%3d ", val);
      }
      printf("\n");
    }
  }
  
  NSMutableData *mInputByteBuffer = [NSMutableData dataWithLength:totalNumberOfBytes];
  NSMutableData *mOutputByteBuffer = [NSMutableData dataWithLength:totalNumberOfBytes];
  
  uint8_t *inPtr = mInputByteBuffer.mutableBytes;
  uint8_t *outPtr = mOutputByteBuffer.mutableBytes;
  
  int numLoopsToFillAllBytes = totalNumberOfBytes / templateNumBytes;
  assert(numLoopsToFillAllBytes*templateNumBytes == totalNumberOfBytes);
  
  // Note that this buffer is being filled in block by block
  // order, but the data needs to be transformed into image
  // order so that 2D reading logic can read the pixels in
  // the proper order from (X,Y).
  
  for (int blocki = 0; blocki < numLoopsToFillAllBytes; blocki++) {
    // Copy inTemplateBytes2D but add blocki to each value
    
    memcpy(inPtr, inTemplateBytes2D, templateNumBytes);
    // Copy blocki values over the first value
    inPtr[0] = blocki;
    inPtr += templateNumBytes;
    
    // Copy but add blocki to each output
    
    //memcpy(outPtr, outTemplateBytes2D, (width1D*width1D));
    
    for (int i=0; i < templateNumBytes; i++) {
      outPtr[i] = outTemplateBytes2D[i] + blocki;
    }
    
    outPtr += templateNumBytes;
    
    if (0) {
      int height = 32;
      int width = 32;
      
      printf("rewrite blocki IN %d\n", blocki);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int val = (inPtr - templateNumBytes)[offset];
          printf("%3d ", val);
        }
        printf("\n");
        fflush(stdout);
      }
      
      printf("done rewrite blocki %d\n", blocki);
      fflush(stdout);
    }
    
    if (0) {
      int height = 32;
      int width = 32;
      
      printf("rewrite blocki OUT %d\n", blocki);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int val = (outPtr - templateNumBytes)[offset];
          printf("%3d ", val);
        }
        printf("\n");
        fflush(stdout);
      }
      
      printf("done rewrite blocki %d\n", blocki);
      fflush(stdout);
    }
  }
  
  if ((1)) {
    inPtr = mInputByteBuffer.mutableBytes;
    outPtr = mOutputByteBuffer.mutableBytes;
    
    NSMutableArray *mInBlockOrderBytes = [NSMutableArray array];
    
    for (int i = 0; i < totalNumberOfBytes; i++) {
      [mInBlockOrderBytes addObject:@(inPtr[i])];
    }
    
    NSMutableArray *mOutBlockOrderBytes = [NSMutableArray array];
    
    for (int i = 0; i < totalNumberOfBytes; i++) {
      [mOutBlockOrderBytes addObject:@(outPtr[i])];
    }
    
    NSArray *flatInImageOrderBytes = [Util flattenBlocksOfSize:width1D values:mInBlockOrderBytes numBlocksInWidth:width2D/width1D];
    
    for (int i = 0; i < totalNumberOfBytes; i++) {
      NSNumber *num = flatInImageOrderBytes[i];
      int numi = [num unsignedCharValue];
      inPtr[i] = numi;
    }
    
    NSArray *flatOutImageOrderBytes = [Util flattenBlocksOfSize:width1D values:mOutBlockOrderBytes numBlocksInWidth:width2D/width1D];
    
    for (int i = 0; i < totalNumberOfBytes; i++) {
      NSNumber *num = flatOutImageOrderBytes[i];
      int numi = [num unsignedCharValue];
      outPtr[i] = numi;
    }
  }
  
  if (0) {
    printf("mInputByteBuffer contains %d bytes\n", (int)mInputByteBuffer.length);
    
    uint8_t *ptr = mInputByteBuffer.mutableBytes;
    for (int i = 0; i < mInputByteBuffer.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
      
      if (((i+1) % width2D) == 0) {
        printf("\n");
      }
    }
    printf("\n");
    printf("\n");
  }
  
  if (0) {
    printf("mOutputByteBuffer contains %d bytes\n", (int)mOutputByteBuffer.length);
    
    uint8_t *ptr = mOutputByteBuffer.mutableBytes;
    for (int i = 0; i < mOutputByteBuffer.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
      
      if (((i+1) % width2D) == 0) {
        printf("\n");
      }
    }
    printf("\n");
    printf("\n");
  }
  
  // Setup frame, a render content will render into this frame
  
  Metal2DColRowSumRenderFrame *mRenderFrame = [[Metal2DColRowSumRenderFrame alloc] init];
  
  CGSize renderSize = CGSizeMake(width2D, height2D);
  CGSize blockSize = CGSizeMake(width1D, width1D);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  id<MTLTexture> inputTexture = mRenderFrame.inputTexture;
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  {
    // Size must be width/4 x height
    
    int textureWidth = (int) inputTexture.width;
    int textureHeight = (int) inputTexture.height;
    
    assert(textureWidth == width2D/4);
    assert(textureHeight == height2D);
    
    assert(textureWidth == outputTexture.width);
    assert(textureHeight == outputTexture.height);
  }
  
  // Copy bytes into inputTexture as 32 bit words
  
  {
    uint32_t *wordPtr = (uint32_t*) mInputByteBuffer.mutableBytes;
    [mrc fillBGRATexture:inputTexture pixels:wordPtr];
  }
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  // Dump output of render process
  
  BOOL dump = TRUE;
  
  if (dump && 0) {
    NSLog(@"inputTexture:");
    
    NSData *inputData = [mrc getBGRATexturePixels:inputTexture];
    uint8_t *ptr = (uint8_t *) inputData.bytes;
    for (int i = 0; i < inputData.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
  }
  
  if (dump && 0) {
    NSLog(@"outputTexture:");
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int i = 0; i < outputData.length; i++) {
      int bVal = ptr[i];
      printf("%d ", bVal);
    }
    printf("\n");
    printf("\n");
    fflush(stdout);
  }
  
  if (0)
  {
    const int width = width2D;
    const int height = height2D;
    
    NSLog(@"inputTexture: %dx%d", width, height);
    
    NSData *inputData = [mrc getBGRATexturePixels:inputTexture];
    uint8_t *ptr = (uint8_t *) inputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  if (0)
  {
    const int width = width2D;
    const int height = height2D;
    
    NSLog(@"expected outputBuffer:");
    
    uint8_t *ptr = (uint8_t *) mOutputByteBuffer.mutableBytes;
    
    XCTAssert(mOutputByteBuffer.length == (width * height));
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  if (0)
  {
    const int width = width2D;
    const int height = height2D;
    
    printf("outputTexture: %dx%d\n", width, height);
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    
    XCTAssert(outputData.length == (width * height));
    
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      printf("row[%3d]: ", row);
      
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  {
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *outputDataPtr = (uint8_t *) outputData.bytes;
    
    XCTAssert(mOutputByteBuffer.length == totalNumberOfBytes);
    XCTAssert(outputData.length == totalNumberOfBytes);
    
    XCTAssert(outputTexture.width*4 == width2D);
    XCTAssert(outputTexture.height == height2D);
    
    uint8_t *expectedOutputPtr = (uint8_t *) mOutputByteBuffer.mutableBytes;
    
    //int same = memcmp(outputDataPtr, mOutputByteBuffer.mutableBytes, mOutputByteBuffer.length);
    //XCTAssert(same == 0);
    
    int same = 1;
    
    if (1)
    {
      const int width = width2D;
      const int height = height2D;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      //uint8_t *ptr = (uint8_t *) outputData.bytes;
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int outputVal = outputDataPtr[offset];
          int expectedVal = expectedOutputPtr[offset];
          if (outputVal != expectedVal) {
            printf("output[%3d,%3d] mismatch : output != expected : %d != %d\n", col, row, outputVal, expectedVal);
            same = 0;
          }
        }
      }
    }
    
    XCTAssert(same == 1);
    
    NSLog(@"validated %d bytes", (int)mOutputByteBuffer.length);
  }
  
  [self measureBlock:^{
    // Get a metal command buffer, render compute invocation into it
    
    CFTimeInterval start = CACurrentMediaTime();
    
    id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
    
#if defined(DEBUG)
    assert(commandBuffer);
#endif // DEBUG
    
    commandBuffer.label = @"XCTestRenderCommandBuffer";
    
    // Put the code you want to measure the time of here.
    
    [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
    
    // Wait for commands to be rendered
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    CFTimeInterval stop = CACurrentMediaTime();
    
    NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  }];
  
}

// Emit threadgroup (tid, blocki, X, Y) values

- (void)test1024ThreadgroupXYOneBlock {
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  Metal2DColRowSumRenderContext *mRenderContext = [[Metal2DColRowSumRenderContext alloc] init];
  
  mRenderContext.computeKernelFunction = @"kernel_2D_words_dim1024_emit_threadgroup_xy_threads32";
  
  [mRenderContext setupRenderPipelines:mrc];
  
  int maxNumThreadsPerThreadgroup = mRenderContext.computePipelineState.maxTotalThreadsPerThreadgroup;
  NSUInteger numThreadsInSIMDGroup = mRenderContext.computePipelineState.threadExecutionWidth;
  
  const int width2D = 32;
  const int height2D = 32;
  
  const int width1D = 32;
  const int width = width2D;
  const int height = height2D;
  
  const int totalNumberOfBytes = width * height;
  
  // Setup frame, a render content will render into this frame
  
  Metal2DColRowSumRenderFrame *mRenderFrame = [[Metal2DColRowSumRenderFrame alloc] init];
  
  CGSize renderSize = CGSizeMake(width2D, height2D);
  CGSize blockSize = CGSizeMake(width1D, width1D);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  id<MTLTexture> inputTexture = mRenderFrame.inputTexture;
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  {
    // Size must be width/4 x height
    
    int textureWidth = (int) inputTexture.width;
    int textureHeight = (int) inputTexture.height;
    
    assert(textureWidth == width1D/4);
    assert(textureHeight == width1D);
    
    assert(textureWidth == outputTexture.width);
    assert(textureHeight == outputTexture.height);
  }
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (1)
  {
    const int width = width2D;
    const int height = height2D;

    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  // Expected shader output
  
  uint8_t expectedOutput[width*height];
  
  // offset counts up in terms of sets of 4 pixels
  int offset = 0;
  
  for (int i = 0; i < width*height; i += 4, offset++) {
    // tid = (0,1,2,..,7)
    // blocki
    // X, Y
    
    int row = i / width2D;
    int col = i % width2D;
    
    int numBlocksInWidth = width2D / width1D;
    int blocki = ((row / width1D) * numBlocksInWidth) + (col / width1D);

    // Process each row with its own thread
    int tid = (row % 32);
    
    expectedOutput[i+0] = tid;
    expectedOutput[i+1] = blocki;
    
    // Output coordinates in terms of whole grid,
    // note that the X coord is col/4
    
    expectedOutput[i+2] = col / sizeof(uint32_t);
    expectedOutput[i+3] = row;
    
    if (0) {
      printf("(col, row) : %d %d\n", col, row);
      printf("%d %d %d %d\n", expectedOutput[i+0], expectedOutput[i+1], expectedOutput[i+2], expectedOutput[i+3]);
    }
  }
  
  if (1)
  {
    NSLog(@"expectedOutput:");
    
    const int width = width2D;
    const int height = height2D;
    
    uint8_t *ptr = expectedOutput;
    
    for (int row = 0; row < height; row++) {
      printf("row[%3d]: ", row);
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done \n");
  }
  
  {
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *outputDataPtr = (uint8_t *) outputData.bytes;
    
    XCTAssert(outputData.length == totalNumberOfBytes);
    XCTAssert(outputTexture.width*4 == width2D);
    XCTAssert(outputTexture.height == height2D);
    
    //int same = memcmp(outputDataPtr, mOutputByteBuffer.mutableBytes, mOutputByteBuffer.length);
    //XCTAssert(same == 0);
    
    int same = 1;
    
    if (1)
    {
      const int width = width2D;
      const int height = height2D;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      //uint8_t *ptr = (uint8_t *) outputData.bytes;
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int outputVal = outputDataPtr[offset];
          int expectedVal = expectedOutput[offset];
          if (outputVal != expectedVal) {
            printf("output[%3d,%3d] mismatch : output != expected : %d != %d\n", col, row, outputVal, expectedVal);
            same = 0;
          }
        }
      }
    }
    
    XCTAssert(same == 1);
    
    NSLog(@"validated %d bytes", (int)sizeof(expectedOutput));
  }
  
  return;
}

// Emit threadgroup (tid, blocki, X, Y) values

- (void)test1024ThreadgroupXYOneBlockReadOrder {
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  Metal2DColRowSumRenderContext *mRenderContext = [[Metal2DColRowSumRenderContext alloc] init];
  
  mRenderContext.computeKernelFunction = @"kernel_2D_words_dim1024_emit_threadgroup_xy_readorder_threads32";
  
  [mRenderContext setupRenderPipelines:mrc];
  
  int maxNumThreadsPerThreadgroup = mRenderContext.computePipelineState.maxTotalThreadsPerThreadgroup;
  NSUInteger numThreadsInSIMDGroup = mRenderContext.computePipelineState.threadExecutionWidth;
  
  const int width2D = 32;
  const int height2D = 32;
  
  const int width1D = 32;
  const int width = width2D;
  const int height = height2D;
  
  const int totalNumberOfBytes = width * height;
  
  // Setup frame, a render content will render into this frame
  
  Metal2DColRowSumRenderFrame *mRenderFrame = [[Metal2DColRowSumRenderFrame alloc] init];
  
  CGSize renderSize = CGSizeMake(width2D, height2D);
  CGSize blockSize = CGSizeMake(width1D, width1D);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  id<MTLTexture> inputTexture = mRenderFrame.inputTexture;
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  {
    // Size must be width/4 x height
    
    int textureWidth = (int) inputTexture.width;
    int textureHeight = (int) inputTexture.height;
    
    assert(textureWidth == width1D/4);
    assert(textureHeight == width1D);
    
    assert(textureWidth == outputTexture.width);
    assert(textureHeight == outputTexture.height);
  }
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (1)
  {
    const int width = width2D;
    const int height = height2D;
    
    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  // Expected shader output
  
  uint8_t expectedOutput[width*height];
  
  // offset counts up in terms of sets of 4 pixels
  int offset = 0;
  
  for (int i = 0; i < width*height; i += 4, offset++) {
    // tid = (0,1,2,..,7)
    // blocki
    // X, Y
    
    int row = i / width2D;
    int col = i % width2D;
    
    int numBlocksInWidth = width2D / width1D;
    int blocki = ((row / width1D) * numBlocksInWidth) + (col / width1D);
    
    // Process each row with its own thread
    int tid = (row % 32);
    
    expectedOutput[i+0] = tid;
    
    //expectedOutput[i+1] = blocki;
    // Read order is column/4
    expectedOutput[i+1] = col / sizeof(uint32_t);
    
    // Output coordinates in terms of whole grid,
    // note that the X coord is col/4
    
    expectedOutput[i+2] = col / sizeof(uint32_t);
    expectedOutput[i+3] = row;
    
    if (0) {
      printf("(col, row) : %d %d\n", col, row);
      printf("%d %d %d %d\n", expectedOutput[i+0], expectedOutput[i+1], expectedOutput[i+2], expectedOutput[i+3]);
    }
  }
  
  if (1)
  {
    NSLog(@"expectedOutput:");
    
    const int width = width2D;
    const int height = height2D;
    
    uint8_t *ptr = expectedOutput;
    
    for (int row = 0; row < height; row++) {
      printf("row[%3d]: ", row);
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done \n");
  }
  
  {
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *outputDataPtr = (uint8_t *) outputData.bytes;
    
    XCTAssert(outputData.length == totalNumberOfBytes);
    XCTAssert(outputTexture.width*4 == width2D);
    XCTAssert(outputTexture.height == height2D);
    
    //int same = memcmp(outputDataPtr, mOutputByteBuffer.mutableBytes, mOutputByteBuffer.length);
    //XCTAssert(same == 0);
    
    int same = 1;
    
    if (1)
    {
      const int width = width2D;
      const int height = height2D;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      //uint8_t *ptr = (uint8_t *) outputData.bytes;
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int outputVal = outputDataPtr[offset];
          int expectedVal = expectedOutput[offset];
          if (outputVal != expectedVal) {
            printf("output[%3d,%3d] mismatch : output != expected : %d != %d\n", col, row, outputVal, expectedVal);
            same = 0;
          }
        }
      }
    }
    
    XCTAssert(same == 1);
    
    NSLog(@"validated %d bytes", (int)sizeof(expectedOutput));
  }
  
  return;
}

// Emit (tid, blocki, gid.x, gid.y) for a 1x2 pair of blocks

- (void)test1024ThreadgroupXYTwoBlockV {
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  Metal2DColRowSumRenderContext *mRenderContext = [[Metal2DColRowSumRenderContext alloc] init];
  
  mRenderContext.computeKernelFunction = @"kernel_2D_words_dim1024_emit_threadgroup_xy";
  
  [mRenderContext setupRenderPipelines:mrc];
  
  int maxNumThreadsPerThreadgroup = mRenderContext.computePipelineState.maxTotalThreadsPerThreadgroup;
  NSUInteger numThreadsInSIMDGroup = mRenderContext.computePipelineState.threadExecutionWidth;
  
  const int width2D = 32;
  const int height2D = 64;
  
  const int width1D = 32;
  
  const int width = width2D;
  const int height = height2D;
  
  const int totalNumberOfBytes = width2D * height2D;
  
  // Setup frame, a render content will render into this frame
  
  Metal2DColRowSumRenderFrame *mRenderFrame = [[Metal2DColRowSumRenderFrame alloc] init];
  
  CGSize renderSize = CGSizeMake(width2D, height2D);
  CGSize blockSize = CGSizeMake(width1D, width1D);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  id<MTLTexture> inputTexture = mRenderFrame.inputTexture;
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  {
    // Size must be width/4 x height
    
    int textureWidth = (int) inputTexture.width;
    int textureHeight = (int) inputTexture.height;
    
    assert(textureWidth == width2D/4);
    assert(textureHeight == height2D);
    
    assert(textureWidth == outputTexture.width);
    assert(textureHeight == outputTexture.height);
  }
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (1)
  {
    const int width = width2D;
    const int height = height2D;

    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      printf("row[%3d]: ", row);
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  // Expected shader output
  
  uint8_t expectedOutput[width*height];
  
  // offset counts up in terms of sets of 4 pixels
  int offset = 0;
  
  for (int i = 0; i < width*height; i += 4, offset++) {
    // tid = (0,1,2,..,7)
    // blocki
    // X, Y
    
    int row = i / width2D;
    int col = i % width2D;
    
    int numBlocksInWidth = width2D / width1D;
    int blocki = ((row / width1D) * numBlocksInWidth) + (col / width1D);
    
    // Process each row with its own thread, so tid = row % 8
    int tid = (row % 32);
    
    expectedOutput[i+0] = tid;
    expectedOutput[i+1] = blocki;
    
    // Output coordinates in terms of whole grid,
    // note that the X coord is col/4
    
    expectedOutput[i+2] = col / sizeof(uint32_t);
    expectedOutput[i+3] = row;
    
    if (0) {
      printf("(col, row) : %d %d\n", col, row);
      printf("%d %d %d %d\n", expectedOutput[i+0], expectedOutput[i+1], expectedOutput[i+2], expectedOutput[i+3]);
    }
  }
  
  if (1)
  {
    NSLog(@"expectedOutput:");
    
    const int width = width2D;
    const int height = height2D;
    
    uint8_t *ptr = expectedOutput;
    
    for (int row = 0; row < height; row++) {
      printf("row[%3d]: ", row);
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done \n");
  }
  
  {
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *outputDataPtr = (uint8_t *) outputData.bytes;
    
    XCTAssert(outputData.length == totalNumberOfBytes);
    XCTAssert(outputTexture.width*4 == width2D);
    XCTAssert(outputTexture.height == height2D);
    
    //int same = memcmp(outputDataPtr, mOutputByteBuffer.mutableBytes, mOutputByteBuffer.length);
    //XCTAssert(same == 0);
    
    int same = 1;
    
    if (1)
    {
      const int width = width2D;
      const int height = height2D;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int outputVal = outputDataPtr[offset];
          int expectedVal = expectedOutput[offset];
          if (outputVal != expectedVal) {
            printf("output[%3d,%3d] mismatch : output != expected : %d != %d\n", col, row, outputVal, expectedVal);
            same = 0;
          }
        }
      }
    }
    
    XCTAssert(same == 1);
    
    NSLog(@"validated %d bytes", (int)sizeof(expectedOutput));
  }
  
  return;
}

// Emit (tid, blocki, gid.x, gid.y) for a 2x1 pair of blocks

- (void)test1024ThreadgroupXYTwoBlockH {
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  Metal2DColRowSumRenderContext *mRenderContext = [[Metal2DColRowSumRenderContext alloc] init];
  
  mRenderContext.computeKernelFunction = @"kernel_2D_words_dim1024_emit_threadgroup_xy";
  
  [mRenderContext setupRenderPipelines:mrc];
  
  int maxNumThreadsPerThreadgroup = mRenderContext.computePipelineState.maxTotalThreadsPerThreadgroup;
  NSUInteger numThreadsInSIMDGroup = mRenderContext.computePipelineState.threadExecutionWidth;
  
  const int width2D = 64;
  const int height2D = 32;
  
  const int width1D = 32;
  
  const int width = width2D;
  const int height = height2D;
  
  const int totalNumberOfBytes = width2D * height2D;
  
  // Setup frame, a render content will render into this frame
  
  Metal2DColRowSumRenderFrame *mRenderFrame = [[Metal2DColRowSumRenderFrame alloc] init];
  
  CGSize renderSize = CGSizeMake(width2D, height2D);
  CGSize blockSize = CGSizeMake(width1D, width1D);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  id<MTLTexture> inputTexture = mRenderFrame.inputTexture;
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  {
    // Size must be width/4 x height
    
    int textureWidth = (int) inputTexture.width;
    int textureHeight = (int) inputTexture.height;
    
    assert(textureWidth == width2D/4);
    assert(textureHeight == height2D);
    
    assert(textureWidth == outputTexture.width);
    assert(textureHeight == outputTexture.height);
  }
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderColRowSum:mrc commandBuffer:commandBuffer renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (1)
  {
    const int width = width2D;
    const int height = height2D;
    
    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      printf("row[%3d]: ", row);
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  // Expected shader output
  
  uint8_t expectedOutput[width*height];
  
  // offset counts up in terms of sets of 4 pixels
  int offset = 0;
  
  for (int i = 0; i < width*height; i += 4, offset++) {
    // tid = (0,1,2,..,7)
    // blocki
    // X, Y
    
    int row = i / width2D;
    int col = i % width2D;
    
    int numBlocksInWidth = width2D / width1D;
    int blocki = ((row / width1D) * numBlocksInWidth) + (col / width1D);
    
    // Process each row with its own thread
    int tid = (row % 32);
    
    expectedOutput[i+0] = tid;
    expectedOutput[i+1] = blocki;
    
    // Output coordinates in terms of whole grid,
    // note that the X coord is col/4
    
    expectedOutput[i+2] = col / sizeof(uint32_t);
    expectedOutput[i+3] = row;
    
    if (1) {
      printf("(col, row) : %d %d\n", col, row);
      printf("%d %d %d %d\n", expectedOutput[i+0], expectedOutput[i+1], expectedOutput[i+2], expectedOutput[i+3]);
    }
  }
  
  if (1)
  {
    NSLog(@"expectedOutput:");
    
    const int width = width2D;
    const int height = height2D;
    
    uint8_t *ptr = expectedOutput;
    
    for (int row = 0; row < height; row++) {
      printf("row[%3d]: ", row);
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done \n");
  }
  
  {
    NSData *outputData = [mrc getBGRATexturePixels:outputTexture];
    uint8_t *outputDataPtr = (uint8_t *) outputData.bytes;
    
    XCTAssert(outputData.length == totalNumberOfBytes);
    XCTAssert(outputTexture.width*4 == width2D);
    XCTAssert(outputTexture.height == height2D);
    
    //int same = memcmp(outputDataPtr, mOutputByteBuffer.mutableBytes, mOutputByteBuffer.length);
    //XCTAssert(same == 0);
    
    int same = 1;
    
    if (1)
    {
      const int width = width2D;
      const int height = height2D;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int outputVal = outputDataPtr[offset];
          int expectedVal = expectedOutput[offset];
          if (outputVal != expectedVal) {
            printf("output[%3d,%3d] mismatch : output != expected : %d != %d\n", col, row, outputVal, expectedVal);
            same = 0;
          }
        }
      }
    }
    
    XCTAssert(same == 1);
    
    NSLog(@"validated %d bytes", (int)sizeof(expectedOutput));
  }
  
  return;
}

 */
 
@end

