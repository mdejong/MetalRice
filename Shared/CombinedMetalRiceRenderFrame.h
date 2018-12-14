//
//  CombinedMetalRiceRenderFrame.h
//
//  Copyright 2016 Mo DeJong.
//
//  See LICENSE for terms.
//
//  Refrences to all render frames needed for rice decoding.

//@import MetalKit;
#include <MetalKit/MetalKit.h>

@class MetalRiceRenderFrame;
@class MetalCropToTextureRenderFrame;

@interface CombinedMetalRiceRenderFrame : NSObject

@property (nonatomic, retain) MetalRiceRenderFrame *metalRiceRenderFrame;

@end
