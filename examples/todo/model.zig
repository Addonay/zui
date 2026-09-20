//! Small, UI-independent task model used by the Daybook example.
const zui = @import("zui");

pub const page_size = 4;

pub const Todo = struct {
    id: u32,
    title: zui.SharedString,
    done: bool,
};

pub const Filter = enum {
    all,
    active,
    done,

    pub fn label(self: @This()) []const u8 {
        return switch (self) {
            .all => "All",
            .active => "Open",
            .done => "Done",
        };
    }
};

pub const Counts = struct { total: usize, done: usize, left: usize };

pub fn counts(todos: []const Todo) Counts {
    var done: usize = 0;
    for (todos) |todo| {
        if (todo.done) done += 1;
    }
    return .{ .total = todos.len, .done = done, .left = todos.len - done };
}

pub fn visible(filter: Filter, todo: Todo) bool {
    return switch (filter) {
        .all => true,
        .active => !todo.done,
        .done => todo.done,
    };
}
