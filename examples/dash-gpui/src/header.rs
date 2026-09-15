//! The "Documents" header bar at the top of the inset panel.

use gpui_kit::component::{Icon, IconName};
use gpui_kit::{
    Context, InteractiveElement as _, IntoElement, ParentElement as _, StatefulInteractiveElement as _,
    Styled as _, div, px,
};

use crate::Dash;
use crate::theme;

pub fn render(sidebar_open: bool, title: &'static str, cx: &mut Context<Dash>) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .h(px(48.))
        .px(px(16.))
        .gap(px(12.))
        .border_b_1()
        .border_color(theme::border())
        .child(
            div()
                .id("sidebar-toggle")
                .flex()
                .items_center()
                .justify_center()
                .size(px(28.))
                .rounded(px(6.))
                .cursor_pointer()
                .hover(|style| style.bg(theme::hover()))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.sidebar_open = !this.sidebar_open;
                    cx.notify();
                }))
                .child(
                    Icon::new(if sidebar_open {
                        IconName::PanelLeft
                    } else {
                        IconName::PanelLeftOpen
                    })
                        .size(px(17.))
                        .text_color(theme::muted()),
                ),
        )
        .child(div().w(px(1.)).h(px(16.)).bg(theme::border()))
        .child(
            div()
                .text_size(px(16.))
                .font_weight(gpui_kit::FontWeight::MEDIUM)
                .text_color(theme::text())
                .child(title),
        )
        .child(div().flex_1())
        .child(
            div()
                .id("github")
                .flex()
                .items_center()
                .h(px(32.))
                .px(px(12.))
                .rounded(px(8.))
                .cursor_pointer()
                .hover(|style| style.bg(theme::hover()))
                .on_click(|_, _, cx| {
                    cx.open_url(
                        "https://github.com/shadcn-ui/ui/tree/main/apps/v4/app/(app)/examples/dashboard",
                    );
                })
                .child(
                    div()
                        .text_size(px(14.))
                        .text_color(theme::text())
                        .child("GitHub"),
                ),
        )
}
