// App additions to the MPL-2.0 acadrust source copy. No global allocator override.
use std::{cell::Cell, ffi::c_void};
pub type Check = unsafe extern "C" fn(*mut c_void, usize) -> i32;
thread_local! {
    static ACTIVE: Cell<Option<(Check,*mut c_void)>> = const {Cell::new(None)};
    static FAILED: Cell<i32> = const {Cell::new(0)};
    static TICKS: Cell<u32> = const {Cell::new(0)};
}
#[derive(Debug)] pub struct Stop(pub i32);
pub struct Scope(Option<(Check,*mut c_void)>);
impl Scope {
    pub fn enter(check:Check, context:*mut c_void)->Self {
        FAILED.with(|f|f.set(0)); TICKS.with(|t|t.set(0));
        Self(ACTIVE.with(|a|a.replace(Some((check,context)))))
    }
}
impl Drop for Scope {fn drop(&mut self){ACTIVE.with(|a|a.set(self.0));FAILED.with(|f|f.set(0));}}
pub fn failure()->i32 {FAILED.with(Cell::get)}
pub fn checkpoint(bytes:usize) {
    if let Some((callback,context))=ACTIVE.with(Cell::get) {
        let previous=failure();
        let result=if previous!=0 {previous}else{unsafe{callback(context,bytes)}};
        if result!=0 {FAILED.with(|f|f.set(result));std::panic::panic_any(Stop(result));}
    }
}
pub fn tick(){TICKS.with(|t|{let n=t.get().wrapping_add(1);t.set(n);if n&255==0 {checkpoint(0);}});}
pub fn capacity<T>(length:usize)->Vec<T> {
    let bytes=length.checked_mul(std::mem::size_of::<T>()).unwrap_or(usize::MAX);
    checkpoint(bytes);
    let mut value=Vec::new();
    if value.try_reserve_exact(length).is_err(){FAILED.with(|f|f.set(2));std::panic::panic_any(Stop(2));}
    value
}
pub fn repeat<T:Clone>(value:T,length:usize)->Vec<T>{let mut result=capacity(length);result.resize(length,value);result}
pub fn check_slice<T>(_:&[T],length:usize){checkpoint(length.saturating_mul(std::mem::size_of::<T>()));}
pub fn string(length:usize)->String{checkpoint(length);let mut value=String::new();if value.try_reserve_exact(length).is_err(){std::panic::panic_any(Stop(2));}value}
pub fn hashmap<K:std::hash::Hash+Eq,V>(length:usize)->std::collections::HashMap<K,V>{
    checkpoint(length.saturating_mul(std::mem::size_of::<(K,V)>().saturating_add(16)).saturating_mul(2));
    let mut value=std::collections::HashMap::new();if value.try_reserve(length).is_err(){std::panic::panic_any(Stop(2));}value
}
pub fn hashset<K:std::hash::Hash+Eq>(length:usize)->std::collections::HashSet<K>{
    checkpoint(length.saturating_mul(std::mem::size_of::<K>().saturating_add(16)).saturating_mul(2));
    let mut value=std::collections::HashSet::new();if value.try_reserve(length).is_err(){std::panic::panic_any(Stop(2));}value
}
pub fn foldmap<K:std::hash::Hash+Eq,V>(length:usize)->foldhash::HashMap<K,V>{
    checkpoint(length.saturating_mul(std::mem::size_of::<(K,V)>().saturating_add(16)).saturating_mul(2));
    let mut value=foldhash::HashMap::with_hasher(Default::default());if value.try_reserve(length).is_err(){std::panic::panic_any(Stop(2));}value
}
pub fn foldset<K:std::hash::Hash+Eq>(length:usize)->foldhash::HashSet<K>{
    checkpoint(length.saturating_mul(std::mem::size_of::<K>().saturating_add(16)).saturating_mul(2));
    let mut value=foldhash::HashSet::with_hasher(Default::default());if value.try_reserve(length).is_err(){std::panic::panic_any(Stop(2));}value
}
pub fn resize<T:Clone>(target:&mut Vec<T>,length:usize,value:T){
    if length>target.capacity(){checkpoint(length.saturating_mul(std::mem::size_of::<T>()));
        if target.try_reserve_exact(length.saturating_sub(target.len())).is_err(){std::panic::panic_any(Stop(2));}}
    target.resize(length,value);
}
#[macro_export]
macro_rules! guarded_vec {
    ($value:expr;$length:expr)=>{$crate::o3dv_guard::repeat($value,$length)};
    ($($value:expr),* $(,)?)=>{std::vec![$($value),*]};
}
#[macro_export]
macro_rules! guarded_resize {
    ($target:expr,$length:expr,$value:expr)=>{{let n=$length;
        if n>$target.capacity(){
            $crate::o3dv_guard::check_slice($target.as_slice(),n);
            if $target.try_reserve_exact(n.saturating_sub($target.len())).is_err(){std::panic::panic_any($crate::o3dv_guard::Stop(2));}
        }
        $target.resize(n,$value);
    }};
}
