//
//  block_process.hpp
//
//  Created by Mo DeJong on 6/3/18.
//  Copyright © 2018 helpurock. All rights reserved.
//
//  The block processing logic creates an optimized
//  block by block segmentation of the input symbols
//  and processes them to convert to base and deltas.
//  Note that a second round of deltas on the base
//  symbols for each block improves compression.

#ifndef _block_process_hpp
#define _block_process_hpp

#include <stdio.h>

#include <cinttypes>
#include <vector>
#include <bitset>

#include  "zigzag.h"
#include "EncDec.hpp"

using namespace std;

extern
int optimalRiceK(
                 const uint8_t * inBytes,
                 int inNumBytes,
                 int blocki);

// Decode the block encoding created by blockDeltaEncoding()

template <const int BD>
void block_delta_process_decode(
                         const uint8_t * inEncodedBlockBytes,
                         int inEncodedBlockNumBytes,
                         const int width,
                         const int height,
                         const unsigned int blockWidth,
                         const unsigned int blockHeight,
                         uint8_t *outBlockBytesPtr,
                         int outBlockNumBytes)
{
    const int blockDim = BD;
    
    int numBlocks = inEncodedBlockNumBytes / (blockDim * blockDim);
    assert((inEncodedBlockNumBytes % (blockDim * blockDim)) == 0);
    
    // Iterate over each block, collecting the back delta value
    // from the pixel at (0,0).
    
    //const uint8_t *inPtr = inEncodedBlockBytes;
    
    //vector<uint8_t> baseDeltaBytes;
    
    //baseDeltaBytes.resize(numBlocks);
    
//    for (int blocki = 0; blocki < numBlocks; blocki++) {
//        const uint8_t *blockPtr = inEncodedBlockBytes + (blocki * (blockDim * blockDim));
//        uint8_t bVal = blockPtr[0];
//        baseDeltaBytes[blocki] = bVal;
//    }
    
    // Reverse zerod encoding for all delta values in a block
    
//    for (int i = 1; i < baseDeltaBytes.size(); i++ ) {
//        uint8_t zerodVal = baseDeltaBytes[i];
//        int8_t sVal = pixelpack_offset_uint8_to_int8(zerodVal);
//        baseDeltaBytes[i] = sVal;
//    }
    
    // Undelta baseDeltaBytes
    
//    vector<uint8_t> baseBytes = decodeDelta(baseDeltaBytes);
    
    // Collect blocks of deltas and push each block to a decoder vector entry
    
    BlockDecoder<uint8_t, blockDim> decoder;
    
    decoder.blockVectors.resize(numBlocks);
    
    vector<uint8_t> vec;
    vec.resize(blockDim);
    
    for (int blocki = 0; blocki < numBlocks; blocki++) {
        const uint8_t *blockPtr = inEncodedBlockBytes + (blocki * (blockDim * blockDim));
        
        vector<uint8_t> decodedBlockBytes;
        decodedBlockBytes.resize(blockDim * blockDim);
        
        // Reverse deltas for column 0
        
        vec[0] = blockPtr[0];
        
        for ( int row = 1; row < blockDim; row++ ) {
            int offset = (row * blockDim);
            uint8_t zerodVal = blockPtr[offset];
            int8_t sVal = pixelpack_offset_uint8_to_int8(zerodVal);
            vec[row] = sVal;
        }
        
        vector<uint8_t> col0Bytes = decodeDelta(vec);

        for ( int row = 0; row < blockDim; row++ ) {
            int offset = (row * blockDim);
            uint8_t byteVal = col0Bytes[row];
            decodedBlockBytes[offset] = byteVal;
        }
        
        // Reverse deltas for each row, note that the row base
        // value was already decoded above.
        
        for ( int row = 0; row < blockDim; row++ ) {
            // col 0
            {
                int offset = (row * blockDim);
                uint8_t byteVal = decodedBlockBytes[offset];
                vec[0] = byteVal;
            }
            
            for ( int col = 1; col < blockDim; col++ ) {
                int offset = (row * blockDim) + col;
                uint8_t zerodVal = blockPtr[offset];
                int8_t sVal = pixelpack_offset_uint8_to_int8(zerodVal);
                vec[col] = sVal;
            }
            
            vector<uint8_t> rowBytes = decodeDelta(vec);
            
            for ( int col = 1; col < blockDim; col++ ) {
                int offset = (row * blockDim) + col;
                uint8_t byteVal = rowBytes[col];
                decodedBlockBytes[offset] = byteVal;
            }
        }
        
        decoder.blockVectors[blocki] = std::move(decodedBlockBytes);
    }
    
    //assert((inPtr - (uint8_t *) inEncodedBlockBytes) == inEncodedBlockNumBytes);
    
    // Flatten and crop blocks to get back to the original pixels
    
    decoder.flattenAndCrop(outBlockBytesPtr, outBlockNumBytes, blockWidth, blockHeight, width, height);
    
    return;
}


// Decode the block encoding created by block_process_encode()

template <const int BD>
void block_process_decode(
                                const uint8_t * inEncodedBlockBytes,
                                int inEncodedBlockNumBytes,
                                const int width,
                                const int height,
                                const unsigned int blockWidth,
                                const unsigned int blockHeight,
                                uint8_t *outBlockBytesPtr,
                                int outBlockNumBytes)
{
    const int blockDim = BD;
    
    int numBlocks = inEncodedBlockNumBytes / (blockDim * blockDim);
    assert((inEncodedBlockNumBytes % (blockDim * blockDim)) == 0);
    
    // Collect blocks of deltas and push each block to a decoder vector entry
    
    BlockDecoder<uint8_t, blockDim> decoder;
    
    decoder.blockVectors.resize(numBlocks);
    
    for (int blocki = 0; blocki < numBlocks; blocki++) {
        const uint8_t *blockPtr = inEncodedBlockBytes + (blocki * (blockDim * blockDim));
        
        vector<uint8_t> decodedBlockBytes;
        decodedBlockBytes.resize(blockDim * blockDim);
        
        memcpy(decodedBlockBytes.data(), blockPtr, (blockDim * blockDim));
        
        decoder.blockVectors[blocki] = std::move(decodedBlockBytes);
    }
    
    // Flatten and crop blocks to get back to the original pixels
    
    decoder.flattenAndCrop(outBlockBytesPtr, outBlockNumBytes, blockWidth, blockHeight, width, height);
    
    return;
}

// This method breaks input up into blocks and then encodes the
// values using an optimal approach where the first "base" value
// in each block is pulled out of the stream and encoded as deltas.
// All the base values are encoded together and then the remainder
// of the block deltas are appended to the output. If the inBlockWidth
// and inBlockHeight is non-zero then that value is used, otherwise
// the value is calculated from the input width and height.

template <const int BD>
void block_delta_process_encode(const uint8_t * inBytes,
                          int inNumBytes,
                          const int width,
                          const int height,
                          const int outBlockWidth,
                          const int outBlockHeight,
                          vector<uint8_t> & outEncodedBlockBytes,
                          int * numBaseValues,
                          int * numBlockValues)
{
    const int dumpBlockInOutBytes = 0;
    const int dumpDeltaBytes = 0;
    
    if (dumpBlockInOutBytes) {
        printf("image order for %5d x %5d image\n", width, height);
        
        for ( int row = 0; row < height; row++ ) {
            for ( int col = 0; col < width; col++ ) {
                uint8_t byteVal = inBytes[(row * width) + col];
                printf("0x%02X ", byteVal);
            }
            
            printf("\n");
        }
        
        printf("image order done\n");
    }
    
    const int blockDim = BD;
    BlockEncoder<uint8_t, blockDim> encoder;
    
    unsigned int blockWidth, blockHeight;
  
    if (outBlockWidth == 0) {
      encoder.calcBlockWidthAndHeight(width, height, blockWidth, blockHeight);
    } else {
      blockWidth = outBlockWidth;
      blockHeight = outBlockHeight;
    }
    
    encoder.splitIntoBlocks(inBytes, inNumBytes, width, height, blockWidth, blockHeight, 0);
  
    // Calculate deltas within eacg block. The initial set of deltas on column zero
    // from (0,0) to (0, height). After column zero deltas have been applied, row
    // deltas are calculated for (0,i) to (width, i) starting from the column 0
    // sum for that row. This type of delta operation can be reversed with each
    // row being processed in parallel.
    
    //vector<uint8_t> baseValuesVec;
    //baseValuesVec.reserve(encoder.blockVectors.size());
    
    // Vector that will be used for delta operation
    vector<uint8_t> deltaVec;
    deltaVec.resize(blockDim);
    
    int blocki = 0;
    for ( vector<uint8_t> & inOutBlockVec : encoder.blockVectors ) {
        // Calculate deltas for column 0
        
        if (dumpDeltaBytes) {
            printf("blocki %d:\n", blocki);
        }
        
        int width = blockDim;
        int height = blockDim;
        
        if (dumpBlockInOutBytes) {
            printf("IN blocki %d:\n", blocki);
            
            for ( int row = 0; row < height; row++ ) {
                for ( int col = 0; col < width; col++ ) {
                    int offset = (row * width) + col;
                    uint8_t byteVal = inOutBlockVec[offset];
                    printf("0x%02X ", byteVal);
                }
                
                printf("\n");
            }
            
            printf("block done\n");
        }
        
        for ( int row = 0; row < height; row++ ) {
            int offset = (row * width);
            uint8_t byteVal = inOutBlockVec[offset];
            deltaVec[row] = byteVal;
        }
        
        if (dumpDeltaBytes) {
            printf("col0 bytes:\n");
            for ( uint8_t byteVal : deltaVec ) {
                printf("0x%02X ", byteVal);
            }
            
            printf("\n");
        }
        
        vector<uint8_t> col0SignedDeltaBytes = encodeDelta(deltaVec);
        
        if (dumpDeltaBytes) {
            printf("col0 delta bytes:\n");
            for ( uint8_t byteVal : col0SignedDeltaBytes ) {
                printf("0x%02X ", byteVal);
            }
            
            printf("\n");
        }

        // Note that column deltas are not copied back over
        // the input block at this point, wait until row
        // deltas have been calculated.
        
        {
            // Ignore (0,0) since this value is unchanged
            
#if defined(DEBUG)
            uint8_t byteVal = col0SignedDeltaBytes[0];
            uint8_t originalByteVal = inOutBlockVec[0];
            assert(byteVal == originalByteVal);
#endif // DEBUG
        }
        
        // Calculate deltas for each row, starting at
        // (0, row) to (width, row)
        
        for ( int row = 0; row < height; row++ ) {
            for ( int col = 0; col < width; col++ ) {
                int offset = (row * width) + col;
                uint8_t byteVal = inOutBlockVec[offset];
                deltaVec[col] = byteVal;
            }
            
            if (dumpDeltaBytes) {
                printf("row%4d bytes:\n", row);
                for ( uint8_t byteVal : deltaVec ) {
                    printf("0x%02X ", byteVal);
                }
                
                printf("\n");
            }
            
            vector<uint8_t> rowSignedDeltaBytes = encodeDelta(deltaVec);
            
            if (dumpDeltaBytes) {
                printf("row%4d delta bytes:\n", row);
                for ( uint8_t byteVal : rowSignedDeltaBytes ) {
                    printf("0x%02X ", byteVal);
                }
                
                printf("\n");
            }
            
            // Copy row deltas back into block order vec
            
            if (dumpDeltaBytes) {
                printf("zerod bytes:\n");
                printf("---- ");
            }
            
            for ( int col = 1; col < width; col++ ) {
                int offset = (row * width) + col;
                uint8_t sVal = rowSignedDeltaBytes[col];
                uint8_t zerodVal = pixelpack_int8_to_offset_uint8(sVal);
                inOutBlockVec[offset] = zerodVal;
                
                if (dumpDeltaBytes) {
                    printf("0x%02X ", zerodVal);
                }
            }
            
            if (dumpDeltaBytes) {
                printf("\n");
            }
        } // end foreach row
        
        // Copy col 0 delta back into block order vec
        
        if (dumpDeltaBytes) {
            printf("col 0 zerod bytes:\n");
            printf("---- ");
        }
        
        for ( int row = 1; row < height; row++ ) {
            int offset = (row * width);
            uint8_t sVal = col0SignedDeltaBytes[row];
            uint8_t zerodVal = pixelpack_int8_to_offset_uint8(sVal);
            inOutBlockVec[offset] = zerodVal;
            
            if (dumpDeltaBytes) {
                printf("0x%02X ", zerodVal);
            }
        }
        
        if (dumpDeltaBytes) {
            printf("\n");
        }
        
        if (dumpBlockInOutBytes) {
            printf("OUT blocki %d:\n", blocki);
            
            for ( int row = 0; row < height; row++ ) {
                for ( int col = 0; col < width; col++ ) {
                    int offset = (row * width) + col;
                    uint8_t byteVal = inOutBlockVec[offset];
                    printf("0x%02X ", byteVal);
                }
                
                printf("\n");
            }
            
            printf("block done\n");
        }
        
        blocki++;
    }
    
    *numBaseValues = 0;
    *numBlockValues = (int) encoder.blockVectors.size() * (blockDim * blockDim);
    
    // Write all encoded bytes in block by block order
    
    {
        int numValuesEachBlock = (blockDim * blockDim);
        int numBytes = numValuesEachBlock * (int)encoder.blockVectors.size();
        
        outEncodedBlockBytes.resize(numBytes);
        
        assert(numBytes == (blockWidth * blockHeight * blockDim * blockDim));
    }
    
    uint8_t *ptr = outEncodedBlockBytes.data();
    
    for ( vector<uint8_t> & vec : encoder.blockVectors ) {
        const uint8_t *blockWithoutBasePtr = vec.data();
        const int numBytes = (blockDim * blockDim);
        memcpy(ptr, blockWithoutBasePtr, numBytes);
        ptr += numBytes;
    }
    
#if defined(DEBUG)
    // Decode the encoded buffer and make sure it becomes the original input
    
    if (1)
    {
        vector<uint8_t> outBlockBytes;
        
        outBlockBytes.resize(inNumBytes);
        
        block_delta_process_decode<blockDim>(outEncodedBlockBytes.data(),
                                       (int)outEncodedBlockBytes.size(),
                                       width, height,
                                       blockWidth, blockHeight,
                                       outBlockBytes.data(), (int)outBlockBytes.size());
        
        for (int i = 0; i < inNumBytes; i++) {
            int inByte = inBytes[i];
            int decodedByte = outBlockBytes[i];
            assert(inByte == decodedByte);
        }
    }
#endif // DEBUG
    
    return;
}

// This method breaks input up into blocks and returns in block order.

template <const int BD>
void block_process_encode(const uint8_t * inBytes,
                          int inNumBytes,
                          const int width,
                          const int height,
                          const int outBlockWidth,
                          const int outBlockHeight,
                          vector<uint8_t> & outEncodedBlockBytes)
{
  if ((0)) {
    printf("image order for %5d x %5d image\n", width, height);
    
    for ( int row = 0; row < height; row++ ) {
      for ( int col = 0; col < width; col++ ) {
        uint8_t byteVal = inBytes[(row * width) + col];
        printf("0x%02X ", byteVal);
      }
      
      printf("\n");
    }
    
    printf("image order done\n");
  }
  
  const int blockDim = BD;
  BlockEncoder<uint8_t, blockDim> encoder;
  
  unsigned int blockWidth, blockHeight;
  
  if (outBlockWidth == 0) {
    encoder.calcBlockWidthAndHeight(width, height, blockWidth, blockHeight);
  } else {
    blockWidth = outBlockWidth;
    blockHeight = outBlockHeight;
  }
  
  encoder.splitIntoBlocks(inBytes, inNumBytes, width, height, blockWidth, blockHeight, 0);
  
  // Write all encoded bytes in block by block order
  
  {
    int numValuesEachBlock = (blockDim * blockDim);
    int numBytes = numValuesEachBlock * (int)encoder.blockVectors.size();
    
    outEncodedBlockBytes.resize(numBytes);
    
    assert(numBytes == (blockWidth * blockHeight * blockDim * blockDim));
  }
  
  uint8_t *ptr = outEncodedBlockBytes.data();
  
  for ( vector<uint8_t> & vec : encoder.blockVectors ) {
    const uint8_t *blockWithoutBasePtr = vec.data();
    const int numBytes = (blockDim * blockDim);
    memcpy(ptr, blockWithoutBasePtr, numBytes);
    ptr += numBytes;
  }
  
#if defined(DEBUG)
  // Decode the encoded buffer and make sure it becomes the original input
  
  if (1)
  {
    vector<uint8_t> outBlockBytes;
    
    outBlockBytes.resize(inNumBytes);
    
    block_process_decode<blockDim>(outEncodedBlockBytes.data(),
                                   (int)outEncodedBlockBytes.size(),
                                   width, height,
                                   blockWidth, blockHeight,
                                   outBlockBytes.data(), (int)outBlockBytes.size());
    
    for (int i = 0; i < inNumBytes; i++) {
      int inByte = inBytes[i];
      int decodedByte = outBlockBytes[i];
      assert(inByte == decodedByte);
    }
  }
#endif // DEBUG
  
  return;
}

// Process a buffer to optimize rice k paramter block by block.

template <const int SL>
void block_process_rice_opt(
                            const vector<uint8_t> & deltaBytes,
                            vector<uint8_t> & optKValues)
{
    const int splitLen = SL;
    
#if defined(DEBUG)
    assert((deltaBytes.size() % splitLen) == 0);
#endif // DEBUG
    
    const vector<vector<uint8_t> > baseDeltasVecOfVecs = splitIntoSubArraysOfLength(deltaBytes, splitLen);
    
    optKValues.reserve(baseDeltasVecOfVecs.size());
    
    int blocki = 0;
    
    for ( auto & vec : baseDeltasVecOfVecs ) {
        const uint8_t *blockPtr = vec.data();
        int numBytes = (int)vec.size();
        int bestK = optimalRiceK(blockPtr, numBytes, blocki++);
        
        optKValues.push_back(bestK);
    }
    
    return;
}

// Generate an input vector of uint32_t blocki values based on
// a width and height. Return blocki values in an order that
// supports table lookups by original blocki.

template <const int blockDim, const int blockiDim>
void block_reorder_blocki(int width,
                          int height,
                          vector<uint32_t> & blockiVec,
                          vector<uint32_t> & blockiLookupVec,
                          const bool resolve = false)
{
  // blockDim corresponds to the dimension of the block that corresponds to a single blocki
  // For example, with 2x2 blocks a blocki value corresponds to 4 pixels and an input that
  // is 4x4 would generate 4 blocki values (0, 1, 2, 3).

  unsigned int numBlocksInWidth, numBlocksInHeight;
  
  {
    BlockEncoder<uint32_t, blockDim> encoder;
    
    encoder.calcBlockWidthAndHeight(width, height, numBlocksInWidth, numBlocksInHeight);
  }
  
  unsigned int numBlocks = numBlocksInWidth * numBlocksInHeight;
  
  blockiVec.clear();
  blockiVec.reserve(numBlocks);
  
  for ( int blocki = 0; blocki < numBlocks; blocki++ ) {
    blockiVec.push_back(blocki);
  }
  
  // Split blocki values based on blockiDim, for example if blockiDim = 4
  // then split blocki values in image order into 4x4 block order data.
  
  unsigned int numBigBlocksInWidth, numBigBlocksInHeight;
  
  BlockEncoder<uint32_t, blockiDim> encoder;
  
  encoder.calcBlockWidthAndHeight(numBlocksInWidth, numBlocksInHeight, numBigBlocksInWidth, numBigBlocksInHeight);

  blockiLookupVec.clear();
  blockiLookupVec.reserve(numBlocks);
  
  uint32_t *inBlockWords = blockiVec.data();
  
  encoder.splitIntoBlocks(inBlockWords, numBlocks, numBlocksInWidth, numBlocksInHeight, numBigBlocksInWidth, numBigBlocksInHeight, 0xFFFFFFFF);
  
  for ( vector<uint32_t> & inOutBlockVec : encoder.blockVectors ) {
    for ( uint32_t blocki : inOutBlockVec ) {
      // Skip any padding elements
      if (blocki == 0xFFFFFFFF) {
        // nop
      } else {
        blockiLookupVec.push_back(blocki);
      }
    }
  }
  
  assert(blockiVec.size() == blockiLookupVec.size());
  
  // If resolve is true, the lookup each original blocki
  
  if (resolve == true) {
    vector<uint32_t> resolved;
    resolved.reserve(blockiLookupVec.size());
    
    for ( uint32_t blocki : blockiVec ) {
      int bigBlocki = (blocki / (blockiDim * blockiDim));
      int bigBlockRooti = bigBlocki * (blockiDim * blockiDim);
      int bigBlockOffset = (blocki - bigBlockRooti);
      int offset = bigBlockRooti + bigBlockOffset;
      uint32_t resolvedBlocki = blockiLookupVec[offset];
      
      if ((0)) {
        printf("blocki %3d : bigBlocki %3d : bigBlockRooti %3d : lookupBlocki %3d\n", blocki, bigBlocki, bigBlockRooti, resolvedBlocki);
      }
            
      resolved.push_back(resolvedBlocki);
    }
    
    blockiLookupVec = resolved;
  }
  
  return;
}

#endif // _block_process_hpp
