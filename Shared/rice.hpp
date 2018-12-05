//
//  rice.hpp
//
//  Created by Mo DeJong on 6/3/18.
//  Copyright © 2018 helpurock. All rights reserved.
//
//  The rice coder provides a fast and simple method of encoding
//  prediction residuals as variable length binary codes.

#ifndef rice_hpp
#define rice_hpp

#if defined(DEBUG)
#include <unordered_map>
#endif // DEBUG

#include "byte_bit_stream.hpp"
#include "rice_util.hpp"

using namespace std;

class RiceEncoder
{
public:
    bitset<8> bits;
    unsigned int bitOffset;
    vector<uint8_t> bytes;
    unsigned int numEncodedBits;
    
    // If true, then most significant bit ordering, defaults to lsb first
    bool msb;

    // unary repeating boolean value, defaults to true
    bool unary1;
    bool unary2;
    
    RiceEncoder()
    : bitOffset(0), numEncodedBits(0), msb(false), unary1(true), unary2(false) {
        bytes.reserve(1024);
    }
    
    void reset() {
        bits.reset();
        bitOffset = 0;
        bytes.clear();
        numEncodedBits = 0;
    }
    
    void flushByte() {
        const bool debug = false;
        
        uint8_t byteVal = 0;
        
        // Flush 8 bits to backing array of bytes.
        // Note that bits can be written as either
        // LSB first (reversed) or MSB first (not reversed).
        
        if (msb) {
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
        bytes.push_back(byteVal);
        
        if (debug) {
            printf("emit byte 0x%02X aka %s\n", byteVal, get_code_bits_as_string64(byteVal, 8).c_str());
        }
    }
    
    void encodeBit(bool bit) {
        bits.set(bitOffset++, bit);
        
        if (bitOffset == 8) {
            numEncodedBits += 8;
            flushByte();
        }
    }
    
    // If any bits still need to be emitted, emit final byte.
    
    void finish() {
        if (bitOffset > 0) {
            // Flush 1-8 bits to some external output.
            // Note that all remaining bits must
            // be flushed as true so that multiple
            // symbols are not encoded at the end
            // of the buffer.
            
            numEncodedBits += bitOffset;
            
            while (bitOffset < 8) {
                // Emit bit that is consumed by the decoder
                // until the end of the input stream.
                bits.set(bitOffset++, unary1);
            }
            
            flushByte();
        }
    }
    
    // Rice encode a byte symbol n with an encoding 2^k
    // where k=0 uses 1 bit for the value zero.
    
    void encode(uint8_t n, const unsigned int k)
    {
        const bool debug = false;
        
#if defined(DEBUG)
        // In DEBUG mode, bits contains bits for this specific symbol.
        vector<bool> bitsThisSymbol;
        vector<bool> prefixBitsThisSymbol;
        vector<bool> suffixBitsThisSymbol;
        assert(unary1 != unary2);
#endif // DEBUG
        
        const unsigned int m = (1 << k); // 2^k
        const unsigned int q = pot_div_k(n, m);
        
        if (debug) {
            printf("n %3d : k %3d : m %3d : q = n / m = %d\n", n, k, m, q);
        }
        
        for (int i = 0; i < q; i++) {
          encodeBit(unary1); // defaults to true
#if defined(DEBUG)
          if (debug) {
          prefixBitsThisSymbol.push_back(unary1);
          bitsThisSymbol.push_back(unary1);
          }
#endif // DEBUG
        }
        
        encodeBit(unary2); // defaults to false
#if defined(DEBUG)
        if (debug) {
        prefixBitsThisSymbol.push_back(unary2);
        bitsThisSymbol.push_back(unary2);
        }
#endif // DEBUG
        
        for (int i = k - 1; i >= 0; i--) {
          bool bit = (((n >> i) & 0x1) != 0);
          encodeBit(bit);
#if defined(DEBUG)
          if (debug) {
          suffixBitsThisSymbol.push_back(bit);
          bitsThisSymbol.push_back(bit);
          }
#endif // DEBUG
        }
        
        if (debug) {
#if defined(DEBUG)
            // Print bits that were emitted for this symbol,
            // note the order from least to most significant
            printf("bits for symbol (least -> most): ");
            
            for ( bool bit : bitsThisSymbol ) {
                printf("%d", bit ? 1 : 0);
            }
            printf("\n");
            
            printf("prefix bits for symbol (least -> most): ");
            
            for ( bool bit : prefixBitsThisSymbol ) {
                printf("%d", bit ? 1 : 0);
            }
            printf(" (%d)\n", (int)prefixBitsThisSymbol.size());

            printf("suffix bits for symbol (least -> most): ");
            
            for ( bool bit : suffixBitsThisSymbol ) {
                printf("%d", bit ? 1 : 0);
            }
            printf(" (%d)\n", (int)suffixBitsThisSymbol.size());
#endif // DEBUG
        }
        
        return;
    }
    
    // Encode N symbols and emit any leftover bits
    
    void encode(const uint8_t * byteVals, int numByteVals, const unsigned int k) {
        const bool debug = false;
        for (int i = 0; i < numByteVals; i++) {
            if (debug) {
                printf("symboli %5d\n", i);
            }
            uint8_t byteVal = byteVals[i];
            encode(byteVal, k);
        }
        finish();
    }

    // Pass k lookup table that has an entry for each byte
    
    void encode(const uint8_t * byteVals, int numByteVals, const uint8_t * kLookupTable) {
        const bool debug = false;
        for (int i = 0; i < numByteVals; i++) {
            uint8_t byteVal = byteVals[i];
            uint8_t k = kLookupTable[i];
            if (debug) {
                printf("symboli %5d : blocki %5d : k %2d\n", i, i, k);
            }
            encode(byteVal, k);
        }
        finish();
    }
    
    // Special case encoding method where an already calculated table
    // of K encoding length values has been calculated for each symbol
    // in the input. This encoding method can interleave bits encoded
    // with different K value, it is typically used with a block by
    // block encoding where the resulting outout should emit bits back
    // to back and the decoder can lookup the k value for each pixel.
    
    void encode(const uint8_t * byteVals, int numByteVals, const uint8_t * kLookupTable, const int kLookupEvery) {
        const bool debug = false;
        for (int i = 0; i < numByteVals; i++) {
            uint8_t byteVal = byteVals[i];
            uint8_t k = kLookupTable[i/kLookupEvery];
            if (debug) {
                printf("symboli %5d : blocki %5d : k %2d\n", i, i/kLookupEvery, k);
            }
            encode(byteVal, k);
        }
        finish();
    }
  
    // Special case encoding method where the k value for a block of values is lookup
    // up in tables. Pass count table which indicates how many blocks the corresponding
    // n table entry corresponds to.
    
    void encode(const uint8_t * byteVals, int numByteVals,
                const uint8_t * kLookupTable,
                int kLookupTableLength,
                const vector<uint32_t> & countTable,
                const vector<uint32_t> & nTable)
    {
        const bool debug = false;
        
        assert(countTable.size() == nTable.size());
        
        int symboli = 0;
        int blocki = 0;
        
        const int tableMax = (int) countTable.size();
        for (int tablei = 0; tablei < tableMax; tablei++) {
            // count indicates how many symbols are covered by block k
            
            int numBlockCount = countTable[tablei];
            int numSymbolsPerBlock = nTable[tablei];
            
            assert(numBlockCount > 0);
            assert(numSymbolsPerBlock > 0);
            
            // The same number of symbols are used for numBlockCount blocks.
            
            int maxBlocki = blocki + numBlockCount;
            
            if (debug) {
                printf("blocki range (%d, %d) numSymbolsPerBlock %d\n", blocki, maxBlocki, numSymbolsPerBlock);
            }
            
            for ( ; blocki < maxBlocki; blocki++ ) {
                int k = kLookupTable[blocki];
                
                int maxSymboli = symboli + numSymbolsPerBlock;
                
                if (debug) {
                    printf("symboli range (%d, %d) k %d\n", symboli, maxSymboli, k);
                }
            
                for ( ; symboli < maxSymboli; symboli++) {
                    uint8_t byteVal = byteVals[symboli];
                    if (debug && 0) {
                        printf("symboli %5d : blocki %5d : k %2d\n", symboli, blocki, k);
                    }
                    encode(byteVal, k);
                }
            }
        }
        
        assert(symboli == numByteVals);
        assert(blocki == (kLookupTableLength-1));
        
        finish();
    }

    // Query number of bits needed to store symbol
    // with the given k parameter. Note that this
    // size query logic does not need to actually copy
    // encoded bytes so it is much faster than encoding.
    
    int numBits(unsigned char n, const unsigned int k) {
        const unsigned int q = pot_div_k(n, k);
        return q + 1 + k;
    }
    
    // Query the number of bits needed to store these symbols
    
    int numBits(const uint8_t * byteVals, int numByteVals, const unsigned int k) {
        int totalNumBits = 0;
        for (int i = 0; i < numByteVals; i++) {
            uint8_t byteVal = byteVals[i];
            totalNumBits += numBits(byteVal, k);
        }
        return totalNumBits;
    }

    // Query the number of bits needed to store these symbols
  
    int numBits(const uint8_t * byteVals, int numByteVals, const uint8_t * kLookupTable, const int kLookupEvery) {
        int totalNumBits = 0;
        for (int i = 0; i < numByteVals; i++) {
            uint8_t byteVal = byteVals[i];
            uint8_t k = kLookupTable[i/kLookupEvery];
            totalNumBits += numBits(byteVal, k);
        }
        return totalNumBits;
    }

};

class RiceDecoder
{
public:
    bitset<8> bits;
    unsigned int bitOffset;
    vector<uint8_t> bytes;
    unsigned int byteOffset;
    unsigned int numDecodedBits;
    bool isFinishedReading;
    
    // If true, then most significant bit ordering, defaults to lsb first
    bool msb;
    
    RiceDecoder()
    :msb(false)
    {
        reset();
    }
    
    void reset() {
        numDecodedBits = 0;
        byteOffset = 0;
        bits.reset();
        bitOffset = 8;
        isFinishedReading = false;
        // msb not set here, it must be set after constructor
        //msb = false;
    }
    
    void finish() {
    }
    
    bool decodeBit() {
        const bool debug = false;
        
        if (debug) {
            printf("decodeBit() bitOffset %d\n", bitOffset);
        }
        
        if (bitOffset == 8) {
            if (byteOffset == bytes.size()) {
                // All bytes read and all bits read
                isFinishedReading = true;
                return false;
            }
            
            bits.reset();
            
            uint8_t byteVal = bytes[byteOffset++];
            
            if (debug) {
                printf("decodeBit() loading new bitset from byte 0x%02X\n", byteVal);
            }
            
            if (msb) {
                // Load MSB first
                
                for ( int i = 0; i < 8; i++ ) {
                    bool bit = ((byteVal >> (7 - i)) & 0x1) ? true : false;
                    bits.set(i, bit);
                }
            } else {
                // Load with LSB at bit position 0
                
                for ( int i = 0; i < 8; i++ ) {
                    bool bit = ((byteVal >> i) & 0x1) ? true : false;
                    bits.set(i, bit);
                }
            }
            
            bitOffset = 0;
        }
        
        if (debug) {
            vector<bool> vecOfBool;

            for ( int i = bitOffset; i < 8; i++ ) {
                bool bit = bits.test(i);
                vecOfBool.push_back(bit);
            }
            
            printf("pending bits: ");
            
            for ( bool bit : vecOfBool ) {
                vecOfBool.push_back(bit);
                printf("%d", bit);
            }
            printf("\n");
        }
        
        bool bit = bits.test(bitOffset++);
        
        if (debug) {
            printf("decodeBit() returning %d\n", bit);
        }
        
        return bit;
    }
    
    // Copy input bytes to the input buffer
    
    void copyInputBytes(const uint8_t * byteVals, const int numBytes) {
#if defined(DEBUG)
        assert(numBytes > 0);
#endif // DEBUG
        bytes.resize(numBytes);
        memcpy(bytes.data(), byteVals, numBytes);
    }
    
    // Decode N symbols from the input stream and write decoded symbols
    // to the output vector. Returns the number of symbols decoded.
    
    virtual
    int decodeSymbols(const unsigned int k, const int nsymbols, vector<uint8_t> & decodedBytes) {
        const bool debug = false;
        
        if (debug) {
            printf("k = %d\n", k);
        }
        
        const unsigned int m = (1 << k);
        
        int symboli = 0;
        
        for ( ; symboli < nsymbols ; symboli++ ) {
            unsigned int symbol;
            unsigned int q = 0;
            
            while (decodeBit()) {
                q++;
            }
            symbol = m * q;
            
            if (debug) {
                printf("symbol : m * q : %d * %d : %d\n", m, q, symbol);
            }
            
            for ( int i = k - 1; i >= 0; i-- ) {
                bool b = decodeBit();
                symbol |= ((b ? 1 : 0) << i);
            }
            
            if (isFinishedReading) {
                break;
            }
            
            if (debug) {
                printf("append decoded symbol = %d\n", symbol);
            }
            
            decodedBytes.push_back(symbol);
            numDecodedBits += (q + 1 + k);
        }
        
        return symboli;
    }
    
    // Decode symbols from a buffer of encoded bytes and
    // return the results as a vector of decoded bytes.
    // This method assumes that the k value is known.
    
    vector<uint8_t> decode(const uint8_t * byteVals, const int numBytes, const unsigned int k) {
        reset();
        
        const bool debug = false;
        
        copyInputBytes(byteVals, numBytes);
        
        vector<uint8_t> decodedBytes;
        
        if (debug) {
            printf("k = %d\n", k);
        }
        
        int nsymbols = INT_MAX;
        
        decodeSymbols(k, nsymbols, decodedBytes);
        
        /*
        const unsigned int m = (1 << k);
        
        for ( ; 1 ; ) {
            unsigned int symbol;
            unsigned int q = 0;
            
            while (decodeBit()) {
                q++;
            }
            symbol = m * q;
            
            if (debug) {
                printf("symbol : m * q : %d * %d : %d\n", m, q, symbol);
            }
            
            for ( int i = k - 1; i >= 0; i-- ) {
                bool b = decodeBit();
                symbol |= ((b ? 1 : 0) << i);
            }
            
            if (isFinishedReading) {
                break;
            }
            
            if (debug) {
                printf("append decoded symbol = %d\n", symbol);
            }
            
            decodedBytes.push_back(symbol);
            numDecodedBits += (q + 1 + k);
        }
         */
        
        return decodedBytes;
    }
    
    /*
    
    // Decode symbols from a buffer of encoded bytes and
    // return the results as a vector of decoded bytes.
    // This method assumes that the k value is known.
    
    vector<uint8_t> decode(const uint8_t * byteVals, const int numBytes, const uint8_t * kLookupTable, const int numBlocks, const unsigned int kLookupEvery) {
        reset();
        
        const bool debug = false;
        
        vector<uint8_t> decodedBytes;
        
        assert(numBytes > 0);
        bytes.resize(numBytes);
        memcpy(bytes.data(), byteVals, numBytes);
        
        int symboli = 0;
        
        int lookupCountdown = kLookupEvery;

        for ( ; 1 ; symboli++ ) {
            unsigned int symbol;
            unsigned int q = 0;
            
            // FIXME: non-optimal. Need to look block by block with constant k for each
            // element in the block.
            
            unsigned int k;
            
            if (lookupCountdown == kLookupEvery) {
                k = kLookupTable[numBlocks];
            } else {
                k = kLookupTable[symboli/kLookupEvery];
            }
            
            lookupCountdown -= 1;
            if (lookupCountdown == 0) {
              lookupCountdown = kLookupEvery;
            }
            
            const unsigned int m = (1 << k);
            
            while (decodeBit()) {
                q++;
            }
            symbol = m * q;
            
            if (debug) {
                printf("symbol : m * q : %d * %d : %d (k = %d)\n", m, q, symbol, k);
            }
            
            for ( int i = k - 1; i >= 0; i-- ) {
                bool b = decodeBit();
                symbol |= ((b ? 1 : 0) << i);
            }

            if (isFinishedReading) {
                break;
            }
            
            if (debug) {
                printf("append decoded symbol = %d\n", symbol);
            }
            
            decodedBytes.push_back(symbol);
            numDecodedBits += (q + 1 + k);
        }
        
        return decodedBytes;
    }
     
     */

    /*
    
    // If the K value differs from one symbol to the next, use this form which makes it possible
    // to lookup the K value for every offset via a K table.
    
    vector<uint8_t> decode(const uint8_t * byteVals, const int numBytes, const uint8_t * kLookupTable) {
        reset();
        
        const bool debug = false;
        
        copyInputBytes(byteVals, numBytes);
        
        vector<uint8_t> decodedBytes;
        
        int symboli = 0;
        
        for ( ; 1 ; symboli++ ) {
            unsigned int symbol;
            unsigned int q = 0;
            
            // FIXME: non-optimal. Need to look block by block with constant k for each
            // element in the block.
            
            const unsigned int k = kLookupTable[symboli];
            const unsigned int m = (1 << k);
            
            while (decodeBit()) {
                q++;
            }
            symbol = m * q;
            
            if (debug) {
                printf("symbol : m * q : %d * %d : %d (k = %d)\n", m, q, symbol, k);
            }
            
            for ( int i = k - 1; i >= 0; i-- ) {
                bool b = decodeBit();
                symbol |= ((b ? 1 : 0) << i);
            }
            
            if (isFinishedReading) {
                break;
            }
            
            if (debug) {
                printf("append decoded symbol = %d\n", symbol);
            }
            
            decodedBytes.push_back(symbol);
            numDecodedBits += (q + 1 + k);
        }
        
        return decodedBytes;
    }
     
    */
    
    /*
    void decode(const uint8_t * byteVals, int numByteVals, const uint8_t * kLookupTable, const int kLookupEvery) {
        for (int i = 0; i < numByteVals; i++) {
            uint8_t byteVal = byteVals[i];
            uint8_t k = kLookupTable[i/kLookupEvery];
            decode(byteVal, numByteVals, k);
        }
    }
     */
    
    /*
    
    // This version of decode accepts a lookup table that is the same dimension
    // as byteVals which means k is looked up for every value.
    
    void decode(const uint8_t * byteVals, int numByteVals, const uint8_t * kLookupTable) {
        for (int i = 0; i < numByteVals; i++) {
            uint8_t byteVal = byteVals[i];
            uint8_t k = kLookupTable[i];
            decode(byteVal, numByteVals, k);
        }
    }
     
     */
    
    // Special case decoding method where the k value for a block of values is lookup
    // up in tables. Pass count table which indicates how many blocks the corresponding
    // n table entry corresponds to.
    
    vector<uint8_t> decode(const uint8_t * bitBuff, int bitBuffN,
                const uint8_t * kLookupTable,
                int kLookupTableLength,
                const vector<uint32_t> & countTable,
                const vector<uint32_t> & nTable)
    {
        const bool debug = false;
        
        reset();
        
#if defined(DEBUG)
        assert(countTable.size() == nTable.size());
#endif // DEBUG
        
        copyInputBytes(bitBuff, bitBuffN);
        
        // FIXME: decode into known buffer of fixed size or loop over
        // table entries once to allocate before push_back() calls.
        vector<uint8_t> decodedBytes;
        
        int symboli = 0;
        int blocki = 0;
        
        const int tableMax = (int) countTable.size();
        for (int tablei = 0; tablei < tableMax; tablei++) {
            // count indicates how many symbols are covered by block k
            
            int numBlockCount = countTable[tablei];
            int numSymbolsPerBlock = nTable[tablei];
            
            assert(numBlockCount > 0);
            assert(numSymbolsPerBlock > 0);
            
            // The same number of symbols are used for numBlockCount blocks.
            
            int maxBlocki = blocki + numBlockCount;
            
            if (debug) {
                printf("blocki range (%d, %d) numSymbolsPerBlock %d\n", blocki, maxBlocki, numSymbolsPerBlock);
            }
            
            for ( ; blocki < maxBlocki; blocki++ ) {
                int k = kLookupTable[blocki];
                
                int maxSymboli = symboli + numSymbolsPerBlock;
                
                if (debug) {
                    printf("symboli range (%d, %d) k %d\n", symboli, maxSymboli, k);
                }
                
                int numSymbolsDecoded = decodeSymbols(k, numSymbolsPerBlock, decodedBytes);
                
#if defined(DEBUG)
                assert(numSymbolsDecoded == numSymbolsPerBlock);
#endif // DEBUG
                
                symboli += numSymbolsDecoded;
            }
        }
        
        assert(blocki == (kLookupTableLength-1));
        
        finish();
        
        return decodedBytes;
    }
};

// Store prefix, optional 8 bit escape, otherwise a rem of size k into one buffer.

template <const bool U1, const bool U2, class BWBS>
class RiceSplit16Encoder
{
public:
    // Emit MSB bit order
    BitWriter<true, BWBS> bitWriter;
    
    // Defaults to emitting a word of zeros after
    // the final full byte was emitted.

    bool writeZeroPadding;
    
    RiceSplit16Encoder() :writeZeroPadding(true) {
    }
    
    void reset() {
        bitWriter.reset();
    }
    
    // If any bits still need to be emitted, emit final byte.
    
    void finish() {
        // Do not adjust numEncodedBits
        
        unsigned int savedNumEncodedBits = bitWriter.numEncodedBits;
        
        if (bitWriter.bitOffset > 0) {
            // Flush 1-8 bits to some external output.
            // Note that all remaining bits must
            // be flushed as true so that multiple
            // symbols are not encoded at the end
            // of the buffer.
            
            const int bitsUntilByte = 8 - bitWriter.bitOffset;

            for ( int i = 0; i < bitsUntilByte; i++ ) {
                // Emit bit that is consumed by the decoder
                // until the end of the input stream.
                bitWriter.writeBit(U1);
            }
            
            // Reset num bits so that it does not include
            // the byte padding that was just emitted above.
            bitWriter.numEncodedBits = savedNumEncodedBits;
        }
        
        // 32 bits of zero padding
        
        if (writeZeroPadding) {
            bitWriter.writeZeroByte();
            bitWriter.writeZeroByte();
            bitWriter.writeZeroByte();
            bitWriter.writeZeroByte();
        }
    }
    
    void encodeBit(const bool bit) {
        bitWriter.writeBit(bit);
    }
    
    // Rice encode a byte symbol n with an encoding 2^k
    // where k=0 uses 1 bit for the value zero. Note that
    // if this method is invoked directly then finish()
    // must be invoked after all symbols have been encoded.
    
    void encode(uint8_t n, const unsigned int k)
    {
        const bool debug = false;
        
#if defined(DEBUG)
        // In DEBUG mode, bits contains bits for this specific symbol.
        vector<bool> bitsThisSymbol;
        vector<bool> prefixBitsThisSymbol;
        vector<bool> suffixBitsThisSymbol;
        assert(U1 != U2);
#endif // DEBUG
        
        const unsigned int m = (1 << k); // 2^k
        const unsigned int q = pot_div_k(n, k);
        
        const unsigned int unaryNumBits = q + 1;
        
        if (debug) {
            printf("n %3d : k %3d : m %3d : q = n / m = %d : unaryNumBits %d \n", n, k, m, q, unaryNumBits);
        }
        
        if (unaryNumBits > 16) {
            // unary1 -> LITERAL : encoded as 16 zero bits in a row.

            for (int i = 0; i < 16; i++) {
                encodeBit(U1);
            }
            
#if defined(DEBUG)
            for (int i = 0; i < q; i++) {
                if (debug) {
                prefixBitsThisSymbol.push_back(U1);
                bitsThisSymbol.push_back(U1);
                }
            }
#endif // DEBUG
            
            // 8 bit literal appended to suffix buffer
            
            for (int i = 7; i >= 0; i--) {
                bool bit = (((n >> i) & 0x1) != 0);
                encodeBit(bit);
#if defined(DEBUG)
                if (debug) {
                suffixBitsThisSymbol.push_back(bit);
                bitsThisSymbol.push_back(bit);
                }
#endif // DEBUG
            }
        } else {
            // PREFIX -> SUFFIX
            
#if defined(DEBUG)
            assert(q != 16);
#endif // DEBUG
        
            for (int i = 0; i < q; i++) {
                encodeBit(U1); // defaults to true
#if defined(DEBUG)
                if (debug) {
                prefixBitsThisSymbol.push_back(U1);
                bitsThisSymbol.push_back(U1);
                }
#endif // DEBUG
            }
            
            encodeBit(U2); // defaults to false
#if defined(DEBUG)
            if (debug) {
            prefixBitsThisSymbol.push_back(U2);
            bitsThisSymbol.push_back(U2);
            }
#endif // DEBUG
            
            for (int i = k - 1; i >= 0; i--) {
                bool bit = (((n >> i) & 0x1) != 0);
                encodeBit(bit);
#if defined(DEBUG)
                if (debug) {
                suffixBitsThisSymbol.push_back(bit);
                bitsThisSymbol.push_back(bit);
                }
#endif // DEBUG
            }
        }
        
        if (debug) {
#if defined(DEBUG)
            // Print bits that were emitted for this symbol,
            // note the order from least to most significant
            printf("bits for symbol (least -> most): ");
            
            for ( bool bit : bitsThisSymbol ) {
                printf("%d", bit ? 1 : 0);
            }
            printf("\n");
            
            printf("prefix bits for symbol (least -> most): ");
            
            for ( bool bit : prefixBitsThisSymbol ) {
                printf("%d", bit ? 1 : 0);
            }
            printf(" (%d)\n", (int)prefixBitsThisSymbol.size());
            
            printf("suffix bits for symbol (least -> most): ");
            
            for ( bool bit : suffixBitsThisSymbol ) {
                printf("%d", bit ? 1 : 0);
            }
            printf(" (%d)\n", (int)suffixBitsThisSymbol.size());
#endif // DEBUG
        }
        
        return;
    }
    
    // Encode N symbols and emit any leftover bits
    
    void encode(const uint8_t * byteVals, int numByteVals, const unsigned int k) {
        const bool debug = false;
        for (int i = 0; i < numByteVals; i++) {
            if (debug) {
                printf("symboli %5d\n", i);
            }
            uint8_t byteVal = byteVals[i];
            encode(byteVal, k);
        }
        finish();
    }
    
    // Special case encoding method where the k value for a block of values is lookup
    // up in tables. Pass count table which indicates how many blocks the corresponding
    // n table entry corresponds to.
    
    void encode(const uint8_t * byteVals, int numByteVals,
                const uint8_t * kLookupTable,
                int kLookupTableLength,
                const vector<uint32_t> & countTable,
                const vector<uint32_t> & nTable)
    {
        const bool debug = false;
        
        assert(countTable.size() == nTable.size());
        
        int symboli = 0;
        int blocki = 0;
        
        const int tableMax = (int) countTable.size();
        for (int tablei = 0; tablei < tableMax; tablei++) {
            // count indicates how many symbols are covered by block k
            
            int numBlockCount = countTable[tablei];
            int numSymbolsPerBlock = nTable[tablei];
            
            assert(numBlockCount > 0);
            assert(numSymbolsPerBlock > 0);
            
            // The same number of symbols are used for numBlockCount blocks.
            
            int maxBlocki = blocki + numBlockCount;
            
            if (debug) {
                printf("blocki range (%d, %d) numSymbolsPerBlock %d\n", blocki, maxBlocki, numSymbolsPerBlock);
            }
            
            for ( ; blocki < maxBlocki; blocki++ ) {
                int k = kLookupTable[blocki];
                
                int maxSymboli = symboli + numSymbolsPerBlock;
                
                if (debug) {
                    printf("symboli range (%d, %d) k %d\n", symboli, maxSymboli, k);
                }
                
                for ( ; symboli < maxSymboli; symboli++) {
                    uint8_t byteVal = byteVals[symboli];
                    if (debug && 0) {
                        printf("symboli %5d : blocki %5d : k %2d\n", symboli, blocki, k);
                    }
                    encode(byteVal, k);
                }
            }
        }
        
        assert(symboli == numByteVals);
        // Note that the table lookup should contain one additional padding zero value
        assert(blocki == (kLookupTableLength-1));
        
        finish();
    }
    
    // Query number of bits needed to store symbol
    // with the given k parameter. Note that this
    // size query logic does not need to actually copy
    // encoded bytes so it is much faster than encoding.
    
    int numBits(unsigned char n, const unsigned int k) {
        const unsigned int q = pot_div_k(n, k);
        const unsigned int unaryNumBits = q + 1;
        if (unaryNumBits > 16) {
            // 16 zeros = zero, special case to indicate literal 8 bits
            return 16 + 8;
        } else {
            return unaryNumBits + k;
        }
    }
    
    // Query the number of bits needed to store these symbols
    
    int numBits(const uint8_t * byteVals, int numByteVals, const unsigned int k) {
        int totalNumBits = 0;
        for (int i = 0; i < numByteVals; i++) {
            uint8_t byteVal = byteVals[i];
            totalNumBits += numBits(byteVal, k);
        }
        return totalNumBits;
    }
    
};

// Optimized split16 decoder, this decoder makes use of a 16 bit input buffer
// and when the special case of 16 input zero bits is found, it simply means
// that the literal value is stored as 24 bits in the remainder. This special
// case would only be activated for very large values so performance for
// data that is mostly very small but has a few large deltas should be better
// and this logic has a maximum prefix clz size of 16.
// This decoder assumes that that unary pattern is N false values terminated
// by a true value.

template <const bool U1, const bool U2, class BRBS>
class RiceSplit16Decoder
{
public:
  // Input bits. A unary prefix has a maximum length of 16
  // and in that case the suffix contains the 8 literal bits.
  // All symbol decode operations can be executed as long
  // as 24 bits are loaded.
  
  uint32_t bits;
  
  BitReader<true, BRBS, 24> bitsReader;
  
  uint8_t *outputBytePtr;
  int outputByteOffset;
  int outputByteLength;
  
  RiceSplit16Decoder()
  :bits(0),
  outputBytePtr(nullptr),
  outputByteOffset(-1),
  outputByteLength(-1)
  {
    bitsReader.setBitsPtr(&bits);
  }
  
  inline
  void refillBits() {
    bitsReader.refillBits();
  }
  
  // Store refs to input and output byte bufers
  
  void setupInputOutput(const uint8_t * bitBuff, const int bitBuffN,
                        uint8_t * symbolBuff, const int symbolBuffN)
  {
    bitsReader.byteReader.setupInput(bitBuff, bitBuffN);
    
    this->outputBytePtr = symbolBuff;
    this->outputByteOffset = 0;
    this->outputByteLength = symbolBuffN;
    
#if defined(DEBUG)
    if (bitBuff != nullptr) {
      uint8_t bVal = bitBuff[0];
      bVal += bitBuff[bitBuffN-1];
      
      outputBytePtr[0] = bVal;
      outputBytePtr[symbolBuffN-1] = bVal;
    }
#endif // DEBUG
  }
  
  // Decode N symbols from the input stream and write decoded symbols
  // to the output vector. Returns the number of symbols decoded.
  
  int decodeSymbols(const unsigned int k, const int nsymbols) {
    const bool debug = false;
    
    if (debug) {
      printf("k = %d\n", k);
    }
    
    //const unsigned int m = (1 << k);
    
    for ( int symboli = 0; symboli < nsymbols; symboli++ ) {
      unsigned int symbol;
      
      // Refill before reading a symbol
      refillBits();
      
      unsigned int q;
      
      if ((bits >> 16) == 0) {
        // Special case for 16 bits of zeros in high halfword
        q = 0;
        
        // FIXME: skip 16 zeros and set symbol to 8 bit literal
        
# if defined(DEBUG)
        assert(bitsReader.bitsInRegister >= 24);
# endif // DEBUG
        
        bits <<= 16;
        
        if (debug) {
          printf("bits (del16): %s\n", get_code_bits_as_string64(bits, 32).c_str());
        }
        
# if defined(DEBUG)
        assert(bitsReader.bitsInRegister >= 8);
# endif // DEBUG
        
        symbol = bits >> 24;
        
        if (debug) {
          printf("symbol      : %s\n", get_code_bits_as_string64(symbol, 32).c_str());
        }
        
        bits <<= 8;
        
        if (debug) {
          printf("bits (del8) : %s\n", get_code_bits_as_string64(bits, 32).c_str());
        }
        
# if defined(DEBUG)
        assert(bitsReader.bitsInRegister >= 24);
# endif // DEBUG
        
        bitsReader.bitsInRegister -= 24;
      } else {
# if defined(DEBUG)
        assert((bits & 0xFFFF0000) != 0);
# endif // DEBUG
        
        //unsigned int lz = __builtin_clz(bits);
        //q = 32 - lz;
        //q = lz;
        
        q = __builtin_clz(bits);
        
        symbol = q << k;
        
        if (debug) {
          printf("q (num leading zeros): %d\n", q);
        }
        
        // Shift left to place MSB of remainder at the MSB of register
        bits <<= (q + 1);
        
        if (debug) {
          printf("lshift   %2d : %s\n", q, get_code_bits_as_string64(bits, 32).c_str());
        }
        
        // FIXME: shift right could use a mask based on k and a shift based
        // on q to avoid using the result of the earlier left shift
        
        // Shift right to place LSB of remainder at bit offset 0
        uint32_t rem = (bits >> 16) >> (16 - k);
        
        if (debug) {
          printf("rem         : %s\n", get_code_bits_as_string64(rem, 32).c_str());
        }
        symbol |= rem;
        
        if (debug) {
          printf("symbol      : %s\n", get_code_bits_as_string64(symbol, 32).c_str());
        }
        
# if defined(DEBUG)
        assert(bitsReader.bitsInRegister >= (q + 1 + k));
# endif // DEBUG
        bitsReader.bitsInRegister -= (q + 1 + k);
        // was already shifted left by (q + 1) above, so shift left to consume rem bits
        bits <<= k;
        
        if (debug) {
          printf("lshift2  %2d : %s\n", k, get_code_bits_as_string64(bits, 32).c_str());
        }
        
      }
      
      if (debug) {
        printf("append decoded symbol = %d\n", symbol);
      }
      
#if defined(DEBUG)
      assert(outputByteOffset < outputByteLength);
#endif // DEBUG
      outputBytePtr[outputByteOffset++] = symbol;
    }
    
    return nsymbols;
  }
  
  // Decode symbols from a buffer of encoded bytes and
  // return the results as a vector of decoded bytes.
  // This method assumes that the k value is known.
  
  void decode(const uint8_t * bitBuff, const int bitBuffN,
              uint8_t * symbolBuff, const int symbolBuffN,
              const unsigned int k)
  {
    setupInputOutput(bitBuff, bitBuffN, symbolBuff, symbolBuffN);
    
    decodeSymbols(k, symbolBuffN);
    
    return;
  }
  
  // Special case decoding method where the k value for a block of values is lookup
  // up in tables. Pass count table which indicates how many blocks the corresponding
  // n table entry corresponds to.
  
  void decode(const uint8_t * bitBuff, int bitBuffN,
              uint8_t * symbolBuff, const int symbolBuffN,
              const uint8_t * kLookupTable,
              int kLookupTableLength,
              const vector<uint32_t> & countTable,
              const vector<uint32_t> & nTable)
  {
    const bool debug = false;
    
    setupInputOutput(bitBuff, bitBuffN, symbolBuff, symbolBuffN);
    
#if defined(DEBUG)
    assert(countTable.size() == nTable.size());
#endif // DEBUG
    
    int symboli = 0;
    int blocki = 0;
    
    const int tableMax = (int) countTable.size();
    for (int tablei = 0; tablei < tableMax; tablei++) {
      // count indicates how many symbols are covered by block k
      
      int numBlockCount = countTable[tablei];
      int numSymbolsPerBlock = nTable[tablei];
      
#if defined(DEBUG)
      assert(numBlockCount > 0);
      assert(numSymbolsPerBlock > 0);
#endif // DEBUG
      
      // The same number of symbols are used for numBlockCount blocks.
      
      int maxBlocki = blocki + numBlockCount;
      
      if (debug) {
        printf("blocki range (%d, %d) numSymbolsPerBlock %d\n", blocki, maxBlocki, numSymbolsPerBlock);
      }
      
      for ( ; blocki < maxBlocki; blocki++ ) {
        int k = kLookupTable[blocki];
        
        int maxSymboli = symboli + numSymbolsPerBlock;
        
        if (debug) {
          printf("symboli range (%d, %d) k %d\n", symboli, maxSymboli, k);
        }
        
        int numSymbolsDecoded = decodeSymbols(k, numSymbolsPerBlock);
        
#if defined(DEBUG)
        assert(numSymbolsDecoded == numSymbolsPerBlock);
#endif // DEBUG
        
        symboli += numSymbolsDecoded;
      }
    }
    
#if defined(DEBUG)
    assert(blocki == (kLookupTableLength-1));
    assert(symboli == symbolBuffN);
#endif // DEBUG
    
    return;
  }
};


// Special purpose split and block into groups of 4 encoding, where 4 values are
// processed at a time so that prefix P and suffix S are stored as (SSSS PPPP)
// 4 at a time. The prefix portion can contain OVER bits that do not fit into k.

template <const bool U1, const bool U2, class BWBS>
class RiceSplit16EncoderG4
{
  public:
  // Emit MSB bit order
  BitWriter<true, BWBS> bitWriter;
  
  // Defaults to emitting a word of zeros after
  // the final full byte was emitted.
  
  bool writeZeroPadding;
  
  RiceSplit16EncoderG4() :writeZeroPadding(true) {
  }
  
  void reset() {
    bitWriter.reset();
  }
  
  // If any bits still need to be emitted, emit final byte.
  
  void finish() {
    // Do not adjust numEncodedBits
    
    unsigned int savedNumEncodedBits = bitWriter.numEncodedBits;
    
    if (bitWriter.bitOffset > 0) {
      // Flush 1-8 bits to some external output.
      // Note that all remaining bits must
      // be flushed as true so that multiple
      // symbols are not encoded at the end
      // of the buffer.
      
      const int bitsUntilByte = 8 - bitWriter.bitOffset;
      
      for ( int i = 0; i < bitsUntilByte; i++ ) {
        // Emit bit that is consumed by the decoder
        // until the end of the input stream.
        bitWriter.writeBit(U1);
      }
      
      // Reset num bits so that it does not include
      // the byte padding that was just emitted above.
      bitWriter.numEncodedBits = savedNumEncodedBits;
    }
    
    // 32 bits of zero padding
    
    if (writeZeroPadding) {
      bitWriter.writeZeroByte();
      bitWriter.writeZeroByte();
      bitWriter.writeZeroByte();
      bitWriter.writeZeroByte();
    }
  }
  
  void encodeBit(const bool bit) {
    bitWriter.writeBit(bit);
  }
  
  // Rice encode a byte symbol n with an encoding 2^k
  // where k=0 uses 1 bit for the value zero. Note that
  // if this method is invoked directly then finish()
  // must be invoked after all symbols have been encoded.
  
  void encode(uint8_t n,
              const unsigned int k,
              const bool emitPrefix,
              const bool emitSuffix)
  {
    const bool debug = false;
    
#if defined(DEBUG)
    // In DEBUG mode, bits contains bits for this specific symbol.
    vector<bool> bitsThisSymbol;
    vector<bool> prefixBitsThisSymbol;
    vector<bool> suffixBitsThisSymbol;
    assert(U1 != U2);
#endif // DEBUG
    
    const unsigned int m = (1 << k); // 2^k
    const unsigned int q = pot_div_k(n, k);
    
    const unsigned int unaryNumBits = q + 1;
    
    if (debug) {
      printf("n %3d : k %3d : m %3d : q = n / m = %d : unaryNumBits %d \n", n, k, m, q, unaryNumBits);
    }
    
    if (unaryNumBits > 16) {
      // unary1 -> LITERAL : encoded as 16 zero bits in a row.
      
      if (emitPrefix) {
        for (int i = 0; i < 16; i++) {
          encodeBit(U1);
        }
      }

#if defined(DEBUG)
      for (int i = 0; i < 16; i++) {
        if (debug) {
          prefixBitsThisSymbol.push_back(U1);
          bitsThisSymbol.push_back(U1);
        }
      }
#endif // DEBUG
      
#if defined(DEBUG)
      // Write all 8 bits to bitsThisSymbol debug vector
      for (int i = 7; i >= 0; i--) {
        if (debug) {
          bool bit = (((n >> i) & 0x1) != 0);
          bitsThisSymbol.push_back(bit);
        }
      }
#endif // DEBUG
      
      // Emit OVER bits (not k) to prefix stream
      
      uint8_t overBits = 0;
      
      if (emitPrefix || debug) {
        for (int i = 7; i >= (int)k; i--) {
          bool bit = (((n >> i) & 0x1) != 0);
          if (debug) {
            overBits |= (bit << i);
          }
          
          if (emitPrefix) {
            encodeBit(bit);
          }
          
#if defined(DEBUG)
          if (debug) {
            prefixBitsThisSymbol.push_back(bit);
          }
#endif // DEBUG
        }
      }

      // Emit most significant k bits to suffix stream
      
      uint8_t kBits = 0;
      
      if (emitSuffix || debug) {
        for (int i = k - 1; i >= 0; i--) {
          bool bit = (((n >> i) & 0x1) != 0);
          
          if (debug) {
            kBits |= (bit << i);
          }
          
          if (emitSuffix) {
            encodeBit(bit);
          }
          
#if defined(DEBUG)
          if (debug) {
            suffixBitsThisSymbol.push_back(bit);
          }
#endif // DEBUG
        }
      }

      if (debug) {
        printf("kBits     %s (%d bits)\n", get_code_bits_as_string64(kBits, 8).c_str(), k);
        printf("overBits  %s (%d bits)\n", get_code_bits_as_string64(overBits,8).c_str(), 8-k);
        
#if defined(DEBUG)
        // Combining overBits and q is simply a matter of ORing
        // these values together, in decoding logic the MSB
        // bits for overBits would need to be shifted left
        // to mask off k bits.
        assert(n == (overBits | kBits));
#endif // DEBUG
      }
      
    } else {
      // emit PREFIX and or SUFFIX
      
#if defined(DEBUG)
      // q can be in range (0, 15) : valid prefixCount range (1, 16)
      assert(q < 16);
      assert(unaryNumBits > 0);
      assert(unaryNumBits < 17);
#endif // DEBUG
      
      if (emitPrefix || debug) {
        // Preix bits
        
        for (int i = 0; i < q; i++) {
          if (emitPrefix) {
            encodeBit(U1); // defaults to true
          }
#if defined(DEBUG)
          if (debug) {
            prefixBitsThisSymbol.push_back(U1);
            bitsThisSymbol.push_back(U1);
          }
#endif // DEBUG
        }
        
        if (emitPrefix) {
          encodeBit(U2); // defaults to false
        }

#if defined(DEBUG)
        if (debug) {
          prefixBitsThisSymbol.push_back(U2);
          bitsThisSymbol.push_back(U2);
        }
#endif // DEBUG
      }

      if (emitSuffix || debug) {
        // suffix bits
        
        for (int i = k - 1; i >= 0; i--) {
          bool bit = (((n >> i) & 0x1) != 0);
          if (emitSuffix) {
            encodeBit(bit);
          }
#if defined(DEBUG)
          if (debug) {
            suffixBitsThisSymbol.push_back(bit);
            bitsThisSymbol.push_back(bit);
          }
#endif // DEBUG
        }
      }
    }
    
    if (debug) {
#if defined(DEBUG)
      // Print bits that were emitted for this symbol,
      // note the order from least to most significant
      printf("bits for symbol (least -> most): ");
      
      for ( bool bit : bitsThisSymbol ) {
        printf("%d", bit ? 1 : 0);
      }
      printf("\n");
      
      printf("prefix bits for symbol (least -> most): ");
      
      for ( bool bit : prefixBitsThisSymbol ) {
        printf("%d", bit ? 1 : 0);
      }
      printf(" (%d)\n", (int)prefixBitsThisSymbol.size());
      
      printf("suffix bits for symbol (least -> most): ");
      
      for ( bool bit : suffixBitsThisSymbol ) {
        printf("%d", bit ? 1 : 0);
      }
      printf(" (%d)\n", (int)suffixBitsThisSymbol.size());
      printf("\n");
#endif // DEBUG
    }
    
    return;
  }
  
  // Encode N symbols and emit any leftover bits
  
  void encode(const uint8_t * byteVals, int numByteVals, const unsigned int k) {
    const bool debug = false;
    for (int i = 0; i < numByteVals; i++) {
      if (debug) {
        printf("symboli %5d\n", i);
      }
      uint8_t byteVal = byteVals[i];
      encode(byteVal, k);
    }
    finish();
  }
  
  // Special case encoding method where the k value for a block of values is lookup
  // up in tables. Pass count table which indicates how many blocks the corresponding
  // n table entry corresponds to.
  
  void encode(const uint8_t * byteVals, int numByteVals,
              const uint8_t * kLookupTable,
              int kLookupTableLength,
              const vector<uint32_t> & countTable,
              const vector<uint32_t> & nTable)
  {
    const bool debug = false;
    
    assert(countTable.size() == nTable.size());
    
    int symboli = 0;
    int blocki = 0;
    
    const int pN = 4;
    
    const int tableMax = (int) countTable.size();
    for (int tablei = 0; tablei < tableMax; tablei++) {
      // count indicates how many symbols are covered by block k
      
      int numBlockCount = countTable[tablei];
      int numSymbolsPerBlock = nTable[tablei];
      
      assert(numBlockCount > 0);
      assert(numSymbolsPerBlock > 0);

      // Block size must be a multiple of pN
      
      assert((numSymbolsPerBlock % pN) == 0);
      
      // The same number of symbols are used for numBlockCount blocks.
      
      int maxBlocki = blocki + numBlockCount;
      
      if (debug) {
        printf("blocki range (%d, %d) numSymbolsPerBlock %d\n", blocki, maxBlocki, numSymbolsPerBlock);
      }
      
      for ( ; blocki < maxBlocki; blocki++ ) {
        int k = kLookupTable[blocki];
        
        int maxSymboli = symboli + numSymbolsPerBlock;
        
        if (debug) {
          printf("symboli range (%d, %d) k %d\n", symboli, maxSymboli, k);
        }
        
        for ( ; symboli < maxSymboli; symboli += pN ) {
          const int symboli4Max = symboli + pN;
          
          // Prefix
          
          for ( int i = symboli ; i < symboli4Max; i++ ) {
            uint8_t byteVal = byteVals[i];
            if (debug && 1) {
              printf("symboli %5d : blocki %5d : k %2d : prefix bits\n", symboli, blocki, k);
            }
            
            encode(byteVal, k, true, false);
          }
          
          // Suffix
          
          for ( int i = symboli ; i < symboli4Max; i++ ) {
            uint8_t byteVal = byteVals[i];
            if (debug && 1) {
              printf("symboli %5d : blocki %5d : k %2d : suffix bits\n", symboli, blocki, k);
            }
            
            encode(byteVal, k, false, true);
          }
          
        }
      }
    }
    
    assert(symboli == numByteVals);
    // Note that the table lookup should contain one additional padding zero value
    assert(blocki == (kLookupTableLength-1));
    
    finish();
  }
  
  // Query number of bits needed to store symbol
  // with the given k parameter. Note that this
  // size query logic does not need to actually copy
  // encoded bytes so it is much faster than encoding.
  
  int numBits(unsigned char n, const unsigned int k) {
    const unsigned int q = pot_div_k(n, k);
    const unsigned int unaryNumBits = q + 1;
    if (unaryNumBits > 16) {
      // 16 zeros = zero, special case to indicate literal 8 bits
      return 16 + 8;
    } else {
      return unaryNumBits + k;
    }
  }
  
  // Query the number of bits needed to store these symbols
  
  int numBits(const uint8_t * byteVals, int numByteVals, const unsigned int k) {
    int totalNumBits = 0;
    for (int i = 0; i < numByteVals; i++) {
      uint8_t byteVal = byteVals[i];
      totalNumBits += numBits(byteVal, k);
    }
    return totalNumBits;
  }
  
};

// Split encoding where elements are broken into prefix and suffix and then
// grouped 4 at a time.

template <const bool U1, const bool U2, class BRBS>
class RiceSplit16DecoderG4
{
public:
  // Input bits. A unary prefix has a maximum length of 16
  // and in that case the suffix contains the 8 literal bits.
  // All symbol decode operations can be executed as long
  // as 24 bits are loaded.
  
  uint32_t bits;
  
  BitReader<true, BRBS, 24> bitsReader;
  
  uint8_t *outputBytePtr;
  int outputByteOffset;
  int outputByteLength;
  
  RiceSplit16DecoderG4()
  :bits(0),
  outputBytePtr(nullptr),
  outputByteOffset(-1),
  outputByteLength(-1)
  {
    bitsReader.setBitsPtr(&bits);
  }
  
  inline
  void refillBits() {
    bitsReader.refillBits();
  }
  
  // Store refs to input and output byte bufers
  
  void setupInputOutput(const uint8_t * bitBuff, const int bitBuffN,
                        uint8_t * symbolBuff, const int symbolBuffN)
  {
    bitsReader.byteReader.setupInput(bitBuff, bitBuffN);
    
    this->outputBytePtr = symbolBuff;
    this->outputByteOffset = 0;
    this->outputByteLength = symbolBuffN;
    
#if defined(DEBUG)
    if (bitBuff != nullptr) {
      uint8_t bVal = bitBuff[0];
      bVal += bitBuff[bitBuffN-1];
      
      outputBytePtr[0] = bVal;
      outputBytePtr[symbolBuffN-1] = bVal;
    }
#endif // DEBUG
  }

  // Decode prefix portion of symbol
  
  uint8_t decodePrefix(const unsigned int k) {
    const bool debug = false;

    unsigned int symbol;

    if ((bits >> 16) == 0) {
      // Special case for 16 bits of zeros in high halfword
      
# if defined(DEBUG)
      assert(bitsReader.bitsInRegister >= 24);
# endif // DEBUG
      
      bits <<= 16;
      
      if (debug) {
        printf("bits (del16): %s\n", get_code_bits_as_string64(bits, 32).c_str());
      }
      
# if defined(DEBUG)
      assert(bitsReader.bitsInRegister >= (8 - k));
# endif // DEBUG
      
      symbol = (bits >> 24) >> k << k;
      
      if (debug) {
        printf("symbol      : %s\n", get_code_bits_as_string64(symbol, 32).c_str());
      }
      
      bits <<= (8 - k);
      
      if (debug) {
        printf("bits (del pre) : %s\n", get_code_bits_as_string64(bits, 32).c_str());
      }
      
# if defined(DEBUG)
      assert(bitsReader.bitsInRegister >= (24 - k));
# endif // DEBUG
      
      bitsReader.bitsInRegister -= (24 - k);
    } else {
# if defined(DEBUG)
      assert((bits & 0xFFFF0000) != 0);
# endif // DEBUG
      
      //unsigned int lz = __builtin_clz(bits);
      //q = 32 - lz;
      //q = lz;
      
      if (debug) {
        printf("bits : %s\n", get_code_bits_as_string64(bits, 32).c_str());
      }
      
      unsigned int q;
      q = __builtin_clz(bits);
      
      symbol = q << k;
      
      if (debug) {
        printf("q (num leading zeros): %d\n", q);
      }
      
      // Shift left to place MSB of remainder at the MSB of register
      bits <<= (q + 1);
      
# if defined(DEBUG)
      assert(bitsReader.bitsInRegister >= (q + 1));
# endif // DEBUG
      bitsReader.bitsInRegister -= (q + 1);
      
      if (debug) {
        printf("lshift   %2d : %s\n", q, get_code_bits_as_string64(bits, 32).c_str());
      }
    }
    
    return symbol;
  }

  uint8_t decodeSuffix(const unsigned int k) {
    const bool debug = false;

    unsigned int rem;
    
    // Shift right to place LSB of remainder at bit offset 0
    rem = (bits >> 16) >> (16 - k);
    
    if (debug) {
      printf("rem         : %s\n", get_code_bits_as_string64(rem, 8).c_str());
    }
    
# if defined(DEBUG)
    assert(bitsReader.bitsInRegister >= k);
# endif // DEBUG
    bitsReader.bitsInRegister -= k;
    bits <<= k;
    
    if (debug) {
      printf("lshift2  %2d : %s\n", k, get_code_bits_as_string64(bits, 32).c_str());
    }
    
    return rem;
  }
  
  // Decode N symbols from the input stream and write decoded symbols
  // to the output vector. Returns the number of symbols decoded.
  
  int decodeSymbols(const unsigned int k, const int nsymbols) {
    const bool debug = false;
    
    if (debug) {
      printf("k = %d\n", k);
    }
    
    //const unsigned int m = (1 << k);

    const int N = 4;
    unsigned int decodedSymbols[N];
    
    assert((nsymbols % N) == 0);
    
    for ( int symboli = 0; symboli < nsymbols; symboli += N ) {
      
      for ( int si = 0 ; si < 4; si++ ) {
        // Refill before reading a symbol
        refillBits();
        
        uint8_t prefix = decodePrefix(k);
        //uint8_t rem = decodeSuffix(k);
        
        unsigned int symbol;
        symbol = prefix;
        
        if (debug) {
          printf("append decoded prefix symbol = %d\n", symbol);
        }
        
        decodedSymbols[si] = symbol;
      }
      
      for ( int si = 0 ; si < 4; si++ ) {
        // Refill before reading a symbol
        refillBits();
        
        //uint8_t prefix = decodePrefix(k);
        uint8_t rem = decodeSuffix(k);
        
        unsigned int symbol = decodedSymbols[si];
        
        symbol |= rem;
        
        if (debug) {
          printf("append decoded prefix|suffix symbol = %d\n", symbol);
        }
        
        decodedSymbols[si] = symbol;
      }
      
      // Emit each symbol
      
      for ( int si = 0 ; si < 4; si++ ) {
        unsigned int symbol = decodedSymbols[si];
#if defined(DEBUG)
        assert(outputByteOffset < outputByteLength);
#endif // DEBUG
        outputBytePtr[outputByteOffset++] = symbol;
      }
    }
    
    return nsymbols;
  }
  
  // Decode symbols from a buffer of encoded bytes and
  // return the results as a vector of decoded bytes.
  // This method assumes that the k value is known.
  
  void decode(const uint8_t * bitBuff, const int bitBuffN,
              uint8_t * symbolBuff, const int symbolBuffN,
              const unsigned int k)
  {
    setupInputOutput(bitBuff, bitBuffN, symbolBuff, symbolBuffN);
    
    decodeSymbols(k, symbolBuffN);
    
    return;
  }
  
  // Special case decoding method where the k value for a block of values is lookup
  // up in tables. Pass count table which indicates how many blocks the corresponding
  // n table entry corresponds to.
  
  void decode(const uint8_t * bitBuff, int bitBuffN,
              uint8_t * symbolBuff, const int symbolBuffN,
              const uint8_t * kLookupTable,
              int kLookupTableLength,
              const vector<uint32_t> & countTable,
              const vector<uint32_t> & nTable)
  {
    const bool debug = false;
    
    setupInputOutput(bitBuff, bitBuffN, symbolBuff, symbolBuffN);
    
#if defined(DEBUG)
    assert(countTable.size() == nTable.size());
#endif // DEBUG
    
    int symboli = 0;
    int blocki = 0;
    
    const int tableMax = (int) countTable.size();
    for (int tablei = 0; tablei < tableMax; tablei++) {
      // count indicates how many symbols are covered by block k
      
      int numBlockCount = countTable[tablei];
      int numSymbolsPerBlock = nTable[tablei];
      
#if defined(DEBUG)
      assert(numBlockCount > 0);
      assert(numSymbolsPerBlock > 0);
#endif // DEBUG
      
      // The same number of symbols are used for numBlockCount blocks.
      
      int maxBlocki = blocki + numBlockCount;
      
      if (debug) {
        printf("blocki range (%d, %d) numSymbolsPerBlock %d\n", blocki, maxBlocki, numSymbolsPerBlock);
      }
      
      for ( ; blocki < maxBlocki; blocki++ ) {
        int k = kLookupTable[blocki];
        
        int maxSymboli = symboli + numSymbolsPerBlock;
        
        if (debug) {
          printf("symboli range (%d, %d) k %d\n", symboli, maxSymboli, k);
        }
        
        int numSymbolsDecoded = decodeSymbols(k, numSymbolsPerBlock);
        
#if defined(DEBUG)
        assert(numSymbolsDecoded == numSymbolsPerBlock);
#endif // DEBUG
        
        symboli += numSymbolsDecoded;
      }
    }
    
#if defined(DEBUG)
    assert(blocki == (kLookupTableLength-1));
    assert(symboli == symbolBuffN);
#endif // DEBUG
    
    return;
  }
};

// Special purpose "split" rice encoding where the bits that make up the unary
// prefix bits are stored in one buffer while the remainder bits are stored
// in a second buffer. This encoder checks for the case where the unary bits
// would take up more than 16 bits and in that case it will simply emit 16 zero
// bits and then store the 8 literal bits directly in the remainder. This produces
// an encoding that has a fixed 24 bit width but very very large values will not
// have a worst case that would require hundreds of bits.

// Note that the BWBS class indicated here must implement the API defined
// in BitWriterBitStream.

template <const bool U1, const bool U2, class BWBS>
class RiceSplit16x2Encoder
{
public:
    // Emit MSB bit order
    BitWriter<true, BWBS> prefixBitWriter;
    BitWriter<true, BWBS> remBitWriter;
    
    vector<uint8_t> unaryNBytes;
    vector<uint8_t> remNBytes;
    
    RiceSplit16x2Encoder() {
    }
    
    void reset() {
        prefixBitWriter.reset();
        remBitWriter.reset();
        
        unaryNBytes.clear();
        remNBytes.clear();
    }
    
    // If any bits still need to be emitted, emit final byte.
    
    void finishPrefix() {
        // Do not adjust numEncodedBits
        
        auto & bitWriter = prefixBitWriter;
        
        unsigned int savedNumEncodedBits = bitWriter.numEncodedBits;
        
        if (bitWriter.bitOffset > 0) {
            // Flush 1-8 bits to some external output.
            // Note that all remaining bits must
            // be flushed as true so that multiple
            // symbols are not encoded at the end
            // of the buffer.
            
            const int bitsUntilByte = 8 - bitWriter.bitOffset;
            
            for ( int i = 0; i < bitsUntilByte; i++ ) {
                // Emit bit that is consumed by the decoder
                // until the end of the input stream.
                bitWriter.writeBit(U1);
            }
            
            // Reset num bits so that it does not include
            // the byte padding that was just emitted above.
            bitWriter.numEncodedBits = savedNumEncodedBits;
        }
        
        // 32 bits of zero padding
        
        bitWriter.writeZeroByte();
        bitWriter.writeZeroByte();
        bitWriter.writeZeroByte();
        bitWriter.writeZeroByte();
    }
    
    void finishRem() {
        // Do not adjust numEncodedBits
        
        auto & bitWriter = remBitWriter;
        
        unsigned int savedNumEncodedBits = bitWriter.numEncodedBits;
        
        if (bitWriter.bitOffset > 0) {
            // Flush 1-8 bits to some external output.
            // Note that all remaining bits must
            // be flushed as true so that multiple
            // symbols are not encoded at the end
            // of the buffer.
            
            const int bitsUntilByte = 8 - bitWriter.bitOffset;
            
            for ( int i = 0; i < bitsUntilByte; i++ ) {
                // Emit bit that is consumed by the decoder
                // until the end of the input stream.
                bitWriter.writeBit(U1);
            }
            
            // Reset num bits so that it does not include
            // the byte padding that was just emitted above.
            bitWriter.numEncodedBits = savedNumEncodedBits;
        }
        
        // 32 bits of zero padding
        
        bitWriter.writeZeroByte();
        bitWriter.writeZeroByte();
        bitWriter.writeZeroByte();
        bitWriter.writeZeroByte();
    }
    
    void finish() {
        finishPrefix();
        finishRem();
    }

    void encodeBit(const bool isPrefix, const bool bit) {
        if (isPrefix) {
            prefixBitWriter.writeBit(bit);
        } else {
            remBitWriter.writeBit(bit);
        }
    }
    
    // Rice encode a byte symbol n with an encoding 2^k
    // where k=0 uses 1 bit for the value zero. Note that
    // if this method is invoked directly then finish()
    // must be invoked after all symbols have been encoded.
    
    void encode(uint8_t n, const unsigned int k)
    {
        const bool debug = false;
        
#if defined(DEBUG)
        // In DEBUG mode, bits contains bits for this specific symbol.
        vector<bool> bitsThisSymbol;
        vector<bool> prefixBitsThisSymbol;
        vector<bool> suffixBitsThisSymbol;
        assert(U1 != U2);
#endif // DEBUG
        
        const unsigned int q = pot_div_k(n, k);
        const unsigned int unaryNumBits = q + 1;
        
        if (debug) {
            const unsigned int m = (1 << k); // m = 2^k
            printf("n %3d : k %3d : m %3d : q = n / m = %d : unaryNumBits %d \n", n, k, m, q, unaryNumBits);
        }
        
        if (unaryNumBits > 16) {
            // unary1 -> LITERAL
            
            unaryNBytes.push_back(17);
            
            for (int i = 0; i < 16; i++) {
                encodeBit(true, U1);
            }
            
            // Note that there is no trailing 1 in this case, 16 zeros
            // in a row indicate that the 8 bits after it are always
            // the 8 bits of the literal byte.
            
#if defined(DEBUG)
            for (int i = 0; i < 16; i++) {
                if (debug) {
                prefixBitsThisSymbol.push_back(U1);
                bitsThisSymbol.push_back(U1);
                }
            }
#endif // DEBUG
            
            // 8 bit literal appended to suffix buffer
            
            for (int i = 7; i >= 0; i--) {
                bool bit = (((n >> i) & 0x1) != 0);
                encodeBit(false, bit);
#if defined(DEBUG)
                if (debug) {
                suffixBitsThisSymbol.push_back(bit);
                bitsThisSymbol.push_back(bit);
                }
#endif // DEBUG
            }
            
            remNBytes.push_back(n);
        } else {
            // PREFIX -> SUFFIX
            
#if defined(DEBUG)
            // q can be in range (0, 15) : valid prefixCount range (1, 16)
            assert(unaryNumBits < 17);
#endif // DEBUG
            unaryNBytes.push_back(unaryNumBits);
            
            for (int i = 0; i < q; i++) {
                encodeBit(true, U1); // defaults to true
#if defined(DEBUG)
                if (debug) {
                prefixBitsThisSymbol.push_back(U1);
                bitsThisSymbol.push_back(U1);
                }
#endif // DEBUG
            }
            
            encodeBit(true, U2); // defaults to false
#if defined(DEBUG)
            if (debug) {
            prefixBitsThisSymbol.push_back(U2);
            bitsThisSymbol.push_back(U2);
            }
#endif // DEBUG
            
            for (int i = k - 1; i >= 0; i--) {
                bool bit = (((n >> i) & 0x1) != 0);
                encodeBit(false, bit);
#if defined(DEBUG)
                if (debug) {
                suffixBitsThisSymbol.push_back(bit);
                bitsThisSymbol.push_back(bit);
                }
#endif // DEBUG
            }
            
            // Save k bit remainder as a byte value
            
            uint8_t rem = 0;
            
            for (int i = k - 1; i >= 0; i--) {
                bool bit = (((n >> i) & 0x1) != 0);
                rem |= ((bit ? 0x1 : 0x0) << i);
            }
            
            remNBytes.push_back(rem);
#if defined(DEBUG)
            assert(n == (rem | (q << k)));
#endif // DEBUG
        }
        
        if (debug) {
#if defined(DEBUG)
            // Print bits that were emitted for this symbol,
            // note the order from least to most significant
            printf("bits for symbol (least -> most): ");
            
            for ( bool bit : bitsThisSymbol ) {
                printf("%d", bit ? 1 : 0);
            }
            printf("\n");
            
            printf("prefix bits for symbol (least -> most): ");
            
            for ( bool bit : prefixBitsThisSymbol ) {
                printf("%d", bit ? 1 : 0);
            }
            printf(" (%d)\n", (int)prefixBitsThisSymbol.size());
            
            printf("suffix bits for symbol (least -> most): ");
            
            for ( bool bit : suffixBitsThisSymbol ) {
                printf("%d", bit ? 1 : 0);
            }
            printf(" (%d)\n", (int)suffixBitsThisSymbol.size());
#endif // DEBUG
        }
        
        return;
    }
    
    // Encode N symbols and emit any leftover bits
    
    void encode(const uint8_t * byteVals, int numByteVals, const unsigned int k) {
        const bool debug = false;
        for (int i = 0; i < numByteVals; i++) {
            if (debug) {
                printf("symboli %5d\n", i);
            }
            uint8_t byteVal = byteVals[i];
            encode(byteVal, k);
        }
        finish();
    }
    
    // Special case encoding method where the k value for a block of values is lookup
    // up in tables. Pass count table which indicates how many blocks the corresponding
    // n table entry corresponds to.
    
    void encode(const uint8_t * byteVals, int numByteVals,
                const uint8_t * kLookupTable,
                int kLookupTableLength,
                const vector<uint32_t> & countTable,
                const vector<uint32_t> & nTable)
    {
        const bool debug = false;
        
        assert(countTable.size() == nTable.size());
        
        int symboli = 0;
        int blocki = 0;
        
        const int tableMax = (int) countTable.size();
        for (int tablei = 0; tablei < tableMax; tablei++) {
            // count indicates how many symbols are covered by block k
            
            int numBlockCount = countTable[tablei];
            int numSymbolsPerBlock = nTable[tablei];
            
            assert(numBlockCount > 0);
            assert(numSymbolsPerBlock > 0);
            
            // The same number of symbols are used for numBlockCount blocks.
            
            int maxBlocki = blocki + numBlockCount;
            
            if (debug) {
                printf("blocki range (%d, %d) numSymbolsPerBlock %d\n", blocki, maxBlocki, numSymbolsPerBlock);
            }
            
            for ( ; blocki < maxBlocki; blocki++ ) {
                int k = kLookupTable[blocki];
                
                int maxSymboli = symboli + numSymbolsPerBlock;
                
                if (debug) {
                    printf("symboli range (%d, %d) k %d\n", symboli, maxSymboli, k);
                }
                
                for ( ; symboli < maxSymboli; symboli++) {
                    uint8_t byteVal = byteVals[symboli];
                    if (debug && 0) {
                        printf("symboli %5d : blocki %5d : k %2d\n", symboli, blocki, k);
                    }
                    encode(byteVal, k);
                }
            }
        }
        
        assert(symboli == numByteVals);
        assert(blocki == (kLookupTableLength-1));
        
        finish();
    }
    
    // Query number of bits needed to store symbol
    // with the given k parameter. Note that this
    // size query logic does not need to actually copy
    // encoded bytes so it is much faster than encoding.
    
    int numBits(unsigned char n, const unsigned int k) {
        const unsigned int q = pot_div_k(n, k);
        const unsigned int unaryNumBits = q + 1;
        if (unaryNumBits > 16) {
            // 16 zeros = zero, special case to indicate literal 8 bits
            return 16 + 8;
        } else {
            return unaryNumBits + k;
        }
    }
    
    // Query the number of bits needed to store these symbols
    
    int numBits(const uint8_t * byteVals, int numByteVals, const unsigned int k) {
        int totalNumBits = 0;
        for (int i = 0; i < numByteVals; i++) {
            uint8_t byteVal = byteVals[i];
            totalNumBits += numBits(byteVal, k);
        }
        return totalNumBits;
    }
    
};

// This optimized split16 decode will read from a prefix byte array source
// and from a rem suffix array source and reassemble symbols based on
// reading from the variable length symbols.

template <const bool U1, const bool U2, class BRBS>
class RiceSplit16x2Decoder
{
public:
    // Input comes from two different arrays, one contains unary
    // prefix bits and the second array contains remainder bits.
    
    uint32_t prefixBits;
    uint32_t suffixBits;
    
    BitReader<true, BRBS, 24> prefixBitsReader;
    BitReader<true, BRBS, 24> suffixBitsReader;
    
    uint8_t *outputBytePtr;
    int outputByteOffset;
    int outputByteLength;
    
    RiceSplit16x2Decoder()
    : outputBytePtr(nullptr),
    outputByteOffset(-1),
    outputByteLength(-1)
    {
        prefixBitsReader.setBitsPtr(&prefixBits);
        suffixBitsReader.setBitsPtr(&suffixBits);
    }
    
    void refillBits() {
        prefixBitsReader.refillBits();
        suffixBitsReader.refillBits();
    }
    
    // Store refs to input and output byte bufers
    
    void setupInputOutput(const uint8_t * prefixBitBuff, const int prefixBitBuffN,
                          const uint8_t * suffixBitBuff, const int suffixitBuffN,
                          uint8_t * symbolBuff, const int symbolBuffN)
    {
        prefixBitsReader.byteReader.setupInput(prefixBitBuff, prefixBitBuffN);
        suffixBitsReader.byteReader.setupInput(suffixBitBuff, suffixitBuffN);
        
        this->outputBytePtr = symbolBuff;
        this->outputByteOffset = 0;
        this->outputByteLength = symbolBuffN;
        
#if defined(DEBUG)
        uint8_t bVal = prefixBitBuff[0];
        bVal += prefixBitBuff[prefixBitBuffN-1];

        bVal += suffixBitBuff[0];
        bVal += suffixBitBuff[suffixitBuffN-1];
        
        outputBytePtr[0] = bVal;
        outputBytePtr[symbolBuffN-1] = bVal;
#endif // DEBUG
    }
    
    // Decode N symbols from the input stream and write decoded symbols
    // to the output vector. Returns the number of symbols decoded.
    
    int decodeSymbols(const unsigned int k, const int nsymbols) {
        const bool debug = false;
        
        if (debug) {
            printf("k = %d\n", k);
        }
        
        const unsigned int m = (1 << k);
        
        int symboli = 0;
        
        for ( ; symboli < nsymbols ; symboli++ ) {
            unsigned int symbol;
            
            // Refill before reading a symbol
            refillBits();
            
            unsigned int q;
            
            if ((prefixBits >> 16) == 0) {
                // Special case for 16 bits of zeros in high halfword
                q = 0;
                
# if defined(DEBUG)
                assert(prefixBitsReader.bitsInRegister >= 16);
# endif // DEBUG
                prefixBitsReader.bitsInRegister -= 16;
                
                prefixBits <<= 16;
                
                if (debug) {
                    printf("bits (del16): %s\n", get_code_bits_as_string64(prefixBits, 32).c_str());
                }
                
# if defined(DEBUG)
                assert(suffixBitsReader.bitsInRegister >= 8);
# endif // DEBUG
                suffixBitsReader.bitsInRegister -= 8;
                
                symbol = suffixBits >> 24;
                
                if (debug) {
                    printf("symbol      : %s\n", get_code_bits_as_string64(symbol, 32).c_str());
                }
                
                suffixBits <<= 8;
                
                if (debug) {
                    printf("bits (del8) : %s\n", get_code_bits_as_string64(suffixBits, 32).c_str());
                }
            } else {
# if defined(DEBUG)
                assert((prefixBits & 0xFFFF0000) != 0);
# endif // DEBUG
                
                q = __builtin_clz(prefixBits);
                
                symbol = q << k;
                
                if (debug) {
                    printf("q (num leading zeros): %d\n", q);
                }
                
                // Shift left to place MSB of remainder at the MSB of register
                
# if defined(DEBUG)
                assert(prefixBitsReader.bitsInRegister >= (q + 1));
# endif // DEBUG
                prefixBitsReader.bitsInRegister -= (q + 1);
                
                prefixBits <<= (q + 1);
                
                if (debug) {
                    printf("lshift   %2d : %s\n", q, get_code_bits_as_string64(prefixBits, 32).c_str());
                }
                
# if defined(DEBUG)
                assert(suffixBitsReader.bitsInRegister >= k);
# endif // DEBUG
                suffixBitsReader.bitsInRegister -= k;
                
                // Shift right to place LSB of remainder at bit offset 0
                uint32_t rem = (suffixBits >> 16) >> (16 - k);
                
                if (debug) {
                    printf("rem         : %s\n", get_code_bits_as_string64(rem, 32).c_str());
                }
                symbol |= rem;
                
                if (debug) {
                    printf("symbol      : %s\n", get_code_bits_as_string64(symbol, 32).c_str());
                }
                
                suffixBits <<= k;
                
                if (debug) {
                    printf("rem lshift  : %s\n", get_code_bits_as_string64(suffixBits, 32).c_str());
                }
            }
            
            //if (isFinishedReading) {
            //    break;
            //}
            
            if (debug) {
                printf("append decoded symbol = %d\n", symbol);
            }
            
#if defined(DEBUG)
            assert(outputByteOffset < outputByteLength);
#endif // DEBUG
            outputBytePtr[outputByteOffset++] = symbol;
        }
        
        return symboli;
    }
    
    // Decode symbols from a buffer of encoded bytes and
    // return the results as a vector of decoded bytes.
    // This method assumes that the k value is known.
    
    void decode(const uint8_t * prefixBitBuff, const int prefixBitBuffN,
                const uint8_t * suffixBitBuff, const int suffixitBuffN,
                uint8_t * symbolBuff, const int symbolBuffN,
                const unsigned int k)
    {
        setupInputOutput(prefixBitBuff, prefixBitBuffN, suffixBitBuff, suffixitBuffN, symbolBuff, symbolBuffN);
        
        decodeSymbols(k, symbolBuffN);
        
        return;
    }
    
    // Special case decoding method where the k value for a block of values is lookup
    // up in tables. Pass count table which indicates how many blocks the corresponding
    // n table entry corresponds to.
    
    void decode(const uint8_t * prefixBitBuff, const int prefixBitBuffN,
                const uint8_t * suffixBitBuff, const int suffixitBuffN,
                uint8_t * symbolBuff, const int symbolBuffN,
                const uint8_t * kLookupTable,
                int kLookupTableLength,
                const vector<uint32_t> & countTable,
                const vector<uint32_t> & nTable)
    {
        const bool debug = false;
        
        setupInputOutput(prefixBitBuff, prefixBitBuffN, suffixBitBuff, suffixitBuffN, symbolBuff, symbolBuffN);
        
#if defined(DEBUG)
        assert(countTable.size() == nTable.size());
#endif // DEBUG
        
        int symboli = 0;
        int blocki = 0;
        
        const int tableMax = (int) countTable.size();
        for (int tablei = 0; tablei < tableMax; tablei++) {
            // count indicates how many symbols are covered by block k
            
            int numBlockCount = countTable[tablei];
            int numSymbolsPerBlock = nTable[tablei];
            
#if defined(DEBUG)
            assert(numBlockCount > 0);
            assert(numSymbolsPerBlock > 0);
#endif // DEBUG
            
            // The same number of symbols are used for numBlockCount blocks.
            
            int maxBlocki = blocki + numBlockCount;
            
            if (debug) {
                printf("blocki range (%d, %d) numSymbolsPerBlock %d\n", blocki, maxBlocki, numSymbolsPerBlock);
            }
            
            for ( ; blocki < maxBlocki; blocki++ ) {
                int k = kLookupTable[blocki];
                
                int maxSymboli = symboli + numSymbolsPerBlock;
                
                if (debug) {
                    printf("symboli range (%d, %d) k %d\n", symboli, maxSymboli, k);
                }
                
                int numSymbolsDecoded = decodeSymbols(k, numSymbolsPerBlock);
                
#if defined(DEBUG)
                assert(numSymbolsDecoded == numSymbolsPerBlock);
#endif // DEBUG
                
                symboli += numSymbolsDecoded;
            }
        }
        
#if defined(DEBUG)
        assert(blocki == (kLookupTableLength-1));
        assert(symboli == symbolBuffN);
#endif // DEBUG
        
        return;
    }
};

// This optimized split16 decoder will decode only the unary prefix bits that
// have been split into a stream. This unary prefix decode operation basically
// just loads data and then does a CLZ operation for each symbol. The critical
// performance issue with this code is in the execution of clz instructions
// since each one needs the previous one to complete before the next one can
// be executed.

template <const bool U1, const bool U2, class BRBS>
class RiceSplit16x2PrefixDecoder
{
public:
    uint32_t prefixBits;
    
    BitReader<true, BRBS, 16> prefixBitsReader;
    
    uint8_t *outputBytePtr;
    
#if defined(DEBUG)
    int outputByteOffset;
    int outputByteLength;
#endif // DEBUG
    
    RiceSplit16x2PrefixDecoder()
    : outputBytePtr(nullptr)
#if defined(DEBUG)
    ,
    outputByteOffset(-1),
    outputByteLength(-1)
#endif // DEBUG
    {
        prefixBitsReader.setBitsPtr(&prefixBits);
    }
    
    inline
    void refillBits() {
        prefixBitsReader.refillBits();
    }
    
    // Store refs to input and output byte bufers
    
    void setupInputOutput(const uint8_t * prefixBitBuff, const int prefixBitBuffN,
                          uint8_t * symbolBuff, const int symbolBuffN)
    {
        prefixBitsReader.byteReader.setupInput(prefixBitBuff, prefixBitBuffN);
        
        this->outputBytePtr = symbolBuff;
#if defined(DEBUG)
        this->outputByteOffset = 0;
        this->outputByteLength = symbolBuffN;
#endif // DEBUG
        
#if defined(DEBUG)
        uint8_t bVal = prefixBitBuff[0];
        bVal += prefixBitBuff[prefixBitBuffN-1];
        
        outputBytePtr[0] = bVal;
        outputBytePtr[symbolBuffN-1] = bVal;
#endif // DEBUG
    }
    
    inline
    void writeByte(const uint8_t prefixCount) {
        // prefixCount minimum value is 1, it can never be zero.
#if defined(DEBUG)
        assert(prefixCount > 0);
#endif // DEBUG
        
#if defined(DEBUG)
        assert(outputByteOffset < outputByteLength);
        outputBytePtr[outputByteOffset++] = prefixCount;
#else
        *outputBytePtr++ = prefixCount;
#endif // DEBUG
    }
    
    // Decode N symbols from the input stream and write decoded symbols
    // to the output vector. Returns the number of symbols decoded.
    
    int decodeSymbols(const int nsymbols) {
        const bool debug = false;
        
        for ( int symboli = 0; symboli < nsymbols ; symboli++ ) {
            refillBits();
# if defined(DEBUG)
            assert(prefixBitsReader.bitsInRegister >= 16);
# endif // DEBUG

            unsigned int prefixCount;

            if (debug) {
                printf("symboli %5d\n", symboli);
            }
            
            const unsigned int top16 = (prefixBits >> 16);
            
            if (top16 == 0) {
                // Special case for 16 bits of zeros in high halfword
                
# if defined(DEBUG)
                assert(prefixBitsReader.bitsInRegister >= 16);
# endif // DEBUG
                prefixBitsReader.bitsInRegister -= 16;
                
                if (debug) {
                    printf("bits        : %s\n", get_code_bits_as_string64(prefixBits, 32).c_str());
                }
                
                prefixBits <<= 16;
                
                if (debug) {
                    printf("bits (del16): %s\n", get_code_bits_as_string64(prefixBits, 32).c_str());
                }
                
                prefixCount = 17;
            } else {
# if defined(DEBUG)
                assert((prefixBits & 0xFFFF0000) != 0);
# endif // DEBUG
                
                unsigned int q = __builtin_clz(prefixBits);
                
                if (debug) {
                    printf("q (num leading zeros): %d\n", q);
                }
                
# if defined(DEBUG)
                // Valid CLZ+1 range is (1, 16)
                assert(q >= 0 && q <= 15);
# endif // DEBUG
                
                // Shift left to drop prefix bits from left side of register.
                
                prefixCount = q + 1;
                
# if defined(DEBUG)
                assert(prefixBitsReader.bitsInRegister >= prefixCount);
# endif // DEBUG
                prefixBitsReader.bitsInRegister -= prefixCount;
                
                prefixBits <<= prefixCount;
                
                if (debug) {
                    printf("lshift   %2d : %s\n", q, get_code_bits_as_string64(prefixBits, 32).c_str());
                }
            }
            
            if (debug) {
                printf("append prefix count = %d\n", prefixCount);
            }
            
            writeByte(prefixCount);
        }
        
        return nsymbols;
    }
    
    // Decode symbols from a buffer of encoded bytes and
    // return the results as a vector of decoded bytes.
    // This method assumes that the k value is known.
    
    void decode(const uint8_t * prefixBitBuff, const int prefixBitBuffN,
                uint8_t * symbolBuff, const int symbolBuffN)
    {
        setupInputOutput(prefixBitBuff, prefixBitBuffN, symbolBuff, symbolBuffN);
        
        decodeSymbols(symbolBuffN);
        
        return;
    }
};

// Prefix decoder built on top of byte reader interface

template <const bool U1, const bool U2, class BRBS>
class RiceSplit16x2PrefixDecoder64
{
public:
    uint64_t outputBuffer;
    uint8_t *outputBytePtr;
    
#if defined(DEBUG)
    int outputByteOffset;
    int outputByteLength;
#endif // DEBUG
    
    uint32_t prefixBits;
    
    BitReader<true, BRBS, 16> prefixBitsReader;
    
    uint8_t outputBufferOffset;
    
    RiceSplit16x2PrefixDecoder64()
    : outputBytePtr(nullptr),
    outputBuffer(0),
    outputBufferOffset(0)
#if defined(DEBUG)
    ,
    outputByteOffset(-1),
    outputByteLength(-1)
#endif // DEBUG
    {
        prefixBitsReader.setBitsPtr(&prefixBits);
    }
    
    inline
    void refillBits() {
        prefixBitsReader.refillBits();
    }
    
    // Store refs to input and output byte bufers
    
    void setupInputOutput(const uint8_t * prefixBitBuff, const int prefixBitBuffN,
                          uint8_t * symbolBuff, const int symbolBuffN)
    {
        prefixBitsReader.byteReader.setupInput(prefixBitBuff, prefixBitBuffN);
        
        this->outputBytePtr = symbolBuff;
#if defined(DEBUG)
        this->outputByteOffset = 0;
        this->outputByteLength = symbolBuffN;
#endif // DEBUG
        
#if defined(DEBUG)
        uint8_t bVal = prefixBitBuff[0];
        bVal += prefixBitBuff[prefixBitBuffN-1];
        
        outputBytePtr[0] = bVal;
        outputBytePtr[symbolBuffN-1] = bVal;
#endif // DEBUG
    }
    
    inline
    void writeByte(const uint8_t prefixCount) {
        const bool debug = false;
        
        if (debug) {
            printf("append prefix count = %d\n", prefixCount);
        }
        
        // prefixCount minimum value is 1, it can never be zero.
#if defined(DEBUG)
        assert(prefixCount > 0);
#endif // DEBUG
        
#if defined(DEBUG)
        assert(outputByteOffset < outputByteLength);
        outputBytePtr[outputByteOffset++] = prefixCount;
#else
        // Write byte to outputBuffer, unless it is already full
        
        if (debug) {
            printf("outputBuffer %s\n", get_code_bits_as_string64(outputBuffer, 64).c_str());
        }
        
        if (outputBufferOffset == 8) {
            #pragma unroll(8)
            for ( int i = 0; i < 8; i++ ) {
                uint8_t bVal = (outputBuffer >> (i * 8)) & 0xFF;
                *outputBytePtr++ = bVal;
            }
            outputBuffer = prefixCount;
            outputBufferOffset = 1;
        } else {
            // Append to next open slot
            
            if (debug) {
                printf("append to next open slot\n");
            }
            
            uint64_t prefixCount64 = prefixCount;
            outputBuffer |= (prefixCount64 << (outputBufferOffset * 8));
            outputBufferOffset += 1;
        }
#endif // DEBUG
    }
    
    inline
    void flushBufferedBytes() {
        for ( int i = 0; i < 8; i++ ) {
            uint8_t bVal = (outputBuffer >> (i * 8)) & 0xFF;
            if (bVal == 0) {
                break;
            }
            *outputBytePtr++ = bVal;
        }
    }
    
    // Decode N symbols from the input stream and write decoded symbols
    // to the output vector. Returns the number of symbols decoded.
    
    int decodeSymbols(const int nsymbols) {
        const bool debug = false;
        
        for ( int symboli = 0; symboli < nsymbols ; symboli++ ) {
            refillBits();
# if defined(DEBUG)
            assert(prefixBitsReader.bitsInRegister >= 16);
# endif // DEBUG
            
            unsigned int prefixCount;
            
            if (debug) {
                printf("symboli %5d\n", symboli);
            }
            
            const unsigned int top16 = (prefixBits >> 16);
            
            if (top16 == 0) {
                // Special case for 16 bits of zeros in high halfword
                
# if defined(DEBUG)
                assert(prefixBitsReader.bitsInRegister >= 16);
# endif // DEBUG
                prefixBitsReader.bitsInRegister -= 16;
                
                if (debug) {
                    printf("bits        : %s\n", get_code_bits_as_string64(prefixBits, 32).c_str());
                }
                
                prefixBits <<= 16;
                
                if (debug) {
                    printf("bits (del16): %s\n", get_code_bits_as_string64(prefixBits, 32).c_str());
                }
                
                prefixCount = 17;
            } else {
# if defined(DEBUG)
                assert((prefixBits & 0xFFFF0000) != 0);
# endif // DEBUG
                
                unsigned int q = __builtin_clz(prefixBits);
                
                if (debug) {
                    printf("q (num leading zeros): %d\n", q);
                }

# if defined(DEBUG)
                assert(q < 16);
# endif // DEBUG
                
                // Shift left to drop prefix bits from left side of register.
                
                prefixCount = q + 1;
                
# if defined(DEBUG)
                assert(prefixCount < 17);
# endif // DEBUG
                
# if defined(DEBUG)
                assert(prefixBitsReader.bitsInRegister >= prefixCount);
# endif // DEBUG
                prefixBitsReader.bitsInRegister -= prefixCount;
                
                prefixBits <<= prefixCount;
                
                if (debug) {
                    printf("lshift   %2d : %s\n", prefixCount, get_code_bits_as_string64(prefixBits, 32).c_str());
                }
            }
            
            if (debug) {
                printf("append prefix count = %d\n", prefixCount);
            }
            
            writeByte(prefixCount);
        }
        
        flushBufferedBytes();
        
        return nsymbols;
    }
    
    // Decode symbols from a buffer of encoded bytes and
    // return the results as a vector of decoded bytes.
    // This method assumes that the k value is known.
    
    void decode(const uint8_t * prefixBitBuff, const int prefixBitBuffN,
                uint8_t * symbolBuff, const int symbolBuffN)
    {
        setupInputOutput(prefixBitBuff, prefixBitBuffN, symbolBuff, symbolBuffN);
        
        decodeSymbols(symbolBuffN);
        
        return;
    }
};

#import "byte_bit_stream64.hpp"

// This split prefix decoder works on top of 64 bit read API.
// A decode invocation will read bits into a register and
// decode a prefix symbol. Note that this implementation
// assumes zero bits for the fill and a 1 bit to mark the
// end of a prefix encoding. While the input comes from
// a uint64_t the output is always written as a simple byte
// since this proves to be the fastest implementaiton.

template <class BRBS>
class RiceSplit16x2PrefixDecoder64Read64
{
public:
    uint8_t *outputBytePtr;
    
    BitReader64<BRBS, 16> prefixBitsReader;
    
    RiceSplit16x2PrefixDecoder64Read64()
    : outputBytePtr(nullptr)
    {
    }
    
    inline
    void refillBits() {
        prefixBitsReader.refillBits();
    }
    
    // Define the output location where symbols will be written to
    
    void setupOutput(uint8_t * symbolBuff)
    {
        this->outputBytePtr = symbolBuff;
    }
    
    inline
    void writeByte(const uint8_t prefixCount) {
        const bool debug = false;
        
        if (debug) {
            printf("append prefix count = %d\n", prefixCount);
        }
        
        // prefixCount minimum value is 1, it can never be zero.
#if defined(DEBUG)
        assert(prefixCount > 0);
#endif // DEBUG
        
        *outputBytePtr++ = prefixCount;
    }
    
    // Decode N symbols from the input stream and write decoded symbols
    // to the output vector. Returns the number of symbols decoded.
    
    int decodeSymbols(const uint64_t nsymbols) {
        const bool debug = false;
        
        for ( uint64_t symboli = 0; symboli < nsymbols ; symboli++ ) {
            refillBits();
# if defined(DEBUG)
            assert(prefixBitsReader.numBits1 >= 16);
# endif // DEBUG
            
            uint64_t prefixCount;
            
            if (debug) {
                printf("symboli %5d\n", (int)symboli);
            }
            
            if ((prefixBitsReader.bits1 >> 32 >> 16) == 0) {
                // Special case for 16 bits of zeros in high halfword
                
# if defined(DEBUG)
                assert(prefixBitsReader.numBits1 >= 16);
# endif // DEBUG
                prefixBitsReader.numBits1 -= 16;
                
                if (debug) {
                    printf("bits        : %s\n", get_code_bits_as_string64(prefixBitsReader.bits1, 64).c_str());
                }
                
                prefixBitsReader.bits1 <<= 16;
                
                if (debug) {
                    printf("bits (del16): %s\n", get_code_bits_as_string64(prefixBitsReader.bits1, 64).c_str());
                }
                
                prefixCount = 17;
            } else {
# if defined(DEBUG)
                assert((prefixBitsReader.bits1 >> 32 >> 16) != 0);
# endif // DEBUG
                
                uint64_t q = __clz(prefixBitsReader.bits1);
                
                if (debug) {
                    printf("q (num leading zeros): %d\n", (int)q);
                }
                
# if defined(DEBUG)
                assert(q < 16);
# endif // DEBUG
                
                // Shift left to drop prefix bits from left side of register.
                
                prefixCount = q + 1;
                
# if defined(DEBUG)
                assert(prefixCount < 17);
# endif // DEBUG
                
# if defined(DEBUG)
                assert(prefixBitsReader.numBits1 >= prefixCount);
# endif // DEBUG
                prefixBitsReader.numBits1 -= prefixCount;
                
                prefixBitsReader.bits1 <<= prefixCount;
                
                if (debug) {
                    printf("lshift   %2d : %s\n", (int)prefixCount, get_code_bits_as_string64(prefixBitsReader.bits1, 64).c_str());
                }
            }
            
            if (debug) {
                printf("append prefix count = %d\n", (int)prefixCount);
            }
            
            writeByte((uint8_t) prefixCount);
        }
        
        return (int) nsymbols;
    }
    
};

// Generate a num symbols per block lookup table for a given
// number of block vecs as a fixed block size.

static inline
vector<uint32_t> MakeFixedKBlockTable(const vector<uint8_t> & kBlockVec,
                                      const int blockSize)
{
    // Sub 1 to ignore padding byte at end of kBlockVec
    int nBlocks = (int)kBlockVec.size() - 1;
    vector<uint32_t> table(nBlocks);
    
    for (int i = 0; i < nBlocks; i++) {
        table[i] = blockSize;
    }
    
    return table;
}

// Rewrite prefix bits as 64 bit values after padding to 8 byte bound

static inline
vector<uint8_t> PrefixBitStreamRewrite64(const vector<uint8_t> & prefixBits)
{
    const bool debug = false;
    
    // Pad until a whole 64 bit read would read until the end of the vector
    
    vector<uint8_t> result = prefixBits;
    
    while (1) {
        uint32_t numBytes = (uint32_t) result.size();
        if ((numBytes % sizeof(uint64_t)) == 0) {
            break;
        }
        result.push_back(0);
    }
    
    // Output has been padded to a whole 64 bit value, now add one more
    // padding 64 bit value to take care of reading ahead by 1.
    
    for (int i = 0; i < sizeof(uint64_t); i++) {
        result.push_back(0);
    }
    
    int numBytes = (int) result.size();
    
    // Output from prefix stage must be in terms of whole dwords
    
    if ((numBytes % sizeof(uint64_t)) != 0) {
        assert(0);
    }
    
    uint64_t *ptr64 = (uint64_t *) result.data();
    
    // Now read each set of 8 bytes into a uint64_t and store
    // with a single write so that when read with uint64_t
    // little endian reads the bytes are in the proper order.
    
    int numDWords = numBytes / sizeof(uint64_t);
    
    for (int i = 0; i < numDWords; i++) {
        uint8_t buffer[8];
        memcpy(&buffer[0], ptr64, sizeof(buffer));
        
        if (debug) {
            for (int i = 0; i < 8; i++) {
                printf("buffer[%3d] = %3d\n", i, buffer[i]);
            }
        }
        
        // Reverse the byte order in memory
        swap(buffer[0], buffer[7]);
        swap(buffer[1], buffer[6]);
        swap(buffer[2], buffer[5]);
        swap(buffer[3], buffer[4]);
        
        // Write 64 bit number so that it is read in big endian form
        // by the native little endian 64 bit read.
        
        if (debug) {
            printf("--------\n");
            
            for (int i = 0; i < 8; i++) {
                printf("buffer[%3d] = %3d\n", i, buffer[i]);
            }
        }
        
        uint64_t val;
        assert(sizeof(uint64_t) == sizeof(buffer));
        memcpy(&val, &buffer[0], sizeof(val));
        *ptr64++ = val;
    }
    
    return result;
}

// Rewrite prefix bits as 32 bit values after padding to 4 byte bound

static inline
vector<uint8_t> PrefixBitStreamRewrite32(const vector<uint8_t> & prefixBits)
{
  const bool debug = false;
  
  // Pad until a whole 64 bit read would read until the end of the vector
  
  vector<uint8_t> result = prefixBits;
  
  while (1) {
    uint32_t numBytes = (uint32_t) result.size();
    if ((numBytes % sizeof(uint32_t)) == 0) {
      break;
    }
    result.push_back(0);
  }
  
  // Output has been padded to a whole 32 bit values, now add one more
  // padding 32 bit value to take care of reading ahead by 1 word.
  
  for (int i = 0; i < sizeof(uint32_t); i++) {
    result.push_back(0);
  }
  
  int numBytes = (int) result.size();
  
  // Output from prefix stage must be in terms of whole dwords
  
  if ((numBytes % sizeof(uint32_t)) != 0) {
    assert(0);
  }
  
  uint32_t *ptr32 = (uint32_t *) result.data();
  
  // Now read each set of 4 bytes into a uint32_t and store
  // with a single write so that when read with uint32_t
  // little endian reads the bytes are in the proper order.
  
  int numWords = numBytes / sizeof(uint32_t);
  
  for (int i = 0; i < numWords; i++) {
    uint8_t buffer[4];
    memcpy(&buffer[0], ptr32, sizeof(buffer));
    
    if (debug) {
      for (int i = 0; i < sizeof(uint32_t); i++) {
        printf("buffer[%3d] = %3d\n", i, buffer[i]);
      }
    }
    
    // Reverse the byte order in memory

    swap(buffer[0], buffer[3]);
    swap(buffer[1], buffer[2]);
    
    // Write 64 bit number so that it is read in big endian form
    // by the native little endian 64 bit read.
    
    if (debug) {
      printf("--------\n");
      
      for (int i = 0; i < sizeof(uint32_t); i++) {
        printf("buffer[%3d] = %3d\n", i, buffer[i]);
      }
    }
    
    uint32_t val;
    assert(sizeof(uint32_t) == sizeof(buffer));
    memcpy(&val, &buffer[0], sizeof(val));
    *ptr32++ = val;
  }
  
  return result;
}

// Encode N byte streams as prefix only encoded bits written
// as 64 bit LE streams. Returns a vector of split prefix bit
// streams.

static inline
void SplitPrefix64Encoding(const vector<vector<uint8_t> > & vecOfVecs,
                         const vector<uint8_t> & kBlockVec,
                         const unsigned int numSymbolsInKBlock,
                         vector<vector<uint8_t> > & prefixVecOfVecs,
                         vector<vector<uint8_t> > & suffixVecOfVecs)
{
    prefixVecOfVecs.clear();
    suffixVecOfVecs.clear();
    
//    // Output destination for byte writes from N input streams
//    vector<uint8_t> bytes;
    
    int numStreams = (int) vecOfVecs.size();
    int numSymbols = -1;
    
    // All vectors must be the same length
    
    for ( const vector<uint8_t> & vec : vecOfVecs ) {
        if (numSymbols != -1) {
            assert(numSymbols == (int)vec.size());
        } else {
            numSymbols = (int)vec.size();
        }
    }
    
    const int numKBlockEachStream = numSymbols / numSymbolsInKBlock;
#if defined(DEBUG)
    assert((numSymbols % numSymbolsInKBlock) == 0);
#endif // DEBUG
    
    // Encode vector of bytes using split encoding so that prefix
    // and suffix bytes are split into different streams.
    
    vector<RiceSplit16x2Encoder<false, true, BitWriterByteStream> > encoderVec;
    
    encoderVec.resize(numStreams);
    
    int blocki = 0;
    int numSymbolsi = 0;
    
    // Vector of the k values for each input stream
    vector<vector<uint8_t> > decoderKVecOfVecs;
    // The number of symbols in each block
    //vector<uint32_t> decoderNumSymbolsVecs;
    
    for (int encoderi = 0; encoderi < encoderVec.size(); encoderi++ ) {
        auto & encoder = encoderVec[encoderi];
        
        // Encode all symbols in this stream, note that each block
        // can have a different k value. and that a table is constructed
        // and passed to encode this entire input stream with a
        // set of k values.
        
        const vector<uint8_t> & inByteVec = vecOfVecs[encoderi];
        
#if defined(DEBUG)
        int blockiStart = blocki;
#endif // DEBUG
        
        vector<uint8_t> encodeKTable(numKBlockEachStream+1);
        
        for (int i = 0; i < numKBlockEachStream; i++) {
#if defined(DEBUG)
            int maxSizeWoPadding = (int)kBlockVec.size() - 1;
            assert(blocki < maxSizeWoPadding);
            assert(i < encodeKTable.size());
#endif // DEBUG
            encodeKTable[i] = kBlockVec[blocki++];
        }
        
        encodeKTable[numKBlockEachStream] = 0;
        
#if defined(DEBUG)
        if ((0)) {
            printf("for unmux input blocki range (%d, %d), k lookup table is:\n", blockiStart, blocki);
            
            for (int i = 0; i < (int)encodeKTable.size(); i++ ) {
                uint8_t k = encodeKTable[i];
                printf("encodeKTable[%3d] = %3d\n", i, k);
            }
        }
#endif // DEBUG
        
        decoderKVecOfVecs.push_back(encodeKTable);
        //decoderNumSymbolsVecs.push_back(numSymbolsInKBlock);
        
        vector<uint32_t> countTable(1);
        vector<uint32_t> nTable(1);
        
        // Number of blocks in the input, corresponds to encodeKTable.size()-1
        countTable[0] = numKBlockEachStream;
        // Num symbols per block
        nTable[0] = numSymbolsInKBlock;
        
        encoder.encode(inByteVec.data(), (int)inByteVec.size(),
                       encodeKTable.data(), (int)encodeKTable.size(),
                       countTable,
                       nTable
                       );
        
        if ((0)) {
            for (int i = 0; i < (int)inByteVec.size(); i++ ) {
                uint8_t symbol = inByteVec[i];
                printf("encoded symbol %3d with encoder for stream %d\n", symbol, encoderi);
            }
        }
    }
    
    // Collect rice prefix and suffix output into different result vectors
    
//    vector<vector<uint8_t> > vecOfRiceVecs;
    
    for ( auto & encoder : encoderVec ) {
        //auto vec = encoder.bitWriter.moveBytes();
        //vecOfRiceVecs.push_back(vec);
        
        auto prefixBitsByteVec = encoder.prefixBitWriter.moveBytes();
        
        auto prefixBitsByteVec64 = PrefixBitStreamRewrite64(prefixBitsByteVec);
        
        prefixVecOfVecs.push_back(std::move(prefixBitsByteVec64));
        
        // Suffix bits
        
        auto suffixBitsByteVec = encoder.remBitWriter.moveBytes();
        
        suffixVecOfVecs.push_back(std::move(suffixBitsByteVec));
    }
    
    /*
    
    // Setup decoding from vector of encoded streams. Each time a byte
    // is read from one of the vector of encoded streams that byte
    // is emitted to a multiplexed stream of bytes.
    
    // Configure RiceSplit16Decoder for each stream
    
    vector<RiceSplit16Decoder<false, true, BitReaderByteStreamMultiplexer> > decoderVec;
    decoderVec.resize(numStreams);
    
    vector<vector<uint8_t> > vecOfDecodeVecs;
    vecOfDecodeVecs.resize(numStreams);
    
    {
        for (int decoderi = 0; decoderi < numStreams; decoderi++) {
            auto & decoder = decoderVec[decoderi];
            
            decoder.bitsReader.byteReader.setBytesPtr(&bytes);
            
            auto & riceVec = vecOfRiceVecs[decoderi];
            
            auto & decodeVec = vecOfDecodeVecs[decoderi];
            decodeVec.resize(numSymbols);
            
            decoder.setupInputOutput(riceVec.data(), (int)riceVec.size(),
                                     decodeVec.data(), (int)decodeVec.size());
        }
    }
    
    // Decode one symbols at a time with each decoder, this will
    // pull byte values from N streams as the decoding operation
    // progresses. Each time a byte value is pulled from the
    // N input rice streams it gets appended to the mux stream.
    
    for (int symboli = 0; symboli < numSymbols; symboli++) {
        for (int decoderi = 0; decoderi < numStreams; decoderi++) {
            // Get decoder for next stream
            auto & decoder = decoderVec[decoderi];
            
            // Lookup k for corresponding input block
            vector<uint8_t> & kVec = decoderKVecOfVecs[decoderi];
            // FIXME: divide op is not fast!
            int blockiBasedOnSymboli;
            if (numSymbolsInKBlock == 64) {
                blockiBasedOnSymboli = symboli / 64;
            } else {
                blockiBasedOnSymboli = symboli / numSymbolsInKBlock;
            }
            int k = kVec[blockiBasedOnSymboli];
            
#if defined(DEBUG)
            if ((0)) {
                printf("decoder %3d contains %d bits in register\n", decoderi, decoder.bitsReader.bitsInRegister);
            }
            
            int numSymbolsDecoded = decoder.decodeSymbols(k, 1);
            
            assert(numSymbolsDecoded == 1);
            
            auto & decodeVec = vecOfDecodeVecs[decoderi];
            
            int symbol = decodeVec[symboli];
            
            if ((0)) {
                printf("decoded symbol %3d for stream %d\n", symbol, decoderi);
            }
            
            // Compre decoded symbol to original
            
            const vector<uint8_t> & origByteVec = vecOfVecs[decoderi];
            
            int origSymbol = origByteVec[symboli];
            
            if ((0)) {
                printf("original symbol %3d for stream %d\n", origSymbol, decoderi);
            }
            
            assert(symbol == origSymbol);
#else
            decoder.decodeSymbols(k, 1);
#endif // DEBUG
        }
    }
    
    return bytes;
     
    */
}

// Multiplexer rice16 encoder, encode N byte streams
// so that reads return needed bytes for each stream.
// The kBlockVec argument is a table of k values
// arranged so that each set of N entries corresponds
// to N streams. The number of symbols indicated in
// numSymbolsInKBlockVec corresponds to the block size
// in each multiplexed stream where N blocks in a row
// indicate the k value for each block in a given stream.
// Note that for best performance, the numSymbolsInKBlock
// argument should be a POT, each block must contain the
// exact same number of symbols.

static inline
vector<uint8_t> ByteStreamMultiplexer(const vector<vector<uint8_t> > & vecOfVecs,
                                      const vector<uint8_t> & kBlockVec,
                                      const unsigned int numSymbolsInKBlock)
{
    // Output destination for byte writes from N input streams
    vector<uint8_t> bytes;
    
    int numStreams = (int) vecOfVecs.size();
    int numSymbols = -1;
    
    // All vectors must be the same length
    
    for ( const vector<uint8_t> & vec : vecOfVecs ) {
        if (numSymbols != -1) {
            assert(numSymbols == (int)vec.size());
        } else {
            numSymbols = (int)vec.size();
        }
    }

    const int numKBlockEachStream = numSymbols / numSymbolsInKBlock;
#if defined(DEBUG)
    assert((numSymbols % numSymbolsInKBlock) == 0);
#endif // DEBUG
    
    // Encode a vector of symbols using standard split16 method
    
    vector<RiceSplit16Encoder<false, true, BitWriterByteStream> > encoderVec;
    
    encoderVec.resize(numStreams);
    
    int blocki = 0;
    int numSymbolsi = 0;
    
    // Vector of the k values for each input stream
    vector<vector<uint8_t> > decoderKVecOfVecs;
    // The number of symbols in each block
    //vector<uint32_t> decoderNumSymbolsVecs;
    
    for (int encoderi = 0; encoderi < encoderVec.size(); encoderi++ ) {
        auto & encoder = encoderVec[encoderi];
        
        // Encode all symbols in this stream, note that each block
        // can have a different k value. and that a table is constructed
        // and passed to encode this entire input stream with a
        // set of k values.
        
        const vector<uint8_t> & inByteVec = vecOfVecs[encoderi];
        
#if defined(DEBUG)
        int blockiStart = blocki;
#endif // DEBUG
        
        vector<uint8_t> encodeKTable(numKBlockEachStream+1);
        
        for (int i = 0; i < numKBlockEachStream; i++) {
#if defined(DEBUG)
            int maxSizeWoPadding = (int)kBlockVec.size() - 1;
            assert(blocki < maxSizeWoPadding);
            assert(i < encodeKTable.size());
#endif // DEBUG
            encodeKTable[i] = kBlockVec[blocki++];
        }
        
        encodeKTable[numKBlockEachStream] = 0;
        
#if defined(DEBUG)
        if ((0)) {
            printf("for unmux input blocki range (%d, %d), k lookup table is:\n", blockiStart, blocki);
            
            for (int i = 0; i < (int)encodeKTable.size(); i++ ) {
                uint8_t k = encodeKTable[i];
                printf("encodeKTable[%3d] = %3d\n", i, k);
            }
        }
#endif // DEBUG
        
        decoderKVecOfVecs.push_back(encodeKTable);
        //decoderNumSymbolsVecs.push_back(numSymbolsInKBlock);
        
        vector<uint32_t> countTable(1);
        vector<uint32_t> nTable(1);
        
        // Number of blocks in the input, corresponds to encodeKTable.size()-1
        countTable[0] = numKBlockEachStream;
        // Num symbols per block
        nTable[0] = numSymbolsInKBlock;

        encoder.encode(inByteVec.data(), (int)inByteVec.size(),
                       encodeKTable.data(), (int)encodeKTable.size(),
                       countTable,
                       nTable
                       );
        
        if ((0)) {
            for (int i = 0; i < (int)inByteVec.size(); i++ ) {
                uint8_t symbol = inByteVec[i];
                printf("encoded symbol %3d with encoder for stream %d\n", symbol, encoderi);
            }
        }
    }

    // Collect each rice encoded stream into a vector
    
    vector<vector<uint8_t> > vecOfRiceVecs;

    for ( auto & encoder : encoderVec ) {
        auto vec = encoder.bitWriter.moveBytes();
        vecOfRiceVecs.push_back(vec);
    }

    // Setup decoding from vector of encoded streams. Each time a byte
    // is read from one of the vector of encoded streams that byte
    // is emitted to a multiplexed stream of bytes.
    
    // Configure RiceSplit16Decoder for each stream
    
    vector<RiceSplit16Decoder<false, true, BitReaderByteStreamMultiplexer> > decoderVec;
    decoderVec.resize(numStreams);
    
    vector<vector<uint8_t> > vecOfDecodeVecs;
    vecOfDecodeVecs.resize(numStreams);
    
    {
        for (int decoderi = 0; decoderi < numStreams; decoderi++) {
            auto & decoder = decoderVec[decoderi];

            decoder.bitsReader.byteReader.setBytesPtr(&bytes);
            
            auto & riceVec = vecOfRiceVecs[decoderi];
            
            auto & decodeVec = vecOfDecodeVecs[decoderi];
            decodeVec.resize(numSymbols);
            
            decoder.setupInputOutput(riceVec.data(), (int)riceVec.size(),
                                     decodeVec.data(), (int)decodeVec.size());
        }
    }

    // Decode one symbols at a time with each decoder, this will
    // pull byte values from N streams as the decoding operation
    // progresses. Each time a byte value is pulled from the
    // N input rice streams it gets appended to the mux stream.
    
    for (int symboli = 0; symboli < numSymbols; symboli++) {
        for (int decoderi = 0; decoderi < numStreams; decoderi++) {
            // Get decoder for next stream
            auto & decoder = decoderVec[decoderi];
            
            // Lookup k for corresponding input block
            vector<uint8_t> & kVec = decoderKVecOfVecs[decoderi];
            // FIXME: divide op is not fast!
            int blockiBasedOnSymboli;
            if (numSymbolsInKBlock == 64) {
                blockiBasedOnSymboli = symboli / 64;
            } else {
                blockiBasedOnSymboli = symboli / numSymbolsInKBlock;
            }
            int k = kVec[blockiBasedOnSymboli];
            
#if defined(DEBUG)
            if ((0)) {
                printf("decoder %3d contains %d bits in register\n", decoderi, decoder.bitsReader.bitsInRegister);
            }
            
            int numSymbolsDecoded = decoder.decodeSymbols(k, 1);
            
            assert(numSymbolsDecoded == 1);
            
            auto & decodeVec = vecOfDecodeVecs[decoderi];
            
            int symbol = decodeVec[symboli];
            
            if ((0)) {
                printf("decoded symbol %3d for stream %d\n", symbol, decoderi);
            }
            
            // Compre decoded symbol to original
            
            const vector<uint8_t> & origByteVec = vecOfVecs[decoderi];
            
            int origSymbol = origByteVec[symboli];
            
            if ((0)) {
                printf("original symbol %3d for stream %d\n", origSymbol, decoderi);
            }
            
            assert(symbol == origSymbol);
#else
            decoder.decodeSymbols(k, 1);
#endif // DEBUG
        }
    }
    
    return bytes;
}

// Given a multiplexed stream and N indicating the number of decoders
// that will decode symbols from this stream, decode and copy
// symbols to the indicated output buffer. The outputValues
// array is known to be of size (N * N) so that each decoded
// symbol is read and written into the matrix column by column.
// This decoder requires that the number of symbols in each
// block of decoded data is constant.

static inline
void ByteStreamDemultiplexer(const unsigned int numSymbolsToDecode,
                             const unsigned int numStreams,
                             const uint8_t * inputStream,
                             const int inputStreamNumBytes,
                             uint8_t * outputValues,
                             const vector<uint8_t> & kBlockVec,
                             const unsigned int numSymbolsPerBlock)
{
    // A single BitReaderByteStream object holds the decode
    // state for the input multiplexed bytes. A decoder
    // object pulls the next byte as needed during decoding.
    
    BitReaderByteStream brbs;
    
    brbs.setupInput(inputStream, inputStreamNumBytes);
    
    // Configure RiceSplit16Decoder for each stream
    
    vector<RiceSplit16Decoder<false, true, BitReaderByteStreamDemultiplexer> > decoderVec;
    
    decoderVec.resize(numStreams);
    
    {
        for ( int decoderi = 0; decoderi < numStreams; decoderi++ ) {
            auto & decoder = decoderVec[decoderi];
        
            decoder.bitsReader.byteReader.setBitReaderPtr(&brbs);
            
            uint8_t *outputPtr = &outputValues[decoderi * numSymbolsToDecode];
            
            decoder.setupInputOutput(nullptr, -1,
                                     outputPtr, numSymbolsToDecode);
        }
    }
    
    // Create a lookup table to map each symbol in a block to the
    // k value for that block. This logic only looks up a k
    // value during the first symbol of a block.
    
    unsigned int numSymbolsLeftInBlock = 0;
    
    // This table is used to lookup k based on the decoderi
    // and the blocki in the stream.
    
    const int numSymbolsEachStream = numSymbolsToDecode / numSymbolsPerBlock;
    
    vector<uint8_t> kLookup(numStreams);
//    uint8_t kLookup[numStreams];
    
    // Decode each symbol in each stream. This is the memory and CPU
    // intensive portion of the decoding operation.
    
    int blocki = 0;
    
    for ( int symboli = 0; symboli < numSymbolsToDecode; symboli++ ) {
        if (numSymbolsLeftInBlock == 0) {
            for ( int decoderi = 0; decoderi < numStreams; decoderi++ ) {
                int offset = (decoderi * numSymbolsEachStream) + blocki;
#if defined(DEBUG)
                assert(decoderi < numStreams);
                assert(offset < (kBlockVec.size()-1));
#endif // DEBUG
                kLookup[decoderi] = kBlockVec[offset];
            }
            
            numSymbolsLeftInBlock = numSymbolsPerBlock;
            blocki += 1;
        }
        
        for ( int decoderi = 0; decoderi < numStreams; decoderi++ ) {
            // For each stream, decode 1 symbol. This logic
            // loads multiplexed bytes from the combined
            // stream as needed for different streams.
            
            int k = kLookup[decoderi];
            
            auto & decoder = decoderVec[decoderi];
            
#if defined(DEBUG)
            int numSymbols = decoder.decodeSymbols(k, 1);
            
            assert(numSymbols == 1);
            
            uint8_t *outputPtr = &outputValues[decoderi * numSymbolsToDecode];
            
            int symbol = outputPtr[symboli];
            
            if ((0)) {
                printf("decoded symbol %3d with decoder for stream %d and k %d\n", symbol, decoderi, k);
            }
#else
            decoder.decodeSymbols(k, 1);
#endif // DEBUG
        }
        
        numSymbolsLeftInBlock -= 1;
    }
    
    return;
}

// 4x decoder implementation where a vector of bit reader objects
// are passed in and the decoding loop approach pulls 64 bit
// word values based on decoding multiple symbols at the same time.

template<class BRBS>
void reader_process_zero16_or_regular(
                                      uint8_t* & outBytes, // ref to pointer
                                      BitReader64<BRBS, 16> & reader)
{
    const bool debug = false;
    
    if ((reader.bits1 >> (32+16)) == (uint64_t)0) {
        // Special case for 16 bits of zeros in high halfword
        
# if defined(DEBUG)
        assert(reader.numBits1 >= 16);
# endif // DEBUG
        reader.numBits1 -= (uint64_t)16;
        
        if (debug) {
            printf("bits        : %s\n", get_code_bits_as_string64(reader.numBits1, 64).c_str());
        }
        
        reader.bits1 <<= 16;
        
        if (debug) {
            printf("bits (del16): %s\n", get_code_bits_as_string64(reader.bits1, 64).c_str());
        }
        
        *outBytes++ = (uint64_t)17;
    } else {
# if defined(DEBUG)
        const uint16_t top16 = (reader.bits1 >> (32+16));
        assert(top16 != 0);
# endif // DEBUG
        
        uint64_t q = __clz(reader.bits1);
        
        if (debug) {
            printf("q (num leading zeros): %d\n", (int)q);
        }
        
        // Shift left to drop prefix bits from left side of register.
        
        uint64_t prefixCount = q + (uint64_t)1;
        
# if defined(DEBUG)
        assert(reader.numBits1 >= prefixCount);
# endif // DEBUG
        reader.numBits1 -= prefixCount;
        
        reader.bits1 <<= prefixCount;
        
        if (debug) {
            printf("lshift   %2d : %s\n", (int)prefixCount, get_code_bits_as_string64(reader.bits1, 64).c_str());
        }
        
        *outBytes++ = prefixCount;
    }
    
    return;
}

template <class T>
void stream_part_process_zero16_or_regular(
                                      uint8_t* & outBytes, // ref to pointer
                                      T & sp)
{
    const bool debug = false;
    
    if ((sp.bits >> (32+16)) == (uint64_t)0) {
        // Special case for 16 bits of zeros in high halfword
        
# if defined(DEBUG)
        assert(sp.numBits >= 16);
# endif // DEBUG
        sp.numBits -= (uint64_t)16;
        
        if (debug) {
            printf("bits        : %s\n", get_code_bits_as_string64(sp.numBits, 64).c_str());
        }
        
        sp.bits <<= 16;
        
        if (debug) {
            printf("bits (del16): %s\n", get_code_bits_as_string64(sp.bits, 64).c_str());
        }
        
        *outBytes++ = (uint64_t)17;
    } else {
# if defined(DEBUG)
        const uint16_t top16 = (sp.bits >> (32+16));
        assert(top16 != 0);
# endif // DEBUG
        
        uint64_t q = __clz(sp.bits);
        
        if (debug) {
            printf("q (num leading zeros): %d\n", (int)q);
        }
        
        // Shift left to drop prefix bits from left side of register.
        
        uint64_t prefixCount = q + (uint64_t)1;
        
# if defined(DEBUG)
        assert(sp.numBits >= prefixCount);
# endif // DEBUG
        sp.numBits -= prefixCount;
        
        sp.bits <<= prefixCount;
        
        if (debug) {
            printf("lshift   %2d : %s\n", (int)prefixCount, get_code_bits_as_string64(sp.bits, 64).c_str());
        }
        
        *outBytes++ = prefixCount;
    }
    
    return;
}

template<class BRBS>
void rice_decode_prefix_bits_4x_both_interleaved_readers(
                                                         vector<BitReader64<BRBS, 16> > & readers,
                                                         uint64_t numSymbolsToDecode,
                                                         uint8_t *outBytes)
{
#pragma unroll(1)
    for ( ; numSymbolsToDecode != 0 ; ) {
        
        //dual_dword_refill_lt16(inBytesLE64, s1PrefixBits1, s1PrefixBits2, s1PrefixNumBits1, s1PrefixNumBits2);
        //dual_dword_refill_lt16(inBytesLE64, s2PrefixBits1, s2PrefixBits2, s2PrefixNumBits1, s2PrefixNumBits2);
        //dual_dword_refill_lt16(inBytesLE64, s3PrefixBits1, s3PrefixBits2, s3PrefixNumBits1, s3PrefixNumBits2);
        //dual_dword_refill_lt16(inBytesLE64, s4PrefixBits1, s4PrefixBits2, s4PrefixNumBits1, s4PrefixNumBits2);
        
        readers[0].refillBits();
        readers[1].refillBits();
        readers[2].refillBits();
        readers[3].refillBits();
        
        // Process special case of 16 zero bits or the next symbol for each stream.
        
        reader_process_zero16_or_regular(outBytes, readers[0]);
        reader_process_zero16_or_regular(outBytes, readers[1]);
        reader_process_zero16_or_regular(outBytes, readers[2]);
        reader_process_zero16_or_regular(outBytes, readers[3]);
        
        numSymbolsToDecode -= 1;
        
        // Combined loop that decodes 1 symbol from each stream
        
#pragma unroll(1)
        while (((readers[0].bits1 >> (32+16)) != (uint64_t)0) &&
               ((readers[1].bits1 >> (32+16)) != (uint64_t)0) &&
               ((readers[2].bits1 >> (32+16)) != (uint64_t)0) &&
               ((readers[3].bits1 >> (32+16)) != (uint64_t)0)) {
# if defined(DEBUG)
            {
                const uint16_t top16 = (readers[0].bits1 >> (32+16));
                assert(top16 != 0);
            }
            {
                const uint16_t top16 = (readers[1].bits1 >> (32+16));
                assert(top16 != 0);
            }
            {
                const uint16_t top16 = (readers[2].bits1 >> (32+16));
                assert(top16 != 0);
            }
            {
                const uint16_t top16 = (readers[3].bits1 >> (32+16));
                assert(top16 != 0);
            }
# endif // DEBUG
            
            uint64_t prefixCount1 = __clz(readers[0].bits1);
            uint64_t prefixCount2 = __clz(readers[1].bits1);
            uint64_t prefixCount3 = __clz(readers[2].bits1);
            uint64_t prefixCount4 = __clz(readers[3].bits1);
            
            prefixCount1 += 1;
            prefixCount2 += 1;
            prefixCount3 += 1;
            prefixCount4 += 1;
            
            // Shift left to drop prefix bits from left side of register.
            
# if defined(DEBUG)
            assert(prefixCount1 < 17);
            assert(prefixCount2 < 17);
            assert(prefixCount3 < 17);
            assert(prefixCount4 < 17);
# endif // DEBUG
            
# if defined(DEBUG)
            assert(readers[0].numBits1 >= prefixCount1);
            assert(readers[1].numBits1 >= prefixCount2);
            assert(readers[2].numBits1 >= prefixCount3);
            assert(readers[3].numBits1 >= prefixCount4);
# endif // DEBUG
            
            numSymbolsToDecode -= 1;
            
            readers[0].bits1 <<= prefixCount1;
            readers[1].bits1 <<= prefixCount2;
            readers[2].bits1 <<= prefixCount3;
            readers[3].bits1 <<= prefixCount4;
            
            *outBytes++ = (uint8_t) prefixCount1;
            readers[0].numBits1 -= prefixCount1;
            
            *outBytes++ = (uint8_t) prefixCount2;
            readers[1].numBits1 -= prefixCount2;
            
            *outBytes++ = (uint8_t) prefixCount3;
            readers[2].numBits1 -= prefixCount3;
            
            *outBytes++ = (uint8_t) prefixCount4;
            readers[3].numBits1 -= prefixCount4;
        }
    }
    
    return;
}

// This logic implements interleaved reading with one 64 bit reader and an approach
// that inserts the exact number of bits into each bits register so that the
// register is completely full. This logic does not maintain

static inline
void rice_decode_prefix_bits_n_both_interleaved_readers_bit_insert(
                                                         vector<BitReader64ReaderPart<BitReaderStream64> > & readerPartVec,
                                                         vector<BitReader64StreamPart<BitReaderStream64> > & streamPartVec,
                                                         uint64_t numSymbolsToDecode,
                                                         uint8_t *outBytes
#if defined(DEBUG)
,
unordered_map<string, int> * countMapPtr
#endif // DEBUG
                                                                   )
{
    assert(readerPartVec.size() == streamPartVec.size());
    assert(readerPartVec.size() > 1);
    
#pragma unroll(1)
    for ( ; numSymbolsToDecode != 0 ; ) {
        
        //dual_dword_refill_lt16(inBytesLE64, s1PrefixBits1, s1PrefixBits2, s1PrefixNumBits1, s1PrefixNumBits2);
        //dual_dword_refill_lt16(inBytesLE64, s2PrefixBits1, s2PrefixBits2, s2PrefixNumBits1, s2PrefixNumBits2);
        //dual_dword_refill_lt16(inBytesLE64, s3PrefixBits1, s3PrefixBits2, s3PrefixNumBits1, s3PrefixNumBits2);
        //dual_dword_refill_lt16(inBytesLE64, s4PrefixBits1, s4PrefixBits2, s4PrefixNumBits1, s4PrefixNumBits2);
        
        for (int i = 0; i < readerPartVec.size(); i++) {
            streamPartVec[i].refillBits(readerPartVec[i]);
        }

#if defined(DEBUG)
        if (countMapPtr) {
            (*countMapPtr)["refill64"] += readerPartVec.size();
        }
#endif // DEBUG
        
        // Process special case of 16 zero bits or the next symbol for each stream.
        
        for (int i = 0; i < readerPartVec.size(); i++) {
            stream_part_process_zero16_or_regular(outBytes, streamPartVec[i]);
        }

#if defined(DEBUG)
        if (countMapPtr) {
            (*countMapPtr)["zero16OrSymbol"] += readerPartVec.size();
        }
#endif // DEBUG
        
        numSymbolsToDecode -= 1;
        
        // Combined loop that decodes 1 symbol from each stream
        
        #pragma unroll(1)
        while (1) {
            bool hasZeros = false;
            
            for (int i = 0; i < readerPartVec.size(); i++) {
                if ((streamPartVec[i].bits >> (32+16)) == (uint64_t)0) {
                    // break out of while loop and refill once one of the stream has 16 zeros
                    hasZeros = true;
                    break;
                }
            }
            if (hasZeros) {
#if defined(DEBUG)
                if (countMapPtr) {
                    (*countMapPtr)["zero16FoundReload"] += 1;
                }
#endif // DEBUG
                break;
            }

# if defined(DEBUG)
            for (int i = 0; i < readerPartVec.size(); i++) {
                const uint16_t top16 = (streamPartVec[i].bits >> (32+16));
                assert(top16 != 0);
            }
# endif // DEBUG
            
#if defined(DEBUG)
            // Incr +1 for each block of N symbols
            
            if (countMapPtr) {
                (*countMapPtr)["processBlockOfSymbols"] += 1;
            }
#endif // DEBUG
            
            for (int i = 0; i < readerPartVec.size(); i++) {
                stream_part_process_zero16_or_regular(outBytes, streamPartVec[i]);
                
# if defined(DEBUG)
                // Should never execute first branch of if
                assert(*(outBytes - 1) != 17);
# endif // DEBUG
            }
            
            numSymbolsToDecode -= 1;
            
            /*
            
            // FIXME: would need a vec of each prefixCount, bits, output byte
            
            uint64_t prefixCount1 = __clz(streamPartVec[0].bits);
            uint64_t prefixCount2 = __clz(streamPartVec[1].bits);
            uint64_t prefixCount3 = __clz(streamPartVec[2].bits);
            uint64_t prefixCount4 = __clz(streamPartVec[3].bits);
            
            prefixCount1 += 1;
            prefixCount2 += 1;
            prefixCount3 += 1;
            prefixCount4 += 1;
            
            // Shift left to drop prefix bits from left side of register.
            
# if defined(DEBUG)
            assert(prefixCount1 < 17);
            assert(prefixCount2 < 17);
            assert(prefixCount3 < 17);
            assert(prefixCount4 < 17);
# endif // DEBUG
            
# if defined(DEBUG)
            assert(streamPartVec[0].numBits >= prefixCount1);
            assert(streamPartVec[1].numBits >= prefixCount2);
            assert(streamPartVec[2].numBits >= prefixCount3);
            assert(streamPartVec[3].numBits >= prefixCount4);
# endif // DEBUG
            
            numSymbolsToDecode -= 1;
            
            streamPartVec[0].bits <<= prefixCount1;
            streamPartVec[1].bits <<= prefixCount2;
            streamPartVec[2].bits <<= prefixCount3;
            streamPartVec[3].bits <<= prefixCount4;
            
            *outBytes++ = (uint8_t) prefixCount1;
            streamPartVec[0].numBits -= prefixCount1;
            
            *outBytes++ = (uint8_t) prefixCount2;
            streamPartVec[1].numBits -= prefixCount2;
            
            *outBytes++ = (uint8_t) prefixCount3;
            streamPartVec[2].numBits -= prefixCount3;
            
            *outBytes++ = (uint8_t) prefixCount4;
            streamPartVec[3].numBits -= prefixCount4;
             
             */
        }
    }
    
    return;
}

// 64 bit stream multiplexer, this logic splits rice encoding into prefix and suffix
// streams and then the prefix bit streams are mixed together into a multiplexed stream.

// FIXME: return vector of suffix bytes and k vector split into N segments ?

static inline
vector<uint64_t> ByteStreamMultiplexer64(
                                        const vector<vector<uint8_t> > & vecOfVecs,
                                        const vector<uint8_t> & kBlockVec,
                                        const unsigned int numSymbolsInKBlock)
{
    // Output destination for byte writes from N input streams
    
    vector<uint64_t> multiplexVec;
    
    int numStreams = (int) vecOfVecs.size();
    int numSymbols = -1;
    
    // All vectors must be the same length
    
    for ( const vector<uint8_t> & vec : vecOfVecs ) {
        if (numSymbols != -1) {
            assert(numSymbols == (int)vec.size());
        } else {
            numSymbols = (int)vec.size();
        }
    }
    
    // Actual encoded num bytes will be smaller that this max size
    multiplexVec.reserve(((numSymbols * numStreams) / sizeof(uint64_t)));
    
    const int numKBlockEachStream = numSymbols / numSymbolsInKBlock;
#if defined(DEBUG)
    assert((numSymbols % numSymbolsInKBlock) == 0);
#endif // DEBUG
    
    // Encode a vector of symbols using standard split16 method
    // and a split into prefix and suffix buffers.
    
    vector<RiceSplit16x2Encoder<false, true, BitWriterByteStream> > encoderVec;
    
    encoderVec.resize(numStreams);
    
    int blocki = 0;
    //int numSymbolsi = 0;
    
    // Vector of the k values for each input stream
    vector<vector<uint8_t> > decoderKVecOfVecs;
    // The number of symbols in each block
    //vector<uint32_t> decoderNumSymbolsVecs;
    
    for (int encoderi = 0; encoderi < encoderVec.size(); encoderi++ ) {
        auto & encoder = encoderVec[encoderi];
        
        // Encode all symbols in this stream, note that each block
        // can have a different k value. and that a table is constructed
        // and passed to encode this entire input stream with a
        // set of k values.
        
        const vector<uint8_t> & inByteVec = vecOfVecs[encoderi];
        
#if defined(DEBUG)
        int blockiStart = blocki;
#endif // DEBUG
        
        vector<uint8_t> encodeKTable(numKBlockEachStream+1);
        
        for (int i = 0; i < numKBlockEachStream; i++) {
#if defined(DEBUG)
            int maxSizeWoPadding = (int)kBlockVec.size() - 1;
            assert(blocki < maxSizeWoPadding);
            assert(i < encodeKTable.size());
#endif // DEBUG
            encodeKTable[i] = kBlockVec[blocki++];
        }
        
        encodeKTable[numKBlockEachStream] = 0;
        
#if defined(DEBUG)
        if ((0)) {
            printf("for unmux input blocki range (%d, %d), k lookup table is:\n", blockiStart, blocki);
            
            for (int i = 0; i < (int)encodeKTable.size(); i++ ) {
                uint8_t k = encodeKTable[i];
                printf("encodeKTable[%3d] = %3d\n", i, k);
            }
        }
#endif // DEBUG
        
        decoderKVecOfVecs.push_back(encodeKTable);
        //decoderNumSymbolsVecs.push_back(numSymbolsInKBlock);
        
        vector<uint32_t> countTable(1);
        vector<uint32_t> nTable(1);
        
        // Number of blocks in the input, corresponds to encodeKTable.size()-1
        countTable[0] = numKBlockEachStream;
        // Num symbols per block
        nTable[0] = numSymbolsInKBlock;
        
        encoder.encode(inByteVec.data(), (int)inByteVec.size(),
                       encodeKTable.data(), (int)encodeKTable.size(),
                       countTable,
                       nTable
                       );
        
        if ((0)) {
            for (int i = 0; i < (int)inByteVec.size(); i++ ) {
                uint8_t symbol = inByteVec[i];
                printf("encoded symbol %3d with encoder for stream %d\n", symbol, encoderi);
            }
        }
    }
    
    // Collect each rice encoded stream into a vector
    
    vector<vector<uint8_t> > prefixVecOfVecs;
    vector<vector<uint8_t> > suffixVecOfVecs;

    // Decoded unary values as bytes (1, 17)
    vector<vector<uint8_t> > prefixUnaryVecOfVecs;
    
    for ( auto & encoder : encoderVec ) {
        auto prefixBitsByteVec = encoder.prefixBitWriter.moveBytes();
        
        // FIXME: does this additional zero padding on the stream
        // actually mess up the mixed streams?
        
        // Convert to LE 64 read ordering and add zero padding
        
        auto prefixBitsByteVec64 = PrefixBitStreamRewrite64(prefixBitsByteVec);
        
        prefixVecOfVecs.push_back(std::move(prefixBitsByteVec64));
        
        // Suffix bits
        
        auto suffixBitsByteVec = encoder.remBitWriter.moveBytes();
        
        suffixVecOfVecs.push_back(std::move(suffixBitsByteVec));
        
        // Store encoded prefix byte values for decode comparison
        prefixUnaryVecOfVecs.push_back(std::move(encoder.unaryNBytes));
    }
    
    // Vector of bytes is already formatted as 64 bit values, but
    // it must be explicitly converted to make C++ happy.
    
    vector<vector<uint64_t> > prefixVecOfVec64;
    
    prefixVecOfVec64.resize(numStreams);
    
    {
        for (int decoderi = 0; decoderi < numStreams; decoderi++) {
            vector<uint8_t> prefixByteVecBytes = prefixVecOfVecs[decoderi];
            
            // Vector of bytes is already formatted as 64 bit values, but
            // it must be explicitly converted to make C++ happy.
            
            vector<uint64_t> & vec64 = prefixVecOfVec64[decoderi];
            
            uint64_t numDwords = prefixByteVecBytes.size() / sizeof(uint64_t);
            
#if defined(DEBUG)
            assert((prefixByteVecBytes.size() % sizeof(uint64_t)) == 0);
#endif // DEBUG
            
            vec64.resize((int)numDwords);
            memcpy(vec64.data(), prefixByteVecBytes.data(), prefixByteVecBytes.size());
        }
    }
    
    // The next phase decodes from N prefix streams. Each time
    // a prefix stream runs low on bits a 64 bit read is executed
    // and this operation indicates the ordering of 64 bit values
    // in the multiplexed stream.
    
    //typedef RiceSplit16x2PrefixDecoder64Read64<BitReaderStream64> Decoder64T;
    typedef RiceSplit16x2PrefixDecoder64Read64<BitReaderByteStreamMultiplexer64> Decoder64T;
    
    vector<Decoder64T> decoderVec;
    decoderVec.resize(numStreams);
    
    vector<vector<uint8_t> > vecOfDecodedSymbolsVec;
    vecOfDecodedSymbolsVec.resize(numStreams);
    
    {
        for (int decoderi = 0; decoderi < numStreams; decoderi++) {
            auto & decoder = decoderVec[decoderi];
            
            // Invoke setupOutput() to store output buffer pointer
            
            auto & decodedSymbolsVec = vecOfDecodedSymbolsVec[decoderi];
            decodedSymbolsVec.resize(numSymbols);
            
            decoder.setupOutput(decodedSymbolsVec.data());
            
            // Prefix bits encoded as LE 64 bit padded read stream.
            
            vector<uint64_t> & vec64 = prefixVecOfVec64[decoderi];
            
            decoder.prefixBitsReader.byteReader64.setupInput(vec64.data());
            
            // In addition, BitReaderByteStreamMultiplexer64 requires that an
            // output stream that interleaves 64 bit writes be defined.
            
            decoder.prefixBitsReader.byteReader64.setMultiplexVecPtr(&multiplexVec);
        }
    }
    
    // For each symbol to be decoded, pull prefix value from each stream.
    // This logic interleaves 64 bit reads from N streams into a combined
    // stream that can then be decoded by reading in the same order.
    
    /*
    
#if defined(DEBUG)
    int totalDecodedNumSymbols = 0;
#endif // DEBUG
    
    for (int symboli = 0; symboli < numSymbols; symboli++) {
        for (int decoderi = 0; decoderi < numStreams; decoderi++) {
            // Get decoder for next stream
            auto & decoder = decoderVec[decoderi];

#if defined(DEBUG)
            int numSymbolsDecoded = decoder.decodeSymbols(1);
            assert(numSymbolsDecoded == 1);
            
            totalDecodedNumSymbols += 1;
            
            auto & decodedSymbolsVec = vecOfDecodedSymbolsVec[decoderi];
            
            int symbol = decodedSymbolsVec[symboli];
            
            if ((0)) {
                printf("decoded symbol %3d for stream %d\n", symbol, decoderi);
            }
            
            // Compare decoded prefix to original value
            
            const vector<uint8_t> & origPrefixUnaryVec = prefixUnaryVecOfVecs[decoderi];
            
            int origPrefixSymbol = origPrefixUnaryVec[symboli];
            
            if ((0)) {
                printf("original symbol %3d for stream %d\n", origPrefixSymbol, decoderi);
            }
            
            assert(symbol == origPrefixSymbol);
#else
            decoder.decodeSymbols(1);
#endif // DEBUG
        }
    }
     
    */
    
    vector<BitReader64<BitReaderByteStreamMultiplexer64, 16> > vecOfReaders;
    
    for (int decoderi = 0; decoderi < numStreams; decoderi++) {
        auto & decoder = decoderVec[decoderi];
        vecOfReaders.push_back(decoder.prefixBitsReader);
    }
    
    vector<uint8_t> outputInterleavedVec;
    outputInterleavedVec.resize(numSymbols * 4);

    rice_decode_prefix_bits_4x_both_interleaved_readers(vecOfReaders, numSymbols, outputInterleavedVec.data());
    
    /*
    
    // FIXME: Decode symbols from this mixed stream format using a decoder
    // and verify that the decoded symbols are exactly as expected.
    
    vector<RiceSplit16x2PrefixDecoder64Read64<BitReaderStream64>> demuxDecoderVec;
    demuxDecoderVec.resize(numStreams);
    
    for (int decoderi = 0; decoderi < numStreams; decoderi++) {
        auto & decoder = demuxDecoderVec[decoderi];
        
        // Invoke setupOutput() to store output buffer pointer
        
        auto & decodedSymbolsVec = vecOfDecodedSymbolsVec[decoderi];
        memset(decodedSymbolsVec.data(), 0, decodedSymbolsVec.size());
        
        decoder.setupOutput(decodedSymbolsVec.data());
        
        // Input is mixed 64 bit stream where each 64 bit read is done
        // by different decoders.
        
//        vector<uint64_t> & vec64 = prefixVecOfVec64[decoderi];
        
//        decoder.prefixBitsReader.byteReader64.setupInput(vec64.data());
        
        // In addition, BitReaderByteStreamMultiplexer64 requires that an
        // output stream that interleaves 64 bit writes be defined.
        
//        decoder.prefixBitsReader.byteReader64.setMultiplexVecPtr(&multiplexVec);
    }

    for (int symboli = 0; symboli < numSymbols; symboli++) {
        for (int decoderi = 0; decoderi < numStreams; decoderi++) {
            // Get decoder for next stream
            auto & decoder = demuxDecoderVec[decoderi];
            
#if defined(DEBUG)
            int numSymbolsDecoded = decoder.decodeSymbols(1);
            assert(numSymbolsDecoded == 1);
            
            totalDecodedNumSymbols += 1;
            
            auto & decodedSymbolsVec = vecOfDecodedSymbolsVec[decoderi];
            
            int symbol = decodedSymbolsVec[symboli];
            
            if ((0)) {
                printf("decoded symbol %3d for stream %d\n", symbol, decoderi);
            }
            
            // Compare decoded prefix to original value
            
            const vector<uint8_t> & origPrefixUnaryVec = prefixUnaryVecOfVecs[decoderi];
            
            int origPrefixSymbol = origPrefixUnaryVec[symboli];
            
            if ((0)) {
                printf("original symbol %3d for stream %d\n", origPrefixSymbol, decoderi);
            }
            
            assert(symbol == origPrefixSymbol);
#else
            decoder.decodeSymbols(1);
#endif // DEBUG
        }
    }
     
    */

    // Output should be exactly as the decoder needs it taking padding
    // and read 1 ahead into account.
    
    // Add 1 unit of zero padding at the end for each stream
    
//    for (int decoderi = 0; decoderi < numStreams; decoderi++) {
//        multiplexVec.push_back(0);
//    }
    
    return multiplexVec;
}

// Given a stream of bytes interleaved as (S0, S1, ..., SN-1) deinterleave
// the values and return in original order.

static inline
vector<uint8_t> ByteStreamDeinterleaveN(const vector<uint8_t> & inBytes, const int N)
{
    vector<vector<uint8_t> > vecOfVecs;
    vecOfVecs.resize(N);
    
    assert(((int) inBytes.size() % N) == 0);
    const int numIters = (int) inBytes.size() / N;
    
    assert(numIters > 0);
    
    for (int i = 0; i < N; i++) {
        vecOfVecs[i].reserve(numIters);
    }
    
    const uint8_t *bytePtr = inBytes.data();
    
    for (int segi = 0; segi < numIters; segi++) {
        for (int i = 0; i < N; i++) {
            uint8_t bVal = *bytePtr++;
            vecOfVecs[i].push_back(bVal);
        }
    }
    
    // Concat each entry in vecOfVecs
    
    vector<uint8_t> combined;
    combined.reserve(N * numIters);
    
    for ( auto & vec : vecOfVecs ) {
        for ( uint8_t bVal : vec ) {
            combined.push_back(bVal);
        }
    }
    
    assert(combined.size() == inBytes.size());
    
    return combined;
}

// New interleaved approach where variable bit width interleaving is used to fully
// refill each bit buffer with no second overflow fill buffer.

static inline
vector<uint64_t> ByteStreamMultiplexer64InterleavedN(
                                                     const vector<vector<uint8_t> > & vecOfVecs,
                                                     const vector<uint8_t> & kBlockVec,
                                                     const unsigned int numSymbolsInKBlock,
                                                     // The split encoding output
                                                     vector<vector<uint8_t> > & prefixVecOfVecs,
                                                     vector<vector<uint8_t> > & suffixVecOfVecs,
                                                     vector<vector<uint8_t> > & kTableVecOfVecs,
                                                     vector<vector<uint8_t> > & prefixUnaryNVecOfVecs
)
{
    // Output destination for byte writes from N input streams
    
    vector<uint64_t> multiplexVec;
    
    int numStreams = (int) vecOfVecs.size();
    int numSymbols = -1;
    
    // All vectors must be the same length
    
    for ( const vector<uint8_t> & vec : vecOfVecs ) {
        if (numSymbols != -1) {
            assert(numSymbols == (int)vec.size());
        } else {
            numSymbols = (int)vec.size();
        }
    }
    
    // Actual encoded num bytes will be smaller that this max size
    //multiplexVec.reserve(((numSymbols * numStreams) / sizeof(uint64_t)));
    
    const int numKBlockEachStream = numSymbols / numSymbolsInKBlock;
#if defined(DEBUG)
    assert((numSymbols % numSymbolsInKBlock) == 0);
#endif // DEBUG
    
    // Encode a subrange of symbols using standard split16 method
    // and a split into prefix and suffix buffers.
    
    vector<RiceSplit16x2Encoder<false, true, BitWriterByteStream> > encoderVec;
    
    encoderVec.resize(numStreams);
    
    int blocki = 0;
    //int numSymbolsi = 0;
    
    // Vector of the k values for each input stream
    vector<vector<uint8_t> > decoderKVecOfVecs;
    // The number of symbols in each block
    //vector<uint32_t> decoderNumSymbolsVecs;
    
    for (int encoderi = 0; encoderi < encoderVec.size(); encoderi++ ) {
        auto & encoder = encoderVec[encoderi];
        
        // Encode all symbols in this stream, note that each block
        // can have a different k value. and that a table is constructed
        // and passed to encode this entire input stream with a
        // set of k values.
        
        const vector<uint8_t> & inByteVec = vecOfVecs[encoderi];
        
#if defined(DEBUG)
        int blockiStart = blocki;
#endif // DEBUG
        
        vector<uint8_t> encodeKTable(numKBlockEachStream+1);
        
        for (int i = 0; i < numKBlockEachStream; i++) {
#if defined(DEBUG)
            int maxSizeWoPadding = (int)kBlockVec.size() - 1;
            assert(blocki < maxSizeWoPadding);
            assert(i < encodeKTable.size());
#endif // DEBUG
            encodeKTable[i] = kBlockVec[blocki++];
        }
        
        encodeKTable[numKBlockEachStream] = 0;
        
#if defined(DEBUG)
        if ((0)) {
            printf("for unmux input blocki range (%d, %d), k lookup table is:\n", blockiStart, blocki);
            
            for (int i = 0; i < (int)encodeKTable.size(); i++ ) {
                uint8_t k = encodeKTable[i];
                printf("encodeKTable[%3d] = %3d\n", i, k);
            }
        }
#endif // DEBUG
        
        decoderKVecOfVecs.push_back(encodeKTable);
        //decoderNumSymbolsVecs.push_back(numSymbolsInKBlock);
        
        vector<uint32_t> countTable(1);
        vector<uint32_t> nTable(1);
        
        // Number of blocks in the input, corresponds to encodeKTable.size()-1
        countTable[0] = numKBlockEachStream;
        // Num symbols per block
        nTable[0] = numSymbolsInKBlock;
        
        kTableVecOfVecs.push_back(encodeKTable); // save sub ktable
        
        encoder.encode(inByteVec.data(), (int)inByteVec.size(),
                       encodeKTable.data(), (int)encodeKTable.size(),
                       countTable,
                       nTable
                       );
        
        if ((0)) {
            for (int i = 0; i < (int)inByteVec.size(); i++ ) {
                uint8_t symbol = inByteVec[i];
                printf("encoded symbol %3d with encoder for stream %d\n", symbol, encoderi);
            }
        }
    }
    
    for ( auto & encoder : encoderVec ) {
        auto prefixBitsByteVec = encoder.prefixBitWriter.moveBytes();
        
        // FIXME: does this additional zero padding on the stream
        // actually mess up the mixed streams?
        
        // Convert to LE 64 read ordering and add zero padding
        
        auto prefixBitsByteVec64 = PrefixBitStreamRewrite64(prefixBitsByteVec);
        
        prefixVecOfVecs.push_back(std::move(prefixBitsByteVec64));
        
        // Suffix bits
        
        auto suffixBitsByteVec = encoder.remBitWriter.moveBytes();
        
        suffixVecOfVecs.push_back(std::move(suffixBitsByteVec));
        
        // Store encoded prefix byte values for decode comparison
        prefixUnaryNVecOfVecs.push_back(std::move(encoder.unaryNBytes));
    }
    
    // Vector of bytes is already formatted as 64 bit values, but
    // it must be explicitly converted to make C++ happy.
    
    vector<vector<uint64_t> > prefixVecOfVec64;
    
    prefixVecOfVec64.resize(numStreams);
    
    {
        for (int decoderi = 0; decoderi < numStreams; decoderi++) {
            vector<uint8_t> prefixByteVecBytes = prefixVecOfVecs[decoderi];
            
            // Vector of bytes is already formatted as 64 bit values, but
            // it must be explicitly converted to make C++ happy.
            
            vector<uint64_t> & vec64 = prefixVecOfVec64[decoderi];
            
            uint64_t numDwords = prefixByteVecBytes.size() / sizeof(uint64_t);
            
#if defined(DEBUG)
            assert((prefixByteVecBytes.size() % sizeof(uint64_t)) == 0);
#endif // DEBUG
            
            vec64.resize((int)numDwords);
            memcpy(vec64.data(), prefixByteVecBytes.data(), prefixByteVecBytes.size());
        }
    }
    
    // This multiplexing implementation encodes with variable width bit buffers
    // needed to fully fill the bit buffer for each of N streams. Unlike a fixed
    // read approach, this encoding minimized read buffering for each stream.

    vector<BitReader64ReaderPart<BitReaderStream64>> readerPartVec(numStreams);
    vector<BitReader64StreamPart<BitReaderStream64>> streamPartVec(numStreams);
    
    vector<vector<uint8_t> > vecOfDecodedSymbolsVec;
    vecOfDecodedSymbolsVec.resize(numStreams);
    
    // Interleaved bit writer
    BitWriter<true,BitWriterByteStream> bitWriter;
    
    {
        for (int decoderi = 0; decoderi < numStreams; decoderi++) {
            //auto & decoder = decoderVec[decoderi];
            
            // Invoke setupOutput() to store output buffer pointer
            
            //auto & decodedSymbolsVec = vecOfDecodedSymbolsVec[decoderi];
            //decodedSymbolsVec.resize(numSymbols);
            
            //decoder.setupOutput(decodedSymbolsVec.data());
            
            // Prefix bits encoded as LE 64 bit padded read stream.
            
            // Setup a reader for each encoded prefix bits stream
            
            vector<uint64_t> & vec64 = prefixVecOfVec64[decoderi];
            
            auto & rp = readerPartVec[decoderi];
            
            rp.byteReader64.setupInput(vec64.data());
            
            printf("in bytes vec %d\n", (int)(vec64.size()*sizeof(uint64_t)));
            
            rp.initBits();

            // Configure stream by connecting bit interleaving output
            
            auto & sp = streamPartVec[decoderi];
            
            sp.bitWriterPtr = &bitWriter;
        }
    }
    
    vector<uint8_t> outputInterleavedVec;
    outputInterleavedVec.resize(numSymbols * numStreams);

#if defined(DEBUG)
    unordered_map<string, int> countMap;
#endif // DEBUG
    
    rice_decode_prefix_bits_n_both_interleaved_readers_bit_insert(readerPartVec,
                                                                   streamPartVec,
                                                                   numSymbols,
                                                                   outputInterleavedVec.data()
#if defined(DEBUG)
                                                                  ,
                                                                  &countMap
#endif // DEBUG
                                                                  );
    
#if defined(DEBUG)
    for ( auto & pair : countMap ) {
        printf("%8d <- %s\n", pair.second, pair.first.c_str());
    }
#endif // DEBUG
    
#if defined(DEBUG)
    // Examine interleaved decoded unary byte values and make sure
    // these value match the original unary N values from the encoder.
    // These values are interleaved as (S0, S1, S2, ...)

    vector<uint8_t> recombinedUnary;
    
    for ( auto & vec : prefixUnaryNVecOfVecs ) {
        for ( uint8_t bVal : vec ) {
            recombinedUnary.push_back(bVal);
        }
    }
    
    vector<uint8_t> streamOrder = ByteStreamDeinterleaveN(outputInterleavedVec, numStreams);
    
    assert(streamOrder.size() == outputInterleavedVec.size());
    assert(streamOrder.size() == recombinedUnary.size());
    
    for ( int i = 0; i < streamOrder.size(); i++) {
        int v1 = streamOrder[i];
        int v2 = recombinedUnary[i];
        assert(v1 == v2);
    }
#endif // DEBUG
    
    // Bit writes sent to bitWriter, but need to convert back to
    // 64 bit values in order to return in acceptable form.
    
    bitWriter.flushByte();
    
    printf("num bits encoded interleaved %d : num bytes %d\n", bitWriter.numEncodedBits, bitWriter.numEncodedBits/8);
    
    // FIXME: Verify that output number of bits exactly matches the input number of bits
    // from N different streams?
    
    // Copy bytes padded to whole 64 bit bound
    
    vector<uint8_t> multiplexedByteVec = bitWriter.moveBytes();

//    int numBytes = (int) byteVector.size();
//
//    while ((numBytes % sizeof(uint64_t)) != 0) {
//        numBytes++;
//    }
//
//    multiplexVec.resize(numBytes);
//
//    memcpy(multiplexVec.data(), byteVector.data(), byteVector.size());

    // Rewrite byte ordering to LE 64 bit ordering so that native read in
    // gets bytes in proper MSB ordering directly.
    
    vector<uint8_t> bytes64 = PrefixBitStreamRewrite64(multiplexedByteVec);
    
    assert((bytes64.size() % sizeof(uint64_t)) == 0);
    
    // Reformatted bytes now in terms of 64 bit chunks
    
    multiplexVec.resize(bytes64.size() / sizeof(uint64_t));
    
    memcpy(multiplexVec.data(), bytes64.data(), bytes64.size());
    
    // FIXME: bits were readd from 64 bit stream layout but are no longer
    // in LE ordering. Need to reorder them as 64 bit LE again before using.
    
    return multiplexVec;
}

// Generate 32 bit k table offsets from a zero terminated table

static inline
void
GenerateSuffixBlockStartTable(uint8_t *blockOptimalKTable,
                              int blockOptimalKTableLength,
                              uint32_t *offsets,
                              const int blockDim)
{
    uint32_t offset = 0;
    
    offsets[0] = 0;
    
    int kBitWidth = blockOptimalKTable[0];
    // Next block starts at the k bit width times the number of symbols in one block
    kBitWidth *= (blockDim * blockDim);
    offset += kBitWidth;
    
    for (int i = 1; i < blockOptimalKTableLength-1; i++) {
        offsets[i] = offset;
        
        int kBitWidth = blockOptimalKTable[i];
        // Next block starts at the k bit width times the number of symbols in one block
        kBitWidth *= (blockDim * blockDim);
        
#if defined(DEBUG)
        {
            uint64_t offset64 = offset;
            offset64 += kBitWidth;
            assert(offset64 <= 0xFFFFFFFF);
        }
#endif // DEBUG
        
        offset += kBitWidth;
    }
    
    return;
}

// Generate table with 6 bit key that covers 64 values. The lookup
// table contains 16 bit entries with a maximum of 4 nibble values
// in the range (0, 15)

static inline
vector<uint16_t>
PrefixBitStreamGenerateLookupTable64K6Bits()
{
    const bool debug = false;

    // 64 entries for 6 bits
    
    vector<uint16_t> generatedTable;
    
    const int tableSize = 64;
    generatedTable.resize(tableSize);
    
    for ( int i = 0; i < tableSize; i++) {
        if (debug) {
            printf("table entry i %d\n", i);
        }
        
        uint32_t keyBits = ((uint32_t)i) << (32 - 8) << 2;
        
        if (debug) {
            uint32_t keyBits6 = ((uint32_t)i);
            printf("bits     %s for i %d\n", get_code_bits_as_string64(keyBits, 32).c_str(), i);
            printf("keyBits6 %s for i %d\n", get_code_bits_as_string64((keyBits6), 6).c_str(), i);
        }
        
        // loop N times, max of 4 lookup values in 16 bits
        
        unsigned int q;
        unsigned int bi = 0;
        uint16_t bits16 = 0;
        
        while (keyBits != 0) {
            if (bi >= 4) {
                break;
            }
            
            if (debug) {
                printf("bits %s from i %d\n", get_code_bits_as_string64(keyBits, 32).c_str(), i);
            }
            
            unsigned int clz = __clz(keyBits);
            q = clz + 1;
            
            assert(q >= 1 && q <= 16);
            assert(clz >= 0 && clz <= 15);
            
            if (debug)
            {
                uint32_t keyBits6 = keyBits >> (32 - 8) >> 2;
                printf("keyBits6 %s : q %d\n", get_code_bits_as_string64(keyBits6, 6).c_str(), q);
            }
            
            bits16 |= (q << (bi * 4));
            keyBits <<= q;
            
            bi += 1;
        }
        
        assert(i < generatedTable.size());
        uint8_t offset8 = i;
        // Offset into table is a byte
        generatedTable[offset8] = bits16;
        
        
        if (debug) {
            printf("generatedTable[%3d] : bits %s : bits16-q %s\n", i, get_code_bits_as_string64(offset8, 6).c_str(), get_code_bits_as_string64(bits16, 16).c_str());
            printf("offset8 %s\n", get_code_bits_as_string64(offset8, 8).c_str());
        }
    }
    
    return generatedTable;
}

#endif // rice_hpp
