/*
 * Copyright (c) 2019-2023, NVIDIA CORPORATION.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <cuda_runtime.h>
#include <curand_kernel.h>
#include <stdint.h>

namespace turbomind {

struct SamplingParams {
    void*          logits;
    int            stride;
    int*           indices;
    int*           kept;
    curandState_t* curandstate;
    size_t         batch_size;
    bool*          finished;
    int*           end_ids;
    int*           output_ids;
    int*           sequence_length;
    float*         sampled_logprobs = nullptr;
    uint32_t*      sampled_indexes  = nullptr;
    uint32_t*      sampled_nums     = nullptr;
};

template<typename T>
void invokeSampling(SamplingParams& params, cudaStream_t stream);

}  // namespace turbomind
