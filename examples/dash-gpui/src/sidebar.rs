//! Left navigation sidebar, mirroring the `dashboard-01` block.

use gpui_kit::assets::IconName;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::component::{Icon, WindowExt as _};
use gpui_kit::{
    Context, InteractiveElement as _, IntoElement, ParentElement as _, StatefulInteractiveElement as _,
    Styled as _, div, px,
};

use crate::Dash;
use crate::pages::Page;
use crate::theme;

const NAV_SIZE: f32 = 14.;
const ICON_SIZE: f32 = 16.;

pub fn render(active_nav: usize, cx: &mut Context<Dash>) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .w(px(288.))
        .h_full()
        .flex_shrink_0()
        .pt(px(8.))
        .pb(px(8.))
        .px(px(16.))
        .bg(theme::page())
        .child(brand())
        .child(quick_create())
        .child(
            div()
                .flex()
                .flex_col()
                .gap(px(4.))
                .pt(px(8.))
                .child(nav_item(IconName::Gauge, "Dashboard", 0, active_nav, cx))
                .child(nav_item(IconName::ListTodo, "Lifecycle", 1, active_nav, cx))
                .child(nav_item(IconName::ChartColumn, "Analytics", 2, active_nav, cx))
                .child(nav_item(IconName::Folder, "Projects", 3, active_nav, cx))
                .child(nav_item(IconName::Users, "Team", 4, active_nav, cx)),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .child(
                    div()
                        .pt(px(24.))
                        .pb(px(8.))
                        .pl(px(12.))
                        .text_size(px(13.))
                        .text_color(theme::muted())
                        .child("Documents"),
                )
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(4.))
                        .child(nav_item(IconName::Database, "Data Library", 5, active_nav, cx))
                        .child(nav_item(IconName::FileText, "Reports", 6, active_nav, cx))
                        .child(nav_item(IconName::FileType, "Word Assistant", 7, active_nav, cx))
                        .child(nav_item(IconName::Ellipsis, "More", 8, active_nav, cx)),
                ),
        )
        .child(div().flex_1())
        .child(
            div()
                .flex()
                .flex_col()
                .gap(px(4.))
                .child(nav_item(IconName::Settings, "Settings", 9, active_nav, cx))
                .child(nav_item(
                    IconName::CircleQuestionMark,
                    "Get Help",
                    10,
                    active_nav,
                    cx,
                ))
                .child(nav_item(IconName::Search, "Search", 11, active_nav, cx)),
        )
        .child(user_footer())
}

fn brand() -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .gap(px(10.))
        .h(px(48.))
        .px(px(8.))
        .child(
            Icon::new(IconName::Circle)
                .size(px(20.))
                .text_color(theme::text()),
        )
        .child(
            div()
                .text_size(px(16.))
                .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                .text_color(theme::text())
                .child("Acme Inc."),
        )
}

fn quick_create() -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .gap(px(8.))
        .pt(px(8.))
        .child(
            div()
                .id("quick-create")
                .flex()
                .flex_1()
                .items_center()
                .gap(px(10.))
                .h(px(32.))
                .px(px(8.))
                .rounded(px(8.))
                .bg(theme::primary())
                .cursor_pointer()
                .on_click(|_, window, cx| {
                    window.push_notification("Quick Create", cx);
                })
                .child(
                    div()
                        .flex()
                        .items_center()
                        .justify_center()
                        .size(px(18.))
                        .rounded_full()
                        .bg(theme::primary_foreground())
                        .child(
                            Icon::new(IconName::Plus)
                                .size(px(11.))
                                .text_color(theme::primary()),
                        ),
                )
                .child(
                    div()
                        .text_size(px(14.))
                        .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                        .text_color(theme::primary_foreground())
                        .child("Quick Create"),
                ),
        )
        .child(
            div()
                .id("inbox")
                .flex()
                .items_center()
                .justify_center()
                .size(px(32.))
                .rounded(px(8.))
                .bg(theme::hover())
                .border_1()
                .border_color(theme::card_border())
                .cursor_pointer()
                .on_click(|_, window, cx| {
                    window.push_notification("Inbox", cx);
                })
                .child(
                    Icon::new(IconName::Mail)
                        .size(px(16.))
                        .text_color(theme::body()),
                ),
        )
}

fn nav_item(
    icon: IconName,
    label: &'static str,
    index: usize,
    active_nav: usize,
    cx: &mut Context<Dash>,
) -> impl IntoElement {
    let active = index == active_nav;
    div()
        .id(("nav", index))
        .flex()
        .items_center()
        .gap(px(12.))
        .h(px(32.))
        .px(px(12.))
        .rounded(px(8.))
        .cursor_pointer()
        .when(active, |item| item.bg(theme::hover()))
        .when(!active, |item| item.hover(|style| style.bg(theme::hover())))
        .on_click(cx.listener(move |this, _, _, cx| {
            this.open_page(Page::from_nav(index));
            cx.notify();
        }))
        .child(
            Icon::new(icon)
                .size(px(ICON_SIZE))
                .text_color(if active { theme::text() } else { theme::nav_text() }),
        )
        .child(
            div()
                .text_size(px(NAV_SIZE))
                .line_height(px(20.))
                .text_color(if active { theme::text() } else { theme::nav_text() })
                .child(label),
        )
}

fn user_footer() -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .gap(px(10.))
        .pt(px(12.))
        .child(
            gpui_kit::component::avatar::Avatar::new()
                .src("avatars/shadcn.png")
                .name("shadcn")
                .size(px(32.)),
        )
        .child(
            div()
                .flex()
                .flex_col()
                .flex_1()
                .gap(px(2.))
                .child(
                    div()
                        .text_size(px(14.))
                        .text_color(theme::text())
                        .child("shadcn"),
                )
                .child(
                    div()
                        .text_size(px(12.))
                        .text_color(theme::muted())
                        .child("m@example.com"),
                ),
        )
        .child(
            Icon::new(IconName::EllipsisVertical)
                .size(px(16.))
                .text_color(theme::muted()),
        )
}
