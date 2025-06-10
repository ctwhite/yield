# Yield: Generators for Emacs Lisp

A lightweight Emacs Lisp library for creating resumable **generators** and sequential workflows.

## Introduction

`yield` provides a robust implementation of **generators** for Emacs Lisp. Generators are special functions that can pause their execution, return an intermediate value (called "yielding"), and then resume from where they left off later. This makes them incredibly useful for:

* **Iterative Processes**: Processing large datasets piece by piece, rather than all at once.

* **Lazy Evaluation**: Generating sequences of values on demand.

* **Stateful Operations**: Managing complex state across multiple calls without relying on global variables.

* **Building Custom Iterators**: Creating flexible and powerful ways to traverse data or produce sequences.

Alongside Emacs Lisp's built-in `generator.el`, `yield` offers a distinct approach to implementing generators, utilizing a unique Continuation-Passing Style (CPS) transformation and Finite State Machine (FSM) runtime.

## Core Concepts

The `yield` library provides three primary macros/functions to work with generators:

### `defgenerator! NAME ARGS &rest BODY`

This macro defines a generator function. It looks and feels like `defun`, but the function it creates returns a **generator instance** (a stateful closure) rather than a single value. You then use `next!` to interact with this instance.

### `yield! VALUE`

Inside a `defgenerator!`, you use `yield!` to pause the generator's execution and return `VALUE`. When `next!` is called on the generator instance again, execution resumes immediately after the `yield!` call.

### `next! GENERATOR-INSTANCE &optional VALUE-TO-SEND`

This function drives a generator instance.

* It executes the generator's code until the next `yield!` point is reached.

* It returns a plist indicating the generator's current status (`:yield`, `:done`, `:error`, etc.) and the yielded value.

* You can optionally send a `VALUE-TO-SEND` back into the generator; this value becomes the result of the `yield!` expression that paused the generator.

### `yield-from! ITERATOR-FORM`

This macro allows a generator to delegate its execution to another generator. It will `yield!` all values from `ITERATOR-FORM` until that sub-generator is exhausted, and then resume its own execution.

## Quick Start & Examples

To use the `yield` library, simply ensure `yield.el`, `yield-generator.el`, `yield-cpm.el`, and `yield-fsm.el` are loaded (e.g., placed in your `load-path` and `(require 'yield)`).

### Example 1: A Simple Counter Generator

Let's create a generator that counts up from a starting number:

```lisp
(require 'yield) ; Make sure the library is loaded

(defgenerator! counter (start step)
  "A generator that counts from START by STEP indefinitely."
  (let ((current start))
    (while t
      (yield! current) ; Pause and yield the current number
      (setq current (+ current step))))) ; Increment for the next yield

;; Create a generator instance that starts at 0 and increments by 1
(setq my-counter (counter 0 1))

;; Drive the generator using next!
(next! my-counter)
;; => (:yield t :value 0)

(next! my-counter)
;; => (:yield t :value 1)

(next! my-counter)
;; => (:yield t :value 2)

;; Create another independent instance
(setq even-numbers (counter 0 2))

(next! even-numbers)
;; => (:yield t :value 0)

(next! even-numbers)
;; => (:yield t :value 2)

```

### Example 2: Delegating with `yield-from!` (Fibonacci Sequence)

Here's an example where one generator delegates to another, perhaps after an introductory yield:

```lisp
(require 'yield)

(defgenerator! fib-sequence ()
  "Yields Fibonacci numbers indefinitely: 0, 1, 1, 2, 3, 5..."
  (let ((a 0) (b 1))
    (while t
      (yield! a) ; Yield the current Fibonacci number
      (let ((next-fib (+ a b)))
        (setq a b)
        (setq b next-fib)))))

(defgenerator! fib-with-intro ()
  "A generator that introduces itself, then yields Fibonacci numbers."
  (yield! "Welcome to the Fibonacci sequence!") ; First, yield an intro message
  (yield-from! (fib-sequence)) ; Then, delegate to the fib-sequence generator
  (yield! "Fibonacci sequence completed.")) ; This will only be reached if fib-sequence finishes (which it doesn't here)

;; Create an instance of the delegating generator
(setq fib-gen (fib-with-intro))

;; Drive the generator
(next! fib-gen)
;; => (:yield t :value "Welcome to the Fibonacci sequence!")

(next! fib-gen)
;; => (:yield t :value 0) ; First fib number from delegated generator

(next! fib-gen)
;; => (:yield t :value 1) ; Second fib number

(next! fib-gen)
;; => (:yield t :value 1) ; Third fib number

;; Continue calling next! to get more Fibonacci numbers
;; (fib-sequence is an infinite generator, so 'fib-with-intro' will never reach its final yield)

```

## How It Works Under the Hood

The `yield` library leverages a sophisticated **Continuation-Passing Style (CPS) transformation** and a **Finite State Machine (FSM)** runtime to achieve its resumable behavior.

1. **CPM (Continuation-Passing Machine)**: The `yield-cpm.el` module acts as a compiler. When you define a generator with `defgenerator!`, the CPM takes your readable Emacs Lisp code and transforms it. It converts all control flow (like `if`, `while`) and `yield!` points into a linear sequence of small, executable steps (called "thunks"). It also "lifts" local variables into a shared environment so their state is preserved across `yield!` calls.

2. **FSM (Finite State Machine)**: The `yield-fsm.el` module is the runtime engine. It's a simple, state-driven loop that executes the sequence of steps generated by the CPM. When a `yield!` step is encountered, the FSM pauses, stores its current position (index) and state, and returns control. When `next!` is called again, the FSM resumes from the exact stored position and continues executing the next step in the sequence.

This architecture allows for flexible, non-blocking iterative processes directly within Emacs Lisp.

## Installation

To use `yield`, place all `.el` files (or their compiled `.elc` counterparts) into a directory that is part of your Emacs `load-path`.

Alternatively, for `use-package` users with `straight.el`, you can install it by adding the following to your Emacs initialization file:

```lisp
(use-package yield
  :straight (yield :type git :host github :repo "your-username/yield") ; REPLACE with actual repo info
  :config
  ;; Any yield-specific configurations here
  )
```

## Contributing & Feedback

We welcome contributions, bug reports, and feedback! If you encounter any issues or have suggestions for improvements, please reach out.
