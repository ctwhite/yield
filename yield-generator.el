;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; yield-generator.el --- High-Level Generator API -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;; This library provides a high-level API for defining resumable generators
;;; in Emacs Lisp. It is the primary entry point for the `yield` framework.
;;;
;;; It orchestrates the `yield-cpm.el` (compiler) and `yield-fsm.el` (runtime)
;;; to provide a seamless generator experience. By requiring this file,
;;; users get access to the entire library.

;;; Code:

(require 'cl-lib)
(require 'yield-fsm)
(require 'yield-cpm)
(require 'dash)
(require 'pcase)
(require 's)
(require 'subr-x)
(require 'macroexp)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Public API

;;;###autoload
(defmacro yield! (value &optional (tag yield--yield-status-key))
  "Yield a VALUE from the current generator, suspending its execution.
When the generator is resumed via `(next! gen new-value)`, this
expression evaluates to NEW-VALUE.

Arguments:
  VALUE: The value to yield.
  TAG (symbol): An optional tag for the yield type.

Results:
  This macro performs a non-local exit and does not return in the
  traditional sense until resumed."
  (error "`yield!` used outside of a generator context."))

;;;###autoload
(defmacro yield-from! (iterator-form)
  "Delegate to another generator, yielding all its values.
This macro yields all values from ITERATOR-FORM until it is
exhausted. The `yield-from!` expression itself then evaluates to
the final value returned by the delegated iterator upon its
completion.

Arguments:
  ITERATOR-FORM: An expression that evaluates to a generator instance.

Results:
  This macro expands into a form interpreted by the CPM."
  `(yield--internal-delegate-form ,iterator-form))

(defun next! (generator-instance &optional value-to-send)
  "Advance a generator to its next yield point or until completion.
This function drives the generator, executing its code until it
either yields a value, encounters an error, or finishes.

Arguments:
  GENERATOR-INSTANCE (function): The generator object returned by a call
                                 to a `defgenerator!`-defined function.
  VALUE-TO-SEND: An optional value to send back into the generator.
                 This value becomes the return value of the `yield!`
                 expression that paused the generator.

Results:
  A plist indicating the generator's status and value:
    `(:yield t :value VALUE)`: The generator yielded VALUE.
    `(:await-external t ...)`: The generator is awaiting an async op.
    `(:done t :value FINAL-VALUE)`: The generator completed successfully.
    `(:error t :error-object ERROR-OBJ)`: The generator terminated."
  (unless (functionp generator-instance)
    (error "Expected a generator function instance, got %S"
           generator-instance))
  (funcall generator-instance value-to-send))

;;;###autoload
(defmacro defgenerator! (name args &rest body)
  "Define NAME as a generator function with ARGS and BODY.
This is the main entry point for creating a generator. The macro
handles the complex process of transforming the human-readable
BODY into an efficient, resumable Finite State Machine.

When the defined function (e.g., `my-generator`) is called, it
returns a stateful closure which is the generator instance. This
instance is then driven by the `next!` function.

Arguments:
  NAME (symbol): The symbol name for the generator function.
  ARGS (list): The argument list for the generator, like `defun`.
  BODY (form...): The Lisp forms that make up the generator's logic.

Results:
  The symbol NAME, for which a function definition has been created."
  (declare (indent defun))
  (let* ((docstring (if (stringp (car body)) (pop body)
                      (format "Generator function %s." name)))
         (fn-args (append args '(&rest fsm-options)))
         ;; Use `cl-macrolet` to create a temporary, local definition for `yield!`.
         ;; Then, use `macroexpand-all` to recursively apply this transformation.
         (generator-body-list
          (macroexpand-all
           `(cl-macrolet ((yield! (value &optional (tag yield--yield-status-key))
                            `(yield--internal-throw-form ,value ,tag)))
              (progn ,@body))))
         ;; Create the argument binding list needed by the CPM for lifting.
         (initial-arg-bindings
          (cl-loop for arg-sym in args collect (list arg-sym arg-sym)))
         ;; Call the CPM transformer with the expanded body.
         (defun-body
          (yield-cpm-generate-generator-lambda-form
                 generator-body-list
                 initial-arg-bindings
                 'fsm-options)))
    ;; The macro expands into a complete `defun` form.
    `(defun ,name ,fn-args
       ,docstring
       ,defun-body)))

(provide 'yield-generator)
;;; yield-generator.el ends here