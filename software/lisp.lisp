;;; lisp.lisp --- software representation of Lisp source code

;; Copyright (C) 2011  Eric Schulte

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;;; Code:
(in-package :software-evolution)


;;; the class of lisp software objects
(defclass lisp (software) ())

(defmethod from ((software lisp) (in stream))
  (setf (genome software)
        (loop :for form = (read in nil :eof)
           :until (eq form :eof)
           :collect form)))

(defmethod to ((software lisp) (to stream))
  (dolist (form (genome software))
    (format to "~&~S" form)))

(defun lisp-from-file (path)
  (let ((new (make-instance 'lisp)))
    (with-open-file (in path) (from new in))
    new))

(defun lisp-to-file (software path)
  (with-open-file (out path :direction :output :if-exists :supersede)
    (to software out)))

(defmethod exe ((lisp lisp) &optional place)
  (declare (ignorable lisp place))
  (error "Lisp software objects are interpreted not compiled."))

(defmethod evaluate ((software lisp))
  (if (ignore-errors
        (handler-case (progn (mapcar #'eval (genome software)) t)
          (error (_) (declare (ignorable _)) nil)))
      (apply #'+ (append (mapcar (lambda (test)
                                   (* *pos-test-mult*
                                      (funcall test)))
                                 *pos-tests*)
                         (mapcar (lambda (test)
                                   (* *neg-test-mult*
                                      (funcall test)))
                                 *neg-tests*)))
      0))


;;; TODO: execution tracing in lisp source code


;;; weighted genome access
(defun good-key (el)
  (if (or (assoc :pos el) (assoc :neg el)) 1 0.25))

(defun bad-key (el)
  (if (assoc :neg el) (if (assoc :pos el) 0.5 1) 0.25))

(defmethod good-ind ((lisp lisp))
  (weighted-ind (genome lisp) #'good-key))

(defmethod bad-ind ((lisp lisp))
  (weighted-ind (genome lisp) #'bad-key))

(defmethod good-place ((lisp lisp))
  (weighted-place (genome lisp) #'good-key))

(defmethod bad-place ((lisp lisp))
  (weighted-place (genome lisp) #'bad-key))
