// CIS565 CUDA Rasterizer: A simple rasterization pipeline for Patrick Cozzi's CIS565: GPU Computing at the University of Pennsylvania
// Written by Yining Karl Li, Copyright (c) 2012 University of Pennsylvania

#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <thrust/random.h>
#include "rasterizeKernels.h"
#include "rasterizeTools.h"
#include "glm/gtc/matrix_transform.hpp"

#if CUDA_VERSION >= 5000
    #include <helper_math.h>
#else
    #include <cutil_math.h>
#endif

#define DEG2RAD 180/PI

glm::vec3* framebuffer;
fragment* depthbuffer;
float* device_vbo;
float* device_cbo;
float* device_nbo;
int* device_ibo;
triangle* primitives;

// NEW
int* lockbuffer;

glm::vec3 up(0, 1, 0);
float fovy = 60;
float zNear = 0.01;
float zFar = 1000;

light* lights;
int lightsize = 4;

void checkCUDAError(const char *msg) {
  cudaError_t err = cudaGetLastError();
  if( cudaSuccess != err) {
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString( err) ); 
    exit(EXIT_FAILURE); 
  }
} 

//Handy dandy little hashing function that provides seeds for random number generation
__host__ __device__ unsigned int hash(unsigned int a){
    a = (a+0x7ed55d16) + (a<<12);
    a = (a^0xc761c23c) ^ (a>>19);
    a = (a+0x165667b1) + (a<<5);
    a = (a+0xd3a2646c) ^ (a<<9);
    a = (a+0xfd7046c5) + (a<<3);
    a = (a^0xb55a4f09) ^ (a>>16);
    return a;
}

//Writes a given fragment to a fragment buffer at a given location
__host__ __device__ void writeToDepthbuffer(int x, int y, fragment frag, fragment* depthbuffer, glm::vec2 resolution){
  if(x<resolution.x && y<resolution.y){
    int index = (y*resolution.x) + x;
    depthbuffer[index] = frag;
  }
}

//Reads a fragment from a given location in a fragment buffer
__host__ __device__ fragment getFromDepthbuffer(int x, int y, fragment* depthbuffer, glm::vec2 resolution){
  if(x<resolution.x && y<resolution.y){
    int index = (y*resolution.x) + x;
    return depthbuffer[index];
  }else{
    fragment f;
    return f;
  }
}

//Writes a given pixel to a pixel buffer at a given location
__host__ __device__ void writeToFramebuffer(int x, int y, glm::vec3 value, glm::vec3* framebuffer, glm::vec2 resolution){
  if(x<resolution.x && y<resolution.y){
    int index = (y*resolution.x) + x;
    framebuffer[index] = value;
  }
}

//Reads a pixel from a pixel buffer at a given location
__host__ __device__ glm::vec3 getFromFramebuffer(int x, int y, glm::vec3* framebuffer, glm::vec2 resolution){
  if(x<resolution.x && y<resolution.y){
    int index = (y*resolution.x) + x;
    return framebuffer[index];
  }else{
    return glm::vec3(0,0,0);
  }
}

//Kernel that clears a given pixel buffer with a given color
__global__ void clearImage(glm::vec2 resolution, glm::vec3* image, glm::vec3 color){
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * resolution.x);
    if(x<=resolution.x && y<=resolution.y){
      image[index] = color;
    }
}

//Kernel that clears a given fragment buffer with a given fragment
__global__ void clearDepthBuffer(glm::vec2 resolution, fragment* buffer, fragment frag){
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * resolution.x);
    if(x<=resolution.x && y<=resolution.y){
      fragment f = frag;
      f.position.x = x;
      f.position.y = y;
      buffer[index] = f;
    }
}

//Set the locks of all pixels to be 0 (unlocked)
__global__ void clearLockBuffer(glm::vec2 resolution, int* lockbuffer) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * resolution.x);
    if(x<=resolution.x && y<=resolution.y){
		lockbuffer[index] = 0;
	}
}

//Clears depth buffer if it passes the stencil test
__global__ void clearDepthBufferOnStencil(glm::vec2 resolution, fragment* buffer, fragment frag){
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * resolution.x);
    if(x<=resolution.x && y<=resolution.y){
			if (buffer[index].s == frag.s) {
				fragment f = frag;
				f.position.x = x;
				f.position.y = y;
				buffer[index] = f;
			}
    }
}

//Kernel that writes the image to the OpenGL PBO directly. 
__global__ void sendImageToPBO(uchar4* PBOpos, glm::vec2 resolution, glm::vec3* image){
  
  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * resolution.x);
  
  if(x<=resolution.x && y<=resolution.y){

      glm::vec3 color;      
      color.x = image[index].x*255.0;
      color.y = image[index].y*255.0;
      color.z = image[index].z*255.0;

      if(color.x>255){
        color.x = 255;
      }

      if(color.y>255){
        color.y = 255;
      }

      if(color.z>255){
        color.z = 255;
      }
      
      // Each thread writes one pixel location in the texture (textel)
      PBOpos[index].w = 0;
      PBOpos[index].x = color.x;     
      PBOpos[index].y = color.y;
      PBOpos[index].z = color.z;
  }
}

__host__ __device__ glm::vec3 transformPos(glm::vec3 v, glm::mat4 matrix, glm::vec2 resolution) {
	glm::vec4 v4(v, 1);
	v4 = matrix * v4;
	// perspective division
	v4.x = v4.x/v4.w;
	v4.y = v4.y/v4.w;
	v4.z = v4.z/v4.w;
	// viewport transform
	v4.x = resolution.x/2 * (v4.x+1);
	v4.y = resolution.y/2 * (v4.y+1);
	v4.z = -0.5 * v4.z + 0.5;

	return glm::vec3(v4);
}

__global__ void transformVertices(float* vbo, int vbosize, glm::mat4 modelMatrix) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if(index<vbosize/3){
	  glm::vec4 v(vbo[index*3], vbo[index*3+1], vbo[index*3+2], 1);
		v = modelMatrix * v;
		vbo[index*3] = v.x;
	  vbo[index*3+1] = v.y;
	  vbo[index*3+2] = v.z;
	}
}

__global__ void transformNormals(float* nbo, int nbosize, glm::mat4 modelMatrix) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if(index<nbosize/3){
		glm::vec4 n(nbo[index*3], nbo[index*3+1], nbo[index*3+2], 0);
		n = modelMatrix * n;
		nbo[index*3] = n.x;
	  nbo[index*3+1] = n.y;
	  nbo[index*3+2] = n.z;
	}
}

//TODO: Implement primative assembly
__global__ void primitiveAssemblyKernel(float* vbo, int vbosize, float* cbo, int cbosize, float* nbo, int nbosize, int* ibo, int ibosize, triangle* primitives){
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  int primitivesCount = ibosize/3;
  if(index<primitivesCount){
	  int v0 = ibo[index*3];
	  int v1 = ibo[index*3+1];
	  int v2 = ibo[index*3+2];
	  glm::vec3 p0(vbo[v0*3], vbo[v0*3+1], vbo[v0*3+2]);
	  glm::vec3 p1(vbo[v1*3], vbo[v1*3+1], vbo[v1*3+2]);
	  glm::vec3 p2(vbo[v2*3], vbo[v2*3+1], vbo[v2*3+2]);
	  glm::vec3 c0(cbo[0], cbo[1], cbo[2]);
	  glm::vec3 c1(cbo[0], cbo[1], cbo[2]);
	  glm::vec3 c2(cbo[0], cbo[1], cbo[2]);
	  //glm::vec3 c0(cbo[v0*3], cbo[v0*3+1], cbo[v0*3+2]);
	  //glm::vec3 c1(cbo[v1*3], cbo[v1*3+1], cbo[v1*3+2]);
	  //glm::vec3 c2(cbo[v2*3], cbo[v2*3+1], cbo[v2*3+2]);
	  glm::vec3 n0(nbo[v0*3], nbo[v0*3+1], nbo[v0*3+2]);
	  glm::vec3 n1(nbo[v1*3], nbo[v1*3+1], nbo[v1*3+2]);
	  glm::vec3 n2(nbo[v2*3], nbo[v2*3+1], nbo[v2*3+2]);
	  primitives[index] = triangle(p0, p1, p2, c0, c1, c2, n0, n1, n2);
  }
}

//TODO: Implement a vertex shader
__global__ void vertexShadeKernel(float* vbo, int vbosize, glm::mat4 cameraMatrix, glm::vec2 resolution){
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if(index<vbosize/3){
	  glm::vec3 v(vbo[index*3], vbo[index*3+1], vbo[index*3+2]);
	  v = transformPos(v, cameraMatrix, resolution);
	  vbo[index*3] = v.x;
	  vbo[index*3+1] = v.y;
	  vbo[index*3+2] = v.z;
  }
}

//Fill primitives with transformed vertex positions
__global__ void updatePrimitiveKernel(float* vbo, int vbosize, int* ibo, int ibosize, triangle* primitives){
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  int primitivesCount = ibosize/3;
  if(index<primitivesCount){
	  int v0 = ibo[index*3];
	  int v1 = ibo[index*3+1];
	  int v2 = ibo[index*3+2];
	  primitives[index].pt0 = glm::vec3(vbo[v0*3], vbo[v0*3+1], vbo[v0*3+2]);
	  primitives[index].pt1 = glm::vec3(vbo[v1*3], vbo[v1*3+1], vbo[v1*3+2]);
	  primitives[index].pt2 = glm::vec3(vbo[v2*3], vbo[v2*3+1], vbo[v2*3+2]);
  }
}

//Populate the primitive list for portal
__global__ void stencilPrimitiveKernel(float* vbo, int vbosize, int* ibo, int ibosize, vertTriangle* primitives){
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  int primitivesCount = ibosize/3;
  if(index<primitivesCount){
	  int v0 = ibo[index*3];
	  int v1 = ibo[index*3+1];
	  int v2 = ibo[index*3+2];
		glm::vec3 pt0 = glm::vec3(vbo[v0*3], vbo[v0*3+1], vbo[v0*3+2]);
	  glm::vec3 pt1 = glm::vec3(vbo[v1*3], vbo[v1*3+1], vbo[v1*3+2]);
	  glm::vec3 pt2 = glm::vec3(vbo[v2*3], vbo[v2*3+1], vbo[v2*3+2]);
		primitives[index] = vertTriangle(pt0, pt1, pt2);
  }
}

__device__ glm::vec3 getScanlineIntersection(glm::vec3 v1, glm::vec3 v2, float y) {
	float t = (y-v1.y)/(v2.y-v1.y);
	return glm::vec3(t*v2.x + (1-t)*v1.x, y, t*v2.z + (1-t)*v1.z);
}

__device__ bool isInScreen(glm::vec3 p, glm::vec2 resolution) {
	return (p.x > 0&& p.x < resolution.x && p.y > 0 && p.y < resolution.y);
}

//primitive parallel rasterization
__global__ void rasterizationPerPrimKernel(triangle* primitives, int primitiveCount, fragment* depthbuffer, glm::vec2 resolution, bool stencilTest, int stencil, int* lockbuffer) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < primitiveCount) {
		triangle prim = primitives[index];
		float topy = min(min(prim.pt0.y, prim.pt1.y), prim.pt2.y);
		float boty = max(max(prim.pt0.y, prim.pt1.y), prim.pt2.y);
		int top = max((int)floor(topy), 0);
		int bot = min((int)ceil(boty), (int)resolution.y);

		for (int y=top; y<bot; ++y) {
			float dy0 = prim.pt0.y - y;
			float dy1 = prim.pt1.y - y;
			float dy2 = prim.pt2.y - y;
			int onPositiveSide = (int)(dy0>=0) + (int)(dy1>=0) + (int)(dy2>=0);
			int onNegativeSide = (int)(dy0<=0) + (int)(dy1<=0) + (int)(dy2<=0);

			glm::vec3 intersection1, intersection2;
			if (onPositiveSide == 3 || onNegativeSide == 3) {
				if (dy0 == 0) {
					intersection1 = prim.pt0;
					intersection2 = prim.pt0;
				}
				else if (dy1 == 0) {
					intersection1 = prim.pt1;
					intersection2 = prim.pt1;
				}
				else if (dy2 == 0) {
					intersection1 = prim.pt2;
					intersection2 = prim.pt2;
				}
			}
			else if (onPositiveSide == 2 && onNegativeSide == 2) { // one vertex is on the scanline
															// doesn't really happen due to the floating point error
				if (dy0 == 0) {
					intersection1 = prim.pt0;
					intersection2 = getScanlineIntersection(prim.pt1, prim.pt2, y);
				}
				else if (dy1 == 0) {
					intersection1 = prim.pt1;
					intersection2 = getScanlineIntersection(prim.pt0, prim.pt2, y);
				}
				else { // dy2 == 0
					intersection1 = prim.pt2;
					intersection2 = getScanlineIntersection(prim.pt1, prim.pt0, y);
				}
			}
			else if (onPositiveSide == 2) {
				if (dy0 < 0) {
					intersection1 = getScanlineIntersection(prim.pt0, prim.pt1, y);
					intersection2 = getScanlineIntersection(prim.pt0, prim.pt2, y);
				}
				else if (dy1 < 0) {
					intersection1 = getScanlineIntersection(prim.pt1, prim.pt0, y);
					intersection2 = getScanlineIntersection(prim.pt1, prim.pt2, y);
				}
				else { // dy2 < 0
					intersection1 = getScanlineIntersection(prim.pt2, prim.pt0, y);
					intersection2 = getScanlineIntersection(prim.pt2, prim.pt1, y);
				}
			}
			else { // onNegativeSide == 2
				if (dy0 > 0) {
					intersection1 = getScanlineIntersection(prim.pt0, prim.pt1, y);
					intersection2 = getScanlineIntersection(prim.pt0, prim.pt2, y);
				}
				else if (dy1 > 0) {
					intersection1 = getScanlineIntersection(prim.pt1, prim.pt0, y);
					intersection2 = getScanlineIntersection(prim.pt1, prim.pt2, y);
				}
				else { // dy2 > 0
					intersection1 = getScanlineIntersection(prim.pt2, prim.pt0, y);
					intersection2 = getScanlineIntersection(prim.pt2, prim.pt1, y);
				}
			}

			// make sure intersection1's x value is less than intersection2's
			if (intersection2.x < intersection1.x) {
				glm::vec3 temp = intersection1;
				intersection1 = intersection2;
				intersection2 = temp;
			}

			int left = min((int)(resolution.x)-1,max(0, (int)floor(intersection1.x)));
			int right = min((int)(resolution.x-1),max(0, (int)floor(intersection2.x)));
			for (int x=left; x<=right; ++x) {
				int pixelIndex = (resolution.x-1-x) + (resolution.y-1-y) * resolution.x;
				float t = (x-intersection1.x)/(intersection2.x-intersection1.x);
				glm::vec3 point = t*intersection2 + (1-t)*intersection1;
				
				// lock stuff
				bool wait = true;
				while (wait) {
					if (0 == atomicExch(&lockbuffer[pixelIndex], 1)) {
						bool draw = true;
						if (stencilTest) {
							draw = (depthbuffer[pixelIndex].s == stencil) && (point.z > depthbuffer[pixelIndex].z);
						}
						else {
							draw = (point.z > depthbuffer[pixelIndex].z);
						}
						if (draw) {
							glm::vec3 bc = calculateBarycentricCoordinate(prim, glm::vec2(point.x, point.y));
							depthbuffer[pixelIndex].color = prim.c0 * bc.x + prim.c1 * bc.y + prim.c2 * bc.z;
							depthbuffer[pixelIndex].normal = glm::normalize(prim.n0 * bc.x + prim.n1 * bc.y + prim.n2 * bc.z);
							depthbuffer[pixelIndex].position = prim.p0 * bc.x + prim.p1 * bc.y + prim.p2 * bc.z;
							depthbuffer[pixelIndex].z = point.z;
						}
						atomicExch(&lockbuffer[pixelIndex], 0);
						wait = false;
					}
				}
			}
		}
	}
}

//scanline parallel rasterization
__global__ void rasterizationKernel(triangle* primitives, int primitivesCount, fragment* depthbuffer, glm::vec2 resolution, bool stencilTest, int stencil, int* lockbuffer){
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if(index < resolution.y){
    for (int i=0; i<primitivesCount; ++i) {
      triangle prim = primitives[i];
      float dy0 = prim.pt0.y - index;
      float dy1 = prim.pt1.y - index;
      float dy2 = prim.pt2.y - index;
      int onPositiveSide = (int)(dy0>=-FLT_EPSILON) + (int)(dy1>=-FLT_EPSILON) + (int)(dy2>=-FLT_EPSILON);
      int onNegativeSide = (int)(dy0<=FLT_EPSILON) + (int)(dy1<=FLT_EPSILON) + (int)(dy2<=FLT_EPSILON);
      if (onPositiveSide != 3 && onNegativeSide != 3) { // the primitive intersects the scanline
        glm::vec3 intersection1, intersection2;
        if (onPositiveSide == 2 && onNegativeSide == 2) { // one vertex is on the scanline, doesn't really happen due to the floating point error
          if (dy0 == 0) {
                  intersection1 = prim.pt0;
                  intersection2 = getScanlineIntersection(prim.pt1, prim.pt2, index);
          }
          else if (dy1 == 0) {
                  intersection1 = prim.pt1;
                  intersection2 = getScanlineIntersection(prim.pt0, prim.pt2, index);
          }
          else { // dy2 == 0
                  intersection1 = prim.pt2;
                  intersection2 = getScanlineIntersection(prim.pt1, prim.pt0, index);
          }
        }
        else if (onPositiveSide == 2) {
          if (dy0 < 0) {
                  intersection1 = getScanlineIntersection(prim.pt0, prim.pt1, index);
                  intersection2 = getScanlineIntersection(prim.pt0, prim.pt2, index);
          }
          else if (dy1 < 0) {
                  intersection1 = getScanlineIntersection(prim.pt1, prim.pt0, index);
                  intersection2 = getScanlineIntersection(prim.pt1, prim.pt2, index);
          }
          else { // dy2 < 0
                  intersection1 = getScanlineIntersection(prim.pt2, prim.pt0, index);
                  intersection2 = getScanlineIntersection(prim.pt2, prim.pt1, index);
          }
        }
        else { // onNegativeSide == 2
          if (dy0 > 0) {
                  intersection1 = getScanlineIntersection(prim.pt0, prim.pt1, index);
                  intersection2 = getScanlineIntersection(prim.pt0, prim.pt2, index);
          }
          else if (dy1 > 0) {
                  intersection1 = getScanlineIntersection(prim.pt1, prim.pt0, index);
                  intersection2 = getScanlineIntersection(prim.pt1, prim.pt2, index);
          }
          else { // dy2 > 0
                  intersection1 = getScanlineIntersection(prim.pt2, prim.pt0, index);
                  intersection2 = getScanlineIntersection(prim.pt2, prim.pt1, index);
          }
        }

        // make sure intersection1's x value is less than intersection2's
        if (intersection2.x < intersection1.x) {
          glm::vec3 temp = intersection1;
          intersection1 = intersection2;
          intersection2 = temp;
        }

        int start = min((int)(resolution.x)-1,max(0, (int)floor(intersection1.x)));
        int end = min((int)(resolution.x-1),max(0, (int)floor(intersection2.x)));
        for (int j=start; j<=end; ++j) {
          int pixelIndex = (resolution.x-1-j) + (resolution.y-1-index) * resolution.x;
          float t = (j-intersection1.x)/(intersection2.x-intersection1.x);
          glm::vec3 point = t*intersection2 + (1-t)*intersection1;
		  
		  // lock stuff
		  bool wait = true;
		  while (wait) {
			  if (0 == atomicExch(&lockbuffer[pixelIndex], 1)) {
				bool draw = true;
				if (stencilTest) {
					draw = (depthbuffer[pixelIndex].s == stencil) && (point.z > depthbuffer[pixelIndex].z);
				}
				else {
					draw = (point.z > depthbuffer[pixelIndex].z);
				}
				if (draw) {
					glm::vec3 bc = calculateBarycentricCoordinate(prim, glm::vec2(point.x, point.y));
					depthbuffer[pixelIndex].color = prim.c0 * bc.x + prim.c1 * bc.y + prim.c2 * bc.z;
					depthbuffer[pixelIndex].normal = glm::normalize(prim.n0 * bc.x + prim.n1 * bc.y + prim.n2 * bc.z);
					depthbuffer[pixelIndex].position = prim.p0 * bc.x + prim.p1 * bc.y + prim.p2 * bc.z;
					depthbuffer[pixelIndex].z = point.z;
				}
				atomicExch(&lockbuffer[pixelIndex], 0);
				wait = false;
			  }
		  }
        }
      }
    }
  }
}

//rasterization for stencil buffer
__global__ void rasterizationStencilKernel(vertTriangle* primitives, int primitivesCount, fragment* depthbuffer, glm::vec2 resolution, int stencil, int* lockbuffer){
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if(index < resolution.y){
    for (int i=0; i<primitivesCount; ++i) {
      vertTriangle prim = primitives[i];
      float dy0 = prim.pt0.y - index;
      float dy1 = prim.pt1.y - index;
      float dy2 = prim.pt2.y - index;
      int onPositiveSide = (int)(dy0>=-FLT_EPSILON) + (int)(dy1>=-FLT_EPSILON) + (int)(dy2>=-FLT_EPSILON);
      int onNegativeSide = (int)(dy0<=FLT_EPSILON) + (int)(dy1<=FLT_EPSILON) + (int)(dy2<=FLT_EPSILON);
      if (onPositiveSide != 3 && onNegativeSide != 3) { // the primitive intersects the scanline
        glm::vec3 intersection1, intersection2;
        if (onPositiveSide == 2 && onNegativeSide == 2) { // one vertex is on the scanline                                                                                               // doesn't really happen due to the floating point error
          if (dy0 == 0) {
                  intersection1 = prim.pt0;
                  intersection2 = getScanlineIntersection(prim.pt1, prim.pt2, index);
          }
          else if (dy1 == 0) {
                  intersection1 = prim.pt1;
                  intersection2 = getScanlineIntersection(prim.pt0, prim.pt2, index);
          }
          else { // dy2 == 0
                  intersection1 = prim.pt2;
                  intersection2 = getScanlineIntersection(prim.pt1, prim.pt0, index);
          }
        }
        else if (onPositiveSide == 2) {
          if (dy0 < 0) {
                  intersection1 = getScanlineIntersection(prim.pt0, prim.pt1, index);
                  intersection2 = getScanlineIntersection(prim.pt0, prim.pt2, index);
          }
          else if (dy1 < 0) {
                  intersection1 = getScanlineIntersection(prim.pt1, prim.pt0, index);
                  intersection2 = getScanlineIntersection(prim.pt1, prim.pt2, index);
          }
          else { // dy2 < 0
                  intersection1 = getScanlineIntersection(prim.pt2, prim.pt0, index);
                  intersection2 = getScanlineIntersection(prim.pt2, prim.pt1, index);
          }
        }
        else { // onNegativeSide == 2
          if (dy0 > 0) {
                  intersection1 = getScanlineIntersection(prim.pt0, prim.pt1, index);
                  intersection2 = getScanlineIntersection(prim.pt0, prim.pt2, index);
          }
          else if (dy1 > 0) {
                  intersection1 = getScanlineIntersection(prim.pt1, prim.pt0, index);
                  intersection2 = getScanlineIntersection(prim.pt1, prim.pt2, index);
          }
          else { // dy2 > 0
                  intersection1 = getScanlineIntersection(prim.pt2, prim.pt0, index);
                  intersection2 = getScanlineIntersection(prim.pt2, prim.pt1, index);
          }
        }

        // make sure intersection1's x value is less than intersection2's
        if (intersection2.x < intersection1.x) {
          glm::vec3 temp = intersection1;
          intersection1 = intersection2;
          intersection2 = temp;
        }

        int start = min((int)(resolution.x)-1,max(0, (int)floor(intersection1.x)));
        int end = min((int)(resolution.x-1),max(0, (int)floor(intersection2.x)));
        for (int j=start; j<=end; ++j) {
          int pixelIndex = (resolution.x-1-j) + (resolution.y-1-index) * resolution.x;
          float t = (j-intersection1.x)/(intersection2.x-intersection1.x);
          glm::vec3 point = t*intersection2 + (1-t)*intersection1;

		  // lock stuff
		  bool wait = true;
		  while (wait) {
			  if (0 == atomicExch(&lockbuffer[pixelIndex], 1)) {
				  if (point.z > depthbuffer[pixelIndex].z) {
					depthbuffer[pixelIndex].s = stencil;
					depthbuffer[pixelIndex].z = point.z;
				  }
				  atomicExch(&lockbuffer[pixelIndex], 0);
				  wait = false;
			  }
		  }
        }
      }
    }
  }
}

//TODO: Implement a fragment shader
__global__ void fragmentShadeKernel(fragment* depthbuffer, glm::vec2 resolution, glm::vec3 eye, light* lights, int lightsize){
  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * resolution.x);
  if(x<=resolution.x && y<=resolution.y){
		glm::vec3 diffuseColor(0);
		glm::vec3 specularColor(0);
		float ks = 0;
		if (glm::distance(depthbuffer[index].color, glm::vec3(245.0/255.0, 222.0/255.0, 179.0/255.0)) > 0.1) {
			ks = 0.3;
		}
		glm::vec3 norm =  depthbuffer[index].normal;
		glm::vec3 pos = depthbuffer[index].position;
		for (int i=0; i<lightsize; ++i) {
			//diffuse component
			glm::vec3 lightDir = glm::normalize(glm::vec3(lights[i].pos - pos));
			float diffuseTerm = glm::clamp(glm::dot(lightDir, norm), 0.0f, 1.0f);
			diffuseColor += diffuseTerm * lights[i].color;

			//specular component
			if (ks > 0.0001) {
				glm::vec3 LR; // reflected light direction
				if (glm::length(lightDir - norm) < 0.0001) {
					LR = norm;
				}
				else if (abs(glm::dot(lightDir, norm)) < 0.0001) {
					LR = -lightDir;
				}
				else {
					LR = glm::normalize(-lightDir - 2.0f * glm::dot(-lightDir, norm) * norm);
				}
				float specularTerm = min(1.0f, pow(max(0.0f, glm::dot(LR, glm::normalize(eye - pos))), 20.0f));
				specularColor += specularTerm * glm::vec3(1.0f);
			}
		}
		depthbuffer[index].color = diffuseColor * depthbuffer[index].color + ks * specularColor;

		//set background color
		if (depthbuffer[index].z == -FLT_MAX) {
			depthbuffer[index].color = glm::vec3(0.6, 0.6, 0.6);
		}
  }
}

//Writes fragment colors to the framebuffer
__global__ void render(glm::vec2 resolution, fragment* depthbuffer, glm::vec3* framebuffer){

  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * resolution.x);

  if(x<=resolution.x && y<=resolution.y){
    framebuffer[index] = depthbuffer[index].color;
  }
}

void initLights() {
	light l1(glm::vec3(0.8, 0.8, 0.8), glm::vec3(4, 4, 4));
	light l2(glm::vec3(0.4, 0.4, 0.4), glm::vec3(-4, 4, 4));
	light l3(glm::vec3(0.3, 0.3, 0.3), glm::vec3(0, 0, -5));
	light l4(glm::vec3(0.3, 0.3, 0.3), glm::vec3(0, -5, 0));
	light* cpulights = new light[lightsize];
	cpulights[0] = l1;
	cpulights[1] = l2;
	cpulights[2] = l3;
	cpulights[3] = l4;
	
	checkCUDAError("Kernel failed!");
	cudaMalloc((void**)&lights, lightsize*sizeof(light));
	checkCUDAError("Kernel failed!");
	cudaMemcpy(lights, cpulights, lightsize*sizeof(light), cudaMemcpyHostToDevice);
	checkCUDAError("Kernel failed!");

	delete [] cpulights;
}

void initBuffers(glm::vec2 resolution) {
	//set up framebuffer
  framebuffer = NULL;
  cudaMalloc((void**)&framebuffer, (int)resolution.x*(int)resolution.y*sizeof(glm::vec3));
  
  //set up depthbuffer
  depthbuffer = NULL;
  cudaMalloc((void**)&depthbuffer, (int)resolution.x*(int)resolution.y*sizeof(fragment));

  lockbuffer = NULL;
  cudaMalloc((void**)&lockbuffer, (int)resolution.x*(int)resolution.y*sizeof(int));

	clearBuffers(resolution);
}

void clearBuffers(glm::vec2 resolution) {
	int tileSize = 8;
  dim3 threadsPerBlock(tileSize, tileSize);
  dim3 fullBlocksPerGrid((int)ceil(float(resolution.x)/float(tileSize)), (int)ceil(float(resolution.y)/float(tileSize)));
	
	//kernel launches to black out accumulated/unaccumlated pixel buffers and clear our scattering states
  clearImage<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, framebuffer, glm::vec3(0,0,0));
	cudaDeviceSynchronize();

	fragment frag;
  frag.color = glm::vec3(0,0,0);
  frag.normal = glm::vec3(0,0,0);
  frag.position = glm::vec3(0,0,0);
  frag.z = -FLT_MAX;
	frag.s = 0;
  clearDepthBuffer<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, depthbuffer,frag);
	cudaDeviceSynchronize();

	clearLockBuffer<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, lockbuffer);
	cudaDeviceSynchronize();
}

void drawToStencilBuffer(glm::vec2 resolution, glm::mat4 rotation, glm::vec3 eye, glm::vec3 center, float* vbo, int vbosize, int* ibo, int ibosize, int stencil) {
	// set up crucial magic
  int tileSize = 8;
  dim3 threadsPerBlock(tileSize, tileSize);
  dim3 fullBlocksPerGrid((int)ceil(float(resolution.x)/float(tileSize)), (int)ceil(float(resolution.y)/float(tileSize)));

	vertTriangle* stencilPrimitives = NULL;
  cudaMalloc((void**)&stencilPrimitives, (ibosize/3)*sizeof(vertTriangle));

  device_ibo = NULL;
  cudaMalloc((void**)&device_ibo, ibosize*sizeof(int));
  cudaMemcpy( device_ibo, ibo, ibosize*sizeof(int), cudaMemcpyHostToDevice);

  device_vbo = NULL;
  cudaMalloc((void**)&device_vbo, vbosize*sizeof(float));
  cudaMemcpy( device_vbo, vbo, vbosize*sizeof(float), cudaMemcpyHostToDevice);

	//------------------------------
  //compute the camera matrix
  //------------------------------
  float aspect = resolution.x / resolution.y;
  glm::mat4 perspMatrix = glm::perspective(fovy, resolution.x/resolution.y, zNear, zFar);
  glm::mat4 lookatMatrix = glm::lookAt(eye, center, up);
  glm::mat4 cameraMatrix = perspMatrix * lookatMatrix;

	//------------------------------
  //vertex shader
  //------------------------------
	tileSize = 64;
	int primitiveBlocks = ceil(((float)vbosize/3)/((float)tileSize));
	transformVertices<<<primitiveBlocks, tileSize>>>(device_vbo, vbosize, rotation);
	vertexShadeKernel<<<primitiveBlocks, tileSize>>>(device_vbo, vbosize, cameraMatrix, resolution);
  cudaDeviceSynchronize();

	//------------------------------
  //update stencil primitives
  //------------------------------
	primitiveBlocks = ceil(((float)ibosize/3)/((float)tileSize));
  stencilPrimitiveKernel<<<primitiveBlocks, tileSize>>>(device_vbo, vbosize, device_ibo, ibosize, stencilPrimitives);
  cudaDeviceSynchronize();

	//------------------------------
  //rasterization
  //------------------------------
	int scanlineBlocks = ceil(((float)resolution.y)/((float)tileSize));
	rasterizationStencilKernel<<<scanlineBlocks, tileSize>>>(stencilPrimitives, ibosize/3, depthbuffer, resolution, stencil, lockbuffer);
	cudaDeviceSynchronize();

	cudaFree(stencilPrimitives);
}

// Clear the depth buffer based on stencil test
void clearOnStencil(glm::vec2 resolution, int stencil) {
	// set up crucial magic
  int tileSize = 8;
  dim3 threadsPerBlock(tileSize, tileSize);
  dim3 fullBlocksPerGrid((int)ceil(float(resolution.x)/float(tileSize)), (int)ceil(float(resolution.y)/float(tileSize)));

	fragment frag;
	frag.color = glm::vec3(0,0,0);
	frag.normal = glm::vec3(0,0,0);
	frag.position = glm::vec3(0,0,0);
	frag.z = -FLT_MAX;
	frag.s = stencil;
	clearDepthBufferOnStencil<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, depthbuffer, frag);
	cudaDeviceSynchronize();

	clearLockBuffer<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, lockbuffer);
	cudaDeviceSynchronize();
}

__global__ void stencilTestKernel(bool* result, glm::vec2 resolution, fragment* depthbuffer, int stencil) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * resolution.x);
  if(x<=resolution.x && y<=resolution.y){
		if (depthbuffer[index].s == stencil) {
			result[0] = true;
		}
	}
}

// Wrapper for the __global__ call that sets up the kernel calls and does a ton of memory management
void cudaRasterizeCore(glm::vec2 resolution, glm::mat4 rotation, glm::vec3 eye, glm::vec3 center,
											 float* vbo, int vbosize, float* cbo, int cbosize, float* nbo,
											 int nbosize, int* ibo, int ibosize, bool stencilTest, bool perPrimitive, int stencil){
	//------------------------------
  //test stencil values, if there's no buffer with desired stencil value, return
  //------------------------------
	if (stencilTest) {
		int tileSize = 8;
		dim3 threadsPerBlock(tileSize, tileSize);
		dim3 fullBlocksPerGrid((int)ceil(float(resolution.x)/float(tileSize)), (int)ceil(float(resolution.y)/float(tileSize)));

		bool cpuresult[1] = {false};
		bool* result;
		cudaMalloc((void**)&result, sizeof(bool));
		cudaMemcpy(result, cpuresult, sizeof(bool), cudaMemcpyHostToDevice);
		stencilTestKernel<<<fullBlocksPerGrid, threadsPerBlock>>>(result, resolution, depthbuffer, stencil);

		bool* cpuresult2 = new bool[1];
		cudaMemcpy(cpuresult2, result, sizeof(bool), cudaMemcpyDeviceToHost);
		if (!cpuresult2[0]) {
			return;
		}
	}

  //------------------------------
  //memory stuff
  //------------------------------
  primitives = NULL;
  cudaMalloc((void**)&primitives, (ibosize/3)*sizeof(triangle));

  device_ibo = NULL;
  cudaMalloc((void**)&device_ibo, ibosize*sizeof(int));
  cudaMemcpy( device_ibo, ibo, ibosize*sizeof(int), cudaMemcpyHostToDevice);

  device_vbo = NULL;
  cudaMalloc((void**)&device_vbo, vbosize*sizeof(float));
  cudaMemcpy( device_vbo, vbo, vbosize*sizeof(float), cudaMemcpyHostToDevice);

  device_cbo = NULL;
  cudaMalloc((void**)&device_cbo, cbosize*sizeof(float));
  cudaMemcpy( device_cbo, cbo, cbosize*sizeof(float), cudaMemcpyHostToDevice);

  device_nbo = NULL;
  cudaMalloc((void**)&device_nbo, nbosize*sizeof(float));
  cudaMemcpy( device_nbo, nbo, nbosize*sizeof(float), cudaMemcpyHostToDevice);

  int tileSize = 64;

  //------------------------------
  //compute the camera matrix
  //------------------------------
  float aspect = resolution.x / resolution.y;
  glm::mat4 perspMatrix = glm::perspective(fovy, resolution.x/resolution.y, zNear, zFar);
  glm::mat4 lookatMatrix = glm::lookAt(eye, center, up);
  glm::mat4 cameraMatrix = perspMatrix * lookatMatrix;

	//------------------------------
  //transform vertices and normals
  //------------------------------
	int primitiveBlocks = ceil(((float)vbosize/3)/((float)tileSize));
	transformVertices<<<primitiveBlocks, tileSize>>>(device_vbo, vbosize, rotation);
	transformNormals<<<primitiveBlocks, tileSize>>>(device_nbo, nbosize, rotation);

  //------------------------------
  //primitive assembly
  //------------------------------
  primitiveBlocks = ceil(((float)ibosize/3)/((float)tileSize));
  primitiveAssemblyKernel<<<primitiveBlocks, tileSize>>>(device_vbo, vbosize, device_cbo, cbosize, device_nbo, nbosize, device_ibo, ibosize, primitives);

  cudaDeviceSynchronize();

  //------------------------------
  //vertex shader
  //------------------------------
	primitiveBlocks = ceil(((float)vbosize/3)/((float)tileSize));
  vertexShadeKernel<<<primitiveBlocks, tileSize>>>(device_vbo, vbosize, cameraMatrix, resolution);

  cudaDeviceSynchronize();

  //------------------------------
  //update primitives
  //------------------------------
	primitiveBlocks = ceil(((float)ibosize/3)/((float)tileSize));
  updatePrimitiveKernel<<<primitiveBlocks, tileSize>>>(device_vbo, vbosize, device_ibo, ibosize, primitives);

  cudaDeviceSynchronize();

  //cudaMemcpy(prim_cpu, primitives, ibosize/3*sizeof(triangle), cudaMemcpyDeviceToHost);
  //t = prim_cpu[0];

  //------------------------------
  //rasterization
  //------------------------------
	if (perPrimitive) {
		//parallel by primitive
		rasterizationPerPrimKernel<<<primitiveBlocks, tileSize>>>(primitives, ibosize/3, depthbuffer, resolution, stencilTest, stencil, lockbuffer);
	}
	else {
		int scanlineBlocks = ceil(((float)resolution.y)/((float)tileSize));
		rasterizationKernel<<<scanlineBlocks, tileSize>>>(primitives, ibosize/3, depthbuffer, resolution, stencilTest, stencil, lockbuffer);
	}

  cudaDeviceSynchronize();

  kernelCleanup();

  checkCUDAError("Kernel failed!");
}

//fragment shader and render
void renderToPBO(uchar4* PBOpos, glm::vec2 resolution, glm::vec3 eye) {
	// set up crucial magic
  int tileSize = 8;
  dim3 threadsPerBlock(tileSize, tileSize);
  dim3 fullBlocksPerGrid((int)ceil(float(resolution.x)/float(tileSize)), (int)ceil(float(resolution.y)/float(tileSize)));

	//------------------------------
  //fragment shader
  //------------------------------
  fragmentShadeKernel<<<fullBlocksPerGrid, threadsPerBlock>>>(depthbuffer, resolution, eye, lights, lightsize);

  cudaDeviceSynchronize();
  //------------------------------
  //write fragments to framebuffer
  //------------------------------
  render<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, depthbuffer, framebuffer);
  sendImageToPBO<<<fullBlocksPerGrid, threadsPerBlock>>>(PBOpos, resolution, framebuffer);

  cudaDeviceSynchronize();
}

void kernelCleanup(){
  cudaFree( primitives );
  cudaFree( device_vbo );
  cudaFree( device_cbo );
  cudaFree( device_nbo );
  cudaFree( device_ibo );
}

void freeBuffers() {
	cudaFree( framebuffer );
  cudaFree( depthbuffer );
  cudaFree( lockbuffer );
}

