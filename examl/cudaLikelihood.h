#include "axml.h"

extern void cudaGPFillXVector(CudaGP *dst, unsigned int tips,
                              long unsigned int size);

extern void cudaGPFillYVector(CudaGP *dst, unsigned char *src);

extern CudaGP *cudaGPMalloc(const int n, const int states,
                            const int maxStateValue, const int taxa);

extern void cudaGPFree(CudaGP *p);

extern void cudaNewViewGAMMA(int tipCase, double *x1, double *x2, double *x3,
                             double *extEV, double *tipVector,
                             unsigned char *tipX1, unsigned char *tipX2, int n,
                             double *left, double *right, int *wgt,
                             int *scalerIncrement, CudaGP *p);

extern double cudaEvaluateGAMMA(int *wptr, double *x1_start, double *x2_start,
                                double *tipVector, unsigned char *tipX1,
                                const int n, double *diagptable,
                                const int states, CudaGP *p);