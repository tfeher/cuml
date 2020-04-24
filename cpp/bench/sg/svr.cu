/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
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

#include <cuml/matrix/kernelparams.h>
#include <cmath>
#include <cuml/cuml.hpp>
#include <cuml/svm/svc.hpp>
#include <cuml/svm/svr.hpp>
#include <utility>
#include "benchmark.cuh"
#include "cuml/svm/svm_model.h"
#include "cuml/svm/svm_parameter.h"

namespace ML {
namespace Bench {
namespace SVM {

template <typename D>
struct Params {
  DatasetParams data;
  RegressionParams regression;
  MLCommon::Matrix::KernelParams kernel;
  ML::SVM::svmParameter svm_param;
  ML::SVM::svmModel<D> model;
};

template <typename D>
class SVR : public RegressionFixture<D> {
 public:
  SVR(const std::string& name, const Params<D>& p)
    : RegressionFixture<D>(p.data, p.regression),
      kernel(p.kernel),
      model(p.model),
      svm_param(p.svm_param) {
    std::vector<std::string> kernel_names{"linear", "poly", "rbf", "tanh"};
    std::ostringstream oss;
    oss << name << "/" << kernel_names[kernel.kernel] << p.data;
    this->SetName(oss.str().c_str());
  }

 protected:
  void runBenchmark(::benchmark::State& state) override {
    if (this->params.rowMajor) {
      state.SkipWithError("SVR only supports col-major inputs");
    }
    if (this->svm_param.svmType != ML::SVM::EPSILON_SVR) {
      state.SkipWithError("SVR currently only supports EPSILON_SVR");
    }
    auto& handle = *this->handle;
    auto stream = handle.getStream();
    for (auto _ : state) {
      CudaEventTimer timer(handle, state, true, stream);
      ML::SVM::svrFit(handle, this->data.X, this->params.nrows,
                      this->params.ncols, this->data.y, this->svm_param,
                      this->kernel, this->model);
      CUDA_CHECK(cudaStreamSynchronize(stream));
      ML::SVM::svmFreeBuffers(handle, this->model);
    }
  }

 private:
  MLCommon::Matrix::KernelParams kernel;
  ML::SVM::svmParameter svm_param;
  ML::SVM::svmModel<D> model;
};

template <typename D>
std::vector<Params<D>> getInputs() {
  struct Triplets {
    int nrows, ncols, n_informative;
  };
  std::vector<Params<D>> out;
  Params<D> p;

  p.data.rowMajor = false;

  p.regression.shuffle = true;  // better to shuffle when n_informative < ncols
  p.regression.seed = 12345ULL;
  p.regression.effective_rank = -1;  // dataset generation will be faster
  p.regression.bias = 0;
  p.regression.tail_strength = 0.5;  // unused when effective_rank = -1
  p.regression.noise = 1;

  // svmParameter{C, cache_size, max_iter, nochange_steps, tol, verbosity,
  //              epsilon, svmType})
  p.svm_param = ML::SVM::svmParameter{
    1, 200, 1000, 100, 1e-3, CUML_LEVEL_INFO, 0.1, ML::SVM::EPSILON_SVR};
  p.model =
    ML::SVM::svmModel<D>{0, 0, 0, nullptr, nullptr, nullptr, 0, nullptr};

  std::vector<Triplets> rowcols = {
    {2000, 2, 2}, {100, 10000, 10}, {2000, 200, 200}};

  std::vector<MLCommon::Matrix::KernelParams> kernels{
    MLCommon::Matrix::KernelParams{MLCommon::Matrix::LINEAR, 3, 1, 0},
    MLCommon::Matrix::KernelParams{MLCommon::Matrix::POLYNOMIAL, 3, 1, 0},
    MLCommon::Matrix::KernelParams{MLCommon::Matrix::RBF, 3, 1, 0},
    MLCommon::Matrix::KernelParams{MLCommon::Matrix::TANH, 3, 0.1, 0}};

  for (auto& rc : rowcols) {
    p.data.nrows = rc.nrows;
    p.data.ncols = rc.ncols;
    p.regression.n_informative = rc.n_informative;
    for (auto kernel : kernels) {
      p.kernel = kernel;
      p.kernel.gamma = 1 / rc.ncols;
      out.push_back(p);
    }
  }
  return out;
}

CUML_BENCH_REGISTER(Params<float>, SVR<float>, "regression",
                    getInputs<float>());
CUML_BENCH_REGISTER(Params<double>, SVR<double>, "regression",
                    getInputs<double>());

}  // namespace SVM
}  // namespace Bench
}  // end namespace ML