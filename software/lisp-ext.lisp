;;; lisp-exe.lisp --- software rep of Lisp code (external eval)
(in-package :software-evolution-library)
(in-readtable :curry-compose-reader-macros)


;;; the class of lisp software objects
(defclass lisp-exe (software-exe) ())

(defvar *test-script*  nil "Script capable of running tests.")
(defvar *pos-test-num* nil "Number of positive tests")
(defvar *neg-test-num* nil "Number of negative tests")

(defmethod from-file ((lisp-exe lisp-exe) file)
  (with-open-file (in path)
    (setf (genome lisp-exe)
          (loop :for form = (read in nil :eof)
             :until (eq form :eof)
             :collect form)))
  lisp-exe)

(defun lisp-exe-from-file (path)
  (from-file (make-instance 'lisp-exe) path))

(defun lisp-exe-to-file (software path)
  (with-open-file (out path :direction :output :if-exists :supersede)
    (dolist (form (genome software))
      (format out "~&~S" form))))

(defmethod exe ((lisp-exe lisp-exe) &optional place)
  (let ((exe (or place (temp-file-name))))
    (lisp-exe-to-file lisp-exe exe)
    exe))

(defmethod evaluate ((lisp-exe lisp-exe))
  (evaluate-with-script lisp-exe *test-script* *pos-test-num* *neg-test-num*))
