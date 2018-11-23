//
//  BlockTests.mm
//
//  Created by Mo DeJong on 7/1/18.
//

#import <XCTest/XCTest.h>

#include <stdlib.h>

#import "block.hpp"
#import "block_process.hpp"

#import "rice.hpp"
#import "zigzag.h"
#import "Rice.h"
#import "Util.h"

@interface BlockTests : XCTestCase

@end

@implementation BlockTests

- (void)setUp {
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void)testBlockSplitGray2x2Ex1 {
    // This is an example of a functional test case.
    // Use XCTAssert and related functions to verify your tests produce the correct results.
    
    const int blockDim = 2;
    BlockEncoder<uint8_t, blockDim> encoder;
    
    uint8_t inputPixels[4] = {
        0x0, 0x1,
        0x2, 0x3
    };
    
    encoder.splitIntoBlocks(inputPixels, sizeof(inputPixels)/sizeof(inputPixels[0]), 2, 2, 1, 1, 0);
    
    XCTAssert(encoder.blockVectors.size() == 1);
    XCTAssert(encoder.blockVectors[0].size() == 4);
    
    vector<uint8_t> & vec = encoder.blockVectors[0];
    
    XCTAssert(vec[0] == 0x0, @"%d", vec[0]);
    XCTAssert(vec[1] == 0x1, @"%d", vec[1]);
    XCTAssert(vec[2] == 0x2, @"%d", vec[2]);
    XCTAssert(vec[3] == 0x3, @"%d", vec[3]);
    
    return;
}

- (void)testBlockSplitBGRA2x2Ex1 {
    // This is an example of a functional test case.
    // Use XCTAssert and related functions to verify your tests produce the correct results.
    
    const int blockDim = 2;
    BlockEncoder<uint32_t, blockDim> encoder;
    
    uint32_t inputPixels[4] = {
        0x0, 0x1,
        0x2, 0x3
    };
    
    encoder.splitIntoBlocks(inputPixels, sizeof(inputPixels)/sizeof(inputPixels[0]), 2, 2, 1, 1, 0);
    
    XCTAssert(encoder.blockVectors.size() == 1);
    XCTAssert(encoder.blockVectors[0].size() == 4);
    
    vector<uint32_t> & vec = encoder.blockVectors[0];
    
    XCTAssert(vec[0] == 0x0, @"%d", vec[0]);
    XCTAssert(vec[1] == 0x1, @"%d", vec[1]);
    XCTAssert(vec[2] == 0x2, @"%d", vec[2]);
    XCTAssert(vec[3] == 0x3, @"%d", vec[3]);
    
    return;
}

- (void)testBlockSplitGray2x2PaddingEx1 {
    // Input is 3x2 which creates zero padded blocks
    
    const int blockDim = 2;
    unsigned int width = 3;
    unsigned int height = 2;
    
    BlockEncoder<uint8_t, blockDim> encoder;
    
    uint8_t inputPixels[6] = {
        0x0, 0x1, 0x4,
        0x2, 0x3, 0x5
    };
    
    unsigned int blockWidth;
    unsigned int blockHeight;
    
    encoder.calcBlockWidthAndHeight(3, 2, blockWidth, blockHeight);
    encoder.splitIntoBlocks(inputPixels, sizeof(inputPixels)/sizeof(inputPixels[0]), width, height, blockWidth, blockHeight, 0);
    
    XCTAssert(encoder.blockVectors.size() == 2);
    
    uint8_t expectedBlock0[4] = {
        0x0, 0x1,
        0x2, 0x3
    };
    
    uint8_t expectedBlock1[4] = {
        0x4, 0x0,
        0x5, 0x0
    };
    
    {
        vector<uint8_t> & vec = encoder.blockVectors[0];
        XCTAssert(vec.size() == 4);
        
        for (int i = 0; i < vec.size(); i++) {
            XCTAssert(vec[i] == expectedBlock0[i], @"%d", vec[i]);
        }
    }

    {
        vector<uint8_t> & vec = encoder.blockVectors[1];
        XCTAssert(vec.size() == 4);
        
        for (int i = 0; i < vec.size(); i++) {
            XCTAssert(vec[i] == expectedBlock1[i], @"%d", vec[i]);
        }
    }
    
    // Decode to flatten and crop the block values
    
    BlockDecoder<uint8_t, blockDim> decoder;
    
    decoder.blockVectors = std::move(encoder.blockVectors);

    vector<uint8_t> outputPixelsVec(sizeof(inputPixels)/sizeof(inputPixels[0]));
    
    decoder.flattenAndCrop(outputPixelsVec.data(), (int)outputPixelsVec.size(), blockWidth, blockHeight, width, height);
    
    int cmp = memcmp(outputPixelsVec.data(), inputPixels, sizeof(inputPixels));
    
    XCTAssert(cmp == 0, @"cropped");
    
    return;
}

// Block encode and decode operation for 3x2 input, zero padded to 2 blocks

- (void)testBlockDeltaEncoding3x2PaddingEx1 {
    // Input is 3x2 which creates zero padded blocks
    
    const int blockDim = 2;
    unsigned int width = 3;
    unsigned int height = 2;

    unsigned int blockWidth = 2;
    unsigned int blockHeight = 1;
    
    BlockEncoder<uint8_t, blockDim> encoder;
    
    uint8_t inputPixels[6] = {
        0x0, 0x1, 0x4,
        0x2, 0x3, 0x5
    };

    int numBaseValues, numBlockValues;
    
    vector<uint8_t> outEncodedBlockBytesVec;
    
    block_delta_process_encode<blockDim>(inputPixels, sizeof(inputPixels),
                                         width, height,
                                         0, 0,
                                         outEncodedBlockBytesVec,
                                         &numBaseValues,
                                         &numBlockValues);
    
    vector<uint8_t> imageOrderSymbolsVec(width*height);
    uint8_t *imageOrderSymbols = imageOrderSymbolsVec.data();
    assert(imageOrderSymbols);
    memset(imageOrderSymbols, 0xFF, width*height);
    
    uint8_t *decodedSymbols = (uint8_t *) outEncodedBlockBytesVec.data();
        
    block_delta_process_decode<blockDim>(decodedSymbols,
                                         (int)outEncodedBlockBytesVec.size(),
                                         width,
                                         height,
                                         blockWidth,
                                         blockHeight,
                                         imageOrderSymbols,
                                         width*height);
    
    int cmp = memcmp(inputPixels, imageOrderSymbols, width*height);
    XCTAssert(cmp == 0);

    return;
}

// 8x8 block and 6x4 input image data

- (void)testBlockDeltaEncoding6x4PaddingEx2 {
    const int blockDim = 8;
    unsigned int width = 6;
    unsigned int height = 4;
    
    unsigned int blockWidth = 1;
    unsigned int blockHeight = 1;
    
    uint8_t inputPixels[6*4];
    
    for (int i = 0; i < sizeof(inputPixels); i++) {
        inputPixels[i] = i;
    }
    
    int numBaseValues, numBlockValues;
    
    vector<uint8_t> outEncodedBlockBytesVec;
    
    block_delta_process_encode<blockDim>(inputPixels, sizeof(inputPixels),
                                         width, height,
                                         0, 0,
                                         outEncodedBlockBytesVec,
                                         &numBaseValues,
                                         &numBlockValues);
    
    vector<uint8_t> imageOrderSymbolsVec(width*height);
    uint8_t *imageOrderSymbols = imageOrderSymbolsVec.data();
    assert(imageOrderSymbols);
    
    uint8_t *decodedSymbols = (uint8_t *) outEncodedBlockBytesVec.data();
    
    block_delta_process_decode<blockDim>(decodedSymbols,
                                         (int)outEncodedBlockBytesVec.size(),
                                         width,
                                         height,
                                         blockWidth,
                                         blockHeight,
                                         imageOrderSymbols,
                                         width*height);
    
    int cmp = memcmp(inputPixels, imageOrderSymbols, width*height);
    XCTAssert(cmp == 0);
    
    return;
}

// Test output block encoding that leaves zero padding for a 4x4 block
// size from a 2x2 input.

- (void)testBlockOutLargerGray2x2Ex1 {
    // This is an example of a functional test case.
    // Use XCTAssert and related functions to verify your tests produce the correct results.
    
    const int blockDim = 2;
    BlockEncoder<uint8_t, blockDim> encoder;
    
    const int width = 2;
    const int height = 2;
    
    uint8_t inputPixels[] = {
        0x0, 0x1,
        0x2, 0x3
    };
    
    // Define output as block padded so that the number of blocks is a multiple of 4.
    // The output width here is 4x4 since blocks are 2x2
    
    const int outBlockWidth = 2;
    const int outBlockHeight = 2;
    
    encoder.splitIntoBlocks(inputPixels, sizeof(inputPixels)/sizeof(inputPixels[0]), width, height, outBlockWidth, outBlockHeight, 0);
    
    XCTAssert(encoder.blockVectors.size() == 4);
    XCTAssert(encoder.blockVectors[0].size() == 4);
    XCTAssert(encoder.blockVectors[1].size() == 4);
    XCTAssert(encoder.blockVectors[2].size() == 4);
    XCTAssert(encoder.blockVectors[3].size() == 4);
    
    {
        vector<uint8_t> & vec = encoder.blockVectors[0];
        
        XCTAssert(vec[0] == 0x0, @"%d", vec[0]);
        XCTAssert(vec[1] == 0x1, @"%d", vec[1]);
        XCTAssert(vec[2] == 0x2, @"%d", vec[2]);
        XCTAssert(vec[3] == 0x3, @"%d", vec[3]);
    }

    {
        vector<uint8_t> & vec = encoder.blockVectors[1];
        
        XCTAssert(vec[0] == 0x0, @"%d", vec[0]);
        XCTAssert(vec[1] == 0x0, @"%d", vec[1]);
        XCTAssert(vec[2] == 0x0, @"%d", vec[2]);
        XCTAssert(vec[3] == 0x0, @"%d", vec[3]);
    }

    {
        vector<uint8_t> & vec = encoder.blockVectors[2];
        
        XCTAssert(vec[0] == 0x0, @"%d", vec[0]);
        XCTAssert(vec[1] == 0x0, @"%d", vec[1]);
        XCTAssert(vec[2] == 0x0, @"%d", vec[2]);
        XCTAssert(vec[3] == 0x0, @"%d", vec[3]);
    }

    {
        vector<uint8_t> & vec = encoder.blockVectors[3];
        
        XCTAssert(vec[0] == 0x0, @"%d", vec[0]);
        XCTAssert(vec[1] == 0x0, @"%d", vec[1]);
        XCTAssert(vec[2] == 0x0, @"%d", vec[2]);
        XCTAssert(vec[3] == 0x0, @"%d", vec[3]);
    }
    
    return;
}

// Input is a 3x2 byte pattern with block size 2x1

- (void)testBlockOutLargerGray3x2Ex1 {
    // This is an example of a functional test case.
    // Use XCTAssert and related functions to verify your tests produce the correct results.
    
    const int blockDim = 2;
    BlockEncoder<uint8_t, blockDim> encoder;
    
    const int width = 3;
    const int height = 2;
    
    uint8_t inputPixels[] = {
        0x0, 0x1, 0x2,
        0x3, 0x4, 0x5
    };
    
    // Define output as block padded so that the number of blocks is a multiple of 4.
    // The output width here is 4x4 since blocks are 2x2
    
    const int outBlockWidth = 2;
    const int outBlockHeight = 1;
    
    encoder.splitIntoBlocks(inputPixels, sizeof(inputPixels)/sizeof(inputPixels[0]), width, height, outBlockWidth, outBlockHeight, 0);
    
    XCTAssert(encoder.blockVectors.size() == 2);
    XCTAssert(encoder.blockVectors[0].size() == 4);
    XCTAssert(encoder.blockVectors[1].size() == 4);
    
    {
        vector<uint8_t> & vec = encoder.blockVectors[0];
        
        XCTAssert(vec[0] == 0x0, @"%d", vec[0]);
        XCTAssert(vec[1] == 0x1, @"%d", vec[1]);
        XCTAssert(vec[2] == 0x3, @"%d", vec[2]);
        XCTAssert(vec[3] == 0x4, @"%d", vec[3]);
    }
    
    {
        vector<uint8_t> & vec = encoder.blockVectors[1];
        
        XCTAssert(vec[0] == 0x2, @"%d", vec[0]);
        XCTAssert(vec[1] == 0x0, @"%d", vec[1]);
        XCTAssert(vec[2] == 0x5, @"%d", vec[2]);
        XCTAssert(vec[3] == 0x0, @"%d", vec[3]);
    }
    
    return;
}

// Block reordering of 2x2 block with deltas

- (void)testBlockReorderWithDeltas2x2 {
    const int blockDim = 2;
    const unsigned int width = 2;
    const unsigned int height = 2;
    const unsigned int blockWidth = 1;
    const unsigned int blockHeight = 1;
    
    uint8_t inputPixels[width*height];
    
    for (int i = 0; i < sizeof(inputPixels); i++) {
        inputPixels[i] = i;
    }
    
    vector<uint8_t> outEncodedBlockBytesVec;
    
    int numBaseValues, numBlockValues;
    
    block_delta_process_encode<blockDim>(inputPixels, sizeof(inputPixels),
                                         width, height,
                                         blockWidth, blockHeight,
                                         outEncodedBlockBytesVec,
                                         &numBaseValues,
                                         &numBlockValues);
    
    // Validate the state of each delta byte, zigzag deltas
    
    {
        uint8_t expectedsDeltaBytes[] = {
            0, +2,
            +4, +2
        };
        
        int cmp = memcmp((uint8_t*)outEncodedBlockBytesVec.data(), expectedsDeltaBytes, sizeof(expectedsDeltaBytes));
        XCTAssert(cmp == 0);
    }

    vector<uint8_t> imageOrderSymbolsVec(width*height);
    uint8_t *imageOrderSymbols = imageOrderSymbolsVec.data();
    assert(imageOrderSymbols);
    
    block_delta_process_decode<blockDim>((uint8_t*)outEncodedBlockBytesVec.data(),
                                   (int)outEncodedBlockBytesVec.size(),
                                   width,
                                   height,
                                   blockWidth,
                                   blockHeight,
                                   imageOrderSymbols,
                                   width*height);
    
    int cmp = memcmp(inputPixels, imageOrderSymbols, width*height);
    XCTAssert(cmp == 0);
    
    return;
}

// Block reordering of 2x2 blocks without application of deltas

- (void)testBlockReorderNoDeltas2x2 {
    const int blockDim = 2;
    const unsigned int width = 2;
    const unsigned int height = 2;
    const unsigned int blockWidth = 1;
    const unsigned int blockHeight = 1;
    
    uint8_t inputPixels[width*height];
    
    for (int i = 0; i < sizeof(inputPixels); i++) {
        inputPixels[i] = i;
    }
    
    vector<uint8_t> outEncodedBlockBytesVec;
    
    block_process_encode<blockDim>(inputPixels, sizeof(inputPixels),
                                         width, height,
                                         blockWidth, blockHeight,
                                         outEncodedBlockBytesVec);
    
    // Validate the state of each delta byte, zigzag deltas
    
    {
        uint8_t expectedsDeltaBytes[] = {
            0, 1,
            2, 3
        };
        
        int cmp = memcmp((uint8_t*)outEncodedBlockBytesVec.data(), expectedsDeltaBytes, sizeof(expectedsDeltaBytes));
        XCTAssert(cmp == 0);
    }
    
    vector<uint8_t> imageOrderSymbolsVec(width*height);
    uint8_t *imageOrderSymbols = imageOrderSymbolsVec.data();
    assert(imageOrderSymbols);
    
    uint8_t *decodedSymbols = (uint8_t *) outEncodedBlockBytesVec.data();
    
    block_process_decode<blockDim>(decodedSymbols,
                                         (int)outEncodedBlockBytesVec.size(),
                                         width,
                                         height,
                                         blockWidth,
                                         blockHeight,
                                         imageOrderSymbols,
                                         width*height);
    
    int cmp = memcmp(inputPixels, imageOrderSymbols, width*height);
    XCTAssert(cmp == 0);
    
    return;
}

// Generate blocki reordering with 2x2 blocks, in this
// case a 2x2 set of pixels values corresponds to a single
// blocki value.

- (void)testBlockiGenerateReorder_2x2_Ex1 {
  const int blockDim = 2;
  const int blockiDim = 1;
  
  const unsigned int width = 2;
  const unsigned int height = 2;
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec);
  
  {
    uint32_t expected[] = {
      0x0
    };
    
    XCTAssert(blockiVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  {
    uint32_t expected[] = {
      0x0
    };
    
    XCTAssert(blockiLookupVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiLookupVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiLookupVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }

  return;
}

// 2x2 block size with 2x1 big block dimensions

- (void)testBlockiGenerateReorder_2x2_Ex2 {
  const int blockDim = 2;
  const int blockiDim = 1;
  
  const unsigned int width = 4;
  const unsigned int height = 2;
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec);
  
  {
    uint32_t expected[] = {
      0, 1
    };
    
    XCTAssert(blockiVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  {
    uint32_t expected[] = {
      0, 1
    };
    
    XCTAssert(blockiLookupVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiLookupVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiLookupVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  return;
}

// 2x2 block size with 2x1 big block dimensions

- (void)testBlockiGenerateReorder_2x2_Ex3 {
  const int blockDim = 2;
  const int blockiDim = 2;
  
  const unsigned int width = 4 * 2;
  const unsigned int height = 2 * 2;
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec);
  
  {
    uint32_t expected[] = {
      0, 1, 2, 3,
      4, 5, 6, 7
    };
    
    XCTAssert(blockiVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  {
    uint32_t expected[] = {
      0, 1, 4, 5,
      2, 3, 6, 7
    };
    
    XCTAssert(blockiLookupVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiLookupVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiLookupVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  // Iterate over block ordered blockiVec and then lookup the blocki value
  // that corresponds to the original blocki.
  
  vector<uint32_t> iterOrder;
  
  for ( uint32_t blocki : blockiVec ) {
    uint32_t iterBlocki = blockiLookupVec[blocki];
    iterOrder.push_back(iterBlocki);
  }
 
  {
    uint32_t expected[] = {
      0, 1, 4, 5,
      2, 3, 6, 7
    };
    
    XCTAssert(iterOrder.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = iterOrder[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"iterOrder[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  return;
}

// 64x64 input with 8x8 blocks

- (void)testBlockiGenerateReorder_64x64_8x8_Ex1 {
  const int blockDim = 8;
  const int blockiDim = 4;
  
  const unsigned int width = 32 * 2;
  const unsigned int height = 32 * 2;

  const unsigned int numBlocksInWidth = width / blockDim;
  const unsigned int numBlocksInHeight = height / blockDim;
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  if ((1)) {
    printf("blockiVec %3d x %3d : blocks %3d x %3d\n", width, height, numBlocksInWidth, numBlocksInHeight);
    
    for (int row = 0; row < numBlocksInHeight; row++) {
      for (int col = 0; col < numBlocksInWidth; col++) {
        int offset = (row * numBlocksInWidth) + col;
        int bVal = blockiVec[offset];
        printf("%3d, ", bVal);
      }
      printf("\n");
    }
  }

  if ((1)) {
    printf("blockiLookupVec %3d x %3d : blocks %3d x %3d\n", width, height, numBlocksInWidth, numBlocksInHeight);
    
    for (int row = 0; row < numBlocksInHeight; row++) {
      for (int col = 0; col < numBlocksInWidth; col++) {
        int offset = (row * numBlocksInWidth) + col;
        int bVal = blockiLookupVec[offset];
        printf("%3d, ", bVal);
      }
      printf("\n");
    }
  }
  
  {
    uint32_t expected[] = {
       0,  1,  2,  3,  4,  5,  6,  7,
       8,  9, 10, 11, 12, 13, 14, 15,
      16, 17, 18, 19, 20, 21, 22, 23,
      24, 25, 26, 27, 28, 29, 30, 31,
      32, 33, 34, 35, 36, 37, 38, 39,
      40, 41, 42, 43, 44, 45, 46, 47,
      48, 49, 50, 51, 52, 53, 54, 55,
      56, 57, 58, 59, 60, 61, 62, 63
    };
    
    XCTAssert(blockiVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  {
    uint32_t expected[] = {
       0,  1,  2,  3,  8,  9, 10, 11,
      16, 17, 18, 19, 24, 25, 26, 27,
       4,  5,  6,  7, 12, 13, 14, 15,
      20, 21, 22, 23, 28, 29, 30, 31,
      32, 33, 34, 35, 40, 41, 42, 43,
      48, 49, 50, 51, 56, 57, 58, 59,
      36, 37, 38, 39, 44, 45, 46, 47,
      52, 53, 54, 55, 60, 61, 62, 63
    };
    
    XCTAssert(blockiLookupVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiLookupVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiLookupVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  // Iterate over block ordered blockiVec and then lookup the blocki value
  // that corresponds to the original blocki.
  
  vector<uint32_t> iterOrder;
  
  for ( uint32_t blocki : blockiVec ) {
    uint32_t iterBlocki = blockiLookupVec[blocki];
    iterOrder.push_back(iterBlocki);
  }
  
  {
    uint32_t expected[] = {
      // block 0
      0,  1,  2,  3,
      8,  9, 10, 11,
      16, 17, 18, 19,
      24, 25, 26, 27,
      // block 1
      4,  5,  6,  7,
      12, 13, 14, 15,
      20, 21, 22, 23,
      28, 29, 30, 31,
      // block 2
      32, 33, 34, 35,
      40, 41, 42, 43,
      48, 49, 50, 51,
      56, 57, 58, 59,
      // block 3
      36, 37, 38, 39,
      44, 45, 46, 47,
      52, 53, 54, 55,
      60, 61, 62, 63
    };
    
    XCTAssert(iterOrder.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = iterOrder[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"iterOrder[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  return;
}

// 256x256 at 8x8 blockDim

- (void)testBlockiGenerateReorder_256x256_8x8_Ex2 {
  const int blockDim = 8;
  const int blockiDim = 4;
  
  const unsigned int width = 32 * 8;
  const unsigned int height = 32 * 8;
  
  const unsigned int numBlocksInWidth = width / blockDim;
  const unsigned int numBlocksInHeight = height / blockDim;
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  if ((0)) {
    printf("blockiVec %3d x %3d : blocks %3d x %3d\n", width, height, numBlocksInWidth, numBlocksInHeight);
    
    for (int row = 0; row < numBlocksInHeight; row++) {
      for (int col = 0; col < numBlocksInWidth; col++) {
        int offset = (row * numBlocksInWidth) + col;
        int bVal = blockiVec[offset];
        printf("%3d, ", bVal);
      }
      printf("\n");
    }
  }
  
  if ((1)) {
    printf("blockiLookupVec %3d x %3d : blocks %3d x %3d\n", width, height, numBlocksInWidth, numBlocksInHeight);
    
    for (int row = 0; row < numBlocksInHeight; row++) {
      for (int col = 0; col < numBlocksInWidth; col++) {
        int offset = (row * numBlocksInWidth) + col;
        int bVal = blockiLookupVec[offset];
        printf("%3d, ", bVal);
      }
      printf("\n");
    }
  }
  
  {
    uint32_t expected[] = {
      0,   1,   2,   3,   4,   5,   6,   7,   8,   9,  10,  11,  12,  13,  14,  15,  16,  17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,
      32,  33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  47,  48,  49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,  62,  63,
      64,  65,  66,  67,  68,  69,  70,  71,  72,  73,  74,  75,  76,  77,  78,  79,  80,  81,  82,  83,  84,  85,  86,  87,  88,  89,  90,  91,  92,  93,  94,  95,
      96,  97,  98,  99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127,
      128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159,
      160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180, 181, 182, 183, 184, 185, 186, 187, 188, 189, 190, 191,
      192, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223,
      224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255,
      256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279, 280, 281, 282, 283, 284, 285, 286, 287,
      288, 289, 290, 291, 292, 293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 304, 305, 306, 307, 308, 309, 310, 311, 312, 313, 314, 315, 316, 317, 318, 319,
      320, 321, 322, 323, 324, 325, 326, 327, 328, 329, 330, 331, 332, 333, 334, 335, 336, 337, 338, 339, 340, 341, 342, 343, 344, 345, 346, 347, 348, 349, 350, 351,
      352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 362, 363, 364, 365, 366, 367, 368, 369, 370, 371, 372, 373, 374, 375, 376, 377, 378, 379, 380, 381, 382, 383,
      384, 385, 386, 387, 388, 389, 390, 391, 392, 393, 394, 395, 396, 397, 398, 399, 400, 401, 402, 403, 404, 405, 406, 407, 408, 409, 410, 411, 412, 413, 414, 415,
      416, 417, 418, 419, 420, 421, 422, 423, 424, 425, 426, 427, 428, 429, 430, 431, 432, 433, 434, 435, 436, 437, 438, 439, 440, 441, 442, 443, 444, 445, 446, 447,
      448, 449, 450, 451, 452, 453, 454, 455, 456, 457, 458, 459, 460, 461, 462, 463, 464, 465, 466, 467, 468, 469, 470, 471, 472, 473, 474, 475, 476, 477, 478, 479,
      480, 481, 482, 483, 484, 485, 486, 487, 488, 489, 490, 491, 492, 493, 494, 495, 496, 497, 498, 499, 500, 501, 502, 503, 504, 505, 506, 507, 508, 509, 510, 511,
      512, 513, 514, 515, 516, 517, 518, 519, 520, 521, 522, 523, 524, 525, 526, 527, 528, 529, 530, 531, 532, 533, 534, 535, 536, 537, 538, 539, 540, 541, 542, 543,
      544, 545, 546, 547, 548, 549, 550, 551, 552, 553, 554, 555, 556, 557, 558, 559, 560, 561, 562, 563, 564, 565, 566, 567, 568, 569, 570, 571, 572, 573, 574, 575,
      576, 577, 578, 579, 580, 581, 582, 583, 584, 585, 586, 587, 588, 589, 590, 591, 592, 593, 594, 595, 596, 597, 598, 599, 600, 601, 602, 603, 604, 605, 606, 607,
      608, 609, 610, 611, 612, 613, 614, 615, 616, 617, 618, 619, 620, 621, 622, 623, 624, 625, 626, 627, 628, 629, 630, 631, 632, 633, 634, 635, 636, 637, 638, 639,
      640, 641, 642, 643, 644, 645, 646, 647, 648, 649, 650, 651, 652, 653, 654, 655, 656, 657, 658, 659, 660, 661, 662, 663, 664, 665, 666, 667, 668, 669, 670, 671,
      672, 673, 674, 675, 676, 677, 678, 679, 680, 681, 682, 683, 684, 685, 686, 687, 688, 689, 690, 691, 692, 693, 694, 695, 696, 697, 698, 699, 700, 701, 702, 703,
      704, 705, 706, 707, 708, 709, 710, 711, 712, 713, 714, 715, 716, 717, 718, 719, 720, 721, 722, 723, 724, 725, 726, 727, 728, 729, 730, 731, 732, 733, 734, 735,
      736, 737, 738, 739, 740, 741, 742, 743, 744, 745, 746, 747, 748, 749, 750, 751, 752, 753, 754, 755, 756, 757, 758, 759, 760, 761, 762, 763, 764, 765, 766, 767,
      768, 769, 770, 771, 772, 773, 774, 775, 776, 777, 778, 779, 780, 781, 782, 783, 784, 785, 786, 787, 788, 789, 790, 791, 792, 793, 794, 795, 796, 797, 798, 799,
      800, 801, 802, 803, 804, 805, 806, 807, 808, 809, 810, 811, 812, 813, 814, 815, 816, 817, 818, 819, 820, 821, 822, 823, 824, 825, 826, 827, 828, 829, 830, 831,
      832, 833, 834, 835, 836, 837, 838, 839, 840, 841, 842, 843, 844, 845, 846, 847, 848, 849, 850, 851, 852, 853, 854, 855, 856, 857, 858, 859, 860, 861, 862, 863,
      864, 865, 866, 867, 868, 869, 870, 871, 872, 873, 874, 875, 876, 877, 878, 879, 880, 881, 882, 883, 884, 885, 886, 887, 888, 889, 890, 891, 892, 893, 894, 895,
      896, 897, 898, 899, 900, 901, 902, 903, 904, 905, 906, 907, 908, 909, 910, 911, 912, 913, 914, 915, 916, 917, 918, 919, 920, 921, 922, 923, 924, 925, 926, 927,
      928, 929, 930, 931, 932, 933, 934, 935, 936, 937, 938, 939, 940, 941, 942, 943, 944, 945, 946, 947, 948, 949, 950, 951, 952, 953, 954, 955, 956, 957, 958, 959,
      960, 961, 962, 963, 964, 965, 966, 967, 968, 969, 970, 971, 972, 973, 974, 975, 976, 977, 978, 979, 980, 981, 982, 983, 984, 985, 986, 987, 988, 989, 990, 991,
      992, 993, 994, 995, 996, 997, 998, 999, 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014, 1015, 1016, 1017, 1018, 1019, 1020, 1021, 1022, 1023
    };
    
    XCTAssert(blockiVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
//      int blocki = blockiVec[i];
//      int bigBlocki = (blocki / (blockiDim * blockiDim));
//      int bigBlockRooti = bigBlocki * (blockiDim * blockiDim);
//      int bigBlockOffset = (blocki - bigBlockRooti);
//      int offset = bigBlockRooti + bigBlockOffset;
//      uint32_t lookupBlocki = blockiLookupVec[offset];
//
//      if ((1)) {
//        printf("blocki %3d : bigBlocki %3d : bigBlockRooti %3d : lookupBlocki %3d\n", blocki, bigBlocki, bigBlockRooti, lookupBlocki);
//      }
      
      uint32_t blocki = blockiVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  {
    uint32_t expected[] = {
      0,   1,   2,   3,  32,  33,  34,  35,  64,  65,  66,  67,  96,  97,  98,  99,   4,   5,   6,   7,  36,  37,  38,  39,  68,  69,  70,  71, 100, 101, 102, 103,
      8,   9,  10,  11,  40,  41,  42,  43,  72,  73,  74,  75, 104, 105, 106, 107,  12,  13,  14,  15,  44,  45,  46,  47,  76,  77,  78,  79, 108, 109, 110, 111,
      16,  17,  18,  19,  48,  49,  50,  51,  80,  81,  82,  83, 112, 113, 114, 115,  20,  21,  22,  23,  52,  53,  54,  55,  84,  85,  86,  87, 116, 117, 118, 119,
      24,  25,  26,  27,  56,  57,  58,  59,  88,  89,  90,  91, 120, 121, 122, 123,  28,  29,  30,  31,  60,  61,  62,  63,  92,  93,  94,  95, 124, 125, 126, 127,
      128, 129, 130, 131, 160, 161, 162, 163, 192, 193, 194, 195, 224, 225, 226, 227, 132, 133, 134, 135, 164, 165, 166, 167, 196, 197, 198, 199, 228, 229, 230, 231,
      136, 137, 138, 139, 168, 169, 170, 171, 200, 201, 202, 203, 232, 233, 234, 235, 140, 141, 142, 143, 172, 173, 174, 175, 204, 205, 206, 207, 236, 237, 238, 239,
      144, 145, 146, 147, 176, 177, 178, 179, 208, 209, 210, 211, 240, 241, 242, 243, 148, 149, 150, 151, 180, 181, 182, 183, 212, 213, 214, 215, 244, 245, 246, 247,
      152, 153, 154, 155, 184, 185, 186, 187, 216, 217, 218, 219, 248, 249, 250, 251, 156, 157, 158, 159, 188, 189, 190, 191, 220, 221, 222, 223, 252, 253, 254, 255,
      256, 257, 258, 259, 288, 289, 290, 291, 320, 321, 322, 323, 352, 353, 354, 355, 260, 261, 262, 263, 292, 293, 294, 295, 324, 325, 326, 327, 356, 357, 358, 359,
      264, 265, 266, 267, 296, 297, 298, 299, 328, 329, 330, 331, 360, 361, 362, 363, 268, 269, 270, 271, 300, 301, 302, 303, 332, 333, 334, 335, 364, 365, 366, 367,
      272, 273, 274, 275, 304, 305, 306, 307, 336, 337, 338, 339, 368, 369, 370, 371, 276, 277, 278, 279, 308, 309, 310, 311, 340, 341, 342, 343, 372, 373, 374, 375,
      280, 281, 282, 283, 312, 313, 314, 315, 344, 345, 346, 347, 376, 377, 378, 379, 284, 285, 286, 287, 316, 317, 318, 319, 348, 349, 350, 351, 380, 381, 382, 383,
      384, 385, 386, 387, 416, 417, 418, 419, 448, 449, 450, 451, 480, 481, 482, 483, 388, 389, 390, 391, 420, 421, 422, 423, 452, 453, 454, 455, 484, 485, 486, 487,
      392, 393, 394, 395, 424, 425, 426, 427, 456, 457, 458, 459, 488, 489, 490, 491, 396, 397, 398, 399, 428, 429, 430, 431, 460, 461, 462, 463, 492, 493, 494, 495,
      400, 401, 402, 403, 432, 433, 434, 435, 464, 465, 466, 467, 496, 497, 498, 499, 404, 405, 406, 407, 436, 437, 438, 439, 468, 469, 470, 471, 500, 501, 502, 503,
      408, 409, 410, 411, 440, 441, 442, 443, 472, 473, 474, 475, 504, 505, 506, 507, 412, 413, 414, 415, 444, 445, 446, 447, 476, 477, 478, 479, 508, 509, 510, 511,
      512, 513, 514, 515, 544, 545, 546, 547, 576, 577, 578, 579, 608, 609, 610, 611, 516, 517, 518, 519, 548, 549, 550, 551, 580, 581, 582, 583, 612, 613, 614, 615,
      520, 521, 522, 523, 552, 553, 554, 555, 584, 585, 586, 587, 616, 617, 618, 619, 524, 525, 526, 527, 556, 557, 558, 559, 588, 589, 590, 591, 620, 621, 622, 623,
      528, 529, 530, 531, 560, 561, 562, 563, 592, 593, 594, 595, 624, 625, 626, 627, 532, 533, 534, 535, 564, 565, 566, 567, 596, 597, 598, 599, 628, 629, 630, 631,
      536, 537, 538, 539, 568, 569, 570, 571, 600, 601, 602, 603, 632, 633, 634, 635, 540, 541, 542, 543, 572, 573, 574, 575, 604, 605, 606, 607, 636, 637, 638, 639,
      640, 641, 642, 643, 672, 673, 674, 675, 704, 705, 706, 707, 736, 737, 738, 739, 644, 645, 646, 647, 676, 677, 678, 679, 708, 709, 710, 711, 740, 741, 742, 743,
      648, 649, 650, 651, 680, 681, 682, 683, 712, 713, 714, 715, 744, 745, 746, 747, 652, 653, 654, 655, 684, 685, 686, 687, 716, 717, 718, 719, 748, 749, 750, 751,
      656, 657, 658, 659, 688, 689, 690, 691, 720, 721, 722, 723, 752, 753, 754, 755, 660, 661, 662, 663, 692, 693, 694, 695, 724, 725, 726, 727, 756, 757, 758, 759,
      664, 665, 666, 667, 696, 697, 698, 699, 728, 729, 730, 731, 760, 761, 762, 763, 668, 669, 670, 671, 700, 701, 702, 703, 732, 733, 734, 735, 764, 765, 766, 767,
      768, 769, 770, 771, 800, 801, 802, 803, 832, 833, 834, 835, 864, 865, 866, 867, 772, 773, 774, 775, 804, 805, 806, 807, 836, 837, 838, 839, 868, 869, 870, 871,
      776, 777, 778, 779, 808, 809, 810, 811, 840, 841, 842, 843, 872, 873, 874, 875, 780, 781, 782, 783, 812, 813, 814, 815, 844, 845, 846, 847, 876, 877, 878, 879,
      784, 785, 786, 787, 816, 817, 818, 819, 848, 849, 850, 851, 880, 881, 882, 883, 788, 789, 790, 791, 820, 821, 822, 823, 852, 853, 854, 855, 884, 885, 886, 887,
      792, 793, 794, 795, 824, 825, 826, 827, 856, 857, 858, 859, 888, 889, 890, 891, 796, 797, 798, 799, 828, 829, 830, 831, 860, 861, 862, 863, 892, 893, 894, 895,
      896, 897, 898, 899, 928, 929, 930, 931, 960, 961, 962, 963, 992, 993, 994, 995, 900, 901, 902, 903, 932, 933, 934, 935, 964, 965, 966, 967, 996, 997, 998, 999,
      904, 905, 906, 907, 936, 937, 938, 939, 968, 969, 970, 971, 1000, 1001, 1002, 1003, 908, 909, 910, 911, 940, 941, 942, 943, 972, 973, 974, 975, 1004, 1005, 1006, 1007,
      912, 913, 914, 915, 944, 945, 946, 947, 976, 977, 978, 979, 1008, 1009, 1010, 1011, 916, 917, 918, 919, 948, 949, 950, 951, 980, 981, 982, 983, 1012, 1013, 1014, 1015,
      920, 921, 922, 923, 952, 953, 954, 955, 984, 985, 986, 987, 1016, 1017, 1018, 1019, 924, 925, 926, 927, 956, 957, 958, 959, 988, 989, 990, 991, 1020, 1021, 1022, 1023
    };
    
    XCTAssert(blockiLookupVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiLookupVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiLookupVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  // Iterate over block ordered blockiVec and then lookup the blocki value
  // that corresponds to the original blocki.
  
  vector<uint32_t> iterOrder;
  
  for ( uint32_t blocki : blockiVec ) {
    uint32_t iterBlocki = blockiLookupVec[blocki];
    iterOrder.push_back(iterBlocki);
  }
  
  {
    uint32_t expected[] = {
      0,   1,   2,   3,  32,  33,  34,  35,  64,  65,  66,  67,  96,  97,  98,  99,   4,   5,   6,   7,  36,  37,  38,  39,  68,  69,  70,  71, 100, 101, 102, 103,
      8,   9,  10,  11,  40,  41,  42,  43,  72,  73,  74,  75, 104, 105, 106, 107,  12,  13,  14,  15,  44,  45,  46,  47,  76,  77,  78,  79, 108, 109, 110, 111,
      16,  17,  18,  19,  48,  49,  50,  51,  80,  81,  82,  83, 112, 113, 114, 115,  20,  21,  22,  23,  52,  53,  54,  55,  84,  85,  86,  87, 116, 117, 118, 119,
      24,  25,  26,  27,  56,  57,  58,  59,  88,  89,  90,  91, 120, 121, 122, 123,  28,  29,  30,  31,  60,  61,  62,  63,  92,  93,  94,  95, 124, 125, 126, 127,
      128, 129, 130, 131, 160, 161, 162, 163, 192, 193, 194, 195, 224, 225, 226, 227, 132, 133, 134, 135, 164, 165, 166, 167, 196, 197, 198, 199, 228, 229, 230, 231,
      136, 137, 138, 139, 168, 169, 170, 171, 200, 201, 202, 203, 232, 233, 234, 235, 140, 141, 142, 143, 172, 173, 174, 175, 204, 205, 206, 207, 236, 237, 238, 239,
      144, 145, 146, 147, 176, 177, 178, 179, 208, 209, 210, 211, 240, 241, 242, 243, 148, 149, 150, 151, 180, 181, 182, 183, 212, 213, 214, 215, 244, 245, 246, 247,
      152, 153, 154, 155, 184, 185, 186, 187, 216, 217, 218, 219, 248, 249, 250, 251, 156, 157, 158, 159, 188, 189, 190, 191, 220, 221, 222, 223, 252, 253, 254, 255,
      256, 257, 258, 259, 288, 289, 290, 291, 320, 321, 322, 323, 352, 353, 354, 355, 260, 261, 262, 263, 292, 293, 294, 295, 324, 325, 326, 327, 356, 357, 358, 359,
      264, 265, 266, 267, 296, 297, 298, 299, 328, 329, 330, 331, 360, 361, 362, 363, 268, 269, 270, 271, 300, 301, 302, 303, 332, 333, 334, 335, 364, 365, 366, 367,
      272, 273, 274, 275, 304, 305, 306, 307, 336, 337, 338, 339, 368, 369, 370, 371, 276, 277, 278, 279, 308, 309, 310, 311, 340, 341, 342, 343, 372, 373, 374, 375,
      280, 281, 282, 283, 312, 313, 314, 315, 344, 345, 346, 347, 376, 377, 378, 379, 284, 285, 286, 287, 316, 317, 318, 319, 348, 349, 350, 351, 380, 381, 382, 383,
      384, 385, 386, 387, 416, 417, 418, 419, 448, 449, 450, 451, 480, 481, 482, 483, 388, 389, 390, 391, 420, 421, 422, 423, 452, 453, 454, 455, 484, 485, 486, 487,
      392, 393, 394, 395, 424, 425, 426, 427, 456, 457, 458, 459, 488, 489, 490, 491, 396, 397, 398, 399, 428, 429, 430, 431, 460, 461, 462, 463, 492, 493, 494, 495,
      400, 401, 402, 403, 432, 433, 434, 435, 464, 465, 466, 467, 496, 497, 498, 499, 404, 405, 406, 407, 436, 437, 438, 439, 468, 469, 470, 471, 500, 501, 502, 503,
      408, 409, 410, 411, 440, 441, 442, 443, 472, 473, 474, 475, 504, 505, 506, 507, 412, 413, 414, 415, 444, 445, 446, 447, 476, 477, 478, 479, 508, 509, 510, 511,
      512, 513, 514, 515, 544, 545, 546, 547, 576, 577, 578, 579, 608, 609, 610, 611, 516, 517, 518, 519, 548, 549, 550, 551, 580, 581, 582, 583, 612, 613, 614, 615,
      520, 521, 522, 523, 552, 553, 554, 555, 584, 585, 586, 587, 616, 617, 618, 619, 524, 525, 526, 527, 556, 557, 558, 559, 588, 589, 590, 591, 620, 621, 622, 623,
      528, 529, 530, 531, 560, 561, 562, 563, 592, 593, 594, 595, 624, 625, 626, 627, 532, 533, 534, 535, 564, 565, 566, 567, 596, 597, 598, 599, 628, 629, 630, 631,
      536, 537, 538, 539, 568, 569, 570, 571, 600, 601, 602, 603, 632, 633, 634, 635, 540, 541, 542, 543, 572, 573, 574, 575, 604, 605, 606, 607, 636, 637, 638, 639,
      640, 641, 642, 643, 672, 673, 674, 675, 704, 705, 706, 707, 736, 737, 738, 739, 644, 645, 646, 647, 676, 677, 678, 679, 708, 709, 710, 711, 740, 741, 742, 743,
      648, 649, 650, 651, 680, 681, 682, 683, 712, 713, 714, 715, 744, 745, 746, 747, 652, 653, 654, 655, 684, 685, 686, 687, 716, 717, 718, 719, 748, 749, 750, 751,
      656, 657, 658, 659, 688, 689, 690, 691, 720, 721, 722, 723, 752, 753, 754, 755, 660, 661, 662, 663, 692, 693, 694, 695, 724, 725, 726, 727, 756, 757, 758, 759,
      664, 665, 666, 667, 696, 697, 698, 699, 728, 729, 730, 731, 760, 761, 762, 763, 668, 669, 670, 671, 700, 701, 702, 703, 732, 733, 734, 735, 764, 765, 766, 767,
      768, 769, 770, 771, 800, 801, 802, 803, 832, 833, 834, 835, 864, 865, 866, 867, 772, 773, 774, 775, 804, 805, 806, 807, 836, 837, 838, 839, 868, 869, 870, 871,
      776, 777, 778, 779, 808, 809, 810, 811, 840, 841, 842, 843, 872, 873, 874, 875, 780, 781, 782, 783, 812, 813, 814, 815, 844, 845, 846, 847, 876, 877, 878, 879,
      784, 785, 786, 787, 816, 817, 818, 819, 848, 849, 850, 851, 880, 881, 882, 883, 788, 789, 790, 791, 820, 821, 822, 823, 852, 853, 854, 855, 884, 885, 886, 887,
      792, 793, 794, 795, 824, 825, 826, 827, 856, 857, 858, 859, 888, 889, 890, 891, 796, 797, 798, 799, 828, 829, 830, 831, 860, 861, 862, 863, 892, 893, 894, 895,
      896, 897, 898, 899, 928, 929, 930, 931, 960, 961, 962, 963, 992, 993, 994, 995, 900, 901, 902, 903, 932, 933, 934, 935, 964, 965, 966, 967, 996, 997, 998, 999,
      904, 905, 906, 907, 936, 937, 938, 939, 968, 969, 970, 971, 1000, 1001, 1002, 1003, 908, 909, 910, 911, 940, 941, 942, 943, 972, 973, 974, 975, 1004, 1005, 1006, 1007,
      912, 913, 914, 915, 944, 945, 946, 947, 976, 977, 978, 979, 1008, 1009, 1010, 1011, 916, 917, 918, 919, 948, 949, 950, 951, 980, 981, 982, 983, 1012, 1013, 1014, 1015,
      920, 921, 922, 923, 952, 953, 954, 955, 984, 985, 986, 987, 1016, 1017, 1018, 1019, 924, 925, 926, 927, 956, 957, 958, 959, 988, 989, 990, 991, 1020, 1021, 1022, 1023
    };
    
    XCTAssert(iterOrder.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = iterOrder[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"iterOrder[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  return;
}

// 4x4 block size with blockiDim set to 4x4 such that 16 blocki elements
// are collected into one big block.

- (void)testBlockiGenerateReorder_2x2_BB_4x4_8x8 {
  const int blockDim = 2;
  const int blockiDim = 4;
  
  // 2x2 blocks where blocks of 4x4 are collected into big blocks
  // that contain 16 small blocks.

  uint8_t inBlockValues[] = {
    0, 0, 1, 1, 2, 2, 3, 3,
    0, 0, 1, 1, 2, 2, 3, 3,
    4, 4, 5, 5, 6, 6, 7, 7,
    4, 4, 5, 5, 6, 6, 7, 7,
    8, 8, 9, 9, 10, 10, 11, 11,
    8, 8, 9, 9, 10, 10, 11, 11,
    12, 12, 13, 13, 14, 14, 15, 15,
    12, 12, 13, 13, 14, 14, 15, 15
  };

  const unsigned int width = 8;
  const unsigned int height = 8;
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec);
  
  {
    uint32_t expected[] = {
      0, 1, 2, 3,
      4, 5, 6, 7,
      8, 9, 10, 11,
      12, 13, 14, 15
    };
    
    XCTAssert(blockiVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  {
    uint32_t expected[] = {
      0, 1, 2, 3,
      4, 5, 6, 7,
      8, 9, 10, 11,
      12, 13, 14, 15
    };
    
    XCTAssert(blockiLookupVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiLookupVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiLookupVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  // Split original image data into blocks and then use the block
  // iteration ordering to lookup the value in each block in
  // big block iteration order.
  
  {
    const int numInPixels = width * height;
    
    BlockEncoder<uint8_t, blockDim> encoder;
    
    unsigned int numBlocksInWidth, numBlocksInHeight;
    
    encoder.calcBlockWidthAndHeight(width, height, numBlocksInWidth, numBlocksInHeight);
    
    encoder.splitIntoBlocks(inBlockValues, numInPixels, width, height, numBlocksInWidth, numBlocksInHeight, 0);
    
    vector<uint8_t> outVec;

    for ( vector<uint8_t> & inOutBlockVec : encoder.blockVectors ) {
      for ( uint8_t bVal : inOutBlockVec ) {
        outVec.push_back(bVal);
      }
    }
    
    int numValues = numBlocksInWidth * numBlocksInHeight * blockDim * blockDim;
    
    XCTAssert(outVec.size() == numValues);
    
    // Lookup 4 values for each blocki
    
    vector<uint8_t> valuesInIterOrder;
    
    for ( uint32_t blocki : blockiVec ) {
      uint32_t iterBlocki = blockiLookupVec[blocki];
      uint8_t * blockStartPtr = &outVec[iterBlocki * (blockDim * blockDim)];
      for (int i = 0; i < (blockDim * blockDim); i++) {
        uint8_t bVal = *blockStartPtr++;
        valuesInIterOrder.push_back(bVal);
      }
    }
    
    XCTAssert(valuesInIterOrder.size() == numValues);
    
    {
      uint32_t expected[] = {
        0, 0, 0, 0,
        1, 1, 1, 1,
        2, 2, 2, 2,
        3, 3, 3, 3,
        
        4, 4, 4, 4,
        5, 5, 5, 5,
        6, 6, 6, 6,
        7, 7, 7, 7,
        
        8, 8, 8, 8,
        9, 9, 9, 9,
        10, 10, 10, 10,
        11, 11, 11, 11,
        
        12, 12, 12, 12,
        13, 13, 13, 13,
        14, 14, 14, 14,
        15, 15, 15, 15
      };
      
      XCTAssert(valuesInIterOrder.size() == sizeof(expected)/sizeof(uint32_t));
      
      for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
        uint8_t val = valuesInIterOrder[i];
        uint8_t expectedVal = expected[i];
        
        XCTAssert(val == expectedVal, @"iterOrder[%4d] != expected[%4d] : %4d != %4d", i, i, val, expectedVal);
      }
    }
  }
  
  return;
}

// 2x2 block size with blockiDim set to 4x4 such that 16 blocki elements
// are collected into one big block.

- (void)testBlockiGenerateReorder_2x2_BB_4x4_16x8 {
  const int blockDim = 2;
  const int blockiDim = 4;
  
  // 2x2 blocks where blocks of 4x4 are collected into big blocks
  // that contain 16 small blocks.
  
  uint8_t inBlockValues[] = {
    0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7,
    0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7,
    8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15,
    8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15,
    16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, 23, 23,
    16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, 23, 23,
    24, 24, 25, 25, 26, 26, 27, 27, 28, 28, 29, 29, 30, 30, 31, 31,
    24, 24, 25, 25, 26, 26, 27, 27, 28, 28, 29, 29, 30, 30, 31, 31
  };
  
  const unsigned int width = 16;
  const unsigned int height = 8;
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec);
  
  {
    uint32_t expected[] = {
      0, 1, 2, 3, 4, 5, 6, 7,
      8, 9, 10, 11, 12, 13, 14, 15,
      16, 17, 18, 19, 20, 21, 22, 23,
      24, 25, 26, 27, 28, 29, 30, 31
    };
    
    XCTAssert(blockiVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  {
    uint32_t expected[] = {
      0, 1, 2, 3,
      8, 9, 10, 11,
      16, 17, 18, 19,
      24, 25, 26, 27,
      
      4, 5, 6, 7,
      12, 13, 14, 15,
      20, 21, 22, 23,
      28, 29, 30, 31
    };
    
    XCTAssert(blockiLookupVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiLookupVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiLookupVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  // Split original image data into blocks and then use the block
  // iteration ordering to lookup the value in each block in
  // big block iteration order.
  
  {
    const int numInPixels = width * height;
    
    BlockEncoder<uint8_t, blockDim> encoder;
    
    unsigned int numBlocksInWidth, numBlocksInHeight;
    
    encoder.calcBlockWidthAndHeight(width, height, numBlocksInWidth, numBlocksInHeight);
    
    encoder.splitIntoBlocks(inBlockValues, numInPixels, width, height, numBlocksInWidth, numBlocksInHeight, 0);
    
    vector<uint8_t> outVec;
    
    for ( vector<uint8_t> & inOutBlockVec : encoder.blockVectors ) {
      for ( uint8_t bVal : inOutBlockVec ) {
        outVec.push_back(bVal);
      }
    }
    
    int numValues = numBlocksInWidth * numBlocksInHeight * blockDim * blockDim;
    
    XCTAssert(outVec.size() == numValues);
    
    // Lookup 4 values for each blocki
    
    vector<int> valuesInIterOrder;
    
    for ( uint32_t blocki : blockiVec ) {
      uint32_t iterBlocki = blockiLookupVec[blocki];
      uint8_t * blockStartPtr = &outVec[iterBlocki * (blockDim * blockDim)];
      for (int i = 0; i < (blockDim * blockDim); i++) {
        uint8_t bVal = *blockStartPtr++;
        valuesInIterOrder.push_back(bVal);
      }
    }
    
    XCTAssert(valuesInIterOrder.size() == numValues);
    
    {
      uint32_t expected[] = {
        0, 0, 0, 0,
        1, 1, 1, 1,
        2, 2, 2, 2,
        3, 3, 3, 3,

        8, 8, 8, 8,
        9, 9, 9, 9,
        10, 10, 10, 10,
        11, 11, 11, 11,
        
        16, 16, 16, 16,
        17, 17, 17, 17,
        18, 18, 18, 18,
        19, 19, 19, 19,
        
        24, 24, 24, 24,
        25, 25, 25, 25,
        26, 26, 26, 26,
        27, 27, 27, 27,

        4, 4, 4, 4,
        5, 5, 5, 5,
        6, 6, 6, 6,
        7, 7, 7, 7,
        
        12, 12, 12, 12,
        13, 13, 13, 13,
        14, 14, 14, 14,
        15, 15, 15, 15,
        
        20, 20, 20, 20,
        21, 21, 21, 21,
        22, 22, 22, 22,
        23, 23, 23, 23,

        28, 28, 28, 28,
        29, 29, 29, 29,
        30, 30, 30, 30,
        31, 31, 31, 31
      };
      
      XCTAssert(valuesInIterOrder.size() == sizeof(expected)/sizeof(uint32_t));
      
      for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
        int val = valuesInIterOrder[i];
        int expectedVal = expected[i];
        
        XCTAssert(val == expectedVal, @"iterOrder[%4d] != expected[%4d] : %4d != %4d", i, i, val, expectedVal);
      }
    }
  }
  
  return;
}

// In this test case, there are not enough blocks to fill
// the height evenly.

- (void)testBlockiGenerateReorder_2x2_BB_4x4_16x8_padded {
  const int blockDim = 2;
  const int blockiDim = 4;
  
  // 2x2 blocks where blocks of 4x4 are collected into big blocks
  // that contain 16 small blocks.
  
  uint8_t inBlockValues[] = {
    0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7,
    0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7,
    8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15,
    8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15,
    16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, 23, 23,
    16, 16, 17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, 23, 23
  };
  
  const unsigned int width = 16;
  const unsigned int height = 6;
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec);
  
  {
    uint32_t expected[] = {
      0, 1, 2, 3, 4, 5, 6, 7,
      8, 9, 10, 11, 12, 13, 14, 15,
      16, 17, 18, 19, 20, 21, 22, 23
    };
    
    XCTAssert(blockiVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  {
    uint32_t expected[] = {
      0, 1, 2, 3,
      8, 9, 10, 11,
      16, 17, 18, 19,
      //0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
      
      4, 5, 6, 7,
      12, 13, 14, 15,
      20, 21, 22, 23,
      //0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
    };
    
    XCTAssert(blockiLookupVec.size() == sizeof(expected)/sizeof(uint32_t));
    
    for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
      uint32_t blocki = blockiLookupVec[i];
      uint32_t expectedVal = expected[i];
      
      XCTAssert(blocki == expectedVal, @"blockiLookupVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
  
  // Split original image data into blocks and then use the block
  // iteration ordering to lookup the value in each block in
  // big block iteration order.
  
  {
    const int numInPixels = width * height;
    
    BlockEncoder<uint8_t, blockDim> encoder;
    
    unsigned int numBlocksInWidth, numBlocksInHeight;
    
    encoder.calcBlockWidthAndHeight(width, height, numBlocksInWidth, numBlocksInHeight);
    
    encoder.splitIntoBlocks(inBlockValues, numInPixels, width, height, numBlocksInWidth, numBlocksInHeight, 0);
    
    vector<uint8_t> outVec;
    
    for ( vector<uint8_t> & inOutBlockVec : encoder.blockVectors ) {
      for ( uint8_t bVal : inOutBlockVec ) {
        outVec.push_back(bVal);
      }
    }
    
    int numValues = numBlocksInWidth * numBlocksInHeight * blockDim * blockDim;
    
    XCTAssert(outVec.size() == numValues);
    
    // Lookup 4 values for each blocki
    
    vector<int> valuesInIterOrder;
    
    for ( uint32_t blocki : blockiVec ) {
      uint32_t iterBlocki = blockiLookupVec[blocki];
      uint8_t * blockStartPtr = &outVec[iterBlocki * (blockDim * blockDim)];
      for (int i = 0; i < (blockDim * blockDim); i++) {
        uint8_t bVal = *blockStartPtr++;
        valuesInIterOrder.push_back(bVal);
      }
    }
    
    XCTAssert(valuesInIterOrder.size() == numValues);
    
    {
      uint32_t expected[] = {
        0, 0, 0, 0,
        1, 1, 1, 1,
        2, 2, 2, 2,
        3, 3, 3, 3,
        
        8, 8, 8, 8,
        9, 9, 9, 9,
        10, 10, 10, 10,
        11, 11, 11, 11,
        
        16, 16, 16, 16,
        17, 17, 17, 17,
        18, 18, 18, 18,
        19, 19, 19, 19,
        
        4, 4, 4, 4,
        5, 5, 5, 5,
        6, 6, 6, 6,
        7, 7, 7, 7,
        
        12, 12, 12, 12,
        13, 13, 13, 13,
        14, 14, 14, 14,
        15, 15, 15, 15,
        
        20, 20, 20, 20,
        21, 21, 21, 21,
        22, 22, 22, 22,
        23, 23, 23, 23
      };
      
      XCTAssert(valuesInIterOrder.size() == sizeof(expected)/sizeof(uint32_t));
      
      for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
        int val = valuesInIterOrder[i];
        int expectedVal = expected[i];
        
        XCTAssert(val == expectedVal, @"iterOrder[%4d] != expected[%4d] : %4d != %4d", i, i, val, expectedVal);
      }
    }
  }
  
  return;
}

// First Fail: test config 260x4 : block 130x2
// width = 260
// height = 4

- (void)testBlocki_2x2_BW_130x2 {
  const int blockDim = 2;
  const int blockiDim = 2;
  
  const unsigned int width = 260;
  const unsigned int height = 4;
  
  int numBlocksInWidth = width / blockDim;
  int numBlocksInHeight = height / blockDim;
  int numBlocks = numBlocksInWidth * numBlocksInHeight;
  
  NSLog(@"test config %dx%d : block %dx%d", width, height, numBlocksInWidth, numBlocksInHeight);
  
  // Generate an input vector in block order for
  // numBlocks elements.
  
  vector<uint8_t> inBlockOrderVec;
  inBlockOrderVec.reserve(width * height);
  
  for (int blocki = 0; blocki < numBlocks; blocki++) {
    // 4 elements for each 2x2 block
    
    for (int i = 0; i < (blockDim * blockDim); i++) {
      inBlockOrderVec.push_back(blocki);
    }
  }
  
  // Reorder block order values into image order
  
  vector<uint8_t> inImageOrderVec;
  inImageOrderVec.resize(width * height);
  
  flattenBlocksOfSize(blockDim, inBlockOrderVec.data(), inImageOrderVec.data(),
                      numBlocksInWidth, numBlocksInHeight);
  
  // 2x2 blocks where a big block is 4x4 values
  
  //  uint8_t inBlockValues[] = {
  //    0, 0, 1, 1, 2, 2, 3, 3,
  //    0, 0, 1, 1, 2, 2, 3, 3,
  //    4, 4, 5, 5, 6, 6, 7, 7,
  //    4, 4, 5, 5, 6, 6, 7, 7
  //  };
  
  uint8_t *inBlockValues = inImageOrderVec.data();
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec);
  
  {
    vector<uint32_t> expectedVec;
    
    for (int blocki = 0; blocki < numBlocks; blocki++) {
      expectedVec.push_back(blocki);
    }
    
    XCTAssert(blockiVec.size() == expectedVec.size());
    
    for (int i = 0; i < expectedVec.size(); i++) {
      uint32_t blocki = blockiVec[i];
      uint32_t expectedVal = expectedVec[i];
      if (blocki != expectedVal) {
        XCTAssert(blocki == expectedVal, @"blockiVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
      }
    }
  }
  
  // Split original image data into blocks and then use the block
  // iteration ordering to lookup the value in each block in
  // big block iteration order.
  
  {
    const int numInPixels = width * height;
    
    BlockEncoder<uint8_t, blockDim> encoder;
    
    unsigned int numBlocksInWidth, numBlocksInHeight;
    
    encoder.calcBlockWidthAndHeight(width, height, numBlocksInWidth, numBlocksInHeight);
    
    encoder.splitIntoBlocks(inBlockValues, numInPixels, width, height, numBlocksInWidth, numBlocksInHeight, 0);
    
    vector<uint8_t> outVec;
    
    for ( vector<uint8_t> & inOutBlockVec : encoder.blockVectors ) {
      for ( uint8_t bVal : inOutBlockVec ) {
        outVec.push_back(bVal);
      }
    }
    
    int numValues = numBlocksInWidth * numBlocksInHeight * blockDim * blockDim;
    
    XCTAssert(outVec.size() == numValues);
    
    // Lookup 4 values for each blocki
    
    vector<int> valuesInIterOrder;
    
    for ( uint32_t blocki : blockiVec ) {
      uint32_t iterBlocki = blockiLookupVec[blocki];
      uint8_t * blockStartPtr = &outVec[iterBlocki * (blockDim * blockDim)];
      for (int i = 0; i < (blockDim * blockDim); i++) {
        int bVal = (int) *blockStartPtr++;
        valuesInIterOrder.push_back(bVal);
      }
    }
    
    XCTAssert(valuesInIterOrder.size() == numValues);
    
    // Each lookup value should correspond to the blocki value
    // used to lookup that value. Generate expected output
    // by repeating the iterBlocki value (blockDim * blockDim) times
    
    {
      vector<uint8_t> expectedVec;
      
      for (int blocki = 0; blocki < numBlocks; blocki++) {
        uint32_t iterBlocki = blockiLookupVec[blocki];
        
        for (int i = 0; i < (blockDim * blockDim); i++) {
          expectedVec.push_back(iterBlocki);
        }
      }
      
//      uint32_t expected[] = {
//        0, 0, 0, 0,
//        1, 1, 1, 1,
//
//        4, 4, 4, 4,
//        5, 5, 5, 5,
//
//        2, 2, 2, 2,
//        3, 3, 3, 3,
//
//        6, 6, 6, 6,
//        7, 7, 7, 7
//      };

      XCTAssert(valuesInIterOrder.size() == expectedVec.size());
      
      for (int i = 0; i < expectedVec.size(); i++) {
        uint8_t val = valuesInIterOrder[i];
        uint8_t expectedVal = expectedVec[i];
        
        if (val != expectedVal) {
          XCTAssert(val == expectedVal, @"iterOrder[%4d] != expected[%4d] : %4d != %4d", i, i, val, expectedVal);
        }
      }
    }
  }
  
  return;
}

// 2x2 block size with blockiDim set to 4x4 such that 16 blocki elements
// are collected into one big block.

- (void) testBlockiGenerateExpanding2x2 {
  const int blockDim = 2;
  const int blockiDim = 2;
  
  const unsigned int height = blockDim * blockiDim;
  //const unsigned int height = blockDim * blockiDim * 2;
  
  for (int i = 0; i < 800; i++) {
    const unsigned int width = 4 + (4 * i);
  
  int numBlocksInWidth = width / blockDim;
  int numBlocksInHeight = height / blockDim;
  int numBlocks = numBlocksInWidth * numBlocksInHeight;

    NSLog(@"test config %dx%d : block %dx%d", width, height, numBlocksInWidth, numBlocksInHeight);
    
  // Generate an input vector in block order for
  // numBlocks elements.

  vector<uint8_t> inBlockOrderVec;
  inBlockOrderVec.reserve(width * height);

  for (int blocki = 0; blocki < numBlocks; blocki++) {
    // 4 elements for each 2x2 block
    
    for (int i = 0; i < (blockDim * blockDim); i++) {
      inBlockOrderVec.push_back(blocki);
    }
  }
  
  // Reorder block order values into image order
  
  vector<uint8_t> inImageOrderVec;
  inImageOrderVec.resize(width * height);

  flattenBlocksOfSize(blockDim, inBlockOrderVec.data(), inImageOrderVec.data(),
                      numBlocksInWidth, numBlocksInHeight);
  
  // 2x2 blocks where a big block is 4x4 values
  
  //  uint8_t inBlockValues[] = {
  //    0, 0, 1, 1, 2, 2, 3, 3,
  //    0, 0, 1, 1, 2, 2, 3, 3,
  //    4, 4, 5, 5, 6, 6, 7, 7,
  //    4, 4, 5, 5, 6, 6, 7, 7
  //  };
  
  uint8_t *inBlockValues = inImageOrderVec.data();
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec);
  
  {
    vector<uint32_t> expectedVec;
    
    for (int blocki = 0; blocki < numBlocks; blocki++) {
      expectedVec.push_back(blocki);
    }
    
    XCTAssert(blockiVec.size() == expectedVec.size());
    
    for (int i = 0; i < expectedVec.size(); i++) {
      uint32_t blocki = blockiVec[i];
      uint32_t expectedVal = expectedVec[i];
      XCTAssert(blocki == expectedVal, @"blockiVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
    }
  }
    
  // Split original image data into blocks and then use the block
  // iteration ordering to lookup the value in each block in
  // big block iteration order.
  
  {
    const int numInPixels = width * height;
    
    BlockEncoder<uint8_t, blockDim> encoder;
    
    unsigned int numBlocksInWidth, numBlocksInHeight;
    
    encoder.calcBlockWidthAndHeight(width, height, numBlocksInWidth, numBlocksInHeight);
    
    encoder.splitIntoBlocks(inBlockValues, numInPixels, width, height, numBlocksInWidth, numBlocksInHeight, 0);
    
    vector<uint8_t> outVec;
    
    for ( vector<uint8_t> & inOutBlockVec : encoder.blockVectors ) {
      for ( uint8_t bVal : inOutBlockVec ) {
        outVec.push_back(bVal);
      }
    }
    
    int numValues = numBlocksInWidth * numBlocksInHeight * blockDim * blockDim;
    
    XCTAssert(outVec.size() == numValues);
    
    // Lookup 4 values for each blocki
    
    vector<int> valuesInIterOrder;
    
    for ( uint32_t blocki : blockiVec ) {
      uint32_t iterBlocki = blockiLookupVec[blocki];
      uint8_t * blockStartPtr = &outVec[iterBlocki * (blockDim * blockDim)];
      for (int i = 0; i < (blockDim * blockDim); i++) {
        int bVal = (int) *blockStartPtr++;
        valuesInIterOrder.push_back(bVal);
      }
    }
    
    XCTAssert(valuesInIterOrder.size() == numValues);
    
    // Each lookup value should correspond to the blocki value
    // used to lookup that value. Generate expected output
    // by repeating the iterBlocki value (blockDim * blockDim) times
    
    {
      vector<uint8_t> expectedVec;
      
      for (int blocki = 0; blocki < numBlocks; blocki++) {
        uint32_t iterBlocki = blockiLookupVec[blocki];

        for (int i = 0; i < (blockDim * blockDim); i++) {
          expectedVec.push_back(iterBlocki);
        }
      }
      
//      uint32_t expected[] = {
//        0, 0, 0, 0,
//        1, 1, 1, 1,
//
//        4, 4, 4, 4,
//        5, 5, 5, 5,
//
//        2, 2, 2, 2,
//        3, 3, 3, 3,
//
//        6, 6, 6, 6,
//        7, 7, 7, 7
//      };
      
      XCTAssert(valuesInIterOrder.size() == expectedVec.size());
      
      for (int i = 0; i < expectedVec.size(); i++) {
        uint8_t val = valuesInIterOrder[i];
        uint8_t expectedVal = expectedVec[i];
        
        if (val != expectedVal) {
          XCTAssert(val == expectedVal, @"iterOrder[%4d] != expected[%4d] : %4d != %4d", i, i, val, expectedVal);
        }
      }
    }
  }
    
  }
  
  return;
}

/*

// 8x8 block size with expanding width

- (void)testBlockiGenerateExpanding8x8 {
  const int blockDim = 8;
  const int blockiDim = 4;
  
  const unsigned int height = blockDim * 48;
  
  //for (int i = 63; i < 65; i++) {
  {
    int i = 64;

    //const unsigned int width = 8 + (8 * i);
    const unsigned int width = (8 * i);
    
    int numBlocksInWidth = width / blockDim;
    int numBlocksInHeight = height / blockDim;
    int numBlocks = numBlocksInWidth * numBlocksInHeight;
    
    NSLog(@"test config %dx%d : block %dx%d", width, height, numBlocksInWidth, numBlocksInHeight);
    
    // Generate an input vector in block order for
    // numBlocks elements.
    
    vector<uint8_t> inBlockOrderVec;
    inBlockOrderVec.reserve(width * height);
    
    for (int blocki = 0; blocki < numBlocks; blocki++) {
      // 4 elements for each 2x2 block
      
      for (int i = 0; i < (blockDim * blockDim); i++) {
        inBlockOrderVec.push_back(blocki);
      }
    }
    
    // Reorder block order values into image order
    
    vector<uint8_t> inImageOrderVec;
    inImageOrderVec.resize(width * height);
    
    flattenBlocksOfSize(blockDim, inBlockOrderVec.data(), inImageOrderVec.data(),
                        numBlocksInWidth, numBlocksInHeight);
    
    // 2x2 blocks where a big block is 4x4 values
    
    //  uint8_t inBlockValues[] = {
    //    0, 0, 1, 1, 2, 2, 3, 3,
    //    0, 0, 1, 1, 2, 2, 3, 3,
    //    4, 4, 5, 5, 6, 6, 7, 7,
    //    4, 4, 5, 5, 6, 6, 7, 7
    //  };
    
    uint8_t *inBlockValues = inImageOrderVec.data();
    
    vector<uint32_t> blockiVec;
    vector<uint32_t> blockiLookupVec;
    
    block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec);
    
    {
      vector<uint8_t> expectedVec;
      
      for (int blocki = 0; blocki < numBlocks; blocki++) {
        expectedVec.push_back(blocki);
      }
      
      XCTAssert(blockiVec.size() == expectedVec.size());
      
      for (int i = 0; i < expectedVec.size(); i++) {
        uint32_t blocki = blockiVec[i];
        uint32_t expectedVal = expectedVec[i];
        XCTAssert(blocki == expectedVal, @"blockiVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
      }
    }
    
    if (0)
    {
      // Generate expected block ordering
      
      uint32_t expected[] = {
        0, 1, 4, 5,
        2, 3, 6, 7,
      };
      
      XCTAssert(blockiLookupVec.size() == sizeof(expected)/sizeof(uint32_t));
      
      for (int i = 0; i < sizeof(expected)/sizeof(uint32_t); i++) {
        uint32_t blocki = blockiLookupVec[i];
        uint32_t expectedVal = expected[i];
        
        XCTAssert(blocki == expectedVal, @"blockiLookupVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
      }
    }
    
    // Split original image data into blocks and then use the block
    // iteration ordering to lookup the value in each block in
    // big block iteration order.
    
    {
      const int numInPixels = width * height;
      
      BlockEncoder<uint8_t, blockDim> encoder;
      
      unsigned int numBlocksInWidth, numBlocksInHeight;
      
      encoder.calcBlockWidthAndHeight(width, height, numBlocksInWidth, numBlocksInHeight);
      
      encoder.splitIntoBlocks(inBlockValues, numInPixels, width, height, numBlocksInWidth, numBlocksInHeight, 0);
      
      vector<uint8_t> outVec;
      
      for ( vector<uint8_t> & inOutBlockVec : encoder.blockVectors ) {
        for ( uint8_t bVal : inOutBlockVec ) {
          outVec.push_back(bVal);
        }
      }
      
      int numValues = numBlocksInWidth * numBlocksInHeight * blockDim * blockDim;
      
      XCTAssert(outVec.size() == numValues);
      
      // Lookup 4 values for each blocki
      
      vector<int> valuesInIterOrder;
      
      for ( uint32_t blocki : blockiVec ) {
        uint32_t iterBlocki = blockiLookupVec[blocki];
        uint8_t * blockStartPtr = &outVec[iterBlocki * (blockDim * blockDim)];
        for (int i = 0; i < (blockDim * blockDim); i++) {
          int bVal = (int) *blockStartPtr++;
          valuesInIterOrder.push_back(bVal);
        }
      }
      
      XCTAssert(valuesInIterOrder.size() == numValues);
      
      // Each lookup value should correspond to the blocki value
      // used to lookup that value. Generate expected output
      // by repeating the iterBlocki value (blockDim * blockDim) times
      
      {
        vector<uint8_t> expectedVec;
        
        for (int blocki = 0; blocki < numBlocks; blocki++) {
          uint32_t iterBlocki = blockiLookupVec[blocki];
          
          for (int i = 0; i < (blockDim * blockDim); i++) {
            expectedVec.push_back(iterBlocki);
          }
        }
        
        //      uint32_t expected[] = {
        //        0, 0, 0, 0,
        //        1, 1, 1, 1,
        //
        //        4, 4, 4, 4,
        //        5, 5, 5, 5,
        //
        //        2, 2, 2, 2,
        //        3, 3, 3, 3,
        //
        //        6, 6, 6, 6,
        //        7, 7, 7, 7
        //      };
        
        XCTAssert(valuesInIterOrder.size() == expectedVec.size());
        
        for (int i = 0; i < expectedVec.size(); i++) {
          uint8_t val = valuesInIterOrder[i];
          uint8_t expectedVal = expectedVec[i];
          
          XCTAssert(val == expectedVal, @"iterOrder[%4d] != expected[%4d] : %4d != %4d", i, i, val, expectedVal);
        }
      }
    }
    
  }
  
  return;
}

*/
 
- (void)testBlockiGenerate8x8_BW_64_48_T4 {
  const int blockDim = 8;
  const int blockiDim = 4;

  const unsigned int width = 64 * blockDim * blockiDim;
  const unsigned int height = 48 * blockDim * blockiDim;
  
{
    int numBlocksInWidth = width / blockDim;
    int numBlocksInHeight = height / blockDim;
    int numBlocks = numBlocksInWidth * numBlocksInHeight;
    
    NSLog(@"test config %dx%d : block %dx%d", width, height, numBlocksInWidth, numBlocksInHeight);
    
    // Generate an input vector of bytes in block order for
    // numBlocks elements.
    
    vector<uint8_t> inBlockOrderVec;
    inBlockOrderVec.reserve(width * height);
  
    bool flipped = false;
  
    for (int blocki = 0; blocki < numBlocks; blocki++) {
      // 4 elements for each 2x2 block
      
      for (int i = 0; i < (blockDim * blockDim); i++) {
        uint8_t blockiAsByte = blocki & 0xFF;
        if (blockiAsByte != blocki) {
          flipped = true;
        }
        inBlockOrderVec.push_back(blockiAsByte);
      }
    }
    
    // Reorder block order values into image order
    
    vector<uint8_t> inImageOrderVec;
    inImageOrderVec.resize(width * height);
    
    flattenBlocksOfSize(blockDim, inBlockOrderVec.data(), inImageOrderVec.data(),
                        numBlocksInWidth, numBlocksInHeight);
    
    // 2x2 blocks where a big block is 4x4 values
    
    //  uint8_t inBlockValues[] = {
    //    0, 0, 1, 1, 2, 2, 3, 3,
    //    0, 0, 1, 1, 2, 2, 3, 3,
    //    4, 4, 5, 5, 6, 6, 7, 7,
    //    4, 4, 5, 5, 6, 6, 7, 7
    //  };
  
  if ((1)) {
    printf("inImageOrderVec:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        if (row >= 33 || col >= 33) {
          continue;
        }
        
        int offset = (row * width) + col;
        int bVal = inImageOrderVec[offset];
        printf("%3d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
    
    vector<uint32_t> blockiVec;
    vector<uint32_t> blockiLookupVec;
    
    block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec);
    
    {
      vector<uint32_t> expectedVec;
      
      for (int blocki = 0; blocki < numBlocks; blocki++) {
        expectedVec.push_back(blocki);
      }
      
      XCTAssert(blockiVec.size() == expectedVec.size());
      
      for (int i = 0; i < expectedVec.size(); i++) {
        uint32_t blocki = blockiVec[i];
        uint32_t expectedVal = expectedVec[i];
        XCTAssert(blocki == expectedVal, @"blockiVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
      }
    }
  
    // Split original image data into blocks and then use the block
    // iteration ordering to lookup the value in each block in
    // big block iteration order.
    
    {
      const int numInPixels = width * height;
      
      BlockEncoder<uint8_t, blockDim> encoder;
      
      unsigned int numBlocksInWidth, numBlocksInHeight;
      
      encoder.calcBlockWidthAndHeight(width, height, numBlocksInWidth, numBlocksInHeight);
      
      uint8_t *inBlockValues = inImageOrderVec.data();
      
      encoder.splitIntoBlocks(inBlockValues, numInPixels, width, height, numBlocksInWidth, numBlocksInHeight, 0);
      
      vector<uint8_t> outVec;
      
      for ( vector<uint8_t> & inOutBlockVec : encoder.blockVectors ) {
        for ( uint8_t bVal : inOutBlockVec ) {
          outVec.push_back(bVal);
        }
      }
      
      int numValues = numBlocksInWidth * numBlocksInHeight * blockDim * blockDim;
      
      XCTAssert(outVec.size() == numValues);
      
      // Lookup 4 values for each blocki
      
      vector<int> valuesInIterOrder;
      
      for ( uint32_t blocki : blockiVec ) {
        uint32_t iterBlocki = blockiLookupVec[blocki];
        uint8_t * blockStartPtr = &outVec[iterBlocki * (blockDim * blockDim)];
        for (int i = 0; i < (blockDim * blockDim); i++) {
          int bVal = (int) *blockStartPtr++;
          valuesInIterOrder.push_back(bVal);
        }
      }
      
      XCTAssert(valuesInIterOrder.size() == numValues);
      
      // Each lookup value should correspond to the blocki value
      // used to lookup that value. Generate expected output
      // by repeating the iterBlocki value (blockDim * blockDim) times
      
      {
        vector<uint8_t> expectedVec;
        
        for (int blocki = 0; blocki < numBlocks; blocki++) {
          uint32_t iterBlocki = blockiLookupVec[blocki];
          
          for (int i = 0; i < (blockDim * blockDim); i++) {
            uint8_t iterBlockiAsByte = iterBlocki & 0xFF;
            if (iterBlockiAsByte != iterBlocki) {
              iterBlockiAsByte = iterBlockiAsByte;
            }
            expectedVec.push_back(iterBlockiAsByte);
          }
        }
        
        //      uint32_t expected[] = {
        //        0, 0, 0, 0,
        //        1, 1, 1, 1,
        //
        //        4, 4, 4, 4,
        //        5, 5, 5, 5,
        //
        //        2, 2, 2, 2,
        //        3, 3, 3, 3,
        //
        //        6, 6, 6, 6,
        //        7, 7, 7, 7
        //      };
        
        XCTAssert(valuesInIterOrder.size() == expectedVec.size());
        
        for (int i = 0; i < expectedVec.size(); i++) {
          uint8_t val = valuesInIterOrder[i];
          uint8_t expectedVal = expectedVec[i];
          
          XCTAssert(val == expectedVal, @"iterOrder[%4d] != expected[%4d] : %4d != %4d", i, i, val, expectedVal);
        }
      }
    }
    
  }
  
  return;
}

// 32x32 small blocks is 256x256 pixels

- (void)testBlockiGenerate8x8_BW_32x32 {
  const int blockDim = 8;
  const int blockiDim = 4;
  
  const unsigned int width = 32 * blockDim;
  const unsigned int height = 32 * blockDim;
  
  {
    int numBlocksInWidth = width / blockDim;
    int numBlocksInHeight = height / blockDim;
    int numBlocks = numBlocksInWidth * numBlocksInHeight;
    
    NSLog(@"test config %dx%d : block %dx%d", width, height, numBlocksInWidth, numBlocksInHeight);
    
    // Generate an input vector of bytes in block order for
    // numBlocks elements.
    
    vector<uint8_t> inBlockOrderVec;
    inBlockOrderVec.reserve(width * height);
    
    bool flipped = false;
    
    for (int blocki = 0; blocki < numBlocks; blocki++) {
      // 4 elements for each 2x2 block
      
      for (int i = 0; i < (blockDim * blockDim); i++) {
        uint8_t blockiAsByte = blocki & 0xFF;
        if (blockiAsByte != blocki) {
          flipped = true;
        }
        inBlockOrderVec.push_back(blockiAsByte);
      }
    }
    
    // Reorder block order values into image order
    
    vector<uint8_t> inImageOrderVec;
    inImageOrderVec.resize(width * height);
    
    flattenBlocksOfSize(blockDim, inBlockOrderVec.data(), inImageOrderVec.data(),
                        numBlocksInWidth, numBlocksInHeight);
    
    // 2x2 blocks where a big block is 4x4 values
    
    //  uint8_t inBlockValues[] = {
    //    0, 0, 1, 1, 2, 2, 3, 3,
    //    0, 0, 1, 1, 2, 2, 3, 3,
    //    4, 4, 5, 5, 6, 6, 7, 7,
    //    4, 4, 5, 5, 6, 6, 7, 7
    //  };
    
    if ((1)) {
      printf("inImageOrderVec:\n");
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          if (row >= 33 || col >= 33) {
            continue;
          }
          
          int offset = (row * width) + col;
          int bVal = inImageOrderVec[offset];
          printf("%3d ", bVal);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    vector<uint32_t> blockiVec;
    vector<uint32_t> blockiLookupVec;
    
    block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec, true);
    
    {
      vector<uint32_t> expectedVec;
      
      for (int blocki = 0; blocki < numBlocks; blocki++) {
        expectedVec.push_back(blocki);
      }
      
      XCTAssert(blockiVec.size() == expectedVec.size());
      
      for (int i = 0; i < expectedVec.size(); i++) {
        uint32_t blocki = blockiVec[i];
        uint32_t expectedVal = expectedVec[i];
        XCTAssert(blocki == expectedVal, @"blockiVec[%4d] != expected[%4d] : %4d != %4d", i, i, blocki, expectedVal);
      }
    }
    
    // Split original image data into blocks and then use the block
    // iteration ordering to lookup the value in each block in
    // big block iteration order.
    
    {
      const int numInPixels = width * height;
      
      BlockEncoder<uint8_t, blockDim> encoder;
      
      unsigned int numBlocksInWidth, numBlocksInHeight;
      
      encoder.calcBlockWidthAndHeight(width, height, numBlocksInWidth, numBlocksInHeight);
      
      uint8_t *inBlockValues = inImageOrderVec.data();
      
      encoder.splitIntoBlocks(inBlockValues, numInPixels, width, height, numBlocksInWidth, numBlocksInHeight, 0);
      
      vector<uint8_t> outVec;
      
      for ( vector<uint8_t> & inOutBlockVec : encoder.blockVectors ) {
        for ( uint8_t bVal : inOutBlockVec ) {
          outVec.push_back(bVal);
        }
      }
      
      int numValues = numBlocksInWidth * numBlocksInHeight * blockDim * blockDim;
      
      XCTAssert(outVec.size() == numValues);
      
      // Lookup 4 values for each blocki
      
      vector<int> valuesInIterOrder;
      
      for ( uint32_t blocki : blockiVec ) {
        uint32_t iterBlocki = blockiLookupVec[blocki];
        uint8_t * blockStartPtr = &outVec[iterBlocki * (blockDim * blockDim)];
        for (int i = 0; i < (blockDim * blockDim); i++) {
          int bVal = (int) *blockStartPtr++;
          valuesInIterOrder.push_back(bVal);
        }
      }
      
      XCTAssert(valuesInIterOrder.size() == numValues);
      
      // Each lookup value should correspond to the blocki value
      // used to lookup that value. Generate expected output
      // by repeating the iterBlocki value (blockDim * blockDim) times
      
      {
        vector<uint8_t> expectedVec;
        
        for (int blocki = 0; blocki < numBlocks; blocki++) {
          uint32_t iterBlocki = blockiLookupVec[blocki];
          
          for (int i = 0; i < (blockDim * blockDim); i++) {
            uint8_t iterBlockiAsByte = iterBlocki & 0xFF;
            if (iterBlockiAsByte != iterBlocki) {
              iterBlockiAsByte = iterBlockiAsByte;
            }
            expectedVec.push_back(iterBlockiAsByte);
          }
        }
        
        //      uint32_t expected[] = {
        //        0, 0, 0, 0,
        //        1, 1, 1, 1,
        //
        //        4, 4, 4, 4,
        //        5, 5, 5, 5,
        //
        //        2, 2, 2, 2,
        //        3, 3, 3, 3,
        //
        //        6, 6, 6, 6,
        //        7, 7, 7, 7
        //      };
        
        XCTAssert(valuesInIterOrder.size() == expectedVec.size());
        
        for (int i = 0; i < expectedVec.size(); i++) {
          uint8_t val = valuesInIterOrder[i];
          uint8_t expectedVal = expectedVec[i];
          
          XCTAssert(val == expectedVal, @"iterOrder[%4d] != expected[%4d] : %4d != %4d", i, i, val, expectedVal);
        }
      }
    }
    
  }
  
  return;
}

@end
