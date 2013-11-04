// CIS565 CUDA Rasterizer: A simple rasterization pipeline for Patrick Cozzi's CIS565: GPU Computing at the University of Pennsylvania
// Written by Yining Karl Li, Copyright (c) 2012 University of Pennsylvania

#ifndef RASTERIZESTRUCTS_H
#define RASTERIZESTRUCTS_H

#include "glm/glm.hpp"
#include "cudaMat4.h"

struct triangle {
  glm::vec3 p0; //the original vertices
  glm::vec3 p1;
  glm::vec3 p2;
  glm::vec3 pt0; //the transformed vertices
  glm::vec3 pt1;
  glm::vec3 pt2;
  glm::vec3 c0;
  glm::vec3 c1;
  glm::vec3 c2;
  glm::vec3 n0;
  glm::vec3 n1;
  glm::vec3 n2;

  __host__ __device__ triangle() : p0(), p1(), p2(), pt0(), pt1(), pt2(), c0(), c1(), c2(), n0(), n1(), n2() {};
  __host__ __device__ triangle(glm::vec3 vp0, glm::vec3 vp1, glm::vec3 vp2, glm::vec3 vc0, glm::vec3 vc1, glm::vec3 vc2, glm::vec3 vn0, glm::vec3 vn1, glm::vec3 vn2) :
	  p0(vp0), p1(vp1), p2(vp2), pt0(), pt1(), pt2(), c0(vc0), c1(vc1), c2(vc2), n0(vn0), n1(vn1), n2(vn2) {};
};

struct fragment{
  glm::vec3 color;
  glm::vec3 normal;
  glm::vec3 position;
  float z;
};

#endif