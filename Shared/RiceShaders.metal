/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Metal shader logic used for parallel prefix sum operation.
*/

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Include header shared between this Metal shader code and C code executing Metal API commands
#import "AAPLShaderTypes.h"

#import "MetalUtils.metal"

// Kernel that reads from 32 parallel streams and writes to an output 2D
// textures that contains 4 values per BGRA pixel. This kernel loops
// over 8x8 blocks in 2 steps. This weird CACHEDBIT_THREAD_SPECIFIC define
// is required for some reason since the template logic does not seem
// to allow thread as a type in the tempalte parameters for some unknown reason.

#define CACHEDBIT_THREAD_SPECIFIC thread
#define CACHEDBIT_METAL_IMPL 1
#define RICEDECODEBLOCKS_METAL_CLZ 1

//#define RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL

// These two symbols must not be defined in Metal compilation mode
//#define EMIT_RICEDECODEBLOCKS_DEBUG_OUTPUT 1
//#define EMIT_CACHEDBITS_DEBUG_OUTPUT 1

// Make sure that DEBUG is not defined in Metal compilation, so that assert() is never compiled
//#define DEBUG
#define PRIVATE_METAL_SHADER_COMPILATION

#import "CachedBits.hpp"
#import "RiceDecodeBlocks.hpp"

//typedef CachedBits<thread uint32_t, const device uint32_t *, uint16_t, uint8_t> CachedBits3216;
typedef CachedBits<thread uint32_t, const device uint32_t *, uint32_t, uint8_t> CachedBits3232;
//typedef CachedBits<thread uint32_t, threadgroup uint32_t *, uint16_t, uint8_t> CachedBits3216Threadgroup;

//typedef CachedBits3216 CachedBitsT;
//typedef RiceDecodeBlocks<CachedBits3216, uint16_t, false> RiceDecodeBlocksT;
typedef RiceDecodeBlocks<CachedBits3232, uint32_t, false> RiceDecodeBlocksT;

// Render a 32x32 block with each threadgroup invocation. Each thread will process
// 1/2 a block so that 32 of the 64 values in a block are processed by each
// thread. This logic reads the prefix, over, rem portions from each stream
// and a single byte value is emitted packed into groups of 4 as BGRA pixels.

kernel void kernel_render_rice2(
                                        texture2d<half, access::write> outTexture [[ texture(0) ]],
                                        constant RiceRenderUniform & riceRenderUniform [[ buffer(0) ]],
                                        device uint32_t *inoutBlockOffsetTable [[ buffer(1) ]],
                                        const device uint32_t *inS32Bits [[ buffer(2) ]],
                                        const device uint8_t *blockOptimalKTable [[ buffer(3) ]],
                                        //ushort2 gid [[ thread_position_in_grid ]],
                                        ushort tid [[ thread_index_in_threadgroup ]],
                                        ushort2 bid [[ threadgroup_position_in_grid ]] // big block blocki
                                        )
{
  // Loop over 1/2 of an 8x8 block of byte values. Byte values are packed
  // into BGRA values so that 16 would be an entire block and 8 would
  // correspond to a half block.
  
  thread RiceDecodeBlocksT rdb;
  
  const ushort blockDim = RICE_SMALL_BLOCK_DIM;
  const ushort bigBlocksDim = 4;
  const ushort numBigBlocksInWidth = (riceRenderUniform.numBlocksInWidth / bigBlocksDim);
  
  int bbid = coords_to_offset(numBigBlocksInWidth, bid);
  
  const ushort blockiInBigBlock = tid >> 1; // tid / 2
  const int blocki = (bbid * bigBlocksDim * bigBlocksDim) + blockiInBigBlock;
  
  uint8_t k = blockOptimalKTable[blocki];

  // tid is a direct offset into the bitOffsets[32] table for this big block
  uint32_t halfBlockStartBitOffset = inoutBlockOffsetTable[int(bbid * 32) + tid];
  
  rdb.cachedBits.initBits(inS32Bits, halfBlockStartBitOffset);
  
  //const int width = ricePrefixRenderUniform.numBlocksInWidth * blockDim;
  
  ushort rowOffset = 0;
  
  // Loop over block of 8x8 block values. Input is parsed as blocks
  // but written in groups of 4 as half4 to the output texture.
  // Render one big block, each thread writes 1/2 an 8x8 block
  // with one compute shader invocation.
  
  // 64 / 4 = 16 : loop 16 times and write 4 bytes per loop
  
  ushort2 bigBlockRootCoords;
  
  {
    // Map bbid to the big block root and convert to (X,Y)
    
    {
      const ushort numBigBlocksInWidth = (riceRenderUniform.numBlocksInWidth / bigBlocksDim);
      ushort bigBlockX = bbid % numBigBlocksInWidth;
      ushort bigBlockY = bbid / numBigBlocksInWidth;
      
      bigBlockRootCoords = ushort2(bigBlockX * (bigBlocksDim * blockDim)/4, bigBlockY * (bigBlocksDim * blockDim));
    }
    
    ushort2 blockRootCoords;
    
    {
      ushort blockX = blockiInBigBlock % bigBlocksDim;
      ushort blockY = blockiInBigBlock / bigBlocksDim;
      blockRootCoords = ushort2(blockX * (blockDim/4), blockY * blockDim);
      
      if (tid & 0x1) {
        // Odd threads render to the half block on the bottom
        rowOffset = blockDim/2;
      }
    }
    
    // Combine bigBlockRootCoords and blockRootCoords
    
    blockRootCoords += bigBlockRootCoords;

    const ushort maxRow = rowOffset + blockDim/2;
    
    for (ushort row = rowOffset; row < maxRow; row++) {
      for (ushort col = 0; col < blockDim/4; col++) {
        // Each col parses 4 prefix byte values
        
        ushort prefixByte0, prefixByte1, prefixByte2, prefixByte3;
        //ushort escape;
        
        // Debug output the block/tid that pixel is written by
        
        if (false) {
          prefixByte0 = tid;
          prefixByte1 = tid;
          prefixByte2 = tid;
          prefixByte3 = tid;
        }
        
        if (false) {
          prefixByte0 = blocki;
          prefixByte1 = blocki;
          prefixByte2 = blocki;
          prefixByte3 = blocki;
        }
        
        if (false) {
          prefixByte0 = k;
          prefixByte1 = 0;
          prefixByte2 = 0;
          prefixByte3 = 0;
        }

        if (false) {
          prefixByte0 = bbid;
          prefixByte1 = halfBlockStartBitOffset;
          prefixByte2 = 0;
          prefixByte3 = 0;
        }
        
        if (false) {
          prefixByte0 = bbid;
          prefixByte1 = 0;
          
          ushort bigBlockX = bbid % numBigBlocksInWidth;
          ushort bigBlockY = bbid / numBigBlocksInWidth;
          
          prefixByte2 = bigBlockX;
          prefixByte3 = bigBlockY;
        }
        
        if (true) {
          prefixByte0  = rdb.decodePrefixByte(k, false, 0, true);
          prefixByte1  = rdb.decodePrefixByte(k, false, 0, false);
          prefixByte2  = rdb.decodePrefixByte(k, false, 0, false);
          prefixByte3  = rdb.decodePrefixByte(k, false, 0, false);
          
          rdb.decodeSuffixByte4x(k, prefixByte0, prefixByte1, prefixByte2, prefixByte3);
        }
        
        ushort2 blockCoords = ushort2(col, row);
        ushort2 outCoords = blockRootCoords + blockCoords;
        
        half4 pixel = half4(uint8_to_half(prefixByte2), uint8_to_half(prefixByte1), uint8_to_half(prefixByte0), uint8_to_half(prefixByte3));
        outTexture.write(pixel, outCoords);
      }
    }
    
    // FIXME: write the number of bits consumed from each stream back to
    // inoutBlockOffsetTablePtr so that another render can progress from
    // where this read operation left off. Note that ushort count of
    // bits for this block should be maintained and then it should be
    // edded back to uint32_t total count.
  
  }
  
  return;
}

#define RICE_WRITE_CACHE
#define RICE_WRITE_CACHE_REVERSE_DELTAS

// Render a 32x32 block with each threadgroup invocation. Each thread will process
// 1/2 a block so that 32 of the 64 values in a block are processed by each
// thread. This logic reads the prefix, over, rem portions from each stream
// and a single byte value is emitted packed into groups of 4 as BGRA pixels.

kernel void kernel_render_rice2_undelta(
                                texture2d<half, access::write> outTexture [[ texture(0) ]],
                                constant RiceRenderUniform & riceRenderUniform [[ buffer(0) ]],
                                device uint32_t *inoutBlockOffsetTable [[ buffer(1) ]],
                                const device uint32_t *inS32Bits [[ buffer(2) ]],
                                const device uint8_t *blockOptimalKTable [[ buffer(3) ]],
                                //ushort2 gid [[ thread_position_in_grid ]],
                                ushort tid [[ thread_index_in_threadgroup ]],
                                ushort2 bid [[ threadgroup_position_in_grid ]] // big block blocki
                                )
{
#if defined(RICE_WRITE_CACHE)
  threadgroup uchar4 writeCache[(32/4)*32];
#endif // RICE_WRITE_CACHE
  
  // Loop over 1/2 of an 8x8 block of byte values. Byte values are packed
  // into BGRA values so that 16 would be an entire block and 8 would
  // correspond to a half block.
  
  thread RiceDecodeBlocksT rdb;
  
  const ushort blockDim = RICE_SMALL_BLOCK_DIM;
  const ushort bigBlocksDim = 4;
  const ushort numBigBlocksInWidth = (riceRenderUniform.numBlocksInWidth / bigBlocksDim);
  
  int bbid = coords_to_offset(numBigBlocksInWidth, bid);
  
  const ushort blockiInBigBlock = tid >> 1; // tid / 2
  
  const int blocki = (bbid * bigBlocksDim * bigBlocksDim) + blockiInBigBlock;
  
  uint8_t k = blockOptimalKTable[blocki];
  
  uint32_t halfBlockStartBitOffset = inoutBlockOffsetTable[int(bbid * 32) + tid];
  
  rdb.cachedBits.initBits(inS32Bits, halfBlockStartBitOffset);
  
  //const int width = ricePrefixRenderUniform.numBlocksInWidth * blockDim;
  
  ushort rowOffset = 0;
  
  // Loop over block of 8x8 block values. Input is parsed as blocks
  // but written in groups of 4 as half4 to the output texture.
  // Render one big block, each thread writes 1/2 an 8x8 block
  // with one compute shader invocation.
  
  // 64 / 4 = 16 : loop 16 times and write 4 bytes per loop
  
  ushort2 bigBlockRootCoords;
  
  {
    // Map bbid to the big block root and convert to (X,Y)
    
    {
      const ushort numBigBlocksInWidth = (riceRenderUniform.numBlocksInWidth / bigBlocksDim);
      ushort bigBlockX = bbid % numBigBlocksInWidth;
      ushort bigBlockY = bbid / numBigBlocksInWidth;
      
      bigBlockRootCoords = ushort2(bigBlockX * (bigBlocksDim * blockDim)/4, bigBlockY * (bigBlocksDim * blockDim));
    }
    
    ushort2 blockRootCoords;
    
    {
      ushort blockX = blockiInBigBlock % bigBlocksDim;
      ushort blockY = blockiInBigBlock / bigBlocksDim;
      blockRootCoords = ushort2(blockX * (blockDim/4), blockY * blockDim);
      
      if (tid & 0x1) {
        // Odd threads render to the half block on the bottom
        rowOffset = blockDim/2;
      }
    }
    
    // Combine bigBlockRootCoords and blockRootCoords
    
    blockRootCoords += bigBlockRootCoords;
    
    const ushort maxRow = rowOffset + blockDim/2;
    
    for (ushort row = rowOffset; row < maxRow; row++) {
      for (ushort col = 0; col < blockDim/4; col++) {
        // Each col parses 4 prefix byte values
        
        ushort prefixByte0, prefixByte1, prefixByte2, prefixByte3;
        //ushort escape;
        
        // Debug output the block/tid that pixel is written by
        
        if (false) {
          prefixByte0 = tid;
          prefixByte1 = tid;
          prefixByte2 = tid;
          prefixByte3 = tid;
        }
        
        if (false) {
          prefixByte0 = blocki;
          prefixByte1 = blocki;
          prefixByte2 = blocki;
          prefixByte3 = blocki;
        }
        
        if (false) {
          prefixByte0 = k;
          prefixByte1 = 0;
          prefixByte2 = 0;
          prefixByte3 = 0;
        }
        
        if (false) {
          prefixByte0 = bbid;
          prefixByte1 = halfBlockStartBitOffset;
          prefixByte2 = 0;
          prefixByte3 = 0;
        }
        
        if (false) {
          prefixByte0 = bbid;
          prefixByte1 = 0;
          
          ushort bigBlockX = bbid % numBigBlocksInWidth;
          ushort bigBlockY = bbid / numBigBlocksInWidth;
          
          prefixByte2 = bigBlockX;
          prefixByte3 = bigBlockY;
        }
        
        if (true) {
          prefixByte0  = rdb.decodePrefixByte(k, false, 0, true);
          prefixByte1  = rdb.decodePrefixByte(k, false, 0, false);
          prefixByte2  = rdb.decodePrefixByte(k, false, 0, false);
          prefixByte3  = rdb.decodePrefixByte(k, false, 0, false);
          
          rdb.decodeSuffixByte4x(k, prefixByte0, prefixByte1, prefixByte2, prefixByte3);
        }

        ushort2 blockCoords = ushort2(col, row);
        ushort2 outCoords = blockRootCoords + blockCoords;
        
#if defined(RICE_WRITE_CACHE)
        // Write to uchar4 formatted bytes cache
        
        // FIXME: generate big block relative outCoords that does not include bigBlockRootCoords outside of loop
        ushort2 outCoordsBigBlockRelative = outCoords - bigBlockRootCoords;
        int writeCacheOffset = (outCoordsBigBlockRelative.y * 32/4) + outCoordsBigBlockRelative.x;
        uchar4 pixel = uchar4(prefixByte0, prefixByte1, prefixByte2, prefixByte3);
        writeCache[writeCacheOffset] = pixel;
#else
        half4 pixel = half4(uint8_to_half(prefixByte2), uint8_to_half(prefixByte1), uint8_to_half(prefixByte0), uint8_to_half(prefixByte3));
        outTexture.write(pixel, outCoords);
#endif // RICE_WRITE_CACHE
      }
    }
    
    // FIXME: write the number of bits consumed from each stream back to
    // inoutBlockOffsetTablePtr so that another render can progress from
    // where this read operation left off. Note that ushort count of
    // bits for this block should be maintained and then it should be
    // edded back to uint32_t total count.
    
#if defined(RICE_WRITE_CACHE_REVERSE_DELTAS)
    // Reverse delta operation by adding each element to the previous sums
    
    //threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Sum each element in each row on the same thread.
    
    {
      const ushort THREADGROUP_1D_DIM4 = 32/4;
      const ushort THREADGROUP_2D_NUM_ROWS = 32;
      
      // Process sum of column 0 elements, row by row, on thread 0
      
      if (tid == 0) {
        uint8_t sum;
        
        // Special case handler for (0,0) since this value is not a delta.
        // Do not reverse zigzag encoding, init sum, do not write back to
        // shared memory slot since value was not changed.
        
        {
          const int i = 0;
          const int offsetT = (i * THREADGROUP_1D_DIM4);
          
          uchar4 vec = writeCache[offsetT];
          
          uint8_t val;
          
          val = vec[0];
          sum = val;
          //vec[0] = sum;
          
          // Write offset for column 0 transposed into shared_memory
          
          //writeCache[offsetT] = vec;
        }
        
        for (int i = 1; i < THREADGROUP_2D_NUM_ROWS; i++) {
          const int offsetT = (i * THREADGROUP_1D_DIM4);
          
          uchar4 vec = writeCache[offsetT];
          
          uint8_t val;
          
          val = vec[0];
          sum += (uint8_t) zigzag_offset_to_num_neg(val);
          vec[0] = sum;
          
          // Write offset for column 0 transposed into shared_memory
          
          writeCache[offsetT] = vec;
        }
      }
      
      //threadgroup_barrier(mem_flags::mem_threadgroup);
      
      const int rowStartSharedWordOffset = (tid * THREADGROUP_1D_DIM4);
      
      uint8_t sum = 0;
      
      {
        const int i = 0;
        uchar4 vec = writeCache[rowStartSharedWordOffset+i];
        
        uint8_t val;
        
        val = vec[0];
        // No zigzag decode for value in column 0
        sum += val;
        vec[0] = sum;
        
        val = vec[1];
        sum += (uint8_t) zigzag_offset_to_num_neg(val);
        vec[1] = sum;
        
        val = vec[2];
        sum += (uint8_t) zigzag_offset_to_num_neg(val);
        vec[2] = sum;
        
        val = vec[3];
        sum += (uint8_t) zigzag_offset_to_num_neg(val);
        vec[3] = sum;
        
        writeCache[rowStartSharedWordOffset+i] = vec;
      }
      
      for (int i = 1; i < THREADGROUP_1D_DIM4; i++) {
        uchar4 vec = writeCache[rowStartSharedWordOffset+i];
        
        uint8_t val;
        
        val = vec[0];
        sum += (uint8_t) zigzag_offset_to_num_neg(val);
        vec[0] = sum;
        
        val = vec[1];
        sum += (uint8_t) zigzag_offset_to_num_neg(val);
        vec[1] = sum;
        
        val = vec[2];
        sum += (uint8_t) zigzag_offset_to_num_neg(val);
        vec[2] = sum;
        
        val = vec[3];
        sum += (uint8_t) zigzag_offset_to_num_neg(val);
        vec[3] = sum;
        
        writeCache[rowStartSharedWordOffset+i] = vec;
      }
    }
#endif
    
#if defined(RICE_WRITE_CACHE)
    //threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Write each value in a single thread, correct output but 3X slower
    
    //    if (tid == 0) {
    //      const ushort THREADGROUP_1D_DIM = 32;
    //      const ushort THREADGROUP_1D_DIM4 = 32/4;
    //
    //      for (ushort row = 0; row < THREADGROUP_1D_DIM; row++) {
    //        for (ushort col = 0; col < THREADGROUP_1D_DIM4; col++) {
    //          ushort writeCacheOffset = (row * THREADGROUP_1D_DIM4) + col;
    //
    //          ushort2 bigBlockCoords = ushort2(col, row);
    //          ushort2 outCoords = bigBlockRootCoords + bigBlockCoords;
    //
    //          uchar4 inPixel = writeCache[writeCacheOffset];
    //
    //          half4 outPixel = half4(uint8_to_half(inPixel[2]), uint8_to_half(inPixel[1]), uint8_to_half(inPixel[0]), uint8_to_half(inPixel[3]));
    //          outTexture.write(outPixel, outCoords);
    //        }
    //      }
    //    }


    // Copy from writeCache to 2D outTexture with 1 thread per row, each write
    // emity all the Y values for a single column.
    
    if (0)
    {
      const ushort THREADGROUP_1D_DIM4 = 32/4;
      const int sharedRowWordOffset = tid * THREADGROUP_1D_DIM4;
      
      ushort2 blockRowCoords = bigBlockRootCoords;
      blockRowCoords.y += tid;
      
      for ( int col = 0; col < THREADGROUP_1D_DIM4; col++ ) {
        ushort2 blockCoords = blockRowCoords;
        
        blockCoords.x += col;
        
        half4 outPixelsVec;
        
        uchar4 vec = writeCache[sharedRowWordOffset+col];
        
        outPixelsVec[0] = uint8_to_half(vec[2]); // R
        outPixelsVec[1] = uint8_to_half(vec[1]); // G
        outPixelsVec[2] = uint8_to_half(vec[0]); // B
        outPixelsVec[3] = uint8_to_half(vec[3]); // A
        
        outTexture.write(outPixelsVec, blockCoords);
      }
    }

    // Copy from writeCache to 2D outTexture by reading from
    // and then writing to (X,Y) calculated from incrementing
    // big block offset. This should combine reads and writes
    // and it appears to be just slightly faster than above approach.
    
    if (1)
    {
      const ushort THREADGROUP_1D_DIM = 32;
      const ushort THREADGROUP_1D_DIM4 = 32/4;
      
      // A row contains 8 words, so 4 rows can be read and
      // written with 32 threads. A total of 8 of these
      // read/write operations will be needed to
      // read and write all values.
      
      // read/write rows (0, 3) then (4, 7) ...
      
      for ( ushort rw = 0; rw < 8; rw++ ) {
        const ushort offset = (rw * THREADGROUP_1D_DIM) + tid;
        const ushort row = offset / THREADGROUP_1D_DIM4;
        const ushort col = offset % THREADGROUP_1D_DIM4;
        
        half4 outPixelsVec;
        
        uchar4 vec = writeCache[offset];
        
        outPixelsVec[0] = uint8_to_half(vec[2]); // R
        outPixelsVec[1] = uint8_to_half(vec[1]); // G
        outPixelsVec[2] = uint8_to_half(vec[0]); // B
        outPixelsVec[3] = uint8_to_half(vec[3]); // A
        
        ushort2 bigBlockCoords = ushort2(col, row);
        ushort2 outCoords = bigBlockRootCoords + bigBlockCoords;
        
        outTexture.write(outPixelsVec, outCoords);
      }
    }
        
#endif // RICE_WRITE_CACHE
  }
  
  return;
}

kernel void kernel_render_rice2_blocki(
                                texture2d<half, access::write> outTexture [[ texture(0) ]],
                                constant RiceRenderUniform & riceRenderUniform [[ buffer(0) ]],
                                device uint32_t *inoutBlockOffsetTable [[ buffer(1) ]],
                                const device uint32_t *inS32Bits [[ buffer(2) ]],
                                const device uint8_t *blockOptimalKTable [[ buffer(3) ]],
                                device uint32_t *out32Ptr [[ buffer(4) ]],
                                //ushort2 gid [[ thread_position_in_grid ]],
                                ushort tid [[ thread_index_in_threadgroup ]],
                                ushort2 bid [[ threadgroup_position_in_grid ]] // big block blocki
                                )
{
  // Loop over 1/2 of an 8x8 block of byte values. Byte values are packed
  // into BGRA values so that 16 would be an entire block and 8 would
  // correspond to a half block.
  
  // Thread specific bit stream and registers
  thread RiceDecodeBlocksT rdb;
  
  const ushort blockDim = RICE_SMALL_BLOCK_DIM;
  const ushort bigBlocksDim = 4;
  const ushort numBigBlocksInWidth = (riceRenderUniform.numBlocksInWidth / bigBlocksDim);
  
  uint bbid = coords_to_offset(numBigBlocksInWidth, bid);
  
  const ushort blockiInBigBlock = tid >> 1; // tid / 2
  const int blocki = (bbid * bigBlocksDim * bigBlocksDim) + blockiInBigBlock;
  
  // Since device memory is read only 1 time per thread, do not need
  // to copy K table memory into shared memory.
  uint8_t k = blockOptimalKTable[blocki];
  
  uint32_t prefixBlockStartBitOffset = inoutBlockOffsetTable[int(bbid * 32) + tid];
  rdb.cachedBits.initBits(inS32Bits, prefixBlockStartBitOffset);
  
  //const int width = ricePrefixRenderUniform.numBlocksInWidth * blockDim;
  
  ushort rowOffset = 0;
  
  // Loop over block of 8x8 block values. Input is parsed as blocks
  // but written in groups of 4 as half4 to the output texture.
  // Render one big block, each thread writes 1/2 an 8x8 block
  // with one compute shader invocation.
  
  // 64 / 4 = 16 : loop 16 times and write 4 bytes per loop
  
  {
    // Map blocki to the big block root and convert to (X,Y)
    
    ushort2 bigBlockRootCoords;
    
    {
      const ushort numBigBlocksInWidth = (riceRenderUniform.numBlocksInWidth / bigBlocksDim);
      ushort bigBlockX = bbid % numBigBlocksInWidth;
      ushort bigBlockY = bbid / numBigBlocksInWidth;
      
      bigBlockRootCoords = ushort2(bigBlockX * (bigBlocksDim * blockDim)/4, bigBlockY * (bigBlocksDim * blockDim));
    }
    
    ushort2 blockRootCoords;
    
    {
      ushort blockX = blockiInBigBlock % bigBlocksDim;
      ushort blockY = blockiInBigBlock / bigBlocksDim;
      blockRootCoords = ushort2(blockX * (blockDim/4), blockY * blockDim);
      
      if (tid & 0x1) {
        // Odd threads render to the half block on the bottom
        rowOffset = blockDim/2;
      }
    }
    
    // Combine bigBlockRootCoords and blockRootCoords
    
    blockRootCoords += bigBlockRootCoords;
    
    const ushort maxRow = rowOffset + blockDim/2;
    
    for (ushort row = rowOffset; row < maxRow; row++) {
      for (ushort col = 0; col < blockDim/4; col++) {
        // Each col parses 4 prefix byte values
        
        ushort prefixByte0, prefixByte1, prefixByte2, prefixByte3;
        
        // Debug output the block/tid that pixel is written by
        
        if (false) {
          prefixByte0 = tid;
          prefixByte1 = tid;
          prefixByte2 = tid;
          prefixByte3 = tid;
        }
        
        if (false) {
          prefixByte0 = blocki;
          prefixByte1 = blocki;
          prefixByte2 = blocki;
          prefixByte3 = blocki;
        }
        
        if (false) {
          prefixByte0 = k;
          prefixByte1 = 0;
          prefixByte2 = 0;
          prefixByte3 = 0;
        }
        
        if (false) {
          prefixByte0 = bbid;
          prefixByte1 = prefixBlockStartBitOffset;
          prefixByte2 = 0;
          prefixByte3 = 0;
        }
        
        if (false) {
          prefixByte0 = bbid;
          prefixByte1 = 0;
          
          ushort bigBlockX = bbid % numBigBlocksInWidth;
          ushort bigBlockY = bbid / numBigBlocksInWidth;
          
          prefixByte2 = bigBlockX;
          prefixByte3 = bigBlockY;
        }
        
        ushort2 blockCoords = ushort2(col, row);
        ushort2 outCoords = blockRootCoords + blockCoords;
        
        //half4 pixel = half4(uint8_to_half(prefixByte2), uint8_to_half(prefixByte1), uint8_to_half(prefixByte0), uint8_to_half(prefixByte3));
        //outTexture.write(pixel, outCoords);
        
        // write blocki to 32 bit output array
        
        if (true) {
          int width = riceRenderUniform.numBlocksInWidth * blockDim;
          int offset = (outCoords.y * width) + (outCoords.x * 4);
          
          out32Ptr[offset+0] = blocki;
          out32Ptr[offset+1] = blocki;
          out32Ptr[offset+2] = blocki;
          out32Ptr[offset+3] = blocki;
        }
      }
    }
    
    // FIXME: write the number of bits consumed from each stream back to
    // inoutBlockOffsetTablePtr so that another render can progress from
    // where this read operation left off. Note that ushort count of
    // bits for this block should be maintained and then it should be
    // edded back to uint32_t total count.
  }
  
  return;
}

// Write the bit offset for each half block for each symbol

kernel void kernel_render_rice2_block_bit_offset(
                                       texture2d<half, access::write> outTexture [[ texture(0) ]],
                                       constant RiceRenderUniform & riceRenderUniform [[ buffer(0) ]],
                                       device uint32_t *inoutBlockOffsetTable [[ buffer(1) ]],
                                       const device uint32_t *inS32Bits [[ buffer(2) ]],
                                       const device uint8_t *blockOptimalKTable [[ buffer(3) ]],
                                       device uint32_t *out32Ptr [[ buffer(4) ]],
                                       //ushort2 gid [[ thread_position_in_grid ]],
                                       ushort tid [[ thread_index_in_threadgroup ]],
                                       ushort2 bid [[ threadgroup_position_in_grid ]] // big block blocki
                                       )
{
  // Loop over 1/2 of an 8x8 block of byte values. Byte values are packed
  // into BGRA values so that 16 would be an entire block and 8 would
  // correspond to a half block.
  
  // Thread specific bit stream and registers
  thread RiceDecodeBlocksT rdb;
  
  const ushort blockDim = RICE_SMALL_BLOCK_DIM;
  const ushort bigBlocksDim = 4;
  const ushort numBigBlocksInWidth = (riceRenderUniform.numBlocksInWidth / bigBlocksDim);
  
  uint bbid = coords_to_offset(numBigBlocksInWidth, bid);
  
  const ushort blockiInBigBlock = tid >> 1; // tid / 2
  const int blocki = (bbid * bigBlocksDim * bigBlocksDim) + blockiInBigBlock;
  
  // Since device memory is read only 1 time per thread, do not need
  // to copy K table memory into shared memory.
  uint8_t k = blockOptimalKTable[blocki];
  
  uint32_t prefixBlockStartBitOffset = inoutBlockOffsetTable[int(bbid * 32) + tid];
  rdb.cachedBits.initBits(inS32Bits, prefixBlockStartBitOffset);
  
  //const int width = ricePrefixRenderUniform.numBlocksInWidth * blockDim;
  
  ushort rowOffset = 0;
  
  // Loop over block of 8x8 block values. Input is parsed as blocks
  // but written in groups of 4 as half4 to the output texture.
  // Render one big block, each thread writes 1/2 an 8x8 block
  // with one compute shader invocation.
  
  // 64 / 4 = 16 : loop 16 times and write 4 bytes per loop
  
  //const bool enableEscapeAdd = true;
  //const bool enableEscapeOnly = false;
  
  {
    // Map blocki to the big block root and convert to (X,Y)
    
    ushort2 bigBlockRootCoords;
    
    {
      const ushort numBigBlocksInWidth = (riceRenderUniform.numBlocksInWidth / bigBlocksDim);
      ushort bigBlockX = bbid % numBigBlocksInWidth;
      ushort bigBlockY = bbid / numBigBlocksInWidth;
      
      bigBlockRootCoords = ushort2(bigBlockX * (bigBlocksDim * blockDim)/4, bigBlockY * (bigBlocksDim * blockDim));
    }
    
    ushort2 blockRootCoords;
    
    {
      ushort blockX = blockiInBigBlock % bigBlocksDim;
      ushort blockY = blockiInBigBlock / bigBlocksDim;
      blockRootCoords = ushort2(blockX * (blockDim/4), blockY * blockDim);
      
      if (tid & 0x1) {
        // Odd threads render to the half block on the bottom
        rowOffset = blockDim/2;
      }
    }
    
    // Combine bigBlockRootCoords and blockRootCoords
    
    blockRootCoords += bigBlockRootCoords;
    
    const ushort maxRow = rowOffset + blockDim/2;
    
    for (ushort row = rowOffset; row < maxRow; row++) {
      for (ushort col = 0; col < blockDim/4; col++) {
        // Each col parses 4 prefix byte values
        
        ushort prefixByte0, prefixByte1, prefixByte2, prefixByte3;
        //ushort escape;
        
        // Debug output the block/tid that pixel is written by
        
        if (false) {
          prefixByte0 = tid;
          prefixByte1 = tid;
          prefixByte2 = tid;
          prefixByte3 = tid;
        }
        
        if (false) {
          prefixByte0 = blocki;
          prefixByte1 = blocki;
          prefixByte2 = blocki;
          prefixByte3 = blocki;
        }
        
        if (false) {
          prefixByte0 = k;
          prefixByte1 = 0;
          prefixByte2 = 0;
          prefixByte3 = 0;
        }
        
        if (false) {
          prefixByte0 = bbid;
          prefixByte1 = prefixBlockStartBitOffset;
          prefixByte2 = 0;
          prefixByte3 = 0;
        }
        
        if (false) {
          prefixByte0 = bbid;
          prefixByte1 = 0;
          
          ushort bigBlockX = bbid % numBigBlocksInWidth;
          ushort bigBlockY = bbid / numBigBlocksInWidth;
          
          prefixByte2 = bigBlockX;
          prefixByte3 = bigBlockY;
        }
                
        ushort2 blockCoords = ushort2(col, row);
        ushort2 outCoords = blockRootCoords + blockCoords;
        
        //half4 pixel = half4(uint8_to_half(prefixByte2), uint8_to_half(prefixByte1), uint8_to_half(prefixByte0), uint8_to_half(prefixByte3));
        //outTexture.write(pixel, outCoords);
        
        // write blocki to 32 bit output array
        
        if (true) {
          int width = riceRenderUniform.numBlocksInWidth * blockDim;
          int offset = (outCoords.y * width) + (outCoords.x * 4);
          
          out32Ptr[offset+0] = prefixBlockStartBitOffset;
          out32Ptr[offset+1] = prefixBlockStartBitOffset;
          out32Ptr[offset+2] = prefixBlockStartBitOffset;
          out32Ptr[offset+3] = prefixBlockStartBitOffset;
        }
      }
    }
    
    // FIXME: write the number of bits consumed from each stream back to
    // inoutBlockOffsetTablePtr so that another render can progress from
    // where this read operation left off. Note that ushort count of
    // bits for this block should be maintained and then it should be
    // edded back to uint32_t total count.
  }
  
  return;
}
