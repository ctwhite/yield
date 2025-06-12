;;; yield-cpm.el --- Continuation-Passing Machine for Generators -*-
;;; lexical-binding: t; -*-

;;; Commentary:
;;; This module implements the Continuation-Passing Style (CPS) transformation
;;; logic for `yield-generator.el`. Its primary purpose is to take a standard
;;; Emacs Lisp code block (the body of a generator) and compile it into a
;;; linear sequence of executable steps (thunks) that the `yield-fsm.el`
;;; runtime can execute.
;;;
;;; The transformation process handles:
;;; 1.  **Control Flow**: Standard forms like `if` and `while` are converted
;;;     into a graph of states with conditional jumps.
;;; 2.  **Variable Lifting**: To preserve lexical scope across `yield!` points
;;;     (where the local call stack is lost), all local variables are "lifted"
;;;     into a shared lexical environment created by the generator instance.
;;; 3.  **Yield Points**: `yield!` and `yield-from!` macros are translated into
;;;     special commands that the FSM runtime can interpret.
;;;
;;; This refactored version splits the main transformation logic into dedicated
;;; helper functions for each special form, improving readability and maintainability.

;;; Code:

(require 'cl-lib)
(require 'pcase)
(require 'subr-x)
(require 'dash)
(require 'yield-fsm)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; CPM Context Struct Definition & Core Helpers

(cl-defstruct (yield-cpm-context (:constructor %%make-yield-cpm-context))
  "A context for the Continuation-Passing Machine transformation.
This struct holds all state relevant to a single transformation pass.

Fields:
  fsm-steps: A list of generated FSM step plists.
  current-bindings: An alist mapping original symbols to their lifted counterparts.
  all-lifted-symbols: A list of all unique lifted symbols for the final `let`.
  value-sym: A gensym for the current value accumulator.
  final-sym: A gensym for the final result accumulator.
  cleanup-functions: A stack for `unwind-protect` handlers (simplified).
  error-handler-stack: A stack for active `condition-case` handlers.
  final-step-name: The gensym for the final completion step, for internal use."
  (fsm-steps nil :type list)
  (current-bindings nil :type alist)
  (all-lifted-symbols nil :type list)
  (value-sym nil :type symbol)
  (final-sym nil :type symbol)
  (cleanup-functions nil :type list)
  (error-handler-stack nil :type list)
  (final-step-name nil :type symbol))

(defun yield-cpm-gensym (prefix)
  "Generate a unique symbol with a given PREFIX for the CPM.
Using a custom wrapper ensures all our generated symbols have a
consistent and identifiable naming scheme.

Arguments:
  PREFIX: A string to use as the base for the symbol name.

Returns:
  A new, unique symbol."
  (gensym (format "cpm-gen-%s-" prefix)))

(defun yield-cpm-make-thunk (form)
  "Create a simple thunk (a zero-argument lambda) for an FSM step.
The FSM runtime executes these thunks one at a time.

Arguments:
  FORM: The Lisp form to wrap in the lambda.

Returns:
  A list representing the lambda form, e.g., `(lambda () FORM)`."
  `(lambda () ,form))

(defun yield-cpm-add-fsm-step (cpm-ctx name body-form)
  "Add a new FSM step to the context.
This function is critical for ensuring that compile-time variables
(like the gensyms stored in `cpm-ctx`) are correctly \"baked into\"
the runtime code of the thunk, preventing `void-variable` errors.
Steps are accumulated by prepending to a list.

Arguments:
  CPM-CTX: The current `yield-cpm-context` instance.
  NAME: A unique symbol for the name of the FSM step.
  BODY-FORM: The Lisp code that will be the body of the step's thunk.

Returns:
  The NAME of the newly created step."
  (let ((final-body-code body-form))
    (when (and (not (eq name (yield-cpm-context-final-step-name cpm-ctx)))
               (car-safe (yield-cpm-context-error-handler-stack cpm-ctx)))
      (let ((err-obj-sym (yield-cpm-gensym "err-obj"))
            (val-sym (yield-cpm-context-value-sym cpm-ctx)))
        (setq final-body-code
              `(condition-case ,err-obj-sym
                   ,final-body-code
                 ,@(-map (-lambda ((condition . handler-cont))
                           `(,condition
                             (setf ,val-sym ,err-obj-sym)
                             '(:jump ,handler-cont . ,err-obj-sym)))
                         (yield-cpm-context-error-handler-stack cpm-ctx))))))
    (let ((step-thunk (yield-cpm-make-thunk final-body-code)))
      (push `(:name ,name :thunk ,step-thunk) (yield-cpm-context-fsm-steps cpm-ctx))
      name)))

(defun yield-cpm-get-lifted-symbol (cpm-ctx original-sym)
  "Get or create a lifted (gensym'd) symbol for ORIGINAL-SYM.
This ensures that variables defined in the generator body have a
unique identity within the generated FSM, preserving lexical scope
across yields.

Arguments:
  CPM-CTX: The current `yield-cpm-context` instance.
  ORIGINAL-SYM: The original symbol from the user's Lisp code.

Returns:
  The corresponding lifted symbol."
  (let ((binding (assq original-sym (yield-cpm-context-current-bindings cpm-ctx))))
    (or (cdr binding)
        (let ((new-lifted-sym (yield-cpm-gensym (symbol-name original-sym))))
          (push new-lifted-sym (yield-cpm-context-all-lifted-symbols cpm-ctx))
          (push (cons original-sym new-lifted-sym)
                (yield-cpm-context-current-bindings cpm-ctx))
          new-lifted-sym))))

(defun yield-cpm--make-initial-let-bindings (cpm-ctx)
  "Generates `let` bindings for all lifted and internal state variables.
This list of bindings will be used to create the lexical environment
that the final generator closure captures.

Arguments:
  CPM-CTX: The context containing all lifted symbols.

Returns:
  A list of binding forms for a `let` block, e.g., '((var1 nil) (var2 nil))."
  (let* ((value-sym (yield-cpm-context-value-sym cpm-ctx))
         (final-sym (yield-cpm-context-final-sym cpm-ctx))
         (lifted-vars (yield-cpm-context-all-lifted-symbols cpm-ctx))
         (lifted-bindings (-map (lambda (sym) `(,sym nil)) lifted-vars)))
    (append lifted-bindings `((,value-sym nil) (,final-sym nil)))))

(defun yield-cpm-substitute-bindings (cpm-ctx form)
  "Recursively substitute original var symbols in FORM with their lifted counterparts."
  (let ((bindings (yield-cpm-context-current-bindings cpm-ctx)))
    (pcase form
      ((pred symbolp) (or (cdr (assq form bindings)) form))
      ((pred consp) (cons (yield-cpm-substitute-bindings cpm-ctx (car form))
                          (yield-cpm-substitute-bindings cpm-ctx (cdr form))))
      (_ form))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Transformation Helpers for Special Forms

(defun yield-cpm--transform-body-sequence (cpm-ctx body-forms next-cont-name)
  "Transforms a sequence of forms, chaining them in correct execution order.
Each form's transformation is given the next form's entry point as its
continuation. The chain is built by processing forms from last to first.

Arguments:
  CPM-CTX: The current `yield-cpm-context` instance.
  BODY-FORMS: A list of Lisp forms to transform.
  NEXT-CONT-NAME: The final continuation after the entire sequence is done.

Returns:
  The symbol name of the FSM step that begins the sequence."
  (let ((continuation next-cont-name))
    (dolist (form (reverse body-forms))
      (setq continuation (yield-cpm-transform-expression cpm-ctx form continuation)))
    continuation))

(defun yield-cpm-handle-atomic-form (cpm-ctx form next-cont-name)
  "Transforms a non-yielding form into a single FSM step.
This is the base case for the transformation recursion. It creates a
step that evaluates the form and then immediately jumps to the next
continuation, passing the result.

Arguments:
  CPM-CTX: The current `yield-cpm-context` instance.
  FORM: The atomic Lisp form to evaluate.
  NEXT-CONT-NAME: The name of the FSM step to jump to after evaluation."
  (let ((step-name (yield-cpm-gensym "atom-eval")))
    (yield-cpm-add-fsm-step
     cpm-ctx step-name
     `(progn
        (setf ,(yield-cpm-context-value-sym cpm-ctx) ,form)
        (list ',yield--jump-status-key ',next-cont-name nil)))
    step-name))

(defun yield-cpm-transform-yield (cpm-ctx form _next-cont-name)
  "Transforms a `yield--internal-throw-form` (from `yield!`).
This creates a step that returns a yield command (e.g., `\='(:yield 42)\=`),
which then handles the actual suspension. When resumed, execution will
continue at the next sequential step in the FSM's `steps` vector.
The `_next-cont-name` argument is ignored as the FSM automatically
advances its index after a yield/throw.

Arguments:
  CPM-CTX: The current `yield-cpm-context` instance.
  FORM: The `(yield--internal-throw-form ...)` form.
  _NEXT-CONT-NAME: The continuation, which is ignored as per CPM design
                   for `yield` (FSM runtime handles progression).

Returns:
  The symbol name of the FSM step that performs the yield."
  (let ((step-name (yield-cpm-gensym "yield-step")))
    (pcase form
      (`(yield--internal-throw-form ,value)
       (yield-cpm-add-fsm-step
        cpm-ctx step-name `(progn (setf ,(yield-cpm-context-value-sym cpm-ctx)
                                       ,(yield-cpm-substitute-bindings cpm-ctx value))
                                  (list ',yield--yield-status-key
                                        ,(yield-cpm-substitute-bindings cpm-ctx value)))))
      (`(yield--internal-throw-form ,value ,tag)
       (yield-cpm-add-fsm-step
        cpm-ctx step-name `(progn (setf ,(yield-cpm-context-value-sym cpm-ctx)
                                       ,(yield-cpm-substitute-bindings cpm-ctx value))
                                  (list ,tag ,(yield-cpm-substitute-bindings cpm-ctx value))))))
    step-name))

(defun yield-cpm-transform-yield-from (cpm-ctx form _next-cont-name)
  "Transforms a `yield--internal-delegate-form` (from `yield-from!`).
This creates steps to first evaluate the iterator that is being
delegated to, and then a final step that returns the `:yield-from`
command to the FSM.

Arguments:
  CPM-CTX: The current `yield-cpm-context` instance.
  FORM: The `(yield--internal-delegate-form ...)` form.
  _NEXT-CONT-NAME: Ignored.

Returns:
  The entry FSM step for the delegation logic."
  (pcase-let* ((`(yield--internal-delegate-form ,iterator-form) form))
    (let* ((delegate-step-name (yield-cpm-gensym "delegate-step"))
           (eval-iterator-entry-point
            (yield-cpm-transform-expression cpm-ctx iterator-form delegate-step-name)))
      (yield-cpm-add-fsm-step
       cpm-ctx delegate-step-name
       `'(:yield-from ,(yield-cpm-context-value-sym cpm-ctx)))
      eval-iterator-entry-point)))

(defun yield-cpm-transform-progn (cpm-ctx form next-cont-name)
  "Transforms a `progn` form.
This is achieved by treating the body of the `progn` as a standard
sequence of forms, which is handled by our sequence transformer.

Arguments:
  CPM-CTX: The current `yield-cpm-context` instance.
  FORM: The `(progn ...)` form.
  NEXT-CONT-NAME: The continuation for the entire `progn` block.

Returns:
  The symbol name of the FSM step that begins the `progn` sequence."
  (let ((body-forms (cdr form)))
    (if (null body-forms)
        (yield-cpm-transform-expression cpm-ctx nil next-cont-name)
      (yield-cpm--transform-body-sequence cpm-ctx body-forms next-cont-name))))

(defun yield-cpm-transform-if (cpm-ctx form next-cont-name)
  "Transforms an `if` form into a conditional jump in the FSM.
The transformation creates a diamond shape in the FSM graph.

  [eval-cond] --(true)--> [then-branch] --+
      |                                    |
      +---------(false)--> [else-branch] --+--> [exit-continuation]

Arguments:
  CPM-CTX: The current `yield-cpm-context` instance.
  FORM: The `(if ...)` form.
  NEXT-CONT-NAME: The continuation for the entire `if` expression.

Returns:
  The symbol name of the FSM step that evaluates the condition."
  (pcase-let* ((`(if ,cond-form ,then-body . ,else-body) form))
    (let* ((if-exit-cont next-cont-name)
           (else-entry-cont
            (yield-cpm-transform-expression cpm-ctx `(progn ,@else-body) if-exit-cont))
           (then-entry-cont
            (yield-cpm-transform-expression cpm-ctx then-body if-exit-cont))
           (eval-cond-step (yield-cpm-gensym "if-cond-eval")))
      (yield-cpm-add-fsm-step
       cpm-ctx eval-cond-step
       `(let ((cond-val ,(yield-cpm-substitute-bindings cpm-ctx cond-form)))
          (list ',yield--jump-status-key
                (if cond-val ',then-entry-cont ',else-entry-cont)
                cond-val)))
      eval-cond-step)))

(defun yield-cpm-transform-while (cpm-ctx form next-cont-name)
  "Transforms a `while` loop into a cycle in the FSM graph.
The graph looks like:

  -> [test-cond] --(true)--> [loop-body] --+
          |                                  |
          +---------(false)--> [exit-continuation]

Arguments:
  CPM-CTX: The current `yield-cpm-context` instance.
  FORM: The `(while ...)` form.
  NEXT-CONT-NAME: The continuation for when the loop terminates.

Returns:
  The symbol name of the FSM step that begins the loop."
  (pcase-let* ((`(while ,test-form . ,body) form))
    (let* ((loop-start-cont (yield-cpm-gensym "while-loop-start"))
           (loop-exit-cont next-cont-name)
           (loop-body-entry-cont
            (yield-cpm-transform-expression cpm-ctx `(progn ,@body) loop-start-cont)))
      (yield-cpm-add-fsm-step
       cpm-ctx loop-start-cont
       `(let ((test-val ,(yield-cpm-substitute-bindings cpm-ctx test-form)))
          (list ',yield--jump-status-key
                (if test-val ',loop-body-entry-cont ',loop-exit-cont)
                test-val)))
      loop-start-cont)))

(defun yield-cpm-transform-let (cpm-ctx form next-cont-name)
  "Transforms a `let` or `let*` form by lifting its variables.
The process turns `(let ((a E1) (b E2)) B)` into a sequence of
steps: `eval E1 -> store lifted-a -> eval E2 -> store lifted-b -> eval B`.

Arguments:
  CPM-CTX: The current `yield-cpm-context` instance.
  FORM: The `(let ...)` or `(let* ...)` form.
  NEXT-CONT-NAME: The continuation for after the `let` block.

Returns:
  The entry FSM step for initializing the bindings."
  (pcase-let* ((`(,(or 'let 'let*) ,bindings . ,body) form))
    (let* ((original-bindings
            (-map (lambda (b) (if (symbolp b) `(,b nil) b)) bindings))
           (new-cpm-bindings
            (copy-alist (yield-cpm-context-current-bindings cpm-ctx)))
           (final-body-entry-point nil))
      ;; Create lifted symbols for all variables in the new scope.
      (-each original-bindings
             (-lambda ((var _value))
               (let* ((lifted-var (yield-cpm-gensym (symbol-name var))))
                 (push (cons var lifted-var) new-cpm-bindings)
                 (push lifted-var (yield-cpm-context-all-lifted-symbols cpm-ctx)))))
      ;; Transform the body within the new lexical context.
      (let ((sub-cpm-ctx (copy-yield-cpm-context cpm-ctx)))
        (setf (yield-cpm-context-current-bindings sub-cpm-ctx) new-cpm-bindings)
        (setq final-body-entry-point
              (yield-cpm-transform-expression cpm-ctx `(progn ,@body) next-cont-name)))
      ;; Chain the binding initializations backwards.
      (let ((current-binding-cont final-body-entry-point))
        (dolist (binding-pair (reverse original-bindings))
          (let* ((var (car binding-pair))
                 (val-form (cl-second binding-pair))
                 (lifted-var (yield-cpm-get-lifted-symbol cpm-ctx var)))
            (setq current-binding-cont
                  (yield-cpm-transform-expression
                   cpm-ctx val-form
                   (yield-cpm-add-fsm-step
                    cpm-ctx (yield-cpm-gensym "let-assign")
                    `(progn
                       (setf ,lifted-var
                             ,(yield-cpm-context-value-sym cpm-ctx))
                       '(,yield--jump-status-key ,current-binding-cont)))))))
        current-binding-cont))))

(defun yield-cpm-transform-setf (cpm-ctx form next-cont-name)
  "Transforms a `(setf PLACE VALUE)` form."
  (pcase-let ((`(setf ,place ,value-form) form))
    (unless (symbolp place)
      (error "yield-cpm: `setf` transformation only supports symbol places, but got %S" place))
    (let ((lifted-var (yield-cpm-get-lifted-symbol cpm-ctx place)))
      (let ((assign-step
             (yield-cpm-add-fsm-step
              cpm-ctx (yield-cpm-gensym "setf-assign")
              `(progn
                 (setf ,lifted-var ,(yield-cpm-context-value-sym cpm-ctx))
                 (list ',yield--jump-status-key ',next-cont-name)))))
        (yield-cpm-transform-expression cpm-ctx value-form assign-step)))))

(defun yield-cpm-transform-setq (cpm-ctx form next-cont-name)
  "Transforms a `(setq VAR1 VAL1 ...)` form by converting it to a `progn` of `setf` forms."
  (let ((setq-args (cdr form))
        (progn-body '()))
    (when (/= 0 (% 2 (length setq-args)))
      (error "yield-cpm: Odd number of arguments to setq: %S" form))
    (while setq-args
      (push `(setf ,(car setq-args) ,(cadr setq-args)) progn-body)
      (setq setq-args (cddr setq-args)))
    (yield-cpm-transform-expression cpm-ctx `(progn ,@(nreverse progn-body)) next-cont-name)))

(defun yield-cpm-transform-funcall (cpm-ctx form next-cont-name)
  "Transforms a generic function call `(f A1 A2 ...)`.
This simple version assumes that none of the arguments A1, A2...
are yieldable expressions themselves. It creates a single step to
evaluate the entire form after substituting any lifted variables."
  (let* ((step-name (yield-cpm-gensym "funcall-step"))
         (substituted-form (yield-cpm-substitute-bindings cpm-ctx form)))
    (yield-cpm-add-fsm-step
     cpm-ctx step-name
     `(progn
        (setf ,(yield-cpm-context-value-sym cpm-ctx) ,substituted-form)
        (list ',yield--jump-status-key ',next-cont-name)))
    step-name))

(defun yield-cpm-transform-expression (cpm-ctx form next-cont-name)
  "Transforms a single Lisp FORM into FSM steps by dispatching to a helper."
  (pcase form
    ((pred numberp) (yield-cpm-handle-atomic-form cpm-ctx form next-cont-name))
    ((pred stringp) (yield-cpm-handle-atomic-form cpm-ctx form next-cont-name))
    ((pred (lambda (x) (memq x '(nil t)))) (yield-cpm-handle-atomic-form cpm-ctx form next-cont-name))
    ((pred symbolp) (yield-cpm-handle-atomic-form cpm-ctx form next-cont-name))
    (`(quote ,_) (yield-cpm-handle-atomic-form cpm-ctx form next-cont-name))
    (`(yield--internal-throw-form . ,_) (yield-cpm-transform-yield cpm-ctx form next-cont-name))
    (`(yield--internal-delegate-form . ,_) (yield-cpm-transform-yield-from cpm-ctx form next-cont-name))
    (`(progn . ,_) (yield-cpm-transform-progn cpm-ctx form next-cont-name))
    (`(if . ,_) (yield-cpm-transform-if cpm-ctx form next-cont-name))
    (`(while . ,_) (yield-cpm-transform-while cpm-ctx form next-cont-name))
    (`(,(or 'let 'let*) . ,_) (yield-cpm-transform-let cpm-ctx form next-cont-name))
    (`(setq . ,_) (yield-cpm-transform-setq cpm-ctx form next-cont-name))
    (`(setf . ,_) (yield-cpm-transform-setf cpm-ctx form next-cont-name))
    ((pred consp) (yield-cpm-transform-funcall cpm-ctx form next-cont-name))
    (_ (error "yield-cpm: Unhandled form in transformation: %S" form))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Main CPM Entry Point & Code Generation

(defun yield-cpm--build-generator-body (ordered-steps cpm-ctx fsm-obj-sym
                                                        initial-arg-bindings
                                                        fsm-options-var)
  "Build the final `let*` block that forms the body of the generator `defun`.
This function's sole purpose is to generate the final, runnable code
for a generator instance. It constructs a `let*` block that sets up
the generator's entire state and returns a closure that acts as the
generator instance.

Arguments:
  ORDERED-STEPS: The final, correctly ordered vector of FSM steps.
  CPM-CTX: The context, for accessing gensyms and lifted vars.
  FSM-OBJ-SYM: The gensym for the FSM instance variable.
  INITIAL-ARG-BINDINGS: An alist of `(original-arg . original-arg)`.
  FSM-OPTIONS-VAR: The symbol that will hold the &rest fsm-options at runtime.

Returns:
  A `let*` s-expression that, when evaluated, creates and returns
  a stateful generator instance."
  `(let* ((,fsm-obj-sym
           (apply #'yield-fsm-new :init ',ordered-steps
                  ,fsm-options-var))
          ,@(yield-cpm--make-initial-let-bindings cpm-ctx))

     (progn
       ,@(-map (lambda (binding)
                 (let* ((arg-sym (car binding))
                        (lifted-sym (yield-cpm-get-lifted-symbol cpm-ctx arg-sym)))
                   `(setf ,lifted-sym ,arg-sym)))
               initial-arg-bindings)

       (lambda (&optional value-to-send)
         (let ((fsm-obj ,fsm-obj-sym)
               (cpm-val ,(yield-cpm-context-value-sym cpm-ctx))
               (result nil))

           (when (boundp 'value-to-send)
             (setq cpm-val value-to-send))

           (catch 'yield-fsm-finished
             (setq result
                   (if (and fsm-obj (yield-fsm-was-yielded fsm-obj))
                       (yield-fsm-resume fsm-obj cpm-val)
                     (yield-fsm-run fsm-obj)))

             (while (and (listp result) (eq (car result) :delegating))
               (let* ((delegate-fsm (yield-fsm-active-delegate fsm-obj))
                      (delegate-result
                       (next! delegate-fsm (yield-fsm-resuming-value fsm-obj))))
                 (setf (yield-fsm-resuming-value fsm-obj) nil)

                 (cond
                  ((memq (car delegate-result) '(,yield--yield-status-key ,yield--await-external-status-key))
                   (setq result delegate-result)
                   (throw yield--yield-throw-tag result))
                  ((eq (car delegate-result) yield--done-status-key)
                   (setf (yield-fsm-active-delegate fsm-obj) nil)
                   (setq cpm-val (plist-get delegate-result yield--value-key))
                   (setq result (yield-fsm-run fsm-obj)))
                  ((eq (car delegate-result) yield--error-status-key)
                   (setf (yield-fsm-active-delegate fsm-obj) nil)
                   (setf (yield-fsm-step-error fsm-obj)
                         (plist-get delegate-result yield--error-object-key))
                   (setf (yield-fsm-state fsm-obj) :error)
                   (setq result (yield-fsm-run fsm-obj))))))
             result))))))

(defun yield-cpm-generate-generator-lambda-form (body initial-arg-bindings fsm-options-var)
  "Main function to transform a generator BODY into the body of a `defun`.
This function orchestrates the entire compilation process:
1. Initializes a compilation context.
2. Lifts argument variables.
3. Transforms the Lisp code body into a sequence of FSM steps.
4. Calls a helper to construct the final, runnable code block.

Arguments:
  BODY: The Lisp code list representing the generator's body.
  INITIAL-ARG-BINDINGS: An alist of `(original-arg . original-arg)`.
  FSM-OPTIONS-VAR: The symbol that will hold the &rest fsm-options
                   at runtime.

Returns:
  A single `let*` s-expression that constitutes the entire body
  of the `defun` being generated."
  (let* ((cpm-ctx (%%make-yield-cpm-context
                   :value-sym (yield-cpm-gensym "cpm-val")
                   :final-sym (yield-cpm-gensym "cpm-final-result")
                   :final-step-name (yield-cpm-gensym "cpm-final-step")))
         (fsm-obj-sym (yield-cpm-gensym "fsm-obj-"))
         (final-body-form `(list ',yield--done-status-key t)))

    (-each initial-arg-bindings
           (-lambda ((orig-sym value))
             (let ((lifted-sym (yield-cpm-gensym (symbol-name orig-sym))))
               (push (cons orig-sym lifted-sym)
                     (yield-cpm-context-current-bindings cpm-ctx))
               (push lifted-sym (yield-cpm-context-all-lifted-symbols cpm-ctx)))))

    (let ((initial-body-cont
           (yield-cpm-transform-expression
            cpm-ctx body (yield-cpm-context-final-step-name cpm-ctx))))

      (let* ((body-steps-in-exec-order (yield-cpm-context-fsm-steps cpm-ctx))
             (final-step-plist `(:name ,(yield-cpm-context-final-step-name cpm-ctx)
                                     :thunk ,(yield-cpm-make-thunk final-body-form)))
             (all-generated-steps (reverse (cons final-step-plist (reverse body-steps-in-exec-order))))
             (final-steps-vector (vconcat all-generated-steps)))

        (yield-cpm--build-generator-body
         final-steps-vector
         cpm-ctx
         fsm-obj-sym
         initial-arg-bindings
         fsm-options-var)))))

(provide 'yield-cpm)
;;; yield-cpm.el ends here