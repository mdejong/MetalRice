//
//  ImageData.m
//
//  Created by Moses DeJong on 9/11/13.
//  Copyright (c) 2013 helpurock. All rights reserved.
//

#import "ImageData.h"

#import "CGFrameBuffer.h"

#import "Util.h"

#import <ImageIO/ImageIO.h>

//#import "misc.h"

//#import "xxhash.h"

// adler32

// largest prime smaller than 65536
#define BASE 65521L

// NMAX is the largest n such that 255n(n+1)/2 + (n+1)(BASE-1) <= 2^32-1
#define NMAX 5552

#define DO1(buf, i)  { s1 += buf[i]; s2 += s1; }
#define DO2(buf, i)  DO1(buf, i); DO1(buf, i + 1);
#define DO4(buf, i)  DO2(buf, i); DO2(buf, i + 2);
#define DO8(buf, i)  DO4(buf, i); DO4(buf, i + 4);
#define DO16(buf)    DO8(buf, 0); DO8(buf, 8);

uint32_t my_adler32(
                    uint32_t adler,
                    unsigned char const *buf,
                    uint32_t len,
                    uint32_t singleCallMode)
{
	int k;
	uint32_t s1 = adler & 0xffff;
	uint32_t s2 = (adler >> 16) & 0xffff;
  
	if (!buf)
		return 1;
  
	while (len > 0) {
		k = len < NMAX ? len :NMAX;
		len -= k;
		while (k >= 16) {
			DO16(buf);
			buf += 16;
			k -= 16;
		}
		if (k != 0)
			do {
				s1 += *buf++;
				s2 += s1;
			} while (--k);
		s1 %= BASE;
		s2 %= BASE;
	}
  
  uint32_t result = (s2 << 16) | s1;
  
  if (singleCallMode && (result == 0)) {
    // All zero input, use 0xFFFFFFFF instead
    result = 0xFFFFFFFF;
  }
  
	return result;
}

static inline uint32_t byte_to_grayscale24(uint32_t byteVal)
{
  return ((0xFF << 24) | (byteVal << 16) | (byteVal << 8) | byteVal);
}

@implementation ImageData

+ (ImageData*) imageData
{
  ImageData *obj = [[ImageData alloc] init];
  return obj;
}

// Always calculate final BGRA pixels adler.
// Note that in the case of RGB pixels, the Alpha component is always set to zero.

- (void) calculateBgraAdler
{
  CGFrameBuffer *frameBuffer = self.frameBuffer;
  
    // Adler 32 checksum
    
    uint32_t bgraAdler;
    bgraAdler = my_adler32(0, (const unsigned char*)frameBuffer.pixels, (uint32_t)frameBuffer.numBytes, 1);
    
    self.bgraAdler = bgraAdler;
}

#if !defined(CLIENT_ONLY_IMPL)

- (void) calculateComponentAdlers
{
  if (self.numComponents == 1) {
    [self calculateGrayscaleAdler];
  } else if (self.numComponents == 3 || self.numComponents == 4) {
    // Note that if a non-opaque alpha value is found then we can assume that
    // all alpha values are already premultiplied from ImageIO.
    
    [self calculateRGBAAdler];
  } else {
    assert(0);
  }
}

- (void) scan
{
  CGFrameBuffer *frameBuffer = self.frameBuffer;
  
  [self scanNumComponents];
  
  if (self.numComponents == 1 || self.numComponents == 3) {
    // Input pixels are known to contain all 0xFF alpha values, so these values
    // can now be rewritten with zero. This has to be completed before the
    // initial BGRA adler is generated.
    
    [frameBuffer clearAlphaChannel];
  }
  
  [self calculateBgraAdler];
  
  if (self.useComponentAdlers) {
    [self calculateComponentAdlers];
  }
  
  // Set the width x height values defined in the framebuffer
  
  self.size = CGSizeMake(frameBuffer.width, frameBuffer.height);
  
  return;
}

#endif // CLIENT_ONLY_IMPL

// This decode method should be invoked when decoding from a plist
// and the number of components and the size is already known.
// There is no need to detect these fields in this case.

- (void) decodeAdlerCheck
{
  NSAssert(self.size.width != 0 && self.size.height != 0, @"width and height not set");
  
  if (self.frameBuffer != nil) {
    [self calculateBgraAdler];
    
#if !defined(CLIENT_ONLY_IMPL)
    
    if (self.useComponentAdlers) {
      [self calculateComponentAdlers];
    }
    
#endif // CLIENT_ONLY_IMPL
  }
  
  return;
}

// The initial scan of pixel data needs to determine how many components
// will be required to represent the image data exactly. Input will
// always be in BGRA format. Need to determine if the input is a
// grayscale image, in that case only 1 channel is needed and that
// reduces the image size by about 2/3.

#if !defined(CLIENT_ONLY_IMPL)

- (void) scanNumComponents
{
  // While pixels are being processed check for the case of grayscale RGB
  // data. A grayscale image has balanced R G and B componenets for each
  // pixel. In this case, the entire image can be represented in 1 channel
  // as opposed to 3 different channels.

  CGFrameBuffer *frameBuffer = self.frameBuffer;
  
  int numRows = (int)frameBuffer.width;
  int numCols = (int)frameBuffer.height;
  int i = 0;
  
  uint32_t *pixels = (uint32_t*)frameBuffer.pixels;
  
  BOOL isGrayscale = TRUE;
  BOOL hasAlpha = FALSE;
  
  for (int row = 0; row < numRows; row++) {
    for (int col = 0; col < numCols; col++) {
      uint32_t pixel = pixels[i++];
      
      uint8_t alpha = (pixel >> 24) & 0xFF;
      uint8_t red = (pixel >> 16) & 0xFF;
      uint8_t green = (pixel >> 8) & 0xFF;
      uint8_t blue = (pixel >> 0) & 0xFF;
      
      if ((red != green) || (red != blue)) {
        isGrayscale = FALSE;
      }
      
      if (alpha != 0xFF) {
        // Image uses partial or full transparency
        hasAlpha = TRUE;
        break;
      }
    }
    
    if (hasAlpha) {
      break;
    }
  }
  
  if (hasAlpha) {
    // RGBA
    self.numComponents = 4;
  } else if (isGrayscale) {
    // Grayscale with no alpha
    self.numComponents = 1;
  } else {
    // RGB
    self.numComponents = 3;
  }
  
  self.bpp = 24;
  if (self.numComponents == 4) {
    self.bpp = 32;
  }
}

#endif // CLIENT_ONLY_IMPL

// Setter for self.numComponents property. When setting the number of components,
// also automatically set the bpp field.

- (void) setNumComponents:(uint32_t)numComponents
{
  self->_numComponents = numComponents;

  self.bpp = 24;
  if (numComponents == 4) {
    self.bpp = 32;
  }
}

+ (uint32_t) adlerForData:(NSData*)data
{
  uint32_t adler = my_adler32(0, data.bytes, (uint32_t)data.length, 1);
  return adler;
}

#if !defined(CLIENT_ONLY_IMPL)

// When input data is known to contain only grayscale pixles, generate an
// adler for only the Red components.

- (void) calculateGrayscaleAdler
{
  NSMutableData *redData = [self splitComponents][0];
  uint32_t adler = [self.class adlerForData:redData];
  self.redAdler = adler;
}

// Scan adler value for each channel

- (void) calculateRGBAAdler
{
  NSArray *channels = [self splitComponents];
  uint32_t adler;
  
  adler = [self.class adlerForData:channels[0]];
  self.redAdler = adler;

  adler = [self.class adlerForData:channels[1]];
  self.greenAdler = adler;

  adler = [self.class adlerForData:channels[2]];
  self.blueAdler = adler;
  
  adler = [self.class adlerForData:channels[3]];
  self.alphaAdler = adler;
}

- (NSArray*) splitComponents
{
  NSMutableData *mRedComponenets = [NSMutableData dataWithCapacity:4096];
  NSMutableData *mGreenComponenets = [NSMutableData dataWithCapacity:4096];
  NSMutableData *mBlueComponenets = [NSMutableData dataWithCapacity:4096];
  NSMutableData *mAlphaComponenets = [NSMutableData dataWithCapacity:4096];
  
  // While pixels are being processed check for the case of grayscale RGB
  // data. A grayscale image has balanced R G and B componenets for each
  // pixel. In this case, the entire image can be represented in 1 channel
  // as opposed to 3 different channels.
  
  CGFrameBuffer *frameBuffer = self.frameBuffer;
  
  int numRows = (int)frameBuffer.width;
  int numCols = (int)frameBuffer.height;
  int i = 0;
  
  uint32_t *pixels = (uint32_t*)frameBuffer.pixels;
  
  for (int row = 0; row < numRows; row++) {
    for (int col = 0; col < numCols; col++) {
      uint32_t pixel = pixels[i++];
      
      uint8_t alpha = (pixel >> 24) & 0xFF;
      uint8_t red = (pixel >> 16) & 0xFF;
      uint8_t green = (pixel >> 8) & 0xFF;
      uint8_t blue = (pixel >> 0) & 0xFF;
      
      [mRedComponenets appendBytes:&red length:sizeof(uint8_t)];
      [mGreenComponenets appendBytes:&green length:sizeof(uint8_t)];
      [mBlueComponenets appendBytes:&blue length:sizeof(uint8_t)];
      [mAlphaComponenets appendBytes:&alpha length:sizeof(uint8_t)];
    }
  }

  return @[mRedComponenets, mGreenComponenets, mBlueComponenets, mAlphaComponenets];
}

#endif // CLIENT_ONLY_IMPL

// Create a CGImageRef given a NSData

#if !defined(CLIENT_ONLY_IMPL)

+ (CGImageRef) makeImageFromData:(NSData*)imageData
{
  CGImageSourceRef sourceRef;
  CGImageRef imageRef;
    
  // Create image object from src image data.
  
  sourceRef = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
  
  // Make sure the image source exists before continuing
  
  if (sourceRef == NULL) {
    return nil;
  }
  
  // Create an image from the first item in the image source.
  
  imageRef = CGImageSourceCreateImageAtIndex(sourceRef, 0, NULL);
  
  CFRelease(sourceRef);
  
  return imageRef;
}

#endif // CLIENT_ONLY_IMPL

// Create a CGImageRef given a filename. Image data is read from the file

#if !defined(CLIENT_ONLY_IMPL)

+ (CGImageRef) makeImageFromFile:(NSString*)filenameStr
{
  CGImageSourceRef sourceRef;
  CGImageRef imageRef;
  
  NSData *image_data = [NSData dataWithContentsOfFile:filenameStr];
  if (image_data == nil) {
    fprintf(stderr, "can't read image data from file \"%s\"\n", [filenameStr UTF8String]);
    exit(1);
  }
  
  // Create image object from src image data.
  
  sourceRef = CGImageSourceCreateWithData((__bridge CFDataRef)image_data, NULL);
  
  // Make sure the image source exists before continuing
  
  if (sourceRef == NULL) {
    fprintf(stderr, "can't create image data from file \"%s\"\n", [filenameStr UTF8String]);
    exit(1);
  }
  
  // Create an image from the first item in the image source.
  
  imageRef = CGImageSourceCreateImageAtIndex(sourceRef, 0, NULL);
  
  CFRelease(sourceRef);
  
  return imageRef;
}

#endif // CLIENT_ONLY_IMPL

// Given an input image, examine the image and the colorspace it is
// defined in and then set the proper colorspace on the passed in
// frameBuffer.

#if !defined(CLIENT_ONLY_IMPL)

+ (BOOL) setupColorspaceAndRender:(CGFrameBuffer*)frameBuffer
                         imageRef:(CGImageRef)imageRef
{

  // What colorspace does CoreGraphics think this image is defined in?
  
  //CGColorSpaceRef detectedColorspace = CGImageGetColorSpace(imageRef);
  
  // Ignore the colorspace by setting the framebuffer colorspace to the same value. This will ensure
  // that no tricky colorspace conversion happens by default when an untagged image is read. The result
  // of this invocation is that the exact RGB pixels define in the image file are grabbed.
  
  //frameBuffer.colorspace = detectedColorspace;
  
  // Query the colorspace used in the input image. Note that if no ICC tag was used then assume sRGB.
  
  CGColorSpaceRef inputColorspace;
  inputColorspace = CGImageGetColorSpace(imageRef);
  // output colorspace will always be something (RGB)
  assert(inputColorspace);
  
  BOOL inputIsRGBColorspace = FALSE;
  BOOL inputIsSRGBColorspace = FALSE;
  BOOL inputIsGrayColorspace = FALSE;
  
  {
    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
    
    NSString *colorspaceDescription = (__bridge_transfer NSString*) CGColorSpaceCopyName(colorspace);
    NSString *inputColorspaceDescription = (__bridge_transfer NSString*) CGColorSpaceCopyName(inputColorspace);
    
    if ([colorspaceDescription isEqualToString:inputColorspaceDescription]) {
      inputIsRGBColorspace = TRUE;
    }
    
    CGColorSpaceRelease(colorspace);
  }
  
  {
    CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    
    NSString *colorspaceDescription = (__bridge_transfer NSString*) CGColorSpaceCopyName(colorspace);
    NSString *inputColorspaceDescription = (__bridge_transfer NSString*) CGColorSpaceCopyName(inputColorspace);
    
    if ([colorspaceDescription isEqualToString:inputColorspaceDescription]) {
      inputIsSRGBColorspace = TRUE;
    }
    
    CGColorSpaceRelease(colorspace);
  }

  {
    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceGray();
    
    // ICC gray (not the default)
    
    // FIXME: is it possible that input could be tagged as generic gray and then
    // this device check would not detect it?
    
    //CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceGenericGray);
    
    NSString *colorspaceDescription = (__bridge_transfer NSString*) CGColorSpaceCopyName(colorspace);
    NSString *inputColorspaceDescription = (__bridge_transfer NSString*) CGColorSpaceCopyName(inputColorspace);
    
    if ([colorspaceDescription isEqualToString:inputColorspaceDescription]) {
      inputIsGrayColorspace = TRUE;
    }
    
    CGColorSpaceRelease(colorspace);
  }
  
  if (inputIsRGBColorspace) {
    assert(inputIsSRGBColorspace == FALSE);
    assert(inputIsGrayColorspace == FALSE);
  }
  if (inputIsSRGBColorspace) {
    assert(inputIsRGBColorspace == FALSE);
    assert(inputIsGrayColorspace == FALSE);
  }
  if (inputIsGrayColorspace) {
    assert(inputIsRGBColorspace == FALSE);
    assert(inputIsSRGBColorspace == FALSE);
  }
  
  // Note that in the case where an ICC colorspace is defined in the image file, the name
  // may not match. So, this logic will then use the defined colorspace and convert to
  // sRGB when rendering.
  
  //assert(inputIsSRGBColorspace || inputIsRGBColorspace || inputIsGrayColorspace);
  
  // Output is always going to be "sRGB", so we have a couple of cases.
  //
  // 1. Input is already in sRGB and output is in sRGB, easy
  // 2. Input is in "GenericRGB" colorspace, so assign this same colorspace to the output
  //    buffer so that no colorspace conversion is done in the render step.
  // 3. If we do not detect sRGB or GenericRGB, then some other ICC profile is defined
  //    and we can convert from that colorspace to sRGB.
  
  BOOL outputSRGBColorspace = FALSE;
  BOOL outputRGBColorspace = FALSE;
  BOOL outputGrayColorspace = FALSE;
  
  if (inputIsSRGBColorspace) {
    outputSRGBColorspace = TRUE;
  } else if (inputIsRGBColorspace) {
    outputRGBColorspace = TRUE;
  } else if (inputIsGrayColorspace) {
    outputGrayColorspace = TRUE;
  } else {
    // input is not sRGB and it is not GenericRGB, so convert from this colorspace
    // to the sRGB colorspace during the render operation.
    outputSRGBColorspace = TRUE;
  }
  
  // Use sRGB colorspace when rendering image pixels to the framebuffer.
  // This is needed when using a custom color space to avoid problems
  // related to storing the exact original input pixels.
  
  if (outputSRGBColorspace) {
    CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    frameBuffer.colorspace = colorspace;
    CGColorSpaceRelease(colorspace);
  } else if (outputRGBColorspace) {
    // Weird case where input RGB image was automatically assigned the GenericRGB colorspace,
    // use the same colorspace when rendering so that no colorspace conversion is done.
    // Then after rendering, set the colorspace of the framebuffer to sRGB so that any
    // future rendering or saving will treat pixels as sRGB.
    
    frameBuffer.colorspace = inputColorspace;
    
    fprintf(stdout, "treating input pixels as sRGB since image does not define an ICC color profile\n");
  } else if (outputGrayColorspace) {
    // Grayscale input should just render into the 24 or 32 BPP output, but it actually
    // silently corrupts the data during a colorspace conversion. Avoid this problem by
    // getting at the 8bpp pixels directly and then doing an explicit copy of the
    // expanded 24BPP pixel values.
    
    uint32_t width = (uint32_t) frameBuffer.width;
    uint32_t height = (uint32_t) frameBuffer.height;
    
    uint8_t *grayImage = (uint8_t *) malloc(width * height * sizeof(uint8_t));
    
    const size_t bitsPerComponent = 8;
    const size_t bytesPerRow = width;
    
    CGContextRef context = CGBitmapContextCreate(grayImage,
                                                 width, height,
                                                 bitsPerComponent,
                                                 bytesPerRow,
                                                 inputColorspace,
                                                 (CGBitmapInfo)kCGImageAlphaNone);
    
    //CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextSetShouldAntialias(context, NO);
    
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), imageRef);
    CGContextRelease(context);
    
    // Copy pixels into frameBuffer
    
    uint32_t *frameBufferPixelPtr = (uint32_t*) frameBuffer.pixels;
    
    for (int i=0; i < (width * height); i++) {
      uint32_t grayByte = grayImage[i];
      uint32_t pixel = (0xFF << 24) | (grayByte << 16) | (grayByte << 8) | grayByte;
      frameBufferPixelPtr[i] = pixel;
    }
    
    free(grayImage);
  } else {
    assert(0);
  }
  
  if (outputGrayColorspace == FALSE) {
    BOOL worked = [frameBuffer renderCGImage:imageRef];
    assert(worked);
  }
  
  if (outputRGBColorspace || outputGrayColorspace) {
    // Assign the sRGB colorspace to the framebuffer so that if another render
    // is done, the colorspace of this framebuffer can be queried to determine
    // the proper colorspace ref to use. When this method completes, the
    // colorspace of the framebuffer must be the sRGB colorspace.
    
    CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    frameBuffer.colorspace = colorspace;
    CGColorSpaceRelease(colorspace);
  }

  return TRUE;
}

#endif // CLIENT_ONLY_IMPL

// Given a filename, read BGRA data from the file and load the results into
// a framebuffer. This function seems straightforward, but it is amazingly
// complex because of the way that ImageIO deals with colorspaces. The output
// needs to be defined in the sRGB colorspace, but untagged image data could
// lead to some really funky conversions that corrupt the image data. Basically,
// any untagged image is treated as sRGB data. If an image has an ICC profile,
// then that profile is used to convert pixel to the sRGB colorspace.

#if !defined(CLIENT_ONLY_IMPL)

+ (CGFrameBuffer*) readFramebufferFromFile:(NSString*)filename
{
  // Read PNG using ImageIO layer
  
  CGImageRef imageRef = [self makeImageFromFile:filename];
	if (imageRef == NULL) {
		fprintf(stderr, "can't read image from file \"%s\"\n", [filename UTF8String]);
		exit(1);
	}
  
  int width = (int)CGImageGetWidth(imageRef);
  int height = (int)CGImageGetHeight(imageRef);
  
  // What is the largest possible size that can be supported ?
  // Should this be 4096 or 2048 ? Seems to be limited by the max
  // size of a texture, but a texture could still be rendered with
  // two API calls in an extreme case.
  
  //int isSizeOkay = check_max_size(imageWidth, imageHeight, bppNum);
  //if (!isSizeOkay) { return nil; }
  
  // General logic is to assume sRGB colorspace since that is what the iOS device assumes.
  //
  // SRGB
  // https://gist.github.com/1130831
  // http://www.mailinglistarchive.com/html/quartz-dev@lists.apple.com/2010-04/msg00076.html
  // http://www.w3.org/Graphics/Color/sRGB.html (see alpha masking topic)
  //
  // Render from input (if it has an ICC profile) into sRGB, this could involve conversions
  // but it makes the results portable and it basically better because it is still as
  // lossless as possible given the constraints. We only deal with sRGB tagged data
  // once this conversion is complete.
  
  // BPP is not known unless image declares that it contains only 24BPP pixels.
  // An image that contains 32BPP pixels might actually only contain 24BPP pixels.
  
  int bppNum = -1;
  int checkAlphaChannel = 1;
  
  int detectedBPP = (int) CGImageGetBitsPerPixel(imageRef);
  
  if (detectedBPP == 24) {
    bppNum = 24;
    checkAlphaChannel = 0;
  }
  
  if (detectedBPP == 8) {
    bppNum = 24;
    checkAlphaChannel = 0;
  } else if (detectedBPP == 24) {
    // Detected as 24BPP means no alpha channel
    bppNum = 24;
  } else {
    if (checkAlphaChannel) {
      // Might be 24BPP or might be 32BPP
      bppNum = 32;
    } else {
      bppNum = 32;
    }
  }
  
  if (checkAlphaChannel) @autoreleasepool {
    // In the case of 32BPP input and it is not clear if the 32BPP pixels are all
    // opaque, need to read the pixels and scan them to see if the data is
    // really 24BPP.
    
    assert(bppNum == 32);
    CGFrameBuffer *scanFrameBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];
    
    [self setupColorspaceAndRender:scanFrameBuffer imageRef:imageRef];
    
    // Scan the alpha values in the framebuffer to determine if any of the pixels have a non-0xFF alpha channel
    // value. If any pixels are non-opaque then the data needs to be treated as 32BPP.
    
    uint32_t *currentPixels = (uint32_t*)scanFrameBuffer.pixels;
    int numPixels = (width * height);
      
    BOOL allOpaque = TRUE;
      
    for (int i=0; i < numPixels; i++) {
      uint32_t currentPixel = currentPixels[i];
        
      // ABGR non-opaque pixel detection
      uint8_t alpha = (currentPixel >> 24) & 0xFF;
      if (alpha != 0xFF) {
        allOpaque = FALSE;
        break;
      }
    }
      
    if (allOpaque) {
      bppNum = 24;
    } else {
      // Leave bppNum = 32
    }
  }
  
  // Scanning could have changed the bpp from 32 to 24 BPP, so kick off another render
  // with the final result BPP.
  
  CGFrameBuffer *frameBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bppNum width:width height:height];

  [self setupColorspaceAndRender:frameBuffer imageRef:imageRef];
  
  if (0) {
    // Dump PNG of image data after decoding from PNG. The data has not
    // been modified by the code at this point, though in the case of
    // 32BPP CoreGraphics can premultiply the alpha channel and pixel values.
    
    NSString *dumpInputPixelsDumpFilename = @"DUMP_input_pixels.png";
    
    NSData *pngData = [frameBuffer formatAsPNG];
    
    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    NSLog(@"cd is %@", cwd);
    NSString *path = [cwd stringByAppendingPathComponent:dumpInputPixelsDumpFilename];
    [pngData writeToFile:path atomically:TRUE];
    
    NSLog(@"wrote %@", dumpInputPixelsDumpFilename);
  }

  CGImageRelease(imageRef);
  
  return frameBuffer;
}

#endif // CLIENT_ONLY_IMPL

#if defined(DEBUG)

// Given an array that contains pixels in NSNumber objects, a fixed width, and
// an output filename, calculate the number of rows and write a PNG

+ (void) dumpArrayOfPixels:(NSArray*)inPixels
                       bpp:(int)bpp
                     width:(int)width
                  filename:(NSString*)filename
{
  [self dumpArrayOfPixels:inPixels bpp:bpp width:width filename:filename premultiplied:TRUE];
}

// Given an array that contains pixels in NSNumber objects, a fixed width, and
// an output filename, calculate the number of rows and write a PNG

+ (NSData*) dumpArrayOfPixels:(NSArray*)inPixels
                          bpp:(int)bpp
                        width:(int)width
                     filename:(NSString*)filename
                premultiplied:(BOOL)premultiplied
{
  int pixelCount = (int) inPixels.count;
  int height = pixelCount / width;
  if ((pixelCount % width) != 0) {
    height += 1;
  }
  if (height == 0) {
    height = 1;
  }

  // BMP output needs some special handling
  
  BOOL isBMP = FALSE;
  
  if ([filename hasSuffix:@".png"]) {
    // No-op
  } else if ([filename hasSuffix:@".bmp"]) {
    isBMP = TRUE;
  } else {
    NSAssert(FALSE, @"unmatched image suffix \"%@\"", filename);
  }
  
  CGFrameBuffer *frameBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:bpp width:width height:height];
  
  // Framebuffer should always be assumed to be in the sRGB colorspace, it is critical to set this property
  // before writing the framebuffer so that the ImageIO library will write the proper metadata to indicate
  // the colorspace in the emitted image.
  
#if TARGET_OS_IPHONE
  // No-op
#else
  if (isBMP == FALSE) {
    // Do not mark BMP as sRGB colorspace since the output pixels would be modified
    CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    frameBuffer.colorspace = colorspace;
    CGColorSpaceRelease(colorspace);
  }
#endif // TARGET_OS_IPHONE
  
  uint32_t *pixelPtr = (uint32_t*) frameBuffer.pixels;
  
  for (NSNumber *pixelNum in inPixels) {
    uint32_t pixel = [pixelNum unsignedIntValue];
    *pixelPtr++ = pixel;
  }
  
//  if (bpp == 24) {
//  [frameBuffer resetAlphaChannel];
//  }
  
#if TARGET_OS_IPHONE
  // No-op
#else
  if (premultiplied == FALSE) {
    // CGFrameBuffer defaults to pre-multiplied pixels
    frameBuffer.nonPremultiplied = TRUE;
  }
#endif // TARGET_OS_IPHONE
  
  NSData *imageData;
  
  if (isBMP == FALSE) {
    imageData = [frameBuffer formatAsPNG];
  } else if (isBMP) {
    imageData = [frameBuffer formatAsBMP];
  } else {
    NSAssert(FALSE, @"unmatched image suffix \"%@\"", filename);
  }
  
  NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
  //NSLog(@"cd is %@", cwd);
  NSString *path = [cwd stringByAppendingPathComponent:filename];
  [imageData writeToFile:path atomically:TRUE];
  
  NSLog(@"wrote %@", filename);
  
  return imageData;
}

// Dump grayscale pixels as 24 BPP PNG image

+ (void) dumpArrayOfGrayscale:(NSArray*)inGrayscale
                        width:(int)width
                     filename:(NSString*)filename
{
  NSMutableArray *mArr = [NSMutableArray array];
  
  for (NSNumber *grayNum in inGrayscale) {
    uint8_t gray = [grayNum unsignedCharValue];
    uint32_t pixel = byte_to_grayscale24(gray);
    [mArr addObject:@(pixel)];
  }
  
  [ImageData dumpArrayOfPixels:mArr
                           bpp:24
                         width:width
                      filename:filename];
}

// Dump an image in a block separated form with 2 black pixels splitting each
// block.

- (void) dumpBlockSpacedImage:(NSString*)filePath
                       blocks:(NSArray*)blocks
                         size:(CGSize)size
{
  // At this point pixel have been read from the image file into
  // BGRA pixel values. The initial reading logic and histogram
  // scanning logic should be solid, but might need to verify
  // by dumping to output files, so do that here.
  
  uint32_t width = (uint32_t)size.width;
  uint32_t height = (uint32_t)size.height;
  
  uint32_t blockSize = 32;
  
  uint32_t numBlocksInWidth = width / blockSize;
  if ((width % blockSize) != 0) {
    numBlocksInWidth += 1;
  }
  uint32_t numBlocksInHeight = height / blockSize;
  if ((height % blockSize) != 0) {
    numBlocksInHeight += 1;
  }
  
  assert(blocks.count > 0);
  
  // Create array of blocks with +2 for the width and height
  
  NSMutableArray *flatBlocksWithBorders = [NSMutableArray array];
  
  uint32_t blockBorderDimension = blockSize + 2;
  
  NSMutableArray *emptyValues = [NSMutableArray array];
  
  NSNumber *grayNum = [NSNumber numberWithUnsignedInt:0xFF7F7F7F];
  
  for (int i=0; i < blockBorderDimension*blockBorderDimension; i++) {
    [emptyValues addObject:grayNum];
  }
  
  for (NSArray *block in blocks) @autoreleasepool {
    NSMutableArray *newBlock = [NSMutableArray arrayWithArray:emptyValues];
    
    for (uint32_t row=0; row < blockSize; row++) {
      for (uint32_t col=0; col < blockSize; col++) {
        uint32_t index = (row * blockSize) + col;
        
        NSNumber *pixel = [block objectAtIndex:index];
        
        uint32_t outIndex = (row * blockBorderDimension) + col;
        
        [newBlock replaceObjectAtIndex:outIndex withObject:pixel];
      }
    }
    
    [flatBlocksWithBorders addObjectsFromArray:newBlock];
  }
  
  // Flatten blocks
  
  assert(flatBlocksWithBorders.count > 0);
  
  NSArray *flatValues = [Util flattenBlocksOfSize:blockBorderDimension values:flatBlocksWithBorders numBlocksInWidth:numBlocksInWidth];
  
  NSAssert(flatValues.count == numBlocksInWidth*numBlocksInHeight*blockBorderDimension*blockBorderDimension, @"num mismatch");
  
  // Copy pixel values to framebuffer and write as PNG
  
  CGFrameBuffer *frameBuffer = self.frameBuffer;
  
  CGFrameBuffer *copyFrameBuffer = [CGFrameBuffer cGFrameBufferWithBppDimensions:frameBuffer.bitsPerPixel
                                                                           width:numBlocksInWidth*blockBorderDimension
                                                                          height:numBlocksInHeight*blockBorderDimension];
  
  copyFrameBuffer.colorspace = frameBuffer.colorspace;
  
  uint32_t *pixelPtr = (uint32_t*) copyFrameBuffer.pixels;
  
  for (NSNumber *pixelNum in flatValues) {
    uint32_t pixel = [pixelNum unsignedIntValue];
    *pixelPtr++ = pixel;
  }
  
  if (copyFrameBuffer.bitsPerPixel == 24) {
    [copyFrameBuffer resetAlphaChannel];
  }
  
  NSData *pngData = [copyFrameBuffer formatAsPNG];
  
  NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
  //NSLog(@"cd is %@", cwd);
  NSString *path = [cwd stringByAppendingPathComponent:filePath];
  [pngData writeToFile:path atomically:TRUE];
  
  NSLog(@"wrote %@", filePath);
  
  return;
}

#endif // DEBUG

@end
