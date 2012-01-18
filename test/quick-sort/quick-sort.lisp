(defun quick-sort (list)
  (unless (null list)
    (let ((x (car list))
          (xs (cdr list)))
      (append (quick-sort (remove-if (lambda (el) (>= el x)) xs))
              (list x)
              (quick-sort (remove-if (lambda (el) (< x el)) xs))))))