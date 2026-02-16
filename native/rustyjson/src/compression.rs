use flate2::write::GzEncoder;
use flate2::Compression;
use rustler::NifUnitEnum;
use std::io::{BufWriter, Error, Write};

#[derive(NifUnitEnum)]
pub enum Algs {
    None,
    Gzip,
}

/// Writer that can be converted to the final output bytes
pub enum Writer {
    Plain(Vec<u8>),
    Gzip(BufWriter<GzEncoder<Vec<u8>>>),
}

impl Write for Writer {
    fn write(&mut self, buf: &[u8]) -> Result<usize, Error> {
        match self {
            Writer::Plain(v) => v.write(buf),
            Writer::Gzip(w) => w.write(buf),
        }
    }

    fn flush(&mut self) -> Result<(), Error> {
        match self {
            Writer::Plain(v) => v.flush(),
            Writer::Gzip(w) => w.flush(),
        }
    }

    fn write_all(&mut self, buf: &[u8]) -> Result<(), Error> {
        match self {
            Writer::Plain(v) => v.write_all(buf),
            Writer::Gzip(w) => w.write_all(buf),
        }
    }
}

impl Writer {
    /// Get the final output buffer, consuming self
    pub fn get_buf(self) -> Result<Vec<u8>, Error> {
        match self {
            Writer::Plain(v) => Ok(v),
            Writer::Gzip(mut w) => {
                w.flush()?;
                let encoder = w.into_inner().map_err(|e| e.into_error())?;
                let vec = encoder.finish()?;
                Ok(vec)
            }
        }
    }
}

/// BufWriter capacity for the gzip output stream.
const GZIP_BUF_CAPACITY: usize = 10_240;

/// Initial capacity for the compressed output Vec.
const GZIP_OUTPUT_CAPACITY: usize = 4096;

/// Initial capacity for the plain (uncompressed) output Vec.
const PLAIN_OUTPUT_CAPACITY: usize = 4096;

pub fn get_writer(opts: Option<(Algs, Option<u32>)>) -> Writer {
    match opts {
        Some((Algs::Gzip, None)) => Writer::Gzip(BufWriter::with_capacity(
            GZIP_BUF_CAPACITY,
            GzEncoder::new(Vec::with_capacity(GZIP_OUTPUT_CAPACITY), Compression::default()),
        )),
        Some((Algs::Gzip, Some(lv))) => Writer::Gzip(BufWriter::with_capacity(
            GZIP_BUF_CAPACITY,
            GzEncoder::new(Vec::with_capacity(GZIP_OUTPUT_CAPACITY), Compression::new(lv)),
        )),
        _ => Writer::Plain(Vec::with_capacity(PLAIN_OUTPUT_CAPACITY)),
    }
}
