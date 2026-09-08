;; Setup to export Org files to Hugo-compatible Markdown using
;; `ox-astro' in an "emacs -Q" environment.

;; Some sane settings
(setq-default require-final-newline t)
(setq-default indent-tabs-mode nil)
(setq-default make-backup-files nil)

;; Toggle debug on error, including `user-error'.
(setq debug-ignored-errors (remq 'user-error debug-ignored-errors))
(toggle-debug-on-error)

(defvar ox-astro-test-setup-verbose nil
  "When non-nil, enable printing more messages from setup-ox-astro.el.")

(defvar ox-astro-install-org-from-elpa (or (null (getenv "OX_HUGO_DEFAULT_ORG"))
                                          (version< emacs-version "26.0"))
  "When non-nil, install Org from Org Elpa.

The default value of this variable is non-nil if emacs version is
older than 26 AND the environment variable OX_HUGO_DEFAULT_ORG is
unset, else it is nil.

Emacs 26 onwards comes with at least Org 9.1.4.  So there is no
need to install Org from Elpa as that Org version meets the
minimum requirement for `ox-astro'.  So set the environment
variable OX_HUGO_DEFAULT_ORG to a value like 1 if using emacs 26
or newer.")

(defvar ox-astro-default-share-directory nil
  "Share directory for this Emacs installation.")

(defvar ox-astro-default-lisp-directory nil
  "Directory containing lisp files for the Emacs installation.

This value must match the path to the lisp/ directory of the
Emacs installation.  If Emacs is installed using
--prefix=\"${PREFIX_DIR}\" this value would typically be
\"${PREFIX_DIR}/share/emacs/<VERSION>/lisp/\".")

;; Remove Org that ships with Emacs from the `load-path' if installing
;; it from Elpa.
(when ox-astro-install-org-from-elpa
  (let* ((bin-dir (when (and invocation-directory
                             (file-exists-p invocation-directory))
                    (file-truename invocation-directory)))
         (prefix-dir (when bin-dir        ;Because bin-dir = prefix-dir + "bin/"
                       (file-name-directory (directory-file-name bin-dir))))
         (share-dir (when prefix-dir
                      (let ((share-dir-1 (file-name-as-directory (expand-file-name "share" prefix-dir))))
                        (when (file-exists-p share-dir-1)
                          (setq ox-astro-default-share-directory share-dir-1))
                        share-dir-1)))
         (version-dir (when share-dir
                        (let* ((emacs-dir (file-name-as-directory (expand-file-name "emacs" share-dir)))
                               ;; Possibility where the lisp dir is something like
                               ;; ../emacs/26.0.50/lisp/.  If `emacs-version' is
                               ;; x.y.z.w, remove the ".w" portion.
                               ;; http://git.savannah.gnu.org/cgit/emacs.git/commit/?id=22b2207471807bda86534b4faf1a29b3a6447536
                               (version (replace-regexp-in-string "\\([0-9]+\\.[0-9]+\\.[0-9]+\\).*" "\\1" emacs-version))
                               (version-dir-1 (file-name-as-directory (expand-file-name version emacs-dir))))
                          (if (file-exists-p version-dir-1)
                              version-dir-1
                            ;; Possibility where the lisp dir is something like
                            ;; ../emacs/25.2/lisp/.  If `emacs-version' is x.y.z,
                            ;; remove the ".z" portion.
                            (setq version (replace-regexp-in-string "\\([0-9]+\\.[0-9]+\\).*" "\\1" emacs-version))
                            (setq version-dir-1 (file-name-as-directory (expand-file-name version emacs-dir)))
                            (when (file-exists-p version-dir-1)
                              version-dir-1))))))
    (when version-dir
      (let ((lisp-dir-1 (file-name-as-directory (expand-file-name "lisp" version-dir))))
        (when (file-exists-p lisp-dir-1)
          (setq ox-astro-default-lisp-directory lisp-dir-1)))))
  (when ox-astro-test-setup-verbose
    (message "ox-astro-default-share-directory: %s" ox-astro-default-share-directory)
    (message "ox-astro-default-lisp-directory: %s" ox-astro-default-lisp-directory))

  (with-eval-after-load 'package
    ;; Remove Org that ships with Emacs from the `load-path'.
    (let ((default-org-path (expand-file-name "org" ox-astro-default-lisp-directory)))
      (setq load-path (delete default-org-path load-path)))

    ;; Remove Org installed in `site-lisp' directory from the `load-path'.
    (let ((site-lisp-org-path (expand-file-name "emacs/site-lisp/org" ox-astro-default-share-directory)))
      (setq load-path (delete site-lisp-org-path load-path)))

    ;; Remove Org from `package--builtin-versions'.
    (setq package--builtin-versions (delete (assoc 'org package--builtin-versions) package--builtin-versions))
    ;; Remove Org from `package--builtins'.
    (require 'finder-inf nil t)         ;Populate `package--builtins'
    (setq package--builtins (delete (assoc 'org package--builtins) package--builtins))

    (when ox-astro-test-setup-verbose
      (message "org detected as installed initially? %S" (package-installed-p 'org))
      (message "load-path: %s" load-path)
      ;; (message "`load-path' Shadows:")
      ;; (message (list-load-path-shadows :stringp))
      )))

(defvar ox-astro-tmp-dir (let ((dir (file-name-as-directory
                                    (or (getenv "OX_HUGO_TMP_DIR")
                                        (expand-file-name
                                         "ox-astro-dev"
                                         (file-name-as-directory
                                          (expand-file-name
                                           user-login-name temporary-file-directory)))))))
                          (make-directory dir :parents)
                          dir))
(when ox-astro-test-setup-verbose
  (message "ox-astro-tmp-dir: %s" ox-astro-tmp-dir))

(defvar ox-astro-packages '(toc-org citeproc org-ref tomelr yaml))
(when ox-astro-install-org-from-elpa
  ;; Fri Sep 22 18:24:19 EDT 2017 - kmodi
  ;; Install the packages in the specified order. We do not want
  ;; `toc-org' to be installed first. If that happens, `org' will be
  ;; required before the newer version of Org gets installed and we
  ;; will end up with mixed Org version.  So put `org' at the
  ;; beginning of `ox-astro-packages'.
  (add-to-list 'ox-astro-packages 'org))

(defvar ox-astro-site-git-root (progn
                                (require 'vc-git)
                                (file-truename (vc-git-root default-directory)))
  "Absolute path of the git root of the current project.")
(when ox-astro-test-setup-verbose
  (message "ox-astro-site-git-root: %S" ox-astro-site-git-root))

(defvar ox-astro-autoloads-file (expand-file-name "ox-astro-autoloads.el" ox-astro-site-git-root)
  "Path to ox-astro package's generated autoloads file.")

(if (and (stringp ox-astro-tmp-dir)
         (file-exists-p ox-astro-tmp-dir))
    (progn
      ;; Load newer version of .el and .elc if both are available
      (setq load-prefer-newer t)

      (setq package-user-dir (format "%selpa_%s/" ox-astro-tmp-dir emacs-major-version))

      ;; Below require will auto-create `package-user-dir' it doesn't exist.
      (require 'package)

      ;; Note: Org stable is now fetched from the GNU Elpa.
      (let* ((no-ssl (and (memq system-type '(windows-nt ms-dos))
                          (not (gnutls-available-p))))
             (protocol (if no-ssl
                           "http"
                         "https"))
             (melpa-url (concat protocol "://melpa.org/packages/")))
        (add-to-list 'package-archives (cons "melpa" melpa-url) :append) ;For `toc-org', `citeproc'
        )

      ;; Delete element with "nongnu" car from `package-archives'.
      (setq package-archives (delq (assoc "nongnu" package-archives) package-archives))

      ;; Generate/update and load the autoloads for ox-astro.el and co.
      (if (fboundp #'loaddefs-generate) ;Emacs 29+
          (loaddefs-generate ox-astro-site-git-root ox-astro-autoloads-file)
        (let ((generated-autoload-file ox-astro-autoloads-file)) ;Emacs 28.x and older
          (update-directory-autoloads ox-astro-site-git-root)))
      (load-file ox-astro-autoloads-file)

      ;; Load emacs packages and activate them.
      ;; Don't delete this line.
      (package-initialize)
      ;; `package-initialize' call is required before any of the below
      ;; can happen.

      (add-to-list 'load-path (concat ox-astro-site-git-root "doc/")) ;For ox-astro-export-gh-doc.el
      (add-to-list 'load-path ox-astro-site-git-root) ;For ox-astro.el, ox-blackfriday.el, etc.

      (defvar ox-astro-missing-packages '()
        "List populated at each startup that contains the list of packages that need
to be installed.")

      (dolist (p ox-astro-packages)
        ;; (message "Is %S installed? %s" p (package-installed-p p))
        (unless (package-installed-p p)
          (add-to-list 'ox-astro-missing-packages p :append)))

      (when ox-astro-missing-packages
        (message "Emacs is now refreshing its package database...")
        (package-refresh-contents)
        ;; Install the missing packages
        (dolist (p ox-astro-missing-packages)
          (message "Installing `%s' .." p)
          (package-install p))
        (setq ox-astro-missing-packages '())))
  (error "The environment variable OX_HUGO_TMP_DIR needs to be set"))

(require 'oc-csl nil :noerror)          ;Auto-register csl processor
;; org-ref is needed only for the citation-related golden tests; do not
;; hard-fail the whole test suite when it is missing (e.g. offline).
(require 'org-ref nil :noerror)

(require 'ox-astro)
(defun org-astro-export-all-wim-to-md ()
  (org-astro-export-wim-to-md :all-subtrees nil nil :noerror))

(require 'ox-astro-export-gh-doc)        ;For `ox-astro-export-gh-doc'

;; Allow setting few vars in Local Variables in the test files.
(put 'org-astro-auto-set-lastmod 'safe-local-variable 'booleanp)
(put 'org-astro-suppress-lastmod-period 'safe-local-variable 'floatp)
(put 'org-cite-csl-styles-dir 'safe-local-variable 'stringp)

(with-eval-after-load 'org
  ;; Allow multiple line Org emphasis markup
  ;; http://emacs.stackexchange.com/a/13828/115
  (setcar (nthcdr 4 org-emphasis-regexp-components) 20) ;Up to 20 lines, default is just 1
  ;; Below is needed to apply the modified `org-emphasis-regexp-components'
  ;; settings from above.
  (org-set-emph-re 'org-emphasis-regexp-components org-emphasis-regexp-components)

  ;; Prevent prompts like:
  ;;   Non-existent agenda file
  (defun org-check-agenda-file (file))

  (let (ob-lang-alist)
    (add-to-list 'ob-lang-alist '(emacs-lisp . t))
    (add-to-list 'ob-lang-alist '(org . t))
    (org-babel-do-load-languages 'org-babel-load-languages ob-lang-alist))

  (with-eval-after-load 'ob-core
    (defun ox-astro-org-confirm-babel-evaluate-fn (lang body)
      "Mark `org' as a safe language for ox-astro tests and docs."
      (let* ((ob-enabled-langs '("org"))
             (ob-enabled-langs-re (regexp-opt ob-enabled-langs 'words))
             (unsafe t)) ;Set the return value `unsafe' to t by default
        (when (string-match-p ob-enabled-langs-re lang)
          (setq unsafe nil))
        unsafe))
    (setq org-confirm-babel-evaluate #'ox-astro-org-confirm-babel-evaluate-fn))

  (with-eval-after-load 'ox
    (setq org-export-headline-levels 4))) ;default is 3

(defun print-emacs-org-versions ()
  "Display Org mode and detailed Emacs version info."
  (let ((emacs-build-info
         (concat (emacs-version) "," " built using commit " emacs-repository-version "\n"
                 "    .. configure options: " system-configuration-options "\n"
                 "    .. features: " system-configuration-features)))
    (message "\n:: Version Check :: Emacs ::")
    (message emacs-build-info)
    (message "\n:: Version Check :: Org Mode ::")
    (message (org-version nil :full))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Settings *only* for tests (applied during "make test")
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(when (string= "1" (getenv "TEST_ENABLED"))
  ;; Set the time-zone to UTC.
  ;; If TZ is unset, Emacs uses system wall clock time, which is a
  ;; platform-dependent default time zone --
  ;; https://www.gnu.org/software/emacs/manual/html_node/elisp/Time-Zone-Rules.html
  (setenv "TZ" "UTC")

  ;; Force the locate to en_US for the tests.
  (set-locale-environment "en_US.UTF-8")
  (setenv "LANGUAGE" "en_US.UTF-8")

  ;; Set all local variables from .dir-locals.el, etc.
  (setq enable-local-variables :all)

  ;; Override the default `org-astro-export-creator-string' so that this
  ;; string is consistent in all ox-astro tests.
  (setq org-astro-export-creator-string "Emacs + Org mode + ox-astro")

  ;; Override the inbuilt `current-time' function so that the "lastmod"
  ;; tests work.
  (defun ox-astro-test/current-time-override (&rest args)
    "Hard-code the 'current time' so that the lastmod tests are reproducible.

`ox-astro' uses `org-current-time' to determine the \"lastmod\" value.

Fake current time: 2100/12/21 00:00:00 (arbitrary)."
    (encode-time 0 0 0 21 12 2100))
  (advice-add 'org-current-time :override #'ox-astro-test/current-time-override)
  ;; (advice-remove 'org-current-time #'ox-astro-test/current-time-override)

  ;; issue # 272
  (load (expand-file-name "test/issue-272-chkbox-items-to-front-matter.el"
                          ox-astro-site-git-root)
        nil :nomessage :nosuffix)

  (with-eval-after-load 'ox
    (add-to-list 'org-export-exclude-tags "dont_export_during_make_test")))
