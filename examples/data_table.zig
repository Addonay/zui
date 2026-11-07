//! Port of GPUI's `examples/data_table.rs`.
//!
//! Differences from the Rust version:
//! - `example_support::load_fonts` is a no-op on native platforms, so it is not called.
//! - The quotes are a slice owned by the table, not `Vec<Rc<Quote>>`. Rows borrow `&quotes[ix]`,
//!   which gives the same sharing without reference counting.
//! - No `rand` crate: values come from `std.Random` with a fixed seed (`SEED`), so every run
//!   shows the same quotes. Rust draws a new set each run.
//! - `Duration` is stored as whole seconds (`timestamp_secs`), since only `as_secs()` is shown.
//! - The Rust `match key` over field names is an enum `Field` whose tag names are the keys.
//! - `TableRow` is `RenderOnce` in Rust. Here `table_row` is a function returning a `*Div`.

const std = @import("std");
const gpui = @import("zui");
const App = gpui.App;
const Bounds = gpui.Bounds;
const ClickEvent = gpui.ClickEvent;
const Context = gpui.Context;
const DispatchPhase = gpui.window.DispatchPhase;
const Div = gpui.Div;
const Entity = gpui.Entity;
const Hsla = gpui.Hsla;
const MouseDownEvent = gpui.MouseDownEvent;
const MouseMoveEvent = gpui.MouseMoveEvent;
const MouseUpEvent = gpui.MouseUpEvent;
const Pixels = gpui.Pixels;
const Point = gpui.Point;
const Range = gpui.Range;
const ScrollHandle = gpui.ScrollHandle;
const UniformListScrollHandle = gpui.UniformListScrollHandle;
const Window = gpui.Window;
const WindowBounds = gpui.WindowBounds;
const WindowOptions = gpui.WindowOptions;
const canvas = gpui.canvas;
const div = gpui.div;
const px = gpui.px;
const rgb = gpui.rgb;
const size = gpui.size;
const uniform_list = gpui.uniform_list;

const TOTAL_ITEMS: usize = 10000;
/// Fixed, so every run shows the same quotes. GPUI uses `rand::rng()`.
const SEED: u64 = 0x5eed_0000_0000_0001;
const SCROLLBAR_THUMB_WIDTH: Pixels = 8.0;
const SCROLLBAR_THUMB_HEIGHT: Pixels = 100.0;

const Quote = struct {
    name: []const u8,
    symbol: []const u8,
    last_done: f64,
    prev_close: f64,
    open: f64,
    high: f64,
    low: f64,
    timestamp_secs: u64,
    volume: i64,
    turnover: f64,
    ttm: f64,
    market_cap: f64,
    float_cap: f64,
    shares: f64,
    pb: f64,
    pe: f64,
    eps: f64,
    dividend: f64,
    dividend_yield: f64,
    dividend_per_share: f64,
    dividend_date: []const u8,
    dividend_payment: f64,

    fn rand_f64(rng: std.Random, lo: f64, hi: f64) f64 {
        return lo + rng.float(f64) * (hi - lo);
    }

    /// `lo..hi`, exclusive upper bound, as Rust's `random_range`.
    fn rand_i64(rng: std.Random, lo: i64, hi: i64) i64 {
        return rng.intRangeLessThan(i64, lo, hi);
    }

    fn random(allocator: std.mem.Allocator, rng: std.Random) !Quote {
        // simulate a base price in a realistic range
        const prev_close = rand_f64(rng, 100.0, 200.0);
        const change_amount = rand_f64(rng, -5.0, 5.0);
        const last_done = prev_close + change_amount;
        const open = prev_close + rand_f64(rng, -3.0, 3.0);
        const high = @max(prev_close + rand_f64(rng, 0.0, 10.0), open);
        const low = @min(prev_close - rand_f64(rng, 0.0, 10.0), open);
        const timestamp_secs: u64 = @intCast(rand_i64(rng, 0, 86400));
        const volume = rand_i64(rng, 1_000_000, 100_000_000);
        const turnover = last_done * @as(f64, @floatFromInt(volume));

        const ticker = if (rng.boolean())
            try std.fmt.allocPrint(allocator, "{d:0>3}.{d}", .{ rand_i64(rng, 100, 1000), rand_i64(rng, 0, 10) })
        else
            try std.fmt.allocPrint(allocator, "{c}{c}", .{ rand_char(rng), rand_char(rng) });
        const symbol = try std.fmt.allocPrint(allocator, "{s}.{c}", .{ ticker, rand_char(rng) });

        const name = try std.fmt.allocPrint(allocator, "{s} {d} - #{d}", .{
            symbol,
            rand_i64(rng, 1, 100),
            rand_i64(rng, 10000, 100000),
        });

        const ttm = rand_f64(rng, 0.0, 10.0);
        const market_cap = rand_f64(rng, 1_000_000.0, 10_000_000.0);
        const float_cap = market_cap + rand_f64(rng, 1_000.0, 10_000.0);
        const shares = rand_f64(rng, 100.0, 1000.0);
        const pb = market_cap / shares;
        const pe = market_cap / shares;
        const eps = market_cap / shares;
        const dividend = rand_f64(rng, 0.0, 10.0);
        const dividend_yield = rand_f64(rng, 0.0, 10.0);
        const dividend_per_share = rand_f64(rng, 0.0, 10.0);
        const dividend_date = try std.fmt.allocPrint(allocator, "{d}-{d}-{d}", .{
            rand_i64(rng, 2000, 2023),
            rand_i64(rng, 1, 12),
            rand_i64(rng, 1, 28),
        });
        const dividend_payment = rand_f64(rng, 0.0, 10.0);

        return .{
            .name = name,
            .symbol = symbol,
            .last_done = last_done,
            .prev_close = prev_close,
            .open = open,
            .high = high,
            .low = low,
            .timestamp_secs = timestamp_secs,
            .volume = volume,
            .turnover = turnover,
            .pb = pb,
            .pe = pe,
            .eps = eps,
            .ttm = ttm,
            .market_cap = market_cap,
            .float_cap = float_cap,
            .shares = shares,
            .dividend = dividend,
            .dividend_yield = dividend_yield,
            .dividend_per_share = dividend_per_share,
            .dividend_date = dividend_date,
            .dividend_payment = dividend_payment,
        };
    }

    fn rand_char(rng: std.Random) u8 {
        return @intCast(rand_i64(rng, 'A', 'Z' + 1));
    }

    fn change(self: *const Quote) f64 {
        return (self.last_done - self.prev_close) / self.prev_close * 100.0;
    }

    fn change_color(self: *const Quote) Hsla {
        if (self.change() > 0.0) return gpui.green();
        return gpui.red();
    }

    fn turnover_ratio(self: *const Quote) f64 {
        return @as(f64, @floatFromInt(self.volume)) / self.turnover * 100.0;
    }
};

/// The columns, in order. The header and every row use the same widths.
const Field = enum {
    id,
    symbol,
    name,
    last_done,
    prev_close,
    open,
    low,
    high,
    ttm,
    market_cap,
    float_cap,
    turnover,
    volume,
    turnover_ratio,
    pe,
    pb,
    eps,
    shares,
    dividend,
    yield,
    dividend_per_share,
    dividend_date,
    dividend_payment,
    timestamp,
};

const Column = struct { field: Field, width: f32 };

const FIELDS = [_]Column{
    .{ .field = .id, .width = 64.0 },
    .{ .field = .symbol, .width = 64.0 },
    .{ .field = .name, .width = 180.0 },
    .{ .field = .last_done, .width = 80.0 },
    .{ .field = .prev_close, .width = 80.0 },
    .{ .field = .open, .width = 80.0 },
    .{ .field = .low, .width = 80.0 },
    .{ .field = .high, .width = 80.0 },
    .{ .field = .ttm, .width = 50.0 },
    .{ .field = .market_cap, .width = 96.0 },
    .{ .field = .float_cap, .width = 96.0 },
    .{ .field = .turnover, .width = 120.0 },
    .{ .field = .volume, .width = 100.0 },
    .{ .field = .turnover_ratio, .width = 96.0 },
    .{ .field = .pe, .width = 64.0 },
    .{ .field = .pb, .width = 64.0 },
    .{ .field = .eps, .width = 64.0 },
    .{ .field = .shares, .width = 96.0 },
    .{ .field = .dividend, .width = 64.0 },
    .{ .field = .yield, .width = 64.0 },
    .{ .field = .dividend_per_share, .width = 64.0 },
    .{ .field = .dividend_date, .width = 96.0 },
    .{ .field = .dividend_payment, .width = 64.0 },
    .{ .field = .timestamp, .width = 120.0 },
};

fn render_cell(ix: usize, quote: *const Quote, field: Field, color: Hsla, width: f32) *Div {
    const content: *Div = switch (field) {
        .id => div().child(gpui.format("{d}", .{ix})),
        .symbol => div().child(quote.symbol),
        .name => div().child(quote.name),
        .last_done => div().text_color(color).child(gpui.format("{d:.3}", .{quote.last_done})),
        .prev_close => div().text_color(color).child(gpui.format("{d:.3}", .{quote.prev_close})),
        .turnover_ratio => div().child(gpui.format("{d:.2}%", .{quote.turnover_ratio()})),
        .timestamp => div().text_color(color).child(gpui.format("{d}", .{quote.timestamp_secs})),
        .open => div().text_color(color).child(gpui.format("{d:.2}", .{quote.open})),
        .low => div().text_color(color).child(gpui.format("{d:.2}", .{quote.low})),
        .high => div().text_color(color).child(gpui.format("{d:.2}", .{quote.high})),
        .ttm => div().text_color(color).child(gpui.format("{d:.2}", .{quote.ttm})),
        .eps => div().text_color(color).child(gpui.format("{d:.2}", .{quote.eps})),
        .market_cap => div().child(gpui.format("{d:.2} M", .{quote.market_cap / 1_000_000.0})),
        .float_cap => div().child(gpui.format("{d:.2} M", .{quote.float_cap / 1_000_000.0})),
        .turnover => div().child(gpui.format("{d:.2} M", .{quote.turnover / 1_000_000.0})),
        .volume => div().child(gpui.format("{d:.2} M", .{@as(f64, @floatFromInt(quote.volume)) / 1_000_000.0})),
        .pe => div().child(gpui.format("{d:.2}", .{quote.pe})),
        .pb => div().child(gpui.format("{d:.2}", .{quote.pb})),
        .shares => div().child(gpui.format("{d:.2}", .{quote.shares})),
        .dividend => div().child(gpui.format("{d:.2}", .{quote.dividend})),
        .yield => div().child(gpui.format("{d:.2}%", .{quote.dividend_yield})),
        .dividend_per_share => div().child(gpui.format("{d:.2}", .{quote.dividend_per_share})),
        .dividend_date => div().child(quote.dividend_date),
        .dividend_payment => div().child(gpui.format("{d:.2}", .{quote.dividend_payment})),
    };
    return div()
        .whitespace_nowrap()
        .truncate()
        .w(px(width))
        .px_1()
        .child(content);
}

/// `TableRow::render`: one row, zebra-striped by index.
fn table_row(ix: usize, quote: *const Quote) *Div {
    const color = quote.change_color();
    var row = div()
        .flex()
        .flex_row()
        .border_b_1()
        .border_color(rgb(0xE0E0E0))
        .bg(if (ix % 2 == 0) rgb(0xFFFFFF) else rgb(0xFAFAFA))
        .py_0p5()
        .px_2();
    for (FIELDS) |column| {
        row = row.child(render_cell(ix, quote, column.field, color, column.width));
    }
    return row;
}

/// Upper-cases a field name and turns `_` into spaces, as `key.replace("_", " ").to_uppercase()`.
fn header_label(key: []const u8) []const u8 {
    const out = gpui.window.frame_arena().alloc(u8, key.len) catch @panic("OOM");
    for (key, 0..) |c, i| out[i] = if (c == '_') ' ' else std.ascii.toUpper(c);
    return out;
}

fn header_cell(column: Column) *Div {
    return div()
        .whitespace_nowrap()
        .flex_shrink_0()
        .truncate()
        .px_1()
        .w(px(column.width))
        .child(header_label(@tagName(column.field)));
}

fn clamp_px(v: Pixels, lo: Pixels, hi: Pixels) Pixels {
    return @max(lo, @min(v, hi));
}

/// What the scrollbar thumb's canvas captures, and what its mouse listeners need.
const ThumbDrag = struct {
    entity: Entity(DataTable),
    thumb_bounds: Bounds(Pixels),
    table_bounds: Bounds(Pixels),
    scroll_height: Pixels,
    scroll_handle: ScrollHandle,
};

const DataTable = struct {
    allocator: std.mem.Allocator,
    quotes: []Quote,
    visible_range: Range,
    scroll_handle: UniformListScrollHandle,
    /// The position in thumb bounds when dragging start mouse down.
    drag_position: ?Point(Pixels),

    fn new(allocator: std.mem.Allocator) DataTable {
        return .{
            .allocator = allocator,
            .quotes = &.{},
            .visible_range = .{},
            .scroll_handle = UniformListScrollHandle.new(),
            .drag_position = null,
        };
    }

    fn generate(self: *DataTable) !void {
        var prng = std.Random.DefaultPrng.init(SEED);
        const rng = prng.random();

        const quotes = try self.allocator.alloc(Quote, TOTAL_ITEMS);
        for (quotes) |*quote| quote.* = try Quote.random(self.allocator, rng);
        self.quotes = quotes;
    }

    fn table_bounds(self: *const DataTable) Bounds(Pixels) {
        return self.scroll_handle.state.base_handle.bounds();
    }

    fn scroll_top(self: *const DataTable) Pixels {
        return self.scroll_handle.state.base_handle.offset().y;
    }

    fn scroll_height(self: *const DataTable) Pixels {
        const item_size: gpui.elements.uniform_list.ItemSize = self.scroll_handle.state.last_item_size orelse .{};
        return item_size.contents.height;
    }

    fn begin_drag(this: *DataTable, pos: Point(Pixels), _: *Context(DataTable)) void {
        this.drag_position = pos;
    }

    fn end_drag(this: *DataTable, _: *Context(DataTable)) void {
        this.drag_position = null;
    }

    fn on_thumb_down(ctx: *anyopaque, ev: *const MouseDownEvent, _: DispatchPhase, _: *Window, cx: *App) void {
        const drag: *ThumbDrag = @ptrCast(@alignCast(ctx));
        if (!drag.thumb_bounds.contains(ev.position)) return;

        drag.entity.update(cx, begin_drag, .{ ev.position.sub(drag.thumb_bounds.origin).sub(drag.table_bounds.origin) });
    }

    fn on_thumb_up(ctx: *anyopaque, _: *const MouseUpEvent, _: DispatchPhase, _: *Window, cx: *App) void {
        const drag: *ThumbDrag = @ptrCast(@alignCast(ctx));
        drag.entity.update(cx, end_drag, .{});
    }

    fn on_thumb_move(ctx: *anyopaque, ev: *const MouseMoveEvent, _: DispatchPhase, _: *Window, cx: *App) void {
        const drag: *ThumbDrag = @ptrCast(@alignCast(ctx));
        if (!ev.dragging()) return;

        const drag_pos = drag.entity.read(cx).drag_position orelse return;

        const table = drag.table_bounds;
        const inside_offset = drag_pos.y;
        const percentage = clamp_px(
            (ev.position.y - table.origin.y + inside_offset) / table.size.height,
            0.0,
            1.0,
        );

        const offset_y = clamp_px(
            (drag.scroll_height - table.size.height) * percentage,
            0.0,
            drag.scroll_height - SCROLLBAR_THUMB_HEIGHT,
        );
        drag.scroll_handle.set_offset(.{ .x = px(0.0), .y = -offset_y });
        cx.notify(drag.entity.entity_id());
    }

    fn prepaint_thumb(_: ThumbCanvas, _: Bounds(Pixels), _: *Window, _: *App) void {}

    /// What the thumb's canvas captures from `render_scrollbar`.
    const ThumbCanvas = struct {
        entity: Entity(DataTable),
        table_bounds: Bounds(Pixels),
        scroll_height: Pixels,
        scroll_handle: ScrollHandle,
    };

    fn paint_thumb(c: ThumbCanvas, thumb_bounds: Bounds(Pixels), _: *void, window: *Window, _: *App) void {
        const drag = gpui.window.frame_arena().create(ThumbDrag) catch @panic("OOM");
        drag.* = .{
            .entity = c.entity,
            .thumb_bounds = thumb_bounds,
            .table_bounds = c.table_bounds,
            .scroll_height = c.scroll_height,
            .scroll_handle = c.scroll_handle,
        };
        window.on_mouse_event(MouseDownEvent, drag, on_thumb_down);
        window.on_mouse_event(MouseUpEvent, drag, on_thumb_up);
        window.on_mouse_event(MouseMoveEvent, drag, on_thumb_move);
    }

    fn render_scrollbar(self: *DataTable, _: *Window, cx: *Context(DataTable)) *Div {
        const content_height = self.scroll_height();
        const table = self.table_bounds();
        const table_height = table.size.height;
        if (table_height == 0) return div().id("scrollbar");

        const percentage = -self.scroll_top() / content_height;
        const offset_top = clamp_px(
            table_height * percentage,
            px(4.0),
            @max(px(4.0), table_height - SCROLLBAR_THUMB_HEIGHT - px(4.0)),
        );
        const entity = cx.entity();
        const scroll_handle = self.scroll_handle.state.base_handle;

        return div()
            .id("scrollbar")
            .absolute()
            .top(offset_top)
            .right_1()
            .h(SCROLLBAR_THUMB_HEIGHT)
            .w(SCROLLBAR_THUMB_WIDTH)
            .bg(rgb(0xC0C0C0))
            .hover(gpui.style_refinement().bg(rgb(0xA0A0A0)))
            .rounded_lg()
            .child(
                canvas(ThumbCanvas{
                    .entity = entity,
                    .table_bounds = table,
                    .scroll_height = content_height,
                    .scroll_handle = scroll_handle,
                }, prepaint_thumb, paint_thumb).size_full(),
            );
    }

    fn render_items(this: *DataTable, range: Range, _: *Window, _: *Context(DataTable)) []gpui.AnyElement {
        this.visible_range = range;
        const alloc = gpui.window.frame_arena();
        var items: std.ArrayList(gpui.AnyElement) = .empty;
        var ix = range.start;
        while (ix < range.end) : (ix += 1) {
            if (ix < this.quotes.len) {
                items.append(alloc, gpui.into_any_element(table_row(ix, &this.quotes[ix]))) catch @panic("OOM");
            }
        }
        return items.items;
    }

    pub fn render(self: *DataTable, window: *Window, cx: *Context(DataTable)) *Div {
        var header = div()
            .flex()
            .flex_row()
            .w_full()
            .overflow_hidden()
            .border_b_1()
            .border_color(rgb(0xE0E0E0))
            .text_color(rgb(0x555555))
            .bg(rgb(0xF0F0F0))
            .py_1()
            .px_2()
            .text_xs();
        for (FIELDS) |column| header = header.child(header_cell(column));

        const list = uniform_list("items", self.quotes.len, cx.processor(render_items))
            .size_full()
            .track_scroll(&self.scroll_handle);
        const scrollbar = self.render_scrollbar(window, cx);

        return div()
            .bg(gpui.white())
            .text_sm()
            .size_full()
            .p_4()
            .gap_2()
            .flex()
            .flex_col()
            .child(gpui.format("Total {d} items, visible range: {d}..{d}", .{
                self.quotes.len,
                self.visible_range.start,
                self.visible_range.end,
            }))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .flex_1()
                    .overflow_hidden()
                    .border_1()
                    .border_color(rgb(0xE0E0E0))
                    .rounded_sm()
                    .child(header)
                    .child(
                        div()
                            .relative()
                            .size_full()
                            .child(list)
                            .child(scrollbar),
                    ),
            );
    }
};

fn build_root(_: *Window, app: *App) Entity(DataTable) {
    var table = DataTable.new(app.allocator);
    table.generate() catch @panic("OOM");
    return app.new(table);
}

fn run_example(cx: *App) void {
    const bounds = Bounds(Pixels).centered(null, size(px(1280.0), px(1000.0)), cx);
    _ = cx.open_window(.{ .focus = true, .window_bounds = .{ .windowed = bounds } }, build_root) catch unreachable;
    cx.activate(true);
}

pub fn main() void {
    gpui.Application.new().run(run_example);
}
