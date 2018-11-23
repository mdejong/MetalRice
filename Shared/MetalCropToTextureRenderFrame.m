//
//  MetalCropToTextureRenderFrame.m
//
//  Copyright 2016 Mo DeJong.
//
//  See LICENSE for terms.
//
//  This module references Metal objects that are used to decode
//  rice encoded data into bytes in a 2D texture.

#include "MetalCropToTextureRenderFrame.h"

#include "MetalRenderContext.h"

// Private API

@interface MetalCropToTextureRenderFrame ()

@end

// Main class performing the rendering
@implementation MetalCropToTextureRenderFrame

- (NSString*) description
{
  return [NSString stringWithFormat:@"mCropToTextureRenderFrame %p : W x H %d x %d",
          self,
          (int)self.width,
          (int)self.height];
}

@end

