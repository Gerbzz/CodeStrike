use codestrike::{BuildReport, CargoAction, Diagnostic, Document, SearchHit, SearchQuery, run_cargo_with_control, search_workspace};
use eframe::egui::{self, Align, Color32};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

const BG: Color32 = Color32::from_rgb(18, 23, 30);
const PANEL: Color32 = Color32::from_rgb(27, 35, 45);
const EDITOR: Color32 = Color32::from_rgb(22, 29, 37);
const TEXT: Color32 = Color32::from_rgb(226, 234, 237);
const MUTED: Color32 = Color32::from_rgb(153, 171, 182);
const ACCENT: Color32 = Color32::from_rgb(125, 196, 239);

struct CodeApp {
    workspace: Option<PathBuf>,
    files: Vec<PathBuf>,
    active: Option<PathBuf>,
    document: Option<Document>,
    buffer: String,
    dirty: bool,
    query: String,
    regex: bool,
    hits: Vec<SearchHit>,
    problems: Vec<Diagnostic>,
    output: String,
    running: Option<Receiver<Result<BuildReport, String>>>,
    cancel: Option<Arc<AtomicBool>>,
    status: String,
    capture: Option<PathBuf>,
    capture_requested: bool,
    frames: usize,
}
impl CodeApp {
    fn new(workspace: Option<PathBuf>, file: Option<PathBuf>, capture: Option<PathBuf>) -> Self {
        let mut app = Self {
            workspace,
            files: Vec::new(),
            active: None,
            document: None,
            buffer: String::new(),
            dirty: false,
            query: String::new(),
            regex: false,
            hits: Vec::new(),
            problems: Vec::new(),
            output: "Choose Check, Build, or Test to run local Cargo.\n".into(),
            running: None,
            cancel: None,
            status: "Ready · local workspace".into(),
            capture,
            capture_requested: false,
            frames: 0,
        };
        app.refresh_files();
        if let Some(file) = file { app.open_file(&file); }
        app
    }
    fn refresh_files(&mut self) {
        self.files.clear();
        if let Some(root) = &self.workspace {
            fn visit(root: &Path, dir: &Path, depth: usize, files: &mut Vec<PathBuf>) {
                if depth > 8 || files.len() >= 300 { return; }
                let Ok(entries) = std::fs::read_dir(dir) else { return };
                for entry in entries.flatten() {
                    let name = entry.file_name().to_string_lossy().to_string();
                    if name.starts_with('.') || name == "target" { continue; }
                    let Ok(ty) = entry.file_type() else { continue };
                    if ty.is_symlink() { continue; }
                    let path = entry.path();
                    if ty.is_dir() { visit(root, &path, depth + 1, files); }
                    else if ty.is_file() && path.starts_with(root) && files.len() < 300 {
                        files.push(path);
                    }
                }
            }
            visit(root, root, 0, &mut self.files);
            self.files.sort();
        }
    }
    fn open_file(&mut self, path: &Path) {
        if self.dirty {
            self.status = "Save or undo the active edit before opening another file".into();
            return;
        }
        match Document::open(path) {
            Ok(document) => {
                self.buffer = document.text();
                self.status = document.read_only_reason().map(|s| format!("Read-only: {s}"))
                    .unwrap_or_else(|| format!("Opened {}", path.display()));
                self.active = Some(path.to_path_buf());
                self.document = Some(document);
                self.dirty = false;
            }
            Err(e) => self.status = format!("Open: {e}"),
        }
    }
    fn save(&mut self) {
        if let Some(document) = &mut self.document {
            match document.save() {
                Ok(()) => { self.dirty = false; self.status = "Saved source file".into(); }
                Err(e) => self.status = format!("Save: {e}"),
            }
        }
    }
    fn history(&mut self, redo: bool) {
        if let Some(document) = &mut self.document {
            let result = if redo { document.redo() } else { document.undo() };
            match result {
                Ok(()) => {
                    self.buffer = document.text();
                    self.dirty = true;
                    self.status = if redo { "Redo recorded for recovery" } else { "Undo recorded for recovery" }.into();
                }
                Err(e) => self.status = e.to_string(),
            }
        }
    }
    fn search(&mut self) {
        if let Some(root) = &self.workspace {
            match search_workspace(root, &SearchQuery { pattern: self.query.clone(), regex: self.regex }) {
                Ok(hits) => { self.status = format!("{} search hits", hits.len()); self.hits = hits; }
                Err(e) => self.status = format!("Search: {e}"),
            }
        }
    }
    fn build(&mut self, action: CargoAction) {
        let Some(root) = self.workspace.clone() else { self.status = "Open a Cargo workspace first".into(); return };
        if self.running.is_some() { return; }
        let verb = match action { CargoAction::Check => "check", CargoAction::Build => "build", CargoAction::Test => "test" };
        self.output = format!("cwd: {}\nargv: cargo {verb} --offline --message-format=json\n\nRunning...", root.display());
        self.status = format!("Running cargo {verb}");
        let (sender, receiver) = mpsc::channel();
        let cancel = Arc::new(AtomicBool::new(false));
        let worker_cancel = cancel.clone();
        std::thread::spawn(move || {
            let result = run_cargo_with_control(&root, action, &worker_cancel, Duration::from_secs(600))
                .map_err(|e| e.to_string());
            let _ = sender.send(result);
        });
        self.running = Some(receiver);
        self.cancel = Some(cancel);
    }
    fn poll_build(&mut self) {
        let result = self.running.as_ref().and_then(|receiver| receiver.try_recv().ok());
        if let Some(result) = result {
            self.running = None;
            self.cancel = None;
            match result {
                Ok(report) => {
                    self.status = format!("Cargo {} · {} problem(s){}", if report.success { "passed" } else { "failed" }, report.diagnostics.len(), if report.output_truncated { " · output truncated" } else { "" });
                    self.problems = report.diagnostics;
                    self.output = report.raw_output;
                }
                Err(e) => { self.status = format!("Cargo: {e}"); self.output = e; }
            }
        }
    }
    fn save_capture(&mut self, ctx: &egui::Context) {
        let Some(path) = self.capture.clone() else { return };
        let image = ctx.input(|i| i.events.iter().find_map(|event| match event {
            egui::Event::Screenshot { image, .. } => Some(image.clone()),
            _ => None,
        }));
        if let Some(image) = image {
            let pixels: Vec<u8> = image.pixels.iter().flat_map(|p| p.to_array()).collect();
            let result = (|| -> Result<(), String> {
                if let Some(parent) = path.parent() { std::fs::create_dir_all(parent).map_err(|e| e.to_string())?; }
                let file = std::fs::File::create(&path).map_err(|e| e.to_string())?;
                let mut png = png::Encoder::new(file, image.size[0] as u32, image.size[1] as u32);
                png.set_color(png::ColorType::Rgba); png.set_depth(png::BitDepth::Eight);
                png.write_header().map_err(|e| e.to_string())?
                    .write_image_data(&pixels).map_err(|e| e.to_string())?;
                Ok(())
            })();
            match result { Ok(()) => println!("Captured {}", path.display()), Err(e) => eprintln!("Capture: {e}") }
            self.capture = None;
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        } else if !self.capture_requested && self.frames > 12 {
            ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot(Default::default()));
            self.capture_requested = true;
        }
    }
}
impl eframe::App for CodeApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.frames += 1;
        if self.frames == 1 {
            let mut visuals = egui::Visuals::dark();
            visuals.override_text_color = Some(TEXT);
            visuals.widgets.noninteractive.fg_stroke.color = TEXT;
            visuals.widgets.inactive.fg_stroke.color = TEXT;
            visuals.selection.bg_fill = Color32::from_rgb(43, 86, 115);
            visuals.selection.stroke.color = ACCENT;
            ctx.set_visuals(visuals);
        }
        self.poll_build();
        self.save_capture(ctx);
        let mut open_file = None;
        egui::TopBottomPanel::top("toolbar").frame(egui::Frame::none().fill(PANEL)
            .inner_margin(egui::Margin::symmetric(14.0, 10.0))).show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label(egui::RichText::new("CODESTRIKE").size(18.0).strong().color(ACCENT));
                ui.add_space(12.0);
                if ui.button("Open folder").clicked()
                    && let Some(root) = rfd::FileDialog::new().pick_folder()
                {
                    self.workspace = Some(root);
                    self.refresh_files();
                    self.status = "Workspace opened".into();
                }
                if ui.button("Open file").clicked()
                    && let Some(path) = rfd::FileDialog::new().pick_file()
                { open_file = Some(path); }
                if ui.add_enabled(self.document.as_ref().is_some_and(Document::editable), egui::Button::new("Save")).clicked() { self.save(); }
                if ui.add_enabled(self.document.as_ref().is_some_and(Document::editable), egui::Button::new("Undo")).clicked() { self.history(false); }
                if ui.add_enabled(self.document.as_ref().is_some_and(Document::editable), egui::Button::new("Redo")).clicked() { self.history(true); }
                ui.with_layout(egui::Layout::right_to_left(Align::Center), |ui| {
                    ui.label(egui::RichText::new(self.workspace.as_ref().map(|p| p.display().to_string()).unwrap_or_else(|| "No workspace".into())).small().color(MUTED));
                });
            });
        });
        egui::SidePanel::left("navigator").default_width(255.0).min_width(210.0).resizable(true)
            .frame(egui::Frame::none().fill(PANEL).inner_margin(egui::Margin::same(13.0)))
            .show(ctx, |ui| {
                ui.heading("Explorer");
                ui.label(egui::RichText::new(format!("{} local files", self.files.len())).small().color(MUTED));
                ui.separator();
                egui::ScrollArea::vertical().id_salt("workspace-files").max_height(255.0).show(ui, |ui| {
                    for path in &self.files {
                        let relative = self.workspace.as_ref().and_then(|root| path.strip_prefix(root).ok()).unwrap_or(path);
                        if ui.selectable_label(self.active.as_ref() == Some(path), relative.display().to_string()).clicked() {
                            open_file = Some(path.clone());
                        }
                    }
                });
                ui.separator();
                ui.label(egui::RichText::new("Workspace search").strong().color(ACCENT));
                ui.text_edit_singleline(&mut self.query);
                ui.horizontal(|ui| {
                    ui.checkbox(&mut self.regex, "Regex");
                    if ui.add_enabled(self.workspace.is_some(), egui::Button::new("Find")).clicked() { self.search(); }
                });
                egui::ScrollArea::vertical().id_salt("search-results").show(ui, |ui| {
                    for hit in &self.hits {
                        let relative = self.workspace.as_ref().and_then(|root| hit.path.strip_prefix(root).ok()).unwrap_or(&hit.path);
                        let label = format!("{}:{}:{}", relative.display(), hit.line, hit.column);
                        if ui.selectable_label(false, label).on_hover_text(&hit.snippet).clicked() {
                            open_file = Some(hit.path.clone());
                        }
                    }
                });
            });
        egui::TopBottomPanel::bottom("status").frame(egui::Frame::none().fill(PANEL)
            .inner_margin(egui::Margin::symmetric(14.0, 6.0))).show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label(&self.status);
                ui.with_layout(egui::Layout::right_to_left(Align::Center), |ui| {
                    ui.label(egui::RichText::new(if self.dirty { "RECOVERY SAVED · SOURCE DIRTY" } else { "SOURCE ON DISK" }).small().color(ACCENT));
                });
            });
        });
        egui::TopBottomPanel::bottom("problems").default_height(205.0).min_height(130.0).resizable(true)
            .frame(egui::Frame::none().fill(PANEL).inner_margin(egui::Margin::same(12.0)))
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    ui.label(egui::RichText::new("PROBLEMS & OUTPUT").strong().color(ACCENT));
                    ui.add_space(15.0);
                    let enabled = self.workspace.is_some() && self.running.is_none();
                    if ui.add_enabled(enabled, egui::Button::new("Check")).clicked() { self.build(CargoAction::Check); }
                    if ui.add_enabled(enabled, egui::Button::new("Build")).clicked() { self.build(CargoAction::Build); }
                    if ui.add_enabled(enabled, egui::Button::new("Test")).clicked() { self.build(CargoAction::Test); }
                    if ui.add_enabled(self.running.is_some(), egui::Button::new("Cancel")).clicked()
                        && let Some(cancel) = &self.cancel
                    {
                        cancel.store(true, Ordering::Release);
                        self.status = "Cancelling Cargo".into();
                    }
                    ui.label(egui::RichText::new("Explicit local Cargo · offline").small().color(MUTED));
                });
                ui.separator();
                for issue in self.problems.iter().take(8) {
                    let location = issue.file.as_ref().map(|f| format!("{}:{}", f.display(), issue.line.unwrap_or(0))).unwrap_or_default();
                    ui.label(format!("{}  {}  {}", issue.level.to_uppercase(), location, issue.message));
                }
                egui::ScrollArea::vertical().id_salt("cargo-output").show(ui, |ui| {
                    ui.label(egui::RichText::new(self.output.chars().take(3500).collect::<String>()).monospace().size(11.0).color(MUTED));
                });
            });
        egui::CentralPanel::default().frame(egui::Frame::none().fill(BG)
            .inner_margin(egui::Margin::same(8.0))).show(ctx, |ui| {
            if let Some(path) = &self.active {
                ui.horizontal(|ui| {
                    ui.label(egui::RichText::new(format!("{}{}", path.file_name().unwrap_or_default().to_string_lossy(), if self.dirty { " ●" } else { "" })).strong().color(TEXT));
                    ui.add_space(10.0);
                    ui.label(egui::RichText::new(path.display().to_string()).small().color(MUTED));
                });
                if let Some(document) = &mut self.document {
                    if document.recovery_path().exists() && !self.dirty {
                        ui.horizontal(|ui| {
                            ui.label("Saved recovery available");
                            if ui.button("Apply recovery").clicked() {
                                match document.recover() {
                                    Ok(()) => { self.buffer = document.text(); self.dirty = true; self.status = "Recovery applied in memory".into(); }
                                    Err(e) => self.status = format!("Recovery: {e}"),
                                }
                            }
                        });
                    }
                    let editable = document.editable();
                    let response = ui.add_enabled(editable,
                        egui::TextEdit::multiline(&mut self.buffer)
                            .font(egui::TextStyle::Monospace)
                            .code_editor()
                            .desired_width(f32::INFINITY)
                            .desired_rows(32)
                            .background_color(EDITOR));
                    if response.changed() {
                        match document.replace(0, document.len_chars(), &self.buffer) {
                            Ok(()) => { self.dirty = true; self.status = "Edit recorded for recovery".into(); }
                            Err(e) => { self.buffer = document.text(); self.status = format!("Edit: {e}"); }
                        }
                    }
                }
            } else {
                ui.vertical_centered(|ui| {
                    ui.add_space(90.0);
                    ui.heading("Open a local source file");
                    ui.label("Choose a folder, edit UTF-8 source, search, then run Cargo explicitly.");
                });
            }
        });
        if let Some(path) = open_file { self.open_file(&path); }
        if ctx.input(|i| i.modifiers.command && i.key_pressed(egui::Key::S)) { self.save(); }
        if self.capture.is_some() || self.running.is_some() {
            ctx.request_repaint_after(std::time::Duration::from_millis(40));
        }
    }
}
fn main() -> eframe::Result {
    let args: Vec<String> = std::env::args().collect();
    let arg = |flag: &str| args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).map(PathBuf::from);
    let workspace = arg("--workspace");
    let file = arg("--file");
    let capture = arg("--capture");
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([1320.0, 790.0]).with_min_inner_size([960.0, 650.0]),
        ..Default::default()
    };
    eframe::run_native("CodeStrike", options, Box::new(move |_cc| Ok(Box::new(CodeApp::new(workspace, file, capture)))))
}
