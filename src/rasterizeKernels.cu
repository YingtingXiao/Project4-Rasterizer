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
triangle* validPrimitives;

glm::vec3 up(0, 1, 0);
float fovy = 60;
float zNear = 0.01;
float zFar = 1000;

glm::vec3 lightColor(1, 1, 1);
glm::vec3 lightPos(4, 4, 4);

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
	  glm::vec3 c1(cbo[3], cbo[4], cbo[5]);
	  glm::vec3 c2(cbo[6], cbo[7], cbo[8]);
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

__device__ glm::vec3 getScanlineIntersection(glm::vec3 v1, glm::vec3 v2, float y) {
	float t = (y-v1.y)/(v2.y-v1.y);
	return glm::vec3(t*v2.x + (1-t)*v1.x, y, t*v2.z + (1-t)*v1.z);
}

__device__ bool isInScreen(glm::vec3 p, glm::vec2 resolution) {
	return (p.x > 0&& p.x < resolution.x && p.y > 0 && p.y < resolution.y);
}

__global__ void validatePrims(triangle* primitives, int primitiveCount, int* validArray, glm::vec3 view, glm::vec2 resolution) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if(index<primitiveCount){
		triangle prim = primitives[index];
		if (!isInScreen(prim.pt0, resolution) && !isInScreen(prim.pt1, resolution) && !isInScreen(prim.pt2, resolution)) {
			//clipping
			validArray[index] = 0;
		}
		else if (glm::dot(view, prim.n0) > 0 && glm::dot(view, prim.n1) > 0 && glm::dot(view, prim.n2) > 0) {
			//back face culling
			validArray[index] = 0;
		}
		else {
			validArray[index] = 1;
		}
	}
}

// Copy valid primitive data to scanArray
__global__ void copy(int* validArray, int primCount, int* scanArray) {
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index < primCount) {
		scanArray[index] = validArray[index];
	}
}

// Scan using shared memory
__global__ void sharedMemoryScan(int* scanArray, int* sumArray, int primCount) {
	__shared__ int subArray1[64];
	__shared__ int subArray2[64];

	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index < primCount) {
		subArray1[threadIdx.x] = scanArray[index];
		subArray2[threadIdx.x] = scanArray[index];
		__syncthreads();

		int d = 1;
#pragma unroll
		for (; d<=ceil(log((float)blockDim.x)/log(2.0f)); ++d) {
			if (threadIdx.x >= ceil(pow((float)2, (float)(d-1)))) {
				int prevIdx = threadIdx.x - ceil(pow((float)2, (float)(d-1)));
				if (d % 2 == 1) {
					subArray2[threadIdx.x] = subArray1[threadIdx.x] + subArray1[prevIdx];
				}
				else {
					subArray1[threadIdx.x] = subArray2[threadIdx.x] + subArray2[prevIdx];
				}
			}
			else {
				if (d % 2 == 1) {
					subArray2[threadIdx.x] = subArray1[threadIdx.x];
				}
				else {
					subArray1[threadIdx.x] = subArray2[threadIdx.x];
				}
			}
			__syncthreads();
		}

		if (d % 2 == 1) {
			scanArray[index] = subArray1[threadIdx.x];
			if (threadIdx.x == 63) {
				sumArray[blockIdx.x] = subArray1[threadIdx.x];
			}
		}
		else {
			scanArray[index] = subArray2[threadIdx.x];
			if (threadIdx.x == 63) {
				sumArray[blockIdx.x] = subArray2[threadIdx.x];
			}
		}
	}
}

// Naive scan, for scanning the sum array
__global__ void naiveScan(int* scanArray1, int* scanArray2, int d, int sumArrayLength) {
	int index = blockIdx.x * blockDim.x + threadIdx.x;

	if (index < sumArrayLength) {
		if (index >= ceil(pow((float)2, (float)(d-1)))) {
			int prevIndex = index - (int)ceil(pow((float)2, (float)(d-1)));
			scanArray2[index] = scanArray1[index] + scanArray1[prevIndex];
		}
		else {
			scanArray2[index] = scanArray1[index];
		}
	}
}

// Add the elements in the sum array to the scan array
__global__ void addToScanArray(int* scanArray, int* sumArray, int primCount) {
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index < primCount && blockIdx.x > 0) {
		scanArray[index] += sumArray[blockIdx.x-1];
	}
}

// Scatter kernel for stream compaction
__global__ void scatter(triangle* primitives, int* validArray, int* scanArray, triangle* validPrimitives, int primCount) {
	int index = blockIdx.x * blockDim.x + threadIdx.x;
	if (index < primCount && validArray[index] == 1) {
		validPrimitives[scanArray[index]-1] = primitives[index];
	}
}


__global__ void rasterizationKernel(triangle* primitives, int primitiveCount, fragment* depthbuffer, glm::vec2 resolution) {
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
				if (point.z > depthbuffer[pixelIndex].z) {
					glm::vec3 bc = calculateBarycentricCoordinate(prim, glm::vec2(point.x, point.y));
					depthbuffer[pixelIndex].color = prim.c0 * bc.x + prim.c1 * bc.y + prim.c2 * bc.z;
					depthbuffer[pixelIndex].normal = glm::normalize(prim.n0 * bc.x + prim.n1 * bc.y + prim.n2 * bc.z);
					depthbuffer[pixelIndex].position = prim.p0 * bc.x + prim.p1 * bc.y + prim.p2 * bc.z;
					depthbuffer[pixelIndex].z = point.z;
				}
			}
		}
	}
}

//TODO: Implement a fragment shader
__global__ void fragmentShadeKernel(fragment* depthbuffer, glm::vec2 resolution, glm::vec3 lightPos, glm::vec3 lightColor){
  int x = (blockIdx.x * blockDim.x) + threadIdx.x;
  int y = (blockIdx.y * blockDim.y) + threadIdx.y;
  int index = x + (y * resolution.x);
  if(x<=resolution.x && y<=resolution.y){
		glm::vec3 lightDir = glm::normalize(glm::vec3(lightPos - depthbuffer[index].position));
		float diffuseTerm = glm::clamp(glm::dot(lightDir, depthbuffer[index].normal), 0.0f, 1.0f);
	  depthbuffer[index].color = diffuseTerm * lightColor * depthbuffer[index].color;
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

// Wrapper for the __global__ call that sets up the kernel calls and does a ton of memory management
void cudaRasterizeCore(uchar4* PBOpos, glm::vec2 resolution, glm::vec3 eye, glm::vec3 center, float frame, float* vbo,
											 int vbosize, float* cbo, int cbosize, float* nbo, int nbosize, int* ibo, int ibosize){
  // set up crucial magic
  int tileSize = 8;
  dim3 threadsPerBlock(tileSize, tileSize);
  dim3 fullBlocksPerGrid((int)ceil(float(resolution.x)/float(tileSize)), (int)ceil(float(resolution.y)/float(tileSize)));

  //set up framebuffer
  framebuffer = NULL;
  cudaMalloc((void**)&framebuffer, (int)resolution.x*(int)resolution.y*sizeof(glm::vec3));
  
  //set up depthbuffer
  depthbuffer = NULL;
  cudaMalloc((void**)&depthbuffer, (int)resolution.x*(int)resolution.y*sizeof(fragment));

  //kernel launches to black out accumulated/unaccumlated pixel buffers and clear our scattering states
  clearImage<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, framebuffer, glm::vec3(0,0,0));
  
  fragment frag;
  frag.color = glm::vec3(0,0,0);
  frag.normal = glm::vec3(0,0,0);
  frag.position = glm::vec3(0,0,0);
  frag.z = -FLT_MAX;
  clearDepthBuffer<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, depthbuffer,frag);

  //------------------------------
  //memory stuff
  //------------------------------
  triangle* primitives = NULL;
	int primcount = ibosize/3;
  cudaMalloc((void**)&primitives, primcount*sizeof(triangle));

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

  tileSize = 64;

  //------------------------------
  //compute the camera matrix
  //------------------------------
  float aspect = resolution.x / resolution.y;
  glm::mat4 perspMatrix = glm::perspective(fovy, resolution.x/resolution.y, zNear, zFar);
  glm::mat4 lookatMatrix = glm::lookAt(eye, center, up);
  glm::mat4 cameraMatrix = perspMatrix * lookatMatrix;

  //------------------------------
  //primitive assembly
  //------------------------------
  int primitiveBlocks = ceil(((float)primcount)/((float)tileSize));
  primitiveAssemblyKernel<<<primitiveBlocks, tileSize>>>(device_vbo, vbosize, device_cbo, cbosize, device_nbo, nbosize, device_ibo, ibosize, primitives);

  cudaDeviceSynchronize();

	//triangle* prim_cpu = new triangle[ibosize/3];
 // cudaMemcpy(prim_cpu, primitives, ibosize/3*sizeof(triangle), cudaMemcpyDeviceToHost);
 // triangle t = prim_cpu[0];

  //------------------------------
  //vertex shader
  //------------------------------
	primitiveBlocks = ceil(((float)vbosize/3)/((float)tileSize));
  vertexShadeKernel<<<primitiveBlocks, tileSize>>>(device_vbo, vbosize, cameraMatrix, resolution);

  cudaDeviceSynchronize();

  //------------------------------
  //update primitives
  //------------------------------
	primitiveBlocks = ceil(((float)primcount)/((float)tileSize));
  updatePrimitiveKernel<<<primitiveBlocks, tileSize>>>(device_vbo, vbosize, device_ibo, ibosize, primitives);

  cudaDeviceSynchronize();

  //cudaMemcpy(prim_cpu, primitives, ibosize/3*sizeof(triangle), cudaMemcpyDeviceToHost);
  //t = prim_cpu[0];

	//------------------------------
  //back face culling and clipping
  //------------------------------
	int* validArray = NULL;
	cudaMalloc((void**)&validArray, primcount*sizeof(int));

	validatePrims<<<primitiveBlocks, tileSize>>>(primitives, primcount, validArray, center-eye, resolution);
	cudaDeviceSynchronize();
	
	//stream compaction
	int* scanArray = NULL;
	cudaMalloc((void**)&scanArray, primcount*sizeof(int));
	copy<<<primitiveBlocks, tileSize>>>(validArray, primcount, scanArray);
	cudaDeviceSynchronize();

	int* sumArray1 = NULL;
	int* sumArray2 = NULL;
	int sumArrayLength = primitiveBlocks;
	cudaMalloc((void**)&sumArray1, sumArrayLength*sizeof(int));
	cudaMalloc((void**)&sumArray2, sumArrayLength*sizeof(int));
	sharedMemoryScan<<<primitiveBlocks, tileSize>>>(scanArray, sumArray1, primcount);
	cudaDeviceSynchronize();

	int naiveScanBlocksPerGrid = ((int)ceil((float)sumArrayLength/(float)64), 24); // 24 is the number of SMs on my GPU
	int naiveScanThreadsPerBlock = ceil((float)sumArrayLength/(float)naiveScanBlocksPerGrid);
	int d = 1;
	for (; d<=ceil(log(float(sumArrayLength))/log(2.0f)); ++d) {
		// use double buffer
		if (d % 2 == 1) {
			naiveScan<<<naiveScanBlocksPerGrid, naiveScanThreadsPerBlock>>>(sumArray1, sumArray2, d, sumArrayLength);
			cudaDeviceSynchronize();
		}
		else {
			naiveScan<<<naiveScanBlocksPerGrid, naiveScanThreadsPerBlock>>>(sumArray2, sumArray1, d, sumArrayLength);
			cudaDeviceSynchronize();
		}
	}
	if (d % 2 == 1) {
		addToScanArray<<<primitiveBlocks, tileSize>>>(scanArray, sumArray1, primcount);
		cudaDeviceSynchronize();
	}
	else {
		addToScanArray<<<primitiveBlocks, tileSize>>>(scanArray, sumArray2, primcount);
		cudaDeviceSynchronize();
	}

	int* validPrimCount = new int[1];
	cudaMemcpy(validPrimCount, scanArray + primcount - 1, sizeof(int), cudaMemcpyDeviceToHost);

	validPrimitives = NULL;
	cudaMalloc((void**)&validPrimitives, validPrimCount[0]*sizeof(triangle));
	scatter<<<primitiveBlocks, tileSize>>>(primitives, validArray, scanArray, validPrimitives, primcount);
	cudaDeviceSynchronize();

	primcount = validPrimCount[0];
	delete [] validPrimCount;

	cudaFree(validArray);
	cudaFree(scanArray);
	cudaFree(sumArray1);
	cudaFree(sumArray2);
	cudaFree(primitives);

  //------------------------------
  //rasterization
  //------------------------------
	tileSize = 64;
	primitiveBlocks = ceil(((float)primcount)/((float)tileSize));
	rasterizationKernel<<<primitiveBlocks, tileSize>>>(validPrimitives, primcount, depthbuffer, resolution);

  cudaDeviceSynchronize();

  //------------------------------
  //fragment shader
  //------------------------------
  fragmentShadeKernel<<<fullBlocksPerGrid, threadsPerBlock>>>(depthbuffer, resolution, lightPos, lightColor);

  cudaDeviceSynchronize();
  //------------------------------
  //write fragments to framebuffer
  //------------------------------
  render<<<fullBlocksPerGrid, threadsPerBlock>>>(resolution, depthbuffer, framebuffer);
  sendImageToPBO<<<fullBlocksPerGrid, threadsPerBlock>>>(PBOpos, resolution, framebuffer);

  cudaDeviceSynchronize();

  kernelCleanup();

  checkCUDAError("Kernel failed!");
}

void kernelCleanup(){
  cudaFree( validPrimitives );
  cudaFree( device_vbo );
  cudaFree( device_cbo );
  cudaFree( device_nbo );
  cudaFree( device_ibo );
  cudaFree( framebuffer );
  cudaFree( depthbuffer );
}

