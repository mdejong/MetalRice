//
//  RiceDecodeBlocksImpl.hpp
//  MetalRice
//
//  Created by Mo DeJong on 10/20/18.
//  Copyright © 2018 Apple. All rights reserved.
//

#include <cstdint>
#include <vector>

#import "AAPLShaderTypes.h"
#import "block.hpp"
#import "block_process.hpp"

using namespace std;

// Decode N symbols and write to pointer location, this impl reads all
// the symbols in the associated stream.

template <typename T, typename R>
void DecodeNPrefixBytes(RiceDecodeBlocks<T, R> & rdb,
                        const int N,
                        const int blockDim,
                        const int numBlocks,
                        uint8_t *outPtr,
                        uint32_t *prefixBlockBitStartOffsetPtr,
                        uint32_t *blockEscapeCountPtr)
{
#if defined(DEBUG)
  assert(N == (blockDim * blockDim * numBlocks));
#endif // DEBUG
  
#if defined(DEBUG)
  int globali = 0;
#endif // DEBUG
  
  for (int blocki = 0; blocki < numBlocks; blocki++) {
    uint32_t numEscapes = 0;
    
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
    prefixBlockBitStartOffsetPtr[blocki] = rdb.totalNumBitsRead;
# if defined(DEBUG)
    printf("blocki %5d : block start at bit offset %5d\n", blocki, prefixBlockBitStartOffsetPtr[blocki]);
# endif // DEBUG
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
    
    for (int i = 0; i < (blockDim * blockDim); i++) {
#if defined(DEBUG)
# if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
      printf("prefixByte[%5d] (bit offset %5d)\n", globali, rdb.totalNumBitsRead);
# endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
#endif // DEBUG
      
      int prefixByte = (int) rdb.parsePrefixByte();
#if defined(DEBUG)
      printf("prefixByte[%5d] = %3d\n", globali, prefixByte);
#endif // DEBUG
      
      if (prefixByte == 17) {
        numEscapes += 1;
      }
      
      *outPtr++ = prefixByte;
      
#if defined(DEBUG)
      globali += 1;
#endif // DEBUG
    }
    
    blockEscapeCountPtr[blocki] = numEscapes;
  }
  
  return;
}

// This decode method reads from a stream that has been segmented into
// 32 substreams as indicated by the bit offset starting location
// for the sub stream and the length.

template <typename T, typename R>
void DecodeNPrefixBytesOneSegmentThread(
                                        const int N,
                                        const int blockDim,
                                        int blocki,
                                        const int numBlocks,
                                        uint8_t *outPtr,
                                        uint32_t *blockEscapeCountPtr,
                                        const uint32_t *in32Ptr,
                                        uint32_t *segmentBlockBitStartOffsetPtr)
{
  // Thread specific bit stream
  RiceDecodeBlocks<T,R> rdb;
  
#if defined(DEBUG)
  assert(N == (blockDim * blockDim * numBlocks));
#endif // DEBUG
  
  outPtr += (blocki * blockDim * blockDim);
  
  // Adjust rdb so that the next read will come from the
  // offset indicated by this block lookup operation.
  
  uint32_t blockBitStartOffset = segmentBlockBitStartOffsetPtr[blocki];
  
  rdb.cachedBits.initBits(in32Ptr, blockBitStartOffset);
  
  // Define starting bit offset after adjusting to first bit for block
  
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
  rdb.totalNumBitsRead = blockBitStartOffset;
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
  
  // Decode N blocks, starting at blocki and ending at blockiMax
  
  int blockiMax = blocki + numBlocks;
  
  for (; blocki < blockiMax; blocki++) {
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
# if defined(DEBUG)
    printf("blocki %5d : block start at bit offset %5d\n", blocki, rdb.totalNumBitsRead);
# endif // DEBUG
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
    
    uint32_t numEscapes = 0;
    
    for (int i = 0; i < (blockDim * blockDim); i++) {
#if defined(DEBUG)
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
      printf("prefixByte[%5d] (bit offset %5d)\n", (blocki * blockDim * blockDim)+i, rdb.totalNumBitsRead);
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
#endif // DEBUG
      
      int prefixByte = (int) rdb.parsePrefixByte();
#if defined(DEBUG)
      printf("block %3d offset %5d block offset %3d : prefixByte %3d\n", blocki, (blocki * blockDim * blockDim)+i, i, prefixByte);
#endif // DEBUG
      
      if (prefixByte == 17) {
        numEscapes += 1;
      }
      
#if defined(DEBUG)
      // In/Out validation of expected sample value
      printf("block %3d offset %5d block offset %3d : expected prefixByte %3d\n", blocki, (blocki * blockDim * blockDim)+i, i, *outPtr);
      if (*outPtr != prefixByte) {
        assert(*outPtr == prefixByte);
      }
#endif // DEBUG
      
      *outPtr++ = prefixByte;
    }
    
    blockEscapeCountPtr[blocki] = numEscapes;
  }
  
  return;
}

// Format blocks of size 8x8 into a custom layout that makes it possible to parse
// input byte values 32 at a time. One parser iteration requires input of 32bit
// offsets into a bit buffer and writes a single block of size 32x32 by collecting
// the next 16 blocks from the stream input. If blockiPtr is not NULL then blocki
// values are looked by by block offset while reading. The blockiReordererKTableVecPtr
// argument can be passed to collect k values after reordering in big block order.
// The blockiReordererKTableHalfVecPtr argument is passed to collect k table values
// into 1/2 blocks in linear order, so that bit encoding can determine the K for each symbol.

static inline
void block_s32_format_block_layout(
                                   const uint8_t *inBlockBytes,
                                   uint8_t *outs32BlockBytes,
                                   const int blockN,
                                   const int blockDim,
                                   const int numSegments,
                                   const uint32_t *blockiPtr,
                                   vector<uint8_t> * blockiReordererVecPtr = nullptr,
                                   vector<uint8_t> * blockiReordererKTableVecPtr = nullptr,
                                   vector<uint8_t> * blockiReordererKTableHalfVecPtr = nullptr,
                                   const int numInterleavedHalfBlocks = 1)
{
  const bool debug = false;
  const bool debugWriteEveryValue = false;
  
  if (debug) {
    printf("block_s32_format_block_layout\n");
  }
  
#if defined(DEBUG)
  memset(outs32BlockBytes, 0xFF, blockN * blockDim * blockDim);
#endif // (DEBUG)
  
  // blockN should be a multiple of 16 with 8x8 blocks
  assert((blockN % (numSegments/2)) == 0);
  
  // Output is in terms of half blocks, the half can be interleaved
  // but output is always a byte append.
  
  uint8_t *outPtr = outs32BlockBytes;
  
  vector<uint8_t> kLookupVec;
  
  if (blockiReordererKTableVecPtr != nullptr) {
    kLookupVec = *blockiReordererKTableVecPtr;
  }
  
  if (blockiReordererKTableHalfVecPtr != nullptr) {
    (*blockiReordererKTableHalfVecPtr).clear();
    (*blockiReordererKTableHalfVecPtr).reserve((blockN * 2) + 1);
  }
  
  for (unsigned int loopBlocki = 0; loopBlocki < blockN; loopBlocki++) {
    int blocki;
    if (blockiPtr) {
      blocki = blockiPtr[loopBlocki];
    } else {
      blocki = loopBlocki;
    }
    
    if (blockiReordererKTableVecPtr != nullptr) {
      int kThisBlocki = kLookupVec[blocki];
      (*blockiReordererKTableVecPtr)[loopBlocki] = kThisBlocki;
    }
    
    if (loopBlocki > 0 && ((loopBlocki % (numSegments/2)) == 0)) {
      if (debug) {
        printf("advance output ptrs before block %3d\n", blocki);
      }
    }
    
    // Append k value for half block vec
    
    if (blockiReordererKTableHalfVecPtr != nullptr) {
      int kThisBlocki = kLookupVec[blocki];
      (*blockiReordererKTableHalfVecPtr).push_back(kThisBlocki);
      (*blockiReordererKTableHalfVecPtr).push_back(kThisBlocki);
    }
    
    // Read the next 32 bytes, write 16 bytes twice with 8x8 blocks
    
    const uint8_t *inBytePtr = &inBlockBytes[blocki * (blockDim * blockDim)];
    
    // Map tid in range (0, 31) into blocki range (0, 15) with 8x8 blocks.

    unsigned int blockiThisBigBlock = (loopBlocki % (numSegments/2)); // range (0, 15)
    unsigned int offset = blockiThisBigBlock * 2; // range (0, 31) w step 2
    
    if (debug) {
      printf("blockiThisBigBlock %3d -> half block tid offset %d\n", blockiThisBigBlock, offset);
    
      if (blockiPtr) {
        printf("block %3d -> %3d\n", loopBlocki, blocki);
      }
      
      printf("block %3d A : input  buffer starting offset %5d\n", blocki, (int)(inBytePtr - inBlockBytes));
      printf("block %3d A : output buffer starting offset %5d\n", blocki, (int)(outPtr - outs32BlockBytes));
    }
    
    for (int i = 0; i < (blockDim * blockDim)/2; i++) {
      uint8_t bVal = *inBytePtr++;
#if defined(DEBUG)
      assert(*outPtr == 0xFF);
#endif // (DEBUG)
      *outPtr = bVal;
      
      if (debugWriteEveryValue) {
        printf("write out[%4d] = %5d\n", (int)(outPtr - outs32BlockBytes), bVal);
      }
      
      if (blockiReordererVecPtr != nullptr) {
        (*blockiReordererVecPtr).push_back(bVal);
      }
      
      outPtr++;
    }
    
    if (debug) {
      printf("block %3d A : update output buffer offset %5d\n", blocki, (int)(outPtr - outs32BlockBytes));
    }
    
    offset += 1;
    
    if (debug) {
      printf("blockiThisBigBlock %3d -> half block tid offset %d\n", blockiThisBigBlock, offset);
      
      printf("block %3d B : input  buffer starting offset %5d\n", blocki, (int)(inBytePtr - inBlockBytes));
      printf("block %3d B : output buffer starting offset %5d\n", blocki, (int)(outPtr - outs32BlockBytes));
    }
    
    for (int i = 0; i < (blockDim * blockDim)/2; i++) {
      uint8_t bVal = *inBytePtr++;
#if defined(DEBUG)
      assert(*outPtr == 0xFF);
#endif // (DEBUG)
      *outPtr = bVal;
      
      if (debugWriteEveryValue) {
        printf("write out[%4d] = %5d\n", (int)(outPtr - outs32BlockBytes), bVal);
      }
      
      if (blockiReordererVecPtr != nullptr) {
        (*blockiReordererVecPtr).push_back(bVal);
      }
      
      outPtr++;
    }
    
    if (debug) {
      printf("block %3d A : update output buffer offset %5d\n", blocki, (int)(outPtr - outs32BlockBytes));
    }
  }
  
  if (blockiReordererKTableHalfVecPtr != nullptr) {
    // 1 additional k = 0 value at the end of the k table
    (*blockiReordererKTableHalfVecPtr).push_back(0);
  }
  
  return;
}

// Given pixel data reordering into s32 ordering, read from the 32 streams
// and reorder output data so that the results are collected back into
// blocks from the half block splits.

static inline
void block_s32_flatten_block_layout(
                                    const uint8_t *inS32BlockBytes,
                                    uint8_t *outBlockBytes,
                                    const int blockN,
                                    const int blockDim,
                                    const int numSegments,
                                    const uint8_t *expectedS32BlockBytes = nullptr)
{
  const bool debug = false;
  const bool debugWriteEveryValue = false;
  const bool debugWriteBlockOutputValue = false;
  
  vector<uint8_t*> halfBlockPtrVec;
  halfBlockPtrVec.resize(numSegments);
  
  // blockN should be a multiple of 16 assuming 8x8 blocks
  assert((blockN % (numSegments/2)) == 0);
  
  for (int i = 0; i < numSegments; i++) {
    const uint8_t *inPtr = &inS32BlockBytes[i * (blockDim * blockDim)/2];
    halfBlockPtrVec[i] = (uint8_t *) inPtr;
    
    if (debug) {
      printf("segment %3d : input buffer starting offset %5d\n", i, (int)(inPtr - inS32BlockBytes));
    }
  }
  
  // Each pair of segments corresponds to a stream
  
  vector<vector<uint8_t> > streamsSegmentsVec;
  
  for (int i = 0; i < numSegments; i++) {
    streamsSegmentsVec.push_back(vector<uint8_t>());
  }
  
  for (int loopBlocki = 0; loopBlocki < blockN; loopBlocki++) {
    int blocki = loopBlocki;
    
    if (loopBlocki > 0 && ((loopBlocki % (numSegments/2)) == 0)) {
      if (debug) {
        printf("advance output ptrs before block %3d\n", blocki);
      }
      
      int numBytesAllSegments = numSegments * (blockDim * blockDim)/2;
      
      for (int i = 0; i < numSegments; i++) {
        uint8_t *inPtr = halfBlockPtrVec[i];
        inPtr += numBytesAllSegments;
        halfBlockPtrVec[i] = inPtr;
      }
    }
    
    // Map tid in range (0, 31) into blocki range (0, 15) with 8x8 blocks.
    
    unsigned int blockiThisBigBlock = (loopBlocki % (numSegments/2)); // range (0, 15)
    unsigned int offset = blockiThisBigBlock * 2; // range (0, 31) w step 2
    uint8_t *inPtr = halfBlockPtrVec[offset];
    
    vector<uint8_t> & streamRefA = streamsSegmentsVec[offset];
    
    //uint8_t *outPtr = &outBlockBytes[blocki * (blockDim * blockDim)];
    
    if (debug) {
      printf("blockiThisBigBlock %3d -> half block tid offset %d\n", blockiThisBigBlock, offset);
      
      printf("block %3d A : input  buffer starting offset %5d\n", blocki, (int)(inPtr - inS32BlockBytes));
      //printf("block %3d A : output buffer starting offset %5d\n", blocki, (int)(outPtr - outBlockBytes));
    }
    
    for (int i = 0; i < (blockDim * blockDim)/2; i++) {
      uint8_t bVal = *inPtr++;
      //*outPtr++ = bVal;
      streamRefA.push_back(bVal);
      
      if (debugWriteEveryValue) {
        printf("write %5d\n", bVal);
      }
    }
    
//    if (debug) {
//      printf("block %3d A : update output buffer offset %5d\n", blocki, (int)(outPtr - outBlockBytes));
//    }
    
    // With 8x8 blocks, read next 32 values from a half block part B
    
    offset += 1;
    inPtr = halfBlockPtrVec[offset];
    
    vector<uint8_t> & streamRefB = streamsSegmentsVec[offset];
    
    if (debug) {
      printf("blockiThisBigBlock %3d -> half block tid offset %d\n", blockiThisBigBlock, offset);
      
      printf("block %3d B : input  buffer starting offset %5d\n", blocki, (int)(inPtr - inS32BlockBytes));
      //printf("block %3d B : output buffer starting offset %5d\n", blocki, (int)(outPtr - outBlockBytes));
    }
    
    for (int i = 0; i < (blockDim * blockDim)/2; i++) {
      uint8_t bVal = *inPtr++;
      //*outPtr++ = bVal;
      streamRefB.push_back(bVal);
      
      if (debugWriteEveryValue) {
        printf("write %5d\n", bVal);
      }
    }
    
//    if (debug) {
//      printf("block %3d A : update output buffer offset %5d\n", blocki, (int)(outPtr - outBlockBytes));
//    }
  }
  
  // Interleave output so that 1 value from each stream is written to the output
  // buffer until all streams are empty.
  
  assert(streamsSegmentsVec.size() == numSegments);
  
  int streamLen = -1;
  
  for (int i = 0; i < numSegments; i++) {
    int len = (int) streamsSegmentsVec[i].size();
    if (streamLen == -1) {
      streamLen = len;
    } else {
      assert(streamLen == len);
    }
  }
  
  uint8_t *outPtr = outBlockBytes;
  
  vector<vector<uint8_t> > vecOfBlockVecs;

  for ( int i = 0 ; i < numSegments; i++ ) {
    vecOfBlockVecs.push_back(vector<uint8_t>());
  }
  
  int outputBlocki = 0;
  
  for ( int streami = 0; streami < streamLen; streami++) {
    for (int segi = 0; segi < numSegments; segi++) {
      vector<uint8_t> & streamRef = streamsSegmentsVec[segi];
      int bVal = streamRef[streami];
      vector<uint8_t> & blockVec = vecOfBlockVecs[segi];
      blockVec.push_back(bVal);
    }
    
    // If block buffers are full, append whole blocks
    // in the big block relative ordering.
    
    if (vecOfBlockVecs[0].size() == (blockDim*blockDim/2)) {
      for (int segi = 0; segi < numSegments; segi++) {
        vector<uint8_t> & block = vecOfBlockVecs[segi];
        
        for ( uint8_t bVal : block ) {
          *outPtr++ = bVal;
          
          if (debugWriteBlockOutputValue) {
            printf("outputBlocki %4d : write %5d\n", outputBlocki, bVal);
          }
          
          if (expectedS32BlockBytes != nullptr) {
            int offset = (int) (outPtr - 1 - outBlockBytes);
            int expected = expectedS32BlockBytes[offset];
            if (bVal != expected) {
              assert(bVal == expected);
            }
          }
        }
        
        block.clear();
        
        outputBlocki++;
      }
    }
  }
  
  return;
}

// Decode API where a block of 32x32 bytes is decoded, this method accepts
// the same parameters as the bit parsing API and outputs the threadid
// for a given pixel in image order.

typedef struct
{
  uint8_t R;
  uint8_t G;
  uint8_t B;
  uint8_t A;
} Pixel32;

typedef struct
{
  uint16_t x;
  uint16_t y;
} UShort2;

static inline
UShort2 MakeUShort2(int x, int y) {
  UShort2 u2;
  u2.x = x;
  u2.y = y;
  return u2;
}

// Decode operation where 32 streams are read at the same time, each stream is
// identified by bit location into a stream that is formatted into blocks
// of 32x32 bytes. The output texture is simulated with a word buffer.
// The output of this process parses prefix values and escape bits
// but not suffix bits.

typedef enum {
  RenderRiceTypedTid,
  RenderRiceTypedBlocki,
  RenderRiceTypedBigBlocki,
  RenderRiceTypedBlockBitOffset,
  RenderRiceTypedDecode,
} RenderRiceTyped;

//typedef CachedBits<uint32_t, const uint32_t *, uint16_t, uint8_t> CachedBits3216;
typedef CachedBits<uint32_t, const uint32_t *, uint32_t, uint8_t> CachedBits3232;

//typedef RiceDecodeBlocks<CachedBits3216, uint16_t, false> RiceDecodeBlocksT;
typedef RiceDecodeBlocks<CachedBits3232, uint32_t, false> RiceDecodeBlocksT;

template <const int D>
void kernel_render_rice_typed(
                              uint32_t *outTexturePtr,
                              RiceRenderUniform & riceRenderUniform,
                              uint32_t *inoutBlockOffsetTablePtr, // 32 entries
                              const uint32_t *inS32BitsPtr,
                              const uint8_t * blockOptimalKTable,
                              RenderRiceTyped rType,
                              unsigned int bbid, // big block blocki
                              int tid, // thread id
                              // output blocki, big blocki, or bit offset on a per pixel basis
                              uint32_t *out32Ptr
                              ) // thread id
{
  const bool debug = false;
  
  // Loop over 1/2 of an 8x8 block of byte values. Byte values are packed
  // into BGRA values so that 16 would be an entire block and 8 would
  // correspond to a half block.
  
  // Thread specific bit stream and registers
  RiceDecodeBlocksT rdb;
  
  //const ushort blockDim = RICE_SMALL_BLOCK_DIM;
  const ushort blockDim = D;
  
  const ushort bigBlocksDim = 4;

  const int numBlocksInWidth = (int) riceRenderUniform.numBlocksInWidth;
  
  const int width = numBlocksInWidth * blockDim;
  //const int height = riceRenderUniform.numBlocksInHeight * blockDim;
  
  // blocki is based on tid, for tid (0,1) blocki is 0 for tid (2,3) blocki is 1
  
  const ushort blockiInBigBlock = ((ushort)tid) >> 1; // tid / 2
  
  unsigned int blocki = (bbid * bigBlocksDim * bigBlocksDim) + blockiInBigBlock;
  
  assert(blockiInBigBlock >= 0 && blockiInBigBlock < 16);
  
  uint8_t k = 0;
  
  if (blockOptimalKTable) {
    k = blockOptimalKTable[blocki];
    
    if (debug) {
      printf("k = %1d for blocki %d\n", k, blocki);
    }
  }
  
  // tid is a direct offset into the bitOffsets[32] table for this big block
  
  uint32_t halfBlockStartBitOffset = 0;
  if (inoutBlockOffsetTablePtr) {
    halfBlockStartBitOffset = inoutBlockOffsetTablePtr[(bbid * 32) + tid];
  }

  if (rType == RenderRiceTypedDecode) {
    if (debug) {
      printf("rdb.cachedBits.initBits(ptr, %d)\n", halfBlockStartBitOffset);
    }
    
    rdb.cachedBits.initBits(inS32BitsPtr, halfBlockStartBitOffset);
    
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
    rdb.totalNumBitsRead = halfBlockStartBitOffset;
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
  }
  
  ushort rowOffset = 0;
  
  // Render one block
  
  {
    // Map blocki to the big block root and convert to (X,Y)
    
    UShort2 bigBlockRootCoords;
    
    {
      const ushort numBigBlocksInWidth = (numBlocksInWidth / bigBlocksDim);
#if defined(DEBUG)
      // Verify that X and Y do not roll over a 16 bit unsigned integer
      {
        int numBigBlocksInWidthInt = int(numBlocksInWidth) / int(bigBlocksDim);;
        assert(numBigBlocksInWidth == numBigBlocksInWidthInt);
      }
#endif // DEBUG

#if defined(DEBUG)
      {
        int numPixels = numBlocksInWidth * blockDim;
        int numBigBlocksInWidthInt = numPixels / (bigBlocksDim * blockDim);
        assert(numBigBlocksInWidth == numBigBlocksInWidthInt);
      }
#endif // DEBUG
      ushort bigBlockX = bbid % numBigBlocksInWidth;
#if defined(DEBUG)
      {
        int bigBlockXInt = bbid % numBigBlocksInWidth;
        assert(bigBlockX == bigBlockXInt);
      }
#endif // DEBUG
      ushort bigBlockY = bbid / numBigBlocksInWidth;
#if defined(DEBUG)
      {
        int bigBlockYInt = bbid / numBigBlocksInWidth;
        assert(bigBlockY == bigBlockYInt);
      }
#endif // DEBUG

#if defined(DEBUG)
      // Verify that X and Y do not roll over a 16 bit unsigned integer
      {
        int bigBlockXInt = bigBlockX;
        int X = bigBlockXInt * (bigBlocksDim * blockDim)/4;
        ushort Xval = bigBlockX * (bigBlocksDim * blockDim)/4;
        assert(X == Xval);
      }
      {
        int bigBlockYInt = bigBlockY;
        int Y = bigBlockYInt * (bigBlocksDim * blockDim);
        ushort Yval = bigBlockY * (bigBlocksDim * blockDim);
        assert(Y == Yval);
      }
#endif // DEBUG
      
      bigBlockRootCoords = MakeUShort2(bigBlockX * (bigBlocksDim * blockDim)/4, bigBlockY * (bigBlocksDim * blockDim));
      
      if (debug) {
        printf("bbid   %4d\n", bbid);
        printf("bigBlockX,bigBlockY %4d,%4d\n", bigBlockX, bigBlockY);
        printf("bigBlockRootCoords  %4d,%4d\n", bigBlockRootCoords.x, bigBlockRootCoords.y);
      }
    }
    
    UShort2 blockRootCoords;
    
    {
      ushort blockX = blockiInBigBlock % bigBlocksDim;
      ushort blockY = blockiInBigBlock / bigBlocksDim;
      
#if defined(DEBUG)
      // Verify that X and Y do not roll over a 16 bit unsigned integer
      {
        int blockXInt = int(blockiInBigBlock) % int(bigBlocksDim);
        assert(blockX == blockXInt);
        int blockYInt = int(blockiInBigBlock) / int(bigBlocksDim);
        assert(blockY == blockYInt);
      }
#endif // DEBUG
      
#if defined(DEBUG)
      // Verify that X and Y do not roll over a 16 bit unsigned integer
      {
        int blockXInt = blockX;
        int X = blockXInt * (blockDim/4);
        ushort Xval = blockX * (blockDim/4);
        assert(X == Xval);
      }
      {
        int blockYInt = blockY;
        int Y = blockYInt * blockDim;
        ushort Yval = blockY * blockDim;
        assert(Y == Yval);
      }
#endif // DEBUG
      
      blockRootCoords = MakeUShort2(blockX * (blockDim/4), blockY * blockDim);
      
      if (tid & 0x1) {
        // Odd threads render to the half block on the bottom
        rowOffset = blockDim/2;
      }

      if (debug) {
        printf("blocki   %4d\n", blocki);
        printf("blockiInBigBlock   %4d\n", blockiInBigBlock);
        printf("blockX,blockY   %4d,%4d\n", blockX, blockY);
        printf("blockRootCoords %4d,%4d\n", blockRootCoords.x, blockRootCoords.y);
      }
    }
    
    // Combine bigBlockRootCoords and blockRootCoords
    
#if defined(DEBUG)
    // Verify that sum does not roll over a 16 bit unsigned integer
    {
      ushort sumX = blockRootCoords.x + bigBlockRootCoords.x;
      int sumXInt = int(blockRootCoords.x) + int(bigBlockRootCoords.x);
      assert(sumX == sumXInt);
    }
    // Verify that sum does not roll over a 16 bit unsigned integer
    {
      ushort sumY = blockRootCoords.y + bigBlockRootCoords.y;
      int sumYInt = int(blockRootCoords.y) + int(bigBlockRootCoords.y);
      assert(sumY == sumYInt);
    }
#endif // DEBUG
    
    blockRootCoords.x += bigBlockRootCoords.x;
    blockRootCoords.y += bigBlockRootCoords.y;

    if (debug) {
      printf("combine bigBlockRootCoords and blockRootCoords\n");
      printf("blockRootCoords %4d,%4d\n", blockRootCoords.x, blockRootCoords.y);
    }

    // Collect 8*8/2 symbols from input bits and write to texture as 2D image data
    
#if defined(DEBUG)
    // Verify that sum does not roll over a 16 bit unsigned integer
    {
      ushort sum = rowOffset + blockDim/2;
      int sumInt = int(rowOffset) + int(blockDim/2);
      assert(sum == sumInt);
    }
#endif // DEBUG
    
    const ushort maxRow = rowOffset + blockDim/2;
    
    for (ushort row = rowOffset; row < maxRow; row++) {
      
      for (ushort col = 0; col < blockDim/4; col++) {
        // Each col parses 4 prefix byte values
        
        ushort prefixByte0, prefixByte1, prefixByte2, prefixByte3;
        
        UShort2 blockCoords = MakeUShort2(col, row);
        UShort2 outCoords;
        
#if defined(DEBUG)
        // Verify that sum does not roll over a 16 bit unsigned integer
        {
          ushort sumX = blockRootCoords.x + blockCoords.x;
          int sumXInt = int(blockRootCoords.x) + int(blockCoords.x);
          assert(sumX == sumXInt);
        }
        // Verify that sum does not roll over a 16 bit unsigned integer
        {
          ushort sumY = blockRootCoords.y + blockCoords.y;
          int sumYInt = int(blockRootCoords.y) + int(blockCoords.y);
          assert(sumY == sumYInt);
        }
#endif // DEBUG
        
        outCoords.x = blockRootCoords.x + blockCoords.x;
        outCoords.y = blockRootCoords.y + blockCoords.y;
        
        // Write to output in image order
        
        int offset = (int(outCoords.y) * width/4) + outCoords.x;
        
        if (rType == RenderRiceTypedTid) {
          prefixByte0 = tid;
          prefixByte1 = tid;
          prefixByte2 = tid;
          prefixByte3 = tid;
        } else if (rType == RenderRiceTypedBlocki) {
          // write 32 bit pixel values to out32Ptr
          assert(outTexturePtr == NULL);
          int offset = (int(outCoords.y) * width) + (outCoords.x * 4);
          
          out32Ptr[offset+0] = blocki;
          out32Ptr[offset+1] = blocki;
          out32Ptr[offset+2] = blocki;
          out32Ptr[offset+3] = blocki;
          
          continue;
        } else if (rType == RenderRiceTypedBigBlocki) {
          // write 32 bit pixel values to out32Ptr
          assert(outTexturePtr == NULL);
          int offset = (int(outCoords.y) * width) + (outCoords.x * 4);
          
          out32Ptr[offset+0] = bbid;
          out32Ptr[offset+1] = bbid;
          out32Ptr[offset+2] = bbid;
          out32Ptr[offset+3] = bbid;
          
          continue;
        } else if (rType == RenderRiceTypedBlockBitOffset) {
          // write 32 bit pixel values to out32Ptr
          assert(outTexturePtr == NULL);
          int offset = (int(outCoords.y) * width) + (outCoords.x * 4);
          
          out32Ptr[offset+0] = halfBlockStartBitOffset;
          out32Ptr[offset+1] = halfBlockStartBitOffset;
          out32Ptr[offset+2] = halfBlockStartBitOffset;
          out32Ptr[offset+3] = halfBlockStartBitOffset;
          
          continue;
        } else if (rType == RenderRiceTypedDecode) {
          //          prefixByte0 = rice_rdb_decode_symbol(rdb, k);
          //          prefixByte1 = rice_rdb_decode_symbol(rdb, k);
          //          prefixByte2 = rice_rdb_decode_symbol(rdb, k);
          //          prefixByte3 = rice_rdb_decode_symbol(rdb, k);
          
//          prefixByte0  = rdb.decodePrefixByte(k, false, 0, true);
//          prefixByte0 |= rdb.decodeSuffixByte(k, true, k, false);
//
//          prefixByte1  = rdb.decodePrefixByte(k, false, 0, false);
//          prefixByte1 |= rdb.decodeSuffixByte(k, true, k, false);
//
//          prefixByte2  = rdb.decodePrefixByte(k, false, 0, false);
//          prefixByte2 |= rdb.decodeSuffixByte(k, true, k, false);
//
//          prefixByte3  = rdb.decodePrefixByte(k, false, 0, false);
//          prefixByte3 |= rdb.decodeSuffixByte(k, true, k, false);
          
          
          prefixByte0  = rdb.decodePrefixByte(k, false, 0, true);
          prefixByte0 |= rdb.decodeSuffixByte(k, false, 0, false);
          
          prefixByte1  = rdb.decodePrefixByte(k, false, 0, false);
          prefixByte1 |= rdb.decodeSuffixByte(k, true, k, false);
          
          prefixByte2  = rdb.decodePrefixByte(k, false, 0, false);
          prefixByte2 |= rdb.decodeSuffixByte(k, true, k, false);
          
          prefixByte3  = rdb.decodePrefixByte(k, false, 0, false);
          prefixByte3 |= rdb.decodeSuffixByte(k, true, k, false);

        } else {
          assert(0);
        }
        
        Pixel32 pixel;
        
        // Write as packed 32 bit pixel values
        
        pixel.R = prefixByte0;
        pixel.G = prefixByte1;
        pixel.B = prefixByte2;
        pixel.A = prefixByte3;
        
        if (debug) {
        printf("outCoords %4d,%4d : offset %4d : bytes (%3d %3d %3d %3d)\n", outCoords.x, outCoords.y, offset, pixel.R, pixel.G, pixel.B, pixel.A);
        }
        
        assert(sizeof(uint32_t) == sizeof(Pixel32));
        uint32_t word;
        memcpy(&word, &pixel, sizeof(uint32_t));
        outTexturePtr[offset] = word;
        
        // Verify that col does not go over ushort limit
        
#if defined(DEBUG)
        assert((int(col) + 1) == (col + 1));
#endif // DEBUG
      }
      
      // Verify that row does not go over ushort limit
#if defined(DEBUG)
      assert((int(row) + 1) == (row + 1));
#endif // DEBUG
    }
  }
  
  return;
}
