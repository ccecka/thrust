/******************************************************************************
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2014, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/**
 * \file
 * cub::BlockRleSweep implements a stateful abstraction of CUDA thread blocks for participating in device-wide run-length-encode.
 */

#pragma once

#include <iterator>

#include "block_scan_prefix_operators.cuh"
#include "../block/block_load.cuh"
#include "../block/block_store.cuh"
#include "../block/block_scan.cuh"
#include "../block/block_exchange.cuh"
#include "../block/block_discontinuity.cuh"
#include "../grid/grid_queue.cuh"
#include "../iterator/cache_modified_input_iterator.cuh"
#include "../iterator/constant_input_iterator.cuh"
#include "../util_namespace.cuh"

/// Optional outer namespace(s)
CUB_NS_PREFIX

/// CUB namespace
namespace cub {


/******************************************************************************
 * Tuning policy types
 ******************************************************************************/

/**
 * Parameterizable tuning policy type for BlockRleSweep
 */
template <
    int                         _BLOCK_THREADS,                 ///< Threads per thread block
    int                         _ITEMS_PER_THREAD,              ///< Items per thread (per tile of input)
    BlockLoadAlgorithm          _LOAD_ALGORITHM,                ///< The BlockLoad algorithm to use
    CacheLoadModifier           _LOAD_MODIFIER,                 ///< Cache load modifier for reading input elements
    bool                        _STORE_WARP_TIME_SLICING,       ///< Whether or not only one warp's worth of shared memory should be allocated and time-sliced among block-warps during any store-related data transpositions (versus each warp having its own storage)
    BlockScanAlgorithm          _SCAN_ALGORITHM>                ///< The BlockScan algorithm to use
struct BlockRleSweepPolicy
{
    enum
    {
        BLOCK_THREADS           = _BLOCK_THREADS,               ///< Threads per thread block
        ITEMS_PER_THREAD        = _ITEMS_PER_THREAD,            ///< Items per thread (per tile of input)
        STORE_WARP_TIME_SLICING = _STORE_WARP_TIME_SLICING,     ///< Whether or not only one warp's worth of shared memory should be allocated and time-sliced among block-warps during any store-related data transpositions (versus each warp having its own storage)
    };

    static const BlockLoadAlgorithm     LOAD_ALGORITHM          = _LOAD_ALGORITHM;      ///< The BlockLoad algorithm to use
    static const CacheLoadModifier      LOAD_MODIFIER           = _LOAD_MODIFIER;       ///< Cache load modifier for reading input elements
    static const BlockScanAlgorithm     SCAN_ALGORITHM          = _SCAN_ALGORITHM;      ///< The BlockScan algorithm to use
};





/******************************************************************************
 * Thread block abstractions
 ******************************************************************************/

/**
 * \brief BlockRleSweep implements a stateful abstraction of CUDA thread blocks for participating in device-wide run-length-encode across a range of tiles
 */
template <
    typename    BlockRleSweepPolicy,      ///< Parameterized BlockRleSweepPolicy tuning policy type
    typename    InputIterator,            ///< Random-access input iterator type for data
    typename    OffsetsOutputIterator,    ///< Random-access output iterator type for offset values
    typename    LengthsOutputIterator,    ///< Random-access output iterator type for length values
    typename    EqualityOp,               ///< T equality operator type
    typename    Offset>                   ///< Signed integer type for global offsets
struct BlockRleSweep
{
    //---------------------------------------------------------------------
    // Types and constants
    //---------------------------------------------------------------------

    // Data type of input iterator
    typedef typename std::iterator_traits<InputIterator>::value_type T;

    // Signed integer type for run lengths
    typedef typename std::iterator_traits<LengthsOutputIterator>::value_type Length;

    // Tuple type for scanning (pairs run-length and run-index)
    typedef ItemOffsetPair<Length, Offset> LengthOffsetPair;

    // Tile status descriptor interface type
    typedef ReduceByKeyScanTileState<Length, Offset> ScanTileState;

    // Constants
    enum
    {
        WARP_THREADS            = CUB_WARP_THREADS(PTX_ARCH),
        BLOCK_THREADS           = BlockRleSweepPolicy::BLOCK_THREADS,
        ITEMS_PER_THREAD        = BlockRleSweepPolicy::ITEMS_PER_THREAD,
        WARP_ITEMS              = WARP_THREADS * ITEMS_PER_THREAD,
        TILE_ITEMS              = BLOCK_THREADS * ITEMS_PER_THREAD,
        WARPS                   = (BLOCK_THREADS + WARP_THREADS - 1) / WARP_THREADS,

        /// Whether or not to sync after loading data
        SYNC_AFTER_LOAD         = (BlockRleSweepPolicy::LOAD_ALGORITHM != BLOCK_LOAD_DIRECT),

        /// Whether or not only one warp's worth of shared memory should be allocated and time-sliced among block-warps during any store-related data transpositions (versus each warp having its own storage)
        STORE_WARP_TIME_SLICING = BlockRleSweepPolicy::STORE_WARP_TIME_SLICING,
        ACTIVE_EXCHANGE_WARPS   = (STORE_WARP_TIME_SLICING) ? 1 : WARPS,
    };


    /**
     * Special operator that signals all out-of-bounds items are not equal to everything else,
     * forcing both (1) the last item to be tail-flagged and (2) all oob items to be marked
     * trivial.
     */
    template <bool LAST_TILE>
    struct OobInequalityOp
    {
        Offset          num_remaining;
        EqualityOp      equality_op;

        __device__ __forceinline__ OobInequalityOp(
            Offset      num_remaining,
            EqualityOp  equality_op)
        :
            num_remaining(num_remaining),
            equality_op(equality_op)
        {}

        template <typename Index>
        __device__ __forceinline__ bool operator()(T first, T second, Index idx)
        {
            if (!LAST_TILE || (idx < num_remaining))
                return !equality_op(first, second);
            else
                return true;
        }
    };


    // Cache-modified input iterator wrapper type for data
    typedef typename If<IsPointer<InputIterator>::VALUE,
            CacheModifiedInputIterator<BlockRleSweepPolicy::LOAD_MODIFIER, T, Offset>,      // Wrap the native input pointer with CacheModifiedVLengthnputIterator
            InputIterator>::Type                                                                     // Directly use the supplied input iterator type
        WrappedInputIterator;

    // Parameterized BlockLoad type for data
    typedef BlockLoad<
            WrappedInputIterator,
            BlockRleSweepPolicy::BLOCK_THREADS,
            BlockRleSweepPolicy::ITEMS_PER_THREAD,
            BlockRleSweepPolicy::LOAD_ALGORITHM>
        BlockLoadT;

    // Parameterized BlockDiscontinuity type for data
    typedef BlockDiscontinuity<T, BLOCK_THREADS> BlockDiscontinuityT;

    // Parameterized WarpScan type
    typedef WarpScan<LengthOffsetPair> WarpScanPairs;

    // Reduce-length-by-run scan operator
    typedef ReduceBySegmentOp<cub::Sum, LengthOffsetPair> ReduceBySegmentOp;

    // Callback type for obtaining tile prefix during block scan
    typedef BlockScanLookbackPrefixOp<
            LengthOffsetPair,
            ReduceBySegmentOp,
            ScanTileState>
        LookbackPrefixCallbackOp;

    // Warp exchange types
    typedef WarpExchange<LengthOffsetPair, ITEMS_PER_THREAD>    WarpExchangePairs;

    typedef typename If<STORE_WARP_TIME_SLICING, typename WarpExchangePairs::TempStorage, NullType>::Type WarpExchangePairsStorage;

    typedef WarpExchange<Offset, ITEMS_PER_THREAD>              WarpExchangeOffsets;
    typedef WarpExchange<Length, ITEMS_PER_THREAD>              WarpExchangeLengths;

    // Shared memory type for this threadblock
    struct _TempStorage
    {
        union
        {
            struct
            {
                typename BlockDiscontinuityT::TempStorage       discontinuity;              // Smem needed for discontinuity detection
                typename WarpScanPairs::TempStorage             warp_scan[WARPS];           // Smem needed for warp-synchronous scans
                LengthOffsetPair                                warp_aggregates[WARPS];     // Smem needed for sharing warp-wide aggregates
                typename LookbackPrefixCallbackOp::TempStorage  prefix;                     // Smem needed for cooperative prefix callback
            };

            // Smem needed for input loading
            typename BlockLoadT::TempStorage                    load;

            // Smem needed for two-phase scatter
            union
            {
                unsigned long long                              align;
                WarpExchangePairsStorage                        exchange_pairs[ACTIVE_EXCHANGE_WARPS];
                typename WarpExchangeOffsets::TempStorage       exchange_offsets[ACTIVE_EXCHANGE_WARPS];
                typename WarpExchangeLengths::TempStorage       exchange_lengths[ACTIVE_EXCHANGE_WARPS];
            };
        };

        Offset              tile_idx;                   // Shared tile index
        LengthOffsetPair    tile_inclusive;             // Inclusive tile prefix
        LengthOffsetPair    tile_exclusive;             // Exclusive tile prefix
    };

    // Alias wrapper allowing storage to be unioned
    struct TempStorage : Uninitialized<_TempStorage> {};


    //---------------------------------------------------------------------
    // Per-thread fields
    //---------------------------------------------------------------------

    _TempStorage                    &temp_storage;      ///< Reference to temp_storage

    WrappedInputIterator            d_in;               ///< Pointer to input sequence of data items
    OffsetsOutputIterator           d_offsets_out;      ///< Input run offsets
    LengthsOutputIterator           d_lengths_out;      ///< Output run lengths

    EqualityOp                      equality_op;        ///< T equality operator
    ReduceBySegmentOp               scan_op;            ///< Reduce-length-by-flag scan operator
    Offset                          num_items;          ///< Total number of input items


    //---------------------------------------------------------------------
    // Constructor
    //---------------------------------------------------------------------

    // Constructor
    __device__ __forceinline__
    BlockRleSweep(
        TempStorage                 &temp_storage,      ///< [in] Reference to temp_storage
        InputIterator               d_in,               ///< [in] Pointer to input sequence of data items
        OffsetsOutputIterator       d_offsets_out,      ///< [out] Pointer to output sequence of run offsets
        LengthsOutputIterator       d_lengths_out,      ///< [out] Pointer to output sequence of run lengths
        EqualityOp                  equality_op,        ///< [in] T equality operator
        Offset                      num_items)          ///< [in] Total number of input items
    :
        temp_storage(temp_storage.Alias()),
        d_in(d_in),
        d_offsets_out(d_offsets_out),
        d_lengths_out(d_lengths_out),
        equality_op(equality_op),
        scan_op(cub::Sum()),
        num_items(num_items)
    {}


    //---------------------------------------------------------------------
    // Utility methods for initializing the selections
    //---------------------------------------------------------------------

    template <bool FIRST_TILE, bool LAST_TILE>
    __device__ __forceinline__ void InitializeSelections(
        Offset              block_offset,
        Offset              num_remaining,
        T                   (&items)[ITEMS_PER_THREAD],
        LengthOffsetPair    (&lengths_and_num_runs)[ITEMS_PER_THREAD])
    {
        bool                head_flags[ITEMS_PER_THREAD];
        bool                tail_flags[ITEMS_PER_THREAD];

        OobInequalityOp<LAST_TILE> inequality_op(num_remaining, equality_op);

        if (FIRST_TILE && LAST_TILE)
        {
            // First-and-last-tile always head-flags the first item and tail-flags the last item

            BlockDiscontinuityT(temp_storage.discontinuity).FlagHeadsAndTails(
                head_flags, tail_flags, items, inequality_op);
        }
        else if (FIRST_TILE)
        {
            // First-tile always head-flags the first item

            // Get the first item from the next tile
            T tile_successor_item;
            if (threadIdx.x == BLOCK_THREADS - 1)
                tile_successor_item = d_in[block_offset + TILE_ITEMS];

            BlockDiscontinuityT(temp_storage.discontinuity).FlagHeadsAndTails(
                head_flags, tail_flags, tile_successor_item, items, inequality_op);
        }
        else if (LAST_TILE)
        {
            // Last-tile always flags the last item

            // Get the last item from the previous tile
            T tile_predecessor_item;
            if (threadIdx.x == 0)
                tile_predecessor_item = d_in[block_offset - 1];

            BlockDiscontinuityT(temp_storage.discontinuity).FlagHeadsAndTails(
                head_flags, tile_predecessor_item, tail_flags, items, inequality_op);
        }
        else
        {
            // Get the first item from the next tile
            T tile_successor_item;
            if (threadIdx.x == BLOCK_THREADS - 1)
                tile_successor_item = d_in[block_offset + TILE_ITEMS];

            // Get the last item from the previous tile
            T tile_predecessor_item;
            if (threadIdx.x == 0)
                tile_predecessor_item = d_in[block_offset - 1];

            BlockDiscontinuityT(temp_storage.discontinuity).FlagHeadsAndTails(
                head_flags, tile_predecessor_item, tail_flags, tile_successor_item, items, inequality_op);
        }

        // Zip counts and runs
        #pragma unroll
        for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ++ITEM)
        {
            lengths_and_num_runs[ITEM].offset   = head_flags[ITEM] && (!tail_flags[ITEM]);
            lengths_and_num_runs[ITEM].value    = ((!head_flags[ITEM]) || (!tail_flags[ITEM]));
        }
    }

    //---------------------------------------------------------------------
    // Scan utility methods
    //---------------------------------------------------------------------

    /**
     * Scan of allocations
     */
    __device__ __forceinline__ void WarpScanAllocations(
        LengthOffsetPair    &tile_aggregate,
        LengthOffsetPair    &warp_aggregate,
        LengthOffsetPair    &warp_exclusive_in_tile,
        LengthOffsetPair    &thread_exclusive_in_warp,
        LengthOffsetPair    (&lengths_and_num_runs)[ITEMS_PER_THREAD])
    {
        // Perform warpscans
        int warp_id = ((WARPS == 1) ? 0 : threadIdx.x / WARP_THREADS);
        int lane_id = LaneId();

        LengthOffsetPair identity;
        identity.offset = 0;
        identity.value = 0;

        LengthOffsetPair thread_inclusive;
        LengthOffsetPair thread_aggregate = ThreadReduce(lengths_and_num_runs, scan_op);
        WarpScanPairs(temp_storage.warp_scan[warp_id]).Scan(
            thread_aggregate,
            thread_inclusive,
            thread_exclusive_in_warp,
            identity,
            scan_op);

        // Last lane in each warp shares its warp-aggregate
        if (lane_id == WARP_THREADS - 1)
            temp_storage.warp_aggregates[warp_id] = thread_inclusive;

        __syncthreads();

        // Accumulate total selected and the warp-wide prefix
        warp_exclusive_in_tile          = identity;
        warp_aggregate                  = temp_storage.warp_aggregates[warp_id];
        tile_aggregate                  = temp_storage.warp_aggregates[0];

        #pragma unroll
        for (int WARP = 1; WARP < WARPS; ++WARP)
        {
            if (warp_id == WARP)
                warp_exclusive_in_tile = tile_aggregate;

            tile_aggregate = scan_op(tile_aggregate, temp_storage.warp_aggregates[WARP]);
        }
    }


    //---------------------------------------------------------------------
    // Utility methods for scattering selections
    //---------------------------------------------------------------------

    /**
     * Two-phase scatter, specialized for warp time-slicing
     */
    template <bool FIRST_TILE>
    __device__ __forceinline__ void ScatterTwoPhase(
        Offset              tile_num_runs_exclusive_in_global,
        Offset              warp_num_runs_aggregate,
        Offset              warp_num_runs_exclusive_in_tile,
        Offset              (&thread_num_runs_exclusive_in_warp)[ITEMS_PER_THREAD],
        LengthOffsetPair    (&lengths_and_offsets)[ITEMS_PER_THREAD],
        Int2Type<true>      is_warp_time_slice)
    {
        int warp_id = ((WARPS == 1) ? 0 : threadIdx.x / WARP_THREADS);
        int lane_id = LaneId();

        // Locally compact items within the warp (first warp)
        if (warp_id == 0)
        {
            WarpExchangePairs(temp_storage.exchange_pairs[0]).ScatterToStriped(lengths_and_offsets, thread_num_runs_exclusive_in_warp);
        }

        // Locally compact items within the warp (remaining warps)
        #pragma unroll
        for (int SLICE = 1; SLICE < WARPS; ++SLICE)
        {
            __syncthreads();

            if (warp_id == SLICE)
            {
                WarpExchangePairs(temp_storage.exchange_pairs[0]).ScatterToStriped(lengths_and_offsets, thread_num_runs_exclusive_in_warp);
            }
        }

        // Global scatter
        #pragma unroll
        for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ITEM++)
        {
            if ((ITEM * WARP_THREADS) < warp_num_runs_aggregate - lane_id)
            {
                Offset item_offset =
                    tile_num_runs_exclusive_in_global +
                    warp_num_runs_exclusive_in_tile +
                    (ITEM * WARP_THREADS) + lane_id;

                // Scatter offset
                d_offsets_out[item_offset] = lengths_and_offsets[ITEM].offset;

                // Scatter length if not the first (global) length
                if ((!FIRST_TILE) || (ITEM != 0) || (threadIdx.x > 0))
                {
                    d_lengths_out[item_offset - 1] = lengths_and_offsets[ITEM].value;
                }
            }
        }
    }


    /**
     * Two-phase scatter
     */
    template <bool FIRST_TILE>
    __device__ __forceinline__ void ScatterTwoPhase(
        Offset              tile_num_runs_exclusive_in_global,
        Offset              warp_num_runs_aggregate,
        Offset              warp_num_runs_exclusive_in_tile,
        Offset              (&thread_num_runs_exclusive_in_warp)[ITEMS_PER_THREAD],
        LengthOffsetPair    (&lengths_and_offsets)[ITEMS_PER_THREAD],
        Int2Type<false>     is_warp_time_slice)
    {
        int warp_id = ((WARPS == 1) ? 0 : threadIdx.x / WARP_THREADS);
        int lane_id = LaneId();

        // Unzip
        Offset run_offsets[ITEMS_PER_THREAD];
        Length run_lengths[ITEMS_PER_THREAD];

        #pragma unroll
        for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ITEM++)
        {
            run_offsets[ITEM] = lengths_and_offsets[ITEM].offset;
            run_lengths[ITEM] = lengths_and_offsets[ITEM].value;
        }

        WarpExchangeOffsets(temp_storage.exchange_offsets[warp_id]).ScatterToStriped(run_offsets, thread_num_runs_exclusive_in_warp);

        if (sizeof(Length) == sizeof(Offset))
            __threadfence_block();
        else
            __syncthreads();

        WarpExchangeLengths(temp_storage.exchange_lengths[warp_id]).ScatterToStriped(run_lengths, thread_num_runs_exclusive_in_warp);

        // Global scatter
        #pragma unroll
        for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ITEM++)
        {
            if ((ITEM * WARP_THREADS) + lane_id < warp_num_runs_aggregate)
            {
                Offset item_offset =
                    tile_num_runs_exclusive_in_global +
                    warp_num_runs_exclusive_in_tile +
                    (ITEM * WARP_THREADS) + lane_id;

                // Scatter offset
                d_offsets_out[item_offset] = run_offsets[ITEM];

                // Scatter length if not the first (global) length
                if ((!FIRST_TILE) || (ITEM != 0) || (threadIdx.x > 0))
                {
                    d_lengths_out[item_offset - 1] = run_lengths[ITEM];
                }
            }
        }
    }


    /**
     * Direct scatter
     */
    template <bool FIRST_TILE>
    __device__ __forceinline__ void ScatterDirect(
        Offset              tile_num_runs_exclusive_in_global,
        Offset              warp_num_runs_aggregate,
        Offset              warp_num_runs_exclusive_in_tile,
        Offset              (&thread_num_runs_exclusive_in_warp)[ITEMS_PER_THREAD],
        LengthOffsetPair    (&lengths_and_offsets)[ITEMS_PER_THREAD])
    {
        #pragma unroll
        for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ++ITEM)
        {
            if (thread_num_runs_exclusive_in_warp[ITEM] < warp_num_runs_aggregate)
            {
                Offset item_offset =
                    tile_num_runs_exclusive_in_global +
                    warp_num_runs_exclusive_in_tile +
                    thread_num_runs_exclusive_in_warp[ITEM];

                // Scatter offset
                d_offsets_out[item_offset] = lengths_and_offsets[ITEM].offset;

                // Scatter length if not the first (global) length
                if ((!FIRST_TILE) || (ITEM != 0) || (threadIdx.x > 0))
                {
                    d_lengths_out[item_offset - 1] = lengths_and_offsets[ITEM].value;
                }
            }
        }
    }


    /**
     * Scatter
     */
    template <bool FIRST_TILE>
    __device__ __forceinline__ void Scatter(
        Offset              tile_num_runs_aggregate,
        Offset              tile_num_runs_exclusive_in_global,
        Offset              warp_num_runs_aggregate,
        Offset              warp_num_runs_exclusive_in_tile,
        Offset              (&thread_num_runs_exclusive_in_warp)[ITEMS_PER_THREAD],
        LengthOffsetPair    (&lengths_and_offsets)[ITEMS_PER_THREAD])
    {
        if ((ITEMS_PER_THREAD == 1) || (tile_num_runs_aggregate < BLOCK_THREADS))
        {
            // Direct scatter if the warp has any items
            if (warp_num_runs_aggregate)
            {
                ScatterDirect<FIRST_TILE>(
                    tile_num_runs_exclusive_in_global,
                    warp_num_runs_aggregate,
                    warp_num_runs_exclusive_in_tile,
                    thread_num_runs_exclusive_in_warp,
                    lengths_and_offsets);
            }
        }
        else
        {
            // Scatter two phase
            ScatterTwoPhase<FIRST_TILE>(
                tile_num_runs_exclusive_in_global,
                warp_num_runs_aggregate,
                warp_num_runs_exclusive_in_tile,
                thread_num_runs_exclusive_in_warp,
                lengths_and_offsets,
                Int2Type<STORE_WARP_TIME_SLICING>());
        }

    }



    //---------------------------------------------------------------------
    // Cooperatively scan a device-wide sequence of tiles with other CTAs
    //---------------------------------------------------------------------

    /**
     * Process a tile of input (dynamic chained scan)
     */
    template <
        bool                LAST_TILE>
    __device__ __forceinline__ LengthOffsetPair ConsumeTile(
        Offset              num_items,          ///< Total number of global input items
        Offset              num_remaining,      ///< Number of global input items remaining (including this tile)
        int                 tile_idx,           ///< Tile index
        Offset              block_offset,       ///< Tile offset
        ScanTileState       &tile_status)       ///< Global list of tile status
    {
        if (tile_idx == 0)
        {
            // First tile

            // Load items
            T items[ITEMS_PER_THREAD];
            if (LAST_TILE)
                BlockLoadT(temp_storage.load).Load(d_in + block_offset, items, num_remaining, ZeroInitialize<T>());
            else
                BlockLoadT(temp_storage.load).Load(d_in + block_offset, items);

            if (SYNC_AFTER_LOAD)
                __syncthreads();

            // Set flags
            LengthOffsetPair    lengths_and_num_runs[ITEMS_PER_THREAD];

            InitializeSelections<true, LAST_TILE>(
                block_offset,
                num_remaining,
                items,
                lengths_and_num_runs);

            // Exclusive scan of lengths and runs
            LengthOffsetPair tile_aggregate;
            LengthOffsetPair warp_aggregate;
            LengthOffsetPair warp_exclusive_in_tile;
            LengthOffsetPair thread_exclusive_in_warp;

            WarpScanAllocations(
                tile_aggregate,
                warp_aggregate,
                warp_exclusive_in_tile,
                thread_exclusive_in_warp,
                lengths_and_num_runs);

            // Update tile status if this is not the last tile
            if (!LAST_TILE && (threadIdx.x == 0))
                tile_status.SetInclusive(0, tile_aggregate);

            // Update thread_exclusive_in_warp to fold in warp run-length
            if (thread_exclusive_in_warp.offset == 0)
                thread_exclusive_in_warp.value += warp_exclusive_in_tile.value;

            LengthOffsetPair    lengths_and_offsets[ITEMS_PER_THREAD];
            Offset              thread_num_runs_exclusive_in_warp[ITEMS_PER_THREAD];
            LengthOffsetPair    lengths_and_num_runs2[ITEMS_PER_THREAD];

            // Downsweep scan through lengths_and_num_runs
            ThreadScanExclusive(lengths_and_num_runs, lengths_and_num_runs2, scan_op, thread_exclusive_in_warp);

            // Zip

            #pragma unroll
            for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ITEM++)
            {
                lengths_and_offsets[ITEM].value         = lengths_and_num_runs2[ITEM].value;
                lengths_and_offsets[ITEM].offset        = block_offset + (threadIdx.x * ITEMS_PER_THREAD) + ITEM;
                thread_num_runs_exclusive_in_warp[ITEM] = (lengths_and_num_runs[ITEM].offset) ?
                                                                lengths_and_num_runs2[ITEM].offset :         // keep
                                                                WARP_THREADS * ITEMS_PER_THREAD;            // discard
            }

            Offset tile_num_runs_aggregate              = tile_aggregate.offset;
            Offset tile_num_runs_exclusive_in_global    = 0;
            Offset warp_num_runs_aggregate              = warp_aggregate.offset;
            Offset warp_num_runs_exclusive_in_tile      = warp_exclusive_in_tile.offset;

            // Scatter
            Scatter<true>(
                tile_num_runs_aggregate,
                tile_num_runs_exclusive_in_global,
                warp_num_runs_aggregate,
                warp_num_runs_exclusive_in_tile,
                thread_num_runs_exclusive_in_warp,
                lengths_and_offsets);

            // Return running total (inclusive of this tile)
            return tile_aggregate;
        }
        else
        {
            // Not first tile

            // Load items
            T items[ITEMS_PER_THREAD];
            if (LAST_TILE)
                BlockLoadT(temp_storage.load).Load(d_in + block_offset, items, num_remaining, ZeroInitialize<T>());
            else
                BlockLoadT(temp_storage.load).Load(d_in + block_offset, items);

            if (SYNC_AFTER_LOAD)
                __syncthreads();

            // Set flags
            LengthOffsetPair    lengths_and_num_runs[ITEMS_PER_THREAD];

            InitializeSelections<false, LAST_TILE>(
                block_offset,
                num_remaining,
                items,
                lengths_and_num_runs);

            // Exclusive scan of lengths and runs
            LengthOffsetPair tile_aggregate;
            LengthOffsetPair warp_aggregate;
            LengthOffsetPair warp_exclusive_in_tile;
            LengthOffsetPair thread_exclusive_in_warp;

            WarpScanAllocations(
                tile_aggregate,
                warp_aggregate,
                warp_exclusive_in_tile,
                thread_exclusive_in_warp,
                lengths_and_num_runs);

            // First warp computes tile prefix in lane 0
            LookbackPrefixCallbackOp prefix_op(tile_status, temp_storage.prefix, Sum(), tile_idx);
            int warp_id = ((WARPS == 1) ? 0 : threadIdx.x / WARP_THREADS);
            if (warp_id == 0)
            {
                prefix_op(tile_aggregate);
                if (threadIdx.x == 0)
                    temp_storage.tile_exclusive = prefix_op.exclusive_prefix;
            }

            __syncthreads();

            LengthOffsetPair tile_exclusive_in_global = temp_storage.tile_exclusive;

            // Update thread_exclusive_in_warp to fold in warp and tile run-lengths
            LengthOffsetPair thread_exclusive = scan_op(tile_exclusive_in_global, warp_exclusive_in_tile);
            if (thread_exclusive_in_warp.offset == 0)
                thread_exclusive_in_warp.value += thread_exclusive.value;

            // Downsweep scan through lengths_and_num_runs
            LengthOffsetPair    lengths_and_num_runs2[ITEMS_PER_THREAD];
            LengthOffsetPair    lengths_and_offsets[ITEMS_PER_THREAD];
            Offset              thread_num_runs_exclusive_in_warp[ITEMS_PER_THREAD];

            ThreadScanExclusive(lengths_and_num_runs, lengths_and_num_runs2, scan_op, thread_exclusive_in_warp);

            // Zip
            #pragma unroll
            for (int ITEM = 0; ITEM < ITEMS_PER_THREAD; ITEM++)
            {
                lengths_and_offsets[ITEM].value         = lengths_and_num_runs2[ITEM].value;
                lengths_and_offsets[ITEM].offset        = block_offset + (threadIdx.x * ITEMS_PER_THREAD) + ITEM;
                thread_num_runs_exclusive_in_warp[ITEM] = (lengths_and_num_runs[ITEM].offset) ?
                                                                lengths_and_num_runs2[ITEM].offset :         // keep
                                                                WARP_THREADS * ITEMS_PER_THREAD;            // discard
            }

            Offset tile_num_runs_aggregate              = tile_aggregate.offset;
            Offset tile_num_runs_exclusive_in_global    = tile_exclusive_in_global.offset;
            Offset warp_num_runs_aggregate              = warp_aggregate.offset;
            Offset warp_num_runs_exclusive_in_tile      = warp_exclusive_in_tile.offset;

            // Scatter
            Scatter<false>(
                tile_num_runs_aggregate,
                tile_num_runs_exclusive_in_global,
                warp_num_runs_aggregate,
                warp_num_runs_exclusive_in_tile,
                thread_num_runs_exclusive_in_warp,
                lengths_and_offsets);

            // Return running total (inclusive of this tile)
            return prefix_op.inclusive_prefix;
        }
    }


    /**
     * Dequeue and scan tiles of items as part of a dynamic chained scan
     */
    template <typename NumRunsIterator>         ///< Output iterator type for recording number of items selected
    __device__ __forceinline__ void ConsumeRange(
        int                 num_tiles,          ///< Total number of input tiles
        GridQueue<int>      queue,              ///< Queue descriptor for assigning tiles of work to thread blocks
        ScanTileState       &tile_status,       ///< Global list of tile status
        NumRunsIterator     d_num_runs_out)         ///< Output pointer for total number of runs identified
    {

#if __CUDA_ARCH__ > 130

        // Blocks may not be launched in increasing order, so work-steal tiles
        if (threadIdx.x == 0)
            temp_storage.tile_idx = queue.Drain(1);

        __syncthreads();

        int tile_idx = temp_storage.tile_idx;

#else

        // Blocks are launched in increasing order, so just assign one tile per block
        int tile_idx = (blockIdx.y * gridDim.x) + blockIdx.x;

#endif

        Offset  block_offset    = Offset(TILE_ITEMS) * tile_idx;            // Global offset for the current tile
        Offset  num_remaining   = num_items - block_offset;                 // Remaining items (including this tile)

        if (tile_idx < num_tiles - 1)
        {
            // Full tile
            ConsumeTile<false>(num_items, num_remaining, tile_idx, block_offset, tile_status);
        }
        else
        {
            // Last tile
            LengthOffsetPair running_total = ConsumeTile<true>(num_items, num_remaining, tile_idx, block_offset, tile_status);

            if (threadIdx.x == 0)
            {
                // Output the total number of items selected
                *d_num_runs_out = running_total.offset;

                // The inclusive prefix contains accumulated length reduction for the last run
                d_lengths_out[running_total.offset - 1] = running_total.value;
            }
        }

    }

};


}               // CUB namespace
CUB_NS_POSTFIX  // Optional outer namespace(s)
