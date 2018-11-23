// Objective C interface to elias gamma parsing functions
//  MIT Licensed

#import "DeltaEncoder.h"

#include <assert.h>

#include <string>
#include <vector>
#include <unordered_map>
#include <cstdint>

#import "EncDec.hpp"

using namespace std;

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

// zerod representation

// 0 = 0, -1 = 1, 1 = 2, -2 = 3, 2 = 4, -3 = 5, 3 = 6

uint32_t
pixelpack_num_neg_to_offset(int32_t value) {
    if (value == 0) {
        return value;
    } else if (value < 0) {
        return (value * -2) - 1;
    } else {
        return value * 2;
    }
}

int32_t
pixelpack_offset_to_num_neg(uint32_t value) {
    if (value == 0) {
        return value;
    } else if ((value & 0x1) != 0) {
        // odd numbers are negative values
        return ((int)value + 1) / -2;
    } else {
        return value / 2;
    }
}

int8_t
pixelpack_offset_uint8_to_int8(uint8_t value)
{
    int offset = (int) value;
    int iVal = pixelpack_offset_to_num_neg(offset);
    assert(iVal >= -128);
    assert(iVal <= 127);
    int8_t sVal = (int8_t) iVal;
    return sVal;
}

uint8_t
pixelpack_int8_to_offset_uint8(int8_t value)
{
    int iVal = (int) value;
    int offset = pixelpack_num_neg_to_offset(iVal);
    assert(offset >= 0);
    assert(offset <= 255);
    uint8_t offset8 = offset;
#if defined(DEBUG)
    {
        // Validate reverse operation, it must regenerate value
        int8_t decoded = pixelpack_offset_uint8_to_int8(offset8);
        assert(decoded == value);
    }
#endif // DEBUG
    return offset8;
}

// Main class performing the rendering

@implementation DeltaEncoder

// Encode symbols by calculating signed byte deltas
// and then converting to zerod deltas which can
// be represented as positive integer values.

+ (NSData*) encodeByteDeltas:(NSData*)data
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
      *outZerodDeltaPtr++ = sVal;
  }

  return [NSData dataWithData:outZerodDeltaBytes];
}

// Decode symbols by reversing zigzag mapping and then applying
// signed 8 bit deltas to recover the original symbols as uint8_t.

+ (NSData*) decodeByteDeltas:(NSData*)deltas
{
  const int maxNumBytes = (int) deltas.length;

  vector<uint8_t> signedDeltaBytes;
  signedDeltaBytes.resize(maxNumBytes);
  const uint8_t *zerodDeltasPtr = (uint8_t *) deltas.bytes;
  
  for (int i = 0; i < maxNumBytes; i++) {
    uint8_t bVal = zerodDeltasPtr[i];
    signedDeltaBytes[i] = bVal;
  }

  // Apply signed deltas
  vector<uint8_t> outSymbols = decodeDelta(signedDeltaBytes);
    
  NSMutableData *mData = [NSMutableData data];
  [mData setLength:maxNumBytes];
  memcpy((void*)mData.mutableBytes, (void*)outSymbols.data(), maxNumBytes);
    
  return [NSData dataWithData:mData];
}

@end


// Entry point for byte delta logic, changes values in place

void bytedelta_generate_deltas(uint8_t *bytePtr, int numBytes) {
  vector<uint8_t> inVec;
  
  inVec.resize(numBytes);
  memcpy(inVec.data(), bytePtr, numBytes);
  
  vector<uint8_t> deltaVec = encodeDelta(inVec);
  
  memcpy(bytePtr, deltaVec.data(), numBytes);
}

void bytedelta_decode_deltas_vec(uint8_t *bytePtr, int numBytes) {
  vector<uint8_t> inVec;
  
  inVec.resize(numBytes);
  memcpy(inVec.data(), bytePtr, numBytes);
  
  decodePlusDeltaDirect(inVec, false);
  
  memcpy(bytePtr, inVec.data(), inVec.size());
}

// Directly undelta using uint8_t datatype

void bytedelta_decode_deltas(uint8_t *bytePtr, int numBytes) {
  uint8_t prev;
  
  // The first value is always a delta from zero, so handle it before
  // the loop logic.
  
#if defined(DEBUG)
  assert(numBytes > 0);
#endif // DEBUG
  
  {
    prev = bytePtr[0];
  }
  
  /*
  #pragma unroll(1)
  for (int i = 1; i < 8; i++) {
    uint8_t delta = bytePtr[i];
    uint8_t val = prev + delta;
    bytePtr[i] = val;
    prev = val;
  }

  #pragma unroll(128)
  for (int i = 8; i < numBytes; i++) {
    uint8_t delta = bytePtr[i];
    uint8_t val = prev + delta;
    bytePtr[i] = val;
    prev = val;
  }
  */

  /*
//  #pragma unroll(4)
//  #pragma unroll(8)
//  #pragma unroll(16)
//  #pragma unroll(32)
//  #pragma unroll(64)
  #pragma unroll(128)
   //#pragma unroll(32)
   //#pragma unroll(64)
   //#pragma unroll(128)
   //#pragma unroll(256)
   //#pragma unroll(512)
   //#pragma unroll(1024)
  for (int i = 1; i < numBytes; i++) {
    uint8_t delta = bytePtr[i];
    uint8_t val = prev + delta;
    bytePtr[i] = val;
    prev = val;
  }
  */

  bytePtr += 1;
  numBytes -= 1;

  // 8 seems to be the magic number, often 2 ms
  #pragma unroll(8)
  for ( ; numBytes > 0; numBytes-- ) {
    uint8_t delta = *bytePtr;
    uint8_t val = prev + delta;
    prev = val;
    *bytePtr++ = val;
  }
  
  return;
}

// Read 64 bits at a time and write bytes

void bytedelta_decode_deltas_64(uint8_t *bytePtr, int numBytes) {
  uint8_t prev;
  
  // The first value is always a delta from zero, so handle it before
  // the loop logic.
  
#if defined(DEBUG)
  assert(numBytes > 0);
#endif // DEBUG
  
  uint64_t *dwordPtr = (uint64_t *) bytePtr;
  assert((numBytes % 8) == 0);

  uint64_t dword = *dwordPtr;
  uint64_t outDword = 0;
  
  {
    prev = dword & 0xFF;
    dword >>= 8;
    outDword = prev;
  }
  
  // Next 7 bytes are deltas

  for (int i = 1; i < 8; i++) {
    uint8_t delta = dword & 0xFF;
    dword >>= 8;
    uint64_t val = prev + delta;
    //val &= 0xFF;
    outDword |= (val << (8 * i));
    prev = val;
  }
  
  *dwordPtr = outDword;
  
  dwordPtr++;
  
  // Now iterate in terms of whole 8 byte dwords
  
  for (int i = 8; i < numBytes; i += sizeof(uint64_t)) {
    dword = *dwordPtr;
    outDword = 0;
    
    for (int j = 0; j < 8; j++) {
      uint8_t delta = dword & 0xFF;
      dword >>= 8;
      
      uint64_t val = prev + delta;
      //val &= 0xFF;
      
      outDword |= (val << (8 * j));
      
      prev = val;
    }

    *dwordPtr = outDword;
    dwordPtr++;
  }
  
  return;
}

// Read 64 bits at a time, write bytes back out

void bytedelta_decode_deltas_64_write_bytes(uint8_t *bytePtr, int numBytes) {
  uint8_t prev;
  
  // The first value is always a delta from zero, so handle it before
  // the loop logic.
  
#if defined(DEBUG)
  assert(numBytes > 0);
  assert((numBytes % 8) == 0);
#endif // DEBUG
  
  uint64_t *dwordPtr = (uint64_t *) bytePtr;
  
  uint64_t dword = *dwordPtr++;
  
  {
    prev = dword & 0xFF;
    dword >>= 8;
  }
  
  // No need to rewrite initial value
  bytePtr += 1;
  
  // Next 7 bytes are deltas
  
  for (int i = 1; i < 8; i++) {
    uint8_t delta = dword & 0xFF;
    dword >>= 8;
    
    uint8_t val = prev + delta;
    
    *bytePtr++ = val;
    
    prev = val;
  }
  
  // Now iterate in terms of whole 8 byte dwords

  #pragma unroll(8)
  for (int i = 8; i < numBytes; i += sizeof(uint64_t)) {
    dword = *dwordPtr++;
    
    for (int j = 0; j < 8; j++) {
      uint8_t delta = dword & 0xFF;
      dword >>= 8;
      
      uint8_t val = prev + delta;
      
      *bytePtr++ = val;
      
      prev = val;
    }
  }
  
  return;
}
