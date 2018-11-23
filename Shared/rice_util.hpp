//
//  rice_util.hpp
//
//  Created by Mo DeJong on 6/3/18.
//  Copyright © 2018 helpurock. All rights reserved.
//
//  Rice encoding/decoding logic that is able to split
//  the prefix and suffix streams. Decoding of the
//  suffix stream can be implemented with parallel
//  processing since the K suffix bits are encoded
//  block by block with a constant bit width. The
//  special case of very long symbols are handled
//  with an escape code of 16 zero bits in a row
//  is converted to a prefix value (N - 16) encoded
//  as a byte.

#ifndef _rice_util_hpp
#define _rice_util_hpp

using namespace std;

// POT divide: q = (n / m) where m is 2^k
// This implementation is needed inside the encoder to avoid a costly
// divide operation for each symbol. Also used when counting bits.

static inline
unsigned int pot_div_k(const unsigned int n, const unsigned int k) {
#if defined(DEBUG)
    {
        assert(k >= 0 && k <= 7);
    }
#endif // DEBUG
    unsigned int q = n >> k;
#if defined(DEBUG)
    {
        const unsigned int m = (1 << k);
        unsigned int divPOT = n / m;
        assert(divPOT == q);
    }
#endif // DEBUG
    return q;
}

// Break a stream of bytes up into N streams that each
// stream contains a multiple of (blockDim * blockDim) bytes.

static inline
vector<vector<uint8_t> > SplitByteStreamIntoNStreams(const vector<uint8_t> & inBytes, const int splitSize)
{
    int rem = inBytes.size() % splitSize;
    assert(rem == 0);
    
    int n = (int)inBytes.size() / splitSize;
    
    const uint8_t *inPtr = inBytes.data();
    
    vector<vector<uint8_t> > resultVec;
    resultVec.resize(splitSize);
    
    for ( int spliti = 0; spliti < splitSize; spliti++ ) {
        vector<uint8_t> & bytesVec = resultVec[spliti];
        
        bytesVec.reserve(n);
        
        for ( int i = 0; i < n; i++ ) {
            uint8_t bVal = *inPtr++;
            bytesVec.push_back(bVal);
        }
    }
    
    assert((inPtr - inBytes.data()) == inBytes.size());
    
    return resultVec;
}

#endif // _rice_util_hpp
