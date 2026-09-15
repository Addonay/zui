//! Stand-in pages for every sidebar destination.
//!
//! Each page is real: lists render data, settings toggle state, the analytics
//! page hosts the chart, and search filters and navigates.

use gpui_kit::assets::IconName;
use gpui_kit::component::input::Input;
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{Icon, avatar::Avatar};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Context, Hsla, InteractiveElement as _, IntoElement, ParentElement as _, StatefulInteractiveElement as _,
    Styled as _, div, px,
};

use crate::Dash;
use crate::cards;
use crate::theme;

#[derive(Clone, Copy, PartialEq, Default)]
pub enum Page {
    #[default]
    Dashboard,
    Lifecycle,
    Analytics,
    Projects,
    Team,
    DataLibrary,
    Reports,
    WordAssistant,
    More,
    Settings,
    GetHelp,
    Search,
}

impl Page {
    pub fn from_nav(index: usize) -> Page {
        match index {
            1 => Page::Lifecycle,
            2 => Page::Analytics,
            3 => Page::Projects,
            4 => Page::Team,
            5 => Page::DataLibrary,
            6 => Page::Reports,
            7 => Page::WordAssistant,
            8 => Page::More,
            9 => Page::Settings,
            10 => Page::GetHelp,
            11 => Page::Search,
            _ => Page::Dashboard,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Page::Dashboard => "Dashboard",
            Page::Lifecycle => "Lifecycle",
            Page::Analytics => "Analytics",
            Page::Projects => "Projects",
            Page::Team => "Team",
            Page::DataLibrary => "Data Library",
            Page::Reports => "Reports",
            Page::WordAssistant => "Word Assistant",
            Page::More => "More",
            Page::Settings => "Settings",
            Page::GetHelp => "Get Help",
            Page::Search => "Search",
        }
    }

    fn description(self) -> &'static str {
        match self {
            Page::Dashboard => "Overview of your workspace",
            Page::Lifecycle => "Every document by its stage",
            Page::Analytics => "How visitors move through the product",
            Page::Projects => "Active projects and their owners",
            Page::Team => "People with access to this workspace",
            Page::DataLibrary => "Datasets available to your team",
            Page::Reports => "Generated reports and exports",
            Page::WordAssistant => "Documents drafted with the assistant",
            Page::More => "Everything else in this workspace",
            Page::Settings => "Workspace preferences",
            Page::GetHelp => "Answers to common questions",
            Page::Search => "Find pages, documents and actions",
        }
    }
}

struct Item {
    name: &'static str,
    meta: &'static str,
    done: bool,
    icon: IconName,
}

fn items(page: Page) -> &'static [Item] {
    match page {
        Page::Lifecycle => &[
            Item { name: "Ideation", meta: "8 documents", done: true, icon: IconName::ListTodo },
            Item { name: "Design review", meta: "4 documents", done: true, icon: IconName::ListTodo },
            Item { name: "Build", meta: "12 documents", done: false, icon: IconName::ListTodo },
            Item { name: "QA", meta: "6 documents", done: false, icon: IconName::ListTodo },
            Item { name: "Launch", meta: "2 documents", done: false, icon: IconName::ListTodo },
        ],
        Page::Projects => &[
            Item { name: "Apollo Dashboard", meta: "Owner: Eddie Lake", done: false, icon: IconName::Folder },
            Item { name: "Borealis API", meta: "Owner: Jamik Tashpulatov", done: true, icon: IconName::Folder },
            Item { name: "Cascade Editor", meta: "Owner: Sarah Chen", done: true, icon: IconName::Folder },
            Item { name: "Dune Analytics", meta: "Owner: Raj Patel", done: false, icon: IconName::Folder },
        ],
        Page::DataLibrary => &[
            Item { name: "Visitors (daily)", meta: "91 rows · 2 series", done: true, icon: IconName::Database },
            Item { name: "Document outline", meta: "68 rows · 7 columns", done: true, icon: IconName::Database },
            Item { name: "Customer accounts", meta: "45,678 rows", done: false, icon: IconName::Database },
            Item { name: "Revenue by plan", meta: "12 rows", done: true, icon: IconName::Database },
        ],
        Page::Reports => &[
            Item { name: "Weekly traffic digest", meta: "Generated 2 days ago", done: true, icon: IconName::FileText },
            Item { name: "Monthly revenue", meta: "Generated last week", done: true, icon: IconName::FileText },
            Item { name: "Retention cohort", meta: "Generating…", done: false, icon: IconName::FileText },
        ],
        Page::WordAssistant => &[
            Item { name: "Executive summary", meta: "Edited 3 hours ago", done: true, icon: IconName::FileType },
            Item { name: "Technical approach", meta: "Edited yesterday", done: true, icon: IconName::FileType },
            Item { name: "Design brief", meta: "Draft", done: false, icon: IconName::FileType },
        ],
        Page::More => &[
            Item { name: "Integrations", meta: "12 connected apps", done: true, icon: IconName::CircleQuestionMark },
            Item { name: "Audit log", meta: "1,204 events", done: true, icon: IconName::CircleQuestionMark },
            Item { name: "API keys", meta: "3 active keys", done: false, icon: IconName::CircleQuestionMark },
        ],
        _ => &[],
    }
}

const FAQ: [(&str, &str); 5] = [
    (
        "How do I invite a teammate?",
        "Open Team in the sidebar, then use the invite action on the member list.",
    ),
    (
        "Where do exports land?",
        "Reports keeps every generated export with its creation date.",
    ),
    (
        "Can I change the reporting window?",
        "Yes — the Total Visitors card switches between 3 months, 30 and 7 days.",
    ),
    (
        "How do I reorder the document table?",
        "Drag the handle at the start of any row to move it.",
    ),
    (
        "Is my data live?",
        "The dashboard is a demo dataset, but every control is wired end to end.",
    ),
];

const TEAM: [(&str, &str, &str); 4] = [
    ("Eddie Lake", "Product", "eddie@example.com"),
    ("Jamik Tashpulatov", "Engineering", "jamik@example.com"),
    ("Sarah Chen", "Design", "sarah@example.com"),
    ("Raj Patel", "Data", "raj@example.com"),
];

pub fn render(page: Page, state: &Dash, cx: &mut Context<Dash>) -> impl IntoElement {
    let body = match page {
        Page::Analytics => div()
            .flex()
            .flex_col()
            .gap(px(24.))
            .child(cards::metrics())
            .child(cards::chart_card(&state.range, cx))
            .into_any_element(),
        Page::Team => team_page().into_any_element(),
        Page::Settings => settings_page(state, cx).into_any_element(),
        Page::GetHelp => faq_page().into_any_element(),
        Page::Search => search_page(state, cx).into_any_element(),
        Page::Dashboard => div().into_any_element(),
        other => list_page(other).into_any_element(),
    };

    div()
        .flex()
        .flex_col()
        .gap(px(24.))
        .child(
            div()
                .flex()
                .flex_col()
                .gap(px(4.))
                .child(
                    div()
                        .text_size(px(24.))
                        .font_weight(gpui_kit::FontWeight::SEMIBOLD)
                        .text_color(theme::text())
                        .child(page.title()),
                )
                .child(
                    div()
                        .text_size(px(14.))
                        .text_color(theme::muted())
                        .child(page.description()),
                ),
        )
        .child(body)
}

fn list_page(page: Page) -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .rounded(px(12.))
        .border_1()
        .border_color(theme::border())
        .overflow_hidden()
        .children(items(page).iter().map(|item| {
            div()
                .flex()
                .items_center()
                .gap(px(14.))
                .h(px(64.))
                .px(px(20.))
                .border_b_1()
                .border_color(theme::border())
                .child(
                    Icon::new(item.icon)
                        .size(px(18.))
                        .text_color(theme::nav_text()),
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
                                .font_weight(gpui_kit::FontWeight::MEDIUM)
                                .text_color(theme::text())
                                .child(item.name),
                        )
                        .child(
                            div()
                                .text_size(px(13.))
                                .text_color(theme::muted())
                                .child(item.meta),
                        ),
                )
                .child(if item.done {
                    badge("Done", theme::green(), true).into_any_element()
                } else {
                    badge("In Process", theme::muted(), false).into_any_element()
                })
        }))
}

fn badge(label: &'static str, color: Hsla, filled: bool) -> impl IntoElement {
    div()
        .flex()
        .items_center()
        .gap(px(6.))
        .h(px(24.))
        .px(px(8.))
        .rounded_full()
        .border_1()
        .border_color(theme::card_border())
        .child(if filled {
            div()
                .flex()
                .items_center()
                .justify_center()
                .size(px(14.))
                .rounded_full()
                .bg(color)
                .child(
                    Icon::new(IconName::Check)
                        .size(px(9.))
                        .text_color(theme::panel()),
                )
                .into_any_element()
        } else {
            Icon::new(IconName::LoaderCircle)
                .size(px(14.))
                .text_color(color)
                .into_any_element()
        })
        .child(
            div()
                .text_size(px(13.))
                .text_color(theme::body())
                .child(label),
        )
}

fn team_page() -> impl IntoElement {
    div()
        .flex()
        .flex_wrap()
        .gap(px(16.))
        .children(TEAM.iter().map(|(name, role, email)| {
            div()
                .flex()
                .items_center()
                .gap(px(14.))
                .w(px(360.))
                .p(px(20.))
                .rounded(px(12.))
                .bg(theme::card_metric())
                .border_1()
                .border_color(theme::card_border())
                .child(Avatar::new().name(*name).size(px(40.)))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(px(14.))
                                .font_weight(gpui_kit::FontWeight::MEDIUM)
                                .text_color(theme::text())
                                .child(*name),
                        )
                        .child(
                            div()
                                .text_size(px(13.))
                                .text_color(theme::muted())
                                .child(format!("{role} · {email}")),
                        ),
                )
        }))
}

fn settings_page(state: &Dash, cx: &mut Context<Dash>) -> impl IntoElement {
    let rows = [
        ("Notifications", "Weekly digest and mentions"),
        ("Dark appearance", "Follow the dashboard theme"),
        ("Compact tables", "Tighter rows in every table"),
    ];
    div()
        .flex()
        .flex_col()
        .rounded(px(12.))
        .border_1()
        .border_color(theme::border())
        .overflow_hidden()
        .children(rows.iter().enumerate().map(|(index, (title, hint))| {
            div()
                .flex()
                .items_center()
                .justify_between()
                .gap(px(14.))
                .h(px(64.))
                .px(px(20.))
                .border_b_1()
                .border_color(theme::border())
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(px(14.))
                                .font_weight(gpui_kit::FontWeight::MEDIUM)
                                .text_color(theme::text())
                                .child(*title),
                        )
                        .child(
                            div()
                                .text_size(px(13.))
                                .text_color(theme::muted())
                                .child(*hint),
                        ),
                )
                .child(
                    Switch::new(("setting", index))
                        .checked(state.settings[index])
                        .on_change(cx.listener(move |this, value, _, cx| {
                            this.settings[index] = *value;
                            cx.notify();
                        })),
                )
        }))
}

fn faq_page() -> impl IntoElement {
    div()
        .flex()
        .flex_col()
        .gap(px(12.))
        .children(FAQ.iter().map(|(question, answer)| {
            div()
                .flex()
                .flex_col()
                .gap(px(6.))
                .p(px(20.))
                .rounded(px(12.))
                .bg(theme::card_metric())
                .border_1()
                .border_color(theme::card_border())
                .child(
                    div()
                        .text_size(px(14.))
                        .font_weight(gpui_kit::FontWeight::MEDIUM)
                        .text_color(theme::text())
                        .child(*question),
                )
                .child(
                    div()
                        .text_size(px(14.))
                        .text_color(theme::muted())
                        .child(*answer),
                )
        }))
}

fn search_page(state: &Dash, cx: &mut Context<Dash>) -> impl IntoElement {
    let query = state.search_query.to_lowercase();
    let results: Vec<Page> = NAV_PAGES
        .iter()
        .copied()
        .filter(|page| {
            query.is_empty()
                || page.title().to_lowercase().contains(&query)
                || page.description().to_lowercase().contains(&query)
        })
        .collect();

    div()
        .flex()
        .flex_col()
        .gap(px(16.))
        .child(div().w(px(420.)).child(Input::new(&state.search)))
        .child(
            div()
                .flex()
                .flex_col()
                .rounded(px(12.))
                .border_1()
                .border_color(theme::border())
                .overflow_hidden()
                .children(results.iter().map(|page| {
                    let page = *page;
                    div()
                        .id(page.title())
                        .flex()
                        .items_center()
                        .gap(px(14.))
                        .h(px(56.))
                        .px(px(20.))
                        .cursor_pointer()
                        .hover(|style| style.bg(theme::hover()))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.page = page;
                            this.active_nav = nav_index(page);
                            cx.notify();
                        }))
                        .child(
                            Icon::new(IconName::Search)
                                .size(px(16.))
                                .text_color(theme::muted()),
                        )
                        .child(
                            div()
                                .text_size(px(14.))
                                .text_color(theme::text())
                                .child(page.title()),
                        )
                        .child(
                            div()
                                .text_size(px(13.))
                                .text_color(theme::muted())
                                .child(page.description()),
                        )
                })),
        )
        .when(results.is_empty(), |column| {
            column.child(
                div()
                    .p(px(20.))
                    .text_size(px(14.))
                    .text_color(theme::muted())
                    .child("No matches. Try “visitors”, “team” or “reports”."),
            )
        })
}

/// Destinations offered by the search page, in sidebar order.
const NAV_PAGES: [Page; 11] = [
    Page::Dashboard,
    Page::Lifecycle,
    Page::Analytics,
    Page::Projects,
    Page::Team,
    Page::DataLibrary,
    Page::Reports,
    Page::WordAssistant,
    Page::More,
    Page::Settings,
    Page::GetHelp,
];

pub fn nav_index(page: Page) -> usize {
    NAV_PAGES
        .iter()
        .position(|candidate| *candidate == page)
        .unwrap_or(0)
}
