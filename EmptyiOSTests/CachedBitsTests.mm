//
//  CachedBitsTests.mm
//
//  Created by Mo DeJong on 8/26/18.
//  Copyright © 2018 Apple. All rights reserved.
//
//  Test cached bits reading logic.

#import <XCTest/XCTest.h>

#import "byte_bit_stream.hpp"
#import "rice.hpp"

#define EMIT_CACHEDBITS_DEBUG_OUTPUT
#import "CachedBits.hpp"

using namespace std;

@interface CachedBitsTests : XCTestCase

@end

@implementation CachedBitsTests

- (void)setUp {
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

// Read 64 bits * 2 from pointer and cache 32 of these bits
// in a 32 bit register.

- (void) testCached6432BitsInit1 {
  
  uint8_t inBytes[] = {
    0, 1, 2, 3,
    4, 5, 6, 7,
    8, 9, 10, 11,
    12, 13, 14, 15
  };
  
  const uint64_t *in64Ptr = (const uint64_t *) inBytes;
  
  CachedBits<uint64_t, const uint64_t*, uint32_t, uint32_t> cb;

  cb.initBits(in64Ptr);

  // init read 2 64 bit values from the input stream
  XCTAssert(cb.inPtr == (in64Ptr+2));
  
  XCTAssert(cb.c1NumBits == 64);
  XCTAssert(cb.c2NumBits == 64);

  for (int i = 0; i < 8; i++) {
    uint8_t bVal = (cb.c1 >> (8*i)) & 0xFF;
    XCTAssert(bVal == i);
  }

  for (int i = 0; i < 8; i++) {
    uint8_t bVal = (cb.c2 >> (8*i)) & 0xFF;
    XCTAssert(bVal == (8+i));
  }
  
  return;
}

// Do 32 bit reads and copy bits into 16 bit dst register

- (void) testCached3216BitsInit1 {
  
  uint8_t inBytes[] = {
    0, 1, 2, 3,
    4, 5, 6, 7,
    8, 9, 10, 11,
    12, 13, 14, 15
  };
  
  // Reorder bytes as 32 bit LE
  
  vector<uint8_t> inBytesVec;
  
  for (int i = 0; i < sizeof(inBytes); i++) {
    int bVal = inBytes[i];
    inBytesVec.push_back(bVal);
  }
  
  inBytesVec = PrefixBitStreamRewrite32(inBytesVec);
  
  const uint32_t *in32Ptr = (const uint32_t *) inBytes;
  
  CachedBits<uint32_t, const uint32_t*, uint16_t, uint8_t> cb;
  
  cb.initBits(in32Ptr);
  
  // init read 2 32 bit values from the input stream
  XCTAssert(cb.inPtr == (in32Ptr+2));
  
  XCTAssert(cb.c1NumBits == 32);
  XCTAssert(cb.c2NumBits == 32);
  
  for (int i = 0; i < 4; i++) {
    uint8_t bVal = (cb.c1 >> (8*i)) & 0xFF;
    XCTAssert(bVal == i);
  }
  
  for (int i = 0; i < 4; i++) {
    uint8_t bVal = (cb.c2 >> (8*i)) & 0xFF;
    XCTAssert(bVal == (4+i));
  }
  
  return;
}

// Init and then read from cached bits, reads 64 bits at a time

- (void) testCached6432BitsInit1Read1 {
  
  uint8_t inBytes[] = {
    0, 1, 2, 3,
    4, 5, 6, 7,
    8, 9, 10, 11,
    12, 13, 14, 15,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0
  };
  
  // Reorder bytes as 64 bit LE
  
  vector<uint8_t> inBytesVec;
  
  for (int i = 0; i < sizeof(inBytes); i++) {
    int bVal = inBytes[i];
    inBytesVec.push_back(bVal);
  }

  inBytesVec = PrefixBitStreamRewrite64(inBytesVec);
  
  const uint64_t *in64Ptr = (const uint64_t *) inBytesVec.data();
  
  CachedBits<uint64_t, const uint64_t*, uint32_t, uint32_t> cb;
  
  // Read 32 bits
  
  cb.initBits(in64Ptr);
  
  XCTAssert(cb.c1NumBits == 64);
  XCTAssert(cb.c2NumBits == 64);
  
  uint32_t dstReg = 0;
  uint32_t dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 32);

  XCTAssert(cb.c1NumBits == 32);
  XCTAssert(cb.c2NumBits == 64);
  
  // First 4 bytes from buffer
  
  printf("dstReg 0x%08X\n", dstReg);
  
  for (int i = 0; i < 4; i++) {
    uint8_t bVal = (dstReg >> (24 - 8*i)) & 0xFF;
    XCTAssert(bVal == i);
  }
  
  // Read next 4 bytes
  
  dstReg = 0;
  dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 32);
  
  // First next 4 bytes from buffer
  
  printf("dstReg 0x%08X\n", dstReg);
  
  for (int i = 0; i < 4; i++) {
    uint8_t bVal = (dstReg >> (24 - 8*i)) & 0xFF;
    XCTAssert(bVal == (4+i));
  }

  // Read next 4 bytes
  
  dstReg = 0;
  dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 32);
  
  // First next 4 bytes from buffer
  
  printf("dstReg 0x%08X\n", dstReg);
  
  for (int i = 0; i < 4; i++) {
    uint8_t bVal = (dstReg >> (24 - 8*i)) & 0xFF;
    XCTAssert(bVal == (8+i));
  }

  // Read next 4 bytes
  
  dstReg = 0;
  dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 32);
  
  // First next 4 bytes from buffer
  
  printf("dstReg 0x%08X\n", dstReg);
  
  for (int i = 0; i < 4; i++) {
    uint8_t bVal = (dstReg >> (24 - 8*i)) & 0xFF;
    XCTAssert(bVal == (12+i));
  }

  return;
}

// Read 16,16,16 and then read 32, the 4th read will
// read more bits than are available in the register
// which triggers a partial bit read followed by
// another source read.

- (void) testCached6432BitsInit1Read2 {
  
  uint8_t inBytes[] = {
    0, 1, 2, 3,
    4, 5, 6, 7,
    8, 9, 10, 11,
    12, 13, 14, 15,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0
  };
  
  // Reorder bytes as 64 bit LE
  
  vector<uint8_t> inBytesVec;
  
  for (int i = 0; i < sizeof(inBytes); i++) {
    int bVal = inBytes[i];
    inBytesVec.push_back(bVal);
  }
  
  inBytesVec = PrefixBitStreamRewrite64(inBytesVec);
  
  const uint64_t *in64Ptr = (const uint64_t *) inBytesVec.data();
  
  CachedBits<uint64_t, const uint64_t*, uint32_t, uint32_t> cb;
  
  // Read 32 bits
  
  cb.initBits(in64Ptr);
  
  XCTAssert(cb.c1NumBits == 64);
  XCTAssert(cb.c2NumBits == 64);
  
  uint32_t dstReg = 0;
  uint32_t dstNumBits = 16;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 32);
  
  XCTAssert(cb.c1NumBits == 32+16);
  XCTAssert(cb.c2NumBits == 64);
  
  // Read 2 bytes into lowest 2 bytes of register

  XCTAssert(dstNumBits == 32);
  
  printf("dstReg 0x%08X\n", dstReg);

  XCTAssert(dstReg == 0x00000001);
  
  // Read next 2 bytes
  
  dstReg = 0;
  dstNumBits = 16;
  
  cb.refill(dstReg, dstNumBits);

  XCTAssert(dstNumBits == 32);
  
  printf("dstReg 0x%08X\n", dstReg);
  
  XCTAssert(dstReg == 0x00000203);
  
  // Read 2 bytes
  
  dstReg = 0;
  dstNumBits = 16;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 32);
  
  printf("dstReg 0x%08X\n", dstReg);
  
  XCTAssert(dstReg == 0x00000405);
  
  // 16 bits remain in c1, read 17 bits
  // so that c1 is fully consumed and
  // 1 additional bit has to be loaded
  // from c2
  
  dstReg = 0;
  dstNumBits = 15;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 32);
  
  printf("dstReg 0x%08X\n", dstReg);
  
  XCTAssert(dstReg == 0x00000C0E);
  
  XCTAssert(cb.c1NumBits == 63);
  XCTAssert(cb.c2NumBits == 64);
  
  return;
}

// Do 32 bit reads from a pointer and copy bits into 32 bit register

- (void) testCached3232BitsInit1Read1 {
  
  uint8_t inBytes[] = {
    0, 1, 2, 3,
    4, 5, 6, 7,
    8, 9, 10, 11,
    12, 13, 14, 15,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0
  };
  
  // Reorder bytes as 32 bit LE
  
  vector<uint8_t> inBytesVec;
  
  for (int i = 0; i < sizeof(inBytes); i++) {
    int bVal = inBytes[i];
    inBytesVec.push_back(bVal);
  }
  
  inBytesVec = PrefixBitStreamRewrite32(inBytesVec);
  
  const uint32_t *in32Ptr = (const uint32_t *) inBytesVec.data();
  
  CachedBits<uint32_t, const uint32_t*, uint32_t, uint8_t> cb;
  
  // Read 32 bits
  
  cb.initBits(in32Ptr);
  
  XCTAssert(cb.c1NumBits == 32);
  XCTAssert(cb.c2NumBits == 32);
  
  uint32_t dstReg = 0;
  uint8_t dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 32);
  
  XCTAssert(cb.c1NumBits == 32);
  XCTAssert(cb.c2NumBits == 32);
  
  // First 4 bytes from buffer
  
  printf("dstReg 0x%04X\n", dstReg);
  
  for (int i = 0; i < sizeof(uint32_t); i++) {
    uint8_t bVal = (dstReg >> (24 - 8*i)) & 0xFF;
    XCTAssert(bVal == i);
  }
  
  // Read next 4 bytes
  
  dstReg = 0;
  dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 32);
  
  // First next 4 bytes from buffer
  
  printf("dstReg 0x%08X\n", dstReg);
  
  for (int i = 0; i < sizeof(uint32_t); i++) {
    uint8_t bVal = (dstReg >> (24 - 8*i)) & 0xFF;
    XCTAssert(bVal == (4+i));
  }
  
  // Read next 4 bytes
  
  dstReg = 0;
  dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 32);
  
  // First next 4 bytes from buffer
  
  printf("dstReg 0x%08X\n", dstReg);
  
  for (int i = 0; i < 4; i++) {
    uint8_t bVal = (dstReg >> (24 - 8*i)) & 0xFF;
    XCTAssert(bVal == (8+i));
  }
  
  // Read next 4 bytes
  
  dstReg = 0;
  dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 32);
  
  // First next 4 bytes from buffer
  
  printf("dstReg 0x%08X\n", dstReg);
  
  for (int i = 0; i < 4; i++) {
    uint8_t bVal = (dstReg >> (24 - 8*i)) & 0xFF;
    XCTAssert(bVal == (12+i));
  }
  
  return;
}

// Weird special case where left shift by 32 is
// undefined on a 32 bit register.

- (void) testCached3232ShiftLeft {
  uint8_t inBytes[] = {
    0, 1, 2, 3,
    4, 5, 6, 7,
    0, 0, 0, 0,
    0, 0, 0, 0
  };
  
  // Reorder bytes as 32 bit LE
  
  vector<uint8_t> inBytesVec;
  
  for (int i = 0; i < sizeof(inBytes); i++) {
    int bVal = inBytes[i];
    inBytesVec.push_back(bVal);
  }
  
  inBytesVec = PrefixBitStreamRewrite32(inBytesVec);
  
  const uint32_t *in32Ptr = (const uint32_t *) inBytesVec.data();
  
  CachedBits<uint32_t, const uint32_t*, uint32_t, uint32_t> cb;
  
  // Read 32 bits
  
  cb.initBits(in32Ptr);
  
  XCTAssert(cb.c1NumBits == 32);
  XCTAssert(cb.c2NumBits == 32);
  
  // Read 32 bits into register
  
  uint32_t dstReg = 0;
  uint32_t dstNumBits = 15;
  
  dstReg = 0;
  dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 32);
  
  printf("dstReg 0x%04X\n", dstReg);
  
  XCTAssert(dstReg == 0x00010203);
}

- (void) testCached3216BitsInit1Read1 {
  
  uint8_t inBytes[] = {
    0, 1, 2, 3,
    4, 5, 6, 7,
    8, 9, 10, 11,
    12, 13, 14, 15,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0
  };
  
  // Reorder bytes as 32 bit LE
  
  vector<uint8_t> inBytesVec;
  
  for (int i = 0; i < sizeof(inBytes); i++) {
    int bVal = inBytes[i];
    inBytesVec.push_back(bVal);
  }
  
  inBytesVec = PrefixBitStreamRewrite32(inBytesVec);
  
  const uint32_t *in32Ptr = (const uint32_t *) inBytesVec.data();
  
  CachedBits<uint32_t, const uint32_t*, uint16_t, uint8_t> cb;
  
  // Read 32 bits
  
  cb.initBits(in32Ptr);
  
  XCTAssert(cb.c1NumBits == 32);
  XCTAssert(cb.c2NumBits == 32);
  
  uint16_t dstReg = 0;
  uint8_t dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 16);
  
  XCTAssert(cb.c1NumBits == 16);
  XCTAssert(cb.c2NumBits == 32);
  
  // First 2 bytes from buffer
  
  printf("dstReg 0x%04X\n", dstReg);
  
  for (int i = 0; i < sizeof(dstReg); i++) {
    uint8_t bVal = (dstReg >> ((16-8) - 8*i)) & 0xFF;
    XCTAssert(bVal == i);
  }
  
  // Read next 2 bytes
  
  dstReg = 0;
  dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 16);
  
  XCTAssert(cb.c1NumBits == 32);
  XCTAssert(cb.c2NumBits == 32);
  
  printf("dstReg 0x%04X\n", dstReg);
  
  for (int i = 0; i < sizeof(dstReg); i++) {
    uint8_t bVal = (dstReg >> ((16-8) - 8*i)) & 0xFF;
    XCTAssert(bVal == (2+i));
  }
  
  // Read next 2 bytes
  
  dstReg = 0;
  dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 16);
  
  XCTAssert(cb.c1NumBits == 16);
  XCTAssert(cb.c2NumBits == 32);
  
  // Next 2 bytes from buffer
  
  printf("dstReg 0x%04X\n", dstReg);
  
  for (int i = 0; i < sizeof(dstReg); i++) {
    uint8_t bVal = (dstReg >> ((16-8) - 8*i)) & 0xFF;
    XCTAssert(bVal == (4+i));
  }
  
  // Read next 2 bytes
  
  dstReg = 0;
  dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 16);
  
  printf("dstReg 0x%04X\n", dstReg);
  
  for (int i = 0; i < sizeof(dstReg); i++) {
    uint8_t bVal = (dstReg >> ((16-8) - 8*i)) & 0xFF;
    XCTAssert(bVal == (6+i));
  }
  
  return;
}

// With 32 bit registers, read 16,8,16. The 3th read
// will read more bits than are available in the
// register which triggers a partial bit read
// followed by another source read.

- (void) testCached3216BitsInit1Read2 {
  
  uint8_t inBytes[] = {
    0, 1, 2, 3,
    4, 5, 6, 7,
    8, 9, 10, 11,
    12, 13, 14, 15,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0
  };
  
  // Reorder bytes as 32 bit LE
  
  vector<uint8_t> inBytesVec;
  
  for (int i = 0; i < sizeof(inBytes); i++) {
    int bVal = inBytes[i];
    inBytesVec.push_back(bVal);
  }
  
  inBytesVec = PrefixBitStreamRewrite32(inBytesVec);
  
  const uint32_t *in32Ptr = (const uint32_t *) inBytesVec.data();
  
  CachedBits<uint32_t, const uint32_t*, uint16_t, uint8_t> cb;

  // Read 16 bits
  
  cb.initBits(in32Ptr);
  
  XCTAssert(cb.c1NumBits == 32);
  XCTAssert(cb.c2NumBits == 32);
  
  uint16_t dstReg = 0;
  uint8_t dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 16);
  
  XCTAssert(cb.c1NumBits == 16);
  XCTAssert(cb.c2NumBits == 32);
  
  printf("dstReg 0x%04X\n", dstReg);
  
  XCTAssert(dstReg == 0x0001);
  
  // Read next byte
  
  dstReg = 0;
  dstNumBits = 8;

  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 16);
  
  XCTAssert(cb.c1NumBits == 8);
  XCTAssert(cb.c2NumBits == 32);
 
  printf("dstReg 0x%04X\n", dstReg);

  XCTAssert(dstReg == 0x0002);

  // Read a full 16 bits, there are only 8 bits
  // left in c1 so c2 is copied over c1 to
  // complete the fill.
  
  dstReg = 0;
  dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 16);

  XCTAssert(cb.c1NumBits == 24);
  XCTAssert(cb.c2NumBits == 32);
  
  printf("dstReg 0x%04X\n", dstReg);
  
  XCTAssert(dstReg == 0x0304);
}

// Repeated 1 bits reads into 16 bit register
// from a 32 bit register.

- (void) testCached3216ReadOneBit {
  
  uint8_t inBytes[] = {
    0, 1, 2, 3,
    4, 5, 6, 7,
    8, 9, 10, 11,
    12, 13, 14, 15,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0,
    0, 0, 0, 0
  };
  
  // Reorder bytes as 32 bit LE
  
  vector<uint8_t> inBytesVec;
  
  for (int i = 0; i < sizeof(inBytes); i++) {
    int bVal = inBytes[i];
    inBytesVec.push_back(bVal);
  }
  
  inBytesVec = PrefixBitStreamRewrite32(inBytesVec);
  
  const uint32_t *in32Ptr = (const uint32_t *) inBytesVec.data();
  
  CachedBits<uint32_t, const uint32_t*, uint16_t, uint8_t> cb;
  
  // Read 32 bits
  
  cb.initBits(in32Ptr);
  
  XCTAssert(cb.c1NumBits == 32);
  XCTAssert(cb.c2NumBits == 32);

  // Grab a single bit 8 times, all bit values are off
  
  uint16_t dstReg = 0;
  uint8_t dstNumBits = 15;
  
  for (int i = 0; i < 8; i++) {
    dstReg = 0;
    dstNumBits = 15;
    
    cb.refill(dstReg, dstNumBits);
    
    XCTAssert(dstNumBits == 16);
    
    printf("dstReg 0x%04X\n", dstReg);
    
    XCTAssert(dstReg == 0x0000);
  }
  
  // Next 7 bits are off
  
  for (int i = 0; i < 7; i++) {
    dstReg = 0;
    dstNumBits = 15;
    
    cb.refill(dstReg, dstNumBits);
    
    XCTAssert(dstNumBits == 16);
    
    printf("dstReg 0x%04X\n", dstReg);
    
    XCTAssert(dstReg == 0x0000);
  }
  
  // 8th bit is on, this is the final bit of the byte 0x01
  
  {
    dstReg = 0;
    dstNumBits = 15;
    
    cb.refill(dstReg, dstNumBits);
    
    XCTAssert(dstNumBits == 16);
    
    printf("dstReg 0x%04X\n", dstReg);
    
    XCTAssert(dstReg == 0x0001);
  }
  
  // Read 2 bytes from c1
  
  XCTAssert(cb.c1NumBits == 16);
  XCTAssert(cb.c2NumBits == 32);
}

// Init stream and skip with whole word skips
// but no individual bit skips.

- (void) testCached3216ReadAfterSkip1 {
  
  uint8_t inBytes[] = {
    0, 1, 2, 3,
    4, 5, 6, 7,
    8, 9, 10, 11,
    12, 13, 14, 15,
    0, 0, 0, 0,
    0, 0, 0, 0,
  };
  
  // Reorder bytes as 32 bit LE
  
  vector<uint8_t> inBytesVec;
  
  for (int i = 0; i < sizeof(inBytes); i++) {
    int bVal = inBytes[i];
    inBytesVec.push_back(bVal);
  }
  
  inBytesVec = PrefixBitStreamRewrite32(inBytesVec);
  
  const uint32_t *in32Ptr = (const uint32_t *) inBytesVec.data();
  
  CachedBits<uint32_t, const uint32_t*, uint16_t, uint8_t> cb;
  
  // Read 32 bits
  
  int startingBitOffset = 32 * 1;
  
  cb.initBits(in32Ptr, startingBitOffset);
  
  XCTAssert(cb.c1NumBits == 32);
  XCTAssert(cb.c2NumBits == 32);
  
  // Grab 2 bytes in 16 bit register, should start with byte 4
  
  uint16_t dstReg;
  uint8_t dstNumBits;
  
  dstReg = 0;
  dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 16);
  
  printf("dstReg 0x%04X\n", dstReg);
  
  XCTAssert(dstReg == 0x0405);

  // 2 bytes were read from c1
  
  XCTAssert(cb.c1NumBits == 16);
  XCTAssert(cb.c2NumBits == 32);
}

// Skip 1 word, then skip next 8 bits

- (void) testCached3216ReadAfterSkip2 {
  
  uint8_t inBytes[] = {
    0, 1, 2, 3,
    4, 5, 6, 7,
    8, 9, 10, 11,
    12, 13, 14, 15,
    0, 0, 0, 0,
    0, 0, 0, 0,
  };
  
  // Reorder bytes as 32 bit LE
  
  vector<uint8_t> inBytesVec;
  
  for (int i = 0; i < sizeof(inBytes); i++) {
    int bVal = inBytes[i];
    inBytesVec.push_back(bVal);
  }
  
  inBytesVec = PrefixBitStreamRewrite32(inBytesVec);
  
  const uint32_t *in32Ptr = (const uint32_t *) inBytesVec.data();
  
  CachedBits<uint32_t, const uint32_t*, uint16_t, uint8_t> cb;
  
  // Read 32 bits, then skip 8 bits
  
  int startingBitOffset = (32 * 1) + 8;
  
  cb.initBits(in32Ptr, startingBitOffset);
  
  XCTAssert(cb.c1NumBits == 24);
  XCTAssert(cb.c2NumBits == 32);
  
  // Grab 2 bytes in 16 bit register, should start with byte 4
  
  uint16_t dstReg;
  uint8_t dstNumBits;
  
  dstReg = 0;
  dstNumBits = 0;
  
  cb.refill(dstReg, dstNumBits);
  
  XCTAssert(dstNumBits == 16);
  
  printf("dstReg 0x%04X\n", dstReg);
  
  XCTAssert(dstReg == 0x0506);
  
  // 2 bytes were read from c1
  
  XCTAssert(cb.c1NumBits == 8);
  XCTAssert(cb.c2NumBits == 32);
}

// Skip over 6 initial bits in a stream
// and then read the next few bits.

- (void) testCached3216BitsInitSkip6InStream {
  
  uint8_t inBytes[] = {
    0, 1, 2, 3,
    4, 5, 6, 7,
    8, 9, 10, 11,
    12, 13, 14, 15
  };
  
  // Reorder bytes as 32 bit LE
  
  vector<uint8_t> inBytesVec;
  
  for (int i = 0; i < sizeof(inBytes); i++) {
    int bVal = inBytes[i];
    inBytesVec.push_back(bVal);
  }
  
  inBytesVec = PrefixBitStreamRewrite32(inBytesVec);
  
  const uint32_t *in32Ptr = (const uint32_t *) inBytes;
  
  CachedBits<uint32_t, const uint32_t*, uint16_t, uint8_t> cb;
  
  uint32_t bitOffset = 6;
  
  cb.initBits(in32Ptr, bitOffset);
  
  // init read two 32 bit values from the input stream
  XCTAssert(cb.inPtr == (in32Ptr+2));
  
  XCTAssert(cb.c1NumBits == 32-bitOffset);
  XCTAssert(cb.c2NumBits == 32);

  // Get top 3 bits : should be 110
  
  uint16_t reg = 0;
  uint8_t regN = 0;
  
  cb.refill(reg, regN);
  
  reg >>= (16 - 3);

  int val = reg;
  XCTAssert(val == 6); // 110
  
  return;
}

// Skip over 29 initial bits in a stream
// and then read the next few bits.

- (void) testCached3216BitsInitSkip29InStream {
  
  uint8_t inBytes[] = {
    1, 0, 1, 0,
    1, 0, 1, 0,
    1, 0, 1, 0,
    1, 0, 1, 0
  };
  
  // Reorder bytes as 32 bit LE
  
  vector<uint8_t> inBytesVec;
  
  for (int i = 0; i < sizeof(inBytes); i++) {
    int bVal = inBytes[i];
    inBytesVec.push_back(bVal);
  }
  
  inBytesVec = PrefixBitStreamRewrite32(inBytesVec);
  
  const uint32_t *in32Ptr = (const uint32_t *) inBytes;
  
  CachedBits<uint32_t, const uint32_t*, uint16_t, uint8_t> cb;
  
  uint32_t bitOffset = 29;
  
  cb.initBits(in32Ptr, bitOffset);
  
  // init read two 32 bit values from the input stream
  XCTAssert(cb.inPtr == (in32Ptr+2));
  
  XCTAssert(cb.c1NumBits == 32-bitOffset);
  XCTAssert(cb.c2NumBits == 32);
  
  // Get top 3 bits : should be 110
  
  uint16_t reg = 0;
  uint8_t regN = 0;
  
  cb.refill(reg, regN);
  
  reg >>= (16 - 3);
  
  int val = reg;
  XCTAssert(val == 1);
  
  return;
}

// In certain cases, it can be useful to be able to
// generate an unconditional load that would cause
// a refill to be executed even though the register
// is already full. For example, when k = 0 a set
// of reads can consume zero bits.

- (void) testCached3216RefillWhenFull {
  const uint32_t highOne = ((uint32_t)1) << 31;
  
  uint32_t inBytes[] = {
    highOne,
    0xFF00FF00,
    0x7F7F7F7F
  };
  
  const uint32_t *in32Ptr = (const uint32_t *) inBytes;
  
  CachedBits<uint32_t, const uint32_t*, uint16_t, uint8_t> cb;
  
  // Read 32 bits x 2
  
  cb.initBits(in32Ptr);
  
  // Read 16 bits into register
  
  uint16_t reg = 0;
  uint8_t regN = 0;
  
  cb.refill(reg, regN);
  
  XCTAssert(regN == 16);
  XCTAssert(reg == (highOne >> 16));
  
  XCTAssert(cb.c1NumBits == 16);
  XCTAssert(cb.c1 == 0x00000000);
  XCTAssert(cb.c2NumBits == 32);
  XCTAssert(cb.c2 == 0xFF00FF00);
  
  // Invoke refill() when the dst register is already full. This
  // should not assert, instead it will read zero bits and then OR
  // the dst register with zero which is a nop. Both left and right
  // shift by 16 need to result in zero for this to work properly.
  
  cb.refill(reg, regN, true);
  
  XCTAssert(regN == 16);
  XCTAssert(reg == (highOne >> 16));
  
  XCTAssert(cb.c1NumBits == 16);
  XCTAssert(cb.c1 == 0x00000000);
  XCTAssert(cb.c2NumBits == 32);
  XCTAssert(cb.c2 == 0xFF00FF00);
}

- (void) testCached3232RefillWhenFull {
  const uint32_t highOne = ((uint32_t)1) << 31;
  
  uint32_t inBytes[] = {
    highOne,
    0xFF00FF00,
    0x7F7F7F7F
  };
  
  const uint32_t *in32Ptr = (const uint32_t *) inBytes;
  
  CachedBits<uint32_t, const uint32_t*, uint32_t, uint8_t> cb;
  
  // Read 32 bits x 2
  
  cb.initBits(in32Ptr);
  
  // Read 32 bits into register
  
  uint32_t reg = 0;
  uint8_t regN = 0;
  
  cb.refill(reg, regN);
  
  XCTAssert(regN == 32);
  XCTAssert(reg == highOne);
  
  XCTAssert(cb.c1NumBits == 32);
  XCTAssert(cb.c1 == 0xFF00FF00);
  XCTAssert(cb.c2NumBits == 32);
  XCTAssert(cb.c2 == 0x7F7F7F7F);
  
  // Invoke refill() when the dst register is already full. This
  // should not assert, instead it will read zero bits and then OR
  // the dst register with zero which is a nop. Both left and right
  // shift by 32 need to result in zero for this to work properly.
  
  cb.refill(reg, regN, true);
  
  XCTAssert(regN == 32);
  XCTAssert(reg == highOne);
  
  XCTAssert(cb.c1NumBits == 32);
  XCTAssert(cb.c1 == 0xFF00FF00);
  XCTAssert(cb.c2NumBits == 32);
  XCTAssert(cb.c2 == 0x7F7F7F7F);
}

@end
