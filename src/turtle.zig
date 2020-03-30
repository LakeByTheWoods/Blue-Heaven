const std = @import("std");
const assert = std.debug.assert;

const TurtleType = enum {
    Horizontal,
    Vertical,

    Style,

    Rect,
};

const TurtleRect = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
};

const TurtleStyle = struct {
    previous_style: ?*Turtle,
};

const TurtleLayout = struct {
    previous_layout: *Turtle,
    rect: TurtleRect,
};

const Turtle = union(TurtleType) {
    Horizontal: TurtleLayout,
    Vertical: TurtleLayout,
    Style: TurtleStyle,
    Rect: TurtleRect,
};

const max_turtles = 16 * 1024;

var turtle_tower: [max_turtles]Turtle = [_]Turtle{undefined} ** max_turtles;
var turtle_tower_top: usize = 0;

var turtle_stack: [max_turtles]usize = [_]usize{undefined} ** max_turtles;
var turtle_stack_top: usize = 0;

var turtle_default_style: Turtle = Turtle{ .Style = TurtleStyle{ .previous_style = null } };
var turtle_default_layout: Turtle = Turtle{ .Horizontal = TurtleLayout{ .previous_layout = undefined, .rect = TurtleRect{} } };

var turtle_current_style: *Turtle = &turtle_default_style;
var turtle_current_layout: *Turtle = &turtle_default_layout;

pub fn turtle_begin() void {
    assert(turtle_tower_top == 0); // Missed call to turtle_end

    turtle_current_style = &turtle_default_style;
    turtle_current_layout = &turtle_default_layout;
}

pub fn turtle_end() void {
    std.debug.warn("turtle_end ttt={}\n", .{turtle_tower_top});
    var style: *Turtle = &turtle_default_style;
    for (turtle_tower[0..turtle_tower_top]) |*t| {
        switch (t.*) {
            .Style => {
                style = t;
            },

            .Rect => |rect| {
                std.debug.warn("TURTLE RECT: {} {} {} {}\n", .{ rect.left, rect.top, rect.right, rect.bottom });
                // TODO: Callback
                // layout.callback(layout.context, layout.rect.left, layout.rect.top, layout.rect.right, layout,rect.bottom)
                // glBegin(GL_QUADS);
                // if (style)
                // {
                //     glColor4f(style.style.fg_colour.red,
                //               style.style.fg_colour.green,
                //               style.style.fg_colour.blue,
                //               style.style.fg_colour.alpha);
                // }

                // {
                //     glTexCoord2f(0.f, 0.f); glVertex2f(t.layout.rect.left,  t.layout.rect.top);
                //     glTexCoord2f(1.f, 0.f); glVertex2f(t.layout.rect.right, t.layout.rect.top);
                //     glTexCoord2f(1.f, 1.f); glVertex2f(t.layout.rect.right, t.layout.rect.bottom);
                //     glTexCoord2f(0.f, 1.f); glVertex2f(t.layout.rect.left,  t.layout.rect.bottom);
                // }
                // glEnd();
            },
            else => {
                std.debug.warn("Something else\n", .{});
            },
        }
    }
    turtle_tower_top = 0;
}

pub fn turtle_push(turtle_type: TurtleType, data: TurtleRect) void {
    var t: *Turtle = &turtle_tower[turtle_tower_top];

    turtle_stack_top += 1;
    turtle_stack[turtle_stack_top] = turtle_tower_top;

    turtle_tower_top += 1;
    assert(turtle_tower_top < max_turtles); // Too many turtles

    switch (turtle_type) {
        .Horizontal, .Vertical => {
            //printf("V: ");
            switch (turtle_current_layout.*) {
                .Horizontal => |layout| {
                    t.* = Turtle{
                        .Horizontal = TurtleLayout{
                            .previous_layout = turtle_current_layout,
                            .rect = TurtleRect{
                                .left = layout.rect.right,
                                .right = layout.rect.right,
                                .top = layout.rect.top,
                                .bottom = layout.rect.top,
                            },
                        },
                    };
                    //printf("IH %f %f %f %f\n", (double)turtle_current_layout.layout.rect.left, (double)turtle_current_layout.layout.rect.top, (double)turtle_current_layout.layout.rect.right, (double)turtle_current_layout.layout.rect.bottom);
                },

                .Vertical => |layout| {
                    t.* = Turtle{
                        .Vertical = TurtleLayout{
                            .previous_layout = turtle_current_layout,
                            .rect = TurtleRect{
                                .left = layout.rect.left,
                                .right = layout.rect.left,
                                .top = layout.rect.bottom,
                                .bottom = layout.rect.bottom,
                            },
                        },
                    };
                    //printf("IV %f %f %f %f\n", (double)turtle_current_layout.layout.rect.left, (double)turtle_current_layout.layout.rect.top, (double)turtle_current_layout.layout.rect.right, (double)turtle_current_layout.layout.rect.bottom);
                },
                else => {},
            }

            turtle_current_layout = t;
        },

        .Style => {
            t.* = turtle_current_style.*;
            t.Style.previous_style = turtle_current_style;
            turtle_current_style = t;
        },

        .Rect => {
            //assert(data, "Turtle Rect requires user data\n");
            const rect: TurtleRect = data; //@as(TurtleRect, data);
            switch (turtle_current_layout.*) {
                .Horizontal => |layout| {
                    std.debug.warn("Rect on hrz\n", .{});
                    t.* = Turtle{
                        .Rect = TurtleRect{
                            .left = layout.rect.right,
                            .right = layout.rect.left + rect.right,
                            .top = layout.rect.top,
                            .bottom = layout.rect.top + rect.bottom,
                        },
                    };
                },

                .Vertical => |layout| {
                    std.debug.warn("Rect on vrt\n", .{});
                    t.* = Turtle{
                        .Rect = TurtleRect{
                            .left = layout.rect.left,
                            .right = layout.rect.left + rect.right,
                            .top = layout.rect.bottom,
                            .bottom = layout.rect.top + rect.bottom,
                        },
                    };
                },

                else => {},
            }
        },
    }
}

pub fn turtle_pop() void {
    const t: *Turtle = &turtle_tower[turtle_stack[turtle_stack_top - 1]];
    turtle_stack_top -= 1;

    switch (t.*) {
        .Horizontal, .Vertical => |layout| {
            turtle_current_layout = layout.previous_layout;
        },

        .Style => |style| {
            if (style.previous_style) |previous_style| {
                turtle_push(.Style, .{});
                const return_to_old = &turtle_tower[turtle_stack[turtle_stack_top - 1]];
                turtle_stack_top -= 1; // We don't want a matching pop for the above push
                return_to_old.* = previous_style.*;
            }
        },
        else => {},
    }

    switch (t.*) {
        .Horizontal,
        .Vertical,
        => |tlayout| {
            switch (turtle_current_layout.*) {
                .Horizontal => |*layout| {
                    layout.rect.right = tlayout.rect.right;
                    layout.rect.bottom = std.math.max(layout.rect.bottom, tlayout.rect.bottom);
                    //printf("OH %f %f %f %f\n", (double)turtle_current_layout.Layout.rect.left, (double)turtle_current_layout.Layout.rect.top, (double)turtle_current_layout.Layout.rect.right, (double)turtle_current_layout.Layout.rect.bottom);
                },
                .Vertical => |*layout| {
                    layout.rect.right = std.math.max(layout.rect.right, tlayout.rect.right);
                    layout.rect.bottom = tlayout.rect.bottom;
                    //printf("OV %f %f %f %f\n", (double)turtle_current_layout.Layout.rect.left, (double)turtle_current_layout.Layout.rect.top, (double)turtle_current_layout.Layout.rect.right, (double)turtle_current_layout.Layout.rect.bottom);
                },
                else => {},
            }
        },
        .Rect => |rect| {
            switch (turtle_current_layout.*) {
                .Horizontal => |*layout| {
                    layout.rect.right = rect.right;
                    layout.rect.bottom = std.math.max(layout.rect.bottom, rect.bottom);
                    //printf("OH %f %f %f %f\n", (double)turtle_current_layout.Layout.rect.left, (double)turtle_current_layout.Layout.rect.top, (double)turtle_current_layout.Layout.rect.right, (double)turtle_current_layout.Layout.rect.bottom);
                },
                .Vertical => |*layout| {
                    layout.rect.right = std.math.max(layout.rect.right, rect.right);
                    layout.rect.bottom = rect.bottom;
                    //printf("OV %f %f %f %f\n", (double)turtle_current_layout.Layout.rect.left, (double)turtle_current_layout.Layout.rect.top, (double)turtle_current_layout.Layout.rect.right, (double)turtle_current_layout.Layout.rect.bottom);
                },
                else => {},
            }
        },
        else => {},
    }
}
