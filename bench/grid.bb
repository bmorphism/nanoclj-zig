#!/usr/bin/env bb
;; bench/grid.bb — substrate-independent 12-op grid
;; Runs on any Clojure-flavored runtime that has babashka.fs + clojure.string.
;; Emits CSV to stdout: op,ns_per_op,ops_per_sec,path
;; Usage:
;;   bb bench/grid.bb           ; run on bb, default n=100000
;;   bb bench/grid.bb 50000     ; smaller corpus
;;   zg bench/grid.bb           ; run on ziggushka (when it exists)

(require '[babashka.fs :as fs]
         '[clojure.string :as str]
         '[babashka.process :as p])

(def N (or (some-> (first *command-line-args*) Long/parseLong) 100000))
(def N-fs   5000)   ; fs ops are slow, fewer iters
(def N-proc 5000)

(defn bench [n f]
  (dotimes [_ 1000] (f))
  (let [t0 (System/nanoTime)]
    (dotimes [_ n] (f))
    (let [ns-per (double (/ (- (System/nanoTime) t0) n))]
      {:ns-per ns-per :ops-per-sec (long (/ 1e9 ns-per))})))

;; Setup
(def tmp-dir
  (let [d (fs/create-temp-dir {:prefix "zg-grid"})]
    (dotimes [i 100] (spit (str d "/file-" i ".txt") "hi"))
    d))

(def s "/Users/bob/i/horse/trees/bcf-0001.tree")
(def re-tree #"\.tree$")
(def m {:a 1 :b 2 :c 3 :d 4 :e 5})
(def v [1 2 3 4 5 6 7 8 9 10])

(def ops
  ;; [label fn iter-count classification]
  [["+ boxed"            #(+ 1 2)                                  N    "L2"]
   [":c m"               #(:c m)                                   N    "L1"]
   ["str/ends-with?"     #(str/ends-with? s ".tree")               N    "L1"]
   ["assoc"              #(assoc m :f 6)                           N    "L1"]
   ["reduce + [10]"      #(reduce + 0 v)                           N    "L2"]
   ["into [] filter"     #(into [] (filter even?) v)               N    "L2"]
   ["re-find"            #(re-find re-tree s)                      N    "L1"]
   ["str/split /"        #(str/split s #"/")                       N    "L2"]
   ["fs/exists?"         #(fs/exists? tmp-dir)                     N-fs "L1"]
   ["fs/list-dir 100"    #(count (fs/list-dir tmp-dir))            N-fs "L1"]
   ["fs/walk 100"        #(let [n (atom 0)]
                            (fs/walk-file-tree tmp-dir
                              {:visit-file (fn [_ _] (swap! n inc) :continue)})
                            @n)                                    N-fs "L1"]
   ;; "process build" measures cost of constructing a ProcessBuilder; uses
   ;; `false` because it exists everywhere and exits 1 cheaply.  Wrap to swallow
   ;; the non-zero exit status.
   ["process build"      #(try (p/process ["false"] {:out :string})
                               (catch Throwable _ nil))
                                                                   N-proc "L1"]])

;; Optional runtime tag (passed via --runtime, default "bb")
(def runtime
  (or (System/getProperty "zg.runtime")
      (System/getenv "ZG_RUNTIME")
      "bb"))

(println "runtime,op,ns_per_op,ops_per_sec,path")
(doseq [[label f n path] ops]
  (let [r (bench n f)]
    (println (format "%s,%s,%.0f,%d,%s"
                     runtime label (:ns-per r) (:ops-per-sec r) path))))

(fs/delete-tree tmp-dir)
