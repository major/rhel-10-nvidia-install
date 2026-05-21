// Minimal CUDA smoke test: GPU vector addition with host-side verification.
// Prints "PASS" on success, "FAIL" otherwise. Exit code mirrors that.

#include <cstdio>
#include <cstdlib>
#include <cuda_runtime.h>

#define N (1 << 20)  // 1,048,576 elements

__global__ void vector_add(const float *a, const float *b, float *c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) {
        c[i] = a[i] + b[i];
    }
}

static void check(cudaError_t e, const char *what) {
    if (e != cudaSuccess) {
        fprintf(stderr, "CUDA error (%s): %s\n", what, cudaGetErrorString(e));
        exit(2);
    }
}

int main(void) {
    size_t bytes = (size_t)N * sizeof(float);

    float *h_a = (float *)malloc(bytes);
    float *h_b = (float *)malloc(bytes);
    float *h_c = (float *)malloc(bytes);
    if (!h_a || !h_b || !h_c) {
        fprintf(stderr, "host malloc failed\n");
        return 2;
    }

    for (int i = 0; i < N; i++) {
        h_a[i] = (float)i;
        h_b[i] = 2.0f * (float)i;
    }

    float *d_a = NULL, *d_b = NULL, *d_c = NULL;
    check(cudaMalloc(&d_a, bytes), "cudaMalloc d_a");
    check(cudaMalloc(&d_b, bytes), "cudaMalloc d_b");
    check(cudaMalloc(&d_c, bytes), "cudaMalloc d_c");

    check(cudaMemcpy(d_a, h_a, bytes, cudaMemcpyHostToDevice), "memcpy H2D a");
    check(cudaMemcpy(d_b, h_b, bytes, cudaMemcpyHostToDevice), "memcpy H2D b");

    int threads = 256;
    int blocks = (N + threads - 1) / threads;
    vector_add<<<blocks, threads>>>(d_a, d_b, d_c, N);
    check(cudaGetLastError(), "kernel launch");
    check(cudaDeviceSynchronize(), "device sync");

    check(cudaMemcpy(h_c, d_c, bytes, cudaMemcpyDeviceToHost), "memcpy D2H c");

    int errors = 0;
    for (int i = 0; i < N; i++) {
        float expected = h_a[i] + h_b[i];
        if (h_c[i] != expected) {
            if (errors < 5) {
                fprintf(stderr, "mismatch at %d: %f != %f\n",
                        i, h_c[i], expected);
            }
            errors++;
        }
    }

    cudaFree(d_a);
    cudaFree(d_b);
    cudaFree(d_c);
    free(h_a);
    free(h_b);
    free(h_c);

    if (errors == 0) {
        printf("PASS: %d elements added on GPU\n", N);
        return 0;
    }
    printf("FAIL: %d mismatches\n", errors);
    return 1;
}
