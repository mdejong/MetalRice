// Objective C interface to rice parsing functions
//  MIT Licensed

#import <Foundation/Foundation.h>

extern
int optimalRiceK(
                 const uint8_t * inBytes,
                 int inNumBytes,
                 int blocki);

// Our platform independent render class
@interface Rice : NSObject

// Given an input buffer, encode the input values and generate
// output that corresponds to rice encoded var length symbols.

+ (void) encodeBits:(const uint8_t*)inBytes
         inNumBytes:(int)inNumBytes
 blockOptimalKTable:(uint8_t*)blockOptimalKTable
blockOptimalKTableDataLength:(int)blockOptimalKTableDataLength
          numBlocks:(int)numBlocks
           outCodes:(NSMutableData*)outCodes
 outBlockBitOffsets:(NSMutableData*)outBlockBitOffsets
              width:(int)width
             height:(int)height
           blockDim:(int)blockDim;

// Unoptimized serial decode logic. Note that this logic
// assumes that huffBuff contains +2 bytes at the end
// of the buffer to account for read ahead.

+ (void) decodeBlockSymbols:(int)numSymbolsToDecode
                    bitBuff:(uint8_t*)bitBuff
                   bitBuffN:(int)bitBuffN
         blockOptimalKTable:(const uint8_t*)blockOptimalKTable
   blockOptimalKTableLength:(int)blockOptimalKTableLength
                  numBlocks:(int)numBlocks
                  outBuffer:(uint8_t*)outBuffer
    blockStartBitOffsetsPtr:(uint32_t*)blockStartBitOffsetsPtr;

// Encode symbols by calculating signed byte deltas
// and then converting to zerod deltas which can
// be represented as positive integer values.

+ (NSData*) encodeSignedByteDeltas:(NSData*)data;

// Decode symbols by reversing zerod mapping and then applying
// signed 8 bit deltas to recover the original symbols as uint8_t.

+ (NSData*) decodeSignedByteDeltas:(NSData*)deltas;

// Given the original input pixels, do block split and processing into deltas
// along with reordering to reduce information down to a minumim. The
// blockWidth and blockHeight can be passed in as a non-zero value, otherwise
// the blockWidth and blockHeight are calculated from the input.

+ (void) blockDeltaEncoding:(const uint8_t *)inBytes
                 inNumBytes:(int)inNumBytes
                      width:(int)width
                     height:(int)height
                 blockWidth:(int)blockWidth
                blockHeight:(int)blockHeight
       outEncodedBlockBytes:(NSMutableData*)outEncodedBlockBytes
              numBaseValues:(int *)numBaseValues
             numBlockValues:(int *)numBlockValues;

// Convert image order to block order but do not do deltas

+ (void) blockEncoding:(const uint8_t *)inBytes
            inNumBytes:(int)inNumBytes
                 width:(int)width
                height:(int)height
            blockWidth:(int)blockWidth
           blockHeight:(int)blockHeight
  outEncodedBlockBytes:(NSMutableData*)outEncodedBlockBytes;

// Two stage delta encoding logic where a large block is used to generate deltas,
// then the block order delta bytes are converted back to image order before
// a smaller block size is used to break deltas up into smaller blocks.

+ (void) blockDeltaEncoding2Stage:(const uint8_t *)inBytes
                       inNumBytes:(int)inNumBytes
                            width:(int)width
                           height:(int)height
                       blockWidth:(int)blockWidth
                      blockHeight:(int)blockHeight
             outEncodedBlockBytes:(NSMutableData*)outEncodedBlockBytes;

// Decode deltas and reorder and crop

+ (void) blockDeltaDecode:(int)numSymbols
        blockOrderSymbols:(const uint8_t*)blockOrderSymbols
        imageOrderSymbols:(uint8_t*)imageOrderSymbols
                    width:(int)width
                   height:(int)height
               blockWidth:(int)blockWidth
              blockHeight:(int)blockHeight;

+ (void) optRiceK:(NSData*)blockOrderSymbolsData
blockOptimalKTableData:(NSMutableData*)blockOptimalKTableData
    numBaseValues:(int *)numBaseValues
   numBlockValues:(int *)numBlockValues;

+ (void) decodePrefixBits:(int)numSymbolsToDecode
                  bitBuff:(uint8_t*)bitBuff
                 bitBuffN:(int)bitBuffN
                numBlocks:(int)numBlocks
                outBuffer:(uint8_t*)outBuffer;

+ (void) flattenBlockBytes:(int)blockDim
                 numPixels:(int)numPixels
                  inPixels:(const uint8_t*)inPixels
                 outPixels:(uint8_t*)outPixels
                     width:(int)width
                    height:(int)height
                blockWidth:(int)blockWidth
               blockHeight:(int)blockHeight;

// Encode Rice2 style stream with prefx, escape, unary are all encoded
// into a single stream that is read word by word in 32 different threads.

+ (void) encodeRice2Stream:(NSData*)inBytes
                    blockN:(int)blockN
                     width:(int)width
                    height:(int)height
         riceEncodedStream:(NSMutableData*)riceEncodedStream
        blockOptimalKTable:(NSMutableData*)blockOptimalKTable
    halfBlockOptimalKTable:(NSMutableData*)halfBlockOptimalKTable
      halfBlockOffsetTable:(NSMutableData*)halfBlockOffsetTable;

@end
