;;; clang.lisp --- clang software representation

;; Copyright (C) 2012 Eric Schulte

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING. If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Code:
(in-package :software-evolution)
(enable-curry-compose-reader-macros :include-utf8)

(define-software clang (ast)
  ((genome   :initarg :genome :initform "" :copier :direct)
   (compiler :initarg :compiler :accessor compiler :initform "clang")
   (ast-root :initarg :ast-root :initform nil :accessor ast-root
             :documentation "Root node of AST.")
   (asts     :initarg :asts :initform nil
             :accessor asts :copier :direct
             :type #+sbcl (list (cons keyword *) *) #+ccl list
             :documentation
             "List of all ASTs.")
   (stmt-asts :initarg :stmt-asts :initform nil
              :accessor stmt-asts :copier :direct
              :type #+sbcl (list (cons keyword *) *) #+ccl list
              :documentation
              "List of statement ASTs which exist within a function body.")
   ;; TODO: We should split non-statement ASTs into typedefs,
   ;;       structs/classes, and global variables, all of which should
   ;;       have different mutation types defined.  This needs more design.
   (non-stmt-asts :initarg :non-stmt-asts :accessor non-stmt-asts
                  :initform nil :copier :direct
                  :type #+sbcl (list (cons keyword *) *) #+ccl list
                  :documentation
                  "List of global AST which live outside of any function.")
   (functions :initarg :functions :accessor functions
              :initform nil :copier :direct
              :type #+sbcl (list (cons keyword *) *) #+ccl list
              :documentation "Complete functions with bodies.")
   (prototypes :initarg :prototypes :accessor prototypes
               :initform nil :copier :direct
               :type #+sbcl (list (cons keyword *) *) #+ccl list
               :documentation "Function prototypes.")
   (includes :initarg :includes :accessor includes
             :initform nil :copier :direct
             :type #+sbcl (list string *) #+ccl list
             :documentation "Names of included includes.")
   (types :initarg :types :accessor types
          :initform nil :copier :direct
          :type #+sbcl (list (cons keyword *) *) #+ccl list
          :documentation "Association list of types keyed by HASH id.")
   (macros :initarg :macros :accessor macros
           :initform nil :copier :direct
           :type #+sbcl (list clang-macro *) #+ccl list
           :documentation "Association list of Names and values of macros.")
   (globals :initarg :globals :accessor globals
            :initform nil :copier :direct
            :type #+sbcl (list (cons string string) *) #+ccl list
            :documentation "Association list of names and values of globals.")
   (asts-changed-p :accessor asts-changed-p
                   :initform t :type boolean
                   :documentation
                   "Have ASTs changed since last clang-mutate run?")
   (copy-lock :initform (bordeaux-threads:make-lock "clang-copy")
              :copier :none
              :documentation "Lock while copying clang objects.")))

(defmethod copy :before ((obj clang))
  ;; Update ASTs before copying to avoid duplicates. Lock to prevent
  ;; multiple threads from updating concurrently.
  (unless (slot-value obj 'ast-root)
    (bordeaux-threads:with-lock-held ((slot-value obj 'copy-lock))
      (update-asts obj))))

(defgeneric ast->snippet (ast)
  (:documentation "Convert AST to alist representation."))

(defstruct (ast-ref)
  "A reference to an AST at a particular location within the tree."
  (path nil :type list)
  (ast nil :type list))

(defmethod print-object ((obj ast-ref) stream)
  (if *print-readably*
      (call-next-method)
      (print-unreadable-object (obj stream :type t)
        (format stream ":PATH ~s ~:_ :AST ~s ~:_ :TEXT ~s"
                (ast-ref-path obj) (car (ast-ref-ast obj))
                (source-text obj)))))

(defmacro define-ast (name options doc &rest fields)
  "Define an AST struct.

Form is similar to DEFSTRUCT, but each field can be described by a
single symbol, or a list containing a name and options.

Field options:
KEY ------------- override the key used for storing field in alists
READER ---------- call this function to transform values read from alists

This macro also creates AST->SNIPPET and SNIPPET->[NAME] methods.
"
  (labels ((splice (&rest symbols)
             "Splice symbols together."
             (intern (format nil "~{~a~}" symbols)))
           (field-name (field)
             "Raw name of a struct field (e.g. ast-name)"
             (if (listp field) (car field) field))
           (field-def (field)
             (if (listp field)
                 (list* (field-name field) ; name
                        nil                ; initform
                        (->> (cdr field)   ; options
                             (plist-drop :key)
                             (plist-drop :reader)))
                 field))
           (field-snippet-name (field)
             "Alist key for accessing a field within a snippet (e.g :name)."
             (or (and (listp field)
                      (plist-get :key field))
                 (make-keyword (field-name field))))
           (field-reader (field getter)
             "Code for transforming a field when building from an alist."
             (if-let ((reader (and (listp field)
                                   (plist-get :reader field))))
               `(funcall ,reader ,getter)
               getter))
           (field-accessor (field)
             "Name of the accessor function for a field (e.g. clang-ast-name)."
             (splice name "-" (field-name field)))
           (field-method (field)
             "Name of the accessor method for a field (e.g ast-name)."
             (splice (plist-get :conc-name options)
                     (field-name field))))
    `(progn
       ;; Struct definition
       (defstruct (,@(cons name (plist-drop :conc-name options)))
         ,doc
         ,@(mapcar #'field-def fields))

       (defmethod ast->snippet ((ast ,name))
         "Convert AST struct to alist."
         (list ,@(mapcar (lambda (f)
                           `(cons ,(field-snippet-name f)
                                  ,(list (field-accessor f) 'ast)))
                         fields)))

       (defun ,(splice 'snippet-> name) (snippet)
         "Convert alist to AST struct."
         ;; Read all fields from alist
         (,(splice 'make- name)
           ,@(iter (for f in fields)
                   (collect (make-keyword (field-name f)))
                   (collect (field-reader f
                                          `(aget ,(field-snippet-name f)
                                                 snippet))))))

       ;; Define getter and setter methods for all fields. These have
       ;; convenient names and (unlike the standard struct accessor
       ;; functions) can be overridden.
       ,@(iter (for f in fields)
               (collect `(defmethod ,(field-method f) ((obj ,name))
                           (,(field-accessor f) obj)))
               (collect `(defmethod (setf ,(field-method f)) (new (obj ,name))
                           (setf (,(field-accessor f) obj) new)))
               ;; Also define accessors on ast-refs
               (collect `(defmethod ,(field-method f) ((obj ast-ref))
                           (,(field-accessor f) (car (ast-ref-ast obj)))))
               (collect `(defmethod (setf ,(field-method f)) (new (obj ast-ref))
                           (setf (,(field-accessor f) (car (ast-ref-ast obj)))
                                 new)))))))

(define-ast clang-ast (:conc-name ast-)
  "AST generated by clang-mutate."
  (args :type list)
  (class :key :ast-class :reader [#'make-keyword #'string-upcase] :type symbol)
  (counter :type (or number null))
  (declares :type list)
  (expr-type :type (or number null))
  (full-stmt :type boolean)
  (guard-stmt :type boolean)
  (in-macro-expansion :type boolean)
  (includes :type list)
  (is-decl :type boolean)
  (macros :type list)
  (name :type (or string null))
  (opcode :type (or string null))
  (ret :type (or number null))
  (syn-ctx :reader [#'make-keyword #'string-upcase] :type (or symbol null))
  (types :type list)
  (unbound-funs :type list)
  (unbound-vals :type list)
  varargs
  (void-ret :type boolean)
  ;; Struct field slots
  (array-length :type (or number null))
  (base-type :type (or string null))
  (bit-field-width :type (or number null))
  ;; An alist which can store any additional data needed by clients.
  (aux-data :type list))

(define-ast clang-type (:conc-name type-)
  "TypeDB entry generated by clang-mutate."
  (array :type string)
  (col :type (or number null))
  (decl :type (or string null))
  (file :type (or string null))
  (line :type (or number null))
  (hash :type number)
  (i-file :type (or string null))
  (pointer :type boolean)
  (const :type boolean)
  (volatile :type boolean)
  (restrict :type boolean)
  (storage-class :reader [#'make-keyword #'string-upcase] :type symbol)
  (reqs :type list)
  (name :key :type :type string)
  (size :type (or number null)))

(define-ast clang-macro (:conc-name macro-)
  "MacroDB entry generated by clang-mutate."
  (hash :type number)
  (name :type string)
  (body :type string))

(defmethod print-object ((obj clang-ast) stream)
  (if *print-readably*
      (call-next-method)
      (print-unreadable-object (obj stream :type t)
        (format stream "~a ~a"
                (ast-counter obj) (ast-class obj)))))

(defgeneric roots (software)
  (:documentation "Return all top-level ASTs in SOFTWARE."))

(defmethod roots ((obj clang))
  (roots (asts obj)))

(defmethod roots ((asts list))
  (remove-if-not [{= 1} #'length #'ast-ref-path] asts))

(defvar *clang-ast-aux-fields* nil
  "Extra fields to read to clang-mutate snippets into ast-aux-data.")

(defun asts->tree (genome asts)
  (let ((roots (mapcar {aget :counter}
                       (remove-if-not [#'zerop {aget :parent-counter}] asts)))
        (ast-vector (coerce asts 'vector))
        ;; Find all multi-byte characters in the genome for adjusting
        ;; offsets later.
        (byte-offsets
         (iter (for c in-string genome)
               (with byte = 0)
               (for length = (->> (make-string 1 :initial-element c)
                                  (trivial-utf-8:utf-8-byte-length)))
               (incf byte length)
               (when (> length 1)
                 (collecting (cons byte (1- length)))))))
   (labels
       ((get-ast (id)
          (aref ast-vector (1- id)))
        (byte-offset-to-chars (offset)
          (if (eq offset :end)
              ;; Special case for end of top-level AST.
              (- (length genome) 1)

              ;; Find all the multi-byte characters at or before this
              ;; offset and accumulate the byte->character offset
              (- offset
                 (iter (for (pos . incr) in byte-offsets)
                       (while (<= pos offset))
                       (summing incr)))))
        (begin-offset (ast)
          (byte-offset-to-chars (aget :begin-off ast)))
        (end-offset (ast)
          (byte-offset-to-chars (aget :end-off ast)))
        (snippet->ast (snippet)
          (let ((ast (snippet->clang-ast snippet)))
            (setf (ast-aux-data ast)
                  (mapcar #'cons
                          *clang-ast-aux-fields*
                          (mapcar {aget _ snippet}
                                  *clang-ast-aux-fields*)))
          ast))
        (collect-children (ast)
          ;; Find child ASTs and sort them in textual order.
          (let ((children (sort (mapcar #'get-ast (aget :children ast))
                                (lambda (a b)
                                  (let ((a-begin (aget :begin-off a))
                                        (b-begin (aget :begin-off b)))
                                    ;; If ASTs start at the same place, put the
                                    ;; larger one first so parent-child munging
                                    ;; below works nicely.
                                    (if (= a-begin b-begin)
                                        (> (aget :end-off a) (aget :end-off b))
                                        (< a-begin b-begin)))))))
            ;; clang-mutate can produce siblings with overlapping source
            ;; ranges. In this case, move one sibling into the child list of the
            ;; other. See the typedef-workaround test for an example.
            (iter (for c in children)
                  (with prev)
                  (if (and prev
                           (< (aget :begin-off c) (aget :end-off prev)))
                      (progn
                        (setf (aget :end-off prev) (max (aget :end-off prev)
                                                        (aget :end-off c)))
                        (push (aget :counter c) (aget :children prev)))
                      (progn (setf prev c)
                             (collect c))))))
        (make-children (ast child-asts)
          (let ((start (begin-offset ast)))
            ;; In macro expansions, the mapping to source text is sketchy and
            ;; it's impossible to build a proper hierarchy. So don't recurse
            ;; into them. And change the ast-class so other code won't get
            ;; confused by the lack of children.
            (when (aget :in-macro-expansion ast)
              (setf (aget :ast-class ast) "MacroExpansion"))

            (if (and child-asts (not (aget :in-macro-expansion ast)))
                ;; Interleave child asts and source text
                (iter (for subtree in child-asts)
                      (for c = (car subtree))
                      ;; Collect text
                      (collect (subseq genome start (begin-offset c))
                        into children)
                      ;; Collect child, converted to AST struct
                      (collect (cons (snippet->ast c) (cdr subtree))
                        into children)
                      (setf start (+ 1 (end-offset c)))
                      (finally
                       (return
                         (append children
                                 (list (subseq genome start
                                               (+ 1 (end-offset ast))))))))
                ;; No children: create a single string child with source text
                (let ((text (subseq genome (begin-offset ast)
                                    (+ 1 (end-offset ast)))))
                  (when (not (emptyp text))
                    (list (cond ((string= "DeclRefExpr"
                                          (aget :ast-class ast))
                                 (unpeel-bananas text))
                                ((string= "MacroExpansion"
                                          (aget :ast-class ast))
                                 (reduce
                                   (lambda (new-text unbound)
                                     (regex-replace-all
                                       (format nil "(^|[^A-Za-z0-9_]+)~
                                                    (~a)~
                                                    ([^A-Za-z0-9_]+|$)"
                                               unbound)
                                       new-text
                                       (format nil "\\1~a\\3"
                                               (unpeel-bananas unbound))))
                                   (append (aget :unbound-vals ast)
                                           (mapcar [#'peel-bananas #'car]
                                                   (aget :unbound-funs ast)))
                                   :initial-value text))
                                (t text))))))))
        (unbound-vals (ast)
          (mapcar [#'peel-bananas #'car] (aget :unbound-vals ast)))
        (make-tree (ast)
          (let ((children (collect-children ast)))
            (if (aget :in-macro-expansion ast)
                ;; Remove depth from unbound-vals, keeping only names
                (setf (aget :unbound-vals ast) (unbound-vals ast))

                ;; clang-mutate aggregates types, unbound-vals, and unbound-funs
                ;; from children into parents. Undo that so it's easier to
                ;; update these properties after mutation.
                (iter (for c in children)
                      (appending (aget :types c) into child-types)
                      (appending (unbound-vals c) into child-vals)
                      (appending (aget :unbound-funs c) into child-funs)

                      (finally
                       (unless (member (aget :ast-class ast) '("Var" "ParmVar")
                                       :test #'string=)
                         (setf (aget :types ast)
                               (remove-if {member _ child-types}
                                          (aget :types ast))))

                       (setf (aget :unbound-vals ast)
                             (remove-if {member _ child-vals :test #'string=}
                                        (unbound-vals ast))

                             (aget :unbound-funs ast)
                             (remove-if {member _ child-funs :test #'equalp}
                                        (aget :unbound-funs ast))))))

            (cons ast (make-children ast (mapcar #'make-tree children))))))

     (destructuring-bind (root . children)
         (make-tree `((:ast-class . :TopLevel)
                      (:children . ,roots)
                      (:begin-off . 0)
                      (:end-off . :end)))
       (cons (snippet->clang-ast root) children)))))

(defgeneric source-text (ast)
  (:documentation "Source code corresponding to an AST."))
(defmethod source-text ((ast ast-ref))
  (source-text (ast-ref-ast ast)))

(defmethod source-text ((ast list))
  (apply #'concatenate 'string
         (iter (for c in (cdr ast))
               (collecting (if (stringp c)
                               c
                               (source-text c))))))

(defun make-statement (class syn-ctx children
                       &key expr-type full-stmt guard-stmt opcode
                         types unbound-funs unbound-vals declares
                         includes)
  "Create a statement AST.

TYPES, UNBOUND-FUNS, and UNBOUND-VALS will be computed from children
if not given."
  (labels
      ((union-child-vals (function)
         (remove-duplicates
          (apply #'append
                 (mapcar function
                         (remove-if-not #'clang-ast-p children)))
          :test #'equal)))
    (let ((types (or types (union-child-vals #'ast-types)))
          (unbound-funs (or unbound-funs
                            (union-child-vals #'ast-unbound-funs)))
          (unbound-vals (or unbound-vals
                            (union-child-vals #'ast-unbound-vals))))
      (make-ast-ref
       :path nil
       :ast (cons (make-clang-ast :class class
                                  :syn-ctx syn-ctx
                                  :expr-type expr-type
                                  :full-stmt full-stmt
                                  :guard-stmt guard-stmt
                                  :opcode opcode
                                  :types types
                                  :declares declares
                                  :unbound-funs unbound-funs
                                  :unbound-vals unbound-vals
                                  :includes includes)
                  (mapcar (lambda (c)
                            (if (ast-ref-p c)
                                (ast-ref-ast c)
                                c))
                          children))))))

(defun make-literal (kind value)
  (multiple-value-bind (class text)
      (ecase kind
        (:integer (values :IntegerLiteral
                          (format nil "~a" (round value))))
        (:float (values :FloatingLiteral
                        (format nil "~a" value)))
        (:string (values :StringLiteral
                         (format nil "~s" value)))
        (:quoted-string                 ; already has quotes, use ~a format
         (assert (and (starts-with #\" value)
                      (ends-with #\" value))
                 nil "Expected quotes around string literal ~s" value)
         (values :StringLiteral
                                (format nil "~a" value))))
    (make-statement class :generic (list text))))

(defun make-operator (syn-ctx opcode child-asts &rest args)
  "Create a unary or binary operator AST."
  (destructuring-bind (class . children)
      (ecase (length child-asts)
        (1 (cons :UnaryOperator
                 (list opcode (car child-asts))))
        (2 (cons :BinaryOperator
                 (list (first child-asts)
                       (format nil " ~a " opcode)
                       (second child-asts)))))
    (apply #'make-statement class syn-ctx children :opcode opcode args)))

(defun make-block (children)
  (make-statement :CompoundStmt :braced
                  `(,(format nil "{~%") ,@children ,(format nil "~%}"))
                  :full-stmt t))

(defun make-parens (children)
  (make-statement :ParenExpr :generic
                  `("(" ,@children ")")))

(defun make-while-stmt (syn-ctx condition body)
  (make-statement :WhileStmt syn-ctx
                  `("while ("
                    ,condition
                    ") "
                    ,body)
                  :full-stmt t))

(defun make-for-stmt (syn-ctx initialization condition update body)
  (make-statement :ForStmt syn-ctx
                  (remove nil
                          `("for ("
                            ,initialization "; "
                            ,condition "; "
                            ,update ") "
                            ,body))
                  :full-stmt t))

(defun make-if-stmt (condition then &optional else)
  (make-statement :IfStmt :fullstmt
                  (append `("if ("
                            ,condition ") "
                            ,then)
                          (unless (or (eq :CompoundStmt (ast-class then))
                                      (not else))
                            '("; "))
                          (when else
                            `(" else " ,else)))
                  :full-stmt t))

(defun make-var-reference (name type)
  (make-statement :ImplicitCastExpr :generic
                  (list (make-statement :DeclRefExpr :generic
                                        (list (unpeel-bananas name))
                                        :expr-type (type-hash type)
                                        :unbound-vals (list name)))
                  :expr-type (type-hash type)))

(defun make-var-decl (name type &optional initializer)
  (let ((decls (list name)))
    (make-statement
     :DeclStmt :fullstmt
     (list (make-statement :Var :generic
                           (if initializer
                               (list (format nil "~a ~a = "
                                             (type-decl-string type) name)
                                     initializer)
                               (list (format nil "~a ~a"
                                             (type-decl-string type) name)))
                           :types (list (type-hash type))
                           :declares decls))
     :declares decls)))

(defun make-array-subscript-expr (array-expr subscript-expr)
  (make-statement :ArraySubscriptExpr :generic
                  (list array-expr "[" subscript-expr "]")))

(defun make-cast-expr (type child)
  (make-statement :CStyleCastExpr :generic
                  (list (format nil "(~a)" (type-name type))
                        child)
                  :types (list (type-hash type))))

(defun make-call-expr (name args syn-ctx &rest rest)
  (apply #'make-statement :CallExpr syn-ctx
         `(,(make-statement :ImplictCastExpr :generic
                         (list (make-statement :DeclRefExpr :generic
                                               (list (unpeel-bananas name)))))
           "("
           ,@(interleave args ", ")
           ")")
         rest))

(defmethod get-ast ((obj clang) (path list))
  (get-ast (ast-root obj) path))

(defmethod get-ast ((tree list) (path list))
    (if path
        (destructuring-bind (head . tail) path
          (get-ast (nth head (cdr tree))
                   tail))
        tree))

(defun fixup-mutation (operation context before ast after)
  "Adjust mutation result according to syntactic context.

Adds and removes semicolons, commas, and braces. "
  (when ast
    (let ((new (copy-clang-ast (car ast))))
      ;; Make a new AST with updated values. If anything changed,
      ;; build a new subtree for it. Otherwise, use the original tree.
      (setf (ast-syn-ctx new) context)
      (setf (ast-full-stmt new) (eq context :fullstmt))
      (unless (equalp new (car ast))
        (setf ast (cons new (cdr ast))))))
  (labels
      ((no-change ()
         (list before ast after))
       (add-semicolon-if-unbraced ()
         (if (or (null ast) (ends-with #\} (source-text ast)))
             (if (starts-with #\; after)
                 (list before ast (subseq after 1))
                 (no-change))
             (add-semicolon)))
       (add-semicolon ()
         (if (or (ends-with #\; (source-text ast))
                 (starts-with #\; after))
             (no-change)
             (list before ast ";" after)))
       (add-comma ()
         (list before ast "," after))
       (wrap-with-block-if-unbraced ()
         ;; Wrap in a CompoundStmt and also add semicolon -- this
         ;; never hurts and is sometimes necessary (e.g. for loop
         ;; bodies).
         (let ((text (source-text ast)))
           (if (and (starts-with #\{ text) (ends-with #\} text))
               (no-change)
               (list before (ast-ref-ast (make-block (list ast ";")))
                     after))))
       (add-null-stmt ()
         ;; Note: clang mutate will generate a NullStmt with ";" as
         ;; its text, but here the semicolon already exists in a
         ;; parent AST.
         (list before
               (ast-ref-ast (make-statement :NullStmt :unbracedbody nil))))
       (add-null-stmt-and-semicolon ()
         (list before
               (ast-ref-ast (make-statement :NullStmt :unbracedbody '(";"))))))
    (remove nil
            (ecase context
              (:generic (no-change))
              (:fullstmt (add-semicolon-if-unbraced))
              (:listelt (ecase operation
                          (:before (add-comma))
                          (:instead (no-change))
                          (:remove (list before
                                         (if (starts-with #\, after)
                                             (subseq after 1)
                                             after)))))
              (:finallistelt (ecase operation
                               (:before (add-comma))
                               (:instead (no-change))
                               (:remove (list after))))
              (:braced
               (ecase operation
                         (:before (no-change))
                         ;; When cutting a free-floating block, we don't need a
                         ;; semicolon, but it's harmless. When cutting a braced
                         ;; loop/function body, we do need the semicolon. Since
                         ;; we can't easily distinguish these case, always add
                         ;; the semicolon.
                         (:remove (add-null-stmt-and-semicolon))
                         (:instead (wrap-with-block-if-unbraced))))
              (:unbracedbody
               (ecase operation
                 (:before (add-semicolon-if-unbraced))
                 (:remove (add-null-stmt))
                 (:instead (add-semicolon-if-unbraced))))
              (:field (ecase operation
                        (:before (add-semicolon))
                        (:instead (add-semicolon))
                        (:remove (no-change))))
              (:toplevel (add-semicolon-if-unbraced))))))

(defun replace-nth-child (ast n replacement)
  (nconc (subseq ast 0 (+ 1 n))
         (list replacement)
         (subseq ast (+ 2 n))))

(defmethod replace-ast ((tree list) (location ast-ref)
                        (replacement ast-ref))
  (labels
    ((non-empty (str)
       "Return STR only if it's not empty.

asts->tree tends to leave dangling empty strings at the ends of child
list, and we want to treat them as NIL in most cases.
"
       (when (not (emptyp str)) str))
     (helper (tree path next)
         (bind (((head . tail) path)
                ((node . children) tree))
           (if tail
               ;; The insertion may need to modify text farther up the
               ;; tree. Pass down the next bit of non-empty text and
               ;; get back a new string.
               (multiple-value-bind (child new-next)
                   (helper (nth head children) tail
                           (or (non-empty (nth (1+ head) children))
                               next))
                 (if (and new-next (non-empty (nth (1+ head) children)))
                     ;; The modified text belongs here. Insert it.
                     (values (nconc (subseq tree 0 (+ 1 head))
                                    (list child new-next)
                                    (subseq tree (+ 3 head)))
                             nil)

                     ;; Otherwise keep passing it up the tree.
                     (values (replace-nth-child tree head child)
                             new-next)))
               (let* ((after (nth (1+ head) children))
                      (fixed (fixup-mutation :instead
                                             (ast-syn-ctx (car (nth head
                                                                    children)))
                                             (if (positive-integer-p head)
                                                 (nth (1- head) children)
                                                 "")
                                             (ast-ref-ast replacement)
                                             (or (non-empty after) next))))

                 (if (non-empty after)
                     ;; fixup-mutation can change the text after the
                     ;; insertion (e.g. to remove a semicolon). If
                     ;; that text is part of this AST, just include it
                     ;; in the list.
                     (values
                      (cons node (nconc (subseq children 0 (max 0 (1- head)))
                                        fixed
                                        (nthcdr (+ 2 head) children)))
                      nil)

                     ;; If the text we need to modify came from
                     ;; farther up the tree, return it instead of
                     ;; inserting it here.
                     (values
                      (cons node (nconc (subseq children 0 (max 0 (1- head)))
                                         (butlast fixed)
                                         (nthcdr (+ 2 head) children)))
                      (lastcar fixed))))))))
    (helper tree (ast-ref-path location) nil)))

(defmethod remove-ast ((tree list) (location ast-ref))
  (labels
      ((helper (tree path)
         (bind (((head . tail) path)
                ((node . children) tree))
           (if tail
               ;; Recurse into child
               (replace-nth-child tree head (helper (nth head children) tail))

               ;; Remove child
               (cons node
                     (nconc (subseq children 0 (max 0 (1- head)))
                            (fixup-mutation
                             :remove
                             (or (&>> (car (nth head children))
                                      (ast-syn-ctx))
                                 :toplevel)
                             (if (positive-integer-p head)
                                 (nth (1- head) children)
                                 "")
                             nil
                             (or (nth (1+ head) children) ""))
                            (nthcdr (+ 2 head) children)))))))
    (helper tree (ast-ref-path location))))

(defmethod splice-asts ((tree list) (location ast-ref) (new-asts list))
  "Splice a list directly into the given location, replacing the original AST.

Can insert ASTs and text snippets. Does minimal syntactic fixups, so
use carefully.
"
  (labels
    ((helper (tree path)
       (bind (((head . tail) path)
              ((node . children) tree))
         (if tail
             ;; Recurse into child
             (replace-nth-child tree head (helper (nth head children) tail))

             ;; Splice into children
             (let ((after (nth (1+ head) children)))
               (cons node
                     (append (subseq children 0 head)
                             new-asts
                             (when (not (starts-with #\;  after))
                               (list ";"))
                             (nthcdr (1+ head) children))))))))
    (assert new-asts)
    (helper tree (ast-ref-path location))))

(defmethod insert-ast ((tree list) (location ast-ref)
                       (replacement ast-ref))
  (labels
    ((helper (tree path)
       (bind (((head . tail) path)
              ((node . children) tree))
         (if tail
             ;; Recurse into child
             (replace-nth-child tree head (helper (nth head children) tail))

             ;; Insert into children
             (cons node
                   (nconc (subseq children 0 (max 0 (1- head)))
                          (fixup-mutation :before
                                          (ast-syn-ctx (car (nth head children)))
                                          (if (positive-integer-p head)
                                              (nth (1- head) children)
                                              "")
                                          (ast-ref-ast replacement)
                                          (or (nth head children) ""))
                          (nthcdr (1+ head) children)))))))
    (helper tree (ast-ref-path location))))

(defgeneric rebind-vars (ast var-replacements fun-replacements)
  (:documentation
   "Replace variable and function references, returning a new AST."))

(defmethod rebind-vars ((ast ast-ref) var-replacements fun-replacements)
  (make-ast-ref :path (ast-ref-path ast)
                :ast (rebind-vars (ast-ref-ast ast)
                                  var-replacements fun-replacements)))

(defmethod rebind-vars ((ast list)
                        var-replacements fun-replacements)
  ;; var-replacements looks like:
  ;; ( (("(|old-name|)" "(|new-name|)") ... )
  ;; These name/depth pairs can come directly from ast-unbound-vals.

  ;; fun-replacements are similar, but the pairs are function info
  ;; lists taken from ast-unbound-funs.

  (destructuring-bind (node . children) ast
    (let ((new (copy-clang-ast node)))
      (setf (ast-unbound-vals new)
            (remove-duplicates
             (mapcar (lambda (v)
                       (or (&>> var-replacements
                             (find-if [{equal v} #'peel-bananas #'car])
                             (second)
                             (peel-bananas))
                           v))
                     (ast-unbound-vals new))
             :test #'equal))

      (cons new
            (mapcar {rebind-vars _ var-replacements fun-replacements}
                    children)))))

(defmethod rebind-vars ((ast string) var-replacements fun-replacements)
  (reduce (lambda (new-ast replacement)
            (replace-all new-ast (first replacement) (second replacement)))
          (append var-replacements
                  (mapcar (lambda (fun-replacement)
                            (list (car (first fun-replacement))
                                  (car (second fun-replacement))))
                          fun-replacements))
          :initial-value ast))

(defgeneric replace-in-ast (ast replacements &key test)
  (:documentation
   "Make arbitrary replacements within AST, returning a new AST."))

(defmethod replace-in-ast ((ast ast-ref) replacements &key (test #'eq))
  (make-ast-ref :path (ast-ref-path ast)
                :ast (replace-in-ast (ast-ref-ast ast) replacements
                                     :test test)))

(defmethod replace-in-ast ((ast list) replacements &key (test #'eq))
  (or
   ;; If replacement found, return it
   (cdr (find ast replacements :key #'car :test test))
   ;; Otherwise recurse into children
   (destructuring-bind (node . children) ast
     (cons node
           (mapcar {replace-in-ast _ replacements :test test}
                   children)))))

(defmethod replace-in-ast (ast replacements &key (test #'eq))
  (or (cdr (find ast replacements :key #'car :test test))
      ast))


;;; Handling header information (formerly "Michondria")
(defgeneric add-type (software type)
  (:documentation "Add TYPE to `types' of SOFTWARE, unique by hash."))

(defmethod add-type ((obj clang) (type clang-type))
  (unless (member (type-hash type) (types obj) :key #'type-hash)
    (if (type-i-file type)
      ;; add requisite includes for this type
      (add-include obj (type-i-file type))
      ;; only add to the genome if there isn't a type with the same type-decl
      ;; already known
      (unless (or (not (type-decl type))
                  (member (type-decl type) (types obj)
                          :key #'type-decl
                          :test #'string=))
        ;; FIXME: ideally this would insert an AST for the type decl
        ;; instead of just adding the text.
        (prepend-to-genome obj (type-decl type))))
    ;; always add type with new hash to types list
    (push type (types obj)))
  obj)
(defmethod add-type ((obj clang) (type null))
  nil)

(defmethod find-type ((obj clang) hash)
  (find-if {= hash} (types obj) :key #'type-hash))

(defmethod find-or-add-type ((obj clang) name &key
                             (pointer nil pointer-arg-p)
                             (array "" array-arg-p)
                             (const nil const-arg-p)
                             (volatile nil volatile-arg-p)
                             (restrict nil restrict-arg-p)
                             (storage-class :None storage-class-arg-p)
                             &aux (type (type-from-trace-string name)))
  "Find the type with given properties, or add it to the type DB."
  (setf (type-hash type)
        (1+ (apply #'max (mapcar #'type-hash (types obj)))))
  (when pointer-arg-p
    (setf (type-pointer type) pointer))
  (when array-arg-p
    (setf (type-array type) array))
  (when const-arg-p
    (setf (type-const type) const))
  (when volatile-arg-p
    (setf (type-volatile type) volatile))
  (when restrict-arg-p
    (setf (type-restrict type) restrict))
  (when storage-class-arg-p
    (setf (type-storage-class type) storage-class))
  (or (find-if «and [{string= (type-name type)} #'type-name]
                    [{string= (type-array type)} #'type-array]
                    [{eq (type-pointer type)} #'type-pointer]
                    [{eq (type-const type)} #'type-const]
                    [{eq (type-volatile type)} #'type-volatile]
                    [{eq (type-restrict type)} #'type-restrict]
                    [{eq (type-storage-class type)} #'type-storage-class]»
               (types obj))
      (progn (add-type obj type) type)))

(defgeneric type-decl-string (type)
  (:documentation "The source text used to declare variables of TYPE.

This will have stars on the right, e.g. char**. "))
(defmethod type-decl-string ((type clang-type))
  (format nil "~a~a~a~a~a~a~a"
          (if (type-const type) "const " "")
          (if (type-volatile type) "volatile " "")
          (if (type-restrict type) "restrict " "")
          (if (not (eq :None (type-storage-class type)))
              (format nil "~a " (->> (type-storage-class type)
                                     (symbol-name)
                                     (string-downcase)))
              "")
          (cond ((equal 0 (search "struct" (type-decl type)))
                 "struct ")
                ((equal 0 (search "union" (type-decl type)))
                 "union ")
                (t ""))
          (type-name type)
          (if (type-pointer type) " *" "")))

(defgeneric type-trace-string (type &key qualified)
  (:documentation "The text used to describe TYPE in an execution trace.

This will have stars on the left, e.g **char."))
(defmethod type-trace-string ((type clang-type) &key (qualified t))
  (concatenate 'string
               (when (type-pointer type) "*")
               (when (not (emptyp (type-array type))) (type-array type))
               (when (and qualified (type-const type)) "const ")
               (when (and qualified (type-volatile type)) "volatile ")
               (when (and qualified (type-restrict type)) "restrict ")
               (when (and qualified
                          (not (eq :None (type-storage-class type))))
                 (format nil "~a " (->> (type-storage-class type)
                                        (symbol-name)
                                        (string-downcase))))
               (type-name type)))

(defgeneric type-from-trace-string (type)
  (:documentation
   "Create a clang-type from a NAME used in an execution trace.

The resulting type will not be added to any clang object and will not have a
valid hash."))
(defmethod type-from-trace-string ((name string))
  (make-clang-type
    :pointer (or (starts-with #\* name) (ends-with #\* name))
    :array (if (starts-with #\[ name) (scan-to-strings "^\\[\\d*\\]" name) "")
    :const (not (null (search "const" name)))
    :volatile (not (null (search "volatile" name)))
    :restrict (not (null (search "restrict" name)))
    :storage-class (or (register-groups-bind (storage-class)
                           ("(extern|static|__private_extern__|auto|register)"
                            name)
                         (make-keyword (string-upcase storage-class)))
                       :None)
    :hash 0
    :size (register-groups-bind (size)
              ("^\\[(\\d+)\\]" name)
            (parse-integer size))
    :name (-> (format nil "^(\\*|\\[\\d*\\]|const |volatile |restrict |extern |~
                             static |__private_extern__ |auto |register )*")
              (regex-replace name ""))))

(defun prepend-to-genome (obj text)
  "Prepend non-AST text to genome.

New text will not be parsed. Only use this for macros, includes, etc which
don't have corresponding ASTs."
  (labels ((normalize-text (text)
             (if (not (equalp #\Newline (last-elt text)))
                 (concatenate 'string text '(#\Newline))
                 text)))
    (with-slots (ast-root) obj
      (setf ast-root
            (destructuring-bind (first second . rest) (ast-root obj)
              (list* first
                     (concatenate 'string (normalize-text text) second)
                     rest))))))

(defgeneric add-macro (software macro)
  (:documentation "Add MACRO to `macros' of SOFTWARE, unique by hash."))
(defmethod add-macro ((obj clang) (macro clang-macro))
  (unless (find-macro obj (macro-hash macro))
    (prepend-to-genome obj (format nil "#define ~a~&" (macro-body macro)))
    (push macro (macros obj)))
  obj)

(defmethod find-macro((obj clang) hash)
  (find-if {= hash} (macros obj) :key #'macro-hash))

(defgeneric add-include (software include)
  (:documentation "Add an #include directive for a INCLUDE to SOFTWARE."))
(defmethod add-include ((obj clang) (include string))
  (unless (member include (includes obj) :test #'string=)
    (prepend-to-genome obj (format nil "#include ~a~&" include))
    (push include (includes obj)))
  obj)

(defgeneric force-include (software include)
  (:documentation "Add an #include directive for an INCLUDE to SOFTWARE
even if such an INCLUDE already exists in SOFTWARE"))
(defmethod force-include ((obj clang) include)
  (prepend-to-genome obj (format nil "#include ~a~&" include))
  (unless (member include (includes obj) :test #'string=)
    (push include (includes obj)))
  obj)


;;; Constants
(define-constant +c-numeric-types+
    '("char" "short" "int" "long" "float" "double" "long double")
  :test #'equalp
  :documentation "C Numeric type names.")

(define-constant +c-relational-operators+
    '("<" "<=" "==" "!=" ">=" ">")
  :test #'equalp
  :documentation "C Relational operators.")

(define-constant +c-arithmetic-binary-operators+
    '("+" "-" "*" "/" "%")
  :test #'equalp
  :documentation "C arithmetic operators on two arguments.")

(define-constant +c-arithmetic-assignment-operators+
    '("+=" "-=" "*=" "/=" "%=")
  :test #'equalp
  :documentation "C arithmetic assignment operators.")

(define-constant +c-bitwise-binary-operators+
    '("&" "|" "^" "<<" ">>")
  :test #'equalp
  :documentation "C bitwise operators on two arguments.")

(define-constant +c-bitwise-assignment-operators+
    '("&=" "|=" "^=" "<<=" ">>=")
  :test #'equalp
  :documentation "C bitwise assignment operators.")

(define-constant +c-arithmetic-unary-operators+
    '("++" "--")
  :test #'equalp
  :documentation "C arithmetic operators on one arguments.")

(define-constant +c-bitwise-unary-operators+
    '("~" "!")
  :test #'equalp
  :documentation "C bitwise operators on one arguments.")

(define-constant +c-sign-unary-operators+
    '("+" "-" )
  :test #'equalp
  :documentation "C sign operators on one arguments.")

(define-constant +c-pointer-unary-operators+
    '("&" "*" )
  :test #'equalp
  :documentation "C pointer operators on one arguments.")

(define-constant +c-variable-modifiers+
    '("const" "enum" "extern" "long" "register" "short" "signed"
      "static" "struct" "unsigned" "volatile")
  :test #'equalp
  :documentation "C variable modifiers.")


;; Targeting functions
(defun pick-general (software first-pool &key second-pool filter)
  "Pick ASTs from FIRST-POOL and optionally SECOND-POOL, where FIRST-POOL and
SECOND-POOL are methods on SOFTWARE which return a list of ASTs.  An
optional filter function having the signature 'f ast &optional first-pick',
may be passed, returning true if the given AST should be included as a possible
pick or false (nil) otherwise."
  (let ((first-pick (&> (mutation-targets software :filter filter
                                                   :stmt-pool first-pool)
                        (random-elt))))
    (if (null second-pool)
        (list (cons :stmt1 first-pick))
        (list (cons :stmt1 first-pick)
              (cons :stmt2 (&> (mutation-targets software
                                 :filter (lambda (ast)
                                           (if filter
                                               (funcall filter ast first-pick)
                                               t))
                                 :stmt-pool second-pool)
                               (random-elt)))))))

(defmethod pick-bad-good ((software clang) &key filter)
  (pick-general software #'bad-stmts
                :second-pool #'good-stmts
                :filter filter))

(defmethod pick-bad-bad ((software clang) &key filter)
  (pick-general software #'bad-stmts
                :second-pool #'bad-stmts
                :filter filter))

(defmethod pick-bad-only ((software clang) &key filter)
  (pick-general software #'bad-stmts :filter filter))

;; Filters for use with Targetting functions
(defun full-stmt-filter (ast &optional first-pick)
  (declare (ignorable first-pick))
  (ast-full-stmt ast))

(defun same-class-filter (ast &optional first-pick)
  (if first-pick
      (eq (ast-class ast) (ast-class first-pick))
      t))


;;; Mutations
(defclass clang-mutation (mutation) ())

(defgeneric build-op (mutation software)
  (:documentation "Build clang-mutate operation from a mutation."))

;; Insert
(define-mutation clang-insert (clang-mutation)
  ((targeter :initform #'pick-bad-good)))

(defmethod build-op ((mutation clang-insert) software)
  (declare (ignorable software))
  `((:insert . ,(targets mutation))))

(define-mutation clang-insert-full (clang-insert)
  ((targeter :initform {pick-bad-good _ :filter #'full-stmt-filter})))

(define-mutation clang-insert-same (clang-insert)
  ((targeter :initform {pick-bad-good _ :filter #'same-class-filter})))

(define-mutation clang-insert-full-same (clang-insert)
  ((targeter :initform {pick-bad-good _ :filter «and #'full-stmt-filter
                                                     #'same-class-filter»})))

;;; Swap
(define-mutation clang-swap (clang-mutation)
  ((targeter :initform #'pick-bad-bad)))

(defmethod build-op ((mutation clang-swap) software)
  (declare (ignorable software))
  `((:set (:stmt1 . ,(aget :stmt1 (targets mutation)))
          (:stmt2 . ,(aget :stmt2 (targets mutation))))
    (:set (:stmt1 . ,(aget :stmt2 (targets mutation)))
          (:stmt2 . ,(aget :stmt1 (targets mutation))))))

(define-mutation clang-swap-full (clang-swap)
  ((targeter :initform {pick-bad-bad _ :filter #'full-stmt-filter})))

(define-mutation clang-swap-same (clang-swap)
  ((targeter :initform {pick-bad-bad _ :filter #'same-class-filter})))

(define-mutation clang-swap-full-same (clang-swap)
  ((targeter :initform {pick-bad-good _ :filter «and #'full-stmt-filter
                                                     #'same-class-filter»})))

;;; Move
(define-mutation clang-move (clang-mutation)
  ((targeter :initform #'pick-bad-bad)))

(defmethod build-op ((mutation clang-move) software)
  (declare (ignorable software))
  `((:insert (:stmt1 . ,(aget :stmt1 (targets mutation)))
             (:stmt2 . ,(aget :stmt2 (targets mutation))))
    (:cut (:stmt1 . ,(aget :stmt2 (targets mutation))))))

;;; Replace
(define-mutation clang-replace (clang-mutation)
  ((targeter :initform #'pick-bad-good)))

(defmethod build-op ((mutation clang-replace) software)
  (declare (ignorable software))
  `((:set . ,(targets mutation))))

(define-mutation clang-replace-full (clang-replace)
  ((targeter :initform {pick-bad-good _ :filter #'full-stmt-filter})))

(define-mutation clang-replace-same (clang-replace)
  ((targeter :initform {pick-bad-good _ :filter #'same-class-filter})))

(define-mutation clang-replace-full-same (clang-replace)
  ((targeter :initform {pick-bad-good _ :filter «and #'full-stmt-filter
                                                     #'same-class-filter»})))

;;; Cut
(define-mutation clang-cut (clang-mutation)
  ((targeter :initform #'pick-bad-only)))

(defmethod build-op ((mutation clang-cut) software)
  (declare (ignorable software))
  `((:cut . ,(targets mutation))))

(define-mutation clang-cut-full (clang-cut)
  ((targeter :initform {pick-bad-only _ :filter #'full-stmt-filter})))

;;; Set Range
(define-mutation clang-set-range (clang-mutation) ())

(defmethod build-op ((mutation clang-set-range) software)
  (declare (ignorable software))
  `((:set-range . ,(targets mutation))))

;;; Nop
(define-mutation clang-nop (clang-mutation) ())

(defmethod build-op ((mutation clang-nop) software)
  (declare (ignorable software mutation))
  nil)

;;; Promote guarded compound statement.
(define-mutation clang-promote-guarded (clang-mutation)
  ((targeter :initform #'pick-guarded-compound)))

(defgeneric pick-guarded-compound (software)
  (:documentation "Pick a guarded compound statement in SOFTWARE."))

(define-constant +clang-guarded-classes+
    '(:IfStmt :ForStmt :WhileStmt :DoStmt)
  :test #'equalp
  :documentation "Statement classes with guards")

(defmethod pick-guarded-compound ((obj clang))
  (aget :stmt1
        (pick-bad-only obj :filter [{member _ +clang-guarded-classes+}
                                    #'ast-class])))

(defmethod build-op ((mutation clang-promote-guarded) software
                     &aux (guarded (targets mutation)))
  (flet
      ((compose-children (&rest parents)
         (-<>> (iter (for p in parents)
                     ;; In case of an unbraced if/loop body, include
                     ;; the body directly.
                     (if (eq :CompoundStmt (ast-class p))
                         (appending (get-immediate-children software p))
                         (collecting p)))
               (mapcar #'ast-ref-ast)
               (interleave <>
                           (coerce (list #\; #\Newline) 'string)))))

      (let ((children
          (switch ((ast-class guarded))
            (:DoStmt
             (compose-children
              (first (get-immediate-children software guarded))))
            (:WhileStmt
             (compose-children
              (second (get-immediate-children software guarded))))
            (:ForStmt
             (compose-children
              (lastcar (get-immediate-children software guarded))))
            (:IfStmt
             (let ((children (get-immediate-children software guarded)))
               (if (= 2 (length children))
                   ;; If with only one branch.
                   (compose-children (second children))
                   ;; If with both branches.
                   (cond
                     ((null             ; Then branch is empty.
                       (get-immediate-children software (second children)))
                      (compose-children (third children)))
                     ((null             ; Else branch is empty.
                       (get-immediate-children software (third children)))
                      (compose-children (second children)))
                     (t                 ; Both branches are populated.
                      (if (random-bool) ; Both or just one.
                          (compose-children (second children) (third children))
                          (if (random-bool) ; Pick a branch randomly.
                              (compose-children (second children))
                              (compose-children (third children)))))))))
            (t (warn "`clang-promote-guarded' unimplemented for ~a"
                     (ast-class guarded))))))

        `((:splice (:stmt1 . ,guarded) (:value1 . ,children))))))

;;; Explode and coalescing mutations over for and while loops.
(define-mutation explode-for-loop (clang-mutation)
  ((targeter :initform #'pick-for-loop))
  (:documentation
   "Select a 'for' loop and explode it into it's component parts.
This mutation will transform 'for(A;B;C)' into 'A;while(B);C'."))

(defgeneric pick-for-loop (software)
  (:documentation "Pick and return a 'for' loop in SOFTWARE."))
(defmethod pick-for-loop ((obj clang))
  (pick-bad-only obj :filter [{eq :ForStmt} #'ast-class]))

(defmethod build-op ((mutation explode-for-loop) (obj clang))
  (labels ((is-initialization-ast (ast)
             (and (eq :BinaryOperator (ast-class ast))
                  (equal "=" (ast-opcode ast))))
           (is-condition-ast (ast)
             (or (eq :ImplicitCastExpr (ast-class ast))
                 (and (eq :BinaryOperator (ast-class ast))
                      (not (equal "=" (ast-opcode ast))))))
           (destructure-for-loop (ast)
             ;; Return the initialization, conditional, increment, and body
             ;; ASTS of the for-loop AST identified by ID as VALUES.
             ;;
             ;; This is an imperfect solution based on heuristics as to
             ;; probable ASTs for each part of a for loop.  These heuristics
             ;; undoubtedly will fail for some cases, and a non-compiling
             ;; individual will be created as a result.
             (let ((children (get-immediate-children obj ast)))
               (case (length children)
                 (4 (values-list children))
                 (3 (if (is-initialization-ast (first children))
                        (if (is-condition-ast (second children))
                            (values (first children)
                                    (second children)
                                    nil
                                    (third children))
                            (values (first children)
                                    nil
                                    (second children)
                                    (third children)))
                        (values nil
                                (first children)
                                (second children)
                                (third children))))
                 (2 (if (is-initialization-ast (first children))
                        (values (first children)
                                nil
                                nil
                                (second children))
                        (if (is-condition-ast (first children))
                            (values nil
                                    (first children)
                                    nil
                                    (second children))
                            (values nil
                                    nil
                                    (first children)
                                    (second children)))))
                 (1 (values nil nil nil (first children))) ; Always assume body
                 (otherwise (values nil nil nil nil))))))
    (let ((ast (aget :stmt1 (targets mutation))))
      (multiple-value-bind (initialization condition increment body)
        (destructure-for-loop ast)
        (let* ((condition (or condition
                             (make-literal :integer 1)))
               (body (make-block (if increment
                                     (list body increment ";")
                                     (list body)))))
         `((:set (:stmt1 . ,ast)
                 (:literal1 . ,(make-while-stmt (ast-syn-ctx ast)
                                                condition
                                                body)))
           .
           ,(when initialization
                  `((:insert (:stmt1 . ,ast)
                             (:literal1 . ,initialization))))))))))

(define-mutation coalesce-while-loop (clang-mutation)
  ((targeter :initform #'pick-while-loop))
  (:documentation
   "Select a 'while' loop and coalesce it into a 'for' loop.
This mutation will transform 'A;while(B);C' into 'for(A;B;C)'."))

(defgeneric pick-while-loop (software)
  (:documentation "Pick and return a 'while' loop in SOFTWARE."))
(defmethod pick-while-loop ((obj clang))
  (pick-bad-only obj :filter [{eq :WhileStmt} #'ast-class]))

(defmethod build-op ((mutation coalesce-while-loop) (obj clang))
  (let ((ast (aget :stmt1 (targets mutation))))
    (destructuring-bind (condition body)
        (get-immediate-children obj ast)
      (let ((precedent (block-predeccessor obj ast)))
        `((:set (:stmt1 . ,ast)
                ,(let ((children (get-immediate-children obj body)))
                      (cons :literal1
                            (make-for-stmt (ast-syn-ctx ast)
                                           precedent
                                           condition
                                           (&>> children (lastcar))
                                           (&>> children
                                                (butlast)
                                                (make-block))))))
          ;; Possibly consume the preceding full statement.
          ,@(when precedent
                  ;; Delete precedent
                  `((:cut (:stmt1 . ,precedent)))))))))

;;; Cut Decl
(define-mutation cut-decl (clang-mutation)
  ((targeter :initform #'pick-cut-decl)))

(defun pick-cut-decl (clang)
  (pick-bad-only clang :filter [{eq :DeclStmt} #'ast-class]))

(defmethod build-op ((mutation cut-decl) clang)
  (let* ((decl (aget :stmt1 (targets mutation)))
         (the-block (enclosing-block clang decl))
         (old-names (ast-declares decl))
         (uses (mappend (lambda (x) (get-children-using clang x the-block))
                        old-names))
         (vars (remove-if {find _ old-names :test #'equal}
                          (mapcar {aget :name}
                                  (get-vars-in-scope clang
                                    (if uses (car uses) the-block)))))
         (var (mapcar (lambda (old-name)
                        (declare (ignorable old-name))
                        (if vars
                            (random-elt vars)
                            "/* no vars before first use of cut-decl */"))
                      old-names)))
    (delete-decl-stmts clang the-block `((,decl . ,var)))))

;;; Swap Decls
(define-mutation swap-decls (clang-swap)
  ((targeter :initform #'pick-swap-decls)))

(defun pick-swap-decls (clang)
  (labels
    ((is-decl (ast)
       (eq :DeclStmt (ast-class ast)))
     (pick-another-decl-in-block (ast)
       (&>> (enclosing-block clang ast)
            (get-immediate-children clang)
            (remove-if-not [{eq :DeclStmt} #'ast-class])
            (remove-if {equalp ast})
            (random-elt))))
    (if-let ((decl (&> (bad-mutation-targets clang
                         :filter «and #'is-decl #'pick-another-decl-in-block»)
                       (random-elt))))
            `((:stmt1 . ,decl)
              (:stmt2 . ,(pick-another-decl-in-block decl))))))

;;; Rename variable
(define-mutation rename-variable (clang-mutation)
  ((targeter :initform #'pick-rename-variable))
  (:documentation
   "Replace a variable in a statement with another in scope variable name."))

(defun pick-rename-variable (clang)
  "Pick a statement in CLANG with a variable and replace with another in scope."
  (let* ((stmt (random-elt (bad-mutation-targets clang
                             :filter {get-used-variables clang})))
         (used (get-used-variables clang stmt))
         (old-var (random-elt used))
         (new-var (random-elt
                   (or (remove-if {equal old-var}
                                  (mapcar {aget :name}
                                          (get-vars-in-scope clang stmt)))
                       (list old-var))))
         (stmt1 (enclosing-full-stmt clang stmt)))
    `((:stmt1 . ,stmt1) (:old-var . ,old-var) (:new-var . ,new-var))))

(defmethod build-op ((mutation rename-variable) software)
  (declare (ignorable software))
  (let ((stmt1 (aget :stmt1 (targets mutation)))
        (old-var (aget :old-var (targets mutation)))
        (new-var (aget :new-var (targets mutation))))
    `((:set
       (:stmt1 . ,stmt1)
       (:literal1 . ,(rebind-vars stmt1
                                  (list (list (unpeel-bananas old-var)
                                              (unpeel-bananas new-var)))
                                  nil))))))

;;; Expand compound assignment or increment/decrement
(define-mutation expand-arithmatic-op (clang-replace)
  ((targeter :initform #'pick-expand-arithmatic-op)))

(defun pick-expand-arithmatic-op (clang)
  (labels ((compound-assign-op (ast) (->> (ast-class ast)
                                          (eq :CompoundAssignOperator)))
           (increment-op (ast) (and (->> (ast-class ast)
                                         (eq :UnaryOperator))
                                    (->> (ast-opcode ast)
                                         (equal "++"))))
           (decrement-op (ast) (and (->> (ast-class ast)
                                         (eq :UnaryOperator))
                                    (->> (ast-opcode ast)
                                         (equal "--")))))
    (let ((ast (&> (bad-mutation-targets clang
                     :filter «or #'compound-assign-op
                                 #'increment-op
                                 #'decrement-op»)
                   (random-elt))))
      `((:stmt1 . ,ast)
        (:literal1 .
           ,(let* ((children (get-immediate-children clang ast))
                   (lhs (first children))
                   (rhs (second children))
                   (one (make-literal :integer 1)))
              (cond
               ((increment-op ast)
                (make-operator (ast-syn-ctx ast) "="
                               (list lhs (make-operator (ast-syn-ctx lhs)
                                                        "+"
                                                        (list lhs one)))))
               ((decrement-op ast)
                (make-operator (ast-syn-ctx ast) "="
                               (list lhs (make-operator (ast-syn-ctx lhs)
                                                        "-"
                                                        (list lhs one)))))
               (t (make-operator
                   (ast-syn-ctx ast) "="
                   (list lhs
                         (make-operator (ast-syn-ctx rhs)
                                        (string-trim "="
                                                     (ast-opcode ast))
                                        (list lhs rhs))))))))))))


;;; Clang methods
(defvar *clang-max-json-size* 104857600
  "Maximum size of output accepted from `clang-mutate'.")

(defgeneric update-asts (software &key)
  (:documentation "Update the store of asts associated with SOFTWARE."))

(defgeneric asts (software)
  (:documentation "Return a list of all asts in SOFTWARE."))

(defgeneric stmts (software)
  (:documentation "Return a list of all statement asts in SOFTWARE."))

(defgeneric good-stmts (software)
  (:documentation "Return a list of all good statement asts in SOFTWARE."))

(defgeneric bad-stmts (software)
  (:documentation "Return a list of all bad statement asts in SOFTWARE."))

(defgeneric get-ast (software id)
  (:documentation "Return the statement in SOFTWARE indicated by ID."))

(defgeneric recontextualize-mutation (clang mutation)
  (:documentation "Bind free variables and functions in the mutation to concrete
values.  Additionally perform any updates to the software object required
for successful mutation (e.g. adding includes/types/macros)"))

(defmethod size ((obj clang))
  (length (asts obj)))

(defvar *clang-json-required-fields*
  '(:ast-class          :counter           :unbound-vals
    :unbound-funs       :types             :syn-ctx
    :parent-counter     :macros            :guard-stmt
    :full-stmt          :begin-addr        :end-addr
    :includes           :declares          :is-decl
    :opcode             :children          :begin-off
    :end-off            :size              :in-macro-expansion)
  "JSON database entry fields required for clang software objects.")

(defvar *clang-json-required-aux*
  '(:asts :types :macros)
  "JSON database AuxDB entries required for clang software objects.")

(defmethod genome ((obj clang))
  ;; If genome string is stored directly, use that. Otherwise,
  ;; build the genome by walking the AST.
  (if-let ((val (slot-value obj 'genome)))
    (progn (assert (null (slot-value obj 'ast-root)) (obj)
                   "Software object ~a has both genome and ASTs saved" obj)
           val)
    (peel-bananas (source-text (ast-root obj)))))

(defmethod (setf genome) :before (new (obj clang))
  (declare (ignorable new))
  (with-slots (ast-root types macros globals fitness) obj
    (setf ast-root nil
          types nil
          macros nil
          globals nil
          fitness nil))
  (clear-caches obj))

(defmethod (setf ast-root) :before (new (obj clang))
  (declare (ignorable new))
  (with-slots (globals fitness) obj
    (setf globals nil
          fitness nil))
  (clear-caches obj))

(defun function-decl-p (ast)
  "Is AST a function (or method/constructor/destructor) decl?"
  (member (ast-class ast)
          '(:Function :CXXMethod :CXXConstructor :CXXDestructor)))

(defmethod update-asts ((obj clang)
                        &key clang-mutate-args)
  ;; Avoid updates if ASTs and genome haven't changed
  (unless (asts-changed-p obj)
    (return-from update-asts))

  (clear-caches obj)
  (with-slots (asts ast-root macros types genome) obj
    (unless genome     ; get genome from existing ASTs if necessary
      (setf genome (genome obj)
            ast-root nil))

    ;; Incorporate ASTs.
    (iter (for ast in (restart-case
                          (clang-mutate obj
                            (list* :sexp
                                   (cons :fields
                                         (append *clang-ast-aux-fields*
                                                 *clang-json-required-fields*))
                                   (cons :aux *clang-json-required-aux*)
                                   clang-mutate-args))
                        (nullify-asts ()
                          :report "Nullify the clang software object."
                          nil)))
          (cond ((and (assoc :hash ast)
                      (assoc :reqs ast)
                      (assoc :type ast))
                  ;; Types
                  (collect (snippet->clang-type ast) into m-types))
                ((and (assoc :name ast)
                      (assoc :body ast)
                      (assoc :hash ast))
                 ;; Macros
                 (collect (snippet->clang-macro ast) into m-macros))
                 ;; ASTs
                ((aget :counter ast)
                 (collect ast into body))
                (t (error "Unrecognized ast.~%~S" ast)))
          (finally
           (setf ast-root (asts->tree genome body)
                 types m-types
                 macros m-macros
                 genome nil))))
  (setf (asts-changed-p obj) nil)

  obj)

(defmethod update-caches ((obj clang))
  (with-slots (asts stmt-asts non-stmt-asts functions prototypes
                    includes) obj
    ;; Collect all ast-refs
    (labels ((helper (tree path)
               (when (listp tree)
                 (cons (make-ast-ref :ast tree :path (reverse path))
                       (iter (for c in (cdr tree))
                             (for i upfrom 0)
                             (unless (stringp c)
                               (appending (helper c (cons i path)))))))))
      ;; Omit the root AST
      (setf asts (cdr (helper (ast-root obj) nil))))

    (iter (for ast in asts)
          (when (function-decl-p ast)
            (collect ast into protos)
            (when (function-body obj ast)
              (collect ast into funs)))
          (mapc (lambda (include)
                  (adjoining include into m-includes test #'string=))
                (ast-includes ast))
          (if (function-containing-ast obj ast)
              (unless (or (eq :ParmVar (ast-class ast))
                          (function-decl-p ast))
                (collect ast into my-stmts))
              (collect ast into my-non-stmts))

          (finally
           (setf stmt-asts my-stmts
                 non-stmt-asts my-non-stmts
                 includes m-includes
                 functions funs
                 prototypes protos))))
  obj)

(defmethod clear-caches ((obj clang))
  (with-slots (stmt-asts non-stmt-asts functions prototypes
                         includes asts-changed-p) obj
    (setf stmt-asts nil
          non-stmt-asts nil
          functions nil
          prototypes nil
          includes nil
          asts-changed-p t)))

(defgeneric from-file-exactly (software path)
  (:documentation
   "Initialize SOFTWARE from PATH as done by `from-string-exactly'."))

(defmethod from-file-exactly ((obj clang) path)
  (setf (ext obj) (pathname-type (pathname path)))
  (from-string-exactly obj (file-to-string path)))

(defmethod from-file ((obj clang) path)
  (setf (ext obj) (pathname-type (pathname path)))
  (from-string obj (file-to-string path))
  obj)

(defgeneric from-string-exactly (software string)
  (:documentation
   "Create a clang software object from a given C file's string representation.
The software object's genome will exactly match the input file's
contents aside from some simple transformations to ease downstream
processing.

Currently the only such transformation is to split variable
declarations onto multiple lines to ease subsequent decl mutations."))

(defun balanced-parens-or-curlies (pos)
  (let ((parens (balanced-parens pos))
        (curlies (balanced-curlies pos)))
    (when parens
      parens
      curlies)))

(defun balanced-parens (pos &aux (deep 0) escape in-string)
  (iter (while (< pos (length ppcre::*string*)))
        (as char = (aref ppcre::*string* pos))
        (cond
          ;; Last char was a backslash, skip over this one
          (escape (setf escape nil))
          ;; Start or end of a quoted string
          ((eq char #\")
           (setf in-string (not in-string)))
          ;; Ignore parens, etc within a quoted string
          ((not in-string)
           (case char
              (#\( (incf deep))
              (#\) (when (zerop deep) (return-from balanced-parens nil))
                   (decf deep))
              (#\,
               (when (zerop deep) (return-from balanced-parens pos)))
              (#\;
               (return-from balanced-parens pos)))))
        (incf pos))
  (if (zerop deep) pos nil))

(defun balanced-curlies (pos &aux (deep 0))
  (iter (while (< pos (length ppcre::*string*)))
        (as char = (aref ppcre::*string* pos))
        (case char
          (#\{ (incf deep))
          (#\} (when (zerop deep) (return-from balanced-curlies nil))
               (decf deep))
          (#\,
           (when (zerop deep) (return-from balanced-curlies pos)))
          (#\;
           (return-from balanced-curlies pos)))
        (incf pos))
  (if (zerop deep) pos nil))


(defun split-balanced-parens (string &aux (start 0) (str-len (length string)))
  (->> (iter (for (values match-start match-end match-begs match-ends)
                  = (scan '(:register (:filter balanced-parens)) string
                          :start start))
             (declare (ignorable match-start))
             (while (and match-end (< start str-len)))
             (collecting (subseq string (aref match-begs 0)
                                 (aref match-ends 0)))
             (if (< start match-end)
                 (setf start match-end)
                 (incf start)))
       (remove-if [#'zerop #'length])))

(defmethod from-string-exactly ((obj clang) string &aux (index 0))
  ;; TODO: Improve clang-mutate so we no longer need this hack.
  ;; Find every probable multi-variable declaration, then split.
  (let ((regex
         (create-scanner
          `(:sequence                   ; Preceding newline.
            (:char-class #\{ #\} #\;)
            (:greedy-repetition 0 nil :whitespace-char-class) #\newline
            (:register                  ; Type name.
             (:sequence
              (:greedy-repetition 0 nil :whitespace-char-class)
              (:greedy-repetition
               0 nil
               (:sequence               ; Type name modifiers.
                (:alternation ,@+c-variable-modifiers+)
                :whitespace-char-class))
              (:negative-lookahead "else") ; Blacklist "else" keyword
              (:greedy-repetition 1 nil :word-char-class)
              (:greedy-repetition 0 1 #\*)
              (:greedy-repetition 1 nil :whitespace-char-class)))
            (:register                  ; All variables.
             (:sequence
              (:greedy-repetition       ; First variable.
               1 nil
               (:char-class #\* :whitespace-char-class :word-char-class))
              (:greedy-repetition
               0 1
               (:register               ; Optional initialization.
                (:sequence #\=
                           (:greedy-repetition 0 nil :whitespace-char-class)
                           (:filter balanced-parens-or-curlies))))
              #\, (:greedy-repetition 1 nil (:inverted-char-class #\;))
              (:greedy-repetition       ; Subsequent variables.
               0 1
               (:register
                (:sequence #\=          ; Optional initialization.
                           (:greedy-repetition 0 nil :whitespace-char-class)
                           (:filter balanced-parens-or-curlies))))))
            #\; (:greedy-repetition 0 nil :whitespace-char-class) #\newline))))
    (iter (for (values match-start match-end match-type match-vars)
               = (scan regex string :start index))
          (declare (ignorable match-start))
          (while match-end)
          ;; C has strict limits on valid strings, so we don't have to
          ;; worry about being inside of a string.
          (concatenating
           (concatenate 'string
             (subseq string index (aref match-type 0))
             (let* ((type
                     (string-right-trim (list #\Space #\Tab #\Newline)
                                        (subseq string
                                                (aref match-type 0)
                                                (aref match-type 1)))))
               (mapconcat [{concatenate 'string type " "}
                           {string-left-trim (list #\Space #\Tab #\Newline)}]
                          (split-balanced-parens
                           (subseq string (aref match-vars 0)
                                   (aref match-vars 1)))
                          (coerce (list #\; #\Newline) 'string))))
           into out-str)
          (setf index (aref match-vars 1))
          (finally (setf (genome obj)
                         (concatenate 'string
                           out-str (subseq string index))))))
  obj)

(defmethod from-string ((obj clang) string)
  ;; Load the raw string and generate a json database
  (from-string-exactly obj string)
  obj)

(defmethod update-asts-if-necessary ((obj clang))
  (with-slots (ast-root) obj (unless ast-root (update-asts obj))))

(defmethod update-caches-if-necessary ((obj clang))
  (with-slots (stmt-asts) obj (unless stmt-asts (update-caches obj))))

(defmethod      ast-root :before ((obj clang)) (update-asts-if-necessary obj))
(defmethod          size :before ((obj clang)) (update-asts-if-necessary obj))

(defmethod          asts :before ((obj clang)) (update-caches-if-necessary obj))
(defmethod     stmt-asts :before ((obj clang)) (update-caches-if-necessary obj))
(defmethod non-stmt-asts :before ((obj clang)) (update-caches-if-necessary obj))
(defmethod     functions :before ((obj clang)) (update-caches-if-necessary obj))
(defmethod    prototypes :before ((obj clang)) (update-caches-if-necessary obj))
(defmethod      includes :before ((obj clang)) (update-caches-if-necessary obj))
(defmethod         types :before ((obj clang)) (update-caches-if-necessary obj))
(defmethod        macros :before ((obj clang)) (update-caches-if-necessary obj))
(defmethod       globals :before ((obj clang)) (update-caches-if-necessary obj))

(defmethod ast-at-index ((obj clang) index)
  (nth index (asts obj)))

(defmethod index-of-ast ((obj clang) (ast ast-ref))
  (position ast (asts obj) :test #'equalp))

(defmethod recontextualize ((clang clang) (ast ast-ref) (pt ast-ref))
  (bind-free-vars clang ast pt))

(defmethod get-parent-decls ((clang clang) ast)
  (remove-if-not #'ast-is-decl (get-parent-asts clang ast)))

(defmethod good-stmts ((clang clang))
  (stmt-asts clang))

(defmethod bad-stmts ((clang clang))
  (stmt-asts clang))

(defmethod pick-good ((clang clang))
  (random-elt (good-mutation-targets clang)))

(defmethod pick-bad ((clang clang))
  (random-elt (bad-mutation-targets clang)))

(defmethod good-mutation-targets ((clang clang) &key filter)
  (mutation-targets clang :filter filter :stmt-pool #'good-stmts))

(defmethod bad-mutation-targets ((clang clang) &key filter)
  (mutation-targets clang :filter filter :stmt-pool #'bad-stmts))

(defmethod mutation-targets ((clang clang) &key (filter nil)
                                                (stmt-pool #'stmt-asts))
  "Return a list of target ASTs from STMT-POOL for mutation, throwing
a 'no-mutation-targets exception if none are available.

:FILTER ------ filter AST from consideration when this function returns nil
:STMT-POOL --- method on CLANG returning a list of ASTs"
  (labels ((do-mutation-targets ()
             (if-let ((target-stmts
                        (if filter
                            (remove-if-not filter (funcall stmt-pool clang))
                            (funcall stmt-pool clang))))
                target-stmts
                (error (make-condition 'no-mutation-targets
                         :obj clang :text "No stmts match the given filter")))))
    (if (equalp stmt-pool #'stmt-asts)
        (do-mutation-targets)
        (restart-case
            (do-mutation-targets)
          (expand-stmt-pool ()
            :report "Expand statement pool for filtering to all statement ASTs"
            (mutation-targets clang :filter filter))))))

(defvar *free-var-decay-rate* 0.3
  "The decay rate for choosing variable bindings.")

(defvar *matching-free-var-retains-name-bias* 0.75
  "The probability that if a free variable's original name matches a name
already in scope, it will keep that name.")

(defvar *matching-free-function-retains-name-bias* 0.95
  "The probability that if a free functions's original name matches a name
already in scope, it will keep that name.")

(defvar *crossover-function-probability* 0.25
  "The probability of crossing a function during whole-program crossover.")

(defvar *clang-mutation-types*
  (cumulative-distribution
   (normalize-probabilities
    '((cut-decl                .  5)    ; All values are /100 total.
      (swap-decls              .  5)
      (rename-variable         .  5)
      (clang-promote-guarded   .  2)
      (explode-for-loop        .  1)
      (coalesce-while-loop     .  1)
      (expand-arithmatic-op    .  1)
      (clang-cut               .  5)
      (clang-cut-full          . 15)
      (clang-insert            .  1)
      (clang-insert-same       .  4)
      (clang-insert-full       .  4)
      (clang-insert-full-same  . 11)
      (clang-swap              .  1)
      (clang-swap-same         .  4)
      (clang-swap-full         .  4)
      (clang-swap-full-same    .  6)
      (clang-move              .  5)
      (clang-replace           .  1)
      (clang-replace-same      .  4)
      (clang-replace-full      .  4)
      (clang-replace-full-same . 11))))
  "Cumulative distribution of normalized probabilities of weighted mutations.")

(defmethod pick-mutation-type ((obj clang))
  (random-pick *clang-mutation-types*))

(defmethod mutate ((clang clang))
  (unless (stmt-asts clang)
    (error (make-condition 'mutate :text "No valid statements" :obj clang)))
  (restart-case
      (let ((mutation
             (make-instance (pick-mutation-type clang) :object clang)))
        (apply-mutation clang mutation)
        (values clang mutation))
    (try-another-mutation ()
      :report "Try another mutation"
      (mutate clang))))

(defun ast-later-p (ast-a ast-b)
  "Is AST-A later in the genome than AST-B?

Use this to sort AST asts for mutations that perform multiple
operations.
"
  (labels
      ((path-later-p (a b)
         (cond
           ;; Consider longer asts to be later, so in case of nested ASTs we
           ;; will sort inner one first. Mutating the outer AST could
           ;; invalidate the inner ast.
           ((null a) nil)
           ((null b) t)
           (t (bind (((head-a . tail-a) a)
                     ((head-b . tail-b) b))
                (cond
                  ((> head-a head-b) t)
                  ((> head-b head-a) nil)
                  (t (path-later-p tail-a tail-b))))))))
    (path-later-p (ast-ref-path ast-a) (ast-ref-path ast-b))))

(defmethod recontextualize-mutation ((obj clang) (mut mutation))
  (recontextualize-mutation obj (build-op mut obj)))

(defmethod recontextualize-mutation ((obj clang) (ops list))
  (loop :for (op . properties) :in ops
     :collecting
     (let ((stmt1  (aget :stmt1  properties))
           (stmt2  (aget :stmt2  properties))
           (value1 (aget :value1 properties))
           (literal1 (aget :literal1 properties)))
       (case op
         ((:cut :set :insert)
          (cons op
            (cons (cons :stmt1 stmt1)
                  (if (or stmt2 value1 literal1)
                      `((:value1 .
                            ,(if literal1 literal1
                                 (recontextualize
                                    obj
                                    (or stmt2 value1)
                                    stmt1))))))))
         ;; Other ops are passed through without changes
         (otherwise (cons op properties))))))

(defun apply-clang-mutate-ops (software ops &aux (tu 0))
  "Run clang-mutate with a list of mutation operations, and update the genome."
  ;; If we multiplex multiple software objects onto one clang-mutate
  ;; invocation, they will need to track their own TU ids.  With one
  ;; software object, it will always be TU 0.
  (setf (genome software)
        (clang-mutate software '(:scripted) :script
                      (format nil "reset ~a; ~{~a; ~}preview ~a"
                              tu
                              (mapcar {mutation-op-to-cmd tu} ops)
                              tu)))
  software)

(defun apply-mutation-ops (software ops)
  (with-slots (ast-root) software
    (iter (for (op . properties) in ops)
          (let ((stmt1 (aget :stmt1 properties))
                (value1 (aget :value1 properties)))
            (setf (ast-root software)
                  (ecase op
                    (:set (replace-ast ast-root stmt1 value1))
                    (:cut (remove-ast ast-root stmt1))
                    (:insert (insert-ast ast-root stmt1 value1))
                    (:splice (splice-asts ast-root stmt1 value1)))))))
  (clear-caches software)
  software)

(defmethod apply-mutation ((software clang)
                           (mutation clang-mutation))
  (restart-case
      (apply-mutation-ops software
                          ;; Sort operations latest-first so they
                          ;; won't step on each other.
                          (sort (recontextualize-mutation software mutation)
                                #'ast-later-p :key [{aget :stmt1} #'cdr]))
    (skip-mutation ()
      :report "Skip mutation and return nil"
      (values nil 1))
    (tidy ()
      :report "Call clang-tidy before re-attempting mutation"
      (clang-tidy software)
      (apply-mutation software mutation))
    (mutate ()
      :report "Apply another mutation before re-attempting mutations"
      (mutate software)
      (apply-mutation software mutation))))

;; Convenience form for compilation fixers, crossover, etc
(defmethod apply-mutation ((clang clang) (op list))
  (apply-mutation clang (make-instance (car op) :targets (cdr op))))

(defmethod mutation-key ((obj clang) op)
  ;; Return a list of the mutation type, and the classes of any stmt1 or
  ;; stmt2 arguments.
  (cons
   (type-of op)
   (mapcar [#'ast-class {get-ast obj} #'cdr]
           (remove-if-not [#'numberp #'cdr]
                          (remove-if-not [{member _ (list :stmt1 :stmt2)} #'car]
                                         (remove-if-not #'consp (targets op)))))))

(defun mutation-op-to-cmd (tu op)
  (labels ((ast (tag) (format nil "~a.~a" tu (aget tag (cdr op))))
           (str (tag) (json:encode-json-to-string (aget tag (cdr op)))))
    (ecase (car op)
      (:cut
       (format nil "cut ~a" (ast :stmt1)))
      (:insert
       (format nil "get ~a as $stmt; before ~a $stmt"
               (ast :stmt1) (ast :stmt2)))
      (:insert-value
       (format nil "before ~a ~a" (ast :stmt1) (str :value1)))
      (:insert-value-after
       (format nil "after ~a ~a" (ast :stmt1) (str :value1)))
      (:swap
       (format nil "swap ~a ~a" (ast :stmt1) (ast :stmt2)))
      (:set
       (format nil "set ~a ~a" (ast :stmt1) (str :value1)))
      (:set2
       (format nil "set ~a ~a ~a ~a"
               (ast :stmt1) (str :value1)
               (ast :stmt2) (str :value2)))
      (:set-range
       (format nil "set-range ~a ~a ~a"
               (ast :stmt1) (ast :stmt2) (str :value1)))
      (:set-func
       (format nil "set-func ~a ~a" (ast :stmt1) (str :value1)))
      (:ids
       (format nil "ids ~a" tu))
      (:list
       (format nil "list ~a" tu))
      (:sexp
       (let ((aux (if (aget :aux (cdr op))
                      (format nil "aux=~{~a~^,~}" (aget :aux (cdr op)))
                      ""))
             (fields (if (aget :fields (cdr op))
                         (format nil "fields=~{~a~^,~}" (aget :fields (cdr op)))
                         "")))
         (if (aget :stmt1 (cdr op))
             (format nil "ast ~a ~a" (ast :stmt1) fields)
             (format nil "sexp ~a ~a ~a" (ast :stmt1) fields aux)))))))

(defmethod clang-mutate ((obj clang) op
                         &key script
                         &aux value1-file value2-file)
  (assert (ext obj) (obj)
          "Software object ~a has no extension, required by clang-mutate."
          obj)
  (with-temp-file-of (src-file (ext obj)) (genome obj)
    (labels ((command-opt (command)
               (ecase command
                 (:cut "-cut")
                 (:insert "-insert")
                 (:insert-value "-insert-value")
                 (:swap "-swap")
                 (:set "-set")
                 (:set2 "-set2")
                 (:set-range "-set-range")
                 (:set-func  "-set-func")
                 (:ids "-ids")
                 (:list "-list")
                 (:sexp "-sexp")
                 (:scripted "-interactive -silent")))
             (option-opt (pair)
               (let ((option (car pair))
                     (value (cdr pair)))
                 (ecase option
                   (:stmt1 (format nil "-stmt1=~d" value))
                   (:stmt2 (format nil "-stmt2=~d" value))
                   (:fields (format nil "-fields=~a"
                                    (mapconcat #'field-opt value ",")))
                   (:aux (format nil "-aux=~a"
                                 (mapconcat #'aux-opt value ",")))
                   (:value1
                    (setf value1-file (temp-file-name))
                    (string-to-file value value1-file)
                    (format nil "-file1=~a" value1-file))
                   (:value2
                    (setf value2-file (temp-file-name))
                    (string-to-file value value2-file)
                    (format nil "-file2=~a" value2-file))
                   (:bin (format nil "-binary=~a" value))
                   (:dwarf-src-file-path
                    (format nil "-dwarf-filepath-mapping=~a=~a"
                            value src-file))
                   (:cfg "-cfg"))))
             (field-opt (field)
               (ecase field
                 (:counter "counter")
                 (:declares "declares")
                 (:is-decl "is_decl")
                 (:parent-counter "parent_counter")
                 (:ast-class "ast_class")
                 (:src-file-name "src_file_name")
                 (:begin-src-line "begin_src_line")
                 (:begin-src-col "begin_src_col")
                 (:end-src-line "end_src_line")
                 (:end-src-col "end_src_col")
                 (:src-text "src_text")
                 (:guard-stmt "guard_stmt")
                 (:full-stmt "full_stmt")
                 (:unbound-vals "unbound_vals")
                 (:unbound-funs "unbound_funs")
                 (:macros "macros")
                 (:types "types")
                 (:stmt-list "stmt_list")
                 (:binary-file-path "binary_file_path")
                 (:scopes "scopes")
                 (:begin-addr "begin_addr")
                 (:end-addr "end_addr")
                 (:includes "includes")
                 (:opcode "opcode")
                 (:children "children")
                 (:successors "successors")
                 (:begin-off "begin_off")
                 (:end-off "end_off")
                 (:begin-norm-off "begin_norm_off")
                 (:end-norm-off "end_norm_off")
                 (:orig-text "orig_text")
                 (:binary-contents "binary_contents")
                 (:base-type "base_type")
                 (:bit-field-width "bit_field_width")
                 (:array-length "array_length")
                 (:in-macro-expansion "in_macro_expansion")
                 (:expr-type "expr_type")
                 (:syn-ctx "syn_ctx")
                 (:size "size")))
             (aux-opt (aux)
               (ecase aux
                 (:types "types")
                 (:asts "asts")
                 (:decls "decls")
                 (:macros "macros")
                 (:none "none"))))
    (let ((json:*identifier-name-to-key* 'se-json-identifier-name-to-key))
      (unwind-protect
        (multiple-value-bind (stdout stderr exit)
            (shell-with-input script
                              "clang-mutate ~a ~{~a~^ ~} ~a -- ~{~a~^ ~}"
                              (command-opt (car op))
                              (mapcar #'option-opt (cdr op))
                              src-file
                              (flags obj))
          (declare (ignorable stderr))
          ;; NOTE: The clang-mutate executable will sometimes produce
          ;;       usable output even on a non-zero exit, e.g., usable
          ;;       json or successful mutations but an exit of 1
          ;;       because of compiler errors.  To ensure these cases
          ;;       are still usable, we only signal mutation errors on
          ;;       specific exit values.
          (when (find exit '(131 132 134 136 139))
            (error
             (make-condition 'mutate
               :text (format nil "clang-mutate core dump, ~d," exit)
               :obj obj :op op)))
          ;; NOTE: If clang-mutate output exceeds 10 MB, this is likely due
          ;; to an insertion which is technically legal via the standard,
          ;; but is actually meaningless.  This tends to happen with array
          ;; initialization forms (e.g { 254, 255, 256 ... }) being inserted
          ;; and interpreted as a block.  Throw an error to clear the genome.
          (when (> (length stdout) *clang-max-json-size*)
            (error (make-condition 'mutate
                     :text (format nil "clang-mutate output exceeds ~a MB."
                                   (floor (/ *clang-max-json-size*
                                             1048576)))
                     :obj obj :op op)))
          (values
           (case (car op)
             (:sexp (read-from-string stdout))
             (t stdout))
           exit))
      ;; Cleanup forms.
      (when (and value1-file (probe-file value1-file))
        (delete-file value1-file))
      (when (and value2-file (probe-file value2-file))
        (delete-file value2-file)))))))


;;; AST Utility functions
(defun ast-to-source-range (obj ast)
  "Convert AST to pair of SOURCE-LOCATIONS."
  (labels
      ((scan-ast (ast line column)
         "Scan entire AST, updating line and column. Return the new values."
         (if (stringp ast)
             ;; String literal
             (iter (for char in-string ast)
                   (incf column)
                   (when (eq char #\newline)
                     (incf line)
                     (setf column 1)))

             ;; Subtree
             (iter (for child in (cdr ast))
               (multiple-value-setq (line column)
                 (scan-ast child line column))))

         (values line column))
       (ast-start (ast path line column)
         "Scan to the start of an AST, returning line and column."
         (bind (((head . tail) path)
                ((_ . children) ast))
           ;; Scan preceeding ASTs
           (iter (for child in (subseq children 0 head))
                 (multiple-value-setq (line column)
                   (scan-ast child line column)))
           ;; Recurse into child
           (when tail
             (multiple-value-setq (line column)
               (ast-start (nth head children) tail line column)))
           (values line column))))

    (when ast
      (bind (((:values start-line start-col)
              (ast-start (ast-root obj) (ast-ref-path ast) 1 1))
             ((:values end-line end-col)
              (scan-ast (ast-ref-ast ast) start-line start-col)))
       (make-instance 'source-range
                      :begin (make-instance 'source-location
                                            :line start-line
                                            :column start-col)
                      :end (make-instance 'source-location
                                          :line end-line
                                          :column end-col))))))

;; FIXME: these are inefficient now -- they scan linearly through the
;; tree for each individual AST. We could do better when ranges are
;; needed for all ASTs.
(defmethod asts-containing-source-location ((obj clang) (loc source-location))
  (when loc
    (remove-if-not [{contains _ loc} {ast-to-source-range obj}] (asts obj))))

(defmethod asts-contained-in-source-range ((obj clang) (range source-range))
  (when range
    (remove-if-not [{contains range} {ast-to-source-range obj}] (asts obj))))

(defmethod asts-intersecting-source-range ((obj clang) (range source-range))
  (when range
    (remove-if-not [{intersects range} {ast-to-source-range obj}] (asts obj))))

(defmethod line-breaks ((clang clang))
  (cons 0 (loop :for char :in (coerce (genome clang) 'list) :as index
                :from 0
                :when (equal char #\Newline) :collect index)))

(defgeneric parent-ast-p (software possible-parent-ast ast)
  (:documentation
   "Check if POSSIBLE-PARENT-AST is a parent of AST in SOFTWARE."))

(defmethod parent-ast-p ((clang clang) possible-parent-ast ast)
  (member possible-parent-ast (get-parent-asts clang ast)
          :test #'equalp))

(defmethod get-parent-ast ((obj clang) (ast ast-ref))
  (when-let ((path (butlast (ast-ref-path ast))))
    (make-ast-ref :ast (get-ast obj path)
                  :path path)))

(defmethod get-parent-asts ((clang clang) (ast ast-ref))
  (iter (for p on (reverse (ast-ref-path ast)))
        (for path = (reverse p))
        (collect (make-ast-ref :ast (get-ast clang path)
                               :path path))))

(defgeneric get-immediate-children (sosftware ast)
  (:documentation "Return the immediate children of AST in SOFTWARE."))

(defmethod get-immediate-children ((clang clang) (ast ast-ref))
  (let ((path (ast-ref-path ast)))
    (iter (for child in (cdr (ast-ref-ast ast)))
          (for i upfrom 0)
          (when (listp child)
            (collect (make-ast-ref :ast child :path (append path (list i))))))))

(defgeneric function-body (software ast)
  (:documentation
   "If AST-PATH is a function AST, return the AST representing its body."))

(defmethod function-body ((software clang) (ast ast-ref))
  (when (function-decl-p ast)
    (find-if [{eq :CompoundStmt} #'ast-class]
             (get-immediate-children software ast))))

(defgeneric get-parent-full-stmt (software ast)
  (:documentation
   "Return the first ancestor of AST in SOFTWARE which is a full stmt.
Returns nil if no full-stmt parent is found."))

(defmethod get-parent-full-stmt ((clang clang) (ast ast-ref))
  (cond ((ast-full-stmt ast) ast)
        (ast (get-parent-full-stmt clang (get-parent-ast clang ast)))))

(defgeneric stmt-range (software function)
  (:documentation
   "The indices of the first and last statements in a function.

Return as a list of (first-index last-index). Indices are positions in
the list returned by (asts software)."  ) )

(defmethod stmt-range ((software clang) (function ast-ref))
  (labels
      ((rightmost-child (ast)
         (if-let ((children (get-immediate-children software ast)))
           (rightmost-child (lastcar children))
           ast)))
    (when-let ((body (function-body software function)))
      (mapcar {index-of-ast software}
              (list body (rightmost-child body))))))

(defgeneric wrap-ast (software ast)
  (:documentation "Wrap AST in SOFTWARE in a compound statement.
Known issue with ifdefs -- consider this snippet:

    if (x) {
      var=1;
    #ifdef SOMETHING
    } else if (y) {
      var=2;
    #endif
    }

it will transform this into:

    if (x) {
      var=1;
    #ifdef SOMETHING
    } else {
        if (y) {
          var=2;
    #endif
        }  // spurious -- now won't compile.
    }"))

(defmethod wrap-ast ((obj clang) (ast ast-ref))
  (apply-mutation obj
                  `(clang-replace (:stmt1 . ,ast)
                                  (:literal1 . ,(make-block (list ast ";")))))
  obj)

(define-constant +clang-wrapable-parents+
    '(:WhileStmt :IfStmt :ForStmt :DoStmt :CXXForRangeStmt)
  :test #'equalp
  :documentation "Types which can be wrapped.")

(defgeneric wrap-child (software ast index)
  (:documentation "Wrap INDEX child of AST in SOFTWARE in a compound stmt."))

(defmethod wrap-child ((obj clang) (ast ast-ref) (index integer))
  (if (member (ast-class ast) +clang-wrapable-parents+)
      (wrap-ast obj (nth index (get-immediate-children obj ast)))
      (error "Will not wrap children of type ~a, only useful for ~a."
             (ast-class ast) +clang-wrapable-parents+))
  obj)

(defgeneric can-be-made-traceable-p (software ast)
  (:documentation "Check if AST can be made a traceable statement in SOFTWARE."))

(defmethod can-be-made-traceable-p ((obj clang) (ast ast-ref))
  (or (traceable-stmt-p obj ast)
      (unless (or (ast-guard-stmt ast) ; Don't wrap guard statements.
                  (string= :CompoundStmt ; Don't wrap CompoundStmts.
                           (ast-class ast)))
        (when-let ((parent (get-parent-ast obj ast)))
          ;; Is a child of a statement which might have a hanging body.
          (member (ast-class parent) +clang-wrapable-parents+
                  :test #'string=)))))

(defgeneric enclosing-traceable-stmt (software ast)
  (:documentation
   "Return the first ancestor of AST in SOFTWARE which may be a full stmt.
If a statement is reached which is not itself full, but which could be
made full by wrapping with curly braces, return that."))

(defmethod enclosing-traceable-stmt ((obj clang) (ast ast-ref))
  (cond
    ((traceable-stmt-p obj ast) ast)
    ;; Wrap AST in a CompoundStmt to make it traceable.
    ((can-be-made-traceable-p obj ast) ast)
    (:otherwise
     (&>> (get-parent-ast obj ast)
          (enclosing-traceable-stmt obj)))))

(defgeneric traceable-stmt-p (software ast)
  (:documentation
   "Return TRUE if AST is a traceable statement in SOFTWARE."))

(defmethod traceable-stmt-p ((obj clang) (ast ast-ref))
  (and (ast-full-stmt ast)
       (not (function-decl-p ast))
       (get-parent-ast obj ast)
       (get-parent-ast obj ast)
       (eq :CompoundStmt (ast-class (get-parent-ast obj ast)))))

(defmethod nesting-depth ((clang clang) stmt &optional orig-depth)
  (let ((depth (or orig-depth 0)))
    (if (null stmt)
        depth
        (nesting-depth clang (enclosing-block clang stmt) (1+ depth)))))

(defmethod enclosing-block ((clang clang) (ast ast-ref))
  ;; First parent AST is self, skip over that.
  (find-if {block-p clang} (cdr (get-parent-asts clang ast))))

(defgeneric full-stmt-p (software statement)
  (:documentation "Check if STATEMENT is a full statement in SOFTWARE."))

(defmethod full-stmt-p ((obj clang) (stmt ast-ref))
  (declare (ignorable obj))
  (ast-full-stmt stmt))

(defgeneric guard-stmt-p (software statement)
  (:documentation "Check if STATEMENT is a guard statement in SOFTWARE."))

(defmethod guard-stmt-p ((obj clang) (stmt ast-ref))
  (declare (ignorable obj))
  (ast-guard-stmt stmt))

(defgeneric block-p (software statement)
  (:documentation "Check if STATEMENT is a block in SOFTWARE."))

(defmethod block-p ((obj clang) (stmt ast-ref))
  (or (eq :CompoundStmt (ast-class stmt))
      (and (member (ast-class stmt) +clang-wrapable-parents+)
           (not (null (->> (get-immediate-children obj stmt)
                           (remove-if «or {guard-stmt-p obj}
                                          [{eq :CompoundStmt}
                                           #'ast-class]»)))))))

(defgeneric enclosing-full-stmt (software stmt)
  (:documentation
   "Return the first full statement in SOFTWARE holding STMT."))

(defmethod enclosing-full-stmt ((obj clang) (stmt ast-ref))
  (find-if #'ast-full-stmt (get-parent-asts obj stmt)))

(defun get-entry-after (item list)
  (cond ((null list) nil)
        ((not (equalp (car list) item)) (get-entry-after item (cdr list)))
        ((null (cdr list)) nil)
        (t (cadr list))))

(defun get-entry-before (item list &optional saw)
  (cond ((null list) nil)
        ((equalp (car list) item) saw)
        (t (get-entry-before item (cdr list) (car list)))))

(defmethod block-successor ((clang clang) ast)
  (let* ((full-stmt (enclosing-full-stmt clang ast))
         (the-block (enclosing-block clang full-stmt))
         (the-stmts (remove-if-not «or {block-p clang}
                                       {full-stmt-p clang}»
                                   (get-immediate-children clang the-block))))
    (get-entry-after full-stmt the-stmts)))

(defmethod block-predeccessor ((clang clang) ast)
  (let* ((full-stmt (enclosing-full-stmt clang ast))
         (the-block (enclosing-block clang full-stmt))
         (the-stmts (remove-if-not «or {block-p clang}
                                       {full-stmt-p clang}»
                                   (get-immediate-children clang the-block))))
    (get-entry-before full-stmt the-stmts)))

(defmethod full-stmt-predecessors ((clang clang) ast &optional acc blocks)
  "All full statements and blocks preceeding AST.

Predecessors are listed starting from the beginning of the containing
function, and grouped by nesting level. The last statement of each
sublist is the parent of the statements in the next sublist.

Ends with AST.
"

  (if (not (ast-full-stmt ast))
      ;; Reached a non-full statement. Go up to the enclosing
      ;; statement.
      (full-stmt-predecessors clang
                              (enclosing-full-stmt clang ast)
                              nil
                              (cons (cons ast acc)
                                    blocks))
      (if (null (enclosing-block clang ast))
          ;; We've made it to the top-level scope; return the accumulator
          (if (null acc)
              blocks
              (cons acc blocks))
          ;; Not at top level yet
          (let ((prev-stmt (block-predeccessor clang ast))
                (new-acc (cons ast acc)))
            (if prev-stmt
                ;; Middle of block. Accumulate and keep going.
                (full-stmt-predecessors clang
                                        prev-stmt
                                        new-acc
                                        blocks)
                ;; Last statement in block. Move up a scope and push
                ;; the accumulated statements onto the block stack.
                (full-stmt-predecessors clang
                                        (enclosing-block clang ast)
                                        nil
                                        (cons new-acc blocks)))))))

(defmethod tree-successors ((ast ast-ref) (ancestor ast-ref) &key include-ast)
  "Find all successors of AST within subtree at ANCESTOR.

Returns ASTs and text snippets, grouped by depth. AST itself is
included as the first successor."
  (labels
      ((successors (tree path)
         (bind (((head . tail) path)
                (children (cdr tree)))
           (if tail
               (cons (subseq children (1+ head))
                     (successors (nth head children) tail))
               (list (subseq children (if include-ast head (1+ head))))))))
      (let* ((ast-path (ast-ref-path ast))
          (rel-path (last ast-path
                          (- (length ast-path)
                             (length (ast-ref-path ancestor))))))
        (reverse (successors (ast-ref-ast ancestor) rel-path)))))

(defmethod update-headers-from-snippet ((clang clang) snippet database)
  (mapc {add-include clang}
        (reverse (aget :includes snippet)))
  (mapc [{add-macro clang} {find-macro database}]
        (reverse (aget :macros snippet)))
  (mapc [{add-type clang} {find-type database}]
        (reverse (aget :types snippet)))
  snippet)

(defgeneric begins-scope (ast)
  (:documentation "True if AST begins a new scope."))
(defmethod begins-scope ((ast ast-ref))
  (member (ast-class ast)
          '(:CompoundStmt :Block :Captured :Function :CXXMethod)))

(defgeneric enclosing-scope (software ast)
  (:documentation "Returns enclosing scope of ast."))
(defmethod enclosing-scope ((software clang) (ast ast-ref))
  (or (find-if #'begins-scope
               (cdr (get-parent-asts software ast)))
      ;; Global scope
      (make-ast-ref :path nil :ast (ast-root software))))

(defmethod nth-enclosing-scope ((software clang) depth (ast ast-ref))
  (let ((scope (enclosing-scope software ast)))
    (if (>= 0 depth) scope
        (nth-enclosing-scope software (1- depth) scope))))

(defgeneric scopes (software ast)
  (:documentation "Return lists of variables in each enclosing scope.
Each variable is represented by an alist containing :NAME, :DECL, :TYPE,
and :SCOPE.
"))

(defmethod scopes ((software clang) (ast ast-ref))
  ;; Stop at the root AST
  (when (not (eq :TopLevel (ast-class ast)))
    (let ((scope (enclosing-scope software ast)))
      (cons (->> (iter (for c in
                            (get-immediate-children software scope))
                       (while (ast-later-p ast c))
                       (collect c))
                  ; remove type and function decls
                 (remove-if-not [{member _ '(:Var :ParmVar :DeclStmt)}
                                 #'ast-class])
                 (mappend
                  (lambda (ast)
                    (mapcar
                     (lambda (name)
                       `((:name . ,name)
                         (:decl . ,ast)
                         (:type . ,(nth (position-if {string= name}
                                                     (ast-declares ast))
                                        (get-ast-types software ast)))
                         (:scope . ,scope)))
                     (ast-declares ast))))
                 (remove-if #'emptyp) ; drop nils and empty strings
                 (reverse))
            (scopes software scope)))))

(defgeneric get-ast-types (software ast)
  (:documentation "Types directly referenced within AST."))
(defmethod get-ast-types ((software clang) (ast ast-ref))
  (remove-duplicates (apply #'append (ast-types ast)
                            (mapcar {get-ast-types software}
                                    (get-immediate-children software ast)))))

(defgeneric get-unbound-funs (software ast)
  (:documentation "Functions used (but not defined) within the AST."))

(defmethod get-unbound-funs ((software clang) (ast ast-ref))
  (remove-duplicates (apply #'append (ast-unbound-funs ast)
                            (mapcar {get-unbound-funs software}
                                    (get-immediate-children software ast)))
                     :test #'equal))

(defmethod get-unbound-funs ((software clang) (ast clang-ast))
  (declare (ignorable software))
  (ast-unbound-funs ast))

(defgeneric get-unbound-vals (software ast)
  (:documentation "Variables used (but not defined) within the AST.

Each variable is represented by an alist in the same format used by SCOPES."))
(defmethod get-unbound-vals ((software clang) (ast ast-ref))
  (labels
      ((in-scope (var scopes)
         (some (lambda (s) (member var s :test #'string=))
               scopes))
       (walk-scope (ast unbound scopes)
         ;; Enter new scope
         (when (begins-scope ast)
           (push nil scopes))

         ;; Add definitions to scope
         (setf (car scopes)
               (append (ast-declarations ast) (car scopes)))

         ;; Find unbound values
         (iter (for name in (ast-unbound-vals ast))
               (unless (in-scope name scopes)
                 (push name unbound)))

         ;; Walk children
         (iter (for c in (get-immediate-children software ast))
               (multiple-value-bind (new-unbound new-scopes)
                   (walk-scope c unbound scopes)
                 (setf unbound new-unbound
                       scopes new-scopes)))

         ;; Exit scope
         (when (begins-scope ast)
           (setf scopes (cdr scopes)))

         (values unbound scopes)))
    ;; Walk this tree, finding all values which are referenced, but
    ;; not defined, within it
    (let ((in-scope (get-vars-in-scope software ast)))
      (-<>> (walk-scope ast nil (list nil))
            (remove-duplicates <> :test #'string=)
            (mapcar (lambda (name)
                      (or (find name in-scope :test #'string= :key {aget :name})
                          `((:name . ,name)))))))))

(defmethod get-unbound-vals ((software clang) (ast clang-ast))
  (declare (ignorable software))
  (ast-unbound-vals ast))

(defgeneric get-vars-in-scope (software ast &optional keep-globals)
  (:documentation "Return all variables in enclosing scopes."))
(defmethod get-vars-in-scope ((obj clang) (ast ast-ref)
                                   &optional keep-globals)
  ;; Remove duplicate variable names from outer scopes. Only the inner variables
  ;; are accessible.
  (iter (for var in (apply #'append (if keep-globals
                                        (butlast (scopes obj ast))
                                        (scopes obj ast))))
        (unless (find (aget :name var) vars
                      :test #'string= :key {aget :name})
          (collect var into vars))
        (finally (return vars))))

(defvar *allow-bindings-to-globals-bias* 1/5
  "Probability that we consider the global scope when binding
free variables.")

(defun random-function-name (protos &key original-name arity)
  (let ((matching '())
        (variadic '())
        (others   '())
        (saw-orig nil))
    (loop :for proto :in protos
       :do (let ((name (ast-name proto))
                 (args (length (ast-args proto))))
             (when (string= name original-name)
               (setf saw-orig t))
             (cond
               ((= args arity) (push name matching))
               ((and (< args arity)
                     (ast-varargs proto)) (push name variadic))
               (t (push name others)))))
    (if (and saw-orig (< (random 1.0) *matching-free-function-retains-name-bias*))
        original-name
        (random-elt (or matching variadic others '(nil))))))

(defun random-function-info (protos &key original-name arity)
  "Returns function info in the same format as unbound-funs."
  (when-let* ((name (random-function-name protos
                                          :original-name original-name
                                          :arity arity))
              (decl (find-if [{string= name} #'ast-name] protos)))
    ;; fun is (name, voidp, variadicp, arity)
    (list (format nil "(|~a|)" (ast-name decl))
          (ast-void-ret decl)
          (ast-varargs decl)
          (length (ast-args decl)))))

(defun binding-for-var (obj in-scope name)
  ;; If the variable's original name matches the name of a variable in scope,
  ;; keep the original name with probability equal to
  ;; *matching-free-var-retains-name-bias*
  (or (when (and (< (random 1.0)
                    *matching-free-var-retains-name-bias*)
                 (find name in-scope :test #'string=))
        name)
      (random-elt-with-decay
       in-scope *free-var-decay-rate*)
      (error (make-condition 'mutate
                             :text "No bound vars in scope."
                             :obj obj))))

(defun binding-for-function (obj functions name arity)
  (or (random-function-info functions
                            :original-name name
                            :arity arity)
      (error (make-condition 'mutate
                             :text "No bound vars in scope."
                             :obj obj))))

(defmethod bind-free-vars ((clang clang) (ast ast-ref) (pt ast-ref))
  (let* ((in-scope (mapcar {aget :name} (get-vars-in-scope clang pt)))
         (var-replacements
          (mapcar (lambda (var)
                    (let ((name (aget :name var)))
                      (mapcar #'unpeel-bananas
                              (list name (binding-for-var clang in-scope
                                                          name)))))
                  (get-unbound-vals clang ast)))
         (fun-replacements
          (mapcar
           (lambda (fun)
             (list fun
                   (binding-for-function clang
                                         (prototypes clang)
                                         (first fun)
                                         (fourth fun))))
           (get-unbound-funs clang ast))))
    (values
     (rebind-vars ast var-replacements fun-replacements)
     var-replacements
     fun-replacements)))

(defgeneric delete-decl-stmts (software block replacements)
  (:documentation
   "Return mutation ops applying REPLACEMENTS to BLOCK in SOFTWARE.
REPLACEMENTS is a list holding lists of an ID to replace, and the new
variables to replace use of the variables declared in stmt ID."))

(defmethod delete-decl-stmts ((obj clang) (block ast-ref) (replacements list))
  (append
   ;; Rewrite those stmts in the BLOCK which use an old variable.
   (let* ((old->new      ; First collect a map of old-name -> new-name.
           (mappend (lambda-bind ((id . replacements))
                      (mapcar #'list
                              (mapcar #'unpeel-bananas (ast-declares id))
                              (mapcar #'unpeel-bananas replacements)))
                    replacements))
          (old (mapcar [#'peel-bananas #'car] old->new)))
     ;; Collect statements using old
     (-<>> (get-immediate-children obj block)
           (remove-if-not (lambda (ast)      ; Only Statements using old.
                            (intersection
                             (get-used-variables obj ast)
                             old :test #'string=)))
           (mapcar (lambda (ast)
                     (list :set (cons :stmt1 ast)
                           (cons :literal1
                                 (rebind-vars ast old->new nil)))))))
      ;; Remove the declaration.
   (mapcar [{list :cut} {cons :stmt1} #'car] replacements)))

(defmethod get-declared-variables ((clang clang) the-block)
  (mappend #'ast-declares (get-immediate-children clang the-block)))

(defmethod get-used-variables ((clang clang) stmt)
  (mapcar {aget :name} (get-unbound-vals clang stmt)))

(defmethod get-children-using ((clang clang) var the-block)
  (remove-if-not [(lambda (el) (find var el :test #'equal))
                  {get-used-variables clang}]
                 (get-immediate-children clang the-block)))

(defmethod nth-enclosing-block ((clang clang) depth stmt)
  (let ((the-block (enclosing-block clang stmt)))
    (if (>= 0 depth) the-block
        (nth-enclosing-block clang (1- depth) the-block))))

(defgeneric ast-declarations (ast)
  (:documentation "Return the names of the variables that AST declares."))

(defmethod ast-declarations ((ast clang-ast))
  (cond
    ; Variable or function arg
    ((member (ast-class ast) '(:Var :ParmVar :DeclStmt))
     (ast-declares ast))
    ((function-decl-p ast)                      ; Function declaration.
     (mapcar #'car (ast-args ast)))
    (:otherwise nil)))

(defmethod ast-declarations ((ast ast-ref))
  (ast-declarations (car (ast-ref-ast ast))))

(defmethod ast-declarations ((ast clang-type))
  nil)

(defgeneric declared-type (ast variable-name)
  (:documentation "Guess the type of the VARIABLE-NAME in AST.
VARIABLE-NAME should be declared in AST."))

(defmethod declared-type ((ast clang-ast) variable-name)
  ;; NOTE: This is very simple and probably not robust to variable
  ;; declarations which are "weird" in any way.
  (declare (ignorable variable-name))
  (first
   (split-sequence #\Space (source-text ast) :remove-empty-subseqs t)))

(defgeneric find-var-type (software variable)
  (:documentation "Return the type of VARIABLE in SOFTWARE."))
(defmethod find-var-type ((obj clang) (variable list))
  (&>> (aget :type variable)
       (find-type obj)))


;;; Crossover functions
(defun create-crossover-context (clang outer start &key include-start)
  "Create the context for a crossover snippet.

Start at the outer AST and proceed forward/inward, copying all
children before the start point of the crossover. This collects
everything within the outer AST that will not be replaced by the
crossover.

Returns a list of parent ASTs from outer to inner, which are bare
trees (not wrapped in ast-refs).
"
  (labels
      ((copy-predecessors (root statements)
         (if (eq root start)
             (values nil (when include-start
                           (list (ast-ref-ast root))))
             (bind (((node . children) (ast-ref-ast root))
                    ;; Last child at this level
                    (last-child (lastcar (car statements)))
                    ;; Position of last child in real AST child list
                    (last-index (position-if {equalp (ast-ref-ast last-child)}
                                             children))
                    ((:values stack new-child)
                     (copy-predecessors last-child (cdr statements)))
                    (new-ast (cons node
                                   ;; keep all but last, including text
                                   (append (subseq children 0 last-index)
                                           ;; copy last and update children
                                           new-child))))
               (values (cons new-ast stack) (list new-ast))))))

    (let ((predecessors (full-stmt-predecessors clang start)))
      (iter (until (or (some [{equalp outer} {get-parent-ast clang}]
                             (car predecessors))
                       (null predecessors)))
            (pop predecessors))
      (when predecessors
        (copy-predecessors outer predecessors)))))

(defun fill-crossover-context (context statements)
  "Fill in context with ASTs from the other genome.

Each element of CONTEXT is an incomplete AST which is missing some
trailing children. Each element of STATEMENTS is a corresponding list
of children.

Returns outermost AST of context.
"
  ;; Reverse context so we're proceeding from the innermost AST
  ;; outward. This ensures that the levels line up.
  (iter (for parent in (reverse context))
        (for children in statements)
        (when children
          (nconcf parent children)))

  (when context
    (car context)))

;; Perform 2-point crossover. The second point will be within the same
;; function as the first point, but may be in an enclosing scope.
;; The number of scopes exited as you go from the first crossover point
;; to the second crossover point will be matched between a and b.
;; Free variables are rebound in such a way as to ensure that they are
;; bound to variables that are declared at each point of use.
;;
;; Modifies parameter A.
;;
(defmethod crossover-2pt-outward
    ((a clang) (b clang) a-begin a-end b-begin b-end)
  (let* ((outer (common-ancestor a a-begin a-end))
         (context (create-crossover-context a outer a-begin :include-start nil))
         (b-stmts (-<>> (common-ancestor b b-begin b-end)
                       (get-parent-ast b)
                       (tree-successors b-begin <> :include-ast t)))
         (value1 (-<>> (fill-crossover-context context b-stmts)
                       ;; Special case if replacing a single statement
                       (or <> ( car (car b-stmts)))
                       (make-ast-ref :ast <>)
                       (recontextualize a <> a-begin))))

    `((:stmt1  . ,outer)
      (:value1 . ,value1))))

;; Perform 2-point crossover. The second point will be within the same
;; function as the first point, but may be in an inner scope. The
;; number of scopes entered as you go from the first crossover point
;; to the second crossover point will be matched between a and b.
;; Free variables are rebound in such a way as to ensure that they are
;; bound to variables that are declared at each point of use.
;;
;; Modifies parameter A.
;;
(defmethod crossover-2pt-inward
    ((a clang) (b clang) a-begin a-end b-begin b-end)
  (labels
      ((child-index (parent child)
         "Position of CHILD within PARENT."
         (assert (equal (ast-ref-path parent)
                        (butlast (ast-ref-path child))))
         (lastcar (ast-ref-path child)))
       (outer-ast (obj begin end)
         "AST which strictly encloses BEGIN and END."
         (let ((ancestor (common-ancestor obj begin end)))
           (if (equalp ancestor begin)
               (get-parent-ast obj ancestor)
               ancestor)))
       (splice-snippets (a-outer b-outer b-inner b-snippet)
         ;; Splice b-snippet into a-outer.
         (bind (((node . children) (ast-ref-ast a-outer))
                (a-index1 (child-index a-outer a-begin))
                (a-index2 (1+ (child-index a-outer
                                           (ancestor-after a a-outer a-end))))
                (b-index1 (child-index b-outer b-begin))
                (b-index2 (child-index b-outer b-inner))
                (tree (cons node
                            (append
                             ;; A children before the crossover
                             (subseq children 0 a-index1)
                             ;; B children up to the inner snippet
                             (subseq (cdr (ast-ref-ast b-outer))
                                     b-index1 (if b-snippet b-index2
                                                  (1+ b-index2)))
                             ;; The inner snippet if it exists
                             (when b-snippet (list b-snippet))
                             ;; A children after the crossover
                             (subseq children a-index2)))))
           (make-ast-ref :path nil :ast tree))))
    (let* ((a-outer (outer-ast a a-begin a-end))
           (b-outer (outer-ast b b-begin b-end))
           (b-inner (ancestor-after b b-outer b-end))
           (context (create-crossover-context b b-inner b-end :include-start t))
           (a-stmts (->> (common-ancestor a a-begin a-end)
                         (get-parent-ast a)
                         (tree-successors a-end)))
           ;; Build snippet starting a b-outer.
           (b-snippet (fill-crossover-context context a-stmts))
           ;; Splice into a-outer to get complete snippet
           (whole-snippet (splice-snippets a-outer b-outer b-inner b-snippet)))

      `((:stmt1  . ,a-outer)
        (:value1 . ,(recontextualize a whole-snippet a-begin))))))


(defun combine-snippets (obj inward-snippet outward-snippet)
  (let* ((outward-stmt1 (aget :stmt1 outward-snippet))
         (outward-value1 (aget :value1 outward-snippet))
         (inward-stmt1 (aget :stmt1 inward-snippet))
         (inward-value1 (aget :value1 inward-snippet)))
   (flet
       ((replace-in-snippet (outer-stmt inner-stmt value)
          (assert (not (equalp outer-stmt inner-stmt)))
          (let* ((inner-path (ast-ref-path inner-stmt))
                 (outer-path (ast-ref-path outer-stmt))
                 (rel-path (last inner-path
                                 (- (length inner-path) (length outer-path)))))
            (setf (ast-ref-ast outer-stmt)
                  (replace-ast (ast-ref-ast outer-stmt)
                                  (make-ast-ref :path rel-path)
                                  value)))))

     (cond
       ((null inward-snippet) outward-snippet)
       ((null outward-snippet) inward-snippet)
       ;; Insert value for outward snippet into inward snippet
       ((ancestor-of obj inward-stmt1 outward-stmt1)
        (replace-in-snippet inward-stmt1 outward-stmt1 outward-value1)
        inward-snippet)

       ;; Insert value for inward snippet into outward snippet
       ((ancestor-of obj outward-stmt1 inward-stmt1)
        (replace-in-snippet outward-stmt1 inward-stmt1 inward-value1)
        outward-snippet)

       (t
        (let* ((ancestor (common-ancestor obj outward-stmt1 inward-stmt1))
               (value1 (make-ast-ref :ast (ast-ref-ast ancestor)
                                     :path (ast-ref-path ancestor))))
          (replace-in-snippet value1 inward-stmt1 inward-value1)
          (replace-in-snippet value1 outward-stmt1 outward-value1)
          `((:stmt1 . ,ancestor) (:value1 . ,value1))))))))

(defmethod update-headers-from-ast ((clang clang) (ast ast-ref) database)
  (labels
      ((update (tree)
         (destructuring-bind (ast . children) tree
           (mapc {add-include clang}
                 (reverse (ast-includes ast)))
           (mapc [{add-macro clang} {find-macro database}]
                 (reverse (ast-macros ast)))
           (mapc [{add-type clang} {find-type database}]
                 (reverse (ast-types ast)))
           (mapc #'update (remove-if-not #'listp children)))))
    (update (ast-ref-ast ast))))

;; Find the ancestor of STMT that is a child of ANCESTOR.
;; On failure, just return STMT again.
(defmethod ancestor-after ((clang clang) (ancestor ast-ref) (stmt ast-ref))
  (or (->> (get-parent-asts clang stmt)
           (find-if [{equalp ancestor} {get-parent-ast clang}]))
      stmt))

(defmethod common-ancestor ((clang clang) x y)
  (let* ((x-ancestry (get-parent-asts clang x))
         (y-ancestry (get-parent-asts clang y))
         (last 0))
    (loop
       :for xp :in (reverse x-ancestry)
       :for yp :in (reverse y-ancestry)
       :when (equalp xp yp)
       :do (setf last xp))
    last))

(defmethod ancestor-of ((clang clang) x y)
  (equalp (common-ancestor clang x y) x))

(defmethod scopes-between ((clang clang) stmt ancestor)
  (iter (for ast in (get-parent-asts clang stmt))
                (counting (block-p clang ast))
                (until (equalp ast ancestor))))

(defmethod nesting-relation ((clang clang) x y)
  (if (or (null x) (null y)) nil
      (let* ((ancestor (common-ancestor clang x y)))
        (cond
          ((equalp x ancestor) (cons 0 (scopes-between clang y ancestor)))
          ((equalp y ancestor) (cons (scopes-between clang x ancestor) 0))
          (t
           ;; If the two crossover points share a CompoundStmt as the
           ;; common ancestor, then you can get from one to the other
           ;; without passing through the final set of braces.  To
           ;; compensate, we subtract one from the number of scopes
           ;; that must be traversed to get from X to Y.
           (let ((correction (if (eq (ast-class ancestor) :CompoundStmt)
                                 1 0)))
             (cons (- (scopes-between clang x ancestor) correction)
                   (- (scopes-between clang y ancestor) correction))))))))

;; Split the path between two nodes into the disjoint union of
;; a path appropriate for across-and-out crossover, followed by a
;; path approppriate for across-and-in.  Returns the pair of
;; path descriptions, or NIL for a path that is not needed.
(defmethod split-vee ((clang clang) x y)
  (let* ((ancestor (common-ancestor clang x y))
         (stmt (ancestor-after clang ancestor x)))
    (cond
      ((equalp x y)
       (values nil (cons x y)))
      ((equalp y ancestor)
       (values (cons x y) nil))
      ((equalp x ancestor)
       (values nil (cons x y)))
      ((equalp x stmt)
       (values nil (cons x y)))
      (t
       (values (cons x stmt)
               (cons (block-successor clang stmt) y))))))

(defmethod match-nesting ((a clang) xs (b clang) ys)
  (let* (;; Nesting relationships for xs, ys
         (x-rel (nesting-relation a (car xs) (cdr xs)))
         (y-rel (nesting-relation b (car ys) (cdr ys)))
         ;; Parent statements of points in xs, ys
         (xps (cons (enclosing-full-stmt a (get-parent-ast a (car xs)))
                    (enclosing-full-stmt a (get-parent-ast a (cdr xs)))))
         (yps (cons (enclosing-full-stmt b (get-parent-ast b (car ys)))
                    (enclosing-full-stmt b (get-parent-ast b (cdr ys))))))
    ;; If nesting relations don't match, replace one of the points with
    ;; its parent's enclosing full statement and try again.
    (cond
      ((< (car x-rel) (car y-rel))
       (match-nesting a xs b (cons (car yps) (cdr ys))))
      ((< (cdr x-rel) (cdr y-rel))
       (match-nesting a xs b (cons (car ys) (cdr yps))))
      ((> (car x-rel) (car y-rel))
       (match-nesting a (cons (car xps) (cdr xs)) b ys))
      ((> (cdr x-rel) (cdr y-rel))
       (match-nesting a (cons (car xs) (cdr xps)) b ys))
      (t
       (multiple-value-bind (a-out a-in)
           (split-vee a (car xs) (cdr xs))
         (multiple-value-bind (b-out b-in)
             (split-vee b (car ys) (cdr ys))
           (values a-out b-out a-in b-in)))))))

(defmethod intraprocedural-2pt-crossover ((a clang) (b clang)
                                          a-begin a-end
                                          b-begin b-end)
  (let ((variant (copy a)))
    (multiple-value-bind (a-out b-out a-in b-in)
        (match-nesting a (cons a-begin a-end)
                       b (cons b-begin b-end))

      (let* ((outward-snippet
              (when (and a-out b-out)
                (crossover-2pt-outward variant b
                                       (car a-out) (cdr a-out)
                                       (car b-out) (cdr b-out))))
             (inward-snippet
              (when (and (car a-in) (car b-in))
                (crossover-2pt-inward variant b
                                       (car a-in) (cdr a-in)
                                       (car b-in) (cdr b-in))))
             (complete-snippet (combine-snippets a inward-snippet
                                                 outward-snippet)))


        (update-headers-from-ast a (aget :value1 complete-snippet) b)

        (apply-mutation-ops
         variant
         `((:set (:stmt1  . ,(aget :stmt1 complete-snippet))
                 (:value1 . ,(aget :value1 complete-snippet)))))

        (values variant
                (cons a-begin a-end)
                (cons b-begin b-end)
                t
                (cons (or (car a-out) (car a-in))
                      (or (cdr a-in) (cdr a-out))))))))

(defgeneric adjust-stmt-range (software start end)
  (:documentation
   "Adjust START and END so that they represent a valid range for set-range.
The values returned will be STMT1 and STMT2, where STMT1 and STMT2 are both
full statements"))

(defmethod adjust-stmt-range ((clang clang) start end)
  (when (and start end)
    (let* ((stmt1 (enclosing-full-stmt clang (ast-at-index clang start)))
           (stmt2 (enclosing-full-stmt clang (ast-at-index clang end)))
           (position1 (index-of-ast clang stmt1))
           (position2 (index-of-ast clang stmt2)))
      (cond ((not (and stmt1 stmt2))
             ;; If either of STMT1 or STMT2 are nil, then most likely
             ;; START or END aren't valid stmt-asts.  In this case we
             ;; will imagine that the caller has made a mistake, and
             ;; simply return STMT1 and STMT2.
             (warn "Unable to find enclosing full statements for ~a and/or ~a."
                   start end)
             (values position1 position2))
            ((or (ancestor-of clang stmt1 stmt2)
                 (ancestor-of clang stmt2 stmt1))
             (values position1 position2))
            ((< position2 position1)
             (values position2 position1))
            (t
             (values position1 position2))))))

(defgeneric random-point-in-function (software prototype)
  (:documentation
   "Return the index of a random point in PROTOTYPE in SOFTWARE.
If PROTOTYPE has an empty function body in SOFTWARE return nil."))

(defmethod random-point-in-function ((clang clang) function)
  (destructuring-bind (first last) (stmt-range clang function)
    (if (equal first last) nil
        (+ (1+ first) (random (- last first))))))

(defgeneric select-intraprocedural-pair (software)
  (:documentation
   "Randomly select an AST within a function body and then select
another point within the same function.  If there are no ASTs
within a function body, return null."))

(defmethod select-intraprocedural-pair ((clang clang))
  (when-let (stmt1 (&>> (remove-if {function-body-p clang} (stmt-asts clang))
                        (random-elt)))
    (values (index-of-ast clang stmt1)
            (random-point-in-function
             clang
             (function-containing-ast clang stmt1)))))

(defmethod select-crossover-points ((a clang) (b clang))
  (multiple-value-bind (a-stmt1 a-stmt2)
      (select-intraprocedural-pair a)
    (multiple-value-bind (b-stmt1 b-stmt2)
        (select-intraprocedural-pair b)
      (values a-stmt1 a-stmt2 b-stmt1 b-stmt2))))

(defmethod select-crossover-points-with-corrections ((a clang) (b clang))
  (multiple-value-bind (a-pt1 a-pt2 b-pt1 b-pt2)
      ;; choose crossover points
      (select-crossover-points a b)
    (multiple-value-bind (a-stmt1 a-stmt2)
        ;; adjust ranges to be valid for use with set-range
        (adjust-stmt-range a a-pt1 a-pt2)
      (multiple-value-bind (b-stmt1 b-stmt2)
          (adjust-stmt-range b b-pt1 b-pt2)
        (values a-stmt1 a-stmt2 b-stmt1 b-stmt2)))))

(defmethod crossover ((a clang) (b clang))
  (multiple-value-bind (a-stmt1 a-stmt2 b-stmt1 b-stmt2)
      (select-crossover-points-with-corrections a b)
    (if (and a-stmt1 a-stmt2 b-stmt1 b-stmt2)
        (multiple-value-bind (crossed a-point b-point changedp)
            (intraprocedural-2pt-crossover
             a b
             (ast-at-index a a-stmt1) (ast-at-index a a-stmt2)
             (ast-at-index b b-stmt1) (ast-at-index b b-stmt2))
          (if changedp
              (values crossed a-point b-point)
              (values crossed nil nil)))
        ;; Could not find crossover point
        (values (copy a) nil nil))))

(defgeneric function-containing-ast (object ast)
  (:documentation "Return the ast for the function containing AST in OBJECT."))

(defmethod function-containing-ast ((clang clang) (ast ast-ref))
  (find-if #'function-decl-p (get-parent-asts clang ast)))

(defmethod function-body-p ((clang clang) stmt)
  (find-if [{equalp stmt} {function-body clang}] (functions clang)))


;;; Clang methods
(defgeneric clang-tidy (software)
  (:documentation "Apply the software fixing command line, part of Clang."))

(defmethod clang-tidy ((clang clang) &aux errno)
  (setf (genome clang)
        (with-temp-file-of (src (ext clang)) (genome clang)
          (multiple-value-bind (stdout stderr exit)
              (shell
               "clang-tidy -fix -fix-errors -checks=~{~a~^,~} ~a -- ~a 1>&2"
               '("cppcore-guidelines*"
                 "misc*"
                 "-misc-static-assert"
                 "-misc-unused-parameters"
                 "-modernize*"
                 "performance*"
                 "readability*"
                 "-readability-function-size"
                 "-readability-identifier-naming"
                 "-readability-non-const-parameter")
               src
               (mapconcat #'identity (flags clang) " "))
            (declare (ignorable stdout stderr))
            (setf errno exit)
            (if (zerop exit) (file-to-string src) (genome clang)))))
  (values clang errno))

(defmethod clang-format ((obj clang) &optional style &aux errno)
  (with-temp-file-of (src (ext obj)) (genome obj)
    (setf (genome obj)
          (multiple-value-bind (stdout stderr exit)
              (shell "clang-format ~a ~a"
                     (if style
                         (format nil "-style=~a" style)
                         (format nil
                                 "-style='{BasedOnStyle: Google,~
                                AllowShortBlocksOnASingleLine: false,~
                                AllowShortCaseLabelsOnASingleLine: false,~
                                AllowShortFunctionsOnASingleLine: false,~
                                AllowShortIfStatementsOnASingleLine: false,~
                                AllowShortLoopsOnASingleLine: false}'"))
                     src)
            (declare (ignorable stderr))
            (setf errno exit)
            (if (zerop exit) stdout (genome obj)))))
  (values obj errno))

(defgeneric indent (software &optional style)
  (:documentation "Apply GNU indent to the software"))

(define-constant +indent-style+
  "-linux -i2 -ts2 -nut"
  :test #'string=
  :documentation "Default style for GNU indent")

(defmethod indent ((obj clang) &optional style &aux errno)
  (with-temp-file-of (src (ext obj)) (genome obj)
    (setf (genome obj)
          (multiple-value-bind (stdout stderr exit)
              (shell "indent ~a ~a -st" src (or style +indent-style+))
            (declare (ignorable stderr))
            (setf errno exit)
            (if (or (= 0 exit) (= 2 exit))
                stdout
                (genome obj)))))
  (values obj errno))

(defun replace-fields-in-snippet (snippet field-replacement-pairs)
  "Given a snippet and an association list in the form ((:field . <value>))
replace the entries in the snippet with the given values."
  (loop :for pair
        :in field-replacement-pairs
        :do (let ((field (car pair))
                  (replacement (cdr pair)))
              (setf (cdr (assoc field snippet))
                    replacement)))
  snippet)
