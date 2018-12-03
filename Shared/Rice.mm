// Objective C interface to elias gamma parsing functions
//  MIT Licensed

#import "Rice.h"

#include <assert.h>

#include <string>
#include <vector>
#include <unordered_map>
#include <cstdint>

#import "block.hpp"
#import "block_process.hpp"

#import "rice.hpp"
//#import "rice_parallel.hpp"
//#import "rice_opt.h"

#import "AAPLShaderTypes.h"

#define EMIT_CACHEDBITS_DEBUG_OUTPUT
#import "CachedBits.hpp"
#define EMIT_RICEDECODEBLOCKS_DEBUG_OUTPUT
#define RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
#import "RiceDecodeBlocks.hpp"

#import "RiceDecodeBlocksImpl.hpp"

using namespace std;

//#define USE_MULTIPLEXER
#define USE_SPLIT_RICE_ENCODER

// Generate table values that encode blocks with different sizes

void generateTableValues(int numBlocks, vector<uint32_t> & countTable, vector<uint32_t> & nTable) {
    // N opt blocks of size 64
    countTable.push_back(numBlocks);
    nTable.push_back(8*8);
}

// Invoke rice util module functions

#if defined(USE_MULTIPLEXER)

#define MULTIPLEXER_NUM_STREAMS (8)

static inline
vector<uint8_t> encode(const uint8_t * bytes,
                       const int numBytes,
                       const uint8_t * blockOptimalKTable,
                       int blockOptimalKTableLength,
                       int numBlocks)
{
    const unsigned int numStreams = MULTIPLEXER_NUM_STREAMS;
    const unsigned int blockDim = RICE_SMALL_BLOCK_DIM;
    const int numSymbolsInOneBlock = (blockDim * blockDim);

    unsigned int numBlocksPerStream = numBlocks / numStreams;
    assert((numBlocksPerStream % numStreams) == 0);
    
    vector<vector<uint8_t> > vecOfVecs;
    vecOfVecs.reserve(numStreams);
    
    for ( int i = 0; i < numStreams; i++ ) {
        vector<uint8_t> vec;
        vec.reserve(numBlocksPerStream * numSymbolsInOneBlock);
        vecOfVecs.push_back(vec);
    }
    
    // Generate table of k values for each block in each stream.
    vector<uint8_t> kBlockVec;
    kBlockVec.reserve(numBlocks + 1);
    
    int blocki = 0;
    
    for ( int streami = 0; streami < numStreams; streami++ ) {
        vector<uint8_t> & inStream = vecOfVecs[streami];
        
        int maxBlocki = blocki + numBlocksPerStream;
        
        for ( ; blocki < maxBlocki; blocki++ ) {
            const uint8_t *blockPtr = bytes + (blocki * numSymbolsInOneBlock);
            
            for ( int i = 0; i < numSymbolsInOneBlock; i++ ) {
                uint8_t bVal = blockPtr[i];
                inStream.push_back(bVal);
            }
            
            int k = blockOptimalKTable[blocki];
            kBlockVec.push_back(k);
        }
    }
    
    kBlockVec.push_back(0); // zero padding required
    assert(kBlockVec.size() == blockOptimalKTableLength);
    
    vector<uint8_t> mstream = ByteStreamMultiplexer(vecOfVecs, kBlockVec, numSymbolsInOneBlock);

    return mstream;
}

// decode

static
void decode( int numSymbolsToDecode,
            uint8_t* bitBuff,
            int bitBuffN,
            const uint8_t* blockOptimalKTable,
            int blockOptimalKTableLength,
            int numBlocks,
            uint8_t* outBuffer,
            uint32_t* blockStartBitOffsetsPtr)
{
    // Each block in each stream contains the same number of values
    
    const int blockDim = RICE_SMALL_BLOCK_DIM;
    const int numStreams = MULTIPLEXER_NUM_STREAMS;
    const int numSymbolsPerBlock = (blockDim * blockDim);
    
    unsigned int numBlocksPerStream = numBlocks / numStreams;
    assert((numBlocksPerStream % numStreams) == 0);
    
    // Generate table of k values for each block in each stream.
    vector<uint8_t> kBlockVec;
    kBlockVec.reserve(numBlocks + 1);
    
    for ( int blocki = 0; blocki < numBlocks; blocki++ ) {
        int k = blockOptimalKTable[blocki];
        kBlockVec.push_back(k);
    }
    
    kBlockVec.push_back(0); // zero padding required
    assert(kBlockVec.size() == blockOptimalKTableLength);
    
    // Decode num/N symbols from N streams
    
    ByteStreamDemultiplexer(numSymbolsToDecode/numStreams,
                            numStreams,
                            bitBuff,
                            bitBuffN,
                            outBuffer,
                            kBlockVec,
                            numSymbolsPerBlock);
    
    return;
}

#else // USE_MULTIPLEXER

static inline
vector<uint8_t> encode(const uint8_t * bytes,
                       const int numBytes,
                       const uint8_t * blockOptimalKTable,
                        int blockOptimalKTableLength,
                       int numBlocks)
{
#if defined(USE_SPLIT_RICE_ENCODER)
    RiceSplit16Encoder<false, true, BitWriterByteStream> encoder;
#else
    RiceEncoder encoder;
#endif // USE_SPLIT_RICE_ENCODER
    
    vector<uint32_t> countTable;
    vector<uint32_t> nTable;
    
    generateTableValues(numBlocks, countTable, nTable);
    
    encoder.encode(bytes, numBytes, blockOptimalKTable, blockOptimalKTableLength, countTable, nTable);
    
#if defined(USE_SPLIT_RICE_ENCODER)
    return encoder.bitWriter.moveBytes();
#else
    return std::move(encoder.bytes);
#endif // USE_SPLIT_RICE_ENCODER
}

#endif // USE_MULTIPLEXER

// Generate a table of bit width offsets for N symbols, this is
// the symbol width added to a running counter of the offset
// into a buffer.

// FIXME: would be more optimal to generate a table of just the block
// offsets instead of all of the symbols in a table.

static inline
vector<uint32_t> generateBitOffsets(const uint8_t * symbols,
                                    int numSymbols,
                                    const uint8_t * blockOptimalKTable,
                                    int numBlocks)
{
    vector<uint32_t> bitOffsets;
    bitOffsets.reserve(numSymbols);
    
    unsigned int offset = 0;
  
    int numSymbolsInBlock = numSymbols / numBlocks;

#if defined(USE_SPLIT_RICE_ENCODER)
    RiceSplit16Encoder<false, true, BitWriterByteStream> encoder;
#else
    RiceEncoder encoder;
#endif // USE_SPLIT_RICE_ENCODER
    
    // FIXME: block k not determined by symbol access here
    
    for ( int i = 0; i < numSymbols; i++ ) {
        bitOffsets.push_back(offset);
        uint8_t symbol = symbols[i];
        uint8_t k = blockOptimalKTable[i/numSymbolsInBlock];
        uint32_t bitWidth = encoder.numBits(symbol, k);
        offset += bitWidth;
    }
    
    return bitOffsets;
}

static inline
string get_code_bits_as_string(uint32_t code, const int width)
{
    string bitsStr;
    int c4 = 1;
    for ( int i = 0; i < width; i++ ) {
        bool isOn = ((code & (0x1 << i)) != 0);
        if (isOn) {
            bitsStr = "1" + bitsStr;
        } else {
            bitsStr = "0" + bitsStr;
        }
        
        if ((c4 == 4) && (i != (width - 1))) {
            bitsStr = "-" + bitsStr;
            c4 = 1;
        } else {
            c4++;
        }
    }
    return bitsStr;
}

// Find optimal K for rice coding.

int optimalRiceK(
                 const uint8_t * inBytes,
                 int inNumBytes,
                 int blocki)
{
    const int debugWriteBlockResults = 0;
    
    int minBlockSize = 0x7FFFFFFF;
    int minBlockK = -1;
    
    // Count bits that would get emitted for each k value

    if ((0)) {
        printf("kdeltas : ");

        for (int i = 0; i < inNumBytes; i++) {
            printf("%d ", (int)inBytes[i]);
        }
        printf("\n");
    }
    
#if defined(USE_SPLIT_RICE_ENCODER)
    RiceSplit16Encoder<false, true, BitWriterByteStream> encoder;
#else
    RiceEncoder encoder;
#endif // USE_SPLIT_RICE_ENCODER
    
    for (int k = 0 ; k < 8; k++) {
        // FIXME: a faster impl might be to loop over the bits once and
        // calculate numBits() for all k values at the same time.
        
        int numBitsForBlock = encoder.numBits(inBytes, inNumBytes, k);
        
        if (numBitsForBlock < minBlockSize) {
            minBlockSize = numBitsForBlock;
            minBlockK = k;
        }
        
        if (debugWriteBlockResults) {
            printf("block %5d encoded at k %3d : (bits) %d\n", blocki, k, numBitsForBlock);
        }
    }
    
    if (debugWriteBlockResults) {
        printf("block %5d : best encoded as k %3d\n", blocki, minBlockK);
        printf("\n");
    }
    
    return minBlockK;
}

// Determine optimal k values on a block by block basis

void optKForBlocks(
                   const vector<uint8_t> & outEncodedBlockBytes,
                   NSMutableData* blockOptimalKTableData,
                   int * numBaseValuesPtr,
                   int * numBlockValuesPtr)
{
    // Rice opt block size is always 8x8
    const int blockDim = RICE_SMALL_BLOCK_DIM;

    int numBase = *numBaseValuesPtr;
    int numBlockValues = *numBlockValuesPtr;
    
    assert(numBase == 0);
    assert(outEncodedBlockBytes.size() == numBlockValues);

    //int numBlockValues = *numBlockValues;
    
    // Split block base bytes off from the block deltas
    
    [blockOptimalKTableData setLength:0];
    
    vector<uint8_t> outEncodedBlockBytesKVec;
    const int splitLen = blockDim*blockDim;
    block_process_rice_opt<splitLen>(outEncodedBlockBytes, outEncodedBlockBytesKVec);
    
    assert(numBlockValues/splitLen == outEncodedBlockBytesKVec.size());
    
    [blockOptimalKTableData appendBytes:outEncodedBlockBytesKVec.data() length:outEncodedBlockBytesKVec.size()];
  
    // Zero padding at end of buffer
    
    {
        uint8_t zero = 0;
        [blockOptimalKTableData appendBytes:&zero length:sizeof(zero)];
    }
    
    return;
}

// Rice encode method

static inline
vector<uint8_t> encodeRice2(const uint8_t * bytes,
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
void decodeRice2(const uint8_t * bitBuff,
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
void decodeRice2ParallelCheck(const uint8_t * bitBuff,
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
    
    RiceDecodeBlocksT rdb;
    
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
vector<uint32_t> generateBitOffsetsRice2(const uint8_t * symbols,
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

// This method breaks input up into blocks and then encodes the
// values using an optimal approach where the first "base" value
// in each block is pulled out of the stream and encoded as deltas.
// All the base values are encoded together and then the remainder
// of the block deltas are appended to the output.

void blockDeltaEncoding(const uint8_t * inBytes,
                   int inNumBytes,
                   const int width,
                   const int height,
                   const int blockWidth,
                   const int blockHeight,
                   vector<uint8_t> & outEncodedBlockBytes,
                   int * numBaseValues,
                   int * numBlockValues)
{
    const int blockDim = RICE_LARGE_BLOCK_DIM;
    
    block_delta_process_encode<blockDim>(inBytes, inNumBytes,
                                         width, height,
                                         blockWidth, blockHeight,
                                         outEncodedBlockBytes,
                                         numBaseValues,
                                         numBlockValues);

    return;
}

// Block reordering without delta operation

void blockEncoding(const uint8_t * inBytes,
                   int inNumBytes,
                   const int width,
                   const int height,
                   const int blockWidth,
                   const int blockHeight,
                   vector<uint8_t> & outEncodedBlockBytes)
{
    const int blockDim = RICE_LARGE_BLOCK_DIM;
    
    block_process_encode<blockDim>(inBytes, inNumBytes,
                                   width, height,
                                   blockWidth, blockHeight,
                                   outEncodedBlockBytes);

    return;
}

@implementation Rice

// Given an input buffer, huffman encode the input values and generate
// output that corresponds to

+ (void) encodeBits:(const uint8_t*)inBytes
         inNumBytes:(int)inNumBytes
 blockOptimalKTable:(uint8_t*)blockOptimalKTable
blockOptimalKTableDataLength:(int)blockOptimalKTableDataLength
          numBlocks:(int)numBlocks
           outCodes:(NSMutableData*)outCodes
 outBlockBitOffsets:(NSMutableData*)outBlockBitOffsets
              width:(int)width
             height:(int)height
           blockDim:(int)blockDim
{
  vector<uint8_t> outBytesVec = encode(inBytes, inNumBytes, blockOptimalKTable, blockOptimalKTableDataLength, numBlocks);
    
  {
      // Copy from outBytesVec to outCodes
      NSMutableData *mData = outCodes;
      int numBytes = (int)(outBytesVec.size() * sizeof(uint8_t));
      [mData setLength:numBytes];
      memcpy(mData.mutableBytes, outBytesVec.data(), numBytes);
  }
    
  // Generate bit width lookup table from original input symbols
  vector<uint32_t> offsetsVec = generateBitOffsets(inBytes, inNumBytes, blockOptimalKTable, numBlocks);

  // The outBlockBitOffsets output contains bit offsets of the start
  // of each block, so skip over (blockDim * blockDim) offsets on
  // each lookup.

  const int maxOffset = (width * height);
  const int blockN = (blockDim * blockDim);
    
  vector<uint32_t> blockStartOffsetsVec;
  blockStartOffsetsVec.reserve(maxOffset / blockN);

  for (int offset = 0; offset < maxOffset; offset += blockN ) {
      int blockStartBitOffset = offsetsVec[offset];
      blockStartOffsetsVec.push_back(blockStartBitOffset);
  }

  {
      int numBytes = (int) (blockStartOffsetsVec.size() * sizeof(uint32_t));
      if ((int)outBlockBitOffsets.length != numBytes) {
          [outBlockBitOffsets setLength:numBytes];
      }
      memcpy(outBlockBitOffsets.mutableBytes, blockStartOffsetsVec.data(), numBytes);
  }
  
  return;
}

// Unoptimized serial decode logic. Note that this logic
// assumes that huffBuff contains +2 bytes at the end
// of the buffer to account for read ahead.

+ (void) decodeBits:(int)numSymbolsToDecode
           bitBuff:(uint8_t*)bitBuff
          bitBuffN:(int)bitBuffN
          outBuffer:(uint8_t*)outBuffer
     bitOffsetTable:(uint32_t*)bitOffsetTable
{
    /*
    vector<uint8_t> outVec;
    outVec.reserve(numSymbolsToDecode);
    
    decode(bitBuff, numSymbolsToDecode, outVec);
    // FIXME: how should decode method return the result data?
    // Since size of buffer is know, this module can assume
    // that allocated buffer is large enough to handle known
    // number of symbols.
    memcpy(outBuffer, outVec.data(), numSymbolsToDecode);
     */
}

// Encode symbols by calculating signed byte deltas
// and then converting to zerod deltas which can
// be represented as positive integer values.

+ (NSData*) encodeSignedByteDeltas:(NSData*)data
{
  vector<int8_t> inBytes;
  inBytes.resize(data.length);
  memcpy(inBytes.data(), data.bytes, data.length);
  
  vector<int8_t> outSignedDeltaBytes = encodeDelta(inBytes);
    
  NSMutableData *outZerodDeltaBytes = [NSMutableData data];
  [outZerodDeltaBytes setLength:outSignedDeltaBytes.size()];
  uint8_t *outZerodDeltaPtr = (uint8_t *) outZerodDeltaBytes.mutableBytes;
    
  // Convert signed delta to zerod (unsigned) deltas
  const int maxNumBytes = (int) outSignedDeltaBytes.size();

  for (int i = 0; i < maxNumBytes; i++) {
      int8_t sVal = outSignedDeltaBytes[i];
      uint8_t zerodVal = pixelpack_int8_to_offset_uint8(sVal);
      *outZerodDeltaPtr++ = zerodVal;
  }

  return [NSData dataWithData:outZerodDeltaBytes];
}

// Decode symbols by reversing zerod mapping and then applying
// signed 8 bit deltas to recover the original symbols as uint8_t.

+ (NSData*) decodeSignedByteDeltas:(NSData*)deltas
{
  const int maxNumBytes = (int) deltas.length;

  vector<uint8_t> signedDeltaBytes;
  signedDeltaBytes.resize(maxNumBytes);
  const uint8_t *zerodDeltasPtr = (uint8_t *) deltas.bytes;
  
  for (int i = 0; i < maxNumBytes; i++) {
    uint8_t zerodVal = zerodDeltasPtr[i];
    int8_t sVal = pixelpack_offset_uint8_to_int8(zerodVal);
    signedDeltaBytes[i] = (uint8_t) sVal;
  }

  // Apply signed deltas
  vector<uint8_t> outSymbols = decodeDelta(signedDeltaBytes);
    
  NSMutableData *mData = [NSMutableData data];
  [mData setLength:maxNumBytes];
  memcpy((void*)mData.mutableBytes, (void*)outSymbols.data(), maxNumBytes);
    
  return [NSData dataWithData:mData];
}

// Decode rice encoded symbols from encoded buffer

#if defined(USE_MULTIPLEXER)

+ (void) decodeBlockSymbols:(int)numSymbolsToDecode
                    bitBuff:(uint8_t*)bitBuff
                   bitBuffN:(int)bitBuffN
         blockOptimalKTable:(const uint8_t*)blockOptimalKTable
   blockOptimalKTableLength:(int)blockOptimalKTableLength
                  numBlocks:(int)numBlocks
                  outBuffer:(uint8_t*)outBuffer
    blockStartBitOffsetsPtr:(uint32_t*)blockStartBitOffsetsPtr
{
    decode( numSymbolsToDecode,
           bitBuff,
           bitBuffN,
           blockOptimalKTable,
           blockOptimalKTableLength,
           numBlocks,
           outBuffer,
           blockStartBitOffsetsPtr);
    
    return;
}

#else // USE_MULTIPLEXER
+ (void) decodeBlockSymbols:(int)numSymbolsToDecode
                    bitBuff:(uint8_t*)bitBuff
                   bitBuffN:(int)bitBuffN
         blockOptimalKTable:(const uint8_t*)blockOptimalKTable
   blockOptimalKTableLength:(int)blockOptimalKTableLength
                  numBlocks:(int)numBlocks
                  outBuffer:(uint8_t*)outBuffer
    blockStartBitOffsetsPtr:(uint32_t*)blockStartBitOffsetsPtr
{
    const int blockDim = RICE_SMALL_BLOCK_DIM;
    
    vector<uint32_t> countTable;
    vector<uint32_t> nTable;
    
    generateTableValues(numBlocks, countTable, nTable);
    
    // Decode all symbols with one invocation
    
    int numSymbolsExpected = (numBlocks * (blockDim * blockDim));
#if defined(DEBUG)
    assert(numSymbolsToDecode == numSymbolsExpected);
#endif // DEBUG
    
#if defined(USE_SPLIT_RICE_ENCODER)
    RiceSplit16Decoder<false, true, BitReaderByteStream> decoder;
#else
    RiceDecoder decoder;
#endif // USE_SPLIT_RICE_ENCODER
    
#if defined(USE_SPLIT_RICE_ENCODER)
    decoder.decode(bitBuff, bitBuffN, outBuffer, numSymbolsToDecode, blockOptimalKTable, blockOptimalKTableLength, countTable, nTable);
#else
    vector<uint8_t> decodedSymbols = decoder.decode(bitBuff, bitBuffN, blockOptimalKTable, blockOptimalKTableLength, countTable, nTable);
    
    if (decodedSymbols.size() > numSymbolsExpected) {
        decodedSymbols.resize(numSymbolsExpected);
    }
    
    memcpy(outBuffer, decodedSymbols.data(), numSymbolsExpected);
#endif // USE_SPLIT_RICE_ENCODER
    
    // FIXME: undo block encoding to convert back to original input symbols?
    
    return;
}

// Given input bytes in block by block order, reformat the blocks
// of data to image order.

+ (void) flattenBlockBytes:(int)blockDim
                 numPixels:(int)numPixels
                  inPixels:(const uint8_t*)inPixels
                 outPixels:(uint8_t*)outPixels
                     width:(int)width
                    height:(int)height
                blockWidth:(int)blockWidth
               blockHeight:(int)blockHeight
{
  flattenBlocksOfSize(blockDim, inPixels, outPixels, blockWidth, blockHeight);
}

// Return 64 entry lookup table wrapped in a NSData

+ (NSData*) generatePrefixBitStreamGenerateLookupTable64K6Bits
{
    vector<uint16_t> vec = PrefixBitStreamGenerateLookupTable64K6Bits();
    
    NSMutableData *mData = [NSMutableData dataWithBytes:vec.data() length:(int)vec.size()*sizeof(uint16_t)];

    return mData;
}

#endif // USE_MULTIPLEXER

// Decode deltas and reorder and crop

+ (void) blockDeltaDecode:(int)numSymbols
        blockOrderSymbols:(const uint8_t*)blockOrderSymbols
        imageOrderSymbols:(uint8_t*)imageOrderSymbols
                    width:(int)width
                   height:(int)height
               blockWidth:(int)blockWidth
              blockHeight:(int)blockHeight
{
    const int blockDim = RICE_LARGE_BLOCK_DIM;
    
    block_delta_process_decode<blockDim>(blockOrderSymbols,
                                   numSymbols,
                                   width,
                                   height,
                                   blockWidth,
                                   blockHeight,
                                   imageOrderSymbols,
                                   width*height);
    
    return;
}

// Given the original input pixels, do block split and processing into deltas
// along with reordering to reduce information down to a minumim.

+ (void) blockDeltaEncoding:(const uint8_t *)inBytes
            inNumBytes:(int)inNumBytes
                 width:(int)width
                height:(int)height
            blockWidth:(int)blockWidth
           blockHeight:(int)blockHeight
  outEncodedBlockBytes:(NSMutableData*)outEncodedBlockBytes
         numBaseValues:(int *)numBaseValues
        numBlockValues:(int *)numBlockValues
{
    vector<uint8_t> outEncodedBlockBytesVec;
    
    blockDeltaEncoding(inBytes, inNumBytes, width, height, blockWidth, blockHeight, outEncodedBlockBytesVec, numBaseValues, numBlockValues);
    
    int numBytes = (int) outEncodedBlockBytesVec.size();
    [outEncodedBlockBytes setLength:numBytes];
    memcpy(outEncodedBlockBytes.mutableBytes, outEncodedBlockBytesVec.data(), numBytes);
    
    return;
}

// Convert image order to block order but do not do deltas

+ (void) blockEncoding:(const uint8_t *)inBytes
            inNumBytes:(int)inNumBytes
                 width:(int)width
                height:(int)height
            blockWidth:(int)blockWidth
           blockHeight:(int)blockHeight
  outEncodedBlockBytes:(NSMutableData*)outEncodedBlockBytes
{
  vector<uint8_t> outEncodedBlockBytesVec;
  
  blockEncoding(inBytes, inNumBytes, width, height, blockWidth, blockHeight, outEncodedBlockBytesVec);
  
  int numBytes = (int) outEncodedBlockBytesVec.size();
  [outEncodedBlockBytes setLength:numBytes];
  memcpy(outEncodedBlockBytes.mutableBytes, outEncodedBlockBytesVec.data(), numBytes);
  
  return;
}

// Two stage delta encoding logic where a large block is used to generate deltas,
// then the block order delta bytes are converted back to image order before
// a smaller block size is used to break deltas up into smaller blocks.

+ (void) blockDeltaEncoding2Stage:(const uint8_t *)inBytes
                 inNumBytes:(int)inNumBytes
                      width:(int)width
                     height:(int)height
                 blockWidth:(int)blockWidth
                blockHeight:(int)blockHeight
       outEncodedBlockBytes:(NSMutableData*)outEncodedBlockBytes
{
    vector<uint8_t> outEncodedBlockBytesVec;
    
    int numBaseValues, numBlockValues;
    
    // 32x32 block delta operation
    
    blockDeltaEncoding(inBytes, inNumBytes, width, height, blockWidth, blockHeight, outEncodedBlockBytesVec, &numBaseValues, &numBlockValues);
    
    // Undo block ordering for 32x32 block, note that the output will be zero padded
    
    const int blockDim = RICE_LARGE_BLOCK_DIM;
    
    vector<uint8_t> outImageOrderDeltaBytes;
    
    const int numBytesPadded = blockWidth * blockHeight * blockDim * blockDim;
    outImageOrderDeltaBytes.resize(numBytesPadded);
    
    assert((int)outEncodedBlockBytesVec.size() == numBytesPadded);
    
    block_process_decode<blockDim>(outEncodedBlockBytesVec.data(),
                                   (int)outEncodedBlockBytesVec.size(),
                                   (blockWidth * blockDim), (blockHeight * blockDim),
                                   blockWidth, blockHeight,
                                   outImageOrderDeltaBytes.data(), (int)outImageOrderDeltaBytes.size());

    if ((0)) {
        uint8_t *outPtr = (uint8_t *) outImageOrderDeltaBytes.data();
        
        printf("image order as deltas for %5d x %5d image\n", width, height);
        
        for ( int row = 0; row < height; row++ ) {
            for ( int col = 0; col < width; col++ ) {
                uint8_t byteVal = outPtr[(row * width) + col];
                printf("0x%02X ", byteVal);
            }
            
            printf("\n");
        }
        
        printf("image order as deltas done\n");
    }

    // Reorder as 8x8 blocks but do not delta, if input was smaller that 32x32
    // it would have been padded to the large block dimension above.
    
    const int smallBlockDim = RICE_SMALL_BLOCK_DIM;

    int numSmallBlocksInWidth = blockWidth * (blockDim/smallBlockDim);
    int numSmallBlocksInHeight = blockHeight * (blockDim/smallBlockDim);
    
    assert(outImageOrderDeltaBytes.size() == outEncodedBlockBytesVec.size());
    
    block_process_encode<smallBlockDim>(outImageOrderDeltaBytes.data(), (int)outImageOrderDeltaBytes.size(),
                                   (blockWidth * blockDim), (blockHeight * blockDim),
                                   numSmallBlocksInWidth, numSmallBlocksInHeight,
                                   outEncodedBlockBytesVec);

    int numBytes = (int) outEncodedBlockBytesVec.size();
    [outEncodedBlockBytes setLength:numBytes];
    memcpy(outEncodedBlockBytes.mutableBytes, outEncodedBlockBytesVec.data(), numBytes);
    
    return;
}


+ (void) optRiceK:(NSData*)blockOrderSymbolsData
blockOptimalKTableData:(NSMutableData*)blockOptimalKTableData
    numBaseValues:(int *)numBaseValues
   numBlockValues:(int *)numBlockValues
{
    vector<uint8_t> outEncodedBlockBytesVec;
    outEncodedBlockBytesVec.resize((int)blockOrderSymbolsData.length);
    memcpy(outEncodedBlockBytesVec.data(), blockOrderSymbolsData.bytes, blockOrderSymbolsData.length);
    
    optKForBlocks(outEncodedBlockBytesVec,
                  blockOptimalKTableData,
                  numBaseValues,
                  numBlockValues);
}

// Encode Rice2 style stream with prefx, escape, unary are all encoded
// into a single stream that is read word by word in 32 different threads.

+ (void) encodeRice2Stream:(NSData*)inBytes
                    blockN:(int)blockN
                     width:(int)width
                    height:(int)height
         riceEncodedStream:(NSMutableData*)riceEncodedStream
        blockOptimalKTable:(NSMutableData*)blockOptimalKTable
    halfBlockOptimalKTable:(NSMutableData*)halfBlockOptimalKTable
      halfBlockOffsetTable:(NSMutableData*)halfBlockOffsetTable
{
  const int blockDim = RICE_SMALL_BLOCK_DIM;
  const int blockiDim = RICE_LARGE_BLOCK_DIM / RICE_SMALL_BLOCK_DIM;
  
  const uint8_t *inBlockOrderSymbols = (const uint8_t *) inBytes.bytes;
  
  int numBlockSymbols = blockN * blockDim * blockDim;
  assert(numBlockSymbols == inBytes.length);
  
  assert(halfBlockOffsetTable.length == 0);
  
  // Generate blocki ordering
  
  vector<uint32_t> blockiVec;
  vector<uint32_t> blockiLookupVec;
  
  block_reorder_blocki<blockDim,blockiDim>(width, height, blockiVec, blockiLookupVec);
  
  // Invoke s32 layout logic with ordered blocki generated above
  
  const int numSegments = 32;
  
  vector<uint8_t> s32OrderPixelsVec(width*height);
  
  uint32_t *blockiPtr = blockiLookupVec.data();

  vector<uint8_t> blockOptimalKTableVec;
  
  blockOptimalKTableVec.resize(blockOptimalKTable.length);
  memcpy(blockOptimalKTableVec.data(), blockOptimalKTable.mutableBytes, blockOptimalKTable.length);
  
  vector<uint8_t> blockiReorderedVec;
  vector<uint8_t> blockiOptimalKTableVec;
  vector<uint8_t> halfBlockOptimalKTableVec;
  
  blockiOptimalKTableVec = blockOptimalKTableVec;
  
  block_s32_format_block_layout(inBlockOrderSymbols,
                                s32OrderPixelsVec.data(),
                                blockN,
                                blockDim,
                                numSegments,
                                blockiPtr,
                                &blockiReorderedVec,
                                &blockiOptimalKTableVec,
                                &halfBlockOptimalKTableVec);
  
  assert(blockiOptimalKTableVec.size() == blockOptimalKTableVec.size());
  
  // Copy reordered block optimal k back over blockOptimalKTable
  
  blockOptimalKTableVec.resize(blockOptimalKTable.length);
  memcpy(blockOptimalKTable.mutableBytes, blockiOptimalKTableVec.data(), blockOptimalKTable.length);
  
  if ((0)) {
    printf("big block s32 image order:\n");
    
    for (int row = 0; row < height; row++) {
      for (int col = 0; col < width; col++) {
        int offset = (row * width) + col;
        int bVal = s32OrderPixelsVec[offset];
        printf("%3d ", bVal);
      }
      printf("\n");
    }
    
    printf("\n");
  }
  
  if ((0)) {
    printf("half block order:\n");
    
    int offset = 0;
    
    for ( ; offset < (width * height); ) {
      printf("offset %3d (%d at a time)\n", offset, (blockDim * blockDim)/2);
      
      for (int i = 0; i < (blockDim * blockDim)/2; i++) {
        int bVal = s32OrderPixelsVec[offset++];
        printf("%3d ", bVal);
      }
      printf("\n");
    }
  }
  
  // Read 16 small blocks at a time from 32 streams
  // so that a big block of 32x32 is read in with
  // 8 reads per small block.
  
  vector<uint8_t> decodedS32PixelsVec(width*height);
  
  uint8_t *s32OrderPixels = s32OrderPixelsVec.data();
  uint8_t *decodedS32Pixels = decodedS32PixelsVec.data();
  
  block_s32_flatten_block_layout(s32OrderPixels,
                                 decodedS32Pixels,
                                 blockN,
                                 blockDim,
                                 numSegments);
  
  if ((0)) {
    printf("s32 block order:\n");
    
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
          printf("bval == expected : %d == %d : offset %d : x,y %d,%d", bval, expected, i, x, y);
          assert(bval == expected);
          numFails += 1;
        }
      }
    }
  }
  
  const uint8_t *blockOptimalKTablePtr = (const uint8_t *) halfBlockOptimalKTableVec.data();
  int blockOptimalKTableLen = (int) halfBlockOptimalKTableVec.size();
  
  vector<uint8_t> riceEncodedVec = encodeRice2(s32OrderPixels,
                                               numBlockSymbols,
                                               blockDim,
                                               blockOptimalKTablePtr,
                                               blockOptimalKTableLen,
                                               blockN);

  printf("encode %d bytes as %d rice encoded bytes\n", numBlockSymbols, (int)riceEncodedVec.size());
  
#if defined(DEBUG)
  {
    vector<uint8_t> outBufferVec(numBlockSymbols);
    uint8_t *outBuffer = outBufferVec.data();
    
    vector<uint32_t> bitOffsetsEveryVal = generateBitOffsetsRice2(s32OrderPixels,
                                                                  numBlockSymbols,
                                                                  blockDim,
                                                                  blockOptimalKTablePtr,
                                                                  blockOptimalKTableLen,
                                                                  blockN,
                                                                  1);

    decodeRice2(riceEncodedVec.data(),
           (int)riceEncodedVec.size(),
           outBuffer,
           numBlockSymbols,
           blockDim,
           blockOptimalKTablePtr,
           blockOptimalKTableLen,
           blockN,
           bitOffsetsEveryVal.data());
    
    int cmp = memcmp(s32OrderPixels, outBuffer, numBlockSymbols);
    assert(cmp == 0);
    
    // Decode with non-stream rice method and validate against known good decoded values stream
    
    decodeRice2ParallelCheck(riceEncodedVec.data(),
                        (int)riceEncodedVec.size(),
                        outBuffer,
                        numBlockSymbols,
                        blockDim,
                        blockOptimalKTablePtr,
                        blockOptimalKTableLen,
                        blockN,
                        bitOffsetsEveryVal.data());
  }
#endif // DEBUG
  
  // Fill in inoutBlockBitOffsetTable with bit offsets every 16 values (1/2 block)
  
  vector<uint32_t> bitOffsetsEveryHalfBlock = generateBitOffsetsRice2(s32OrderPixels,
                                                                      numBlockSymbols,
                                                                      blockDim,
                                                                      blockOptimalKTablePtr,
                                                                      blockOptimalKTableLen,
                                                                      blockN,
                                                                      (blockDim * blockDim)/2);

  // Copy bits out
  
  [riceEncodedStream setLength:riceEncodedVec.size()];
  memcpy(riceEncodedStream.mutableBytes, riceEncodedVec.data(), riceEncodedVec.size());
  
  // Copy offsets for each half block back out
  
  {
    int numBytes = (int) (bitOffsetsEveryHalfBlock.size() * sizeof(uint32_t));
    [halfBlockOffsetTable setLength:numBytes];
    memcpy(halfBlockOffsetTable.mutableBytes, bitOffsetsEveryHalfBlock.data(), numBytes);
  }
  
  return;
}


@end
