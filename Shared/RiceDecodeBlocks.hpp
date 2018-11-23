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

// rice util method that decodes on stream from bit stream

template <typename T>
uint8_t rice_rdb_decode_symbol(
                               CACHEDBIT_THREAD_SPECIFIC T & rdb,
                               const uint8_t k)
{
#if defined(DEBUG)
  const bool debug = false;
#endif // DEBUG

#if defined(DEBUG)
  if (debug) {
    printf("rice_rdb_decode_symbol bits: %s and rdb.regN %d\n", get_code_bits_as_string64(rdb.reg, 16).c_str(), rdb.regN);
  }
#endif // DEBUG

  unsigned int symbol;
  
  if (rdb.regN < 16) {
    rdb.cachedBits.refill(rdb.reg, rdb.regN);
    
#if defined(DEBUG)
    assert(rdb.regN == 16);
#endif // DEBUG
  }
  
  unsigned int q;
  
  if (rdb.reg == 0) {
#if defined(DEBUG)
    assert(rdb.regN == 16);
#endif // DEBUG
    
    rdb.regN = 0;
    
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
    rdb.totalNumBitsRead += 16;
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
    
    // Special case for 16 bits of zeros in high halfword
    q = 0;
    
    // Ignore the 16 zero bits and reload from input stream
    
    rdb.cachedBits.refill(rdb.reg, rdb.regN);
    
#if defined(DEBUG)
    assert(rdb.regN == 16);
#endif // DEBUG
    
#if defined(DEBUG)
    if (debug) {
      printf("bits (del16): %s\n", get_code_bits_as_string64(rdb.reg, 16).c_str());
    }
#endif // DEBUG
    
# if defined(DEBUG)
    assert(rdb.regN >= 8);
# endif // DEBUG
    
    symbol = rdb.reg >> 8;
    
#if defined(DEBUG)
    if (debug) {
      printf("symbol      : %s\n", get_code_bits_as_string64(symbol, 8).c_str());
    }
#endif // DEBUG
    
    rdb.reg <<= 8;
    
#if defined(DEBUG)
    if (debug) {
      printf("bits (del8) : %s\n", get_code_bits_as_string64(rdb.reg, 16).c_str());
    }
#endif // DEBUG
    
# if defined(DEBUG)
    assert(rdb.regN >= 8);
# endif // DEBUG
    
    rdb.regN -= 8;
    
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
    rdb.totalNumBitsRead += 8;
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
  } else {
# if defined(DEBUG)
    assert(rdb.reg != 0);
# endif // DEBUG
    
    // clz impl
    
#if defined(RICEDECODEBLOCKS_METAL_CLZ)
    // clz on 16 bit register in Metal. Metal shading language
    // spec indicates that clz(0) returns 16 in this situation.
    q = clz(rdb.reg);
#else // RICEDECODEBLOCKS_METAL_CLZ
    // clz with 32 bit gcc builtin instruction
    
    uint32_t bits = ((uint32_t) rdb.reg) << 16;
    q = __builtin_clz(bits);
    
# if defined(DEBUG)
    if (debug) {
      printf("rdb.reg : %s\n", get_code_bits_as_string64(rdb.reg, 16).c_str());
      printf("bits    : %s\n", get_code_bits_as_string64(bits, 32).c_str());
    }
# endif // DEBUG
#endif // RICEDECODEBLOCKS_METAL_CLZ
    
    symbol = q << k;
    
#if defined(DEBUG)
    if (debug) {
      printf("q (num leading zeros): %d\n", q);
    }
    if (debug) {
      printf("symbol      : %s\n", get_code_bits_as_string64(symbol, 8).c_str());
    }
# endif // DEBUG
    
    // Shift left to place MSB of remainder at the MSB of register
    rdb.reg <<= (q + 1);
    
#if defined(DEBUG)
    if (debug) {
      printf("lshift   %2d : %s\n", (q + 1), get_code_bits_as_string64(rdb.reg, 16).c_str());
    }
# endif // DEBUG
    
# if defined(DEBUG)
    assert(rdb.regN >= (q + 1));
# endif // DEBUG
    rdb.regN -= (q + 1);
    
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
    rdb.totalNumBitsRead += (q + 1);
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
    
    // Reload so that REM bits will always be available
    
    rdb.cachedBits.refill(rdb.reg, rdb.regN);
    
# if defined(DEBUG)
    assert(rdb.regN >= k);
# endif // DEBUG
    
    // FIXME: shift right could use a mask based on k and a shift based
    // on q to avoid using the result of the earlier left shift
    
    // Shift right to place LSB of remainder at bit offset 0
    uint8_t rem = rdb.reg >> (16 - k);
    
#if defined(DEBUG)
    if (debug) {
      printf("rem         : %s\n", get_code_bits_as_string64(rem, 8).c_str());
    }
# endif // DEBUG
    
    symbol |= rem;
    
#if defined(DEBUG)
    if (debug) {
      printf("symbol      : %s\n", get_code_bits_as_string64(symbol, 8).c_str());
    }
# endif // DEBUG
    
# if defined(DEBUG)
    assert(rdb.regN >= k);
# endif // DEBUG
    rdb.regN -= k;
    // was already shifted left by (q + 1) above, so shift left to consume rem bits
    rdb.reg <<= k;
    
#if defined(DEBUG)
    if (debug) {
      printf("lshift2  %2d : %s\n", k, get_code_bits_as_string64(rdb.reg, 16).c_str());
    }
#endif // DEBUG
    
#if defined(RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL)
    rdb.totalNumBitsRead += k;
#endif // RICEDECODEBLOCKS_NUM_BITS_READ_TOTAL
  }
  
#if defined(DEBUG)
  if (debug) {
    printf("append decoded symbol = %d\n", symbol);
  }
#endif // DEBUG
  
  return symbol;
}

// RiceDecodeBlocks

template <typename T, const bool ALWAYS_REFILL = false>
class RiceDecodeBlocks
{
public:
  
  T cachedBits;
  uint16_t reg;
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
      assert(regN < 16);
#endif // DEBUG
      
      cachedBits.refill(reg, regN);
      
#if defined(DEBUG)
      assert(regN == 16);
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
    if (reg == 0) {
      // __builtin_clz(0) is undefined
      clz = 16 + 16;
    } else {
      clz = __builtin_clz((unsigned int) reg);
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
    if (reg == 0) {
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
    if (shiftNumBits == 16) {
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
};

#endif // rice_decode_blocks_hpp
