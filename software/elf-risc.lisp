;;; elf-risc.lisp --- software representation of risc ELF files

;; Copyright (C) 2011-2013  Eric Schulte

;; Licensed under the Gnu Public License Version 3 or later

;;; Commentary:

;;; Code:
(in-package :software-evolution)


;;; elf software objects
(defvar risc-nop (coerce (elf:int-to-bytes #x0 1) 'list))

(defclass elf-risc (elf)
  ((nop :initarg :nop :accessor nop :initform risc-nop)))

(defmethod copy ((elf elf-risc))
  (make-instance (type-of elf)
    :fitness (fitness elf)
    :genome (map 'vector #'copy-tree (coerce (genome elf) 'list))
    :base (base elf)))

(defmethod elf ((elf elf-risc))
  (with-slots (base genome) elf
    (let ((new (copy-elf base))
          (offset 0))
      ;; If this file has a .text section, simply replace the contents
      ;; of that section.
      (if (named-section base ".text")
          (setf (data (named-section base ".text"))
                (coerce (mappend {aget :bytes} (coerce genome 'list)) 'vector))
          ;; Otherwise split up the genome among all loadable
          ;; sections.
          (mapc (lambda (sec)
                  (setf (data sec)
                        (coerce
                         (mappend {aget :bytes}
                                  (coerce (subseq genome offset
                                                  (incf offset (elf:size sec)))
                                          'list))
                         'vector)))
                (remove-if-not [{eql :load}  #'elf:type]
                               (sections new))))
      new)))

(defmethod from-file ((elf elf-risc) path)
  (with-slots (base genome) elf
    (setf base (read-elf path)
          genome
          (coerce
           (mapcar [#'list {cons :bytes} #'list]
                   (or
                    ;; When initializing the genome, first try to read
                    ;; a .text section if present and named.
                    (coerce (data (named-section base ".text")) 'list)
                    ;; Otherwise we assume that the elf file is
                    ;; stripped.  In this later case, collect all
                    ;; sections with program headers of type :LOAD.
                    (apply #'concatenate 'list
                           (mapcar #'data
                                   (remove-if-not
                                    [{eql :load}  #'elf:type #'elf:ph]
                                    (remove-if-not #'elf:ph
                                                   (sections (base elf))))))))
           'vector)))
  elf)

(defmethod lines ((elf elf-risc))
  (mappend {aget :bytes} (coerce (genome elf) 'list)))

(defmethod (setf lines) (new (elf elf-risc))
  (setf (genome elf) (map 'vector [#'list {cons :bytes}] new)))

(defmethod apply-mutation ((elf elf-risc) mut)
  (let ((starting-length (length (genome elf))))
    (setf (genome elf)
          (ecase (car mut)
            (:cut    (elf-cut elf (second mut)))
            (:insert (elf-insert elf (second mut)
                                 (cdr (assoc :bytes
                                             (aref (genome elf) (third mut))))))
            (:swap   (elf-swap elf (second mut) (third mut)))))
    (assert (= (length (genome elf)) starting-length)
            (elf) "mutation ~S changed size of genome [~S -> ~S]"
            mut starting-length (length (genome elf)))))

(defmethod elf-cut ((elf elf-risc) s1)
  (with-slots (genome nop) elf
    (setf (cdr (assoc :bytes (aref genome s1))) nop)
    genome))

;; Thanks to the uniform width of RISC instructions, this is the only
;; operation which requires any bookkeeping.  We'll try to
(defvar elf-risc-max-displacement nil
  "Maximum range that `elf-insert' will displace instructions.
This is the range within which insertion will search for a nop to
delete, if none is found in this range insertion becomes replacement.
A value of nil means never replace.")

(defmethod elf-insert ((elf elf-risc) s1 val)
  (with-slots (genome base nop) elf
    (let* ((borders
            ;; Only return the borders between sections if this is the
            ;; genome has been concatenated from multiple ELF
            ;; sections.  We check this by looking for a .text
            ;; section, and if one is found we know that it is the
            ;; sole section in the genome, so no borders are
            ;; necessary.
            (if (named-section base ".text")
                nil
                (reduce (lambda (offsets ph)
                          (cons (+ (car offsets) (filesz ph))
                                offsets))
                        (program-table (base elf)) :initial-value '(0))))
           (backwards-p t) (forwards-p t)
           (nop-location               ; find the nearest nop in range
            (loop :for i :below (or elf-risc-max-displacement (length genome))
               :do
               (cond
                 ;; don't cross borders or leave the genome
                 ((or (member (+ s1 i) borders) (>= (+ s1 i) (length genome)))
                  (setf forwards-p nil))
                 ((or (member (- s1 i) borders) (< (- s1 i) 0))
                  (setf backwards-p nil))
                 ((and (not forwards-p) (not backwards-p)) (return nil))
                 ;; continue search forwards and backwards
                 ((and forwards-p
                       (equal nop (cdr (assoc :bytes (aref genome (+ s1 i))))))
                  (return (+ s1 i)))
                 ((and backwards-p
                       (equal nop (cdr (assoc :bytes (aref genome (- s1 i))))))
                  (return (- s1 i)))))))
      (if nop-location                 ; displace all bytes to the nop
          (reduce (lambda (previous i)
                    (let ((current (cdr (assoc :bytes (aref genome i)))))
                      (setf (cdr (assoc :bytes (aref genome i))) previous)
                      current))
                  (range s1 nop-location) :initial-value val)
          (setf (cdr (assoc :bytes (aref genome s1))) val)))
    genome))

(defmethod elf-swap ((elf elf-risc) s1 s2)
  (with-slots (genome) elf
    (let ((left-bytes  (copy-tree (cdr (assoc :bytes (aref genome s1)))))
          (right-bytes (copy-tree (cdr (assoc :bytes (aref genome s2))))))
      (setf (cdr (assoc :bytes (aref genome s1))) right-bytes
            (cdr (assoc :bytes (aref genome s2))) left-bytes))
    genome))

(defmethod crossover ((a elf-risc) (b elf-risc))
  "One point crossover."
  (let ((point (random (length (genome a))))
        (new (copy a)))
    (setf (genome new) (concatenate 'vector
                         (subseq (genome a) 0 point)
                         (subseq (genome b) point)))
    new))