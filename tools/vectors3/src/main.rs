//! Multi-block golden vectors (RFC 6330 4.3, 4.4): OTI, Partition[I,J], K_L, derived parameters (Z, N), and complete encoded
//! objects (every source and repair packet of every source block) plus decode scenarios with losses spread over the blocks.
//! Usage: cargo run --release -- <out_dir>      (default ../../tests/vectors3); formats in tests/vectors3/README.md
use raptorq::{
    Decoder, EncodingPacket, Encoder, ObjectTransmissionInformation, PayloadId, extended_source_block_symbols,
    partition,
};
use std::fmt::Write as _;
use std::fs;

struct Lcg(u32);
impl Lcg {
    fn next(&mut self) -> u32 {
        self.0 = self.0.wrapping_mul(1664525).wrapping_add(1013904223);
        self.0
    }
    fn byte(&mut self) -> u8 {
        (self.next() >> 24) as u8
    }
    fn below(&mut self, n: u32) -> u32 {
        (self.next() >> 8) % n
    }
}

fn join(v: &[u32]) -> String {
    v.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(" ")
}

/// (id, F, T, Z, N, Al): objects with ZL and ZS blocks, odd symbol sizes, sub-blocks, alignments
const OBJECTS: &[(u32, u64, u16, u8, u16, u8)] = &[
    (0, 360, 16, 4, 1, 4),   // Kt 23 -> Z 4: 3 x 6 + 1 x 5
    (1, 3000, 32, 3, 1, 8),  // Kt 94 -> 1 x 32 + 2 x 31
    (2, 1003, 5, 5, 1, 1),   // odd T: Kt 201 -> 1 x 41 + 4 x 40
    (3, 1010, 16, 3, 2, 4),  // Kt 64, N = 2 sub-blocks of 8 octets
    (4, 777, 32, 2, 3, 4),   // Kt 25 -> 13 + 12; N = 3: sub-symbols 12, 12, 8 octets
    (5, 2490, 24, 7, 5, 2),  // Al = 2: Kt 104 -> 6 x 15 + 1 x 14; N = 5: 6, 6, 4, 4, 4 octets
    (6, 2000, 8, 4, 1, 8),   // Kt 250 -> 2 x 63 + 2 x 62, K' = 64 padding
    (7, 85, 4, 3, 1, 4),     // Kt 22 -> 8 + 7 + 7, K < 10: every block is padded to K' = 10
    (8, 200, 20, 1, 1, 4),   // single block, same path
    (9, 1030, 16, 11, 4, 4), // Kt 65 -> 10 x 6 + 1 x 5, N = 4
    (10, 40, 8, 2, 1, 8),    // Kt 5 -> 3 + 2 (tiny blocks)
];

fn main() {
    let dir = std::env::args().nth(1).unwrap_or("../../tests/vectors3".into());
    fs::create_dir_all(&dir).unwrap();
    let (mut oti_s, mut pk_s, mut dec_s, mut part_s, mut kl_s, mut par_s) = (
        String::new(), String::new(), String::new(), String::new(), String::new(), String::new(),
    );

    // ---- Partition[I, J] -----------------------------------------------------------------------------------------------
    writeln!(part_s, "# I J IL IS JL JS   (raptorq::partition)").unwrap();
    let is: [u32; 14] = [1, 2, 7, 10, 23, 64, 94, 100, 201, 750, 1000, 4097, 56403, 56404];
    for &i in &is {
        for &j in &[1u32, 2, 3, 4, 5, 7, 8, 11, 16, 100, 255] {
            if j <= i {
                let (il, is_, jl, js) = partition(i, j);
                writeln!(part_s, "{} {} {} {} {} {}", i, j, il, is_, jl, js).unwrap();
            }
        }
    }

    // ---- K_L helper: largest Table 2 value K' <= x (via the crate's K' lookup) --------------------------------------------
    writeln!(kl_s, "# x kmax   largest K' of Table 2 with K' <= x (0 below 10)").unwrap();
    let xs: [u32; 40] = [
        9, 10, 11, 12, 13, 17, 18, 19, 20, 21, 25, 26, 27, 100, 101, 500, 999, 1000, 1001, 4000, 4001, 10000, 10001, 20000, 30000,
        40000, 50000, 56000, 56402, 56403, 56404, 100000, 65535, 1024, 2048, 8192, 16384, 32768, 12000, 45000,
    ];
    for &x in &xs {
        let mut y = x.min(56403);
        let kmax = loop {
            if y < 10 {
                break 0;
            }
            if extended_source_block_symbols(y) == y {
                break y;
            }
            y -= 1;
        };
        writeln!(kl_s, "{} {}", x, kmax).unwrap();
    }

    // ---- parameters derived by RFC 4.3 (the crate's generate_encoding_parameters) -------------------------------------
    writeln!(par_s, "# F P' Al SS WS  ->  T Z N Al   (generate_encoding_parameters; Z = 0: the true Z exceeds 255 (the crate truncates it to u8): must be rejected)").unwrap();
    let kmax = |x: u64| -> u64 {
        let mut y = x.min(56403) as u32;
        loop {
            if y < 10 {
                return 0;
            }
            if extended_source_block_symbols(y) == y {
                return y as u64;
            }
            y -= 1;
        }
    };
    let fs_: [u64; 12] = [1, 1000, 12345, 65536, 1_000_000, 7_654_321, 50_000_000, 123_456_789, 1_000_000_000, 3_000_000_000, 4_294_967_295, 700];
    let mtus: [u16; 9] = [8, 16, 32, 63, 64, 100, 512, 1400, 1472];
    let wss: [u64; 7] = [10 * 1024 * 1024, 1 << 20, 1 << 18, 1 << 16, 1 << 14, 5000, 100_000_000];
    std::panic::set_hook(Box::new(|_| {}));
    let (mut npar, mut nrej) = (0, 0);
    for &f in &fs_ {
        for &m in &mtus {
            for &ws in &wss {
                let r = std::panic::catch_unwind(|| ObjectTransmissionInformation::generate_encoding_parameters(f, m, ws));
                if let Ok(c) = r {
                    let al = c.symbol_alignment() as u64;
                    let ss = if m >= 64 { 8u64 } else { 1 };
                    let t = c.symbol_size() as u64;
                    let kt = f.div_ceil(t);
                    let n_max = t / (ss * al);
                    let kl_max = kmax(ws / (al * t.div_ceil(al * n_max)));
                    let true_z = kt.div_ceil(kl_max);
                    if true_z > 255 {
                        writeln!(par_s, "{} {} {} {} {}  {} 0 0 0", f, m, al, ss, ws, t).unwrap();
                        nrej += 1;
                    } else {
                        assert_eq!(true_z, c.source_blocks() as u64);
                        writeln!(par_s, "{} {} {} {} {}  {} {} {} {}", f, m, al, ss, ws, c.symbol_size(), c.source_blocks(), c.sub_blocks(), c.symbol_alignment()).unwrap();
                        npar += 1;
                    }
                }
            }
        }
    }
    let _ = std::panic::take_hook();
    eprintln!("{} derived-parameter cases, {} rejected (Z > 255)", npar, nrej);

    // ---- objects -------------------------------------------------------------------------------------------------------------
    writeln!(oti_s, "# id seed F T Z N Al  Kt KL KS ZL ZS  <12 serialized OTI octets>").unwrap();
    writeln!(pk_s, "# id sbn esi b0..b{{T-1}}   every source packet then R repair packets, block by block").unwrap();
    writeln!(dec_s, "# id kind nrecv  sbn esi sbn esi ..   kind 0 same losses in every block, 1 different per block, 2 uniform + shuffled arrival").unwrap();
    for &(id, f, t, z, n, al) in OBJECTS {
        let seed = id * 65536 + f as u32;
        let mut rng = Lcg(seed);
        let data: Vec<u8> = (0..f).map(|_| rng.byte()).collect();
        let config = ObjectTransmissionInformation::new(f, t, z, n, al);
        let kt = f.div_ceil(t as u64) as u32;
        let (kl, ks, zl, zs) = partition(kt, z as u32);
        let ser: Vec<u32> = config.serialize().iter().map(|&b| b as u32).collect();
        writeln!(oti_s, "{} {} {} {} {} {} {}  {} {} {} {} {}  {}", id, seed, f, t, z, n, al, kt, kl, ks, zl, zs, join(&ser)).unwrap();

        let encoder = Encoder::new(&data, config);
        let mut all: Vec<(u32, u32, Vec<u8>)> = vec![]; // (sbn, esi, payload), in the order of the file
        let r_of = |k: u32| k / 3 + 12;
        for (sbn, be) in encoder.get_block_encoders().iter().enumerate() {
            let k = if (sbn as u32) < zl { kl } else { ks };
            let mut ps = be.source_packets();
            ps.extend(be.repair_packets(0, r_of(k)));
            for p in ps {
                assert_eq!(p.payload_id().source_block_number() as usize, sbn);
                all.push((sbn as u32, p.payload_id().encoding_symbol_id(), p.data().to_vec()));
            }
        }
        for (sbn, esi, d) in &all {
            assert_eq!(d.len(), t as usize);
            write!(pk_s, "{} {} {} ", id, sbn, esi).unwrap();
            writeln!(pk_s, "{}", d.iter().map(|b| b.to_string()).collect::<Vec<_>>().join(" ")).unwrap();
        }

        // decode scenarios
        let mut lrng = Lcg(seed ^ 0x5A5A_0000);
        for kind in 0..3u32 {
            // per block: the ESI list received
            let mut recv: Vec<(u32, u32)> = vec![];
            let mut extra = 0u32; // extra received symbols per block, grown until the reference decoder succeeds
            loop {
                recv.clear();
                for sbn in 0..(zl + zs) {
                    let k = if sbn < zl { kl } else { ks };
                    let modulus = if kind == 1 { 3 + sbn % 3 } else { 3 };
                    let phase = if kind == 1 { sbn % modulus } else { 1 };
                    let shift = if kind == 1 { sbn % 3 } else { 0 };
                    let src: Vec<u32> = (0..k).filter(|i| i % modulus != phase).collect();
                    let need = k as usize + (if kind == 1 { sbn as usize % 2 } else { 0 }) + extra as usize;
                    let mut es = src;
                    let mut e = k + shift;
                    while es.len() < need {
                        assert!(e < k + r_of(k), "not enough repair symbols");
                        es.push(e);
                        e += 1;
                    }
                    // arrival order: kind 0/1 ascending ESI; kind 2 shuffled below
                    for x in es {
                        recv.push((sbn, x));
                    }
                }
                if kind == 2 {
                    for i in (1..recv.len()).rev() {
                        let j = lrng.below(i as u32 + 1) as usize;
                        recv.swap(i, j);
                    }
                }
                // reference decoder
                let mut dec = Decoder::new(config);
                let mut out = None;
                for &(sbn, esi) in &recv {
                    let d = &all.iter().find(|(s, e, _)| *s == sbn && *e == esi).unwrap().2;
                    out = dec.decode(EncodingPacket::new(PayloadId::new(sbn as u8, esi), d.clone()));
                }
                match out {
                    Some(o) => {
                        assert_eq!(o, data, "reference decoder returned wrong data");
                        break;
                    }
                    None => {
                        extra += 1;
                        assert!(extra < 6, "reference decoder keeps failing");
                    }
                }
            }
            let flat: Vec<u32> = recv.iter().flat_map(|&(s, e)| [s, e]).collect();
            writeln!(dec_s, "{} {} {}  {}", id, kind, recv.len(), join(&flat)).unwrap();
        }
    }
    for (name, s) in [("oti.txt", &oti_s), ("packets.txt", &pk_s), ("decode.txt", &dec_s), ("partition.txt", &part_s), ("kmax.txt", &kl_s), ("params.txt", &par_s)] {
        fs::write(format!("{}/{}", dir, name), s).unwrap();
        eprintln!("{}: {} bytes", name, s.len());
    }
}
