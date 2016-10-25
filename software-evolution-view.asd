(defsystem :software-evolution-view
  :description "Viewing functions for the SOFTWARE-EVOLUTION library."
  :version "0.0.0"
  :depends-on (alexandria
               cl-interpol
               metabang-bind
               curry-compose-reader-macros
               cl-arrows
               iterate
               split-sequence
               trivial-shell
               cl-ppcre
               cl-store
               cl-dot
               diff
               bordeaux-threads)
  :components
  ((:module view
            :pathname "view"
            :components
            ((:file "package")
             (:file "view" :depends-on ("package"))))))