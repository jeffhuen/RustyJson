use rustler::{Binary, Env, OwnedBinary};
use std::io::{self, Write};

/// Minimum capacity for the backing binary after a growth event.
const MIN_GROW_CAPACITY: usize = 128;

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
    /// Panics if the initial allocation fails (extremely unlikely).
    pub fn new(initial_cap: usize) -> Self {
        let inner = OwnedBinary::new(initial_cap).expect("OwnedBinary allocation failed");
        Self { inner, pos: 0 }
    }

    /// Ensure at least `additional` bytes of spare capacity.
    #[inline]
    fn reserve(&mut self, additional: usize) {
        let required = self.pos + additional;
        if required > self.inner.len() {
            // Double or grow to required, whichever is larger
            let new_cap = required.max(self.inner.len() * 2).max(MIN_GROW_CAPACITY);
            self.inner.realloc_or_copy(new_cap);
        }
    }

    /// Consume the writer and return an immutable `Binary`.
    /// Shrinks the allocation to the exact number of bytes written.
    pub fn into_binary(mut self, env: Env) -> Binary {
        if self.pos < self.inner.len() {
            // Best-effort shrink; if realloc fails we keep the oversized buffer.
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
