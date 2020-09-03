const std = @import("std");

pub const Vector2f = packed struct {
    x: f32 = 0.0,
    y: f32 = 0.0,

    pub fn add(self: *Vector2f, other: Vector2f) void {
        self.*.x += other.x;
        self.*.y += other.y;
    }
};

pub fn v2f(x: f32, y: f32) Vector2f {
    return Vector2f{ .x = x, .y = y };
}

pub fn v2fAdd(a: Vector2f, b: Vector2f) Vector2f {
    return Vector2f{ .x = a.x + b.x, .y = a.y + b.y };
}

pub const Vector3f = packed struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
};

pub fn v3f(x: f32, y: f32, z: f32) Vector2f {
    return Vector3f{ .x = x, .y = y, .z = z };
}

pub const Rectf = struct {
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

pub fn rectfwh(pos_x: f32, pos_y: f32, size_x: f32, size_y: f32) Rectf {
    return Rectf{ .tl = v2f(pos_x, pos_y), .br = v2f(pos_x + size_x, pos_y + size_y) };
}

pub fn collision_rectf_v2f(rect: Rectf, v: Vector2f) bool {
    return (v.x > rect.tl.x and v.x < rect.br.x and v.y > rect.tl.y and v.y < rect.br.y);
}

pub fn lerp(t: anytype, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
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

pub fn unlerp(comptime ReturnType: type, v: anytype, a: @TypeOf(v), b: @TypeOf(v)) ReturnType {
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

pub fn linmap(v: anytype, a: @TypeOf(v), b: @TypeOf(v), c: @TypeOf(v), d: @TypeOf(v)) @TypeOf(v) {
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

pub const Color3f = packed struct {
    r: f32 = 0.0,
    g: f32 = 0.0,
    b: f32 = 0.0,
};

pub fn colr3f(r: f32, g: f32, b: f32) Color3f {
    return Color3f{ .r = r, .g = g, .b = b };
}

pub const palette = struct {
    pub const blue_heaven = hexToColr3f(0x0075b3);
    pub const raspberry = hexToColr3f(0xff5a5f);

    pub const honeycomb = hexToColr3f(0xefa00b);

    pub const shadow = hexToColr3f(0x3c3c3c);
    pub const ice_cream = hexToColr3f(0xf5f5f5);
};

pub fn hexToColr3f(hex: u24) Color3f {
    return Color3f{
        .r = @intToFloat(f32, (hex & 0xFF0000) >> 16) / 255.0,
        .g = @intToFloat(f32, (hex & 0xFF00) >> 8) / 255.0,
        .b = @intToFloat(f32, (hex & 0xFF) >> 0) / 255.0,
    };
}
