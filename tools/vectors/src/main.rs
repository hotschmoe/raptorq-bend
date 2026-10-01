//! Golden-vector generator for the Bend RaptorQ implementation.
//! Usage: cargo run --release -- <out_dir>      (default ../../tests/vectors)
//! See tests/vectors/README.md for the file formats.
use raptorq::{
    ObjectTransmissionInformation, SourceBlockDecoder, SourceBlockEncoder,
    extended_source_block_symbols,
};
use std::fmt::Write as _;
use std::fs;

/// repair symbols emitted per case (ESIs K..K+R-1)
fn repair_count(k: u32) -> u32 {
    std::cmp::max(20, k / 4 + 3)
}

/// Numerical-Recipes LCG on u32. byte = high 8 bits of the NEW state.
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

fn seed_data(k: u32, t: u32) -> u32 {
    k * 65536 + t
}
fn seed_loss(k: u32, t: u32) -> u32 {
    seed_data(k, t) ^ 0x5A5A_0000
}

fn line(out: &mut String, head: &[u32], bytes: &[u8]) {
    for h in head {
        write!(out, "{} ", h).unwrap();
    }
    let v: Vec<String> = bytes.iter().map(|b| b.to_string()).collect();
    out.push_str(&v.join(" "));
    out.push('\n');
}

/// choose `n` distinct values from `pool`, returned sorted
fn choose(rng: &mut Lcg, mut pool: Vec<u32>, n: usize) -> Vec<u32> {
    for i in 0..n {
        let j = i + rng.below((pool.len() - i) as u32) as usize;
        pool.swap(i, j);
    }
    let mut r = pool[..n].to_vec();
    r.sort();
    r
}

fn main() {
    let dir = std::env::args().nth(1).unwrap_or("../../tests/vectors".into());
    fs::create_dir_all(&dir).unwrap();

    // (K, T) cases
    let mut cases: Vec<(u32, u32)> = vec![];
    for &k in &[1u32, 2, 10, 26] {
        for &t in &[16u32, 32, 5] {
            cases.push((k, t));
        }
    }
    for &k in &[50u32, 100] {
        for &t in &[16u32, 5] {
            cases.push((k, t));
        }
    }
    for &k in &[500u32, 1000] {
        cases.push((k, 4));
    }

    let (mut src, mut enc, mut inter, mut dec, mut par) = (
        String::new(), String::new(), String::new(), String::new(), String::new(),
    );
    let mut ks: Vec<u32> = cases.iter().map(|c| c.0).collect();
    ks.dedup();
    let mut case_id = 0;

    for &k in &ks {
        let kp = extended_source_block_symbols(k);
        // SAFETY of reuse: crate's table accessors are pub in vendor copy only via lib re-export
        let (j, s, h, w) = params(k);
        let l = kp + s + h;
        let p = l - w;
        writeln!(par, "{} {} {} {} {} {} {} {} {}", k, kp, j, s, h, w, l, p, p1(p)).unwrap();
    }

    for &(k, t) in &cases {
        let mut rng = Lcg(seed_data(k, t));
        let data: Vec<u8> = (0..k * t).map(|_| rng.byte()).collect();
        let repair = repair_count(k);
        let config = ObjectTransmissionInformation::new((k * t) as u64, t as u16, 1, 1, 1);
        let encoder = SourceBlockEncoder::new(0, &config, &data);

        for i in 0..k as usize {
            line(&mut src, &[k, t, i as u32], &data[i * t as usize..(i + 1) * t as usize]);
        }

        // encoded packets: source then repair
        let mut packets = encoder.source_packets();
        packets.extend(encoder.repair_packets(0, repair));
        for (i, p) in packets.iter().enumerate() {
            assert_eq!(p.payload_id().encoding_symbol_id(), i as u32);
            if (i as u32) < k {
                // RFC 6330 4.4.2 / 5.3.1: systematic symbols equal source data
                assert_eq!(p.data(), &data[i * t as usize..(i + 1) * t as usize]);
            }
            line(&mut enc, &[k, t, i as u32], p.data());
        }

        for (j, sym) in encoder.intermediate_symbols_shim().iter().enumerate() {
            line(&mut inter, &[k, t, j as u32], sym);
        }

        // decode cases
        let mut lrng = Lcg(seed_loss(k, t));
        let all_src: Vec<u32> = (0..k).collect();
        let all_rep: Vec<u32> = (k..k + repair).collect();
        let mut specs: Vec<(&str, usize, usize)> = vec![]; // (kind, n_src_lost, n_recv)
        let lost = std::cmp::max(1, k / 4) as usize;
        for extra in 0..3usize {
            specs.push(("randloss", lost, k as usize + extra));
        }
        specs.push(("nodrop", 0, k as usize));
        if k + 2 <= repair {
            specs.push(("allrepair", k as usize, k as usize + 1));
            specs.push(("allrepair", k as usize, k as usize + 2));
        }
        for (kind, lost, n) in specs {
            let nsrc = k as usize - lost;
            let mut recv = choose(&mut lrng, all_src.clone(), nsrc);
            recv.extend(choose(&mut lrng, all_rep.clone(), n - nsrc));
            let pk: Vec<_> = recv.iter().map(|&e| packets[e as usize].clone()).collect();
            let mut d = SourceBlockDecoder::new(0, &config, (k * t) as u64);
            let res = d.decode(pk);
            let ok = match &res {
                Some(r) => {
                    assert_eq!(r, &data, "decoder returned wrong data");
                    1
                }
                None => 0,
            };
            write!(dec, "{} {} {} {} {} {} {}", case_id, k, t, n, ok, nsrc, kind_code(kind)).unwrap();
            for e in &recv {
                write!(dec, " {}", e).unwrap();
            }
            writeln!(dec, "   # {}", kind).unwrap();
            case_id += 1;
        }
    }

    let w = |name: &str, hdr: &str, body: &str| {
        fs::write(format!("{}/{}", dir, name), format!("{}{}", hdr, body)).unwrap();
    };
    let common = "# GENERATED by tools/vectors (cargo run --release). Do not edit. See README.md.\n# Lines starting with '#' are comments. All fields are decimal, whitespace separated.\n";
    w("params.txt", &format!("{common}# RFC 6330 5.6 parameters. One line per K:\n#   K Kprime J(K') S H W L P P1\n# (L=K'+S+H, P=L-W, P1=smallest prime >= P)\n"), &par);
    w("source.txt", &format!("{common}# Source symbols. One line per source symbol:\n#   K T i b0 b1 ... b{{T-1}}\n# Data for (K,T): x = K*65536+T (u32); for each of K*T bytes in order:\n#   x = (x*1664525 + 1013904223) mod 2^32 ; byte = x >> 24.\n# Symbol i is bytes [i*T, (i+1)*T) of the stream.\n"), &src);
    w("encoded.txt", &format!("{common}# Encoding symbols for ESI 0..K+R-1, R=max(20,K/4+3) (ESI<K source == source.txt, ESI>=K repair, RFC 6330 5.3.4/5.3.5). One line per symbol:\n#   K T esi b0 ... b{{T-1}}\n"), &enc);
    w("intermediate.txt", &format!("{common}# Intermediate symbols C[0..L-1] (RFC 6330 5.3.3.4 / 5.4.2), L=K'+S+H from params.txt. One line per symbol:\n#   K T idx b0 ... b{{T-1}}\n"), &inter);
    w("decode.txt", &format!("{common}# Decode cases. One line per case:\n#   id K T nrecv ok nsrc kind e_0 ... e_{{nrecv-1}}   # kind name\n# e_i: received ESIs (sorted, distinct), symbol data from encoded.txt.\n# ok=1: decoding succeeds and the recovered K*T bytes equal the source of (K,T) in source.txt.\n# ok=0: the reference decoder reports failure (matrix singular for this ESI set); a correct decoder must also fail.\n# nsrc: how many of the received ESIs are source ESIs (<K). kind code: 0=randloss 1=nodrop 2=allrepair.\n"), &dec);
    eprintln!("cases: {}, decode cases: {}", cases.len(), case_id);
}

fn kind_code(k: &str) -> u32 {
    match k {
        "randloss" => 0,
        "nodrop" => 1,
        _ => 2,
    }
}

fn params(k: u32) -> (u32, u32, u32, u32) {
    (
        raptorq::systematic_index(k),
        raptorq::num_ldpc_symbols(k),
        raptorq::num_hdpc_symbols(k),
        raptorq::num_lt_symbols(k),
    )
}
fn p1(p: u32) -> u32 {
    let mut n = p;
    loop {
        if n >= 2 && (2..n).take_while(|d| d * d <= n).all(|d| n % d != 0) {
            return n;
        }
        n += 1;
    }
}
