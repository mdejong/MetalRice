//
//  Block32Tests.mm
//
//  Created by Mo DeJong on 7/1/18.
//

#import <XCTest/XCTest.h>

#include <stdlib.h>
#include <cstdint>

#import "block.hpp"
#import "block_process.hpp"

#import "rice.hpp"
//#import "rice_opt.h"
#import "zigzag.h"
#import "Rice.h"
#import "Util.h"

#import <vector>
#import <cstdint>

#define EMIT_CACHEDBITS_DEBUG_OUTPUT
#import "CachedBits.hpp"
#define EMIT_RICEDECODEBLOCKS_DEBUG_OUTPUT
#define RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
#import "RiceDecodeBlocks.hpp"

#import "RiceDecodeBlocksImpl.hpp"

using namespace std;

@interface Block32Tests : XCTestCase

@end

// Rice encode method

static inline
vector<uint8_t> encode(const uint8_t * bytes,
                       const int numBytes,
                       const int blockDim,
                       const uint8_t * blockOptimalKTable,
                       int blockOptimalKTableLength,
                       int numBlocks)
{
  RiceSplit16Encoder<false, true, BitWriterByteStream> encoder;
  
  vector<uint32_t> countTable;
  vector<uint32_t> nTable;

  const int numHalfBlocks = numBlocks * 2;
  const int numValuesInHalfBlock = (blockDim * blockDim) / 2;

  // Number of k table values must match the number of input bytes
  assert(numHalfBlocks == (blockOptimalKTableLength - 1));
  assert((numHalfBlocks * numValuesInHalfBlock) == numBytes);
  
  countTable.push_back(numHalfBlocks);
  nTable.push_back(numValuesInHalfBlock);
  
  encoder.encode(bytes, numBytes, blockOptimalKTable, blockOptimalKTableLength, countTable, nTable);
  
  vector<uint8_t> plainBytes = encoder.bitWriter.moveBytes();
  
  vector<uint8_t> int32Words = PrefixBitStreamRewrite32(plainBytes);
  
  return int32Words;
}

// Rice stream decode method

static inline
void decode(const uint8_t * bitBuff,
            const int bitBuffN,
            uint8_t *outBuffer,
            int numSymbolsToDecode,
            const int blockDim,
            const uint8_t * blockOptimalKTable,
            int blockOptimalKTableLength,
            int numBlocks,
            uint32_t *everyBitOffsetPtr = nullptr)
{
  RiceSplit16Decoder<false, true, BitReaderByteStream> decoder;
  
  vector<uint32_t> countTable;
  vector<uint32_t> nTable;
  
  const int numHalfBlocks = numBlocks * 2;
  const int numValuesInHalfBlock = (blockDim * blockDim) / 2;

  // Number of k table values must match the number of input bytes
  assert(numHalfBlocks == (blockOptimalKTableLength - 1));
  assert((numHalfBlocks * numValuesInHalfBlock) == numSymbolsToDecode);
  
  countTable.push_back(numHalfBlocks);
  nTable.push_back(numValuesInHalfBlock);
  
  // Convert buffer of uint32_t words to plain byte order
  
  assert((bitBuffN % sizeof(uint32_t)) == 0);
  
  vector<uint8_t> plainBytes;
  plainBytes.resize(bitBuffN);
  uint32_t *wordPtr = (uint32_t *) bitBuff;
  uint8_t *bytePtr = (uint8_t *) plainBytes.data();
  
  for (int i = 0; i < bitBuffN/4; i++) {
    uint32_t word = wordPtr[i];
    
    //    for (int i = 0; i < 4; i++) {
    //      *bytePtr++ = (word >> (i*8)) & 0xFF;
    //    }
    
    for (int i = 3; i >= 0; i--) {
      *bytePtr++ = (word >> (i*8)) & 0xFF;
    }
    
    //    *bytePtr++ = (word >> 0) & 0xFF;
    //    *bytePtr++ = (word >> 8) & 0xFF;
    //    *bytePtr++ = (word >> 16) & 0xFF;
    //    *bytePtr++ = (word >> 24) & 0xFF;
  }
  
  decoder.decode(plainBytes.data(), bitBuffN, outBuffer, numSymbolsToDecode, blockOptimalKTable, blockOptimalKTableLength, countTable, nTable);
  
  if (everyBitOffsetPtr != nullptr) {
    // Walk over every symbol and make sure the bit offset for the indicated symbol
    // matches the expected offset for the symbol.

    RiceSplit16Encoder<false, true, BitWriterByteStream> encoder;
    
    uint32_t bitOffset = 0;
    
    for ( int i = 0; i < numSymbolsToDecode; i++ ) {
      int blocki = i / numValuesInHalfBlock;
      int k = blockOptimalKTable[blocki];
      int symbol = outBuffer[i];
      
      // The current bit offset should match the input table value for this symbol
      uint32_t expectedBitOffset = everyBitOffsetPtr[i];
      assert(bitOffset == expectedBitOffset);
      
      int numBits = encoder.numBits(symbol, k);

      assert(numBits > 0);
      assert((bitOffset + numBits) > bitOffset); // make sure uint32_t does not overflow
      bitOffset += numBits;
    }
  }
  
  return;
}

// Rice parallel decode method which requires a table of bit offsets for every
// value in the stream.

static inline
void decodeParallelCheck(const uint8_t * bitBuff,
                         const int bitBuffN,
                         uint8_t *expectedBuffer,
                         int numSymbolsToDecode,
                         const int blockDim,
                         const uint8_t * blockOptimalKTable,
                         int blockOptimalKTableLength,
                         int numBlocks,
                         uint32_t *everyBitOffsetPtr)
{
  const bool debug = false;
  
  uint32_t *in32Ptr = (uint32_t *) bitBuff;
  assert(everyBitOffsetPtr);
  
  const int numValuesInHalfBlock = (blockDim * blockDim) / 2;
  
  for ( int i = 0; i < numSymbolsToDecode; i++ ) {
    uint32_t expectedBitOffset = everyBitOffsetPtr[i];
    int expectedSymbol = expectedBuffer[i];

    int blocki = i / numValuesInHalfBlock;
    assert(blocki < (blockOptimalKTableLength-1));
    int k = blockOptimalKTable[blocki];
    
    if (debug) {
      printf("symbol[%5d] = expected %3d\n", i, expectedSymbol);
      printf("absolute blocki %3d : k = %d\n", blocki, k);
      printf("symbol starting bit offset %d\n", expectedBitOffset);
    }
    
    RiceDecodeBlocks<CachedBits3216> rdb;
    
    rdb.cachedBits.initBits(in32Ptr, expectedBitOffset);
    
    rdb.totalNumBitsRead = expectedBitOffset;
    
    // Decode the next rice symbol at the absolute bit offset
    
    uint8_t symbol = rice_rdb_decode_symbol(rdb, k);
    
    assert(symbol == expectedSymbol);
    
    // Check number of bits just read (this symbol width)
    if (i != (numSymbolsToDecode - 1)) {
      int nextBitOffset = everyBitOffsetPtr[i+1];
      assert(rdb.totalNumBitsRead == nextBitOffset);
    }
  }
  
  return;
}

// Given symbols to be encoded, determine bit offsets
// and return as a vector of offsets. The everyN argument
// indicates when to record the bit offsets, pass 1 to
// record a bit offset for every symbol.

static inline
vector<uint32_t> generateBitOffsets(const uint8_t * symbols,
                                    int numSymbols,
                                    const int blockDim,
                                    const uint8_t * blockOptimalKTable,
                                    const int blockOptimalKTableLen,
                                    int numBlocks,
                                    const int everyN)
{
  vector<uint32_t> bitOffsets;
  bitOffsets.reserve(numSymbols);
  
  unsigned int offset = 0;

  int numSymbolsInHalfBlock = (blockDim * blockDim) / 2;
  int numSymbolsInAllBlocks = numSymbolsInHalfBlock * (numBlocks * 2);
  
  assert(numSymbolsInAllBlocks == numSymbols);
  
  RiceSplit16Encoder<false, true, BitWriterByteStream> encoder;
  
  for ( int i = 0; i < numSymbols; i++ ) {
    if (everyN == 1) {
      bitOffsets.push_back(offset);
    } else {
      if ((i % everyN) == 0) {
        bitOffsets.push_back(offset);
      }
    }
    
    uint8_t symbol = symbols[i];
    int blocki = i / numSymbolsInHalfBlock;
    assert(blocki < blockOptimalKTableLen);
    uint8_t k = blockOptimalKTable[blocki];
    uint32_t bitWidth = encoder.numBits(symbol, k);
    offset += bitWidth;
  }
  
  return bitOffsets;
}

// Generate blocki values in big block ordering, each block of 32x32 is offset by 16 blocks
// of 8x8 of the same value. The D param is 8 for the 8x8 small block size.

template <const int D>
vector<uint32_t> generateBlockiValues(int width, int height)
{
  const bool debug = false;
  
  // Generate blocki values in big block iteration order
  
  const int blockDim = D;
  const int blockiDim = 4;
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim, blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  // blockiLookupVec maps input blocki elements to the big block ordered blocki values.
  // With this mapping complete, generate a original blocki mapping to big block
  // identity where the output blocki values are 
  
  // Iterate over each (X,Y) coordinate and convert to blocki via lookup table
  
  vector<uint32_t> outputBlockForCoords;
  
  outputBlockForCoords.reserve(width * height);
  
  for (int row = 0; row < height; row++) {
    for (int col = 0; col < width; col++) {
      int blockX = col / blockDim;
      int blockY = row / blockDim;
           
      int blockiForCoord = (blockY * width/blockDim) + blockX;
      
      if (debug) {
        printf("(%4d,%4d) -> blockXY (%4d,%4d) -> blocki %4d\n", col, row, blockX, blockY, blockiForCoord);
      }
      
      // Lookup blockiInBigBlock
      
      int blockiInBigBlock = blockiLookupVec[blockiForCoord];
      
      if (debug) {
        printf("blocki %4d -> big blocki iter %4d\n", blockiForCoord, blockiInBigBlock);
      }
      
      outputBlockForCoords.push_back(blockiInBigBlock);
    }
  }
  
  return outputBlockForCoords;
}

@implementation Block32Tests

- (void)setUp {
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (void)testFormatBlock32_2x2Ex1 {
  const int blockDim = 2;
  
  uint8_t inputPixels[4] = {
    0x0, 0x1,
    0x2, 0x3
  };
  
  vector<uint8_t> outputPixelsVec(4);
  
  // With a single block, splitting into 1/2 blocks is a nop
  
  uint8_t expectedPixels[4] = {
    0x0, 0x1,
    0x2, 0x3
  };
  
  const int blockN = 1;
  const int numSegments = 2;
  
  block_s32_format_block_layout(inputPixels,
                                outputPixelsVec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                nullptr,
                                nullptr,
                                nullptr,
                                nullptr,
                                1);
  
  for (int i = 0; i < outputPixelsVec.size(); i++) {
    uint8_t bval = outputPixelsVec[i];
    uint8_t expected = expectedPixels[i];
    XCTAssert(bval == expected, @"bval == expected : %d == %d", bval, expected);
  }
  
  return;
}

- (void)testFormatBlock32_2x2Ex2 {
  const int blockDim = 2;
  
  uint8_t inputPixels[(2*2)*2] = {
    // block 0
    0x0, 0x1,
    0x2, 0x3,
    // block 1
    0x4, 0x5,
    0x6, 0x7
  };
  
  vector<uint8_t> inputPixelsVec(sizeof(inputPixels));
  memcpy(inputPixelsVec.data(), inputPixels, sizeof(inputPixels));
  
  vector<uint8_t> outputPixelsVec((2*2)*2);
  
  uint8_t expectedPixels[(2*2)*2] = {
    // block 0A
    0x0, 0x1,
    // block 0B
    0x2, 0x3,
    // block 1A
    0x4, 0x5,
    // block 1B
    0x6, 0x7
  };
  
  const int blockN = 2;
  const int numSegments = 4;
  
  // k table
  
  uint8_t kTable[] = {
    7,
    8
  };
  
  vector<uint8_t> kTableVec(sizeof(kTable));
  memcpy(kTableVec.data(), kTable, sizeof(kTable));

  vector<uint32_t> inBlockiVec;
  inBlockiVec.push_back(0);
  inBlockiVec.push_back(1);
  
  const uint32_t *inBlockiPtr = (const uint32_t *) inBlockiVec.data();

  // Input bytes reordered into the order indicated by blocki table
  
  vector<uint8_t> outBlockiOrderVec;
  
  vector<uint8_t> kTableReorderedVec;
  
  // Reorder is a nop when no blocki is provided
  
  kTableReorderedVec = kTableVec;
  
  block_s32_format_block_layout(inputPixels,
                                outputPixelsVec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                inBlockiPtr,
                                &outBlockiOrderVec,
                                &kTableReorderedVec,
                                nullptr,
                                1);
  
  XCTAssert(outBlockiOrderVec == inputPixelsVec, @"outBlockiOrderVec");
  XCTAssert(kTableReorderedVec == kTableVec, @"kTableReorderedVec");
  
  for (int i = 0; i < outputPixelsVec.size(); i++) {
    uint8_t bval = outputPixelsVec[i];
    uint8_t expected = expectedPixels[i];
    XCTAssert(bval == expected, @"bval == expected : %d == %d", bval, expected);
  }
  
  return;
}

- (void)testFormatBlock32_2x2Ex3 {
  const int blockDim = 2;
  
  uint8_t inputPixels[(2*2)*2] = {
    // block 0
    0x0, 0x1,
    0x2, 0x3,
    // block 1
    0x4, 0x5,
    0x6, 0x7
  };
  
  vector<uint8_t> inputPixelsVec(sizeof(inputPixels));
  memcpy(inputPixelsVec.data(), inputPixels, sizeof(inputPixels));
  
  vector<uint8_t> outputPixelsVec((2*2)*2);
  
  uint8_t expectedPixels[(2*2)*2] = {
    // block 1A
    0x4, 0x5,
    // block 1B
    0x6, 0x7,
    // block 0A
    0x0, 0x1,
    // block 0B
    0x2, 0x3
  };
  
  const int blockN = 2;
  const int numSegments = 4;
  
  // k table
  
  uint8_t kTable[] = {
    7,
    8
  };
  
  vector<uint8_t> kTableVec(sizeof(kTable));
  memcpy(kTableVec.data(), kTable, sizeof(kTable));
  
  vector<uint32_t> inBlockiVec;
  inBlockiVec.push_back(1);
  inBlockiVec.push_back(0);
  
  const uint32_t *inBlockiPtr = (const uint32_t *) inBlockiVec.data();
  
  // Input bytes reordered into the order indicated by blocki table
  
  vector<uint8_t> outBlockiOrderVec;
  
  vector<uint8_t> kTableReorderedVec;
  
  // Reorder is a nop when no blocki is provided
  
  kTableReorderedVec = kTableVec;
  
  block_s32_format_block_layout(inputPixels,
                                outputPixelsVec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                inBlockiPtr,
                                &outBlockiOrderVec,
                                &kTableReorderedVec,
                                nullptr,
                                1);

  XCTAssert(kTableReorderedVec.size() == 2, @"kTableReorderedVec");
  XCTAssert(kTableReorderedVec[0] == 8, @"kTableReorderedVec");
  XCTAssert(kTableReorderedVec[1] == 7, @"kTableReorderedVec");
  
  for (int i = 0; i < outputPixelsVec.size(); i++) {
    uint8_t bval = outputPixelsVec[i];
    uint8_t expected = expectedPixels[i];
    XCTAssert(bval == expected, @"bval == expected : %d == %d", bval, expected);
  }
  
  return;
}


- (void)testFormatBlock32_2x2Ex4 {
  const int blockDim = 2;
  
  uint8_t inputPixels[(blockDim*blockDim)*3] = {
    // block 0
    0x0, 0x1,
    0x2, 0x3,
    // block 1
    0x4, 0x5,
    0x6, 0x7,
    // block 2
    0x8, 0x9,
    0xA, 0xB
  };
  
  vector<uint8_t> outputPixelsVec((blockDim*blockDim)*3);
  
  uint8_t expectedPixels[(blockDim*blockDim)*3] = {
    // block 0A
    0x0, 0x1,
    // block 0B
    0x2, 0x3,
    // block 1A
    0x4, 0x5,
    // block 1B
    0x6, 0x7,
    // block 2A
    0x8, 0x9,
    // block 2B
    0xA, 0xB,
  };
  
  const int blockN = 3;
  const int numSegments = 6;
  
  block_s32_format_block_layout(inputPixels,
                                outputPixelsVec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                nullptr,
                                nullptr,
                                nullptr,
                                nullptr,
                                1);
  
  block_s32_format_block_layout(inputPixels,
                                outputPixelsVec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                NULL);
  
  for (int i = 0; i < outputPixelsVec.size(); i++) {
    uint8_t bval = outputPixelsVec[i];
    uint8_t expected = expectedPixels[i];
    XCTAssert(bval == expected, @"bval == expected : %d == %d", bval, expected);
  }
  
  return;
}

// With 32 streams and 16 blocks, at 8x8 this would translate to 32x32 pixels in a full block

- (void)testFormatBlock32_2x2Ex32 {
  const int blockDim = 2;

  const int numBytes = (blockDim*blockDim)*16;

  vector<uint8_t> inputPixelsVec;
  inputPixelsVec.resize(numBytes);
  uint8_t *inputPixelsPtr = inputPixelsVec.data();
  
  for (int i = 0; i < numBytes; i++) {
    inputPixelsPtr[i] = i;
  }

  vector<uint8_t> outputPixelsVec;
  outputPixelsVec.resize(numBytes);
  uint8_t *outputPixelsPtr = outputPixelsVec.data();
  memset(outputPixelsPtr, 0, outputPixelsVec.size());
  
  uint8_t expectedPixels[numBytes] = {
    // block 0A
    0, 1,
    // block 0B
    2, 3,

    // block 1A
    4, 5,
    // block 1B
    6, 7,

    // block 2A
    8, 9,
    // block 2B
    10, 11,

    // block 3A
    12, 13,
    // block 3B
    14, 15,
    
    // block 4A
    16, 17,
    // block 4B
    18, 19,
    
    // block 5A
    20, 21,
    // block 5B
    22, 23,

    // block 6A
    24, 25,
    // block 6B
    26, 27,

    // block 7A
    28, 29,
    // block 7B
    30, 31,

    // block 8A
    32, 33,
    // block 8B
    34, 35,

    // block 9A
    36, 37,
    // block 9B
    38, 39,

    // block 10A
    40, 41,
    // block 10B
    42, 43,

    // block 11A
    44, 45,
    // block 11B
    46, 47,

    // block 12A
    48, 49,
    // block 12B
    50, 51,

    // block 13A
    52, 53,
    // block 13B
    54, 55,

    // block 14A
    56, 57,
    // block 14B
    58, 59,

    // block 14A
    60, 61,
    // block 14B
    62, 63
  };
  
  const int blockN = 16;
  const int numSegments = 32;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                outputPixelsPtr,
                                blockN,
                                blockDim,
                                numSegments,
                                NULL);
  
  for (int i = 0; i < numBytes; i++) {
    uint8_t bval = outputPixelsPtr[i];
    uint8_t expected = expectedPixels[i];
    XCTAssert(bval == expected, @"bval == expected : %d == %d", bval, expected);
  }
  
  return;
}

// format image order blocki values into 32x32 blocks that correspond to 4x4 blocks

- (void)testFormatBlockiAs4x4_16x8_Ex1 {
  const int blockDim = 8;
  const int blockiDim = 4;
  
  int width = 16 * 4;
  int height = 8 * 4;
  int numBlocks = ((width * height) / (blockDim * blockDim));
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  // Print blocki values in image order
  
  if ((1)) {
    printf("blocki in image order:\n");
  
    for (int blocki = 0; blocki < numBlocks; blocki++) {
      int bVal = blockiVec[blocki];
      printf("%3d\n", bVal);
    }
  }

  // Reformat block values so that block of 4x4 would be
  // iterated in big block order
  
  // Print blocki values in block order
  
  if ((1)) {
    printf("big block order:\n");

    for (int blocki = 0; blocki < numBlocks; blocki++) {
      int lookedupBlocki = blockiLookupVec[blocki];
      printf("%3d\n", lookedupBlocki);
    }
  }
  
  uint32_t expectedOutput[] = {
    // blocki 0
    0,  1, 2, 3,
    8,  9, 10, 11,
    16, 17, 18, 19,
    24, 25, 26, 27,
    
    // blocki 1
    4,  5, 6, 7,
    12, 13, 14, 15,
    20, 21, 22, 23,
    28, 29, 30, 31
  };

  for (int i = 0; i < blockiLookupVec.size(); i++) {
    uint32_t ival = blockiLookupVec[i];
    uint32_t expected = expectedOutput[i];
    XCTAssert(ival == expected, @"bval == expected : %d == %d", ival, expected);
  }
  
  return;
}

// Format input image order data into 2x2 blocks and then generate a blocki ordering
// array that indicates how the blocks are iterated over.

- (void)testFormatImageOrderToBlockiEx1 {
  const int blockDim = 2;
  const int blockiDim = 4;
  
  const int width = 8 * blockDim;
  const int height = 8 * blockDim;
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  // 2x2 block, 64 of them
  
  vector<uint8_t> inputPixelsVec(width*height);
  vector<uint8_t> outputPixelsVec(width*height);

  vector<uint8_t> blockOptimalKTableVec(blockN + 1);

  // k = 0
  for (int i = 0; i < blockN; i++) {
    blockOptimalKTableVec[i] = 0;
  }

  for (int row = 0; row < height; row++) {
    for (int col = 0; col < width; col++) {
      int offset = (row * width) + col;
      inputPixelsVec[offset] = offset;
    }
  }
  
  // Image is generated in block order so that the ascending
  // values are stored 1 block at a time.
  
  if ((1)) {
    printf("2x2 block order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputPixelsVec[offset];
        printf("%3d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Generate blocki ordering

  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixelsVec.data();
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                outputPixelsVec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec);
  
  XCTAssert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size(), @"same size");
  XCTAssert(blockiOptimalKTableVec == blockOptimalKTableVec, @"same k values");
  
  if ((1)) {
    printf("big block s32 image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = outputPixelsVec[offset];
        printf("%3d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }

  // Print blocki values in block order
  
  if ((0)) {
    printf("s32 block by block order:\n");
    printf("(%d at a time)\n", (blockDim*blockDim));
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      //printf("offset %3d (%d at a time)\n", offset, (blockDim*blockDim));
      
      for (int i = 0; i < (blockDim*blockDim); i++) {
        int bVal = outputPixelsVec[offset++];
        printf("%3d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // One big block is 64 values, this is 4 concatenated big blocks: q1, q2, q3, q4
  
  uint8_t expectedS32Pixels[width*height] = {
    0,   1,   2,   3,
    4,   5,   6,   7,
    8,   9,  10,  11,
    12,  13,  14,  15,
    32,  33,  34,  35,
    36,  37,  38,  39,
    40,  41,  42,  43,
    44,  45,  46,  47,
    64,  65,  66,  67,
    68,  69,  70,  71,
    72,  73,  74,  75,
    76,  77,  78,  79,
    96,  97,  98,  99,
    100, 101, 102, 103,
    104, 105, 106, 107,
    108, 109, 110, 111,
    16,  17,  18,  19,
    20,  21,  22,  23,
    24,  25,  26,  27,
    28,  29,  30,  31,
    48,  49,  50,  51,
    52,  53,  54,  55,
    56,  57,  58,  59,
    60,  61,  62,  63,
    80,  81,  82,  83,
    84,  85,  86,  87,
    88,  89,  90,  91,
    92,  93,  94,  95,
    112, 113, 114, 115,
    116, 117, 118, 119,
    120, 121, 122, 123,
    124, 125, 126, 127,
    128, 129, 130, 131,
    132, 133, 134, 135,
    136, 137, 138, 139,
    140, 141, 142, 143,
    160, 161, 162, 163,
    164, 165, 166, 167,
    168, 169, 170, 171,
    172, 173, 174, 175,
    192, 193, 194, 195,
    196, 197, 198, 199,
    200, 201, 202, 203,
    204, 205, 206, 207,
    224, 225, 226, 227,
    228, 229, 230, 231,
    232, 233, 234, 235,
    236, 237, 238, 239,
    144, 145, 146, 147,
    148, 149, 150, 151,
    152, 153, 154, 155,
    156, 157, 158, 159,
    176, 177, 178, 179,
    180, 181, 182, 183,
    184, 185, 186, 187,
    188, 189, 190, 191,
    208, 209, 210, 211,
    212, 213, 214, 215,
    216, 217, 218, 219,
    220, 221, 222, 223,
    240, 241, 242, 243,
    244, 245, 246, 247,
    248, 249, 250, 251,
    252, 253, 254, 255
  };

  for (int i = 0; i < (width*height); i++) {
    uint8_t bval = outputPixelsVec[i];
    uint8_t expected = expectedS32Pixels[i];
    XCTAssert(bval == expected, @"bval == expected : %d == %d", bval, expected);
  }
  
  // Read 16 small blocks at a time from 32 streams
  // so that a big block of 32x32 is read in with
  // 8 reads per small block.
  
  vector<uint8_t> decodedS32PixelsVec(width*height);
  
  block_s32_flatten_block_layout(outputPixelsVec.data(),
                                 decodedS32PixelsVec.data(),
                                 blockN,
                                 blockDim,
                                 numSegments,
                                 (const uint8_t *)blockiReorderedVec.data());
  
  if ((1)) {
    printf("s32 flattened block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      //printf("offset %3d (%d at a time)\n", offset, (blockDim * blockDim));
      
      for (int i = 0; i < (blockDim * blockDim); i++) {
        int bVal = decodedS32PixelsVec[offset++];
        printf("%3d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32PixelsVec[i];
      uint8_t expected = blockiReorderedVec[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (numFails < 10) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
          numFails += 1;
        }
      }
    }
  }
   
  return;
}

// Passing blocki ordering values into s32 format method
// will reorder optional k table argument.

- (void)testS32FormatKTableBlockiReverse {
  const int blockDim = 2;
  const int blockiDim = 4;
  
  const int width = 4 * blockDim;
  const int height = 4 * blockDim;
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  // 2x2 block, 64 of them
  
  vector<uint8_t> inputPixelsVec(width*height);
  vector<uint8_t> outputPixelsVec(width*height);
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  blockOptimalKTableVec[blockN-1] = 0;
  
  // Increasing k values
  for (int i = 0; i < blockN; i++) {
    blockOptimalKTableVec[i] = i;
  }
  
  // Generate blocki ordering that reverses each blocki
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  // Reverse blocki ordering
  
  for (int i = 0; i < blockN; i++) {
    blockiLookupVec[i] = (blockN - 1) - i;
  }
  
  if ((1)) {
    printf("blocki order:\n");
    
    for (int i = 0; i < blockiLookupVec.size(); i++) {
      int blocki = blockiLookupVec[i];
      printf("%2d ", blocki);
    }
    
    printf("\n");
  }
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  if ((1)) {
    printf("k input order:\n");
    
    for (int i = 0; i < blockOptimalKTableVec.size(); i++) {
      int kVal = blockOptimalKTableVec[i];
      printf("%1d ", kVal);
    }
    
    printf("\n");
  }
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixelsVec.data();
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                outputPixelsVec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec);
  
  XCTAssert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size(), @"same size");
  
  if ((1)) {
    printf("k output order:\n");
    
    for (int i = 0; i < blockiOptimalKTableVec.size(); i++) {
      int kVal = blockiOptimalKTableVec[i];
      printf("%1d, ", kVal);
    }
    
    printf("\n");
  }
  
  int expectedK[] = {
    15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0,
  };
  
  {
    int numFails = 0;
    
    for (int i = 0; i < blockiOptimalKTableVec.size(); i++) {
      int bval = blockiOptimalKTableVec[i];
      int expected = expectedK[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (numFails < 10) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
          numFails += 1;
        }
      }
    }
  }
  
  return;
}

// 2x2 block with 8x8 values is one big block, each of the blocki
// values in the big block has a different K value, this test
// case makes sure that the K specific encoding and decoding
// logic works properly WRT half block values.

- (void)testS32_1x1_DiffK02 {
  const int blockDim = 2;
  const int blockiDim = 4;
  
  const int width = 4 * blockDim;
  const int height = 4 * blockDim;
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  // 2x2 block, 64 of them
  
  vector<uint8_t> inputPixelsVec(width*height);
  vector<uint8_t> s32OrderPixelsVec(width*height);
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  blockOptimalKTableVec[blockN-1] = 0;
  
  // Increasing K values, 0 .. 2 for 2 big blocks
  
  {
    int currentK = 0;
    
    for (int i = 0; i < blockN; i++) {
      blockOptimalKTableVec[i] = currentK;
      currentK += 1;
      if (currentK > 2) {
        currentK = 0;
      }
    }
  }
  
  if ((1)) {
    printf("k input blocki order:\n");
    
    for (int i = 0; i < blockOptimalKTableVec.size(); i++) {
      int k = blockOptimalKTableVec[i];
      printf("%1d ", k);
    }
    
    printf("\n");
  }
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  if ((1)) {
    printf("blocki order:\n");
    
    for (int i = 0; i < blockiLookupVec.size(); i++) {
      int blocki = blockiLookupVec[i];
      printf("%2d ", blocki);
    }
    
    printf("\n");
  }
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixelsVec.data();
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  vector<uint8_t> halfBlockOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                s32OrderPixelsVec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec,
                                &halfBlockOptimalKTableVec);
  
  XCTAssert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size(), @"same size");
  
  int sizeWOPadding = (int) (blockiOptimalKTableVec.size() - 1);
  XCTAssert((sizeWOPadding * 2 + 1) == (int)halfBlockOptimalKTableVec.size(), @"half block double size");
  
  if ((1)) {
    printf("k output order:\n");
    
    for (int i = 0; i < blockiOptimalKTableVec.size(); i++) {
      int kVal = blockiOptimalKTableVec[i];
      printf("%1d, ", kVal);
    }
    
    printf("\n");
  }

  if ((1)) {
    printf("k half block output order:\n");
    
    for (int i = 0; i < halfBlockOptimalKTableVec.size(); i++) {
      int kVal = halfBlockOptimalKTableVec[i];
      printf("%1d, ", kVal);
    }
    
    printf("\n");
  }
  
  // blocki ordering is the same as blockOptimalKTableVec
  
  {
    int expectedK[] = {
      0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0,
      0
    };
    
    {
      int numFails = 0;
      
      for (int i = 0; i < sizeof(expectedK)/sizeof(uint32_t); i++) {
        int bval = blockiOptimalKTableVec[i];
        int expected = expectedK[i];
        if (bval != expected) {
          if (numFails < 10) {
            XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d", bval, expected, i);
            numFails += 1;
          }
        }
      }
    }
  }

  // half block ordering doubles up each entry so that bit encoding can be applied
  // to each half block.
  
  {
    int expectedK[] = {
      0, 0, 1, 1, 2, 2, 0, 0, 1, 1, 2, 2, 0, 0, 1, 1, 2, 2, 0, 0, 1, 1, 2, 2, 0, 0, 1, 1, 2, 2, 0, 0,
      0
    };
    
    {
      int numFails = 0;
      
      for (int i = 0; i < sizeof(expectedK)/sizeof(uint32_t); i++) {
        int bval = halfBlockOptimalKTableVec[i];
        int expected = expectedK[i];
        if (bval != expected) {
          if (numFails < 10) {
            XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d", bval, expected, i);
            numFails += 1;
          }
        }
      }
    }
  }
  
  // Encode as rice bits and then decode with stream based decode for sanity check
  
  {
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = s32OrderPixelsVec.data();
    
    //const uint8_t *blockOptimalKTable = blockOptimalKTableVec.data();
    const uint8_t *blockOptimalKTable = halfBlockOptimalKTableVec.data();
    const int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
    
    vector<uint8_t> riceEncodedVec = encode(blockSymbols,
                                            numBlockSymbols,
                                            blockDim,
                                            blockOptimalKTable,
                                            blockOptimalKTableLen,
                                            blockN);
    
#if defined(DEBUG)
    {
      vector<uint8_t> outBufferVec(width*height);
      uint8_t *outBuffer = outBufferVec.data();
      
      vector<uint32_t> bitOffsetsEveryVal = generateBitOffsets(blockSymbols,
                                                               numBlockSymbols,
                                                               blockDim,
                                                               blockOptimalKTable,
                                                               blockOptimalKTableLen,
                                                               blockN,
                                                               1);
      
      decode(riceEncodedVec.data(),
             (int)riceEncodedVec.size(),
             outBuffer,
             width*height,
             blockDim,
             blockOptimalKTable,
             blockOptimalKTableLen,
             blockN,
             bitOffsetsEveryVal.data());
      
      int cmp = memcmp(blockSymbols, outBuffer, width*height);
      assert(cmp == 0);
      
      // Decode with non-stream rice method and validate against known good decoded values stream
      
      decodeParallelCheck(riceEncodedVec.data(),
                          (int)riceEncodedVec.size(),
                          outBuffer,
                          width*height,
                          blockDim,
                          blockOptimalKTable,
                          blockOptimalKTableLen,
                          blockN,
                          bitOffsetsEveryVal.data());
    }
#endif // DEBUG
  }
  
  return;
}

- (void)testS32_2x1_DiffK02 {
  const int blockDim = 2;
  const int blockiDim = 4;
  
  const int width = 8 * blockDim;
  const int height = 4 * blockDim;
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  // 2x2 block, 64 of them
  
  vector<uint8_t> inputPixelsVec(width*height);
  vector<uint8_t> s32OrderPixelsVec(width*height);
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  blockOptimalKTableVec[blockN-1] = 0;
  
  // Increasing K values, 0 .. 2 for a total of 16 blocks
  
  {
    int currentK = 0;
    
    for (int i = 0; i < blockN; i++) {
      blockOptimalKTableVec[i] = currentK;
      currentK += 1;
      if (currentK > 2) {
        currentK= 0;
      }
    }
  }
  
  if ((1)) {
    printf("k input blocki order:\n");
    
    for (int i = 0; i < blockOptimalKTableVec.size(); i++) {
      int k = blockOptimalKTableVec[i];
      printf("%1d ", k);
    }
    
    printf("\n");
  }
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  if ((1)) {
    printf("blocki order:\n");
    
    for (int i = 0; i < blockiLookupVec.size(); i++) {
      int blocki = blockiLookupVec[i];
      printf("%2d ", blocki);
    }
    
    printf("\n");
  }
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixelsVec.data();
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  vector<uint8_t> halfBlockOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                s32OrderPixelsVec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec,
                                &halfBlockOptimalKTableVec);
  
  XCTAssert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size(), @"same size");
  
  int sizeWOPadding = (int) (blockiOptimalKTableVec.size() - 1);
  XCTAssert((sizeWOPadding * 2 + 1) == (int)halfBlockOptimalKTableVec.size(), @"half block double size");
  
  if ((1)) {
    printf("k output order (len %d):\n", (int)blockiOptimalKTableVec.size());
    
    for (int i = 0; i < blockiOptimalKTableVec.size(); i++) {
      int kVal = blockiOptimalKTableVec[i];
      printf("%1d, ", kVal);
    }
    
    printf("\n");
  }
  
  if ((1)) {
    printf("k half block output order (len %d):\n", (int)halfBlockOptimalKTableVec.size());
    
    for (int i = 0; i < halfBlockOptimalKTableVec.size(); i++) {
      int kVal = halfBlockOptimalKTableVec[i];
      printf("%1d, ", kVal);
    }
    
    printf("\n");
  }

  // blocki identity, lookup k
  
  {
    int expectedK[] = {
      // big block 0
      0, 1, 2, 0,
      // big block 1
      1, 2, 0, 1,
      // big block 0
      2, 0, 1, 2,
      // big block 1
      0, 1, 2, 0,
      // big block 0
      1, 2, 0, 1,
      // big block 1
      2, 0, 1, 2,
      // big block 0
      0, 1, 2, 0,
      // big block 1
      1, 2, 0, 1,
      // extra k zero value
      0
    };
    
    {
      int numFails = 0;
      
      for (int i = 0; i < sizeof(expectedK)/sizeof(uint32_t); i++) {
        int kVal = blockOptimalKTableVec[i];
        int expected = expectedK[i];
        if (kVal != expected) {
          if (numFails < 10) {
            XCTAssert(kVal == expected, @"k == expected : %d == %d : offset %d", kVal, expected, i);
            numFails += 1;
          }
        }
      }
    }
  }
  
    // blocki reordered and then k looked up
  
  {
    int expectedK[] = {
      // big block 0
      0, 1, 2, 0,
      2, 0, 1, 2,
      1, 2, 0, 1,
      0, 1, 2, 0,
      
      // big block 1
      1, 2, 0, 1,
      0, 1, 2, 0,
      2, 0, 1, 2,
      1, 2, 0, 1,
      
      // extra k zero value
      0
    };
    
    {
      int numFails = 0;
      
      for (int i = 0; i < sizeof(expectedK)/sizeof(uint32_t); i++) {
        int bval = blockiOptimalKTableVec[i];
        int expected = expectedK[i];
        if (bval != expected) {
          if (numFails < 10) {
            XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d", bval, expected, i);
            numFails += 1;
          }
        }
      }
    }
  }
  
  // blocki reordered and then k looked up, each big block has 2x entries for half blocks
  
  {
    int expectedK[] = {
      // big block 0
      0, 0, 1, 1, 2, 2, 0, 0,
      2, 2, 0, 0, 1, 1, 2, 2,
      1, 1, 2, 2, 0, 0, 1, 1,
      0, 0, 1, 1, 2, 2, 0, 0,

      // big block 1
      1, 1, 2, 2, 0, 0, 1, 1,
      0, 0, 1, 1, 2, 2, 0, 0,
      2, 2, 0, 0, 1, 1, 2, 2,
      1, 1, 2, 2, 0, 0, 1, 1,
      
      0
    };
    
    {
      int numFails = 0;
      
      for (int i = 0; i < sizeof(expectedK)/sizeof(uint32_t); i++) {
        int bval = halfBlockOptimalKTableVec[i];
        int expected = expectedK[i];
        if (bval != expected) {
          if (numFails < 10) {
            XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d", bval, expected, i);
            numFails += 1;
          }
        }
      }
    }
  }
  
  // Encode as rice bits and then decode with stream based decode for sanity check
  
  {
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = s32OrderPixelsVec.data();
    
    //const uint8_t *blockOptimalKTable = blockOptimalKTableVec.data();
    const uint8_t *blockOptimalKTable = halfBlockOptimalKTableVec.data();
    const int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
    
    vector<uint8_t> riceEncodedVec = encode(blockSymbols,
                                            numBlockSymbols,
                                            blockDim,
                                            blockOptimalKTable,
                                            blockOptimalKTableLen,
                                            blockN);
    
#if defined(DEBUG)
    {
      vector<uint8_t> outBufferVec(width*height);
      uint8_t *outBuffer = outBufferVec.data();
      
      vector<uint32_t> bitOffsetsEveryVal = generateBitOffsets(blockSymbols,
                                                               numBlockSymbols,
                                                               blockDim,
                                                               blockOptimalKTable,
                                                               blockOptimalKTableLen,
                                                               blockN,
                                                               1);
      
      decode(riceEncodedVec.data(),
             (int)riceEncodedVec.size(),
             outBuffer,
             width*height,
             blockDim,
             blockOptimalKTable,
             blockOptimalKTableLen,
             blockN,
             bitOffsetsEveryVal.data());
      
      int cmp = memcmp(blockSymbols, outBuffer, width*height);
      assert(cmp == 0);
      
      // Decode with non-stream rice method and validate against known good decoded values stream
      
      decodeParallelCheck(riceEncodedVec.data(),
                          (int)riceEncodedVec.size(),
                          outBuffer,
                          width*height,
                          blockDim,
                          blockOptimalKTable,
                          blockOptimalKTableLen,
                          blockN,
                          bitOffsetsEveryVal.data());
    }
#endif // DEBUG
  }
  
  return;
}

- (void)testS32_2x2_DiffK02 {
  const int blockDim = 2;
  const int blockiDim = 4;
  
  const int width = 8 * blockDim;
  const int height = 8 * blockDim;
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  // 2x2 block, 64 of them
  
  vector<uint8_t> inputPixelsVec(width*height);
  vector<uint8_t> s32OrderPixelsVec(width*height);
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  blockOptimalKTableVec[blockN-1] = 0;
  
  // Increasing K values, 0 .. 2 for a total of 16 blocks
  
  {
    int currentK = 0;
    
    for (int i = 0; i < blockN; i++) {
      blockOptimalKTableVec[i] = currentK;
      currentK += 1;
      if (currentK > 2) {
        currentK= 0;
      }
    }
  }
  
  if ((1)) {
    printf("k input blocki order:\n");
    
    for (int i = 0; i < blockOptimalKTableVec.size(); i++) {
      int k = blockOptimalKTableVec[i];
      printf("%1d ", k);
    }
    
    printf("\n");
  }
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  if ((1)) {
    printf("blocki order:\n");
    
    for (int i = 0; i < blockiLookupVec.size(); i++) {
      int blocki = blockiLookupVec[i];
      printf("%2d ", blocki);
    }
    
    printf("\n");
  }
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixelsVec.data();
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  vector<uint8_t> halfBlockOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                s32OrderPixelsVec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec,
                                &halfBlockOptimalKTableVec);
  
  XCTAssert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size(), @"same size");
  
  int sizeWOPadding = (int) (blockiOptimalKTableVec.size() - 1);
  XCTAssert((sizeWOPadding * 2 + 1) == (int)halfBlockOptimalKTableVec.size(), @"half block double size");
  
  if ((1)) {
    printf("k output order (len %d):\n", (int)blockiOptimalKTableVec.size());
    
    for (int i = 0; i < blockiOptimalKTableVec.size(); i++) {
      int kVal = blockiOptimalKTableVec[i];
      printf("%1d, ", kVal);
    }
    
    printf("\n");
  }
  
  if ((1)) {
    printf("k half block output order (len %d):\n", (int)halfBlockOptimalKTableVec.size());
    
    for (int i = 0; i < halfBlockOptimalKTableVec.size(); i++) {
      int kVal = halfBlockOptimalKTableVec[i];
      printf("%1d, ", kVal);
    }
    
    printf("\n");
  }
  
  // Encode as rice bits and then decode with stream based decode for sanity check
  
  {
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = s32OrderPixelsVec.data();
    
    //const uint8_t *blockOptimalKTable = blockOptimalKTableVec.data();
    const uint8_t *blockOptimalKTable = halfBlockOptimalKTableVec.data();
    const int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
    
    vector<uint8_t> riceEncodedVec = encode(blockSymbols,
                                            numBlockSymbols,
                                            blockDim,
                                            blockOptimalKTable,
                                            blockOptimalKTableLen,
                                            blockN);
    
#if defined(DEBUG)
    {
      vector<uint8_t> outBufferVec(width*height);
      uint8_t *outBuffer = outBufferVec.data();
      
      vector<uint32_t> bitOffsetsEveryVal = generateBitOffsets(blockSymbols,
                                                               numBlockSymbols,
                                                               blockDim,
                                                               blockOptimalKTable,
                                                               blockOptimalKTableLen,
                                                               blockN,
                                                               1);
      
      decode(riceEncodedVec.data(),
             (int)riceEncodedVec.size(),
             outBuffer,
             width*height,
             blockDim,
             blockOptimalKTable,
             blockOptimalKTableLen,
             blockN,
             bitOffsetsEveryVal.data());
      
      int cmp = memcmp(blockSymbols, outBuffer, width*height);
      assert(cmp == 0);
      
      // Decode with non-stream rice method and validate against known good decoded values stream
      
      decodeParallelCheck(riceEncodedVec.data(),
                          (int)riceEncodedVec.size(),
                          outBuffer,
                          width*height,
                          blockDim,
                          blockOptimalKTable,
                          blockOptimalKTableLen,
                          blockN,
                          bitOffsetsEveryVal.data());
    }
#endif // DEBUG
  }
  
  return;
}

- (void)testS32_8x8_2x2_DiffK02 {
  const int blockDim = 8;
  const int blockiDim = 4;
  
  const int width = 8 * blockDim;
  const int height = 8 * blockDim;
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  vector<uint8_t> inputPixelsVec(width*height);
  vector<uint8_t> s32OrderPixelsVec(width*height);
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  blockOptimalKTableVec[blockN-1] = 0;
  
  // Increasing K values, 0 .. 2 for a total of 16 blocks
  
  {
    int currentK = 0;
    
    for (int i = 0; i < blockN; i++) {
      blockOptimalKTableVec[i] = currentK;
      currentK += 1;
      if (currentK > 2) {
        currentK= 0;
      }
    }
  }
  
  if ((1)) {
    printf("k input blocki order:\n");
    
    for (int i = 0; i < blockOptimalKTableVec.size(); i++) {
      int k = blockOptimalKTableVec[i];
      printf("%1d ", k);
    }
    
    printf("\n");
  }
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  if ((1)) {
    printf("blocki order:\n");
    
    for (int i = 0; i < blockiLookupVec.size(); i++) {
      int blocki = blockiLookupVec[i];
      printf("%2d ", blocki);
    }
    
    printf("\n");
  }
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixelsVec.data();
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  vector<uint8_t> halfBlockOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                s32OrderPixelsVec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec,
                                &halfBlockOptimalKTableVec);
  
  XCTAssert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size(), @"same size");
  
  if ((1)) {
    printf("k output order (len %d):\n", (int)blockiOptimalKTableVec.size());
    
    for (int i = 0; i < blockiOptimalKTableVec.size(); i++) {
      int kVal = blockiOptimalKTableVec[i];
      printf("%1d, ", kVal);
    }
    
    printf("\n");
  }
  
  if ((1)) {
    printf("k half block output order (len %d):\n", (int)halfBlockOptimalKTableVec.size());
    
    for (int i = 0; i < halfBlockOptimalKTableVec.size(); i++) {
      int kVal = halfBlockOptimalKTableVec[i];
      printf("%1d, ", kVal);
    }
    
    printf("\n");
  }
  
  // Encode as rice bits and then decode with stream based decode for sanity check
  
  {
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = s32OrderPixelsVec.data();
    
    //const uint8_t *blockOptimalKTable = blockOptimalKTableVec.data();
    const uint8_t *blockOptimalKTable = halfBlockOptimalKTableVec.data();
    const int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
    
    vector<uint8_t> riceEncodedVec = encode(blockSymbols,
                                            numBlockSymbols,
                                            blockDim,
                                            blockOptimalKTable,
                                            blockOptimalKTableLen,
                                            blockN);
    
#if defined(DEBUG)
    {
      vector<uint8_t> outBufferVec(width*height);
      uint8_t *outBuffer = outBufferVec.data();
      
      vector<uint32_t> bitOffsetsEveryVal = generateBitOffsets(blockSymbols,
                                                               numBlockSymbols,
                                                               blockDim,
                                                               blockOptimalKTable,
                                                               blockOptimalKTableLen,
                                                               blockN,
                                                               1);
      
      decode(riceEncodedVec.data(),
             (int)riceEncodedVec.size(),
             outBuffer,
             width*height,
             blockDim,
             blockOptimalKTable,
             blockOptimalKTableLen,
             blockN,
             bitOffsetsEveryVal.data());
      
      int cmp = memcmp(blockSymbols, outBuffer, width*height);
      assert(cmp == 0);
      
      // Decode with non-stream rice method and validate against known good decoded values stream
      
      decodeParallelCheck(riceEncodedVec.data(),
                          (int)riceEncodedVec.size(),
                          outBuffer,
                          width*height,
                          blockDim,
                          blockOptimalKTable,
                          blockOptimalKTableLen,
                          blockN,
                          bitOffsetsEveryVal.data());
    }
#endif // DEBUG
  }
  
  return;
}

// Format 4 2x2 blocks into a partial s32 stream
// and check that the blocki mapping logic is
// working as expected. An input blocki value
// is used to access blocki data from the input
// formatted as block data.

- (void)testFormatSmallBlockiToBigBlocksOffset1 {
  const int blockDim = 2;
  //const int blockiDim = 4;
  
  // Input data is in image order
  
  int numBlocksInWidth = 2;
  int numBlocksInHeight = 2;
  
  int width = numBlocksInWidth * blockDim;
  int height = numBlocksInHeight * blockDim;
  
  uint8_t inputPixels[] = {
    // blocks 0, 1
    0, 1, 4, 5,
    2, 3, 6, 7,
    // blocks 2, 3
    8, 9, 12, 13,
    10, 11, 14, 15
  };
  
  // Image order -> block ordering
  
  vector<uint8_t> inputBlockOrderVec;
  
  {
    BlockEncoder<uint8_t, blockDim> encoder;
    
    encoder.splitIntoBlocks(inputPixels, sizeof(inputPixels)/sizeof(inputPixels[0]), width, height, numBlocksInWidth, numBlocksInHeight, 0);
    
    XCTAssert(encoder.blockVectors.size() == 4);
    XCTAssert(encoder.blockVectors[0].size() == 4);
    
    for ( vector<uint8_t> & vec : encoder.blockVectors ) {
      for ( uint8_t bVal : vec ) {
        inputBlockOrderVec.push_back(bVal);
      }
    }
    
    // block by block data should be increasing values from 0 to 15
    
    XCTAssert(inputBlockOrderVec.size() == 16, @"vec size");
    
    for (int i = 0; i < inputBlockOrderVec.size(); i++) {
      uint8_t bval = inputBlockOrderVec[i];
      uint8_t expected = i;
      XCTAssert(bval == expected, @"bval == expected : %d == %d", bval, expected);
    }
  }
  
  vector<uint8_t> outputS32Vec;
  outputS32Vec.resize(inputBlockOrderVec.size());
  
  // blocki mapping table
  
  int blockN = (numBlocksInWidth * numBlocksInHeight);
  int numSegments = 4;
  
  uint32_t blockiMap[] = {
    0, 1,
    2, 3
  };
  
  uint8_t expectedS32Pixels[] = {
    // block 0 A
    0, 1,
    // block 0 B
    2, 3,
    // block 1 A
    4, 5,
    // block 1 B
    6, 7,
    
    // block 2 A
    8, 9,
    // block 2 B
    10, 11,
    // block 3 A
    12, 13,
    // block 3 B
    14, 15,
  };
  
  block_s32_format_block_layout(inputBlockOrderVec.data(),
                                outputS32Vec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                blockiMap);
  
  for (int i = 0; i < outputS32Vec.size(); i++) {
    uint8_t bval = outputS32Vec[i];
    uint8_t expected = expectedS32Pixels[i];
    XCTAssert(bval == expected, @"bval == expected : %d == %d", bval, expected);
  }
  
  return;
}

// Same setup as above except that a blocki reordering table
// is passed into block_s32_format_block_layout() to reorder
// input blocki values into s32 stream order.

- (void)testFormatSmallBlockiToBigBlocksOffset2 {
  const int blockDim = 2;
  //const int blockiDim = 4;
  
  // Input data is in image order
  
  int numBlocksInWidth = 2;
  int numBlocksInHeight = 2;
  
  int width = numBlocksInWidth * blockDim;
  int height = numBlocksInHeight * blockDim;
  
  uint8_t inputPixels[] = {
    // blocks 0, 1
    0, 1, 4, 5,
    2, 3, 6, 7,
    // blocks 2, 3
    8, 9, 12, 13,
    10, 11, 14, 15
  };
  
  // Image order -> block ordering
  
  vector<uint8_t> inputBlockOrderVec;
  
  {
    BlockEncoder<uint8_t, blockDim> encoder;
    
    encoder.splitIntoBlocks(inputPixels, sizeof(inputPixels)/sizeof(inputPixels[0]), width, height, numBlocksInWidth, numBlocksInHeight, 0);
    
    XCTAssert(encoder.blockVectors.size() == 4);
    XCTAssert(encoder.blockVectors[0].size() == 4);
    
    for ( vector<uint8_t> & vec : encoder.blockVectors ) {
      for ( uint8_t bVal : vec ) {
        inputBlockOrderVec.push_back(bVal);
      }
    }
    
    // block by block data should be increasing values from 0 to 15
    
    XCTAssert(inputBlockOrderVec.size() == 16, @"vec size");
    
    for (int i = 0; i < inputBlockOrderVec.size(); i++) {
      uint8_t bval = inputBlockOrderVec[i];
      uint8_t expected = i;
      XCTAssert(bval == expected, @"bval == expected : %d == %d", bval, expected);
    }
  }
  
  vector<uint8_t> outputS32Vec;
  outputS32Vec.resize(inputBlockOrderVec.size());
  
  // blocki mapping table
  
  int blockN = (numBlocksInWidth * numBlocksInHeight);
  int numSegments = 4;
  
  uint32_t blockiMap[] = {
    3, 2,
    1, 0
  };
  
  uint8_t expectedS32Pixels[] = {
    // block 3 A
    12, 13,
    // block 3 B
    14, 15,
    // block 2 A
    8, 9,
    // block 2 B
    10, 11,
    
    // block 1 A
    4, 5,
    // block 1 B
    6, 7,
    // block 0 A
    0, 1,
    // block 0 B
    2, 3
  };
  
  block_s32_format_block_layout(inputBlockOrderVec.data(),
                                outputS32Vec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                blockiMap);
  
  for (int i = 0; i < outputS32Vec.size(); i++) {
    uint8_t bval = outputS32Vec[i];
    uint8_t expected = expectedS32Pixels[i];
    XCTAssert(bval == expected, @"bval == expected : %d == %d", bval, expected);
  }
  
  return;
}

// Generate 8x8 block ordered data and then format into S32 stream
// followed by decoder impl that reads formatted stream and
// decoded into image order.

- (void)testTID_Ex1 {
  const int blockDim = 8;
  
  // 1x1 in terms of 8x8 blocks
  const int width = 4 * blockDim;
  const int height = 4 * blockDim;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  // Render tid into BGRA formatted output array
  
  int width4 = width / sizeof(uint32_t);
  uint32_t decodedPixels32[width4*height];
  memset(decodedPixels32, 0, sizeof(decodedPixels32));
  uint32_t inoutBlockOffsetTable[32];
  
  RiceRenderUniform riceRenderUniform;
  riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
  riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  riceRenderUniform.numBlocksEachSegment = 1;
  
  for (int tid = 0; tid < 32; tid++) {
    kernel_render_rice_typed<blockDim>(decodedPixels32,
                                       riceRenderUniform,
                                       inoutBlockOffsetTable,
                                       NULL,
                                       NULL,
                                       RenderRiceTypedTid,
                                       0,
                                       tid,
                                       NULL);
  }
  
  uint8_t decodedBytes[width*height];
  memcpy(decodedBytes, decodedPixels32, sizeof(decodedPixels32));
  uint8_t *pixels8 = (uint8_t *) decodedBytes;
  
  if ((1)) {
    printf("decoded image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = pixels8[offset];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Expected
 
  uint8_t expectedBytes[width*height] = {
    0,  0,  0,  0,  0,  0,  0,  0,  2,  2,  2,  2,  2,  2,  2,  2,  4,  4,  4,  4,  4,  4,  4,  4,  6,  6,  6,  6,  6,  6,  6,  6,
    0,  0,  0,  0,  0,  0,  0,  0,  2,  2,  2,  2,  2,  2,  2,  2,  4,  4,  4,  4,  4,  4,  4,  4,  6,  6,  6,  6,  6,  6,  6,  6,
    0,  0,  0,  0,  0,  0,  0,  0,  2,  2,  2,  2,  2,  2,  2,  2,  4,  4,  4,  4,  4,  4,  4,  4,  6,  6,  6,  6,  6,  6,  6,  6,
    0,  0,  0,  0,  0,  0,  0,  0,  2,  2,  2,  2,  2,  2,  2,  2,  4,  4,  4,  4,  4,  4,  4,  4,  6,  6,  6,  6,  6,  6,  6,  6,
    1,  1,  1,  1,  1,  1,  1,  1,  3,  3,  3,  3,  3,  3,  3,  3,  5,  5,  5,  5,  5,  5,  5,  5,  7,  7,  7,  7,  7,  7,  7,  7,
    1,  1,  1,  1,  1,  1,  1,  1,  3,  3,  3,  3,  3,  3,  3,  3,  5,  5,  5,  5,  5,  5,  5,  5,  7,  7,  7,  7,  7,  7,  7,  7,
    1,  1,  1,  1,  1,  1,  1,  1,  3,  3,  3,  3,  3,  3,  3,  3,  5,  5,  5,  5,  5,  5,  5,  5,  7,  7,  7,  7,  7,  7,  7,  7,
    1,  1,  1,  1,  1,  1,  1,  1,  3,  3,  3,  3,  3,  3,  3,  3,  5,  5,  5,  5,  5,  5,  5,  5,  7,  7,  7,  7,  7,  7,  7,  7,
    8,  8,  8,  8,  8,  8,  8,  8, 10, 10, 10, 10, 10, 10, 10, 10, 12, 12, 12, 12, 12, 12, 12, 12, 14, 14, 14, 14, 14, 14, 14, 14,
    8,  8,  8,  8,  8,  8,  8,  8, 10, 10, 10, 10, 10, 10, 10, 10, 12, 12, 12, 12, 12, 12, 12, 12, 14, 14, 14, 14, 14, 14, 14, 14,
    8,  8,  8,  8,  8,  8,  8,  8, 10, 10, 10, 10, 10, 10, 10, 10, 12, 12, 12, 12, 12, 12, 12, 12, 14, 14, 14, 14, 14, 14, 14, 14,
    8,  8,  8,  8,  8,  8,  8,  8, 10, 10, 10, 10, 10, 10, 10, 10, 12, 12, 12, 12, 12, 12, 12, 12, 14, 14, 14, 14, 14, 14, 14, 14,
    9,  9,  9,  9,  9,  9,  9,  9, 11, 11, 11, 11, 11, 11, 11, 11, 13, 13, 13, 13, 13, 13, 13, 13, 15, 15, 15, 15, 15, 15, 15, 15,
    9,  9,  9,  9,  9,  9,  9,  9, 11, 11, 11, 11, 11, 11, 11, 11, 13, 13, 13, 13, 13, 13, 13, 13, 15, 15, 15, 15, 15, 15, 15, 15,
    9,  9,  9,  9,  9,  9,  9,  9, 11, 11, 11, 11, 11, 11, 11, 11, 13, 13, 13, 13, 13, 13, 13, 13, 15, 15, 15, 15, 15, 15, 15, 15,
    9,  9,  9,  9,  9,  9,  9,  9, 11, 11, 11, 11, 11, 11, 11, 11, 13, 13, 13, 13, 13, 13, 13, 13, 15, 15, 15, 15, 15, 15, 15, 15,
    16, 16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22,
    16, 16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22,
    16, 16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22,
    16, 16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22,
    17, 17, 17, 17, 17, 17, 17, 17, 19, 19, 19, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 21, 21, 23, 23, 23, 23, 23, 23, 23, 23,
    17, 17, 17, 17, 17, 17, 17, 17, 19, 19, 19, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 21, 21, 23, 23, 23, 23, 23, 23, 23, 23,
    17, 17, 17, 17, 17, 17, 17, 17, 19, 19, 19, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 21, 21, 23, 23, 23, 23, 23, 23, 23, 23,
    17, 17, 17, 17, 17, 17, 17, 17, 19, 19, 19, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 21, 21, 23, 23, 23, 23, 23, 23, 23, 23,
    24, 24, 24, 24, 24, 24, 24, 24, 26, 26, 26, 26, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 30, 30, 30, 30, 30, 30, 30, 30,
    24, 24, 24, 24, 24, 24, 24, 24, 26, 26, 26, 26, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 30, 30, 30, 30, 30, 30, 30, 30,
    24, 24, 24, 24, 24, 24, 24, 24, 26, 26, 26, 26, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 30, 30, 30, 30, 30, 30, 30, 30,
    24, 24, 24, 24, 24, 24, 24, 24, 26, 26, 26, 26, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 30, 30, 30, 30, 30, 30, 30, 30,
    25, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31, 31, 31, 31,
    25, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31, 31, 31, 31,
    25, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31, 31, 31, 31,
    25, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31, 31, 31, 31
  };
  
  for (int i = 0; i < (width*height); i++) {
    uint8_t bval = decodedBytes[i];
    uint8_t expected = expectedBytes[i];
    XCTAssert(bval == expected, @"bval == expected : %d == %d", bval, expected);
  }
  
  return;
}

- (void)testTID_Ex2 {
  const int blockDim = 8;
  
  // 2x1 in terms of 8x8 blocks
  const int width = 8 * blockDim;
  const int height = 4 * blockDim;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  // Render tid into BGRA formatted output array
  
  int width4 = width / sizeof(uint32_t);
  vector<uint32_t> decodedPixels32Vec;
  decodedPixels32Vec.resize(width4*height);
  uint32_t *decodedPixels32 = decodedPixels32Vec.data();
  memset(decodedPixels32, 0xFF, decodedPixels32Vec.size() * sizeof(uint32_t));
  
  RiceRenderUniform riceRenderUniform;
  riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
  riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  riceRenderUniform.numBlocksEachSegment = 1;
  
  // First block
  
  for (int tid = 0; tid < 32; tid++) {
    kernel_render_rice_typed<blockDim>(decodedPixels32,
                                       riceRenderUniform,
                                       NULL,
                                       NULL,
                                       NULL,
                                       RenderRiceTypedTid,
                                       0,
                                       tid,
                                       NULL);
  }
  
  // Second block
  
  for (int tid = 0; tid < 32; tid++) {
    kernel_render_rice_typed<blockDim>(decodedPixels32,
                                       riceRenderUniform,
                                       NULL,
                                       NULL,
                                       NULL,
                                       RenderRiceTypedTid,
                                       1,
                                       tid,
                                       NULL);
  }
  
  uint8_t decodedBytes[width*height];
  memcpy(decodedBytes, decodedPixels32, decodedPixels32Vec.size() * sizeof(uint32_t));
  uint8_t *pixels8 = (uint8_t *) decodedBytes;
  
  if ((1)) {
    printf("decoded image order: %d x %d\n", width, height);
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = pixels8[offset];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Expected
  
  uint8_t expectedBytes[width*height] = {
    0,  0,  0,  0,  0,  0,  0,  0,  2,  2,  2,  2,  2,  2,  2,  2,  4,  4,  4,  4,  4,  4,  4,  4,  6,  6,  6,  6,  6,  6,  6,  6,  0,  0,  0,  0,  0,  0,  0,  0,  2,  2,  2,  2,  2,  2,  2,  2,  4,  4,  4,  4,  4,  4,  4,  4,  6,  6,  6,  6,  6,  6,  6,  6,
    0,  0,  0,  0,  0,  0,  0,  0,  2,  2,  2,  2,  2,  2,  2,  2,  4,  4,  4,  4,  4,  4,  4,  4,  6,  6,  6,  6,  6,  6,  6,  6,  0,  0,  0,  0,  0,  0,  0,  0,  2,  2,  2,  2,  2,  2,  2,  2,  4,  4,  4,  4,  4,  4,  4,  4,  6,  6,  6,  6,  6,  6,  6,  6,
    0,  0,  0,  0,  0,  0,  0,  0,  2,  2,  2,  2,  2,  2,  2,  2,  4,  4,  4,  4,  4,  4,  4,  4,  6,  6,  6,  6,  6,  6,  6,  6,  0,  0,  0,  0,  0,  0,  0,  0,  2,  2,  2,  2,  2,  2,  2,  2,  4,  4,  4,  4,  4,  4,  4,  4,  6,  6,  6,  6,  6,  6,  6,  6,
    0,  0,  0,  0,  0,  0,  0,  0,  2,  2,  2,  2,  2,  2,  2,  2,  4,  4,  4,  4,  4,  4,  4,  4,  6,  6,  6,  6,  6,  6,  6,  6,  0,  0,  0,  0,  0,  0,  0,  0,  2,  2,  2,  2,  2,  2,  2,  2,  4,  4,  4,  4,  4,  4,  4,  4,  6,  6,  6,  6,  6,  6,  6,  6,
    1,  1,  1,  1,  1,  1,  1,  1,  3,  3,  3,  3,  3,  3,  3,  3,  5,  5,  5,  5,  5,  5,  5,  5,  7,  7,  7,  7,  7,  7,  7,  7,  1,  1,  1,  1,  1,  1,  1,  1,  3,  3,  3,  3,  3,  3,  3,  3,  5,  5,  5,  5,  5,  5,  5,  5,  7,  7,  7,  7,  7,  7,  7,  7,
    1,  1,  1,  1,  1,  1,  1,  1,  3,  3,  3,  3,  3,  3,  3,  3,  5,  5,  5,  5,  5,  5,  5,  5,  7,  7,  7,  7,  7,  7,  7,  7,  1,  1,  1,  1,  1,  1,  1,  1,  3,  3,  3,  3,  3,  3,  3,  3,  5,  5,  5,  5,  5,  5,  5,  5,  7,  7,  7,  7,  7,  7,  7,  7,
    1,  1,  1,  1,  1,  1,  1,  1,  3,  3,  3,  3,  3,  3,  3,  3,  5,  5,  5,  5,  5,  5,  5,  5,  7,  7,  7,  7,  7,  7,  7,  7,  1,  1,  1,  1,  1,  1,  1,  1,  3,  3,  3,  3,  3,  3,  3,  3,  5,  5,  5,  5,  5,  5,  5,  5,  7,  7,  7,  7,  7,  7,  7,  7,
    1,  1,  1,  1,  1,  1,  1,  1,  3,  3,  3,  3,  3,  3,  3,  3,  5,  5,  5,  5,  5,  5,  5,  5,  7,  7,  7,  7,  7,  7,  7,  7,  1,  1,  1,  1,  1,  1,  1,  1,  3,  3,  3,  3,  3,  3,  3,  3,  5,  5,  5,  5,  5,  5,  5,  5,  7,  7,  7,  7,  7,  7,  7,  7,
    8,  8,  8,  8,  8,  8,  8,  8, 10, 10, 10, 10, 10, 10, 10, 10, 12, 12, 12, 12, 12, 12, 12, 12, 14, 14, 14, 14, 14, 14, 14, 14,  8,  8,  8,  8,  8,  8,  8,  8, 10, 10, 10, 10, 10, 10, 10, 10, 12, 12, 12, 12, 12, 12, 12, 12, 14, 14, 14, 14, 14, 14, 14, 14,
    8,  8,  8,  8,  8,  8,  8,  8, 10, 10, 10, 10, 10, 10, 10, 10, 12, 12, 12, 12, 12, 12, 12, 12, 14, 14, 14, 14, 14, 14, 14, 14,  8,  8,  8,  8,  8,  8,  8,  8, 10, 10, 10, 10, 10, 10, 10, 10, 12, 12, 12, 12, 12, 12, 12, 12, 14, 14, 14, 14, 14, 14, 14, 14,
    8,  8,  8,  8,  8,  8,  8,  8, 10, 10, 10, 10, 10, 10, 10, 10, 12, 12, 12, 12, 12, 12, 12, 12, 14, 14, 14, 14, 14, 14, 14, 14,  8,  8,  8,  8,  8,  8,  8,  8, 10, 10, 10, 10, 10, 10, 10, 10, 12, 12, 12, 12, 12, 12, 12, 12, 14, 14, 14, 14, 14, 14, 14, 14,
    8,  8,  8,  8,  8,  8,  8,  8, 10, 10, 10, 10, 10, 10, 10, 10, 12, 12, 12, 12, 12, 12, 12, 12, 14, 14, 14, 14, 14, 14, 14, 14,  8,  8,  8,  8,  8,  8,  8,  8, 10, 10, 10, 10, 10, 10, 10, 10, 12, 12, 12, 12, 12, 12, 12, 12, 14, 14, 14, 14, 14, 14, 14, 14,
    9,  9,  9,  9,  9,  9,  9,  9, 11, 11, 11, 11, 11, 11, 11, 11, 13, 13, 13, 13, 13, 13, 13, 13, 15, 15, 15, 15, 15, 15, 15, 15,  9,  9,  9,  9,  9,  9,  9,  9, 11, 11, 11, 11, 11, 11, 11, 11, 13, 13, 13, 13, 13, 13, 13, 13, 15, 15, 15, 15, 15, 15, 15, 15,
    9,  9,  9,  9,  9,  9,  9,  9, 11, 11, 11, 11, 11, 11, 11, 11, 13, 13, 13, 13, 13, 13, 13, 13, 15, 15, 15, 15, 15, 15, 15, 15,  9,  9,  9,  9,  9,  9,  9,  9, 11, 11, 11, 11, 11, 11, 11, 11, 13, 13, 13, 13, 13, 13, 13, 13, 15, 15, 15, 15, 15, 15, 15, 15,
    9,  9,  9,  9,  9,  9,  9,  9, 11, 11, 11, 11, 11, 11, 11, 11, 13, 13, 13, 13, 13, 13, 13, 13, 15, 15, 15, 15, 15, 15, 15, 15,  9,  9,  9,  9,  9,  9,  9,  9, 11, 11, 11, 11, 11, 11, 11, 11, 13, 13, 13, 13, 13, 13, 13, 13, 15, 15, 15, 15, 15, 15, 15, 15,
    9,  9,  9,  9,  9,  9,  9,  9, 11, 11, 11, 11, 11, 11, 11, 11, 13, 13, 13, 13, 13, 13, 13, 13, 15, 15, 15, 15, 15, 15, 15, 15,  9,  9,  9,  9,  9,  9,  9,  9, 11, 11, 11, 11, 11, 11, 11, 11, 13, 13, 13, 13, 13, 13, 13, 13, 15, 15, 15, 15, 15, 15, 15, 15,
    16, 16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22, 16, 16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22,
    16, 16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22, 16, 16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22,
    16, 16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22, 16, 16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22,
    16, 16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22, 16, 16, 16, 16, 16, 16, 16, 16, 18, 18, 18, 18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 20, 22, 22, 22, 22, 22, 22, 22, 22,
    17, 17, 17, 17, 17, 17, 17, 17, 19, 19, 19, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 21, 21, 23, 23, 23, 23, 23, 23, 23, 23, 17, 17, 17, 17, 17, 17, 17, 17, 19, 19, 19, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 21, 21, 23, 23, 23, 23, 23, 23, 23, 23,
    17, 17, 17, 17, 17, 17, 17, 17, 19, 19, 19, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 21, 21, 23, 23, 23, 23, 23, 23, 23, 23, 17, 17, 17, 17, 17, 17, 17, 17, 19, 19, 19, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 21, 21, 23, 23, 23, 23, 23, 23, 23, 23,
    17, 17, 17, 17, 17, 17, 17, 17, 19, 19, 19, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 21, 21, 23, 23, 23, 23, 23, 23, 23, 23, 17, 17, 17, 17, 17, 17, 17, 17, 19, 19, 19, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 21, 21, 23, 23, 23, 23, 23, 23, 23, 23,
    17, 17, 17, 17, 17, 17, 17, 17, 19, 19, 19, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 21, 21, 23, 23, 23, 23, 23, 23, 23, 23, 17, 17, 17, 17, 17, 17, 17, 17, 19, 19, 19, 19, 19, 19, 19, 19, 21, 21, 21, 21, 21, 21, 21, 21, 23, 23, 23, 23, 23, 23, 23, 23,
    24, 24, 24, 24, 24, 24, 24, 24, 26, 26, 26, 26, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 30, 30, 30, 30, 30, 30, 30, 30, 24, 24, 24, 24, 24, 24, 24, 24, 26, 26, 26, 26, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 30, 30, 30, 30, 30, 30, 30, 30,
    24, 24, 24, 24, 24, 24, 24, 24, 26, 26, 26, 26, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 30, 30, 30, 30, 30, 30, 30, 30, 24, 24, 24, 24, 24, 24, 24, 24, 26, 26, 26, 26, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 30, 30, 30, 30, 30, 30, 30, 30,
    24, 24, 24, 24, 24, 24, 24, 24, 26, 26, 26, 26, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 30, 30, 30, 30, 30, 30, 30, 30, 24, 24, 24, 24, 24, 24, 24, 24, 26, 26, 26, 26, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 30, 30, 30, 30, 30, 30, 30, 30,
    24, 24, 24, 24, 24, 24, 24, 24, 26, 26, 26, 26, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 30, 30, 30, 30, 30, 30, 30, 30, 24, 24, 24, 24, 24, 24, 24, 24, 26, 26, 26, 26, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 30, 30, 30, 30, 30, 30, 30, 30,
    25, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31, 31, 31, 31, 25, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31, 31, 31, 31,
    25, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31, 31, 31, 31, 25, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31, 31, 31, 31,
    25, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31, 31, 31, 31, 25, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31, 31, 31, 31,
    25, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31, 31, 31, 31, 25, 25, 25, 25, 25, 25, 25, 25, 27, 27, 27, 27, 27, 27, 27, 27, 29, 29, 29, 29, 29, 29, 29, 29, 31, 31, 31, 31, 31, 31, 31, 31
  };
  
  for (int i = 0; i < (width*height); i++) {
    uint8_t bval = decodedBytes[i];
    uint8_t expected = expectedBytes[i];
    XCTAssert(bval == expected, @"bval == expected : %d == %d", bval, expected);
  }
  
  return;
}

// Generate 8x8 block ordered data and then format into S32 stream
// followed by decoder impl that reads formatted stream and
// decoded into image order.

- (void)testBlocki_Ex1 {
  const int blockDim = 8;
  const int bigBlockDim = 4;
  
  // 1x1 big blocks in terms of 8x8 blocks
  const int width = 4 * blockDim;
  const int height = 4 * blockDim;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / (blockDim * bigBlockDim);
  const int numBigBlocksInHeight = height / (blockDim * bigBlockDim);
  
  // Render blocki as 32 bit value into final array argument
  
  vector<uint32_t> blockiVec(width*height);
  
  RiceRenderUniform riceRenderUniform;
  riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
  riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  riceRenderUniform.numBlocksEachSegment = 1;
  
  for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
    for (int tid = 0; tid < 32; tid++) {
      kernel_render_rice_typed<blockDim>(NULL,
                                         riceRenderUniform,
                                         NULL,
                                         NULL,
                                         NULL,
                                         RenderRiceTypedBlocki,
                                         bigBlocki,
                                         tid,
                                         blockiVec.data());
    }
  }

  if ((0)) {
    printf("decoded blocki:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int blocki = blockiVec[offset];
        printf("%2d, ", blocki);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Expected
  
  uint32_t expectedBlocki[width*height] = {
    0,  0,  0,  0,  0,  0,  0,  0,  1,  1,  1,  1,  1,  1,  1,  1,  2,  2,  2,  2,  2,  2,  2,  2,  3,  3,  3,  3,  3,  3,  3,  3,
    0,  0,  0,  0,  0,  0,  0,  0,  1,  1,  1,  1,  1,  1,  1,  1,  2,  2,  2,  2,  2,  2,  2,  2,  3,  3,  3,  3,  3,  3,  3,  3,
    0,  0,  0,  0,  0,  0,  0,  0,  1,  1,  1,  1,  1,  1,  1,  1,  2,  2,  2,  2,  2,  2,  2,  2,  3,  3,  3,  3,  3,  3,  3,  3,
    0,  0,  0,  0,  0,  0,  0,  0,  1,  1,  1,  1,  1,  1,  1,  1,  2,  2,  2,  2,  2,  2,  2,  2,  3,  3,  3,  3,  3,  3,  3,  3,
    0,  0,  0,  0,  0,  0,  0,  0,  1,  1,  1,  1,  1,  1,  1,  1,  2,  2,  2,  2,  2,  2,  2,  2,  3,  3,  3,  3,  3,  3,  3,  3,
    0,  0,  0,  0,  0,  0,  0,  0,  1,  1,  1,  1,  1,  1,  1,  1,  2,  2,  2,  2,  2,  2,  2,  2,  3,  3,  3,  3,  3,  3,  3,  3,
    0,  0,  0,  0,  0,  0,  0,  0,  1,  1,  1,  1,  1,  1,  1,  1,  2,  2,  2,  2,  2,  2,  2,  2,  3,  3,  3,  3,  3,  3,  3,  3,
    0,  0,  0,  0,  0,  0,  0,  0,  1,  1,  1,  1,  1,  1,  1,  1,  2,  2,  2,  2,  2,  2,  2,  2,  3,  3,  3,  3,  3,  3,  3,  3,
    4,  4,  4,  4,  4,  4,  4,  4,  5,  5,  5,  5,  5,  5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  6,  7,  7,  7,  7,  7,  7,  7,  7,
    4,  4,  4,  4,  4,  4,  4,  4,  5,  5,  5,  5,  5,  5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  6,  7,  7,  7,  7,  7,  7,  7,  7,
    4,  4,  4,  4,  4,  4,  4,  4,  5,  5,  5,  5,  5,  5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  6,  7,  7,  7,  7,  7,  7,  7,  7,
    4,  4,  4,  4,  4,  4,  4,  4,  5,  5,  5,  5,  5,  5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  6,  7,  7,  7,  7,  7,  7,  7,  7,
    4,  4,  4,  4,  4,  4,  4,  4,  5,  5,  5,  5,  5,  5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  6,  7,  7,  7,  7,  7,  7,  7,  7,
    4,  4,  4,  4,  4,  4,  4,  4,  5,  5,  5,  5,  5,  5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  6,  7,  7,  7,  7,  7,  7,  7,  7,
    4,  4,  4,  4,  4,  4,  4,  4,  5,  5,  5,  5,  5,  5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  6,  7,  7,  7,  7,  7,  7,  7,  7,
    4,  4,  4,  4,  4,  4,  4,  4,  5,  5,  5,  5,  5,  5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  6,  7,  7,  7,  7,  7,  7,  7,  7,
    8,  8,  8,  8,  8,  8,  8,  8,  9,  9,  9,  9,  9,  9,  9,  9, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11,
    8,  8,  8,  8,  8,  8,  8,  8,  9,  9,  9,  9,  9,  9,  9,  9, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11,
    8,  8,  8,  8,  8,  8,  8,  8,  9,  9,  9,  9,  9,  9,  9,  9, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11,
    8,  8,  8,  8,  8,  8,  8,  8,  9,  9,  9,  9,  9,  9,  9,  9, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11,
    8,  8,  8,  8,  8,  8,  8,  8,  9,  9,  9,  9,  9,  9,  9,  9, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11,
    8,  8,  8,  8,  8,  8,  8,  8,  9,  9,  9,  9,  9,  9,  9,  9, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11,
    8,  8,  8,  8,  8,  8,  8,  8,  9,  9,  9,  9,  9,  9,  9,  9, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11,
    8,  8,  8,  8,  8,  8,  8,  8,  9,  9,  9,  9,  9,  9,  9,  9, 10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11,
    12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15,
    12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15,
    12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15,
    12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15,
    12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15,
    12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15,
    12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15,
    12, 12, 12, 12, 12, 12, 12, 12, 13, 13, 13, 13, 13, 13, 13, 13, 14, 14, 14, 14, 14, 14, 14, 14, 15, 15, 15, 15, 15, 15, 15, 15
  };
  
  for (int i = 0; i < (width*height); i++) {
    uint32_t blocki = blockiVec[i];
    uint32_t eBlocki = expectedBlocki[i];
    XCTAssert(blocki == eBlocki, @"blocki == expected : %d == %d : offset %d", blocki, eBlocki, i);
  }
  
  return;
}

// 8x4

- (void)testBlocki_Ex2 {
  const int blockDim = 8;
  const int bigBlockDim = 4;
  
  // 1x1 big blocks in terms of 8x8 blocks
  const int width = 8 * blockDim;
  const int height = 4 * blockDim;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;

  const int numBigBlocksInWidth = width / (blockDim * bigBlockDim);
  const int numBigBlocksInHeight = height / (blockDim * bigBlockDim);
  
  // Render blocki as 32 bit value into final array argument
  
  vector<uint32_t> blockiVec(width*height);
  
  RiceRenderUniform riceRenderUniform;
  riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
  riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  riceRenderUniform.numBlocksEachSegment = 1;
  
  for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
    for (int tid = 0; tid < 32; tid++) {
      kernel_render_rice_typed<blockDim>(NULL,
                                         riceRenderUniform,
                                         NULL,
                                         NULL,
                                         NULL,
                                         RenderRiceTypedBlocki,
                                         bigBlocki,
                                         tid,
                                         blockiVec.data());
    }
  }
  
  if ((1)) {
    printf("decoded blocki:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int blocki = blockiVec[offset];
        printf("%2d, ", blocki);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Expected
  
  uint32_t expectedBlocki[width*height] = {
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31
  };
  
  for (int i = 0; i < (width*height); i++) {
    uint32_t blocki = blockiVec[i];
    uint32_t eBlocki = expectedBlocki[i];
    XCTAssert(blocki == eBlocki, @"blocki == expected : %d == %d : offset %d", blocki, eBlocki, i);
  }
  
  return;
}

// 4x8

- (void)testBlocki_Ex3 {
  const int blockDim = 8;
  const int bigBlockDim = 4;
  
  // 1x1 big blocks in terms of 8x8 blocks
  const int width = 4 * blockDim;
  const int height = 8 * blockDim;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / (blockDim * bigBlockDim);
  const int numBigBlocksInHeight = height / (blockDim * bigBlockDim);
  
  // Render blocki as 32 bit value into final array argument
  
  vector<uint32_t> blockiVec(width*height);
  
  RiceRenderUniform riceRenderUniform;
  riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
  riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  riceRenderUniform.numBlocksEachSegment = 1;
  
  for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
    for (int tid = 0; tid < 32; tid++) {
      kernel_render_rice_typed<blockDim>(NULL,
                                         riceRenderUniform,
                                         NULL,
                                         NULL,
                                         NULL,
                                         RenderRiceTypedBlocki,
                                         bigBlocki,
                                         tid,
                                         blockiVec.data());
    }
  }
  
  if ((1)) {
    printf("decoded blocki:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int blocki = blockiVec[offset];
        printf("%2d, ", blocki);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Expected
  
  uint32_t expectedBlocki[width*height] = {
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,
    16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31
  };
  
  for (int i = 0; i < (width*height); i++) {
    uint32_t blocki = blockiVec[i];
    uint32_t eBlocki = expectedBlocki[i];
    XCTAssert(blocki == eBlocki, @"blocki == expected : %d == %d : offset %d", blocki, eBlocki, i);
  }
  
  return;
}

// 8x8

- (void)testBlocki_Ex4 {
  const int blockDim = 8;
  const int bigBlockDim = 4;
  
  // 1x1 big blocks in terms of 8x8 blocks
  const int width = 8 * blockDim;
  const int height = 8 * blockDim;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / (blockDim * bigBlockDim);
  const int numBigBlocksInHeight = height / (blockDim * bigBlockDim);
  
  // Render blocki as 32 bit value into final array argument
  
  vector<uint32_t> blockiVec(width*height);
  
  RiceRenderUniform riceRenderUniform;
  riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
  riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  riceRenderUniform.numBlocksEachSegment = 1;
  
  for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
    for (int tid = 0; tid < 32; tid++) {
      kernel_render_rice_typed<blockDim>(NULL,
                                         riceRenderUniform,
                                         NULL,
                                         NULL,
                                         NULL,
                                         RenderRiceTypedBlocki,
                                         bigBlocki,
                                         tid,
                                         blockiVec.data());
    }
  }
  
  if ((1)) {
    printf("decoded blocki:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int blocki = blockiVec[offset];
        printf("%2d, ", blocki);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Expected
  
  uint32_t expectedBlocki[width*height] = {
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    0,   0,   0,   0,   0,   0,   0,   0,   1,   1,   1,   1,   1,   1,   1,   1,   2,   2,   2,   2,   2,   2,   2,   2,   3,   3,   3,   3,   3,   3,   3,   3,  16,  16,  16,  16,  16,  16,  16,  16,  17,  17,  17,  17,  17,  17,  17,  17,  18,  18,  18,  18,  18,  18,  18,  18,  19,  19,  19,  19,  19,  19,  19,  19,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    4,   4,   4,   4,   4,   4,   4,   4,   5,   5,   5,   5,   5,   5,   5,   5,   6,   6,   6,   6,   6,   6,   6,   6,   7,   7,   7,   7,   7,   7,   7,   7,  20,  20,  20,  20,  20,  20,  20,  20,  21,  21,  21,  21,  21,  21,  21,  21,  22,  22,  22,  22,  22,  22,  22,  22,  23,  23,  23,  23,  23,  23,  23,  23,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    8,   8,   8,   8,   8,   8,   8,   8,   9,   9,   9,   9,   9,   9,   9,   9,  10,  10,  10,  10,  10,  10,  10,  10,  11,  11,  11,  11,  11,  11,  11,  11,  24,  24,  24,  24,  24,  24,  24,  24,  25,  25,  25,  25,  25,  25,  25,  25,  26,  26,  26,  26,  26,  26,  26,  26,  27,  27,  27,  27,  27,  27,  27,  27,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    12,  12,  12,  12,  12,  12,  12,  12,  13,  13,  13,  13,  13,  13,  13,  13,  14,  14,  14,  14,  14,  14,  14,  14,  15,  15,  15,  15,  15,  15,  15,  15,  28,  28,  28,  28,  28,  28,  28,  28,  29,  29,  29,  29,  29,  29,  29,  29,  30,  30,  30,  30,  30,  30,  30,  30,  31,  31,  31,  31,  31,  31,  31,  31,
    32,  32,  32,  32,  32,  32,  32,  32,  33,  33,  33,  33,  33,  33,  33,  33,  34,  34,  34,  34,  34,  34,  34,  34,  35,  35,  35,  35,  35,  35,  35,  35,  48,  48,  48,  48,  48,  48,  48,  48,  49,  49,  49,  49,  49,  49,  49,  49,  50,  50,  50,  50,  50,  50,  50,  50,  51,  51,  51,  51,  51,  51,  51,  51,
    32,  32,  32,  32,  32,  32,  32,  32,  33,  33,  33,  33,  33,  33,  33,  33,  34,  34,  34,  34,  34,  34,  34,  34,  35,  35,  35,  35,  35,  35,  35,  35,  48,  48,  48,  48,  48,  48,  48,  48,  49,  49,  49,  49,  49,  49,  49,  49,  50,  50,  50,  50,  50,  50,  50,  50,  51,  51,  51,  51,  51,  51,  51,  51,
    32,  32,  32,  32,  32,  32,  32,  32,  33,  33,  33,  33,  33,  33,  33,  33,  34,  34,  34,  34,  34,  34,  34,  34,  35,  35,  35,  35,  35,  35,  35,  35,  48,  48,  48,  48,  48,  48,  48,  48,  49,  49,  49,  49,  49,  49,  49,  49,  50,  50,  50,  50,  50,  50,  50,  50,  51,  51,  51,  51,  51,  51,  51,  51,
    32,  32,  32,  32,  32,  32,  32,  32,  33,  33,  33,  33,  33,  33,  33,  33,  34,  34,  34,  34,  34,  34,  34,  34,  35,  35,  35,  35,  35,  35,  35,  35,  48,  48,  48,  48,  48,  48,  48,  48,  49,  49,  49,  49,  49,  49,  49,  49,  50,  50,  50,  50,  50,  50,  50,  50,  51,  51,  51,  51,  51,  51,  51,  51,
    32,  32,  32,  32,  32,  32,  32,  32,  33,  33,  33,  33,  33,  33,  33,  33,  34,  34,  34,  34,  34,  34,  34,  34,  35,  35,  35,  35,  35,  35,  35,  35,  48,  48,  48,  48,  48,  48,  48,  48,  49,  49,  49,  49,  49,  49,  49,  49,  50,  50,  50,  50,  50,  50,  50,  50,  51,  51,  51,  51,  51,  51,  51,  51,
    32,  32,  32,  32,  32,  32,  32,  32,  33,  33,  33,  33,  33,  33,  33,  33,  34,  34,  34,  34,  34,  34,  34,  34,  35,  35,  35,  35,  35,  35,  35,  35,  48,  48,  48,  48,  48,  48,  48,  48,  49,  49,  49,  49,  49,  49,  49,  49,  50,  50,  50,  50,  50,  50,  50,  50,  51,  51,  51,  51,  51,  51,  51,  51,
    32,  32,  32,  32,  32,  32,  32,  32,  33,  33,  33,  33,  33,  33,  33,  33,  34,  34,  34,  34,  34,  34,  34,  34,  35,  35,  35,  35,  35,  35,  35,  35,  48,  48,  48,  48,  48,  48,  48,  48,  49,  49,  49,  49,  49,  49,  49,  49,  50,  50,  50,  50,  50,  50,  50,  50,  51,  51,  51,  51,  51,  51,  51,  51,
    32,  32,  32,  32,  32,  32,  32,  32,  33,  33,  33,  33,  33,  33,  33,  33,  34,  34,  34,  34,  34,  34,  34,  34,  35,  35,  35,  35,  35,  35,  35,  35,  48,  48,  48,  48,  48,  48,  48,  48,  49,  49,  49,  49,  49,  49,  49,  49,  50,  50,  50,  50,  50,  50,  50,  50,  51,  51,  51,  51,  51,  51,  51,  51,
    36,  36,  36,  36,  36,  36,  36,  36,  37,  37,  37,  37,  37,  37,  37,  37,  38,  38,  38,  38,  38,  38,  38,  38,  39,  39,  39,  39,  39,  39,  39,  39,  52,  52,  52,  52,  52,  52,  52,  52,  53,  53,  53,  53,  53,  53,  53,  53,  54,  54,  54,  54,  54,  54,  54,  54,  55,  55,  55,  55,  55,  55,  55,  55,
    36,  36,  36,  36,  36,  36,  36,  36,  37,  37,  37,  37,  37,  37,  37,  37,  38,  38,  38,  38,  38,  38,  38,  38,  39,  39,  39,  39,  39,  39,  39,  39,  52,  52,  52,  52,  52,  52,  52,  52,  53,  53,  53,  53,  53,  53,  53,  53,  54,  54,  54,  54,  54,  54,  54,  54,  55,  55,  55,  55,  55,  55,  55,  55,
    36,  36,  36,  36,  36,  36,  36,  36,  37,  37,  37,  37,  37,  37,  37,  37,  38,  38,  38,  38,  38,  38,  38,  38,  39,  39,  39,  39,  39,  39,  39,  39,  52,  52,  52,  52,  52,  52,  52,  52,  53,  53,  53,  53,  53,  53,  53,  53,  54,  54,  54,  54,  54,  54,  54,  54,  55,  55,  55,  55,  55,  55,  55,  55,
    36,  36,  36,  36,  36,  36,  36,  36,  37,  37,  37,  37,  37,  37,  37,  37,  38,  38,  38,  38,  38,  38,  38,  38,  39,  39,  39,  39,  39,  39,  39,  39,  52,  52,  52,  52,  52,  52,  52,  52,  53,  53,  53,  53,  53,  53,  53,  53,  54,  54,  54,  54,  54,  54,  54,  54,  55,  55,  55,  55,  55,  55,  55,  55,
    36,  36,  36,  36,  36,  36,  36,  36,  37,  37,  37,  37,  37,  37,  37,  37,  38,  38,  38,  38,  38,  38,  38,  38,  39,  39,  39,  39,  39,  39,  39,  39,  52,  52,  52,  52,  52,  52,  52,  52,  53,  53,  53,  53,  53,  53,  53,  53,  54,  54,  54,  54,  54,  54,  54,  54,  55,  55,  55,  55,  55,  55,  55,  55,
    36,  36,  36,  36,  36,  36,  36,  36,  37,  37,  37,  37,  37,  37,  37,  37,  38,  38,  38,  38,  38,  38,  38,  38,  39,  39,  39,  39,  39,  39,  39,  39,  52,  52,  52,  52,  52,  52,  52,  52,  53,  53,  53,  53,  53,  53,  53,  53,  54,  54,  54,  54,  54,  54,  54,  54,  55,  55,  55,  55,  55,  55,  55,  55,
    36,  36,  36,  36,  36,  36,  36,  36,  37,  37,  37,  37,  37,  37,  37,  37,  38,  38,  38,  38,  38,  38,  38,  38,  39,  39,  39,  39,  39,  39,  39,  39,  52,  52,  52,  52,  52,  52,  52,  52,  53,  53,  53,  53,  53,  53,  53,  53,  54,  54,  54,  54,  54,  54,  54,  54,  55,  55,  55,  55,  55,  55,  55,  55,
    36,  36,  36,  36,  36,  36,  36,  36,  37,  37,  37,  37,  37,  37,  37,  37,  38,  38,  38,  38,  38,  38,  38,  38,  39,  39,  39,  39,  39,  39,  39,  39,  52,  52,  52,  52,  52,  52,  52,  52,  53,  53,  53,  53,  53,  53,  53,  53,  54,  54,  54,  54,  54,  54,  54,  54,  55,  55,  55,  55,  55,  55,  55,  55,
    40,  40,  40,  40,  40,  40,  40,  40,  41,  41,  41,  41,  41,  41,  41,  41,  42,  42,  42,  42,  42,  42,  42,  42,  43,  43,  43,  43,  43,  43,  43,  43,  56,  56,  56,  56,  56,  56,  56,  56,  57,  57,  57,  57,  57,  57,  57,  57,  58,  58,  58,  58,  58,  58,  58,  58,  59,  59,  59,  59,  59,  59,  59,  59,
    40,  40,  40,  40,  40,  40,  40,  40,  41,  41,  41,  41,  41,  41,  41,  41,  42,  42,  42,  42,  42,  42,  42,  42,  43,  43,  43,  43,  43,  43,  43,  43,  56,  56,  56,  56,  56,  56,  56,  56,  57,  57,  57,  57,  57,  57,  57,  57,  58,  58,  58,  58,  58,  58,  58,  58,  59,  59,  59,  59,  59,  59,  59,  59,
    40,  40,  40,  40,  40,  40,  40,  40,  41,  41,  41,  41,  41,  41,  41,  41,  42,  42,  42,  42,  42,  42,  42,  42,  43,  43,  43,  43,  43,  43,  43,  43,  56,  56,  56,  56,  56,  56,  56,  56,  57,  57,  57,  57,  57,  57,  57,  57,  58,  58,  58,  58,  58,  58,  58,  58,  59,  59,  59,  59,  59,  59,  59,  59,
    40,  40,  40,  40,  40,  40,  40,  40,  41,  41,  41,  41,  41,  41,  41,  41,  42,  42,  42,  42,  42,  42,  42,  42,  43,  43,  43,  43,  43,  43,  43,  43,  56,  56,  56,  56,  56,  56,  56,  56,  57,  57,  57,  57,  57,  57,  57,  57,  58,  58,  58,  58,  58,  58,  58,  58,  59,  59,  59,  59,  59,  59,  59,  59,
    40,  40,  40,  40,  40,  40,  40,  40,  41,  41,  41,  41,  41,  41,  41,  41,  42,  42,  42,  42,  42,  42,  42,  42,  43,  43,  43,  43,  43,  43,  43,  43,  56,  56,  56,  56,  56,  56,  56,  56,  57,  57,  57,  57,  57,  57,  57,  57,  58,  58,  58,  58,  58,  58,  58,  58,  59,  59,  59,  59,  59,  59,  59,  59,
    40,  40,  40,  40,  40,  40,  40,  40,  41,  41,  41,  41,  41,  41,  41,  41,  42,  42,  42,  42,  42,  42,  42,  42,  43,  43,  43,  43,  43,  43,  43,  43,  56,  56,  56,  56,  56,  56,  56,  56,  57,  57,  57,  57,  57,  57,  57,  57,  58,  58,  58,  58,  58,  58,  58,  58,  59,  59,  59,  59,  59,  59,  59,  59,
    40,  40,  40,  40,  40,  40,  40,  40,  41,  41,  41,  41,  41,  41,  41,  41,  42,  42,  42,  42,  42,  42,  42,  42,  43,  43,  43,  43,  43,  43,  43,  43,  56,  56,  56,  56,  56,  56,  56,  56,  57,  57,  57,  57,  57,  57,  57,  57,  58,  58,  58,  58,  58,  58,  58,  58,  59,  59,  59,  59,  59,  59,  59,  59,
    40,  40,  40,  40,  40,  40,  40,  40,  41,  41,  41,  41,  41,  41,  41,  41,  42,  42,  42,  42,  42,  42,  42,  42,  43,  43,  43,  43,  43,  43,  43,  43,  56,  56,  56,  56,  56,  56,  56,  56,  57,  57,  57,  57,  57,  57,  57,  57,  58,  58,  58,  58,  58,  58,  58,  58,  59,  59,  59,  59,  59,  59,  59,  59,
    44,  44,  44,  44,  44,  44,  44,  44,  45,  45,  45,  45,  45,  45,  45,  45,  46,  46,  46,  46,  46,  46,  46,  46,  47,  47,  47,  47,  47,  47,  47,  47,  60,  60,  60,  60,  60,  60,  60,  60,  61,  61,  61,  61,  61,  61,  61,  61,  62,  62,  62,  62,  62,  62,  62,  62,  63,  63,  63,  63,  63,  63,  63,  63,
    44,  44,  44,  44,  44,  44,  44,  44,  45,  45,  45,  45,  45,  45,  45,  45,  46,  46,  46,  46,  46,  46,  46,  46,  47,  47,  47,  47,  47,  47,  47,  47,  60,  60,  60,  60,  60,  60,  60,  60,  61,  61,  61,  61,  61,  61,  61,  61,  62,  62,  62,  62,  62,  62,  62,  62,  63,  63,  63,  63,  63,  63,  63,  63,
    44,  44,  44,  44,  44,  44,  44,  44,  45,  45,  45,  45,  45,  45,  45,  45,  46,  46,  46,  46,  46,  46,  46,  46,  47,  47,  47,  47,  47,  47,  47,  47,  60,  60,  60,  60,  60,  60,  60,  60,  61,  61,  61,  61,  61,  61,  61,  61,  62,  62,  62,  62,  62,  62,  62,  62,  63,  63,  63,  63,  63,  63,  63,  63,
    44,  44,  44,  44,  44,  44,  44,  44,  45,  45,  45,  45,  45,  45,  45,  45,  46,  46,  46,  46,  46,  46,  46,  46,  47,  47,  47,  47,  47,  47,  47,  47,  60,  60,  60,  60,  60,  60,  60,  60,  61,  61,  61,  61,  61,  61,  61,  61,  62,  62,  62,  62,  62,  62,  62,  62,  63,  63,  63,  63,  63,  63,  63,  63,
    44,  44,  44,  44,  44,  44,  44,  44,  45,  45,  45,  45,  45,  45,  45,  45,  46,  46,  46,  46,  46,  46,  46,  46,  47,  47,  47,  47,  47,  47,  47,  47,  60,  60,  60,  60,  60,  60,  60,  60,  61,  61,  61,  61,  61,  61,  61,  61,  62,  62,  62,  62,  62,  62,  62,  62,  63,  63,  63,  63,  63,  63,  63,  63,
    44,  44,  44,  44,  44,  44,  44,  44,  45,  45,  45,  45,  45,  45,  45,  45,  46,  46,  46,  46,  46,  46,  46,  46,  47,  47,  47,  47,  47,  47,  47,  47,  60,  60,  60,  60,  60,  60,  60,  60,  61,  61,  61,  61,  61,  61,  61,  61,  62,  62,  62,  62,  62,  62,  62,  62,  63,  63,  63,  63,  63,  63,  63,  63,
    44,  44,  44,  44,  44,  44,  44,  44,  45,  45,  45,  45,  45,  45,  45,  45,  46,  46,  46,  46,  46,  46,  46,  46,  47,  47,  47,  47,  47,  47,  47,  47,  60,  60,  60,  60,  60,  60,  60,  60,  61,  61,  61,  61,  61,  61,  61,  61,  62,  62,  62,  62,  62,  62,  62,  62,  63,  63,  63,  63,  63,  63,  63,  63,
    44,  44,  44,  44,  44,  44,  44,  44,  45,  45,  45,  45,  45,  45,  45,  45,  46,  46,  46,  46,  46,  46,  46,  46,  47,  47,  47,  47,  47,  47,  47,  47,  60,  60,  60,  60,  60,  60,  60,  60,  61,  61,  61,  61,  61,  61,  61,  61,  62,  62,  62,  62,  62,  62,  62,  62,  63,  63,  63,  63,  63,  63,  63,  63
  };
  
  for (int i = 0; i < (width*height); i++) {
    uint32_t blocki = blockiVec[i];
    uint32_t eBlocki = expectedBlocki[i];
    XCTAssert(blocki == eBlocki, @"blocki == expected : %d == %d : offset %d", blocki, eBlocki, i);
  }
  
  return;
}

// 1x1 in terms of big blocks and k = 7

- (void)testGenerateImageOrder8x8And1x1Ex1 {
  const int blockDim = 8;
  const int blockiDim = 4;
  
  int constK = 7;
  
  // 8x8 blocks at 1x1 big blocks, aka 32x32
  const int width = 4 * blockDim;
  const int height = 4 * blockDim;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;

  const int numBigBlocksInWidth = width / (blockDim * blockiDim);
  const int numBigBlocksInHeight = height / (blockDim * blockiDim);
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  const int numBitOffsetsThisTest = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  memset(blockOptimalKTableVec.data(), constK, (int)blockOptimalKTableVec.size());
  
  int over = 1;
  
  for (int row = 0; row < height; row++) {
    for (int col = 0; col < width; col++) {
      int offset = (row * width) + col;
      int bVal = offset & 63;
      inputPixels[offset] = bVal;
      
      if ((offset != 0) && (bVal == 0)) {
        inputPixels[offset] += over;
        over += 1;
      }
    }
  }
  
  // Image is generated in block order so that the ascending
  // values are stored 1 block at a time.
  
  if ((1)) {
    printf("8x8 block order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Reorder into image order and print
  
  {
    // Reorder bytes from block order to image order via flatten
    
    BlockDecoder<uint8_t, blockDim> db;
    
    uint8_t *inPrefixBytesPtr = inputPixels;
    
    db.blockVectors.resize(numBlocksInWidth * numBlocksInHeight);
    
    for (int blocki = 0; blocki < (numBlocksInWidth * numBlocksInHeight); blocki++) {
      vector<uint8_t> & blockVec = db.blockVectors[blocki];
      // Append pixels from block by block data
      
      const int numBytes = blockDim * blockDim;
      blockVec.resize(numBytes);
      memcpy(blockVec.data(), inPrefixBytesPtr, numBytes);
      inPrefixBytesPtr += numBytes;
    }
    
    db.flattenAndCrop(inputImageOrderPixels,
                      width*height,
                      numBlocksInWidth,
                      numBlocksInHeight,
                      width,
                      height);
  }
  
  
  if ((1)) {
    printf("original image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputImageOrderPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Generate blocki ordering

  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;

  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixels;
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  vector<uint8_t> halfBlockOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                outputPixels,
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec,
                                &halfBlockOptimalKTableVec);
  
  XCTAssert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size(), @"same size");
  XCTAssert(blockiOptimalKTableVec == blockOptimalKTableVec, @"same k values");
  
  if ((1)) {
    printf("big block s32 image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = outputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Print blocki values in block order
  
  if ((1)) {
    printf("block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = outputPixels[offset++];
        printf("%3d ", bVal);
      }
      printf("\n");
    }
  }
  
  // Read 16 small blocks at a time from 32 streams
  // so that a big block of 32x32 is read in with
  // 8 reads per small block.
  
  vector<uint8_t> decodedS32PixelsVec(width*height);
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32PixelsVec.data(),
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((1)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32PixelsVec[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32PixelsVec[i];
      uint8_t expected = blockiReorderedVec[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (numFails < 10) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
          numFails += 1;
        }
      }
    }
  }
  
  // Note that blockOptimalKTableVec is replaced with blockiOptimalKTableVec
  // values here since the reordered table of K value is in big block iteration order.
  
  //blockOptimalKTableVec = blockiOptimalKTableVec;
  blockOptimalKTableVec = halfBlockOptimalKTableVec;
  
  // Encode as rice bits and then decode with stream based decode for sanity check
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    memset(decodedPixels32, 0xFF, width*height);
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    const uint8_t *blockOptimalKTable = blockOptimalKTableVec.data();
    const int blockOptimalKTableLen = (int) blockOptimalKTableVec.size();
    
    vector<uint8_t> riceEncodedVec = encode(blockSymbols,
                                            numBlockSymbols,
                                            blockDim,
                                            blockOptimalKTable,
                                            blockOptimalKTableLen,
                                            blockN);
    
#if defined(DEBUG)
    {
      vector<uint8_t> outBufferVec(width*height);
      uint8_t *outBuffer = outBufferVec.data();
      
      vector<uint32_t> bitOffsetsEveryVal = generateBitOffsets(blockSymbols,
                                                               numBlockSymbols,
                                                               blockDim,
                                                               blockOptimalKTable,
                                                               blockOptimalKTableLen,
                                                               blockN,
                                                               1);

      decode(riceEncodedVec.data(),
             (int)riceEncodedVec.size(),
             outBuffer,
             width*height,
             blockDim,
             blockOptimalKTable,
             blockOptimalKTableLen,
             blockN,
             bitOffsetsEveryVal.data());
      
      int cmp = memcmp(blockSymbols, outBuffer, width*height);
      assert(cmp == 0);
      
      // Decode with non-stream rice method and validate against known good decoded values stream
      
      decodeParallelCheck(riceEncodedVec.data(),
                          (int)riceEncodedVec.size(),
                          outBuffer,
                          width*height,
                          blockDim,
                          blockOptimalKTable,
                          blockOptimalKTableLen,
                          blockN,
                          bitOffsetsEveryVal.data());
    }
#endif // DEBUG
    
    uint32_t *prefixBitsWordPtr = (uint32_t *) riceEncodedVec.data();
    
    // Fill in inoutBlockBitOffsetTable with bit offsets every 16 values (1/2 block)
    
    vector<uint32_t> bitOffsetsEvery16 = generateBitOffsets(blockSymbols,
                                                            numBlockSymbols,
                                                            blockDim,
                                                            blockOptimalKTable,
                                                            blockOptimalKTableLen,
                                                            blockN,
                                                            (blockDim * blockDim)/2);

    assert(bitOffsetsEvery16.size() == numBitOffsetsThisTest);
    
    vector<uint32_t> inoutBlockBitOffsetTableVec(numBitOffsetsThisTest);
    uint32_t *inoutBlockBitOffsetTable = inoutBlockBitOffsetTableVec.data();
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEvery16.size(); i++) {
      inoutBlockBitOffsetTable[i] = bitOffsetsEvery16[i];
    }
    
    // Render for each big block
    
    for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
      if ((1)) {
        printf("render bigBlocki %d\n", bigBlocki);
      }
      
      for (int tid = 0; tid < 32; tid++) {
        kernel_render_rice_typed<blockDim>(decodedPixels32,
                                           riceRenderUniform,
                                           inoutBlockBitOffsetTable,
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    uint8_t *decodedBytes = decodedBytesVec.data();
    memcpy(decodedBytes, decodedPixels32, width*height);
    uint8_t *pixels8 = (uint8_t *) decodedBytes;
    
    if ((1)) {
      printf("decoded image order:\n");
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int bVal = pixels8[offset];
          printf("%3d, ", bVal);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = pixels8[i];
      uint8_t expected = inputImageOrderPixels[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (bval != expected) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
        }
      }
    }
  }
  
  // FIXME: validate that output block bit offsets were updated
  
  return;
}

// 1x1 in terms of big blocks and k = 0

- (void)testGenerateImageOrder8x8And1x1Ex2 {
  const int blockDim = 8;
  const int blockiDim = 4;
  
  int constK = 0;
  
  // 8x8 blocks at 1x1 big blocks, aka 32x32
  const int width = 4 * blockDim;
  const int height = 4 * blockDim;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / (blockDim * blockiDim);
  const int numBigBlocksInHeight = height / (blockDim * blockiDim);
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  const int numBitOffsetsThisTest = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  memset(blockOptimalKTableVec.data(), constK, (int)blockOptimalKTableVec.size());
  
  int over = 1;
  
  for (int row = 0; row < height; row++) {
    for (int col = 0; col < width; col++) {
      int offset = (row * width) + col;
      int bVal = offset & 63;
      inputPixels[offset] = bVal;
      
      if ((offset != 0) && (bVal == 0)) {
        inputPixels[offset] += over;
        over += 1;
      }
    }
  }
  
  // Image is generated in block order so that the ascending
  // values are stored 1 block at a time.
  
  if ((1)) {
    printf("8x8 block order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Reorder into image order and print
  
  {
    // Reorder bytes from block order to image order via flatten
    
    BlockDecoder<uint8_t, blockDim> db;
    
    uint8_t *inPrefixBytesPtr = inputPixels;
    
    db.blockVectors.resize(numBlocksInWidth * numBlocksInHeight);
    
    for (int blocki = 0; blocki < (numBlocksInWidth * numBlocksInHeight); blocki++) {
      vector<uint8_t> & blockVec = db.blockVectors[blocki];
      // Append pixels from block by block data
      
      const int numBytes = blockDim * blockDim;
      blockVec.resize(numBytes);
      memcpy(blockVec.data(), inPrefixBytesPtr, numBytes);
      inPrefixBytesPtr += numBytes;
    }
    
    db.flattenAndCrop(inputImageOrderPixels,
                      width*height,
                      numBlocksInWidth,
                      numBlocksInHeight,
                      width,
                      height);
  }
  
  
  if ((1)) {
    printf("original image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputImageOrderPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Generate blocki ordering
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixels;
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  vector<uint8_t> halfBlockOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                outputPixels,
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec,
                                &halfBlockOptimalKTableVec);
  
  XCTAssert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size(), @"same size");
  XCTAssert(blockiOptimalKTableVec == blockOptimalKTableVec, @"same k values");
  
  if ((1)) {
    printf("big block s32 image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = outputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Print blocki values in block order
  
  if ((1)) {
    printf("block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = outputPixels[offset++];
        printf("%3d ", bVal);
      }
      printf("\n");
    }
  }
  
  // Read 16 small blocks at a time from 32 streams
  // so that a big block of 32x32 is read in with
  // 8 reads per small block.
  
  vector<uint8_t> decodedS32PixelsVec(width*height);
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32PixelsVec.data(),
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((1)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32PixelsVec[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32PixelsVec[i];
      uint8_t expected = blockiReorderedVec[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (numFails < 10) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
          numFails += 1;
        }
      }
    }
  }
  
  // Note that blockOptimalKTableVec is replaced with blockiOptimalKTableVec
  // values here since the reordered table of K value is in big block iteration order.
  
  blockOptimalKTableVec = halfBlockOptimalKTableVec;
  
  // Encode as rice bits and then decode with stream based decode for sanity check
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    memset(decodedPixels32, 0xFF, width*height);
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    const uint8_t *blockOptimalKTable = blockOptimalKTableVec.data();
    const int blockOptimalKTableLen = (int) blockOptimalKTableVec.size();
    
    vector<uint8_t> riceEncodedVec = encode(blockSymbols,
                                            numBlockSymbols,
                                            blockDim,
                                            blockOptimalKTable,
                                            blockOptimalKTableLen,
                                            blockN);
    
#if defined(DEBUG)
    {
      vector<uint8_t> outBufferVec(width*height);
      uint8_t *outBuffer = outBufferVec.data();
      
      vector<uint32_t> bitOffsetsEveryVal = generateBitOffsets(blockSymbols,
                                                               numBlockSymbols,
                                                               blockDim,
                                                               blockOptimalKTable,
                                                               blockOptimalKTableLen,
                                                               blockN,
                                                               1);

      decode(riceEncodedVec.data(),
             (int)riceEncodedVec.size(),
             outBuffer,
             width*height,
             blockDim,
             blockOptimalKTable,
             blockOptimalKTableLen,
             blockN,
             bitOffsetsEveryVal.data());
      
      int cmp = memcmp(blockSymbols, outBuffer, width*height);
      assert(cmp == 0);
      
      // Decode with non-stream rice method and validate against known good decoded values stream
      
      decodeParallelCheck(riceEncodedVec.data(),
                          (int)riceEncodedVec.size(),
                          outBuffer,
                          width*height,
                          blockDim,
                          blockOptimalKTable,
                          blockOptimalKTableLen,
                          blockN,
                          bitOffsetsEveryVal.data());
    }
#endif // DEBUG
    
    uint32_t *prefixBitsWordPtr = (uint32_t *) riceEncodedVec.data();
    
    // Fill in inoutBlockBitOffsetTable with bit offsets every 16 values (1/2 block)
    
    vector<uint32_t> bitOffsetsEvery16 = generateBitOffsets(blockSymbols,
                                                            numBlockSymbols,
                                                            blockDim,
                                                            blockOptimalKTable,
                                                            blockOptimalKTableLen,
                                                            blockN,
                                                            (blockDim * blockDim)/2);
    
    assert(bitOffsetsEvery16.size() == numBitOffsetsThisTest);
    
    vector<uint32_t> inoutBlockBitOffsetTableVec(numBitOffsetsThisTest);
    uint32_t *inoutBlockBitOffsetTable = inoutBlockBitOffsetTableVec.data();
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEvery16.size(); i++) {
      inoutBlockBitOffsetTable[i] = bitOffsetsEvery16[i];
    }
    
    // Render for each big block
    
    for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
      if ((1)) {
        printf("render bigBlocki %d\n", bigBlocki);
      }
      
      for (int tid = 0; tid < 32; tid++) {
        kernel_render_rice_typed<blockDim>(decodedPixels32,
                                           riceRenderUniform,
                                           inoutBlockBitOffsetTable,
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    uint8_t *decodedBytes = decodedBytesVec.data();
    memcpy(decodedBytes, decodedPixels32, width*height);
    uint8_t *pixels8 = (uint8_t *) decodedBytes;
    
    if ((1)) {
      printf("decoded image order:\n");
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int bVal = pixels8[offset];
          printf("%3d, ", bVal);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = pixels8[i];
      uint8_t expected = inputImageOrderPixels[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (bval != expected) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
        }
      }
    }
  }
  
  // FIXME: validate that output block bit offsets were updated
  
  return;
}

// 2x1 in terms of big blocks and k = 0

- (void)testGenerateImageOrder8x8And2x1Ex1 {
  const int blockDim = 8;
  const int blockiDim = 4;
  
  int constK = 0;
  
  const int width = 8 * blockDim;
  const int height = 4 * blockDim;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / (blockDim * blockiDim);
  const int numBigBlocksInHeight = height / (blockDim * blockiDim);
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  const int numBitOffsetsThisTest = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  memset(blockOptimalKTableVec.data(), constK, (int)blockOptimalKTableVec.size());
  
  int over = 1;
  
  for (int row = 0; row < height; row++) {
    for (int col = 0; col < width; col++) {
      int offset = (row * width) + col;
      int bVal = offset & 63;
      inputPixels[offset] = bVal;
      
      if ((offset != 0) && (bVal == 0)) {
        inputPixels[offset] += over;
        over += 1;
      }
    }
  }
  
  // Image is generated in block order so that the ascending
  // values are stored 1 block at a time.
  
  if ((1)) {
    printf("8x8 block order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Reorder into image order and print
  
  {
    // Reorder bytes from block order to image order via flatten
    
    BlockDecoder<uint8_t, blockDim> db;
    
    uint8_t *inPrefixBytesPtr = inputPixels;
    
    db.blockVectors.resize(numBlocksInWidth * numBlocksInHeight);
    
    for (int blocki = 0; blocki < (numBlocksInWidth * numBlocksInHeight); blocki++) {
      vector<uint8_t> & blockVec = db.blockVectors[blocki];
      // Append pixels from block by block data
      
      const int numBytes = blockDim * blockDim;
      blockVec.resize(numBytes);
      memcpy(blockVec.data(), inPrefixBytesPtr, numBytes);
      inPrefixBytesPtr += numBytes;
    }
    
    db.flattenAndCrop(inputImageOrderPixels,
                      width*height,
                      numBlocksInWidth,
                      numBlocksInHeight,
                      width,
                      height);
  }
  
  
  if ((1)) {
    printf("original image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputImageOrderPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Generate blocki ordering
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixels;
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  vector<uint8_t> halfBlockOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                outputPixels,
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec,
                                &halfBlockOptimalKTableVec);
  
  XCTAssert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size(), @"same size");
  XCTAssert(blockiOptimalKTableVec == blockOptimalKTableVec, @"same k values");
  
  if ((1)) {
    printf("big block s32 image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = outputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Print blocki values in block order
  
  if ((1)) {
    printf("block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = outputPixels[offset++];
        printf("%3d ", bVal);
      }
      printf("\n");
    }
  }
  
  // Read 16 small blocks at a time from 32 streams
  // so that a big block of 32x32 is read in with
  // 8 reads per small block.
  
  vector<uint8_t> decodedS32PixelsVec(width*height);
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32PixelsVec.data(),
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((1)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32PixelsVec[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32PixelsVec[i];
      uint8_t expected = blockiReorderedVec[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (numFails < 10) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
          numFails += 1;
        }
      }
    }
  }
  
  // Note that blockOptimalKTableVec is replaced with blockiOptimalKTableVec
  // values here since the reordered table of K value is in big block iteration order.
  
  blockOptimalKTableVec = halfBlockOptimalKTableVec;
  
  // Encode as rice bits and then decode with stream based decode for sanity check
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    memset(decodedPixels32, 0xFF, width*height);
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    const uint8_t *blockOptimalKTable = blockOptimalKTableVec.data();
    const int blockOptimalKTableLen = (int) blockOptimalKTableVec.size();
    
    vector<uint8_t> riceEncodedVec = encode(blockSymbols,
                                            numBlockSymbols,
                                            blockDim,
                                            blockOptimalKTable,
                                            blockOptimalKTableLen,
                                            blockN);
    
#if defined(DEBUG)
    {
      vector<uint8_t> outBufferVec(width*height);
      uint8_t *outBuffer = outBufferVec.data();
      
      vector<uint32_t> bitOffsetsEveryVal = generateBitOffsets(blockSymbols,
                                                               numBlockSymbols,
                                                               blockDim,
                                                               blockOptimalKTable,
                                                               blockOptimalKTableLen,
                                                               blockN,
                                                               1);
      
      decode(riceEncodedVec.data(),
             (int)riceEncodedVec.size(),
             outBuffer,
             width*height,
             blockDim,
             blockOptimalKTable,
             blockOptimalKTableLen,
             blockN,
             bitOffsetsEveryVal.data());
      
      int cmp = memcmp(blockSymbols, outBuffer, width*height);
      assert(cmp == 0);
      
      // Decode with non-stream rice method and validate against known good decoded values stream
      
      decodeParallelCheck(riceEncodedVec.data(),
                          (int)riceEncodedVec.size(),
                          outBuffer,
                          width*height,
                          blockDim,
                          blockOptimalKTable,
                          blockOptimalKTableLen,
                          blockN,
                          bitOffsetsEveryVal.data());
    }
#endif // DEBUG
    
    uint32_t *prefixBitsWordPtr = (uint32_t *) riceEncodedVec.data();
    
    // Fill in inoutBlockBitOffsetTable with bit offsets every 16 values (1/2 block)
    
    vector<uint32_t> bitOffsetsEvery16 = generateBitOffsets(blockSymbols,
                                                            numBlockSymbols,
                                                            blockDim,
                                                            blockOptimalKTable,
                                                            blockOptimalKTableLen,
                                                            blockN,
                                                            (blockDim * blockDim)/2);
    
    assert(bitOffsetsEvery16.size() == numBitOffsetsThisTest);
    
    vector<uint32_t> inoutBlockBitOffsetTableVec(numBitOffsetsThisTest);
    uint32_t *inoutBlockBitOffsetTable = inoutBlockBitOffsetTableVec.data();
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEvery16.size(); i++) {
      inoutBlockBitOffsetTable[i] = bitOffsetsEvery16[i];
    }
    
    // Render for each big block
    
    for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
      if ((1)) {
        printf("render bigBlocki %d\n", bigBlocki);
      }
      
      for (int tid = 0; tid < 32; tid++) {
        kernel_render_rice_typed<blockDim>(decodedPixels32,
                                           riceRenderUniform,
                                           inoutBlockBitOffsetTable,
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    uint8_t *decodedBytes = decodedBytesVec.data();
    memcpy(decodedBytes, decodedPixels32, width*height);
    uint8_t *pixels8 = (uint8_t *) decodedBytes;
    
    if ((1)) {
      printf("decoded image order:\n");
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int bVal = pixels8[offset];
          printf("%3d, ", bVal);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = pixels8[i];
      uint8_t expected = inputImageOrderPixels[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (bval != expected) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
        }
      }
    }
  }
  
  // FIXME: validate that output block bit offsets were updated
  
  return;
}

// original size 2048x2048

- (void)testGenerateImageOrder2048x2048 {
  const int blockDim = 8;
  const int blockiDim = 4;
  
  int constK = 0;
  
  // 8x8 blocks at 1x1 big blocks, aka 2048x2048
  const int width = 64 * 32;
  const int height = 64 * 32;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / (blockDim * blockiDim);
  const int numBigBlocksInHeight = height / (blockDim * blockiDim);
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  const int numBitOffsetsThisTest = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  memset(blockOptimalKTableVec.data(), constK, (int)blockOptimalKTableVec.size());
  
  int over = 1;
  
  for (int row = 0; row < height; row++) {
    for (int col = 0; col < width; col++) {
      int offset = (row * width) + col;
      int bVal = offset & 63;
      inputPixels[offset] = bVal;
      
      if ((offset != 0) && (bVal == 0)) {
        inputPixels[offset] += over;
        over += 1;
      }
    }
  }
  
  // Image is generated in block order so that the ascending
  // values are stored 1 block at a time.
  
  if ((0)) {
    printf("8x8 block order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Reorder into image order and print
  
  {
    // Reorder bytes from block order to image order via flatten
    
    BlockDecoder<uint8_t, blockDim> db;
    
    uint8_t *inPrefixBytesPtr = inputPixels;
    
    db.blockVectors.resize(numBlocksInWidth * numBlocksInHeight);
    
    for (int blocki = 0; blocki < (numBlocksInWidth * numBlocksInHeight); blocki++) {
      vector<uint8_t> & blockVec = db.blockVectors[blocki];
      // Append pixels from block by block data
      
      const int numBytes = blockDim * blockDim;
      blockVec.resize(numBytes);
      memcpy(blockVec.data(), inPrefixBytesPtr, numBytes);
      inPrefixBytesPtr += numBytes;
    }
    
    db.flattenAndCrop(inputImageOrderPixels,
                      width*height,
                      numBlocksInWidth,
                      numBlocksInHeight,
                      width,
                      height);
  }
  
  
  if ((0)) {
    printf("original image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputImageOrderPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Generate blocki ordering
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixels;
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  vector<uint8_t> halfBlockOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                outputPixels,
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec,
                                &halfBlockOptimalKTableVec);
  
  XCTAssert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size(), @"same size");
  XCTAssert(blockiOptimalKTableVec == blockOptimalKTableVec, @"same k values");
  
  if ((0)) {
    printf("big block s32 image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = outputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Print blocki values in block order
  
  if ((0)) {
    printf("block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = outputPixels[offset++];
        printf("%3d ", bVal);
      }
      printf("\n");
    }
  }
  
  // Read 16 small blocks at a time from 32 streams
  // so that a big block of 32x32 is read in with
  // 8 reads per small block.
  
  vector<uint8_t> decodedS32PixelsVec(width*height);
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32PixelsVec.data(),
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((0)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32PixelsVec[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32PixelsVec[i];
      uint8_t expected = blockiReorderedVec[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (numFails < 10) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
          numFails += 1;
        }
      }
    }
  }
  
  // Note that blockOptimalKTableVec is replaced with blockiOptimalKTableVec
  // values here since the reordered table of K value is in big block iteration order.
  
  //blockOptimalKTableVec = blockiOptimalKTableVec;
  blockOptimalKTableVec = halfBlockOptimalKTableVec;
  
  // Encode as rice bits and then decode with stream based decode for sanity check
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    memset(decodedPixels32, 0xFF, width*height);
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    const uint8_t *blockOptimalKTable = blockOptimalKTableVec.data();
    const int blockOptimalKTableLen = (int) blockOptimalKTableVec.size();
    
    vector<uint8_t> riceEncodedVec = encode(blockSymbols,
                                            numBlockSymbols,
                                            blockDim,
                                            blockOptimalKTable,
                                            blockOptimalKTableLen,
                                            blockN);
    
#if defined(DEBUG)
    {
      vector<uint8_t> outBufferVec(width*height);
      uint8_t *outBuffer = outBufferVec.data();
      
      vector<uint32_t> bitOffsetsEveryVal = generateBitOffsets(blockSymbols,
                                                               numBlockSymbols,
                                                               blockDim,
                                                               blockOptimalKTable,
                                                               blockOptimalKTableLen,
                                                               blockN,
                                                               1);
      
      decode(riceEncodedVec.data(),
             (int)riceEncodedVec.size(),
             outBuffer,
             width*height,
             blockDim,
             blockOptimalKTable,
             blockOptimalKTableLen,
             blockN,
             bitOffsetsEveryVal.data());
      
      int cmp = memcmp(blockSymbols, outBuffer, width*height);
      assert(cmp == 0);
      
      // Decode with non-stream rice method and validate against known good decoded values stream
      
      decodeParallelCheck(riceEncodedVec.data(),
                          (int)riceEncodedVec.size(),
                          outBuffer,
                          width*height,
                          blockDim,
                          blockOptimalKTable,
                          blockOptimalKTableLen,
                          blockN,
                          bitOffsetsEveryVal.data());
    }
#endif // DEBUG
    
    uint32_t *prefixBitsWordPtr = (uint32_t *) riceEncodedVec.data();
    
    // Fill in inoutBlockBitOffsetTable with bit offsets every 16 values (1/2 block)
    
    vector<uint32_t> bitOffsetsEvery16 = generateBitOffsets(blockSymbols,
                                                            numBlockSymbols,
                                                            blockDim,
                                                            blockOptimalKTable,
                                                            blockOptimalKTableLen,
                                                            blockN,
                                                            (blockDim * blockDim)/2);
    
    assert(bitOffsetsEvery16.size() == numBitOffsetsThisTest);
    
    vector<uint32_t> inoutBlockBitOffsetTableVec(numBitOffsetsThisTest);
    uint32_t *inoutBlockBitOffsetTable = inoutBlockBitOffsetTableVec.data();
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEvery16.size(); i++) {
      inoutBlockBitOffsetTable[i] = bitOffsetsEvery16[i];
    }
    
    // Render for each big block
    
    for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
      if ((0)) {
        printf("render bigBlocki %d\n", bigBlocki);
      }
      
      for (int tid = 0; tid < 32; tid++) {
        kernel_render_rice_typed<blockDim>(decodedPixels32,
                                           riceRenderUniform,
                                           inoutBlockBitOffsetTable,
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    uint8_t *decodedBytes = decodedBytesVec.data();
    memcpy(decodedBytes, decodedPixels32, width*height);
    uint8_t *pixels8 = (uint8_t *) decodedBytes;
    
    if ((0)) {
      printf("decoded image order:\n");
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int bVal = pixels8[offset];
          printf("%3d, ", bVal);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = pixels8[i];
      uint8_t expected = inputImageOrderPixels[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (bval != expected) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
        }
      }
    }
  }
  
  // FIXME: validate that output block bit offsets were updated
  
  return;
}

// 1x1 in terms of big blocks and differing k

- (void)testGenerateImageOrder8x8And1x1Diffk02 {
  const int blockDim = 8;
  const int blockiDim = 4;
  
  // 8x8 blocks at 1x1 big blocks, aka 32x32
  const int width = 4 * blockDim;
  const int height = 4 * blockDim;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / (blockDim * blockiDim);
  const int numBigBlocksInHeight = height / (blockDim * blockiDim);
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  const int numBitOffsetsThisTest = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  
  // Increasing K values, 0 .. 2 for a total of 16 blocks
  
  {
    int currentK = 0;
    
    for (int i = 0; i < blockN; i++) {
      blockOptimalKTableVec[i] = currentK;
      currentK += 1;
      if (currentK > 2) {
        currentK= 0;
      }
    }
  }
  
  int over = 1;
  
  for (int row = 0; row < height; row++) {
    for (int col = 0; col < width; col++) {
      int offset = (row * width) + col;
      int bVal = offset & 63;
      inputPixels[offset] = bVal;
      
      if ((offset != 0) && (bVal == 0)) {
        inputPixels[offset] += over;
        over += 1;
      }
    }
  }
  
  // Image is generated in block order so that the ascending
  // values are stored 1 block at a time.
  
  if ((1)) {
    printf("8x8 block order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Reorder into image order and print
  
  {
    // Reorder bytes from block order to image order via flatten
    
    BlockDecoder<uint8_t, blockDim> db;
    
    uint8_t *inPrefixBytesPtr = inputPixels;
    
    db.blockVectors.resize(numBlocksInWidth * numBlocksInHeight);
    
    for (int blocki = 0; blocki < (numBlocksInWidth * numBlocksInHeight); blocki++) {
      vector<uint8_t> & blockVec = db.blockVectors[blocki];
      // Append pixels from block by block data
      
      const int numBytes = blockDim * blockDim;
      blockVec.resize(numBytes);
      memcpy(blockVec.data(), inPrefixBytesPtr, numBytes);
      inPrefixBytesPtr += numBytes;
    }
    
    db.flattenAndCrop(inputImageOrderPixels,
                      width*height,
                      numBlocksInWidth,
                      numBlocksInHeight,
                      width,
                      height);
  }
  
  
  if ((1)) {
    printf("original image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputImageOrderPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Generate blocki ordering
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixels;
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  vector<uint8_t> halfBlockOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                outputPixels,
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec,
                                &halfBlockOptimalKTableVec);
  
  XCTAssert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size(), @"same size");
  XCTAssert(blockiOptimalKTableVec == blockOptimalKTableVec, @"same k values");
  
  if ((1)) {
    printf("big block s32 image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = outputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Print blocki values in block order
  
  if ((1)) {
    printf("block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = outputPixels[offset++];
        printf("%3d ", bVal);
      }
      printf("\n");
    }
  }
  
  // Read 16 small blocks at a time from 32 streams
  // so that a big block of 32x32 is read in with
  // 8 reads per small block.
  
  vector<uint8_t> decodedS32PixelsVec(width*height);
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32PixelsVec.data(),
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((1)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32PixelsVec[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32PixelsVec[i];
      uint8_t expected = blockiReorderedVec[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (numFails < 10) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
          numFails += 1;
        }
      }
    }
  }
  
  // Note that blockOptimalKTableVec is replaced with blockiOptimalKTableVec
  // values here since the reordered table of K value is in big block iteration order.
  
  //blockOptimalKTableVec = blockiOptimalKTableVec;
  blockOptimalKTableVec = halfBlockOptimalKTableVec;
  
  // Encode as rice bits and then decode with stream based decode for sanity check
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    memset(decodedPixels32, 0xFF, width*height);
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    uint8_t *blockOptimalKTable = blockOptimalKTableVec.data();
    int blockOptimalKTableLen = (int) blockOptimalKTableVec.size();
    
    vector<uint8_t> riceEncodedVec = encode(blockSymbols,
                                            numBlockSymbols,
                                            blockDim,
                                            blockOptimalKTable,
                                            blockOptimalKTableLen,
                                            blockN);
    
#if defined(DEBUG)
    {
      vector<uint8_t> outBufferVec(width*height);
      uint8_t *outBuffer = outBufferVec.data();
      
      vector<uint32_t> bitOffsetsEveryVal = generateBitOffsets(blockSymbols,
                                                               numBlockSymbols,
                                                               blockDim,
                                                               blockOptimalKTable,
                                                               blockOptimalKTableLen,
                                                               blockN,
                                                               1);
      
      decode(riceEncodedVec.data(),
             (int)riceEncodedVec.size(),
             outBuffer,
             width*height,
             blockDim,
             blockOptimalKTable,
             blockOptimalKTableLen,
             blockN,
             bitOffsetsEveryVal.data());
      
      int cmp = memcmp(blockSymbols, outBuffer, width*height);
      assert(cmp == 0);
      
      // Decode with non-stream rice method and validate against known good decoded values stream
      
      decodeParallelCheck(riceEncodedVec.data(),
                          (int)riceEncodedVec.size(),
                          outBuffer,
                          width*height,
                          blockDim,
                          blockOptimalKTable,
                          blockOptimalKTableLen,
                          blockN,
                          bitOffsetsEveryVal.data());
    }
#endif // DEBUG
    
    uint32_t *prefixBitsWordPtr = (uint32_t *) riceEncodedVec.data();
    
    // Fill in inoutBlockBitOffsetTable with bit offsets every 16 values (1/2 block)
    
    vector<uint32_t> bitOffsetsEvery16 = generateBitOffsets(blockSymbols,
                                                            numBlockSymbols,
                                                            blockDim,
                                                            blockOptimalKTable,
                                                            blockOptimalKTableLen,
                                                            blockN,
                                                            (blockDim * blockDim)/2);
    
    assert(bitOffsetsEvery16.size() == numBitOffsetsThisTest);
    
    vector<uint32_t> inoutBlockBitOffsetTableVec(numBitOffsetsThisTest);
    uint32_t *inoutBlockBitOffsetTable = inoutBlockBitOffsetTableVec.data();
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEvery16.size(); i++) {
      inoutBlockBitOffsetTable[i] = bitOffsetsEvery16[i];
    }
    
    // Pass blockiOptimalKTableVec into shader logic, it already deals
    // with calculating blocki and k in terms of big block ordering
    
    blockOptimalKTable = blockiOptimalKTableVec.data();
    blockOptimalKTableLen = (int) blockiOptimalKTableVec.size();
    
    // Render for each big block
    
    for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
      if ((1)) {
        printf("render bigBlocki %d\n", bigBlocki);
      }
      
      for (int tid = 0; tid < 32; tid++) {
        kernel_render_rice_typed<blockDim>(decodedPixels32,
                                           riceRenderUniform,
                                           inoutBlockBitOffsetTable,
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    uint8_t *decodedBytes = decodedBytesVec.data();
    memcpy(decodedBytes, decodedPixels32, width*height);
    uint8_t *pixels8 = (uint8_t *) decodedBytes;
    
    if ((1)) {
      printf("decoded image order:\n");
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int bVal = pixels8[offset];
          printf("%3d, ", bVal);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = pixels8[i];
      uint8_t expected = inputImageOrderPixels[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (bval != expected) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
        }
      }
    }
  }
  
  // FIXME: validate that output block bit offsets were updated
  
  return;
}

// 1x1 in terms of big blocks and differing k

- (void)testGenerateImageOrder8x8And2x1Diffk02 {
  const int blockDim = 8;
  const int blockiDim = 4;
  
  // 8x8 blocks at 1x1 big blocks, aka 32x32
  const int width = 8 * blockDim;
  const int height = 4 * blockDim;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / (blockDim * blockiDim);
  const int numBigBlocksInHeight = height / (blockDim * blockiDim);
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  const int numBitOffsetsThisTest = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  
  // Increasing K values, 0 .. 2 for a total of 16 blocks
  
  {
    int currentK = 0;
    
    for (int i = 0; i < blockN; i++) {
      blockOptimalKTableVec[i] = currentK;
      currentK += 1;
      if (currentK > 2) {
        currentK= 0;
      }
    }
  }
  
  int over = 1;
  
  for (int row = 0; row < height; row++) {
    for (int col = 0; col < width; col++) {
      int offset = (row * width) + col;
      int bVal = offset & 63;
      inputPixels[offset] = bVal;
      
      if ((offset != 0) && (bVal == 0)) {
        inputPixels[offset] += over;
        over += 1;
      }
    }
  }
  
  // Image is generated in block order so that the ascending
  // values are stored 1 block at a time.
  
  if ((1)) {
    printf("8x8 block order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Reorder into image order and print
  
  {
    // Reorder bytes from block order to image order via flatten
    
    BlockDecoder<uint8_t, blockDim> db;
    
    uint8_t *inPrefixBytesPtr = inputPixels;
    
    db.blockVectors.resize(numBlocksInWidth * numBlocksInHeight);
    
    for (int blocki = 0; blocki < (numBlocksInWidth * numBlocksInHeight); blocki++) {
      vector<uint8_t> & blockVec = db.blockVectors[blocki];
      // Append pixels from block by block data
      
      const int numBytes = blockDim * blockDim;
      blockVec.resize(numBytes);
      memcpy(blockVec.data(), inPrefixBytesPtr, numBytes);
      inPrefixBytesPtr += numBytes;
    }
    
    db.flattenAndCrop(inputImageOrderPixels,
                      width*height,
                      numBlocksInWidth,
                      numBlocksInHeight,
                      width,
                      height);
  }
  
  
  if ((1)) {
    printf("original image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputImageOrderPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Generate blocki ordering
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixels;
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  vector<uint8_t> halfBlockOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                outputPixels,
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec,
                                &halfBlockOptimalKTableVec);
  
  XCTAssert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size(), @"same size");
  XCTAssert(blockiOptimalKTableVec != blockOptimalKTableVec, @"same k values");
  
  if ((1)) {
    printf("big block s32 image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = outputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Print blocki values in block order
  
  if ((1)) {
    printf("block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = outputPixels[offset++];
        printf("%3d ", bVal);
      }
      printf("\n");
    }
  }

  if ((1)) {
    printf("k input order (len %d):\n", (int)blockOptimalKTableVec.size());
    
    for (int i = 0; i < blockOptimalKTableVec.size(); i++) {
      int kVal = blockOptimalKTableVec[i];
      printf("blockOptimalKTableVec[%5d] = %1d\n", i, kVal);
    }
    
    printf("\n");
  }
  
  if ((1)) {
    printf("k output order (len %d):\n", (int)blockiOptimalKTableVec.size());
    
    for (int i = 0; i < blockiOptimalKTableVec.size(); i++) {
      int kVal = blockiOptimalKTableVec[i];
      printf("blockiOptimalKTableVec[%5d] = %1d\n", i, kVal);
    }
    
    printf("\n");
  }
  
  if ((1)) {
    printf("k half block output order (len %d):\n", (int)halfBlockOptimalKTableVec.size());
    
    for (int i = 0; i < halfBlockOptimalKTableVec.size(); i++) {
      int kVal = halfBlockOptimalKTableVec[i];
      printf("halfBlockOptimalKTableVec[%5d] = %1d\n", i, kVal);
    }
    
    printf("\n");
  }
  
  // Since each block maps to a single k, it should now be possible
  // to generate a check
  
  // Read 16 small blocks at a time from 32 streams
  // so that a big block of 32x32 is read in with
  // 8 reads per small block.
  
  vector<uint8_t> decodedS32PixelsVec(width*height);
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32PixelsVec.data(),
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((1)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32PixelsVec[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32PixelsVec[i];
      uint8_t expected = blockiReorderedVec[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (numFails < 10) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
          numFails += 1;
        }
      }
    }
  }
  
  // Note that blockOptimalKTableVec is replaced with blockiOptimalKTableVec
  // values here since the reordered table of K value is in big block iteration order.
  
  //blockOptimalKTableVec = blockiOptimalKTableVec;
  //blockOptimalKTableVec = halfBlockOptimalKTableVec;
  
  // Encode as rice bits and then decode with stream based decode for sanity check
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    memset(decodedPixels32, 0xFF, width*height);
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    uint8_t *blockOptimalKTable = halfBlockOptimalKTableVec.data();
    int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
    
    vector<uint8_t> riceEncodedVec = encode(blockSymbols,
                                            numBlockSymbols,
                                            blockDim,
                                            blockOptimalKTable,
                                            blockOptimalKTableLen,
                                            blockN);
    
#if defined(DEBUG)
    {
      vector<uint8_t> outBufferVec(width*height);
      uint8_t *outBuffer = outBufferVec.data();
      
      vector<uint32_t> bitOffsetsEveryVal = generateBitOffsets(blockSymbols,
                                                               numBlockSymbols,
                                                               blockDim,
                                                               blockOptimalKTable,
                                                               blockOptimalKTableLen,
                                                               blockN,
                                                               1);
      
      decode(riceEncodedVec.data(),
             (int)riceEncodedVec.size(),
             outBuffer,
             width*height,
             blockDim,
             blockOptimalKTable,
             blockOptimalKTableLen,
             blockN,
             bitOffsetsEveryVal.data());
      
      int cmp = memcmp(blockSymbols, outBuffer, width*height);
      assert(cmp == 0);
      
      // Decode with non-stream rice method and validate against known good decoded values stream
      
      decodeParallelCheck(riceEncodedVec.data(),
                          (int)riceEncodedVec.size(),
                          outBuffer,
                          width*height,
                          blockDim,
                          blockOptimalKTable,
                          blockOptimalKTableLen,
                          blockN,
                          bitOffsetsEveryVal.data());
    }
#endif // DEBUG
    
    uint32_t *prefixBitsWordPtr = (uint32_t *) riceEncodedVec.data();
    
    // Fill in inoutBlockBitOffsetTable with bit offsets every 16 values (1/2 block)
    
    vector<uint32_t> bitOffsetsEvery32 = generateBitOffsets(blockSymbols,
                                                            numBlockSymbols,
                                                            blockDim,
                                                            blockOptimalKTable,
                                                            blockOptimalKTableLen,
                                                            blockN,
                                                            (blockDim * blockDim)/2);
    
    assert(bitOffsetsEvery32.size() == numBitOffsetsThisTest);
    
    vector<uint32_t> inoutBlockBitOffsetTableVec(numBitOffsetsThisTest);
    uint32_t *inoutBlockBitOffsetTable = inoutBlockBitOffsetTableVec.data();
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEvery32.size(); i++) {
      inoutBlockBitOffsetTable[i] = bitOffsetsEvery32[i];
    }
    
    // Pass blockiOptimalKTableVec into shader logic, it already deals
    // with calculating blocki and k in terms of big block ordering
    
    blockOptimalKTable = blockiOptimalKTableVec.data();
    blockOptimalKTableLen = (int) blockiOptimalKTableVec.size();
    
    // Render for each big block
    
    for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
      if ((0)) {
        printf("render bigBlocki %d\n", bigBlocki);
      }
      
      for (int tid = 0; tid < 32; tid++) {
        kernel_render_rice_typed<blockDim>(decodedPixels32,
                                           riceRenderUniform,
                                           inoutBlockBitOffsetTable,
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    uint8_t *decodedBytes = decodedBytesVec.data();
    memcpy(decodedBytes, decodedPixels32, width*height);
    uint8_t *pixels8 = (uint8_t *) decodedBytes;
    
    if ((1)) {
      printf("decoded image order:\n");
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int bVal = pixels8[offset];
          printf("%3d, ", bVal);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    {
      int numMismatches = 0;
      
      for (int i = 0; i < (width*height); i++) {
        uint8_t bval = pixels8[i];
        uint8_t expected = inputImageOrderPixels[i];
        if (bval != expected) {
          int x = i % width;
          int y = i / width;
          if (numMismatches < 10) {
            XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
            numMismatches += 1;
          }
        }
      }
    }
    
  }
  
  // FIXME: validate that output block bit offsets were updated
  
  return;
}

// original size 2048x1536

- (void)testGenerateImageOrder2048x1536DiffK02 {
  const int blockDim = 8;
  const int blockiDim = 4;
  
  const int width = 64 * 32;
  const int height = 48 * 32;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / (blockDim * blockiDim);
  const int numBigBlocksInHeight = height / (blockDim * blockiDim);
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  const int numBitOffsetsThisTest = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  blockOptimalKTableVec[blockN-1] = 0;
  
  // Increasing K values, 0 .. 2 for a total of 16 blocks
  
  {
    int currentK = 0;
    
    for (int i = 0; i < blockN; i++) {
      blockOptimalKTableVec[i] = currentK;
      currentK += 1;
      if (currentK > 2) {
        currentK= 0;
      }
    }
  }
  
  int over = 1;
  
  for (int row = 0; row < height; row++) {
    for (int col = 0; col < width; col++) {
      int offset = (row * width) + col;
      int bVal = offset & 63;
      inputPixels[offset] = bVal;
      
      if ((offset != 0) && (bVal == 0)) {
        inputPixels[offset] += over;
        over += 1;
      }
    }
  }
  
  // Image is generated in block order so that the ascending
  // values are stored 1 block at a time.
  
  if ((0)) {
    printf("8x8 block order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Reorder into image order and print
  
  {
    // Reorder bytes from block order to image order via flatten
    
    BlockDecoder<uint8_t, blockDim> db;
    
    uint8_t *inPrefixBytesPtr = inputPixels;
    
    db.blockVectors.resize(numBlocksInWidth * numBlocksInHeight);
    
    for (int blocki = 0; blocki < (numBlocksInWidth * numBlocksInHeight); blocki++) {
      vector<uint8_t> & blockVec = db.blockVectors[blocki];
      // Append pixels from block by block data
      
      const int numBytes = blockDim * blockDim;
      blockVec.resize(numBytes);
      memcpy(blockVec.data(), inPrefixBytesPtr, numBytes);
      inPrefixBytesPtr += numBytes;
    }
    
    db.flattenAndCrop(inputImageOrderPixels,
                      width*height,
                      numBlocksInWidth,
                      numBlocksInHeight,
                      width,
                      height);
  }
  
  
  if ((0)) {
    printf("original image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = inputImageOrderPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Generate blocki ordering
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec, true);
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixels;
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  vector<uint8_t> halfBlockOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inputPixelsPtr,
                                outputPixels,
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec,
                                &halfBlockOptimalKTableVec);
  
  XCTAssert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size(), @"same size");
  XCTAssert(blockiOptimalKTableVec == blockOptimalKTableVec, @"same k values");
  
  if ((0)) {
    printf("big block s32 image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = outputPixels[offset];
        printf("%2d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  // Print blocki values in block order
  
  if ((0)) {
    printf("block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = outputPixels[offset++];
        printf("%3d ", bVal);
      }
      printf("\n");
    }
  }
  
  // Read 16 small blocks at a time from 32 streams
  // so that a big block of 32x32 is read in with
  // 8 reads per small block.
  
  vector<uint8_t> decodedS32PixelsVec(width*height);
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32PixelsVec.data(),
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((0)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32PixelsVec[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32PixelsVec[i];
      uint8_t expected = blockiReorderedVec[i];
      if (bval != expected) {
        int x = i % width;
        int y = i / width;
        if (numFails < 10) {
          XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
          numFails += 1;
        }
      }
    }
  }
  
  // Note that blockOptimalKTableVec is replaced with blockiOptimalKTableVec
  // values here since the reordered table of K value is in big block iteration order.
  
  //blockOptimalKTableVec = blockiOptimalKTableVec;
  //blockOptimalKTableVec = halfBlockOptimalKTableVec;
  
  // Encode as rice bits and then decode with stream based decode for sanity check
  
  {
    // bit encoding will make use of 1/2 block size k lookup
    
    blockOptimalKTableVec = halfBlockOptimalKTableVec;
    
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    memset(decodedPixels32, 0xFF, width*height);
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    uint8_t *blockOptimalKTable = blockOptimalKTableVec.data();
    int blockOptimalKTableLen = (int) blockOptimalKTableVec.size();
    
    vector<uint8_t> riceEncodedVec = encode(blockSymbols,
                                            numBlockSymbols,
                                            blockDim,
                                            blockOptimalKTable,
                                            blockOptimalKTableLen,
                                            blockN);
    
#if defined(DEBUG)
    {
      vector<uint8_t> outBufferVec(width*height);
      uint8_t *outBuffer = outBufferVec.data();
      
      vector<uint32_t> bitOffsetsEveryVal = generateBitOffsets(blockSymbols,
                                                               numBlockSymbols,
                                                               blockDim,
                                                               blockOptimalKTable,
                                                               blockOptimalKTableLen,
                                                               blockN,
                                                               1);
      
      decode(riceEncodedVec.data(),
             (int)riceEncodedVec.size(),
             outBuffer,
             width*height,
             blockDim,
             blockOptimalKTable,
             blockOptimalKTableLen,
             blockN,
             bitOffsetsEveryVal.data());
      
      int cmp = memcmp(blockSymbols, outBuffer, width*height);
      assert(cmp == 0);
      
      // Decode with non-stream rice method and validate against known good decoded values stream
      
      decodeParallelCheck(riceEncodedVec.data(),
                          (int)riceEncodedVec.size(),
                          outBuffer,
                          width*height,
                          blockDim,
                          blockOptimalKTable,
                          blockOptimalKTableLen,
                          blockN,
                          bitOffsetsEveryVal.data());
    }
#endif // DEBUG
    
    uint32_t *prefixBitsWordPtr = (uint32_t *) riceEncodedVec.data();
    
    // Fill in inoutBlockBitOffsetTable with bit offsets every 16 values (1/2 block)
    
    vector<uint32_t> bitOffsetsEvery16 = generateBitOffsets(blockSymbols,
                                                            numBlockSymbols,
                                                            blockDim,
                                                            blockOptimalKTable,
                                                            blockOptimalKTableLen,
                                                            blockN,
                                                            (blockDim * blockDim)/2);
    
    assert(bitOffsetsEvery16.size() == numBitOffsetsThisTest);
    
    vector<uint32_t> inoutBlockBitOffsetTableVec(numBitOffsetsThisTest);
    uint32_t *inoutBlockBitOffsetTable = inoutBlockBitOffsetTableVec.data();
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEvery16.size(); i++) {
      inoutBlockBitOffsetTable[i] = bitOffsetsEvery16[i];
    }
    
    // Reset blockOptimalKTable
    
    blockOptimalKTable = blockiOptimalKTableVec.data();
    blockOptimalKTableLen = (int) blockiOptimalKTableVec.size();
    
    // Render for each big block
    
    for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
      if ((0)) {
        printf("render bigBlocki %d\n", bigBlocki);
      }
      
      for (int tid = 0; tid < 32; tid++) {
        kernel_render_rice_typed<blockDim>(decodedPixels32,
                                           riceRenderUniform,
                                           inoutBlockBitOffsetTable,
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    uint8_t *decodedBytes = decodedBytesVec.data();
    memcpy(decodedBytes, decodedPixels32, width*height);
    
    if ((0)) {
      printf("decoded image order:\n");
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int bVal = decodedBytes[offset];
          printf("%3d, ", bVal);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    {
      int numFails = 0;
    
      for (int i = 0; i < (width*height); i++) {
        uint8_t bval = decodedBytes[i];
        uint8_t expected = inputImageOrderPixels[i];
        if (bval != expected) {
          int x = i % width;
          int y = i / width;
          if (numFails < 10) {
            XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
            numFails++;
          }
        }
      }
    }
  }
  
  return;
}

@end
