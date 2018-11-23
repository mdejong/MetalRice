//
//  ImageData.h
//
//  Created by Moses DeJong on 9/11/13.
//  Copyright (c) 2013 helpurock. All rights reserved.
//
//  This ImageData object encapsulates basic image data
//  like width and height along with more complex
//  metadata and subsample representations. Different
//  codec formats might want to access some parts of
//  the data but ignore other parts. This class makes
//  it easy to pass around one reference and then
//  the extended data can be queried.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

//#import "misc.h"

@class CGFrameBuffer;

@interface ImageData : NSObject

@property (nonatomic, copy) NSString *inputFilename;

@property (nonatomic, retain) CGFrameBuffer *frameBuffer;

// The width and height of the final output image in pixels

@property (nonatomic, assign) CGSize size;

// An image could include padding to adjust the final width x height
// to even numbers or a specific block size.

@property (nonatomic, assign) CGSize paddedSize;

// This is the number of pixels that appears at the end of each row.

@property (nonatomic, assign) uint32_t rowPadding;

// A grayscale image with only 1 channel has the value
// 1 for this field. A RGB image is 3 and a RGBA image is 4.

@property (nonatomic, assign) uint32_t numComponents;

@property (nonatomic, assign) uint32_t bpp;

// int number of unique pixels in entire image

@property (nonatomic, assign) uint32_t uniqueNumPixels;

@property (nonatomic, assign) uint32_t bgraAdler;

@property (nonatomic, assign) uint32_t bgraH64w0;
@property (nonatomic, assign) uint32_t bgraH64w1;

@property (nonatomic, assign) uint32_t redAdler;
@property (nonatomic, assign) uint32_t greenAdler;
@property (nonatomic, assign) uint32_t blueAdler;
@property (nonatomic, assign) uint32_t alphaAdler;

// This codec property must be set to TRUE for the codec to
// take the extra time to calculate component specific
// adlers as opposed to a combined adler to BGRA.
// This property defaults to FALSE.

@property (nonatomic, assign) BOOL useComponentAdlers;

+ (ImageData*) imageData;

// Scan should be invoked when encoding and only the input pixels
// are know. Scanning will detect the number of components needed
// and then adlers will be calculated.

#if !defined(CLIENT_ONLY_IMPL)

- (void) scan;

#endif // CLIENT_ONLY_IMPL

// This decode method should be invoked when decoding from a plist
// and the number of components and the size is already known.
// There is no need to detect these fields in this case. This
// decode method will also calculate adlers.

- (void) decodeAdlerCheck;

// Split pixels into R G B A components, each one is a NSMutableData
// that contains 1 byte samples

#if !defined(CLIENT_ONLY_IMPL)

- (NSArray*) splitComponents;

#endif // CLIENT_ONLY_IMPL

// Gen adler32 checksum

+ (uint32_t) adlerForData:(NSData*)data;

// Given a filename, read BGRA data from the file and load the results into
// a framebuffer. This function seems straightforward, but it is amazingly
// comple because of the way that ImageIO deals with colorspaces. The output
// needs to be defined in the sRGB colorspace, but untagged image data could
// lead to some really funky conversions that corrupt the image data. Basically,
// any untagged image is treated as sRGB data. If an image has an ICC profile,
// then that profile is used to convert pixel to the sRGB colorspace.

#if !defined(CLIENT_ONLY_IMPL)

+ (CGFrameBuffer*) readFramebufferFromFile:(NSString*)filename;

#endif // CLIENT_ONLY_IMPL

// Load image with ImageIO

#if !defined(CLIENT_ONLY_IMPL)

+ (CGImageRef) makeImageFromData:(NSData*)imageData;

#endif // CLIENT_ONLY_IMPL

// Given an array that contains pixels in NSNumber objects, a fixed width, and
// an output filename, calculate the number of rows and write a PNG

#if defined(DEBUG)

+ (void) dumpArrayOfPixels:(NSArray*)inPixels
                       bpp:(int)bpp
                     width:(int)width
                  filename:(NSString*)filename;

+ (NSData*) dumpArrayOfPixels:(NSArray*)inPixels
                          bpp:(int)bpp
                        width:(int)width
                     filename:(NSString*)filename
                premultiplied:(BOOL)premultiplied;

// Dump grayscale pixels as 24 BPP PNG image

+ (void) dumpArrayOfGrayscale:(NSArray*)inGrayscale
                     width:(int)width
                  filename:(NSString*)filename;

// Dump an image in a block separated form with 2 black pixels splitting each
// block.

- (void) dumpBlockSpacedImage:(NSString*)filePath
                       blocks:(NSArray*)blocks
                         size:(CGSize)size;

#endif // DEBUG

@end
