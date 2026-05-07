;; coloring_canon.clj v2 — 10 sources from the Gay-TOFU exa pull, implemented
;; in nanoclj-zig's integer-bit-op dialect.
;;
;; Dialect constraints (probed):
;;   ✓ loop/recur (no let inside recur path)
;;   ✓ defn, named-fn passed to mapv/reduce
;;   ✓ bit-and, bit-or, bit-xor, unsigned-bit-shift-right, mod (signed)
;;   ✓ vec, mapv, reduce, range, conj, last, nth, count, get
;;   ✗ Math/*, fn literals, hex 0x literals, assoc-on-vector, nested assoc,
;;     3-arg get, vec-key map lookup, let-inside-recur
;;
;; Run:  echo '(load-file "examples/coloring_canon.clj")' | ./zig-out/bin/nanoclj

(println "")
(println "═══ COLORING CANON — 10 sources implemented ═══")
(println "")

;; ─── 1. Hadwiger–Nelson — chromatic plane, 7-coloring witness ───
(println "─── 1. Hadwiger–Nelson 7-coloring (R² unit-distance) ───")
(defn hn7 [x y] (mod (+ (* 3 x) (* 2 y)) 7))
(println "  hn7(0,0)=" (hn7 0 0) " hn7(1,0)=" (hn7 1 0) " hn7(0,1)=" (hn7 0 1)
         " hn7(2,3)=" (hn7 2 3) " hn7(7,0)=" (hn7 7 0) " (period 7)")

;; ─── 2. Plastic ratio ρ via Padovan — quasiperiodic seed generator ───
(println "")
(println "─── 2. Plastic ratio via Padovan recurrence ───")
;; State as 3 separate scalars to avoid vec-deconstructing in recur path.
(defn padovan-tail [steps]
  (loop [a 1 b 1 c 1 i 0]
    (if (>= i steps)
      [a b c]
      (recur b c (+ a b) (+ i 1)))))
(def pad-state (padovan-tail 20))
(def pad-prev (nth pad-state 1))
(def pad-curr (nth pad-state 2))
(println "  P(20)=" (nth pad-state 0) " P(21)=" pad-prev " P(22)=" pad-curr)
(println "  10000·P(22)/P(21) =" (quot (* pad-curr 10000) pad-prev)
         "  (target ρ ≈ 13247)")

;; ─── 3. Roberts low-discrepancy color sequence ───
(println "")
(println "─── 3. Roberts quasirandom 24-bit colors ───")
(def PLASTIC-32 3242174889)        ;; floor(2^32 / ρ)
(def MASK-24 16777215)             ;; 2^24 - 1
(defn roberts-color [n]
  (bit-and (* (+ n 1) PLASTIC-32) MASK-24))
(def roberts-16 (mapv roberts-color (range 16)))
(println "  16 Roberts colors (24-bit ints):" roberts-16)

;; ─── 4. Penrose / Robinson matching as cocycle (Z/3) ───
(println "")
(println "─── 4. Penrose/Robinson matching as edge cocycle (Z/3) ───")
(defn edge-cocycle [edge]
  (mod (+ (- (nth edge 0) (nth edge 1)) 3) 3))
(def patch-edges [[2 1] [1 0] [0 2] [2 2] [1 1]])
(def patch-cocycles (mapv edge-cocycle patch-edges))
(def cocycle-sum (mod (reduce + patch-cocycles) 3))
(println "  edges (head,tail):" patch-edges)
(println "  cocycles:" patch-cocycles
         "  Σ mod 3:" cocycle-sum
         "  (0 ↔ consistent tiling)")

;; ─── 5. Cieran-style preference learning (no assoc-on-vec) ───
(println "")
(println "─── 5. Cieran-style preference learning ───")
;; Use a 5-cell tail-recursive integer accumulator instead of (assoc vec ...).
;; Pre-compute per-colormap delta from prefs, then materialize once.
(def n-cmap 5)
(def prefs [[0 1] [0 2] [3 1] [3 4] [0 3] [3 2] [0 4] [3 0]])
;; Direct recursion (no inner `loop`) so build-scores' outer loop isn't shadowed.
(defn delta-rec [k ps i acc]
  (if (>= i (count ps)) acc
      (delta-rec k ps (+ i 1)
                 (+ acc
                    (if (= (nth (nth ps i) 0) k) 1 0)
                    (if (= (nth (nth ps i) 1) k) -1 0)))))
(defn delta-for [k ps] (delta-rec k ps 0 0))
(defn build-scores [n ps]
  (loop [k 0 acc []]
    (if (>= k n) acc
      (recur (+ k 1) (conj acc (delta-for k ps))))))
(def cieran-final (build-scores n-cmap prefs))
(defn argmax-int [xs]
  (loop [i 0 best 0 bv (nth xs 0)]
    (if (>= i (count xs)) best
      (recur (+ i 1)
             (if (> (nth xs i) bv) i best)
             (if (> (nth xs i) bv) (nth xs i) bv)))))
(println "  prefs:" prefs)
(println "  final scores:" cieran-final
         "  argmax = colormap" (argmax-int cieran-final))

;; ─── 6. Non-opponent afterimages — Hering predicate flagged as obsolete ───
(println "")
(println "─── 6. Hering-opponent predicate (flagged obsolete by 2025) ───")
(defn hering-predicted [lab]
  [(nth lab 0) (- 0 (nth lab 1)) (- 0 (nth lab 2))])
(def red-lab [55 66 42])
(def hering-pred (hering-predicted red-lab))
(def empirical [55 -50 -48])
;; Use simple integer comparison (no `and`):
(defn lab-match [a b]
  (loop [i 0]
    (if (>= i 3) 1
      (if (= (nth a i) (nth b i)) (recur (+ i 1)) 0))))
(def violation-flag (- 1 (lab-match hering-pred empirical)))
(println "  red Lab:" red-lab "  Hering predicts:" hering-pred)
(println "  empirical (CommPsy 2025):" empirical
         "  Hering-violation flag:" violation-flag " (1 = obsoleted)")

;; ─── 7. BCI cross-subject calibration ───
(println "")
(println "─── 7. BCI cross-subject calibration (per-channel offset) ───")
(def subjA [[58 64 40] [22 -12 38] [80 -8 -10]])
(def subjB [[55 66 42] [25 -10 36] [78 -6 -8]])
(defn pair-diff [i]
  [(- (nth (nth subjA i) 0) (nth (nth subjB i) 0))
   (- (nth (nth subjA i) 1) (nth (nth subjB i) 1))
   (- (nth (nth subjA i) 2) (nth (nth subjB i) 2))])
(defn build-offsets [n]
  (loop [i 0 acc []]
    (if (>= i n) acc
      (recur (+ i 1) (conj acc (pair-diff i))))))
(def offsets (build-offsets (count subjA)))
(defn col-sum [vs k]
  (loop [i 0 s 0]
    (if (>= i (count vs)) s
      (recur (+ i 1) (+ s (nth (nth vs i) k))))))
(def n-trials (count offsets))
(def bci-mean
  [(quot (col-sum offsets 0) n-trials)
   (quot (col-sum offsets 1) n-trials)
   (quot (col-sum offsets 2) n-trials)])
(println "  per-stimulus offsets:" offsets)
(println "  mean A→B calibration:" bci-mean)

;; ─── 8. Tyler Cipriani: drunken bishop ASCII fingerprint walk ───
(println "")
(println "─── 8. Drunken-bishop walk on *seed* (4×4 board) ───")
;; Position encoded as int  k = y*4 + x  (vec-keyed maps don't work).
;; Step computed inline in recur args (no `let`).
(defn db-stepx [x bits]
  (if (= (mod bits 2) 0)
    (if (< (- x 1) 0) 0 (- x 1))
    (if (>= (+ x 1) 4) 3 (+ x 1))))
(defn db-stepy [y bits]
  (if (= (bit-and bits 2) 0)
    (if (< (- y 1) 0) 0 (- y 1))
    (if (>= (+ y 1) 4) 3 (+ y 1))))
(defn pos-key [x y] (+ (* y 4) x))
(defn db-walk [seed steps]
  (loop [i 0 x 2 y 2 visits {} s seed]
    (if (>= i steps) visits
      (recur (+ i 1)
             (db-stepx x (bit-and s 3))
             (db-stepy y (bit-and s 3))
             (assoc visits (pos-key x y)
                    (+ 1 (or (get visits (pos-key x y)) 0)))
             (unsigned-bit-shift-right s 2)))))
(def db-result (db-walk (bit-and *seed* 4294967295) 16))
(println "  16-step walk visits (key=y*4+x):" db-result)

;; ─── 9. Yau colored operad — operation indexed by color tuple ───
(println "")
(println "─── 9. Coloured operad (Yau) op-table ───")
;; Vec-key maps were broken; encode as parallel vectors instead.
(def op-keys
  [[0 0 0]
   [0 1 0]
   [1 0 1]
   [2 1 0]
   [2 2 2]])
(def op-vals
  [:RR-to-R :GR-to-R :RG-to-G :GR-to-B :BB-to-B])
(defn op-at [colors]
  (loop [i 0]
    (if (>= i (count op-keys)) :no-op
      (if (= (nth op-keys i) colors) (nth op-vals i)
          (recur (+ i 1))))))
(println "  op[R,R,R]:" (op-at [0 0 0]))
(println "  op[B,G,R]:" (op-at [2 1 0]))
(println "  op[R,B,B]:" (op-at [0 2 2]))
(println "  ops registered:" (count op-keys))

;; ─── 10. D3 schemeObservable10 — successor categorical palette ───
(println "")
(println "─── 10. D3 schemeObservable10 palette (decimal, hex literals N/A) ───")
;; 0x4269d0 0xefb118 0xff725c 0x6cc5b0 0x3ca951 0xff8ab7 0xa463f2 0x97bbf5 0x9c6b4e 0x9498a0
(def schemeObservable10
  [4352464  ;; 4269d0
   15708440 ;; efb118
   16741468 ;; ff725c
   7128496  ;; 6cc5b0
   3984721  ;; 3ca951
   16747703 ;; ff8ab7
   10773234 ;; a463f2
   9943029  ;; 97bbf5
   10250062 ;; 9c6b4e
   9737376]) ;; 9498a0
(defn nth-obs10 [i] (nth schemeObservable10 (mod i 10)))
(println "  palette (decimal):" schemeObservable10)
(println "  obs10[0]=" (nth-obs10 0)
         " obs10[5]=" (nth-obs10 5)
         " obs10[15]=" (nth-obs10 15) " (wraps to idx 5)")

(println "")
(println "═══ END coloring_canon — 10/10 sources covered ═══")
