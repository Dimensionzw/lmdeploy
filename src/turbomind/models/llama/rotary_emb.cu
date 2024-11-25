// Copyright (c) OpenMMLab. All rights reserved.
#include "src/turbomind/models/llama/rotary_emb.h"
#include <map>

namespace turbomind {

__device__ int get_batch_id(int qi, int* q_len, int batch_size)
{
    int result{};
    int end = (batch_size + blockDim.x - 1) / blockDim.x * blockDim.x;
    for (int i = threadIdx.x; i < end; i += blockDim.x) {
        int  prefix_sum = (i < batch_size) ? q_len[i + 1] : q_len[batch_size];
        auto count      = __syncthreads_count(prefix_sum > qi);
        if (count != 0) {
            result = i / blockDim.x * blockDim.x + blockDim.x - count + 1;
            break;
        }
    }
    return result;
}

__inline__ __device__ float compute_default_parameters(float base, float dim, int di, float factor)
{
    float scale_factor = -log2f(base) / dim;
    float inv_freq     = exp2f(di * scale_factor) * factor;
    return inv_freq;
}

__global__ void computeCosSinDefault(const float* rope_base,
                                     int*         q_len,
                                     int*         k_len,
                                     int          token_num,
                                     int          batch_size,
                                     int          dim,
                                     float        factor,
                                     float*       cos_sin)
{
    int qi = blockIdx.x;
    int di = threadIdx.x;

    int   bid         = get_batch_id(qi, q_len, batch_size);
    int   history_len = (k_len[bid] - k_len[bid - 1]) - (q_len[bid] - q_len[bid - 1]);
    float base        = rope_base[bid - 1];
    float ti          = history_len + qi - q_len[bid - 1];

    float inv_freq = compute_default_parameters(base, dim, di * 2, factor);
    float c, s;
    sincosf(ti * inv_freq, &s, &c);
    (float2&)cos_sin[dim * qi + 2 * di] = {c, s};
}

__global__ void computeCosSinLlama3(const float* rope_base,
                                    int*         q_len,
                                    int*         k_len,
                                    int          token_num,
                                    int          batch_size,
                                    int          dim,
                                    float        llama3_inv_scaling_factor,
                                    float        llama3_alpha,
                                    float        llama3_beta,
                                    float*       cos_sin)
{
    int qi = blockIdx.x;
    int di = threadIdx.x;

    int   bid         = get_batch_id(qi, q_len, batch_size);
    int   history_len = (k_len[bid] - k_len[bid - 1]) - (q_len[bid] - q_len[bid - 1]);
    float base        = rope_base[bid - 1];
    float ti          = history_len + qi - q_len[bid - 1];

    float inv_freq = compute_default_parameters(base, dim, di * 2, 1.0f);
    auto  smooth   = fmaxf(0.f, fminf(1.f, llama3_alpha * inv_freq - llama3_beta));
    inv_freq       = (1 - smooth) * inv_freq * llama3_inv_scaling_factor + smooth * inv_freq;
    float c, s;
    sincosf(ti * inv_freq, &s, &c);
    (float2&)cos_sin[dim * qi + 2 * di] = {c, s};
}

__global__ void computeCosSinYarn(const float* rope_base,
                                  int*         q_len,
                                  int*         k_len,
                                  int          token_num,
                                  int          batch_size,
                                  int          dim,
                                  float        yarn_ramp_inv_factor_div_2,
                                  float        yarn_ramp_inv_factor_mul_min,
                                  float        yarn_inv_scaling_factor,
                                  float        attention_scaling,
                                  float*       cos_sin)
{
    int qi = blockIdx.x;
    int di = threadIdx.x;

    int   bid         = get_batch_id(qi, q_len, batch_size);
    int   history_len = (k_len[bid] - k_len[bid - 1]) - (q_len[bid] - q_len[bid - 1]);
    float base        = rope_base[bid - 1];
    float ti          = history_len + qi - q_len[bid - 1];

    float inv_freq = compute_default_parameters(base, dim, di * 2, 1.0f);
    float alpha    = 2 * di * yarn_ramp_inv_factor_div_2 - yarn_ramp_inv_factor_mul_min;
    alpha          = fmaxf(0.f, fminf(1.f, alpha));
    inv_freq       = inv_freq - inv_freq * alpha * yarn_inv_scaling_factor;

    float c, s;
    sincosf(ti * inv_freq, &s, &c);
    c *= attention_scaling;
    s *= attention_scaling;
    (float2&)cos_sin[dim * qi + 2 * di] = {c, s};
}

RotaryScalingType GetRoPEType(const std::string& type)
{
    std::map<std::string, RotaryScalingType> lookup = {{"", RotaryScalingType::kDefault},
                                                       {"linear", RotaryScalingType::kLinear},
                                                       {"dynamic", RotaryScalingType::kDynamic},
                                                       {"yarn", RotaryScalingType::kYarn},
                                                       {"llama3", RotaryScalingType::kLlama3},
                                                       {"mrope", RotaryScalingType::kMrope}};
    return lookup.at(type);
}

void RotaryEmbeddingV2::freeBuffer()
{
    allocator_->free((void**)&cos_sin_);
}

void RotaryEmbeddingV2::allocateBuffer(size_t token_num)
{
    cos_sin_ = (float*)allocator_->reMalloc(cos_sin_, sizeof(float) * token_num * dim_);
}

RotaryEmbeddingV2::RotaryEmbeddingV2(const AttentionParam& param, cudaStream_t stream, IAllocator* allocator):
    stream_(stream), allocator_(allocator)
{
    type_                = GetRoPEType(param.rope_scaling_type);
    dim_                 = param.rotary_embedding_dim;
    rope_scaling_factor_ = 1.0f;
    attention_factor_    = 1.0f;

    if (type_ == RotaryScalingType::kLinear) {
        rope_scaling_factor_ /= param.rope_scaling_factor;
    }
    else if (type_ == RotaryScalingType::kLlama3) {
        const double PI                   = 3.14159265358979323846;
        float        inv_diff_freq_factor = 1.0 / (param.high_freq_factor - param.low_freq_factor);
        llama3_inv_scaling_factor_        = 1.0 / param.rope_scaling_factor;
        llama3_alpha_                     = param.original_max_position_embeddings / (2 * PI) * inv_diff_freq_factor;
        llama3_beta_                      = param.low_freq_factor * inv_diff_freq_factor;
    }
    else if (type_ == RotaryScalingType::kYarn) {
        const double PI                  = 3.14159265358979323846;
        auto         find_correction_dim = [&](float num_rotations) {
            return (param.rotary_embedding_dim * std::log(param.max_position_embeddings / (num_rotations * 2 * PI)))
                   / (2 * std::log(param.rotary_embedding_base));
        };
        auto find_correction_range = [&](float low_rot, float high_rot, float& low, float& high) {
            low  = std::floor(find_correction_dim(low_rot));
            high = std::ceil(find_correction_dim(high_rot));
            low  = std::max(low, 0.f);
            high = std::min(high, param.rotary_embedding_dim - 1.f);
        };
        float low, high;
        find_correction_range(param.beta_fast, param.beta_slow, low, high);
        if (low == high) {
            high += 0.01f;
        }
        yarn_ramp_inv_factor_div_2_   = 1.0 / (high - low) / 2.0;
        yarn_ramp_inv_factor_mul_min_ = 1.0 / (high - low) * low;
        yarn_inv_scaling_factor_      = (1 - 1.0 / param.rope_scaling_factor);
        attention_factor_             = param.attention_factor;
    }
}

void RotaryEmbeddingV2::forward(const RotaryEmbeddingV2Params& params)
{
    allocateBuffer(params.token_num);

    const int grid  = params.token_num;
    const int block = dim_ / 2;

    switch (type_) {
        case RotaryScalingType::kDefault:
        case RotaryScalingType::kLinear:
        case RotaryScalingType::kDynamic:
            computeCosSinDefault<<<grid, block, 0, stream_>>>(params.rope_theta,
                                                              params.q_len,
                                                              params.k_ken,
                                                              params.token_num,
                                                              params.batch_size,
                                                              dim_,
                                                              rope_scaling_factor_,
                                                              cos_sin_);
            break;
        case RotaryScalingType::kLlama3:
            computeCosSinLlama3<<<grid, block, 0, stream_>>>(params.rope_theta,
                                                             params.q_len,
                                                             params.k_ken,
                                                             params.token_num,
                                                             params.batch_size,
                                                             dim_,
                                                             llama3_inv_scaling_factor_,
                                                             llama3_alpha_,
                                                             llama3_beta_,
                                                             cos_sin_);
            break;
        case RotaryScalingType::kYarn:
            computeCosSinYarn<<<grid, block, 0, stream_>>>(params.rope_theta,
                                                           params.q_len,
                                                           params.k_ken,
                                                           params.token_num,
                                                           params.batch_size,
                                                           dim_,
                                                           yarn_ramp_inv_factor_div_2_,
                                                           yarn_ramp_inv_factor_mul_min_,
                                                           yarn_inv_scaling_factor_,
                                                           attention_factor_,
                                                           cos_sin_);
            break;
        case RotaryScalingType::kMrope:
            FT_CHECK(0);
        default:
            FT_CHECK(0);
    }
}

}  // namespace turbomind