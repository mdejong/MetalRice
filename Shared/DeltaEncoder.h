// Objective C interface to elias gamma parsing functions
//  MIT Licensed

#import <Foundation/Foundation.h>

// Our platform independent render class
@interface DeltaEncoder : NSObject

+ (NSData*) encodeByteDeltas:(NSData*)data;

+ (NSData*) decodeByteDeltas:(NSData*)deltas;

@end

// Generate and decode in place

extern "C" {

void bytedelta_generate_deltas(uint8_t *bytePtr, int numBytes);

void bytedelta_decode_deltas(uint8_t *bytePtr, int numBytes);

void bytedelta_decode_deltas_64(uint8_t *bytePtr, int numBytes);

void bytedelta_decode_deltas_64_write_bytes(uint8_t *bytePtr, int numBytes);
  
}
