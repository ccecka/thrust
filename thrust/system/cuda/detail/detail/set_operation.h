/*
 *  Copyright 2008-2013 NVIDIA Corporation
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

#pragma once

#include <thrust/detail/config.h>
#include <thrust/system/cuda/detail/execution_policy.h>

namespace thrust
{
namespace system
{
namespace cuda
{
namespace detail
{
namespace detail
{

template<typename DerivedPolicy,
         typename RandomAccessIterator1,
         typename RandomAccessIterator2,
         typename RandomAccessIterator3,
         typename Compare,
         typename SetOperation>
__host__ __device__
RandomAccessIterator3 set_operation(execution_policy<DerivedPolicy> &exec,
                                    RandomAccessIterator1 first1,
                                    RandomAccessIterator1 last1,
                                    RandomAccessIterator2 first2,
                                    RandomAccessIterator2 last2,
                                    RandomAccessIterator3 result,
                                    Compare comp,
                                    SetOperation set_op);


} // end detail
} // end detail
} // end cuda
} // end system
} // end thrust

#include <thrust/system/cuda/detail/detail/set_operation.inl>
