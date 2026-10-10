//! Reporting presentation and native Cairo charts shared by the reporting page.

use std::cell::RefCell;
use std::f64::consts::{FRAC_PI_2, TAU};
use std::rc::Rc;

use adw::prelude::*;
use bw_core::models::BWCategoryType;
use bw_core::reporting::{
    BWReportingAmountMode, BWReportingComparisonRow, BWReportingComponent, BWReportingSummary,
};
use gtk::cairo;
use gtk::{Align, Orientation};

use crate::store::{ReportMode, money_text, supported_currencies};

// Use the same paired palette as Windows. Segment identities survive theme changes.
const PALETTE: [(u32, u32); 6] = [
    (0x2563eb, 0x60a5fa),
    (0xf97316, 0xfb7185),
    (0x06b6d4, 0x22d3ee),
    (0xeab308, 0xfbbf24),
    (0xa855f7, 0xc084fc),
    (0x84cc16, 0xa3e635),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Tone {
    Normal,
    Positive,
    Negative,
}

struct Metric {
    title: &'static str,
    amount: i64,
    tone: Tone,
}

#[derive(Clone, Debug)]
struct Segment {
    title: String,
    amount: i64,
    color: usize,
    row: Option<BWReportingComparisonRow>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ChartKind {
    Comparison,
    Donut,
}

#[derive(Clone)]
struct Chart {
    title: String,
    empty_title: String,
    kind: ChartKind,
    segments: Vec<Segment>,
    totals: Vec<(&'static str, i64)>,
}

struct Presentation {
    metrics: Vec<Metric>,
    charts: Vec<Chart>,
}

impl Presentation {
    fn new(summary: &BWReportingSummary, mode: ReportMode) -> Self {
        let totals = &summary.totals;
        let amount_mode = match mode {
            ReportMode::Planned => BWReportingAmountMode::Planned,
            ReportMode::Actual => BWReportingAmountMode::Actual,
        };
        let mode_title = if mode == ReportMode::Planned {
            "Planned"
        } else {
            "Actual"
        };
        let metrics = vec![
            Metric {
                title: "Income",
                amount: totals.income.value,
                tone: Tone::Normal,
            },
            Metric {
                title: "Planned Spending",
                amount: totals.planned_spending.value,
                tone: if totals.planned_spending.value > totals.income.value {
                    Tone::Negative
                } else {
                    Tone::Normal
                },
            },
            Metric {
                title: "Actual Spending",
                amount: totals.actual_spending.value,
                tone: if totals.actual_spending.value > totals.planned_spending.value {
                    Tone::Negative
                } else {
                    Tone::Positive
                },
            },
            Metric {
                title: "Savings",
                amount: totals.planned_savings.value,
                tone: Tone::Normal,
            },
            Metric {
                title: "Left to Budget",
                amount: totals.left_to_budget,
                tone: if totals.left_to_budget < 0 {
                    Tone::Negative
                } else {
                    Tone::Normal
                },
            },
        ];
        let mut charts = vec![
            Chart {
                title: "Income vs Allocation".to_string(),
                empty_title: "No allocation amounts yet".to_string(),
                kind: ChartKind::Comparison,
                segments: summary
                    .comparison_segments
                    .iter()
                    .filter(|segment| segment.amount.value > 0)
                    .map(|segment| Segment {
                        title: component_title(segment.component).to_string(),
                        amount: segment.amount.value,
                        color: component_color(segment.component),
                        row: Some(segment.row),
                    })
                    .collect(),
                totals: vec![
                    ("Income", totals.income.value),
                    ("Planned", totals.planned_allocation.value),
                    ("Actual", totals.actual_allocation.value),
                ],
            },
            Chart {
                title: format!("{mode_title} Allocation Breakdown"),
                empty_title: format!("No {} allocation amounts yet", mode_title.to_lowercase()),
                kind: ChartKind::Donut,
                segments: summary
                    .allocation_segments
                    .iter()
                    .filter(|segment| {
                        segment.amount_mode == amount_mode && segment.amount.value > 0
                    })
                    .map(|segment| Segment {
                        title: segment.category_type.title().to_string(),
                        amount: segment.amount.value,
                        color: type_color(segment.category_type),
                        row: None,
                    })
                    .collect(),
                totals: Vec::new(),
            },
        ];
        for kind in [
            BWCategoryType::Income,
            BWCategoryType::Expenses,
            BWCategoryType::Savings,
            BWCategoryType::Debt,
        ] {
            // Enumerate the union of both modes so zero amounts do not shift category colors.
            let mut category_order = Vec::new();
            for segment in summary
                .category_segments
                .iter()
                .filter(|segment| segment.category_type == kind)
            {
                if !category_order.contains(&segment.category_id) {
                    category_order.push(segment.category_id);
                }
            }
            charts.push(Chart {
                title: format!("{} Breakdown", kind.title()),
                empty_title: format!(
                    "No {} {} amounts yet",
                    mode_title.to_lowercase(),
                    kind.title().to_lowercase()
                ),
                kind: ChartKind::Donut,
                segments: summary
                    .category_segments
                    .iter()
                    .filter(|segment| {
                        segment.category_type == kind
                            && segment.amount_mode == amount_mode
                            && segment.amount.value > 0
                    })
                    .map(|segment| Segment {
                        title: segment.title.clone(),
                        amount: segment.amount.value,
                        color: category_order
                            .iter()
                            .position(|id| *id == segment.category_id)
                            .unwrap_or(0)
                            % PALETTE.len(),
                        row: None,
                    })
                    .collect(),
                totals: Vec::new(),
            });
        }
        Self { metrics, charts }
    }
}

pub fn content(summary: &BWReportingSummary, mode: ReportMode, currency: &str) -> gtk::Widget {
    let presentation = Presentation::new(summary, mode);
    let body = gtk::Box::new(Orientation::Vertical, 24);
    let metrics = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(5)
        .column_spacing(12)
        .row_spacing(12)
        .homogeneous(true)
        .activate_on_single_click(false)
        .build();
    metrics.set_widget_name("reporting-metrics");
    for (index, metric) in presentation.metrics.iter().enumerate() {
        metrics.insert(&metric_card(metric, currency), -1);
        if let Some(child) = metrics.child_at_index(index as i32) {
            child.set_can_target(false);
            child.set_focusable(false);
        }
    }
    body.append(&metrics);
    let charts = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(3)
        .column_spacing(18)
        .row_spacing(18)
        .homogeneous(false)
        .valign(Align::Start)
        .activate_on_single_click(false)
        .build();
    charts.set_widget_name("reporting-charts");
    for (index, chart) in presentation.charts.into_iter().enumerate() {
        charts.insert(&chart_card(chart, currency, false), -1);
        if let Some(child) = charts.child_at_index(index as i32) {
            child.set_can_target(false);
            child.set_focusable(false);
        }
    }
    body.append(&charts);
    body.upcast()
}

pub fn at_a_glance(
    summary: &BWReportingSummary,
    mode: ReportMode,
    currency: &str,
    on_mode_changed: impl Fn(ReportMode) + 'static,
) -> gtk::Widget {
    let presentation = Presentation::new(summary, mode);
    let panel = adw::ToolbarView::new();
    let header = adw::HeaderBar::new();
    header.set_title_widget(Some(&gtk::Label::new(Some("At a Glance"))));
    panel.add_top_bar(&header);

    let body = gtk::Box::new(Orientation::Vertical, 14);
    set_margins(&body, 12);
    let metrics = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .min_children_per_line(1)
        .max_children_per_line(2)
        .column_spacing(8)
        .row_spacing(8)
        .homogeneous(true)
        .activate_on_single_click(false)
        .build();
    for (index, metric) in presentation.metrics.iter().enumerate() {
        metrics.insert(&metric_card(metric, currency), -1);
        if let Some(child) = metrics.child_at_index(index as i32) {
            child.set_can_target(false);
            child.set_focusable(false);
        }
    }
    body.append(&metrics);
    body.append(&gtk::Separator::new(Orientation::Horizontal));

    let amount_mode = gtk::Box::new(Orientation::Horizontal, 0);
    amount_mode.add_css_class("linked");
    let planned = gtk::ToggleButton::with_label("Planned");
    let actual = gtk::ToggleButton::with_label("Actual");
    actual.set_group(Some(&planned));
    planned.set_active(mode == ReportMode::Planned);
    actual.set_active(mode == ReportMode::Actual);
    let on_mode_changed = Rc::new(on_mode_changed);
    for (button, next_mode) in [
        (&planned, ReportMode::Planned),
        (&actual, ReportMode::Actual),
    ] {
        let on_mode_changed = on_mode_changed.clone();
        button.connect_toggled(move |button| {
            if button.is_active() {
                on_mode_changed(next_mode);
            }
        });
    }
    amount_mode.append(&planned);
    amount_mode.append(&actual);
    amount_mode.set_halign(Align::Center);
    body.append(&amount_mode);

    for chart in presentation.charts.into_iter().take(2) {
        body.append(&chart_card(chart, currency, true));
    }

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(&body)
        .build();
    panel.set_content(Some(&scroll));
    panel.upcast()
}

fn metric_card(metric: &Metric, currency: &str) -> gtk::Widget {
    let card = gtk::Box::new(Orientation::Vertical, 6);
    card.add_css_class("card");
    card.set_size_request(140, 82);
    card.set_hexpand(true);
    let body = gtk::Box::new(Orientation::Vertical, 6);
    set_margins(&body, 16);
    let title = gtk::Label::new(Some(metric.title));
    title.set_xalign(0.0);
    title.add_css_class("caption");
    title.add_css_class("dim-label");
    let formatted = money_text(metric.amount, currency);
    let value = gtk::Label::new(Some(&formatted));
    value.set_xalign(0.0);
    value.add_css_class("title-2");
    value.set_ellipsize(gtk::pango::EllipsizeMode::End);
    value.set_max_width_chars(16);
    match metric.tone {
        Tone::Negative => value.add_css_class("error"),
        Tone::Positive => value.add_css_class("success"),
        Tone::Normal => (),
    }
    body.append(&title);
    body.append(&value);
    card.append(&body);
    card.upcast()
}

fn chart_card(chart: Chart, currency: &str, compact: bool) -> gtk::Widget {
    let card = gtk::Box::new(Orientation::Vertical, 0);
    card.add_css_class("card");
    card.set_width_request(280);
    card.set_hexpand(true);
    let body = gtk::Box::new(Orientation::Vertical, 14);
    set_margins(&body, 18);
    let heading = gtk::Label::new(Some(&chart.title));
    heading.add_css_class("heading");
    heading.set_xalign(0.0);
    heading.set_wrap(true);
    body.append(&heading);
    if chart.segments.is_empty() {
        let empty = gtk::Label::new(Some(&chart.empty_title));
        empty.set_wrap(true);
        empty.set_justify(gtk::Justification::Center);
        empty.add_css_class("dim-label");
        empty.set_height_request(190);
        body.append(&empty);
    } else {
        let chart = Rc::new(chart);
        let draw_chart = chart.clone();
        let draw_currency = currency.to_string();
        let area = themed_canvas(
            if compact {
                if chart.kind == ChartKind::Comparison {
                    130
                } else {
                    170
                }
            } else if chart.kind == ChartKind::Comparison {
                190
            } else {
                180
            },
            move |area, cr, width, height| {
                let foreground = area.color();
                let foreground = (
                    foreground.red() as f64,
                    foreground.green() as f64,
                    foreground.blue() as f64,
                );
                let dark = adw::StyleManager::default().is_dark();
                match draw_chart.kind {
                    ChartKind::Comparison => draw_comparison(
                        cr,
                        &draw_chart.segments,
                        width,
                        height,
                        foreground,
                        dark,
                        &draw_currency,
                    ),
                    ChartKind::Donut => draw_donut(cr, &draw_chart.segments, width, height, dark),
                }
            },
        );
        let description = chart
            .segments
            .iter()
            .map(|segment| {
                format!(
                    "{}{}: {}",
                    segment
                        .row
                        .map(|row| format!("{} — ", row_title(row)))
                        .unwrap_or_default(),
                    segment.title,
                    money_text(segment.amount, currency)
                )
            })
            .collect::<Vec<_>>()
            .join(". ");
        area.update_property(&[
            gtk::accessible::Property::Label(&chart.title),
            gtk::accessible::Property::Description(&description),
        ]);
        body.append(&area);
        if chart.kind == ChartKind::Donut {
            let total = total(&chart.segments);
            for segment in &chart.segments {
                body.append(&legend_row(segment, Some(total), currency, false));
            }
        }
        // Legends and totals are native text widgets, so chart data remains accessible.
        // The legend is populated below using the same palette as the drawing.
        if chart.kind == ChartKind::Comparison {
            let legend = gtk::FlowBox::builder()
                .selection_mode(gtk::SelectionMode::None)
                .min_children_per_line(1)
                .max_children_per_line(2)
                .column_spacing(10)
                .row_spacing(6)
                .activate_on_single_click(false)
                .build();
            for (index, component) in [
                BWReportingComponent::Income,
                BWReportingComponent::Expenses,
                BWReportingComponent::Savings,
                BWReportingComponent::Debt,
            ]
            .into_iter()
            .enumerate()
            {
                let segment = Segment {
                    title: component_title(component).to_string(),
                    amount: 0,
                    color: component_color(component),
                    row: None,
                };
                legend.insert(&legend_row(&segment, None, "", true), -1);
                if let Some(child) = legend.child_at_index(index as i32) {
                    child.set_can_target(false);
                    child.set_focusable(false);
                }
            }
            body.append(&legend);
            for (title, amount) in &chart.totals {
                let label =
                    gtk::Label::new(Some(&format!("{title}: {}", money_text(*amount, currency))));
                label.add_css_class("caption");
                label.add_css_class("dim-label");
                label.set_xalign(0.0);
                label.set_wrap(true);
                body.append(&label);
            }
        }
    }
    card.append(&body);
    card.upcast()
}

fn legend_row(
    segment: &Segment,
    total: Option<u128>,
    currency: &str,
    compact: bool,
) -> gtk::Widget {
    let row = gtk::Box::new(Orientation::Horizontal, 8);
    let color = segment.color;
    let swatch = themed_canvas(9, move |_, cr, width, height| {
        source_color(cr, color, adw::StyleManager::default().is_dark());
        cr.rectangle(0.0, 0.0, width, height);
        let _ = cr.fill();
    });
    swatch.set_size_request(9, 9);
    swatch.set_valign(Align::Center);
    swatch.set_hexpand(false);
    row.append(&swatch);
    let title = gtk::Label::new(Some(&segment.title));
    title.add_css_class("caption");
    title.set_xalign(0.0);
    title.set_hexpand(true);
    title.set_ellipsize(gtk::pango::EllipsizeMode::End);
    title.set_max_width_chars(20);
    row.append(&title);
    if !compact {
        let amount = gtk::Label::new(Some(&money_text(segment.amount, currency)));
        amount.add_css_class("caption");
        amount.add_css_class("dim-label");
        amount.set_xalign(1.0);
        row.append(&amount);
        if let Some(total) = total {
            let fraction = gtk::Label::new(Some(&percent(segment.amount, total)));
            fraction.add_css_class("caption");
            fraction.add_css_class("dim-label");
            fraction.set_width_chars(6);
            fraction.set_xalign(1.0);
            row.append(&fraction);
        }
    }
    row.upcast()
}

fn themed_canvas(
    height: i32,
    draw: impl Fn(&gtk::DrawingArea, &cairo::Context, f64, f64) + 'static,
) -> gtk::DrawingArea {
    let area = gtk::DrawingArea::builder()
        .content_height(height)
        .hexpand(true)
        .build();
    area.set_draw_func(move |area, cr, width, height| draw(area, cr, width as f64, height as f64));
    let handler = Rc::new(RefCell::new(None));
    let handler_clone = handler.clone();
    area.connect_realize(move |area| {
        let weak = area.downgrade();
        let id = adw::StyleManager::default().connect_dark_notify(move |_| {
            if let Some(area) = weak.upgrade() {
                area.queue_draw();
            }
        });
        *handler_clone.borrow_mut() = Some(id);
    });
    area.connect_unrealize(move |_| {
        if let Some(id) = handler.borrow_mut().take() {
            adw::StyleManager::default().disconnect(id);
        }
    });
    area
}

fn draw_donut(cr: &cairo::Context, segments: &[Segment], width: f64, height: f64, dark: bool) {
    let total = total(segments);
    if total == 0 || width <= 0.0 || height <= 0.0 {
        return;
    }
    let (cx, cy, radius) = (width / 2.0, height / 2.0, width.min(height) * 0.46);
    let mut angle = -FRAC_PI_2;
    for segment in segments.iter().filter(|segment| segment.amount > 0) {
        let sweep = TAU * segment.amount as f64 / total as f64;
        let gap = if segments.len() > 1 {
            (1.5 / radius).min(sweep * 0.2)
        } else {
            0.0
        };
        cr.new_path();
        cr.arc(cx, cy, radius, angle + gap / 2.0, angle + sweep - gap / 2.0);
        cr.arc_negative(
            cx,
            cy,
            radius * 0.58,
            angle + sweep - gap / 2.0,
            angle + gap / 2.0,
        );
        cr.close_path();
        source_color(cr, segment.color, dark);
        let _ = cr.fill();
        angle += sweep;
    }
}

const ROWS: [BWReportingComparisonRow; 3] = [
    BWReportingComparisonRow::Income,
    BWReportingComparisonRow::Planned,
    BWReportingComparisonRow::Actual,
];

fn comparison_geometry(width: f64, height: f64) -> (f64, f64, f64) {
    // Short row labels leave a useful plot area even on a phone-sized window.
    let left = 61.0;
    (
        left,
        (width - left - 12.0).max(1.0),
        ((height - 35.0) / 3.0).max(1.0),
    )
}

fn draw_comparison(
    cr: &cairo::Context,
    segments: &[Segment],
    width: f64,
    height: f64,
    fg: (f64, f64, f64),
    dark: bool,
    currency: &str,
) {
    if width <= 0.0 || height <= 0.0 {
        return;
    }
    let maximum = comparison_maximum(segments);
    if maximum <= 0.0 {
        return;
    }
    let (left, plot_width, row_height) = comparison_geometry(width, height);
    let axis_maximum = nice_maximum(maximum);
    let axis_y = row_height * 3.0 + 2.0;
    cr.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Normal);
    cr.set_font_size(11.0);
    let ticks = if plot_width < 230.0 { 2 } else { 4 };
    for index in 0..=ticks {
        let x = left + plot_width * index as f64 / ticks as f64;
        cr.set_source_rgba(fg.0, fg.1, fg.2, 0.12);
        cr.set_line_width(1.0);
        cr.move_to(x.floor() + 0.5, 4.0);
        cr.line_to(x.floor() + 0.5, axis_y);
        let _ = cr.stroke();
        let text = compact_money(axis_maximum * index as f64 / ticks as f64, currency);
        let text_width = cr
            .text_extents(&text)
            .map(|extents| extents.width())
            .unwrap_or(0.0);
        let origin = (x - text_width / 2.0).clamp(0.0, (width - text_width).max(0.0));
        cr.set_source_rgba(fg.0, fg.1, fg.2, 0.65);
        cr.move_to(origin, axis_y + 19.0);
        let _ = cr.show_text(&text);
    }
    for (index, row) in ROWS.iter().enumerate() {
        let y = index as f64 * row_height + 13.0;
        cr.set_source_rgba(fg.0, fg.1, fg.2, 0.8);
        cr.move_to(0.0, y + 15.0);
        let _ = cr.show_text(row_title(*row));
        let mut cumulative = 0_u128;
        for segment in segments
            .iter()
            .filter(|segment| segment.row == Some(*row) && segment.amount > 0)
        {
            let x = left + plot_width * cumulative as f64 / axis_maximum;
            cumulative += segment.amount as u128;
            let end = left + plot_width * cumulative as f64 / axis_maximum;
            source_color(cr, segment.color, dark);
            cr.rectangle(x, y, (end - x).max(0.0), 24.0);
            let _ = cr.fill();
        }
    }
}

fn comparison_maximum(segments: &[Segment]) -> f64 {
    ROWS.iter()
        .map(|row| {
            segments
                .iter()
                .filter(|segment| segment.row == Some(*row) && segment.amount > 0)
                .map(|segment| segment.amount as u128)
                .sum::<u128>()
        })
        .max()
        .unwrap_or(0) as f64
}

fn nice_maximum(maximum: f64) -> f64 {
    if maximum <= 0.0 {
        return 0.0;
    }
    let raw_step = maximum / 4.0;
    let magnitude = 10_f64.powf(raw_step.log10().floor());
    let normalized = raw_step / magnitude;
    let step = if normalized <= 1.0 {
        1.0
    } else if normalized <= 2.0 {
        2.0
    } else if normalized <= 5.0 {
        5.0
    } else {
        10.0
    } * magnitude;
    (maximum / step).ceil() * step
}

fn compact_money(cents: f64, currency: &str) -> String {
    let symbol = supported_currencies()
        .iter()
        .find(|item| item.code == currency)
        .map(|item| item.symbol.as_str())
        .unwrap_or(currency);
    let amount = cents / 100.0;
    let (number, suffix) = if amount >= 1_000_000_000.0 {
        (amount / 1_000_000_000.0, "B")
    } else if amount >= 1_000_000.0 {
        (amount / 1_000_000.0, "M")
    } else if amount >= 1_000.0 {
        (amount / 1_000.0, "k")
    } else {
        (amount, "")
    };
    let number = if number == 0.0 || number >= 100.0 {
        format!("{number:.0}")
    } else {
        let value = format!("{number:.1}");
        value
            .trim_end_matches('0')
            .trim_end_matches('.')
            .to_string()
    };
    format!("{symbol}{number}{suffix}")
}

fn total(segments: &[Segment]) -> u128 {
    segments
        .iter()
        .filter(|segment| segment.amount > 0)
        .map(|segment| segment.amount as u128)
        .sum()
}

fn percent(amount: i64, total: u128) -> String {
    if total == 0 {
        return "0%".to_string();
    }
    let value = format!("{:.1}", amount.max(0) as f64 / total as f64 * 100.0);
    format!("{}%", value.trim_end_matches('0').trim_end_matches('.'))
}

fn source_color(cr: &cairo::Context, color: usize, dark: bool) {
    let pair = PALETTE[color % PALETTE.len()];
    let hex = if dark { pair.1 } else { pair.0 };
    cr.set_source_rgb(
        ((hex >> 16) & 0xff) as f64 / 255.0,
        ((hex >> 8) & 0xff) as f64 / 255.0,
        (hex & 0xff) as f64 / 255.0,
    );
}

fn type_color(kind: BWCategoryType) -> usize {
    match kind {
        BWCategoryType::Income => 0,
        BWCategoryType::Expenses => 1,
        BWCategoryType::Savings => 2,
        BWCategoryType::Debt => 3,
    }
}

fn component_color(component: BWReportingComponent) -> usize {
    match component {
        BWReportingComponent::Income => 0,
        BWReportingComponent::Expenses => 1,
        BWReportingComponent::Savings => 2,
        BWReportingComponent::Debt => 3,
    }
}

fn component_title(component: BWReportingComponent) -> &'static str {
    match component {
        BWReportingComponent::Income => "Income",
        BWReportingComponent::Expenses => "Expenses",
        BWReportingComponent::Savings => "Savings",
        BWReportingComponent::Debt => "Debt",
    }
}

fn row_title(row: BWReportingComparisonRow) -> &'static str {
    match row {
        BWReportingComparisonRow::Income => "Income",
        BWReportingComparisonRow::Planned => "Planned",
        BWReportingComparisonRow::Actual => "Actual",
    }
}

fn set_margins(widget: &impl IsA<gtk::Widget>, margin: i32) {
    widget.set_margin_top(margin);
    widget.set_margin_bottom(margin);
    widget.set_margin_start(margin);
    widget.set_margin_end(margin);
}

#[cfg(test)]
mod presentation_tests {
    use super::*;
    use bw_core::models::BWMoneyAmount;
    use bw_core::reporting::{
        BWReportingAllocationSegment, BWReportingCategorySegment, BWReportingComparisonSegment,
        BWReportingTotals,
    };
    use uuid::Uuid;

    fn summary() -> BWReportingSummary {
        let first = Uuid::from_u128(1);
        let second = Uuid::from_u128(2);
        BWReportingSummary {
            totals: BWReportingTotals {
                income: BWMoneyAmount { value: 500_000 },
                planned_spending: BWMoneyAmount { value: 200_000 },
                actual_spending: BWMoneyAmount { value: 240_000 },
                planned_savings: BWMoneyAmount { value: 100_000 },
                planned_allocation: BWMoneyAmount { value: 300_000 },
                actual_allocation: BWMoneyAmount { value: 240_000 },
                left_to_budget: 200_000,
            },
            allocation_segments: vec![
                BWReportingAllocationSegment {
                    amount_mode: BWReportingAmountMode::Planned,
                    category_type: BWCategoryType::Expenses,
                    amount: BWMoneyAmount { value: 200_000 },
                },
                BWReportingAllocationSegment {
                    amount_mode: BWReportingAmountMode::Actual,
                    category_type: BWCategoryType::Expenses,
                    amount: BWMoneyAmount { value: 240_000 },
                },
            ],
            category_segments: vec![
                BWReportingCategorySegment {
                    amount_mode: BWReportingAmountMode::Planned,
                    category_id: first,
                    category_type: BWCategoryType::Expenses,
                    title: "First".into(),
                    amount: BWMoneyAmount { value: 100_000 },
                },
                BWReportingCategorySegment {
                    amount_mode: BWReportingAmountMode::Actual,
                    category_id: first,
                    category_type: BWCategoryType::Expenses,
                    title: "First".into(),
                    amount: BWMoneyAmount { value: 0 },
                },
                BWReportingCategorySegment {
                    amount_mode: BWReportingAmountMode::Planned,
                    category_id: second,
                    category_type: BWCategoryType::Expenses,
                    title: "Second".into(),
                    amount: BWMoneyAmount { value: 100_000 },
                },
                BWReportingCategorySegment {
                    amount_mode: BWReportingAmountMode::Actual,
                    category_id: second,
                    category_type: BWCategoryType::Expenses,
                    title: "Second".into(),
                    amount: BWMoneyAmount { value: 240_000 },
                },
            ],
            comparison_segments: vec![BWReportingComparisonSegment {
                row: BWReportingComparisonRow::Income,
                component: BWReportingComponent::Income,
                amount: BWMoneyAmount { value: 500_000 },
            }],
        }
    }

    #[test]
    fn presentation_uses_requested_amount_mode_and_preserves_category_colors() {
        let summary = summary();
        let planned = Presentation::new(&summary, ReportMode::Planned);
        let actual = Presentation::new(&summary, ReportMode::Actual);
        let planned_expenses = &planned.charts[3].segments;
        let actual_expenses = &actual.charts[3].segments;

        assert_eq!(
            planned_expenses
                .iter()
                .map(|item| item.amount)
                .collect::<Vec<_>>(),
            vec![100_000, 100_000]
        );
        assert_eq!(
            actual_expenses
                .iter()
                .map(|item| item.amount)
                .collect::<Vec<_>>(),
            vec![240_000]
        );
        assert_eq!(planned_expenses[1].color, actual_expenses[0].color);
        assert_eq!(planned.charts[1].title, "Planned Allocation Breakdown");
        assert_eq!(actual.charts[1].title, "Actual Allocation Breakdown");
        assert_eq!(actual.metrics[2].tone, Tone::Negative);
        assert_eq!(actual.metrics[4].amount, 200_000);
    }

    #[test]
    fn chart_scaling_and_labels_handle_zero_small_and_large_values() {
        assert_eq!(nice_maximum(0.0), 0.0);
        assert_eq!(nice_maximum(100.0), 100.0);
        assert!(nice_maximum(101.0) >= 101.0);
        assert_eq!(percent(1, 3), "33.3%");
        assert_eq!(percent(3, 3), "100%");
        assert_eq!(percent(0, 0), "0%");
        assert_eq!(compact_money(123_450.0, "USD"), "$1.2k");
    }
}
