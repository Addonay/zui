//! Verification example: run a WGSL compute shader through wgpu-native and
//! check the readback on the CPU.
//!
//! Run with: zig build run-compute
//!
//! Exercises: instance creation, adapter selection and reporting, device
//! creation, error scopes, compute pipeline creation, GPU buffer upload,
//! dispatch, buffer readback via map-async, and full resource cleanup.

const std = @import("std");
const wgpu = @import("wgpu");
const c = wgpu.c;
const common = @import("common.zig");

const input_data = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
const expected = [_]u32{ 3, 5, 7, 9, 11, 13, 15, 17 };
const workgroup_size = 4;
const workgroup_count = (input_data.len + workgroup_size - 1) / workgroup_size;

const compute_wgsl =
    \\@group(0) @binding(0) var<storage, read> input: array<u32>;
    \\@group(0) @binding(1) var<storage, read_write> output: array<u32>;
    \\
    \\@compute @workgroup_size(4)
    \\fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    \\    output[gid.x] = input[gid.x] * 2u + 1u;
    \\}
;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var force_adapter_failure = false;
    var force_fallback_adapter = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--force-adapter-failure")) force_adapter_failure = true;
        if (std.mem.eql(u8, arg, "--force-fallback-adapter")) force_fallback_adapter = true;
    }

    common.installLogging(c.WGPULogLevel_Warn);

    // Registered before the first resource, so it runs after every deferred
    // release and reports that the failure path cleaned up.
    defer std.debug.print("cleanup: all handles released\n", .{});

    const instance = c.wgpuCreateInstance(null) orelse {
        std.debug.print("FAIL: wgpuCreateInstance returned null\n", .{});
        return error.NoInstance;
    };
    defer c.wgpuInstanceRelease(instance);

    // ------------------------------------------------------------- adapter
    var adapter_query = common.AdapterQuery{};
    var adapter_options = c.wgpu_zig_init_WGPURequestAdapterOptions();
    adapter_options.powerPreference = c.WGPUPowerPreference_HighPerformance;
    if (force_adapter_failure) {
        // `WGPUBackendType_Null` asks wgpu-native for an empty backend set,
        // which deterministically fails adapter selection. Used by
        // `zig build check-failure` to exercise the initialization-failure
        // cleanup path.
        adapter_options.backendType = c.WGPUBackendType_Null;
    }
    if (force_fallback_adapter) {
        // Selects the implementation's fallback adapter, typically a CPU
        // rasterizer such as llvmpipe/lavapipe. Used to demonstrate the
        // hardware vs software distinction.
        adapter_options.forceFallbackAdapter = 1;
    }
    _ = c.wgpuInstanceRequestAdapter(instance, &adapter_options, .{
        .callback = &common.AdapterQuery.onCallback,
        .userdata1 = &adapter_query,
    });
    const adapter = adapter_query.adapter orelse {
        std.debug.print("FAIL: no compatible adapter found\n", .{});
        return error.NoAdapter;
    };
    defer c.wgpuAdapterRelease(adapter);

    var adapter_info = c.wgpu_zig_init_WGPUAdapterInfo();
    if (c.wgpuAdapterGetInfo(adapter, &adapter_info) != c.WGPUStatus_Success) {
        std.debug.print("FAIL: wgpuAdapterGetInfo failed\n", .{});
        return error.AdapterInfoFailed;
    }
    defer c.wgpuAdapterInfoFreeMembers(adapter_info);
    common.printAdapterInfo(&adapter_info);

    // -------------------------------------------------------------- device
    var errors = common.ErrorTracker{};
    var device_desc = c.wgpu_zig_init_WGPUDeviceDescriptor();
    device_desc.label = wgpu.stringView("compute-device");
    device_desc.uncapturedErrorCallbackInfo = .{
        .callback = &common.ErrorTracker.onUncaptured,
        .userdata1 = &errors,
    };
    var device_query = common.DeviceQuery{};
    _ = c.wgpuAdapterRequestDevice(adapter, &device_desc, .{
        .callback = &common.DeviceQuery.onCallback,
        .userdata1 = &device_query,
    });
    const device = device_query.device orelse {
        std.debug.print("FAIL: device request failed\n", .{});
        return error.NoDevice;
    };
    defer c.wgpuDeviceRelease(device);

    const queue = c.wgpuDeviceGetQueue(device) orelse {
        std.debug.print("FAIL: wgpuDeviceGetQueue returned null\n", .{});
        return error.NoQueue;
    };
    defer c.wgpuQueueRelease(queue);

    // ---------------------------------------------------- error reporting
    // A buffer with `MapRead | Storage` is invalid WebGPU. The validation
    // error must be captured by the error scope and must NOT reach the
    // uncaptured-error callback, which is checked at the end.
    c.wgpuDevicePushErrorScope(device, c.WGPUErrorFilter_Validation);
    var invalid_desc = c.wgpu_zig_init_WGPUBufferDescriptor();
    invalid_desc.label = wgpu.stringView("invalid buffer");
    invalid_desc.size = 16;
    invalid_desc.usage = c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_Storage;
    const invalid_buffer = c.wgpuDeviceCreateBuffer(device, &invalid_desc);
    if (invalid_buffer != null) c.wgpuBufferRelease(invalid_buffer);

    var scope = common.ErrorScopeResult{};
    _ = c.wgpuDevicePopErrorScope(device, .{
        .callback = &common.ErrorScopeResult.onPop,
        .userdata1 = &scope,
    });
    if (scope.status != c.WGPUPopErrorScopeStatus_Success or
        scope.error_type != c.WGPUErrorType_Validation)
    {
        std.debug.print("FAIL: error scope did not capture validation error (status={d} type={d})\n", .{
            scope.status, scope.error_type,
        });
        return error.ErrorScopeFailed;
    }
    std.debug.print("error scope captured validation error: \"{s}\"\n", .{scope.messageSliceOf()});

    // -------------------------------------------------------- compute work
    const size: u64 = @sizeOf(@TypeOf(input_data));

    const storage_usage = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopySrc | c.WGPUBufferUsage_CopyDst;
    var input_desc = c.wgpu_zig_init_WGPUBufferDescriptor();
    input_desc.label = wgpu.stringView("compute-input");
    input_desc.size = size;
    input_desc.usage = storage_usage;
    const input_buffer = c.wgpuDeviceCreateBuffer(device, &input_desc) orelse {
        std.debug.print("FAIL: input buffer creation failed\n", .{});
        return error.BufferCreationFailed;
    };
    defer c.wgpuBufferRelease(input_buffer);

    var output_desc = c.wgpu_zig_init_WGPUBufferDescriptor();
    output_desc.label = wgpu.stringView("compute-output");
    output_desc.size = size;
    output_desc.usage = storage_usage;
    const output_buffer = c.wgpuDeviceCreateBuffer(device, &output_desc) orelse {
        std.debug.print("FAIL: output buffer creation failed\n", .{});
        return error.BufferCreationFailed;
    };
    defer c.wgpuBufferRelease(output_buffer);

    var staging_desc = c.wgpu_zig_init_WGPUBufferDescriptor();
    staging_desc.label = wgpu.stringView("compute-readback");
    staging_desc.size = size;
    staging_desc.usage = c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst;
    const staging_buffer = c.wgpuDeviceCreateBuffer(device, &staging_desc) orelse {
        std.debug.print("FAIL: staging buffer creation failed\n", .{});
        return error.BufferCreationFailed;
    };
    defer c.wgpuBufferRelease(staging_buffer);

    const shader = createShader(device, compute_wgsl) orelse {
        std.debug.print("FAIL: shader module creation failed\n", .{});
        return error.ShaderCreationFailed;
    };
    defer c.wgpuShaderModuleRelease(shader);

    var pipeline_desc = c.wgpu_zig_init_WGPUComputePipelineDescriptor();
    pipeline_desc.label = wgpu.stringView("double-and-add");
    pipeline_desc.layout = null; // automatic pipeline layout
    pipeline_desc.compute = .{
        .module = shader,
        .entryPoint = wgpu.stringView("main"),
    };
    const pipeline = c.wgpuDeviceCreateComputePipeline(device, &pipeline_desc) orelse {
        std.debug.print("FAIL: compute pipeline creation failed\n", .{});
        return error.PipelineCreationFailed;
    };
    defer c.wgpuComputePipelineRelease(pipeline);

    const bind_group_layout = c.wgpuComputePipelineGetBindGroupLayout(pipeline, 0) orelse {
        std.debug.print("FAIL: bind group layout unavailable\n", .{});
        return error.BindGroupLayoutFailed;
    };
    defer c.wgpuBindGroupLayoutRelease(bind_group_layout);

    var entries = [_]c.WGPUBindGroupEntry{
        c.wgpu_zig_init_WGPUBindGroupEntry(),
        c.wgpu_zig_init_WGPUBindGroupEntry(),
    };
    entries[0].binding = 0;
    entries[0].buffer = input_buffer;
    entries[0].offset = 0;
    entries[0].size = size;
    entries[1].binding = 1;
    entries[1].buffer = output_buffer;
    entries[1].offset = 0;
    entries[1].size = size;

    var bind_group_desc = c.wgpu_zig_init_WGPUBindGroupDescriptor();
    bind_group_desc.label = wgpu.stringView("compute-bind-group");
    bind_group_desc.layout = bind_group_layout;
    bind_group_desc.entryCount = entries.len;
    bind_group_desc.entries = &entries;
    const bind_group = c.wgpuDeviceCreateBindGroup(device, &bind_group_desc) orelse {
        std.debug.print("FAIL: bind group creation failed\n", .{});
        return error.BindGroupFailed;
    };
    defer c.wgpuBindGroupRelease(bind_group);

    var encoder_desc = c.wgpu_zig_init_WGPUCommandEncoderDescriptor();
    encoder_desc.label = wgpu.stringView("compute-encoder");
    const encoder = c.wgpuDeviceCreateCommandEncoder(device, &encoder_desc) orelse {
        std.debug.print("FAIL: command encoder creation failed\n", .{});
        return error.EncoderFailed;
    };
    defer c.wgpuCommandEncoderRelease(encoder);

    var pass_desc = c.wgpu_zig_init_WGPUComputePassDescriptor();
    pass_desc.label = wgpu.stringView("compute-pass");
    const pass = c.wgpuCommandEncoderBeginComputePass(encoder, &pass_desc) orelse {
        std.debug.print("FAIL: compute pass creation failed\n", .{});
        return error.ComputePassFailed;
    };
    c.wgpuComputePassEncoderSetPipeline(pass, pipeline);
    c.wgpuComputePassEncoderSetBindGroup(pass, 0, bind_group, 0, null);
    c.wgpuComputePassEncoderDispatchWorkgroups(pass, workgroup_count, 1, 1);
    c.wgpuComputePassEncoderEnd(pass);
    c.wgpuComputePassEncoderRelease(pass);

    c.wgpuCommandEncoderCopyBufferToBuffer(encoder, output_buffer, 0, staging_buffer, 0, size);

    var command_buffer_desc = c.wgpu_zig_init_WGPUCommandBufferDescriptor();
    command_buffer_desc.label = wgpu.stringView("compute-commands");
    const command_buffer = c.wgpuCommandEncoderFinish(encoder, &command_buffer_desc) orelse {
        std.debug.print("FAIL: command buffer creation failed\n", .{});
        return error.CommandBufferFailed;
    };
    defer c.wgpuCommandBufferRelease(command_buffer);

    c.wgpuQueueWriteBuffer(queue, input_buffer, 0, &input_data, @sizeOf(@TypeOf(input_data)));
    c.wgpuQueueSubmit(queue, 1, &command_buffer);

    // -------------------------------------------------------- map readback
    var map_state = common.MapState{};
    _ = c.wgpuBufferMapAsync(staging_buffer, c.WGPUMapMode_Read, 0, size, .{
        .callback = &common.MapState.onCallback,
        .userdata1 = &map_state,
    });
    // Callbacks are driven by polling in this revision; wait=true blocks until
    // the submitted work and the map callback have completed.
    _ = c.wgpuDevicePoll(device, 1, null);
    if (!map_state.ok) {
        std.debug.print("FAIL: staging buffer map failed\n", .{});
        return error.MapFailed;
    }

    const mapped = c.wgpuBufferGetMappedRange(staging_buffer, 0, size) orelse {
        std.debug.print("FAIL: wgpuBufferGetMappedRange returned null\n", .{});
        return error.MappedRangeFailed;
    };
    const results: [*]const u32 = @ptrCast(@alignCast(mapped));
    const actual = results[0..input_data.len];

    std.debug.print("compute output: {any}\n", .{actual});
    for (actual, expected, 0..) |got, want, index| {
        if (got != want) {
            std.debug.print("FAIL: index {d}: expected {d}, got {d}\n", .{ index, want, got });
            c.wgpuBufferUnmap(staging_buffer);
            return error.ComputeMismatch;
        }
    }
    c.wgpuBufferUnmap(staging_buffer);

    // -------------------------------------------------------- final checks
    _ = c.wgpuDevicePoll(device, 1, null);
    if (errors.count != 0) {
        std.debug.print("FAIL: {d} uncaptured device error(s); last type={d} message=\"{s}\"\n", .{
            errors.count, errors.last_type, errors.last(),
        });
        return error.UncapturedDeviceError;
    }

    std.debug.print("PASS: compute result verified against expected values\n", .{});
}

fn createShader(device: c.WGPUDevice, code: []const u8) c.WGPUShaderModule {
    var source = c.wgpu_zig_init_WGPUShaderSourceWGSL();
    source.chain.sType = c.WGPUSType_ShaderSourceWGSL;
    source.code = wgpu.stringView(code);

    var desc = c.wgpu_zig_init_WGPUShaderModuleDescriptor();
    desc.label = wgpu.stringView("compute-shader");
    desc.nextInChain = &source.chain;
    return c.wgpuDeviceCreateShaderModule(device, &desc);
}
