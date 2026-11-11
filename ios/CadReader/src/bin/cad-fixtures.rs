//! Test-data generator; never runs in the app or writes a source drawing.
use acadrust::entities::mesh::{Mesh, MeshFace};
use acadrust::{CadDocument, DwgWriter, DxfReader, DxfVersion, DxfWriter, EntityType, Vector3};
fn main() {
    let args: Vec<_> = std::env::args().collect();
    assert_eq!(
        args.len(),
        4,
        "cad-fixtures source.dxf destination.dwg AC10xx | mesh destination.dxf unused"
    );
    if args[1] == "dimension" {
        use acadrust::entities::dimension::{Dimension, DimensionLinear};
        let mut doc = CadDocument::default();
        doc.header.insertion_units = 6;
        let style = doc.dim_styles.get_mut("Standard").unwrap();
        style.dimlfac = 10.;
        style.dimdec = 2;
        style.dimpost = "<> mm".into();
        style.dimtxt = 0.5;
        style.dimasz = 0.25;
        let mut dim = DimensionLinear::new(Vector3::new(0., 0., 0.), Vector3::new(10., 0., 0.));
        dim.definition_point = Vector3::new(0., 2., 0.);
        dim.base.definition_point = dim.definition_point;
        dim.base.text_middle_point = Vector3::new(5., 2.5, 0.);
        if args[3] == "suppressed" {
            dim.base.set_text_override(Some(" ".into()));
        }
        doc.add_entity(EntityType::Dimension(Box::new(Dimension::Linear(dim))))
            .unwrap();
        DxfWriter::new(&doc).write_to_file(&args[2]).unwrap();
        return;
    }
    if args[1].starts_with("mesh") {
        let mut doc = CadDocument::default();
        doc.header.insertion_units = 6;
        let mut mesh = Mesh::new();
        mesh.vertices = vec![
            Vector3::new(0., 0., 3.),
            Vector3::new(2., 0., 3.),
            Vector3::new(2., 2., 3.),
            Vector3::new(1., 1., 3.),
            Vector3::new(0., 2., 3.),
            Vector3::new(1., 0., 3.),
        ];
        mesh.faces = vec![MeshFace::new(match args[1].as_str() {
            "mesh-repeat" => vec![0, 1, 2, 2, 3, 4],
            "mesh-collinear" => vec![0, 5, 1, 2, 3, 4],
            "mesh-clockwise" => vec![4, 3, 2, 1, 0],
            "mesh-degenerate" => vec![0, 5, 1, 1],
            _ => vec![0, 1, 2, 3, 4],
        })];
        doc.add_entity(EntityType::Mesh(mesh)).unwrap();
        DxfWriter::new(&doc).write_to_file(&args[2]).unwrap();
        return;
    }
    let mut doc = DxfReader::from_file(&args[1]).unwrap().read().unwrap();
    doc.version = match args[3].as_str() {
        "AC1015" => DxfVersion::AC1015,
        "AC1018" => DxfVersion::AC1018,
        "AC1021" => DxfVersion::AC1021,
        "AC1024" => DxfVersion::AC1024,
        "AC1027" => DxfVersion::AC1027,
        "AC1032" => DxfVersion::AC1032,
        _ => panic!("unsupported fixture version"),
    };
    DwgWriter::write_to_file(&args[2], &doc).unwrap();
}
