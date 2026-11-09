#pragma once
#include <napi/native_api.h>

// Registers asynchronous start/snapshot/cancel APIs; media work never runs on the JS thread.
napi_value RegisterMovieExports(napi_env env, napi_value exports);
