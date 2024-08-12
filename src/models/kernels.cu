// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
#include <cuda_fp16.h>
#include <cuda_runtime.h>
#include <stdint.h>
#include <limits>

namespace Generators {
namespace cuda {

template <typename T>
__global__ void UpdatePositionIds(T* positions, int batch_beam_size) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < batch_beam_size)
    positions[i]++;
}

template <typename T>
void Launch_UpdatePositionIds(T* positions, int batch_beam_size, cudaStream_t stream) {
  UpdatePositionIds<T><<<(batch_beam_size + 255) / 256, 256, 0, stream>>>(positions, batch_beam_size);
}

template void Launch_UpdatePositionIds(int32_t* positions, int batch_beam_size, cudaStream_t stream);
template void Launch_UpdatePositionIds(int64_t* positions, int batch_beam_size, cudaStream_t stream);

template <typename T>
__global__ void CopyAndUpdateAttentionMask(T* mask_data, const T* old_mask_data, int batch_beam_size,
                                           int current_length, int max_length) {
  int global_index = blockIdx.x * blockDim.x + threadIdx.x;
  int i = global_index / current_length;
  int j = global_index % current_length;
  if (i < batch_beam_size) {
    if (j < current_length - 1) {
      mask_data[i * max_length + j] = old_mask_data[i * (current_length - 1) + j];
    } else {
      mask_data[i * max_length + j] = 1;
    }
  }
}

template <typename T>
__global__ void UpdateAttentionMask(T* mask_data, int batch_beam_size, int current_length, int max_length) {
  int i = blockIdx.x;
  if (i < batch_beam_size) {
    mask_data[i * max_length + current_length] = 1;
  }
}

template <typename T>
void Launch_UpdateAttentionMask(T* mask_data, const T* old_mask_data, int batch_beam_size, int current_length,
                                int max_length, bool update_only, cudaStream_t stream) {
  if (update_only) {
    UpdateAttentionMask<T>
        <<<batch_beam_size, 1, 0, stream>>>(mask_data, batch_beam_size, current_length, max_length);
  } else {
    CopyAndUpdateAttentionMask<T><<<(batch_beam_size * max_length + 255) / 256, 256, 0, stream>>>(
        mask_data, old_mask_data, batch_beam_size, current_length, max_length);
  }
}

template void Launch_UpdateAttentionMask(int32_t* mask_data, const int32_t* old_mask_data, int batch_beam_size,
                                         int current_length, int max_length, bool update_only, cudaStream_t stream);
template void Launch_UpdateAttentionMask(int64_t* mask_data, const int64_t* old_mask_data, int batch_beam_size,
                                         int current_length, int max_length, bool update_only, cudaStream_t stream);

// Support head_size up to 128
constexpr unsigned int kTileSize = 32;
constexpr unsigned int kSeqTileSize = 16;

__global__ void ReorderPastStatesKernel(float4* out_buffer,
                                        const float4* in_buffer,
                                        int batch_size,
                                        int num_heads,
                                        int max_length,
                                        int chunked_head_size) {
  __shared__ float4 tile[kSeqTileSize][kTileSize + 1];

  const int b = blockIdx.z;
  const int n = blockIdx.y;
  const int s_base = blockIdx.x * kSeqTileSize;
  const int s = s_base + threadIdx.y;
  const int base_offset = (b * num_heads + n) * max_length * chunked_head_size;

  if (s < max_length) {
    const int in_offset = base_offset + s * chunked_head_size + threadIdx.x;
    tile[threadIdx.y][threadIdx.x] = in_buffer[in_offset];
  }

  __syncthreads();

  const int tidx = threadIdx.x + threadIdx.y * chunked_head_size;
  const int tidx_x = tidx % kSeqTileSize;
  const int tidx_y = tidx / kSeqTileSize;

  const int s2 = s_base + tidx_x;

  if (s2 < max_length) {
    const int out_offset = base_offset + tidx_y * max_length + s2;
    out_buffer[out_offset] = tile[tidx_x][tidx_y];
  }
}

void ReorderPastStatesKernelLauncher(void* out_buffer,
                                     const void* in_buffer,
                                     int batch_size,
                                     int num_heads,
                                     int max_length,
                                     int head_size,
                                     int chunk_size,
                                     cudaStream_t stream) {
  // [B, N, max_length, H2(head_size/chunk_size), equv_chunk_size] -> [B, N, H2(head_size/chunk_size), max_length, equv_chunk_size]
  const int chunked_head_size = head_size / chunk_size;
  const dim3 block(chunked_head_size, kSeqTileSize);
  const dim3 grid((max_length + kSeqTileSize - 1) / kSeqTileSize, num_heads, batch_size);
  if (chunk_size == 4 || chunk_size == 8) {
    ReorderPastStatesKernel<<<grid, block, 0, stream>>>(reinterpret_cast<float4*>(out_buffer),
                                                        reinterpret_cast<const float4*>(in_buffer),
                                                        batch_size,
                                                        num_heads,
                                                        max_length,
                                                        chunked_head_size);
  }
}

__global__ void HandleEOSArray(float* batch_logits, int batch_beam_size, int vocab_size, const int32_t* eos_token_ids, int eos_token_ids_count) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= batch_beam_size)
    return;

  float* logits = batch_logits + index * vocab_size;
  float max = std::numeric_limits<float>::lowest();
  for (int i = 0; i < eos_token_ids_count; i++) {
    max = std::max(max, logits[eos_token_ids[i]]);
    logits[eos_token_ids[i]] = std::numeric_limits<float>::lowest();  // Set all EOS token options to never happen (the first will get the max of all)
  }

  logits[eos_token_ids[0]] = max;  // Set the score of the primary EOS token to the highest of any of the EOS tokens
}

void LaunchHandleEOSArray(float* batch_logits, int batch_beam_size, int vocab_size, const int32_t* eos_token_ids, int eos_token_ids_count, cudaStream_t stream) {
  HandleEOSArray<<<(batch_beam_size + 255) / 256, 256, 0, stream>>>(batch_logits, batch_beam_size, vocab_size, eos_token_ids, eos_token_ids_count);
}

__global__ void ConvertFp16ToFp32(const half* src, float* dst, int count) {
  int idx = threadIdx.x + blockIdx.x * blockDim.x;
  if (idx < count)
    dst[idx] = __half2float(src[idx]);
}

void LaunchFp16ToFp32(const uint16_t* fp16, float* fp32, int count, cudaStream_t stream) {
  int block_size = 256;
  int num_blocks = (count + block_size - 1) / block_size;
  ConvertFp16ToFp32<<<num_blocks, block_size, 0, stream>>>(reinterpret_cast<const half*>(fp16), fp32, count);
}

__global__ void ConvertFp32ToFp16(const float* src, half* dst, int count) {
  int idx = threadIdx.x + blockIdx.x * blockDim.x;
  if (idx < count)
    dst[idx] = __float2half(src[idx]);
}

void LaunchFp32ToFp16(const float* fp32, uint16_t* fp16, int count, cudaStream_t stream) {
  int block_size = 256;
  int num_blocks = (count + block_size - 1) / block_size;
  ConvertFp32ToFp16<<<num_blocks, block_size, 0, stream>>>(fp32, reinterpret_cast<half*>(fp16), count);
}

__global__ void ConvertInt32ToInt64(const int32_t* src, int64_t* dst, int count) {
  int idx = threadIdx.x + blockIdx.x * blockDim.x;
  if (idx < count) {
    dst[idx] = src[idx];
  }
}

void LaunchInt32ToInt64(const int32_t* src, int64_t* dst, int count, cudaStream_t stream) {
  int block_size = 256;
  int num_blocks = (count + block_size - 1) / block_size;
  ConvertInt32ToInt64<<<num_blocks, block_size, 0, stream>>>(src, dst, count);
}

__global__ void UpdateDecoderMaskedMultiHeadAttentionCacheIndirectionKernel(int32_t* tgt_indir_cache,
                                                                            const int32_t* src_indir_cache,
                                                                            const int32_t* beam_ids,
                                                                            int batch_size,
                                                                            int beam_width,
                                                                            int input_seq_length,
                                                                            int max_seq_length,
                                                                            int current_length) {
  int time_step = threadIdx.x + blockIdx.x * blockDim.x;
  int bb_id = threadIdx.y + blockIdx.y * blockDim.y;
  const int batch_id = bb_id / beam_width;
  const int beam_id = bb_id % beam_width;

  if (bb_id >= beam_width * batch_size || time_step >= current_length) {
    return;
  }

  const int src_beam = beam_ids[batch_id * beam_width + beam_id] % beam_width;

  const int tgt_offset = batch_id * beam_width * max_seq_length + beam_id * max_seq_length + time_step;

  if (time_step < input_seq_length) {
    // For time steps that correspond to the input sequence,
    // the beam that it comes from is always 0.
    tgt_indir_cache[tgt_offset] = static_cast<int32_t>(0);
  } else if (time_step == (current_length - 1)) {
    // For the final (newly generated) time step,
    // the beam that it comes from is always the beam that we
    // are currently processing (i.e.) from this point on, these time-steps
    // form the new beams.
    tgt_indir_cache[tgt_offset] = static_cast<int32_t>(beam_id);
  } else {
    // For all other time-steps, we look up the source indirection, to
    // see which beam it came from based on the `src_beam`.
    const int src_offset = batch_id * beam_width * max_seq_length + src_beam * max_seq_length + time_step;
    tgt_indir_cache[tgt_offset] = src_indir_cache[src_offset];
  }
}

void UpdateDecoderMaskedMultiHeadAttentionCacheIndirection(int32_t* tgt_indir_cache,
                                                           const int32_t* src_indir_cache,
                                                           const int32_t* beam_ids,
                                                           int batch_size,
                                                           int beam_width,
                                                           int input_seq_length,
                                                           int max_seq_length,
                                                           int current_length,
                                                           cudaStream_t stream) {
  const dim3 block(32);
  const dim3 grid((current_length + block.x - 1) / block.x, batch_size * beam_width);
  UpdateDecoderMaskedMultiHeadAttentionCacheIndirectionKernel<<<grid, block, 0, stream>>>(tgt_indir_cache,
                                                                                          src_indir_cache,
                                                                                          beam_ids,
                                                                                          batch_size,
                                                                                          beam_width,
                                                                                          input_seq_length,
                                                                                          max_seq_length,
                                                                                          current_length);
}

}  // namespace cuda
}  // namespace Generators
