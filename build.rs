#[path = "build_support/windows_icon.rs"]
mod windows_icon;

fn main() {
    windows_icon::embed(
        "assets/branding/CodeStrike-geometric.ico",
        "codestrike-desktop",
    );
}
