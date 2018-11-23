//
//  byte_bit_stream.hpp
//
//  Created by Mo DeJong on 6/3/18.
//  Copyright © 2018 helpurock. All rights reserved.
//
//  This module provides general purpose C++ implementations
//  of writing to and reading from bit and byte streams.
//  For example, one can emit a series of bits as bytes
//  and then read bits back from a stream of bytes.

#ifndef byte_bit_stream_hpp
#define byte_bit_stream_hpp

#include <stdio.h>

#include <cinttypes>
#include <vector>
#include <bitset>

using namespace std;

// Return bits as LSB first

static inline
string get_code_bits_as_string64(uint64_t code, const int width)
{
    string bitsStr;
    int c4 = 1;
    for ( int i = 0; i < width; i++ ) {
        const uint64_t on64 = 0x1;
        bool isOn = ((code & (on64 << i)) != 0);
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

// Read one bit at a time from a stream of bytes

class BitReaderByteStream
{
public:
    uint8_t *bytePtr;
    unsigned int byteOffset;
    unsigned int byteLength;
    
    BitReaderByteStream()
    :bytePtr(nullptr),
    byteOffset(0),
    byteLength(0)
    {
    }
    
    // Store refs to input and output byte bufers
    
    void setupInput(const uint8_t * bitBuff, const int bitBuffN)
    {
        bytePtr = (uint8_t *) bitBuff;
        byteOffset = 0;
        byteLength = bitBuffN;
    }
    
    // The next two methods must be implemented to satisfy
    // a byte stream reading interface.
    
    void reset() {
        byteOffset = 0;
    }
    
    // Read the next byte in the stream
    
    inline
    uint8_t readByte() {
#if defined(DEBUG)
        assert(byteOffset < byteLength);
#endif // DEBUG
        return bytePtr[byteOffset++];
    }
};

// General purpose byte to bit reading logic, a byte
// array is iterated over until N values have been
// read. The MSB argument indicates if bits are returned
// from the least significant or most significant bit first.
// This object reads and writes bits to a specific uint32_t
// pointer in memory, the actual bits can be stored in another
// object or in an array of memory.
// The MB arguments indicates the min number of bits that can
// still be left in the buffer without a refill.

template <const bool MSB, class BRBS, const int MB>
class BitReader
{
public:
    BRBS byteReader;
    
    uint32_t *bitsPtr;
    unsigned int bitsInRegister;
    
    BitReader()
    : byteReader(),
    bitsPtr(nullptr),
    bitsInRegister(0)
    {
        // 32 bits required
        
#if defined(DEBUG)
        assert(sizeof(*bitsPtr) == 4);
#endif // DEBUG
    }
    
    void reset() {
        byteReader.reset();
    }
    
    void setBitsPtr(uint32_t *inOutBitsPtr) {
        *inOutBitsPtr = 0;
        bitsPtr = inOutBitsPtr;
        this->bitsInRegister = 0;
    }
    
    // Refill so that there are at least 24 pending bits
    
    inline
    void refillBits() {
        const bool debug = false;
        
        if (debug) {
            printf("refillBits() bitsInRegister %d\n", bitsInRegister);
        }
        
        // Shift bits into register so that LSB is at the lowest
        // unused position.
        
        const int minBits = MB;
        
        if (bitsInRegister <= minBits) {
            uint32_t bits = *bitsPtr;
            
            do {
                uint32_t byteVal = byteReader.readByte();
                
                // Move msb input bits to top of 32 bit register
                bits |= (byteVal << ((32 - 8) - bitsInRegister));
                bitsInRegister += 8;
                
                if (debug) {
                    printf("refill  bits: %s\n", get_code_bits_as_string64(bits, 32).c_str());
                }
            } while (bitsInRegister <= minBits);
            
            *bitsPtr = bits;
        }
        
#if defined(DEBUG)
        assert(bitsInRegister >= MB);
        assert(bitsInRegister <= 32);
#endif // DEBUG
        
        if (debug) {
            printf("refillBits() bitsInRegister refilled to %d\n", bitsInRegister);
        }
        
        if (debug) {
            printf("pending bits: %s\n", get_code_bits_as_string64(*bitsPtr, 32).c_str());
        }
        
        return;
    }
};

// Write bytes to a vector of bytes in memory

class BitWriterByteStream
{
public:
    vector<uint8_t> bytes;
    
    BitWriterByteStream() {
        bytes.reserve(1024);
    }
    
    void reset() {
        bytes.clear();
    }
    
    void writeByte(uint8_t bVal) {
        bytes.push_back(bVal);
    }
};

// General purpose bit to byte writer, once 8 bits have been emitted
// then write a full byte to the output vector. This writer instance
// does not know the length of emitted bytes ahead of time.

template <const bool MSB, class BWBS>
class BitWriter
{
public:
    BWBS byteWriter;
    
    bitset<8> bits;
    unsigned int bitOffset;
    unsigned int numEncodedBits;
    
    BitWriter() {
        reset();
    }
    
    void reset() {
        byteWriter.reset();
        bits.reset();
        bitOffset = 0;
        numEncodedBits = 0;
    }
    
    void flushByte() {
        const bool debug = false;
        
        uint8_t byteVal = 0;
        
        // Flush 8 bits to backing array of bytes.
        // Note that bits can be written as either
        // LSB first (reversed) or MSB first (not reversed).
        
        if (MSB) {
            for ( int i = 0; i < 8; i++ ) {
                unsigned int v = (bits.test(i) ? 0x1 : 0x0);
                byteVal |= (v << (7 - i));
            }
        } else {
            for ( int i = 0; i < 8; i++ ) {
                unsigned int v = (bits.test(i) ? 0x1 : 0x0);
                byteVal |= (v << i);
            }
        }
        
        bits.reset();
        bitOffset = 0;
        byteWriter.writeByte(byteVal);
        
        if (debug) {
            printf("emit byte 0x%02X aka %s\n", byteVal, get_code_bits_as_string64(byteVal, 8).c_str());
        }
    }
    
    void writeBit(bool bit) {
        bits.set(bitOffset++, bit);
        numEncodedBits += 1;
        
        if (bitOffset == 8) {
            flushByte();
        }
    }
    
    // Write a byte that contains all off bits, useful for padding
    
    void writeZeroByte() {
#if defined(DEBUG)
        assert(bitOffset == 0);
#endif // DEBUG
        byteWriter.writeByte(0);
    }
    
    // Move output bytes object into caller scope
    
    vector<uint8_t> moveBytes() {
        return std::move(byteWriter.bytes);
    }
};

// This bit reader implementation will multiplex bytes as
// they are decoded from N already encoded rice streams.

class BitReaderByteStreamMultiplexer : public BitReaderByteStream
{
public:
    // Each byte read from a compressed stream generates
    // a byte write to a multiplexed output stream.
    
    vector<uint8_t> * bytesPtr;
    
    BitReaderByteStreamMultiplexer()
    {
    }
    
    void setBytesPtr(vector<uint8_t> * inBytesPtr) {
        this->bytesPtr = inBytesPtr;
    }
    
    // Read the next byte in the stream
    
    uint8_t readByte() {
        uint8_t bVal = BitReaderByteStream::readByte();
        
        bytesPtr->push_back(bVal);
        
        return bVal;
    }
};

// Each decoder stream that will read values from
// a multiplexed stream will use an instance of
// this class to read bytes for N different streams
// in "as needed" order. A single BitReaderByteStream
// is shared between all demultiplexer instances
// via the bit reader ptr. Each byte read is passed
// through to the BitReaderByteStream instance.

class BitReaderByteStreamDemultiplexer
{
public:
    // Ref to BitReaderByteStream object shared
    // between N BitReaderByteStreamDemultiplexer
    // instances.
    
    BitReaderByteStream * bitReaderPtr;
    
    BitReaderByteStreamDemultiplexer()
    {
    }
    
    // Nop this method for Demultiplexer impl
    
    void setupInput(const uint8_t * bitBuff, const int bitBuffN)
    {
    }
    
    void setBitReaderPtr(BitReaderByteStream * inBitReaderPtr) {
        this->bitReaderPtr = inBitReaderPtr;
    }
    
    // The next two methods must be implemented to satisfy
    // a byte stream reading interface.
    
    void reset() {
        // Nop
    }
    
    // Read the next byte in the stream
    
    uint8_t readByte() const {
        return bitReaderPtr->readByte();
    }
};

#endif // byte_bit_stream_h
