use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use budget_warden_linux::store::AppState;
use budget_warden_linux::ui::AppUi;

fn main() -> gtk::glib::ExitCode {
    let bytes = gtk::glib::Bytes::from_static(include_bytes!(concat!(
        env!("OUT_DIR"),
        "/budget-warden.gresource"
    )));
    let resources =
        gtk::gio::Resource::from_data(&bytes).expect("Valid embedded application resources");
    gtk::gio::resources_register(&resources);
    let application = adw::Application::builder()
        .application_id("com.lazarovco.BudgetWarden")
        .flags(gtk::gio::ApplicationFlags::HANDLES_OPEN)
        .build();
    application.connect_startup(|_| {
        if let Some(display) = gtk::gdk::Display::default() {
            gtk::IconTheme::for_display(&display)
                .add_resource_path("/com/lazarovco/BudgetWarden/icons");
        }
    });
    let active_ui: Rc<RefCell<Option<Rc<AppUi>>>> = Rc::new(RefCell::new(None));
    let active_ui_on_activate = active_ui.clone();

    application.connect_activate(move |application| {
        if let Some(ui) = active_ui_on_activate.borrow().as_ref() {
            ui.present();
            return;
        }
        let state = match AppState::new() {
            Ok(state) => state,
            Err(error) => {
                eprintln!("Could not initialize Budget Warden: {error}");
                application.quit();
                return;
            }
        };
        let ui = AppUi::new(application, state);
        *active_ui_on_activate.borrow_mut() = Some(ui.clone());
        ui.present();
    });

    let active_ui_on_open = active_ui.clone();
    application.connect_open(move |application, files, _| {
        if active_ui_on_open.borrow().is_none() {
            application.activate();
        }
        if let Some(ui) = active_ui_on_open.borrow().as_ref() {
            if let Some(file) = files.first().and_then(|file| file.path()) {
                ui.open_external_budget(file);
            } else {
                ui.present();
            }
        }
    });

    application.run()
}
