use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;

use adw::prelude::*;
use bw_core::models::{BWCategory, BWCategoryType, BWDate, BWMoneyAmount, BWTransaction};
use chrono::{Datelike, Local};
use gtk::{Align, Orientation};
use uuid::Uuid;

use crate::store::{
    AppPage, AppState, BudgetTemplate, ReportMode, TransactionSort, budget_date_range,
    category_date_range, money_text, parse_date, parse_money, read_budget, supported_currencies,
    today_text,
};

#[derive(Clone)]
struct MainView {
    budget_id: Rc<Cell<Uuid>>,
    split: adw::NavigationSplitView,
    glance_split: adw::OverlaySplitView,
    glance_toggle: gtk::ToggleButton,
    glance_visible: Rc<Cell<bool>>,
    suppress_glance_visibility: Rc<Cell<bool>>,
    sidebar: gtk::ListBox,
    title: adw::WindowTitle,
    actions: gtk::Box,
    recent: gtk::MenuButton,
    content: gtk::Box,
}

struct PageView {
    widget: gtk::Widget,
    scroll: gtk::ScrolledWindow,
}

#[derive(Clone)]
struct CategoryWindow {
    window: adw::ApplicationWindow,
    category_id: Uuid,
    filters: Rc<RefCell<TransactionFilters>>,
    scroll: Rc<RefCell<Option<gtk::ScrolledWindow>>>,
}

#[derive(Clone)]
struct TransactionFilters {
    search: String,
    date_enabled: bool,
    start: String,
    end: String,
    minimum: String,
    maximum: String,
    sort: TransactionSort,
}

impl TransactionFilters {
    fn new(range: (String, String)) -> Self {
        Self {
            search: String::new(),
            date_enabled: false,
            start: range.0,
            end: range.1,
            minimum: String::new(),
            maximum: String::new(),
            sort: TransactionSort::Newest,
        }
    }

    fn active(&self) -> bool {
        self.date_enabled || !self.minimum.trim().is_empty() || !self.maximum.trim().is_empty()
    }

    fn matches(&self, item: &TransactionItem, currency: &str) -> bool {
        let transaction = &item.transaction;
        let search = self.search.trim().to_lowercase();
        if !search.is_empty() {
            let searchable = format!(
                "{} {} {} {} {} {} {}",
                item.category_title,
                item.category_type.title(),
                transaction.title,
                transaction.description,
                transaction_date(transaction),
                money_input(transaction.amount.value),
                money_text(transaction.amount.value, currency)
            );
            if !searchable.to_lowercase().contains(&search) {
                return false;
            }
        }
        if self.date_enabled {
            let (Some(date), Some(start), Some(end)) = (
                parse_date(&transaction_date(transaction)),
                parse_date(&self.start),
                parse_date(&self.end),
            ) else {
                return false;
            };
            if date < start || date > end {
                return false;
            }
        }
        if !self.minimum.trim().is_empty()
            && parse_money(&self.minimum).is_none_or(|value| transaction.amount.value < value)
        {
            return false;
        }
        if !self.maximum.trim().is_empty()
            && parse_money(&self.maximum).is_none_or(|value| transaction.amount.value > value)
        {
            return false;
        }
        true
    }
}

#[derive(Clone)]
struct TransactionItem {
    category_title: String,
    category_type: BWCategoryType,
    transaction: BWTransaction,
}

struct FormDialog {
    dialog: adw::Dialog,
    body: gtk::Box,
    save: gtk::Button,
    error: gtk::Label,
}

impl FormDialog {
    fn new(title: &str, action: &str) -> Self {
        let dialog = adw::Dialog::builder()
            .title(title)
            .content_width(460)
            .build();
        let toolbar = adw::ToolbarView::new();
        let header = adw::HeaderBar::new();
        header.set_show_start_title_buttons(false);
        header.set_show_end_title_buttons(false);
        let cancel = gtk::Button::with_label("Cancel");
        let weak_dialog = dialog.downgrade();
        cancel.connect_clicked(move |_| {
            if let Some(dialog) = weak_dialog.upgrade() {
                dialog.close();
            }
        });
        header.pack_start(&cancel);
        let save = gtk::Button::with_label(action);
        save.add_css_class("suggested-action");
        header.pack_end(&save);
        toolbar.add_top_bar(&header);
        let body = gtk::Box::new(Orientation::Vertical, 24);
        body.set_margin_top(24);
        body.set_margin_bottom(24);
        body.set_margin_start(24);
        body.set_margin_end(24);
        let error = gtk::Label::new(None);
        error.set_wrap(true);
        error.set_xalign(0.0);
        error.add_css_class("error");
        error.set_visible(false);
        body.append(&error);
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .propagate_natural_height(true)
            .child(&body)
            .build();
        toolbar.set_content(Some(&scroll));
        dialog.set_child(Some(&toolbar));
        dialog.set_default_widget(Some(&save));
        Self {
            dialog,
            body,
            save,
            error,
        }
    }
}

pub struct AppUi {
    app: adw::Application,
    window: adw::ApplicationWindow,
    state: RefCell<AppState>,
    main: RefCell<Option<MainView>>,
    displayed_budget_path: RefCell<Option<String>>,
    editors: RefCell<Vec<gtk::glib::WeakRef<adw::Dialog>>>,
    main_scroll: RefCell<Option<gtk::ScrolledWindow>>,
    filters: Rc<RefCell<TransactionFilters>>,
    category_windows: RefCell<Vec<CategoryWindow>>,
    search: RefCell<Option<gtk::SearchEntry>>,
}

impl AppUi {
    pub fn new(app: &adw::Application, state: AppState) -> Rc<Self> {
        let window = adw::ApplicationWindow::builder()
            .application(app)
            .title("Budget Warden")
            .default_width(1100)
            .default_height(760)
            .width_request(360)
            .height_request(480)
            .build();
        let ui = Rc::new(Self {
            app: app.clone(),
            window,
            state: RefCell::new(state),
            main: RefCell::new(None),
            displayed_budget_path: RefCell::new(None),
            editors: RefCell::new(Vec::new()),
            main_scroll: RefCell::new(None),
            filters: Rc::new(RefCell::new(TransactionFilters::new((
                today_text(),
                today_text(),
            )))),
            category_windows: RefCell::new(Vec::new()),
            search: RefCell::new(None),
        });
        ui.install_actions();
        ui
    }

    pub fn present(self: &Rc<Self>) {
        if self.window.content().is_none() {
            self.refresh();
        }
        self.window.present();
    }

    pub fn open_external_budget(self: &Rc<Self>, path: PathBuf) {
        self.open_budget(path);
    }

    fn install_actions(self: &Rc<Self>) {
        for (name, shortcut) in [
            ("new-budget", "<Primary>n"),
            ("open-budget", "<Primary>o"),
            ("preferences", "<Primary>comma"),
            ("quit", "<Primary>q"),
            ("search", "<Primary>f"),
            ("about", ""),
        ] {
            let action = gtk::gio::SimpleAction::new(name, None);
            let ui = self.clone();
            action.connect_activate(move |_, _| match name {
                "new-budget" => ui.show_new_budget_dialog(),
                "open-budget" => ui.open_file_dialog(),
                "preferences" => ui.show_preferences(),
                "about" => ui.show_about(),
                "search" => {
                    if ui.state.borrow().budget.is_some() {
                        ui.state.borrow_mut().page = AppPage::Transactions;
                        if let Some(main) = ui.main.borrow().as_ref() {
                            main.sidebar
                                .select_row(main.sidebar.row_at_index(2).as_ref());
                            main.split.set_show_content(true);
                        }
                        ui.render_page(false);
                        if let Some(search) = ui.search.borrow().as_ref() {
                            search.grab_focus();
                        }
                    }
                }
                "quit" => ui.app.quit(),
                _ => (),
            });
            self.app.add_action(&action);
            if !shortcut.is_empty() {
                self.app
                    .set_accels_for_action(&format!("app.{name}"), &[shortcut]);
            }
        }
        let recent = gtk::gio::SimpleAction::new("open-recent", Some(gtk::glib::VariantTy::STRING));
        let ui = self.clone();
        recent.connect_activate(move |_, parameter| {
            if let Some(path) = parameter.and_then(|value| value.str()) {
                ui.open_budget(PathBuf::from(path));
            }
        });
        self.app.add_action(&recent);
    }

    fn app_menu(&self) -> gtk::gio::Menu {
        let menu = gtk::gio::Menu::new();
        let files = gtk::gio::Menu::new();
        files.append(Some("New Budget…"), Some("app.new-budget"));
        files.append(Some("Open Budget…"), Some("app.open-budget"));
        menu.append_section(None, &files);
        let settings = gtk::gio::Menu::new();
        settings.append(Some("Preferences"), Some("app.preferences"));
        settings.append(Some("About Budget Warden"), Some("app.about"));
        menu.append_section(None, &settings);
        menu.append(Some("Quit"), Some("app.quit"));
        menu
    }

    fn recent_menu(&self) -> gtk::gio::Menu {
        let menu = gtk::gio::Menu::new();
        menu.append(Some("Open Budget…"), Some("app.open-budget"));
        menu.append(Some("New Budget…"), Some("app.new-budget"));
        let recent = gtk::gio::Menu::new();
        for path in &self.state.borrow().recent_files {
            let title = path
                .file_stem()
                .and_then(|name| name.to_str())
                .unwrap_or("Budget");
            let item = gtk::gio::MenuItem::new(Some(title), None);
            item.set_action_and_target_value(
                Some("app.open-recent"),
                Some(&path.to_string_lossy().as_ref().to_variant()),
            );
            recent.append_item(&item);
        }
        menu.append_section(Some("Recent Budgets"), &recent);
        menu
    }

    fn refresh(self: &Rc<Self>) {
        let budget = self.state.borrow().budget.clone();
        let Some(budget) = budget else {
            self.window.set_content(Some(&self.welcome()));
            return;
        };
        let existing = self.main.borrow().clone();
        let changed = existing
            .as_ref()
            .is_none_or(|main| main.budget_id.get() != budget.id)
            || *self.displayed_budget_path.borrow() != budget.url;
        *self.displayed_budget_path.borrow_mut() = budget.url.clone();
        if changed {
            for editor in self.editors.replace(Vec::new()) {
                if let Some(editor) = editor.upgrade() {
                    editor.close();
                }
            }
            *self.filters.borrow_mut() = TransactionFilters::new(budget_date_range(&budget));
            let windows = self.category_windows.replace(Vec::new());
            for handle in windows {
                handle.window.close();
            }
            self.state.borrow_mut().page = AppPage::Budget;
        }
        let main = if let Some(main) = existing {
            main.budget_id.set(budget.id);
            if changed {
                main.sidebar
                    .select_row(main.sidebar.row_at_index(0).as_ref());
            }
            main
        } else {
            let main = self.build_main(budget.id);
            self.window.set_content(Some(&main.split));
            *self.main.borrow_mut() = Some(main.clone());
            main
        };
        main.recent.set_menu_model(Some(&self.recent_menu()));
        self.render_page(!changed);
        let windows = self.category_windows.borrow().clone();
        for handle in windows {
            self.render_category_window(&handle);
        }
    }

    fn welcome(self: &Rc<Self>) -> gtk::Widget {
        let toolbar = adw::ToolbarView::new();
        let header = adw::HeaderBar::new();
        let menu = gtk::MenuButton::builder()
            .icon_name("open-menu-symbolic")
            .menu_model(&self.app_menu())
            .tooltip_text("Main Menu")
            .build();
        header.pack_end(&menu);
        toolbar.add_top_bar(&header);
        let body = gtk::Box::new(Orientation::Vertical, 24);
        body.set_margin_top(24);
        body.set_margin_bottom(32);
        let status = adw::StatusPage::builder()
            .icon_name("document-open-symbolic")
            .title("Budget Warden")
            .description("Plan your money. Keep your budgets in portable local files.")
            .build();
        let actions = gtk::Box::new(Orientation::Horizontal, 12);
        actions.set_halign(Align::Center);
        let create = gtk::Button::with_label("New Budget");
        create.add_css_class("suggested-action");
        create.add_css_class("pill");
        create.set_action_name(Some("app.new-budget"));
        let open = gtk::Button::with_label("Open Budget");
        open.add_css_class("pill");
        open.set_action_name(Some("app.open-budget"));
        actions.append(&create);
        actions.append(&open);
        status.set_child(Some(&actions));
        body.append(&status);
        let recent = self.state.borrow().recent_files.clone();
        if !recent.is_empty() {
            let group = adw::PreferencesGroup::builder()
                .title("Recent Budgets")
                .build();
            for path in recent {
                let row = action_row(
                    path.file_stem()
                        .and_then(|s| s.to_str())
                        .unwrap_or("Budget"),
                    &path.to_string_lossy(),
                );
                row.set_activatable(true);
                row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
                let ui = self.clone();
                row.connect_activated(move |_| ui.open_budget(path.clone()));
                group.add(&row);
            }
            body.append(&group);
        }
        let scroll = clamped_scroll(&body, 560);
        toolbar.set_content(Some(&scroll));
        toolbar.upcast()
    }

    fn build_main(self: &Rc<Self>, budget_id: Uuid) -> MainView {
        let split = adw::NavigationSplitView::new();
        split.set_min_sidebar_width(190.0);
        split.set_max_sidebar_width(250.0);
        split.set_sidebar_width_fraction(0.22);
        let sidebar_toolbar = adw::ToolbarView::new();
        let sidebar_header = adw::HeaderBar::new();
        let recent = gtk::MenuButton::builder()
            .icon_name("document-open-symbolic")
            .tooltip_text("Open or Switch Budget")
            .menu_model(&self.recent_menu())
            .build();
        sidebar_header.pack_start(&recent);
        let menu = gtk::MenuButton::builder()
            .icon_name("open-menu-symbolic")
            .tooltip_text("Main Menu")
            .menu_model(&self.app_menu())
            .build();
        sidebar_header.pack_end(&menu);
        sidebar_header.set_title_widget(Some(&gtk::Label::new(Some("Budget Warden"))));
        sidebar_toolbar.add_top_bar(&sidebar_header);
        let sidebar = gtk::ListBox::new();
        sidebar.add_css_class("navigation-sidebar");
        sidebar.set_selection_mode(gtk::SelectionMode::Single);
        sidebar.set_activate_on_single_click(true);
        for (label, icon) in [
            ("Budget", "view-grid-symbolic"),
            ("Reporting", "budget-warden-chart"),
            ("Transactions", "view-list-symbolic"),
        ] {
            let content = gtk::Box::new(Orientation::Horizontal, 12);
            content.set_margin_top(8);
            content.set_margin_bottom(8);
            content.set_margin_start(8);
            content.set_margin_end(8);
            let icon: gtk::Widget = if icon == "budget-warden-chart" {
                chart_icon().upcast()
            } else {
                gtk::Image::from_icon_name(icon).upcast()
            };
            content.append(&icon);
            let text = gtk::Label::new(Some(label));
            text.set_xalign(0.0);
            content.append(&text);
            let row = gtk::ListBoxRow::new();
            row.set_child(Some(&content));
            sidebar.append(&row);
        }
        sidebar.select_row(sidebar.row_at_index(0).as_ref());
        let sidebar_scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&sidebar)
            .build();
        sidebar_toolbar.set_content(Some(&sidebar_scroll));
        split.set_sidebar(Some(&adw::NavigationPage::new(
            &sidebar_toolbar,
            "Budget Warden",
        )));

        let glance_split = adw::OverlaySplitView::builder()
            .sidebar_position(gtk::PackType::End)
            .min_sidebar_width(320.0)
            .max_sidebar_width(420.0)
            .sidebar_width_fraction(0.42)
            .show_sidebar(true)
            .build();
        glance_split.set_hexpand(true);
        glance_split.set_vexpand(true);
        let glance_visible = Rc::new(Cell::new(true));
        let suppress_glance_visibility = Rc::new(Cell::new(false));
        let glance_toggle = gtk::ToggleButton::new();
        glance_toggle.set_child(Some(&gtk::Image::from_icon_name(
            "sidebar-show-right-symbolic",
        )));
        glance_toggle.add_css_class("flat");
        glance_toggle.set_tooltip_text(Some(if glance_split.shows_sidebar() {
            "Hide At a Glance"
        } else {
            "Show At a Glance"
        }));
        glance_toggle.update_property(&[gtk::accessible::Property::Label("At a Glance Sidebar")]);
        glance_toggle.set_active(glance_split.shows_sidebar());
        let glance_split_for_toggle = glance_split.clone();
        let glance_visible_for_toggle = glance_visible.clone();
        let suppress_for_toggle = suppress_glance_visibility.clone();
        glance_toggle.connect_toggled(move |button| {
            if !suppress_for_toggle.get() {
                glance_visible_for_toggle.set(button.is_active());
                glance_split_for_toggle.set_show_sidebar(button.is_active());
            }
            button.set_tooltip_text(Some(if button.is_active() {
                "Hide At a Glance"
            } else {
                "Show At a Glance"
            }));
        });
        let glance_toggle_for_split = glance_toggle.clone();
        let glance_visible_for_split = glance_visible.clone();
        let suppress_for_split = suppress_glance_visibility.clone();
        glance_split.connect_show_sidebar_notify(move |view| {
            if !suppress_for_split.get() {
                glance_visible_for_split.set(view.shows_sidebar());
            }
            let suppressed = suppress_for_split.replace(true);
            glance_toggle_for_split.set_active(view.shows_sidebar());
            suppress_for_split.set(suppressed);
        });
        let suppress_for_collapse = suppress_glance_visibility.clone();
        let visible_for_collapse = glance_visible.clone();
        let ui_for_collapse = self.clone();
        glance_split.connect_collapsed_notify(move |view| {
            if view.is_collapsed() {
                suppress_for_collapse.set(true);
                view.set_show_sidebar(false);
                suppress_for_collapse.set(false);
            } else if visible_for_collapse.get()
                && ui_for_collapse.state.borrow().page == AppPage::Budget
            {
                view.set_show_sidebar(true);
            }
        });
        let glance_breakpoint = adw::Breakpoint::new(
            adw::BreakpointCondition::parse("max-width: 900sp").expect("valid breakpoint"),
        );
        glance_breakpoint.add_setter(&glance_split, "collapsed", Some(&true.to_value()));
        self.window.add_breakpoint(glance_breakpoint);

        let toolbar = adw::ToolbarView::new();
        let header = adw::HeaderBar::new();
        let title = adw::WindowTitle::new("Budget", "");
        header.set_title_widget(Some(&title));
        let actions = gtk::Box::new(Orientation::Horizontal, 6);
        header.pack_end(&actions);
        toolbar.add_top_bar(&header);
        let content = gtk::Box::new(Orientation::Vertical, 0);
        content.set_vexpand(true);
        content.set_hexpand(true);
        toolbar.set_content(Some(&content));
        glance_split.set_content(Some(&toolbar));
        split.set_content(Some(&adw::NavigationPage::new(&glance_split, "Budget")));
        split.set_show_content(true);
        let breakpoint = adw::Breakpoint::new(
            adw::BreakpointCondition::parse("max-width: 760sp").expect("valid breakpoint"),
        );
        breakpoint.add_setter(&split, "collapsed", Some(&true.to_value()));
        self.window.add_breakpoint(breakpoint);
        let weak_ui = Rc::downgrade(self);
        let split_clone = split.clone();
        sidebar.connect_row_selected(move |_, row| {
            let Some(ui) = weak_ui.upgrade() else {
                return;
            };
            let Some(row) = row else {
                return;
            };
            let page = match row.index() {
                1 => AppPage::Reporting,
                2 => AppPage::Transactions,
                _ => AppPage::Budget,
            };
            let changed = ui.state.borrow().page != page;
            ui.state.borrow_mut().page = page;
            split_clone.set_show_content(true);
            if changed {
                ui.render_page(false);
            }
        });
        MainView {
            budget_id: Rc::new(Cell::new(budget_id)),
            split,
            glance_split,
            glance_toggle,
            glance_visible,
            suppress_glance_visibility,
            sidebar,
            title,
            actions,
            recent,
            content,
        }
    }

    fn render_page(self: &Rc<Self>, preserve_scroll: bool) {
        let Some(main) = self.main.borrow().clone() else {
            return;
        };
        let previous = if preserve_scroll {
            self.main_scroll
                .borrow()
                .as_ref()
                .map(|scroll| scroll.vadjustment().value())
                .unwrap_or(0.0)
        } else {
            0.0
        };
        let (page, title) = {
            let state = self.state.borrow();
            (
                state.page,
                state
                    .budget
                    .as_ref()
                    .map(|budget| budget.title.clone())
                    .unwrap_or_default(),
            )
        };
        main.title.set_title(match page {
            AppPage::Budget => "Budget",
            AppPage::Reporting => "Reporting",
            AppPage::Transactions => "Transactions",
        });
        main.title.set_subtitle(&title);
        clear_box(&main.actions);
        self.search.borrow_mut().take();
        let view = match page {
            AppPage::Budget => {
                main.actions.append(&main.glance_toggle);
                let add = gtk::Button::builder()
                    .icon_name("list-add-symbolic")
                    .tooltip_text("New Category")
                    .build();
                let ui = self.clone();
                add.connect_clicked(move |_| ui.show_category_dialog(None, None));
                main.actions.append(&add);
                let view = self.budget_page();
                let sidebar = self.at_a_glance_panel();
                main.glance_split.set_sidebar(Some(&sidebar));
                main.suppress_glance_visibility.set(true);
                main.glance_split.set_show_sidebar(
                    main.glance_visible.get() && !main.glance_split.is_collapsed(),
                );
                main.suppress_glance_visibility.set(false);
                PageView {
                    widget: view.widget,
                    scroll: view.scroll,
                }
            }
            AppPage::Reporting => {
                main.suppress_glance_visibility.set(true);
                main.glance_split.set_show_sidebar(false);
                main.suppress_glance_visibility.set(false);
                self.reporting_page(&main.actions)
            }
            AppPage::Transactions => {
                main.suppress_glance_visibility.set(true);
                main.glance_split.set_show_sidebar(false);
                main.suppress_glance_visibility.set(false);
                let add = gtk::Button::builder()
                    .icon_name("list-add-symbolic")
                    .tooltip_text("New Transaction")
                    .build();
                add.set_sensitive(
                    self.state
                        .borrow()
                        .budget
                        .as_ref()
                        .is_some_and(|budget| !budget.categories.is_empty()),
                );
                let ui = self.clone();
                add.connect_clicked(move |_| ui.show_transaction_dialog(None, None, &ui.window));
                main.actions.append(&add);
                self.transactions_page(None, self.filters.clone(), &self.window)
            }
        };
        clear_box(&main.content);
        main.content.append(&view.widget);
        *self.main_scroll.borrow_mut() = Some(view.scroll.clone());
        restore_scroll(&view.scroll, previous);
    }

    fn budget_page(self: &Rc<Self>) -> PageView {
        let (budget, currency) = {
            let state = self.state.borrow();
            (
                state.budget.clone().expect("open budget"),
                state.currency.clone(),
            )
        };
        let body = gtk::Box::new(Orientation::Vertical, 28);
        body.set_widget_name("budget-categories");
        body.set_margin_top(24);
        body.set_margin_bottom(32);
        for category_type in category_types() {
            let categories = budget.ordered_categories(Some(category_type));
            let group = adw::PreferencesGroup::builder()
                .title(category_type.title())
                .build();
            let planned =
                category_total(&categories, |category| category.amount_planned, &currency);
            let actual = category_total(&categories, |category| category.amount_actual, &currency);
            group.set_description(Some(&format!("{planned} planned · {actual} actual")));
            let add = gtk::Button::builder()
                .icon_name("list-add-symbolic")
                .tooltip_text(format!("New {} Category", category_type.title()))
                .valign(Align::Center)
                .css_classes(["flat"])
                .build();
            let ui = self.clone();
            add.connect_clicked(move |_| ui.show_category_dialog(None, Some(category_type)));
            group.set_header_suffix(Some(&add));
            if categories.is_empty() {
                let empty = action_row("No categories", "Use + to add a category");
                empty.set_sensitive(false);
                group.add(&empty);
            }
            for category in categories {
                group.add(&self.category_row(&category, &currency));
            }
            body.append(&group);
        }
        let scroll = clamped_scroll(&body, 880);
        scroll.set_widget_name("category-scroll");
        PageView {
            widget: scroll.clone().upcast(),
            scroll,
        }
    }

    fn at_a_glance_panel(self: &Rc<Self>) -> gtk::Widget {
        let result = {
            let state = self.state.borrow();
            state
                .reporting_summary()
                .map(|summary| (summary, state.report_mode, state.currency.clone()))
        };
        match result {
            Ok((summary, mode, currency)) => {
                let weak_ui = Rc::downgrade(self);
                crate::reporting::at_a_glance(&summary, mode, &currency, move |next_mode| {
                    let Some(ui) = weak_ui.upgrade() else {
                        return;
                    };
                    gtk::glib::idle_add_local_once(move || {
                        let changed = ui.state.borrow().report_mode != next_mode;
                        if changed {
                            ui.state.borrow_mut().report_mode = next_mode;
                            ui.refresh_at_a_glance();
                        }
                    });
                })
            }
            Err(error) => adw::StatusPage::builder()
                .title("Reporting Unavailable")
                .description(error)
                .icon_name("dialog-warning-symbolic")
                .build()
                .upcast(),
        }
    }

    fn refresh_at_a_glance(self: &Rc<Self>) {
        let Some(main) = self.main.borrow().clone() else {
            return;
        };
        if self.state.borrow().page != AppPage::Budget {
            return;
        }
        let sidebar = self.at_a_glance_panel();
        main.glance_split.set_sidebar(Some(&sidebar));
    }

    fn category_row(self: &Rc<Self>, category: &BWCategory, currency: &str) -> adw::ActionRow {
        let count = category.transactions.len();
        let subtitle = if matches!(
            category.category_type,
            BWCategoryType::Savings | BWCategoryType::Debt
        ) {
            format!(
                "{} accumulated · {} transaction{}",
                money_text(category.amount_accumulated.value, currency),
                count,
                if count == 1 { "" } else { "s" }
            )
        } else {
            format!("{} transaction{}", count, if count == 1 { "" } else { "s" })
        };
        let row = action_row(&category.title, &subtitle);
        row.set_widget_name(&format!("category-{}", category.id));
        row.set_activatable(true);
        let amounts = gtk::Box::new(Orientation::Vertical, 3);
        amounts.set_valign(Align::Center);
        let planned = amount_label(&money_text(category.amount_planned.value, currency));
        let actual = amount_label(&format!(
            "{} actual",
            money_text(category.amount_actual.value, currency)
        ));
        actual.add_css_class("caption");
        actual.add_css_class("dim-label");
        amounts.append(&planned);
        amounts.append(&actual);
        row.add_suffix(&amounts);
        row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
        let id = category.id;
        let ui = self.clone();
        row.connect_activated(move |_| ui.show_category_dialog(Some(id), None));
        row
    }

    fn reporting_page(self: &Rc<Self>, actions: &gtk::Box) -> PageView {
        let body = gtk::Box::new(Orientation::Vertical, 24);
        body.set_margin_top(24);
        body.set_margin_bottom(32);
        let currency = self.state.borrow().currency.clone();
        let mode = self.state.borrow().report_mode;
        let switch = gtk::Box::new(Orientation::Horizontal, 0);
        switch.add_css_class("linked");
        let planned = gtk::ToggleButton::with_label("Planned");
        let actual = gtk::ToggleButton::with_label("Actual");
        actual.set_group(Some(&planned));
        planned.set_active(mode == ReportMode::Planned);
        actual.set_active(mode == ReportMode::Actual);
        for (button, next_mode) in [
            (&planned, ReportMode::Planned),
            (&actual, ReportMode::Actual),
        ] {
            let ui = self.clone();
            button.connect_toggled(move |button| {
                if button.is_active() && ui.state.borrow().report_mode != next_mode {
                    ui.state.borrow_mut().report_mode = next_mode;
                    // Finish the toggle emission before replacing the page's controls.
                    let weak_ui = Rc::downgrade(&ui);
                    gtk::glib::idle_add_local_once(move || {
                        if let Some(ui) = weak_ui.upgrade() {
                            ui.render_page(true);
                        }
                    });
                }
            });
        }
        switch.append(&planned);
        switch.append(&actual);
        actions.append(&switch);
        let result = self.state.borrow().reporting_summary();
        match result {
            Err(error) => body.append(
                &adw::StatusPage::builder()
                    .title("Reporting Unavailable")
                    .description(error)
                    .icon_name("dialog-warning-symbolic")
                    .build(),
            ),
            Ok(summary) => body.append(&crate::reporting::content(&summary, mode, &currency)),
        }
        let scroll = clamped_scroll(&body, 1120);
        PageView {
            widget: scroll.clone().upcast(),
            scroll,
        }
    }

    fn transactions_page(
        self: &Rc<Self>,
        category_id: Option<Uuid>,
        filters: Rc<RefCell<TransactionFilters>>,
        parent: &impl IsA<gtk::Window>,
    ) -> PageView {
        let body = gtk::Box::new(Orientation::Vertical, 18);
        body.set_margin_top(24);
        body.set_margin_bottom(32);
        let controls = gtk::Box::new(Orientation::Horizontal, 8);
        let search = gtk::SearchEntry::builder()
            .placeholder_text("Search transactions")
            .hexpand(true)
            .build();
        search.set_text(&filters.borrow().search);
        controls.append(&search);
        if category_id.is_none() {
            *self.search.borrow_mut() = Some(search.clone());
        }
        let filter_button = gtk::MenuButton::builder()
            .icon_name("view-filter-symbolic")
            .tooltip_text("Filter and Sort")
            .build();
        controls.append(&filter_button);
        body.append(&controls);
        let list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .css_classes(["boxed-list"])
            .build();
        let empty = adw::StatusPage::builder()
            .icon_name("view-list-symbolic")
            .title("No Transactions")
            .description("Add a transaction to start building your history.")
            .build();
        body.append(&list);
        body.append(&empty);
        let weak_ui = Rc::downgrade(self);
        let filters_clone = filters.clone();
        let list_clone = list.clone();
        let empty_clone = empty.clone();
        let parent: gtk::Window = parent.as_ref().clone();
        let update: Rc<dyn Fn()> = Rc::new(move || {
            if let Some(ui) = weak_ui.upgrade() {
                ui.fill_transactions(
                    &list_clone,
                    &empty_clone,
                    category_id,
                    &filters_clone.borrow(),
                    &parent,
                );
            }
        });
        update();
        let update_clone = update.clone();
        let filters_clone = filters.clone();
        search.connect_search_changed(move |entry| {
            filters_clone.borrow_mut().search = entry.text().to_string();
            update_clone();
        });
        filter_button.set_popover(Some(&self.filter_popover(
            category_id,
            filters,
            update,
            &filter_button,
        )));
        let scroll = clamped_scroll(&body, 880);
        PageView {
            widget: scroll.clone().upcast(),
            scroll,
        }
    }

    fn filter_popover(
        self: &Rc<Self>,
        category_id: Option<Uuid>,
        filters: Rc<RefCell<TransactionFilters>>,
        update: Rc<dyn Fn()>,
        button: &gtk::MenuButton,
    ) -> gtk::Popover {
        let popover = gtk::Popover::new();
        let body = gtk::Box::new(Orientation::Vertical, 18);
        body.set_size_request(300, -1);
        body.set_margin_top(12);
        body.set_margin_bottom(12);
        body.set_margin_start(12);
        body.set_margin_end(12);
        let snapshot = filters.borrow().clone();
        let dates = adw::PreferencesGroup::new();
        let enabled = adw::SwitchRow::builder()
            .title("Date Range")
            .active(snapshot.date_enabled)
            .build();
        let start = date_entry("From", &snapshot.start);
        let end = date_entry("Until", &snapshot.end);
        start.set_sensitive(snapshot.date_enabled);
        end.set_sensitive(snapshot.date_enabled);
        dates.add(&enabled);
        dates.add(&start);
        dates.add(&end);
        body.append(&dates);
        let amounts = adw::PreferencesGroup::new();
        let minimum = entry_row("Minimum Amount", &snapshot.minimum);
        let maximum = entry_row("Maximum Amount", &snapshot.maximum);
        amounts.add(&minimum);
        amounts.add(&maximum);
        body.append(&amounts);
        let sort = combo_row(
            "Sort By",
            &[
                "Newest First",
                "Oldest First",
                "Amount: High to Low",
                "Amount: Low to High",
                "Title",
                "Category",
                "Description",
            ],
        );
        sort.set_selected(sort_index(snapshot.sort));
        let order = adw::PreferencesGroup::new();
        order.add(&sort);
        body.append(&order);
        let reset = gtk::Button::with_label("Reset Filters");
        body.append(&reset);
        popover.set_child(Some(&body));
        let button_weak = button.downgrade();
        let filters_clone = filters.clone();
        let changed: Rc<dyn Fn()> = Rc::new(move || {
            if let Some(button) = button_weak.upgrade() {
                if filters_clone.borrow().active() {
                    button.add_css_class("accent");
                } else {
                    button.remove_css_class("accent");
                }
            }
            update();
        });
        changed();
        let filters_clone = filters.clone();
        let changed_clone = changed.clone();
        let start_clone = start.clone();
        let end_clone = end.clone();
        enabled.connect_active_notify(move |row| {
            filters_clone.borrow_mut().date_enabled = row.is_active();
            start_clone.set_sensitive(row.is_active());
            end_clone.set_sensitive(row.is_active());
            changed_clone();
        });
        for (entry, field) in [(&start, 0), (&end, 1), (&minimum, 2), (&maximum, 3)] {
            let filters = filters.clone();
            let changed = changed.clone();
            entry.connect_changed(move |entry| {
                let value = entry.text().to_string();
                let valid = if field < 2 {
                    parse_date(&value).is_some()
                } else {
                    value.trim().is_empty() || parse_money(&value).is_some()
                };
                if valid {
                    entry.remove_css_class("error");
                } else {
                    entry.add_css_class("error");
                }
                {
                    let mut filters = filters.borrow_mut();
                    match field {
                        0 => filters.start = value,
                        1 => filters.end = value,
                        2 => filters.minimum = value,
                        _ => filters.maximum = value,
                    }
                }
                changed();
            });
        }
        let filters_clone = filters.clone();
        let changed_clone = changed.clone();
        sort.connect_selected_notify(move |row| {
            filters_clone.borrow_mut().sort = sort_from_index(row.selected());
            changed_clone();
        });
        let ui = self.clone();
        reset.connect_clicked(move |_| {
            let range = {
                let state = ui.state.borrow();
                category_id
                    .and_then(|id| state.category(id))
                    .map(|category| category_date_range(&category))
                    .or_else(|| state.budget.as_ref().map(budget_date_range))
                    .unwrap_or((today_text(), today_text()))
            };
            // Widget signals update the model; never hold a mutable borrow while emitting them.
            enabled.set_active(false);
            start.set_text(&range.0);
            end.set_text(&range.1);
            minimum.set_text("");
            maximum.set_text("");
            sort.set_selected(0);
            changed();
        });
        popover
    }

    fn fill_transactions(
        self: &Rc<Self>,
        list: &gtk::ListBox,
        empty: &adw::StatusPage,
        category_id: Option<Uuid>,
        filters: &TransactionFilters,
        parent: &gtk::Window,
    ) {
        while let Some(child) = list.first_child() {
            list.remove(&child);
        }
        let (budget, currency) = {
            let state = self.state.borrow();
            (state.budget.clone(), state.currency.clone())
        };
        let Some(budget) = budget else {
            return;
        };
        let mut items = budget
            .categories
            .iter()
            .filter(|category| category_id.is_none_or(|id| category.id == id))
            .flat_map(|category| {
                category
                    .transactions
                    .iter()
                    .map(move |transaction| TransactionItem {
                        category_title: category.title.clone(),
                        category_type: category.category_type,
                        transaction: transaction.clone(),
                    })
            })
            .filter(|item| filters.matches(item, &currency))
            .collect::<Vec<_>>();
        sort_transactions(&mut items, filters.sort);
        empty.set_visible(items.is_empty());
        list.set_visible(!items.is_empty());
        let is_filtered = filters.active() || !filters.search.trim().is_empty();
        empty.set_title(if is_filtered {
            "No Matching Transactions"
        } else {
            "No Transactions"
        });
        empty.set_description(Some(if is_filtered {
            "Try changing your search or filters."
        } else {
            "Add a transaction to start building your history."
        }));
        for item in items {
            let transaction = &item.transaction;
            let mut details = Vec::new();
            if category_id.is_none() {
                details.push(item.category_title);
            }
            details.push(transaction_date(transaction));
            if !transaction.description.trim().is_empty() {
                details.push(transaction.description.clone());
            }
            let row = action_row(&transaction.title, &details.join(" · "));
            row.set_widget_name(&format!("transaction-{}", transaction.id));
            row.set_activatable(true);
            row.add_suffix(&amount_label(&money_text(
                transaction.amount.value,
                &currency,
            )));
            row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
            let id = transaction.id;
            let ui = self.clone();
            let parent = parent.clone();
            row.connect_activated(move |_| {
                ui.show_transaction_dialog(Some(id), category_id, &parent)
            });
            list.append(&row);
        }
    }

    fn show_category_dialog(
        self: &Rc<Self>,
        id: Option<Uuid>,
        initial_type: Option<BWCategoryType>,
    ) {
        let editing_budget = self
            .state
            .borrow()
            .budget
            .as_ref()
            .map(|budget| (budget.id, budget.url.clone()));
        let category = id.and_then(|id| self.state.borrow().category(id));
        if id.is_some() && category.is_none() {
            self.show_error("This category no longer exists.");
            return;
        }
        let form = FormDialog::new(
            if category.is_some() {
                "Edit Category"
            } else {
                "New Category"
            },
            if category.is_some() { "Save" } else { "Add" },
        );
        self.track_editor(&form.dialog);
        let group = adw::PreferencesGroup::new();
        let title = entry_row(
            "Title",
            category
                .as_ref()
                .map(|category| category.title.as_str())
                .unwrap_or(""),
        );
        title.set_widget_name("category-title");
        group.add(&title);
        let type_names = category_types()
            .iter()
            .map(|kind| kind.title())
            .collect::<Vec<_>>();
        let type_refs = type_names.iter().map(String::as_str).collect::<Vec<_>>();
        let kind = combo_row("Type", &type_refs);
        kind.set_selected(type_index(
            category
                .as_ref()
                .map(|category| category.category_type)
                .or(initial_type)
                .unwrap_or(BWCategoryType::Expenses),
        ));
        group.add(&kind);
        let planned = entry_row(
            "Planned Amount",
            &money_input(
                category
                    .as_ref()
                    .map(|category| category.amount_planned.value)
                    .unwrap_or(0),
            ),
        );
        planned.set_widget_name("category-planned");
        group.add(&planned);
        let accumulated = entry_row(
            "Accumulated Amount",
            &money_input(
                category
                    .as_ref()
                    .map(|category| category.amount_accumulated.value)
                    .unwrap_or(0),
            ),
        );
        let editing = id.is_some();
        let show_accumulated = editing && kind.selected() >= 2;
        accumulated.set_visible(show_accumulated);
        group.add(&accumulated);
        let accumulated_clone = accumulated.clone();
        kind.connect_selected_notify(move |row| {
            accumulated_clone.set_visible(editing && row.selected() >= 2)
        });
        form.body.append(&group);
        if let Some(category) = category.as_ref() {
            let details = adw::PreferencesGroup::new();
            let actual = action_row("Actual Amount", "Calculated from transactions");
            actual.add_suffix(&amount_label(&money_text(
                category.amount_actual.value,
                &self.state.borrow().currency,
            )));
            details.add(&actual);
            let view = action_row(
                "Transactions",
                &format!("{} transactions", category.transactions.len()),
            );
            view.set_activatable(true);
            view.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
            let ui = self.clone();
            let id = category.id;
            let weak_dialog = form.dialog.downgrade();
            view.connect_activated(move |_| {
                if let Some(dialog) = weak_dialog.upgrade() {
                    dialog.close();
                }
                ui.open_category_window(id);
            });
            details.add(&view);
            let position = action_row("Position", "Order within this category type");
            let order = gtk::Box::new(Orientation::Horizontal, 0);
            order.add_css_class("linked");
            let up = gtk::Button::builder()
                .icon_name("go-up-symbolic")
                .tooltip_text("Move Up")
                .valign(Align::Center)
                .build();
            let down = gtk::Button::builder()
                .icon_name("go-down-symbolic")
                .tooltip_text("Move Down")
                .valign(Align::Center)
                .build();
            up.set_sensitive(self.category_can_move(id, -1));
            down.set_sensitive(self.category_can_move(id, 1));
            order.append(&up);
            order.append(&down);
            order.set_valign(Align::Center);
            position.add_suffix(&order);
            details.add(&position);
            for (button, offset) in [(&up, -1), (&down, 1)] {
                let ui = self.clone();
                let error = form.error.clone();
                let up_weak = up.downgrade();
                let down_weak = down.downgrade();
                let editing_budget = editing_budget.clone();
                button.connect_clicked(move |_| {
                    if !ui.is_current_budget(&editing_budget) {
                        return;
                    }
                    let result = ui.state.borrow_mut().move_category(id, offset);
                    match result {
                        Ok(()) => {
                            ui.refresh();
                            if let Some(up) = up_weak.upgrade() {
                                up.set_sensitive(ui.category_can_move(id, -1));
                            }
                            if let Some(down) = down_weak.upgrade() {
                                down.set_sensitive(ui.category_can_move(id, 1));
                            }
                        }
                        Err(message) => inline_error(&error, &message),
                    }
                });
            }
            form.body.append(&details);
            let delete = gtk::Button::with_label("Delete Category…");
            delete.add_css_class("destructive-action");
            let ui = self.clone();
            let weak_dialog = form.dialog.downgrade();
            let editing_budget = editing_budget.clone();
            delete.connect_clicked(move |_| {
                let Some(editor) = weak_dialog.upgrade() else {
                    return;
                };
                let alert = delete_alert(
                    "Delete Category?",
                    "The category and all its transactions will be removed from this budget.",
                    "Delete Category",
                );
                let ui = ui.clone();
                let weak_editor = editor.downgrade();
                let editing_budget = editing_budget.clone();
                alert.connect_response(Some("delete"), move |_, _| {
                    if !ui.is_current_budget(&editing_budget) {
                        return;
                    }
                    let result = ui.state.borrow_mut().delete_category(id);
                    match result {
                        Ok(()) => {
                            if let Some(editor) = weak_editor.upgrade() {
                                editor.close();
                            }
                            ui.refresh();
                        }
                        Err(error) => ui.show_error(&error),
                    }
                });
                alert.present(Some(&editor));
            });
            form.body.append(&delete);
        }
        require_title(&title, &form.save);
        let ui = self.clone();
        let weak_dialog = form.dialog.downgrade();
        let error = form.error.clone();
        form.save.connect_clicked(move |_| {
            if !ui.is_current_budget(&editing_budget) {
                return;
            }
            let Some(planned) = parse_money(&planned.text()) else {
                inline_error(
                    &error,
                    "Enter a planned amount with up to two decimal places.",
                );
                return;
            };
            let category_type = category_types()[kind.selected().min(3) as usize];
            let accumulated = if matches!(
                category_type,
                BWCategoryType::Savings | BWCategoryType::Debt
            ) {
                let Some(value) = parse_money(&accumulated.text()) else {
                    inline_error(&error, "Enter a valid accumulated amount.");
                    return;
                };
                value
            } else {
                0
            };
            let title = title.text().trim().to_string();
            if title.is_empty() {
                inline_error(&error, "Enter a category title.");
                return;
            }
            let result = if let Some(mut category) = category.clone() {
                category.title = title;
                category.amount_planned = BWMoneyAmount { value: planned };
                category.amount_accumulated = BWMoneyAmount { value: accumulated };
                category.category_type = category_type;
                ui.state.borrow_mut().update_category(category)
            } else {
                // New savings/debt categories start with zero accumulated, as on macOS.
                ui.state
                    .borrow_mut()
                    .create_category(&title, planned, category_type)
            };
            match result {
                Ok(()) => {
                    if let Some(dialog) = weak_dialog.upgrade() {
                        dialog.close();
                    }
                    ui.refresh();
                }
                Err(message) => inline_error(&error, &message),
            }
        });
        form.dialog.present(Some(&self.window));
    }

    fn category_can_move(&self, id: Uuid, offset: i32) -> bool {
        let state = self.state.borrow();
        let Some(category) = state.category(id) else {
            return false;
        };
        let Some(budget) = state.budget.as_ref() else {
            return false;
        };
        let categories = budget.ordered_categories(Some(category.category_type));
        categories
            .iter()
            .position(|category| category.id == id)
            .is_some_and(|index| (0..categories.len() as i32).contains(&(index as i32 + offset)))
    }

    fn show_transaction_dialog(
        self: &Rc<Self>,
        id: Option<Uuid>,
        initial_category: Option<Uuid>,
        parent: &impl IsA<gtk::Window>,
    ) {
        let editing_budget = self
            .state
            .borrow()
            .budget
            .as_ref()
            .map(|budget| (budget.id, budget.url.clone()));
        let existing = id.and_then(|id| self.state.borrow().transaction(id));
        if id.is_some() && existing.is_none() {
            self.show_error("This transaction no longer exists.");
            return;
        }
        let categories = self
            .state
            .borrow()
            .budget
            .as_ref()
            .map(|budget| budget.ordered_categories(None))
            .unwrap_or_default();
        if categories.is_empty() {
            self.show_error("Add a category before creating a transaction.");
            return;
        }
        let form = FormDialog::new(
            if existing.is_some() {
                "Edit Transaction"
            } else {
                "New Transaction"
            },
            if existing.is_some() { "Save" } else { "Add" },
        );
        self.track_editor(&form.dialog);
        let transaction = existing.as_ref().map(|(_, transaction)| transaction);
        let group = adw::PreferencesGroup::new();
        let title = entry_row(
            "Title",
            transaction
                .map(|transaction| transaction.title.as_str())
                .unwrap_or(""),
        );
        title.set_widget_name("transaction-title");
        let amount = entry_row(
            "Amount",
            &transaction
                .map(|transaction| money_input(transaction.amount.value))
                .unwrap_or_default(),
        );
        amount.set_widget_name("transaction-amount");
        let description = entry_row(
            "Description",
            transaction
                .map(|transaction| transaction.description.as_str())
                .unwrap_or(""),
        );
        let date = date_entry(
            "Date",
            &transaction.map(transaction_date).unwrap_or_else(today_text),
        );
        date.set_widget_name("transaction-date");
        group.add(&title);
        group.add(&amount);
        group.add(&description);
        group.add(&date);
        form.body.append(&group);
        let category_group = adw::PreferencesGroup::new();
        let names = categories
            .iter()
            .map(|category| format!("{} · {}", category.title, category.category_type.title()))
            .collect::<Vec<_>>();
        let name_refs = names.iter().map(String::as_str).collect::<Vec<_>>();
        let category = combo_row("Category", &name_refs);
        category.set_enable_search(true);
        let selected = existing.as_ref().map(|(id, _)| *id).or(initial_category);
        category.set_selected(
            categories
                .iter()
                .position(|category| Some(category.id) == selected)
                .unwrap_or(0) as u32,
        );
        category_group.add(&category);
        form.body.append(&category_group);
        if let Some((category_id, transaction)) = existing.as_ref() {
            let category_id = *category_id;
            let transaction_id = transaction.id;
            let delete = gtk::Button::with_label("Delete Transaction…");
            delete.add_css_class("destructive-action");
            let weak_editor = form.dialog.downgrade();
            let ui = self.clone();
            let editing_budget = editing_budget.clone();
            delete.connect_clicked(move |_| {
                let Some(editor) = weak_editor.upgrade() else {
                    return;
                };
                let alert = delete_alert(
                    "Delete Transaction?",
                    "This transaction will be removed from the budget.",
                    "Delete Transaction",
                );
                let weak_editor = editor.downgrade();
                let ui = ui.clone();
                let editing_budget = editing_budget.clone();
                alert.connect_response(Some("delete"), move |_, _| {
                    if !ui.is_current_budget(&editing_budget) {
                        return;
                    }
                    let result = ui
                        .state
                        .borrow_mut()
                        .delete_transaction(category_id, transaction_id);
                    match result {
                        Ok(()) => {
                            if let Some(editor) = weak_editor.upgrade() {
                                editor.close();
                            }
                            ui.refresh();
                        }
                        Err(error) => ui.show_error(&error),
                    }
                });
                alert.present(Some(&editor));
            });
            form.body.append(&delete);
        }
        require_title(&title, &form.save);
        let ui = self.clone();
        let weak_dialog = form.dialog.downgrade();
        let error = form.error.clone();
        form.save.connect_clicked(move |_| {
            if !ui.is_current_budget(&editing_budget) {
                return;
            }
            let title = title.text().trim().to_string();
            if title.is_empty() {
                inline_error(&error, "Enter a transaction title.");
                return;
            }
            let Some(amount) = parse_money(&amount.text()).filter(|amount| *amount > 0) else {
                inline_error(&error, "Enter an amount greater than zero.");
                return;
            };
            let Some(date) = parse_date(&date.text()) else {
                inline_error(&error, "Choose a valid date or enter YYYY-MM-DD.");
                return;
            };
            let Some(target) = categories.get(category.selected() as usize) else {
                inline_error(&error, "Choose a category.");
                return;
            };
            let description = description.text().trim().to_string();
            let result = if let Some((origin, original)) = existing.as_ref() {
                ui.state.borrow_mut().save_transaction(
                    *origin,
                    target.id,
                    BWTransaction {
                        id: original.id,
                        title,
                        description,
                        date: BWDate {
                            year: date.year(),
                            month: date.month() as i32,
                            day: date.day() as i32,
                        },
                        amount: BWMoneyAmount { value: amount },
                    },
                )
            } else {
                ui.state.borrow_mut().create_transaction(
                    target.id,
                    &title,
                    &description,
                    date,
                    amount,
                )
            };
            match result {
                Ok(()) => {
                    if let Some(dialog) = weak_dialog.upgrade() {
                        dialog.close();
                    }
                    ui.refresh();
                }
                Err(message) => inline_error(&error, &message),
            }
        });
        form.dialog.present(Some(parent.as_ref()));
    }

    fn show_new_budget_dialog(self: &Rc<Self>) {
        let form = FormDialog::new("New Budget", "Continue");
        let group = adw::PreferencesGroup::new();
        let title = entry_row("Title", &Local::now().format("%B %Y").to_string());
        title.set_widget_name("budget-title");
        group.add(&title);
        let mut templates = vec![BudgetTemplate::BasicMonthly, BudgetTemplate::Empty];
        let mut names = vec!["Monthly Budget".to_string(), "Empty Budget".to_string()];
        for path in self.state.borrow().recent_files.clone() {
            if let Ok(budget) = read_budget(&path) {
                names.push(format!("Previous · {}", budget.title));
                templates.push(BudgetTemplate::Previous(path));
            }
        }
        let refs = names.iter().map(String::as_str).collect::<Vec<_>>();
        let template = combo_row("Template", &refs);
        template.set_selected(0);
        template.set_widget_name("budget-template");
        group.add(&template);
        group.set_description(Some(
            "Choose where to save your .budget file in the next step.",
        ));
        form.body.append(&group);
        require_title(&title, &form.save);
        let ui = self.clone();
        let weak_dialog = form.dialog.downgrade();
        let error = form.error.clone();
        form.save.connect_clicked(move |save| {
            let title = title.text().trim().to_string();
            if title.is_empty() {
                inline_error(&error, "Enter a budget title.");
                return;
            }
            let Some(template) = templates.get(template.selected() as usize).cloned() else {
                return;
            };
            let chooser = budget_file_dialog("Save Budget");
            chooser.set_initial_name(Some(&budget_file_name(&title)));
            save.set_sensitive(false);
            let ui = ui.clone();
            let weak_dialog = weak_dialog.clone();
            let error = error.clone();
            let weak_save = save.downgrade();
            chooser.save(
                Some(&ui.window.clone()),
                gtk::gio::Cancellable::NONE,
                move |result| {
                    if let Some(save) = weak_save.upgrade() {
                        save.set_sensitive(true);
                    }
                    let file = match result {
                        Ok(file) => file,
                        Err(message) => {
                            if !file_dialog_cancelled(&message) {
                                inline_error(&error, &message.to_string());
                            }
                            return;
                        }
                    };
                    let Some(mut path) = file.path() else {
                        inline_error(&error, "Choose a local file location for this budget.");
                        return;
                    };
                    if path.extension().is_none() {
                        path.set_extension("budget");
                    }
                    let result = ui
                        .state
                        .borrow_mut()
                        .create_budget(&title, &template, &path);
                    match result {
                        Ok(()) => {
                            if let Some(dialog) = weak_dialog.upgrade() {
                                dialog.close();
                            }
                            ui.refresh();
                        }
                        Err(message) => inline_error(&error, &message),
                    }
                },
            );
        });
        form.dialog.present(Some(&self.window));
    }

    fn open_file_dialog(self: &Rc<Self>) {
        let chooser = budget_file_dialog("Open Budget");
        let ui = self.clone();
        chooser.open(
            Some(&self.window),
            gtk::gio::Cancellable::NONE,
            move |result| match result {
                Ok(file) => match file.path() {
                    Some(path) => ui.open_budget(path),
                    None => ui.show_error("Choose a local budget file."),
                },
                Err(error) if !file_dialog_cancelled(&error) => ui.show_error(&error.to_string()),
                Err(_) => (),
            },
        );
    }

    fn open_budget(self: &Rc<Self>, path: PathBuf) {
        let result = self.state.borrow_mut().open_budget(&path);
        match result {
            Ok(()) => {
                self.refresh();
                self.window.present();
            }
            Err(error) => self.show_error(&error),
        }
    }

    fn show_preferences(self: &Rc<Self>) {
        let dialog = adw::PreferencesDialog::new();
        let page = adw::PreferencesPage::new();
        let group = adw::PreferencesGroup::new();
        let currencies = supported_currencies();
        let names = currencies
            .iter()
            .map(|currency| format!("{} ({}, {})", currency.name, currency.code, currency.symbol))
            .collect::<Vec<_>>();
        let refs = names.iter().map(String::as_str).collect::<Vec<_>>();
        let currency = combo_row("Currency", &refs);
        currency.set_enable_search(true);
        currency.set_selected(
            currencies
                .iter()
                .position(|currency| currency.code == self.state.borrow().currency)
                .unwrap_or(0) as u32,
        );
        group.add(&currency);
        page.add(&group);
        dialog.add(&page);
        let ui = self.clone();
        currency.connect_selected_notify(move |row| {
            if let Some(currency) = supported_currencies().get(row.selected() as usize) {
                let result = ui.state.borrow_mut().set_currency(currency.code.clone());
                match result {
                    Ok(()) => ui.refresh(),
                    Err(error) => ui.show_error(&error),
                }
            }
        });
        dialog.present(Some(&self.window));
    }

    fn show_about(&self) {
        let dialog = adw::AboutDialog::builder()
            .application_name("Budget Warden")
            .application_icon("com.lazarovco.BudgetWarden")
            .developer_name("Lazarov and Co EOOD")
            .version(env!("CARGO_PKG_VERSION"))
            .comments("Plan your money with portable local budgets.")
            .license_type(gtk::License::Custom)
            .license("Source-Available Educational License. See the LICENSE file for full terms.")
            .build();
        dialog.present(Some(&self.window));
    }

    fn track_editor(&self, dialog: &adw::Dialog) {
        let mut editors = self.editors.borrow_mut();
        editors.retain(|editor| editor.upgrade().is_some());
        editors.push(dialog.downgrade());
    }

    fn is_current_budget(&self, identity: &Option<(Uuid, Option<String>)>) -> bool {
        let current = self
            .state
            .borrow()
            .budget
            .as_ref()
            .map(|budget| (budget.id, budget.url.clone()));
        if current != *identity {
            self.show_error("The open budget has changed. Close this editor and reopen it in the current budget.");
            return false;
        }
        true
    }

    fn show_error(&self, message: &str) {
        let dialog = adw::AlertDialog::new(Some("Could Not Complete Action"), Some(message));
        dialog.add_response("close", "Close");
        dialog.set_default_response(Some("close"));
        dialog.set_close_response("close");
        dialog.present(Some(&self.window));
    }

    fn open_category_window(self: &Rc<Self>, category_id: Uuid) {
        let existing = self
            .category_windows
            .borrow()
            .iter()
            .find(|handle| handle.category_id == category_id)
            .cloned();
        if let Some(handle) = existing {
            handle.window.present();
            return;
        }
        let Some(category) = self.state.borrow().category(category_id) else {
            return;
        };
        let window = adw::ApplicationWindow::builder()
            .application(&self.app)
            .default_width(780)
            .default_height(650)
            .width_request(360)
            .height_request(400)
            .build();
        let handle = CategoryWindow {
            window: window.clone(),
            category_id,
            filters: Rc::new(RefCell::new(TransactionFilters::new(category_date_range(
                &category,
            )))),
            scroll: Rc::new(RefCell::new(None)),
        };
        self.category_windows.borrow_mut().push(handle.clone());
        let weak_ui = Rc::downgrade(self);
        window.connect_close_request(move |window| {
            if let Some(ui) = weak_ui.upgrade() {
                ui.category_windows
                    .borrow_mut()
                    .retain(|handle| handle.window != *window);
            }
            gtk::glib::Propagation::Proceed
        });
        self.render_category_window(&handle);
        window.present();
    }

    fn render_category_window(self: &Rc<Self>, handle: &CategoryWindow) {
        let Some(category) = self.state.borrow().category(handle.category_id) else {
            handle.window.close();
            return;
        };
        let previous = handle
            .scroll
            .borrow()
            .as_ref()
            .map(|scroll| scroll.vadjustment().value())
            .unwrap_or(0.0);
        let toolbar = adw::ToolbarView::new();
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&adw::WindowTitle::new(
            &category.title,
            "Transactions",
        )));
        handle
            .window
            .set_title(Some(&format!("{} — Budget Warden", category.title)));
        let add = gtk::Button::builder()
            .icon_name("list-add-symbolic")
            .tooltip_text("New Transaction")
            .build();
        let ui = self.clone();
        let parent = handle.window.clone();
        let id = category.id;
        add.connect_clicked(move |_| ui.show_transaction_dialog(None, Some(id), &parent));
        header.pack_end(&add);
        toolbar.add_top_bar(&header);
        let page =
            self.transactions_page(Some(category.id), handle.filters.clone(), &handle.window);
        toolbar.set_content(Some(&page.widget));
        handle.window.set_content(Some(&toolbar));
        *handle.scroll.borrow_mut() = Some(page.scroll.clone());
        restore_scroll(&page.scroll, previous);
    }
}

fn clamped_scroll(child: &impl IsA<gtk::Widget>, maximum_size: i32) -> gtk::ScrolledWindow {
    let clamp = adw::Clamp::builder()
        .maximum_size(maximum_size)
        .tightening_threshold(600)
        .child(child)
        .build();
    clamp.set_margin_start(24);
    clamp.set_margin_end(24);
    // A scrolled window otherwise requests only its minimum height, clipping the template list.
    gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Automatic)
        .hexpand(true)
        .vexpand(true)
        .child(&clamp)
        .build()
}

fn restore_scroll(scroll: &gtk::ScrolledWindow, value: f64) {
    let adjustment = scroll.vadjustment();
    let weak_scroll = scroll.downgrade();
    gtk::glib::idle_add_local_once(move || {
        if weak_scroll.upgrade().is_some() {
            adjustment.set_value(value.min((adjustment.upper() - adjustment.page_size()).max(0.0)));
        }
    });
}

fn action_row(title: &str, subtitle: &str) -> adw::ActionRow {
    let row = adw::ActionRow::new();
    // Budget content is plain text, including ampersands in monthly template names.
    row.set_use_markup(false);
    row.set_title(title);
    row.set_subtitle(subtitle);
    row.set_title_lines(1);
    row.set_subtitle_lines(2);
    row
}

fn entry_row(title: &str, text: &str) -> adw::EntryRow {
    let row = adw::EntryRow::builder().title(title).build();
    row.set_text(text);
    row
}

fn date_entry(title: &str, text: &str) -> adw::EntryRow {
    let row = entry_row(title, text);
    let picker = gtk::MenuButton::builder()
        .icon_name("x-office-calendar-symbolic")
        .tooltip_text("Choose Date")
        .valign(Align::Center)
        .css_classes(["flat"])
        .build();
    let popover = gtk::Popover::new();
    let calendar = gtk::Calendar::new();
    if let Ok(date) = gtk::glib::DateTime::from_iso8601(&format!("{text}T12:00:00Z"), None) {
        calendar.select_day(&date);
    }
    popover.set_child(Some(&calendar));
    picker.set_popover(Some(&popover));
    row.add_suffix(&picker);
    let weak_row = row.downgrade();
    let weak_popover = popover.downgrade();
    let selected_handler = calendar.connect_day_selected(move |calendar| {
        if let Some(row) = weak_row.upgrade() {
            let date = calendar.date();
            row.set_text(&format!(
                "{:04}-{:02}-{:02}",
                date.year(),
                date.month(),
                date.day_of_month()
            ));
        }
        if let Some(popover) = weak_popover.upgrade() {
            popover.popdown();
        }
    });
    let weak_row = row.downgrade();
    popover.connect_show(move |_| {
        if let Some(row) = weak_row.upgrade()
            && let Some(date) = parse_date(&row.text())
            && let Ok(date) = gtk::glib::DateTime::from_iso8601(
                &format!("{}T12:00:00Z", date.format("%Y-%m-%d")),
                None,
            )
        {
            calendar.block_signal(&selected_handler);
            calendar.select_day(&date);
            calendar.unblock_signal(&selected_handler);
        }
    });
    row
}

fn combo_row(title: &str, labels: &[&str]) -> adw::ComboRow {
    let model = gtk::StringList::new(labels);
    let expression = gtk::PropertyExpression::new(
        gtk::StringObject::static_type(),
        gtk::Expression::NONE,
        "string",
    );
    adw::ComboRow::builder()
        .title(title)
        .model(&model)
        .expression(&expression)
        .build()
}

fn chart_icon() -> gtk::DrawingArea {
    let icon = gtk::DrawingArea::builder()
        .content_width(16)
        .content_height(16)
        .build();
    icon.set_can_target(false);
    icon.set_draw_func(|area, cr, width, height| {
        let color = area.color();
        cr.set_source_rgba(
            color.red() as f64,
            color.green() as f64,
            color.blue() as f64,
            color.alpha() as f64,
        );
        let unit = (width.min(height) as f64 / 16.0).max(1.0);
        cr.set_line_width(1.6 * unit);
        cr.set_line_cap(gtk::cairo::LineCap::Round);
        cr.move_to(3.0 * unit, 13.0 * unit);
        cr.line_to(13.0 * unit, 13.0 * unit);
        let _ = cr.stroke();
        for (x, top) in [(4.0, 8.0), (7.5, 5.5), (11.0, 3.0)] {
            cr.rectangle(x * unit, top * unit, 2.0 * unit, (13.0 - top) * unit);
            let _ = cr.fill();
        }
    });
    icon
}

fn require_title(title: &adw::EntryRow, save: &gtk::Button) {
    save.set_sensitive(!title.text().trim().is_empty());
    let weak_save = save.downgrade();
    title.connect_changed(move |entry| {
        if let Some(save) = weak_save.upgrade() {
            save.set_sensitive(!entry.text().trim().is_empty());
        }
    });
}

fn inline_error(label: &gtk::Label, message: &str) {
    label.set_label(message);
    label.set_visible(true);
}

fn amount_label(value: &str) -> gtk::Label {
    let label = gtk::Label::new(Some(value));
    label.set_xalign(1.0);
    label.set_valign(Align::Center);
    label
}

fn category_types() -> [BWCategoryType; 4] {
    [
        BWCategoryType::Income,
        BWCategoryType::Expenses,
        BWCategoryType::Savings,
        BWCategoryType::Debt,
    ]
}

fn type_index(kind: BWCategoryType) -> u32 {
    category_types()
        .iter()
        .position(|item| *item == kind)
        .unwrap_or(0) as u32
}

fn category_total(
    categories: &[BWCategory],
    amount: impl Fn(&BWCategory) -> BWMoneyAmount,
    currency: &str,
) -> String {
    bw_core::money::sum_money_amounts(categories.iter().map(amount).collect())
        .map(|total| money_text(total.value, currency))
        .unwrap_or_else(|_| "Too large".to_string())
}

fn money_input(value: i64) -> String {
    bw_core::money::format_money_input(BWMoneyAmount { value }).unwrap_or_default()
}

fn transaction_date(transaction: &BWTransaction) -> String {
    format!(
        "{:04}-{:02}-{:02}",
        transaction.date.year, transaction.date.month, transaction.date.day
    )
}

fn sort_index(sort: TransactionSort) -> u32 {
    match sort {
        TransactionSort::Newest => 0,
        TransactionSort::Oldest => 1,
        TransactionSort::AmountHigh => 2,
        TransactionSort::AmountLow => 3,
        TransactionSort::Title => 4,
        TransactionSort::Category => 5,
        TransactionSort::Description => 6,
    }
}

fn sort_from_index(index: u32) -> TransactionSort {
    match index {
        1 => TransactionSort::Oldest,
        2 => TransactionSort::AmountHigh,
        3 => TransactionSort::AmountLow,
        4 => TransactionSort::Title,
        5 => TransactionSort::Category,
        6 => TransactionSort::Description,
        _ => TransactionSort::Newest,
    }
}

fn sort_transactions(items: &mut [TransactionItem], sort: TransactionSort) {
    items.sort_by(|left, right| {
        let a = &left.transaction;
        let b = &right.transaction;
        let date_a = (a.date.year, a.date.month, a.date.day);
        let date_b = (b.date.year, b.date.month, b.date.day);
        let order = match sort {
            TransactionSort::Newest => date_b.cmp(&date_a),
            TransactionSort::Oldest => date_a.cmp(&date_b),
            TransactionSort::AmountHigh => b.amount.value.cmp(&a.amount.value),
            TransactionSort::AmountLow => a.amount.value.cmp(&b.amount.value),
            TransactionSort::Title => a.title.to_lowercase().cmp(&b.title.to_lowercase()),
            TransactionSort::Category => left
                .category_title
                .to_lowercase()
                .cmp(&right.category_title.to_lowercase()),
            TransactionSort::Description => a
                .description
                .to_lowercase()
                .cmp(&b.description.to_lowercase()),
        };
        order.then_with(|| a.id.cmp(&b.id))
    });
}

fn delete_alert(heading: &str, body: &str, action: &str) -> adw::AlertDialog {
    let dialog = adw::AlertDialog::new(Some(heading), Some(body));
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("delete", action);
    dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
    dialog.set_default_response(Some("cancel"));
    dialog.set_close_response("cancel");
    dialog
}

fn file_dialog_cancelled(error: &gtk::glib::Error) -> bool {
    error.matches(gtk::DialogError::Dismissed) || error.matches(gtk::DialogError::Cancelled)
}

fn budget_file_dialog(title: &str) -> gtk::FileDialog {
    let filter = budget_file_filter();
    let filters = gtk::gio::ListStore::new::<gtk::FileFilter>();
    filters.append(&filter);
    gtk::FileDialog::builder()
        .title(title)
        .modal(true)
        .filters(&filters)
        .default_filter(&filter)
        .build()
}

fn budget_file_filter() -> gtk::FileFilter {
    let filter = gtk::FileFilter::new();
    filter.set_name(Some("Budget files"));
    filter.add_pattern("*.budget");
    filter
}

fn budget_file_name(title: &str) -> String {
    let safe = title
        .chars()
        .map(|character| {
            if character.is_control() || matches!(character, '/' | '\\') {
                '_'
            } else {
                character
            }
        })
        .collect::<String>();
    if safe.ends_with(".budget") {
        safe
    } else {
        format!("{safe}.budget")
    }
}

fn clear_box(container: &gtk::Box) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }
}

#[cfg(test)]
mod transaction_logic_tests {
    use super::*;

    fn item(
        id: u128,
        title: &str,
        category: &str,
        date: (i32, i32, i32),
        amount: i64,
    ) -> TransactionItem {
        TransactionItem {
            category_title: category.to_string(),
            category_type: BWCategoryType::Expenses,
            transaction: BWTransaction {
                id: Uuid::from_u128(id),
                title: title.to_string(),
                description: "Weekly groceries".to_string(),
                date: BWDate {
                    year: date.0,
                    month: date.1,
                    day: date.2,
                },
                amount: BWMoneyAmount { value: amount },
            },
        }
    }

    #[test]
    fn search_matches_transaction_category_date_and_amount() {
        let row = item(1, "Market", "Groceries", (2025, 4, 8), 4_250);
        let mut filters = TransactionFilters::new(("2025-01-01".into(), "2025-12-31".into()));
        for term in [
            "market",
            "GROCERIES",
            "expense",
            "weekly",
            "2025-04-08",
            "42.50",
        ] {
            filters.search = term.to_string();
            assert!(filters.matches(&row, "USD"), "search should match {term}");
        }
        filters.search = "transport".to_string();
        assert!(!filters.matches(&row, "USD"));
    }

    #[test]
    fn date_and_amount_filters_include_boundaries_and_reject_invalid_bounds() {
        let row = item(1, "Market", "Groceries", (2025, 4, 8), 4_250);
        let mut filters = TransactionFilters::new(("2025-04-08".into(), "2025-04-08".into()));
        filters.date_enabled = true;
        filters.minimum = "42.50".to_string();
        filters.maximum = "42.50".to_string();
        assert!(filters.matches(&row, "USD"));

        filters.maximum = "42.49".to_string();
        assert!(!filters.matches(&row, "USD"));
        filters.maximum.clear();
        filters.start = "2025-04-09".to_string();
        assert!(!filters.matches(&row, "USD"));
        filters.start = "not a date".to_string();
        assert!(!filters.matches(&row, "USD"));
        filters.date_enabled = false;
        filters.minimum = "-1".to_string();
        assert!(!filters.matches(&row, "USD"));
    }

    #[test]
    fn transaction_sort_modes_are_ordered_and_ties_have_stable_ids() {
        let rows = vec![
            item(3, "Beta", "Food", (2025, 4, 7), 4_250),
            item(1, "Alpha", "Transport", (2025, 4, 8), 4_250),
            item(2, "Alpha", "Food", (2025, 4, 8), 7_000),
        ];
        let ids_for = |sort| {
            let mut rows = rows.clone();
            sort_transactions(&mut rows, sort);
            rows.into_iter()
                .map(|row| row.transaction.id)
                .collect::<Vec<_>>()
        };
        assert_eq!(
            ids_for(TransactionSort::Newest),
            vec![Uuid::from_u128(1), Uuid::from_u128(2), Uuid::from_u128(3)]
        );
        assert_eq!(
            ids_for(TransactionSort::Oldest),
            vec![Uuid::from_u128(3), Uuid::from_u128(1), Uuid::from_u128(2)]
        );
        assert_eq!(
            ids_for(TransactionSort::AmountHigh),
            vec![Uuid::from_u128(2), Uuid::from_u128(1), Uuid::from_u128(3)]
        );
        assert_eq!(
            ids_for(TransactionSort::Title),
            vec![Uuid::from_u128(1), Uuid::from_u128(2), Uuid::from_u128(3)]
        );
        assert_eq!(
            ids_for(TransactionSort::Category),
            vec![Uuid::from_u128(2), Uuid::from_u128(3), Uuid::from_u128(1)]
        );
    }
}
