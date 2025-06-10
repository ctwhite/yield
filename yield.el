;;; yield.el --- Top-level entry point for the `yield` generator library. -*-
;;; lexical-binding: t; -*-

;; Author: Christian White <christiantwhite@protonmail.com>
;; Keywords: extensions, tools, lisp
;;
;; This file is part of the `yield` generator library.
;;
;;; Commentary:
;;
;; This file serves as the primary entry point for the `yield` generator library.
;; By requiring this single file, users gain access to the full functionality
;; of the framework.
;;
;; It loads the public API defined in `yield-generator.el`, which in turn
;; loads the necessary subsystems: the FSM runtime and the CPM compiler.
;;
;; Key features available after loading this file:
;;
;; - Defining resumable generators with `defgenerator!`.
;; - Suspending execution and yielding values with `yield!`.
;; - Delegating to sub-generators with `yield-from!`.
;; - Advancing generators and sending values with `next!`.
;;
;;; Code:

(require 'yield-generator)

(provide 'yield)
;;; yield.el ends here