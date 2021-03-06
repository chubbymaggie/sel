;; repair using software evolution
(mapcar #'require '(:software-evolution-library :cl-store))
(defpackage :repair
  (:use :common-lisp :alexandria :metabang-bind :curry-compose-reader-macros
        :software-evolution-library :software-evolution-library/utility
        :split-sequence :cl-store :cl-ppcre))
(in-package :repair)
(in-readtable :curry-compose-reader-macros)

;; reproducibility
(let ((seed-path "seed"))
  (if (probe-file seed-path)
      (setf *random-state* (with-open-file (in seed-path) (read in)))
      (progn
        (setf *random-state* (make-random-state t))
        (with-open-file (out seed-path :direction :output)
          (write *random-state* :stream out)))))

(defvar *test*  "./test/gcd/test.sh")

(defun test-suite (ast)
  (with-temp-file (bin)
    (if (zerop (second (multiple-value-list (phenome ast :bin bin))))
        (count t (loop :for num :upto 10 :collect
                    (multiple-value-bind (output err-output exit)
                        (shell "~a ~a ~a" *test* bin num)
                      (declare (ignorable output err-output))
                      (zerop exit))))
        0)))
