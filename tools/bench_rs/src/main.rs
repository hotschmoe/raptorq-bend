// Reference timings of the cberner/raptorq crate (vendored copy, RFC 6330), single source block, same workload as
// tools/bench/bench.bend:  bench_rs <K> <T> <N>
//   setup_cold_ms : SourceBlockEncoder::new in a fresh process (includes generating the encoding plan = the solve)
//   setup_warm_ms : the same call again (the crate caches the plan per K: only replays it on the new data)
//   repair_ms     : N repair symbols;  decode_ms: SourceBlockDecoder::decode of K symbols (every 8th ESI a source symbol)
// Single-threaded.  One line of output; run one process per (K,T) so the plan cache is cold.
use raptorq::{
    EncodingPacket, ObjectTransmissionInformation, PayloadId, SourceBlockDecoder, SourceBlockEncoder,
};
use std::time::Instant;

fn lcg(x: u32) -> u32 {
    x.wrapping_mul(1664525).wrapping_add(1013904223)
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let k: usize = a[1].parse().unwrap();
    let t: usize = a[2].parse().unwrap();
    let n: u32 = a[3].parse().unwrap();

    let mut x = (k * 65536 + t) as u32;
    let data: Vec<u8> = (0..k * t)
        .map(|_| {
            x = lcg(x);
            (x >> 24) as u8
        })
        .collect();
    let cfg = ObjectTransmissionInformation::new(data.len() as u64, t as u16, 1, 1, 1);

    let t0 = Instant::now();
    let enc = SourceBlockEncoder::new(0, &cfg, &data);
    let setup_cold = t0.elapsed();
    let t0 = Instant::now();
    let enc2 = SourceBlockEncoder::new(0, &cfg, &data);
    let setup_warm = t0.elapsed();
    drop(enc2);

    let t0 = Instant::now();
    let repair = enc.repair_packets(0, n);
    let repair_t = t0.elapsed();
    let mut chk = 0u64;
    for p in &repair {
        chk = chk.wrapping_mul(31).wrapping_add(p.data()[0] as u64);
    }

    // decode input: K packets, every 8th ESI is a source symbol, the others repair symbols (ESI K + i)
    let src = enc.source_packets();
    let rep = enc.repair_packets(0, k as u32);
    let mut pk: Vec<EncodingPacket> = Vec::with_capacity(k);
    for i in 0..k {
        if i % 8 == 0 {
            pk.push(src[i].clone());
        } else {
            let (_, d) = rep[i].clone().split();
            pk.push(EncodingPacket::new(PayloadId::new(0, (k + i) as u32), d));
        }
    }
    let mut dec = SourceBlockDecoder::new(0, &cfg, data.len() as u64);
    let t0 = Instant::now();
    let out = dec.decode(pk);
    let dec_t = t0.elapsed();
    let ok = out.as_deref() == Some(&data[..]);

    println!(
        "RUST K={} T={} N={} setup_cold_ms={:.1} setup_warm_ms={:.1} repair_ms={:.1} decode_ms={:.1} ok={} chk={}",
        k,
        t,
        n,
        setup_cold.as_secs_f64() * 1e3,
        setup_warm.as_secs_f64() * 1e3,
        repair_t.as_secs_f64() * 1e3,
        dec_t.as_secs_f64() * 1e3,
        ok as u32,
        chk
    );
}
