//! CAD text is shaped by Core Text, then emitted as ordinary paged geometry.
use super::*;
use acadrust::entities::mtext_format::{parse_mtext, MTextColor, MTextScalar};
use acadrust::entities::text::{TextHorizontalAlignment as H, TextVerticalAlignment as T};
use acadrust::entities::{AttributeDefinition, AttributeEntity, MText, Text};
use serde_json::Value;

pub type Emit = unsafe extern "C" fn(*mut c_void, i32, *const c_void, usize) -> i32;
pub type Layout = unsafe extern "C" fn(*mut c_void, *const u8, usize, *mut c_void, Emit) -> i32;
#[derive(Clone)]
pub struct FontStyle {
    pub font: String,
    pub vertical: bool,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Annotation {
    pub id: String,
    pub kind: String,
    pub value: String,
    pub layer_index: usize,
    pub font: String,
    pub layout: [f64; 8],
}
struct Sink<'a> {
    context: &'a mut Context,
    matrix: M,
    base: M,
    offset: V,
    height: f64,
    width: f64,
    oblique: f64,
    flags: i16,
    h: i16,
    vert: i16,
    fit: Option<f64>,
    attachment: Option<i16>,
    style: Style,
    styles: Vec<Style>,
    key: String,
    kind: String,
    error: Option<String>,
    metrics: [f64; 8],
}
unsafe extern "C" fn emit(
    sink: *mut c_void,
    kind: i32,
    values: *const c_void,
    count: usize,
) -> i32 {
    let s = &mut *(sink as *mut Sink<'_>);
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> R<()> {
        if kind == 4 {
            s.error = Some(
                String::from_utf8_lossy(std::slice::from_raw_parts(values as *const u8, count))
                    .into_owned(),
            );
            return Ok(());
        }
        let values = std::slice::from_raw_parts(values as *const f64, count);
        match kind {
            0 => {
                if count != 8 || values.iter().any(|v| !v.is_finite()) {
                    return Err("文字排版返回无效参数。".into());
                }
                s.metrics.copy_from_slice(values);
                let advance = values[0];
                let (mut sx, mut sy) = (s.height * s.width, s.height);
                if let Some(distance) = s.fit {
                    if advance > 0. {
                        sx = distance / advance;
                        if s.h == 3 {
                            sy = sx / s.width.abs().max(1e-12);
                        }
                    }
                }
                if s.flags & 2 != 0 {
                    sx = -sx;
                }
                if s.flags & 4 != 0 {
                    sy = -sy;
                }
                let (x, y) = if let Some(a) = s.attachment {
                    let col = (a - 1) % 3;
                    let row = (a - 1) / 3;
                    (
                        -values[5] * (col as f64) * 0.5,
                        match row {
                            0 => -values[4],
                            1 => -(values[4] + values[2]) * 0.5,
                            _ => -values[2],
                        },
                    )
                } else {
                    let x = match s.h {
                        1 | 4 => -advance * 0.5,
                        2 => -advance,
                        _ => 0.,
                    };
                    let y = if s.h == 4 && s.vert == 0 {
                        -(values[4] + values[2]) * 0.5
                    } else {
                        match s.vert {
                            1 => -values[2],
                            2 => -(values[4] + values[2]) * 0.5,
                            3 => -values[4],
                            _ => 0.,
                        }
                    };
                    (x, y)
                };
                let mut affine = id();
                affine[0] = sx;
                affine[4] = s.oblique.tan() * sy;
                affine[5] = sy;
                s.matrix = product(
                    &s.base,
                    &product(
                        &translation(s.offset),
                        &product(&affine, &translation([x, y, 0.])),
                    ),
                );
            }
            1 => {
                if count != 6 {
                    return Err("文字三角面数据无效。".into());
                }
                s.context.triangle(
                    [
                        [values[0], values[1], 0.],
                        [values[2], values[3], 0.],
                        [values[4], values[5], 0.],
                    ],
                    &s.matrix,
                    &s.style,
                    &s.key,
                    &s.kind,
                )?;
            }
            2 => {
                if count != 4 {
                    return Err("文字装饰线数据无效。".into());
                }
                s.context.line(
                    [values[0], values[1], 0.],
                    [values[2], values[3], 0.],
                    &s.matrix,
                    &s.style,
                    &s.key,
                    &s.kind,
                )?;
            }
            3 => {
                let index = *values.first().unwrap_or(&0.) as usize;
                if let Some(style) = s.styles.get(index) {
                    s.style = style.clone();
                }
            }
            _ => return Err("文字排版返回未知数据。".into()),
        }
        Ok(())
    }));
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            s.error = Some(e);
            1
        }
        Err(payload) => {
            if let Some(stop) = payload.downcast_ref::<guard::Stop>() {
                stop.0
            } else {
                1
            }
        }
    }
}
fn rotation(angle: f64) -> M {
    let (s, c) = angle.sin_cos();
    [c, s, 0., 0., -s, c, 0., 0., 0., 0., 1., 0., 0., 0., 0., 1.]
}
fn clean(value: &str) -> String {
    // TEXT has %% symbol escapes; MTEXT's parser handles its own controls.
    let mut text = value.to_string();
    for (code, symbol) in [("%%c", "Ø"), ("%%d", "°"), ("%%p", "±")] {
        text = text
            .replace(code, symbol)
            .replace(&code.to_uppercase(), symbol);
    }
    text
}
impl Context {
    fn font_style(&mut self, name: &str) -> FontStyle {
        self.text_styles.get(name).cloned().unwrap_or(FontStyle {
            font: String::new(),
            vertical: false,
        })
    }
    fn shape_text(
        &mut self,
        request: Value,
        style: Style,
        styles: Vec<Style>,
        base: M,
        offset: V,
        height: f64,
        width: f64,
        oblique: f64,
        flags: i16,
        h: i16,
        vert: i16,
        fit: Option<f64>,
        attachment: Option<i16>,
        key: &str,
        kind: &str,
        value: &str,
        font: &str,
    ) -> R<()> {
        guard::checkpoint(value.len().saturating_mul(128));
        if !height.is_finite()
            || height < 0.
            || !width.is_finite()
            || width == 0.
            || !oblique.is_finite()
        {
            return Err("CAD 文字尺寸无效。".into());
        }
        if height == 0. || value.is_empty() {
            return Ok(());
        }
        let label = value.chars().take(160).collect::<String>();
        self.text_labels.insert(key.into(), label);
        let data = serde_json::to_vec(&request).map_err(|e| e.to_string())?;
        let callback = self.text_layout;
        let user = self.user;
        let mut sink = Sink {
            context: self,
            matrix: id(),
            base,
            offset,
            height,
            width,
            oblique,
            flags,
            h,
            vert,
            fit,
            attachment,
            style: style.clone(),
            styles,
            key: key.into(),
            kind: kind.into(),
            error: None,
            metrics: [0.; 8],
        };
        let result = unsafe {
            callback(
                user,
                data.as_ptr(),
                data.len(),
                &mut sink as *mut _ as *mut c_void,
                emit,
            )
        };
        let error = sink.error.take();
        let metrics = sink.metrics;
        drop(sink);
        self.text_labels.remove(key);
        if result < 0 {
            if result == -2 || result == -3 {
                std::panic::panic_any(guard::Stop(-result));
            }
            return Err(error.unwrap_or("CAD 文字轮廓未能完整生成。".into()));
        }
        if result & 1 != 0 {
            self.font_substitutions.insert(if font.is_empty() {
                "未指定字体".into()
            } else {
                font.into()
            });
        }
        if result & 2 != 0 {
            self.unsupported("缺少字形的文字");
        }
        self.manifest.text_objects += 1;
        self.manifest.annotations.push(Annotation {
            id: key.into(),
            kind: kind.into(),
            value: value.into(),
            layer_index: style.layer,
            font: font.into(),
            layout: metrics,
        });
        Ok(())
    }
    pub(super) fn text(&mut self, e: &Text, m: &M, style: &Style, key: &str, kind: &str) -> R<()> {
        let font = self.font_style(&e.style);
        if font.vertical {
            self.unsupported("竖排文字");
            return Ok(());
        }
        let h = match e.horizontal_alignment {
            H::Left => 0,
            H::Center => 1,
            H::Right => 2,
            H::Aligned => 3,
            H::Middle => 4,
            H::Fit => 5,
        };
        let vert = match e.vertical_alignment {
            T::Baseline => 0,
            T::Bottom => 1,
            T::Middle => 2,
            T::Top => 3,
        };
        let mut anchor = if h == 0 && vert == 0 {
            v(e.insertion_point)
        } else {
            v(e.alignment_point.unwrap_or(e.insertion_point))
        };
        let mut angle = e.rotation;
        let mut fit = None;
        if (h == 3 || h == 5) && vert == 0 {
            anchor = v(e.insertion_point);
            if let Some(end) = e.alignment_point {
                let delta = sub(v(end), anchor);
                angle = delta[1].atan2(delta[0]);
                fit = Some(length(delta));
            }
        }
        let basis = ocs(v(e.normal));
        let base = product(m, &product(&basis, &rotation(angle)));
        let offset = position(&rotation(-angle), anchor);
        let mut value = clean(&e.value);
        let mut runs = Vec::new();
        let (mut underline, mut overline) = (false, false);
        let mut rest = value.as_str();
        let mut plain = String::new();
        while !rest.is_empty() {
            let control = rest
                .char_indices()
                .find(|(i, _)| {
                    rest[*i..].starts_with("%%u")
                        || rest[*i..].starts_with("%%U")
                        || rest[*i..].starts_with("%%o")
                        || rest[*i..].starts_with("%%O")
                })
                .map(|(i, _)| i);
            let end = control.unwrap_or(rest.len());
            if end > 0 {
                let content = &rest[..end];
                plain.push_str(content);
                runs.push(json!({"text":content,"font":font.font,"height":1.,"width":1.,"index":0,"underline":underline,"overline":overline}));
            }
            if let Some(i) = control {
                if rest.as_bytes()[i + 2].eq_ignore_ascii_case(&b'u') {
                    underline = !underline;
                } else {
                    overline = !overline;
                }
                rest = &rest[i + 3..];
            } else {
                break;
            }
        }
        value = plain;
        let request = json!({"runs":runs,"width":0.,"lineSpacing":1.6666666667});
        if e.thickness != 0. {
            self.unsupported("文字厚度");
        }
        self.shape_text(
            request,
            style.clone(),
            vec![style.clone()],
            base,
            offset,
            e.height,
            e.width_factor,
            e.oblique_angle,
            e.generation_flags,
            h,
            vert,
            fit,
            None,
            key,
            kind,
            &value,
            &font.font,
        )
    }
    pub(super) fn mtext(
        &mut self,
        e: &MText,
        m: &M,
        style: &Style,
        key: &str,
        kind: &str,
    ) -> R<()> {
        let font = self.font_style(&e.style);
        if font.vertical
            || matches!(
                e.drawing_direction,
                acadrust::entities::mtext::DrawingDirection::TopToBottom
            )
        {
            self.unsupported("竖排文字");
            return Ok(());
        }
        let parsed = parse_mtext(&e.value, false);
        let mut runs = Vec::new();
        let mut styles = Vec::new();
        let mut plain = String::new();
        for (pi, paragraph) in parsed.paragraphs.iter().enumerate() {
            if pi > 0 {
                runs.push(json!({"text":"\n","font":font.font,"height":1.,"index":styles.len()}));
                styles.push(style.clone());
                plain.push('\n');
            }
            if paragraph.properties != Default::default() {
                self.text_layout_warnings
                    .insert("多行文字段落格式已采用基本排版".into());
            }
            for span in &paragraph.spans {
                let p = &span.properties;
                let content = if let Some(stack) = &span.stacking {
                    self.text_layout_warnings
                        .insert("堆叠分数暂按行内分数显示".into());
                    format!("{}/{}", stack.numerator, stack.denominator)
                } else {
                    span.text.clone()
                };
                plain.push_str(&content);
                let height = match p.height {
                    Some(MTextScalar::Factor(h)) => h,
                    Some(MTextScalar::Absolute(h)) => h / e.height.max(1e-12),
                    None => 1.,
                };
                let mut runstyle = style.clone();
                let color = if let Some(rgb) = p.color_rgb {
                    Some(Color::from_rgb(rgb.0, rgb.1, rgb.2))
                } else {
                    match p.color {
                        Some(MTextColor::Index(i)) => Some(Color::from_index(i as i16)),
                        Some(MTextColor::TrueColor(value)) => {
                            Some(Color::from_true_color_value(value as i32))
                        }
                        _ => None,
                    }
                };
                if let Some(color) = color {
                    let mut common = EntityCommon::default();
                    common.color = color;
                    runstyle = self.style(&common, style);
                }
                let name = p
                    .font
                    .as_ref()
                    .map(|f| f.name.as_str())
                    .unwrap_or(&font.font);
                let index = styles.len();
                styles.push(runstyle);
                runs.push(json!({"text":content,"font":name,"height":height,"width":p.width_factor.unwrap_or(1.),"oblique":p.oblique_angle.unwrap_or(0.).to_radians(),"bold":p.font.as_ref().is_some_and(|f|f.bold),"italic":p.font.as_ref().is_some_and(|f|f.italic),"tracking":p.tracking.unwrap_or(1.)-1.,"underline":p.stroke.underline(),"overline":p.stroke.overline(),"strike":p.stroke.strikethrough(),"index":index}));
            }
        }
        if e.column_data.column_type != 0 {
            self.text_layout_warnings
                .insert("多栏文字暂按单栏显示".into());
        }
        if e.background_fill_flags != 0 {
            self.text_layout_warnings
                .insert("文字背景遮罩尚未显示".into());
        }
        let basis = ocs(v(e.normal));
        let orient = if let Some(x) = e.dwg_x_direction {
            let x = unit(v(x));
            let y = cross(unit(v(e.normal)), x);
            [
                x[0], x[1], x[2], 0., y[0], y[1], y[2], 0., e.normal.x, e.normal.y, e.normal.z, 0.,
                0., 0., 0., 1.,
            ]
        } else {
            product(&basis, &rotation(e.rotation))
        };
        let base = product(m, &product(&translation(v(e.insertion_point)), &orient));
        let request = json!({"runs":runs,"width":e.rectangle_width/e.height.max(1e-12),"lineSpacing":e.line_spacing_factor*5./3.,"exactSpacing":e.line_spacing_style as i16 == 2});
        self.shape_text(
            request,
            style.clone(),
            styles,
            base,
            [0.; 3],
            e.height,
            1.,
            0.,
            0,
            0,
            0,
            None,
            Some(e.attachment_point as i16),
            key,
            kind,
            &plain,
            &font.font,
        )
    }
    pub(super) fn attribute(
        &mut self,
        e: &AttributeEntity,
        m: &M,
        parent: &Style,
        key: &str,
    ) -> R<()> {
        let mut style = self.style(&e.common, parent);
        style.visible &= !e.flags.invisible;
        if let Some(mtext) = &e.embedded_mtext {
            return self.mtext(mtext, m, &style, key, "ATTRIB");
        }
        let mut text = Text::with_value(&e.value, e.insertion_point);
        text.alignment_point = Some(e.alignment_point);
        text.height = e.height;
        text.rotation = e.rotation;
        text.width_factor = e.width_factor;
        text.oblique_angle = e.oblique_angle;
        text.style = e.text_style.clone();
        text.normal = e.normal;
        text.generation_flags = e.text_generation_flags;
        text.thickness = e.thickness;
        text.horizontal_alignment = match e.horizontal_alignment.to_value() {
            1 => H::Center,
            2 => H::Right,
            3 => H::Aligned,
            4 => H::Middle,
            5 => H::Fit,
            _ => H::Left,
        };
        text.vertical_alignment = match e.vertical_alignment.to_value() {
            1 => T::Bottom,
            2 => T::Middle,
            3 => T::Top,
            _ => T::Baseline,
        };
        self.text(&text, m, &style, key, "ATTRIB")
    }
    pub(super) fn attribute_definition(
        &mut self,
        e: &AttributeDefinition,
        m: &M,
        parent: &Style,
        key: &str,
        in_block: bool,
    ) -> R<()> {
        if in_block && !e.flags.constant {
            return Ok(());
        }
        let mut attribute = AttributeEntity::from_definition(e, None);
        if !in_block && !e.flags.constant {
            attribute.value = e.tag.clone();
        }
        self.attribute(&attribute, m, parent, key)
    }
}
