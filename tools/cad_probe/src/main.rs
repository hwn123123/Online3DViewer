//! Read-only feasibility probe. Never saves a drawing beside its source.
use acadrust::{CadDocument, DwgReader, DxfReader};
use acadrust::io::dwg::dwg_reader::DwgReadOptions;
use acadrust::io::dxf::DxfReaderConfiguration;
use acadrust::io::read::ReadOutcome;
use acadrust::entities::EntityType;
use serde_json::{json, Value};
use std::{collections::BTreeMap, path::Path, time::Instant};

fn inventory(doc: &CadDocument) -> Value {
    let mut all = BTreeMap::<String, usize>::new();
    let mut model = BTreeMap::<String, usize>::new();
    let mut unknown = BTreeMap::<String, usize>::new();
    let mut missing_blocks = BTreeMap::<String, usize>::new();
    let (mut acis_bytes, mut wire_segments, mut mesh_faces) = (0usize, 0usize, 0usize);
    for entity in doc.entities() {
        *all.entry(entity.as_entity().entity_type().into()).or_default() += 1;
        let acis = match entity {
            EntityType::Solid3D(e) => Some((&e.acis_data, &e.wires)),
            EntityType::Region(e) => Some((&e.acis_data, &e.wires)),
            EntityType::Body(e) => Some((&e.acis_data, &e.wires)),
            EntityType::Surface(e) => Some((&e.acis_data, &e.wires)),
            EntityType::Unknown(e) => { *unknown.entry(e.dxf_name.clone()).or_default() += 1; None },
            EntityType::Insert(e) => {
                if !doc.block_records.contains(&e.block_name) {
                    *missing_blocks.entry(e.block_name.clone()).or_default() += 1;
                }
                None
            },
            EntityType::Mesh(e) => { mesh_faces += e.faces.len(); None },
            EntityType::PolyfaceMesh(e) => { mesh_faces += e.faces.len(); None },
            _ => None,
        };
        if let Some((data, wires)) = acis {
            acis_bytes += data.sat_data.len() + data.sab_data.len();
            wire_segments += wires.iter().map(|wire| wire.points.len().saturating_sub(1)).sum::<usize>();
        }
    }
    for entity in doc.model_space_entities() {
        *model.entry(entity.as_entity().entity_type().into()).or_default() += 1;
    }
    let layers: Vec<_> = doc.layers.iter().map(|layer| json!({
        "name": layer.name, "off": layer.flags.off, "frozen": layer.flags.frozen,
        "color": format!("{:?}",layer.color)
    })).collect();
    let blocks: Vec<_> = doc.block_records.iter().map(|block| json!({
        "name": block.name, "entities": block.entity_handles.len()
    })).collect();
    json!({"allEntityTypes":all,"modelEntityTypes":model,"layers":layers,
           "blocks":blocks,"units":doc.header.insertion_units,"unknownEntityTypes":unknown,
           "missingBlockNames":missing_blocks,"acisPayloadBytes":acis_bytes,
           "acisWireSegments":wire_segments,"meshFaces":mesh_faces})
}

fn main() {
    let arguments: Vec<_> = std::env::args().collect();
    if arguments.len() < 2 { eprintln!("usage: o3dv-cad-probe drawing [strict|failsafe|sharded]"); std::process::exit(2); }
    let source = Path::new(&arguments[1]);
    let mode = arguments.get(2).map(String::as_str).unwrap_or("strict");
    let started = Instant::now();
    let mut shards = Vec::<Value>::new();
    let mut incomplete = false;
    let mut unverified = false;
    let limit: usize = std::env::var("O3DV_CAD_DECOMPRESS_LIMIT").ok().and_then(|s|s.parse().ok()).unwrap_or(256*1024*1024);
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<(), String> {
        let mut record = |outcome: ReadOutcome| {
            incomplete |= !outcome.stats.record_stream_read || !outcome.stats.stream_completed;
            unverified |= outcome.stats.recovered_errors > 0 || outcome.stats.skipped_source_records > 0;
            shards.push(json!({"stats":outcome.stats,"inventory":inventory(&outcome.document)}));
        };
        if source.extension().is_some_and(|extension|extension.eq_ignore_ascii_case("dxf")) {
            let reader = DxfReader::from_file(source).map_err(|e|e.to_string())?
                .with_configuration(DxfReaderConfiguration{failsafe:mode=="failsafe",..Default::default()});
            record(reader.read_with_stats().map_err(|e|e.to_string())?);
        } else {
            // Retain every mesh face; resource rejection must not become silent truncation.
            let mut options = DwgReadOptions::default().with_unlimited_mesh()
                .with_max_decompressed_bytes(limit).with_deferred_solid_reference_point().without_roundtrip_data();
            options.failsafe = mode=="failsafe";
            let mut reader = DwgReader::from_file_with_options(source, options).map_err(|e|e.to_string())?;
            if mode=="sharded" {
                reader.read_sharded(5000,|outcome|{record(outcome);Ok(())}).map_err(|e|e.to_string())?;
            } else {record(reader.read_with_stats().map_err(|e|e.to_string())?);}
        }
        Ok(())
    }));
    // Upstream can return Ok with a missing objects section, even in strict mode.
    // Preserve diagnostics and reject that as an incomplete decode.
    let error = match result { Ok(Ok(())) if incomplete=>Some("incomplete-record-stream".into()),
        Ok(Ok(())) if unverified=>Some("unverified-source-records".into()),
        Ok(Ok(()))=>None,Ok(Err(e))=>Some(e),Err(_)=>Some("reader-panic".into()) };
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    let measured = unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) } == 0;
    #[cfg(target_vendor = "apple")]
    let peak_rss = usage.ru_maxrss as u64;
    #[cfg(not(target_vendor = "apple"))]
    let peak_rss = (usage.ru_maxrss as u64) * 1024;
    let output = json!({"path":source,"mode":mode,"seconds":started.elapsed().as_secs_f64(),
        "decompressLimitBytes":limit,"error":error,"shards":shards,
        "peakResidentBytes":if measured {Some(peak_rss)}else{None}});
    println!("{}",output);
    if error.is_some() {std::process::exit(1);}
}

#[cfg(test)]
mod tests {
    use super::*;
    use acadrust::{DwgWriter, DxfWriter, EntityType, Vector3};
    use std::io::Cursor;

    #[test]
    fn native_dxf_keeps_three_dimensional_mesh_vertices() {
        // Independently CAD-exported reference, supplied by the pinned dependency.
        let source = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../build/ios/acadrust-upstream/tests/fixtures/r12/cad-created/native-geometry.dxf");
        let document = DxfReader::from_file(source).unwrap().read().unwrap();
        let mut checked = 0;
        for entity in document.entities() {
            match entity {
                EntityType::PolyfaceMesh(mesh) => {
                    assert_eq!(mesh.vertices.len(), 4);
                    assert_eq!(mesh.faces.len(), 1);
                    assert_eq!(mesh.vertices[2].location, Vector3::new(60.,10.,3.));
                    assert_eq!([mesh.faces[0].index1,mesh.faces[0].index2,mesh.faces[0].index3,mesh.faces[0].index4],[1,2,3,4]);
                    checked += 1;
                },
                EntityType::PolygonMesh(mesh) => {
                    assert_eq!((mesh.m_vertex_count,mesh.n_vertex_count),(2,3));
                    assert_eq!(mesh.vertices.len(),6);
                    assert_eq!(mesh.vertices[5].location,Vector3::new(40.,10.,5.));
                    checked += 1;
                },
                EntityType::Polyline3D(line) => {
                    assert_eq!(line.vertices.len(),3);
                    assert_eq!(line.vertices[2].position,Vector3::new(10.,15.,7.));
                    checked += 1;
                },
                _ => {},
            }
        }
        assert_eq!(checked,3);
        assert_eq!(inventory(&document)["missingBlockNames"],json!({}));
    }

    #[test]
    fn unicode_dxf_coordinates_and_layer_survive_reading() {
        // Authored DXF text; no writer from the candidate reader creates this input.
        let text="0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1021\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nLINE\n5\n100\n8\n构件图层\n10\n123456789.125\n20\n-2.5\n30\n7\n11\n123456790.125\n21\n4.5\n31\n-9\n0\nENDSEC\n0\nEOF\n";
        let document=DxfReader::from_reader(Cursor::new(text.as_bytes())).unwrap().read().unwrap();
        let line=document.entities().find_map(|e|if let EntityType::Line(line)=e{Some(line)}else{None}).unwrap();
        assert_eq!(line.common.layer,"构件图层");
        assert_eq!(line.start,Vector3::new(123456789.125,-2.5,7.));
        assert_eq!(line.end,Vector3::new(123456790.125,4.5,-9.));
        // Binary input is generated by the candidate writer; the ASCII source
        // above and CAD-exported mesh test remain the independent references.
        let binary=DxfWriter::new_binary(&document).write_to_vec().unwrap();
        assert!(binary.starts_with(b"AutoCAD Binary DXF"));
        let restored=DxfReader::from_reader(Cursor::new(binary)).unwrap().read().unwrap();
        let restored=restored.entities().find_map(|e|if let EntityType::Line(line)=e{Some(line)}else{None}).unwrap();
        assert_eq!(restored.start,line.start);
        assert_eq!(restored.end,line.end);
        assert_eq!(restored.common.layer,line.common.layer);
    }

    #[test]
    fn rejected_objects_section_must_not_qualify_as_a_complete_read() {
        let document=CadDocument::default();
        let bytes=DwgWriter::write_to_vec(&document).unwrap();
        let options=DwgReadOptions::default().with_max_decompressed_bytes(1);
        let mut reader=DwgReader::from_stream_with_options(Cursor::new(bytes),options);
        // Current upstream returns Ok + diagnostics for some extraction failures.
        // Neither Err nor such an empty outcome is a qualified parse.
        if let Ok(outcome)=reader.read_with_stats() {
            assert!(!outcome.stats.record_stream_read || !outcome.stats.stream_completed ||
                outcome.stats.recovered_errors>0 || outcome.stats.skipped_source_records>0);
        }
    }
}
