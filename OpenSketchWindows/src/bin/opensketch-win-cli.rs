use opensketch_win_core::*;
use serde_json::json;
use std::env;
use std::path::Path;

fn count_descendants(layer: &SketchLayer) -> usize {
    1 + layer.layers.iter().map(count_descendants).sum::<usize>()
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!(
            "Usage: opensketch-win-cli <inspect|validate|repair|export-svg|export-png|export-pdf|export-css|bench> <file.sketch> [output]"
        );
        std::process::exit(1);
    }

    let cmd = args[1].as_str();
    let input_path = Path::new(&args[2]);

    match cmd {
        "validate" => {
            let fmt = SketchDocumentIO::detect_format(input_path)
                .unwrap_or(SketchReaderFormat::LegacySqlite);
            let entries = SketchZipArchive::read_entries_from_path(input_path).unwrap_or_default();
            let status = SketchDocumentIO::validate(&entries);
            let share = SketchDocumentIO::share_info(&entries);
            let out = json!({
                "file": input_path.display().to_string(),
                "readerFormat": fmt.class_name(),
                "validationStatus": status.as_i32(),
                "dialogMessage": status.dialog_message(),
                "hasShareInfo": share.is_some()
            });
            println!("{}", serde_json::to_string_pretty(&out).unwrap());
        }
        "inspect" => {
            let (doc, status, repaired) =
                SketchDocumentIO::read_document_from_path(input_path, true).unwrap_or_else(|e| {
                    eprintln!("Error: {}", e);
                    std::process::exit(1);
                });
            let total_layers: usize = doc.pages.iter().map(count_descendants).sum();
            let out = json!({
                "file": input_path.display().to_string(),
                "validationStatus": status.as_i32(),
                "wasRepaired": repaired,
                "pageCount": doc.pages.len(),
                "symbolMasterCount": doc.all_symbol_masters().len(),
                "totalLayerCount": total_layers,
                "imageCount": doc.images.len()
            });
            println!("{}", serde_json::to_string_pretty(&out).unwrap());
        }
        "repair" => {
            let output_path = args.get(3).map(Path::new).unwrap_or(input_path);
            let (doc, status, repaired) =
                SketchDocumentIO::read_document_from_path(input_path, true).unwrap_or_else(|e| {
                    eprintln!("Error: {}", e);
                    std::process::exit(1);
                });
            SketchDocumentIO::write_document(&doc, output_path, false).unwrap();
            println!(
                "{}",
                serde_json::to_string_pretty(&json!({
                    "repaired": repaired,
                    "originalStatus": status.as_i32(),
                    "output": output_path.display().to_string()
                }))
                .unwrap()
            );
        }
        "export-svg" => {
            let (doc, _, _) = SketchDocumentIO::read_document_from_path(input_path, true).unwrap();
            let svg = SketchExporter::export_svg(&doc.pages[0], &doc);
            if let Some(out_file) = args.get(3) {
                std::fs::write(out_file, &svg).unwrap();
            } else {
                println!("{}", svg);
            }
        }
        "export-png" => {
            let (doc, _, _) = SketchDocumentIO::read_document_from_path(input_path, true).unwrap();
            let png = SketchExporter::export_png(&doc.pages[0], &doc, 1.0);
            let out_file = args
                .get(3)
                .map(|s| s.as_str())
                .unwrap_or("out/opensketch-win-exported.png");
            std::fs::write(out_file, png).unwrap();
            println!("Exported PNG to {}", out_file);
        }
        "export-pdf" => {
            let (doc, _, _) = SketchDocumentIO::read_document_from_path(input_path, true).unwrap();
            let pdf = SketchExporter::export_pdf(&doc.pages[0], &doc);
            let out_file = args
                .get(3)
                .map(|s| s.as_str())
                .unwrap_or("out/opensketch-win-exported.pdf");
            std::fs::write(out_file, pdf).unwrap();
            println!("Exported PDF to {}", out_file);
        }
        "export-css" => {
            let (doc, _, _) = SketchDocumentIO::read_document_from_path(input_path, true).unwrap();
            let css = SketchExporter::css_attributes(&doc.pages[0]);
            println!("{}", css);
        }
        "bench" => {
            let (doc, _, _) = SketchDocumentIO::read_document_from_path(input_path, true).unwrap();
            let report = SketchPerformanceSuite::run_all_checks(&doc, Some(input_path));
            let json_str = serde_json::to_string_pretty(&report).unwrap();
            if let Some(out_file) = args.get(3) {
                std::fs::write(out_file, &json_str).unwrap();
            }
            println!("{}", json_str);
            if !report.all_passed {
                std::process::exit(2);
            }
        }
        _ => {
            eprintln!("Unknown command: {}", cmd);
            std::process::exit(1);
        }
    }
}
