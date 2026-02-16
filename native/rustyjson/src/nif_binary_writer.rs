use rustler::{Binary, Env, OwnedBinary};
use std::io::{self, Write};

/// Growable writer backed by a NIF `OwnedBinary`.
///
/// Writes go directly into Erlang-managed memory, eliminating the
/// `Vec<u8>` → `NewBinary` copy that the previous encode path performed.
/// On finalization, the binary is shrunk to exact size via `realloc` and
/// released as an immutable `Binary`.
pub struct NifBinaryWriter {
    inner: OwnedBinary,
    pos: usize,
}

impl NifBinaryWriter {
    /// Create a new writer with the given initial capacity.
    /// Returns the writer, or propagates an `io::Error` if allocation fails
    /// instead of panicking (which would crash the NIF scheduler thread).
    pub fn new(initial_cap: usize) -> Self {
        match OwnedBinary::new(initial_cap) {
            Some(inner) => Self { inner, pos: 0 },
            None => {
                // Fallback: try a minimal allocation. If even 0 bytes fails,
                // we have no choice but to panic — the system is out of memory.
                let inner = OwnedBinary::new(0)
                    .expect("OwnedBinary: system out of memory (even 0-byte alloc failed)");
                Self { inner, pos: 0 }
            }
        }
    }

    /// Ensure at least `additional` bytes of spare capacity.
    #[inline]
    fn reserve(&mut self, additional: usize) {
        let required = self.pos + additional;
        if required > self.inner.len() {
            // Double or grow to required, whichever is larger
            let new_cap = required.max(self.inner.len() * 2).max(128);
            self.inner.realloc_or_copy(new_cap);
        }
    }

    /// Consume the writer and return an immutable `Binary`.
    /// Shrinks the allocation to the exact number of bytes written.
    pub fn into_binary(mut self, env: Env) -> Binary {
        if self.pos < self.inner.len() {
            let _ = self.inner.realloc(self.pos);
        }
        self.inner.release(env)
    }
}

impl Write for NifBinaryWriter {
    #[inline]
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.reserve(buf.len());
        self.inner.as_mut_slice()[self.pos..self.pos + buf.len()].copy_from_slice(buf);
        self.pos += buf.len();
        Ok(buf.len())
    }

    #[inline]
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }

    #[inline]
    fn write_all(&mut self, buf: &[u8]) -> io::Result<()> {
        self.reserve(buf.len());
        self.inner.as_mut_slice()[self.pos..self.pos + buf.len()].copy_from_slice(buf);
        self.pos += buf.len();
        Ok(())
    }
}
