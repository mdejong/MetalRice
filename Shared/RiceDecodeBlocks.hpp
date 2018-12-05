//
//  RiceDecodeBlocks.hpp
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

#ifndef rice_decode_blocks_hpp
#define rice_decode_blocks_hpp

//#define EMIT_CACHEDBITS_DEBUG_OUTPUT
#import "CachedBits.hpp"

// Define this symbol to use Metal clz instruction
//#define RICEDECODEBLOCKS_METAL_CLZ

// Define this symbol to enable a uint32_t counter of
// the total number of bits read from a stream.
//#define RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL

//#define EMIT_RICEDECODEBLOCKS_DEBUG_OUTPUT

// Read suffix from symbol input, note that this method is not optimal
// for the k = 0 case since the whole block is not skipped.

template <typename T>
uint8_t rice_rdb_decode_symbol(
                                      CACHEDBIT_THREAD_SPECIFIC T & rdb,
                                      const uint8_t k)
{
  ushort prefixByte = rdb.decodePrefixByte(k, false, 0, true);
  prefixByte |= rdb.decodeSuffixByte(k, false, 0, true);
  return prefixByte;
}

// RiceDecodeBlocks

template <typename T, typename R, const bool ALWAYS_REFILL = false>
class RiceDecodeBlocks
{
public:
  
  T cachedBits;
  R reg;
  uint8_t regN;
  
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
  uint32_t totalNumBitsRead;
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
  
  RiceDecodeBlocks()
  :
  cachedBits(), // Default constructor
  reg(0),
  regN(0)
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
  ,
  totalNumBitsRead(0)
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
  {
  }

  // Parse a prefix byte from the stream, returns CLZ+1
  // and shifts modified bits out of the register. This
  // logic must assume that at least 1 bit is always
  // consumed by a method invocation.
  
  uint8_t parsePrefixByte() {
#if defined(EMIT_RICEDECODEBLOCKS_DEBUG_OUTPUT)
    
# if defined(PRIVATE_METAL_SHADER_COMPILATION)
#error "parsePrefixByte and PRIVATE_METAL_SHADER_COMPILATION"
# endif // METAL_COMP_DEFINE
    
    const bool debug = false;
    if (debug) {
      printf("parsePrefixByte : regN %3d : reg 0x%4X\n", regN, reg);
    }
#endif // EMIT_RICEDECODEBLOCKS_DEBUG_OUTPUT
    
    // Assume that clz of zero will always consume at least
    // 1 bit, so unconditionally load at least 1 bit so
    // that the register is completely full for each invocation.
    
    if (ALWAYS_REFILL || reg == 0) {
      // If reg is non-zero then at least 1 bit is set, so the
      // clz operator will return the correct value without actually
      // loading additional bits from c1. This optimization means
      // that the code flow is optimal for the vast majority of
      // cases where no reload is needed.
      
#if defined(EMIT_RICEDECODEBLOCKS_DEBUG_OUTPUT)
      if (debug) {
        if (ALWAYS_REFILL) {
          printf("parsePrefixByte : reloading register 16 from c1 since ALWAYS_REFILL is true\n");
        } else {
          printf("parsePrefixByte : reloading register 16 from c1 since reg is zero\n");
          assert(reg == 0);
        }
      }
#endif // EMIT_RICEDECODEBLOCKS_DEBUG_OUTPUT
      
#if defined(DEBUG)
# if defined(PRIVATE_METAL_SHADER_COMPILATION)
#error "assert and PRIVATE_METAL_SHADER_COMPILATION"
# endif // PRIVATE_METAL_SHADER_COMPILATION
      assert(regN < numRegBits());
#endif // DEBUG
      
      cachedBits.refill(reg, regN);
      
#if defined(DEBUG)
      assert(regN == numRegBits());
#endif // DEBUG
    }
    
    // At this point, reg can contain fewer than 16 bits, but in
    // the special escape case a refill would have been done above.
    // Execute the clz on the 16 bit reg knowing that the branch
    // over the refill() above is taken on almost every thread.
    
#if defined(RICEDECODEBLOCKS_METAL_CLZ)
    // clz on 16 bit register in Metal. Metal shading language
    // spec indicates that clz(0) returns 16 in this situation.
    uint8_t clzReg = clz(reg);
    uint8_t prefixCount = clzReg + 1;
#else // RICEDECODEBLOCKS_METAL_CLZ
    // clz with 32 bit gcc builtin instruction
    unsigned int clz;
    if ((reg >> (numRegBits() - 16)) == 0) {
      // __builtin_clz(0) is undefined
      clz = 16 + 16;
    } else {
      unsigned int reg32 = reg;
      if (numRegBits() == 32) {
        reg32 >>= 8;
        reg32 >>= 8;
      }
      clz = __builtin_clz(reg32);
    }
#if defined(DEBUG)
    assert(clz >= 16);
#endif // DEBUG
    clz -= 16;
    uint8_t prefixCount = (uint8_t) (clz + 1);
#endif // RICEDECODEBLOCKS_METAL_CLZ
    
#if defined(EMIT_RICEDECODEBLOCKS_DEBUG_OUTPUT)
    if (debug) {
      printf("clz(0x%04X) -> %d : prefixCount %d\n", reg, clz, prefixCount);
    }
#endif // EMIT_RICEDECODEBLOCKS_DEBUG_OUTPUT
    
#if defined(DEBUG)
    // valid prefixCount range (1, 16) not that in the
    // case of 16 zeros the prefixCount result would be 17
    if ((reg >> (numRegBits() - 16)) == 0) {
      assert(prefixCount == 17);
    } else {
      assert(prefixCount >= 1 && prefixCount <= 16);
    }
#endif // DEBUG
    
    // Special case of 17 indicates that 16 bits should be
    // removed from the register.
    
    uint16_t shiftNumBits = (prefixCount == 17) ? 16 : prefixCount;
    
    // Shift reg bits to drop prefixCount bits off the left
    
#if defined(DEBUG)
    assert(regN >= shiftNumBits);
#endif // DEBUG
    
    //#if defined(RICEDECODEBLOCKS_METAL_CLZ)
    // Shift as 16 bit operation without conditional
    //reg = (shiftNumBits == 16) ? 0 : reg << shiftNumBits;
    //regN = (shiftNumBits == 16) ? 0 : regN - shiftNumBits;
    
    //reg <<= shiftNumBits;
    //regN -= shiftNumBits;
    //#else // RICEDECODEBLOCKS_METAL_CLZ
    if (shiftNumBits == numRegBits()) {
      reg = 0;
      regN = 0;
    } else {
      reg <<= shiftNumBits;
      regN -= shiftNumBits;
    }
    //#endif // RICEDECODEBLOCKS_METAL_CLZ
    
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
    totalNumBitsRead += shiftNumBits;
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
    
#if defined(EMIT_RICEDECODEBLOCKS_DEBUG_OUTPUT)
    if (debug) {
      printf("post shift by %2d bits : reg is 0x%04X : regN %2d\n", shiftNumBits, reg, regN);
    }
#endif // EMIT_RICEDECODEBLOCKS_DEBUG_OUTPUT
    
    return prefixCount;
  }
  
  // Return the number of bits width that reg is
  
  inline
  uint8_t numRegBits() {
    // Calc num bits that can be helsd by type
    return sizeof(reg) * 8;
  }
  
  // Execute clz on 16 or 32 bit register, returns q.
  // When successful this method returns a value in the range
  // (0, 15) otherwise a value larger than 15 can be returned.
  
  inline
  ushort clzImpl() {
#if defined(DEBUG)
    const bool debug = false;
#endif // DEBUG

    ushort q;
    
    // clz impl
    
#if defined(RICEDECODEBLOCKS_METAL_CLZ)
    // clz on 16 bit register in Metal. Metal shading language
    // spec indicates that clz(0) returns 16 in this situation.
    // A previous attempt to optimize the clz via
    // clz(ushort(reg >> 16))
    // with a 32 bit register was actually slower and so
    // clz is executed directly on the 16 or 32 bit register.
    
    q = clz(reg);
#else // RICEDECODEBLOCKS_METAL_CLZ
    // clz with 32 bit gcc builtin instruction
    
    uint32_t clzBits;
    
    if (numRegBits() == 16) {
      // 16 bits must be expanded to left anchored 32 bits
      clzBits = ((uint32_t) reg) << 16;
    } else {
      // 32 bits
      clzBits = reg;
    }
    
    if (clzBits == 0) {
      // __builtin_clz(0) is undefined, return 16 for either 16 or 32 sized registers
      q = 16;
    } else {
      q = __builtin_clz(clzBits);
    }
    
# if defined(DEBUG)
    if (debug) {
      printf("reg     : %s\n", get_code_bits_as_string64(reg, numRegBits()).c_str());
      printf("clzBits : %s\n", get_code_bits_as_string64(clzBits, 32).c_str());
      printf("q       : %d\n", q);
    }
# endif // DEBUG
#endif // RICEDECODEBLOCKS_METAL_CLZ
    
    return q;
  }
  
  // Given the successful result q of a CLZ(reg) operation, return the
  // symbol prefix portion and update the bits and bit count registers.
  
  inline
  ushort parseSymbolFromQ(const uint8_t k, const ushort q, const ushort numBitsRead) {
#if defined(DEBUG)
    const bool debug = false;
#endif // DEBUG
    
#if defined(DEBUG)
    if (numBitsRead == (q+1)) {
      assert(q < 16);
    }
#endif // DEBUG
    
#if defined(DEBUG)
    // 16 bits : (reg == 0)
    // 32 bits : ((reg >> 16) == 0)
    assert((reg >> (numRegBits() - 16)) != 0);
#endif // DEBUG
    ushort symbol = q << k;
    
#if defined(DEBUG)
    if (debug) {
      printf("q (num leading zeros): %d\n", q);
    }
    if (debug) {
      printf("symbol      : %s\n", get_code_bits_as_string64(symbol, 8).c_str());
    }
# endif // DEBUG
    
    // Shift left to remove the indicated number of bits from register
    reg <<= numBitsRead;
    
#if defined(DEBUG)
    if (debug) {
      printf("lshift   %2d : %s\n", numBitsRead, get_code_bits_as_string64(reg, numRegBits()).c_str());
    }
# endif // DEBUG
    
# if defined(DEBUG)
    assert(regN >= numBitsRead);
# endif // DEBUG
    regN -= numBitsRead;
    
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
    totalNumBitsRead += numBitsRead;
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
    
    return symbol;
  }
  
  // Parse prefix byte value, always consumes at least 1 bit
  // and returns the byte without the REM portion.
  
  uint8_t decodePrefixByte(const uint8_t k,
                           const bool reloadLT,
                           const uint8_t lt,
                           const bool reloadAlways) {
#if defined(DEBUG)
    const bool debug = false;
#endif // DEBUG
    
#if defined(DEBUG)
    if (debug) {
      printf("decodePrefixByte bits: %s and regN %d : k = %d\n", get_code_bits_as_string64(reg, numRegBits()).c_str(), regN, k);
    }
#endif // DEBUG
    
#if defined(DEBUG)
    if (reloadLT) {
      assert(reloadAlways == false);
    }
    if (reloadAlways) {
      assert(reloadLT == false);
    }
#endif // DEBUG
    
    // Make refill() call unconditional, this provides a significant
    // speedup in the decode pathway, at least 1/2 a ms improvement.
    
    if (reloadAlways)
    {
      cachedBits.refill(reg, regN, true);
      
#if defined(DEBUG)
      assert(regN == numRegBits());
#endif // DEBUG
    }

    // Conditional based on passed in value
    
    if (reloadLT && (regN < lt))
    {
#if defined(DEBUG)
      assert(regN < numRegBits());
#endif // DEBUG
      
      cachedBits.refill(reg, regN);
      
#if defined(DEBUG)
      assert(regN == numRegBits());
#endif // DEBUG
    }
    
    // Unconditionally execute a clz operation to determine
    // if a unary prefix value can be parsed from the stream.
    
    ushort symbol, q, numBitsRead;
    
    // If clz is in the range (0, 15) then a prefix value was parsed successfully.
    
    q = clzImpl();
    
    if (q < 16) {
      // A successful clz is the most likely case by far, so this logic need
      // not require that a full 16 bit be available when at least one of the
      // next 16 bits is on.
      numBitsRead = q + 1;
    } else {
      // clz was not successful, there are not enough bits or
      // there could be 16 zeros in a row, either way refill
      // and then check for the escape special case followed
      // by cleanup path where clz would be executed again.
      
      // Previously this refill was conditional on (regN < numRegBits())
      // it is now unconditional since the refill() is now a nop
      // when register is already full.
      
      {
        cachedBits.refill(reg, regN, true);
        
#if defined(DEBUG)
        assert(regN == numRegBits());
#endif // DEBUG
      }
      
      if ((reg >> (numRegBits() - 16)) == 0) {
        // Escape special case
#if defined(DEBUG)
        assert(regN >= 16);
#endif // DEBUG
        
        if (numRegBits() == 16) {
          // 16 bits
          regN = 0;
          //reg = 0;
        } else {
          // 32 bits
          regN -= 16;
          reg <<= 8;
          reg <<= 8;
        }
        
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
        totalNumBitsRead += 16;
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
        
#if defined(DEBUG)
        if (debug) {
          printf("bits (del16): %s\n", get_code_bits_as_string64(reg, numRegBits()).c_str());
        }
#endif // DEBUG
        
        if (numRegBits() == 16) {
          cachedBits.refill(reg, regN, false);
          
#if defined(DEBUG)
          assert(regN == numRegBits());
#endif // DEBUG
        }

        // The next (8 - k) bits contain OVER bits
        
        const ushort numNotK = 8 - k;
        
# if defined(DEBUG)
        assert(regN >= numNotK);
        assert((numRegBits() - numNotK) < numRegBits());
# endif // DEBUG
        
        // read the OVER bits from prefix stream. Note that
        // this parse logic makes use of common code in
        // parseSymbolFromQ() so that compiler is able to
        // optimize a single path with conditional parts.
        
        //symbol = (reg >> (numRegBits() - numNotK)) << k;
        q = (reg >> (numRegBits() - numNotK));
        numBitsRead = numNotK;
        
        // FIXME: could unconditional refill after the escape special case
        // lead to better 4x in a row processing codegen?
      } else {
        // prefix parse 2nd check, a reload means
        // that clz op must be executed again.
        // The result must be LT 16.
        
# if defined(DEBUG)
        if (numRegBits() == 16) {
          // 16 bits
          assert(reg != 0);
        } else {
          // 32 bits
          assert((reg >> 16) != 0);
        }
        
        assert(regN >= 16);
# endif // DEBUG
        
        q = clzImpl();
        numBitsRead = q + 1;
        // Fall through to parseSymbolFromQ()
      }
    }
    
    // Common logic to return symbol and update reg and bit count
    
    symbol = parseSymbolFromQ(k, q, numBitsRead);
    
#if defined(DEBUG)
    if (debug) {
      printf("append decoded prefix symbol = %d\n", symbol);
    }
#endif // DEBUG
    
    return symbol;
  }
  
  // Return the REM portion k bits wide
  
  uint8_t decodeSuffixByte(const uint8_t k,
                           const bool reloadLT,
                           const uint8_t lt,
                           const bool reloadAlways) {
#if defined(DEBUG)
    const bool debug = false;
#endif // DEBUG
    
#if defined(DEBUG)
    if (debug) {
      printf("decodeSuffixByte bits: %s and rdb.regN %d\n", get_code_bits_as_string64(reg, numRegBits()).c_str(), regN);
    }
#endif // DEBUG
    
    ushort symbol;
    
    // Assume that since reg is 32 bits and this logic can only
    // be accessed after an unconditional refill, so remove this
    // refill path since the most bits that could have been removed
    // was 16+1 for the escape case.
    
    // Reload only when the register has too few bits for next k, note that in
    // the special case of k = 0, no reload is executed since regN is never LT zero.

#if defined(DEBUG)
    if (reloadLT) {
      assert(reloadAlways == false);
    }
    if (reloadAlways) {
      assert(reloadLT == false);
    }
#endif // DEBUG
    
    if (reloadAlways) {
//#if defined(DEBUG)
//      assert(regN < numRegBits());
//#endif // DEBUG
      
      cachedBits.refill(reg, regN, true);
      
#if defined(DEBUG)
      assert(regN == numRegBits());
#endif // DEBUG
    }
    
    if (reloadLT && (regN < lt)) {
#if defined(DEBUG)
      assert(regN < numRegBits());
#endif // DEBUG
      
      cachedBits.refill(reg, regN);
      
#if defined(DEBUG)
      assert(regN == numRegBits());
#endif // DEBUG
    }

    {
      // The next k bits is REM
      
# if defined(DEBUG)
      assert(regN >= k);
# endif // DEBUG
      
#if defined(DEBUG)
      if (debug) {
        printf("reg      : %s\n", get_code_bits_as_string64(reg, numRegBits()).c_str());
        printf("k        : %d\n", k);
      }
#endif // DEBUG
      
      // Read k REM bits from suffix stream and right align.
      // Note the special case here of k = 0 which results
      // in a right shift by 16 or 32 bits which can be undefined.
      
      //symbol = (reg >> (numRegBits() - k));
      
      symbol = (reg >> (numRegBits() - 8));
      symbol <<= k;
      symbol >>= 8;
      
#if defined(DEBUG)
      if (debug) {
        printf("symbol      : %s\n", get_code_bits_as_string64(symbol, 8).c_str());
      }
#endif // DEBUG
      
      reg <<= k;
      
#if defined(DEBUG)
      if (debug) {
        printf("bits (notK) : %s\n", get_code_bits_as_string64(reg, numRegBits()).c_str());
      }
#endif // DEBUG
      
      regN -= k;
      
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
      totalNumBitsRead += k;
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
    }
    
#if defined(DEBUG)
    if (debug) {
      printf("append decoded suffix symbol = %d\n", symbol);
    }
#endif // DEBUG
    
    return symbol;
  }
};

#endif // rice_decode_blocks_hpp
