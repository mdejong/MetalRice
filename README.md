# MetalRice
A GPU based rice decoder for iOS on top of Metal

## Overview
This project implements a GPU decoder for rice based entropy coding. The decoder is implemented on top of Apple's Metal API and as a result it executes quickly with almost no CPU usage.

## Decoding Speed

The Metal compute kernel is able to decode 2048x1536 bytes of data in 8-9 ms on an A8-A9 generation processor. This implementation makes use of a static optimized k table, as opposed to context modeling, so the decoding logic is very efficient.

## Implementation
See AAPLRenderer.m and RiceShaders.metal for the core GPU rendering logic.

