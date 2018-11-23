# MetalRice
A GPU based rice decoder for iOS on top of Metal

## Overview
This project implements a GPU decoder for rice based entroy coding. The decoder is implemented on top of Apple's Metal API and as a result it executes quickly with very little CPU usage.

## Decoding Speed

The Metal compute kernel is able to decode 2048x1536 bytes of data in 8-9 ms on an A8-A9 generation processor.

## Implementation
See AAPLRenderer.m and RiceShaders.metal for the core GPU rendering logic.

