#ifndef GPU_FUNC_H_
#define GPU_FUNC_H_

#include <cuda_runtime.h>
#include <helper_cuda.h>
#include "cublas_v2.h"
#include <thrust/execution_policy.h>
#include "proxgpu_types.h"


typedef struct cox_data{
    numeric *X;
    numeric *censor;
    int *rankmin;
    int *rankmax;
    int *ncase_cumu; // an array in the form {0, ncase[0], ncase[1],...,ncase[K-1]}.
} cox_data;

typedef struct cox_cache{
    numeric *outer_accumu;
    numeric *eta;
    numeric *exp_eta;
    numeric *exp_accumu;
    numeric *residual;
    numeric *B_col_norm;
    numeric *cox_val;
} cox_cache;

typedef struct cox_param{
    numeric *B;
    numeric *v;
    numeric *grad;
    numeric *prev_B;
    numeric *penalty_factor;
    numeric *ls_result;
    numeric *grad_ls;
    numeric *change;

} cox_param;

void allocate_device_memory(cox_data &dev_data, cox_cache &dev_cache, cox_param &dev_param, int total_cases, int K, int p);

void free_device_memory(cox_data &dev_data, cox_cache &dev_cache, cox_param &dev_param);


void compute_product(numeric *A, numeric *x, numeric *b, 
                     int n, int p, cudaStream_t stream, cublasHandle_t handle, cublasOperation_t trans);

void apply_exp(const numeric *x, numeric *ex, int len, cudaStream_t stream);
void rev_cumsum(numeric *x, numeric *y, int len, cudaStream_t stream);
void adjust_ties(const numeric *x, const int *rank, numeric *y, int len , cudaStream_t stream);
void cwise_div(const numeric *x, const numeric *y, numeric *z, int len, cudaStream_t stream);
void cumsum(numeric *x, int len, cudaStream_t stream);

void mult_add(numeric *z, const numeric *a, const numeric *b, const numeric *c, int len,cudaStream_t stream);

void get_coxvalue(const numeric *x, numeric *y, const numeric *z, numeric *val, int len, cudaStream_t stream);

void update_parameters(cox_param &dev_param,
                       int K,
                       int p,
                       numeric step_size,
                       numeric lambda_1,
                       numeric lambda_2);

numeric ls_stop_v1(cox_param &dev_param, numeric step_size, int K, int p);

numeric ls_stop_v2(cox_param &dev_param, numeric step_size, int K, int p);

void nesterov_update(cox_param &dev_param, int K, int p, numeric weight_old, numeric weight_new, cudaStream_t stream, cublasHandle_t handle);

numeric max_diff(cox_param &dev_param, int K, int p);

void cublas_copy(cox_param &dev_param, int len, cudaStream_t stream, cublasHandle_t handle);

#endif