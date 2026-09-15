//! Section cards (metrics + the visitors area chart).

use gpui_kit::assets::IconName;
use gpui_kit::component::Icon;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Context, Hsla, InteractiveElement as _, IntoElement, ParentElement as _, StatefulInteractiveElement as _,
    Styled as _, div, linear_color_stop, linear_gradient, px,
};

use crate::Dash;
use crate::data;
use crate::theme;

/// Time window for the visitors chart, mirroring the reference's toggle group.
#[derive(Clone, Copy, PartialEq, Default)]
pub enum Range {
    #[default]
    Months90,
    Days30,
    Days7,
}

impl Range {
    fn label(self) -> &'static str {
        match self {
            Range::Months90 => "Last 3 months",
            Range::Days30 => "Last 30 days",
            Range::Days7 => "Last 7 days",
        }
    }

    /// How many of the trailing days the window covers.
    fn days(self) -> usize {
        match self {
            Range::Months90 => data::DAYS.len(),
            Range::Days30 => 30,
            Range::Days7 => 7,
        }
    }

    /// Label stride: fewer points need denser ticks to stay readable.
    fn tick_margin(self) -> usize {
        match self {
            Range::Months90 => 5,
            Range::Days30 => 3,
            Range::Days7 => 1,
        }
    }

    fn all() -> [Range; 3] {
        [Range::Months90, Range::Days30, Range::Days7]
    }
}

pub fn metrics() -> impl IntoElement {
    div()
        .flex()
        .flex_wrap()
        .gap(px(16.))
        .children(data::METRICS.iter().map(metric_card))
}

fn metric_card(metric: &data::Metric) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .flex_1()
        .min_w(px(300.))
        .h(px(184.))
        .p(px(24.))
        .rounded(px(12.))
        .bg(theme::card_metric())
        .border_1()
        .border_color(theme::card_border())
        .child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .child(text(14., theme::muted(), metric.title))
                .child(delta_badge(metric.delta, metric.up)),
        )
        .child(
            div()
                .pt(px(10.))
                .text_size(px(30.))
                .line_height(px(36.))
                .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                .text_color(theme::text())
                .child(metric.value),
        )
        .child(div().flex_1())
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(6.))
                .child(text(14., theme::text(), metric.foot))
                .child(
                    Icon::new(if metric.foot_up {
                        IconName::TrendingUp
                    } else {
                        IconName::TrendingDown
                    })
                    .size(px(16.))
                    .text_color(theme::text()),
                ),
        )
        .child(div().pt(px(6.)).child(text(14., theme::muted(), metric.sub)))
}

fn delta_badge(delta: &str, up: bool) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .gap(px(4.))
        .h(px(22.))
        .px(px(8.))
        .rounded_full()
        .border_1()
        .border_color(theme::card_border())
        .child(
            Icon::new(if up {
                IconName::TrendingUp
            } else {
                IconName::TrendingDown
            })
            .size(px(12.))
            .text_color(theme::muted()),
        )
        .child(text(12., theme::muted(), delta))
}

pub fn chart_card(range: &Range, cx: &mut Context<Dash>) -> impl IntoElement {
    let range = *range;
    div()
        .flex()
        .flex_col()
        .p(px(24.))
        .rounded(px(12.))
        .bg(theme::card())
        .border_1()
        .border_color(theme::card_border())
        .child(
            div()
                .flex()
                .items_start()
                .justify_between()
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(4.))
                        .child(
                            div()
                                .text_size(px(16.))
                                .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                                .text_color(theme::text())
                                .child("Total Visitors"),
                        )
                        .child(text(
                            14.,
                            theme::muted(),
                            match range {
                                Range::Months90 => "Total for the last 3 months",
                                Range::Days30 => "Total for the last 30 days",
                                Range::Days7 => "Total for the last 7 days",
                            },
                        )),
                )
                .child(segmented(range, cx)),
        )
        .child(
            div()
                .pt(px(16.))
                .w_full()
                .h(px(300.))
                .child(visitors_chart(range)),
        )
}

fn visitors_chart(range: Range) -> impl IntoElement {
    let days: Vec<data::Day> = data::DAYS[data::DAYS.len() - range.days()..].to_vec();
    let stroke: Hsla = theme::primary();
    let fill_top = linear_gradient(
        0.,
        linear_color_stop(theme::white().opacity(0.04), 0.),
        linear_color_stop(theme::white().opacity(0.36), 1.),
    );
    let fill_bottom = linear_gradient(
        0.,
        linear_color_stop(theme::white().opacity(0.05), 0.),
        linear_color_stop(theme::white().opacity(0.32), 1.),
    );

    gpui_kit::component::chart::AreaChart::new(days)
        .x(|day| day.label)
        .y(|day| day.total() as f64)
        .stroke(stroke)
        .fill(fill_top)
        .natural()
        .name("Total")
        .y(|day| day.mobile as f64)
        .stroke(stroke)
        .fill(fill_bottom)
        .natural()
        .name("Mobile")
        .tick_margin(range.tick_margin())
        .id("visitors-chart")
}

fn segmented(active: Range, cx: &mut Context<Dash>) -> impl IntoElement {
    let mut row = div()
        .flex()
        .items_center()
        .p(px(2.))
        .gap(px(2.))
        .rounded(px(8.))
        .border_1()
        .border_color(theme::card_border());
    for range in Range::all() {
        row = row.child(segment(range, active, cx));
    }
    row
}

fn segment(range: Range, active: Range, cx: &mut Context<Dash>) -> impl IntoElement {
    let is_active = range == active;
    div()
        .id(range.label())
        .flex()
        .items_center()
        .h(px(28.))
        .px(px(12.))
        .rounded(px(6.))
        .cursor_pointer()
        .when(is_active, |style| style.bg(theme::tab_active()))
        .when(!is_active, |style| style.hover(|s| s.bg(theme::hover())))
        .on_click(cx.listener(move |this, _, _, cx| {
            this.range = range;
            cx.notify();
        }))
        .child(text(
            14.,
            if is_active {
                theme::text()
            } else {
                theme::muted()
            },
            range.label(),
        ))
}

fn text(size: f32, color: Hsla, value: &str) -> impl IntoElement {
    div()
        .text_size(px(size))
        .text_color(color)
        .child(value.to_string())
}
