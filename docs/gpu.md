# Would a GPU target help? (Mali-G720 / OpenCL study)

Date: 2026-10-02. Research only: nothing in `src/` was touched. Numbers marked "measured" come from throw-away micro-benchmarks run
on this box (CIX P1 / Sky1, Mali-G720-Immortalis MC10, 31 GB unified LPDDR); the scripts were not kept in the repo. Numbers marked
"estimate" are reasoning, not measurements.

## Recommendation

1. **Do not build a Mali backend for the Bend compiler for this project.** It is 3-5 person-weeks for a prototype and 8-12 for
   something that passes Bend's own benchmark suite, and even a perfect backend would not make RaptorQ faster: the GPU-suitable
   phase (repair generation) is memory-bound, already takes 1 ms on one NEON core when written in C, and the phases that cost time
   (pivoting, elimination logs, tail Gauss-Jordan) are sequential.
2. **The thing that would help is not the GPU but getting symbols out of Bend's 24-40 byte-per-word trees.** Do it as a *foreign
   C import* (Bend effect, `.c` + `.js` twin), on the CPU with NEON, first. It is feasible without touching the compiler. Expected:
   repair generation 130 ms -> ~10 ms (tree rebuild dominated) or ~1 ms if the consumer takes bytes; plan replay (needs the
   not-yet-written operation log) removes the T-dependent part of setup/decode (4.1 s -> ~1 s at K=10000, T=1024).
3. **An OpenCL variant of that foreign import is optional and low value.** On this SoC it ties a single NEON core at best and loses
   to 8 cores (measured, below). Only worth it as a later experiment (bulk offload of N >= ~10^4 repair symbols with T >= 4096),
   and it needs no compiler work either (dlopen libOpenCL from the effect).
4. Skip: GPU for the solver, GPU for decode, GPU for K/T below the break-evens in section 6.

Ordered next steps are at the end.

## 1. What this machine has (checked, nothing installed)

| Item | Finding |
|---|---|
| SoC / GPU | CIX P1 CP8180 (Cortex-A520 x4 part 0xd80, A720 x8 part 0xd81; L2 4 MiB total, L3 12 MiB). `/sys/class/misc/mali0/device/gpuinfo`: "Mali-G720-Immortalis 10 cores r0p0 0x0C080700" (Arm Valhall 5th gen, CSF firmware `mali_csffw.bin`). `/dev/mali0` is the proprietary kbase driver; devfreq nodes top out at 1.0-1.2 GHz (which one is the GPU was not confirmed). `power_policy` = coarse_demand, so first launches may run at low clock. |
| OpenCL | **Works.** `/opt/cixgpu-pro/lib/aarch64-linux-gnu/libOpenCL.so.1` over `libmali.so.0.53.0` (r53p0). Platform "ARM Platform", FULL_PROFILE, **OpenCL 3.0**, OpenCL C 3.0. The Debian `/lib/aarch64-linux-gnu/libOpenCL.so.1` is a bare ICD loader with no platforms (clGetPlatformIDs = -1001) because there is no `/etc/OpenCL/vendors`; use the cixgpu-pro one (`ldconfig -p` lists both). `clinfo` is not installed; I queried with ctypes. |
| Device caps | 10 compute units, max work-group 1024, local memory 32 KB, global mem and max alloc 33.2 GB (the whole RAM), CL_DEVICE_HOST_UNIFIED_MEMORY = 1, global cache 2 MB, line 64 B, max 64 sub-groups per group, **sub-group independent forward progress = true**, `cl_khr_int64_base/extended_atomics`, `cl_khr_subgroups` (+ballot, shuffle, rotate, clustered), `cl_khr_il_program` (SPIR-V 1.0), `cl_arm_import_memory_host`, `cl_arm_import_memory_dma_buf`, `cl_ext_cxx_for_opencl` is listed, `cl_arm_scheduling_controls`, `cl_khr_command_buffer`. No fp64 (irrelevant: Bend has no F64). |
| SVM | `CL_DEVICE_SVM_CAPABILITIES` = 1: **coarse-grain buffer only** (no fine-grain buffer, no fine-grain system, no SVM atomics). Host and device may not touch a buffer at the same time without map/unmap. Bend's model ("the CPU and the GPU never compute at the same time") is compatible. |
| Compiler support in the driver | `clBuildProgram` compiles OpenCL C at run time: `-cl-std=CL1.2/2.0/3.0/CLC++` accepted (`clc++2021` rejected). Feature macros for generic address space, seq_cst/acq_rel order, device-scope atomics and fences are defined; C11 `atomic_fetch_*_explicit` / `atomic_compare_exchange_weak_explicit` / `atomic_work_item_fence(..., memory_scope_device)` on `__global atomic_uint*` compiled; a generic-pointer function compiled. (The `ATOMIC_MEMORY_CAPABILITIES` query returned an implausible 0x100000, so I do not trust it; a real test of cross-group ordering is part of the prototype.) Compile of a toy kernel took 0.8 s. |
| Vulkan | `/etc/vulkan/icd.d/mali.json` -> `libmali.so`, api_version 1.3.296; loader `libvulkan.so.1.3.239`. `vulkaninfo`, `glslc`, `glslangValidator`, `spirv-*` are not installed, so Vulkan compute was not exercised. Mesa: Debian 22.3.6 (`panfrost_dri.so` present) and `cix-mesa 24.0.4` compat libs (swrast/zink/radeonsi only). **Panfrost/PanVk/rusticl are not usable**: the kernel side is kbase, not the panfrost DRM driver; the vendor stack is the only compute path. |
| Compilers | `/usr/bin/clang` = Debian clang 14.0.6 (aarch64; builds Bend binaries). `/usr/share/cix/bin/clang` = clang 15 **x86_64** (ahead in PATH; the README note about "unknown target triple x86_64" is this). No clang >= 19 anywhere (Bend's `!` host runtime needs it). Offline Mali compiler: `/usr/share/cix/bin/mali_clcc`, `malisc` (the latter is a shader-stat tool; not explored). Vendor examples: `mali_cl_simple_example`, `mali_cl_svm_example`, `mali_cl_import_memory_example`, `mali_cl_ext_cxx_for_opencl_example`, `cl_unit`, `mali_cl_peak_flops_example`. No OpenCL headers (`cl.h`) on the box: a backend or an effect would ship the Khronos headers or declare prototypes and `dlopen`. |
| `/usr/share/cix` | Mostly camera/ISP/NPU/VPU tooling and Mali test binaries (`bin/`), plus `lib/` (MNN OpenCL/Vulkan, llm, npu). `LD_LIBRARY_PATH=/usr/share/cix/lib` is set in this shell. Nothing there is a Bend-relevant compiler. |

## 2. How the Bend 2 compiler generates its targets (commit 7d24b8d, shallow clone)

Everything backend-related is in `bend2/comp.ts` (6468 lines) plus ~35 lines of build driver in `bend2/main.ts`. There is **no IR layer
per target**: the front end rewrites the program to flat "segments" (state-machine fragments, `RuntimeC` template starts at line 3414),
and the C runtime text is emitted verbatim with the program's segments spliced into it.

| Target | Where | Size |
|---|---|---|
| C (CPU) | `RuntimeC` template, lines 3414-6108: runtime (heap, terms, rings, tasks, work loop, thread pool, cube driver, corpus, IO event loop, show) | ~2700 lines of C inside a TS template; the part compiled for the device is the Err..Dev sections, lines 3847-4772 (~900 lines) plus the generated segments |
| JavaScript | `RuntimeJs`, lines 6108-6468 | ~360 lines (garbage-collected objects, trampolines; sequential, ignores `!`) |
| Metal | not a separate generator: `#ifdef __METAL_VERSION__` dialect macros (lines 3475-3575) + `__OBJC__` host code (lines 5018-5128) + `window_msl` | ~110 lines host + ~100 lines macros + ~20 `#ifdef` sites |
| CUDA | same file, `BEND_CUDA` host code (lines 5128-5248, NVRTC + driver API, `cuMemAllocManaged`) and `BEND_RTC` dialect branch | ~120 lines host + the shared macros |
| Device kernel | `bend_dev` (lines 4652-4770): one kernel, `pass` = 0 grow / 1 drain / 2 pack banks | ~120 lines |
| Build driver | `main.ts` `cli_build` + `cc_find` (lines ~382-440): `-DBEND_CUDA=1 -lcuda -lnvrtc` or Metal; needs clang 14 for CPU, **19 for GPU** (`#embed` of its own source, `preserve_none`/`preserve_most`); GPU only attempted if `$CUDA_HOME/include/nvrtc.h` exists (or on macOS) | ~60 lines |

So the three "backends" are one C file with address-space and intrinsic macros (`DEV`, `THR`, `TG`, `CONSTV`, `FENCE`, `BAR`, `BARD`, `CLZ`),
and a new GPU target is a new dialect block + a new host glue block + a build-driver branch, not a new code generator. That is
the good news. The paper (`paper/BendRT.pdf`, read from its Typst source `bend2/docs/BendRT/main.typ` since no PDF tool is installed):

* **Runtime model (HVM-style in spirit, but not interaction nets):** a term is one 64-bit word (tag, 16-bit aux, 40-bit heap
  offset; small values inline). One flat `corpus` of u64 shared by host and device (header, 2^14 task rings, per-lane stacks, heap).
  Affine values: a `match` frees the node it opens, only `+` values carry a reference count, no GC, no C stack (each def is a segment of a
  flat state machine; on the device the `fid` switch).
* **Scheduler:** a 128 x 128 "cube" of task rings; bulk-synchronous rounds: *grow* (widen the fork frontier) then *work* (every lane drains its
  ring), the host only reads the frontier counter between dispatches. Contention-free: no work stealing, no migration, balance
  is the programmer's job.
* **What runs on the GPU:** not the whole program. Only a call marked `f!(x)` at a *sequential program point* is detached whole, its
  continuation becomes the root, the phase loop runs on the device until the root delivers, then the CPU continues. CPU and GPU never
  compute together. The paper says GPU wins only on uniform work (52-67x over one thread for game of life, n-body, mandelbrot, merkle on an
  M4 Max) and loses on divergent/skewed work (n-queens, symbolic regression lose even to 16 CPU threads).
* **What a new backend must provide:** (a) one corpus visible to host and device at the same addresses (CUDA: managed memory; Metal: zero-copy
  buffer wrapping the host mapping; span fixed before the first dispatch; no growth under a running kernel); (b) **32-bit** atomics only
  (`a32_*`: add/min/max/exch/CAS loops, load/store, release/acquire as relaxed + `FENCE()`); 64-bit terms are plain loads/stores and
  the ring slots are read as two a32 halves, so no 64-bit atomics are needed; (c) workgroup barriers with 128 lanes (`CUBE_T`) and
  ~18 KB of threadgroup memory (`TG_HOLD` 2304 words x 8 B), and shared-memory atomics for the grow/work votes; (d) a device-scope
  memory fence; (e) error protocol through the header word (a device cannot abort); (f) a per-device cube shape (CUDA: group count from L2
  size, 16..128 groups of 128 lanes); (g) dispatch of 3 passes per round, plus a per-binary program cache (`<bin>.gpu`);
  (h) foreign imports (effects) are host-only: "proofs, termination and the GPU never touch host code" (GUIDE), so nothing to port.
* The tuned lane is Metal; the paper says CUDA "is in the source and not measured". Memory: the corpus reserves task rings
  (2^14 x 1026 x 8 B = 134 MB) and lane stacks (2^14 x 2048 x 8 B = 268 MB) before any heap, fine on 31 GB.

## 3. What would break or need care on Mali

| Area | Assessment |
|---|---|
| 64-bit atomics | Not needed (a32 only). Mali would offer them anyway (`cl_khr_int64_*_atomics`). No risk. |
| Unified memory | Hardware is unified, but SVM is coarse-grain only. Use `CL_MEM_USE_HOST_PTR` / `cl_arm_import_memory_host` on the mmap'd corpus (the Metal approach) and bracket every dispatch with map/unmap; the host reads the frontier counter and error word between rounds, so each round pays launch (~90 us measured) + map. Needs a fixed span (like Metal's `--gpu 4GB`). Risk: driver cache maintenance cost per map on a multi-GB mapping, and the host's fixed high base address/doubling in-place scheme (8 GiB) must be given up for the GPU lane. Medium. |
| Memory model | Valhall L1s are not coherent between cores. The runtime already hands off through a32 + device `FENCE()` (that is how it works on CUDA where plain data is L1-cached; Metal needed `coherent(device)` because M1 lost stores). Needs `atomic_work_item_fence(CLK_GLOBAL_MEM_FENCE, seq_cst, memory_scope_device)`; compiles. Whether Arm's compiler honors it for plain 64-bit loads/stores of ring slots and task nodes is the main correctness risk (the Metal port hit exactly this class of bug). Medium-high; only a stress test answers it. |
| Forward progress | Good news: no inter-work-group spinning (cross-group communication is through the rings, consumed in the *next* dispatch; the `err_spun`/`root_done` loops are error polls, not waits). Sub-group independent forward progress is reported. In-group barriers need uniform control flow, which the vote protocol already provides. Low. |
| Work-group size | The kernel needs 128 lanes per group + barriers and a large switch (every def segment) with 64-bit state. Mali halves the usable group size as register use grows and spills hard; `CL_KERNEL_WORK_GROUP_SIZE` for a real program may fall below 128 (my tiny kernels reported 1024). Also compile time of a giant switch in Arm's online compiler. Unknown; medium-high. Measure first with `mali_clcc` on the emitted device text. |
| Source dialect | The device text is CUDA-C++/MSL flavoured (overloaded `A32()`, `extern "C" __global__`, compound literals). OpenCL C 3.0 has address spaces like Metal (so the existing `DEV/THR/TG` discipline is a head start; no generic-pointer dependency), but no overloading of user functions and no `#embed`; `CLC++` is accepted by the driver. Expect a few dozen lines of mechanical rewriting. Low-medium. |
| Subgroup size | Not used by the runtime (it uses work-group barriers and shared atomics), so Mali's 16-wide warps need no logic change; they only matter for divergence cost (lanes of one subgroup run different `fid` cases: n-queens-style slowdowns, as in the paper). |
| SPIR-V / Vulkan | Not needed: OpenCL source build is enough. Vulkan compute + SPIR-V would be a second, larger project (no pointers-to-buffer, 64-bit address math through `PhysicalStorageBuffer`, atomics in a different model). Do not. |
| Host toolchain | `!` builds need clang 19 for `#embed`/`preserve_none`; absent here (Debian 12 has 14). The `#embed` can be replaced by emitting the source as a string; `preserve_none` has a fallback macro. The build driver must stop assuming CUDA. Low. |
| Measured performance | Unknown. M4 Max GPU is ~4x the shader cores of this part; and Bend on GPU is pointer-chasing, not streaming. |

## 4. Effort and risk for a Mali/OpenCL backend (estimate, one engineer who already knows the runtime; double it if not)

| Work item | Person-weeks |
|---|---|
| OpenCL dialect macros + make the Err..Dev device text compile as OpenCL C (strip C++-isms, address spaces, atomics map) | 0.5-1 |
| Host glue: probe, context/queue, host-pointer import or SVM, map/unmap per round, `clBuildProgram` + binary cache (`.gpu`), error protocol, `--gpu` flags, cube shaping for G720 | 1-1.5 |
| Build driver (`cli_build`, detection, drop CUDA assumption, headers/`dlopen` of libOpenCL) | 0.3-0.5 |
| Get `pow2!`/mandelbrot/game of life correct (first light) | 0.5-1 |
| Memory-model and work-group-size debugging on Valhall (stress, fences, register/spill limits, giant-switch compile time) | 1-3 (the unknown) |
| Pass the pinned 12-benchmark suite with identical checksums, tune cube shape/quantum | 1-2 |
| Docs, CI on a Mali box, upstreaming review | 0.5-1 |
| **Total** | **~5-10 (prototype 3-5; "works on all pinned benches" 8-12 is the safe commitment)** |

Risk list, highest first: (1) device-scope ordering bugs only visible under load; (2) kernel register pressure / group size < 128 / online
compile time; (3) per-round map/launch overhead (~0.1-0.3 ms; the CUDA lane also pays launch costs per round, but unified buffers
avoid copies) making small `!` calls slower than the CPU; (4) coarse-grain-only SVM and 2 MB L2 limiting pointer-chasing
performance; (5) upstream maintenance: the repo changes the runtime text constantly (ABI-less), so an out-of-tree backend rots;
(6) no Mali CI hardware outside this box; (7) clang 19 requirement.

## 5. The cheaper route: foreign C (and optionally OpenCL) import

Mechanism (`guide/EFFECTS.md`, `bend2/effs/*.c`): a def of type `IO(R)` whose body is `import "./x.c"` + `import "./x.js"`. The `.c` is
spliced after the runtime, so runtime internals (`Env`, `Term`, `ctr_take`, `io_node`, `io_str`, `io_list`, `io_work`) are in scope; the
effect registers itself with `io_eff(CID(Name), fn, need)`. Arguments arrive as raw `Term`s in `f[]`; U32 is the word; Strings/lists are
walked with the runtime helpers. Constraints:

* IO only, run by the single-threaded event loop at a sequential point (fine: the codec's top level is IO `main`; `solve_auto` is already IO).
* No ABI promise ("rebuild your effects with every update"): pin the Bend version (2.0.34 here).
* Needs a `.js` twin (can be a slow pure fallback or a stub that throws); `bend file.bend` (interpreted run) uses the JS twin, native `-o`
  uses the C. The proofs and laws do not see the C: it falls outside `PROOF.bend` unless the C kernel is treated as an axiom.
* Link flags: `cli_build` adds only `-lpthread -lm` plus X11/ALSA when the file text includes `<X11/` / `<alsa`, so OpenCL must be
  `dlopen`ed (glibc 2.36 has dlopen in libc) with Khronos prototypes declared locally; that also keeps CPU-only builds working.
* User handle types are WONTFIX: keep native state in a C-side table and hand Bend a U32 id (like an fd), with an explicit free effect.
* Marshalling is the real cost: a `Vec` is a tree of `VNode`/`VWord` constructors (24-40 B per word per `docs/perf.md`). Walking it
  out is a pointer chase (estimate 20-50 ns/word, i.e. 50-130 ms for the 2.6 M words of the K=10000, T=1024 intermediates, once);
  building one back is `io_node` allocations (estimate ~30 ns/word, 8 ms for 1000 x 1024 B). Flat `Array<U32>` blocks exist in the
  runtime ("packed 32-bit cells") but passing them across the effect boundary is undocumented; worth a 1-day probe because it would
  remove most of the marshalling.

Feasibility verdict: **yes**, a "native symbol store" effect set is buildable with no compiler change:
`Native.load(intermediates : Vec list) -> IO(U32 id)`, `Native.repair(id, isi list) -> IO(...)`, `Native.free(id)`, later
`Native.replay(plan, symbols)`. The first version should be plain C with NEON `vqtbl1q_u8` nibble-table muladd and 128-bit XOR (CPU); OpenCL
can sit behind the same API afterwards (a second `.c` branch), selected by size.

## 6. Workload analysis: which RaptorQ phases are GPU-suitable

Sizes from `docs/benchmarks.md` (K up to 10000, T = 16..1024, N = 1000 repair, L = K + S + H = 10269 at K = 10000) and `docs/perf.md`.

| Phase | Nature | Suitable? |
|---|---|---|
| Repair / source-symbol generation (RFC 5.3.5.3) | N independent symbols, each an XOR of ~8-10 intermediates (LT degree avg ~5-6 plus 2-3 PI terms) of T bytes; arithmetic intensity ~0.1 op/byte: memory bound. Degree varies 1..~40 per symbol (divergent in a Bend task-per-symbol model, fine in a hand kernel). | Yes in principle; wins nothing in practice (below). |
| Plan application on large T (replay of the elimination log on symbols) | ~6.4 xors per pivot plus dense-row corrections (10 dense rows x L pivots muladd at K'=56403), dependency levels in the hundreds; parallel across T bytes and partially across independent ops. Needs a persistent kernel with one slice per group, i.e. T >= ~64 KB to fill 10 cores at 2 KB/group, or ~hundreds of 90 us launches. GF(256) muladd on Mali has no byte-table instruction (measured SWAR kernel 4.8 GB/s vs NEON `tbl` 10-13 GB/s). | Poor for T <= a few KB (the RFC range, <= ~1.4 KB typical). |
| Solver phase 1 (pivot search, inactivation, logs) | sequential greedy graph walk, 0.4 s (K=10000) to 3 s (K'=56403) | No. |
| Materialisation / leftover rows / phase 3 forward substitution | chain of dependent row updates (pivot order) | No (replay on CPU). |
| Tail Gauss-Jordan (n = 79..604 columns) | dense GF(256) n^3 <= 2.2e8 byte ops; tiny, pivot-by-pivot, per-step synchronisation | No (CPU, ~25 ms in NEON at the largest size). |
| Decode | solve + K source regenerations; same as above | Same as repair for the regeneration step only. |
| Many independent blocks (Z > 1, not implemented) | embarrassingly parallel in principle but each block still pivots sequentially | Only as multi-core CPU parallelism, not GPU. |

### Measured micro-benchmarks on this box (OpenCL through libmali vs C/NEON, random indices, avg degree ~9, data random, min of repeats)

| Case (L, T, N) | CPU 1 core NEON | CPU 8-12 threads | Mali kernel only | Mali kernel + 90 us launch + 0.2-0.7 ms readback copy |
|---|---|---|---|---|
| 1071, 1024, 1000 | 0.87 ms | 1.3-1.9 ms (threads lose) | 0.18 ms | ~1.0 ms |
| 10269, 1024, 1000 | 0.60 ms | 1.1-1.5 ms | 0.21 ms | ~0.7 ms |
| 10269, 256, 1000 | 0.19 ms | 0.3-0.5 ms | 0.08 ms | ~0.4 ms |
| 10269, 16, 1000 | 0.013 ms | 0.04 ms | 0.05 ms | worse than CPU |
| 10269, 4096, 1000 | 3.3 ms | 5-7 ms | 1.1 ms | ~2.4 ms |
| 57326, 1024, 1000 | 0.78 ms | 0.9-1.3 ms | 1.1 ms | ~1.4 ms |
| 10269, 1024, 10000 | 5.6 ms | 5.0-9.4 ms | 9.4 ms | ~12 ms |
| 10269, 4096, 10000 | 35.7 ms | 12-13 ms | 35.6 ms | ~36-78 ms |

Other measurements: empty-kernel launch + `clFinish` 90 us; streaming read+write XOR 12-15 GB/s at 4-64 MB and 35.7 GB/s at 512 MB (GPU
clock was probably still ramping); GF(256) muladd, Mali SWAR 2.9-4.8 GB/s of source vs CPU NEON tbl 10.3 GB/s (1 core), 12.9 GB/s
(8 threads). Output verified equal to a NumPy reference for the first and last symbol of each repair run. Caveats: the Mali kernel is
untuned (one 16 B vector per work-item, no local-memory staging, `deg`/`idx` read per item), the clock governor was not pinned on either
side, the GPU read-back used `clEnqueueReadBuffer` (a copy; a zero-copy import would remove most of it), and the CPU thread results are
noisy because the 12 cores are not equal (A520 + A720) and the working set is cache-resident.

Conclusions from the measurements:

* A native single-core NEON repair of 1000 symbols at K=10000, T=1024 takes ~0.6 ms against Bend's measured 130 ms (1 thread) / 333 ms
  (12 threads): the speedup of "any C" over Bend is ~200x on the pure compute. **The GPU's contribution is a factor in [0.3, ~3] on top
  of that, versus a single core, and in [0.3, 1] versus the multi-core CPU.** The data are small enough to live in L2/L3 on the CPU
  side, and the DRAM is shared, so the Mali's higher streaming bandwidth (maybe 2-2.5x one core) only appears at tens of MB.
* **Break-even** (this SoC, estimate from the table): the fixed GPU cost is ~0.1 ms launch + ~0.05-0.2 ms sync/map; GPU beats one NEON
  core when N x T is above roughly 0.3-1 MB of output (e.g. N >= 300-1000 at T = 1024, N >= 1000 at T >= 256); it never beats 8
  threads of NEON unless the working set outgrows the CPU caches (L >= ~50k at T >= 1024, i.e. K near 56403: 0.78 ms CPU vs 1.1 ms GPU, still
  a loss). K matters only through L x T (the intermediate size); small K (< 1000) never pays. T < 256: never (CPU 13 us at T = 16).
* **Replay/plan application**: GPU loses at T <= 4 KB because of muladd cost and launch count; in the K = 10000, T = 1024 setup the plan is
  ~100k symbol ops (~0.1 GB, ~10 ms of NEON), already below the 0.9 s of symbol-independent Bend pivoting that remains.
* If instead the *Bend* `!` backend ran the existing Bend repair code on Mali (task per repair symbol, 1000 tasks over 16k lanes, tree
  walks over 24-40 B-per-word `Vec`s, degrees 1..40+): estimate 0.3-3x of Bend single-thread performance (the paper's own
  divergent benchmarks lose to 16 CPU threads, and `docs/perf.md` shows the current 12-thread runtime is already slower than 1 thread
  at T=1024 repair). That is 1-3 orders of magnitude behind the foreign C path.

## 7. Ordered next steps

1. (half a day) Probe whether an effect can take/return a flat `Array<U32>` (`TAG_ARR` blocks) instead of walking `Vec` trees; if yes,
   marshalling cost nearly vanishes. Measure `Vec` walk/build ns/word with a throwaway effect.
2. (2-3 days) Prototype `Native.muladd/xor` and `Native.repair` as a C effect with NEON (CPU only), a pure-Bend fallback behind a flag;
   benchmark against `tools/bench/run.sh`; add a test that compares to `Codec.symbols` bit for bit (existing vectors). Keep it out of
   `PROOF.bend`, document the trust boundary.
3. (1-2 weeks) Implement the operation-log "plan" (the Rust warm path; already listed as future work in `docs/benchmarks.md`): run the
   solver at T = 1 word with a log of (dst, src, coef) ops, replay the log in C on flat symbols. This is the largest remaining lever
   for T >= 256 setup/decode and is GPU-independent.
4. Only after 1-3: if profile shows repair for N >= 10^4 and T >= 4096 dominating, add an OpenCL branch behind the same effect
   (dlopen `/opt/cixgpu-pro/.../libOpenCL.so.1`, `CL_MEM_USE_HOST_PTR` import, coarse-grain map/unmap), tuned with local-memory
   staging; expected gain <= 2x over one core, ~1x over many.
5. Revisit a Mali Bend backend only if upstream Bend ships an OpenCL/Vulkan lane or someone else needs `!` on this SoC; if it does,
   the first experiment is to run `mali_clcc`/`clBuildProgram` on the emitted device text and read `CL_KERNEL_WORK_GROUP_SIZE` and
   build time, which retires or confirms risks (1)-(2) in a day.
