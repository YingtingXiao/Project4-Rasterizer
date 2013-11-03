// CIS565 CUDA Rasterizer: A simple rasterization pipeline for Patrick Cozzi's CIS565: GPU Computing at the University of Pennsylvania
// Written by Yining Karl Li, Copyright (c) 2012 University of Pennsylvania

#ifndef RASTERIZEKERNEL_H
#define RASTERIZEKERNEL_H

#include <stdio.h>
#include <thrust/random.h>
#include <cuda.h>
#include <cmath>
#include "glm/glm.hpp"

#if CUDA_VERSION >= 5000
    #include <helper_math.h>
#else
    #include <cutil_math.h>
#endif

void kernelCleanup();
void cudaRasterizeCore(uchar4* PBOpos, glm::vec2 resolution, glm::vec3 eye, glm::vec3 center, float frame, float* vbo,
											 int vbosize, float* cbo, int cbosize, float* nbo, int nbosize, int* ibo, int ibosize);

#endif //RASTERIZEKERNEL_H
