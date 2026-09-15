//! Tabs and the virtualized, drag-reorderable data table.

use std::rc::Rc;

use gpui_kit::assets::IconName;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Icon, Sizable as _, WindowExt as _, v_virtual_list};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AppContext as _, Context, DragMoveEvent, Hsla, InteractiveElement as _, IntoElement, ParentElement as _,
    Pixels, Render, StatefulInteractiveElement as _, Styled as _, Window, div, px, size,
};

use crate::Dash;
use crate::data::{self, Status};
use crate::theme;

/// Height of one table row; the virtual list needs it up front.
const ROW_HEIGHT: f32 = 52.;

/// Fixed viewport for the virtualized rows, so only ~11 rows are ever built.
const ROWS_VIEWPORT: f32 = 560.;

#[derive(Clone, Copy, PartialEq, Default)]
pub enum Tab {
    #[default]
    Outline,
    PastPerformance,
    KeyPersonnel,
    FocusDocuments,
}

impl Tab {
    fn label(self) -> &'static str {
        match self {
            Tab::Outline => "Outline",
            Tab::PastPerformance => "Past Performance",
            Tab::KeyPersonnel => "Key Personnel",
            Tab::FocusDocuments => "Focus Documents",
        }
    }

    fn all() -> [Tab; 4] {
        [
            Tab::Outline,
            Tab::PastPerformance,
            Tab::KeyPersonnel,
            Tab::FocusDocuments,
        ]
    }

    fn matches(self, row: &data::Row) -> bool {
        match self {
            Tab::Outline => true,
            Tab::PastPerformance => row.status == Status::Done,
            Tab::KeyPersonnel => row.reviewer != "Assign reviewer",
            Tab::FocusDocuments => row.section_type == "Narrative",
        }
    }
}

/// Indices into `rows` for the rows the tab shows.
fn visible_indices(rows: &[data::Row], tab: Tab) -> Vec<usize> {
    rows.iter()
        .enumerate()
        .filter_map(|(index, row)| tab.matches(row).then_some(index))
        .collect()
}

pub fn render(
    tab: Tab,
    rows: &[data::Row],
    checked: &[bool],
    cx: &mut Context<Dash>,
) -> impl IntoElement {
    let indices = visible_indices(rows, tab);
    let all_checked = !indices.is_empty() && indices.iter().all(|index| checked[*index]);

    div()
        .flex()
        .flex_col()
        .gap(px(16.))
        .child(toolbar(tab, rows, cx))
        .child(
            div()
                .flex()
                .flex_col()
                .rounded(px(10.))
                .border_1()
                .border_color(theme::border())
                .overflow_hidden()
                // Like the reference's `overflow-x-auto` wrapper: below the
                // columns' combined width the table scrolls sideways instead
                // of squashing and drifting out of alignment.
                .child(
                    div()
                        .id("table-x-scroll")
                        .overflow_x_scroll()
                        .child(
                            div()
                                .flex()
                                .flex_col()
                                .min_w(px(1160.))
                                .child(header_row(tab, all_checked, cx))
                                .child(
                                    div()
                                        .h(px(ROWS_VIEWPORT))
                                        .w_full()
                                        .child(rows_list(cx)),
                                ),
                        ),
                ),
        )
}

fn toolbar(tab: Tab, rows: &[data::Row], cx: &mut Context<Dash>) -> impl IntoElement {
    let mut tabs = div()
        .flex()
        .items_center()
        .gap(px(2.))
        .p(px(2.))
        .rounded(px(8.))
        .bg(theme::table_head());
    for value in Tab::all() {
        let count = visible_indices(rows, value).len();
        tabs = tabs.child(tab_button(value, tab, count, cx));
    }
    div()
        .flex()
        .flex_wrap()
        .items_center()
        .justify_between()
        .gap(px(8.))
        .child(tabs)
        .child(
            div()
                .flex()
                .items_center()
                .gap(px(8.))
                .child(outline_button(IconName::Columns3, "Customize Columns", true))
                .child(outline_button(IconName::Plus, "Add Section", false)),
        )
}

fn tab_button(value: Tab, active: Tab, count: usize, cx: &mut Context<Dash>) -> impl IntoElement {
    let is_active = value == active;
    div()
        .id(value.label())
        .flex()
        .items_center()
        .gap(px(6.))
        .h(px(32.))
        .px(px(12.))
        .rounded(px(6.))
        .cursor_pointer()
        .when(is_active, |style| style.bg(theme::tab_active()))
        .when(!is_active, |style| style.hover(|s| s.bg(theme::hover())))
        .on_click(cx.listener(move |this, _, _, cx| {
            this.tab = value;
            cx.notify();
        }))
        .child(text(
            14.,
            if is_active {
                theme::text()
            } else {
                theme::muted()
            },
            value.label(),
        ))
        .when(value != Tab::Outline, |row| {
            row.child(
                div()
                    .flex()
                    .items_center()
                    .justify_center()
                    .h(px(18.))
                    .min_w(px(18.))
                    .px(px(5.))
                    .rounded_full()
                    .bg(theme::card_border())
                    .child(text(11., theme::text(), &count.to_string())),
            )
        })
}

fn outline_button(icon: IconName, label: &'static str, caret: bool) -> impl IntoElement {
    div()
        .id(label)
        .flex()
        .items_center()
        .gap(px(6.))
        .h(px(32.))
        .px(px(10.))
        .rounded(px(8.))
        .border_1()
        .border_color(theme::card_border())
        .bg(theme::card())
        .cursor_pointer()
        .hover(|style| style.bg(theme::hover()))
        .on_click({
            let label = label.to_string();
            move |_, window, cx| {
                window.push_notification(label.clone(), cx);
            }
        })
        .child(Icon::new(icon).size(px(14.)).text_color(theme::body()))
        .child(text(14., theme::body(), label))
        .when(caret, |row| {
            row.child(
                Icon::new(IconName::ChevronDown)
                    .size(px(14.))
                    .text_color(theme::muted()),
            )
        })
}

fn header_row(tab: Tab, all_checked: bool, cx: &mut Context<Dash>) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .h(px(40.))
        .px(px(16.))
        .gap(px(20.))
        .bg(theme::table_head())
        .child(div().w(px(20.)))
        .child(checkbox(all_checked).id("check-all").on_click(cx.listener(move |this, _, _, cx| {
            let indices = visible_indices(&this.rows, tab);
            let target = !indices.iter().all(|index| this.checked[*index]);
            for index in indices {
                this.checked[index] = target;
            }
            cx.notify();
        })))
        .child(div().flex_1().child(table_head_text("Header")))
        .child(div().w(px(210.)).child(table_head_text("Section Type")))
        .child(div().w(px(180.)).child(table_head_text("Status")))
        .child(
            div()
                .w(px(90.))
                .flex()
                .justify_end()
                .child(table_head_text("Target")),
        )
        .child(
            div()
                .w(px(70.))
                .flex()
                .justify_end()
                .child(table_head_text("Limit")),
        )
        .child(div().w(px(160.)).child(table_head_text("Reviewer")))
        .child(div().w(px(20.)))
}

/// Only the visible slice of rows is built: the page keeps its regular scroll
/// for the cards and chart, while the table scrolls (and virtualizes) itself.
fn rows_list(cx: &mut Context<Dash>) -> impl IntoElement {
    let view = cx.entity();
    let sizes = Rc::new(vec![size(px(0.), px(ROW_HEIGHT)); data::ROWS.len()]);
    v_virtual_list(view, "table-rows", sizes, |this, range, _window, cx| {
        let indices = visible_indices(&this.rows, this.tab);
        let mut rows = Vec::with_capacity(range.len());
        for display_index in range {
            let Some(row_index) = indices.get(display_index).copied() else {
                continue;
            };
            let checked = this.checked.get(row_index).copied().unwrap_or(false);
            rows.push(body_row(
                row_index,
                this.rows[row_index],
                checked,
                this.dragging,
                this.sidebar_open,
                cx,
            ));
        }
        rows
    })
}

fn body_row(
    index: usize,
    row: data::Row,
    checked: bool,
    dragging: Option<u32>,
    sidebar_open: bool,
    cx: &mut Context<Dash>,
) -> gpui_kit::AnyElement {
    let last = index + 1 == data::ROWS.len();
    let target_id = row.id;
    let is_dragging = dragging == Some(row.id);
    let view = cx.entity().downgrade();
    div()
        .id(("row", row.id))
        .flex()
        .items_center()
        .w_full()
        .h(px(ROW_HEIGHT))
        .px(px(16.))
        .gap(px(20.))
        .when(!last, |style| {
            style.border_b_1().border_color(theme::border())
        })
        .when(is_dragging, |style| style.opacity(0.35))
        // Grab anywhere on the row: the overlay is the whole row, held at the
        // point you grabbed, and rows reorder live while you move — the way a
        // sortable JS list behaves.
        .on_drag(row, {
            let view = view.clone();
            move |row: &data::Row, _offset, window, cx| {
                let row = *row;
                let _ = view.update(cx, |this, cx| {
                    this.dragging = Some(row.id);
                    this.drag_target = None;
                    cx.notify();
                });
                let width = overlay_width(window, sidebar_open);
                cx.new(move |_| RowPreview {
                    row,
                    checked,
                    width,
                })
            }
        })
        .on_drag_move::<data::Row>(cx.listener(move |this, event: &DragMoveEvent<data::Row>, _, cx| {
            let dragged = event.drag(cx).id;
            if dragged == target_id {
                return;
            }
            let from = this.rows.iter().position(|candidate| candidate.id == dragged);
            let to = this.rows.iter().position(|candidate| candidate.id == target_id);
            let (Some(from), Some(to)) = (from, to) else {
                return;
            };
            let middle = event.bounds.origin.y + event.bounds.size.height / 2.0;
            let past_middle = event.event.position.y > middle;
            let should_move = if from < to { past_middle } else { !past_middle };
            if should_move && this.dragging == Some(dragged) {
                this.drop_row(dragged, target_id, past_middle);
                this.drag_target = Some(target_id);
                cx.notify();
            }
        }))
        .on_drop(cx.listener(|this, _: &data::Row, _, cx| {
            this.end_drag();
            cx.notify();
        }))
        .child(
            div()
                .id(("grip", row.id))
                .flex()
                .items_center()
                .justify_center()
                .size(px(20.))
                .rounded(px(4.))
                .cursor_move()
                .hover(|style| style.bg(theme::hover()))
                .child(
                    Icon::new(IconName::GripVertical)
                        .size(px(16.))
                        .text_color(theme::faint()),
                ),
        )
        .child(checkbox(checked).id(("row-check", row.id)).on_click(cx.listener(move |this, _, _, cx| {
            if let Some(value) = this.checked.get_mut(index) {
                *value = !*value;
            }
            cx.notify();
        })))
        .child(div().flex_1().child(
            div()
                .text_size(px(14.))
                .font_weight(gpui_kit::FontWeight::MEDIUM)
                .text_color(theme::text())
                .child(row.header),
        ))
        .child(div().w(px(210.)).child(section_badge(row.section_type)))
        .child(div().w(px(180.)).child(status_badge(row.status)))
        .child(
            div()
                .w(px(90.))
                .flex()
                .justify_end()
                .child(text(14., theme::text(), row.target)),
        )
        .child(
            div()
                .w(px(70.))
                .flex()
                .justify_end()
                .child(text(14., theme::text(), row.limit)),
        )
        .child(
            div()
                .w(px(160.))
                .child(text(14., theme::text(), row.reviewer)),
        )
        .child(
            div()
                .id(("row-actions", row.id))
                .cursor_pointer()
                .on_click(|_, window, cx| {
                    window.push_notification("Row actions", cx);
                })
                .child(
                    Icon::new(IconName::EllipsisVertical)
                        .size(px(16.))
                        .text_color(theme::muted()),
                ),
        )
        .into_any_element()
}

/// How wide the table is, given the window and whether the sidebar is open.
/// Used so the drag overlay matches the real row.
fn overlay_width(window: &Window, sidebar_open: bool) -> Pixels {
    let total = window.bounds().size.width;
    if sidebar_open {
        total - px(336.)
    } else {
        total - px(48.)
    }
}

/// What the pointer carries while dragging: a floating copy of the whole row,
/// held where it was grabbed.
struct RowPreview {
    row: data::Row,
    checked: bool,
    width: Pixels,
}

impl Render for RowPreview {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .items_center()
            .w(self.width)
            .h(px(ROW_HEIGHT))
            .px(px(16.))
            .gap(px(20.))
            .rounded(px(8.))
            .bg(theme::card_metric())
            .border_1()
            .border_color(theme::primary().opacity(0.5))
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_center()
                    .size(px(20.))
                    .child(
                        Icon::new(IconName::GripVertical)
                            .size(px(16.))
                            .text_color(theme::faint()),
                    ),
            )
            .child(checkbox(self.checked))
            .child(div().flex_1().child(
                div()
                    .text_size(px(14.))
                    .font_weight(gpui_kit::FontWeight::MEDIUM)
                    .text_color(theme::text())
                    .child(self.row.header),
            ))
            .child(div().w(px(210.)).child(section_badge(self.row.section_type)))
            .child(div().w(px(180.)).child(status_badge(self.row.status)))
            .child(
                div()
                    .w(px(90.))
                    .flex()
                    .justify_end()
                    .child(text(14., theme::text(), self.row.target)),
            )
            .child(
                div()
                    .w(px(70.))
                    .flex()
                    .justify_end()
                    .child(text(14., theme::text(), self.row.limit)),
            )
            .child(
                div()
                    .w(px(160.))
                    .child(text(14., theme::text(), self.row.reviewer)),
            )
            .child(
                Icon::new(IconName::EllipsisVertical)
                    .size(px(16.))
                    .text_color(theme::muted()),
            )
    }
}

fn checkbox(checked: bool) -> gpui_kit::Div {
    div()
        .flex()
        .items_center()
        .justify_center()
        .size(px(16.))
        .rounded(px(4.))
        .border_1()
        .border_color(if checked {
            theme::primary()
        } else {
            theme::card_border()
        })
        .bg(if checked {
            theme::primary()
        } else {
            theme::panel()
        })
        .cursor_pointer()
        .when(checked, |el| {
            el.child(
                Icon::new(IconName::Check)
                    .size(px(11.))
                    .text_color(theme::panel()),
            )
        })
}

fn section_badge(label: &str) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .h(px(22.))
        .px(px(8.))
        .rounded_full()
        .border_1()
        .border_color(theme::card_border())
        .child(text(12., theme::body(), label))
}

fn status_badge(status: Status) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .gap(px(6.))
        .h(px(24.))
        .px(px(8.))
        .rounded_full()
        .border_1()
        .border_color(theme::card_border())
        .child(match status {
            Status::Done => div()
                .flex()
                .items_center()
                .justify_center()
                .size(px(14.))
                .rounded_full()
                .bg(theme::green())
                .child(
                    Icon::new(IconName::Check)
                        .size(px(9.))
                        .text_color(theme::panel()),
                )
                .into_any_element(),
            Status::InProcess => Spinner::new()
                .small()
                .color(theme::muted())
                .into_any_element(),
        })
        .child(text(
            14.,
            theme::body(),
            match status {
                Status::Done => "Done",
                Status::InProcess => "In Process",
            },
        ))
}

fn table_head_text(value: &'static str) -> impl IntoElement {
    div()
        .text_size(px(14.))
        .font_weight(gpui_kit::FontWeight::SEMIBOLD)
        .text_color(theme::text())
        .child(value)
}

fn text(size: f32, color: Hsla, value: &str) -> impl IntoElement {
    div()
        .text_size(px(size))
        .text_color(color)
        .child(value.to_string())
}
