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

// Compute shader to process column 0 and then row by row sum with
// BGRA inputs (vector of 4 bytes).

kernel void kernel_passthrough_bytes_to_bgra(
                                                             texture2d<half, access::read> inTexture [[ texture(0) ]],
                                                             texture2d<half, access::write> outTexture [[ texture(1) ]],
                                                             ushort2 gid [[ thread_position_in_grid ]],
                                                             ushort tid [[ thread_index_in_threadgroup ]],
                                                             ushort2 bid [[ threadgroup_position_in_grid ]]
                                                             //ushort2 blockDim [[ threads_per_threadgroup ]]
                                                             ) {
    // Foreach output pixel, read 4 byte values and write
    // these values to the output texture as vector of 4 values

    half4 outPixelsVec;

    ushort2 inGid;
    inGid.y = gid.y;
    inGid.x = gid.x * 4;
    
    for (int i = 0; i < 4; i++) {
        ushort2 inGidPlusi = inGid;
        inGidPlusi.x += i;
        half inPixel = inTexture.read(inGidPlusi).x; // Input is grayscale
        outPixelsVec[i] = inPixel;
    }
    
    // Swap B and R
    half tmp = outPixelsVec[0];
    outPixelsVec[0] = outPixelsVec[2];
    outPixelsVec[2] = tmp;
    
    outTexture.write(outPixelsVec, gid);
}

// Compute shader to process column 0 and then row by row sum with
// BGRA inputs (vector of 4 bytes).

kernel void kernel_column_row_sum_2D_bytes_dim1024_threads32_nozigzag(
                                                             texture2d<half, access::read> inTexture [[ texture(0) ]],
                                                             texture2d<half, access::write> outTexture [[ texture(1) ]],
                                                             ushort2 gid [[ thread_position_in_grid ]],
                                                             ushort tid [[ thread_index_in_threadgroup ]],
                                                             ushort2 bid [[ threadgroup_position_in_grid ]]
                                                             //ushort2 blockDim [[ threads_per_threadgroup ]]
                                                             ) {
  // FIXME: go back an optimize use of int values in this
  // logic so that ushort is used every place that the
  // value wil fit into a 16 bit register.
  
  const ushort NUM_THREADS = 32; // 32 threads in threadgroup
  const ushort THREADGROUP_1D_DIM = 32; // height
  const ushort THREADGROUP_1D_DIM4 = THREADGROUP_1D_DIM/4; // width / 4
  const ushort THREADGROUP_2D_NUM_ROWS = THREADGROUP_1D_DIM;
  
  // Input/Output dimensions in 2D
  const ushort width4 = inTexture.get_width();
  const ushort height = inTexture.get_height();
  const ushort2 inTextureSize = ushort2(width4, height);
  
  const ushort2 blockDimensions = ushort2(THREADGROUP_1D_DIM4, THREADGROUP_1D_DIM);
  const ushort numBlocksInWidth = (width4 * 4) / THREADGROUP_1D_DIM;
  const ushort numBlocksInHeight = height / THREADGROUP_1D_DIM;
  
  threadgroup uchar4 shared_memory[THREADGROUP_1D_DIM4 * THREADGROUP_1D_DIM];
  
  // Get blocki for this thread and threadgroup
  const uint blocki = coords_to_offset(numBlocksInWidth, bid);
  
  // Get block root coords in terms of 8x32 word coordinates
  //ushort2 blockRootCoords = offset_to_coords(width4, blocki * (THREADGROUP_1D_DIM4 * THREADGROUP_1D_DIM));
  
  ushort2 blockRootCoords = offset_to_coords(numBlocksInWidth, blocki);
  blockRootCoords *= blockDimensions;
  
  // Copy all input pixels from texture to shared memory
  {
    int sharedRowWordOffset = tid * THREADGROUP_1D_DIM4;
    
    ushort2 blockRowCoords = blockRootCoords;
    blockRowCoords.y += tid;
    
    for ( int col = 0; col < THREADGROUP_1D_DIM4; col++ ) {
      ushort2 blockCoords = blockRowCoords;
      blockCoords.x += col;
      
      // coalescing 2D column read:
      //
      // (0,0) to (0, 31)
      // (1,0) to (1, 31)
      // ...
      // (7,0) to (7, 31)
      
      half4 inPixelsVec = inTexture.read(blockCoords);
      
      uchar4 vec;
      
      vec[0] = uint8_from_half(inPixelsVec[2]); // R
      vec[1] = uint8_from_half(inPixelsVec[1]); // G
      vec[2] = uint8_from_half(inPixelsVec[0]); // B
      vec[3] = uint8_from_half(inPixelsVec[3]); // A
      
      shared_memory[sharedRowWordOffset+col] = vec;
    }
  }
  
  threadgroup_barrier(mem_flags::mem_threadgroup);
  
  // Process sum of column 0 elements, row by row, on thread 0
  
  if (tid == 0) {
    uint8_t sum = 0;
    
    for (int i = 0; i < THREADGROUP_2D_NUM_ROWS; i++) {
      int offsetT = (i * THREADGROUP_1D_DIM4);
      
      uchar4 vec = shared_memory[offsetT];
      
      uint8_t val;
      
      val = vec[0];
      sum += val;
      vec[0] = sum;
      
      // Write offset for column 0 transposed into shared_memory
      
      shared_memory[offsetT] = vec;
    }
  }
  
  threadgroup_barrier(mem_flags::mem_threadgroup);
  
  // Sum each element in each row on the same thread.
  
  {
    const int rowStartSharedWordOffset = (tid * THREADGROUP_1D_DIM4);
    
    uint8_t sum = 0;
    
    for (int i = 0; i < THREADGROUP_1D_DIM4; i++) {
      uchar4 vec = shared_memory[rowStartSharedWordOffset+i];
      
      uint8_t val;
      
      val = vec[0];
      sum += val;
      vec[0] = sum;
      
      val = vec[1];
      sum += val;
      vec[1] = sum;
      
      val = vec[2];
      sum += val;
      vec[2] = sum;
      
      val = vec[3];
      sum += val;
      vec[3] = sum;
      
      shared_memory[rowStartSharedWordOffset+i] = vec;
    }
  }
  
  threadgroup_barrier(mem_flags::mem_threadgroup);
  
  // Copy from shared_memory to outTexture with 1 thread per row
  
  {
    int sharedRowWordOffset = tid * THREADGROUP_1D_DIM4;
    
    ushort2 blockRowCoords = blockRootCoords;
    blockRowCoords.y += tid;
    
    for ( int col = 0; col < THREADGROUP_1D_DIM4; col++ ) {
      ushort2 blockCoords = blockRowCoords;
      
      blockCoords.x += col;
      
      half4 outPixelsVec;
      
      uchar4 vec = shared_memory[sharedRowWordOffset+col];
      
      outPixelsVec[0] = uint8_to_half(vec[2]); // R
      outPixelsVec[1] = uint8_to_half(vec[1]); // G
      outPixelsVec[2] = uint8_to_half(vec[0]); // B
      outPixelsVec[3] = uint8_to_half(vec[3]); // A
      
      outTexture.write(outPixelsVec, blockCoords);
    }
  }
}

// Compute shader to process column 0 and then row by row sum with
// BGRA inputs (vector of 4 bytes). Note that zigzag encoding
// would not be applied to (0,0) but it would have been applied
// to all the delta values.

kernel void kernel_column_row_sum_2D_bytes_dim1024_threads32(
                                                             texture2d<half, access::read> inTexture [[ texture(0) ]],
                                                             texture2d<half, access::write> outTexture [[ texture(1) ]],
                                                             ushort2 gid [[ thread_position_in_grid ]],
                                                             ushort tid [[ thread_index_in_threadgroup ]],
                                                             ushort2 bid [[ threadgroup_position_in_grid ]]
                                                             //ushort2 blockDim [[ threads_per_threadgroup ]]
                                                             ) {
    // FIXME: go back an optimize use of int values in this
    // logic so that ushort is used every place that the
    // value wil fit into a 16 bit register.
    
    const ushort NUM_THREADS = 32; // 32 threads in threadgroup
    const ushort THREADGROUP_1D_DIM = 32; // height
    const ushort THREADGROUP_1D_DIM4 = THREADGROUP_1D_DIM/4; // width / 4
    const ushort THREADGROUP_2D_NUM_ROWS = THREADGROUP_1D_DIM;
    
    // Input/Output dimensions in 2D
    const ushort width4 = inTexture.get_width();
    const ushort height = inTexture.get_height();
    const ushort2 inTextureSize = ushort2(width4, height);
    
    const ushort2 blockDimensions = ushort2(THREADGROUP_1D_DIM4, THREADGROUP_1D_DIM);
    const ushort numBlocksInWidth = (width4 * 4) / THREADGROUP_1D_DIM;
    const ushort numBlocksInHeight = height / THREADGROUP_1D_DIM;
    
    threadgroup uchar4 shared_memory[THREADGROUP_1D_DIM4 * THREADGROUP_1D_DIM];
    
    // Get blocki for this thread and threadgroup
    const uint blocki = coords_to_offset(numBlocksInWidth, bid);
    
    // Get block root coords in terms of 8x32 word coordinates
    //ushort2 blockRootCoords = offset_to_coords(width4, blocki * (THREADGROUP_1D_DIM4 * THREADGROUP_1D_DIM));
    
    ushort2 blockRootCoords = offset_to_coords(numBlocksInWidth, blocki);
    blockRootCoords *= blockDimensions;
    
    // Copy all input pixels from texture to shared memory
    {
        int sharedRowWordOffset = tid * THREADGROUP_1D_DIM4;
        
        ushort2 blockRowCoords = blockRootCoords;
        blockRowCoords.y += tid;
        
        for ( int col = 0; col < THREADGROUP_1D_DIM4; col++ ) {
            ushort2 blockCoords = blockRowCoords;
            blockCoords.x += col;
            
            // coalescing 2D column read:
            //
            // (0,0) to (0, 31)
            // (1,0) to (1, 31)
            // ...
            // (7,0) to (7, 31)
            
            half4 inPixelsVec = inTexture.read(blockCoords);
            
            uchar4 vec;
            
            vec[0] = uint8_from_half(inPixelsVec[2]); // R
            vec[1] = uint8_from_half(inPixelsVec[1]); // G
            vec[2] = uint8_from_half(inPixelsVec[0]); // B
            vec[3] = uint8_from_half(inPixelsVec[3]); // A
            
            shared_memory[sharedRowWordOffset+col] = vec;
        }
    }
    
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Process sum of column 0 elements, row by row, on thread 0
    
    if (tid == 0) {
        uint8_t sum;

        // Special case handler for (0,0) since this value is not a delta.
        // Do not reverse zigzag encoding, init sum, do not write back to
        // shared memory slot since value was not changed.

        {
            const int i = 0;
            const int offsetT = (i * THREADGROUP_1D_DIM4);
            
            uchar4 vec = shared_memory[offsetT];
            
            uint8_t val;
            
            val = vec[0];
            sum = val;
            //vec[0] = sum;
            
            // Write offset for column 0 transposed into shared_memory
            
            //shared_memory[offsetT] = vec;
        }
      
        for (int i = 1; i < THREADGROUP_2D_NUM_ROWS; i++) {
            int offsetT = (i * THREADGROUP_1D_DIM4);
            
            uchar4 vec = shared_memory[offsetT];
            
            uint8_t val;
            
            val = vec[0];
            sum += (uint8_t) zigzag_offset_to_num_neg(val);
            vec[0] = sum;
            
            // Write offset for column 0 transposed into shared_memory
            
            shared_memory[offsetT] = vec;
        }
    }
    
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Sum each element in each row on the same thread.
    
    {
        const int rowStartSharedWordOffset = (tid * THREADGROUP_1D_DIM4);
        
        uint8_t sum = 0;
        
        /*
        
        for (int i = 0; i < THREADGROUP_1D_DIM4; i++) {
            uchar4 vec = shared_memory[rowStartSharedWordOffset+i];
            
            uint8_t val;
            
            val = vec[0];
            sum += val;
            vec[0] = sum;
            
            val = vec[1];
            sum += val;
            vec[1] = sum;
            
            val = vec[2];
            sum += val;
            vec[2] = sum;
            
            val = vec[3];
            sum += val;
            vec[3] = sum;
            
            shared_memory[rowStartSharedWordOffset+i] = vec;
        }
         
        */
        
        {
            const int i = 0;
            uchar4 vec = shared_memory[rowStartSharedWordOffset+i];
            
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
            
            shared_memory[rowStartSharedWordOffset+i] = vec;
        }
        
        for (int i = 1; i < THREADGROUP_1D_DIM4; i++) {
            uchar4 vec = shared_memory[rowStartSharedWordOffset+i];
            
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
            
            shared_memory[rowStartSharedWordOffset+i] = vec;
        }
    }
    
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    // Copy from shared_memory to outTexture with 1 thread per row
    
    {
        int sharedRowWordOffset = tid * THREADGROUP_1D_DIM4;
        
        ushort2 blockRowCoords = blockRootCoords;
        blockRowCoords.y += tid;
        
        for ( int col = 0; col < THREADGROUP_1D_DIM4; col++ ) {
            ushort2 blockCoords = blockRowCoords;
            
            blockCoords.x += col;
            
            half4 outPixelsVec;
            
            uchar4 vec = shared_memory[sharedRowWordOffset+col];
            
            outPixelsVec[0] = uint8_to_half(vec[2]); // R
            outPixelsVec[1] = uint8_to_half(vec[1]); // G
            outPixelsVec[2] = uint8_to_half(vec[0]); // B
            outPixelsVec[3] = uint8_to_half(vec[3]); // A
            
            outTexture.write(outPixelsVec, blockCoords);
        }
    }
}

