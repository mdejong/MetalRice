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

@class MetalRice2RenderFrame;
//@class Metal2DColRowSumRenderFrame;
@class MetalCropToTextureRenderFrame;

@interface CombinedMetalRiceRenderFrame : NSObject

@property (nonatomic, retain) MetalRice2RenderFrame *metalRiceRenderFrame;

//@property (nonatomic, retain) Metal2DColRowSumRenderFrame *metalRowcolRenderFrame;

@property (nonatomic, retain) MetalCropToTextureRenderFrame *metalCropToTextureRenderFrame;

@end
