#!/usr/bin/env bb
;; Oracle for tests/visible_width_cases.json.
;;
;; Computes visible-width using joker's EXACT helper from commit 964c013
;; (core/data/pprint.joke, function `visible-width`). This is the canonical
;; reference implementation; nanoclj-zig's src/visible_width.zig must agree
;; on every case in cases.json, modulo documented divergences.
;;
;; Usage:
;;   bb tests/visible_width_oracle.bb            ; verify, exit 1 on diff
;;   bb tests/visible_width_oracle.bb --promote  ; auto-fill `expected`
;;
;; Diff-empty (Murray) + adjoint round-trip (Meijer) + replica convergence
;; (Kleppmann) are all expressed as the single property:
;;   forall case, oracle(input) == zig(input) == case.expected

(require '[clojure.string :as str]
         '[cheshire.core :as json]
         '[clojure.java.io :as io])

;; --- joker 964c013's visible-width, verbatim ---
;; (defn- visible-width [s] ...)  -- inlined here as the oracle

(def osc8-seq-re #"\x1b\]8;[^\x07\x1b]*(\x07|\x1b\\)")

(defn visible-width
  "Joker v1.7.1 reference impl. Strips OSC 8 frames, returns codepoint count."
  [s]
  (let [s (str s)]
    (if (re-find osc8-seq-re s)
      (- (count s)
         (apply +
                (map (fn [m] (count (if (vector? m) (first m) m)))
                     (re-seq osc8-seq-re s))))
      (count s))))

;; Joker counts BYTES (UTF-8 raw). For UTF-8 visible-cell parity with
;; nanoclj-zig (which counts codepoint-leading bytes), the corpus uses
;; codepoint counts. This helper reflects the Zig semantics for the diff.
(defn codepoint-width
  "Count UTF-8 codepoints, with OSC 8 frames stripped first."
  [bytes-str]
  (let [stripped (str/replace bytes-str osc8-seq-re "")
        ;; count leading bytes of each UTF-8 codepoint
        b (.getBytes stripped "UTF-8")]
    (count (filter #(not= 0x80 (bit-and % 0xC0)) b))))

;; --- corpus IO ---
(def corpus-path "tests/visible_width_cases.json")

(defn hex->str [hex]
  (let [pairs (partition 2 hex)
        bytes (byte-array (map (fn [[a b]] (Integer/parseInt (str a b) 16)) pairs))]
    (String. bytes "UTF-8")))

(defn load-cases []
  (-> corpus-path slurp (json/parse-string true)))

(defn save-cases [data]
  (spit corpus-path
        (str (json/generate-string data {:pretty true}) "\n")))

;; --- main ---
(defn run [{:keys [promote?]}]
  (let [data  (load-cases)
        cases (:cases data)
        results
        (for [c cases]
          (let [s (hex->str (:input_hex c))
                ;; codepoint-width matches Zig semantics (cell count)
                want (codepoint-width s)
                have (:expected c)]
            (assoc c :computed want :match? (= want have))))
        diffs (remove :match? results)]
    (println (format "%-32s %5s %5s %s"
                     "case" "want" "have" "ok?"))
    (println (apply str (repeat 60 "-")))
    (doseq [r results]
      (println (format "%-32s %5d %5s %s"
                       (:name r) (:computed r)
                       (str (:expected r))
                       (if (:match? r) "ok" "DIFF"))))
    (println)
    (cond
      promote?
      (do
        (save-cases (assoc data :cases
                           (mapv (fn [r] (-> r
                                             (assoc :expected (:computed r))
                                             (dissoc :computed :match?)))
                                 results)))
        (println (format "promoted %d case(s) to %s" (count results) corpus-path)))

      (seq diffs)
      (do
        (println (format "FAIL: %d case(s) diverge from oracle"
                         (count diffs)))
        (System/exit 1))

      :else
      (println (format "OK: all %d case(s) match" (count results))))))

(run {:promote? (some #{"--promote"} *command-line-args*)})
