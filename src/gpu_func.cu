#include "gpu_func.h"
#include <cuda_runtime.h>
#include "cublas_v2.h"
#include <thrust/scan.h>
#include <thrust/device_vector.h>
#include <thrust/iterator/reverse_iterator.h>
#include <thrust/device_ptr.h>
#include <stdlib.h>

typedef thrust::device_vector<numeric>::iterator Iterator; 
#define MAX_THREAD_PER_BLOCK 1024

void allocate_device_memory(cox_data &dev_data, cox_cache &dev_cache, cox_param &dev_param, int total_cases, int K, int p)
{
    cudaMalloc((void**)&dev_data.X, sizeof(numeric) *p * total_cases);
    cudaMalloc((void**)&dev_data.censor, sizeof(numeric)  * total_cases);
    cudaMalloc((void**)&dev_data.rankmin, sizeof(int) * total_cases);
    cudaMalloc((void**)&dev_data.rankmax, sizeof(int) * total_cases);

    cudaMalloc((void**)&dev_cache.outer_accumu, sizeof(numeric) * total_cases);
    cudaMalloc((void**)&dev_cache.eta, sizeof(numeric) * total_cases);
    cudaMalloc((void**)&dev_cache.exp_eta, sizeof(numeric) * total_cases);
    cudaMalloc((void**)&dev_cache.exp_accumu, sizeof(numeric) * total_cases);
    cudaMalloc((void**)&dev_cache.residual, sizeof(numeric) * total_cases);
    cudaMalloc((void**)&dev_cache.B_col_norm, sizeof(numeric) * p);
    cudaMalloc((void**)&dev_cache.cox_val, sizeof(numeric) * K);

    cudaMalloc((void**)&dev_param.B, sizeof(numeric) * K * p);
    cudaMalloc((void**)&dev_param.v, sizeof(numeric) * K * p);
    cudaMalloc((void**)&dev_param.grad, sizeof(numeric) * K * p);
    cudaMalloc((void**)&dev_param.prev_B, sizeof(numeric) * K * p);
    cudaMalloc((void**)&dev_param.grad_ls, sizeof(numeric) * K * p);
    cudaMalloc((void**)&dev_param.penalty_factor, sizeof(numeric) * p);
    cudaMalloc((void**)&dev_param.ls_result, sizeof(numeric) * 2);
    cudaMalloc((void**)&dev_param.change, sizeof(numeric) * 1);

}

void free_device_memory(cox_data &dev_data, cox_cache &dev_cache, cox_param &dev_param)
{
    cudaFree(dev_data.X);
    cudaFree(dev_data.censor);
    cudaFree(dev_data.rankmax);
    cudaFree(dev_data.rankmin);

    cudaFree(dev_cache.outer_accumu);
    cudaFree(dev_cache.eta);
    cudaFree(dev_cache.exp_eta);
    cudaFree(dev_cache.exp_accumu);
    cudaFree(dev_cache.residual);
    cudaFree(dev_cache.B_col_norm);
    cudaFree(dev_cache.cox_val);

    cudaFree(dev_param.B);
    cudaFree(dev_param.v);
    cudaFree(dev_param.grad);
    cudaFree(dev_param.prev_B);
    cudaFree(dev_param.penalty_factor);
    cudaFree(dev_param.ls_result);
    cudaFree(dev_param.grad_ls);
    cudaFree(dev_param.change);

}

#if !defined(__CUDA_ARCH__) || __CUDA_ARCH__ >= 600
#else
__device__ double atomicAdd(double* address, double val)
{
    unsigned long long int* address_as_ull = (unsigned long long int*)address;
    unsigned long long int old = *address_as_ull, assumed;
    do {
        assumed = old;
        old = atomicCAS(address_as_ull, assumed,
                __double_as_longlong(val + __longlong_as_double(assumed)));
    } while (assumed != old);
    return __longlong_as_double(old);
}

#endif


// double atomicMax, copied from https://github.com/treecode/Bonsai/blob/master/runtime/profiling/derived_atomic_functions.h
__device__ __forceinline__ double atomicMax(double *address, double val)
{
    unsigned long long ret = __double_as_longlong(*address);
    while(val > __longlong_as_double(ret))
    {
        unsigned long long old = ret;
        if((ret = atomicCAS((unsigned long long *)address, old, __double_as_longlong(val))) == old)
            break;
    }
    return __longlong_as_double(ret);
}

// float atomicMax
__device__ __forceinline__ float atomicMax(float *address, float val)
{
    int ret = __float_as_int(*address);
    while(val > __int_as_float(ret))
    {
        int old = ret;
        if((ret = atomicCAS((int *)address, old, __float_as_int(val))) == old)
            break;
    }
    return __int_as_float(ret);
}


void compute_product(numeric *A, numeric *x, numeric *b, 
    int n, int p, cudaStream_t stream, cublasHandle_t handle, cublasOperation_t trans=CUBLAS_OP_N)
{
    numeric alpha = 1.0;
    numeric beta = 0.0;
    cublasSetStream(handle, stream);
    cublasDgemv(handle, trans, n, p, &alpha, A, n, x, 1, &beta, b, 1);
}

__global__
void apply_exp_gpu(const numeric *x, numeric *ex, int len)
{
    int tid = blockDim.x * blockIdx.x + threadIdx.x;
    if(tid < len)
    {
        ex[tid] = exp(x[tid]);
    }
}

void apply_exp(const numeric *x, numeric *ex, int len, cudaStream_t stream)
{
    constexpr int num_thread = 128;
    int num_block = (len + num_thread - 1)/num_thread;
    apply_exp_gpu<<<num_block, num_thread, 0, stream>>>(x, ex, len);
}

// do rev_cumsum of x and save it to y
void rev_cumsum(numeric *x, numeric *y, int len, cudaStream_t stream)
{
    thrust::device_ptr<numeric> dptr_x = thrust::device_pointer_cast<numeric>(x);
    thrust::reverse_iterator<Iterator> r_x = make_reverse_iterator(dptr_x+len);
    thrust::device_ptr<numeric> dptr_y = thrust::device_pointer_cast<numeric>(y);
    thrust::reverse_iterator<Iterator> r_y = make_reverse_iterator(dptr_y+len);

    thrust::inclusive_scan(thrust::cuda::par.on(stream), r_x, r_x+len, r_y);
}

__global__
void adjust_ties_gpu(const numeric *x, const int *rank, numeric *y, int len)
{
    int tid = blockDim.x * blockIdx.x + threadIdx.x;
    if(tid < len)
    {
        y[tid] = x[rank[tid]];
    }

}

// adjust rank of x and save it to y
void adjust_ties(const numeric *x, const int *rank, numeric *y, int len , cudaStream_t stream)
{
    constexpr int num_thread = 128;
    int num_block = (len + num_thread - 1)/num_thread;
    adjust_ties_gpu<<<num_block, num_thread, 0, stream>>>(x, rank, y, len);
}


__global__
void cwise_div_gpu(const numeric *x, const  numeric *y, numeric *z, int len)
{
    int tid = blockDim.x * blockIdx.x + threadIdx.x;
    if(tid < len)
    {
        z[tid] = x[tid]/y[tid];
    }

}


// Compute x./y and save the result to z
void cwise_div(const numeric *x, const numeric *y, numeric *z, int len, cudaStream_t stream)
{
    constexpr int num_thread = 128;
    int num_block = (len + num_thread - 1)/num_thread;
    cwise_div_gpu<<<num_block, num_thread, 0, stream>>>(x, y, z, len);
}

void cumsum(numeric *x, int len, cudaStream_t stream)
{
    thrust::device_ptr<numeric> dev_ptr = thrust::device_pointer_cast(x);
    thrust::inclusive_scan(thrust::cuda::par.on(stream), dev_ptr, dev_ptr+len, dev_ptr);
}


__global__
void mult_add_gpu(numeric *z, const numeric *a, const numeric *b, const numeric *c, int len)
{
    int tid = blockDim.x * blockIdx.x + threadIdx.x;
    if(tid < len)
    {
        z[tid] = a[tid] * b[tid] - c[tid];
    }

}


// Set z = a*b - c
void mult_add(numeric *z, const numeric *a, const numeric *b, const numeric *c, int len,cudaStream_t stream)
{
    constexpr int num_thread = 128;
    int num_block = (len + num_thread - 1)/num_thread;
    mult_add_gpu<<<num_block, num_thread, 0, stream>>>(z, a, b, c, len);
}


__global__
void coxval_gpu(const numeric *x, numeric *y, const numeric *z, numeric *val, int len)
{
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    if(i==0){
        val[0] = 0.0;
    }

    if(i < len)
    {
        y[i] = (log(x[i]) - y[i]) * z[i];
    }
    __shared__ numeric sdata[128];
    sdata[threadIdx.x] = (i<len)?y[i]:0.0;

    __syncthreads();
    // do reduction in shared mem
    for (int s=1; s < blockDim.x; s *=2)
    {
        int index = 2 * s * threadIdx.x;;

        if (index < blockDim.x)
        {
            sdata[index] += sdata[index + s];
        }
        __syncthreads();
    }

    // write result for this block to global mem
    if (threadIdx.x == 0){
        atomicAdd(val,sdata[0]);
    }
}




// compute sum((log(x) - y) *z), x will be modified, result saved in val
void get_coxvalue(const numeric *x, numeric *y, const  numeric *z, numeric *val, int len, cudaStream_t stream)
{
    constexpr int num_thread = 128;
    int num_block = (len + num_thread - 1)/num_thread;
    coxval_gpu<<<num_block, num_thread, 0, stream>>>(x, y, z, val, len);
}

__global__
void update_parameters_gpu(numeric *B, const numeric *v, const numeric *g, const numeric *penalty_factor,
                           int K, int p,numeric step_size, numeric lambda_1, numeric lambda_2)
{
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    if (i < p)
    {
        numeric ba;
        numeric lambdap1 = lambda_1*penalty_factor[i]*step_size;
        numeric lambdap2 = lambda_2*penalty_factor[i]*step_size;
        numeric norm = 0.0;
        for (int k = 0; k <K; ++k)
        {
            int ind = i+k*p;
            // gradient  descent
            B[ind] = v[ind] - step_size*g[ind];
            //soft-thresholding
            ba = fabs(B[ind]);
            B[ind] = signbit(lambdap1-ba)*copysign(ba-lambdap1, B[ind]);

            norm += B[ind]*B[ind];
        }
        // Group soft-thresholding
        norm = fmax(sqrt(norm), lambdap2);
        for(int k = 0; k <K; ++k)
        {
            int ind = i+k*p;
            B[ind] *= ((norm - lambdap2)/norm);
        }

    }

}


void update_parameters(cox_param &dev_param,
    int K,
    int p,
    numeric step_size,
    numeric lambda_1,
    numeric lambda_2)
{
    constexpr int num_thread = 128;
    int num_block = (p + num_thread - 1)/num_thread;
    update_parameters_gpu<<<num_block, num_thread>>>(dev_param.B, dev_param.v, dev_param.grad, dev_param.penalty_factor,
                                                     K, p,step_size, lambda_1,lambda_2);

}


__global__
void ls_stop_v1_gpu(const numeric *B, const numeric *v, const numeric *g, numeric *result, int K, int p, numeric step_size)
{
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    if(i==0){
        result[0] = 0.0;
    }

    numeric local = 0.0;
    if(i < K*p)
    {
        numeric diff = B[i] - v[i];
        local = g[i]*diff + diff*diff/(2*step_size);
    }
    __shared__ numeric sdata[256];
    sdata[threadIdx.x] = local;

    __syncthreads();
    // do reduction in shared mem
    for (int s=1; s < blockDim.x; s *=2)
    {
        int index = 2 * s * threadIdx.x;;

        if (index < blockDim.x)
        {
            sdata[index] += sdata[index + s];
        }
        __syncthreads();
    }

    // write result for this block to global mem
    if (threadIdx.x == 0){
        atomicAdd(result, sdata[0]);
    }
}



numeric ls_stop_v1(cox_param &dev_param, numeric step_size, int K, int p)
{
    constexpr int num_thread = 256;
    int num_block = (K*p + num_thread - 1)/num_thread;
    ls_stop_v1_gpu<<<num_block, num_thread>>>(dev_param.B, dev_param.v, dev_param.grad, dev_param.ls_result, K, p, step_size);
    numeric result[1];
    cudaMemcpy(result, dev_param.ls_result, sizeof(numeric)*1, cudaMemcpyDeviceToHost);
    return result[0];
}


__global__
void ls_stop_v2_gpu(const numeric *B, const numeric *v, const numeric *g, const numeric *g_ls,
                    numeric *result, int K, int p, numeric step_size)
{
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    if(i<2){
        result[i] = 0.0;
    }

    numeric local = 0.0;
    numeric diff = 0.0;
    if(i < K*p)
    {
        diff = B[i] - v[i];
        local = diff*diff;
    }
    __shared__ numeric sdata[256];
    sdata[threadIdx.x] = local;

    __syncthreads();
    // do reduction in shared mem
    for (int s=1; s < blockDim.x; s *=2)
    {
        int index = 2 * s * threadIdx.x;;
        if (index < blockDim.x)
        {
            sdata[index] += sdata[index + s];
        }
        __syncthreads();
    }
    // write result for this block to global mem
    if (threadIdx.x == 0){
        atomicAdd(result, sdata[0]);
    }
    // second term
    if(i < K*p)
    {
        local = diff*(g_ls[i]-g[i]);
    }

    sdata[threadIdx.x] = local;

    __syncthreads();
    // do reduction in shared mem
    for (int s=1; s < blockDim.x; s *=2)
    {
        int index = 2 * s * threadIdx.x;;
        if (index < blockDim.x)
        {
            sdata[index] += sdata[index + s];
        }
        __syncthreads();
    }
    // write result for this block to global mem
    if (threadIdx.x == 0){
        atomicAdd(result+1, sdata[0]);
    }
}





numeric ls_stop_v2(cox_param &dev_param, numeric step_size, int K, int p)
{
    constexpr int num_thread = 256;
    int num_block = (K*p + num_thread - 1)/num_thread;
    ls_stop_v2_gpu<<<num_block, num_thread>>>(dev_param.B, dev_param.v, dev_param.grad, dev_param.grad_ls,
                                                dev_param.ls_result, K, p, step_size);
    numeric result[2];
    cudaMemcpy(result, dev_param.ls_result, sizeof(numeric)*2, cudaMemcpyDeviceToHost);

    return (result[0]/(2*step_size) - abs(result[1]));
}


void nesterov_update(cox_param &dev_param, int K, int p, numeric weight_old, numeric weight_new, cudaStream_t stream, cublasHandle_t handle)
{
    numeric alpha =  (weight_old - 1)/weight_new + 1;
    numeric beta = (1 - weight_old)/weight_new;
    cublasSetStream(handle, stream);
    cublasDgeam(handle, CUBLAS_OP_N, CUBLAS_OP_N, p, K, &alpha, dev_param.B, p , &beta, dev_param.prev_B, p, dev_param.v, p);
}


__global__
void max_diff_gpu(numeric *A, numeric *B, numeric *result, int len)
{
    int i = blockIdx.x*blockDim.x + threadIdx.x;
    if (i == 0)
    {
        result[0] = 0.0;
    }
    numeric local = 0;
    if(i < len)
    {
        local = fabs(A[i] - B[i]);
    }

    __shared__ numeric sdata[256];
    sdata[threadIdx.x] = local;

    __syncthreads();
    // do reduction in shared mem
    for (int s=1; s < blockDim.x; s *=2)
    {
        int index = 2 * s * threadIdx.x;;

        if (index < blockDim.x)
        {
            sdata[index] = fmax(sdata[index + s], sdata[index]);
        }
        __syncthreads();
    }

    // write result for this block to global mem
    if (threadIdx.x == 0){
        atomicMax(result, sdata[0]);
    }


}

numeric max_diff(cox_param &dev_param, int K, int p)
{
    constexpr int num_thread = 256;
    int num_block = (K*p + num_thread - 1)/num_thread;
    max_diff_gpu<<<num_block, num_thread>>>(dev_param.B, dev_param.prev_B, dev_param.change, K*p);
    numeric result[1];
    cudaMemcpy(result, dev_param.change, sizeof(numeric)*1, cudaMemcpyDeviceToHost);
    return result[0];
}

void cublas_copy(cox_param &dev_param, int len, cudaStream_t stream, cublasHandle_t handle)
{
    cublasSetStream(handle, stream);
    cublasDcopy(handle, len,dev_param.B, 1,dev_param.prev_B, 1);
}

