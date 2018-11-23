//
//  MetalRice2RenderFrame.m
//
//  Copyright 2016 Mo DeJong.
//
//  See LICENSE for terms.
//
//  This module references Metal objects that are used to render
//  rice prefix values read from a stream that is broken up into
//  32 sub streams.

#include "MetalRice2RenderFrame.h"

#include "MetalRenderContext.h"

// Private API

@interface MetalRice2RenderFrame ()

@end

// Main class performing the rendering
@implementation MetalRice2RenderFrame

- (NSString*) description
{
  return [NSString stringWithFormat:@"mrpRenderFrame %p : W x H %d x %d",
          self,
          (int)self.width,
          (int)self.height];
}

@end

