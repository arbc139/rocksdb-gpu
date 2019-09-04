
#include <chrono>
#include <cstdio>
#include <functional>
#include <iostream>
#include <string>
#include <thread>
#include <vector>
extern "C" {
#include <pinpool.h>
#include <filemap.h>
}
#include "accelerator/cuda/block_decoder.h"
#include "accelerator/cuda/filter.h"
#include "rocksdb/slice.h"
#include "table/format.h"
#include "stdio.h"

#define KB 1024
#define MB 1024 * KB
#define GB 1024 * MB

#define cudaCheckError(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line,
                      bool abort=true) {
  if (code != cudaSuccess) {
    fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
    if (abort) exit(code);
  }
}

namespace ruda {
namespace kernel {
__global__
void rudaDonardFilterKernel(char **file_address, uint64_t size, uint64_t *block_index, uint64_t *g_block_index, uint64_t block_unit, uint64_t *handles,
 RudaSchema *schema, uint64_t *results_size, int *results_idx, donardSlice *d_results);
}  // namespace kernel

struct DonardManager {

  // fileMap list
  struct filemap ** fmlist; 

  // Parameter

  int *num_entries_;

  int num_file_;
  int total_blocks_;
  int block_unit_;
  int num_thread_;
  int max_results_count_;   
  std::vector<uint64_t> gpu_blocks_;
 
  
  // MetaData
  //void **file_address;  // [fmlist[0]->data][fmlist[1]->data][fmlist[2]->data] ...
  char **file_address;
  uint64_t *block_index; // the number of blocks in each file
  uint64_t *g_block_index;
  uint64_t *d_handles;

  // Schema
  RudaSchema *d_schema; // device schema
  RudaSchema h_schema; // host schema

  // Result
  int *d_results_idx;
  uint64_t *d_results_size;
  uint64_t *h_results_size;
  donardSlice *d_results;
  donardSlice * h_results;

  DonardManager(int num_file, int total_blocks, int block_unit, int num_thread, int max_results_count) {
    std::cout << "[DONARD MANAGER INITALIZE]" << std::endl;
    num_file_ = num_file;
    total_blocks_ = total_blocks;
    block_unit_ = block_unit;
    num_thread_ = num_thread;
    max_results_count_ = max_results_count;
  }

  void populate(std::vector<std::string> files, std::vector<uint64_t> num_blocks, std::vector<uint64_t> handles, const rocksdb::SlicewithSchema &schema) {
    std::cout << "[DONARD POPULATE]" << std::endl;
    fmlist = (filemap **)malloc(sizeof(filemap *) * num_file_);
    for(uint i = 0; i < num_file_; i++) {
      fmlist[i] = filemap_open_cuda(files[i].c_str());
    }

    std::cout << "[DONARD POPULATE1] " << num_file_ << " " << total_blocks_ << std::endl;
    //cudaCheckError(cudaMalloc((void ***) &file_address, sizeof(char *) * num_file_));
    cudaCheckError(cudaHostAlloc((void**)&file_address, sizeof(char*) * num_file_, cudaHostAllocMapped));

    std::cout << "[DONARD POPULATE 1-1]" << std::endl;
    for(uint i = 0; i < num_file_; i++) {
      file_address[i] = (char *)fmlist[i]->data;
    }
    
    int tmp_gpu_blocks = 0;
    for(uint i = 0; i < num_blocks.size(); i++) {
      int unit = 0;
      int remain = 0;
      if( i == 0 ) {
        unit = num_blocks[i] / block_unit_;
        remain = num_blocks[i] % block_unit_;
      } else {
        unit = (num_blocks[i] - num_blocks[i-1]) / block_unit_;
        remain = (num_blocks[i] - num_blocks[i-1]) % block_unit_;
      }
      tmp_gpu_blocks += unit;
      if(remain != 0) tmp_gpu_blocks += 1;
      gpu_blocks_.emplace_back(tmp_gpu_blocks);
    }

    std::cout << "gpu block index size " << gpu_blocks_.size() << std::endl;

    std::cout << "[DONARD POPULATE2]" << std::endl;
    cudaCheckError(cudaMalloc((void **) &block_index, sizeof(uint64_t) * num_blocks.size()));
    cudaCheckError(cudaMemcpy(block_index, &num_blocks[0], sizeof(uint64_t) * num_blocks.size(), cudaMemcpyHostToDevice));

    cudaCheckError(cudaMalloc((void **) &g_block_index, sizeof(uint64_t) * gpu_blocks_.size()));
    cudaCheckError(cudaMemcpy(g_block_index, &gpu_blocks_[0], sizeof(uint64_t) * gpu_blocks_.size(), cudaMemcpyHostToDevice));

    cudaCheckError(cudaMalloc((void **) &d_handles, sizeof(uint64_t) * handles.size()));
    cudaCheckError(cudaMemcpy(d_handles, &handles[0], sizeof(uint64_t) * handles.size(), cudaMemcpyHostToDevice));
  
    std::cout << "[DONARD POPULATE3]" << std::endl;
    // Deep copy for Schema
    rocksdb::SlicewithSchema* copy_schema = schema.clone();
    cudaCheckError(cudaHostRegister(&h_schema, sizeof(rocksdb::SlicewithSchema), cudaHostAllocMapped));
    cudaCheckError(cudaMalloc((void **) &d_schema, sizeof(RudaSchema)));
    cudaCheckError(h_schema.populateToCuda(*copy_schema));
    cudaCheckError(cudaMemcpy(d_schema, &h_schema, sizeof(RudaSchema), cudaMemcpyHostToDevice));

    std::cout << "[DONARD POPULATE4]" << std::endl;
    cudaCheckError(cudaMalloc((void **) &d_results_idx, sizeof(int)));
    cudaCheckError(cudaMemset(d_results_idx, 0, sizeof(int)));
    cudaCheckError(cudaMalloc((void **) &d_results_size, sizeof(uint64_t)));
    cudaCheckError(cudaMemset(d_results_size, 0, sizeof(int64_t)));

    std::cout << "[DONARD POPULATE5]" << std::endl;
    cudaCheckError(cudaMalloc((void **) &d_results, sizeof(donardSlice) * max_results_count_));
  
  }

  void executeKernel() {
    std::cout << "[DONARD KERNEL EXECUTE] : " << gpu_blocks_.back() << std::endl;
    kernel::rudaDonardFilterKernel<<< gpu_blocks_.back() , num_thread_ >>> (file_address, num_file_, block_index, g_block_index, block_unit_, d_handles,
                             d_schema, d_results_size, d_results_idx, d_results);
    //cudaMemcpy(h_results_size, d_results_size, sizeof(uint64_t));
  }

  void translatePairsToSlices(std::vector<rocksdb::PinnableSlice> &keys, std::vector<rocksdb::PinnableSlice> &results) {
    std::cout << "[DONARD TRANSLATE TO SLICES]" << std::endl;
    num_entries_ = (int *)malloc(sizeof(int));
    cudaCheckError(cudaMemcpy(num_entries_, d_results_idx, sizeof(int), cudaMemcpyDeviceToHost));
    
    std::cout << "[DONARD TRANSLATE TO SLICES 1]" << std::endl;
    int count = *num_entries_;

    h_results = (donardSlice *)malloc(sizeof(donardSlice) * count);
    cudaCheckError(cudaMemcpy(h_results, d_results, sizeof(donardSlice) * count, cudaMemcpyDeviceToHost));

    std::cout << "[DONARD TRANSLATE TO SLICES 2] " << count << std::endl;
    for (size_t i = 0; i < count; i++) {
      size_t key_size = h_results[i].key_size;
      char *key_char = (char *) malloc(sizeof(char) * key_size);
      memcpy((void *)key_char, h_results[i].key, sizeof(char) * key_size);

      size_t value_size = h_results[i].d_size;
      char *val_char = (char *) malloc(sizeof(char) * value_size);
      cudaCheckError(cudaMemcpy((void *)val_char, h_results[i].d_data, sizeof(char) * value_size, cudaMemcpyDeviceToHost));

      keys.emplace_back(std::move(rocksdb::PinnableSlice(key_char, key_size)));
      results.emplace_back(std::move(rocksdb::PinnableSlice(val_char, value_size)));
      free(key_char);
      free(val_char);
    }
  }

  void clear() {
    std::cout << "[DONARD CLEAR]" << std::endl;
    for(uint i = 0; i < num_file_; i++) {
      filemap_free(fmlist[i]);
    } 
    cudaCheckError(cudaFreeHost(file_address)); 
    cudaCheckError(cudaFree(block_index));
    cudaCheckError(h_schema.clear());
    cudaCheckError(cudaFree(d_schema));

    cudaCheckError(cudaFree(d_results_idx));
    cudaCheckError(cudaFree(d_results));
  }
};

__global__
void kernel::rudaDonardFilterKernel(char **file_address, uint64_t size, uint64_t *block_index, uint64_t *g_block_index, uint64_t g_block_unit, uint64_t * d_handles,
 RudaSchema *schema, uint64_t *results_size, int *results_idx, donardSlice *d_results) {  
  
  // blockDim.x * blockIdx.x + threadIdx.x;
  // blockDim = number of Thread in block

  // Find file location 
  unsigned int idx = getFileIdx(blockIdx.x, size, g_block_index);

  int gBlockOffset = (idx == 0) ? blockIdx.x : blockIdx.x - g_block_index[idx-1];
  int accumulatedBlocks = (idx == 0) ? g_block_unit * gBlockOffset : block_index[idx-1] + g_block_unit * gBlockOffset;

  int gBlockRemain = 0;
  if (blockIdx.x == g_block_index[idx] - 1) {
    gBlockRemain = (idx == 0) ? block_index[idx] % g_block_unit : (block_index[idx] - block_index[idx -1]) % g_block_unit;
  }
  if (gBlockRemain != 0) g_block_unit = gBlockRemain; 

  char *filePtr = file_address[idx];  
  const char *startPtr = (gBlockOffset == 0) ? filePtr : filePtr + d_handles[accumulatedBlocks -1];

  uint32_t blockSize = 0;
  int kDataBlockIndexTypeBitShift = 31;
  uint32_t kNumRestartsMask = (1u << kDataBlockIndexTypeBitShift) - 1u;
  uint32_t kBlockTrailerSize = 5;

  uint32_t threadsPerBlock = blockDim.x / g_block_unit;
  uint32_t threadRemain = blockDim.x % g_block_unit;
  uint32_t threadIdInBlock = threadIdx.x / g_block_unit;
  uint32_t blockLocation = threadIdx.x % g_block_unit; 

  if (blockLocation < threadRemain) threadsPerBlock += 1;

  if (gBlockOffset == 0) {
   if(blockLocation == 0) {
    blockSize = d_handles[accumulatedBlocks] - kBlockTrailerSize;
   } else {
    blockSize = d_handles[accumulatedBlocks + blockLocation] - d_handles[accumulatedBlocks + blockLocation - 1] - kBlockTrailerSize;
    startPtr += d_handles[accumulatedBlocks + blockLocation - 1];
   }
  } else { 
    blockSize = d_handles[accumulatedBlocks + blockLocation] - d_handles[accumulatedBlocks + blockLocation - 1] - kBlockTrailerSize; 
    startPtr += d_handles[accumulatedBlocks + blockLocation - 1] - d_handles[accumulatedBlocks - 1];
  }

  uint32_t numRestarts = DecodeFixed32(startPtr + blockSize - sizeof(uint32_t));
  numRestarts = numRestarts & kNumRestartsMask;
  uint32_t restartOffset = static_cast<uint32_t>(blockSize) - (1 + numRestarts) * sizeof(uint32_t);

  if (numRestarts < threadIdInBlock + 1) return;

  uint32_t numTask = numRestarts / threadsPerBlock;
  uint32_t remainNumTask = numRestarts % threadsPerBlock;

  bool lastThread = false;
  if (numTask == 0 && threadIdInBlock == numRestarts - 1) lastThread = true;
  if (numTask != 0 && threadIdInBlock == threadsPerBlock - 1) lastThread = true; 

  if (threadIdInBlock < remainNumTask) numTask += 1;

  if(numTask == 0) return;

  uint32_t startLocation = restartOffset;

  startLocation += (threadIdInBlock >= remainNumTask) ? (remainNumTask + (numTask * threadIdInBlock)) * sizeof(uint32_t) : (numTask * threadIdInBlock * sizeof(uint32_t));

  if (!lastThread) restartOffset = 0;
  DecodeNFilterOnSchemaDonard(startPtr, restartOffset, startLocation, numTask, schema, results_size, results_idx, d_results); 

}

int donardFilter( std::vector<std::string> files, std::vector<uint64_t> num_blocks, std::vector<uint64_t> handles, const rocksdb::SlicewithSchema &schema,
                  uint64_t max_results_count,
                  std::vector<rocksdb::PinnableSlice> &keys,
                  std::vector<rocksdb::PinnableSlice> &results) {

  std::cout << "[GPU][donardFilter] START" << std::endl;

  void *warming_up;
  cudaCheckError(cudaMalloc(&warming_up, 0));
  cudaCheckError(cudaFree(warming_up));

  DonardManager donard_mgr(
      files.size(),
      num_blocks.back(),
      30,
      128 /* kBlockSize */,
      max_results_count);

  donard_mgr.populate(files, num_blocks, handles, schema);
  donard_mgr.executeKernel();

  donard_mgr.translatePairsToSlices(keys, results);
  donard_mgr.clear();

  std::cout << "This is end " << std::endl;
  cudaDeviceSynchronize();
  cudaDeviceReset();
  return accelerator::ACC_OK;
}

}  // namespace ruda
