/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Metal shaders used for this sample
*/

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Include header shared between this Metal shader code and C code executing Metal API commands

#import "AAPLShaderTypes.h"

#import "MetalUtils.metal"

// Vertex shader outputs and per-fragmeht inputs.  Includes clip-space position and vertex outputs
//  interpolated by rasterizer and fed to each fragment genterated by clip-space primitives.
typedef struct
{
    // The [[position]] attribute qualifier of this member indicates this value is the clip space
    //   position of the vertex wen this structure is returned from the vertex shader
    float4 clipSpacePosition [[position]];

    // Since this member does not have a special attribute qualifier, the rasterizer will
    //   interpolate its value with values of other vertices making up the triangle and
    //   pass that interpolated value to the fragment shader for each fragment in that triangle;
    float2 textureCoordinate;

} RasterizerData;

typedef struct {
  uint8_t symbol;
  uint8_t bitWidth;
} VariableBitWidthSymbol;

// Vertex Function
vertex RasterizerData
vertexShader(uint vertexID [[ vertex_id ]],
             constant AAPLVertex *vertexArray [[ buffer(AAPLVertexInputIndexVertices) ]])
{
    RasterizerData out;

    // Index into our array of positions to get the current vertex
    //   Our positons are specified in pixel dimensions (i.e. a value of 100 is 100 pixels from
    //   the origin)
    float2 pixelSpacePosition = vertexArray[vertexID].position.xy;
  
    // THe output position of every vertex shader is in clip space (also known as normalized device
    //   coordinate space, or NDC).   A value of (-1.0, -1.0) in clip-space represents the
    //   lower-left corner of the viewport wheras (1.0, 1.0) represents the upper-right corner of
    //   the viewport.

    out.clipSpacePosition.xy = pixelSpacePosition;
  
    // Set the z component of our clip space position 0 (since we're only rendering in
    //   2-Dimensions for this sample)
    out.clipSpacePosition.z = 0.0;

    // Set the w component to 1.0 since we don't need a perspective divide, which is also not
    //   necessary when rendering in 2-Dimensions
    out.clipSpacePosition.w = 1.0;

    // Pass our input textureCoordinate straight to our output RasterizerData.  This value will be
    //   interpolated with the other textureCoordinate values in the vertices that make up the
    //   triangle.
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;
    out.textureCoordinate.y = 1.0 - out.textureCoordinate.y;
    
    return out;
}

// Fill texture with gradient from green to blue as Y axis increases from origin at top left

//fragment float4
//fragmentFillShader1(RasterizerData in [[stage_in]],
//                   float4 framebuffer [[color(0)]])
//{
//  return float4(0.0, (1.0 - in.textureCoordinate.y) * framebuffer.x, in.textureCoordinate.y * framebuffer.x, 1.0);
//}

fragment float4
fragmentFillShader2(RasterizerData in [[stage_in]])
{
  return float4(0.0, 1.0 - in.textureCoordinate.y, in.textureCoordinate.y, 1.0);
}

// Fragment function
fragment float4
samplingPassThroughShader(RasterizerData in [[stage_in]],
               texture2d<half, access::sample> inTexture [[ texture(AAPLTextureIndexes) ]])
{
  constexpr sampler s(mag_filter::linear, min_filter::linear);
  
  return float4(inTexture.sample(s, in.textureCoordinate));
  
}

// Fragment function that crops from the input texture while rendering
// pixels to the output texture.

fragment half4
samplingCropShader(RasterizerData in [[stage_in]],
                   texture2d<half, access::read> inTexture [[ texture(0) ]],
                   constant RenderTargetDimensionsAndBlockDimensionsUniform & rtd [[ buffer(0) ]])
{
  // Convert float coordinates to integer (X,Y) offsets
  const float2 textureSize = float2(rtd.width, rtd.height);
  float2 c = in.textureCoordinate;
  const float2 halfPixel = (1.0 / textureSize) / 2.0;
  c -= halfPixel;
  ushort2 iCoordinates = ushort2(round(c * textureSize));
  
  half value = inTexture.read(iCoordinates).x;
  half4 outGrayscale = half4(value, value, value, 1.0h);
  return outGrayscale;
}

// Read pixels from multiple textures and zip results back together

fragment half4
cropAndGrayscaleFromTexturesFragmentShader(RasterizerData in [[stage_in]],
                                           texture2d<half, access::read> inTexture [[ texture(0) ]],
                                           constant RenderTargetDimensionsAndBlockDimensionsUniform & rtd [[ buffer(0) ]])
{
  const ushort blockDim = RICE_SMALL_BLOCK_DIM;
  
  ushort2 gid = calc_gid_from_frag_norm_coord(ushort2(rtd.width, rtd.height), in.textureCoordinate);
  
  // gid to read from is (gid.x/4, gid.y)

  //ushort2 gid2 = ushort2(gid.x/4, gid.y);
  ushort2 gid2 = ushort2(gid.x >> 2, gid.y);
  
  // Calculate blocki in terms of the number of whole blocks in the input texture.
  
  //ushort2 blockRoot = gid / blockDim;
  //ushort2 blockRootCoords = blockRoot * blockDim;
  //ushort2 offsetFromBlockRootCoords = gid - blockRootCoords;
  //ushort offsetFromBlockRoot = (offsetFromBlockRootCoords.y * blockDim) + offsetFromBlockRootCoords.x;
  //ushort slice = (offsetFromBlockRoot / 4) % 16;

  //const ushort blockWidth = rtd.blockWidth;
  //const ushort blockHeight = rtd.blockHeight;
  //const ushort maxNumBlocksInColumn = 8;
  //ushort2 sliceCoord = ushort2(slice % maxNumBlocksInColumn, slice / maxNumBlocksInColumn);
  
  //ushort2 inCoords = blockRoot + ushort2(sliceCoord.x * blockWidth, sliceCoord.y * blockHeight);
  half4 inHalf4 = inTexture.read(gid2);
  
  // For (0, 1, 2, 3, 0, 1, 2, 3, ...) choose (R, G, B, A)
  
  //ushort remXOf4 = gid.x % 4;
  ushort remXOf4 = gid.x & 0x3;
  
  //ushort remXOf4 = offsetFromBlockRoot % 4;
  
//  This logic shows a range bug on A7
//  half4 reorder4 = half4(inHalf4.b, inHalf4.g, inHalf4.r, inHalf4.a);
//  uint bgraPixel = pack_half_to_unorm4x8(reorder4);
//  ushort bValue = (bgraPixel >> (remXOf4 * 8)) & 0xFF;
//  half value = bValue / 255.0h;

  //  This logic shows a range bug on A7
//  uint bgraPixel = uint_from_half4(inHalf4);
//  ushort bValue = (bgraPixel >> (remXOf4 * 8)) & 0xFF;
//  //half value = bValue / 255.0h;
//  return half4(bValue / 255.0h, bValue / 255.0h, bValue / 255.0h, 1.0h);

  // On A7, this array assign logic does not seem to have the bug and it
  // is faster than the if below.
  
  half hArr4[4];
  hArr4[0] = inHalf4.b;
  hArr4[1] = inHalf4.g;
  hArr4[2] = inHalf4.r;
  hArr4[3] = inHalf4.a;
  half value = hArr4[remXOf4];
  
  // This works and does not show the conversion bug, but seems slower than the array impl

  /*
  half value;

  if (remXOf4 == 0) {
    value = inHalf4.b;
  } else if (remXOf4 == 1) {
    value = inHalf4.g;
  } else if (remXOf4 == 2) {
    value = inHalf4.r;
  } else {
    value = inHalf4.a;
  }
  */
  
  half4 outGrayscale = half4(value, value, value, 1.0h);
  return outGrayscale;
}
