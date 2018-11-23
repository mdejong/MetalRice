//
//  block.hpp
//
//  Created by Mo DeJong on 6/3/18.
//  Copyright © 2018 helpurock. All rights reserved.
//
//  The block processing logic creates an optimized
//  block by block segmentation of the input symbols
//  and processes them to convert to base and deltas.
//  Note that a second round of deltas on the base
//  symbols for each block improves compression.

#ifndef block_hpp
#define block_hpp

#include <stdio.h>

#include <cinttypes>
#include <vector>
#include <bitset>

using namespace std;

// This optimized version of splitIntoBlocksOfSize operates
// on type T values. The input buffer is not padded with
// zeros while the output buffer is. Note that the input buffer
// need not be the same block dimensions as the padded output
// as any data not in the input blocks is written as the zeroValue.

template <typename T>
void splitIntoBlocksOfSize(
                           const unsigned int blockSize,
                           const T *inPixels,
                           unsigned int width,
                           unsigned int height,
                           unsigned int inNumBlocksWidth,
                           unsigned int inNumBlocksHeight,
                           T *outPixels,
                           unsigned int outNumBlocksWidth,
                           unsigned int outNumBlocksHeight,
                           T zeroValue)
{
    const bool debug = false;
  
    // Loop over blockSize bytes at a time appending one row of block
    // values at a time to a specific block pointer.
    
    const unsigned int numPixelsInOneBlock = blockSize * blockSize;
    
    //const unsigned int inBlockMax = inNumBlocksWidth * inNumBlocksHeight;
    const unsigned int outBlockMax = outNumBlocksWidth * outNumBlocksHeight;
    
    //const unsigned int inNumPixelsInAllBlocks = numPixelsInOneBlock * inBlockMax;
    const unsigned int outNumPixelsInAllBlocks = numPixelsInOneBlock * outBlockMax;
    
    // zero out block memory to a known init value, any bytes not written
    // over in the loop below will remain the zero padding value.
    
    if (zeroValue == 0) {
        memset(outPixels, 0, outNumPixelsInAllBlocks * sizeof(T));
    } else {
        for (int i = 0; i < outNumPixelsInAllBlocks; i++ ) {
            outPixels[i] = zeroValue;
        }
    }
    
    // This array of pointers points to the next available address
    // for each output block. As a block is filled in row by row this
    // address is updated to account for the row that was written.
    // Note that a very very large allocation on the stack would fail.
    
    vector<T*> outBlockStartPtrs(outNumBlocksWidth * outNumBlocksHeight);
    assert(outBlockStartPtrs.size() == (outNumBlocksWidth * outNumBlocksHeight));
    
    for (int blocki = 0; blocki < outBlockMax; blocki++) {
        outBlockStartPtrs[blocki] = &outPixels[blocki * numPixelsInOneBlock];
    }
    
    // Iterate over each row and then over a block worth of pixels
    
    unsigned int offset = 0;
    unsigned int numBlocksInThisManyRows = 0;
    unsigned int rowCountdown = blockSize;

    // Iterate over each input row and then over each input column in a specific block.
  
    for (int rowi = 0; rowi < height; rowi++, rowCountdown--) {
        if (rowCountdown == 0) {
            numBlocksInThisManyRows++;
            rowCountdown = blockSize;
        }
        
        for (int columnBlocki = 0; columnBlocki < inNumBlocksWidth; columnBlocki++) {
            // Iterate once for each block in this row
            
            unsigned int blocki = (numBlocksInThisManyRows * inNumBlocksWidth) + columnBlocki;
            
            if (debug) {
                printf("row %d col %d = blocki %d\n", rowi, columnBlocki*blockSize, blocki);
            }
            
            T *blockOutPtr = outBlockStartPtrs[blocki];
            
            unsigned int numPixelsToCopy = blockSize;
            
            if (columnBlocki == (inNumBlocksWidth - 1)) {
                unsigned int widthWholeBlocks = inNumBlocksWidth * blockSize;
                
                if (width < widthWholeBlocks) {
                    numPixelsToCopy = width - (widthWholeBlocks - blockSize);
                    
#if defined(DEBUG)
                    assert(width < widthWholeBlocks);
                    assert((width % blockSize) == numPixelsToCopy);
                    assert(numPixelsToCopy < blockSize);
#endif // DEBUG
                    
                    if (debug) {
                        printf("found block row %d with cropped width %d\n", rowi, numPixelsToCopy);
                    }
                }
                
#if defined(DEBUG)
                assert(numPixelsToCopy <= blockSize);
#endif // DEBUG
            }
            
            memcpy(blockOutPtr, &inPixels[offset], numPixelsToCopy*sizeof(T));
            
            if (debug) {
                for (int i=0; i < numPixelsToCopy; i++) {
                    printf("wrote byte %d to block %d\n", blockOutPtr[i], blocki);
                }
            }
            
            offset += numPixelsToCopy;
            
            blockOutPtr += blockSize;
            
            outBlockStartPtrs[blocki] = blockOutPtr;
        }
    }
    
    return;
}

// This optimized version of flattenBlocksOfSize reads 8/16/32 bit pixels
// from inPixels and writes the flattened blocks to the passed in
// outPixels buffer. This optimized impl does not allocate memory in the
// tight loop. The outPixels buffer must be the same length as inPixels.

template <typename T>
void flattenBlocksOfSize(
                         const unsigned int blockDim,
                         const T *inPixels,
                         T *outPixels,
                         const unsigned int numBlocksInWidth,
                         const unsigned int numBlocksInHeight)
{
    const bool debugBlockOutput = false;
    
    // Iterate over each block and write the output to one row at a time.
    
    const unsigned int numBlocksTotal = numBlocksInWidth * numBlocksInHeight;
    const unsigned int numPixelsInBlock = blockDim * blockDim;
    const unsigned int blockSize = blockDim;
  
    if (debugBlockOutput) {
        printf("numBlocksInWidth x numBlocksInHeight : %d x %d\n", numBlocksInWidth, numBlocksInHeight);
        printf("numBlocksTotal = %d\n", numBlocksTotal);
        printf("pixels per row %d\n", (int)(numBlocksInWidth * blockSize));
    }
    
    const T *inPixelsPtr = inPixels;
    
    int rowOfBlocksi = 0;
    
    for (int blocki = 0; blocki < numBlocksTotal; ) {
        
        if (debugBlockOutput) {
            printf("blocki %d with rowOfBlocksi %d\n", blocki, rowOfBlocksi);
        }
        
        // The start of a block in inPixels means that next ( blockSize * blockSize )
        // pixels contain the block pixels. Each row of input pixels contains
        // blockSize pixels and these rows are written to different offsets in
        // the output.
        
        for (int rowi = 0; rowi < blockSize; rowi++) {
            unsigned int blockRootOffset = ((blocki % numBlocksInWidth) * blockSize) + (rowOfBlocksi * (numPixelsInBlock * numBlocksInWidth));
            T *outPixelsBlockRootPtr = &outPixels[blockRootOffset];
            
            T *outPixelsRowPtr = outPixelsBlockRootPtr + (rowi * blockSize * numBlocksInWidth);
            
            if (debugBlockOutput) {
                printf("copy %d pixels from input offset %d to output offset %d\n",
                       (int)blockSize, (int)(inPixelsPtr - inPixels), (int)(outPixelsRowPtr - outPixels));
                printf("numBlocksTotal = %d\n", numBlocksTotal);
                printf("pixels per row %d\n", (int)(numBlocksInWidth * blockSize));
            }
            
            // Copy the next blockSize for this specific row
            
            if (0) {
                for (int i = 0; i < blockSize; i++) {
                    T pixel = *inPixelsPtr++;
                    *outPixelsRowPtr++ = pixel;
                    
                    if (debugBlockOutput) {
                        printf("row[%d] = %d\n", i, pixel);
                    }
                }
            } else {
                memcpy(outPixelsRowPtr, inPixelsPtr, blockSize * sizeof(T));
                inPixelsPtr += blockSize;
            }
        }
        
        blocki++;
        
        if ((blocki > 0) && ((blocki % numBlocksInWidth) == 0)) {
            rowOfBlocksi++;
        }
    }
    
    return;
}

// Given a flat array of pixels that might have been zero padded, crop off
// any zero padding by doing a copy only for the pixels that are inside
// the crop rectangle. The result is a buffer that is width x height pixels.

template <typename T>
void cropZeroPaddedBlocks(
                          const unsigned int blockSize,
                          T *pixels,
                          const int paddedWidth,
                          const int paddedHeight,
                          const int croppedWidth,
                          const int croppedHeight
                          )
{
    const unsigned int numPadedPixels = paddedWidth * paddedHeight;
    const unsigned int numCroppedPixels = croppedWidth * croppedHeight;
    
    if (numCroppedPixels == numPadedPixels) {
        // Not zero padded
        return;
    }
    
    // pixels must be a multiple of block_size
    
#if defined(DEBUG)
    assert((numPadedPixels % blockSize) == 0);
#endif // DEBUG
    
    // FIXME: pass in numBlocksInWidth to avoid compulation
    
    unsigned int numBlocksInWidth = paddedWidth / blockSize;
    
    if ((paddedWidth % blockSize) != 0) {
        numBlocksInWidth += 1;
    }
    
    unsigned int numValuesInPaddedRow = blockSize * numBlocksInWidth;
    unsigned int numValuesInCroppedRow = croppedWidth;
    unsigned int numBytesInCroppedRow = numValuesInCroppedRow * sizeof(T);
    
    // memcpy() each row on top of the previous one so that the resulting
    // flat array contains the pixels without the zero padding.
    
    for (int rowi = 1; rowi < croppedHeight; rowi++) {
        T *srcPtr = &pixels[rowi * numValuesInPaddedRow];
        T *dstPtr = &pixels[rowi * numValuesInCroppedRow];
        
        //printf("memmove %d bytes from offset %d to offset %d\n", numBytesInCroppedRow, (int)(srcPtr-pixels), (int)(dstPtr-pixels));
        
        memmove(dstPtr, srcPtr, numBytesInCroppedRow);
    }
    
    return;
}

// Process width x height blocks of type T, typically be uint8_t, uint16_t, or uint32_t

template <typename T, const int D>
class BlockEncoder
{
public:
    // Input is split into block vectors, any processing can then operate
    // on each block as a unit.
    vector<vector<T> > blockVectors;
    
    BlockEncoder() {
    }

    // Calculate block width and block height from image width and height
    
    void calcBlockWidthAndHeight(
                                 const unsigned int width,
                                 const unsigned int height,
                                 unsigned int & blockWidth,
                                 unsigned int & blockHeight)
    {
#if defined(DEBUG)
        assert(width > 0);
        assert(height > 0);
#endif // DEBUG
        
        blockWidth = width / D;
        if ((width % D) != 0) {
            blockWidth += 1;
        }
        
        blockHeight = height / D;
        if ((height % D) != 0) {
            blockHeight += 1;
        }
    }
    
    // Break input into blocks, note the input need not be exactly the
    // same as the block size as any unused bytes will be represented
    // with the zero value.
    
    void splitIntoBlocks(const T* pixelsPtr,
                         const int numPixels,
                         const int width,
                         const int height,
                         const int outBlockWidth,
                         const int outBlockHeight,
                         const T zeroValue)
    {
        const bool debug = false;
      
        // Split into block by block memory layout
        
        const int outTotalNumBlocks = outBlockWidth * outBlockHeight;
        const int outBlockNumPixels = (outTotalNumBlocks * D * D);
        
        vector<T> outBlockLayout(outBlockNumPixels);
        
        unsigned int inBlockWidth;
        unsigned int inBlockHeight;
        
        calcBlockWidthAndHeight(width, height, inBlockWidth, inBlockHeight);
      
        splitIntoBlocksOfSize(D,
                              pixelsPtr,
                              width,
                              height,
                              inBlockWidth,
                              inBlockHeight,
                              outBlockLayout.data(),
                              outBlockWidth,
                              outBlockHeight,
                              zeroValue);
        
        // Init/Reinit vector of vectors
        if (blockVectors.size() != outTotalNumBlocks) {
            blockVectors.clear();
            blockVectors.resize(outTotalNumBlocks);
            
            for (int blocki = 0; blocki < outTotalNumBlocks; blocki++) {
                blockVectors[blocki] = vector<T>();
            }
        }
        
        // Iterate block by block and copy blocks symbols into blockVectors
        
        for ( int blocki = 0; blocki < outTotalNumBlocks; blocki++ ) {
            const T* blockStartPtr = outBlockLayout.data() + (blocki * (D * D));
            
            vector<T> & blockVec = blockVectors[blocki];
            if (blockVec.size() != (D * D)) {
                blockVec.clear();
                blockVec.resize(D * D);
            }

            if (debug) {
                int numValues = (D * D);
                printf("block %4d : will copy %d values\n", blocki, (int)numValues);
                for (int i = 0; i < numValues; i++) {
                  T val = blockStartPtr[i];
                  printf("copy %d\n", (int)val);
                }
            }
          
            memcpy(blockVec.data(), blockStartPtr, (D * D) * sizeof(T));
        }
        
        return;
    }
};

// A block decoder reads from data already formatted into blocks and provides
// logic to reorder block data to image order and crop to the original dimensions.

template <typename T, const int D>
class BlockDecoder
{
public:
    
    // Note that these vectors can be initialized by std::move() via
    // decoder.blockVectors = std::move(encoder.blockVectors);
    
    vector<vector<T> > blockVectors;
    
    BlockDecoder()
    {
    }
    
    void flattenAndCrop(const T* outPixels,
                        const int numPixels,
                        const int blockWidth,
                        const int blockHeight,
                        const int width,
                        const int height)
    {
        // Collect all block segmented data into a single vector
        
        const int totalNumBlocks = blockWidth * blockHeight;
        const int totalPixelsAllBlocks = totalNumBlocks * (D * D);
        
        vector<T> blockLayout(totalPixelsAllBlocks);
        vector<T> flatLayout(totalPixelsAllBlocks);
        
        int blocki = 0;
        T *blockLayoutBasePtr = blockLayout.data();
        
        for ( vector<T> & vec : blockVectors ) {
            T *blockStartPtr = blockLayoutBasePtr + (blocki * (D * D));
            memcpy(blockStartPtr, vec.data(), vec.size() * sizeof(T));
            blocki++;
        }
        
        flattenBlocksOfSize(D, blockLayout.data(), flatLayout.data(), blockWidth, blockHeight);
        
        cropZeroPaddedBlocks(D, flatLayout.data(), blockWidth*D, blockHeight*D, width, height);
        
        // Copy cropped data from flatLayout to outPixels
        
        memcpy((void*)outPixels, (void*)flatLayout.data(), width*height*sizeof(T));
    }
};


// split vector of values into vector of vectors, the final length could be smaller

static inline
vector<vector<uint8_t> > splitIntoSubArraysOfLength(const vector<uint8_t> & inVec, const int splitLen)
{
  int numElementsLeft = (int) inVec.size();
  
  vector<vector<uint8_t> > result;
  
  int length = splitLen;
  
  const uint8_t *inPtr = inVec.data();
  
  while (numElementsLeft > 0) {
    if (numElementsLeft < splitLen) {
      length = numElementsLeft;
    }
    
    vector<uint8_t> subVec;
    subVec.reserve(length);
    
    for (int i = 0; i < length; i++) {
      subVec.push_back(*inPtr++);
    }
    
    result.push_back(subVec);
    
    numElementsLeft -= length;
  }
  
  return result;
}

#endif // block_hpp
