const std = @import("std");
const ascii = @import("std").ascii;
const assert = @import("std").debug.assert;

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

const Vector2f = packed struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
};

const Vector3f = packed struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
};

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

    var mouse_x: i32 = 0;
    var mouse_y: i32 = 0;

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

    game_loop: while (true) {
        var display_size_changed = false;
        var should_quit = false;
        while (XPending(display) > 0) {
            var event: XEvent = undefined;
            _ = XNextEvent(display, &event);
            switch (event.type) {
                Expose => {
                    xres = XGetWindowAttributes(display, window, &window_attributes);
                    assert(xres != 0);
                    if (display_width != window_attributes.width or display_height != window_attributes.height) {
                        display_size_changed = true;
                        display_width = window_attributes.width;
                        display_height = window_attributes.height;
                    }
                },
                ClientMessage => {
                    if (@intCast(Atom, event.xclient.data.l[0]) == wm_delete_window) {
                        std.debug.warn("Should quit!\n", .{});
                        should_quit = true;
                    }
                },
                MotionNotify => {
                    mouse_x = event.xmotion.x;
                    mouse_y = event.xmotion.y;
                },
                else => {},
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
            glClearColor(0.0 / 255.0, 117.0 / 255.0, 179.0 / 255.0, 1.0);
            glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

            renderer.draw_rect(Color3f{ .r = 1.0, .g = 1.0, .b = 1.0 }, Rectf{ .tl = Vector2f{ .x = 100, .y = 100 }, .br = Vector2f{ .x = 400, .y = 500 } });
        }

        // FIXME: only swap if double buffering is enabled?
        glXSwapBuffers(display, window);
        glFinish();

        const target_frame_rate = 60;
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
