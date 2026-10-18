#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use opensketch_win_core::launch_windows_studio;
use std::env;
use std::path::PathBuf;

fn main() {
    let args: Vec<String> = env::args().collect();
    let initial_path = args.get(1).map(PathBuf::from).or_else(|| {
        let candidate = PathBuf::from("samples/smart-layout.sketch");
        if candidate.exists() {
            Some(candidate)
        } else {
            None
        }
    });

    if let Err(err) = launch_windows_studio(initial_path.as_deref(), 0) {
        eprintln!("OpenSketch for Windows error: {}", err);
        std::process::exit(1);
    }
}
