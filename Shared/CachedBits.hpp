//
//  CachedBits.hpp
//
//  Created by Mo DeJong on 6/3/18.
//  Copyright © 2018 helpurock. All rights reserved.
//
// Cached bit reading logic where a read operation fills two cached
// registers from a slow read source. The registers C1 and C2 hold
// data that has been read in from an input pointer that is the same
// type as C1 and C2. Both C1 and C2 must be GTEQ than DEST in terms
// of the number of bits that the type can contain.
//
// For example, with C1 and C2 defined as uint64_t and
// DEST defined as uint32_t, then 64 bit reads will be segmented
// into 32 bits chunks when read 32 bits at a time. Reads will
// fill C1 and then C2. The C2 register is always filled N bits
// at a time depending on the size of C2. The C1 register can
// contain a number of bits LTEQ the size of the register.

#ifndef cached_bits_hpp
#define cached_bits_hpp

// If this symbol is not defined, no output debug code is generated
//#define EMIT_CACHEDBITS_DEBUG_OUTPUT

#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
#include "byte_bit_stream.hpp"
#include "rice_util.hpp"
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT

#if !defined(CACHEDBIT_THREAD_SPECIFIC)
#define CACHEDBIT_THREAD_SPECIFIC
#endif // CACHEDBIT_THREAD_SPECIFIC

template <typename CACHED, typename CACHED_PTR, typename DST, typename NBITS>
class CachedBits
{
public:
  CACHED_PTR inPtr;
  
#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
  CACHED_PTR inPtrOrig;
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT
  
  CACHED c1;
  CACHED c2;
  
  NBITS c1NumBits;
  NBITS c2NumBits;
  
  CachedBits()
  :
  inPtr((CACHED_PTR)nullptr),
#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
  inPtrOrig((CACHED_PTR)nullptr),
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT
  c1(0),
  c2(0),
  c1NumBits(0),
  c2NumBits(0)
  {
  }
  
  NBITS numCachedBits() {
    return sizeof(CACHED) * 8;
  }
  
  NBITS numDstBits() {
    // Calc num bits that can be helsd by type
    return sizeof(DST) * 8;
  }
  
  void initBits(CACHED_PTR srcPtr, uint32_t skipBits = 0) {
#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
    
# if defined(PRIVATE_METAL_SHADER_COMPILATION)
#error "initBits and PRIVATE_METAL_SHADER_COMPILATION"
# endif // METAL_COMP_DEFINE
    
    const bool debug = false;
    
    if (debug) {
      printf("CachedBits.init()\n");
    }
#else
#if !defined(PRIVATE_METAL_SHADER_COMPILATION)
#error "expected EMIT_CACHEDBITS_DEBUG_OUTPUT to be defined"
#endif // PRIVATE_METAL_SHADER_COMPILATION
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT
    
    inPtr = (CACHED_PTR) srcPtr;
#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
    inPtrOrig = (CACHED_PTR)srcPtr;
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT

    uint32_t numCachedUnits = 0;
    uint8_t numBitsOver = 0;
    
    if (skipBits != 0) {
      numCachedUnits = skipBits / numCachedBits();
#if defined(DEBUG)
      // Make sure that calculating number of pointer units to
      // skip does not overflow numCachedUnits variable.
      assert((skipBits / numCachedBits()) == numCachedUnits);
#endif // DEBUG
      
      numBitsOver = skipBits % numCachedBits();
      
#if defined(DEBUG)
      assert((skipBits % numCachedBits()) == numBitsOver);
#endif // DEBUG
    }
    
    inPtr += numCachedUnits;
    
    c1 = read();
    c1NumBits = numCachedBits();
    
    c2 = read();
    c2NumBits = numCachedBits();
    
#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
    if (debug) {
      if (numCachedBits() == 64) {
        printf("c1 : %s : c1NumBits %d : 0x%016llX\n", get_code_bits_as_string64(c1, 64).c_str(), (int)c1NumBits, c1);
        printf("c2 : %s : c2NumBits %d : 0x%016llX\n", get_code_bits_as_string64(c2, 64).c_str(), (int)c2NumBits, c2);
      } else {
        printf("c1 : %s : c1NumBits %d : 0x%08X\n", get_code_bits_as_string64(c1, 32).c_str(), (int)c1NumBits, c1);
        printf("c2 : %s : c2NumBits %d : 0x%08X\n", get_code_bits_as_string64(c2, 32).c_str(), (int)c2NumBits, c2);
      }
    }
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT
    
    // It is possible that N additional bits at the front of c1 still
    // need to be skipped.
    
    if (numBitsOver > 0) {
      // c1NumBits cannot be zero after this subtract step
#if defined(DEBUG)
      
# if defined(PRIVATE_METAL_SHADER_COMPILATION)
#error "assert and PRIVATE_METAL_SHADER_COMPILATION"
# endif // PRIVATE_METAL_SHADER_COMPILATION
      
#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
      if (debug && (numBitsOver > 0)) {
        printf("initial c1 contains %d bits at the front of the buffer that will be dropped\n", numBitsOver);
      }
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT
      
      assert(numBitsOver < numCachedBits());
      assert(c1NumBits > numBitsOver);
#endif // DEBUG
      
      // numBitsOver can never be larger than the number of bits in type here
      c1 <<= numBitsOver;
      c1NumBits -= numBitsOver;
    }

#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
    if (debug && (numBitsOver > 0)) {
      if (numCachedBits() == 64) {
        printf("c1 : %s : c1NumBits %d : 0x%016llX\n", get_code_bits_as_string64(c1, 64).c_str(), (int)c1NumBits, c1);
        printf("c2 : %s : c2NumBits %d : 0x%016llX\n", get_code_bits_as_string64(c2, 64).c_str(), (int)c2NumBits, c2);
      } else {
        printf("c1 : %s : c1NumBits %d : 0x%08X\n", get_code_bits_as_string64(c1, 32).c_str(), (int)c1NumBits, c1);
        printf("c2 : %s : c2NumBits %d : 0x%08X\n", get_code_bits_as_string64(c2, 32).c_str(), (int)c2NumBits, c2);
      }
    }
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT
    
    return;
  }
  
  CACHED read() {
#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
    const bool debug = false;
    if (debug) {
      int offset = (int)(inPtr - inPtrOrig);
      printf("CachedBits.read() (word offset = %5d)\n", offset);
    }
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT
    
    CACHED v = *inPtr++;
    return v;
  }
  
  // Implements left/right shift except that this method handles the
  // weird edgecase where the number of bits to be shifted
  // could be 32. This should shift all the bits out of the
  // register and return zero but C does not define this behavior.
  // Note that Metal defines a zero fill rule for unsigned numbers
  // so special handling is not needed.
  
  inline
  CACHED zerodShiftLeft(CACHED val, NBITS shiftNBits) {
#if defined(DEBUG)
    assert(shiftNBits <= numCachedBits());
#endif // DEBUG
    
#if defined(CACHEDBIT_METAL_IMPL)
    return (val << shiftNBits);
#else
    if ((0)) {
      CACHED shifted;
      if (shiftNBits == numCachedBits()) {
        shifted = 0;
      } else {
        shifted = (val << shiftNBits);
      }
      return shifted;
    } else {
      bool cond = (shiftNBits == numCachedBits());
      val = (cond ? 0 : val);
      shiftNBits = (cond ? 0 : shiftNBits);
      CACHED shifted = (val << shiftNBits);
      return shifted;
    }
#endif // CACHEDBIT_METAL_IMPL
  }
  
  inline
  CACHED zerodShiftRight(CACHED val, NBITS shiftNBits) {
#if defined(DEBUG)
    assert(shiftNBits <= numCachedBits());
#endif // DEBUG

    // A plain bit shift should work but Metal seems to define a right shift by 32
    // as a nop instead of a zero fill. Work around this problem with the same
    // logic for both C/C++ and Metal.
    
    //return (val >> shiftNBits);
    
    if ((0)) {
      CACHED shifted;
      if (shiftNBits == numCachedBits()) {
        shifted = 0;
      } else {
        shifted = (val >> shiftNBits);
      }
      return shifted;
    } else {
      bool cond = (shiftNBits == numCachedBits());
      val = (cond ? 0 : val);
      shiftNBits = (cond ? 0 : shiftNBits);
      CACHED shifted = (val >> shiftNBits);
      return shifted;
    }
  }
  
  // Refill will always copy 1 to N bits from the cached bits
  // into a DST type register. The number of bits currently
  // in dst is passed in as dstNumBits and this value is
  // updated to the full size of DST before this method returns.
  
  void refill(CACHEDBIT_THREAD_SPECIFIC DST & dst, CACHEDBIT_THREAD_SPECIFIC NBITS & dstNumBits, const bool allowRefillWhenFull = false) {
    const NBITS dstFullNumBits = numDstBits();
    NBITS inDstNumBits = dstNumBits;
    NBITS numBitsNeeded = dstFullNumBits - inDstNumBits;
    
#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
    const bool debug = false;
    
    if (debug) {
      printf("CachedBits.refill()\n");
      
      if (numCachedBits() == 64) {
        printf("c1 : %s : c1NumBits %2d : 0x%016llX\n", get_code_bits_as_string64(c1, 64).c_str(), (int)c1NumBits, c1);
        printf("c2 : %s : c2NumBits %2d : 0x%016llX\n", get_code_bits_as_string64(c2, 64).c_str(), (int)c2NumBits, c2);
      } else {
        printf("c1 : %s : c1NumBits %2d : 0x%08X\n", get_code_bits_as_string64(c1, 32).c_str(), (int)c1NumBits, c1);
        printf("c2 : %s : c2NumBits %2d : 0x%08X\n", get_code_bits_as_string64(c2, 32).c_str(), (int)c2NumBits, c2);
      }
      
      printf("c1NumBits %d\n", (int)c1NumBits);
      printf("c2NumBits %d\n", (int)c2NumBits);
      printf("dstNumBits %d\n", (int)inDstNumBits);
      printf("numBitsNeeded %d\n", (int)numBitsNeeded);
    }
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT
    
#if defined(DEBUG)
    {
      assert(inDstNumBits >= 0);
      // dstNumBits must be smaller than the full number
      // of bits in a register, this is required so that
      // each pass is gaurenteed to process 1 symbol.
      if (allowRefillWhenFull == false) {
        // Check that dst register is not already full
        assert(inDstNumBits < dstFullNumBits);
      }
    }
#endif // DEBUG
    
    // Copy N bits at top of c1 into dst
    
    const NBITS dstShift = numCachedBits() - numDstBits();
    
    if (numBitsNeeded <= c1NumBits) {
      // There are enough bits in C1 to fill the dst register
      
#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
      if (debug) {
        if (numCachedBits() == 64) {
          printf("c1  : %s : c1NumBits %2d : 0x%016llX\n", get_code_bits_as_string64(c1, 64).c_str(), (int)c1NumBits, c1);
          printf("c2  : %s : c2NumBits %2d : 0x%016llX\n", get_code_bits_as_string64(c2, 64).c_str(), (int)c2NumBits, c2);
        } else if (numCachedBits() == 32) {
          printf("c1  : %s : c1NumBits %2d : 0x%08X\n", get_code_bits_as_string64(c1, 32).c_str(), (int)c1NumBits, c1);
          printf("c2  : %s : c2NumBits %2d : 0x%08X\n", get_code_bits_as_string64(c2, 32).c_str(), (int)c2NumBits, c2);
        }
      }
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT

      
#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
      if (debug) {
        if (numDstBits() == 16) {
          printf("dst : %s : inDstNumBits %2d : 0x%04X\n", get_code_bits_as_string64(dst, 16).c_str(), (int)inDstNumBits, dst);
        } else {
          printf("dst : %s : inDstNumBits %2d : 0x%08X\n", get_code_bits_as_string64(dst, 32).c_str(), (int)inDstNumBits, dst);
        }
      }
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT
      
#if defined(DEBUG)
      if (allowRefillWhenFull == false) {
        assert((inDstNumBits + dstShift) < numCachedBits());
      }
#endif // DEBUG
      
      NBITS shiftBy = (inDstNumBits + dstShift);
      dst |= zerodShiftRight(c1, shiftBy);
      dstNumBits += numBitsNeeded;

#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
      if (debug) {
        if (numDstBits() == 16) {
          printf("dst : %s :   dstNumBits %2d : 0x%04X\n", get_code_bits_as_string64(dst, 16).c_str(), (int)dstNumBits, dst);
        } else {
          printf("dst : %s :   dstNumBits %2d : 0x%08X\n", get_code_bits_as_string64(dst, 32).c_str(), (int)dstNumBits, dst);
        }
      }
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT
      
      c1 = zerodShiftLeft(c1, numBitsNeeded);
      c1NumBits -= numBitsNeeded;
      
      if (c1NumBits == 0)
      {
        // c1 is empty, load from c2 and async refill c2
        c1 = c2;
        c1NumBits = numCachedBits();
        c2 = read();
        c2NumBits = numCachedBits();
      }
    } else {
      // There are not enough bits in C1 to fill the dst register,
      // copy the bits that are in C1 and then finish the fill
      // with the bits from C2.
      
#if defined(DEBUG)
      assert(numBitsNeeded > c1NumBits);
      assert((inDstNumBits + dstShift) < numCachedBits());
#endif // DEBUG
      
      NBITS shiftBy = (inDstNumBits + dstShift);
      dst |= zerodShiftRight(c1, shiftBy);
      dstNumBits += c1NumBits;
      numBitsNeeded -= c1NumBits;
      
#if defined(DEBUG)
      assert(numBitsNeeded > 0);
#endif // DEBUG
      
      // c1 is now empty, move c2 over c1
      // and async read into c2.
      
      {
        c1 = c2;
        c1NumBits = numCachedBits();
        c2 = read();
        c2NumBits = numCachedBits();
        
#if defined(DEBUG)
        {
          // Number of bits in C1 at this point must be
          // larger than the number needed in DST. This
          // is required so that reading into DST does
          // not require more than a single read from
          // the slow source in an if branch.
          assert(c1NumBits > numBitsNeeded);
        }
#endif // DEBUG
        
        // Copy remaining needed bits into dst
        
#if defined(DEBUG)
        assert((dstNumBits + dstShift) < numCachedBits());
#endif // DEBUG
        
        NBITS shiftBy = (dstNumBits + dstShift);
        dst |= zerodShiftRight(c1, shiftBy);
        dstNumBits += numBitsNeeded;
        
#if defined(DEBUG)
        assert(numBitsNeeded < numCachedBits());
#endif // DEBUG
        
        c1 = zerodShiftLeft(c1, numBitsNeeded);
        c1NumBits -= numBitsNeeded;
      }
      
#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
      if (debug) {
        if (numDstBits() == 16) {
          printf("dst : %s :   dstNumBits %2d : 0x%04X\n", get_code_bits_as_string64(dst, 16).c_str(), (int)dstNumBits, dst);
        } else {
          printf("dst : %s :   dstNumBits %2d : 0x%08X\n", get_code_bits_as_string64(dst, 32).c_str(), (int)dstNumBits, dst);
        }
      }
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT

    }
    
# if defined(DEBUG)
    {
      const NBITS tmpNumBits = numCachedBits();
      
      assert(c1NumBits > 0);
      assert(c1NumBits <= tmpNumBits);
      
      assert(c2NumBits == tmpNumBits);
    }
# endif // DEBUG
    
#if defined(EMIT_CACHEDBITS_DEBUG_OUTPUT)
    if (debug) {
      if (numCachedBits() == 64) {
        printf("c1  : %s : c1NumBits %2d : 0x%016llX\n", get_code_bits_as_string64(c1, 64).c_str(), (int)c1NumBits, c1);
        printf("c2  : %s : c2NumBits %2d : 0x%016llX\n", get_code_bits_as_string64(c2, 64).c_str(), (int)c2NumBits, c2);
      } else if (numCachedBits() == 32) {
        printf("c1  : %s : c1NumBits %2d : 0x%08X\n", get_code_bits_as_string64(c1, 32).c_str(), (int)c1NumBits, c1);
        printf("c2  : %s : c2NumBits %2d : 0x%08X\n", get_code_bits_as_string64(c2, 32).c_str(), (int)c2NumBits, c2);
      }
    }
#endif // EMIT_CACHEDBITS_DEBUG_OUTPUT
    
# if defined(DEBUG)
    assert(dstNumBits == numDstBits());
# endif // DEBUG
  }
  
};

#endif // cached_bits_hpp
