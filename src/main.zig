const std = @import("std");
const ascii = @import("std").ascii;
const assert = @import("std").debug.assert;

pub usingnamespace @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("GL/gl.h");
    @cInclude("GL/glx.h");
    @cInclude("GL/glext.h");
});

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("string.h");
});

fn xErrorHandler (display : ?*Display, event : [*c]XErrorEvent) callconv(.C) c_int {
    var buffer : [512]u8 = undefined;
    assert(XGetErrorText(display, event.*.error_code, &buffer, buffer.len) == 0);
    std.debug.warn("X Error: {}\n", .{buffer});
    assert(false);
    return 0;
}

fn opaquePtrCast(comptime To : type, from : var) To {
    return @ptrCast(To, @alignCast(@alignOf(To.Child), from));
}

fn isExtensionSupported(glx_extensions : [*:0]const u8, extension : []const u8) bool {
    assert(extension.len != 0);

    const space = ascii.indexOfIgnoreCase(extension, " ");
    assert(space == null); // Extention string should not contain spaces

    const extensions_len = c.strlen(glx_extensions);

    var index : usize = 0;
    while (ascii.indexOfIgnoreCase(glx_extensions[index..extensions_len], extension)) |where| {
        const terminator = where + extension.len;
        if (where == index or glx_extensions[where - 1] == ' ') {
            if (terminator == extensions_len or glx_extensions[terminator] == ' ') {
                std.debug.warn("Found GLX Extension: {}\n", .{extension});
                return true;
            }
        }
        index = terminator;
    }
    return false;
}

pub fn main() anyerror!void {
    const display : ?*Display = XOpenDisplay(0);
    defer { _ = XSync(display, 0); _ = XCloseDisplay(display);}
    _ = XSetErrorHandler(xErrorHandler);

    const visual_attributes = [_]GLint{
        GLX_X_RENDERABLE, True,
        GLX_DRAWABLE_TYPE, GLX_WINDOW_BIT,
        GLX_RENDER_TYPE, GLX_RGBA_BIT,
        GLX_X_VISUAL_TYPE, GLX_TRUE_COLOR,
        GLX_RED_SIZE, 8,
        GLX_GREEN_SIZE, 8,
        GLX_BLUE_SIZE, 8,
        GLX_ALPHA_SIZE, 8,
        GLX_DEPTH_SIZE, 24,
        GLX_STENCIL_SIZE, 8,
        GLX_DOUBLEBUFFER,
        None
    };
    assert(display != null);

    {
        var glx_major : c_int = undefined;
        var glx_minor : c_int = undefined;

        assert(glXQueryVersion(display, &glx_major, &glx_minor) != 0); //, "Couldn't get glx version");
        assert(glx_major >= 1); //, "Invalid GLX version");
        assert((glx_major != 1) or (glx_minor >= 3)); //, "Invalid GLX version");
        std.debug.warn("GLX Version major = {}\n", .{glx_major});
        std.debug.warn("GLX Version minor = {}\n", .{glx_minor});
    }

    var default_screen = DefaultScreen(display.?);
    const fb_config : GLXFBConfig = blk: {
        var fbcount : c_int = undefined;
        var fbc : [*c]GLXFBConfig = glXChooseFBConfig(display, default_screen, &visual_attributes[0], &fbcount);
        defer _ = XFree(fbc);
        assert(fbc != null);

        var best_fbc : ?usize = null;
        var best_num_samp : i32 = -1;

        var i : usize = 0;
        while (i < fbcount) : (i += 1) {
            const vi : [*c]XVisualInfo = glXGetVisualFromFBConfig(display, fbc[i]);
            defer _ = XFree(vi);
            if (vi != 0) {
                var samp_buf : c_int = undefined;
                var samples : c_int = undefined;
                _ = glXGetFBConfigAttrib(display, fbc[i], GLX_SAMPLE_BUFFERS, &samp_buf);
                _ = glXGetFBConfigAttrib(display, fbc[i], GLX_SAMPLES       , &samples );

                if (best_fbc == null  or (samp_buf != 0 and (samples > best_num_samp))) {
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
    // FIXME: RootWindow couldn't be generated
    //const root : Window = RootWindow(display, visual_info.*.screen);
    const root : Window = (opaquePtrCast(_XPrivDisplay, display.?).*.screens[@intCast(usize, visual_info.*.screen)]).root;

    const color_map : Colormap =XCreateColormap(display, root, visual_info.*.visual, AllocNone); 
    defer _ = XFreeColormap(display, color_map);
    var set_window_attributes = XSetWindowAttributes {
        .colormap          = color_map,
        .event_mask        = StructureNotifyMask | ExposureMask | KeyPressMask,
        .background_pixmap = None,
        .border_pixel      = None,

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

    const window = XCreateWindow(display, root,
            0, 0, 800, 600, 0, visual_info.*.depth, InputOutput,
            visual_info.*.visual, CWBorderPixel | CWColormap | CWEventMask, &set_window_attributes);
    defer _ = XDestroyWindow(display, window);

    const wm_delete_window = {
        var protocols : [1]Atom = .{  XInternAtom(display, "WM_DELETE_WINDOW", 0) };
        var status : Status = XSetWMProtocols(display, window, &protocols, protocols.len);
        assert(status != 0);
    };

    _ = XStoreName(display, window, "Blue Heaven");
    _ = XMapWindow(display, window);

    std.debug.warn("Creating GL context\n", .{});
    var vsync_enabled = true;
    {
        const glx_extensions = glXQueryExtensionsString(display, default_screen);
        assert(glx_extensions != null);
        const glXCreateContextAttribsARBProc = fn(?*Display, GLXFBConfig, GLXContext, c_int, [*c]const GLint) callconv(.C) GLXContext;
        const glXCreateContextAttribsARB = @ptrCast(glXCreateContextAttribsARBProc, glXGetProcAddressARB(@ptrCast([*c] const u8, &"glXCreateContextAttribsARB"[0]))); // Will (almost) never return NULL, even if the function doesn't exist: https://dri.freedesktop.org/wiki/glXGetProcAddressNeverReturnsNULL/
        _ = c.printf("%s\n", glx_extensions);
        const extension_found = isExtensionSupported(@ptrCast([*:0]const u8, glx_extensions),  "GLX_ARB_create_context");
        assert(extension_found);

        const context_attributes = [_:None]GLint {
            GLX_CONTEXT_MAJOR_VERSION_ARB, 3,
            GLX_CONTEXT_MINOR_VERSION_ARB, 3,
            //GLX_CONTEXT_PROFILE_MASK_ARB,
            //GLX_CONTEXT_FLAGS_ARB,
            //GLX_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB,
            None,
        };
        const glx_context = glXCreateContextAttribsARB(display.?, fb_config, @intToPtr(GLXContext, 0), True, &context_attributes[0]);
        std.debug.warn("GLXContext: {}\n", .{glx_context});
        assert(glx_context != null); // GLX context creation failed
        std.debug.warn("Created GLX context\n", .{});

        _ = glXMakeCurrent(display.?, window, glx_context);

        // enable VSync if available
        if (isExtensionSupported(glx_extensions, "GLX_MESA_swap_control")) {
            std.debug.warn("MESA_swap_control is supported\n", .{});
            const glXSwapIntervalMESA = @ptrCast(PFNGLXSWAPINTERVALMESAPROC, glXGetProcAddressARB(@ptrCast([*c] const u8, &"glXSwapIntervalMESA"[0]))).?; // Will (almost) never return NULL, even if the function doesn't exist: https://dri.freedesktop.org/wiki/glXGetProcAddressNeverReturnsNULL/
            _ = glXSwapIntervalMESA(1);
        } else if (isExtensionSupported(glx_extensions, "GLX_SGI_swap_control")) {
            std.debug.warn("SGI_swap_control is supported\n", .{});
            const glXSwapIntervalSGI = @ptrCast(PFNGLXSWAPINTERVALSGIPROC, glXGetProcAddressARB(@ptrCast([*c] const u8, &"glXSwapIntervalSGI"[0]))).?; // Will (almost) never return NULL, even if the function doesn't exist: https://dri.freedesktop.org/wiki/glXGetProcAddressNeverReturnsNULL/
            _ = glXSwapIntervalSGI(1);
        } else if (isExtensionSupported(glx_extensions, "GLX_EXT_swap_control")) {
            std.debug.warn("EXT_swap_control is supported\n", .{});
            const glXSwapIntervalEXT = @ptrCast(PFNGLXSWAPINTERVALEXTPROC, glXGetProcAddressARB(@ptrCast([*c] const u8, &"glXSwapIntervalEXT"[0]))).?; // Will (almost) never return NULL, even if the function doesn't exist: https://dri.freedesktop.org/wiki/glXGetProcAddressNeverReturnsNULL/
            _ = glXSwapIntervalEXT(display.?, window, 1);
        } else {
            std.debug.warn("VSync not supported\n", .{});
        }

        _ = XSync(display.?, 0);
    }
    {
        const opengl_version                  = glGetString(GL_VERSION);
        const opengl_vendor                   = glGetString(GL_VENDOR);
        const opengl_renderer                 = glGetString(GL_RENDERER);
        const opengl_shading_language_version = glGetString(GL_SHADING_LANGUAGE_VERSION);
        _ = c.printf("opengl version = %s\n", opengl_version);
        _ = c.printf("opengl vendor = %s\n", opengl_vendor);
        _ = c.printf("opengl renderer = %s\n", opengl_renderer);
        _ = c.printf("opengl shading language version = %s\n", opengl_shading_language_version);
    }

    //// Buffers
    //PFNGLGENBUFFERSPROC glGenBuffers;
    //PFNGLBINDBUFFERPROC glBindBuffer;
    //PFNGLBUFFERDATAPROC glBufferData;

    //// Vertex Arrays and Attributes
    //PFNGLVERTEXATTRIBPOINTERPROC glVertexAttribPointer;
    //PFNGLGENVERTEXARRAYSPROC glGenVertexArrays;
    //PFNGLBINDVERTEXARRAYPROC glBindVertexArray;
    //PFNGLENABLEVERTEXATTRIBARRAYPROC glEnableVertexAttribArray;
    //PFNGLDISABLEVERTEXATTRIBARRAYPROC glDisableVertexAttribArray;

    //PFNGLGETUNIFORMLOCATIONPROC glGetUniformLocation;
    //PFNGLUNIFORM2FPROC  glUniform2f;
    //PFNGLUNIFORM4FPROC  glUniform4f;
    //PFNGLUNIFORMMATRIX4FVPROC glUniformMatrix4fv;

    //PFNGLCREATESHADERPROC glCreateShader;
    //PFNGLATTACHSHADERPROC glAttachShader;
    //PFNGLDETACHSHADERPROC glDetachShader;
    //PFNGLDELETESHADERPROC glDeleteShader;
    //PFNGLSHADERSOURCEPROC glShaderSource;
    //PFNGLCOMPILESHADERPROC glCompileShader;
    //PFNGLGETSHADERIVPROC glGetShaderiv;
    //PFNGLGETSHADERINFOLOGPROC glGetShaderInfoLog;

    //PFNGLCREATEPROGRAMPROC glCreateProgram;
    //PFNGLLINKPROGRAMPROC glLinkProgram;
    //PFNGLGETPROGRAMIVPROC glGetProgramiv;
    //PFNGLGETPROGRAMINFOLOGPROC glGetProgramInfoLog;
    //PFNGLUSEPROGRAMPROC glUseProgram;

    while (true){}
}

