//! OS file-lock and directory-sync glue for exact-product cache publication.

use fs2::FileExt;
use rustler::{Encoder, Env, ResourceArc, Term};
use std::fs::{File, OpenOptions};
use std::io::ErrorKind;
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
        busy,
        error
    }
}

pub struct CacheLockResource {
    file: Mutex<Option<File>>,
}

#[rustler::resource_impl]
impl rustler::Resource for CacheLockResource {}

#[rustler::nif(schedule = "DirtyIo")]
pub fn data_cache_lock_try<'a>(env: Env<'a>, path: String) -> Term<'a> {
    let opened = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path);
    let file = match opened {
        Ok(file) => file,
        Err(_) => return (atoms::error(), "open").encode(env),
    };
    match file.try_lock_exclusive() {
        Ok(()) => (
            atoms::ok(),
            ResourceArc::new(CacheLockResource {
                file: Mutex::new(Some(file)),
            }),
        )
            .encode(env),
        Err(error) if error.kind() == ErrorKind::WouldBlock => atoms::busy().encode(env),
        Err(_) => (atoms::error(), "lock").encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn data_cache_lock_release<'a>(env: Env<'a>, lock: ResourceArc<CacheLockResource>) -> Term<'a> {
    let mut guard = match lock.file.lock() {
        Ok(guard) => guard,
        Err(_) => return (atoms::error(), "poisoned").encode(env),
    };
    if let Some(file) = guard.take() {
        if FileExt::unlock(&file).is_err() {
            return (atoms::error(), "unlock").encode(env);
        }
    }
    atoms::ok().encode(env)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn data_cache_sync_directory<'a>(env: Env<'a>, path: String) -> Term<'a> {
    match File::open(path).and_then(|directory| directory.sync_all()) {
        Ok(()) => atoms::ok().encode(env),
        Err(_) => (atoms::error(), "sync_directory").encode(env),
    }
}
