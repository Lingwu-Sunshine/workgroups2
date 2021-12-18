;;; workgroups2-support.el --- load/unload 3rd party buffers  -*- lexical-binding: t -*-


;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program; if not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'workgroups2-sdk)

(defmacro wg-support (mode pkg params)
  "Macro to create (de)serialization functions for a buffer.
You need to save/restore a specific MODE which is loaded from a
package PKG.  In PARAMS you give local variables to save and a
deserialization function."
  (declare (indent 2))
  `(let ((mode-str (symbol-name ,mode))
         (args ,params))

     ;; Fix compile warn.
     (ignore args)

     (eval `(defun ,(intern (format "wg-deserialize-%s-buffer" mode-str)) (buffer)
              "DeSerialization function created with `wg-support'.
Gets saved variables and runs code to restore a BUFFER."
              (when (require ',,pkg nil 'noerror)
                (wg-dbind (this-function variables) (wg-buf-special-data buffer)
                  (let ((default-directory (car variables))
                        (df (cdr (assoc 'deserialize ',,params)))
                        (user-vars (cadr variables)))
                    (if df
                        (funcall df buffer user-vars)
                      (get-buffer-create wg-default-buffer))
                    ))))
           t)

     (eval `(defun ,(intern (format "wg-serialize-%s-buffer" mode-str)) (buffer)
              "Serialization function created with `wg-support'.
Saves some variables to restore a BUFFER later."
              (when (get-buffer buffer)
                (with-current-buffer buffer
                  (when (eq major-mode ',,mode)
                    (let ((sf (cdr (assoc 'serialize ',,params)))
                          (save (cdr (assoc 'save ',,params))))
                      (list ',(intern (format "wg-deserialize-%s-buffer" mode-str))
                            (list default-directory
                                  (if sf
                                      (funcall sf buffer)
                                    (if save (mapcar 'wg-get-value save)))
                                  )))))))
           t)
     ;; Maybe change a docstring for functions
     ;;(put (intern (format "wg-serialize-%s-buffer" (symbol-name mode)))
     ;;     'function-documentation
     ;;     (format "A function created by `wg-support'."))

     ;; Add function to `wg-special-buffer-serdes-functions' variable
     (eval `(add-to-list 'wg-special-buffer-serdes-functions
                         ',(intern (format "wg-serialize-%s-buffer" mode-str)) t)
           t)))

;; Dired
(wg-support 'dired-mode 'dired
  `((deserialize . ,(lambda (_buffer _vars)
                      (when (or wg-restore-remote-buffers
                                (not (file-remote-p default-directory)))
                        (let ((d (wg-get-first-existing-dir)))
                          (if (file-directory-p d) (dired d))))))))

(wg-support 'Info-mode 'info
  `((save . (Info-current-file Info-current-node))
    (deserialize . ,(lambda (buffer vars)
                      (if vars
                          (if (fboundp 'Info-find-node)
                              (apply #'Info-find-node vars))
                        (info)
                        (get-buffer (wg-buf-name buffer)))))))

;; `help-mode'
;; Bug: https://github.com/pashinin/workgroups2/issues/29
;; bug in wg-get-value
(wg-support 'help-mode 'help-mode
  `((save . (help-xref-stack-item help-xref-stack help-xref-forward-stack))
    (deserialize . ,(lambda (_buffer vars)
                      (wg-dbind (item stack forward-stack) vars
                        (condition-case err
                            (apply (car item) (cdr item))
                          (error (message "%s" err)))
                        (when (get-buffer "*Help*")
                          (set-buffer (get-buffer "*Help*"))
                          (setq help-xref-stack stack
                                help-xref-forward-stack forward-stack)))))))

;; ielm
(wg-support 'inferior-emacs-lisp-mode 'ielm
  `((deserialize . ,(lambda (_buffer _vars)
                      (ielm) (get-buffer "*ielm*")))))

;; Magit status
(wg-support 'magit-status-mode 'magit
  `((deserialize . ,(lambda (_buffer _vars)
                      (if (file-directory-p default-directory)
                          (magit-status-setup-buffer default-directory)
                        (let ((d (wg-get-first-existing-dir)))
                          (if (file-directory-p d) (dired d))))))))

;; Shell
(wg-support 'shell-mode 'shell
  `((deserialize . ,(lambda (buffer _vars)
                      (shell (wg-buf-name buffer))))))

;; org-agenda buffer
(defun wg-get-org-agenda-view-commands ()
  "Return commands to restore the state of Agenda buffer.
Can be restored using \"(eval commands)\"."
  (interactive)
  (when (boundp 'org-agenda-buffer-name)
    (if (get-buffer org-agenda-buffer-name)
        (with-current-buffer org-agenda-buffer-name
          (let* ((p (or (and (looking-at "\\'") (1- (point))) (point)))
                 (series-redo-cmd (get-text-property p 'org-series-redo-cmd)))
            (if series-redo-cmd
                (get-text-property p 'org-series-redo-cmd)
              (get-text-property p 'org-redo-cmd)))))))

(defun wg-run-agenda-cmd (f)
  "Run commands F in Agenda buffer.
You can get these commands using `wg-get-org-agenda-view-commands'."
  (when (and (boundp 'org-agenda-buffer-name)
             (fboundp 'org-current-line)
             (fboundp 'org-goto-line))
    (if (get-buffer org-agenda-buffer-name)
        (save-window-excursion
          (with-current-buffer org-agenda-buffer-name
            (let* ((line (org-current-line)))
              (if f (eval f t))
              (org-goto-line line)))))))

(wg-support 'org-agenda-mode 'org-agenda
  '((serialize . (lambda (buffer)
                   (wg-get-org-agenda-view-commands)))
    (deserialize . (lambda (buffer vars)
                     (org-agenda-list)
                     (let* ((buf (get-buffer org-agenda-buffer-name)))
                       (when
                        (with-current-buffer buf
                          (wg-run-agenda-cmd vars))
                        buf))))))

;; eshell
(wg-support 'eshell-mode 'esh-mode
  '((deserialize . (lambda (buffer vars)
                     (prog1 (eshell t)
                       (rename-buffer (wg-buf-name buffer) t))))))

;; term-mode
;;
;; This should work for `ansi-term's, too, as there doesn't seem to
;; be any difference between the two except how the name of the
;; buffer is generated.
;;
(wg-support 'term-mode 'term
  `((serialize . ,(lambda (buffer)
                    (if (get-buffer-process buffer)
                        (car (last (process-command (get-buffer-process buffer))))
                      "/bin/bash")))
    (deserialize . ,(lambda (buffer vars)
                      (cl-labels ((term-window-width () 80)
                                  (window-height () 24))
                        (prog1 (term vars)
                          (rename-buffer (wg-buf-name buffer) t)))))))

;; `inferior-python-mode'
(wg-support 'inferior-python-mode 'python
            `((save . (python-shell-interpreter python-shell-interpreter-args))
              (deserialize . ,(lambda (_buffer vars)
                                (wg-dbind (pythoncmd pythonargs) vars
                                          (run-python (concat pythoncmd " " pythonargs))
                                          (let ((buf (get-buffer (process-buffer
                                                                  (python-shell-get-process)))))
                                            (when buf
                                              (with-current-buffer buf (goto-char (point-max)))
                                              buf)))))))


;; Sage shell ;;
(wg-support 'inferior-sage-mode 'sage-mode
            `((deserialize . ,(lambda (_buffer _vars)
                                (save-window-excursion
                                  (if (boundp' sage-command)
                                      (run-sage t sage-command t)))
                                (when (and (boundp 'sage-buffer) sage-buffer)
                                  (set-buffer sage-buffer)
                                  (switch-to-buffer sage-buffer)
                                  (goto-char (point-max)))))))

;; `inferior-ess-mode'     M-x R
(defvar ess-history-file)
(defvar ess-ask-about-transfile)
(defvar ess-ask-for-ess-directory)

(wg-support 'inferior-ess-mode 'ess-inf
  `((save . (inferior-ess-program))
    (deserialize . ,(lambda (buffer vars)
                      (wg-dbind (_cmd) vars
                        (let ((ess-ask-about-transfile nil)
                              (ess-ask-for-ess-directory nil)
                              (ess-history-file nil))
                          (R)
                          (get-buffer (wg-buf-name buffer))))))))

;; `inferior-octave-mode'
(wg-support 'inferior-octave-mode 'octave
  `((deserialize . ,(lambda (buffer _vars)
                      (prog1 (run-octave)
                        (rename-buffer (wg-buf-name buffer) t))))))

;; `prolog-inferior-mode'
(wg-support 'prolog-inferior-mode 'prolog
  `((deserialize . ,(lambda (_buffer _vars)
                      (save-window-excursion
                        (run-prolog nil))
                      (switch-to-buffer "*prolog*")
                      (goto-char (point-max))))))

;; `ensime-inf-mode'
(wg-support 'ensime-inf-mode 'ensime
  `((deserialize . ,(lambda (_buffer _vars)
                      (save-window-excursion
                        (ensime-inf-switch))
                      (when (boundp 'ensime-inf-buffer-name)
                        (switch-to-buffer ensime-inf-buffer-name)
                        (goto-char (point-max)))))))

;; compilation-mode
;;
;; I think it's not a good idea to compile a program just to switch
;; workgroups. So just restoring a buffer name.
(wg-support 'compilation-mode 'compile
  `((serialize . ,(lambda (_buffer)
                    (if (boundp' compilation-arguments) compilation-arguments)))
    (deserialize . ,(lambda (buffer vars)
                      (save-window-excursion
                        (get-buffer-create (wg-buf-name buffer)))
                      (with-current-buffer (wg-buf-name buffer)
                        (when (boundp' compilation-arguments)
                          (make-local-variable 'compilation-arguments)
                          (setq compilation-arguments vars)))
                      (switch-to-buffer (wg-buf-name buffer))
                      (goto-char (point-max))))))

;; grep-mode
;; see grep.el - `compilation-start' - it is just a compilation buffer
;; local variables:
;; `compilation-arguments' == (cmd mode nil nil)
(wg-support 'grep-mode 'grep
  `((serialize . ,(lambda (_buffer)
                    (if (boundp' compilation-arguments) compilation-arguments)))
    (deserialize . ,(lambda (_buffer vars)
                      (compilation-start (car vars) (nth 1 vars))
                      (switch-to-buffer "*grep*")))))

(defun wg-deserialize-slime-buffer (buf)
  "Deserialize `slime' buffer BUF."
  (when (require 'slime nil 'noerror)
    (wg-dbind (_this-function args) (wg-buf-special-data buf)
      (let ((default-directory (car args))
            (arguments (nth 1 args)))
        (when (and (fboundp 'slime-start*)
                   (fboundp 'slime-process))
          (save-window-excursion
            (slime-start* arguments))
          (switch-to-buffer (process-buffer (slime-process)))
          (current-buffer))))))

;; `comint-mode'  (general mode for all shells)
;;
;; It may have different shells. So we need to determine which shell is
;; now in `comint-mode' and how to restore it.
;;
;; Just executing `comint-exec' may be not enough because we can miss
;; some hooks or any other stuff that is executed when you run a
;; specific shell.
(defun wg-serialize-comint-buffer (buffer)
  "Serialize comint BUFFER."
  (with-current-buffer buffer
    (if (fboundp 'comint-mode)
        (when (eq major-mode 'comint-mode)
          ;; `slime-inferior-lisp-args' var is used when in `slime'
          (when (and (boundp 'slime-inferior-lisp-args)
                     slime-inferior-lisp-args)
            (list 'wg-deserialize-slime-buffer
                  (list default-directory slime-inferior-lisp-args)
                  ))))))

;; inf-mongo
;; https://github.com/tobiassvn/inf-mongo
;; `mongo-command' - command used to start inferior mongo
(wg-support 'inf-mongo-mode 'inf-mongo
  `((serialize . ,(lambda (_buffer)
                    (if (boundp 'inf-mongo-command) inf-mongo-command)))
    (deserialize . ,(lambda (_buffer vars)
                      (save-window-excursion
                        (when (fboundp 'inf-mongo)
                          (inf-mongo vars)))
                      (when (get-buffer "*mongo*")
                        (switch-to-buffer "*mongo*")
                        (goto-char (point-max)))))))

(defun wg-temporarily-rename-buffer-if-exists (buffer)
  "Rename BUFFER if it exists."
  (when (get-buffer buffer)
    (with-current-buffer buffer
      (rename-buffer "*wg--temp-buffer*" t))))

;; SML shell
;; Functions to serialize deserialize inferior sml buffer
;; `inf-sml-program' is the program run as inferior sml, is the
;; `inf-sml-args' are the extra parameters passed, `inf-sml-host'
;; is the host on which sml was running when serialized
(wg-support 'inferior-sml-mode 'sml-mode
  `((serialize . ,(lambda (_buffer)
                    (list (if (boundp 'sml-program-name) sml-program-name)
                          (if (boundp 'sml-default-arg) sml-default-arg)
                          (if (boundp 'sml-host-name) sml-host-name))))
    (deserialize . ,(lambda (buffer vars)
                      (wg-dbind (program args host) vars
                        (save-window-excursion
                          ;; If a inf-sml buffer already exists rename it temporarily
                          ;; otherwise `run-sml' will simply switch to the existing
                          ;; buffer, however we want to create a separate buffer with
                          ;; the serialized name
                          (let* ((inf-sml-buffer-name (concat "*"
                                                              (file-name-nondirectory program)
                                                              "*"))
                                 (existing-sml-buf (wg-temporarily-rename-buffer-if-exists
                                                    inf-sml-buffer-name)))
                            (with-current-buffer (run-sml program args host)
                              ;; Rename the buffer
                              (rename-buffer (wg-buf-name buffer) t)

                              ;; Now we can re-rename the previously renamed buffer
                              (when existing-sml-buf
                                (with-current-buffer existing-sml-buf
                                  (rename-buffer inf-sml-buffer-name t))))))
                        (switch-to-buffer (wg-buf-name buffer))
                        (goto-char (point-max)))))))

;; Geiser repls
;; http://www.nongnu.org/geiser/
(wg-support 'geiser-repl-mode 'geiser
  `((save . (geiser-impl--implementation))
    (deserialize . ,(lambda (buffer vars)
                      (when (fboundp 'run-geiser)
                        (wg-dbind (impl) vars
                          (run-geiser impl)
                          (goto-char (point-max))))
                      (switch-to-buffer (wg-buf-name buffer))))))

;; w3m-mode
(wg-support 'w3m-mode 'w3m
  `((save . (w3m-current-url))
    (deserialize . ,(lambda (_buffer vars)
                      (wg-dbind (url) vars
                        (w3m-goto-url url))))))

;; notmuch
(wg-support 'notmuch-hello-mode 'notmuch
  `((deserialize . ,(lambda (buffer vars)
                      (ignore vars)
                      (notmuch)
                      (get-buffer (wg-buf-name buffer))))))

;; dired-sidebar
(defvar dired-sidebar-display-alist)
(wg-support 'dired-sidebar-mode 'dired-sidebar
  `((serialize . ,(lambda (_buffer) dired-sidebar-display-alist))
    (deserialize . ,(lambda (_buffer saved-display-alist)
                      (when (and (or wg-restore-remote-buffers
                                     (not (file-remote-p default-directory)))
                                 ;; Restore buffer only if `dired-sidebar-show-sidebar'
                                 ;; will place it in the same side window as before.
                                 (equal dired-sidebar-display-alist saved-display-alist))
                        (let ((dir (wg-get-first-existing-dir)))
                          (when (file-directory-p dir)
                            (let ((buffer (dired-sidebar-get-or-create-buffer dir)))
                              ;; Set up the buffer by calling `dired-sidebar-show-sidebar'
                              ;; for side effects only, discarding the created window. We
                              ;; don't want to add extra new windows during the session
                              ;; restoration process.
                              (save-window-excursion (dired-sidebar-show-sidebar buffer))
                              ;; HACK: Replace the just-restored window after session is
                              ;; restored. This ensures that we perform any additional
                              ;; window setup that was not done by deserialization. The
                              ;; point is to avoid depending too closely on the
                              ;; implementation details of dired-sidebar. Rather than
                              ;; serialize every detail, we let `dired-sidebar-show-sidebar'
                              ;; do the work.
                              (let ((frame (selected-frame)))
                                (run-at-time 0 nil
                                             (lambda ()
                                               (with-selected-frame frame
                                                 (dired-sidebar-hide-sidebar)
                                                 (dired-sidebar-show-sidebar buffer)))))
                              buffer))))))))

(wg-support 'ivy-occur-grep-mode 'ivy
            `((serialize . ,(lambda (_buffer)
                              (list default-directory
                                    (base64-encode-string (buffer-string) t))))
              (deserialize . ,(lambda (buffer _vars)
                                (switch-to-buffer (wg-buf-name buffer))
                                (setq default-directory (nth 0 _vars))
                                (goto-char (point-min))
                                (insert (base64-decode-string (nth 1 _vars)))
                                (goto-char (point-min))
                                ;; easier than `ivy-occur-grep-mode' to set up
                                (grep-mode)
                                (current-buffer)))))

(provide 'workgroups2-support)
;;; workgroups2-support.el ends here
