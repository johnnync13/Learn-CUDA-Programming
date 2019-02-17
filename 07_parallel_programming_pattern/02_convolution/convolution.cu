#include <cuda.h>
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <algorithm>
#include <helper_timer.h>
#include "helper_cuda.h"
#include <assert.h>

#define BLOCK_DIM   16
#define MAX_FILTER_LENGTH 128

__global__ void
convolution_kernel_v1(float *d_output, float *d_input, float *d_filter, int num_row, int num_col, int filter_size)
{
    int idx_x = blockDim.x * blockIdx.x + threadIdx.x;
    int idx_y = blockDim.y * blockIdx.y + threadIdx.y;

    float result = 0.f;
    //For every value in the filter around the pixel (c, r)
    for (int filter_row = -filter_size / 2; filter_row <= filter_size / 2; ++filter_row)
    {
        for (int filter_col = -filter_size / 2; filter_col <= filter_size / 2; ++filter_col)
        {
            //Find the global image position for this filter position
            //clamp to boundary of the image
            int image_row = min(max(idx_y + filter_row, 0), static_cast<int>(num_row - 1));
            int image_col = min(max(idx_x + filter_col, 0), static_cast<int>(num_col - 1));

            float image_value = static_cast<float>(d_input[image_row * num_col + image_col]);
            float filter_value = d_filter[(filter_row + filter_size / 2) * filter_size + filter_col + filter_size / 2];

            result += image_value * filter_value;
        }
    }

    d_output[idx_y * num_col + idx_x] = result;
}

__global__ void
convolution_kernel_v2(float *d_output, float *d_input, float *d_filter, int num_row, int num_col, int filter_size)
{
    int idx_x = blockDim.x * blockIdx.x + threadIdx.x;
    int idx_y = blockDim.y * blockIdx.y + threadIdx.y;

    __shared__ float s_filter[BLOCK_DIM][BLOCK_DIM];
    __shared__ float s_input[BLOCK_DIM*3][BLOCK_DIM*3];

    // this kernel assumes filter_size is smaller than BLOCK_DIM
    assert(filter_size < BLOCK_DIM);

    // copy filter data to shared memory
    if (threadIdx.y * filter_size + threadIdx.x < filter_size * filter_size)
        s_filter[threadIdx.y][threadIdx.x] = d_filter[threadIdx.y * filter_size + threadIdx.x];

    for (int row = -1; row <= 1; row++) {
        for (int col = -1; col <= 1; col++) {
            //Find the global image position for this filter position
            //clamp to boundary of the image
            int image_row = min(max(idx_y + row * blockDim.y, 0), static_cast<int>(num_row - 1));
            int image_col = min(max(idx_x + col * blockDim.x, 0), static_cast<int>(num_col - 1));

            s_input[threadIdx.y + (row + 1) * BLOCK_DIM][threadIdx.x + (col + 1) * BLOCK_DIM] = \
                static_cast<float>(d_input[image_row * num_col + image_col]);
        }
    }

    __syncthreads();

    float result = 0.f;
    //For every value in the filter around the pixel (c, r)
    for (int filter_row = -filter_size / 2; filter_row <= filter_size / 2; ++filter_row)
    {
        for (int filter_col = -filter_size / 2; filter_col <= filter_size / 2; ++filter_col)
        {
            int image_row = threadIdx.y + BLOCK_DIM + filter_row;
            int image_col = threadIdx.x + BLOCK_DIM + filter_col;

            float image_value = static_cast<float>(s_input[image_row][image_col]);
            float filter_value = s_filter[filter_row + filter_size / 2][filter_col + filter_size / 2];

            result += image_value * filter_value;
        }
    }

    d_output[idx_y * num_col + idx_x] = result;
}

void convolution_gpu(float *d_output, float *d_input, float *d_filter, int num_row, int num_col, int filter_size)
{
    dim3 dimBlock(BLOCK_DIM, BLOCK_DIM);
    dim3 dimGrid((num_col + BLOCK_DIM - 1) / BLOCK_DIM, (num_row + BLOCK_DIM - 1) / BLOCK_DIM);
    convolution_kernel_v2<<<dimGrid, dimBlock>>>(d_output, d_input, d_filter, num_row, num_col, filter_size);
    checkCudaErrors(cudaGetLastError());
}

void convolution_host(float *h_output, float *h_input, float *h_filter, int num_row, int num_col, int filter_size)
{
    //For every pixel in the image
    #pragma omp parallel 
    for (int row = 0; row < (int)num_row; ++row)
    {
        for (int col = 0; col < (int)num_col; ++col)
        {
            float result = 0.f;
            //For every value in the filter around the pixel (c, r)
            for (int filter_row = -filter_size / 2; filter_row <= filter_size / 2; ++filter_row)
            {
                for (int filter_col = -filter_size / 2; filter_col <= filter_size / 2; ++filter_col)
                {
                    //Find the global image position for this filter position
                    //clamp to boundary of the image
                    int image_row = std::min(std::max(row + filter_row, 0), static_cast<int>(num_row - 1));
                    int image_col = std::min(std::max(col + filter_col, 0), static_cast<int>(num_col - 1));

                    float image_value = static_cast<float>(h_input[image_row * num_col + image_col]);
                    float filter_value = h_filter[(filter_row + filter_size / 2) * filter_size + filter_col + filter_size / 2];

                    result += image_value * filter_value;
                }
            }

            h_output[row * num_col + col] = result;
        }
    }
}


/* Generates Bi-symetric Gaussian Filter */
void generate_filter(float *h_filter, int filter_size)
{
    float blur_kernel_sigma = 2.;

    float sum_filter = 0.f; //for normalization
    for (int row = -filter_size / 2; row <= filter_size / 2; row++)
    {
        for (int col = -filter_size / 2; col <= filter_size / 2; col++)
        {
            float filterValue = expf(-(float)(col * col + row * row) / (2.f * blur_kernel_sigma * blur_kernel_sigma));
            h_filter[(row + filter_size / 2) * filter_size + col + filter_size / 2] = filterValue;
            sum_filter += filterValue;
        }
    }

    // normalization
    float normalizationFactor = 1.f / sum_filter;
    for (int row = -filter_size / 2; row <= filter_size / 2; row++)
        for (int col = -filter_size / 2; col <= filter_size / 2; col++)
            h_filter[(row + filter_size / 2) * filter_size + col + filter_size / 2] *= normalizationFactor;
}

void generate_data(float *h_buffer, int num_row, int num_col)
{
    for (int row = 0; row < num_row; row++) {
        for (int col = 0; col < num_col; col++) {
            h_buffer[row * num_col + col] = float(rand() & 0xFFF) / RAND_MAX;
        }
    }
}

bool value_test(float *a, float *b, int length)
{
    float epsilon = 0.000001;
    bool result = true;
    for (int i = 0; i < length; i++)
        if (abs(a[i] - b[i]) >= epsilon)
            result = false;
    return result;
}

int main()
{
    int num_row = 2048;
    int num_col = 2048;
    int filter_size = 15;
    int buf_size = num_row * num_col * sizeof(float);

    float *h_input, *d_input;
    float *h_output_host, *h_output_gpu, *d_output;
    float *h_filter, *d_filter;

    float elapsed_time_host, elapsed_time_gpu;

    // initialize timer
    StopWatchInterface *timer_host, *timer_gpu;
    sdkCreateTimer(&timer_host);
    sdkCreateTimer(&timer_gpu);

    srand(2019);

    // allocate host memories
    h_input = (float *)malloc(buf_size);
    h_output_host = (float *)malloc(buf_size);
    h_output_gpu = (float *)malloc(buf_size);
    h_filter = (float *)malloc(filter_size * filter_size * sizeof(float));

    // allocate gpu memories
    cudaMalloc((void **)&d_input, buf_size);
    cudaMalloc((void **)&d_output, buf_size);
    cudaMalloc((void **)&d_filter, filter_size * filter_size * sizeof(float));

    // generate data
    generate_data(h_input, num_row, num_col);
    generate_filter(h_filter, filter_size);

    // processing in CPU
    sdkStartTimer(&timer_host);
    //convolution_host(h_output_host, h_input, h_filter, num_row, num_col, filter_size);
    sdkStopTimer(&timer_host);

    // copy input date to gpu
    cudaMemcpy(d_input, h_input, buf_size, cudaMemcpyHostToDevice);
    cudaMemcpy(d_filter, h_filter, filter_size * filter_size * sizeof(float), cudaMemcpyHostToDevice);

    // processing in GPU
    sdkStartTimer(&timer_gpu);
    convolution_gpu(d_output, d_input, d_filter, num_row, num_col, filter_size);
    cudaDeviceSynchronize();
    sdkStopTimer(&timer_gpu);

    // report elapsed time (host, gpu)
    elapsed_time_host = sdkGetTimerValue(&timer_host);
    elapsed_time_gpu = sdkGetTimerValue(&timer_gpu);
    printf("Processing Time -> Host: %.2f ms, GPU: %.2f ms\n", elapsed_time_host, elapsed_time_gpu);

    // compare the result
    cudaMemcpy(h_output_gpu, d_output, buf_size, cudaMemcpyDeviceToHost);
    if (value_test(h_output_host, h_output_gpu, num_row * num_col))
        printf("SUCCESS!!\n");
    else
        printf("Error\n");

    // finalize
    free(h_input);
    free(h_output_host);
    free(h_output_gpu);
    free(h_filter);

    return 0;
}

