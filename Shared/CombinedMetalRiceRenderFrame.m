//
//  CombinedMetalRiceRenderFrame.h
//
//  Copyright 2016 Mo DeJong.
//
//  See LICENSE for terms.
//
//  Refrences to all render frames needed for rice decoding.

#include "CombinedMetalRiceRenderFrame.h"

// Private API

@interface CombinedMetalRiceRenderFrame ()

@end

// Main class performing the rendering
@implementation CombinedMetalRiceRenderFrame

- (NSString*) description
{
  return [NSString stringWithFormat:@"cmRiceRenderFrame %p", self];
}

@end

