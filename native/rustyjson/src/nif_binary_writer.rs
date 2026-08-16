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
    pub fn new(initial_cap: usize) -> io::Result<Self> {
        let inner = OwnedBinary::new(initial_cap).ok_or(io::ErrorKind::OutOfMemory)?;
        Ok(Self { inner, pos: 0 })
    }

    /// Ensure at least `additional` bytes of spare capacity.
    #[inline]
    fn reserve(&mut self, additional: usize) -> io::Result<usize> {
        let required = self.pos.checked_add(additional).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "NIF binary capacity overflow")
        })?;

        if required > self.inner.len() {
            let doubled = self.inner.len().saturating_mul(2);
            let new_cap = required.max(doubled).max(MIN_GROW_CAPACITY);

            if !self.inner.realloc(new_cap) {
                let mut replacement =
                    OwnedBinary::new(new_cap).ok_or(io::ErrorKind::OutOfMemory)?;
                replacement.as_mut_slice()[..self.pos]
                    .copy_from_slice(&self.inner.as_slice()[..self.pos]);
                self.inner = replacement;
            }
        }

        Ok(required)
    }

    /// Consume the writer and return an immutable `Binary`.
    /// Shrinks the allocation to the exact number of bytes written.
    pub fn into_binary(mut self, env: Env) -> io::Result<Binary> {
        if self.pos < self.inner.len() && !self.inner.realloc(self.pos) {
            let mut exact = OwnedBinary::new(self.pos).ok_or(io::ErrorKind::OutOfMemory)?;
            exact
                .as_mut_slice()
                .copy_from_slice(&self.inner.as_slice()[..self.pos]);
            self.inner = exact;
        }

        Ok(self.inner.release(env))
    }
}

impl Write for NifBinaryWriter {
    #[inline]
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let end = self.reserve(buf.len())?;
        self.inner.as_mut_slice()[self.pos..end].copy_from_slice(buf);
        self.pos = end;
        Ok(buf.len())
    }

    #[inline]
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }

    #[inline]
    fn write_all(&mut self, buf: &[u8]) -> io::Result<()> {
        let end = self.reserve(buf.len())?;
        self.inner.as_mut_slice()[self.pos..end].copy_from_slice(buf);
        self.pos = end;
        Ok(())
    }
}
