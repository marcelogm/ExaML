#include "axml.h"
#include <math.h>
#include <stdbool.h>

static unsigned int GRID_SIZE_N;
static unsigned int GRID_SIZE_4N;
static unsigned int MAX_STATE_VALUE;

static inline int cudaBestGrid(int n) {
  return (n / BLOCK_SIZE) + ((n % BLOCK_SIZE == 0) ? 0 : 1);
}

__global__ static void cudaTTGammaKernel(double *extEV, double *x3, double *uX1,
                                         double *uX2, unsigned char *tipX1,
                                         unsigned char *tipX2) {
  __shared__ volatile double x1px2[16], v[64];
  const int tid = threadIdx.z * 16 + threadIdx.y * 4 + threadIdx.x;
  const int squareId = threadIdx.z * 4 + threadIdx.y;
  if (threadIdx.x == 0) {
    x1px2[squareId] = uX1[16 * tipX1[blockIdx.x] + squareId] *
                      uX2[16 * tipX2[blockIdx.x] + squareId];
  }
  __syncthreads();
  v[tid] = x1px2[squareId] * extEV[4 * threadIdx.y + threadIdx.x];
  __syncthreads();
  if (threadIdx.y <= 1) {
    v[tid] += v[tid + 8];
  }
  __syncthreads();
  if (threadIdx.y == 0) {
    v[tid] += v[tid + 4];
    x3[blockIdx.x * 16 + threadIdx.z * 4 + threadIdx.x] = v[tid];
  }
}

__global__ static void cudaTIGammaKernel(double *extEV, double *x2, double *x3,
                                         unsigned char *tipX1,
                                         unsigned char *tipX2, double *r,
                                         double *uX1, double *uX2) {
  __shared__ volatile double ump[64], x1px2[16], v[64];
  const int tid = (threadIdx.z * 16) + (threadIdx.y * 4) + threadIdx.x;
  const int offset = 16 * blockIdx.x + threadIdx.z * 4;
  const int squareId = threadIdx.z * 4 + threadIdx.y;
  uX1 += 16 * tipX1[blockIdx.x];
  ump[tid] = x2[offset + threadIdx.x] * r[tid];
  __syncthreads();
  if (threadIdx.x <= 1) {
    ump[tid] += ump[tid + 2];
  }
  __syncthreads();
  if (threadIdx.x == 0) {
    ump[tid] += ump[tid + 1];
    uX2[4 * blockIdx.x + threadIdx.y] = ump[tid];
    x1px2[squareId] = uX1[squareId] * ump[tid];
  }
  __syncthreads();
  v[tid] = x1px2[squareId] * extEV[threadIdx.y * 4 + threadIdx.x];
  __syncthreads();
  if (threadIdx.y <= 1) {
    v[tid] += v[tid + 8];
  }
  __syncthreads();
  if (threadIdx.y == 0) {
    v[tid] += v[tid + 4];
    x3[offset + threadIdx.x] = v[tid];
  }
}

__global__ static void cudaIIGammaKernel(double *extEV, double *x1, double *x2,
                                         double *x3, double *left,
                                         double *right) {
  __shared__ volatile double al[64], ar[64], v[64], x1px2[16];
  const int tid = (threadIdx.z * 16) + (threadIdx.y * 4) + threadIdx.x;
  const int offset = 16 * blockIdx.x + 4 * threadIdx.z;
  al[tid] = x1[offset + threadIdx.x] * left[tid];
  ar[tid] = x2[offset + threadIdx.x] * right[tid];
  __syncthreads();
  if (threadIdx.x <= 1) {
    al[tid] += al[tid + 2];
    ar[tid] += ar[tid + 2];
  }
  __syncthreads();
  if (threadIdx.x == 0) {
    al[tid] += al[tid + 1];
    ar[tid] += ar[tid + 1];
    x1px2[(threadIdx.z * 4) + threadIdx.y] = al[tid] * ar[tid];
  }
  __syncthreads();
  v[tid] = x1px2[threadIdx.y + (threadIdx.z * 4)] *
           extEV[threadIdx.y * 4 + threadIdx.x];
  __syncthreads();
  if (threadIdx.y <= 1) {
    v[tid] += v[tid + 8];
  }
  __syncthreads();
  if (threadIdx.y == 0) {
    v[tid] += v[tid + 4];
    x3[offset + threadIdx.x] = v[tid];
  }
}

__global__ static void cudaPreTTGammaKernel(double *tipVector, double *l, double *r,
                                              double *umpX1, double *umpX2)
{
    __shared__ volatile double ump[64];
    const int tid = threadIdx.y * 4 + threadIdx.x;
    if (blockIdx.y == 0)
    {
        ump[tid] = tipVector[4 * blockIdx.x + threadIdx.x] * l[tid];
        __syncthreads();
        if (threadIdx.x <= 1)
        {
            ump[tid] += ump[tid + 2];
        }
        __syncthreads();
        if (threadIdx.x == 0)
        {
            ump[tid] += ump[tid + 1];
            umpX1[blockIdx.x * 16 + threadIdx.y] = ump[tid];
        }
    }
    else
    {
        ump[tid] = tipVector[4 * blockIdx.x + threadIdx.x] * r[tid];
        __syncthreads();
        if (threadIdx.x <= 1)
        {
            ump[tid] += ump[tid + 2];
        }
        __syncthreads();
        if (threadIdx.x == 0)
        {
            ump[tid] += ump[tid + 1];
            umpX2[blockIdx.x * 16 + threadIdx.y] = ump[tid];
        }
    }
}

__global__ static void cudaPreTIGammaKernel(double *tipVector, double *l, double *ump)
{
    __shared__ volatile double sump[64];
    const int tid = threadIdx.y * 4 + threadIdx.x;
    sump[tid] = tipVector[4 * blockIdx.x + threadIdx.x] * l[tid];
    __syncthreads();
    if (threadIdx.x <= 1)
    {
        sump[tid] += sump[tid + 2];
    }
    __syncthreads();
    if (threadIdx.x == 0)
    {
        sump[tid] += sump[tid + 1];
        ump[blockIdx.x * 16 + threadIdx.y] = sump[tid];
    }
}


__global__ static void
cudaEvaluateLeftGammaKernel(int *wptr, double *x2, double *tipVector,
                            unsigned char *tipX1, double *diagptable,
                            double *output, const int limit) {
  const int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= limit) {
    output[i] = 0.0;
    return;
  }
  int j;
  double term = 0.0;
  tipVector += 4 * tipX1[i];
  x2 += 16 * i;
#pragma unroll
  for (j = 0; j < 4; j++) {
    term += tipVector[0] * x2[0] * diagptable[0];
    term += tipVector[1] * x2[1] * diagptable[1];
    term += tipVector[2] * x2[2] * diagptable[2];
    term += tipVector[3] * x2[3] * diagptable[3];
    x2 += 4;
    diagptable += 4;
  }
  term = log(0.25 * fabs(term));
  output[i] = wptr[i] * term;
}

__global__ static void cudaEvaluateRightGammaKernel(int *wptr, double *x1,
                                                    double *x2,
                                                    double *diagptable,
                                                    double *output,
                                                    const int limit) {
  const int i = blockIdx.x * blockDim.x + threadIdx.x;
  output[i] = 0.0;
  if (i >= limit) {
    return;
  }
  int j;
  double term = 0.0;
  x1 += 16 * i;
  x2 += 16 * i;
#pragma unroll
  for (j = 0; j < 4; j++) {
    term += x1[0] * x2[0] * diagptable[0];
    term += x1[1] * x2[1] * diagptable[1];
    term += x1[2] * x2[2] * diagptable[2];
    term += x1[3] * x2[3] * diagptable[3];
    x1 += 4;
    x2 += 4;
    diagptable += 4;
  }
  term = log(0.25 * fabs(term));
  output[i] += wptr[i] * term;
}

__global__ static void cudaSumTTGammaKernel(unsigned char *tipX1,
                                            unsigned char *tipX2,
                                            double *tipVector, double *sumtable,
                                            int limit) {
  const int n = blockIdx.x * blockDim.x + threadIdx.x;
  if (n >= limit) {
    return;
  }
  const int i = n / 4, j = n % 4;
  double *left = &(tipVector[4 * tipX1[i]]);
  double *right = &(tipVector[4 * tipX2[i]]);
  double *sum = &sumtable[i * 16 + j * 4];
#pragma unroll
  for (int k = 0; k < 4; k++) {
    sum[k] = left[k] * right[k];
  }
}

__global__ static void cudaSumTIGammaKernel(unsigned char *tipX1, double *x2,
                                            double *tipVector, double *sumtable,
                                            int limit) {
  const int n = blockIdx.x * blockDim.x + threadIdx.x;
  if (n >= limit) {
    return;
  }
  const int i = n / 4, l = n % 4;
  double *left = &(tipVector[4 * tipX1[i]]);
  double *right = &(x2[16 * i + l * 4]);
  double *sum = &sumtable[i * 16 + l * 4];
#pragma unroll
  for (int k = 0; k < 4; k++) {
    sum[k] = left[k] * right[k];
  }
}

__global__ static void cudaSumIIGammaKernel(double *x1, double *x2,
                                            double *sumtable, int limit) {
  const int n = blockIdx.x * blockDim.x + threadIdx.x;
  if (n >= limit) {
    return;
  }
  const int i = n / 4, l = n % 4;
  double *left = &(x1[16 * i + l * 4]);
  double *right = &(x2[16 * i + l * 4]);
  double *sum = &(sumtable[i * 16 + l * 4]);
#pragma unroll
  for (int k = 0; k < 4; k++) {
    sum[k] = left[k] * right[k];
  }
}

__global__ static void cudaCoreGammaKernel(double *sumtable, double *diagptable,
                                           int *wgt, double *dlnLdlzBuffer,
                                           double *d2lnLdlz2Buffer, int limit) {
  const int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= limit) {
    dlnLdlzBuffer[i] = 0.0;
    d2lnLdlz2Buffer[i] = 0.0;
    return;
  }
  double *sum = &sumtable[i * 16];
  double inv_Li = 0.0;
  double dlnLidlz = 0.0;
  double d2lnLidlz2 = 0.0;
  double tmp;
  int j, l;
#pragma unroll
  for (j = 0; j < 4; j++) {
    inv_Li += sum[j * 4];
#pragma unroll
    for (l = 1; l < 4; l++) {
      inv_Li += (tmp = diagptable[j * 16 + l * 4] * sum[j * 4 + l]);
      dlnLidlz += tmp * diagptable[j * 16 + l * 4 + 1];
      d2lnLidlz2 += tmp * diagptable[j * 16 + l * 4 + 2];
    }
  }
  inv_Li = 1.0 / FABS(inv_Li);
  dlnLidlz *= inv_Li;
  d2lnLidlz2 *= inv_Li;
  dlnLdlzBuffer[i] = wgt[i] * dlnLidlz;
  d2lnLdlz2Buffer[i] = wgt[i] * (d2lnLidlz2 - dlnLidlz * dlnLidlz);
}

__global__ static void cudaAScaleGammaKernel(double *x3, int *addScale,
                                             int *wgt, int limit) {
  const int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= limit)
    return;
  x3 += 16 * i;
  int l, scale = 1;
#pragma unroll
  for (l = 0; scale && (l < 16); l++) {
    scale = (ABS(x3[l]) < minlikelihood);
  }
  if (scale) {
#pragma unroll
    for (l = 0; l < 16; l++)
      x3[l] *= twotothe256;
    atomicAdd(addScale, wgt[i]);
  }
}

template <unsigned int blockSize>
__global__ static void cudaUnrolledReduceKernel(double *input, double *output,
                                                unsigned int limit) {
  __shared__ volatile double sdata[BLOCK_SIZE];
  const unsigned int tid = threadIdx.x;
  const unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= limit) {
    sdata[tid] = 0.0;
  } else {
    sdata[tid] = input[i];
  }
  __syncthreads();
  if (blockSize >= 512) {
    if (tid < 256) {
      sdata[tid] += sdata[tid + 256];
    }
    __syncthreads();
  }
  if (blockSize >= 256) {
    if (tid < 128) {
      sdata[tid] += sdata[tid + 128];
    }
    __syncthreads();
  }
  if (blockSize >= 128) {
    if (tid < 64) {
      sdata[tid] += sdata[tid + 64];
    }
    __syncthreads();
  }
  if (tid < 32) {
    if (blockSize >= 64) {
      sdata[tid] += sdata[tid + 32];
    }
    if (blockSize >= 32) {
      sdata[tid] += sdata[tid + 16];
    }
    if (blockSize >= 16) {
      sdata[tid] += sdata[tid + 8];
    }
    if (blockSize >= 8) {
      sdata[tid] += sdata[tid + 4];
    }
    if (blockSize >= 4) {
      sdata[tid] += sdata[tid + 2];
    }
    if (blockSize >= 2) {
      sdata[tid] += sdata[tid + 1];
    }
  }
  if (tid == 0) {
    output[blockIdx.x] = sdata[0];
  }
}

extern "C" CudaGP *cudaGPAlloc(const int n, const int states,
                               const int maxStateValue, const int taxa,
                               unsigned char *yResource, int *wgt) {
  const int statesSquare = states * states, span = states * 4,
            precomputeLength = maxStateValue * span;
  int i;
  GRID_SIZE_N = cudaBestGrid(n);
  GRID_SIZE_4N = cudaBestGrid(n * 4);
  MAX_STATE_VALUE = maxStateValue;
  CudaGP *p = (CudaGP *)malloc(sizeof(CudaGP));
  p->sumBufferSize = sizeof(double) * n * 4 * states;
  p->pVectorSize = sizeof(double) * statesSquare * 4;
  cudaMalloc(&p->addScale, sizeof(int));
  cudaMalloc(&p->extEV, sizeof(double) * statesSquare);
  cudaMalloc(&p->tipVector, sizeof(double) * span * states);
  cudaMalloc(&p->left, p->pVectorSize);
  cudaMalloc(&p->right, p->pVectorSize);
  cudaMalloc(&p->umpX1, sizeof(double) * precomputeLength);
  cudaMalloc(&p->umpX2, (n * states * 4 < 256)
                            ? sizeof(double) * precomputeLength
                            : sizeof(double) * n * states * 4);
  cudaMalloc(&p->diagptable, p->pVectorSize);
  cudaMalloc(&p->sumBuffer, p->sumBufferSize);
  cudaMalloc(&p->reduceBufferB, GRID_SIZE_N * BLOCK_SIZE * sizeof(double));
  cudaMalloc(&p->reduceBufferA, GRID_SIZE_N * sizeof(double));
  cudaMalloc(&p->dlnLdlzBuffer, GRID_SIZE_N * BLOCK_SIZE * sizeof(double));
  cudaMalloc(&p->d2lnLdlz2Buffer, GRID_SIZE_N * BLOCK_SIZE * sizeof(double));
  p->hReduceBuffer = (double *)malloc(sizeof(double) * GRID_SIZE_N);
  // xVector allocation
  p->xVector = (double **)malloc(sizeof(double *) * taxa);
#pragma unroll
  for (i = 0; i < taxa; i++) {
    p->xVector[i] = (double *)NULL;
  }
  // yVector allocation and copy
  p->yVector = (unsigned char **)calloc(taxa + 1, sizeof(unsigned char *));
  cudaMalloc(&p->yResource, taxa * n * sizeof(unsigned char));
  cudaMemcpy(p->yResource, yResource, taxa * n * sizeof(unsigned char),
             cudaMemcpyHostToDevice);
#pragma unroll
  for (i = 1; i <= taxa; ++i) {
    p->yVector[i] = p->yResource + (i - 1) * n;
  }
  // Wgt copy
  cudaMalloc(&p->wgt, n * sizeof(int));
  cudaMemcpy(p->wgt, wgt, n * sizeof(int), cudaMemcpyHostToDevice);
  p->length = n;
  p->taxa = taxa;
  p->span = states * 4;
  return p;
}

extern "C" void cudaGPAllocXVector(double **x, unsigned int size) {
  if (*x) {
    cudaFree(*x);
  }
  cudaMalloc(x, size);
}

extern "C" void cudaGPCopyModel(CudaGP *dst, double *evSrc, unsigned int evSize,
                                double *tipSrc, unsigned int tipSize) {
  cudaMemcpy(dst->extEV, evSrc, evSize * sizeof(double),
             cudaMemcpyHostToDevice);
  cudaMemcpy(dst->tipVector, tipSrc, tipSize * sizeof(double),
             cudaMemcpyHostToDevice);
}

extern "C" double cudaEvaluateGAMMA(int *wptr, double *x1_start,
                                    double *x2_start, unsigned char *tipX1,
                                    const int n, double *diagptable,
                                    CudaGP *p) {
  double sum = 0.0;
  cudaMemcpy(p->diagptable, diagptable, p->pVectorSize, cudaMemcpyHostToDevice);
  if (tipX1) {
    cudaEvaluateLeftGammaKernel<<<GRID_SIZE_N, BLOCK_SIZE>>>(
        wptr, x2_start, p->tipVector, tipX1, p->diagptable, p->reduceBufferB,
        n);
  } else {
    cudaEvaluateRightGammaKernel<<<GRID_SIZE_N, BLOCK_SIZE>>>(
        wptr, x1_start, x2_start, p->diagptable, p->reduceBufferB, n);
  }
#ifdef __MULTI_REDUCE
  bool flag = TRUE;
  unsigned int toReduce = n;
  do {
    unsigned int grid = cudaBestGrid(toReduce);
    if (flag) {
      cudaUnrolledReduceKernel<BLOCK_SIZE><<<grid, BLOCK_SIZE>>>(
          p->reduceBufferB, p->reduceBufferA, toReduce);
      flag = FALSE;
    } else {
      cudaUnrolledReduceKernel<BLOCK_SIZE><<<grid, BLOCK_SIZE>>>(
          p->reduceBufferA, p->reduceBufferB, toReduce);
      flag = TRUE;
    }
    toReduce = grid;
  } while (toReduce > 1);
  cudaMemcpy(&sum, (flag) ? p->reduceBufferB : p->reduceBufferA, sizeof(double),
             cudaMemcpyDeviceToHost);
#else
  cudaUnrolledReduceKernel<BLOCK_SIZE><<<GRID_SIZE_N, BLOCK_SIZE>>>(
      p->reduceBufferB, p->reduceBufferA, n);
  cudaMemcpy(p->hReduceBuffer, p->reduceBufferA, GRID_SIZE_N * sizeof(double),
             cudaMemcpyDeviceToHost);
#pragma unroll
  for (int i = 0; i < GRID_SIZE_N; i++) {
    sum += p->hReduceBuffer[i];
  }
#endif
  return sum;
}

extern "C" void cudaNewViewGAMMA(int tipCase, double *x1, double *x2,
                                 double *x3, unsigned char *tipX1,
                                 unsigned char *tipX2, int n, double *left,
                                 double *right, int *wgt, int *scalerIncrement,
                                 CudaGP *p) {
  int addScale = 0;
  cudaMemcpy(p->left, left, p->pVectorSize, cudaMemcpyHostToDevice);
  cudaMemcpy(p->right, right, p->pVectorSize, cudaMemcpyHostToDevice);
  dim3 block(4, 4, 4);
  switch (tipCase) {
  case TIP_TIP: {
    dim3 pregrid(MAX_STATE_VALUE, 2, 1);
    dim3 preblock(4, 16, 1);
    cudaPreTTGammaKernel<<<pregrid, preblock>>>(p->tipVector, p->left, p->right, p->umpX1,
      p->umpX2);
    /*cudaPreTTGammaKernel<<<MAX_STATE_VALUE * 2, p->span>>>(
        p->tipVector, p->left, p->right, p->umpX1, p->umpX2, MAX_STATE_VALUE);*/
    cudaTTGammaKernel<<<n, block>>>(p->extEV, x3, p->umpX1, p->umpX2, tipX1,
                                    tipX2);
  } break;
  case TIP_INNER: {
    /*
    cudaPreTIGammaKernel<<<MAX_STATE_VALUE, p->span>>>(
        p->tipVector, p->left, p->umpX1, MAX_STATE_VALUE);*/
    dim3 preblock(4, 16, 1);
    cudaPreTIGammaKernel<<<MAX_STATE_VALUE, preblock>>>(p->tipVector, p->left, p->umpX1);
    cudaTIGammaKernel<<<n, block>>>(p->extEV, x2, x3, tipX1, tipX2, p->right,
                                    p->umpX1, p->umpX2);
    cudaMemset(p->addScale, 0, sizeof(int));
    cudaAScaleGammaKernel<<<GRID_SIZE_N, BLOCK_SIZE>>>(x3, p->addScale, wgt, n);
    cudaMemcpy(&addScale, p->addScale, sizeof(int), cudaMemcpyDeviceToHost);
  } break;
  case INNER_INNER: {
    cudaIIGammaKernel<<<n, block>>>(p->extEV, x1, x2, x3, p->left, p->right);
    cudaMemset(p->addScale, 0, sizeof(int));
    cudaAScaleGammaKernel<<<GRID_SIZE_N, BLOCK_SIZE>>>(x3, p->addScale, wgt, n);
    cudaMemcpy(&addScale, p->addScale, sizeof(int), cudaMemcpyDeviceToHost);
  } break;
  default:
    assert(0);
  }

  *scalerIncrement = addScale;
}

extern "C" void cudaSumGAMMA(int tipCase, double *sumtable, double *x1,
                             double *x2, unsigned char *tipX1,
                             unsigned char *tipX2, int n, CudaGP *p) {

  switch (tipCase) {
  case TIP_TIP:
    cudaSumTTGammaKernel<<<GRID_SIZE_4N, BLOCK_SIZE>>>(
        tipX1, tipX2, p->tipVector, p->sumBuffer, n * 4);

    break;
  case TIP_INNER:
    cudaSumTIGammaKernel<<<GRID_SIZE_4N, BLOCK_SIZE>>>(tipX1, x2, p->tipVector,
                                                       p->sumBuffer, n * 4);
    break;
  case INNER_INNER:
    cudaSumIIGammaKernel<<<GRID_SIZE_4N, BLOCK_SIZE>>>(x1, x2, p->sumBuffer,
                                                       n * 4);
    break;
  default:
    assert(0);
  }
}

extern "C" void cudaCoreGAMMA(int upper, volatile double *ext_dlnLdlz,
                              volatile double *ext_d2lnLdlz2, double *EIGN,
                              double *gammaRates, double lz, CudaGP *p) {
  double diagptable[1024], ki, kisqr;
  int i, l;
#pragma unroll
  for (i = 0; i < 4; i++) {
    ki = gammaRates[i];
    kisqr = ki * ki;

#pragma unroll
    for (l = 1; l < 4; l++) {
      diagptable[i * 16 + l * 4] = EXP(EIGN[l] * ki * lz);
      diagptable[i * 16 + l * 4 + 1] = EIGN[l] * ki;
      diagptable[i * 16 + l * 4 + 2] = EIGN[l] * EIGN[l] * kisqr;
    }
  }

  cudaMemcpy(p->diagptable, diagptable, p->pVectorSize, cudaMemcpyHostToDevice);
  cudaCoreGammaKernel<<<GRID_SIZE_N, BLOCK_SIZE>>>(p->sumBuffer, p->diagptable,
                                                   p->wgt, p->dlnLdlzBuffer,
                                                   p->d2lnLdlz2Buffer, upper);
#ifdef __MULTI_REDUCE
  bool flag = TRUE;
  unsigned int toReduce = upper;
  do {
    unsigned int grid = cudaBestGrid(toReduce);
    if (flag) {
      cudaUnrolledReduceKernel<BLOCK_SIZE><<<grid, BLOCK_SIZE>>>(
          p->dlnLdlzBuffer, p->reduceBufferB, toReduce);
      cudaUnrolledReduceKernel<BLOCK_SIZE><<<grid, BLOCK_SIZE>>>(
          p->d2lnLdlz2Buffer, p->reduceBufferA, toReduce);
      flag = FALSE;
    } else {
      cudaUnrolledReduceKernel<BLOCK_SIZE><<<grid, BLOCK_SIZE>>>(
          p->reduceBufferB, p->dlnLdlzBuffer, toReduce);
      cudaUnrolledReduceKernel<BLOCK_SIZE><<<grid, BLOCK_SIZE>>>(
          p->reduceBufferA, p->d2lnLdlz2Buffer, toReduce);
      flag = TRUE;
    }
    toReduce = grid;
  } while (toReduce > 1);
  if (flag) {
    cudaMemcpy((void *)ext_d2lnLdlz2, p->d2lnLdlz2Buffer, sizeof(double),
               cudaMemcpyDeviceToHost);
    cudaMemcpy((void *)ext_dlnLdlz, p->dlnLdlzBuffer, sizeof(double),
               cudaMemcpyDeviceToHost);
  } else {
    cudaMemcpy((void *)ext_d2lnLdlz2, p->reduceBufferA, sizeof(double),
               cudaMemcpyDeviceToHost);
    cudaMemcpy((void *)ext_dlnLdlz, p->reduceBufferB, sizeof(double),
               cudaMemcpyDeviceToHost);
  }
#else
  cudaUnrolledReduceKernel<BLOCK_SIZE><<<GRID_SIZE_N, BLOCK_SIZE>>>(
      p->dlnLdlzBuffer, p->reduceBufferA, upper);
  cudaMemcpy(p->hReduceBuffer, p->reduceBufferA, GRID_SIZE_N * sizeof(double),
             cudaMemcpyDeviceToHost);
#pragma unroll
  for (int i = 0; i < GRID_SIZE_N; i++) {
    *ext_dlnLdlz += p->hReduceBuffer[i];
  }
  cudaUnrolledReduceKernel<BLOCK_SIZE><<<GRID_SIZE_N, BLOCK_SIZE>>>(
      p->d2lnLdlz2Buffer, p->reduceBufferA, upper);
  cudaMemcpy(p->hReduceBuffer, p->reduceBufferA, GRID_SIZE_N * sizeof(double),
             cudaMemcpyDeviceToHost);
#pragma unroll
  for (int i = 0; i < GRID_SIZE_N; i++) {
    *ext_d2lnLdlz2 += p->hReduceBuffer[i];
  }
#endif
}
