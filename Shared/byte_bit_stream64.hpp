//
//  byte_bit_stream64.hpp
//
//  Created by Mo DeJong on 6/3/18.
//  Copyright © 2018 helpurock. All rights reserved.
//
//  Bit stream reading interface for 64 bit at a time
//  reading logic.

#ifndef byte_bit_stream64_hpp
#define byte_bit_stream64_hpp

#include <stdio.h>

#include <cinttypes>
#include <vector>
#include <bitset>

using namespace std;

// Return bits as LSB first

//static inline
//string get_code_bits_as_string64(uint64_t code, const int width)
//{
//    string bitsStr;
//    int c4 = 1;
//    for ( int i = 0; i < width; i++ ) {
//        const uint64_t on64 = 0x1;
//        bool isOn = ((code & (on64 << i)) != 0);
//        if (isOn) {
//            bitsStr = "1" + bitsStr;
//        } else {
//            bitsStr = "0" + bitsStr;
//        }
//        
//        if ((c4 == 4) && (i != (width - 1))) {
//            bitsStr = "-" + bitsStr;
//            c4 = 1;
//        } else {
//            c4++;
//        }
//    }
//    
//    return bitsStr;
//}

// Optimized 64 bit bit read stream, this logic operates directly on a 64 bit
// pointer and reads 64 bits at a time.

class BitReaderStream64
{
public:
    uint64_t *ptr;
    
    BitReaderStream64()
    : ptr(nullptr)
    {
    }
    
    // FIXME: setore both buffer start pointer and length, but
    // length only needs to be checkin in DEBUG mode.
    
    // Store refs to input and output byte bufers
    
    void setupInput(uint64_t * bitBuff)
    {
        ptr = (uint64_t *) bitBuff;
    }
    
    void reset() {
    }
    
    // Read the next byte in the stream
    
    inline
    uint64_t read64() {
        return *ptr++;
    }
};

// Optimized bit reader that operates in terms of
// a pair of 64 bit values. From that point on a
// non-blocking read into the second register
// keeps loading bits without blocking the very
// next call.

template <class BRBS, const int MB>
class BitReader64
{
public:
    uint64_t bits1;
    uint64_t bits2;

    uint64_t numBits1;
    uint64_t numBits2;
    
    BRBS byteReader64;
    
    BitReader64()
    : byteReader64(),
    bits1(0),
    bits2(0),
    numBits1(0),
    numBits2(0)
    {
        // 64 bits required
        
#if defined(DEBUG)
        assert(sizeof(bits1) == 8);
        assert(sizeof(bits2) == 8);
#endif // DEBUG
    }
    
    void reset() {
        byteReader64.reset();
    }
    
    // Refill bit buffer so that 64 bits are pending
    
    inline
    void refillBits() {
        const bool debug = false;
        
        if (debug) {
            printf("refillBits()\n");
            printf("numBits1 %d\n", (int)numBits1);
            printf("numBits2 %d\n", (int)numBits2);
        }
        
        if (numBits1 < (uint64_t)MB) {
# if defined(DEBUG)
            assert(numBits2 == 0 || numBits2 == 32 || numBits2 == 64);
# endif // DEBUG
            
            if (numBits2 == (uint64_t)64) {
                bits1 |= ((bits2 >> 32) << 32) >> numBits1;
                numBits1 += (uint64_t)32;
                bits2 <<= 32;
                numBits2 = (uint64_t)32;
            } else if (numBits2 == (uint64_t)32) {
                bits1 |= bits2 >> numBits1;
                numBits1 += (uint64_t)32;
                // async read into bits2
                bits2 = byteReader64.read64();
                numBits2 = (uint64_t)64;
            } else {
                // numBits2 is zero
                if (numBits1 == (uint64_t)0) {
                    bits1 = byteReader64.read64();
                    bits2 = byteReader64.read64();
                    numBits1 = (uint64_t)64;
                    numBits2 = (uint64_t)64;
                } else {
# if defined(DEBUG)
                    assert(0);
# endif // DEBUG
                }
            }
            
# if defined(DEBUG)
            assert(numBits2 == 0 || numBits2 == 32 || numBits2 == 64);
# endif // DEBUG
            
            if (debug) {
                printf("bits1 : %s : numBits1 %d\n", get_code_bits_as_string64(bits1, 64).c_str(), (int)numBits1);
                printf("bits2 : %s : numBits2 %d\n", get_code_bits_as_string64(bits2, 64).c_str(), (int)numBits2);
            }
        }
        
# if defined(DEBUG)
        assert(numBits1 >= MB);
        
        // Whatever numBits1 is set to, make sure that all the remaining bits
        // after that are set to 0.
        
        for ( uint64_t i = numBits1; i < 64; i++ ) {
            bool bit = (bits1 >> (63 - i)) & 0x1;
            assert(bit == 0);
        }
# endif // DEBUG
        
        if (debug) {
            printf("numBits1 %d\n", (int)numBits1);
            printf("numBits2 %d\n", (int)numBits2);
        }
        
        if (debug) {
            printf("bits1: %s\n", get_code_bits_as_string64(bits1, 64).c_str());
            printf("bits2: %s\n", get_code_bits_as_string64(bits2, 64).c_str());
        }
        
        return;
    }
};

// A stream reader pulls bits from a stream
// in chunks of 64 bits at a time.

template <class BRBS>
class BitReader64ReaderPart
{
public:
    uint64_t bits;
    uint64_t numBits;
    
    BRBS byteReader64;
    
    BitReader64ReaderPart() :
    bits(0),
    numBits(0)
    {
    }

    void initBits() {
        bits = byteReader64.read64();
        numBits = (uint64_t)64;
    }
    
    inline
    void fillBits(uint64_t & fillBits, uint64_t fillNumBits) {
        const bool debug = false;
        
        if (debug) {
            printf("fillBits()\n");
            
            printf("fill bits: %s (num bits %d)\n", get_code_bits_as_string64(fillBits, 64).c_str(), (int)fillNumBits);
            printf("src  bits: %s (num bits %d)\n", get_code_bits_as_string64(bits, 64).c_str(), (int)numBits);
        }
        
#if defined(DEBUG)
        assert(numBits > 0);
#endif // DEBUG
        
        // Note that the caller must implicitly set the number of bits in
        // the fill register to 64 in the caller scope. Like:
        // fillNumBits = 64;
        
        uint64_t numBitsToBeFilled = 64 - fillNumBits;
        
        if (numBitsToBeFilled == numBits) {
            // Exactly the number of bits needed to fill register
            
            if (debug) {
                printf("exactly %d bits needed to fill register\n", (int)numBitsToBeFilled);
            }
            
            fillBits |= (bits >> fillNumBits);
            
            if (debug) {
                printf("or   bits: %s\n", get_code_bits_as_string64(fillBits, 64).c_str());
            }
            
            bits = byteReader64.read64();
            numBits = (uint64_t)64;
        } else if (numBitsToBeFilled < numBits) {
            // More than enough bits to fill the register without another read
            
            if (debug) {
                printf("have %d bits, only needed %d bits (LT)\n", (int)numBits, (int)numBitsToBeFilled);
            }
            
            fillBits |= (bits >> fillNumBits);
            
            if (debug) {
                printf("or   bits: %s (num bits %d)\n", get_code_bits_as_string64(fillBits, 64).c_str(), (int)fillNumBits);
            }
            
            bits <<= numBitsToBeFilled;
            numBits -= numBitsToBeFilled;
            
#if defined(DEBUG)
            assert(numBits > 0);
#endif // DEBUG
        } else {
            // Too few bits to fully fill the register, copy over the existing
            // bits and then load the next 64 bits and finish filling the register
            
            if (debug) {
                printf("have %d bits needed 2 reads to fill %d bits (GT)\n", (int)numBits, (int)numBitsToBeFilled);
            }
            
            fillBits |= (bits >> fillNumBits);
            bits = byteReader64.read64();
            
            if (debug) {
                printf("or1  bits: %s (num bits %d)\n", get_code_bits_as_string64(fillBits, 64).c_str(), (int)fillNumBits);
            }
            
            uint64_t numBitsFill2 = fillNumBits + numBits;
            numBitsToBeFilled -= numBits;
            numBits = (uint64_t)64;
            
            if (debug) {
                printf("src  bits: %s (num bits %d)\n", get_code_bits_as_string64(bits, 64).c_str(), (int)numBits);
            }
            
#if defined(DEBUG)
            assert(numBitsToBeFilled <= numBits);
#endif // DEBUG
            
            fillBits |= (bits >> numBitsFill2);
            
            if (debug) {
                printf("or2  bits: %s (num bits %d)\n", get_code_bits_as_string64(fillBits, 64).c_str(), (int)fillNumBits);
            }
            
            bits <<= numBitsToBeFilled;
            numBits -= numBitsToBeFilled;
        }
        
        if (debug) {
            printf("post bits: %s (num bits %d)\n", get_code_bits_as_string64(bits, 64).c_str(), (int)numBits);
        }
    }
};
    
// This bit stream part contains the actual bits and
// and the number of bits in the register.
// Note that this method does not contain the
// incoming buffer of bits being read from.

template <class BRBS>
class BitReader64StreamPart
{
public:
    uint64_t bits;
    uint64_t numBits;

    // If a bit writer is defined (not nullptr), then write the
    // bits for each refill operation out to the bit writer
    // in refill order.
    
    BitWriter<true,BitWriterByteStream> * bitWriterPtr;
    
    BitReader64StreamPart() :
    bits(0),
    numBits(0),
    bitWriterPtr(nullptr)
    {
        // 64 bits required
        
#if defined(DEBUG)
        assert(sizeof(bits) == 8);
#endif // DEBUG
    }
    
    void reset() {
    }
    
    // To refill the bits for a specific bit stream, read
    // bits from a stream input and exactly fill the number
    // of bits that were consumed.
    
    inline
    void refillBits(BitReader64ReaderPart<BRBS> & rp) {
        if (numBits < 64) {
            rp.fillBits(bits, numBits);
            
            refillCompleted((int)numBits, 64);
            
            // Implicit reset of number of bits in caller scope.
            numBits = 64;
        }
        
# if defined(DEBUG)
        assert(numBits == 64);
# endif // DEBUG
    }
    
    // Each time that the bits register is refilled,
    // this method is invoked to process the state
    // of the filled register. The start and endi
    // indexes indicate the MSB to LSB bit position
    // of the refill range. Note that when no bits
    // were loaded this method is not invoked.
    
    inline
    void refillCompleted(int starti, int endi) {
        const bool debug = false;
        
        if (debug) {
            printf("refillCompleted(%2d, %2d)\n", starti, endi);
            
            printf("bits  : %s\n", get_code_bits_as_string64(bits, 64).c_str());
            
            uint64_t refill = bits << starti;
            
            printf("refill: %s (num bits %d)\n", get_code_bits_as_string64(refill, 64).c_str(), (endi - starti));
        }
        
        // Inclusive grab the bits that were just refilled and write as
        // bits to the writer if one is defined.
        
        if (bitWriterPtr != nullptr) {
            for (int i = starti; i < endi; i++) {
                bool bit = (bits >> (63 - i)) & 0x1;
                
                if (debug && 0) {
                    printf("interleave bit [%2d]: %d\n", (i - starti) , (int)bit);
                }

                bitWriterPtr->writeBit(bit);
            }
        }

        return;
    }
};

// This bit stream part contains the actual bits and
// and the number of bits in the register.
// Note that this method does not contain the
// incoming buffer of bits being read from.

template <class BRBS>
class BitReader64StreamPartNoWriter
{
public:
    uint64_t bits;
    uint64_t numBits;
    
    BitReader64StreamPartNoWriter() :
    bits(0),
    numBits(0)
    {
        // 64 bits required
        
#if defined(DEBUG)
        assert(sizeof(bits) == 8);
#endif // DEBUG
    }
    
    void reset() {
    }
    
    // To refill the bits for a specific bit stream, read
    // bits from a stream input and exactly fill the number
    // of bits that were consumed.
    
    inline
    void refillBits(BitReader64ReaderPart<BRBS> & rp) {
        if (numBits < 64) {
            rp.fillBits(bits, numBits);
            
            //refillCompleted((int)numBits, 64);
            
            // Implicit reset of number of bits in caller scope.
            numBits = 64;
        }
        
# if defined(DEBUG)
        assert(numBits == 64);
# endif // DEBUG
    }
    
    // Each time that the bits register is refilled,
    // this method is invoked to process the state
    // of the filled register. The start and endi
    // indexes indicate the MSB to LSB bit position
    // of the refill range. Note that when no bits
    // were loaded this method is not invoked.
    
    /*
    inline
    void refillCompleted(int starti, int endi) {
        const bool debug = false;
        
        if (debug) {
            printf("refillCompleted(%2d, %2d)\n", starti, endi);
            
            printf("bits  : %s\n", get_code_bits_as_string64(bits, 64).c_str());
            
            uint64_t refill = bits << starti;
            
            printf("refill: %s (num bits %d)\n", get_code_bits_as_string64(refill, 64).c_str(), (endi - starti));
        }
        
        // Inclusive grab the bits that were just refilled and write as
        // bits to the writer if one is defined.
        
        if (bitWriterPtr != nullptr) {
            for (int i = starti; i < endi; i++) {
                bool bit = (bits >> (63 - i)) & 0x1;
                
                if (debug && 0) {
                    printf("interleave bit [%2d]: %d\n", (i - starti) , (int)bit);
                }
                
                bitWriterPtr->writeBit(bit);
            }
        }
        
        return;
    }
     */
};

// Multiplexer reader extends BitReaderStream64 and operates in the same
// way except that each call to read64() writes to a shared output vector
// that interleaves dword values.

class BitReaderByteStreamMultiplexer64 : public BitReaderStream64
{
public:
    // Each byte read from a compressed stream generates
    // a byte write to a multiplexed output stream.
    
    vector<uint64_t> * multiplexVecPtr;
    
    BitReaderByteStreamMultiplexer64()
    : multiplexVecPtr(nullptr)
    {
    }
    
    void setMultiplexVecPtr(vector<uint64_t> * outMultiplexVecPtr) {
        this->multiplexVecPtr = outMultiplexVecPtr;
    }
    
    // Read the next byte in the stream
    
    uint64_t read64() {
        uint64_t val = BitReaderStream64::read64();
        
        multiplexVecPtr->push_back(val);
        
        return val;
    }
};

// A bit stream represented by a series of 64 bit chunks.
// A single call to readBits(n) can read at most 64 bits
// from the stream at one time. Each time the stream of
// bits is read, the offset and bitOffset inside the
// 64 bit chunk is updated.

class BitStream64
{
public:
    vector<uint64_t> bytes;
    int offset;
    int bitOffset;
    
    BitStream64():
    offset(0),
    bitOffset(0)
    {
    }
    
    // Fill the bit stream with N bits read from a uint8_t
    // pointer where maxNumBits indicates the total number
    // of bits in the buffer.
    
    void fillFrom(uint8_t *ptr, int numBytes, int totalNumBits) {
        bytes.clear();
        
        int blocks64 = totalNumBits / 64;
        if ((totalNumBits % 64) != 0) {
            blocks64 += 1;
        }
        
        bytes.reserve(blocks64);
        
        int byteChunks64 = numBytes / sizeof(uint64_t);
        
        uint64_t val;
        
        for (int i = 0; i < byteChunks64; i++) {
            // Fill in 64 bit buffer
            memcpy((void*)&val, &ptr[i*sizeof(uint64_t)], sizeof(uint64_t));
            bytes.push_back(val);
        }
        
        // Copy remaining bytes with zero filled 64 bit value
        
        
    }

    // Return the number of bits read from the stream
    
    int numBitsRead() {
        return (offset * 64) + bitOffset;
    }
    
    // Grab a number of bits from the stream, max of 64.
    // Note that it is possible to grab zero bits since
    // the bit buffer to store into might already be full.
    
    uint64_t readBits(int numBits) {
        assert(numBits >= 0 && numBits <= 64);
        
        // Collect the next N bits from this input stream. This
        // is complicated by the implicit size of either 8 bits or 64
        // for elements that contain the bits. Does it make sense to
        // convert this to a vector of bits (very large) so that the
        // reading logic is simplified. Or is that just way too slow?
        
        int numBitsAtCurrentOffset = (64 - bitOffset);
        
        if (numBits <= numBitsAtCurrentOffset) {
            // Enough bits at this offset
            
            uint64_t bits1 = bytes[offset];
            bits1 >>= bitOffset;
            
            if (numBits == numBitsAtCurrentOffset) {
                offset += 1;
            }
            
            uint64_t mask = ~(~((uint64_t)0) << numBits);
            return bits1 & mask;
        } else {
            // Collect remaining bits at this offset and combine with
            // rest of bits from the next offset.
            
            int numBits1 = numBitsAtCurrentOffset;
            int numBits2 = numBits - numBits1;
            
            uint64_t bits1 = bytes[offset++];
            bits1 >>= bitOffset;
            
            uint64_t bits2 = bytes[offset];
            
            bits1 |= (bits2 << numBits1);
            
            uint64_t mask = ~(~((uint64_t)0) << numBits);
            
            return bits1 & mask;
        }
    }
};

// FIXME: Look at exact bit stream encoding and decoding so that the exact number of bits
// needed for N streams can be encoded in a way that can then be parsed out exactly
// by the reader without needing to know anything about pending bits. This logic
// would need to track the number of bits used in each 64 bit register being read.



// A bit stream represented by a collection of bytes

class BitStream
{
public:
    vector<uint8_t> bytes;
    
    // Grab a number of bits from the stream, max of 64.
    // Note that it is possible to grab zero bits since
    // the bit buffer to store into might already be full.
    
    uint64_t grabBits(int numBits) {
        assert(numBits >= 0 && numBits <= 64);
        
        // Collect the next N bits from this input stream. This
        // is complicated by the implicit size of either 8 bits or 64
        // for elements that contain the bits. Does it make sense to
        // convert this to a vector of bits (very large) so that the
        // reading logic is simplified. Or is that just way too slow?
        
        return 0;
    }
};

// A class that contains N streams of bits, an instance of bit stream container
// is passed into a method that removes bits from a numbered stream in order to
// fill buffers as needed.

class NBitStreams
{
public:
    vector<BitStream> streams;
    
    uint64_t grabBits(int streami, int numBits) {
        return streams[streami].grabBits(numBits);
    }
};

#endif // byte_bit_stream64_hpp
