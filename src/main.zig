const std = @import("std");
const ascii = @import("std").ascii;
const assert = @import("std").debug.assert;
const hsluv = @import("hsluv");

usingnamespace @import("renderer.zig");
usingnamespace @import("turtle.zig");
usingnamespace @import("lmath.zig");

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

fn opaquePtrCast(comptime To: type, from: anytype) To {
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

fn drawSlider(renderer: *Renderer, slider_val: anytype, val_min: @TypeOf(slider_val).Child, val_max: @TypeOf(slider_val).Child, pos: Vector2f, knob_size: Vector2f, track_size: Vector2f, grabbed: *bool, mouse: *MouseState) void {
    assert(@typeInfo(@TypeOf(slider_val)) == .Pointer);
    const track_rect = rectfwh(pos.x, pos.y + knob_size.y / 2 - track_size.y / 2, track_size.x, track_size.y);
    const track_rect_inner = rectfwh(pos.x + 2, pos.y + knob_size.y / 2 - track_size.y / 2 + 2, track_size.x - 2 * 2, track_size.y - 2 * 2);

    const half_width = knob_size.x / 2.0;

    const knob_min = pos.x;
    const knob_max = pos.x + (track_size.x - knob_size.x);

    var knob_x = linmap(slider_val.*, val_min, val_max, knob_min, knob_max);
    var knob_rect = rectfwh(knob_x, pos.y, knob_size.x, knob_size.y);

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
            v2f(@intToFloat(f32, mouse.*.button1_begin_x), @intToFloat(f32, mouse.*.button1_begin_y)),
        ) or
            collision_rectf_v2f(
            track_rect,
            v2f(@intToFloat(f32, mouse.*.button1_begin_x), @intToFloat(f32, mouse.*.button1_begin_y)),
        )) {
            knob_mid = @intToFloat(f32, mouse.*.x);
            grabbed.* = true;
        }
    }

    knob_x = std.math.clamp(knob_mid - half_width, @as(f32, knob_min), @as(f32, knob_max));
    slider_val.* = linmap(knob_x, knob_min, knob_max, val_min, val_max);

    knob_rect = rectfwh(knob_x, pos.y, knob_size.x, knob_size.y);
    const knob_rect_inner = rectfwh(knob_x + 5, pos.y + 5, knob_size.x - 5 * 2, knob_size.y - 5 * 2);

    renderer.draw_rect(colr3f(0.0, 0.0, 0.0), track_rect);
    renderer.draw_rect(colr3f(0.5, 0.5, 0.5), track_rect_inner);
    renderer.draw_rect(colr3f(0.0, 0.0, 0.0), knob_rect);
    renderer.draw_rect(colr3f(1.0, 1.0, 1.0), knob_rect_inner);
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
    {
        turtle_begin();
        defer turtle_end();

        turtle_push(.Horizontal, .{});
        defer turtle_pop();
        turtle_push(.Rect, .{ .left = 100, .top = 200, .right = 300, .bottom = 400 });
        defer turtle_pop();
    }
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

    //var default_screen = DefaultScreen(display);
    var default_screen = (@import("std").meta.cast(_XPrivDisplay, display)).*.default_screen;
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

    var renderer = Renderer.init(rectfwh(0, 0, @intToFloat(f32, display_width), @intToFloat(f32, display_height)));

    var colour_select_hue: f32 = 200.0;
    var colour_select_saturation: f32 = 60.0;
    var colour_select_lightness: f32 = 40.0;
    var colour_select_hue_grabbed = false;
    var colour_select_saturation_grabbed = false;
    var colour_select_lightness_grabbed = false;

    var mouse_state = MouseState{};

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

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
            renderer.display_rect = rectfwh(0, 0, @intToFloat(f32, display_width), @intToFloat(f32, display_height));
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

            const fg_lightness = if (colour_select_lightness < lighter_min_L)
                hsluv.contrast.lighterMinL(contrast_ratio, colour_select_lightness)
            else
                hsluv.contrast.darkerMaxL(contrast_ratio, colour_select_lightness);

            //std.debug.warn("fg={} bg={}\n", .{ fg_lightness, colour_select_lightness });

            const hsl_bg = [3]f64{
                colour_select_hue,
                colour_select_saturation,
                colour_select_lightness,
            };
            //const hsl_bg = hsluv.rgbToHsluv([3]f64{ 0.1, 1.0, 0.5 });
            //std.debug.warn("HSL={} {} {}\n", .{ hsl[0], hsl[1], hsl[2] });
            const clear_colour = hsluv.hsluvToRgb(hsl_bg);

            //glClearColor(0.0 / 255.0, 117.0 / 255.0, 179.0 / 255.0, 1.0);
            glClearColor(@floatCast(f32, clear_colour[0]), @floatCast(f32, clear_colour[1]), @floatCast(f32, clear_colour[2]), 1.0);
            //std.debug.warn("rgb = {} {} {}\n", .{ @floatToInt(i32, clear_colour[0] * 255), @floatToInt(i32, clear_colour[1] * 255), @floatToInt(i32, clear_colour[2] * 255) });
            glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

            const hsl_fg = [3]f64{
                colour_select_hue,
                colour_select_saturation,
                fg_lightness,
            };
            const text_colour_array = hsluv.hsluvToRgb(hsl_fg);
            const text_colour = colr3f(@floatCast(f32, text_colour_array[0]), @floatCast(f32, text_colour_array[1]), @floatCast(f32, text_colour_array[2]));

            var layout_cursor = Vector2f{ .x = 40.0, .y = 300 };

            drawSlider(
                &renderer,
                &colour_select_hue,
                0.0,
                360.0,
                layout_cursor,
                Vector2f{ .x = 20, .y = 40 },
                Vector2f{ .x = 400, .y = 10 },
                &colour_select_hue_grabbed,
                &mouse_state,
            );
            layout_cursor.add(v2f(0.0, 50));

            drawSlider(
                &renderer,
                &colour_select_saturation,
                0.0,
                100.0,
                layout_cursor,
                Vector2f{ .x = 20, .y = 40 },
                Vector2f{ .x = 400, .y = 10 },
                &colour_select_saturation_grabbed,
                &mouse_state,
            );
            layout_cursor.add(v2f(0.0, 50));

            drawSlider(
                &renderer,
                &colour_select_lightness,
                0.0,
                100.0,
                layout_cursor,
                Vector2f{ .x = 20, .y = 40 },
                Vector2f{ .x = 400, .y = 10 },
                &colour_select_lightness_grabbed,
                &mouse_state,
            );
            layout_cursor.add(v2f(0.0, 50));

            renderer.draw_simple_font_text(&hsluv.rgbToHex(clear_colour), text_colour, palette.shadow, Vector2f{ .x = 100, .y = 500 }, 3.0); // BG
            renderer.draw_simple_font_text(&hsluv.rgbToHex(text_colour_array), text_colour, palette.shadow, Vector2f{ .x = 280, .y = 500 }, 3.0); // FG

            const picker_geo = try hsluv.color_picker.getPickerGeometry(allocator, colour_select_lightness);
            defer picker_geo.deinit();

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
