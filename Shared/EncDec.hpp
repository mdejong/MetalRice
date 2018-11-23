//
//  EncDec.hpp
//
//  Created by Mo DeJong on 4/3/16.
//  Copyright © 2016 HelpURock. All rights reserved.
//
//  C++ templates for encoding and decoding numbers
//  as bytes.

#ifndef ENC_DEC_H
#define ENC_DEC_H

#include "assert.h"

#include <vector>

#include <unordered_map>

using namespace std;

#define LUT_DEBUG_DUMP_PIXEL 0

// encode from vector of bytes to NSData*

#ifdef __OBJC__

static inline
NSData*
encode(const vector<uint8_t> &buf)
{
  NSMutableData *mData = [NSMutableData dataWithCapacity:(NSUInteger)buf.size()];
  [mData setLength:(NSUInteger)buf.size()];
  
  uint8_t *bytePtr = (uint8_t *) mData.mutableBytes;
  for ( uint8_t bVal : buf ) {
    *bytePtr++ = bVal;
  }
  
  return [NSData dataWithData:mData];

}

#endif

// Encode an 8 bit int as a byte

static inline
void
encode(vector<uint8_t> &buf, uint8_t iVal)
{
  buf.push_back(iVal);
  return;
}

// Deocde an 8 bit int as a byte and update the offset
// ref to indicate how many bytes were read.

static inline
void
decode(const vector<uint8_t> &buf, int & offset, uint8_t & iVal)
{
  iVal = buf[offset++];
}

// Encode a 16 bit int as bytes

static inline
void
encode(vector<uint8_t> &buf, uint16_t iVal)
{
  uint8_t bVal;
  
  bVal = iVal & 0xFF;
  buf.push_back(bVal);
  
  bVal = (iVal >> 8) & 0xFF;
  buf.push_back(bVal);
  
  return;
}

// Deocde an 8 bit int as a byte and update the offset
// ref to indicate how many bytes were read.

static inline
void
decode(const vector<uint8_t> &buf, int & offset, uint16_t & iVal)
{
  iVal = buf[offset++];
  iVal |= (buf[offset++] << 8);
}

// Encode a 32 bit int as bytes

static inline
void
encode(vector<uint8_t> &buf, uint32_t iVal)
{
  uint8_t bVal;
  
  for ( int i = 0; i < 4; i++ ) {
    bVal = (iVal >> (i * 8)) & 0xFF;
    buf.push_back(bVal);
  }
  
  return;
}

// Encode a 64 bit int as bytes

static inline
void
encode(vector<uint8_t> &buf, uint64_t iVal)
{
  uint8_t bVal;
  
  for ( int i = 0; i < 8; i++ ) {
    bVal = (iVal >> (i * 8)) & 0xFF;
    buf.push_back(bVal);
  }

  return;
}

static inline
void
decode(const vector<uint8_t> &buf, int & offset, uint32_t & iVal)
{
  iVal = buf[offset++];
  iVal |= (buf[offset++] << 8);
  iVal |= (buf[offset++] << 16);
  iVal |= (buf[offset++] << 24);
}

static inline
void
decode(const vector<uint8_t> &buf, int & offset, uint64_t & iVal)
{
  iVal = buf[offset++];
  iVal |= (buf[offset++] << 8);
  iVal |= (buf[offset++] << 16);
  iVal |= (buf[offset++] << 24);
  iVal |= (((uint64_t) buf[offset++]) << 32);
  iVal |= (((uint64_t) buf[offset++]) << 40);
  iVal |= (((uint64_t) buf[offset++]) << 48);
  iVal |= (((uint64_t) buf[offset++]) << 56);
}

// Append a buffer of bytes to and existing buffer of bytes

static inline
void
append(vector<uint8_t> &buf1, const vector<uint8_t> &buf2)
{
  buf1.insert(end(buf1), begin(buf2), end(buf2));
  return;
}

// Encode a buffer of N numbers where N is a 32 bit
// integer size. Note that it is possible that the
// size of the numbers vector is zero, since the
// format may require knowing that zero elements
// were encoded at a specific location.

template <typename T>
vector<uint8_t>
encodeN(const vector<T> &numbers)
{
  vector<uint8_t> buf;
  
  assert(numbers.size() <= 0xFFFFFFFF);
  uint32_t N = (uint32_t) numbers.size();
  
  encode(buf, N);
  
  for ( T num : numbers ) {
    encode(buf, num);
  }
  
  return std::move(buf);
}

// Decode a 32 bit N and then that many 32 bit words from a buffer

template <typename T>
void
decodeN(const vector<uint8_t> &buf, int & offset, vector<T> &vec)
{
  uint32_t N;
  
  vec.clear();
  
  decode(buf, offset, N);
  
  for ( int i = 0; i < N; i++ ) {
    T val;
    decode(buf, offset, val);
    vec.push_back(val);
  }
  
  return;
}

// Encode pairs of nibbles (4bits) stored as uint8_t values in a vector

template <typename T>
void
mergeNibbles(const vector<T> &numbers, vector<uint8_t> &mergedVec)
{
  mergedVec.clear();
  
  int N = (int) numbers.size();
  
  for ( int i = 0; i < N; i += 2) {
    T b1 = numbers[i];
    T b2 = 0;
    if ((i+1) < N) {
      b2 = numbers[i+1];
    }
    
    assert(b1 <= 0xF);
    assert(b2 <= 0xF);
    
    uint8_t merged = (b2 << 4) | b1;
    
#if defined(DEBUG)
    {
      uint8_t low = merged & 0xF;
      uint8_t high = (merged >> 4) & 0xF;
      assert(low == b1);
      assert(high == b2);
    }
#endif // DEBUG
    
    // Encode 2 nibbles as a single byte
    
    mergedVec.push_back(merged);
  }
  
  return;
}

// Split nibbles (merged into bytes) back out to nibbles

static inline
void
splitNibbles(const vector<uint8_t> &mergedVec, vector<uint8_t> &nibbles)
{
  nibbles.clear();
  int N = (int) mergedVec.size();
  
  int offset = 0;
  
  for ( int i = 0; i < N; i += 2 ) {
    uint8_t merged, b1, b2;
    
    decode(mergedVec, offset, merged);
    
    b1 = merged & 0xF;
    b2 = (merged >> 4) & 0xF;
    
    nibbles.push_back(b1);
    nibbles.push_back(b2);
  }
  
  return;
}

// Encode pairs of nibbles (4bits) stored as uint8_t values with the number of values as a 32 bit int at the front

template <typename T>
void
encodeNibbles(const vector<T> &numbers, vector<uint8_t> &nibbles)
{
  assert(numbers.size() <= 0xFFFFFFFF);
  uint32_t N = (uint32_t) numbers.size();
  assert((N % 2) == 0);
  
  encode(nibbles, N/2);
  
  for ( int i = 0; i < N; i += 2) {
    T b1 = numbers[i];
    T b2 = numbers[i+1];
    
    assert(b1 <= 0xF);
    assert(b2 <= 0xF);
    
    uint8_t merged = (b2 << 4) | b1;
    
#if defined(DEBUG)
    {
      uint8_t low = merged & 0xF;
      uint8_t high = (merged >> 4) & 0xF;
      assert(low == b1);
      assert(high == b2);
    }
#endif // DEBUG
    
    // Encode 2 nibbles as a single byte
    
    encode(nibbles, merged);
  }
  
  return;
}

// Decode N nibbles into a vector of bytes

static inline
void
decodeNibbles(const vector<uint8_t> &buf, int & offset, vector<uint8_t> &nibbles)
{
  uint32_t N;
  
  nibbles.clear();
  
  offset = 0;
  decode(buf, offset, N);
  N *= 2;
  
  for ( int i = 0; i < N; i += 2 ) {
    uint8_t merged, b1, b2;
    
    decode(buf, offset, merged);
    
    b1 = merged & 0xF;
    b2 = (merged >> 4) & 0xF;
    
    nibbles.push_back(b1);
    nibbles.push_back(b2);
  }
  
  return;
}

// Encode a number of bits into bytes in blocks of 8.
// This logic writes the number of bits as an initial
// 32 bit word.

template <typename T>
vector<uint8_t>
encodeNBits(const vector<T> &numbers)
{
  vector<uint8_t> buf;
  
  assert(numbers.size() <= 0xFFFFFFFF);

  uint32_t N = (uint32_t) numbers.size();
  
  encode(buf, N);
  
  int numBytes = N / 8;
  int numOver = (N % 8);
  
  int bytei = 0;
  
  for ( ; bytei < numBytes; bytei++ ) {
    uint32_t bVal = 0;
    
    for ( int j = 0; j < 8; j++ ) {
      T val = numbers[(bytei * 8) + j];
      if (val != 0) {
        val = 1;
      }
      bVal |= ((uint32_t) val) << j;
    }
  
    buf.push_back((uint8_t) bVal);
  }
  
  if (numOver) {
    uint32_t bVal = 0;
    
    for ( int j = 0; j < numOver; j++ ) {
      T val = numbers[(bytei * 8) + j];
      if (val != 0) {
        val = 1;
      }
      bVal |= ((uint32_t) val) << j;
    }
    
    buf.push_back((uint8_t) bVal);
  }
  
  return std::move(buf);
}

// Read a number of bits as a 32 bit integer and then store those bits
// as either zero or 1 in the output bytes.

static inline
void
decodeNBits(const vector<uint8_t> & buf, int & offset, vector<uint8_t> & bitValues)
{
  uint32_t N;
  
  bitValues.clear();
  
  offset = 0;
  decode(buf, offset, N);
  
  int numBytes = N / 8;
  int numOver = (N % 8);
  
  int bytei = 0;
  
  for ( ; bytei < numBytes; bytei++ ) {
    uint8_t bVal;
    decode(buf, offset, bVal); // read 1 byte
    
    for ( int j = 0; j < 8; j++ ) {
      uint8_t val = (bVal >> j) & 0x1;
      bitValues.push_back(val);
    }
  }
  
  if (numOver) {
    uint8_t bVal;
    decode(buf, offset, bVal); // read 1 byte
    
    for ( int j = 0; j < numOver; j++ ) {
      uint8_t val = (bVal >> j) & 0x1;
      bitValues.push_back(val);
    }
  }
  
  return;
}

// Generate deltas between i and i+1 in the vector. This logic accepts only
// values that are known to be in increasing int order.

template <typename T>
vector<T>
encodePlusDelta(const vector<T> &ascOrderVec, const bool minusOne = false)
{
  T prev;
  vector<T> deltas;
  deltas.reserve(ascOrderVec.size());
  
  // The first value is always a delta from zero, so handle it before
  // the loop logic.
  
  {
    T val = ascOrderVec[0];
    deltas.push_back(val);
    prev = val;
  }
  
  int maxi = (int) ascOrderVec.size();
  for (int i = 1; i < maxi; i++) {
    T val = ascOrderVec[i];
#if defined(DEBUG)
    assert(val > prev); // Next number must be larger, so that delta can be stored as (d-1)
#endif // DEBUG
    T delta = val - prev;
    if (minusOne) {
      delta -= 1;
    }
    deltas.push_back(delta);
    prev = val;
  }
  
  return std::move(deltas);
}

template <typename T>
void
encodePlusDeltaDirect(vector<T> & inOutVec, const bool minusOne = false)
{
  T prev;
  
#if defined(DEBUG)
  assert(inOutVec.size() > 0);
#endif // DEBUG
  
  // The first value is always a delta from zero, so handle it before
  // the loop logic.
  
  {
    prev = inOutVec[0];
  }
  
  int maxi = (int) inOutVec.size();
  for (int i = 1; i < maxi; i++) {
    T val = inOutVec[i];
#if defined(DEBUG)
    assert(val > prev); // Next number must be larger, so that delta can be stored as (d-1)
#endif // DEBUG
    T delta = val - prev;
    if (minusOne) {
      delta -= 1;
    }
    inOutVec[i] = delta;
    prev = val;
  }
  
  return;
}

// Generate signed delta, note that this method supports repeated value that delta to zero

template <typename T>
vector<T>
encodeDelta(const vector<T> & orderVec)
{
  T prev;
  vector<T> deltas;
  deltas.reserve(orderVec.size());
  
  // The first value is always a delta from zero, so handle it before
  // the loop logic.
  
  {
    T val = orderVec[0];
    deltas.push_back(val);
    prev = val;
  }
  
  int maxi = (int) orderVec.size();
  for (int i = 1; i < maxi; i++) {
    T val = orderVec[i];
    T delta = val - prev;
    deltas.push_back(delta);
    prev = val;
  }
  
  return std::move(deltas);
}

// Apply positive deltas between i and i+1. These deltas values must have been encoded
// with encodePlusDelta().

template <typename T>
vector<T>
decodePlusDelta(const vector<T> &deltas, const bool minusOne = false)
{
  T prev;
  vector<T> values;
  values.reserve(deltas.size());
  
  // The first value is always a delta from zero, so handle it before
  // the loop logic.
  
  {
    T val = deltas[0];
    values.push_back(val);
    prev = val;
  }
  
  int maxi = (int) deltas.size();
  for (int i = 1; i < maxi; i++) {
    T delta = deltas[i];
    if (minusOne) {
      delta += 1;
    }
    T val = prev + delta;
    values.push_back(val);
    prev = val;
  }
  
  return std::move(values);
}

template <typename T>
vector<T>
decodeDelta(const vector<T> &deltas)
{
  return decodePlusDelta(deltas, false);
}

// Same as decodePlusDelta except that the decoding operation is done in place
// and no vector allocation is needed.

template <typename T>
void
decodePlusDeltaDirect(vector<T> & deltas, const bool minusOne)
{
  T prev;
  
  // The first value is always a delta from zero, so handle it before
  // the loop logic.
  
#if defined(DEBUG)
  assert(deltas.size() > 0);
#endif // DEBUG
  
  {
    prev = deltas[0];
  }
  
  int maxi = (int) deltas.size();
  for (int i = 1; i < maxi; i++) {
    T delta = deltas[i];
    if (minusOne) {
      delta += 1;
    }
    T val = prev + delta;
    deltas[i] = val;
    prev = val;
  }
  
  return;
}

// Same as decodePlusDelta except that the decoding operation is done in place
// and no vector allocation is needed.

template <typename T>
void
decodePlusDeltaDirect(T *deltasPtr, int n, const bool minusOne)
{
    T prev;
    
    // The first value is always a delta from zero, so handle it before
    // the loop logic.
    
    {
        prev = deltasPtr[0];
    }
    
    for (int i = 1; i < n; i++) {
        T delta = deltasPtr[i];
        if (minusOne) {
            delta += 1;
        }
        T val = prev + delta;
        deltasPtr[i] = val;
        prev = val;
    }
    
    return;
}

// Delta encoding that supports a delta of zero as a valid value

template <typename T>
vector<T>
encodePlusZeroDelta(const vector<T> &ascOrderVec)
{
  T prev;
  vector<T> deltas;
  deltas.reserve(ascOrderVec.size());
  
  // The first value is always a delta from zero, so handle it before
  // the loop logic.
  
  {
    T val = ascOrderVec[0];
    deltas.push_back(val);
    prev = val;
  }
  
  const int maxi = (int) ascOrderVec.size();
  for (int i = 1; i < maxi; i++) {
    T val = ascOrderVec[i];
    assert(val >= prev);
    T delta = val - prev;
    deltas.push_back(delta);
    prev = val;
  }
  
  return std::move(deltas);
}

template <typename T>
vector<T>
decodePlusZeroDelta(const vector<T> &deltas)
{
  T prev;
  vector<T> values;
  values.reserve(deltas.size());
  
  // The first value is always a delta from zero, so handle it before
  // the loop logic.
  
  {
    T val = deltas[0];
    values.push_back(val);
    prev = val;
  }
  
  int maxi = (int) deltas.size();
  for (int i = 1; i < maxi; i++) {
    T delta = deltas[i];
    T val = prev + delta;
    values.push_back(val);
    prev = val;
  }
  
  return std::move(values);
}

// Encode N elements of 16 bit size as planar
// bytes where each component is C0,C0,...,C1,...

static inline
vector<uint8_t>
encodePlanar16N(const vector<uint16_t> &numbers, bool encodeN)
{
  vector<uint8_t> buf;
  
  assert(numbers.size() <= 0xFFFFFFFF);
  uint32_t N = (uint32_t) numbers.size();
  
  if (encodeN) {
    encode(buf, N);
  }

  vector<uint8_t> encodedLow;
  vector<uint8_t> encodedHigh;
  
  encodedLow.reserve(numbers.size());
  encodedHigh.reserve(numbers.size());
  
  for ( uint16_t val : numbers ) {
    uint8_t low = val & 0xFF;
    uint8_t high = (val >> 8) & 0xFF;
    
    encodedLow.push_back(low);
    encodedHigh.push_back(high);
    
#if defined(DEBUG)
    if ((1)) {
      // Reverse the encoding and compare to original
      
      uint16_t decN;
      
      decN = low;
      decN |= ((uint16_t)high) << 8;
      
      assert(decN == val);
    }
#endif // DEBUG
  }
  
  for ( uint8_t bVal : encodedLow ) {
    buf.push_back(bVal);
  }

  for ( uint8_t bVal : encodedHigh ) {
    buf.push_back(bVal);
  }
  
  return std::move(buf);
}

// Decode N elements of 16 bit size as planar
// bytes where each component is C0,C0,...,C1,...

static inline
vector<uint16_t>
decodePlanar16N(const vector<uint8_t> &encodedPlanarBytes, bool encodeN)
{
    // FIXME: if N was encoded before buffer, read it as uint32_t
    assert(encodeN == false);
    
    int countOfNumbers = (int)encodedPlanarBytes.size() / 2;
    
    vector<uint16_t> numbers;
    numbers.reserve(countOfNumbers);

    int mid = countOfNumbers;
    
    for ( int i = 0; i < countOfNumbers; i++ ) {
        uint16_t low = encodedPlanarBytes[i];
        uint16_t high = encodedPlanarBytes[mid+i];
        
        uint16_t decN;
        
        decN = low;
        decN |= ((uint16_t)high) << 8;
        
        numbers.push_back(decN);
    }
    
    return std::move(numbers);
}

// Encode pairs of byte values where the value in each i,i+1
// byte is known to fit into a halfbyte in the range (0, 15)

static inline
vector<uint8_t>
encodeNibbleN(const vector<uint8_t> &numbers)
{
  vector<uint8_t> buf;
  
  assert(numbers.size() <= 0xFFFFFFFF);
  assert((numbers.size() % 2) == 0); // Must contain even # values
  uint32_t N = (uint32_t) numbers.size() / 2;

  buf.reserve(N + 4);
  
  encode(buf, N);
  
  for (int i=0; i < N; i++) {
    int i2 = i * 2;
    uint8_t pixel1 = numbers[i2];
    uint8_t pixel2 = numbers[i2 + 1];
    
#if defined(DEBUG)
    assert(pixel1 <= 0xF);
    assert(pixel2 <= 0xF);
#endif // DEBUG
    
    uint8_t outByte = (pixel2 << 4) | pixel1;
    
#if defined(DEBUG)
    {
      uint8_t decodedPixel1 = outByte & 0xF;
      uint8_t decodedPixel2 = (outByte >> 4) & 0xF;
      assert(decodedPixel1 == pixel1);
      assert(decodedPixel2 == pixel2);
    }
#endif // DEBUG
    
    buf.push_back(outByte);
  }
  
  return std::move(buf);
}

// Reverse nibble encoding where pairs of nibbles
// are stored in the low and high portion of a byte.

static inline
vector<uint8_t>
decodeNibbleN(const vector<uint8_t> &buf)
{
  vector<uint8_t> values;
  
  // Read the number of pairs N
  
  uint32_t N;
  
  int offset = 0;
  decode(buf, offset, N);
  
  values.reserve(N * 2);
  
  for (int i=0; i < N; i++) {
    uint8_t bVal = buf[offset];
    offset += 1;
    
    uint8_t pixel1 = bVal & 0xF;
    uint8_t pixel2 = (bVal >> 4) & 0xF;
    
    values.push_back(pixel1);
    values.push_back(pixel2);
  }
  
  return std::move(values);
}

#endif // ENC_DEC_H
