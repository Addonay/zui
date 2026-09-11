/*
 * wgpu_init.h - Zig-facing initializer shims for the wgpu-native C API.
 *
 * GENERATED FILE - DO NOT EDIT BY HAND.
 * Regenerate with:
 *
 *     python3 tools/gen_init_shims.py
 *
 * For every `WGPU_*_INIT` compound-literal macro in the pinned upstream
 * headers this header defines a `static inline` function returning that exact
 * initializer. `zig translate-c` turns each function into a Zig function, so
 * Zig consumers can obtain the upstream field defaults (which are not the same
 * as a zeroed struct) without transcribing them:
 *
 *     var desc = c.wgpu_zig_init_WGPUTextureDescriptor();
 *
 * The upstream headers are byte-for-byte copies of the pinned revision; see
 * README.md. The initializer bodies are evaluated by the C preprocessor and
 * therefore follow the defaults of the target being translated.
 */

#ifndef WGPU_ZIG_INIT_SHIMS_H_
#define WGPU_ZIG_INIT_SHIMS_H_

#include "webgpu/webgpu.h"
#include "webgpu/wgpu.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 92 initializer macros: WGPU_STRING_VIEW_INIT, WGPU_BUFFER_MAP_CALLBACK_INFO_INIT, WGPU_COMPILATION_INFO_CALLBACK_INFO_INIT, WGPU_CREATE_COMPUTE_PIPELINE_ASYNC_CALLBACK_INFO_INIT, WGPU_CREATE_RENDER_PIPELINE_ASYNC_CALLBACK_INFO_INIT, WGPU_DEVICE_LOST_CALLBACK_INFO_INIT, WGPU_POP_ERROR_SCOPE_CALLBACK_INFO_INIT, WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT, WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT, WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT, WGPU_UNCAPTURED_ERROR_CALLBACK_INFO_INIT, WGPU_ADAPTER_INFO_INIT, WGPU_BLEND_COMPONENT_INIT, WGPU_BUFFER_BINDING_LAYOUT_INIT, WGPU_BUFFER_DESCRIPTOR_INIT, WGPU_COLOR_INIT, WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT, WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT, WGPU_COMPATIBILITY_MODE_LIMITS_INIT, WGPU_COMPILATION_MESSAGE_INIT, WGPU_CONSTANT_ENTRY_INIT, WGPU_EXTENT_3D_INIT, WGPU_EXTERNAL_TEXTURE_BINDING_ENTRY_INIT, WGPU_EXTERNAL_TEXTURE_BINDING_LAYOUT_INIT, WGPU_FUTURE_INIT, WGPU_INSTANCE_LIMITS_INIT, WGPU_MULTISAMPLE_STATE_INIT, WGPU_ORIGIN_3D_INIT, WGPU_PASS_TIMESTAMP_WRITES_INIT, WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT, WGPU_PRIMITIVE_STATE_INIT, WGPU_QUERY_SET_DESCRIPTOR_INIT, WGPU_QUEUE_DESCRIPTOR_INIT, WGPU_RENDER_BUNDLE_DESCRIPTOR_INIT, WGPU_RENDER_BUNDLE_ENCODER_DESCRIPTOR_INIT, WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT, WGPU_RENDER_PASS_MAX_DRAW_COUNT_INIT, WGPU_REQUEST_ADAPTER_WEBXR_OPTIONS_INIT, WGPU_SAMPLER_BINDING_LAYOUT_INIT, WGPU_SAMPLER_DESCRIPTOR_INIT, WGPU_SHADER_SOURCE_SPIRV_INIT, WGPU_SHADER_SOURCE_WGSL_INIT, WGPU_STENCIL_FACE_STATE_INIT, WGPU_STORAGE_TEXTURE_BINDING_LAYOUT_INIT, WGPU_SUPPORTED_FEATURES_INIT, WGPU_SUPPORTED_INSTANCE_FEATURES_INIT, WGPU_SUPPORTED_WGSL_LANGUAGE_FEATURES_INIT, WGPU_SURFACE_CAPABILITIES_INIT, WGPU_SURFACE_COLOR_MANAGEMENT_INIT, WGPU_SURFACE_CONFIGURATION_INIT, WGPU_SURFACE_SOURCE_ANDROID_NATIVE_WINDOW_INIT, WGPU_SURFACE_SOURCE_METAL_LAYER_INIT, WGPU_SURFACE_SOURCE_WAYLAND_SURFACE_INIT, WGPU_SURFACE_SOURCE_WINDOWS_HWND_INIT, WGPU_SURFACE_SOURCE_XCB_WINDOW_INIT, WGPU_SURFACE_SOURCE_XLIB_WINDOW_INIT, WGPU_SURFACE_TEXTURE_INIT, WGPU_TEXEL_COPY_BUFFER_LAYOUT_INIT, WGPU_TEXTURE_BINDING_LAYOUT_INIT, WGPU_TEXTURE_BINDING_VIEW_DIMENSION_INIT, WGPU_TEXTURE_COMPONENT_SWIZZLE_INIT, WGPU_VERTEX_ATTRIBUTE_INIT, WGPU_BIND_GROUP_ENTRY_INIT, WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT, WGPU_BLEND_STATE_INIT, WGPU_COMPILATION_INFO_INIT, WGPU_COMPUTE_PASS_DESCRIPTOR_INIT, WGPU_COMPUTE_STATE_INIT, WGPU_DEPTH_STENCIL_STATE_INIT, WGPU_FUTURE_WAIT_INFO_INIT, WGPU_INSTANCE_DESCRIPTOR_INIT, WGPU_LIMITS_INIT, WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT, WGPU_REQUEST_ADAPTER_OPTIONS_INIT, WGPU_SHADER_MODULE_DESCRIPTOR_INIT, WGPU_SURFACE_DESCRIPTOR_INIT, WGPU_TEXEL_COPY_BUFFER_INFO_INIT, WGPU_TEXEL_COPY_TEXTURE_INFO_INIT, WGPU_TEXTURE_COMPONENT_SWIZZLE_DESCRIPTOR_INIT, WGPU_TEXTURE_DESCRIPTOR_INIT, WGPU_VERTEX_BUFFER_LAYOUT_INIT, WGPU_BIND_GROUP_DESCRIPTOR_INIT, WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT, WGPU_COLOR_TARGET_STATE_INIT, WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT, WGPU_DEVICE_DESCRIPTOR_INIT, WGPU_RENDER_PASS_DESCRIPTOR_INIT, WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT, WGPU_VERTEX_STATE_INIT, WGPU_FRAGMENT_STATE_INIT, WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT, WGPU_NATIVE_LIMITS_INIT */

/* WGPU_STRING_VIEW_INIT (from webgpu/webgpu.h) */
static inline WGPUStringView wgpu_zig_init_WGPUStringView(void) {
    WGPUStringView v = WGPU_STRING_VIEW_INIT;
    return v;
}

/* WGPU_BUFFER_MAP_CALLBACK_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPUBufferMapCallbackInfo wgpu_zig_init_WGPUBufferMapCallbackInfo(void) {
    WGPUBufferMapCallbackInfo v = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    return v;
}

/* WGPU_COMPILATION_INFO_CALLBACK_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPUCompilationInfoCallbackInfo wgpu_zig_init_WGPUCompilationInfoCallbackInfo(void) {
    WGPUCompilationInfoCallbackInfo v = WGPU_COMPILATION_INFO_CALLBACK_INFO_INIT;
    return v;
}

/* WGPU_CREATE_COMPUTE_PIPELINE_ASYNC_CALLBACK_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPUCreateComputePipelineAsyncCallbackInfo wgpu_zig_init_WGPUCreateComputePipelineAsyncCallbackInfo(void) {
    WGPUCreateComputePipelineAsyncCallbackInfo v = WGPU_CREATE_COMPUTE_PIPELINE_ASYNC_CALLBACK_INFO_INIT;
    return v;
}

/* WGPU_CREATE_RENDER_PIPELINE_ASYNC_CALLBACK_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPUCreateRenderPipelineAsyncCallbackInfo wgpu_zig_init_WGPUCreateRenderPipelineAsyncCallbackInfo(void) {
    WGPUCreateRenderPipelineAsyncCallbackInfo v = WGPU_CREATE_RENDER_PIPELINE_ASYNC_CALLBACK_INFO_INIT;
    return v;
}

/* WGPU_DEVICE_LOST_CALLBACK_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPUDeviceLostCallbackInfo wgpu_zig_init_WGPUDeviceLostCallbackInfo(void) {
    WGPUDeviceLostCallbackInfo v = WGPU_DEVICE_LOST_CALLBACK_INFO_INIT;
    return v;
}

/* WGPU_POP_ERROR_SCOPE_CALLBACK_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPUPopErrorScopeCallbackInfo wgpu_zig_init_WGPUPopErrorScopeCallbackInfo(void) {
    WGPUPopErrorScopeCallbackInfo v = WGPU_POP_ERROR_SCOPE_CALLBACK_INFO_INIT;
    return v;
}

/* WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPUQueueWorkDoneCallbackInfo wgpu_zig_init_WGPUQueueWorkDoneCallbackInfo(void) {
    WGPUQueueWorkDoneCallbackInfo v = WGPU_QUEUE_WORK_DONE_CALLBACK_INFO_INIT;
    return v;
}

/* WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPURequestAdapterCallbackInfo wgpu_zig_init_WGPURequestAdapterCallbackInfo(void) {
    WGPURequestAdapterCallbackInfo v = WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT;
    return v;
}

/* WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPURequestDeviceCallbackInfo wgpu_zig_init_WGPURequestDeviceCallbackInfo(void) {
    WGPURequestDeviceCallbackInfo v = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
    return v;
}

/* WGPU_UNCAPTURED_ERROR_CALLBACK_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPUUncapturedErrorCallbackInfo wgpu_zig_init_WGPUUncapturedErrorCallbackInfo(void) {
    WGPUUncapturedErrorCallbackInfo v = WGPU_UNCAPTURED_ERROR_CALLBACK_INFO_INIT;
    return v;
}

/* WGPU_ADAPTER_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPUAdapterInfo wgpu_zig_init_WGPUAdapterInfo(void) {
    WGPUAdapterInfo v = WGPU_ADAPTER_INFO_INIT;
    return v;
}

/* WGPU_BLEND_COMPONENT_INIT (from webgpu/webgpu.h) */
static inline WGPUBlendComponent wgpu_zig_init_WGPUBlendComponent(void) {
    WGPUBlendComponent v = WGPU_BLEND_COMPONENT_INIT;
    return v;
}

/* WGPU_BUFFER_BINDING_LAYOUT_INIT (from webgpu/webgpu.h) */
static inline WGPUBufferBindingLayout wgpu_zig_init_WGPUBufferBindingLayout(void) {
    WGPUBufferBindingLayout v = WGPU_BUFFER_BINDING_LAYOUT_INIT;
    return v;
}

/* WGPU_BUFFER_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUBufferDescriptor wgpu_zig_init_WGPUBufferDescriptor(void) {
    WGPUBufferDescriptor v = WGPU_BUFFER_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_COLOR_INIT (from webgpu/webgpu.h) */
static inline WGPUColor wgpu_zig_init_WGPUColor(void) {
    WGPUColor v = WGPU_COLOR_INIT;
    return v;
}

/* WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUCommandBufferDescriptor wgpu_zig_init_WGPUCommandBufferDescriptor(void) {
    WGPUCommandBufferDescriptor v = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUCommandEncoderDescriptor wgpu_zig_init_WGPUCommandEncoderDescriptor(void) {
    WGPUCommandEncoderDescriptor v = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_COMPATIBILITY_MODE_LIMITS_INIT (from webgpu/webgpu.h) */
static inline WGPUCompatibilityModeLimits wgpu_zig_init_WGPUCompatibilityModeLimits(void) {
    WGPUCompatibilityModeLimits v = WGPU_COMPATIBILITY_MODE_LIMITS_INIT;
    return v;
}

/* WGPU_COMPILATION_MESSAGE_INIT (from webgpu/webgpu.h) */
static inline WGPUCompilationMessage wgpu_zig_init_WGPUCompilationMessage(void) {
    WGPUCompilationMessage v = WGPU_COMPILATION_MESSAGE_INIT;
    return v;
}

/* WGPU_CONSTANT_ENTRY_INIT (from webgpu/webgpu.h) */
static inline WGPUConstantEntry wgpu_zig_init_WGPUConstantEntry(void) {
    WGPUConstantEntry v = WGPU_CONSTANT_ENTRY_INIT;
    return v;
}

/* WGPU_EXTENT_3D_INIT (from webgpu/webgpu.h) */
static inline WGPUExtent3D wgpu_zig_init_WGPUExtent3D(void) {
    WGPUExtent3D v = WGPU_EXTENT_3D_INIT;
    return v;
}

/* WGPU_EXTERNAL_TEXTURE_BINDING_ENTRY_INIT (from webgpu/webgpu.h) */
static inline WGPUExternalTextureBindingEntry wgpu_zig_init_WGPUExternalTextureBindingEntry(void) {
    WGPUExternalTextureBindingEntry v = WGPU_EXTERNAL_TEXTURE_BINDING_ENTRY_INIT;
    return v;
}

/* WGPU_EXTERNAL_TEXTURE_BINDING_LAYOUT_INIT (from webgpu/webgpu.h) */
static inline WGPUExternalTextureBindingLayout wgpu_zig_init_WGPUExternalTextureBindingLayout(void) {
    WGPUExternalTextureBindingLayout v = WGPU_EXTERNAL_TEXTURE_BINDING_LAYOUT_INIT;
    return v;
}

/* WGPU_FUTURE_INIT (from webgpu/webgpu.h) */
static inline WGPUFuture wgpu_zig_init_WGPUFuture(void) {
    WGPUFuture v = WGPU_FUTURE_INIT;
    return v;
}

/* WGPU_INSTANCE_LIMITS_INIT (from webgpu/webgpu.h) */
static inline WGPUInstanceLimits wgpu_zig_init_WGPUInstanceLimits(void) {
    WGPUInstanceLimits v = WGPU_INSTANCE_LIMITS_INIT;
    return v;
}

/* WGPU_MULTISAMPLE_STATE_INIT (from webgpu/webgpu.h) */
static inline WGPUMultisampleState wgpu_zig_init_WGPUMultisampleState(void) {
    WGPUMultisampleState v = WGPU_MULTISAMPLE_STATE_INIT;
    return v;
}

/* WGPU_ORIGIN_3D_INIT (from webgpu/webgpu.h) */
static inline WGPUOrigin3D wgpu_zig_init_WGPUOrigin3D(void) {
    WGPUOrigin3D v = WGPU_ORIGIN_3D_INIT;
    return v;
}

/* WGPU_PASS_TIMESTAMP_WRITES_INIT (from webgpu/webgpu.h) */
static inline WGPUPassTimestampWrites wgpu_zig_init_WGPUPassTimestampWrites(void) {
    WGPUPassTimestampWrites v = WGPU_PASS_TIMESTAMP_WRITES_INIT;
    return v;
}

/* WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUPipelineLayoutDescriptor wgpu_zig_init_WGPUPipelineLayoutDescriptor(void) {
    WGPUPipelineLayoutDescriptor v = WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_PRIMITIVE_STATE_INIT (from webgpu/webgpu.h) */
static inline WGPUPrimitiveState wgpu_zig_init_WGPUPrimitiveState(void) {
    WGPUPrimitiveState v = WGPU_PRIMITIVE_STATE_INIT;
    return v;
}

/* WGPU_QUERY_SET_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUQuerySetDescriptor wgpu_zig_init_WGPUQuerySetDescriptor(void) {
    WGPUQuerySetDescriptor v = WGPU_QUERY_SET_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_QUEUE_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUQueueDescriptor wgpu_zig_init_WGPUQueueDescriptor(void) {
    WGPUQueueDescriptor v = WGPU_QUEUE_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_RENDER_BUNDLE_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPURenderBundleDescriptor wgpu_zig_init_WGPURenderBundleDescriptor(void) {
    WGPURenderBundleDescriptor v = WGPU_RENDER_BUNDLE_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_RENDER_BUNDLE_ENCODER_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPURenderBundleEncoderDescriptor wgpu_zig_init_WGPURenderBundleEncoderDescriptor(void) {
    WGPURenderBundleEncoderDescriptor v = WGPU_RENDER_BUNDLE_ENCODER_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT (from webgpu/webgpu.h) */
static inline WGPURenderPassDepthStencilAttachment wgpu_zig_init_WGPURenderPassDepthStencilAttachment(void) {
    WGPURenderPassDepthStencilAttachment v = WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
    return v;
}

/* WGPU_RENDER_PASS_MAX_DRAW_COUNT_INIT (from webgpu/webgpu.h) */
static inline WGPURenderPassMaxDrawCount wgpu_zig_init_WGPURenderPassMaxDrawCount(void) {
    WGPURenderPassMaxDrawCount v = WGPU_RENDER_PASS_MAX_DRAW_COUNT_INIT;
    return v;
}

/* WGPU_REQUEST_ADAPTER_WEBXR_OPTIONS_INIT (from webgpu/webgpu.h) */
static inline WGPURequestAdapterWebXROptions wgpu_zig_init_WGPURequestAdapterWebXROptions(void) {
    WGPURequestAdapterWebXROptions v = WGPU_REQUEST_ADAPTER_WEBXR_OPTIONS_INIT;
    return v;
}

/* WGPU_SAMPLER_BINDING_LAYOUT_INIT (from webgpu/webgpu.h) */
static inline WGPUSamplerBindingLayout wgpu_zig_init_WGPUSamplerBindingLayout(void) {
    WGPUSamplerBindingLayout v = WGPU_SAMPLER_BINDING_LAYOUT_INIT;
    return v;
}

/* WGPU_SAMPLER_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUSamplerDescriptor wgpu_zig_init_WGPUSamplerDescriptor(void) {
    WGPUSamplerDescriptor v = WGPU_SAMPLER_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_SHADER_SOURCE_SPIRV_INIT (from webgpu/webgpu.h) */
static inline WGPUShaderSourceSPIRV wgpu_zig_init_WGPUShaderSourceSPIRV(void) {
    WGPUShaderSourceSPIRV v = WGPU_SHADER_SOURCE_SPIRV_INIT;
    return v;
}

/* WGPU_SHADER_SOURCE_WGSL_INIT (from webgpu/webgpu.h) */
static inline WGPUShaderSourceWGSL wgpu_zig_init_WGPUShaderSourceWGSL(void) {
    WGPUShaderSourceWGSL v = WGPU_SHADER_SOURCE_WGSL_INIT;
    return v;
}

/* WGPU_STENCIL_FACE_STATE_INIT (from webgpu/webgpu.h) */
static inline WGPUStencilFaceState wgpu_zig_init_WGPUStencilFaceState(void) {
    WGPUStencilFaceState v = WGPU_STENCIL_FACE_STATE_INIT;
    return v;
}

/* WGPU_STORAGE_TEXTURE_BINDING_LAYOUT_INIT (from webgpu/webgpu.h) */
static inline WGPUStorageTextureBindingLayout wgpu_zig_init_WGPUStorageTextureBindingLayout(void) {
    WGPUStorageTextureBindingLayout v = WGPU_STORAGE_TEXTURE_BINDING_LAYOUT_INIT;
    return v;
}

/* WGPU_SUPPORTED_FEATURES_INIT (from webgpu/webgpu.h) */
static inline WGPUSupportedFeatures wgpu_zig_init_WGPUSupportedFeatures(void) {
    WGPUSupportedFeatures v = WGPU_SUPPORTED_FEATURES_INIT;
    return v;
}

/* WGPU_SUPPORTED_INSTANCE_FEATURES_INIT (from webgpu/webgpu.h) */
static inline WGPUSupportedInstanceFeatures wgpu_zig_init_WGPUSupportedInstanceFeatures(void) {
    WGPUSupportedInstanceFeatures v = WGPU_SUPPORTED_INSTANCE_FEATURES_INIT;
    return v;
}

/* WGPU_SUPPORTED_WGSL_LANGUAGE_FEATURES_INIT (from webgpu/webgpu.h) */
static inline WGPUSupportedWGSLLanguageFeatures wgpu_zig_init_WGPUSupportedWGSLLanguageFeatures(void) {
    WGPUSupportedWGSLLanguageFeatures v = WGPU_SUPPORTED_WGSL_LANGUAGE_FEATURES_INIT;
    return v;
}

/* WGPU_SURFACE_CAPABILITIES_INIT (from webgpu/webgpu.h) */
static inline WGPUSurfaceCapabilities wgpu_zig_init_WGPUSurfaceCapabilities(void) {
    WGPUSurfaceCapabilities v = WGPU_SURFACE_CAPABILITIES_INIT;
    return v;
}

/* WGPU_SURFACE_COLOR_MANAGEMENT_INIT (from webgpu/webgpu.h) */
static inline WGPUSurfaceColorManagement wgpu_zig_init_WGPUSurfaceColorManagement(void) {
    WGPUSurfaceColorManagement v = WGPU_SURFACE_COLOR_MANAGEMENT_INIT;
    return v;
}

/* WGPU_SURFACE_CONFIGURATION_INIT (from webgpu/webgpu.h) */
static inline WGPUSurfaceConfiguration wgpu_zig_init_WGPUSurfaceConfiguration(void) {
    WGPUSurfaceConfiguration v = WGPU_SURFACE_CONFIGURATION_INIT;
    return v;
}

/* WGPU_SURFACE_SOURCE_ANDROID_NATIVE_WINDOW_INIT (from webgpu/webgpu.h) */
static inline WGPUSurfaceSourceAndroidNativeWindow wgpu_zig_init_WGPUSurfaceSourceAndroidNativeWindow(void) {
    WGPUSurfaceSourceAndroidNativeWindow v = WGPU_SURFACE_SOURCE_ANDROID_NATIVE_WINDOW_INIT;
    return v;
}

/* WGPU_SURFACE_SOURCE_METAL_LAYER_INIT (from webgpu/webgpu.h) */
static inline WGPUSurfaceSourceMetalLayer wgpu_zig_init_WGPUSurfaceSourceMetalLayer(void) {
    WGPUSurfaceSourceMetalLayer v = WGPU_SURFACE_SOURCE_METAL_LAYER_INIT;
    return v;
}

/* WGPU_SURFACE_SOURCE_WAYLAND_SURFACE_INIT (from webgpu/webgpu.h) */
static inline WGPUSurfaceSourceWaylandSurface wgpu_zig_init_WGPUSurfaceSourceWaylandSurface(void) {
    WGPUSurfaceSourceWaylandSurface v = WGPU_SURFACE_SOURCE_WAYLAND_SURFACE_INIT;
    return v;
}

/* WGPU_SURFACE_SOURCE_WINDOWS_HWND_INIT (from webgpu/webgpu.h) */
static inline WGPUSurfaceSourceWindowsHWND wgpu_zig_init_WGPUSurfaceSourceWindowsHWND(void) {
    WGPUSurfaceSourceWindowsHWND v = WGPU_SURFACE_SOURCE_WINDOWS_HWND_INIT;
    return v;
}

/* WGPU_SURFACE_SOURCE_XCB_WINDOW_INIT (from webgpu/webgpu.h) */
static inline WGPUSurfaceSourceXCBWindow wgpu_zig_init_WGPUSurfaceSourceXCBWindow(void) {
    WGPUSurfaceSourceXCBWindow v = WGPU_SURFACE_SOURCE_XCB_WINDOW_INIT;
    return v;
}

/* WGPU_SURFACE_SOURCE_XLIB_WINDOW_INIT (from webgpu/webgpu.h) */
static inline WGPUSurfaceSourceXlibWindow wgpu_zig_init_WGPUSurfaceSourceXlibWindow(void) {
    WGPUSurfaceSourceXlibWindow v = WGPU_SURFACE_SOURCE_XLIB_WINDOW_INIT;
    return v;
}

/* WGPU_SURFACE_TEXTURE_INIT (from webgpu/webgpu.h) */
static inline WGPUSurfaceTexture wgpu_zig_init_WGPUSurfaceTexture(void) {
    WGPUSurfaceTexture v = WGPU_SURFACE_TEXTURE_INIT;
    return v;
}

/* WGPU_TEXEL_COPY_BUFFER_LAYOUT_INIT (from webgpu/webgpu.h) */
static inline WGPUTexelCopyBufferLayout wgpu_zig_init_WGPUTexelCopyBufferLayout(void) {
    WGPUTexelCopyBufferLayout v = WGPU_TEXEL_COPY_BUFFER_LAYOUT_INIT;
    return v;
}

/* WGPU_TEXTURE_BINDING_LAYOUT_INIT (from webgpu/webgpu.h) */
static inline WGPUTextureBindingLayout wgpu_zig_init_WGPUTextureBindingLayout(void) {
    WGPUTextureBindingLayout v = WGPU_TEXTURE_BINDING_LAYOUT_INIT;
    return v;
}

/* WGPU_TEXTURE_BINDING_VIEW_DIMENSION_INIT (from webgpu/webgpu.h) */
static inline WGPUTextureBindingViewDimension wgpu_zig_init_WGPUTextureBindingViewDimension(void) {
    WGPUTextureBindingViewDimension v = WGPU_TEXTURE_BINDING_VIEW_DIMENSION_INIT;
    return v;
}

/* WGPU_TEXTURE_COMPONENT_SWIZZLE_INIT (from webgpu/webgpu.h) */
static inline WGPUTextureComponentSwizzle wgpu_zig_init_WGPUTextureComponentSwizzle(void) {
    WGPUTextureComponentSwizzle v = WGPU_TEXTURE_COMPONENT_SWIZZLE_INIT;
    return v;
}

/* WGPU_VERTEX_ATTRIBUTE_INIT (from webgpu/webgpu.h) */
static inline WGPUVertexAttribute wgpu_zig_init_WGPUVertexAttribute(void) {
    WGPUVertexAttribute v = WGPU_VERTEX_ATTRIBUTE_INIT;
    return v;
}

/* WGPU_BIND_GROUP_ENTRY_INIT (from webgpu/webgpu.h) */
static inline WGPUBindGroupEntry wgpu_zig_init_WGPUBindGroupEntry(void) {
    WGPUBindGroupEntry v = WGPU_BIND_GROUP_ENTRY_INIT;
    return v;
}

/* WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT (from webgpu/webgpu.h) */
static inline WGPUBindGroupLayoutEntry wgpu_zig_init_WGPUBindGroupLayoutEntry(void) {
    WGPUBindGroupLayoutEntry v = WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT;
    return v;
}

/* WGPU_BLEND_STATE_INIT (from webgpu/webgpu.h) */
static inline WGPUBlendState wgpu_zig_init_WGPUBlendState(void) {
    WGPUBlendState v = WGPU_BLEND_STATE_INIT;
    return v;
}

/* WGPU_COMPILATION_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPUCompilationInfo wgpu_zig_init_WGPUCompilationInfo(void) {
    WGPUCompilationInfo v = WGPU_COMPILATION_INFO_INIT;
    return v;
}

/* WGPU_COMPUTE_PASS_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUComputePassDescriptor wgpu_zig_init_WGPUComputePassDescriptor(void) {
    WGPUComputePassDescriptor v = WGPU_COMPUTE_PASS_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_COMPUTE_STATE_INIT (from webgpu/webgpu.h) */
static inline WGPUComputeState wgpu_zig_init_WGPUComputeState(void) {
    WGPUComputeState v = WGPU_COMPUTE_STATE_INIT;
    return v;
}

/* WGPU_DEPTH_STENCIL_STATE_INIT (from webgpu/webgpu.h) */
static inline WGPUDepthStencilState wgpu_zig_init_WGPUDepthStencilState(void) {
    WGPUDepthStencilState v = WGPU_DEPTH_STENCIL_STATE_INIT;
    return v;
}

/* WGPU_FUTURE_WAIT_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPUFutureWaitInfo wgpu_zig_init_WGPUFutureWaitInfo(void) {
    WGPUFutureWaitInfo v = WGPU_FUTURE_WAIT_INFO_INIT;
    return v;
}

/* WGPU_INSTANCE_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUInstanceDescriptor wgpu_zig_init_WGPUInstanceDescriptor(void) {
    WGPUInstanceDescriptor v = WGPU_INSTANCE_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_LIMITS_INIT (from webgpu/webgpu.h) */
static inline WGPULimits wgpu_zig_init_WGPULimits(void) {
    WGPULimits v = WGPU_LIMITS_INIT;
    return v;
}

/* WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT (from webgpu/webgpu.h) */
static inline WGPURenderPassColorAttachment wgpu_zig_init_WGPURenderPassColorAttachment(void) {
    WGPURenderPassColorAttachment v = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
    return v;
}

/* WGPU_REQUEST_ADAPTER_OPTIONS_INIT (from webgpu/webgpu.h) */
static inline WGPURequestAdapterOptions wgpu_zig_init_WGPURequestAdapterOptions(void) {
    WGPURequestAdapterOptions v = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
    return v;
}

/* WGPU_SHADER_MODULE_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUShaderModuleDescriptor wgpu_zig_init_WGPUShaderModuleDescriptor(void) {
    WGPUShaderModuleDescriptor v = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_SURFACE_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUSurfaceDescriptor wgpu_zig_init_WGPUSurfaceDescriptor(void) {
    WGPUSurfaceDescriptor v = WGPU_SURFACE_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_TEXEL_COPY_BUFFER_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPUTexelCopyBufferInfo wgpu_zig_init_WGPUTexelCopyBufferInfo(void) {
    WGPUTexelCopyBufferInfo v = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
    return v;
}

/* WGPU_TEXEL_COPY_TEXTURE_INFO_INIT (from webgpu/webgpu.h) */
static inline WGPUTexelCopyTextureInfo wgpu_zig_init_WGPUTexelCopyTextureInfo(void) {
    WGPUTexelCopyTextureInfo v = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
    return v;
}

/* WGPU_TEXTURE_COMPONENT_SWIZZLE_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUTextureComponentSwizzleDescriptor wgpu_zig_init_WGPUTextureComponentSwizzleDescriptor(void) {
    WGPUTextureComponentSwizzleDescriptor v = WGPU_TEXTURE_COMPONENT_SWIZZLE_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_TEXTURE_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUTextureDescriptor wgpu_zig_init_WGPUTextureDescriptor(void) {
    WGPUTextureDescriptor v = WGPU_TEXTURE_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_VERTEX_BUFFER_LAYOUT_INIT (from webgpu/webgpu.h) */
static inline WGPUVertexBufferLayout wgpu_zig_init_WGPUVertexBufferLayout(void) {
    WGPUVertexBufferLayout v = WGPU_VERTEX_BUFFER_LAYOUT_INIT;
    return v;
}

/* WGPU_BIND_GROUP_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUBindGroupDescriptor wgpu_zig_init_WGPUBindGroupDescriptor(void) {
    WGPUBindGroupDescriptor v = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUBindGroupLayoutDescriptor wgpu_zig_init_WGPUBindGroupLayoutDescriptor(void) {
    WGPUBindGroupLayoutDescriptor v = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_COLOR_TARGET_STATE_INIT (from webgpu/webgpu.h) */
static inline WGPUColorTargetState wgpu_zig_init_WGPUColorTargetState(void) {
    WGPUColorTargetState v = WGPU_COLOR_TARGET_STATE_INIT;
    return v;
}

/* WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUComputePipelineDescriptor wgpu_zig_init_WGPUComputePipelineDescriptor(void) {
    WGPUComputePipelineDescriptor v = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_DEVICE_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUDeviceDescriptor wgpu_zig_init_WGPUDeviceDescriptor(void) {
    WGPUDeviceDescriptor v = WGPU_DEVICE_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_RENDER_PASS_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPURenderPassDescriptor wgpu_zig_init_WGPURenderPassDescriptor(void) {
    WGPURenderPassDescriptor v = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPUTextureViewDescriptor wgpu_zig_init_WGPUTextureViewDescriptor(void) {
    WGPUTextureViewDescriptor v = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_VERTEX_STATE_INIT (from webgpu/webgpu.h) */
static inline WGPUVertexState wgpu_zig_init_WGPUVertexState(void) {
    WGPUVertexState v = WGPU_VERTEX_STATE_INIT;
    return v;
}

/* WGPU_FRAGMENT_STATE_INIT (from webgpu/webgpu.h) */
static inline WGPUFragmentState wgpu_zig_init_WGPUFragmentState(void) {
    WGPUFragmentState v = WGPU_FRAGMENT_STATE_INIT;
    return v;
}

/* WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT (from webgpu/webgpu.h) */
static inline WGPURenderPipelineDescriptor wgpu_zig_init_WGPURenderPipelineDescriptor(void) {
    WGPURenderPipelineDescriptor v = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
    return v;
}

/* WGPU_NATIVE_LIMITS_INIT (from webgpu/wgpu.h) */
static inline WGPUNativeLimits wgpu_zig_init_WGPUNativeLimits(void) {
    WGPUNativeLimits v = WGPU_NATIVE_LIMITS_INIT;
    return v;
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* WGPU_ZIG_INIT_SHIMS_H_ */
