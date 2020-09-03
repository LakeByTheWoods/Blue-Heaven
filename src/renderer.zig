const std = @import("std");
const assert = std.debug.assert;
usingnamespace @import("lmath.zig");

usingnamespace @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("GL/gl.h");
    @cInclude("GL/glx.h");
    @cInclude("GL/glext.h");

    @cInclude("simple_font.h");
});

fn glInitProc(comptime T: type, name: [:0]const u8) T {
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

pub const Renderer = struct {
    pub fn init(display_rect: Rectf) Renderer {

        //// Buffers
        glGenBuffers = glInitProc(PFNGLGENBUFFERSPROC, "glGenBuffers");
        glBindBuffer = glInitProc(PFNGLBINDBUFFERPROC, "glBindBuffer");
        glBufferData = glInitProc(PFNGLBUFFERDATAPROC, "glBufferData");

        //// Vertex Arrays and Attributes
        glVertexAttribPointer = glInitProc(PFNGLVERTEXATTRIBPOINTERPROC, "glVertexAttribPointer");
        glGenVertexArrays = glInitProc(PFNGLGENVERTEXARRAYSPROC, "glGenVertexArrays");
        glBindVertexArray = glInitProc(PFNGLBINDVERTEXARRAYPROC, "glBindVertexArray");
        glEnableVertexAttribArray = glInitProc(PFNGLENABLEVERTEXATTRIBARRAYPROC, "glEnableVertexAttribArray");
        glDisableVertexAttribArray = glInitProc(PFNGLDISABLEVERTEXATTRIBARRAYPROC, "glDisableVertexAttribArray");

        //// Uniforms
        glGetUniformLocation = glInitProc(PFNGLGETUNIFORMLOCATIONPROC, "glGetUniformLocation");
        glUniform2f = glInitProc(PFNGLUNIFORM2FPROC, "glUniform2f");
        glUniform4f = glInitProc(PFNGLUNIFORM4FPROC, "glUniform4f");
        glUniformMatrix4fv = glInitProc(PFNGLUNIFORMMATRIX4FVPROC, "glUniformMatrix4fv");

        //// Shader creation
        glCreateShader = glInitProc(PFNGLCREATESHADERPROC, "glCreateShader");
        glAttachShader = glInitProc(PFNGLATTACHSHADERPROC, "glAttachShader");
        glDetachShader = glInitProc(PFNGLDETACHSHADERPROC, "glDetachShader");
        glDeleteShader = glInitProc(PFNGLDELETESHADERPROC, "glDeleteShader");
        glShaderSource = glInitProc(PFNGLSHADERSOURCEPROC, "glShaderSource");
        glCompileShader = glInitProc(PFNGLCOMPILESHADERPROC, "glCompileShader");
        glGetShaderiv = glInitProc(PFNGLGETSHADERIVPROC, "glGetShaderiv");
        glGetShaderInfoLog = glInitProc(PFNGLGETSHADERINFOLOGPROC, "glGetShaderInfoLog");

        //// Program creation
        glCreateProgram = glInitProc(PFNGLCREATEPROGRAMPROC, "glCreateProgram");
        glLinkProgram = glInitProc(PFNGLLINKPROGRAMPROC, "glLinkProgram");
        glGetProgramiv = glInitProc(PFNGLGETPROGRAMIVPROC, "glGetProgramiv");
        glGetProgramInfoLog = glInitProc(PFNGLGETPROGRAMINFOLOGPROC, "glGetProgramInfoLog");
        glUseProgram = glInitProc(PFNGLUSEPROGRAMPROC, "glUseProgram");

        const shader_string_vertex_rect = @embedFile("../shaders/rectangle.vert");
        const shader_string_fragment_simple = @embedFile("../shaders/simple.frag");

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

        const program_rect = _renderer_build_one_off_program(shader_string_vertex_rect, shader_string_fragment_simple);
        const program_rect_uniform_location_rect = glGetUniformLocation.?(program_rect, "rect");
        const program_rect_uniform_location_rect_color = glGetUniformLocation.?(program_rect, "rect_color");
        const program_rect_uniform_location_screen_size = glGetUniformLocation.?(program_rect, "screen_size");

        glEnable(GL_DEPTH_TEST);
        //glEnable(GL_CULL_FACE);
        glEnable(GL_MULTISAMPLE);

        //glCullFace(GL_BACK);
        glDepthFunc(GL_LEQUAL);

        return Renderer{
            .display_rect = display_rect,

            ._program_rect = program_rect,
            ._program_rect_uniform_location_rect = program_rect_uniform_location_rect,
            ._program_rect_uniform_location_rect_color = program_rect_uniform_location_rect_color,
            ._program_rect_uniform_location_screen_size = program_rect_uniform_location_screen_size,
        };
    }

    pub fn draw_rect(self: *Renderer, color: Color3f, rect: Rectf) void {
        glUseProgram.?(self._program_rect);
        glUniform4f.?(self._program_rect_uniform_location_rect, rect.tl.x, rect.tl.y, rect.br.x, rect.br.y);
        glUniform4f.?(self._program_rect_uniform_location_rect_color, color.r, color.g, color.b, 1.0);
        glUniform2f.?(self._program_rect_uniform_location_screen_size, self.display_rect.width(), self.display_rect.height());
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }

    pub fn draw_simple_font_char(self: *Renderer, c: u8, fg_color: Color3f, bg_color: Color3f, left_baseline: Vector2f, size: f32) void {
        var y: f32 = left_baseline.y - 12.0 * size;

        var j: u8 = 0;
        while (j < 16) : (j += 1) {
            //std.debug.warn("{} {}\n", .{ c, j });
            const bits = simple_font[c][j];
            var i: u4 = 0;
            while (i < 8) : (i += 1) {
                const x = left_baseline.x + 8.0 * size - @intToFloat(f32, i) * size;
                if (bits & (@as(u8, 1) << @intCast(u3, i)) != 0) {
                    self.draw_rect(fg_color, Rectf{ .tl = Vector2f{ .x = x, .y = y }, .br = Vector2f{ .x = x + size, .y = y + size } });
                }
            }
            y += size;
        }
    }

    pub fn draw_simple_font_text(self: *Renderer, txt: []const u8, fg_color: Color3f, bg_color: Color3f, left_baseline: Vector2f, size: f32) void {
        var c_left_baseline = left_baseline;
        for (txt) |c| {
            switch (c) {
                '\n' => {
                    c_left_baseline.x = left_baseline.x;
                    c_left_baseline.y += 16 * size;
                },
                else => {
                    self.draw_simple_font_char(c, fg_color, bg_color, c_left_baseline, size);
                    c_left_baseline.x += 8 * size;
                },
            }
        }
    }

    display_rect: Rectf,

    _program_rect: GLuint = undefined,
    _program_rect_uniform_location_rect: GLint = undefined,
    _program_rect_uniform_location_rect_color: GLint = undefined,
    _program_rect_uniform_location_screen_size: GLint = undefined,
};
