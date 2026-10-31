//! Graphics API for wasm32-wasi under Peach, which has no GPU. Each render
//! pass step runs its Metal pipeline (`shaders/shaders.metal`) on the CPU into
//! an 8-bit RGBA target stored as Metal stores it (sRGB encoded when blending
//! is linear), and `present` hands the target to a sublayer of the
//! embedder's UIView through the Peach hosted layer C API, as Metal presents
//! an IOSurface into a sublayer of the view on iOS.
//!
//! Colors keep their sRGB primaries. Metal converts sRGB colors to Display P3
//! for its P3 layer and the compositor converts them back, so the composited
//! pixels are the sRGB colors this renderer writes directly.
pub const Raster = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const shadertoy = @import("shadertoy.zig");
const glshaders = @import("opengl/shaders.zig");
const Renderer = rendererpkg.GenericRenderer(Raster);

/// Creates a layer for `view`'s content and adds it as a sublayer of the
/// view's layer, clipping the view to its bounds.
extern fn peach_hosted_layer_create(view: *anyopaque, contents_scale: f64) *anyopaque;
/// The layer's bounds times its contents scale, in whole pixels.
extern fn peach_hosted_layer_pixel_size(layer: *anyopaque, width: *u32, height: *u32) void;
/// Sets the layer's contents to premultiplied 8-bit RGBA pixels in sRGB.
extern fn peach_hosted_layer_present(layer: *anyopaque, rgba: [*]const u8, width: u32, height: u32) void;
extern fn peach_hosted_layer_release(layer: *anyopaque) void;

pub const GraphicsAPI = Raster;

pub const custom_shader_target: shadertoy.Target = .glsl;
pub const custom_shader_y_is_down = false;

/// Each step completes before `step` returns, so one target is enough.
pub const swap_chain_count = 1;

alloc: Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The hosted layer the surface presents into.
layer: *anyopaque,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) error{}!Raster {
    const scale: f64 = @floatCast(opts.rt_surface.content_scale.x);
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .layer = peach_hosted_layer_create(opts.rt_surface.platform.ios.uiview, scale),
    };
}

pub fn deinit(self: *Raster) void {
    peach_hosted_layer_release(self.layer);
    self.* = undefined;
}

pub fn surfaceSize(self: *const Raster) !struct { width: u32, height: u32 } {
    var width: u32 = 0;
    var height: u32 = 0;
    peach_hosted_layer_pixel_size(self.layer, &width, &height);
    return .{ .width = width, .height = height };
}

pub fn drawFrameStart(self: *Raster) void {
    _ = self;
}

pub fn drawFrameEnd(self: *Raster) void {
    _ = self;
}

pub fn initShaders(
    self: *const Raster,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    // custom shaders compile through glslang, which does not build on wasi
    if (custom_shaders.len > 0) return error.CustomShadersUnsupported;
    return .{ .linear = self.blending.isLinear() };
}

pub fn initTarget(self: *const Raster, width: usize, height: usize) !Target {
    return .{
        .alloc = self.alloc,
        .width = width,
        .height = height,
        .pixels = try self.alloc.alloc(u8, width * height * 4),
    };
}

pub fn present(self: *Raster, target: Target) !void {
    // linear blending stores sRGB encoded bytes and native blending stores
    // the shader output as is; either way the bytes are the displayed colors
    peach_hosted_layer_present(
        self.layer,
        target.pixels.ptr,
        @intCast(target.width),
        @intCast(target.height),
    );
}

/// The layer keeps its contents, so there is nothing to present again.
pub fn presentLastTarget(self: *Raster) !void {
    _ = self;
}

pub fn gpuResourcesReleased(self: *Raster) void {
    _ = self;
}

pub inline fn beginFrame(
    self: *Raster,
    renderer: *Renderer,
    target: *Target,
) !Frame {
    return .{ .api = self, .renderer = renderer, .target = target };
}

pub const BufferOptions = struct {
    alloc: Allocator,
};

pub inline fn bufferOptions(self: Raster) BufferOptions {
    return .{ .alloc = self.alloc };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

pub inline fn textureOptions(self: Raster) Texture.Options {
    return .{ .alloc = self.alloc, .format = .rgba, .srgb = self.blending.isLinear() };
}

pub inline fn samplerOptions(self: Raster) Sampler.Options {
    _ = self;
    return .{};
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = Texture.Format;

pub inline fn imageTextureOptions(
    self: Raster,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{ .alloc = self.alloc, .format = format, .srgb = srgb };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const Raster,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const opts: Texture.Options = switch (atlas.format) {
        .grayscale => .{ .alloc = self.alloc, .format = .gray, .srgb = false },
        .bgra => .{ .alloc = self.alloc, .format = .bgra, .srgb = true },
        else => @panic("unsupported atlas format for the raster renderer"),
    };
    return try Texture.init(opts, atlas.size, atlas.size, null);
}

/// The bytes of a buffer as the shaders read them.
pub const BufferHandle = struct {
    ptr: ?*const anyopaque = null,
    len: usize = 0,

    fn items(self: BufferHandle, comptime T: type) []const T {
        const ptr: [*]const T = @ptrCast(@alignCast(self.ptr orelse return &.{}));
        return ptr[0..self.len];
    }
};

/// Storage for a certain set of equal types.
pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: BufferHandle = .{},
        opts: BufferOptions,
        storage: []T,

        /// Current capacity in `T`s.
        len: usize,

        pub fn init(opts: BufferOptions, len: usize) !Self {
            const storage = try opts.alloc.alloc(T, len);
            return .{
                .opts = opts,
                .storage = storage,
                .len = len,
                .buffer = .{ .ptr = storage.ptr, .len = len },
            };
        }

        pub fn initFill(opts: BufferOptions, data: []const T) !Self {
            var self = try Self.init(opts, data.len);
            @memcpy(self.storage, data);
            self.buffer.len = data.len;
            return self;
        }

        pub fn deinit(self: *const Self) void {
            self.opts.alloc.free(self.storage);
        }

        fn ensure(self: *Self, len: usize) !void {
            if (len <= self.len) return;
            // grow to double the needed size, as the GPU buffers do
            self.storage = try self.opts.alloc.realloc(self.storage, len * 2);
            self.len = self.storage.len;
        }

        pub fn sync(self: *Self, data: []const T) !void {
            try self.ensure(data.len);
            @memcpy(self.storage[0..data.len], data);
            self.buffer = .{ .ptr = self.storage.ptr, .len = data.len };
        }

        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total_len: usize = 0;
            for (lists) |list| total_len += list.items.len;
            try self.ensure(total_len);
            var i: usize = 0;
            for (lists) |list| {
                @memcpy(self.storage[i..][0..list.items.len], list.items);
                i += list.items.len;
            }
            self.buffer = .{ .ptr = self.storage.ptr, .len = total_len };
            return total_len;
        }
    };
}

pub const Target = struct {
    alloc: Allocator,
    width: usize,
    height: usize,

    /// Premultiplied RGBA, 8 bits per channel, top row first.
    pixels: []u8,

    pub fn deinit(self: *Target) void {
        self.alloc.free(self.pixels);
    }
};

pub const Texture = struct {
    pub const Format = enum {
        /// 1 byte per pixel grayscale.
        gray,
        /// 4 bytes per pixel RGBA.
        rgba,
        /// 4 bytes per pixel BGRA.
        bgra,

        fn depth(self: Format) usize {
            return switch (self) {
                .gray => 1,
                .rgba, .bgra => 4,
            };
        }
    };

    pub const Options = struct {
        alloc: Allocator,
        format: Format,
        /// Sampling decodes the color channels from sRGB to linear.
        srgb: bool,
    };

    pub const Error = Allocator.Error;

    opts: Options,
    width: usize,
    height: usize,
    data: []u8,

    pub fn init(opts: Options, width: usize, height: usize, data: ?[]const u8) Error!Texture {
        const bytes = try opts.alloc.alloc(u8, width * height * opts.format.depth());
        if (data) |d| @memcpy(bytes, d[0..bytes.len]) else @memset(bytes, 0);
        return .{ .opts = opts, .width = width, .height = height, .data = bytes };
    }

    pub fn deinit(self: Texture) void {
        self.opts.alloc.free(self.data);
    }

    pub fn replaceRegion(
        self: Texture,
        x: usize,
        y: usize,
        width: usize,
        height: usize,
        data: []const u8,
    ) Error!void {
        const depth = self.opts.format.depth();
        const row = width * depth;
        for (0..height) |r| {
            const at = ((y + r) * self.width + x) * depth;
            @memcpy(self.data[at..][0..row], data[r * row ..][0..row]);
        }
    }

    /// The texel at whole coordinates as RGBA in 0...1, sRGB decoded when
    /// the format is sRGB. Grayscale reads as its red channel.
    fn texel(self: Texture, x: usize, y: usize) Color {
        const depth = self.opts.format.depth();
        const p = self.data[(y * self.width + x) * depth ..][0..depth];
        const raw: Color = switch (self.opts.format) {
            .gray => .{ unorm(p[0]), 0, 0, 1 },
            .rgba => .{ unorm(p[0]), unorm(p[1]), unorm(p[2]), unorm(p[3]) },
            .bgra => .{ unorm(p[2]), unorm(p[1]), unorm(p[0]), unorm(p[3]) },
        };
        if (!self.opts.srgb) return raw;
        return .{ linearize(raw[0]), linearize(raw[1]), linearize(raw[2]), raw[3] };
    }

    /// A nearest sample at pixel coordinates, clamped to the edge.
    fn nearest(self: Texture, coord: [2]f32) Color {
        return self.texel(clampIndex(@floor(coord[0]), self.width), clampIndex(@floor(coord[1]), self.height));
    }

    /// A linear sample at pixel coordinates. Outside texels are the edge
    /// texel when `zero` is false and transparent black when it is true.
    fn linear(self: Texture, coord: [2]f32, zero: bool) Color {
        const x = coord[0] - 0.5;
        const y = coord[1] - 0.5;
        const x0 = @floor(x);
        const y0 = @floor(y);
        const fx = x - x0;
        const fy = y - y0;
        const a = self.tap(x0, y0, zero);
        const b = self.tap(x0 + 1, y0, zero);
        const c = self.tap(x0, y0 + 1, zero);
        const d = self.tap(x0 + 1, y0 + 1, zero);
        const top = a + (b - a) * splat(fx);
        const bottom = c + (d - c) * splat(fx);
        return top + (bottom - top) * splat(fy);
    }

    fn tap(self: Texture, x: f32, y: f32, zero: bool) Color {
        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);
        if (zero and (x < 0 or y < 0 or x >= w or y >= h)) return @splat(0);
        return self.texel(clampIndex(x, self.width), clampIndex(y, self.height));
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
    program: Program,

    pub const Program = enum { bg_color, bg_image, cell_bg, cell_text, image };

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

    linear: bool,
    target: Target,

    /// The uniforms bound by the last step that bound any, which later steps
    /// keep reading as the GPU keeps its bindings.
    uniforms: ?*const Uniforms = null,

    pub fn begin(linear_: bool, opts: Options) RenderPass {
        const attachment = opts.attachments[0];
        const target = switch (attachment.target) {
            .target => |t| t,
            // only custom shaders render to textures, and they do not build on wasi
            .texture => unreachable,
        };
        const self: RenderPass = .{ .linear = linear_, .target = target };
        if (attachment.clear_color) |c| {
            const bytes = self.store(.{ c[0], c[1], c[2], c[3] });
            var i: usize = 0;
            while (i < target.pixels.len) : (i += 4) @memcpy(target.pixels[i..][0..4], &bytes);
        }
        return self;
    }

    pub fn step(self: *RenderPass, s: Step) void {
        if (s.uniforms) |u| self.uniforms = &u.items(Uniforms)[0];
        const u = self.uniforms.?;
        switch (s.pipeline.program) {
            .bg_color => self.bgColor(u),
            .bg_image => self.bgImage(u, s.buffers[0].?.items(BgImage)[0], s.textures[0].?),
            .cell_bg => self.cellBg(u, s.buffers[1].?.items(CellBg)),
            .cell_text => self.cellText(
                u,
                s.buffers[0].?.items(CellText)[0..s.draw.instance_count],
                s.buffers[1].?.items(CellBg),
                s.textures[0].?,
                s.textures[1].?,
            ),
            .image => for (s.buffers[0].?.items(Image)) |in| self.image(u, in, s.textures[0].?),
        }
    }

    pub fn complete(self: *const RenderPass) void {
        _ = self;
    }

    fn pixel(self: *const RenderPass, x: usize, y: usize) *[4]u8 {
        return self.target.pixels[(y * self.target.width + x) * 4 ..][0..4];
    }

    /// The color a pixel holds, as a blend reads it.
    fn load(self: *const RenderPass, p: [4]u8) Color {
        const c: Color = .{ unorm(p[0]), unorm(p[1]), unorm(p[2]), unorm(p[3]) };
        if (!self.linear) return c;
        return .{ linearize(c[0]), linearize(c[1]), linearize(c[2]), c[3] };
    }

    /// A fragment color as the target stores it: sRGB encoded for a linear
    /// target, then rounded to 8 bits.
    fn store(self: *const RenderPass, c: Color) [4]u8 {
        const e: Color = if (self.linear)
            .{ unlinearize(c[0]), unlinearize(c[1]), unlinearize(c[2]), c[3] }
        else
            c;
        var out: [4]u8 = undefined;
        inline for (0..4) |i| out[i] = @intFromFloat(@round(std.math.clamp(e[i], 0, 1) * 255));
        return out;
    }

    /// Premultiplied source over: src + dst * (1 - src.a).
    fn blend(self: *const RenderPass, x: usize, y: usize, src: Color) void {
        if (src[3] == 0 and src[0] == 0 and src[1] == 0 and src[2] == 0) return;
        const p = self.pixel(x, y);
        p.* = self.store(src + self.load(p.*) * splat(1 - src[3]));
    }

    fn bgColor(self: *const RenderPass, u: *const Uniforms) void {
        const bytes = self.store(loadColor(u.bg_color, u.bools.use_display_p3, u.bools.use_linear_blending));
        var i: usize = 0;
        while (i < self.target.pixels.len) : (i += 4) @memcpy(self.target.pixels[i..][0..4], &bytes);
    }

    fn cellBg(self: *const RenderPass, u: *const Uniforms, cells: []const CellBg) void {
        const cols: i32 = u.grid_size[0];
        const rows: i32 = u.grid_size[1];
        if (cols == 0 or rows == 0) return;
        for (0..self.target.height) |y| {
            const row = gridIndex(center(y), u.grid_padding[0], u.cell_size[1], rows, u.padding_extend.up, u.padding_extend.down) orelse continue;
            for (0..self.target.width) |x| {
                const col = gridIndex(center(x), u.grid_padding[3], u.cell_size[0], cols, u.padding_extend.left, u.padding_extend.right) orelse continue;
                const cell = cells[@intCast(row * cols + col)];
                self.blend(x, y, loadColor(cell, u.bools.use_display_p3, u.bools.use_linear_blending));
            }
        }
    }

    fn cellText(
        self: *const RenderPass,
        u: *const Uniforms,
        cells: []const CellText,
        bg_cells: []const CellBg,
        grayscale: Texture,
        color_atlas: Texture,
    ) void {
        const p3 = u.bools.use_display_p3;
        const global_bg = loadColor(u.bg_color, p3, true);
        for (cells) |cell| {
            // cell_text_vertex
            const gx: f32 = @floatFromInt(cell.grid_pos[0]);
            const gy: f32 = @floatFromInt(cell.grid_pos[1]);
            const size: [2]f32 = .{ @floatFromInt(cell.glyph_size[0]), @floatFromInt(cell.glyph_size[1]) };
            const origin: [2]f32 = .{
                u.cell_size[0] * gx + @as(f32, @floatFromInt(cell.bearings[0])),
                u.cell_size[1] * gy + u.cell_size[1] - @as(f32, @floatFromInt(cell.bearings[1])),
            };
            var color = loadColor(cell.color, p3, true);
            const cell_bg = bg_cells[@as(usize, cell.grid_pos[1]) * u.grid_size[0] + cell.grid_pos[0]];
            var bg = loadColor(cell_bg, p3, true);
            bg += global_bg * splat(1 - bg[3]);
            if (u.min_contrast > 1 and !cell.bools.no_min_contrast) color = contrastedColor(u.min_contrast, color, bg);
            const is_cursor_pos = (cell.grid_pos[0] == u.cursor_pos[0] or
                (u.bools.cursor_wide and cell.grid_pos[0] == u.cursor_pos[0] + 1)) and
                cell.grid_pos[1] == u.cursor_pos[1];
            if (!cell.bools.is_cursor_glyph and is_cursor_pos) color = loadColor(u.cursor_color, p3, true);

            const glyph: [2]f32 = .{ @floatFromInt(cell.glyph_pos[0]), @floatFromInt(cell.glyph_pos[1]) };
            const quad = self.rasterRect(u, origin, .{ origin[0] + size[0], origin[1] + size[1] }) orelse continue;
            for (quad.y0..quad.y1) |y| for (quad.x0..quad.x1) |x| {
                // tex_coord interpolates across the quad from glyph_pos to glyph_pos + glyph_size
                const coord: [2]f32 = .{
                    glyph[0] + (center(x) - quad.fx0) / (quad.fx1 - quad.fx0) * size[0],
                    glyph[1] + (center(y) - quad.fy0) / (quad.fy1 - quad.fy0) * size[1],
                };
                // cell_text_fragment
                const out: Color = switch (cell.atlas) {
                    .grayscale => gray: {
                        var c = color;
                        if (!u.bools.use_linear_blending) c = unlinearizePremultiplied(c);
                        var a = grayscale.nearest(coord)[0];
                        if (u.bools.use_linear_correction) {
                            const fg_l = luminance(c);
                            const bg_l = luminance(bg);
                            if (@abs(fg_l - bg_l) > 0.001) {
                                const blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1 - a));
                                a = std.math.clamp((blend_l - bg_l) / (fg_l - bg_l), 0, 1);
                            }
                        }
                        break :gray c * splat(a);
                    },
                    .color => colored: {
                        const c = color_atlas.nearest(coord);
                        if (u.bools.use_linear_blending) break :colored c;
                        break :colored unlinearizePremultiplied(c);
                    },
                };
                self.blend(x, y, out);
            };
        }
    }

    fn image(self: *const RenderPass, u: *const Uniforms, in: Image, texture: Texture) void {
        // image_vertex
        const origin: [2]f32 = .{
            u.cell_size[0] * in.grid_pos[0] + in.cell_offset[0],
            u.cell_size[1] * in.grid_pos[1] + in.cell_offset[1],
        };
        const quad = self.rasterRect(u, origin, .{ origin[0] + in.dest_size[0], origin[1] + in.dest_size[1] }) orelse return;
        for (quad.y0..quad.y1) |y| for (quad.x0..quad.x1) |x| {
            const coord: [2]f32 = .{
                in.source_rect[0] + (center(x) - quad.fx0) / (quad.fx1 - quad.fx0) * in.source_rect[2],
                in.source_rect[1] + (center(y) - quad.fy0) / (quad.fy1 - quad.fy0) * in.source_rect[3],
            };
            // image_fragment
            var rgba = texture.linear(coord, false);
            if (!u.bools.use_linear_blending) rgba = .{ unlinearize(rgba[0]), unlinearize(rgba[1]), unlinearize(rgba[2]), unlinearize(rgba[3]) };
            self.blend(x, y, .{ rgba[0] * rgba[3], rgba[1] * rgba[3], rgba[2] * rgba[3], rgba[3] });
        };
    }

    fn bgImage(self: *const RenderPass, u: *const Uniforms, in: BgImage, texture: Texture) void {
        // bg_image_vertex
        const screen = u.screen_size;
        const tex: [2]f32 = .{ @floatFromInt(texture.width), @floatFromInt(texture.height) };
        const dest: [2]f32 = switch (in.info.fit) {
            .contain => fit: {
                const s = @min(screen[0] / tex[0], screen[1] / tex[1]);
                break :fit .{ tex[0] * s, tex[1] * s };
            },
            .cover => fit: {
                const s = @max(screen[0] / tex[0], screen[1] / tex[1]);
                break :fit .{ tex[0] * s, tex[1] * s };
            },
            .stretch => screen,
            .none => tex,
        };
        const mid: [2]f32 = .{ (screen[0] - dest[0]) / 2, (screen[1] - dest[1]) / 2 };
        const end: [2]f32 = .{ screen[0] - dest[0], screen[1] - dest[1] };
        const offset: [2]f32 = switch (in.info.position) {
            .tl => .{ 0, 0 },
            .tc => .{ mid[0], 0 },
            .tr => .{ end[0], 0 },
            .ml => .{ 0, mid[1] },
            .mc => mid,
            .mr => .{ end[0], mid[1] },
            .bl => .{ 0, end[1] },
            .bc => .{ mid[0], end[1] },
            .br => end,
        };
        const scale: [2]f32 = .{ tex[0] / dest[0], tex[1] / dest[1] };
        const opaque_bg = loadColor(.{ u.bg_color[0], u.bg_color[1], u.bg_color[2], 255 }, u.bools.use_display_p3, u.bools.use_linear_blending);
        const bg_alpha = unorm(u.bg_color[3]);

        // bg_image_fragment
        for (0..self.target.height) |y| for (0..self.target.width) |x| {
            var coord: [2]f32 = .{ (center(x) - offset[0]) * scale[0], (center(y) - offset[1]) * scale[1] };
            if (in.info.repeat) {
                inline for (0..2) |i| coord[i] = @mod(@mod(coord[i], tex[i]) + tex[i], tex[i]);
            }
            var rgba = texture.linear(coord, true);
            if (!u.bools.use_linear_blending) rgba = .{ unlinearize(rgba[0]), unlinearize(rgba[1]), unlinearize(rgba[2]), unlinearize(rgba[3]) };
            rgba = .{ rgba[0] * rgba[3], rgba[1] * rgba[3], rgba[2] * rgba[3], rgba[3] };
            rgba *= splat(@min(in.opacity, 1 / bg_alpha));
            rgba += @max(splat(0), Color{ opaque_bg[0], opaque_bg[1], opaque_bg[2], 1 } * splat(1 - rgba[3]));
            self.blend(x, y, rgba * splat(bg_alpha));
        };
    }

    const Rect = struct {
        x0: usize,
        y0: usize,
        x1: usize,
        y1: usize,
        fx0: f32,
        fy0: f32,
        fx1: f32,
        fy1: f32,
    };

    /// The pixels whose centers a rectangle in projection space covers once
    /// projected to the target, by the top-left fill rule.
    fn rasterRect(self: *const RenderPass, u: *const Uniforms, a: [2]f32, b: [2]f32) ?Rect {
        const p = self.project(u, a);
        const q = self.project(u, b);
        const fx0 = @min(p[0], q[0]);
        const fx1 = @max(p[0], q[0]);
        const fy0 = @min(p[1], q[1]);
        const fy1 = @max(p[1], q[1]);
        const w: f32 = @floatFromInt(self.target.width);
        const h: f32 = @floatFromInt(self.target.height);
        const x0 = std.math.clamp(@ceil(fx0 - 0.5), 0, w);
        const x1 = std.math.clamp(@ceil(fx1 - 0.5), 0, w);
        const y0 = std.math.clamp(@ceil(fy0 - 0.5), 0, h);
        const y1 = std.math.clamp(@ceil(fy1 - 0.5), 0, h);
        if (x0 >= x1 or y0 >= y1) return null;
        return .{
            .x0 = @intFromFloat(x0),
            .x1 = @intFromFloat(x1),
            .y0 = @intFromFloat(y0),
            .y1 = @intFromFloat(y1),
            .fx0 = fx0,
            .fx1 = fx1,
            .fy0 = fy0,
            .fy1 = fy1,
        };
    }

    /// The projection matrix, then the viewport transform to target pixels.
    fn project(self: *const RenderPass, u: *const Uniforms, v: [2]f32) [2]f32 {
        const m = u.projection_matrix;
        const ndc_x = m[0][0] * v[0] + m[1][0] * v[1] + m[3][0];
        const ndc_y = m[0][1] * v[0] + m[1][1] * v[1] + m[3][1];
        const w: f32 = @floatFromInt(self.target.width);
        const h: f32 = @floatFromInt(self.target.height);
        return .{ (ndc_x + 1) / 2 * w, (1 - ndc_y) / 2 * h };
    }
};

pub const Frame = struct {
    api: *Raster,
    renderer: *Renderer,
    target: *Target,

    pub inline fn renderPass(
        self: *const Frame,
        attachments: []const RenderPass.Options.Attachment,
    ) RenderPass {
        return RenderPass.begin(self.renderer.shaders.linear, .{ .attachments = attachments });
    }

    pub fn complete(self: *const Frame, sync: bool) void {
        _ = sync;
        self.api.present(self.target.*) catch unreachable;
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
            bg_color: Pipeline = .{ .program = .bg_color },
            cell_bg: Pipeline = .{ .program = .cell_bg },
            cell_text: Pipeline = .{ .program = .cell_text },
            image: Pipeline = .{ .program = .image },
            bg_image: Pipeline = .{ .program = .bg_image },
        } = .{},

        post_pipelines: []const Pipeline = &.{},

        /// The targets store sRGB encoded colors and blend in linear space.
        linear: bool,

        /// Set to true when deinited, deiniting twice is ignored.
        defunct: bool = false,

        pub fn deinit(self: *Shaders, alloc: Allocator) void {
            _ = alloc;
            self.defunct = true;
        }
    };
};

const Uniforms = shaders.Uniforms;
const CellText = shaders.CellText;
const CellBg = shaders.CellBg;
const Image = shaders.Image;
const BgImage = shaders.BgImage;

const Color = @Vector(4, f32);

fn splat(v: f32) Color {
    return @splat(v);
}

fn unorm(b: u8) f32 {
    return @as(f32, @floatFromInt(b)) / 255;
}

fn center(i: usize) f32 {
    return @as(f32, @floatFromInt(i)) + 0.5;
}

fn clampIndex(v: f32, len: usize) usize {
    return @intFromFloat(std.math.clamp(v, 0, @as(f32, @floatFromInt(len - 1))));
}

/// The cell a fragment coordinate falls in along one axis, clamped into the
/// grid where the padding extends and null where it does not.
fn gridIndex(at: f32, padding: f32, cell: f32, count: i32, extend_low: bool, extend_high: bool) ?i32 {
    const i: i32 = @intFromFloat(@floor((at - padding) / cell));
    if (i < 0) return if (extend_low) 0 else null;
    if (i > count - 1) return if (extend_high) count - 1 else null;
    return i;
}

fn linearize(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn unlinearize(v: f32) f32 {
    return if (v <= 0.0031308) v * 12.92 else std.math.pow(f32, v, 1.0 / 2.4) * 1.055 - 0.055;
}

fn unlinearizePremultiplied(c: Color) Color {
    if (c[3] == 0) return c;
    const a = c[3];
    return .{ unlinearize(c[0] / a) * a, unlinearize(c[1] / a) * a, unlinearize(c[2] / a) * a, a };
}

fn luminance(c: Color) f32 {
    return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722;
}

fn contrastRatio(a: Color, b: Color) f32 {
    const l1 = luminance(a);
    const l2 = luminance(b);
    return (@max(l1, l2) + 0.05) / (@min(l1, l2) + 0.05);
}

fn contrastedColor(min: f32, fg: Color, bg: Color) Color {
    if (contrastRatio(fg, bg) >= min) return fg;
    const white_ratio = contrastRatio(splat(1), bg);
    const black_ratio = contrastRatio(.{ 0, 0, 0, 1 }, bg);
    return if (white_ratio > black_ratio) splat(1) else .{ 0, 0, 0, 1 };
}

/// load_color: a non-premultiplied 8-bit color, premultiplied and linear
/// when `linear` is set. A Display P3 color is converted to sRGB primaries.
fn loadColor(in: [4]u8, display_p3: bool, linear: bool) Color {
    var c: Color = .{ unorm(in[0]), unorm(in[1]), unorm(in[2]), unorm(in[3]) };
    if (display_p3 or linear) {
        c = .{ linearize(c[0]), linearize(c[1]), linearize(c[2]), c[3] };
        if (display_p3) {
            const r = c[0];
            const g = c[1];
            const b = c[2];
            c = .{
                1.2249401 * r - 0.2249404 * g,
                -0.0420569 * r + 1.0420571 * g,
                -0.0196376 * r - 0.0786361 * g + 1.0982735 * b,
                c[3],
            };
        }
        if (!linear) c = .{ unlinearize(c[0]), unlinearize(c[1]), unlinearize(c[2]), c[3] };
    }
    return .{ c[0] * c[3], c[1] * c[3], c[2] * c[3], c[3] };
}
