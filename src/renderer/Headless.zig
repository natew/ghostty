//! Graphics API wrapper for targets with no GPU. Resources only keep the
//! sizes the generic renderer reads back and every draw call is dropped, so
//! the generic renderer's state (cells, atlases, images) still updates but
//! nothing is rasterized. An embedder that rasterizes itself replaces this.
pub const Headless = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const shadertoy = @import("shadertoy.zig");
const glshaders = @import("opengl/shaders.zig");
const Renderer = rendererpkg.GenericRenderer(Headless);

pub const GraphicsAPI = Headless;

pub const custom_shader_target: shadertoy.Target = .glsl;
pub const custom_shader_y_is_down = false;

/// Nothing is ever in flight, so there is nothing to multi-buffer.
pub const swap_chain_count = 1;

alloc: Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) error{}!Headless {
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
    };
}

pub fn deinit(self: *Headless) void {
    self.* = undefined;
}

/// There is no surface to measure, which makes `drawFrame` return early.
pub fn surfaceSize(self: *const Headless) !struct { width: u32, height: u32 } {
    _ = self;
    return .{ .width = 0, .height = 0 };
}

pub fn drawFrameStart(self: *Headless) void {
    _ = self;
}

pub fn drawFrameEnd(self: *Headless) void {
    _ = self;
}

pub fn initShaders(
    self: *const Headless,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = self;
    _ = alloc;
    _ = custom_shaders;
    return .{};
}

pub fn initTarget(self: *const Headless, width: usize, height: usize) !Target {
    _ = self;
    return .{ .width = width, .height = height };
}

pub fn present(self: *Headless, target: Target) !void {
    _ = self;
    _ = target;
}

pub fn presentLastTarget(self: *Headless) !void {
    _ = self;
}

pub fn gpuResourcesReleased(self: *Headless) void {
    _ = self;
}

pub inline fn beginFrame(
    self: *const Headless,
    renderer: *Renderer,
    target: *Target,
) !Frame {
    _ = self;
    return .{ .renderer = renderer, .target = target };
}

pub const BufferOptions = struct {};

pub inline fn bufferOptions(self: Headless) BufferOptions {
    _ = self;
    return .{};
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

pub inline fn textureOptions(self: Headless) Texture.Options {
    _ = self;
    return .{};
}

pub inline fn samplerOptions(self: Headless) Sampler.Options {
    _ = self;
    return .{};
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    gray,
    rgba,
    bgra,
};

pub inline fn imageTextureOptions(
    self: Headless,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    _ = format;
    _ = srgb;
    return .{};
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const Headless,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    return try Texture.init(.{}, atlas.size, atlas.size, null);
}

pub const BufferHandle = struct {};

/// Storage for a certain set of equal types. Only the capacity is tracked.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: BufferHandle = .{},
        opts: BufferOptions,

        /// Current capacity in `T`s.
        len: usize,

        pub fn init(opts: BufferOptions, len: usize) !Self {
            return .{ .opts = opts, .len = len };
        }

        pub fn initFill(opts: BufferOptions, data: []const T) !Self {
            return .{ .opts = opts, .len = data.len * @sizeOf(T) };
        }

        pub fn deinit(self: Self) void {
            _ = self;
        }

        pub fn sync(self: *Self, data: []const T) !void {
            if (data.len > self.len) self.len = data.len * 2;
        }

        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total_len: usize = 0;
            for (lists) |list| total_len += list.items.len;
            if (total_len > self.len) self.len = total_len * 2;
            return total_len;
        }
    };
}

pub const Target = struct {
    width: usize,
    height: usize,

    pub fn deinit(self: *Target) void {
        _ = self;
    }
};

pub const Texture = struct {
    pub const Options = struct {};
    pub const Error = error{};

    width: usize,
    height: usize,

    pub fn init(opts: Options, width: usize, height: usize, data: ?[]const u8) Error!Texture {
        _ = opts;
        _ = data;
        return .{ .width = width, .height = height };
    }

    pub fn deinit(self: Texture) void {
        _ = self;
    }

    pub fn replaceRegion(
        self: Texture,
        x: usize,
        y: usize,
        width: usize,
        height: usize,
        data: []const u8,
    ) Error!void {
        _ = self;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        _ = data;
    }
};

pub const Sampler = struct {
    pub const Options = struct {};
    pub const Error = error{};

    pub fn init(opts: Options) Error!Sampler {
        _ = opts;
        return .{};
    }

    pub fn deinit(self: Sampler) void {
        _ = self;
    }
};

pub const Pipeline = struct {
    pub fn deinit(self: Pipeline) void {
        _ = self;
    }
};

pub const RenderPass = struct {
    pub const Options = struct {
        attachments: []const Attachment,

        pub const Attachment = struct {
            target: union(enum) {
                texture: Texture,
                target: Target,
            },
            clear_color: ?[4]f32 = null,
        };
    };

    pub const Step = struct {
        pipeline: Pipeline,
        uniforms: ?BufferHandle = null,
        buffers: []const ?BufferHandle = &.{},
        textures: []const ?Texture = &.{},
        samplers: []const ?Sampler = &.{},
        draw: Draw,

        pub const Draw = struct {
            type: Primitive,
            vertex_count: usize,
            instance_count: usize = 1,
        };

        pub const Primitive = enum { triangle, triangle_strip };
    };

    pub fn begin(opts: Options) RenderPass {
        _ = opts;
        return .{};
    }

    pub fn step(self: *RenderPass, s: Step) void {
        _ = self;
        _ = s;
    }

    pub fn complete(self: *const RenderPass) void {
        _ = self;
    }
};

pub const Frame = struct {
    renderer: *Renderer,
    target: *Target,

    pub inline fn renderPass(
        self: *const Frame,
        attachments: []const RenderPass.Options.Attachment,
    ) RenderPass {
        _ = self;
        return RenderPass.begin(.{ .attachments = attachments });
    }

    pub fn complete(self: *const Frame, sync: bool) void {
        _ = sync;
        self.renderer.frameCompleted(.healthy);
    }
};

pub const shaders = struct {
    pub const Uniforms = glshaders.Uniforms;
    pub const CellText = glshaders.CellText;
    pub const CellBg = glshaders.CellBg;
    pub const Image = glshaders.Image;
    pub const BgImage = glshaders.BgImage;

    pub const Shaders = struct {
        pipelines: struct {
            bg_color: Pipeline = .{},
            cell_bg: Pipeline = .{},
            cell_text: Pipeline = .{},
            image: Pipeline = .{},
            bg_image: Pipeline = .{},
        } = .{},

        post_pipelines: []const Pipeline = &.{},

        /// Set to true when deinited, deiniting twice is ignored.
        defunct: bool = false,

        pub fn deinit(self: *Shaders, alloc: Allocator) void {
            _ = alloc;
            self.defunct = true;
        }
    };
};
