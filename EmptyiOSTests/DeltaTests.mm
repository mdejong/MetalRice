//
//  DeltaTests.mm
//
//  Created by Mo DeJong on 8/26/18.
//

#import <XCTest/XCTest.h>

#import "prefix_sum.h"

#import "EncDec.hpp"

#import "DeltaEncoder.h"

#import <vector>

@interface DeltaTests : XCTestCase

@end

@implementation DeltaTests

- (void)setUp {
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the class.
}

- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

// Recursive doubling on byte values, this shader will
// read values from input into shared memory and then
// execute a single recursive doubling pass.

- (void)testDeltaEncodeDecode8Bytes {
  
  uint8_t inBytes[] = {
    1, 2, 4, 7, 11, 16, 23, 31
  };

  uint8_t deltas[8];
  uint8_t decoded[8];

  memcpy(deltas, inBytes, sizeof(inBytes));
  
  bytedelta_generate_deltas(deltas, sizeof(deltas));
  
  memcpy(decoded, deltas, sizeof(deltas));

  bytedelta_decode_deltas(decoded, sizeof(decoded));
  
  //bytedelta_decode_deltas_64(decoded, sizeof(decoded));

  //bytedelta_decode_deltas_64_write_bytes(decoded, sizeof(decoded));
  
  int cmp = memcmp(inBytes, decoded, sizeof(decoded));

  XCTAssert(cmp == 0);
}

- (void)testDeltaEncodeDecode2048 {
  
  std::vector<uint8_t> vecBytes;
  
  int numBytes = 2048 * 1536;
  vecBytes.resize(numBytes);
  
  for (int i = 0; i < numBytes; i++) {
    vecBytes[i] = i;
  }
  
  std::vector<uint8_t> copyBytes;
  
  copyBytes = vecBytes;
  
  bytedelta_generate_deltas(vecBytes.data(), (int)vecBytes.size());
  
  bytedelta_decode_deltas(vecBytes.data(), (int)vecBytes.size());
  
  //bytedelta_decode_deltas_64(vecBytes.data(), (int)vecBytes.size());
  
  //bytedelta_decode_deltas_64_write_bytes(vecBytes.data(), (int)vecBytes.size());
  
  bool same = (copyBytes == vecBytes);
  
  XCTAssert(same);
}


- (void)testPerformance2048 {
  
  std::vector<uint8_t> vecBytes;
  
  int numBytes = 2048 * 1536;
  vecBytes.resize(numBytes);
  
  for (int i = 0; i < numBytes; i++) {
    vecBytes[i] = i;
  }
  
  std::vector<uint8_t> copyBytes;
  
  copyBytes = vecBytes;
  
  bytedelta_generate_deltas(vecBytes.data(), (int)vecBytes.size());

  uint8_t *bytePtr = vecBytes.data();
  
  //std::vector<uint8_t> * vecPtr = &vecBytes;
  
  [self measureBlock:^{
    // Get a metal command buffer, render compute invocation into it
    
    CFTimeInterval start = CACurrentMediaTime();

    bytedelta_decode_deltas(bytePtr, numBytes);
    
    CFTimeInterval stop = CACurrentMediaTime();
    
    NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  }];
  
}

- (void)testPerformance2048_64 {
  
  std::vector<uint8_t> vecBytes;
  
  int numBytes = 2048 * 1536;
  vecBytes.resize(numBytes);
  
  for (int i = 0; i < numBytes; i++) {
    vecBytes[i] = i;
  }
  
  std::vector<uint8_t> copyBytes;
  
  copyBytes = vecBytes;
  
  bytedelta_generate_deltas(vecBytes.data(), (int)vecBytes.size());
  
  uint8_t *bytePtr = vecBytes.data();
  
  //std::vector<uint8_t> * vecPtr = &vecBytes;
  
  [self measureBlock:^{
    // Get a metal command buffer, render compute invocation into it
    
    CFTimeInterval start = CACurrentMediaTime();
    
//    bytedelta_decode_deltas_64(bytePtr, numBytes);

    bytedelta_decode_deltas_64_write_bytes(bytePtr, numBytes);
    
    CFTimeInterval stop = CACurrentMediaTime();
    
    NSLog(@"measured time %.2f ms", (stop-start) * 1000);
  }];
  
}

@end

