//! Dash: the shadcn `dashboard-01` example rebuilt with gpui-kit.

mod cards;
mod data;
mod header;
mod pages;
mod sidebar;
mod table;
mod theme;

use std::borrow::Cow;

use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::component::{Root, Theme, ThemeMode, TitleBar};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::*;

use crate::pages::Page;

/// Serves the bundled icons plus the grayscale avatar used in the sidebar.
struct AppAssets;

impl AssetSource for AppAssets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        if path == "avatars/shadcn.png" {
            return Ok(Some(Cow::Borrowed(
                include_bytes!("../../dash/assets/avatar.png").as_slice(),
            )));
        }
        gpui_kit::assets::AllAssets.load(path)
    }

    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        gpui_kit::assets::AllAssets.list(path)
    }
}

/// Everything the dashboard can be interacted with lives here.
struct Dash {
    sidebar_open: bool,
    page: Page,
    active_nav: usize,
    pub(crate) range: cards::Range,
    tab: table::Tab,
    rows: Vec<data::Row>,
    checked: Vec<bool>,
    pub(crate) settings: [bool; 3],
    pub(crate) search: Entity<InputState>,
    pub(crate) search_query: String,
    /// Row currently being dragged, and the row it is hovering (both by row id).
    pub(crate) dragging: Option<u32>,
    pub(crate) drag_target: Option<u32>,
    _subscriptions: Vec<Subscription>,
}

impl Dash {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search pages…"));
        let subscription = cx.subscribe_in(&search, window, |this, state, event, _, cx| {
            if matches!(event, InputEvent::Change) {
                this.search_query = state.read(cx).value().to_string();
                cx.notify();
            }
        });
        Self {
            sidebar_open: true,
            page: Page::Dashboard,
            active_nav: 0,
            range: cards::Range::default(),
            tab: table::Tab::default(),
            rows: data::ROWS.to_vec(),
            checked: vec![false; data::ROWS.len()],
            settings: [true, true, false],
            search,
            search_query: String::new(),
            dragging: None,
            drag_target: None,
            _subscriptions: vec![subscription],
        }
    }

    fn open_page(&mut self, page: Page) {
        self.page = page;
        self.active_nav = pages::nav_index(page);
    }

    /// Move the dragged row to (just before or just after) the target row,
    /// the way a sortable list reorders live while the pointer moves.
    pub(crate) fn drop_row(&mut self, dragged_id: u32, target_id: u32, after: bool) {
        if dragged_id == target_id {
            return;
        }
        let from = self.rows.iter().position(|row| row.id == dragged_id);
        let to = self.rows.iter().position(|row| row.id == target_id);
        if let (Some(from), Some(to)) = (from, to) {
            let row = self.rows.remove(from);
            let checked = self.checked.remove(from);
            // The target shifts up by one when the dragged row came from above it.
            let target_index = if from < to { to - 1 } else { to };
            let insert = (target_index + usize::from(after)).min(self.rows.len());
            self.rows.insert(insert, row);
            self.checked.insert(insert, checked);
        }
    }

    /// Ends a drag interaction, clearing the transient row state.
    pub(crate) fn end_drag(&mut self) {
        if self.dragging.is_some() || self.drag_target.is_some() {
            self.dragging = None;
            self.drag_target = None;
        }
    }
}

impl Render for Dash {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let sidebar_open = self.sidebar_open;
        let title = if self.page == Page::Dashboard {
            "Documents"
        } else {
            self.page.title()
        };

        // The window itself is opaque and square: a transparent rounded shell
        // picks up the compositor's square shadow/border around the window
        // rectangle, which reads as a stray border. The inset panel below
        // keeps the rounded look.
        div()
            .flex()
            .flex_col()
            .size_full()
            .overflow_hidden()
            .bg(theme::page())
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, _, _, cx| {
                    let had_drag = this.dragging.is_some() || this.drag_target.is_some();
                    this.end_drag();
                    if had_drag {
                        cx.notify();
                    }
                }),
            )
            .child(title_bar())
            .child(
                div()
                    .flex()
                    .flex_1()
                    .min_h(px(0.))
                    .when(sidebar_open, |row| {
                        row.child(sidebar::render(self.active_nav, cx))
                    })
                    .child(panel(self, sidebar_open, title, cx)),
            )
            .children(Root::render_notification_layer(window, cx))
    }
}

fn title_bar() -> impl IntoElement {
    TitleBar::new()
        .bg(theme::page())
        .border_color(theme::border())
        .child(
            div()
                .flex()
                .items_center()
                .h_full()
                .pl(px(4.))
                .child(
                    div()
                        .text_size(px(13.))
                        .text_color(theme::muted())
                        .child("Dash"),
                ),
        )
}

/// The inset main panel: documents header plus the scrollable page body.
fn panel(state: &Dash, sidebar_open: bool, title: &'static str, cx: &mut Context<Dash>) -> impl IntoElement {
    let body = if state.page == Page::Dashboard {
        div()
            .flex()
            .flex_col()
            .gap(px(24.))
            .child(cards::metrics())
            .child(cards::chart_card(&state.range, cx))
            .child(table::render(state.tab, &state.rows, &state.checked, cx))
            .into_any_element()
    } else {
        pages::render(state.page, state, cx).into_any_element()
    };

    div()
        .flex_1()
        .h_full()
        .min_w(px(0.))
        .pt(px(8.))
        .pr(px(8.))
        .pb(px(8.))
        .when(!sidebar_open, |panel| panel.pl(px(8.)))
        .child(
            div()
                .flex()
                .flex_col()
                .size_full()
                .rounded(px(12.))
                .bg(theme::panel())
                .overflow_hidden()
                .child(header::render(sidebar_open, title, cx))
                .child(
                    div()
                        .flex_1()
                        .min_h(px(0.))
                        .id("panel-scroll")
                        .overflow_y_scroll()
                        .child(
                            div()
                                .flex()
                                .flex_col()
                                .px(px(16.))
                                .pt(px(24.))
                                .pb(px(32.))
                                .gap(px(24.))
                                .child(body),
                        ),
                ),
        )
}

fn main() {
    let app = gpui_kit::application().with_assets(AppAssets);

    app.run(move |cx| {
        gpui_kit::init(cx);
        Theme::change(ThemeMode::Dark, None, cx);
        {
            let theme = Theme::global_mut(cx);
            theme.font_family = "Noto Sans".into();
            // The dashboard draws its own interaction styling; the focus ring
            // reads as a stray square border on plain controls.
            theme.focus_ring = false;
        }
        Theme::sync_base(cx);

        cx.spawn(async move |cx| {
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds {
                        origin: point(px(80.), px(80.)),
                        size: size(px(1600.), px(1000.)),
                    })),
                    window_min_size: Some(size(px(1100.), px(700.))),
                    // Custom title bar: it drags and double clicks the window
                    // itself, so the system one is out of the picture. The
                    // title is still set for the window switcher/taskbar.
                    window_decorations: Some(WindowDecorations::Client),
                    titlebar: Some(TitlebarOptions {
                        title: Some("Dash".into()),
                        ..TitleBar::title_bar_options()
                    }),
                    app_owns_titlebar_drag: true,
                    ..Default::default()
                },
                |window, cx| {
                    let view = cx.new(|cx| Dash::new(window, cx));
                    cx.new(|cx| Root::new(view, window, cx))
                },
            )
            .expect("failed to open window");
        })
        .detach();
    });
}
