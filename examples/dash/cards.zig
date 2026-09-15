//! Section cards: the metric row and the visitors chart card.

const zui = @import("zui");

const chart = @import("chart.zig");
const data = @import("data.zig");
const icons = @import("icons.zig");
const theme = @import("theme.zig");
const ui = @import("ui.zig");

const Dash = @import("main.zig").Dash;
const Range = @import("main.zig").Range;

/// `width` is the page's content width: a definite constraint lets the row
/// wrap 4 -> 2 -> 1 cards as the window narrows.
pub fn metrics(width: f32) zui.Element {
    var row = zui.div().flex_row().flex_wrap().w(width).gap(16);
    for (&data.METRICS) |*metric| row = row.child(metricCard(metric));
    return row;
}

fn metricCard(metric: *const data.Metric) zui.Element {
    return zui.div().flex_1().w(300).flex_col().h(184).p(24).rounded_xl().bg(theme.card_metric)
        .border_1().border_color(theme.card_border)
        .child(zui.div().flex_row().items_center().justify_between()
            .child(ui.label(metric.title, 14, theme.muted))
            .child(deltaBadge(metric)))
        .child(zui.div().pt(10).child(zui.text(metric.value, .{
            .font = theme.font,
            .size = 30,
            .line_height = 36,
            .weight = .semibold,
            .color = theme.text,
        })))
        .child(zui.spacer())
        .child(zui.div().flex_row().items_center().gap(6)
            .child(ui.strong(metric.foot, 14, theme.text))
            .child(ui.icon(if (metric.foot_up) icons.trending_up else icons.trending_down, 16, theme.text)))
        .child(zui.div().pt(6).child(ui.label(metric.sub, 14, theme.muted)));
}

fn deltaBadge(metric: *const data.Metric) zui.Element {
    return zui.div().flex_row().items_center().gap(4).h(22).px(8).rounded_full()
        .border_1().border_color(theme.card_border)
        .child(ui.icon(if (metric.up) icons.trending_up else icons.trending_down, 12, theme.muted))
        .child(ui.label(metric.delta, 12, theme.muted));
}

pub fn chartCard(dash: *Dash, body_width: f32, cx: *zui.Context(Dash)) zui.Element {
    const svg = dash.chart_svg orelse "";
    const plot_h = dash.plotHeight(body_width);
    return zui.div().flex_col().p(24).rounded_xl().bg(theme.card)
        .border_1().border_color(theme.card_border)
        .child(zui.div().flex_row().items_center().justify_between()
            .child(zui.div().flex_col().gap(4)
                .child(ui.strong("Total Visitors", 16, theme.text))
                .child(ui.label(dash.range.description(), 14, theme.muted)))
            .child(segmented(dash.range, cx)))
        .child(zui.div().pt(24).w_full().h(plot_h)
            .child(zui.svg(svg).w_full().h(plot_h).object_fit(.fill)))
        .child(labelsRow(dash.range, body_width - 48));
}

fn segmented(active: Range, cx: *zui.Context(Dash)) zui.Element {
    var row = zui.div().flex_row().items_center().p(2).gap(2).rounded_lg()
        .border_1().border_color(theme.card_border);
    inline for (.{ Range.months90, Range.days30, Range.days7 }) |value| {
        row = row.child(segment(value, active, cx));
    }
    return row;
}

fn segment(value: Range, active: Range, cx: *zui.Context(Dash)) zui.Element {
    const is_active = value == active;
    var item = zui.div().flex_row().items_center().h(28).px(12).rounded_lg().cursor_pointer()
        .on_click(cx.listenerWith(Range, Dash, setRange, value));
    item = if (is_active) item.bg(theme.tab_active) else item.hover_bg(theme.hover);
    return item.child(ui.label(value.label(), 14, if (is_active) theme.text else theme.muted));
}

fn setRange(dash: *Dash, value: Range, cx: *zui.Context(Dash)) void {
    if (dash.range == value) return;
    dash.setRange(value);
    cx.notify();
}

/// The x labels the target shows: every fifth day plus the final day,
/// absolutely placed under the sample they belong to.
fn labelsRow(range: Range, plot_width: f32) zui.Element {
    const days = range.days(&data.DAYS);
    var row = zui.div().w_full().h(20).pt(8);
    const last_x = labelX(days.len - 1, days.len, plot_width);
    var index: usize = 4;
    while (index < days.len) : (index += 5) {
        // Keep the tail labels from colliding with the final date.
        if (labelX(index, days.len, plot_width) > last_x - 44) break;
        row = row.child(xLabel(days[index].label, index, days.len, plot_width));
    }
    if (days.len > 1) {
        row = row.child(xLabel(days[days.len - 1].label, days.len - 1, days.len, plot_width));
    }
    return row;
}

fn labelX(index: usize, count: usize, plot_width: f32) f32 {
    const frac = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count - 1));
    return (10.0 + frac * 1180.0) * (plot_width / 1200.0);
}

fn xLabel(text: []const u8, index: usize, count: usize, plot_width: f32) zui.Element {
    // Match the SVG's 10px side padding and stretch to the element width.
    return zui.div().absolute().left(labelX(index, count, plot_width) - 15).top(8).w(64)
        .child(ui.label(text, 11, theme.faint));
}
