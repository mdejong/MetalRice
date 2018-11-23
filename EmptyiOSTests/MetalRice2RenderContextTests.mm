//
//  MetalRice2RenderContextTests.m
//
//  Created by Mo DeJong on 8/26/18.
//

#import <XCTest/XCTest.h>

#import <vector>

using namespace std;

#import "block.hpp"

#import "byte_bit_stream.hpp"
#import "rice.hpp"
#import "rice_parallel.hpp"

#define EMIT_CACHEDBITS_DEBUG_OUTPUT
#import "CachedBits.hpp"
#define EMIT_RICEDECODEBLOCKS_DEBUG_OUTPUT
#define RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
#import "RiceDecodeBlocks.hpp"

#import "RiceDecodeBlocksImpl.hpp"

#import "MetalRenderContext.h"

#import "MetalRice2RenderContext.h"
#import "MetalRice2RenderFrame.h"

#import "AAPLShaderTypes.h"

#import "Rice.h"

#import "Util.h"

#import "EncDec.hpp"

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

@interface MetalRice2RenderContextTests : XCTestCase

@end

@implementation MetalRice2RenderContextTests

- (void)setUp {
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

// 32x32 with 8x8 blocks is one big block and k = 7

- (void)testRiceRender4x4_k7 {
  
  const int constK = 7;
  
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
  
  const int numOffsetsToCopy = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec;
  inputPixelsVec.resize(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec;
  inputImageOrderPixelsVec.resize(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec;
  outputPixelsVec.resize(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint32_t> blockBitStartOffset;
  vector<uint8_t> riceEncodedVec;
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  memset(blockOptimalKTableVec.data(), constK, (int)blockOptimalKTableVec.size());
  
//  int over = 1;
//  for (int row = 0; row < height; row++) {
//    for (int col = 0; col < width; col++) {
//      int offset = (row * width) + col;
//      int bVal = offset & 63;
//      inputPixels[offset] = bVal;
//
//      if ((offset != 0) && (bVal == 0)) {
//        inputPixels[offset] += over;
//        over += 1;
//      }
//    }
//  }
  
  // Incrementing values from row number
  
  for (int row = 0; row < height; row++) {
    // Write col 0 for each row
    
    int bVal;
    
    {
      int col = 0;
      int offset = (row * width) + col;
      bVal = row & 0xFF;
      inputPixels[offset] = bVal;
    }
    
    for (int col = 1; col < width; col++) {
      int offset = (row * width) + col;
      bVal += 1;
      inputPixels[offset] = bVal;
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
      
      blockVec.resize(blockDim * blockDim);
      memcpy(blockVec.data(), inPrefixBytesPtr, blockDim * blockDim * sizeof(uint8_t));
      inPrefixBytesPtr += (blockDim * blockDim);
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
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec);
  
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
  XCTAssert(inputPixelsVec == blockiReorderedVec, @"blocki reordered pixels");
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
  uint8_t *decodedS32Pixels = decodedS32PixelsVec.data();
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32Pixels,
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((1)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32Pixels[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32Pixels[i];
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
  
  // Encode bytes as rice codes and then decode with software impl like compute shader
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    memset(decodedPixels32Vec.data(), 0xFF, decodedPixels32Vec.size() * sizeof(uint32_t));
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    uint8_t *blockOptimalKTable = halfBlockOptimalKTableVec.data();
    int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
    
    riceEncodedVec = encode(blockSymbols,
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
    
    vector<uint32_t> bitOffsetsEveryHalfBlock = generateBitOffsets(blockSymbols,
                                                            numBlockSymbols,
                                                            blockDim,
                                                            blockOptimalKTable,
                                                            blockOptimalKTableLen,
                                                            blockN,
                                                            (blockDim * blockDim)/2);
    
    assert(bitOffsetsEveryHalfBlock.size() == numOffsetsToCopy);
    
    blockBitStartOffset.resize(numOffsetsToCopy);
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEveryHalfBlock.size(); i++) {
      blockBitStartOffset[i] = bitOffsetsEveryHalfBlock[i];
    }
    
    // Use reordered k table that was rearranged into big block order
    
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
                                           blockBitStartOffset.data(),
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }

    vector<uint8_t> decodedBytesVec(width*height);
    memcpy(decodedBytesVec.data(), decodedPixels32, width*height);
    uint8_t *pixels8 = decodedBytesVec.data();
    
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
        XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
      }
    }
    
    // Emit blocki as 32 bit values
    
    vector<uint32_t> blockiVec;
    blockiVec.resize(width*4*height);
    uint32_t *blockiVecPtr = blockiVec.data();
    memset(blockiVecPtr, 0xFF, width*4*height);

    for (int tid = 0; tid < 32; tid++) {
      kernel_render_rice_typed<blockDim>(NULL,
                                         riceRenderUniform,
                                         blockBitStartOffset.data(),
                                         prefixBitsWordPtr,
                                         blockOptimalKTable,
                                         RenderRiceTypedBlocki,
                                         0,
                                         tid,
                                         blockiVecPtr);
    }

    if ((1)) {
      printf("blocki order:\n");
      
      uint32_t *ptr = blockiVec.data();
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int blocki = ptr[offset];
          printf("%3d, ", blocki);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    // Expected blocki is simple big block relative ordering sta
    
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
  }
  
  // ----------------------------
  
  // Start Metal config
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  MetalRice2RenderContext *mRenderContext = [[MetalRice2RenderContext alloc] init];
  
  mRenderContext.computeKernelFunction = @"kernel_render_rice2";
  
  [mRenderContext setupRenderPipelines:mrc];
  
  MetalRice2RenderFrame *mRenderFrame = [[MetalRice2RenderFrame alloc] init];
  
  const int totalNumberOfBytes = width * height;
  
  assert((blockN * blockDim * blockDim) == totalNumberOfBytes);
  
  CGSize renderSize = CGSizeMake(width, height);
  CGSize blockSize = CGSizeMake(blockDim, blockDim);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  {
    // Copy/Read compresed input (prefix bits)
    
    const uint32_t *in32Ptr = (const uint32_t *) riceEncodedVec.data();
    const uint32_t inNumBytes = (uint32_t) riceEncodedVec.size();
    
    [mRenderContext ensureBitsBuffCapacity:mrc
                                  numBytes:inNumBytes
                               renderFrame:mRenderFrame];
    
    assert(inNumBytes == mRenderFrame.bitsBuff.length);
    memcpy(mRenderFrame.bitsBuff.contents, in32Ptr, inNumBytes);
  }
  
  {
    // RiceRenderUniform
    
    assert(mRenderFrame.riceRenderUniform.length == sizeof(RiceRenderUniform));
    
    RiceRenderUniform & riceRenderUniform = *((RiceRenderUniform*) mRenderFrame.riceRenderUniform.contents);
    
    assert(((numBlocksInWidth * numBlocksInHeight) % 16) == 0); // Must be a multiple of 16 small blocks
    
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  }

  {
    // Copy block start bit table
    
    uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
    assert(blockBitStartOffset.size() == numOffsetsToCopy);
    assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
    
    for (int i = 0; i < blockBitStartOffset.size(); i++) {
      uint32_t bitOffset = blockBitStartOffset[i];
      bitOffsetTableOutPtr[i] = bitOffset;
    }
  }
  
  // Copy K table
  
  {
    // Use reordered k table that was rearranged into big block order
    
    uint8_t * blockOptimalKTable = blockiOptimalKTableVec.data();
    uint32_t blockOptimalKTableLen = (int) blockiOptimalKTableVec.size();
    
    assert(mRenderFrame.blockOptimalKTable.length == blockOptimalKTableLen);
    memcpy(mRenderFrame.blockOptimalKTable.contents, blockOptimalKTable, blockOptimalKTableLen);
    
    if (1)
    {
      NSLog(@"kTable: %d", blockOptimalKTableLen);
      
      uint8_t *ptr = (uint8_t *) mRenderFrame.blockOptimalKTable.contents;
      
      for (int i = 0; i < blockOptimalKTableLen; i++) {
        int val = ptr[i];
        printf("%3d\n", val);
        fflush(stdout);
      }
      
      printf("done\n");
    }
  }
  
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderRice:mrc
                     commandBuffer:commandBuffer
                       renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (1)
  {
    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%2d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  // Compare output bytes in image order
  
  {
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *outputPrefixBytesPtr = (uint8_t *) outputData.bytes;
    
    // Image order original bytes
    uint8_t *expectedBytesPtr = inputImageOrderPixels;
    
    int same = 1;
    
    if (1)
    {
      int numMismatched = 0;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint8_t outputVal = outputPrefixBytesPtr[offset];
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
    
    NSLog(@"validated %d bytes", (int)width*height);
  }
  
  // Assume the above is working, run the decode process over and over
  // to get accurate timing results
  
  [self measureBlock:^{
    // Get a metal command buffer, render compute invocation into it
    
    CFTimeInterval start = CACurrentMediaTime();
    
    id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
    
#if defined(DEBUG)
    assert(commandBuffer);
#endif // DEBUG
    
    commandBuffer.label = @"XCTestRenderCommandBuffer";
    
    {
      // Copy into blockOffsetTableBuff
      
      uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
      assert(blockBitStartOffset.size() == numOffsetsToCopy);
      assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
      
      for (int i = 0; i < blockBitStartOffset.size(); i++) {
        uint32_t bitOffset = blockBitStartOffset[i];
        bitOffsetTableOutPtr[i] = bitOffset;
      }
    }
    
    // Put the code you want to measure the time of here.
    
    [mRenderContext renderRice:mrc
                 commandBuffer:commandBuffer
                   renderFrame:mRenderFrame];
    
    // Wait for commands to be rendered
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    CFTimeInterval stop = CACurrentMediaTime();
    
    NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  }];
  
  return;
}

// 32x32 with 8x8 blocks is one big block and k = 0 up to k = 7

- (void)testRiceRender4x4_allk {

  for (int constK = 0; constK <= 7; constK++ ) {
  
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
  
  const int numOffsetsToCopy = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec;
  inputPixelsVec.resize(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec;
  inputImageOrderPixelsVec.resize(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec;
  outputPixelsVec.resize(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint32_t> blockBitStartOffset;
  vector<uint8_t> riceEncodedVec;
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  memset(blockOptimalKTableVec.data(), constK, (int)blockOptimalKTableVec.size());
  
//    int over = 1;
//    for (int row = 0; row < height; row++) {
//      for (int col = 0; col < width; col++) {
//        int offset = (row * width) + col;
//        int bVal = offset & 63;
//        inputPixels[offset] = bVal;
//
//        if ((offset != 0) && (bVal == 0)) {
//          inputPixels[offset] += over;
//          over += 1;
//        }
//      }
//    }
  
  // Incrementing values from row number
  
  for (int row = 0; row < height; row++) {
    // Write col 0 for each row
    
    int bVal;
    
    {
      int col = 0;
      int offset = (row * width) + col;
      bVal = row & 0xFF;
      inputPixels[offset] = bVal;
    }
    
    for (int col = 1; col < width; col++) {
      int offset = (row * width) + col;
      bVal += 1;
      inputPixels[offset] = bVal;
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
      
      blockVec.resize(blockDim * blockDim);
      memcpy(blockVec.data(), inPrefixBytesPtr, blockDim * blockDim * sizeof(uint8_t));
      inPrefixBytesPtr += (blockDim * blockDim);
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
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec);
  
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
  XCTAssert(inputPixelsVec == blockiReorderedVec, @"blocki reordered pixels");
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
  uint8_t *decodedS32Pixels = decodedS32PixelsVec.data();
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32Pixels,
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((1)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32Pixels[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32Pixels[i];
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
  
  // Encode bytes as rice codes and then decode with software impl like compute shader
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    memset(decodedPixels32Vec.data(), 0xFF, decodedPixels32Vec.size() * sizeof(uint32_t));
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    uint8_t *blockOptimalKTable = halfBlockOptimalKTableVec.data();
    int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
    
    riceEncodedVec = encode(blockSymbols,
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
    
    vector<uint32_t> bitOffsetsEveryHalfBlock = generateBitOffsets(blockSymbols,
                                                                   numBlockSymbols,
                                                                   blockDim,
                                                                   blockOptimalKTable,
                                                                   blockOptimalKTableLen,
                                                                   blockN,
                                                                   (blockDim * blockDim)/2);
    
    assert(bitOffsetsEveryHalfBlock.size() == numOffsetsToCopy);
    
    blockBitStartOffset.resize(numOffsetsToCopy);
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEveryHalfBlock.size(); i++) {
      blockBitStartOffset[i] = bitOffsetsEveryHalfBlock[i];
    }
    
    // Use reordered k table that was rearranged into big block order
    
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
                                           blockBitStartOffset.data(),
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    memcpy(decodedBytesVec.data(), decodedPixels32, width*height);
    uint8_t *pixels8 = decodedBytesVec.data();
    
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
        XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
      }
    }
    
  }
  
  // ----------------------------
  
  // Start Metal config
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  MetalRice2RenderContext *mRenderContext = [[MetalRice2RenderContext alloc] init];
  
  mRenderContext.computeKernelFunction = @"kernel_render_rice2";
    
  [mRenderContext setupRenderPipelines:mrc];
  
  MetalRice2RenderFrame *mRenderFrame = [[MetalRice2RenderFrame alloc] init];
  
  const int totalNumberOfBytes = width * height;
  
  assert((blockN * blockDim * blockDim) == totalNumberOfBytes);
  
  CGSize renderSize = CGSizeMake(width, height);
  CGSize blockSize = CGSizeMake(blockDim, blockDim);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  {
    // Copy/Read compresed input (prefix bits)
    
    const uint32_t *in32Ptr = (const uint32_t *) riceEncodedVec.data();
    const uint32_t inNumBytes = (uint32_t) riceEncodedVec.size();
    
    [mRenderContext ensureBitsBuffCapacity:mrc
                                  numBytes:inNumBytes
                               renderFrame:mRenderFrame];
    
    assert(inNumBytes == mRenderFrame.bitsBuff.length);
    memcpy(mRenderFrame.bitsBuff.contents, in32Ptr, inNumBytes);
  }
  
  {
    // RicePrefixRenderUniform
    
    assert(mRenderFrame.riceRenderUniform.length == sizeof(RiceRenderUniform));
    
    RiceRenderUniform & riceRenderUniform = *((RiceRenderUniform*) mRenderFrame.riceRenderUniform.contents);
    
    assert(((numBlocksInWidth * numBlocksInHeight) % 16) == 0); // Must be a multiple of 16 small blocks
    
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  }
  
  {
    // Copy block start bit table
    
    uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
    assert(blockBitStartOffset.size() == numOffsetsToCopy);
    assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
    
    for (int i = 0; i < blockBitStartOffset.size(); i++) {
      uint32_t bitOffset = blockBitStartOffset[i];
      bitOffsetTableOutPtr[i] = bitOffset;
    }
  }
  
  // Copy K table
  
  {
    // Use reordered k table that was rearranged into big block order
    
    uint8_t * blockOptimalKTable = blockiOptimalKTableVec.data();
    uint32_t blockOptimalKTableLen = (int) blockiOptimalKTableVec.size();
    
    assert(mRenderFrame.blockOptimalKTable.length == blockOptimalKTableLen);
    memcpy(mRenderFrame.blockOptimalKTable.contents, blockOptimalKTable, blockOptimalKTableLen);
    
    if (1)
    {
      NSLog(@"kTable: %d", blockOptimalKTableLen);
      
      uint8_t *ptr = (uint8_t *) mRenderFrame.blockOptimalKTable.contents;
      
      for (int i = 0; i < blockOptimalKTableLen; i++) {
        int val = ptr[i];
        printf("%3d\n", val);
        fflush(stdout);
      }
      
      printf("done\n");
    }
  }
  
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderRice:mrc
               commandBuffer:commandBuffer
                 renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (1)
  {
    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%2d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  // Compare output bytes in image order
  
  {
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *outputPrefixBytesPtr = (uint8_t *) outputData.bytes;
    
    // Image order original bytes
    uint8_t *expectedBytesPtr = inputImageOrderPixels;
    
    int same = 1;
    
    if (1)
    {
      int numMismatched = 0;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint8_t outputVal = outputPrefixBytesPtr[offset];
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
    
    NSLog(@"validated %d bytes for k = %d", (int)width*height, constK);
  }
    
  }
  
  return;
}


// 64x32 with 8x8 blocks is two big blocks and k = 7

- (void)testRiceRender8x4_k7 {
  
  const int constK = 7;
  
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
  
  const int numOffsetsToCopy = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec;
  inputPixelsVec.resize(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec;
  inputImageOrderPixelsVec.resize(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec;
  outputPixelsVec.resize(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint32_t> blockBitStartOffset;
  vector<uint8_t> riceEncodedVec;
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  memset(blockOptimalKTableVec.data(), constK, (int)blockOptimalKTableVec.size());
  
  //  int over = 1;
  //  for (int row = 0; row < height; row++) {
  //    for (int col = 0; col < width; col++) {
  //      int offset = (row * width) + col;
  //      int bVal = offset & 63;
  //      inputPixels[offset] = bVal;
  //
  //      if ((offset != 0) && (bVal == 0)) {
  //        inputPixels[offset] += over;
  //        over += 1;
  //      }
  //    }
  //  }
  
  // Incrementing values from row number
  
  for (int row = 0; row < height; row++) {
    // Write col 0 for each row
    
    int bVal;
    
    {
      int col = 0;
      int offset = (row * width) + col;
      bVal = row & 0xFF;
      inputPixels[offset] = bVal;
    }
    
    for (int col = 1; col < width; col++) {
      int offset = (row * width) + col;
      bVal += 1;
      inputPixels[offset] = bVal;
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
      
      blockVec.resize(blockDim * blockDim);
      memcpy(blockVec.data(), inPrefixBytesPtr, blockDim * blockDim * sizeof(uint8_t));
      inPrefixBytesPtr += (blockDim * blockDim);
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
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec);
  
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
  XCTAssert(inputPixelsVec != blockiReorderedVec, @"blocki reordered pixels");
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
  uint8_t *decodedS32Pixels = decodedS32PixelsVec.data();
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32Pixels,
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((1)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32Pixels[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32Pixels[i];
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
  
  // Encode bytes as rice codes and then decode with software impl like compute shader
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    memset(decodedPixels32Vec.data(), 0xFF, decodedPixels32Vec.size() * sizeof(uint32_t));
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    uint8_t *blockOptimalKTable = halfBlockOptimalKTableVec.data();
    int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
    
    riceEncodedVec = encode(blockSymbols,
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
    
    vector<uint32_t> bitOffsetsEveryHalfBlock = generateBitOffsets(blockSymbols,
                                                                   numBlockSymbols,
                                                                   blockDim,
                                                                   blockOptimalKTable,
                                                                   blockOptimalKTableLen,
                                                                   blockN,
                                                                   (blockDim * blockDim)/2);
    
    assert(bitOffsetsEveryHalfBlock.size() == numOffsetsToCopy);
    
    blockBitStartOffset.resize(numOffsetsToCopy);
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEveryHalfBlock.size(); i++) {
      blockBitStartOffset[i] = bitOffsetsEveryHalfBlock[i];
    }
    
    // Use reordered k table that was rearranged into big block order
    
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
                                           blockBitStartOffset.data(),
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    memcpy(decodedBytesVec.data(), decodedPixels32, width*height);
    uint8_t *pixels8 = decodedBytesVec.data();
    
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
        XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
      }
    }
    
    // Emit blocki as 32 bit values
    
    vector<uint32_t> blockiVec;
    blockiVec.resize(width*4*height);
    uint32_t *blockiVecPtr = blockiVec.data();
    memset(blockiVecPtr, 0xFF, width*4*height);
    
    for (int tid = 0; tid < 32; tid++) {
      kernel_render_rice_typed<blockDim>(NULL,
                                         riceRenderUniform,
                                         blockBitStartOffset.data(),
                                         prefixBitsWordPtr,
                                         blockOptimalKTable,
                                         RenderRiceTypedBlocki,
                                         0,
                                         tid,
                                         blockiVecPtr);
    }
    
    if ((1)) {
      printf("blocki order:\n");
      
      uint32_t *ptr = blockiVec.data();
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int blocki = ptr[offset];
          printf("%3d, ", blocki);
        }
        printf("\n");
      }
      
      printf("\n");
    }

  }
  
  // ----------------------------
  
  // Start Metal config
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  MetalRice2RenderContext *mRenderContext = [[MetalRice2RenderContext alloc] init];
  
  mRenderContext.computeKernelFunction = @"kernel_render_rice2";
  
  [mRenderContext setupRenderPipelines:mrc];
  
  MetalRice2RenderFrame *mRenderFrame = [[MetalRice2RenderFrame alloc] init];
  
  const int totalNumberOfBytes = width * height;
  
  assert((blockN * blockDim * blockDim) == totalNumberOfBytes);
  
  CGSize renderSize = CGSizeMake(width, height);
  CGSize blockSize = CGSizeMake(blockDim, blockDim);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  {
    // Copy/Read compresed input (prefix bits)
    
    const uint32_t *in32Ptr = (const uint32_t *) riceEncodedVec.data();
    const uint32_t inNumBytes = (uint32_t) riceEncodedVec.size();
    
    [mRenderContext ensureBitsBuffCapacity:mrc
                                  numBytes:inNumBytes
                               renderFrame:mRenderFrame];
    
    assert(inNumBytes == mRenderFrame.bitsBuff.length);
    memcpy(mRenderFrame.bitsBuff.contents, in32Ptr, inNumBytes);
  }
  
  {
    // RiceRenderUniform
    
    assert(mRenderFrame.riceRenderUniform.length == sizeof(RiceRenderUniform));
    
    RiceRenderUniform & riceRenderUniform = *((RiceRenderUniform*) mRenderFrame.riceRenderUniform.contents);
    
    assert(((numBlocksInWidth * numBlocksInHeight) % 16) == 0); // Must be a multiple of 16 small blocks
    
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  }
  
  {
    // Copy block start bit table
    
    uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
    assert(blockBitStartOffset.size() == numOffsetsToCopy);
    assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
    
    for (int i = 0; i < blockBitStartOffset.size(); i++) {
      uint32_t bitOffset = blockBitStartOffset[i];
      bitOffsetTableOutPtr[i] = bitOffset;
    }
  }
  
  // Copy K table
  
  {
    // Use reordered k table that was rearranged into big block order
    
    uint8_t * blockOptimalKTable = blockiOptimalKTableVec.data();
    uint32_t blockOptimalKTableLen = (int) blockiOptimalKTableVec.size();
    
    assert(mRenderFrame.blockOptimalKTable.length == blockOptimalKTableLen);
    memcpy(mRenderFrame.blockOptimalKTable.contents, blockOptimalKTable, blockOptimalKTableLen);
    
    if (1)
    {
      NSLog(@"kTable: %d", blockOptimalKTableLen);
      
      uint8_t *ptr = (uint8_t *) mRenderFrame.blockOptimalKTable.contents;
      
      for (int i = 0; i < blockOptimalKTableLen; i++) {
        int val = ptr[i];
        printf("%3d\n", val);
        fflush(stdout);
      }
      
      printf("done\n");
    }
  }
  
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderRice:mrc
               commandBuffer:commandBuffer
                 renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (1)
  {
    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
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
  
  // Compare output bytes in image order
  
  {
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *outputPrefixBytesPtr = (uint8_t *) outputData.bytes;
    
    // Image order original bytes
    uint8_t *expectedBytesPtr = inputImageOrderPixels;
    
    int same = 1;
    
    if (1)
    {
      int numFails = 0;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint8_t outputVal = outputPrefixBytesPtr[offset];
          //outputVal += 1; // Adjust CLZ to CLZ+1
          uint8_t expectedVal = expectedBytesPtr[offset];
          if (outputVal != expectedVal && numFails < 10) {
            printf("output[%3d,%3d] mismatch : output != expected : %d != %d\n", col, row, outputVal, expectedVal);
            same = 0;
            numFails += 1;
          }
        }
      }
    }
    
    XCTAssert(same == 1);
    
    NSLog(@"validated %d bytes", (int)width*height);
  }
  
  // Assume the above is working, run the decode process over and over
  // to get accurate timing results
  
  [self measureBlock:^{
    // Get a metal command buffer, render compute invocation into it
    
    CFTimeInterval start = CACurrentMediaTime();
    
    id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
    
#if defined(DEBUG)
    assert(commandBuffer);
#endif // DEBUG
    
    commandBuffer.label = @"XCTestRenderCommandBuffer";
    
    {
      // Copy into blockOffsetTableBuff
      
      uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
      assert(blockBitStartOffset.size() == numOffsetsToCopy);
      assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
      
      for (int i = 0; i < blockBitStartOffset.size(); i++) {
        uint32_t bitOffset = blockBitStartOffset[i];
        bitOffsetTableOutPtr[i] = bitOffset;
      }
    }
    
    // Put the code you want to measure the time of here.
    
    [mRenderContext renderRice:mrc
                 commandBuffer:commandBuffer
                   renderFrame:mRenderFrame];
    
    // Wait for commands to be rendered
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    CFTimeInterval stop = CACurrentMediaTime();
    
    NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  }];
  
  return;
}

// 32x64 with 8x8 blocks is two big blocks and k = 7

- (void)testRiceRender4x8_k7 {
  
  const int constK = 7;
  
  const int blockDim = 8;
  const int blockiDim = 4;
  
  // 8x8 blocks at 1x1 big blocks, aka 32x32
  const int width = 4 * blockDim;
  const int height = 8 * blockDim;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / (blockDim * blockiDim);
  const int numBigBlocksInHeight = height / (blockDim * blockiDim);
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  const int numOffsetsToCopy = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec;
  inputPixelsVec.resize(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec;
  inputImageOrderPixelsVec.resize(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec;
  outputPixelsVec.resize(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint32_t> blockBitStartOffset;
  vector<uint8_t> riceEncodedVec;
  
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
  
  // Incrementing values from row number
  
//  for (int row = 0; row < height; row++) {
//    // Write col 0 for each row
//
//    int bVal;
//
//    {
//      int col = 0;
//      int offset = (row * width) + col;
//      bVal = row & 0xFF;
//      inputPixels[offset] = bVal;
//    }
//
//    for (int col = 1; col < width; col++) {
//      int offset = (row * width) + col;
//      bVal += 1;
//      inputPixels[offset] = bVal;
//    }
//  }
  
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
      
      blockVec.resize(blockDim * blockDim);
      memcpy(blockVec.data(), inPrefixBytesPtr, blockDim * blockDim * sizeof(uint8_t));
      inPrefixBytesPtr += (blockDim * blockDim);
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
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec);
  
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
  XCTAssert(inputPixelsVec == blockiReorderedVec, @"blocki reordered pixels");
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
  uint8_t *decodedS32Pixels = decodedS32PixelsVec.data();
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32Pixels,
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((1)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32Pixels[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32Pixels[i];
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
  
  // Encode bytes as rice codes and then decode with software impl like compute shader
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    memset(decodedPixels32Vec.data(), 0xFF, decodedPixels32Vec.size() * sizeof(uint32_t));
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    uint8_t *blockOptimalKTable = halfBlockOptimalKTableVec.data();
    int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
    
    riceEncodedVec = encode(blockSymbols,
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
    
    vector<uint32_t> bitOffsetsEveryHalfBlock = generateBitOffsets(blockSymbols,
                                                                   numBlockSymbols,
                                                                   blockDim,
                                                                   blockOptimalKTable,
                                                                   blockOptimalKTableLen,
                                                                   blockN,
                                                                   (blockDim * blockDim)/2);
    
    assert(bitOffsetsEveryHalfBlock.size() == numOffsetsToCopy);
    
    blockBitStartOffset.resize(numOffsetsToCopy);
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEveryHalfBlock.size(); i++) {
      blockBitStartOffset[i] = bitOffsetsEveryHalfBlock[i];
    }
    
    // Use reordered k table that was rearranged into big block order
    
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
                                           blockBitStartOffset.data(),
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    memcpy(decodedBytesVec.data(), decodedPixels32, width*height);
    uint8_t *pixels8 = decodedBytesVec.data();
    
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
        XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
      }
    }
    
    // Emit blocki as 32 bit values
    
    vector<uint32_t> blockiVec;
    blockiVec.resize(width*4*height);
    uint32_t *blockiVecPtr = blockiVec.data();
    memset(blockiVecPtr, 0xFF, width*4*height);
    
    for (int tid = 0; tid < 32; tid++) {
      kernel_render_rice_typed<blockDim>(NULL,
                                         riceRenderUniform,
                                         blockBitStartOffset.data(),
                                         prefixBitsWordPtr,
                                         blockOptimalKTable,
                                         RenderRiceTypedBlocki,
                                         0,
                                         tid,
                                         blockiVecPtr);
    }
    
    if ((1)) {
      printf("blocki order:\n");
      
      uint32_t *ptr = blockiVec.data();
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int blocki = ptr[offset];
          printf("%3d, ", blocki);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
  }
  
  // ----------------------------
  
  // Start Metal config
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  MetalRice2RenderContext *mRenderContext = [[MetalRice2RenderContext alloc] init];
  
  mRenderContext.computeKernelFunction = @"kernel_render_rice2";
  
  [mRenderContext setupRenderPipelines:mrc];
  
  MetalRice2RenderFrame *mRenderFrame = [[MetalRice2RenderFrame alloc] init];
  
  const int totalNumberOfBytes = width * height;
  
  assert((blockN * blockDim * blockDim) == totalNumberOfBytes);
  
  CGSize renderSize = CGSizeMake(width, height);
  CGSize blockSize = CGSizeMake(blockDim, blockDim);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  {
    // Copy/Read compresed input (prefix bits)
    
    const uint32_t *in32Ptr = (const uint32_t *) riceEncodedVec.data();
    const uint32_t inNumBytes = (uint32_t) riceEncodedVec.size();
    
    [mRenderContext ensureBitsBuffCapacity:mrc
                                  numBytes:inNumBytes
                               renderFrame:mRenderFrame];
    
    assert(inNumBytes == mRenderFrame.bitsBuff.length);
    memcpy(mRenderFrame.bitsBuff.contents, in32Ptr, inNumBytes);
  }
  
  {
    // RiceRenderUniform
    
    assert(mRenderFrame.riceRenderUniform.length == sizeof(RiceRenderUniform));
    
    RiceRenderUniform & riceRenderUniform = *((RiceRenderUniform*) mRenderFrame.riceRenderUniform.contents);
    
    assert(((numBlocksInWidth * numBlocksInHeight) % 16) == 0); // Must be a multiple of 16 small blocks
    
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  }

  {
    // Copy block start bit table
    
    uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
    assert(blockBitStartOffset.size() == numOffsetsToCopy);
    assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
    
    for (int i = 0; i < blockBitStartOffset.size(); i++) {
      uint32_t bitOffset = blockBitStartOffset[i];
      bitOffsetTableOutPtr[i] = bitOffset;
    }
  }
  
  // Copy K table
  
  {
    // Use reordered k table that was rearranged into big block order
    
    uint8_t * blockOptimalKTable = blockiOptimalKTableVec.data();
    uint32_t blockOptimalKTableLen = (int) blockiOptimalKTableVec.size();
    
    assert(mRenderFrame.blockOptimalKTable.length == blockOptimalKTableLen);
    memcpy(mRenderFrame.blockOptimalKTable.contents, blockOptimalKTable, blockOptimalKTableLen);
    
    if (1)
    {
      NSLog(@"kTable: %d", blockOptimalKTableLen);
      
      uint8_t *ptr = (uint8_t *) mRenderFrame.blockOptimalKTable.contents;
      
      for (int i = 0; i < blockOptimalKTableLen; i++) {
        int val = ptr[i];
        printf("%3d\n", val);
        fflush(stdout);
      }
      
      printf("done\n");
    }
  }
  
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderRice:mrc
               commandBuffer:commandBuffer
                 renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (1)
  {
    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%2d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  // Compare output bytes in image order
  
  {
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *outputPrefixBytesPtr = (uint8_t *) outputData.bytes;
    
    // Image order original bytes
    uint8_t *expectedBytesPtr = inputImageOrderPixels;
    
    int same = 1;
    
    if (1)
    {
      int numMismatched = 0;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint8_t outputVal = outputPrefixBytesPtr[offset];
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
    
    NSLog(@"validated %d bytes", (int)width*height);
  }
  
  // Assume the above is working, run the decode process over and over
  // to get accurate timing results
  
  [self measureBlock:^{
    // Get a metal command buffer, render compute invocation into it
    
    CFTimeInterval start = CACurrentMediaTime();
    
    id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
    
#if defined(DEBUG)
    assert(commandBuffer);
#endif // DEBUG
    
    commandBuffer.label = @"XCTestRenderCommandBuffer";
    
    {
      // Copy into blockOffsetTableBuff
      
      uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
      assert(blockBitStartOffset.size() == numOffsetsToCopy);
      assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
      
      for (int i = 0; i < blockBitStartOffset.size(); i++) {
        uint32_t bitOffset = blockBitStartOffset[i];
        bitOffsetTableOutPtr[i] = bitOffset;
      }
    }
    
    // Put the code you want to measure the time of here.
    
    [mRenderContext renderRice:mrc
                 commandBuffer:commandBuffer
                   renderFrame:mRenderFrame];
    
    // Wait for commands to be rendered
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    CFTimeInterval stop = CACurrentMediaTime();
    
    NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  }];
  
  return;
}

// 64x32 with 8x8 blocks is two big blocks with variable
// k values depending on the block.

- (void)testRiceRender8x4_DiffK02 {
  
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
  
  const int numOffsetsToCopy = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec;
  inputPixelsVec.resize(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec;
  inputImageOrderPixelsVec.resize(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec;
  outputPixelsVec.resize(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint32_t> blockBitStartOffset;
  vector<uint8_t> riceEncodedVec;
  
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

  // Incrementing values from row number
  
//  for (int row = 0; row < height; row++) {
//    // Write col 0 for each row
//
//    int bVal;
//
//    {
//      int col = 0;
//      int offset = (row * width) + col;
//      bVal = row & 0xFF;
//      inputPixels[offset] = bVal;
//    }
//
//    for (int col = 1; col < width; col++) {
//      int offset = (row * width) + col;
//      bVal += 1;
//      inputPixels[offset] = bVal;
//    }
//  }
  
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
      
      blockVec.resize(blockDim * blockDim);
      memcpy(blockVec.data(), inPrefixBytesPtr, blockDim * blockDim * sizeof(uint8_t));
      inPrefixBytesPtr += (blockDim * blockDim);
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
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec);
  
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
  XCTAssert(inputPixelsVec != blockiReorderedVec, @"blocki reordered pixels");
  XCTAssert(blockiOptimalKTableVec != blockOptimalKTableVec, @"same k values");
  
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
  uint8_t *decodedS32Pixels = decodedS32PixelsVec.data();
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32Pixels,
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((0)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32Pixels[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32Pixels[i];
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
  
  // Encode bytes as rice codes and then decode with software impl like compute shader
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    memset(decodedPixels32Vec.data(), 0xFF, decodedPixels32Vec.size() * sizeof(uint32_t));
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    uint8_t *blockOptimalKTable = halfBlockOptimalKTableVec.data();
    int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
    
    riceEncodedVec = encode(blockSymbols,
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
    
    vector<uint32_t> bitOffsetsEveryHalfBlock = generateBitOffsets(blockSymbols,
                                                                   numBlockSymbols,
                                                                   blockDim,
                                                                   blockOptimalKTable,
                                                                   blockOptimalKTableLen,
                                                                   blockN,
                                                                   (blockDim * blockDim)/2);
    
    assert(bitOffsetsEveryHalfBlock.size() == numOffsetsToCopy);
    
    blockBitStartOffset.resize(numOffsetsToCopy);
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEveryHalfBlock.size(); i++) {
      blockBitStartOffset[i] = bitOffsetsEveryHalfBlock[i];
    }
    
    // Use reordered k table that was rearranged into big block order
    
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
                                           blockBitStartOffset.data(),
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    memcpy(decodedBytesVec.data(), decodedPixels32, width*height);
    uint8_t *pixels8 = decodedBytesVec.data();
    
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
        XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
      }
    }
    
    // Emit blocki as 32 bit values
    
    vector<uint32_t> blockiVec;
    blockiVec.resize(width*4*height);
    uint32_t *blockiVecPtr = blockiVec.data();
    memset(blockiVecPtr, 0xFF, width*4*height);
    
    for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
      for (int tid = 0; tid < 32; tid++) {
        kernel_render_rice_typed<blockDim>(NULL,
                                           riceRenderUniform,
                                           blockBitStartOffset.data(),
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedBlocki,
                                           bigBlocki,
                                           tid,
                                           blockiVecPtr);
      }
    }

    if ((1)) {
      printf("blocki order:\n");
      
      uint32_t *ptr = blockiVec.data();
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int blocki = ptr[offset];
          printf("%3d, ", blocki);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
  }
  
  // ----------------------------
  
  // Start Metal config
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  MetalRice2RenderContext *mRenderContext = [[MetalRice2RenderContext alloc] init];
  
  mRenderContext.computeKernelFunction = @"kernel_render_rice2";
  
  [mRenderContext setupRenderPipelines:mrc];
  
  MetalRice2RenderFrame *mRenderFrame = [[MetalRice2RenderFrame alloc] init];
  
  const int totalNumberOfBytes = width * height;
  
  assert((blockN * blockDim * blockDim) == totalNumberOfBytes);
  
  CGSize renderSize = CGSizeMake(width, height);
  CGSize blockSize = CGSizeMake(blockDim, blockDim);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  {
    // Copy/Read compresed input (prefix bits)
    
    const uint32_t *in32Ptr = (const uint32_t *) riceEncodedVec.data();
    const uint32_t inNumBytes = (uint32_t) riceEncodedVec.size();
    
    [mRenderContext ensureBitsBuffCapacity:mrc
                                  numBytes:inNumBytes
                               renderFrame:mRenderFrame];
    
    assert(inNumBytes == mRenderFrame.bitsBuff.length);
    memcpy(mRenderFrame.bitsBuff.contents, in32Ptr, inNumBytes);
  }
  
  {
    // RiceRenderUniform
    
    assert(mRenderFrame.riceRenderUniform.length == sizeof(RiceRenderUniform));
    
    RiceRenderUniform & riceRenderUniform = *((RiceRenderUniform*) mRenderFrame.riceRenderUniform.contents);
    
    assert(((numBlocksInWidth * numBlocksInHeight) % 16) == 0); // Must be a multiple of 16 small blocks
    
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  }

  {
    // Copy block start bit table
    
    uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
    assert(blockBitStartOffset.size() == numOffsetsToCopy);
    assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
    
    for (int i = 0; i < blockBitStartOffset.size(); i++) {
      uint32_t bitOffset = blockBitStartOffset[i];
      bitOffsetTableOutPtr[i] = bitOffset;
    }
  }
  
  // Copy K table
  
  {
    // Use reordered k table that was rearranged into big block order
    
    uint8_t * blockOptimalKTable = blockiOptimalKTableVec.data();
    uint32_t blockOptimalKTableLen = (int) blockiOptimalKTableVec.size();
    
    assert(mRenderFrame.blockOptimalKTable.length == blockOptimalKTableLen);
    memcpy(mRenderFrame.blockOptimalKTable.contents, blockOptimalKTable, blockOptimalKTableLen);
    
    if (1)
    {
      NSLog(@"kTable: %d", blockOptimalKTableLen);
      
      uint8_t *ptr = (uint8_t *) mRenderFrame.blockOptimalKTable.contents;
      
      for (int i = 0; i < blockOptimalKTableLen; i++) {
        int val = ptr[i];
        printf("%3d\n", val);
        fflush(stdout);
      }
      
      printf("done\n");
    }
  }
  
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderRice:mrc
               commandBuffer:commandBuffer
                 renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (1)
  {
    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%2d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  // Compare output bytes in image order
  
  {
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *outputPrefixBytesPtr = (uint8_t *) outputData.bytes;
    
    // Image order original bytes
    uint8_t *expectedBytesPtr = inputImageOrderPixels;
    
    int same = 1;
    
    if (1)
    {
      int numMismatched = 0;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint8_t outputVal = outputPrefixBytesPtr[offset];
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
    
    NSLog(@"validated %d bytes", (int)width*height);
  }
  
  // Assume the above is working, run the decode process over and over
  // to get accurate timing results
  
  [self measureBlock:^{
    // Get a metal command buffer, render compute invocation into it
    
    CFTimeInterval start = CACurrentMediaTime();
    
    id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
    
#if defined(DEBUG)
    assert(commandBuffer);
#endif // DEBUG
    
    commandBuffer.label = @"XCTestRenderCommandBuffer";
    
    {
      // Copy into blockOffsetTableBuff
      
      uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
      assert(blockBitStartOffset.size() == numOffsetsToCopy);
      assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
      
      for (int i = 0; i < blockBitStartOffset.size(); i++) {
        uint32_t bitOffset = blockBitStartOffset[i];
        bitOffsetTableOutPtr[i] = bitOffset;
      }
    }
    
    // Put the code you want to measure the time of here.
    
    [mRenderContext renderRice:mrc
                 commandBuffer:commandBuffer
                   renderFrame:mRenderFrame];
    
    // Wait for commands to be rendered
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    CFTimeInterval stop = CACurrentMediaTime();
    
    NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  }];
  
  return;
}

// 256x256

- (void)testRiceRender256x256_DiffK02 {
  
  const int blockDim = 8;
  const int blockiDim = 4;
  
  const int width = 8 * 32;
  const int height = 8 * 32;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / (blockDim * blockiDim);
  const int numBigBlocksInHeight = height / (blockDim * blockiDim);
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  const int numOffsetsToCopy = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec;
  inputPixelsVec.resize(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec;
  inputImageOrderPixelsVec.resize(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec;
  outputPixelsVec.resize(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint32_t> blockBitStartOffset;
  vector<uint8_t> riceEncodedVec;
  
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
  
  // Incrementing values from row number
  
  //  for (int row = 0; row < height; row++) {
  //    // Write col 0 for each row
  //
  //    int bVal;
  //
  //    {
  //      int col = 0;
  //      int offset = (row * width) + col;
  //      bVal = row & 0xFF;
  //      inputPixels[offset] = bVal;
  //    }
  //
  //    for (int col = 1; col < width; col++) {
  //      int offset = (row * width) + col;
  //      bVal += 1;
  //      inputPixels[offset] = bVal;
  //    }
  //  }
  
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
      
      blockVec.resize(blockDim * blockDim);
      memcpy(blockVec.data(), inPrefixBytesPtr, blockDim * blockDim * sizeof(uint8_t));
      inPrefixBytesPtr += (blockDim * blockDim);
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
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec);
  
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
  XCTAssert(inputPixelsVec != blockiReorderedVec, @"blocki reordered pixels");
  XCTAssert(blockiOptimalKTableVec != blockOptimalKTableVec, @"same k values");
  
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
  uint8_t *decodedS32Pixels = decodedS32PixelsVec.data();
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32Pixels,
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((0)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32Pixels[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32Pixels[i];
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
  
  // Encode bytes as rice codes and then decode with software impl like compute shader
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    memset(decodedPixels32Vec.data(), 0xFF, decodedPixels32Vec.size() * sizeof(uint32_t));
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    uint8_t *blockOptimalKTable = halfBlockOptimalKTableVec.data();
    int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
    
    riceEncodedVec = encode(blockSymbols,
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
    
    vector<uint32_t> bitOffsetsEveryHalfBlock = generateBitOffsets(blockSymbols,
                                                                   numBlockSymbols,
                                                                   blockDim,
                                                                   blockOptimalKTable,
                                                                   blockOptimalKTableLen,
                                                                   blockN,
                                                                   (blockDim * blockDim)/2);
    
    assert(bitOffsetsEveryHalfBlock.size() == numOffsetsToCopy);
    
    blockBitStartOffset.resize(numOffsetsToCopy);
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEveryHalfBlock.size(); i++) {
      blockBitStartOffset[i] = bitOffsetsEveryHalfBlock[i];
    }
    
    // Use reordered k table that was rearranged into big block order
    
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
                                           blockBitStartOffset.data(),
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    memcpy(decodedBytesVec.data(), decodedPixels32, width*height);
    uint8_t *pixels8 = decodedBytesVec.data();
    
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
        XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
      }
    }
    
    // Emit blocki as 32 bit values
    
    vector<uint32_t> blockiVec;
    blockiVec.resize(width*4*height);
    uint32_t *blockiVecPtr = blockiVec.data();
    memset(blockiVecPtr, 0xFF, width*4*height);
    
    for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
      for (int tid = 0; tid < 32; tid++) {
        kernel_render_rice_typed<blockDim>(NULL,
                                           riceRenderUniform,
                                           blockBitStartOffset.data(),
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedBlocki,
                                           bigBlocki,
                                           tid,
                                           blockiVecPtr);
      }
    }
    
    if ((0)) {
      printf("blocki order:\n");
      
      uint32_t *ptr = blockiVec.data();
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int blocki = ptr[offset];
          printf("%3d, ", blocki);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
  }
  
  // ----------------------------
  
  // Start Metal config
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  MetalRice2RenderContext *mRenderContext = [[MetalRice2RenderContext alloc] init];
  
  mRenderContext.computeKernelFunction = @"kernel_render_rice2";
  
  [mRenderContext setupRenderPipelines:mrc];
  
  MetalRice2RenderFrame *mRenderFrame = [[MetalRice2RenderFrame alloc] init];
  
  const int totalNumberOfBytes = width * height;
  
  assert((blockN * blockDim * blockDim) == totalNumberOfBytes);
  
  CGSize renderSize = CGSizeMake(width, height);
  CGSize blockSize = CGSizeMake(blockDim, blockDim);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  {
    // Copy/Read compresed input (prefix bits)
    
    const uint32_t *in32Ptr = (const uint32_t *) riceEncodedVec.data();
    const uint32_t inNumBytes = (uint32_t) riceEncodedVec.size();
    
    [mRenderContext ensureBitsBuffCapacity:mrc
                                  numBytes:inNumBytes
                               renderFrame:mRenderFrame];
    
    assert(inNumBytes == mRenderFrame.bitsBuff.length);
    memcpy(mRenderFrame.bitsBuff.contents, in32Ptr, inNumBytes);
  }
  
  {
    // RicePrefixRenderUniform
    
    assert(mRenderFrame.riceRenderUniform.length == sizeof(RiceRenderUniform));
    
    RiceRenderUniform & riceRenderUniform = *((RiceRenderUniform*) mRenderFrame.riceRenderUniform.contents);
    
    assert(((numBlocksInWidth * numBlocksInHeight) % 16) == 0); // Must be a multiple of 16 small blocks
    
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  }
  
  {
    // Copy block start bit table
    
    uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
    assert(blockBitStartOffset.size() == numOffsetsToCopy);
    assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
    
    for (int i = 0; i < blockBitStartOffset.size(); i++) {
      uint32_t bitOffset = blockBitStartOffset[i];
      bitOffsetTableOutPtr[i] = bitOffset;
    }
  }
  
  // Copy K table
  
  {
    // Use reordered k table that was rearranged into big block order
    
    uint8_t * blockOptimalKTable = blockiOptimalKTableVec.data();
    uint32_t blockOptimalKTableLen = (int) blockiOptimalKTableVec.size();
    
    assert(mRenderFrame.blockOptimalKTable.length == blockOptimalKTableLen);
    memcpy(mRenderFrame.blockOptimalKTable.contents, blockOptimalKTable, blockOptimalKTableLen);
    
    if (0)
    {
      NSLog(@"kTable: %d", blockOptimalKTableLen);
      
      uint8_t *ptr = (uint8_t *) mRenderFrame.blockOptimalKTable.contents;
      
      for (int i = 0; i < blockOptimalKTableLen; i++) {
        int val = ptr[i];
        printf("%3d\n", val);
        fflush(stdout);
      }
      
      printf("done\n");
    }
  }
  
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderRice:mrc
               commandBuffer:commandBuffer
                 renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (0)
  {
    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%2d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  // Compare output bytes in image order
  
  {
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *outputPrefixBytesPtr = (uint8_t *) outputData.bytes;
    
    // Image order original bytes
    uint8_t *expectedBytesPtr = inputImageOrderPixels;
    
    int same = 1;
    
    if (1)
    {
      printf("validate outputTexture: %dx%d\n", width, height);
      
      int numFails = 0;
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint8_t outputVal = outputPrefixBytesPtr[offset];
          //outputVal += 1; // Adjust CLZ to CLZ+1
          uint8_t expectedVal = expectedBytesPtr[offset];
          if (outputVal != expectedVal && numFails < 10) {
            printf("output[%3d,%3d] mismatch : output != expected : %d != %d\n", col, row, outputVal, expectedVal);
            same = 0;
            numFails += 1;
          }
        }
      }
    }
    
    XCTAssert(same == 1);
    
    NSLog(@"validated %d bytes", (int)width*height);
  }
  
  // Assume the above is working, run the decode process over and over
  // to get accurate timing results
  
  [self measureBlock:^{
    // Get a metal command buffer, render compute invocation into it
    
    CFTimeInterval start = CACurrentMediaTime();
    
    id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
    
#if defined(DEBUG)
    assert(commandBuffer);
#endif // DEBUG
    
    commandBuffer.label = @"XCTestRenderCommandBuffer";
    
    {
      // Copy into blockOffsetTableBuff
      
      uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
      assert(blockBitStartOffset.size() == numOffsetsToCopy);
      assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
      
      for (int i = 0; i < blockBitStartOffset.size(); i++) {
        uint32_t bitOffset = blockBitStartOffset[i];
        bitOffsetTableOutPtr[i] = bitOffset;
      }
    }
    
    // Put the code you want to measure the time of here.
    
    [mRenderContext renderRice:mrc
                 commandBuffer:commandBuffer
                   renderFrame:mRenderFrame];
    
    // Wait for commands to be rendered
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    CFTimeInterval stop = CACurrentMediaTime();
    
    NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  }];
  
  return;
}

// iPad screen size with variable K values

- (void)testRiceRender2048x1536_DiffK02 {
  
  const int blockDim = 8;
  const int blockiDim = 4;
  
  const int width = 64 * 32;
  const int height = 48 * 32;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / (blockDim * blockiDim);
  const int numBigBlocksInHeight = height / (blockDim * blockiDim);
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  const int numOffsetsToCopy = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec;
  inputPixelsVec.resize(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec;
  inputImageOrderPixelsVec.resize(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec;
  outputPixelsVec.resize(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint32_t> blockBitStartOffset;
  vector<uint8_t> riceEncodedVec;
  
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
  
  // Incrementing values from row number
  
  //  for (int row = 0; row < height; row++) {
  //    // Write col 0 for each row
  //
  //    int bVal;
  //
  //    {
  //      int col = 0;
  //      int offset = (row * width) + col;
  //      bVal = row & 0xFF;
  //      inputPixels[offset] = bVal;
  //    }
  //
  //    for (int col = 1; col < width; col++) {
  //      int offset = (row * width) + col;
  //      bVal += 1;
  //      inputPixels[offset] = bVal;
  //    }
  //  }
  
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
      
      blockVec.resize(blockDim * blockDim);
      memcpy(blockVec.data(), inPrefixBytesPtr, blockDim * blockDim * sizeof(uint8_t));
      inPrefixBytesPtr += (blockDim * blockDim);
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
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec);
  
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
  XCTAssert(inputPixelsVec != blockiReorderedVec, @"blocki reordered pixels");
  //XCTAssert(blockiOptimalKTableVec != blockOptimalKTableVec, @"same k values");
  
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
  uint8_t *decodedS32Pixels = decodedS32PixelsVec.data();
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32Pixels,
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((0)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32Pixels[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32Pixels[i];
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
  
  // Encode bytes as rice codes and then decode with software impl like compute shader
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    memset(decodedPixels32Vec.data(), 0xFF, decodedPixels32Vec.size() * sizeof(uint32_t));
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    uint8_t *blockOptimalKTable = halfBlockOptimalKTableVec.data();
    int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
    
    riceEncodedVec = encode(blockSymbols,
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
    
    vector<uint32_t> bitOffsetsEveryHalfBlock = generateBitOffsets(blockSymbols,
                                                                   numBlockSymbols,
                                                                   blockDim,
                                                                   blockOptimalKTable,
                                                                   blockOptimalKTableLen,
                                                                   blockN,
                                                                   (blockDim * blockDim)/2);
    
    assert(bitOffsetsEveryHalfBlock.size() == numOffsetsToCopy);
    
    blockBitStartOffset.resize(numOffsetsToCopy);
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEveryHalfBlock.size(); i++) {
      blockBitStartOffset[i] = bitOffsetsEveryHalfBlock[i];
    }
    
    // Use reordered k table that was rearranged into big block order
    
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
                                           blockBitStartOffset.data(),
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    memcpy(decodedBytesVec.data(), decodedPixels32, width*height);
    uint8_t *pixels8 = decodedBytesVec.data();
    
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
        XCTAssert(bval == expected, @"bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
      }
    }
    
    // Emit blocki as 32 bit values
    
    vector<uint32_t> blockiVec;
    blockiVec.resize(width*4*height);
    uint32_t *blockiVecPtr = blockiVec.data();
    memset(blockiVecPtr, 0xFF, width*4*height);
    
    for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
      for (int tid = 0; tid < 32; tid++) {
        kernel_render_rice_typed<blockDim>(NULL,
                                           riceRenderUniform,
                                           blockBitStartOffset.data(),
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedBlocki,
                                           bigBlocki,
                                           tid,
                                           blockiVecPtr);
      }
    }
    
    if ((0)) {
      printf("blocki order:\n");
      
      uint32_t *ptr = blockiVec.data();
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int blocki = ptr[offset];
          printf("%3d, ", blocki);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
  }
  
  // ----------------------------
  
  // Start Metal config
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  MetalRice2RenderContext *mRenderContext = [[MetalRice2RenderContext alloc] init];
  
  mRenderContext.computeKernelFunction = @"kernel_render_rice2";
  
  [mRenderContext setupRenderPipelines:mrc];
  
  MetalRice2RenderFrame *mRenderFrame = [[MetalRice2RenderFrame alloc] init];
  
  const int totalNumberOfBytes = width * height;
  
  assert((blockN * blockDim * blockDim) == totalNumberOfBytes);
  
  CGSize renderSize = CGSizeMake(width, height);
  CGSize blockSize = CGSizeMake(blockDim, blockDim);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  {
    // Copy/Read compresed input (prefix bits)
    
    const uint32_t *in32Ptr = (const uint32_t *) riceEncodedVec.data();
    const uint32_t inNumBytes = (uint32_t) riceEncodedVec.size();
    
    [mRenderContext ensureBitsBuffCapacity:mrc
                                  numBytes:inNumBytes
                               renderFrame:mRenderFrame];
    
    assert(inNumBytes == mRenderFrame.bitsBuff.length);
    memcpy(mRenderFrame.bitsBuff.contents, in32Ptr, inNumBytes);
  }
  
  {
    // RicePrefixRenderUniform
    
    assert(mRenderFrame.riceRenderUniform.length == sizeof(RiceRenderUniform));
    
    RiceRenderUniform & riceRenderUniform = *((RiceRenderUniform*) mRenderFrame.riceRenderUniform.contents);
    
    assert(((numBlocksInWidth * numBlocksInHeight) % 16) == 0); // Must be a multiple of 16 small blocks
    
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  }

  {
    // Copy block start bit table
    
    uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
    assert(blockBitStartOffset.size() == numOffsetsToCopy);
    assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
    
    for (int i = 0; i < blockBitStartOffset.size(); i++) {
      uint32_t bitOffset = blockBitStartOffset[i];
      bitOffsetTableOutPtr[i] = bitOffset;
    }
  }
  
  // Copy K table
  
  {
    // Use reordered k table that was rearranged into big block order
    
    uint8_t * blockOptimalKTable = blockiOptimalKTableVec.data();
    uint32_t blockOptimalKTableLen = (int) blockiOptimalKTableVec.size();
    
    assert(mRenderFrame.blockOptimalKTable.length == blockOptimalKTableLen);
    memcpy(mRenderFrame.blockOptimalKTable.contents, blockOptimalKTable, blockOptimalKTableLen);
    
    if (0)
    {
      NSLog(@"kTable: %d", blockOptimalKTableLen);
      
      uint8_t *ptr = (uint8_t *) mRenderFrame.blockOptimalKTable.contents;
      
      for (int i = 0; i < blockOptimalKTableLen; i++) {
        int val = ptr[i];
        printf("%3d\n", val);
        fflush(stdout);
      }
      
      printf("done\n");
    }
  }
  
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderRice:mrc
               commandBuffer:commandBuffer
                 renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (0)
  {
    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
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
  
  // Compare output bytes in image order
  
  {
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *outputPrefixBytesPtr = (uint8_t *) outputData.bytes;
    
    // Image order original bytes
    uint8_t *expectedBytesPtr = inputImageOrderPixels;
    
    int same = 1;
    
    if (1)
    {
      int numMismatched = 0;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint8_t outputVal = outputPrefixBytesPtr[offset];
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
    
    NSLog(@"validated %d bytes", (int)width*height);
  }
  
  // Assume the above is working, run the decode process over and over
  // to get accurate timing results
  
  [self measureBlock:^{
    // Get a metal command buffer, render compute invocation into it
    
    CFTimeInterval start = CACurrentMediaTime();
    
    id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
    
#if defined(DEBUG)
    assert(commandBuffer);
#endif // DEBUG
    
    commandBuffer.label = @"XCTestRenderCommandBuffer";
    
    {
      // Copy into blockOffsetTableBuff
      
      uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
      assert(blockBitStartOffset.size() == numOffsetsToCopy);
      assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
      
      for (int i = 0; i < blockBitStartOffset.size(); i++) {
        uint32_t bitOffset = blockBitStartOffset[i];
        bitOffsetTableOutPtr[i] = bitOffset;
      }
    }
    
    // Put the code you want to measure the time of here.
    
    [mRenderContext renderRice:mrc
                 commandBuffer:commandBuffer
                   renderFrame:mRenderFrame];
    
    // Wait for commands to be rendered
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    CFTimeInterval stop = CACurrentMediaTime();
    
    NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  }];
  
  return;
}

// Compare blocki for simulated shader output to Metal shader at 2048x2048

- (void)testRiceRender2048x2048_k0_blocki {
  
  const int constK = 0;
  
  const int blockDim = 8;
  const int blockiDim = 4;
  
  const int width = 64 * 32;
  const int height = 64 * 32;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / 32;
  const int numBigBlocksInHeight = height / 32;
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  const int numOffsetsToCopy = (numBlocksInWidth * numBlocksInHeight * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec;
  inputPixelsVec.resize(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec;
  inputImageOrderPixelsVec.resize(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec;
  outputPixelsVec.resize(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint32_t> blockiFromShader;
  
  int over = 1;
  
  vector<uint32_t> blockBitStartOffset;
  vector<uint8_t> riceEncodedVec;
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  memset(blockOptimalKTableVec.data(), constK, (int)blockOptimalKTableVec.size());
  
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
      
      blockVec.resize(blockDim * blockDim);
      memcpy(blockVec.data(), inPrefixBytesPtr, blockDim * blockDim * sizeof(uint8_t));
      inPrefixBytesPtr += (blockDim * blockDim);
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
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec);
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixels;
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  block_s32_format_block_layout(inputPixelsPtr,
                                outputPixels,
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr);
  
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
  
  vector<uint8_t> decodedPixelsVec;
  decodedPixelsVec.resize(width * height);
  uint8_t *decodedPixels = decodedPixelsVec.data();
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedPixels,
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((0)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedPixels[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Encode bytes as rice codes and then decode with software impl like compute shader
  
  {
    vector<uint32_t> decodedBlockiVec(width*height);
    uint32_t *decodedBlocki = decodedBlockiVec.data();
    memset(decodedBlocki, 0xFF, decodedBlockiVec.size() * sizeof(uint32_t));
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Render blocki
    
    for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
      if ((0)) {
        printf("render bigBlocki %d\n", bigBlocki);
      }
      
      for (int tid = 0; tid < 32; tid++) {
        kernel_render_rice_typed<blockDim>(NULL,
                                           riceRenderUniform,
                                           NULL,
                                           NULL,
                                           NULL,
                                           RenderRiceTypedBlocki,
                                           bigBlocki,
                                           tid,
                                           decodedBlockiVec.data());
      }
    }
    
    // Save rendered blocki values
    
    if ((0)) {
      printf("blocki rendered:\n");
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint32_t blocki = decodedBlockiVec[offset];
          printf("%3d, ", blocki);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    blockiFromShader = decodedBlockiVec;
  }
  
  // ----------------------------
  
  // Start Metal config
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  MetalRice2RenderContext *mRenderContext = [[MetalRice2RenderContext alloc] init];
  
  mRenderContext.computeKernelFunction = @"kernel_render_rice2_blocki";
  mRenderContext.computeKernelPassArg32 = TRUE;
  
  [mRenderContext setupRenderPipelines:mrc];
  
  MetalRice2RenderFrame *mRenderFrame = [[MetalRice2RenderFrame alloc] init];
  
  const int totalNumberOfBytes = width * height;
  
  assert((blockN * blockDim * blockDim) == totalNumberOfBytes);
  
  CGSize renderSize = CGSizeMake(width, height);
  CGSize blockSize = CGSizeMake(blockDim, blockDim);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  {
    // Copy/Read compresed input (prefix bits)
    
    const uint32_t *in32Ptr = (const uint32_t *) riceEncodedVec.data();
    const uint32_t inNumBytes = (uint32_t) riceEncodedVec.size();
    
    [mRenderContext ensureBitsBuffCapacity:mrc
                                  numBytes:inNumBytes
                               renderFrame:mRenderFrame];
    
    assert(inNumBytes == mRenderFrame.bitsBuff.length);
    memcpy(mRenderFrame.bitsBuff.contents, in32Ptr, inNumBytes);
  }
  
  {
    // RicePrefixRenderUniform
    
    assert(mRenderFrame.riceRenderUniform.length == sizeof(RiceRenderUniform));
    
    RiceRenderUniform & riceRenderUniform = *((RiceRenderUniform*) mRenderFrame.riceRenderUniform.contents);
    
    assert(((numBlocksInWidth * numBlocksInHeight) % 16) == 0); // Must be a multiple of 16 small blocks
    
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  }
  
//  {
//    // Copy block start bit table
//    
//    uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
//    assert(blockBitStartOffset.size() == numOffsetsToCopy);
//    assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
//    
//    for (int i = 0; i < blockBitStartOffset.size(); i++) {
//      uint32_t bitOffset = blockBitStartOffset[i];
//      bitOffsetTableOutPtr[i] = bitOffset;
//    }
//  }
  
  // Copy K table
  
  {
    const uint8_t *kTable = (const uint8_t *) blockOptimalKTableVec.data();
    const uint32_t kTableNumBytes = (uint32_t) blockOptimalKTableVec.size();
    
    assert(mRenderFrame.blockOptimalKTable.length == kTableNumBytes);
    memcpy(mRenderFrame.blockOptimalKTable.contents, kTable, kTableNumBytes);
    
    if (0)
    {
      NSLog(@"kTable: %d", kTableNumBytes);
      
      uint8_t *ptr = (uint8_t *) mRenderFrame.blockOptimalKTable.contents;
      
      for (int i = 0; i < kTableNumBytes; i++) {
        int val = ptr[i];
        printf("%3d\n", val);
        fflush(stdout);
      }
      
      printf("done\n");
    }
  }
  
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderRice:mrc
               commandBuffer:commandBuffer
                 renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (0)
  {
    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%2d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  // Capture blocki output and validate against blockiFromShader
  
  if (mRenderContext.computeKernelPassArg32 == TRUE) {
    id<MTLBuffer> out32Buff = mRenderFrame.out32Buff;
    
    vector<uint32_t> capturedBlocki(width * height);
    
    assert((capturedBlocki.size() * sizeof(uint32_t)) == out32Buff.length);
    memcpy(capturedBlocki.data(), out32Buff.contents, out32Buff.length);
    
    if ((0)) {
      printf("blocki rendered:\n");
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint32_t blocki = capturedBlocki[offset];
          printf("%3d, ", blocki);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    // Compare each blocki value
    
    if (1)
    {
      printf("validate blocki output: %dx%d\n", width, height);
      
      int same = 1;
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int softBlocki = blockiFromShader[offset];
          int metalBlocki = capturedBlocki[offset];
          if (softBlocki != metalBlocki) {
            printf("blocki output (%3d,%3d) mismatch : output != expected : %d != %d\n", col, row, softBlocki, metalBlocki);
            same = 0;
          }
        }
      }
      
      XCTAssert(same == 1, @"same");
    }
    
  }
  
  return;
}

// Compare 1/2 block bit start offsets emitted by software shader vs Metal shader

- (void)testRiceRender2048x2048_k0_block_bit_offset {
  
  const int constK = 0;
  
  const int blockDim = 8;
  const int blockiDim = 4;
  
  const int width = 64 * 32;
  const int height = 64 * 32;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / 32;
  const int numBigBlocksInHeight = height / 32;
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  const int numOffsetsToCopy = (numBlocksInWidth * numBlocksInHeight * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputPixelsVec;
  inputPixelsVec.resize(width*height);
  uint8_t *inputPixels = inputPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec;
  inputImageOrderPixelsVec.resize(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec;
  outputPixelsVec.resize(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint32_t> blockHalfBlockBitOffsetsFromShader;
  
  int over = 1;
  
  vector<uint32_t> blockBitStartOffset;
  vector<uint8_t> riceEncodedVec;
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  
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
      
      blockVec.resize(blockDim * blockDim);
      memcpy(blockVec.data(), inPrefixBytesPtr, blockDim * blockDim * sizeof(uint8_t));
      inPrefixBytesPtr += (blockDim * blockDim);
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
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec);
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputPixels;
  uint32_t *blockiPtr = blockiLookupVec.data();
  
  block_s32_format_block_layout(inputPixelsPtr,
                                outputPixels,
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr);
  
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
  
  vector<uint8_t> decodedPixelsVec;
  decodedPixelsVec.resize(width * height);
  uint8_t *decodedPixels = decodedPixelsVec.data();
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedPixels,
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((0)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedPixels[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Encode bytes as rice codes and then decode with software impl like compute shader
  
  {
    vector<uint32_t> decodedBlockiVec(width*height);
    uint32_t *decodedBlocki = decodedBlockiVec.data();
    memset(decodedBlocki, 0xFF, decodedBlockiVec.size() * sizeof(uint32_t));
    
    memset(blockOptimalKTableVec.data(), constK, (int)blockOptimalKTableVec.size());
    
    vector<uint32_t> inoutBlockBitOffsetTableVec;
    inoutBlockBitOffsetTableVec.resize(blockN * 2);
//    uint32_t *inoutBlockBitOffsetTable = inoutBlockBitOffsetTableVec.data();
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
//    for (int i = 0; i < bitOffsetsEvery16.size(); i++) {
//      inoutBlockBitOffsetTable[i] = bitOffsetsEvery16[i];
//
//      if ((0)) {
//        printf("inoutBlockBitOffsetTable[%5d] = %3d\n", i, inoutBlockBitOffsetTable[i]);
//      }
//    }
    
    // Render bit offset for each blocki
    
    for (int bigBlocki = 0; bigBlocki < (numBigBlocksInWidth * numBigBlocksInHeight); bigBlocki++) {
      if ((1)) {
        printf("render bigBlocki %d\n", bigBlocki);
      }
      
      for (int tid = 0; tid < 32; tid++) {
        kernel_render_rice_typed<blockDim>(NULL,
                                           riceRenderUniform,
                                           NULL,
                                           NULL,
                                           NULL,
                                           RenderRiceTypedBlockBitOffset,
                                           bigBlocki,
                                           tid,
                                           decodedBlockiVec.data());
      }
    }
    
    // Save rendered blocki values
    
    if ((0)) {
      printf("blocki rendered:\n");
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint32_t blocki = decodedBlockiVec[offset];
          printf("%3d, ", blocki);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    blockHalfBlockBitOffsetsFromShader = decodedBlockiVec;
  }
  
  // ----------------------------
  
  // Start Metal config
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  MetalRice2RenderContext *mRenderContext = [[MetalRice2RenderContext alloc] init];
  
  mRenderContext.computeKernelFunction = @"kernel_render_rice2_block_bit_offset";
  mRenderContext.computeKernelPassArg32 = TRUE;
  
  [mRenderContext setupRenderPipelines:mrc];
  
  MetalRice2RenderFrame *mRenderFrame = [[MetalRice2RenderFrame alloc] init];
  
  const int totalNumberOfBytes = width * height;
  
  assert((blockN * blockDim * blockDim) == totalNumberOfBytes);
  
  CGSize renderSize = CGSizeMake(width, height);
  CGSize blockSize = CGSizeMake(blockDim, blockDim);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  {
    // Copy/Read compresed input (prefix bits)
    
    const uint32_t *in32Ptr = (const uint32_t *) riceEncodedVec.data();
    const uint32_t inNumBytes = (uint32_t) riceEncodedVec.size();
    
    [mRenderContext ensureBitsBuffCapacity:mrc
                                  numBytes:inNumBytes
                               renderFrame:mRenderFrame];
    
    assert(inNumBytes == mRenderFrame.bitsBuff.length);
    memcpy(mRenderFrame.bitsBuff.contents, in32Ptr, inNumBytes);
  }
  
  {
    // RicePrefixRenderUniform
    
    assert(mRenderFrame.riceRenderUniform.length == sizeof(RiceRenderUniform));
    
    RiceRenderUniform & riceRenderUniform = *((RiceRenderUniform*) mRenderFrame.riceRenderUniform.contents);
    
    assert(((numBlocksInWidth * numBlocksInHeight) % 16) == 0); // Must be a multiple of 16 small blocks
    
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  }
  
//  {
//    // Copy block start bit table
//
//    uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
//    assert(blockBitStartOffset.size() == numOffsetsToCopy);
//    assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
//
//    for (int i = 0; i < blockBitStartOffset.size(); i++) {
//      uint32_t bitOffset = blockBitStartOffset[i];
//      bitOffsetTableOutPtr[i] = bitOffset;
//    }
//  }
  
  // Copy K table
  
  {
    const uint8_t *kTable = (const uint8_t *) blockOptimalKTableVec.data();
    const uint32_t kTableNumBytes = (uint32_t) blockOptimalKTableVec.size();
    
    assert(mRenderFrame.blockOptimalKTable.length == kTableNumBytes);
    memcpy(mRenderFrame.blockOptimalKTable.contents, kTable, kTableNumBytes);
    
    if (0)
    {
      NSLog(@"kTable: %d", kTableNumBytes);
      
      uint8_t *ptr = (uint8_t *) mRenderFrame.blockOptimalKTable.contents;
      
      for (int i = 0; i < kTableNumBytes; i++) {
        int val = ptr[i];
        printf("%3d\n", val);
        fflush(stdout);
      }
      
      printf("done\n");
    }
  }
  
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderRice:mrc
               commandBuffer:commandBuffer
                 renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (0)
  {
    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%2d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }
  
  // Capture blocki output and validate against blockiFromShader
  
  if (mRenderContext.computeKernelPassArg32 == TRUE) {
    id<MTLBuffer> out32Buff = mRenderFrame.out32Buff;
    
    vector<uint32_t> capturedOffsets(width * height);
    
    assert((capturedOffsets.size() * sizeof(uint32_t)) == out32Buff.length);
    memcpy(capturedOffsets.data(), out32Buff.contents, out32Buff.length);
    
    if ((0)) {
      printf("block bit offset rendered:\n");
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint32_t bitOffset = capturedOffsets[offset];
          printf("%3d, ", bitOffset);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    // Compare each blocki value
    
    if (1)
    {
      printf("validate bit offset output: %dx%d\n", width, height);
      
      int same = 1;
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int softOffset = blockHalfBlockBitOffsetsFromShader[offset];
          int metalOffset = capturedOffsets[offset];
          if (softOffset != metalOffset) {
            printf("half block start bit offset output (%3d,%3d) mismatch : output != expected : %d != %d\n", col, row, softOffset, metalOffset);
            same = 0;
          }
        }
      }
      
      XCTAssert(same == 1, @"same");
    }
    
  }
  
  return;
}

// Render example bridge image

- (void)testRiceRenderExampleImageBridge {
  
  const int blockDim = 8;
  const int blockiDim = 4;
  
  const int width = 64 * 32;
  const int height = 48 * 32;
  
  const int numBlocksInWidth = width / blockDim;
  const int numBlocksInHeight = height / blockDim;
  
  const int numBigBlocksInWidth = width / (blockDim * blockiDim);
  const int numBigBlocksInHeight = height / (blockDim * blockiDim);
  
  const int blockN = (width * height) / (blockDim * blockDim);
  
  const int numOffsetsToCopy = (blockN * 2);
  
  // 8x8 blocks
  
  vector<uint8_t> inputBlockOrderPixelsVec;
  inputBlockOrderPixelsVec.resize(width*height);
  uint8_t *inputBlockOrderPixels = inputBlockOrderPixelsVec.data();
  
  vector<uint8_t> inputImageOrderPixelsVec;
  inputImageOrderPixelsVec.resize(width*height);
  uint8_t *inputImageOrderPixels = inputImageOrderPixelsVec.data();
  
  vector<uint8_t> outputPixelsVec;
  outputPixelsVec.resize(width*height);
  uint8_t *outputPixels = outputPixelsVec.data();
  
  vector<uint32_t> blockBitStartOffset;
  vector<uint8_t> riceEncodedVec;
  
  vector<uint8_t> blockOptimalKTableVec(blockN + 1);
  blockOptimalKTableVec[blockN-1] = 0;
  
  // Grab input pixels from PNG source
  
  NSString *resFilename = @"BigBridge.png";
  NSString* path = [[NSBundle mainBundle] pathForResource:resFilename ofType:nil];
  NSAssert(path, @"path is nil");
  
  UIImage *img = [UIImage imageWithContentsOfFile:path];
  assert(img);

  assert((int)img.size.width == width);
  assert((int)img.size.height == height);
  
  NSData *inputData = [self.class convertImageToGrayScale:img];
  
  memcpy(inputImageOrderPixels, inputData.bytes, inputData.length);
  
  NSMutableData *blockOptimalKTableData = [NSMutableData data];
  
  NSMutableData *outBlockOrderSymbolsData = [NSMutableData data];
  
  {
    // Dual stage block delta encoding, calculate deltas based on 32x32 blocks
    // and then split into 8x8 rice opt blocks.
    
    [Rice blockDeltaEncoding2Stage:inputImageOrderPixelsVec.data()
                        inNumBytes:(int)inputImageOrderPixelsVec.size()
                             width:width
                            height:height
                        blockWidth:numBigBlocksInWidth
                       blockHeight:numBigBlocksInHeight
              outEncodedBlockBytes:outBlockOrderSymbolsData];
    
    assert(outBlockOrderSymbolsData.length == (numBigBlocksInWidth * numBigBlocksInHeight * RICE_LARGE_BLOCK_DIM * RICE_LARGE_BLOCK_DIM));
    
    const uint8_t *outBlockOrderSymbolsPtr = (uint8_t *) outBlockOrderSymbolsData.mutableBytes;
    
    // Copy to block order input

    assert(inputBlockOrderPixelsVec.size() == outBlockOrderSymbolsData.length);
    memcpy(inputBlockOrderPixels, outBlockOrderSymbolsPtr, outBlockOrderSymbolsData.length);
    
    int outNumBaseValues = 0;
    int outNumBlockValues = (int)outBlockOrderSymbolsData.length;
    
    [Rice optRiceK:outBlockOrderSymbolsData
blockOptimalKTableData:blockOptimalKTableData
     numBaseValues:&outNumBaseValues
    numBlockValues:&outNumBlockValues];
    
    memcpy(blockOptimalKTableVec.data(), blockOptimalKTableData.bytes, blockOptimalKTableData.length);
  }
  
  // Generate blocki ordering
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec);
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  int numSegments = 32;
  
  uint8_t *inputPixelsPtr = inputBlockOrderPixels;
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
  uint8_t *decodedS32Pixels = decodedS32PixelsVec.data();
  
  block_s32_flatten_block_layout(outputPixels,
                                 decodedS32Pixels,
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((0)) {
    printf("interleaved block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, numSegments);
      
      for (int i = 0; i < numSegments; i++) {
        int bVal = decodedS32Pixels[offset++];
        printf("%2d, ", bVal);
      }
      printf("\n");
    }
  }
  
  // Validate output flat block order against original block input order
  
  {
    int numFails = 0;
    
    for (int i = 0; i < (width*height); i++) {
      uint8_t bval = decodedS32Pixels[i];
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
  
  // Encode bytes as rice codes and then decode with software impl like compute shader
  
  {
    int width4 = width / sizeof(uint32_t);
    vector<uint32_t> decodedPixels32Vec(width4*height);
    memset(decodedPixels32Vec.data(), 0xFF, decodedPixels32Vec.size() * sizeof(uint32_t));
    uint32_t *decodedPixels32 = decodedPixels32Vec.data();
    
    // Encode bytes as rice bits
    
    int numBlockSymbols = blockN * blockDim * blockDim;
    const uint8_t *blockSymbols = outputPixels;
    
    uint8_t *blockOptimalKTable = halfBlockOptimalKTableVec.data();
    int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
    
    riceEncodedVec = encode(blockSymbols,
                            numBlockSymbols,
                            blockDim,
                            blockOptimalKTable,
                            blockOptimalKTableLen,
                            blockN);
    
    printf("encode %d bytes as %d rice encoded bytes\n", numBlockSymbols, (int)riceEncodedVec.size());
    
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
      XCTAssert(cmp == 0);
      
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
    
    vector<uint32_t> bitOffsetsEveryHalfBlock = generateBitOffsets(blockSymbols,
                                                                   numBlockSymbols,
                                                                   blockDim,
                                                                   blockOptimalKTable,
                                                                   blockOptimalKTableLen,
                                                                   blockN,
                                                                   (blockDim * blockDim)/2);
    
    assert(bitOffsetsEveryHalfBlock.size() == numOffsetsToCopy);
    
    blockBitStartOffset.resize(numOffsetsToCopy);
    
    RiceRenderUniform riceRenderUniform;
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
    riceRenderUniform.numBlocksEachSegment = 1;
    
    // Copy bit offsets
    
    for (int i = 0; i < bitOffsetsEveryHalfBlock.size(); i++) {
      blockBitStartOffset[i] = bitOffsetsEveryHalfBlock[i];
    }
    
    // Use reordered k table that was rearranged into big block order
    
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
                                           blockBitStartOffset.data(),
                                           prefixBitsWordPtr,
                                           blockOptimalKTable,
                                           RenderRiceTypedDecode,
                                           bigBlocki,
                                           tid,
                                           NULL);
      }
    }
    
    vector<uint8_t> decodedBytesVec(width*height);
    memcpy(decodedBytesVec.data(), decodedPixels32, width*height);
    uint8_t *decodedBytes = decodedBytesVec.data();
    
    if ((0)) {
      printf("decoded image order:\n");
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          int bVal = decodedBytesVec[offset];
          printf("%3d, ", bVal);
        }
        printf("\n");
      }
      
      printf("\n");
    }
    
    // At this point image data is written as deltas in original image order,
    // need to now process into 32x32 blocks and reverse the deltas
    
    {
      // Reorder image order values to 32x32 block order (without deltas)
      
      NSMutableData *imageOrderDeltas2Data = [NSMutableData data];
      
      NSMutableData *imageOrderSymbolsData = [NSMutableData data];
      [imageOrderSymbolsData setLength:width*height];
      
      [Rice blockEncoding:decodedBytes
               inNumBytes:(int)width*height
                    width:width
                   height:height
               blockWidth:numBigBlocksInWidth
              blockHeight:numBigBlocksInHeight
     outEncodedBlockBytes:imageOrderDeltas2Data];

      XCTAssert(imageOrderDeltas2Data.length == (numBlocksInWidth * numBlocksInHeight * blockDim * blockDim));
      
      // Undo 32x32 block order and reverse deltas
      
      [Rice blockDeltaDecode:(int)imageOrderDeltas2Data.length
           blockOrderSymbols:(uint8_t*)imageOrderDeltas2Data.mutableBytes
           imageOrderSymbols:(uint8_t*)imageOrderSymbolsData.mutableBytes
                       width:width
                      height:height
                  blockWidth:numBigBlocksInWidth
                 blockHeight:numBigBlocksInHeight];
      
      int cmp = memcmp(inputImageOrderPixels, imageOrderSymbolsData.mutableBytes, width*height);
      XCTAssert(cmp == 0);
    }
    
    if (0)
    {
      int numFails = 0;
      
      for (int i = 0; i < (width*height); i++) {
        uint8_t bval = decodedBytesVec[i];
        uint8_t expected = inputImageOrderPixels[i];
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
   
    // Capture bit offsets to a buffer ?
    
    // Every bit value is an increasing value, so a simple diff generates
    // generally small deltas. uint16_t would hold em, bit might be able
    // to even use uint8_t is a prediction and delta kind of approach were
    // used. Might be better to just encode as 2 planes using 16 bit deltas
    // and go with that.
    
    //vector<uint32_t> capturedBitOffsets = bitOffsetsEveryHalfBlock;
    
    
    int prevOffset = -1;
    int minDelta = 0xFFFF;
    int maxDelta = 0;
    
    for (int i = 0; i < bitOffsetsEveryHalfBlock.size(); i++) {
      int bitOffset = bitOffsetsEveryHalfBlock[i];
      assert(bitOffset > prevOffset);
      int bitDelta = bitOffset - prevOffset;
      if (bitDelta < minDelta) {
        minDelta = bitDelta;
      }
      if (bitDelta > maxDelta) {
        maxDelta = bitDelta;
      }
      //printf("bitDelta %d\n", bitDelta);
      prevOffset = bitOffset;
    }
    
    printf("minDelta %d : maxDelta %d\n", minDelta, maxDelta);
    
    vector<uint32_t> deltas32 = encodePlusDelta(bitOffsetsEveryHalfBlock);
    
    vector<uint16_t> deltas16;
    deltas16.reserve(bitOffsetsEveryHalfBlock.size());
    
    // FIXME: encode as planar bytes in 2 phases for best RLE compression

    for ( uint32_t delta32 : deltas32 ) {
      assert(delta32 < 0xFFFF);
      deltas16.push_back((uint16_t) delta32);
    }
    
    printf("deltas16 is %d bytes\n", (int)deltas16.size());
    
    NSData *deltas16Data = [NSData dataWithBytes:deltas16.data() length:deltas16.size()*sizeof(uint16_t)];
    
    if ((0)) {
      NSString *tmpDir = NSTemporaryDirectory();
      NSString *path = [tmpDir stringByAppendingPathComponent:@"deltas_every_half_block.halfwords"];
      BOOL worked = [deltas16Data writeToFile:path atomically:TRUE];
      assert(worked);
      NSLog(@"wrote %@ as %d bytes", path, (int)deltas16Data.length);
    }
  }
  
  // ----------------------------
  
  // Start Metal config
  
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  
  MetalRenderContext *mrc = [[MetalRenderContext alloc] init];
  
  [mrc setupMetal:device];
  
  MetalRice2RenderContext *mRenderContext = [[MetalRice2RenderContext alloc] init];
  
  [mRenderContext setupRenderPipelines:mrc];
  
  MetalRice2RenderFrame *mRenderFrame = [[MetalRice2RenderFrame alloc] init];
  
  const int totalNumberOfBytes = width * height;
  
  assert((blockN * blockDim * blockDim) == totalNumberOfBytes);
  
  CGSize renderSize = CGSizeMake(width, height);
  CGSize blockSize = CGSizeMake(blockDim, blockDim);
  
  [mRenderContext setupRenderTextures:mrc
                           renderSize:renderSize
                            blockSize:blockSize
                          renderFrame:mRenderFrame];
  
  {
    // Copy/Read compresed input (prefix bits)
    
    const uint32_t *in32Ptr = (const uint32_t *) riceEncodedVec.data();
    const uint32_t inNumBytes = (uint32_t) riceEncodedVec.size();
    
    [mRenderContext ensureBitsBuffCapacity:mrc
                                  numBytes:inNumBytes
                               renderFrame:mRenderFrame];
    
    assert(inNumBytes == mRenderFrame.bitsBuff.length);
    memcpy(mRenderFrame.bitsBuff.contents, in32Ptr, inNumBytes);
  }
  
  {
    // RicePrefixRenderUniform
    
    assert(mRenderFrame.riceRenderUniform.length == sizeof(RiceRenderUniform));
    
    RiceRenderUniform & riceRenderUniform = *((RiceRenderUniform*) mRenderFrame.riceRenderUniform.contents);
    
    assert(((numBlocksInWidth * numBlocksInHeight) % 16) == 0); // Must be a multiple of 16 small blocks
    
    riceRenderUniform.numBlocksInWidth = numBlocksInWidth;
    riceRenderUniform.numBlocksInHeight = numBlocksInHeight;
  }
  
  {
    // Copy block start bit table
    
    uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
    assert(blockBitStartOffset.size() == numOffsetsToCopy);
    assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
    
    for (int i = 0; i < blockBitStartOffset.size(); i++) {
      uint32_t bitOffset = blockBitStartOffset[i];
      bitOffsetTableOutPtr[i] = bitOffset;
    }
  }
  
  // Copy K table
  
  {
    // Use reordered k table that was rearranged into big block order
    
    uint8_t * blockOptimalKTable = blockiOptimalKTableVec.data();
    uint32_t blockOptimalKTableLen = (int) blockiOptimalKTableVec.size();
    
    assert(mRenderFrame.blockOptimalKTable.length == blockOptimalKTableLen);
    memcpy(mRenderFrame.blockOptimalKTable.contents, blockOptimalKTable, blockOptimalKTableLen);
    
    if (0)
    {
      NSLog(@"kTable: %d", blockOptimalKTableLen);
      
      uint8_t *ptr = (uint8_t *) mRenderFrame.blockOptimalKTable.contents;
      
      for (int i = 0; i < blockOptimalKTableLen; i++) {
        int val = ptr[i];
        printf("%3d\n", val);
        fflush(stdout);
        
        if (i > 100) {
          break;
        }
      }
      
      printf("done\n");
    }
  }
  
  id<MTLTexture> outputTexture = mRenderFrame.outputTexture;
  
  // Get a metal command buffer, render compute invocation into it
  
  CFTimeInterval start = CACurrentMediaTime();
  
  id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
  
#if defined(DEBUG)
  assert(commandBuffer);
#endif // DEBUG
  
  commandBuffer.label = @"XCTestRenderCommandBuffer";
  
  // Put the code you want to measure the time of here.
  
  [mRenderContext renderRice:mrc
               commandBuffer:commandBuffer
                 renderFrame:mRenderFrame];
  
  // Wait for commands to be rendered
  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  
  CFTimeInterval stop = CACurrentMediaTime();
  
  NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  
  if (0)
  {
    NSLog(@"outputTexture: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
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

  if (1)
  {
    NSLog(@"outputTexture first 32: %d x %d", width, height);
    
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *ptr = (uint8_t *) outputData.bytes;
    
    for (int row = 0; row < 32; row++) {
      for (int col = 0; col < 32; col++) {
        int offset = (row * width) + col;
        int val = ptr[offset];
        printf("%3d ", val);
      }
      printf("\n");
      fflush(stdout);
    }
    
    printf("done\n");
  }

  
  // Compare output bytes in image order
  
  {
    NSData *outputData = [mrc getBGRATextureAsBytes:outputTexture];
    uint8_t *outputPrefixBytesPtr = (uint8_t *) outputData.bytes;
    
    // Image order original bytes
    uint8_t *expectedBytesPtr = inputImageOrderPixels;
    
    int same = 1;
    
    if (1)
    {
      int numMismatches = 0;
      
      printf("validate outputTexture: %dx%d\n", width, height);
      
      for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
          int offset = (row * width) + col;
          uint8_t outputVal = outputPrefixBytesPtr[offset];
          uint8_t expectedVal = expectedBytesPtr[offset];
          if (outputVal != expectedVal && numMismatches < 10) {
            printf("output[%3d,%3d] mismatch : output != expected : %d != %d\n", col, row, outputVal, expectedVal);
            same = 0;
            numMismatches += 1;
          }
        }
      }
    }
    
    XCTAssert(same == 1);
    
    NSLog(@"validated %d bytes", (int)width*height);
  }
  
  // Assume the above is working, run the decode process over and over
  // to get accurate timing results
  
  [self measureBlock:^{
    // Get a metal command buffer, render compute invocation into it
    
    CFTimeInterval start = CACurrentMediaTime();
    
    id <MTLCommandBuffer> commandBuffer = [mrc.commandQueue commandBuffer];
    
#if defined(DEBUG)
    assert(commandBuffer);
#endif // DEBUG
    
    commandBuffer.label = @"XCTestRenderCommandBuffer";
    
    {
      // Copy into blockOffsetTableBuff
      
      uint32_t *bitOffsetTableOutPtr = (uint32_t *) mRenderFrame.blockOffsetTableBuff.contents;
      assert(blockBitStartOffset.size() == numOffsetsToCopy);
      assert(mRenderFrame.blockOffsetTableBuff.length == (numOffsetsToCopy * sizeof(uint32_t)));
      
      for (int i = 0; i < blockBitStartOffset.size(); i++) {
        uint32_t bitOffset = blockBitStartOffset[i];
        bitOffsetTableOutPtr[i] = bitOffset;
      }
    }
    
    // Put the code you want to measure the time of here.
    
    [mRenderContext renderRice:mrc
                 commandBuffer:commandBuffer
                   renderFrame:mRenderFrame];
    
    // Wait for commands to be rendered
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    
    CFTimeInterval stop = CACurrentMediaTime();
    
    NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  }];
  
  return;
}

+ (NSData*) convertImageToGrayScale:(UIImage *)image
{
  // Create image rectangle with current image width/height
  CGRect imageRect = CGRectMake(0, 0, image.size.width, image.size.height);
  
  // Grayscale color space
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
  
  // Create bitmap content with current image size and grayscale colorspace
  CGContextRef context = CGBitmapContextCreate(nil, image.size.width, image.size.height, 8, 0, colorSpace, kCGImageAlphaNone);
  
  // Draw image into current context, with specified rectangle
  // using previously defined context (with grayscale colorspace)
  CGContextDrawImage(context, imageRect, [image CGImage]);
  
  // Create bitmap image info from pixel data in current context
  //CGImageRef imageRef = CGBitmapContextCreateImage(context);
  
  // Create a new UIImage object
  //UIImage *newImage = [UIImage imageWithCGImage:imageRef];
  
  NSMutableData *mData = [NSMutableData dataWithBytes:CGBitmapContextGetData(context) length:image.size.width*image.size.height];
  
  // Release colorspace, context and bitmap information
  CGColorSpaceRelease(colorSpace);
  CGContextRelease(context);
  //CFRelease(imageRef);
  
  // Return the new grayscale image
  //return newImage;
  
  return [NSData dataWithData:mData];
}

@end

