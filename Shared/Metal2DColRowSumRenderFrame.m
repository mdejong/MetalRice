//
//  Metal2DColRowSumRenderFrame.m
//
//  Copyright 2016 Mo DeJong.
//
//  See LICENSE for terms.
//
//  This module references Metal objects that are used to render
//  a 2D sum, first column 0 is summed along the Y axis, then
//  each row is summed. There can be N render frames
//  associates with a single render context.

#include "Metal2DColRowSumRenderFrame.h"

#include "MetalRenderContext.h"

// Private API

@interface Metal2DColRowSumRenderFrame ()

@end

// Main class performing the rendering
@implementation Metal2DColRowSumRenderFrame

- (NSString*) description
{
  return [NSString stringWithFormat:@"m2dcrsRenderFrame %p : W x H %d x %d",
          self,
          (int)self.width,
          (int)self.height];
}

@end

