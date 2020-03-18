const std = @import("std");
const ascii = @import("std").ascii;
const assert = @import("std").debug.assert;
const hsluv = @import("hsluv");

usingnamespace @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("unistd.h");
    @cInclude("time.h");
    @cInclude("errno.h");

    @cInclude("X11/Xlib.h");
    @cInclude("GL/gl.h");
    @cInclude("GL/glx.h");
    @cInclude("GL/glext.h");

    @cInclude("simple_font.h");
});

fn timespecToNanosec(ts: *timespec) u64 {
    const result: u64 = @intCast(u64, ts.tv_sec) * 1000000000 + @intCast(u64, ts.tv_nsec);
    return result;
}

fn nanosecToTimespec(ns: u64) timespec {
    const result = timespec{
        .tv_sec = @intCast(time_t, ns / 1000000000),
        .tv_nsec = @intCast(c_long, ns % 1000000000),
    };
    return result;
}

fn xErrorHandler(display: ?*Display, event: [*c]XErrorEvent) callconv(.C) c_int {
    var buffer: [512]u8 = undefined;
    assert(XGetErrorText(display, event.*.error_code, &buffer[0], buffer.len) == 0);
    std.debug.warn("X Error: {}\n", .{buffer});
    assert(false);
    return 0;
}

fn opaquePtrCast(comptime To: type, from: var) To {
    return @ptrCast(To, @alignCast(@alignOf(To.Child), from));
}

fn isExtensionSupported(glx_extensions: [*:0]const u8, extension: []const u8) bool {
    assert(extension.len != 0);

    const space = ascii.indexOfIgnoreCase(extension, " ");
    assert(space == null); // Extention string should not contain spaces

    const extensions_len = strlen(glx_extensions);

    var xindex: usize = 0;
    while (ascii.indexOfIgnoreCase(glx_extensions[xindex..extensions_len], extension)) |where| {
        const terminator = where + extension.len;
        if (where == xindex or glx_extensions[where - 1] == ' ') {
            if (terminator == extensions_len or glx_extensions[terminator] == ' ') {
                std.debug.warn("Found GLX Extension: {}\n", .{extension});
                return true;
            }
        }
        xindex = terminator;
    }
    return false;
}

fn init_gl_proc(comptime T: type, name: [:0]const u8) T {
    return @ptrCast(T, glXGetProcAddressARB(@ptrCast(*const GLubyte, &name[0])));
}

//// Buffers
var glGenBuffers: PFNGLGENBUFFERSPROC = undefined;
var glBindBuffer: PFNGLBINDBUFFERPROC = undefined;
var glBufferData: PFNGLBUFFERDATAPROC = undefined;

//// Vertex Arrays and Attributes
var glVertexAttribPointer: PFNGLVERTEXATTRIBPOINTERPROC = undefined;
var glGenVertexArrays: PFNGLGENVERTEXARRAYSPROC = undefined;
var glBindVertexArray: PFNGLBINDVERTEXARRAYPROC = undefined;
var glEnableVertexAttribArray: PFNGLENABLEVERTEXATTRIBARRAYPROC = undefined;
var glDisableVertexAttribArray: PFNGLDISABLEVERTEXATTRIBARRAYPROC = undefined;

//// Uniforms
var glGetUniformLocation: PFNGLGETUNIFORMLOCATIONPROC = undefined;
var glUniform2f: PFNGLUNIFORM2FPROC = undefined;
var glUniform4f: PFNGLUNIFORM4FPROC = undefined;
var glUniformMatrix4fv: PFNGLUNIFORMMATRIX4FVPROC = undefined;

//// Shader creation
var glCreateShader: PFNGLCREATESHADERPROC = undefined;
var glAttachShader: PFNGLATTACHSHADERPROC = undefined;
var glDetachShader: PFNGLDETACHSHADERPROC = undefined;
var glDeleteShader: PFNGLDELETESHADERPROC = undefined;
var glShaderSource: PFNGLSHADERSOURCEPROC = undefined;
var glCompileShader: PFNGLCOMPILESHADERPROC = undefined;
var glGetShaderiv: PFNGLGETSHADERIVPROC = undefined;
var glGetShaderInfoLog: PFNGLGETSHADERINFOLOGPROC = undefined;

//// Program creation
var glCreateProgram: PFNGLCREATEPROGRAMPROC = undefined;
var glLinkProgram: PFNGLLINKPROGRAMPROC = undefined;
var glGetProgramiv: PFNGLGETPROGRAMIVPROC = undefined;
var glGetProgramInfoLog: PFNGLGETPROGRAMINFOLOGPROC = undefined;
var glUseProgram: PFNGLUSEPROGRAMPROC = undefined;

fn _check_shader_compile_status(shader: GLuint) void {
    var success: GLint = undefined;
    glGetShaderiv.?(shader, GL_COMPILE_STATUS, &success);
    if (success == GL_FALSE) {
        var buffer: [2048:0]GLchar = undefined;
        var max_length: GLint = undefined;
        glGetShaderiv.?(shader, GL_INFO_LOG_LENGTH, &max_length);
        max_length = if (buffer.len < max_length) buffer.len else max_length;
        glGetShaderInfoLog.?(shader, max_length, &max_length, &buffer[0]);
        glDeleteShader.?(shader);
        std.debug.warn("GL shader compile status BAD: \"{}\"\n", .{buffer[0..@intCast(usize, max_length)]});
        assert(false);
    } else std.debug.warn("GL shader compile status GOOD\n", .{});
}

fn _renderer_build_one_off_program(shader_string_vertex: [:0]const u8, shader_string_fragment: [:0]const u8) GLuint {
    const shader_vert = glCreateShader.?(GL_VERTEX_SHADER);
    const shader_frag = glCreateShader.?(GL_FRAGMENT_SHADER);

    glShaderSource.?(shader_vert, 1, &(&shader_string_vertex[0]), 0);
    glShaderSource.?(shader_frag, 1, &(&shader_string_fragment[0]), 0);

    glCompileShader.?(shader_vert);
    _check_shader_compile_status(shader_vert);

    glCompileShader.?(shader_frag);
    _check_shader_compile_status(shader_frag);

    const program = glCreateProgram.?();
    glAttachShader.?(program, shader_vert);
    glAttachShader.?(program, shader_frag);

    std.debug.warn("Linking shader program\n", .{});
    glLinkProgram.?(program);
    {
        var result: GLint = undefined;
        var info_log_length: GLint = undefined;
        glGetProgramiv.?(program, GL_LINK_STATUS, &result);
        glGetProgramiv.?(program, GL_INFO_LOG_LENGTH, &info_log_length);
        if (info_log_length > 0) {
            var buffer: [2048:0]GLchar = undefined;
            info_log_length = if (buffer.len < info_log_length) buffer.len else info_log_length;
            glGetProgramInfoLog.?(program, info_log_length, &info_log_length, &buffer[0]);
            std.debug.warn("GL shader LINK status BAD: \"{}\"\n", .{buffer[0..@intCast(usize, info_log_length)]});
            assert(false);
        } else std.debug.warn("GL shader LINK status GOOD\n", .{});
    }
    glDetachShader.?(program, shader_vert);
    glDetachShader.?(program, shader_frag);
    glDeleteShader.?(shader_vert);
    glDeleteShader.?(shader_frag);
    return program;
}

const Color3f = packed struct {
    r: f32 = 0.0,
    g: f32 = 0.0,
    b: f32 = 0.0,
};

fn colr3f(r: f32, g: f32, b: f32) Color3f {
    return Color3f{ .r = r, .g = g, .b = b };
}

const palette = struct {
    const blue_heaven = hexToColr3f(0x0075b3);
    const raspberry = hexToColr3f(0xff5a5f);

    const honeycomb = hexToColr3f(0xefa00b);

    const shadow = hexToColr3f(0x3c3c3c);
    const ice_cream = hexToColr3f(0xf5f5f5);
};

pub fn hexToColr3f(hex: u24) Color3f {
    return Color3f{
        .r = @intToFloat(f32, (hex & 0xFF0000) >> 16) / 255.0,
        .g = @intToFloat(f32, (hex & 0xFF00) >> 8) / 255.0,
        .b = @intToFloat(f32, (hex & 0xFF) >> 0) / 255.0,
    };
}

const Vector2f = packed struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
};

fn v2f(x: f32, y: f32) Vector2f {
    return Vector2f{ .x = x, .y = y };
}

const Vector3f = packed struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
};

fn v3f(x: f32, y: f32, z: f32) Vector2f {
    return Vector3f{ .x = x, .y = y, .z = z };
}

const Rectf = struct {
    tl: Vector2f,
    br: Vector2f,

    pub fn width(self: *Rectf) f32 {
        return (self.br.x - self.tl.x);
    }

    pub fn height(self: *Rectf) f32 {
        return (self.br.y - self.tl.y);
    }
};

pub fn rectf(pos: Vector2f, size: Vector2f) Rectf {
    return Rectf{ .tl = pos, .br = v2f(pos.x + size.x, pos.y + size.y) };
}

pub fn rectfsep(pos_x: f32, pos_y: f32, size_x: f32, size_y: f32) Rectf {
    return Rectf{ .tl = v2f(pos_x, pos_y), .br = v2f(pos_x + size_x, pos_y + size_y) };
}

pub fn collision_rectf_v2f(rect: Rectf, v: Vector2f) bool {
    return (v.x > rect.tl.x and v.x < rect.br.x and v.y > rect.tl.y and v.y < rect.br.y);
}

var _program_rect: GLuint = undefined;
var _program_rect_uniform_location_rect: GLint = undefined;
var _program_rect_uniform_location_rect_color: GLint = undefined;
var _program_rect_uniform_location_screen_size: GLint = undefined;

const Renderer = struct {
    display_rect: Rectf,
    fn draw_rect(renderer: *Renderer, color: Color3f, rect: Rectf) void {
        glUseProgram.?(_program_rect);
        glUniform4f.?(_program_rect_uniform_location_rect, rect.tl.x, rect.tl.y, rect.br.x, rect.br.y);
        glUniform4f.?(_program_rect_uniform_location_rect_color, color.r, color.g, color.b, 1.0);
        glUniform2f.?(_program_rect_uniform_location_screen_size, renderer.display_rect.width(), renderer.display_rect.height());
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }

    fn draw_simple_font_char(renderer: *Renderer, c: u8, fg_color: Color3f, bg_color: Color3f, left_baseline: Vector2f, size: f32) void {
        var y: f32 = left_baseline.y - 12.0 * size;

        var j: u8 = 0;
        while (j < 16) : (j += 1) {
            //std.debug.warn("{} {}\n", .{ c, j });
            const bits = simple_font[c][j];
            var i: u4 = 0;
            while (i < 8) : (i += 1) {
                const x = left_baseline.x + 8.0 * size - @intToFloat(f32, i) * size;
                if (bits & (@as(u8, 1) << @intCast(u3, i)) != 0) {
                    renderer.draw_rect(fg_color, Rectf{ .tl = Vector2f{ .x = x, .y = y }, .br = Vector2f{ .x = x + size, .y = y + size } });
                }
            }
            y += size;
        }
    }

    fn draw_simple_font_text(renderer: *Renderer, txt: []const u8, fg_color: Color3f, bg_color: Color3f, left_baseline: Vector2f, size: f32) void {
        var c_left_baseline = left_baseline;
        for (txt) |c| {
            switch (c) {
                '\n' => {
                    c_left_baseline.x = left_baseline.x;
                    c_left_baseline.y += 16 * size;
                },
                else => {
                    renderer.draw_simple_font_char(c, fg_color, bg_color, c_left_baseline, size);
                    c_left_baseline.x += 8 * size;
                },
            }
        }
    }
};

fn lerp(t: var, a: var, b: @TypeOf(a)) @TypeOf(a) {
    // TODO: Could be replaced with FMA when available
    const T = @TypeOf(t);
    const A = @TypeOf(a);
    std.debug.assert(@typeInfo(T) == .Float);
    switch (@typeInfo(@TypeOf(a))) {
        .ComptimeInt,
        .Int,
        => {
            return @floatToInt(A, (1.0 - t) * @intToFloat(T, a) + t * @intToFloat(T, b));
        },
        .Float => {
            return (1.0 - t) * a + t * b;
        },
        else => unreachable,
    }
}

fn unlerp(comptime ReturnType: type, v: var, a: @TypeOf(v), b: @TypeOf(v)) ReturnType {
    std.debug.assert(@typeInfo(ReturnType) == .Float);

    switch (@typeInfo(@TypeOf(v))) {
        .ComptimeInt,
        .Int,
        => {
            return ((v - @intToFloat(ReturnType, a)) / @intToFloat(ReturnType, b - a));
        },
        .Float => {
            std.debug.assert(ReturnType == @TypeOf(v));
            return (v - a) / (b - a);
        },
        else => unreachable,
    }
}

fn linmap(v: var, a: @TypeOf(v), b: @TypeOf(v), c: @TypeOf(v), d: @TypeOf(v)) @TypeOf(v) {
    switch (@typeInfo(@TypeOf(v))) {
        .ComptimeInt,
        .Int,
        => {
            return lerp(unlerp(f64, v, a, b), c, d);
        },
        .Float => {
            return lerp(unlerp(@TypeOf(v), v, a, b), c, d);
        },
        else => unreachable,
    }
}

fn drawSlider(renderer: *Renderer, comptime T: type, slider_val: *T, val_min: T, val_max: T, pos: Vector2f, knob_size: Vector2f, track_size: Vector2f, grabbed: *bool, mouse: *MouseState) void {
    const track_rect = rectfsep(pos.x, pos.y + knob_size.y / 2 - track_size.y / 2, track_size.x, track_size.y);

    const half_width = knob_size.x / 2.0;

    const knob_min = pos.x;
    const knob_max = pos.x + (track_size.x - knob_size.x);

    var knob_x = linmap(slider_val.*, val_min, val_max, knob_min, knob_max);
    var knob_rect = rectfsep(knob_x, pos.y, knob_size.x, knob_size.y);

    var knob_mid = knob_x + half_width;

    if (grabbed.*) {
        if (mouse.*.button1_down) {
            knob_mid = @intToFloat(f32, mouse.*.x);
        } else {
            knob_mid = @intToFloat(f32, mouse.*.button1_end_x);
            grabbed.* = false;
        }
    } else if (mouse.*.button1_down) {
        if (collision_rectf_v2f(
            knob_rect,
            v2f(@intToFloat(f32, mouse.*.x), @intToFloat(f32, mouse.*.y)),
        )) {
            knob_mid = @intToFloat(f32, mouse.*.x);
            grabbed.* = true;
        }
    }

    knob_x = std.math.clamp(knob_mid - half_width, @as(f32, knob_min), @as(f32, knob_max));
    slider_val.* = linmap(knob_x, knob_min, knob_max, val_min, val_max);

    knob_rect = rectfsep(knob_x, pos.y, knob_size.x, knob_size.y);

    renderer.draw_rect(colr3f(0.5, 0.5, 0.5), track_rect);
    renderer.draw_rect(colr3f(1.0, 1.0, 1.0), knob_rect);
}

const MouseState = struct {
    button1_down: bool = false,
    button1_begin_x: c_int = 0,
    button1_begin_y: c_int = 0,

    button1_end_x: c_int = 0,
    button1_end_y: c_int = 0,

    x: i32 = 0,
    y: i32 = 0,
};

pub fn main() anyerror!void {
    const display: *Display = XOpenDisplay(0).?;
    defer {
        _ = XSync(display, 0);
        _ = XCloseDisplay(display);
    }
    _ = XSetErrorHandler(xErrorHandler);

    {
        var glx_major: c_int = undefined;
        var glx_minor: c_int = undefined;

        assert(glXQueryVersion(display, &glx_major, &glx_minor) != 0); //, "Couldn't get glx version");
        assert(glx_major >= 1); //, "Invalid GLX version");
        assert((glx_major != 1) or (glx_minor >= 3)); //, "Invalid GLX version");
        std.debug.warn("GLX Version major = {}\n", .{glx_major});
        std.debug.warn("GLX Version minor = {}\n", .{glx_minor});
    }

    var default_screen = DefaultScreen(display);
    const fb_config: GLXFBConfig = blk: {
        const visual_attributes = [_]GLint{
            GLX_X_RENDERABLE,  True,
            GLX_DRAWABLE_TYPE, GLX_WINDOW_BIT,
            GLX_RENDER_TYPE,   GLX_RGBA_BIT,
            GLX_X_VISUAL_TYPE, GLX_TRUE_COLOR,
            GLX_RED_SIZE,      8,
            GLX_GREEN_SIZE,    8,
            GLX_BLUE_SIZE,     8,
            GLX_ALPHA_SIZE,    8,
            GLX_DEPTH_SIZE,    24,
            GLX_STENCIL_SIZE,  8,
            GLX_DOUBLEBUFFER,  None,
        };

        var fbcount: c_int = undefined;
        var fbc: [*c]GLXFBConfig = glXChooseFBConfig(display, default_screen, &visual_attributes[0], &fbcount);
        defer _ = XFree(fbc);
        assert(fbc != null);

        var best_fbc: ?usize = null;
        var best_num_samp: i32 = -1;

        var i: usize = 0;
        while (i < fbcount) : (i += 1) {
            const vi: [*c]XVisualInfo = glXGetVisualFromFBConfig(display, fbc[i]);
            defer _ = XFree(vi);
            if (vi != 0) {
                var samp_buf: c_int = undefined;
                var samples: c_int = undefined;
                _ = glXGetFBConfigAttrib(display, fbc[i], GLX_SAMPLE_BUFFERS, &samp_buf);
                _ = glXGetFBConfigAttrib(display, fbc[i], GLX_SAMPLES, &samples);

                if (best_fbc == null or (samp_buf != 0 and (samples > best_num_samp))) {
                    best_fbc = i;
                    best_num_samp = samples;
                }
            }
        }
        assert(best_fbc != null);
        std.debug.warn("Best FBConfig index = {}\n", .{best_fbc});
        break :blk fbc[best_fbc.?];
    };

    const visual_info: [*c]XVisualInfo = glXGetVisualFromFBConfig(display, fb_config);
    defer _ = XFree(visual_info);
    //FIXME:
    //const root: Window = RootWindow(display, visual_info.*.screen);
    const root: Window = (opaquePtrCast(_XPrivDisplay, display).*.screens[@intCast(usize, visual_info.*.screen)]).root;

    const color_map: Colormap = XCreateColormap(display, root, visual_info.*.visual, AllocNone);
    defer _ = XFreeColormap(display, color_map);
    var set_window_attributes = XSetWindowAttributes{
        .colormap = color_map,
        .event_mask = StructureNotifyMask | ExposureMask | KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask,
        .background_pixmap = None,
        .border_pixel = None,

        .background_pixel = 0,
        .border_pixmap = None,
        .bit_gravity = 0,
        .win_gravity = 0,
        .backing_store = 0,
        .backing_planes = 0,
        .backing_pixel = 0,
        .save_under = 0,
        .do_not_propagate_mask = 0,
        .override_redirect = 0,
        .cursor = None,
    };

    const window = XCreateWindow(display, root, 0, 0, 800, 600, 0, visual_info.*.depth, InputOutput, visual_info.*.visual, CWBorderPixel | CWColormap | CWEventMask, &set_window_attributes);
    defer _ = XDestroyWindow(display, window);

    const wm_delete_window: Atom = blk: {
        var protocols: [1]Atom = .{XInternAtom(display, "WM_DELETE_WINDOW", 0)};
        var status: Status = XSetWMProtocols(display, window, &protocols, protocols.len);
        assert(status != 0);
        break :blk protocols[0];
    };

    _ = XStoreName(display, window, "Blue Heaven");
    _ = XMapWindow(display, window);

    std.debug.warn("Creating GL context\n", .{});
    var vsync_enabled = true;
    var glx_context = blk: {
        const glx_extensions = glXQueryExtensionsString(display, default_screen);
        assert(glx_extensions != null);
        const glXCreateContextAttribsARBProc = fn (?*Display, GLXFBConfig, GLXContext, c_int, [*c]const GLint) callconv(.C) GLXContext;
        const glXCreateContextAttribsARB = @ptrCast(glXCreateContextAttribsARBProc, glXGetProcAddressARB(@ptrCast([*c]const u8, &"glXCreateContextAttribsARB"[0]))); // Will (almost) never return NULL, even if the function doesn't exist: https://dri.freedesktop.org/wiki/glXGetProcAddressNeverReturnsNULL/
        _ = printf("%s\n", glx_extensions);
        const extension_found = isExtensionSupported(@ptrCast([*:0]const u8, glx_extensions), "GLX_ARB_create_context");
        assert(extension_found);

        const context_attributes = [_:None]GLint{
            GLX_CONTEXT_MAJOR_VERSION_ARB, 3,
            GLX_CONTEXT_MINOR_VERSION_ARB, 3,
            //GLX_CONTEXT_PROFILE_MASK_ARB,
            //GLX_CONTEXT_FLAGS_ARB,
            //GLX_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB,
            None,
        };
        const glx_context = glXCreateContextAttribsARB(display, fb_config, @intToPtr(GLXContext, 0), True, &context_attributes[0]);
        std.debug.warn("GLXContext: {}\n", .{glx_context});
        assert(glx_context != null); // GLX context creation failed
        std.debug.warn("Created GLX context\n", .{});

        _ = glXMakeCurrent(display, window, glx_context);

        // enable VSync if available
        if (isExtensionSupported(glx_extensions, "GLX_EXT_swap_control")) {
            std.debug.warn("EXT_swap_control is supported\n", .{});
            const glXSwapIntervalEXT = @ptrCast(PFNGLXSWAPINTERVALEXTPROC, glXGetProcAddressARB(@ptrCast([*c]const u8, &"glXSwapIntervalEXT"[0]))).?; // Will (almost) never return NULL, even if the function doesn't exist: https://dri.freedesktop.org/wiki/glXGetProcAddressNeverReturnsNULL/
            _ = glXSwapIntervalEXT(display, window, 1);
        } else if (isExtensionSupported(glx_extensions, "GLX_MESA_swap_control")) {
            std.debug.warn("MESA_swap_control is supported\n", .{});
            const glXSwapIntervalMESA = @ptrCast(PFNGLXSWAPINTERVALMESAPROC, glXGetProcAddressARB(@ptrCast([*c]const u8, &"glXSwapIntervalMESA"[0]))).?; // Will (almost) never return NULL, even if the function doesn't exist: https://dri.freedesktop.org/wiki/glXGetProcAddressNeverReturnsNULL/
            _ = glXSwapIntervalMESA(1);
        } else if (isExtensionSupported(glx_extensions, "GLX_SGI_swap_control")) {
            std.debug.warn("SGI_swap_control is supported\n", .{});
            const glXSwapIntervalSGI = @ptrCast(PFNGLXSWAPINTERVALSGIPROC, glXGetProcAddressARB(@ptrCast([*c]const u8, &"glXSwapIntervalSGI"[0]))).?; // Will (almost) never return NULL, even if the function doesn't exist: https://dri.freedesktop.org/wiki/glXGetProcAddressNeverReturnsNULL/
            _ = glXSwapIntervalSGI(1);
        } else {
            std.debug.warn("VSync not supported\n", .{});
        }

        _ = XSync(display, 0);
        break :blk glx_context;
    };
    defer {
        _ = glXMakeCurrent(display, None, null);
        _ = glXDestroyContext(display, glx_context);
    }

    {
        const opengl_version = glGetString(GL_VERSION);
        const opengl_vendor = glGetString(GL_VENDOR);
        const opengl_renderer = glGetString(GL_RENDERER);
        const opengl_shading_language_version = glGetString(GL_SHADING_LANGUAGE_VERSION);
        _ = printf("opengl version = %s\n", opengl_version);
        _ = printf("opengl vendor = %s\n", opengl_vendor);
        _ = printf("opengl renderer = %s\n", opengl_renderer);
        _ = printf("opengl shading language version = %s\n", opengl_shading_language_version);
    }

    //// Buffers
    glGenBuffers = init_gl_proc(PFNGLGENBUFFERSPROC, "glGenBuffers");
    glBindBuffer = init_gl_proc(PFNGLBINDBUFFERPROC, "glBindBuffer");
    glBufferData = init_gl_proc(PFNGLBUFFERDATAPROC, "glBufferData");

    //// Vertex Arrays and Attributes
    glVertexAttribPointer = init_gl_proc(PFNGLVERTEXATTRIBPOINTERPROC, "glVertexAttribPointer");
    glGenVertexArrays = init_gl_proc(PFNGLGENVERTEXARRAYSPROC, "glGenVertexArrays");
    glBindVertexArray = init_gl_proc(PFNGLBINDVERTEXARRAYPROC, "glBindVertexArray");
    glEnableVertexAttribArray = init_gl_proc(PFNGLENABLEVERTEXATTRIBARRAYPROC, "glEnableVertexAttribArray");
    glDisableVertexAttribArray = init_gl_proc(PFNGLDISABLEVERTEXATTRIBARRAYPROC, "glDisableVertexAttribArray");

    //// Uniforms
    glGetUniformLocation = init_gl_proc(PFNGLGETUNIFORMLOCATIONPROC, "glGetUniformLocation");
    glUniform2f = init_gl_proc(PFNGLUNIFORM2FPROC, "glUniform2f");
    glUniform4f = init_gl_proc(PFNGLUNIFORM4FPROC, "glUniform4f");
    glUniformMatrix4fv = init_gl_proc(PFNGLUNIFORMMATRIX4FVPROC, "glUniformMatrix4fv");

    //// Shader creation
    glCreateShader = init_gl_proc(PFNGLCREATESHADERPROC, "glCreateShader");
    glAttachShader = init_gl_proc(PFNGLATTACHSHADERPROC, "glAttachShader");
    glDetachShader = init_gl_proc(PFNGLDETACHSHADERPROC, "glDetachShader");
    glDeleteShader = init_gl_proc(PFNGLDELETESHADERPROC, "glDeleteShader");
    glShaderSource = init_gl_proc(PFNGLSHADERSOURCEPROC, "glShaderSource");
    glCompileShader = init_gl_proc(PFNGLCOMPILESHADERPROC, "glCompileShader");
    glGetShaderiv = init_gl_proc(PFNGLGETSHADERIVPROC, "glGetShaderiv");
    glGetShaderInfoLog = init_gl_proc(PFNGLGETSHADERINFOLOGPROC, "glGetShaderInfoLog");

    //// Program creation
    glCreateProgram = init_gl_proc(PFNGLCREATEPROGRAMPROC, "glCreateProgram");
    glLinkProgram = init_gl_proc(PFNGLLINKPROGRAMPROC, "glLinkProgram");
    glGetProgramiv = init_gl_proc(PFNGLGETPROGRAMIVPROC, "glGetProgramiv");
    glGetProgramInfoLog = init_gl_proc(PFNGLGETPROGRAMINFOLOGPROC, "glGetProgramInfoLog");
    glUseProgram = init_gl_proc(PFNGLUSEPROGRAMPROC, "glUseProgram");

    const shader_string_vertex_rect =
        \\#version 330
        \\uniform vec4 rect;
        \\uniform vec2 screen_size;
        \\void main(){
        \\ if(gl_VertexID==0)gl_Position.xy=rect.xy;
        \\ if(gl_VertexID==1)gl_Position.xy=rect.xw;
        \\ if(gl_VertexID==2)gl_Position.xy=rect.zy;
        \\ if(gl_VertexID==3)gl_Position.xy=rect.zw;
        \\ gl_Position.zw=vec2(-1.0,1.0);
        \\ gl_Position.xy=gl_Position.xy/screen_size*vec2(2.0,-2.0)-vec2(1.0,-1.0);
        \\}
        \\
    ;

    const shader_string_fragment_simple =
        \\#version 330
        \\uniform vec4 rect_color;
        \\out vec3 color;
        \\void main(){
        \\ color=rect_color.rgb;
        \\}
        \\
    ;

    const vertex_buffer_data = [_]GLfloat{
        0.0, 0.0,
        1.0, 0.0,
        1.0, 1.0,
        0.0, 1.0,
    };
    {
        var test_vao: GLuint = undefined;
        var test_vbuffer: GLuint = undefined;

        glGenVertexArrays.?(1, &test_vao);
        glBindVertexArray.?(test_vao);

        glGenBuffers.?(1, &test_vbuffer);
        glBindBuffer.?(GL_ARRAY_BUFFER, test_vbuffer);
        glBufferData.?(GL_ARRAY_BUFFER, @sizeOf(@TypeOf(vertex_buffer_data)), &vertex_buffer_data[0], GL_STATIC_DRAW);
    }

    _program_rect = _renderer_build_one_off_program(shader_string_vertex_rect, shader_string_fragment_simple);
    _program_rect_uniform_location_rect = glGetUniformLocation.?(_program_rect, "rect");
    _program_rect_uniform_location_rect_color = glGetUniformLocation.?(_program_rect, "rect_color");
    _program_rect_uniform_location_screen_size = glGetUniformLocation.?(_program_rect, "screen_size");

    glEnable(GL_DEPTH_TEST);
    //glEnable(GL_CULL_FACE);
    glEnable(GL_MULTISAMPLE);

    //glCullFace(GL_BACK);
    glDepthFunc(GL_LEQUAL);

    var xres: c_int = 0;
    var window_attributes: XWindowAttributes = undefined;
    xres = XGetWindowAttributes(display, window, &window_attributes);
    assert(xres != 0);

    var display_width: i32 = window_attributes.width;
    var display_height: i32 = window_attributes.height;
    std.debug.warn("width={}, height={}\n", .{ display_width, display_height });

    const mono_clock: clockid_t = CLOCK_MONOTONIC_RAW;
    var game_start_timespec: timespec = undefined;
    assert(clock_gettime(mono_clock, &game_start_timespec) == 0);
    var frame_start_time = timespecToNanosec(&game_start_timespec);

    var renderer = Renderer{
        .display_rect = Rectf{
            .tl = Vector2f{ .x = 0.0, .y = 0.0 },
            .br = Vector2f{ .x = @intToFloat(f32, display_width), .y = @intToFloat(f32, display_height) },
        },
    };

    var colour_select_hue: f32 = 0.0;
    var colour_select_saturation: f32 = 0.0;
    var colour_select_lightness: f32 = 0.0;
    var colour_select_hue_grabbed = false;

    var mouse_state = MouseState{};

    game_loop: while (true) {
        var display_size_changed = false;
        var should_quit = false;
        var got_input_event = false;
        var event: XEvent = undefined;
        _ = XPeekEvent(display, &event);
        while (XPending(display) > 0) {
            _ = XNextEvent(display, &event);
            switch (event.type) {
                Expose => {
                    xres = XGetWindowAttributes(display, window, &window_attributes);
                    assert(xres != 0);
                    if (display_width != window_attributes.width or display_height != window_attributes.height) {
                        display_size_changed = true;
                        display_width = window_attributes.width;
                        display_height = window_attributes.height;
                        got_input_event = true;
                    }
                },
                ClientMessage => {
                    if (@intCast(Atom, event.xclient.data.l[0]) == wm_delete_window) {
                        std.debug.warn("Should quit!\n", .{});
                        should_quit = true;
                    }
                },
                MotionNotify => {
                    mouse_state.x = event.xmotion.x;
                    mouse_state.y = event.xmotion.y;
                    got_input_event = true;
                },
                KeyPress => {},
                KeyRelease => {},
                ButtonPress => {
                    if (event.xbutton.button == Button1) {
                        mouse_state.button1_down = true;
                        mouse_state.button1_begin_x = event.xbutton.x;
                        mouse_state.button1_begin_y = event.xbutton.y;

                        mouse_state.x = event.xbutton.x;
                        mouse_state.y = event.xbutton.y;
                        std.debug.warn("Time = {}\n", .{event.xbutton.time});
                    }
                },
                ButtonRelease => {
                    if (event.xbutton.button == Button1) {
                        if (!mouse_state.button1_down) {
                            std.debug.warn("Got button release with no matching button press, ignoring\n", .{});
                        } else {
                            mouse_state.button1_down = false;
                            mouse_state.button1_end_x = event.xbutton.x;
                            mouse_state.button1_end_y = event.xbutton.y;
                            std.debug.warn("Time = {}\n", .{event.xbutton.time});
                        }
                    }
                },
                else => {
                    std.debug.warn("Unhandled event: {}\n", .{event.type});
                },
            }
        }

        if (should_quit) break :game_loop;
        if (display_size_changed) {
            glViewport(0, 0, display_width, display_height);
            renderer.display_rect = Rectf{
                .tl = Vector2f{ .x = 0.0, .y = 0.0 },
                .br = Vector2f{ .x = @intToFloat(f32, display_width), .y = @intToFloat(f32, display_height) },
            };
        }

        {
            // BlueHeaven = 0075b3
            // RaspberryDark = ff5a5f

            // Raspberry = c1839f
            // HoneyComb = efa00b

            // Shadow = 3c3c3c
            // VanillaIceCream = f5f5f5

            // Render
            comptime const contrast_ratio = hsluv.contrast.W3C_CONTRAST_TEXT + 0.0825757; // +Constant so that light-min and dark-max cross at ~49.39 lightness
            comptime const lighter_min_L = hsluv.contrast.lighterMinL(contrast_ratio, 0.0);
            comptime const darker_max_L = hsluv.contrast.darkerMaxL(contrast_ratio, 100.0);
            //std.debug.warn("bg fg={} {}\n", .{ lighter_min_L, darker_max_L });

            const bg_lightness = @intToFloat(f64, mouse_state.y) / @intToFloat(f64, display_height) * 100;
            const fg_lightness = if (bg_lightness < lighter_min_L)
                hsluv.contrast.lighterMinL(contrast_ratio, bg_lightness)
            else
                hsluv.contrast.darkerMaxL(contrast_ratio, bg_lightness);

            //std.debug.warn("fg={} bg={}\n", .{ fg_lightness, bg_lightness });

            const hsl_bg = [3]f64{
                colour_select_hue,
                //@intToFloat(f64, mouse_state.x) / @intToFloat(f64, display_width) * 360,
                //@intToFloat(f64, mouse_state.y) / @intToFloat(f64, display_height) * 100,
                85,
                bg_lightness,
            };
            //const hsl_bg = hsluv.rgbToHsluv([3]f64{ 0.1, 1.0, 0.5 });
            //std.debug.warn("HSL={} {} {}\n", .{ hsl[0], hsl[1], hsl[2] });
            const clear_colour = hsluv.hsluvToRgb(hsl_bg);

            //glClearColor(0.0 / 255.0, 117.0 / 255.0, 179.0 / 255.0, 1.0);
            glClearColor(@floatCast(f32, clear_colour[0]), @floatCast(f32, clear_colour[1]), @floatCast(f32, clear_colour[2]), 1.0);
            //std.debug.warn("rgb = {} {} {}\n", .{ @floatToInt(i32, clear_colour[0] * 255), @floatToInt(i32, clear_colour[1] * 255), @floatToInt(i32, clear_colour[2] * 255) });
            glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

            const hsl_fg = [3]f64{
                @intToFloat(f64, mouse_state.x) / @intToFloat(f64, display_width) * 360,
                //@intToFloat(f64, mouse_state.y) / @intToFloat(f64, display_height) * 100,
                85,
                fg_lightness,
            };
            const text_colour_array = hsluv.hsluvToRgb(hsl_fg);
            const text_colour = colr3f(@floatCast(f32, text_colour_array[0]), @floatCast(f32, text_colour_array[1]), @floatCast(f32, text_colour_array[2]));

            drawSlider(
                &renderer,
                f32,
                &colour_select_hue,
                0.0,
                360.0,
                Vector2f{ .x = 40.0, .y = 300.0 },
                Vector2f{ .x = 20, .y = 40 },
                Vector2f{ .x = 400, .y = 10 },
                &colour_select_hue_grabbed,
                &mouse_state,
            );
            //renderer.draw_simple_font_char('B', Color3f{ .r = 1.0, .g = 0.0, .b = 0.5 }, Color3f{ .r = 0.0, .g = 0.0, .b = 0.0 }, Vector2f{ .x = 100, .y = 100 }, 3.0);
            renderer.draw_simple_font_text(
                \\the quick brown fox
                \\jumps over the lazy dog
                \\
                \\THE QUICK BROWN FOX
                \\JUMPS OVER THE LAZY DOG
            , text_colour, palette.shadow, Vector2f{ .x = 100, .y = 100 }, 3.0);
        }

        // FIXME: only swap if double buffering is enabled?
        glXSwapBuffers(display, window);
        glFinish();

        const target_frame_rate: u32 = 0; //if (got_input_event) 60 else 12;
        if (target_frame_rate > 0) {
            var target_delta_time: u64 = 0;
            target_delta_time = 1000000000 / target_frame_rate;

            var frame_end_timespec: timespec = undefined;
            assert(clock_gettime(mono_clock, &frame_end_timespec) == 0);
            const frame_end_time = timespecToNanosec(&frame_end_timespec);
            var delta_time = frame_end_time - frame_start_time;
            if (delta_time < target_delta_time) {
                var sleep_time = nanosecToTimespec(target_delta_time - delta_time);
                while (nanosleep(&sleep_time, &sleep_time) == -1) {
                    // FIXME: zig is choking on errno
                    //std.debug.warn("nanosleep failed! errno={}\n", .{errno});
                    std.debug.warn("nanosleep failed! errno=???\n", .{});
                }
            }

            assert(clock_gettime(mono_clock, &frame_end_timespec) == 0);
            frame_start_time = timespecToNanosec(&frame_end_timespec);
        }
    }
}
