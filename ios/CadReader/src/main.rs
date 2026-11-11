use std::{
    ffi::{c_void, CStr, CString},
    time::Instant,
};
struct Context {
    started: Instant,
    cancel: bool,
    requests: usize,
}
unsafe extern "C" fn check(context: *mut c_void, bytes: usize) -> i32 {
    let c = &mut *(context as *mut Context);
    c.requests += 1;
    if c.cancel
        || std::env::var("O3DV_TEST_CANCEL_AFTER")
            .ok()
            .and_then(|s| s.parse::<f64>().ok())
            .is_some_and(|t| c.started.elapsed().as_secs_f64() > t)
    {
        return 3;
    }
    let limit = std::env::var("O3DV_TEST_DECODER_BUDGET")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(128 * 1024 * 1024);
    if bytes > limit {
        return 2;
    }
    0
}
unsafe extern "C" fn event(_: *mut c_void, data: *const u8, count: usize) {
    println!(
        "{}",
        String::from_utf8_lossy(std::slice::from_raw_parts(data, count))
    );
}
unsafe extern "C" fn snapshot(_: *mut c_void, output: *mut u64) {
    *output = 0;
    *output.add(1) = 0;
}
unsafe extern "C" fn layout(
    _: *mut c_void,
    _: *const u8,
    _: usize,
    _: *mut c_void,
    _: unsafe extern "C" fn(*mut c_void, i32, *const c_void, usize) -> i32,
) -> i32 {
    -1
}
fn main() {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: cad-stream drawing cache-directory");
        std::process::exit(2);
    }
    let source = CString::new(args[1].as_str()).unwrap();
    let directory = CString::new(args[2].as_str()).unwrap();
    let mut c = Context {
        started: Instant::now(),
        cancel: std::env::var_os("O3DV_TEST_CANCEL").is_some(),
        requests: 0,
    };
    let mut error = std::ptr::null_mut();
    let result = unsafe {
        o3dv_cad::o3dv_cad_convert(
            source.as_ptr(),
            directory.as_ptr(),
            check,
            event,
            snapshot,
            layout,
            &mut c as *mut _ as *mut c_void,
            128 * 1024 * 1024,
            &mut error,
        )
    };
    if result != 0 {
        unsafe {
            if !error.is_null() {
                eprintln!("CAD:{result} {}", CStr::from_ptr(error).to_string_lossy());
                o3dv_cad::o3dv_cad_free(error);
            }
        }
        let _ = std::fs::remove_dir_all(&args[2]);
        std::process::exit(1);
    }
    eprintln!(
        "checks:{} seconds:{:.3}",
        c.requests,
        c.started.elapsed().as_secs_f64()
    );
}
