const std = @import("std");
const assert = @import("std").debug.assert;

pub usingnamespace @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("GL/gl.h");
    @cInclude("GL/glx.h");
    @cInclude("GL/glext.h");
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

pub fn main() anyerror!void {
    _ = XSetErrorHandler(xErrorHandler);

    const display : ?*Display = XOpenDisplay(0);
    defer { _ = XSync(display, 0); _ = XCloseDisplay(display);}
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

    const fb_config : GLXFBConfig = blk: {
        var fbcount : c_int = undefined;
        var default_screen = DefaultScreen(display.?);
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
}

