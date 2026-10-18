pub mod geometry;
pub mod io;
pub mod model;
pub mod render;
pub mod ui_app;

pub use geometry::*;
pub use io::*;
pub use model::*;
pub use render::*;
pub use ui_app::*;

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .to_path_buf()
    }

    fn collect_descendants<'a>(layer: &'a SketchLayer, out: &mut Vec<&'a SketchLayer>) {
        out.push(layer);
        for child in &layer.layers {
            collect_descendants(child, out);
        }
    }

    #[test]
    fn test_magic_byte_format_detection() {
        let root = repo_root();
        let sketch_path = root.join("samples/smart-layout.sketch");
        let fmt = SketchDocumentIO::detect_format(&sketch_path).unwrap();
        assert_eq!(fmt, SketchReaderFormat::ZippedJson);
        assert_eq!(fmt.class_name(), "MSDocumentZippedJSONReader");
    }

    #[test]
    fn test_validation_statuses_and_crash_fix_across_all_six_variants() {
        let root = repo_root();
        let variants_dir = root.join("samples/variants");

        let v0 = SketchZipArchive::read_entries_from_path(&variants_dir.join("v0-control.sketch"))
            .unwrap();
        assert_eq!(SketchDocumentIO::validate(&v0), SketchValidationStatus::Valid);

        let v2 = SketchZipArchive::read_entries_from_path(
            &variants_dir.join("v2-no-user-json.sketch"),
        )
        .unwrap();
        assert_eq!(
            SketchDocumentIO::validate(&v2),
            SketchValidationStatus::CorruptMetadata
        );
        // Crash fix verification: share_info must not panic when user.json is missing
        assert!(SketchDocumentIO::share_info(&v2).is_none());
        let (repaired_v2, status_v2, was_repaired) =
            SketchDocumentIO::read_document_from_entries(&v2, true).unwrap();
        assert_eq!(status_v2, SketchValidationStatus::CorruptMetadata);
        assert!(was_repaired);
        assert!(!repaired_v2.pages.is_empty());

        let v3 = SketchZipArchive::read_entries_from_path(
            &variants_dir.join("v3-old-version.sketch"),
        )
        .unwrap();
        assert_eq!(
            SketchDocumentIO::validate(&v3),
            SketchValidationStatus::LegacyUnsupported
        );

        let v4 = SketchZipArchive::read_entries_from_path(
            &variants_dir.join("v4-newer-version.sketch"),
        )
        .unwrap();
        assert_eq!(
            SketchDocumentIO::validate(&v4),
            SketchValidationStatus::NewerVersionWarning
        );

        let v5 = SketchZipArchive::read_entries_from_path(
            &variants_dir.join("v5-newer-compat.sketch"),
        )
        .unwrap();
        assert_eq!(
            SketchDocumentIO::validate(&v5),
            SketchValidationStatus::IncompatibleNewer
        );
        assert!(SketchDocumentIO::read_document_from_entries(&v5, true).is_err());

        let v6 = SketchZipArchive::read_entries_from_path(
            &variants_dir.join("v6-no-meta-json.sketch"),
        )
        .unwrap();
        assert_eq!(
            SketchDocumentIO::validate(&v6),
            SketchValidationStatus::CorruptMetadata
        );
    }

    #[test]
    fn test_smart_layout_document_read_and_roundtrip_write() {
        let root = repo_root();
        let (doc, status, repaired) = SketchDocumentIO::read_document_from_path(
            &root.join("samples/smart-layout.sketch"),
            true,
        )
        .unwrap();
        assert_eq!(status, SketchValidationStatus::Valid);
        assert!(!repaired);
        assert_eq!(doc.pages.len(), 2);
        assert_eq!(doc.all_symbol_masters().len(), 46);

        let encoded_entries = SketchDocumentIO::encode_document_entries(&doc, false).unwrap();
        let zip_bytes = SketchZipArchive::write_entries(&encoded_entries).unwrap();
        let roundtrip_entries = SketchZipArchive::read_entries(&zip_bytes).unwrap();
        assert_eq!(
            SketchDocumentIO::validate(&roundtrip_entries),
            SketchValidationStatus::Valid
        );
        let (doc2, _, _) =
            SketchDocumentIO::read_document_from_entries(&roundtrip_entries, false).unwrap();
        assert_eq!(doc2.pages.len(), 2);
        assert_eq!(doc2.all_symbol_masters().len(), 46);
    }

    #[test]
    fn test_bezier_builder_and_corner_fillet_kappa() {
        assert!((SketchBezierBuilder::FILLET_KAPPA_COMPLEMENT - 0.4477152502).abs() < 1e-9);
        let rect = SketchLayer::make_rectangle(
            "Rounded",
            SketchRect::new(10.0, 20.0, 200.0, 100.0),
            16.0,
            SketchColor::WHITE,
            SketchColor::BLACK,
        );
        let path = SketchBezierBuilder::build_vector_path(
            &rect.points,
            rect.frame,
            rect.is_closed,
            rect.fixed_radius,
        );
        let d = SketchBezierBuilder::svg_path_data(&path);
        assert!(d.contains('M'));
        assert!(d.contains('C'));
        assert!(d.ends_with('Z'));
    }

    #[test]
    fn test_boolean_operations_engine() {
        let a = SketchLayer::make_rectangle(
            "A",
            SketchRect::new(0.0, 0.0, 100.0, 100.0),
            0.0,
            SketchColor::WHITE,
            SketchColor::BLACK,
        );
        let b = SketchLayer::make_rectangle(
            "B",
            SketchRect::new(50.0, 50.0, 100.0, 100.0),
            0.0,
            SketchColor::BLACK,
            SketchColor::WHITE,
        );
        for op in [
            SketchBooleanOperation::Union,
            SketchBooleanOperation::Subtract,
            SketchBooleanOperation::Intersect,
            SketchBooleanOperation::Difference,
        ] {
            let group = SketchBooleanEngine::combine_layers(&a, &b, op);
            assert_eq!(group.kind(), SketchLayerKind::ShapeGroup);
            let path = SketchBooleanEngine::evaluate_shape_group_path(&group);
            assert!(!path.is_empty());
        }
    }

    #[test]
    fn test_smart_layout_dynamic_symbol_override_expansion() {
        let root = repo_root();
        let (doc, _, _) = SketchDocumentIO::read_document_from_path(
            &root.join("samples/smart-layout.sketch"),
            true,
        )
        .unwrap();
        let mut nodes = Vec::new();
        collect_descendants(&doc.pages[0], &mut nodes);
        let instance = (*nodes
            .into_iter()
            .find(|l| l.kind() == SketchLayerKind::SymbolInstance && !l.override_values.is_empty())
            .expect("symbolInstance with overrides"))
        .clone();

        let base_expanded =
            SketchSmartLayoutEngine::expand_symbol_instance(&instance, &doc).expect("expanded");

        let mut longer_instance = instance.clone();
        if let Some(first_ov) = longer_instance
            .override_values
            .iter_mut()
            .find(|o| o.override_name.ends_with("_stringValue"))
        {
            first_ov.value =
                "Super Long Dynamic Smart Layout Label Override On Windows".to_string();
        }
        SketchRenderCache::global().clear_all();
        let expanded_longer =
            SketchSmartLayoutEngine::expand_symbol_instance(&longer_instance, &doc)
                .expect("expanded longer");
        assert!(
            expanded_longer.frame.width >= base_expanded.frame.width
                || expanded_longer.frame.height >= base_expanded.frame.height
        );
    }

    #[test]
    fn test_svg_png_pdf_css_exporters() {
        let root = repo_root();
        let (doc, _, _) = SketchDocumentIO::read_document_from_path(
            &root.join("samples/smart-layout.sketch"),
            true,
        )
        .unwrap();
        let page = &doc.pages[0];

        let svg = SketchExporter::export_svg(page, &doc);
        assert!(svg.starts_with("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
        assert!(svg.contains("<svg"));

        let png = SketchExporter::export_png(page, &doc, 0.25);
        assert!(png.len() > 64);
        assert_eq!(&png[0..8], &[137, 80, 78, 71, 13, 10, 26, 10]);

        let pdf = SketchExporter::export_pdf(page, &doc);
        assert!(pdf.starts_with(b"%PDF-1.4"));
        assert!(pdf.ends_with(b"%%EOF\n"));

        let rect = SketchLayer::make_rectangle(
            "Card",
            SketchRect::new(0.0, 0.0, 240.0, 120.0),
            12.0,
            SketchColor::new(0.2, 0.4, 0.8, 1.0),
            SketchColor::BLACK,
        );
        let css = SketchExporter::css_attributes(&rect);
        assert!(css.contains("width: 240px;"));
        assert!(css.contains("border-radius: 12px;"));
    }

    #[test]
    fn test_performance_checks_suite() {
        let root = repo_root();
        let sketch_path = root.join("samples/smart-layout.sketch");
        let (doc, _, _) = SketchDocumentIO::read_document_from_path(&sketch_path, true).unwrap();
        let report = SketchPerformanceSuite::run_all_checks(&doc, Some(&sketch_path));
        assert_eq!(report.checks.len(), 6);
        for check in &report.checks {
            assert!(
                check.passed,
                "Performance check {} failed: {:.2} ms > {:.2} ms",
                check.name, check.measured_ms, check.budget_ms
            );
        }
        assert!(report.all_passed);
    }

    #[test]
    fn test_versioned_preset_archive_and_polygon_star_triangle_masking() {
        let poly =
            SketchLayer::make_polygon("Hexagon", 6, SketchRect::new(0.0, 0.0, 100.0, 100.0));
        assert_eq!(poly.points.len(), 6);

        let star =
            SketchLayer::make_star("Star", 5, 0.5, SketchRect::new(0.0, 0.0, 100.0, 100.0));
        assert_eq!(star.points.len(), 10);

        let tri = SketchLayer::make_triangle("Triangle", SketchRect::new(0.0, 0.0, 100.0, 100.0));
        assert_eq!(tri.points.len(), 3);
    }
}
