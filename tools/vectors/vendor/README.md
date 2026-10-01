`raptorq/` is a COPY of ref/raptorq-rs (cberner/raptorq 2.0.1, Apache-2.0) with src/python.rs
and dev-dependencies removed and ONE addition: `SourceBlockEncoder::intermediate_symbols_shim()`
(in src/encoder.rs) which exposes the intermediate symbols. No algorithmic change.
(also lib.rs re-exports systematic_constants accessors)
