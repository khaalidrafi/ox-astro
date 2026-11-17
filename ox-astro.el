;;; ox-astro.el --- Hugo Markdown Back-End for Org Export Engine  -*- lexical-binding: t -*-

;; Author: Kaushal Modi <kaushal.modi@gmail.com>
;;         Matt Price <moptop99@gmail.com>
;; Version: 0.12.1
;; Package-Requires: ((emacs "26.3") (tomelr "0.4.3"))
;; Keywords: Org, markdown, docs
;; URL: https://ox-astro.scripter.co

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; ox-astro implements a Markdown back-end for Org exporter.  The
;; exported Markdown is compatible with the Hugo static site generator
;; (https://gohugo.io/).  This exporter also generates the post
;; front-matter in TOML or YAML.

;; To start using this exporter, add the below to your Emacs config:
;;
;;   (with-eval-after-load 'ox
;;     (require 'ox-astro))
;;
;; With the above evaluated, the ox-astro exporter options will be
;; available in the Org Export Dispatcher.  The ox-astro export
;; commands have bindings beginning with "H" (for Hugo).
;;
;; # Blogging Flows
;;
;; 1. one-post-per-subtree flow :: A single Org file can have multiple
;;      Org subtrees which export to individual Hugo posts.  Each of
;;      those subtrees that has the EXPORT_FILE_NAME property set is
;;      called a 'valid Hugo post subtree' in this package and its
;;      documentation.
;;
;; 2. one-post-per-file flow :: A single Org file exports to only
;;      *one* Hugo post.  An Org file intended to be exported by this
;;      flow must not have any 'valid Hugo post subtrees', and instead
;;      must have the #+title property set.
;;
;; # Commonly used export commands
;;
;; ## For both one-post-per-subtree and one-post-per-file flows
;;
;;    - C-c C-e H H  -> Export "What I Mean".
;;                      - If point is in a 'valid Hugo post subtree',
;;                        export that subtree to a Hugo post in
;;                        Markdown.
;;                      - If the file is intended to be exported as a
;;                        whole (i.e. has the #+title keyword),
;;                        export the whole Org file to a Hugo post in
;;                        Markdown.
;;
;;    - C-c C-e H A  -> Export *all* "What I Mean"
;;                      - If the Org file has one or more 'valid Hugo
;;                        post subtrees', export them to Hugo posts in
;;                        Markdown.
;;                      - If the file is intended to be exported as a
;;                        whole (i.e. no 'valid Hugo post subtrees'
;;                        at all, and has the #+title keyword),
;;                        export the whole Org file to a Hugo post in
;;                        Markdown.
;;
;; ## For only the one-post-per-file flow
;;
;;    - C-c C-e H h  -> Export the Org file to a Hugo post in Markdown.

;; Do M-x customize-group, and select `org-export-astro' to see the
;; available customization options for this package.

;; See this package's website for more instructions and examples:
;;
;;   https://ox-astro.scripter.co

;;; Code:

(require 'tomelr nil :noerror)                       ;For `tomelr-encode'
(require 'ox-md)
(require 'ox-html)


(require 'ffap)                         ;For `ffap-url-regexp'
(require 'ob-core nil :noerror)                      ;For `org-babel-parse-header-arguments'
;; `org-refile.el' is new in Org 9.4
;; https://git.savannah.gnu.org/cgit/emacs/org-mode.git/commit/?id=f636cf91b6cbe322eca56e23283f4614548c9d65
(require 'org-refile nil :noerror)      ;For `org-get-outline-path'

(require 'org)
(require 'org-id)                       ;For `org-id-find'

;; For `org-info-emacs-documents', `org-info-other-documents'
;; org-info.el got renamed to ol-info.el in Org version 9.3.  Remove
;; below if condition after the minimum emacs dependency is raised to
;; emacs 27.x. The Org version shipped with Emacs 26.3 is 9.1.9.
(if (version< (org-version) "9.3")
    (require 'org-info)
  (require 'ol-info))




(defvar ffap-url-regexp)                ;Silence byte-compiler


;; Using the correct function for getting inherited Org tags.
;; Starting Org 9.2, `org-get-tags' returns all the inherited tags
;; instead of returning only the local tags i.e. only the current
;; heading tags.
;; https://git.savannah.gnu.org/cgit/emacs/org-mode.git/commit/?id=fbe56f89f75a8979e0ba48001a822518df2c66fe

;; For Org <= 9.1, `org-get-tags' returned a list of tags *only* at
;; the current heading, while `org-get-tags-at' returned inherited
;; tags too.
(with-no-warnings
  (if (fboundp #'org--get-local-tags)   ;If using Org 9.2+
      (defalias 'org-astro--get-tags 'org-get-tags)
    (defalias 'org-astro--get-tags 'org-get-tags-at)))

;; `org-back-to-heading-or-point-min' was introduced in Org 9.5 in
;; https://git.savannah.gnu.org/cgit/emacs/org-mode.git/commit/?id=1bdff9f73dc1e7ff625a90e3e61350bdea99f29c.
;; If a user is using a slightly older version of Org (like 9.3),
;; define it.
(unless (fboundp #'org-back-to-heading-or-point-min)
  (defun org-back-to-heading-or-point-min (&optional invisible-ok)
    "Go back to heading or first point in buffer.
If point is before first heading go to first point in buffer
instead of back to heading."
    (if (org-before-first-heading-p)
        (goto-char (point-min))
      (org-back-to-heading invisible-ok))))

(defvar org-astro--subtree-coord nil
  "Variable to store the current valid Hugo subtree coordinates.
It holds the value returned by
`org-astro--get-post-subtree-coordinates'.")

(defvar org-astro--subtree-count 0
  "Variable to count of number of subtrees getting exported.
This variable is used when exporting all subtrees in a file.")

(defvar org-astro--fm nil
  "Variable to store the current post's front-matter string.")

(defvar org-astro--fm-yaml nil
  "Variable to store the current post's front-matter string in YAML format.")

(defvar org-astro--roam-table nil
  "Roam unit table of the buffer being exported, or nil.

Each element is a (ID SLUG TITLE) list describing one export unit
(a valid post subtree carrying an org-id, or the whole file for
file-based exports).  `org-astro--before-export-function' fills
this in before an export and `org-astro--after-1-export-function'
resets it; `org-astro--roam-table' also computes it on demand when
a caller like the buffer pre-processor needs it earlier.  When
nil, the roam helpers compute it using `org-astro--get-roam-table'.")

(defvar org-astro--internal-list-separator "\n"
  "String used to separate elements in list variables.

Examples are internal variables holding Hugo tags, categories and
keywords.

This variable is for internal use only, and must not be
modified.")

(defvar org-astro--date-time-regexp (concat "\\`[[:digit:]]\\{4\\}-[[:digit:]]\\{2\\}-[[:digit:]]\\{2\\}"
                                           "\\(?:T[[:digit:]]\\{2\\}:[[:digit:]]\\{2\\}:[[:digit:]]\\{2\\}"
                                           "\\(?:Z\\|[+-][[:digit:]]\\{2\\}:[[:digit:]]\\{2\\}\\)*\\)*\\'")
  "Regexp to match the Hugo time stamp strings.

Reference: https://tools.ietf.org/html/rfc3339#section-5.8

Examples:
  2017-07-31
  2017-07-31T17:05:38
  2017-07-31T17:05:38Z
  2017-07-31T17:05:38+04:00
  2017-07-31T17:05:38-04:00.")

(defvar org-astro--trim-pre-marker "<!-- trim-pre -->"
  "Special string to mark where whitespace should be trimmed before an element.")

(defvar org-astro-html5-inline-elements
  '("a" "abbr" "b" "bdo" "br" "button" "cite" "code" "data" "datalist"
    "dfn" "em" "embed" "i" "iframe" "img" "input" "kbd" "label" "map"
    "mark" "meter" "noscript" "object" "output" "picture" "progress"
    "q" "ruby" "s" "samp" "script" "select" "slot" "small" "span"
    "svg" "template" "textarea" "time" "u" "var" "video")
  "HTML 5 inline elements for special block rendering.")

(defvar org-astro--trim-post-marker "<!-- trim-post -->"
  "Special string to mark where whitespace should be trimmed after an element.")

(defvar org-astro--opened-buffers '()
  "List of buffers opened during an export, which will be auto-closed at the end.

An export operation might need to open files for resolving links
pointing to other Org files or temporary buffers for
pre-processing an Org file.  Each buffer opened during an Ox-Hugo
export gets added to this list, and they all are auto-closed at
the end of the export in `org-astro--after-all-exports-function'.")

(defvar org-astro--disable-after-all-exports-hook nil
  "If set, `org-astro--after-all-exports-function' function is not called.

This variable is set internally by `org-astro-export-wim-to-md'
when its ALL-SUBTREES arg is set to a non-nil value.

Setting this to non-nil will lead to slow or incorrect
exports.  This variable is for internal use only, and must not be
modified.")

(defvar org-astro--all-subtrees-export--functions-to-silence
  '(org-babel-exp-src-block ;Don't print "org-babel-exp process .." messages
    write-region            ;Don't print "Wrote .." messages
    table-generate-source   ;Don't print "Generating source..." messages
    )
  "List of functions to silence in Echo and Messages buffers.

These functions are silenced only when ALL-SUBTREES export is done.")

(defconst org-astro--preprocess-buffer t
  "Enable pre-processing of the current Org buffer.

This variable needs to be non-nil for the support of
cross-subtree Org internal links when using the subtree-based
export flow.")

(defvar org-astro--preprocessed-buffer nil
  "Name of the pre-processed buffer.")

(defconst org-astro--preprocessed-buffer-dummy-file-suffix ".pre-processed.org"
  "Dummy suffix (including file extension) for pre-processed buffers.

Dummy Org file paths are created in
`org-astro--get-pre-processed-buffer' by appending this variable
to the link targets out of the current subtree scope.")


;;; Obsoletions

(define-obsolete-variable-alias 'org-astro-default-section-directory 'org-astro-section "Oct 31, 2018")
(define-obsolete-function-alias 'org-astro-headline 'org-astro-heading "Jan 3, 2022")



;;; User-Configurable Variables

(defgroup org-export-astro nil
  "Options for exporting Org mode files to Hugo-compatible Markdown."
  :tag "Org Export Hugo"
  :group 'org-export
  :version "25.2")

(defcustom org-astro-base-dir nil
  "Base directory for Hugo.

Set either this value, or the ASTRO_BASE_DIR global property for
export."
  :group 'org-export-astro
  :type 'directory)
;;;###autoload (put 'org-astro-base-dir 'safe-local-variable 'stringp)

(defcustom org-astro-content-folder "content"
  "Content folder for Hugo.

Set either this value, or the ASTRO_BASE_CONTENT_FOLDER global property for
export."
  :group 'org-export-astro
  :type 'string)
;;;###autoload (put 'org-astro-content-folder 'safe-local-variable 'stringp)

(defcustom org-astro-headline-anchor t
  "Enable anchor for headline"
  :group 'org-export-astro
  :type 'boolean)
;;;###autoload (put 'org-astro-headline-anchor 'safe-local-variable 'booleanp)

(defcustom org-astro-section "posts"
  "Default section for Hugo posts.

This variable is the name of the directory under the \"content/\"
directory where all Hugo posts should go by default."
  :group 'org-export-astro
  :type 'directory)
;;;###autoload (put 'org-astro-section 'safe-local-variable 'stringp)

(defcustom org-astro-front-matter-format "yaml"
  "Front-matter format used in the exported Astro Markdown.
This variable can be set to either \"yaml\" (default; Astro's
preferred format) or \"toml\"."
  :group 'org-export-astro
  :type '(choice
          (const :tag "YAML" "yaml")
          (const :tag "TOML" "toml")))
;;;###autoload (put 'org-astro-front-matter-format 'safe-local-variable 'stringp)

(defcustom org-astro-footer ""
  "String to be appended at the end of each Hugo post.

The string needs to be in a Hugo-compatible Markdown format or HTML."
  :group 'org-export-astro
  :type 'string)
;;;###autoload (put 'org-astro-footer 'safe-local-variable 'stringp)

(defcustom org-astro-preserve-filling t
  "When non-nil, text filling done in Org will be retained in Markdown."
  :group 'org-export-astro
  :type 'boolean)
;;;###autoload (put 'org-astro-preserve-filling 'safe-local-variable 'booleanp)

(defcustom org-astro-delete-trailing-ws t
  "When non-nil, delete trailing whitespace in Markdown output.
Trailing empty lines at the end of the Markdown output are also deleted.

One might want to set this variable to nil if they want to
preserve the trailing whitespaces in Markdown for the purpose of
forcing line-breaks.

The trailing whitespace deleting is skipped if
`org-export-preserve-breaks' is set to non-nil; either via that
variable or via the OPTIONS keyword \"\\n:t\" (See (org) Export
settings).

\(In below Markdown, underscores are used to represent spaces.)

    abc__
    def__

Those trailing whitespaces render to \"<br />\" tags in the Hugo
generated HTML.  But the same result can also be achived by using the
Org Verse block or Blackfriday hardLineBreak extension."
  :group 'org-export-astro
  :type 'boolean)
;;;###autoload (put 'org-astro-delete-trailing-ws 'safe-local-variable 'booleanp)

(defcustom org-astro-use-code-for-kbd nil
  "When non-nil, ~text~ will translate to <kbd>text</kbd>."
  :group 'org-export-astro
  :type 'boolean)
;;;###autoload (put 'org-astro-use-code-for-kbd 'safe-local-variable 'booleanp)

(defcustom org-astro-allow-spaces-in-tags t
  "When non-nil, replace double underscores in Org tags with spaces.

See `org-astro--tag-processing-fn-replace-with-spaces-maybe' for
more information.

This variable affects the Hugo tags and categories (set via Org
tags using the \"@\" prefix)."
  :group 'org-export-astro
  :type 'boolean)
;;;###autoload (put 'org-astro-allow-spaces-in-tags 'safe-local-variable 'booleanp)

(defcustom org-astro-prefer-hyphen-in-tags t
  "When non-nil, replace single underscores in Org tags with hyphens.

See `org-astro--tag-processing-fn-replace-with-hyphens-maybe' for
more information.

This variable affects the Hugo tags and categories (set via Org
tags using the \"@\" prefix)."
  :group 'org-export-astro
  :type 'boolean)
;;;###autoload (put 'org-astro-prefer-hyphen-in-tags 'safe-local-variable 'booleanp)

(defcustom org-astro-tag-processing-functions '(org-astro--tag-processing-fn-replace-with-spaces-maybe
                                               org-astro--tag-processing-fn-replace-with-hyphens-maybe)
  "List of functions that are called in order to process the Org tags.
Each function has to accept two arguments:

Arg 1: TAG-LIST which is a list of Org tags of the type
       \(\"TAG1\" \"TAG2\" ..).
Arg 2: INFO which is a plist holding contextual information.

Each function should then return a list of strings, which would
be processed form of TAG-LIST.

All the functions are called in order, and the output of one
function is fed as the TAG-LIST input of the next called
function.

The `org-astro--tag-processing-fn-replace-with-spaces-maybe'
function skips any processing and returns its input TAG-LIST as
it is if `org-astro-allow-spaces-in-tags' is nil.

The `org-astro--tag-processing-fn-replace-with-hyphens-maybe'
function skips any processing and returns its input TAG-LIST as
it is if `org-astro-prefer-hyphen-in-tags' is nil."
  :group 'org-export-astro
  :type '(repeat (function)))

(defcustom org-astro-auto-set-lastmod nil
  "When non-nil, set the lastmod field in front-matter to current time."
  :group 'org-export-astro
  :type 'boolean)
;;;###autoload (put 'org-astro-auto-set-lastmod 'safe-local-variable 'booleanp)

(defcustom org-astro-suppress-lastmod-period 0.0
  "Suppressing period (in seconds) for adding the lastmod front-matter.

The suppressing period is calculated as a delta between the
\"date\" and auto-calculated \"lastmod\" values.  This value can
be 0.0 or a positive float.

The default value is 0.0 (seconds), which means that the lastmod
parameter will be added to front-matter even if the post is
modified within just 0.1 seconds after the initial creation of
it (when the \"date\" is set).

If the value is 86400.0, the lastmod parameter will not be added
to the front-matter within 24 hours from the initial exporting.

This variable is effective only if auto-setting of the
\"lastmod\" parameter is enabled i.e. if
`org-astro-auto-set-lastmod' or `EXPORT_ASTRO_AUTO_SET_LASTMOD' is
non-nil."
  :group 'org-export-astro
  :type 'float)
;;;###autoload (put 'org-astro-suppress-lastmod-period 'safe-local-variable 'floatp)

(defcustom org-astro-export-with-toc nil
  "When non-nil, Markdown format TOC will be inserted.

The TOC contains headings with levels up
to`org-export-headline-levels'.  When an integer, include levels
up to N in the toc, this may then be different from
`org-export-headline-levels', but it will not be allowed to be
larger than the number of heading levels.  When nil, no table of
contents is made.

This option can also be set with the OPTIONS keyword,
e.g. \"toc:nil\", \"toc:t\" or \"toc:3\"."
  :group 'org-export-astro
  :type '(choice
          (const :tag "No Table of Contents" nil)
          (const :tag "Full Table of Contents" t)
          (integer :tag "TOC to level")))
;;;###autoload (put 'org-astro-export-with-toc 'safe-local-variable (lambda (x) (or (booleanp x) (integerp x))))

(defcustom org-astro-export-with-section-numbers nil
  "Configuration for adding section numbers to headings.

When set to `onlytoc', none of the headings will be numbered in
the exported post body, but TOC generation will use the section
numbers.

When set to an integer N, numbering will only happen for
headings whose relative level is higher or equal to N.

When set to any other non-nil value, numbering will happen for
all the headings.

This option can also be set with the OPTIONS keyword,
e.g. \"num:onlytoc\", \"num:nil\", \"num:t\" or \"num:3\"."
  :group 'org-export-astro
  :type '(choice
          (const :tag "Don't number only in body" onlytoc)
          (const :tag "Don't number any heading" nil)
          (const :tag "Number all headings" t)
          (integer :tag "Number to level")))
;;;###autoload (put 'org-astro-export-with-section-numbers 'safe-local-variable (lambda (x) (or (booleanp x) (equal 'onlytoc x) (integerp x))))

(defcustom org-astro-default-static-subdirectory-for-externals "ox-astro"
  "Default sub-directory in Hugo static directory for external files.
If the source path for external files does not contain
\"static\", `ox-astro` cannot know what directory structure to
create inside the Hugo static directory.  So all such files are
copied to this sub-directory inside the Hugo static directory."
  :group 'org-export-astro
  :type 'string)
;;;###autoload (put 'org-astro-default-static-subdirectory-for-externals 'safe-local-variable 'stringp)

(defcustom org-astro-external-file-extensions-allowed-for-copying
  '("jpg" "jpeg" "tiff" "png" "svg" "gif" "bmp"
    "mp4"
    "pdf" "odt"
    "doc" "ppt" "xls"
    "docx" "pptx" "xlsx")
  "List of external file extensions allowed for copying to Hugo static dir.
If an Org link references a file with one of these extensions,
and if that file is not in the Hugo static directory, that file
is copied over to the static directory.

The auto-copying behavior is disabled if this variable is set to
nil."
  :group 'org-export-astro
  :type '(repeat string))

(defcustom org-astro-export-creator-string
  (format "Emacs %s (Org mode%s + ox-astro)"
          emacs-version
          (if (fboundp 'org-version)
              (concat " " (org-version))
            ""))
  "Information about the creator of the document.
This option can also be set on with the CREATOR keyword."
  :group 'org-export-astro
  :type '(string :tag "Creator string"))
;;;###autoload (put 'org-astro-export-creator-string 'safe-local-variable 'stringp)

(defcustom org-astro-date-format "%Y-%m-%dT%T%z"
  "Date format used for exporting date in front-matter.

Front-matter date parameters: `date', `publishDate',
`expiryDate', `lastmod'.

Note that the date format must match the date specification from
RFC3339.  See `org-astro--date-time-regexp' for reference and
examples of compatible date strings.

Examples of RFC3339-compatible values for this variable:

  - %Y-%m-%dT%T%z (default) -> 2017-07-31T17:05:38-04:00
  - %Y-%m-%dT%T             -> 2017-07-31T17:05:38
  - %Y-%m-%d                -> 2017-07-31

Note that \"%Y-%m-%dT%T%z\" actually produces a date string like
\"2017-07-31T17:05:38-0400\"; notice the missing colon in the
time-zone portion.

A colon is needed to separate the hours and minutes in the
time-zone as per RFC3339.  This gets fixed in the
`org-astro--format-date' function, so that \"%Y-%m-%dT%T%z\" now
results in a date string like \"2017-07-31T17:05:38-04:00\".

See `format-time-string' to learn about the date format string
expression."
  :group 'org-export-astro
  :type 'string)
;;;###autoload (put 'org-astro-date-format 'safe-local-variable 'stringp)

(defcustom org-astro-link-desc-insert-type nil
  "Insert the element type in link descriptions for numbered elements.

String representing the type is inserted for these Org elements
if they are numbered (i.e. both \"#+name\" and \"#+caption\" are
specified for them):

- src-block : \"Code Snippet\"
- table: \"Table\"
- figure: \"Figure\"."
  :group 'org-export-astro
  :type 'boolean)
;;;###autoload (put 'org-astro-link-desc-insert-type 'safe-local-variable 'booleanp)

(defcustom org-astro-container-element ""
  "HTML element to use for wrapping top level sections.
Can be set with the in-buffer HTML_CONTAINER property.

When set to \"\", the top level sections are not wrapped in any
HTML element."
  :group 'org-export-astro
  :type 'string)
;;;###autoload (put 'org-astro-container-element 'safe-local-variable 'stringp)

(defcustom org-astro-special-block-type-properties '(("audio" . (:raw t))
                                                    ("katex" . (:raw t))
                                                    ("mark" . (:trim-pre t :trim-post t))
                                                    ("tikzjax" . (:raw t))
                                                    ("video" . (:raw t)))
  "Alist for storing default properties for special block types.

Each element of the alist is of the form (TYPE . PLIST) where
TYPE is a string holding the special block's type and PLIST is a
property list for that TYPE.

The TYPE string could be any special block type like an HTML
inline or block tag, or name of a Hugo shortcode, or any random
string.

Properties recognized in the PLIST:

- :raw :: When set to t, the contents of the special block as
          exported raw i.e. as typed in the Org buffer.

- :trim-pre :: When set to t, the whitespace before the special
               block is removed.

- :trim-pre :: When set to t, the whitespace after the special
               block is removed.

For the special block types not specified in this variable, the
default behavior is same as if (:raw nil :trim-pre nil :trim-post
nil) plist were associated with them."
  :group 'org-export-astro
  :type '(alist :key-type string :value-type (plist :key-type symbol :value-type boolean)))

(defcustom org-astro-anchor-functions '(org-astro-get-page-or-bundle-name
                                       org-astro-get-custom-id
                                       org-astro-get-heading-slug
                                       org-astro-get-md5)
  "A list of functions for deriving the anchor of current Org heading.

The functions will be run in the order added to this variable
until the first one returns a non-nil value.  So the functions in
this list are order-sensitive.

For example, if `org-astro-get-page-or-bundle-name' is the first
element in this list, the heading's `:EXPORT_FILE_NAME' property
will have the highest precedence in determining the heading's
anchor string.

This variable is used in the `org-astro--get-anchor' internal
function.

Functions added to this list should have 2 arguments (which could
even be declared as optional):

1. ELEMENT : Org element
2. INFO    : General plist used as a communication channel

Some of the inbuilt functions that can be added to this list:
- `org-astro-get-page-or-bundle-name'
- `org-astro-get-custom-id'
- `org-astro-get-heading-slug'
- `org-astro-get-md5'
- `org-astro-get-id'"
  :group 'org-export-astro
  :type '(repeat function))

(defcustom org-astro-citations-plist '(:bibliography-section-heading "References")
  "Property list for storing default properties for citation exports.

Properties recognized in the PLIST:

- :bibliography-section-heading :: Heading to insert before the bibliography
                                   section.

Auto-detection of bibliography section requires installing the
`citations' package from Melpa and adding `#+cite_export: csl' at
the top of the Org file.

If `:bibliography-section-heading' set to an empty string,
bibliography heading auto-injection is not done."
  :group 'org-export-astro
  :type '(plist :key-type symbol :value-type string))

(defcustom org-astro-info-gnu-software '("3dldf" "8sync"
                                        "a2ps" "acct" "acm" "adns" "alive" "anubis" "apl"
                                        "archimedes" "aris" "artanis" "aspell" "auctex" "autoconf" "autoconf-archive"
                                        "autogen" "automake" "avl"
                                        "ballandpaddle" "barcode" "bash" "bayonne" "bazaar" "bc" "behistun"
                                        "bfd" "binutils" "bison" "bool" "bpel2owfn"
                                        "c-graph" "ccaudio" "ccd2cue" "ccide" "ccrtp" "ccscript" "cflow"
                                        "cgicc" "chess" "cim" "classpath" "classpathx" "clisp" "combine"
                                        "commoncpp" "complexity" "config" "consensus" "coreutils" "cpio" "cppi"
                                        "cssc" "cursynth"
                                        "dap" "datamash" "dc" "ddd" "ddrescue" "dejagnu" "denemo"
                                        "dia" "dico" "diction" "diffutils" "direvent" "djgpp" "dominion"
                                        "dr-geo"
                                        "easejs" "ed" "edma" "electric" "emacs" "emacs-muse" "emms"
                                        "enscript" "epsilon"
                                        "fdisk" "ferret" "findutils" "fisicalab" "foliot" "fontopia" "fontutils"
                                        "freedink" "freefont" "freeipmi" "freetalk" "fribidi"
                                        "g-golf" "gama" "garpd" "gawk" "gcal" "gcc" "gcide"
                                        "gcl" "gcompris" "gdb" "gdbm" "gengen" "gengetopt" "gettext"
                                        "gforth" "ggradebook" "ghostscript" "gift" "gimp" "glean" "global"
                                        "glpk" "glue" "gmediaserver" "gmp" "gnash" "gnat" "gnats"
                                        "gnatsweb" "gnowsys" "gnu-c-manual" "gnu-crypto" "gnu-pw-mgr" "gnuae" "gnuastro"
                                        "gnubatch" "gnubg" "gnubiff" "gnubik" "gnucap" "gnucash" "gnucobol"
                                        "gnucomm" "gnudos" "gnufm" "gnugo" "gnuit" "gnujdoc" "gnujump"
                                        "gnukart" "gnulib" "gnumach" "gnumed" "gnumeric" "gnump3d" "gnun"
                                        "gnunet" "gnupg" "gnupod" "gnuprologjava" "gnuradio" "gnurobots" "gnuschool"
                                        "gnushogi" "gnusound" "gnuspeech" "gnuspool" "gnustandards" "gnustep" "gnutls"
                                        "gnutrition" "gnuzilla" "goptical" "gorm" "gpaint" "gperf" "gprolog"
                                        "grabcomics" "greg" "grep" "gretl" "groff" "grub" "gsasl"
                                        "gsegrafix" "gsl" "gslip" "gsrc" "gss" "gtick" "gtypist"
                                        "guile" "guile-cv" "guile-dbi" "guile-gnome" "guile-ncurses" "guile-opengl"
                                        "guile-rpc" "guile-sdl" "guix" "gurgle" "gv" "gvpe" "gwl" "gxmessage"
                                        "gzip"
                                        "halifax" "health" "hello" "help2man" "hp2xx" "html-info" "httptunnel"
                                        "hurd" "hyperbole"
                                        "icecat" "idutils" "ignuit" "indent" "inetutils" "inklingreader" "intlfonts"
                                        "jacal" "jami" "java-getopt" "jel" "jitter" "jtw" "jwhois"
                                        "kawa" "kopi"
                                        "leg" "less" "libc" "libcdio" "libdbh" "liberty-eiffel" "libextractor"
                                        "libffcall" "libgcrypt" "libiconv" "libidn" "libjit" "libmatheval"
                                        "libmicrohttpd" "libredwg" "librejs" "libsigsegv" "libtasn1" "libtool"
                                        "libunistring" "libxmi" "lightning" "lilypond" "lims" "linux-libre" "liquidwar6"
                                        "lispintro" "lrzsz" "lsh"
                                        "m4" "macchanger" "mailman" "mailutils" "make" "marst" "maverik"
                                        "mc" "mcron" "mcsim" "mdk" "mediagoblin" "melting" "mempool"
                                        "mes" "metaexchange" "metahtml" "metalogic-inference" "mifluz" "mig" "miscfiles"
                                        "mit-scheme" "moe" "motti" "mpc" "mpfr" "mpria" "mtools"
                                        "nana" "nano" "nano-archimedes" "ncurses" "nettle" "network"
                                        "ocrad" "octave" "oleo" "oo-browser" "orgadoc" "osip"
                                        "panorama" "parallel" "parted" "pascal" "patch" "paxutils" "pcb"
                                        "pem" "pexec" "pies" "pipo" "plotutils" "poke" "polyxmass"
                                        "powerguru" "proxyknife" "pspp" "psychosynth" "pth" "pythonwebkit"
                                        "qexo" "quickthreads"
                                        "r" "radius" "rcs" "readline" "recutils" "reftex" "remotecontrol"
                                        "rottlog" "rpge" "rush"
                                        "sather" "scm" "screen" "sed" "serveez" "sharutils" "shepherd"
                                        "shishi" "shmm" "shtool" "sipwitch" "slib" "smalltalk" "social"
                                        "solfege" "spacechart" "spell" "sqltutor" "src-highlite" "ssw" "stalkerfs"
                                        "stow" "stump" "superopt" "swbis" "sysutils"
                                        "taler" "talkfilters" "tar" "termcap" "termutils" "teseq" "teximpatient"
                                        "texinfo" "texmacs" "time" "tramp" "trans-coord" "trueprint"
                                        "unifont" "units" "unrtf" "userv" "uucp"
                                        "vc-dwim" "vcdimager" "vera" "vmgen"
                                        "wb" "wdiff" "websocket4j" "webstump" "wget" "which" "womb"
                                        "xaos" "xboard" "xlogmaster" "xmlat" "xnee" "xorriso"
                                        "zile")
  "List of GNU software for Info manual links.
The software list is taken from https://www.gnu.org/software/."
  :group 'org-export-astro
  :type '(repeat string))



;;; --- Absorbed helpers from ox-blackfriday.el (simplified for Astro) ---

;;;; Element type display strings (for captions/ordinals in links)
(defvar org-astro--org-element-string '((src-block . "Code Snippet")
                                        (table . "Table")
                                        (figure . "Figure"))
  "Alist mapping Org element types to display name strings.
Used for generating captions like \"Figure 1:\" in links.")

;;;; Translate element type names
(defun org-astro--translate (type info &optional str)
  "Return translated string for element TYPE to the current language.
TYPE is the Org element type symbol, or nil to translate STR directly.
INFO is a plist holding contextual information."
  (let ((elem-str (cdr (assoc type org-astro--org-element-string))))
    (if elem-str
        (cond
         ((equal 'src-block type)
          (let ((listing-tr (org-html--translate "Listing" info)))
            (if (string= "Listing" listing-tr)
                (org-html--translate elem-str info)
              listing-tr)))
         (t
          (org-html--translate elem-str info)))
      (if (stringp str)
          (org-html--translate str info)
        ""))))

;;;; Reference prefixes for named elements
(defun org-astro--get-ref-prefix (symbol)
  "Return the anchor prefix string for SYMBOL (an Org element type).
Returns nil if SYMBOL's prefix is not defined."
  (let ((prefix-alist '((figure . "figure--")
                        (radio . "org-radio--")
                        (src-block . "code-snippet--")
                        (table . "table--")
                        (target . "org-target--"))))
    (cdr (assoc symbol prefix-alist))))

;;;; Valid HTML anchor name
(defun org-astro--valid-html-anchor-name (str)
  "Turn STR into a valid HTML anchor name by replacing invalid chars."
  (or (and (stringp str)
           (string-trim
            (replace-regexp-in-string "[^a-zA-Z0-9_-.]" "-" str)
            "-"))
      ""))

;;;; Reference from #+name
(defun org-astro--get-reference (elem)
  "Return an anchor reference for ELEM using its #+name property.
Removes common prefixes (code__, tab__, fig__) and normalizes
underscores/hyphens.  Returns nil if #+name is not set."
  (let ((name (org-element-property :name elem)))
    (when name
      (let* ((elem-type (org-element-type elem))
             (prefix (or (org-astro--get-ref-prefix elem-type)
                         (format "org-%s--" (symbol-name elem-type))))
             (name1 (replace-regexp-in-string
                     "[_/]" "-"
                     (replace-regexp-in-string
                      "\\`\\(code\\|tab\\|table\\|img\\|fig\\|figure\\|\\)__" "" name))))
        (format "%s%s" prefix name1)))))

;;;; Target anchor
(defun org-astro--get-target-anchor (target)
  "Get HTML anchor string for a TARGET element.
Anchors with names starting with \".\" are verbatim (no prefix)."
  (let ((target-name (org-element-property :value target))
        (verbatim-prefix ".")
        (prefix ""))
    (unless (string-prefix-p verbatim-prefix target-name)
      (setq prefix (org-astro--get-ref-prefix 'target)))
    (setq target-name (org-astro--valid-html-anchor-name target-name))
    (format "%s%s" prefix target-name)))

;;;; Link target span
(defun org-astro--link-target (attr &optional desc)
  "Return an HTML <span> tag with ATTR attributes and optional DESC content."
  (format "<span%s>%s</span>" (or attr "") (or desc "")))

;;;; HTML attribute string from plist
(defun org-astro--make-attribute-string (attributes)
  "Return ATTRIBUTES plist as a string of HTML attributes.
Nil-valued attributes are omitted.  Non-string values are ignored."
  (let (result)
    (dolist (item attributes)
      (cond
       ((null item) (pop result))   ;nil value removes previous key
       ((symbolp item) (push (substring (symbol-name item) 1) result))
       (t (when (car result)
            (let ((key (car result))
                  (value (replace-regexp-in-string
                          "\"" "&quot;" (org-html-encode-plain-text item))))
              (setcar result (format "%s=\"%s\"" key value)))))))
    (mapconcat #'identity (nreverse result) " ")))

;;;; CSS property string from plist
(defun org-astro--make-css-property-string (props)
  "Return CSS properties from PROPS plist as a string."
  (let (ret)
    (dolist (item props (mapconcat #'identity (nreverse ret) " "))
      (cond ((null item) (pop ret))
            ((symbolp item) (push (substring (symbol-name item) 1) ret))
            (t (let ((key (car ret))
                     (value (replace-regexp-in-string
                             "\"" "&quot;" (org-html-encode-plain-text item))))
                 (setcar ret (format "%s: %s; " key value))))))))

;;;; Inline style from #+attr_css
(defun org-astro--get-style-str (elem)
  "Return a <style> tag for ELEM if #+attr_html has a class and #+attr_css has props."
  (let* ((html-attr (org-export-read-attribute :attr_html elem))
         (class (plist-get html-attr :class))
         (first-class (when (stringp class) (car (split-string class)))))
    (if first-class
        (let* ((css-props (org-export-read-attribute :attr_css elem))
               (css-str (org-astro--make-css-property-string css-props)))
          (if (org-string-nw-p css-str)
              (format "<style>.%s { %s }</style>\n\n" first-class css-str)
            ""))
      "")))

;;;; Div-wrap with HTML attributes
(defun org-astro--div-wrap-maybe (elem contents info)
  "Wrap CONTENTS in a <div> with HTML attributes from #+attr_html on ELEM.
Returns CONTENTS unchanged if no attributes are specified.
INFO is a plist used as a communication channel."
  (let* ((elem-type (org-element-type elem))
         (html-attr (let ((attr1 (org-export-read-attribute :attr_html elem)))
                      ;; Remove image-specific attributes from paragraph attrs.
                      (when (equal elem-type 'paragraph)
                        (plist-put attr1 :target nil)
                        (plist-put attr1 :rel nil)
                        (plist-put attr1 :src nil)
                        (plist-put attr1 :alt nil)
                        (plist-put attr1 :height nil)
                        (plist-put attr1 :width nil))
                      attr1))
         (html-attr-str (org-astro--make-attribute-string html-attr))
         (ret contents))
    (when (org-string-nw-p html-attr-str)
      (setq ret (concat (org-astro--get-style-str elem)
                        (when contents
                          (format "<div %s>%s\n</div>"
                                  html-attr-str contents)))))
    ret))

;;;; GFM footnote reference [^fn:N]
(defun org-astro-footnote-reference (footnote-reference _contents info)
  "Transcode a FOOTNOTE-REFERENCE into GFM format [^fn:N]."
  (concat
   (let ((prev (org-export-get-previous-element footnote-reference info)))
     (and (eq (org-element-type prev) 'footnote-reference)
          (plist-get info :html-footnote-separator)))
   (format "[^fn:%d]" (org-export-get-footnote-number footnote-reference info))))

;;;; GFM footnote section
(defun org-astro-footnote-section (info)
  "Format the footnote section as GFM-style [^fn:N]: definitions.
Multi-line footnote content is indented by 4 spaces (remark-gfm compatible)."
  (let ((fn-alist (org-export-collect-footnote-definitions info))
        fn-alist-stripped)
    (let ((n 1) def)
      (dolist (fn fn-alist)
        (setq def (org-trim (org-export-data (nth 2 fn) info)))
        ;; Indent continuation lines by 4 spaces for multi-line footnotes.
        (setq def (replace-regexp-in-string "\n" "\n    " def))
        (push (cons n def) fn-alist-stripped)
        (setq n (1+ n))))
    (when fn-alist-stripped
      (mapconcat (lambda (fn)
                   (format "[^fn:%d]: %s" (car fn) (cdr fn)))
                 (nreverse fn-alist-stripped)
                 "\n"))))

;;;; State variables for fenced code blocks
(defvar org-astro--code-block-num-backticks-default 3
  "Default number of backticks for code fences.")

(defvar org-astro--code-block-num-backticks org-astro--code-block-num-backticks-default
  "Current number of backticks for code fences.  Incremented inside nested blocks.")

;;;; Syntax highlighting language mapping
(defcustom org-astro-syntax-highlighting-langs
  '(("ipython" . "python")
    ("jupyter-python" . "python")
    ("conf-toml" . "toml")
    ("conf-space" . "cfg")
    ("conf" . "cfg"))
  "Alist mapping src block languages to their syntax highlighting equivalents."
  :group 'org-export-astro
  :type '(repeat (cons (string) (string))))

;;;; Fenced src block (core code fence emitter)
(defun org-astro--fenced-src-block (src-block _contents info)
  "Transcode SRC-BLOCK into a fenced Markdown code block.
Reads :md-code and :md-code-attr from INFO if set (used by the
parent transcoder), otherwise formats the block directly."
  (let* ((lang (org-element-property :language src-block))
         (lang (or (cdr (assoc lang org-astro-syntax-highlighting-langs)) lang))
         (code (or (plist-get info :md-code)
                   (org-export-format-code-default src-block info)))
         (code-attr (if (plist-get info :md-code-attr)
                        (format " { %s }" (plist-get info :md-code-attr))
                      ""))
         (num-backticks-in-code
          (when (string-match "^[[:blank:]]*\\(`\\{3,\\}\\)" code)
            (length (match-string-no-properties 1 code))))
         backticks)
    ;; Ensure the fence backticks are longer than any run in the code.
    (when (and (numberp num-backticks-in-code)
               (<= org-astro--code-block-num-backticks num-backticks-in-code))
      (setq org-astro--code-block-num-backticks (1+ num-backticks-in-code)))
    (setq backticks (make-string org-astro--code-block-num-backticks ?`))
    (prog1
        (format "%s%s%s\n%s%s" backticks lang code-attr code backticks)
      ;; Reset the plist cache.
      (plist-put info :md-code nil)
      (plist-put info :md-code-attr nil))))

;;;; Fenced example block
(defun org-astro--fenced-example-block (example-block _contents info)
  "Transcode EXAMPLE-BLOCK into a fenced Markdown code block (no language)."
  (let* ((code (or (plist-get info :md-code)
                   (org-export-format-code-default example-block info)))
         (code-attr (if (plist-get info :md-code-attr)
                        (format " { %s }" (plist-get info :md-code-attr))
                      ""))
         (num-backticks (when (string-match "^[[:blank:]]*\\(`\\{3,\\}\\)" code)
                          (length (match-string-no-properties 1 code))))
         (backticks (make-string
                     (if (and num-backticks (<= org-astro--code-block-num-backticks num-backticks))
                         (1+ num-backticks)
                       org-astro--code-block-num-backticks)
                     ?`)))
    (prog1
        (format "%stext%s\n%s%s" backticks code-attr code backticks)
      (plist-put info :md-code nil)
      (plist-put info :md-code-attr nil))))

;;;; Strike-through
(defun org-astro-strike-through (_strike-through contents _info)
  "Transcode strike-through text to GFM ~~text~~."
  (format "~~%s~~" contents))

;;;; Radio target
(defun org-astro-radio-target (radio-target text _info)
  "Transcode a RADIO-TARGET into an HTML span with matching anchor."
  (let* ((prefix (org-astro--get-ref-prefix 'radio))
         (ref (format "%s%s" prefix
                      (org-astro--valid-html-anchor-name
                       (org-element-property :value radio-target))))
         (attr (format " class=\"%s\" id=\"%s\""
                       (string-remove-suffix "--" prefix) ref)))
    (org-astro--link-target attr text)))

;;;; Target
(defun org-astro-target (target _contents _info)
  "Transcode a TARGET into an HTML span with anchor id."
  (let* ((class (string-remove-suffix "--" (org-astro--get-ref-prefix 'target)))
         (anchor (org-astro--get-target-anchor target))
         (attr (format " class=\"%s\" id=\"%s\"" class anchor)))
    (org-astro--link-target attr)))

;;;; Pipe table support

;; State variables for table rendering.
(defvar org-astro--hrule-inserted nil
  "Track whether the horizontal rule has been inserted in the current table.")

(defvar org-astro-table-left-border "| " "Left border string for pipe tables.")
(defvar org-astro-table-separator " | " "Column separator for pipe tables.")
(defvar org-astro-table-right-border " |" "Right border string for pipe tables.")

;; Column width cache (reset per table).
(defvar org-astro-width-cookies nil "Hash table caching column widths.")
(defvar org-astro-width-cookies-table nil "Table for which widths are cached.")

(defun org-astro-table-col-width (table column info)
  "Return the width of TABLE at COLUMN using INFO.
Caches results in `org-astro-width-cookies'."
  (let ((cookie (when (hash-table-p org-astro-width-cookies)
                  (gethash column org-astro-width-cookies))))
    (if (and (eq table org-astro-width-cookies-table) cookie)
        cookie
      (unless (and (eq table org-astro-width-cookies-table)
                   (hash-table-p org-astro-width-cookies))
        (setq org-astro-width-cookies (make-hash-table))
        (setq org-astro-width-cookies-table table))
      (let ((max-width 0)
            (specialp (org-export-table-has-special-column-p table)))
        (org-element-map table 'table-row
          (lambda (row)
            (setq max-width
                  (max (length
                        (org-export-data
                         (org-element-contents
                          (elt (if specialp
                                   (car (org-element-contents row))
                                 (org-element-contents row))
                               column))
                         info))
                       max-width)))
          info)
        (puthash column max-width org-astro-width-cookies)))))

(defun org-astro-table-cell-alignment (table-cell info)
  "Save and return the alignment of TABLE-CELL.
Results are cached in INFO under :table-cell-alignment-cache."
  (let* ((table (org-export-get-parent-table table-cell))
         (row (org-export-get-parent table-cell))
         (column (cdr (org-export-table-cell-address table-cell info)))
         (alignment-cache (or (plist-get info :table-cell-alignment-cache)
                              (let ((ht (make-hash-table :test #'eq)))
                                (plist-put info :table-cell-alignment-cache ht)
                                ht)))
         (align-vector (or (gethash table alignment-cache)
                           (let* ((dims (org-export-table-dimensions table info))
                                  (v (make-vector (cdr dims) nil)))
                             (puthash table v alignment-cache)
                             v)))
         (align (org-export-table-cell-alignment table-cell info)))
    (aset align-vector column align)
    align))

(defun org-astro-table-cell (table-cell contents info)
  "Transcode TABLE-CELL into a pipe table cell."
  (let* ((table (org-export-get-parent-table table-cell))
         (column (cdr (org-export-table-cell-address table-cell info)))
         (width (org-astro-table-col-width table column info))
         (left-border (if (org-export-table-cell-starts-colgroup-p table-cell info) "| " " "))
         (right-border " |")
         (data (or contents ""))
         (cell (concat left-border
                       data
                       (make-string (max 0 (- width (string-width data))) ?\s)
                       right-border)))
    ;; Save alignment info for the column.
    (org-astro-table-cell-alignment table-cell info)
    ;; Ensure minimum cell width of 3 chars.
    (when (< (length cell) 4)
      (setq cell (concat (make-string (- 4 (length cell)) ? ) cell)))
    cell))

(defun org-astro-table-row (table-row contents info)
  "Transcode TABLE-ROW into a pipe table row."
  (let* ((table (org-export-get-parent-table table-row))
         (row-num (cl-position table-row
                               (org-element-map table 'table-row #'identity info)))
         (row contents))
    ;; Reset state at first row.
    (when (eq 0 row-num)
      (setq org-astro--hrule-inserted nil))
    ;; Rule rows: only valid as second row.
    (when (and row
               (eq 'rule (org-element-property :type table-row))
               (eq 1 row-num))
      (let ((cols (cdr (org-export-table-dimensions table info))))
        (setq row (concat org-astro-table-left-border
                          (mapconcat
                           (lambda (col)
                             (make-string (max 3 (+ 1 (org-astro-table-col-width table col info))) ?-))
                           (number-sequence 0 (- cols 1))
                           org-astro-table-separator)
                          org-astro-table-right-border))))
    ;; Auto-insert a rule after the first row if no explicit rule exists.
    (when (and (stringp row)
               (null org-astro--hrule-inserted))
      (let ((rule (replace-regexp-in-string "[^|]" "-" row))
            (pos 0)
            (new-rule "")
            matches)
        (while (string-match "|-+" rule pos)
          (push (match-string 0 rule) matches)
          (setq pos (match-end 0)))
        (setq matches (nreverse matches))
        (let* ((alignment-cache (plist-get info :table-cell-alignment-cache))
               (align-vector (gethash table alignment-cache))
               (col 0))
          (dolist (match matches)
            (let ((align (when align-vector (aref align-vector col))))
              (when (member align '(left center))
                (setq match (replace-regexp-in-string "\\`|-" "|:" match)))
              (when (member align '(right center))
                (setq match (replace-regexp-in-string "-\\'" ":" match))))
            (setq new-rule (concat new-rule match))
            (setq col (1+ col))))
        (setq new-rule (concat new-rule "|"))
        (setq row (concat row "\n" new-rule))
        (setq org-astro--hrule-inserted t)))
    row))

(defun org-astro-table (table contents info)
  "Transcode TABLE into a pipe table with header row and alignment."
  (let* ((caption (org-export-get-caption table))
         (cap-ref (org-astro--get-reference table))
         (table-pre (if cap-ref
                        (format "<a id=\"%s\"></a>\n" cap-ref)
                      ""))
         (caption-html (if caption
                           (let* ((table-num (org-export-get-ordinal
                                              table info nil #'org-html--has-caption-p))
                                  (cap-prefix (org-astro--translate 'table info))
                                  (cap-str (org-export-data caption info)))
                             (format "<div class=\"table-caption\">\n  <span class=\"table-number\">%s:</span>\n  %s\n</div>\n"
                                     (if cap-ref
                                         (format "<a href=\"#%s\">%s %s</a>" cap-ref cap-prefix table-num)
                                       (format "%s %s" cap-prefix table-num))
                                     cap-str))
                         ""))
         (tbl (replace-regexp-in-string "\\`[ \t]*<br/>" "" contents))
         (no-header (org-export-table-has-header-p table info))
         (blank-line (if (or (org-string-nw-p table-pre)
                             (org-string-nw-p caption-html))
                         "\n" "")))
    ;; Handle single-row tables: add empty header.
    (when no-header
      (string-match "\\`\\(.*\\)\n\\(.*\\)\n\\'" tbl)
      (let* ((row-1 (match-string-no-properties 1 tbl))
             (hrule (match-string-no-properties 2 tbl))
             (dummy-header (replace-regexp-in-string "[-:]" " " hrule)))
        (setq tbl (concat dummy-header "\n" hrule "\n" row-1))))
    (concat table-pre caption-html blank-line tbl)))

;;; --- End of absorbed helpers ---

;;; Define Back-End

(org-export-define-derived-backend 'astro 'md ;astro < md < html
  :menu-entry
  '(?H "Export to Astro-compatible Markdown"
       ((?H "Subtree or File to Md file            "
            (lambda (a _s v _b)
              (org-astro-export-wim-to-md nil a v)))
        (?h "File to Md file"
            (lambda (a s v _b)
              (org-astro-export-to-md a s v)))
        (?O "Subtree or File to Md file and open   "
            (lambda (a _s v _b)
              (if a
                  (org-astro-export-wim-to-md nil :async v)
                (org-open-file (org-astro-export-wim-to-md nil nil v)))))
        (?o "File to Md file and open"
            (lambda (a s v _b)
              (if a
                  (org-astro-export-to-md :async s v)
                (org-open-file (org-astro-export-to-md nil s v)))))
        (?A "All subtrees (or File) to Md file(s)  "
            (lambda (a _s v _b)
              (org-astro-export-wim-to-md :all-subtrees a v)))
        (?t "File to a temporary Md buffer"
            (lambda (a s v _b)
              (org-astro-export-as-md a s v)))))
;;;; translate-alist
  :translate-alist '((code . org-astro-kbd-tags-maybe)
                     (drawer . org-astro-drawer)
                     (example-block . org-astro-example-block)
                     (export-block . org-astro-export-block)
                     (export-snippet . org-astro-export-snippet)
                     (headline . org-astro-heading)
                     (inner-template . org-astro-inner-template)
                     (inline-src-block . org-astro-inline-src-block)
                     (keyword . org-astro-keyword)
                     (link . org-astro-link)
                     (paragraph . org-astro-paragraph)
                     (src-block . org-astro-src-block)
                     (special-block . org-astro-special-block))
  :filters-alist '((:filter-body . org-astro-body-filter))
;;;; options-alist
  ;;                KEY                       KEYWORD                    OPTION  DEFAULT                     BEHAVIOR
  :options-alist '(;; Variables not setting the front-matter directly
                   (:with-toc nil "toc" org-astro-export-with-toc)
                   (:section-numbers nil "num" org-astro-export-with-section-numbers)
                   (:author "AUTHOR" nil user-full-name newline)
                   (:creator "CREATOR" nil org-astro-export-creator-string)
                   (:with-smart-quotes nil "'" nil) ;Hugo/Goldmark does more correct conversion to smart quotes, especially for single quotes.
                   (:with-special-strings nil "-" nil) ;Hugo/Goldmark does the auto-conversion of "--" -> "–", "---" -> "—" and "..." -> "…"
                   (:with-sub-superscript nil "^" '{}) ;Require curly braces to be wrapped around text to sub/super-scripted
                   (:astro-with-locale "ASTRO_WITH_LOCALE" nil nil)
                   (:astro-front-matter-format "ASTRO_FRONT_MATTER_FORMAT" nil     org-astro-front-matter-format)
                   (:astro-level-offset "ASTRO_LEVEL_OFFSET" nil "1")
                   (:astro-preserve-filling "ASTRO_PRESERVE_FILLING" nil org-astro-preserve-filling) ;Preserve breaks so that text filling in Markdown matches that of Org
                   (:astro-delete-trailing-ws "ASTRO_DELETE_TRAILING_WS" nil org-astro-delete-trailing-ws)
                   (:astro-section "ASTRO_SECTION" nil org-astro-section)
                   (:astro-base-dir "ASTRO_BASE_DIR" nil org-astro-base-dir)
                   (:astro-base-dir "ASTRO_BASE_CONTENT_FOLDER" nil org-astro-content-folder)
                   (:astro-code-fence "ASTRO_CODE_FENCE" nil t) ;Prefer to generate triple-backquoted Markdown code blocks by default.
                   (:astro-use-code-for-kbd "ASTRO_USE_CODE_FOR_KBD" nil org-astro-use-code-for-kbd)
                   (:astro-prefer-hyphen-in-tags "ASTRO_PREFER_HYPHEN_IN_TAGS" nil org-astro-prefer-hyphen-in-tags)
                   (:astro-allow-spaces-in-tags "ASTRO_ALLOW_SPACES_IN_TAGS" nil org-astro-allow-spaces-in-tags)
                   (:astro-auto-set-lastmod "ASTRO_AUTO_SET_LASTMOD" nil org-astro-auto-set-lastmod)
                   (:astro-custom-front-matter "ASTRO_CUSTOM_FRONT_MATTER" nil nil space)
                   (:astro-front-matter-key-replace "ASTRO_FRONT_MATTER_KEY_REPLACE" nil nil space)
                   (:astro-date-format "ASTRO_DATE_FORMAT" nil org-astro-date-format)
                   (:html-container "HTML_CONTAINER" nil org-astro-container-element)
                   (:html-container-class "HTML_CONTAINER_CLASS" nil "")
                   (:html-container-nested "HTML_CONTAINER_NESTED" nil nil)

                   ;; Front-matter variables
                   ;; https://gohugo.io/content-management/front-matter/#front-matter-variables
                   ;; aliases
                   (:astro-aliases "ASTRO_ALIASES" nil nil space)
                   ;; audio
                   (:astro-audio "ASTRO_AUDIO" nil nil)
                   ;; date
                   ;; "date" is parsed from the Org #+date or subtree property EXPORT_ASTRO_DATE
                   (:date "DATE" nil nil)
                   ;; description
                   (:description "DESCRIPTION" nil nil)
                   ;; draft
                   ;; "draft" value interpreted by the TODO state of a
                   ;; post as Org subtree gets higher precedence.
                   (:astro-draft "ASTRO_DRAFT" nil nil)
                   ;; expiryDate
                   (:astro-expirydate "ASTRO_EXPIRYDATE" nil nil)
                   ;; headless (only for Page Bundles - Hugo v0.35+)
                   (:astro-headless "ASTRO_HEADLESS" nil nil)
                   ;; images
                   (:astro-images "ASTRO_IMAGES" nil nil newline)
                   ;; isCJKLanguage
                   (:astro-iscjklanguage "ASTRO_ISCJKLANGUAGE" nil nil)
                   ;; keywords
                   ;; "keywords" is parsed from the Org #+keywords or
                   ;; subtree property EXPORT_KEYWORDS.
                   (:keywords "KEYWORDS" nil nil newline)
                   ;; layout
                   (:astro-layout "ASTRO_LAYOUT" nil nil)
                   ;; lastmod
                   (:astro-lastmod "ASTRO_LASTMOD" nil nil)
                   ;; linkTitle
                   (:astro-linktitle "ASTRO_LINKTITLE" nil nil)
                   ;; locale (used in Hugo internal templates)
                   (:astro-locale "ASTRO_LOCALE" nil nil)
                   ;; markup
                   (:astro-markup "ASTRO_MARKUP" nil nil) ;default is "md"
                   ;; menu
                   (:astro-menu "ASTRO_MENU" nil nil space)
                   (:astro-menu-override "ASTRO_MENU_OVERRIDE" nil nil space)
                   ;; outputs
                   (:astro-outputs "ASTRO_OUTPUTS" nil nil space)
                   ;; publishDate
                   (:astro-publishdate "ASTRO_PUBLISHDATE" nil nil)
                   ;; series
                   (:astro-series "ASTRO_SERIES" nil nil newline)
                   ;; slug
                   (:astro-slug "ASTRO_SLUG" nil nil)
                   ;; taxomonomies - tags, categories
                   (:astro-tags "ASTRO_TAGS" nil nil newline)
                   ;; #+hugo_tags are used to set the post tags in Org
                   ;; files written for file-based exports.  But for
                   ;; subtree-based exports, the EXPORT_ASTRO_TAGS
                   ;; property can be used to override inherited tags
                   ;; and Org-style tags.
                   (:astro-categories "ASTRO_CATEGORIES" nil nil newline)
                   ;; #+hugo_categories are used to set the post
                   ;; categories in Org files written for file-based
                   ;; exports.  But for subtree-based exports, the
                   ;; EXPORT_ASTRO_CATEGORIES property can be used to
                   ;; override inherited categories and Org-style
                   ;; categories (Org-style tags with "@" prefix).
                   ;; resources
                   (:astro-resources "ASTRO_RESOURCES" nil nil space)
                   ;; title
                   ;; "title" is parsed from the Org #+title or the subtree heading.
                   ;; type
                   (:astro-type "ASTRO_TYPE" nil nil)
                   ;; url
                   (:astro-url "ASTRO_URL" nil nil)
                   ;; videos
                   (:astro-videos "ASTRO_VIDEOS" nil nil newline)
                   ;; weight
                   (:astro-weight "ASTRO_WEIGHT" nil nil space)))



;;; Miscellaneous Helper Functions

;;;; Check if a value is non-nil
(defun org-astro--value-get-true-p (value)
  "Return non-nil if VALUE is non-nil.
Return nil if VALUE is nil, \"nil\" or \"\"."
  (cond
   ((or (equal t value)
        (equal nil value))
    value)
   ((and (stringp value)
         (string= value "nil"))
    nil)
   (t
    ;; "" -> nil
    ;; "t" -> "t"
    ;; "anything else" -> "anything else"
    ;; 123 -> nil
    (org-string-nw-p value))))

;;;; Check if a boolean plist value is non-nil
(defun org-astro--plist-get-true-p (info key)
  "Return non-nil if KEY in INFO is non-nil.
Return nil if the value of KEY in INFO is nil, \"nil\" or \"\".

This is a special version of `plist-get' used only for keys that
are expected to hold a boolean value.

INFO is a plist used as a communication channel."
  (let ((value (plist-get info key)))
    ;; (message "dbg: org-astro--plist-get-true-p:: key:%S value:%S" key value)
    (org-astro--value-get-true-p value)))

;;;; Workaround to retain custom parameters in src-block headers post `org-babel-exp-code'
;; http://lists.gnu.org/archive/html/emacs-orgmode/2017-10/msg00300.html
(defun org-astro--org-babel-exp-code (orig-fun &rest args)
  "Return the original code block formatted for export.
ORIG-FUN is the original function `org-babel-exp-code' that this
function is designed to advice using `:around'.  ARGS are the
arguments of the ORIG-FUN.

This advice retains the `:hl_lines', `linenos', `syntax-style' and
`:front_matter_extra' parameters, if added to any source block.
This parameter is used in `org-astro-src-block'."
  (let* ((param-keys-to-be-retained '(:hl_lines :linenos :syntax-style :front_matter_extra))
         (info (car args))
         (parameters (nth 2 info))
         (ox-astro-params-str (let ((str ""))
                               (dolist (param parameters)
                                 (dolist (retain-key param-keys-to-be-retained)
                                   (when (equal retain-key (car param))
                                     (let ((val (cdr param)))
                                       (setq str
                                             (concat str " "
                                                     (symbol-name retain-key) " "
                                                     (cond
                                                      ((stringp val)
                                                       val)
                                                      ((numberp val)
                                                       (number-to-string val))
                                                      (t
                                                       (user-error "Invalid value %S assigned to %S"
                                                                   val retain-key)))))))))
                               (org-string-nw-p (org-trim str))))
         ret)
    ;; (message "[ox-astro ob-exp] info: %S" info)
    ;; (message "[ox-astro ob-exp] parameters: %S" parameters)
    ;; (message "[ox-astro ob-exp] ox-astro-params-str: %S" ox-astro-params-str)
    (setq ret (apply orig-fun args))
    (when ox-astro-params-str
      (let ((case-fold-search t))
        (setq ret (replace-regexp-in-string "\\`#\\+begin_src .*"
                                            (format "\\& %s" ox-astro-params-str) ret))))
    ;; (message "[ox-astro ob-exp] ret: %S" ret)
    ret))


;;;; Workaround to fix the regression in the behavior of `org-babel--string-to-number'.
;; https://lists.gnu.org/r/emacs-orgmode/2020-02/msg00931.html
(defun org-astro--org-babel--string-to-number (string)
  "If STRING represents a number return its value.
Otherwise return nil.

This function restores the behavior of
`org-babel--string-to-number' to that of before
https://git.savannah.gnu.org/cgit/emacs/org-mode.git/commit/?id=6b2a7cb20b357e730de151522fe4204c96615f98."
  (and (string-match-p "\\`-?\\([0-9]\\|\\([1-9]\\|[0-9]*\\.\\)[0-9]*\\)\\'" string)
       (string-to-number string)))

(defun org-astro--org-info-export (path desc format)
  "Add support for exporting [[info:..]] links for `astro' format.

See `org-link-parameters' for details about PATH, DESC and FORMAT."
  (let* ((parts (split-string path "#\\|::"))
         (manual (car parts))
         (node (or (nth 1 parts) "Top"))
         (title (format "Emacs Lisp: (info \\\"(%s) %s\\\")" manual node))
         (desc (or desc
                   (if (string= node "Top")
                       (format "%s Info" (capitalize manual))
                     (format "%s Info: %s" (capitalize manual) node))))
         ;; `link' below is mostly derived from the code in
         ;; `org-info-map-html-url'.
         (link (cond ((member manual org-info-emacs-documents)
                      (let ((manual-url (if (string= (downcase manual) "org")
                                            "https://orgmode.org/manual"
                                          (format "https://www.gnu.org/software/emacs/manual/html_node/%s" manual)))
                            (node-url (if (string= node "Top")
                                          "index.html"
                                        (concat (org-info--expand-node-name node) ".html"))))
                        (format "%s/%s" manual-url node-url)))
                     ((member manual org-astro-info-gnu-software)
                      (let ((manual-url (format "https://www.gnu.org/software/%s/manual/html_node" manual))
                            (node-url (if (string= node "Top")
                                          "index.html"
                                        (concat (org-info--expand-node-name node) ".html"))))
                        (format "%s/%s" manual-url node-url)))
                     ((cdr (assoc manual org-info-other-documents)))
                     (t
                      (concat manual ".html")))))
    (when (member format '(md astro))
      (format "[%s](%s \"%s\")" desc link title))))

(defun org-astro--org-cite-export-bibliography (orig-fun &rest args)
  "Insert a heading before the exported bibliography.

ORIG-FUN is the original function `org-cite-export-bibliography'
that this function is designed to advice using `:around'.  ARGS
are the arguments of the ORIG-FUN."
  (let ((bib (apply orig-fun args)))
    (when (org-string-nw-p bib)
      ;; Auto-inject Bibliography heading.
      (let ((info (nth 2 args)) ;(org-cite-export-bibliography KEYWORD _ INFO)
            (bib-heading (org-string-nw-p (plist-get org-astro-citations-plist :bibliography-section-heading))))
        (when bib-heading
          (let* ((bib-heading (org-astro--translate nil info bib-heading))
                 (loffset (string-to-number
                           (or (org-entry-get nil "EXPORT_ASTRO_LEVEL_OFFSET" :inherit)
                               (plist-get info :astro-level-offset))))
                 (level-mark (make-string (+ loffset 1) ?#)))
            (format "%s %s\n\n%s" level-mark bib-heading bib)))))))

(defun org-astro--before-export-function (subtreep)
  "Function to be run before an ox-astro export.

This function is called in the very beginning of
`org-astro-export-to-md' and `org-astro-export-as-md'.

SUBTREEP is non-nil for subtree-based exports.

This function is used to advise few functions.  Those advices are
effective only while an ox-astro export is in progress because
they get removed later in `org-astro--after-1-export-function'.

This is an internal function."
  (unless subtreep
    ;; Reset the variables that are used only for subtree exports.
    (setq org-astro--subtree-coord nil))
  (advice-add 'org-babel-exp-code :around #'org-astro--org-babel-exp-code)
  (advice-add 'org-babel--string-to-number :override #'org-astro--org-babel--string-to-number)
  (advice-add 'org-info-export :override #'org-astro--org-info-export)
  (advice-add 'org-cite-export-bibliography :around #'org-astro--org-cite-export-bibliography)
  ;; Cache the Org-roam unit table for the upcoming export; the
  ;; roamID/roamLinks front-matter fields and the id: link
  ;; translator read it.
  (setq org-astro--roam-table (org-astro--get-roam-table)))

(defun org-astro--after-1-export-function (info outfile)
  "Function to be run after exporting one post.

The post could be exported using the subtree-based or file-based
method.

This function is called in the end of `org-astro-export-to-md',
and `org-astro-export-as-md'.

INFO is a plist used as a communication channel.

OUTFILE is the Org exported file name.

This is an internal function."
  (advice-remove 'org-cite-export-bibliography #'org-astro--org-cite-export-bibliography)
  (advice-remove 'org-info-export #'org-astro--org-info-export)
  (advice-remove 'org-babel--string-to-number #'org-astro--org-babel--string-to-number)
  (advice-remove 'org-babel-exp-code #'org-astro--org-babel-exp-code)
  (setq org-astro--fm nil)
  (setq org-astro--fm-yaml nil)
  (setq org-astro--roam-table nil))

(defun org-astro--cleanup ()
  "Function to kill Ox-Hugo opened buffers and reset internal variables.

This is an internal function."
  (setq org-astro--subtree-count 0) ;Reset the subtree count

  ;; Kill all the buffers opened by during an export.
  (dolist (buf org-astro--opened-buffers)
    (kill-buffer buf))
  (setq org-astro--opened-buffers nil)

  (setq org-astro--preprocessed-buffer nil)
  ;; Drop the memoized roam table too: it belongs to the buffer that
  ;; was just exported, and a stale copy must not leak into the next
  ;; export.
  (setq org-astro--roam-table nil))

(defun org-astro--after-all-exports-function ()
  "Function to be run after Ox-Hugo exports all the posts.

This function is called in the end of
`org-astro-export-wim-to-md', `org-astro-export-to-md' and
`org-astro-export-as-md' (if its ALL-SUBTREES arg is non-nil).

This is an internal function."
  (org-astro--cleanup)
  (dolist (fn org-astro--all-subtrees-export--functions-to-silence)
    (advice-remove fn #'org-astro--advice-silence-messages)))

;;;; HTMLized section number for heading
(defun org-astro--get-heading-number (heading info &optional toc)
  "Return htmlized section number for the HEADING.
INFO is a plist used as a communication channel.

When the \"num\" export option is `onlytoc', heading number is
returned only if the optional argument TOC is non-nil.

Return nil if there is no heading number, or if it has been
disabled."
  (let ((onlytoc (equal 'onlytoc (plist-get info :section-numbers))))
    (when (and (if toc
                   t
                 (not onlytoc)) ;If `toc' is nil, but `onlytoc' is non-nil, return nil
               (org-export-numbered-headline-p heading info))
      (let ((number-str (mapconcat
                         'number-to-string
                         (org-export-get-headline-number heading info) ".")))
        (format "<span class=\"section-num\">%s</span> " number-str)))))

;;;; Build TOC
(defun org-astro--build-toc (info &optional n scope local)
  "Return table of contents as a string.

INFO is a plist used as a communication channel.

Optional argument N, when non-nil, is a positive integer
specifying the depth of the table.

When optional argument SCOPE is non-nil, build a table of
contents according to the specified element.

When optional argument LOCAL is non-nil, build a table of
contents according to the current heading."
  (let* ((toc-heading
          (unless local
            (format "\n<div class=\"heading\">%s</div>\n"
                    (org-html--translate "Table of Contents" info))))
         (current-level nil)
         (toc-items
          (mapconcat
           (lambda (heading)
             (let* ((level-raw (org-export-get-relative-level heading info))
                    (level (if scope
                               (let* ((current-level-inner
                                       (progn
                                         (unless current-level
                                           (setq current-level level-raw))
                                         current-level))
                                      (relative-level
                                       (1+ (- level-raw current-level-inner))))
                                 ;; (message (concat "[ox-astro build-toc DBG] "
                                 ;;                  "current-level-inner:%d relative-level:%d")
                                 ;;          current-level-inner relative-level)
                                 relative-level)
                             level-raw))
                    (indentation (make-string (* 4 (1- level)) ?\s))
                    (todo (and (org-astro--plist-get-true-p info :with-todo-keywords)
                               (org-element-property :todo-keyword heading)))
                    (todo-str (if todo
                                  (concat (org-astro--todo todo info) " ")
                                ""))
                    (heading-num-list (org-export-get-headline-number heading info))
                    (number (if heading-num-list
                                ;; (message "[ox-astro TOC DBG] heading-num-list: %S" heading-num-list)
                                (org-astro--get-heading-number heading info :toc)
                              ""))
                    (toc-entry
                     (format "[%s%s](#%s)"
                             todo-str
                             (org-export-data-with-backend
                              (org-export-get-alt-title heading info)
                              (org-export-toc-entry-backend 'astro)
                              info)
                             (org-astro--get-anchor heading info)))
                    (tags (and (plist-get info :with-tags)
                               (not (eq 'not-in-toc (plist-get info :with-tags)))
                               (let ((tags (org-export-get-tags heading info)))
                                 (and tags
                                      (format ":%s:"
                                              (mapconcat #'identity tags ":")))))))
               ;; (message "[ox-astro build-toc DBG] level:%d, number:%s" level number)
               ;; (message "[ox-astro build-toc DBG] indentation: %S" indentation)
               ;; (message "[ox-astro build-toc DBG] todo: %s | %s" todo todo-str)
               (concat indentation "- " number toc-entry tags)))
           (org-export-collect-headlines info n scope)
           "\n"))                       ;Newline between TOC items
         ;; Remove blank lines from in-between TOC items, which can
         ;; get introduced when using the "UNNUMBERED: t" heading
         ;; property.
         (toc-items (org-string-nw-p
                     (replace-regexp-in-string "\n\\{2,\\}" "\n" toc-items))))
    ;; (message "[ox-astro build-toc DBG] toc-items:%s" toc-items)
    (when toc-items
      (let ((toc-classes '("toc" "ox-astro-toc"))
            ;; `has-section-numbers' is non-nil if section numbers are
            ;; present for even one heading.
            (has-section-numbers (string-match-p "^\\s-*\\-\\s-<span class=\"section\\-num\"" toc-items)))
        (when has-section-numbers
          (push "has-section-numbers" toc-classes))
        (when local
          (push "local" toc-classes))
        (concat (format "<div class=\"%s\">\n" (string-join (reverse toc-classes) " "))
                "" ;This is a nasty workaround till Hugo/Blackfriday support
                toc-heading    ;wrapping Markdown in HTML div's.
                "\n"
                toc-items ;https://github.com/kaushalmodi/ox-astro/issues/93
                "\n\n"
                "</div>\n"
                ;; Special comment that can be use to filter out the TOC
                ;; from .Summary in Hugo templates.
                ;;
                ;;     {{ $summary_splits := split .Summary "<!--endtoc-->" }}
                ;;     {{ if eq (len $summary_splits) 2 }}
                ;;         <!-- If that endtoc special comment is present, output only the part after that comment as Summary. -->
                ;;         {{ index $summary_splits 1 | safeHTML }}
                ;;     {{ else }}
                ;;         <!-- Print the whole Summary if endtoc special comment is not found. -->
                ;;         {{ .Summary }}
                ;;     {{ end }}
                "<!--endtoc-->\n")))))

;;;; Resources Alist Merging
(defun org-astro--get-resources-alist (resources)
  "Generate a merged RESOURCES alist.

All parameters for the same \"src\" are merged together in the
same Lisp form.  Parameters that are none of \"src\", \"title\"
or \"name\" are packed into an alist with `car' as \"params\"."
  ;; (message "[resources IN DBG]: %S" resources)
  (when resources
    (let (src1 all-src src-cons src-already-exists)
      (dolist (res resources)
        ;; (message "res: %S" res)
        (let ((key (car res)))
          (cond
           ((equal key 'src)
            (unless (null src1)
              (setq src1 (nreverse src1))
              (if src-already-exists
                  (setcdr src-already-exists (cdr src1))
                (push src1 all-src)))
            (setq src-cons res)
            (setq src-already-exists (assoc src-cons all-src))
            ;; (message "%S exists? %S" (cdr src-cons) src-already-exists)
            (setq src1 (or (nreverse src-already-exists) (list res)))
            ;; (message "src1 temp: %S" src1)
            )
           ((member key '(title name))
            (push res src1))
           (t                             ;Resource Params
            (let* ((params-cons (assoc 'params src1))
                   (params (cdr params-cons)))
              (if params
                  (progn
                    ;; (message "params 1: %S" params)
                    (push res params)
                    (setq params (nreverse params))
                    ;; (message "params 2: %S" params)
                    (setcdr params-cons params))
                (setq params (list res))
                (push `(params . ,params) src1))
              ;; (message "src1 temp 2: %S" src1)
              (setcdr (assoc 'params src1) params))))))
      (setq src1 (nreverse src1))
      ;; (message "src1: %S" src1)
      (if src-already-exists
          (setcdr src-already-exists (cdr src1))
        (push src1 all-src))
      ;; Retain the order of src
      (setq all-src (nreverse all-src))
      ;; (message "all-src: %S" all-src)
      all-src)))

;;;; Publication Directory
(defun org-astro--get-pub-dir (info)
  "Return the post publication directory path.

The publication directory is created if it does not exist.

INFO is a plist used as a communication channel."
  (let* ((base-dir (if (plist-get info :astro-base-dir)
                       (file-name-as-directory (plist-get info :astro-base-dir))
                     (user-error "It is mandatory to set the ASTRO_BASE_DIR property or the `org-astro-base-dir' local variable")))
         (content-dir (concat org-astro-content-folder "/"))
         (section-path (org-astro--get-section-path info))
         (bundle-dir (let ((bundle-path (or ;Hugo bundle set in the post subtree gets higher precedence
                                         (org-astro--entry-get-concat nil "EXPORT_ASTRO_BUNDLE" "/")
                                         (plist-get info :astro-bundle)))) ;This is mainly to support per-file flow
                       (if bundle-path
                           (file-name-as-directory bundle-path)
                         "")))
         (pub-dir (let ((dir (concat base-dir content-dir section-path bundle-dir)))
                    (make-directory dir :parents) ;Create the directory if it does not exist
                    dir)))
    (file-truename pub-dir)))

;;;; Get the publish date for the current post
(defun org-astro--get-date (info fmt)
  "Return current post's publish date as a string.

The date is derived with this precedence:

1. `:logbook-date' property from INFO

2. `CLOSED' time stamp if the point is in an Org subtree with the
   `CLOSED' property set (usually generated automatically when
   switching a heading's TODO state to \"DONE\")

3. `EXPORT_DATE' property in current post subtree

4. Date if set in the Org file's \"#+date\" keyword. This date is
   formatted using the time format string FMT.

If none of the above apply, return nil.

INFO is a plist used as a communication channel."
  (or
   (plist-get info :logbook-date)
   (org-entry-get (point) "CLOSED")
   (org-string-nw-p
    (org-export-data (plist-get info :date) info)) ;`org-export-data' required
   (org-string-nw-p
    (org-export-get-date info fmt))))

;;;; Format Dates
(defun org-astro--org-date-time-to-rfc3339 (date-time info)
  "Convert DATE-TIME to RFC 3339 format.

DATE-TIME can be either Emacs format time list (example: return
value of `current-time'), or an Org date/time string.

INFO is a plist used as a communication channel."
  (let* ((date-time (if (stringp date-time)
                        (apply #'encode-time (org-parse-time-string date-time))
                      date-time))
         (date-nocolon (format-time-string
                        (plist-get info :astro-date-format)
                        date-time)))
    ;; Hugo expects the date stamp in this format (RFC3339 -- See
    ;; `org-astro--date-time-regexp'.) i.e. if the date contains the
    ;; time-zone, a colon is required to separate the hours and
    ;; minutes in the time-zone section.  2017-07-06T14:59:45-04:00

    ;; But by default the "%z" placeholder for time-zone (see
    ;; `format-time-string') produces the zone time-string as "-0400"
    ;; (Note the missing colon).  Below simply adds a colon between
    ;; "04" and "00" in that example.
    (and (stringp date-nocolon)
         (replace-regexp-in-string
          "\\([0-9]\\{2\\}\\)\\([0-9]\\{2\\}\\)\\'" "\\1:\\2"
          date-nocolon))))

(defun org-astro--format-date (date-key info)
  "Return a date string formatted in Hugo-compatible format.

DATE-KEY is the key in INFO from which the date is to be
retrieved.  INFO is a plist used as a communication channel.

Possible values of DATE-KEY are `:date', `:astro-lastmod',
`:astro-publishdate', and `:astro-expirydate'.

Return nil if the retrieved date from INFO is nil or if the date
cannot be formatted in Hugo-compatible format."
  (let* ((date-fmt (plist-get info :astro-date-format))
         (date-raw (cond
                    ((equal date-key :date)
                     ;; (message "[ox-astro date DBG] 1 %s" (plist-get info date-key))
                     ;; (message "[ox-astro date DBG] 2 %s" (org-export-data (plist-get info date-key) info))
                     (org-astro--get-date info date-fmt))
                    ((equal date-key :astro-lastmod)
                     (or (plist-get info :logbook-lastmod) ;lastmod derived from LOGBOOK gets higher precedence
                         (org-string-nw-p (plist-get info date-key))))
                    ((and (equal date-key :astro-publishdate)
                          (org-entry-get (point) "SCHEDULED"))
                     ;; Get the date from the "SCHEDULED" property.
                     (org-entry-get (point) "SCHEDULED"))
                    (t            ;:astro-publishdate, :astro-expirydate
                     (org-string-nw-p (plist-get info date-key)))))
         (dt-rfc3339 (cond
                      ;; If the date set for the DATE-KEY parameter is
                      ;; already in Hugo-compatible format, use it.
                      ((and (stringp date-raw)
                            (string-match-p org-astro--date-time-regexp date-raw))
                       date-raw)
                      ;; Else if it's any other string (like
                      ;; "<2018-01-23 Tue>"), try to parse that date.
                      ((stringp date-raw)
                       (condition-case err
                           (org-astro--org-date-time-to-rfc3339 date-raw info)
                         (error
                          ;; Set dt-rfc3339 to nil if error happens.
                          ;; An example: If #+date is set to 2012-2017
                          ;; to set the copyright years, just set the
                          ;; date to nil instead of throwing an error
                          ;; like: org-parse-time-string: Not a
                          ;; standard Org time string: 2012-2017
                          (message
                           (format "[ox-astro] Date will not be set in the front-matter: %s"
                                   (nth 1 err)))
                          nil)))
                      ;; Else (if nil) and user want to auto-set the
                      ;; lastmod field. If the lastmod value is
                      ;; derived from LOGBOOK, disable the
                      ;; auto-setting of lastmod.
                      ((and (equal date-key :astro-lastmod)
                            (null (plist-get info :logbook-lastmod))
                            (org-astro--plist-get-true-p info :astro-auto-set-lastmod))
                       (let* ((curr-time (org-current-time))
                              (lastmod-str (org-astro--org-date-time-to-rfc3339 curr-time info)))
                         ;; (message "[ox-astro suppress-lastmod] current-time = %S (decoded = %S)"
                         ;;          curr-time (decode-time curr-time))
                         ;; (message "[ox-astro suppress-lastmod] lastmod-str = %S"
                         ;;          lastmod-str )
                         (if (= 0.0 org-astro-suppress-lastmod-period)
                             (progn
                               ;; (message "[ox-astro suppress-lastmod] not suppressed")
                               lastmod-str)
                           (let ((date-str (org-string-nw-p (org-astro--get-date info date-fmt))))
                             ;; (message "[ox-astro suppress-lastmod] date-str = %S"
                             ;;          date-str)
                             (when date-str
                               (let* ((date-time (apply #'encode-time
                                                        (mapcar (lambda (el) (or el 0))
                                                                (parse-time-string date-str))))
                                      ;; It's safe to assume that
                                      ;; `current-time' will always
                                      ;; be >= the post date.
                                      (delta (float-time
                                              (time-subtract curr-time date-time)))
                                      (suppress-period (if (< 0.0 org-astro-suppress-lastmod-period)
                                                           org-astro-suppress-lastmod-period
                                                         (- org-astro-suppress-lastmod-period))))
                                 ;; (message "[ox-astro suppress-lastmod] date-time = %S (decoded = %S)"
                                 ;;          date-time (decode-time date-time))
                                 ;; (message "[ox-astro suppress-lastmod] delta = %S" delta)
                                 ;; (message "[ox-astro suppress-lastmod] suppress-period = %S"
                                 ;;          suppress-period)
                                 (when (>= delta suppress-period)
                                   lastmod-str)))))))
                      ;; Else.. do nothing.
                      (t
                       nil))))
    dt-rfc3339))

;;;; Replace Front-matter Keys
(defun org-astro--replace-keys-maybe (data info)
  "Return DATA with its keys replaced, maybe.

The keys in DATA are replaced if ASTRO_FRONT_MATTER_KEY_REPLACE is
set appropriately.

The replacement syntax is:

    #+hugo_front_matter_key_replace: oldkey>newkey

If newkey is a special string \"nil\", oldkey will be removed
from the front-matter.

You can also do multiple key replacements:

    #+hugo_front_matter_key_replace: oldkey1>newkey1 oldkey2>newkey2

Above examples are using the keyword
ASTRO_FRONT_MATTER_KEY_REPLACE, but the same also applies when
using its subtree property form
:EXPORT_ASTRO_FRONT_MATTER_KEY_REPLACE:.

Note that:

1. There are no spaces around the special character \">\".
2. Spaces are used to only separate multiple replacements are shown in
   the second example above.
3. The replacements are literal.. there are no regular expressions
   involved.

INFO is a plist used as a communication channel."
  (let* ((repl-str (plist-get info :astro-front-matter-key-replace))
         (repl-str (when (org-string-nw-p repl-str)
                     (org-trim repl-str))))
    (when repl-str
      ;; (message "[ox-astro replace-key str DBG] %S" repl-str)
      (let* ((repl-list (split-string repl-str)) ;`repl-str' is space-separated
             (repl-alist (let (alist)
                           (dolist (repl repl-list)
                             (when (and (stringp repl) ;`repl' would look like "oldkey>newkey"
                                        (string-match-p ">" repl))
                               (let* ((pair (split-string repl ">"))
                                      (key-orig-str (org-string-nw-p (nth 0 pair)))
                                      (key-repl-str (org-string-nw-p (nth 1 pair)))
                                      (repl-pair (when (and key-orig-str
                                                            key-repl-str)
                                                   (cons (intern key-orig-str)
                                                         (intern key-repl-str)))))
                                 (when repl-pair
                                   ;; (message "[ox-astro pair DBG] %S" pair)
                                   ;; (message "[ox-astro repl-pair DBG] %S" repl-pair)
                                   ;; (message "[ox-astro repl-pair car DBG] %S" (car repl-pair))
                                   ;; (message "[ox-astro repl-pair cdr DBG] %S" (cdr repl-pair))
                                   (push repl-pair alist)))))
                           alist)))
        ;; (message "[ox-astro replace-key list DBG] %S" repl-list)
        ;; (message "[ox-astro replace-key alist DBG] %S" repl-alist)
        (dolist (repl repl-alist)
          (let ((key-orig (car repl))
                (key-repl (cdr repl)))
            (let ((found-key-cell (assoc key-orig data)))
              (when found-key-cell
                ;; (message "[ox-astro replace-key found-key-cell DBG] %S" found-key-cell)
                ;; (message "[ox-astro replace-key key-orig DBG] %S" key-orig)
                ;; (message "[ox-astro replace-key key-repl DBG] %S" key-repl)
                (if (string= "nil" key-repl)
                    ;; Setting value of a front-matter key to nil will
                    ;; cause that key to be removed during export.
                    ;; See `org-astro--gen-front-matter'.
                    (setf (cdr found-key-cell) nil)
                  ;; https://emacs.stackexchange.com/a/3398/115
                  (setf (car found-key-cell) key-repl))))))))
    data))

;;;; TODO keywords
(defun org-astro--todo (todo info)
  "Format TODO keywords into HTML.

This function is almost like `org-html--todo' except that:
- An \"org-todo\" class is always added to the span element.
- `org-astro--replace-underscores-with-spaces' is used to replace
  double-underscores in TODO with spaces.

INFO is a plist used as a communication channel."
  (when todo
    ;; (message "[DBG todo] todo: %S" todo)
    ;; (message "[DBG todo] org-done-keywords: %S" org-done-keywords)
    ;; (message "[DBG todo] is a done keyword? %S" (member todo org-done-keywords))
    ;; (message "[DBG todo] html-todo-kwd-class-prefix: %S" (plist-get info :html-todo-kwd-class-prefix))
    (format "<span class=\"org-todo %s %s%s\">%s</span>"
            (if (member todo org-done-keywords) "done" "todo")
            (or (org-string-nw-p (plist-get info :html-todo-kwd-class-prefix)) "")
            (org-html-fix-class-name todo)
            (org-astro--replace-underscores-with-spaces todo))))

;;;; Parse draft state
(defun org-astro--parse-draft-state (info)
  "Parse the draft state of the post heading at point.

Return a \"true\" or \"false\" string.

For per-subtree export flow, the draft state parsed from the Org
TODO state has a higher precedence than the value of ASTRO_DRAFT
keyword/property.

INFO is a plist used as a communication channel."
  (let* ((todo-keyword (org-entry-get (point) "TODO"))
         (draft (cond
                 ((stringp todo-keyword)
                  (if (member todo-keyword org-done-keywords)
                      nil
                    (progn
                      (when (string= "DRAFT" todo-keyword)
                        (let ((title (org-entry-get (point) "ITEM"))) ;Post title
                          (message "[ox-astro] `%s' post is marked as a DRAFT" title)))
                      t)))
                 (;; If the ASTRO_DRAFT keyword/property *is* set, but
                  ;; not to nil.
                  (plist-get info :astro-draft)
                  (let* ((draft-1 (org-astro--front-matter-value-booleanize (plist-get info :astro-draft)))
                         (is-draft (if (string= "true" draft-1) t nil)))
                    (when is-draft
                      (let* ((entry (org-element-at-point))
                             (is-subtree (org-element-property :EXPORT_FILE_NAME entry))
                             (title (if is-subtree
                                        (org-entry-get (point) "ITEM")
                                      (or (car (plist-get info :title)) "<EMPTY TITLE>"))))
                        (message "[ox-astro] `%s' post is marked as a DRAFT" title)))
                    is-draft))
                 (t ;Neither of Org TODO state and ASTRO_DRAFT keyword/property are set
                  nil)))
         (draft-bool-str (org-astro--front-matter-value-booleanize (symbol-name draft))))
    ;; (message "dbg: draft-state: todo keyword=%S ASTRO_DRAFT=%S draft=%S"
    ;;          todo-keyword (plist-get info :astro-draft) draft-bool-str)
    draft-bool-str))

;;;; Get a property value and concat it with its parent value
(defun org-astro--entry-get-concat (pom property &optional sep)
  "Concatenate an Org Property value with its inherited value.

Get value of PROPERTY for entry or content at point-or-marker
POM.  If a parent subtree has the same PROPERTY set, append the
current property value to that, following the optional SEP.

SEP is the concatenation separator string.  If it is nil, it
defaults to \"\".

This function internally calls `org-entry-get' with its INHERIT
argument set to non-nil and the LITERAL-NIL argument set to nil.

If the property is present but empty, the return value is the
empty string.  If the property is not present at all, nil is
returned.  In any other case, return the value as a string.
Search is case-insensitive."
  (let ((sep (or sep ""))
        (value-no-concat (org-entry-get pom property :inherit)))
    ;; (message "[ox-astro section concat DBG] value-no-concat: %S" value-no-concat)
    (if value-no-concat
        ;; Get the value of PROPERTY from the parent relative to
        ;; current point.
        (let ((value-here-no-inherit (org-entry-get pom property nil))
              (value-parent (org-with-wide-buffer
                             (when (org-up-heading-safe)
                               (org-astro--entry-get-concat nil property sep)))))
          ;; (message "[ox-astro section concat DBG] value-here-no-inherit: %S" value-here-no-inherit)
          ;; (message "[ox-astro section concat DBG] value-parent: %S" value-parent)
          (if value-here-no-inherit
              (format "%s%s%s"
                      (or value-parent "")
                      (if value-parent
                          (if (and (org-string-nw-p sep)
                                   (string-suffix-p sep value-parent))
                              "" ;Don't add the `sep' if `value-parent' already ends with that `sep'
                            sep)
                        "")
                      value-no-concat)
            ;; Use the value from parent directly if the property is not
            ;; set in the current subtree.
            value-parent))
      nil)))

(defun org-astro--get-section-path (info)
  "Return the Hugo section path.
This is the path relative to the Hugo \"content\" directory.

If the EXPORT_ASTRO_SECTION_FRAG keyword is set in the current or a
parent subtree, return the concatenation of the \"ASTRO_SECTION\"
and the concatenated \"EXPORT_ASTRO_SECTION_FRAG\" values as a path.

Else, return the \"ASTRO_SECTION\" path.

The function always returns a string.

INFO is a plist used as a communication channel."
  (let* ((hugo-section-prop (org-entry-get nil "EXPORT_ASTRO_SECTION" :inherit))
         (hugo-section-kwd (plist-get info :astro-section))
         (hugo-section-frag-prop (org-entry-get nil "EXPORT_ASTRO_SECTION_FRAG" :inherit))
         (section-path-1 (or hugo-section-prop ;EXPORT_ASTRO_SECTION gets higher precedence
                             hugo-section-kwd)) ;This is mainly to support per-file flow
         section-path)
    ;; (message "[ox-astro section-path DBG] hugo-section-prop: %S" hugo-section-prop)
    ;; (message "[ox-astro section-path DBG] hugo-section-kwd: %S" hugo-section-kwd)
    ;; (message "[ox-astro section-path DBG] hugo-section-frag-prop: %S" hugo-section-frag-prop)
    ;; (message "[ox-astro section-path DBG] section path-1: %S" section-path-1)
    (unless section-path-1
      (user-error "It is mandatory to set the ASTRO_SECTION property"))
    (when (org-string-nw-p hugo-section-frag-prop)
      (setq section-path-1
            (concat (file-name-as-directory section-path-1) ;Add trailing slash if absent
                    (org-astro--entry-get-concat nil "EXPORT_ASTRO_SECTION_FRAG" "/"))))
    (setq section-path (file-name-as-directory section-path-1))
    ;; (message "[ox-astro section-path DBG] section path: %S" section-path)
    section-path))

;;;; Get Language
(defun org-astro--get-lang (info)
  "Return the language used for the content.

The returned value is a string that can consist of only English
alphabets and an underscore.

The first 2 characters of this string is a language codes as per
ISO 639-1 standard.  See
https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes.

INFO is a plist used as a communication channel."
  (let ((lang (plist-get info :lang-iso-code)))
    (unless lang
      (setq lang
            (or (plist-get info :astro-locale)
                ;; https://www.gnu.org/software/gettext/manual/html_node/Locale-Environment-Variables.html
                (getenv "LANGUAGE")
                (getenv "LC_ALL")
                (getenv "LANG")))
      (when (stringp lang)
        (setq lang
              (replace-regexp-in-string "\\`\\([a-z]+_[A-Z]+\\).*\\'" "\\1" lang)))
      (setq lang (org-string-nw-p lang))
      (when lang
        ;; (message "[org-astro--get-lang DBG] language: %s" lang)
        (plist-put info :lang-iso-code lang)))
    lang))

;;;; Check if lang is CJ(K)
(defun org-astro--lang-cjk-p (info)
  "Return non-nil is the language is Chinese or Japanese.

\(Check for Korean language has not been added as no `ox-astro'
user has requested for it.)

INFO is a plist used as a communication channel."
  (let* ((lang (org-astro--get-lang info))
         (lang-2chars (when (and (stringp lang)
                                 (>= (length lang) 2))
                        (substring lang 0 2))))
    (and lang-2chars
         (member lang-2chars '("zh"      ;"zh", "zh_CH", ..
                               "ja"))))) ;"ja", ..

;;;; Format tags into HTML
(defun org-astro--tags (tags info)
  "Format TAGS into HTML.
INFO is a plist containing export options.

This function is almost identical to `org-html--tags' from
`ox-html' except that the tag separator is an empty string."
  (when tags
    (format "<span class=\"tag\">%s</span>"
            (mapconcat
             (lambda (tag)
               (format "<span class=\"%s\">%s</span>"
                       (concat (plist-get info :html-tag-class-prefix)
                               (org-html-fix-class-name tag))
                       tag))
             tags ""))))

;;;; Check if the buffer has any valid post subtree
(defun org-astro--buffer-has-valid-post-subtree-p ()
  "Return non-nil if the current Org buffer has at least one valid post subtree.

A valid Hugo post subtree has the `:EXPORT_FILE_NAME:' property
set to a non-empty string."
  (org-with-wide-buffer
   (catch 'found
     (org-map-entries
      (lambda () (throw 'found t)) ;Return quickly on finding the first match
      "EXPORT_FILE_NAME<>\"\""))))

;;;; Advice for silencing messages
(defun org-astro--advice-silence-messages (orig-fun &rest args)
  "Advice function that silences all messages in ORIG-FUN.
ARGS are the ORIG-FUN function's arguments."
  (let ((inhibit-message t)      ;Don't show the messages in Echo area
        (message-log-max nil))   ;Don't show the messages in the *Messages* buffer
    (apply orig-fun args)))

;;;; Plainify (mimick the Hugo plainify function)
(defun org-astro--plainify-string (str info)
  "Return STR string without any markup.

INFO is a plist used as a communication channel.

If STR is an empty string or nil, return nil.

This function aims to mimick the Hugo `plainify' function:
https://gohugo.io/functions/plainify/.  For example, if STR is
\"string *with* some /markup/\", the returned string is \"string
with some markup\"."
  (org-string-nw-p
   (replace-regexp-in-string
    "</?[^>]+>" ""
    (org-export-data-with-backend str 'html info))))



;;; Transcode Functions

;;;; Code (<kdb> tags)
(defun org-astro-kbd-tags-maybe (verbatim _contents info)
  "Wrap text in VERBATIM object with HTML kbd tags.
The kdb wrapping is done if `org-astro-use-code-for-kbd' is non-nil.

CONTENTS is nil.  INFO is a plist used as a communication
channel."
  (if (org-astro--plist-get-true-p info :astro-use-code-for-kbd)
      (format "<kbd>%s</kbd>" (org-html-encode-plain-text
                               (org-element-property :value verbatim)))
    (org-md-verbatim verbatim nil nil)))

;;;; Drawer
(defun org-astro--parse-logbook-entry (para parent-heading-title info)
  "Parse a LOGBOOK `paragraph' element PARA and save data to INFO.

If the LOGBOOK drawer is under a sub-heading,
PARENT-HEADING-TITLE will be that heading's \"plainified\" title
string.  If LOGBOOK drawer is at the top level, this argument
will be nil.

INFO is a plist used as a communication channel.

This function updates these properties in INFO: `:logbook-date',
`:logbook-lastmod', `:logbook'."
  ;; (pp para)
  (let* ((logbook-entry ())
         (para-raw-str (org-export-data para info))
         ;; Parse the logbook entry's timestamp.
         (timestamp
          (org-element-map para 'timestamp
            (lambda (ts)
              ;; (pp ts)
              (let* ((ts-raw-str (org-element-property :raw-value ts))
                     (ts-str (org-astro--org-date-time-to-rfc3339 ts-raw-str info)))
                ;; (message "[ox-astro logbook DBG] ts: %s, ts fmtd: %s"
                ;;          ts-raw-str ts-str)
                (push `(timestamp . ,ts-str) logbook-entry)
                ts-str)) ;lambda return for (org-element-map para 'timestamp
            nil :first-match)))
    ;; (message "\n[ox-astro logbook DBG] paragraph raw str : %s" para-raw-str)
    ;; (message "[ox-astro logbook DBG] timestamp : %s" timestamp)
    (unless timestamp
      (user-error "No time stamp is recorded in the LOGBOOK drawer entry"))

    (cl-labels ((get-match-string-and-trim-quotes
                 (num str)
                 (org-string-nw-p
                  (replace-regexp-in-string
                   ;; Handle corner case: If a TODO state has "__" in them, the
                   ;; underscore will be escaped. Remove that "\".
                   "\\\\" ""
                   (save-match-data ;Required because `string-trim' changes match data
                     (string-trim
                      (or (match-string-no-properties num str) "")
                      "\"" "\"")))))

                ;; Parse (assq 'state org-log-note-headings)
                (parse-state-change-maybe
                 ()
                 (let ((state-change-re "^State\\s-+\\(?1:\".+?\"\\)*\\s-+from\\s-+\\(?2:\".+?\"\\)*"))
                   (when (string-match state-change-re para-raw-str)
                     (let ((to-state (get-match-string-and-trim-quotes 1 para-raw-str))
                           ;; (from-state (get-match-string-and-trim-quotes 2 para-raw-str)) ;For debug
                           )
                       ;; (message "[ox-astro logbook DBG] state change : from %s to %s @ %s"
                       ;;          from-state to-state timestamp)
                       (when to-state
                         (push `(to_state . ,to-state) logbook-entry)
                         ;; (message "[ox-astro logbook DBG] org-done-keywords: %S" org-done-keywords)
                         (when (and (null parent-heading-title) ;Parse dates from only the toplevel LOGBOOK drawer.
                                    (member to-state org-done-keywords))
                           ;; The first parsed TODO state change entry will be the
                           ;; latest one, and `:logbook-date' would already have
                           ;; been set to that.  So if `:logbook-lastmod' is not set,
                           ;; set that that to the value of `:logbook-date'.
                           ;; *This always works because the newest state change or note
                           ;; entry is always put to the top of the LOGBOOK.*
                           (unless (plist-get info :logbook-lastmod)
                             (when (plist-get info :logbook-date)
                               (plist-put info :logbook-lastmod (plist-get info :logbook-date))))
                           ;; `:logbook-date' will keep on getting updating until the last
                           ;; parsed (first entered) "state changed to DONE" entry.
                           (plist-put info :logbook-date timestamp)))
                       ;; (when from-state ;For debug
                       ;;   (push `(from_state . ,from-state) logbook-entry))
                       )
                     t)))

                ;; Parse (assq 'note org-log-note-headings)
                (parse-note-maybe
                 ()
                 (let ((note-re "^Note taken on .*?\n\\(?1:\\(.\\|\n\\)*\\)"))
                   (when (string-match note-re para-raw-str)
                     (let ((logbook-notes (plist-get info :logbook))
                           (note (string-trim
                                  (match-string-no-properties 1 para-raw-str))))
                       ;; (message "[ox-astro logbook DBG] note : %s @ %s" note timestamp)
                       (push `(note . ,note) logbook-entry)
                       ;; Update the `lastmod' field using the
                       ;; note's timestamp.
                       ;; *This always works because the newest state change or note
                       ;; entry is always put to the top of the LOGBOOK.*
                       (unless parent-heading-title ;Parse dates from only the toplevel LOGBOOK drawer.
                         (unless (plist-get info :logbook-lastmod)
                           (plist-put info :logbook-lastmod timestamp)))

                       (let ((context-key (or parent-heading-title "_toplevel")))
                         (unless (assoc context-key logbook-notes)
                           (push (cons context-key (list (cons 'notes (list)))) logbook-notes))
                         (setcdr (assoc 'notes (assoc context-key logbook-notes))
                                 (append (cdr (assoc 'notes (assoc context-key logbook-notes)))
                                         (list (nreverse logbook-entry)))))
                       (plist-put info :logbook logbook-notes))
                     t))))

      (save-match-data
        (cond
         ((parse-state-change-maybe))
         ((parse-note-maybe))
         (t
          (user-error "LOGBOOK drawer entry is neither a state change, nor a note"))))
      ;; (message "[org-astro--parse-logbook-entry DBG] logbook derived `date' : %S" (plist-get info :logbook-date))
      ;; (message "[org-astro--parse-logbook-entry DBG] logbook derived `lastmod' : %S" (plist-get info :logbook-lastmod))
      ;; (message "[org-astro--parse-logbook-entry DBG] logbook entry : %S" logbook-entry)
      nil)))

(defun org-astro-drawer (drawer contents info)
  "Transcode a DRAWER element from Org to appropriate Hugo front-matter.
CONTENTS holds the contents of the block.  INFO is a plist
holding contextual information."
  (let* ((drawer-name (org-element-property :drawer-name drawer))
         (parent-heading (catch 'found
                           (let ((el drawer))
                             (while t
                               (let ((p-el (org-export-get-parent el)))
                                 (when (or (null p-el)
                                           (equal 'headline (org-element-type p-el)))
                                   ;; Return when there's no parent element
                                   ;; or if the parent element is a `headline'.
                                   (throw 'found p-el))
                                 (setq el p-el))))))
         (parent-heading-title (org-astro--plainify-string
                                (org-element-property :title parent-heading)
                                info)))
    ;; (message "[org-astro-drawer DBG] parent-heading : %S" parent-heading)
    ;; (message "[org-astro-drawer DBG] parent-heading-title : %S" parent-heading-title))
    (cond
     ;; :LOGBOOK: Drawer
     ((equal drawer-name (org-log-into-drawer))
      ;; (message "[org-astro-drawer DBG] elem type: %s" (org-element-type drawer))
      ;; (drawer
      ;;   ..
      ;;   (plain-list
      ;;     (item
      ;;       (paragraph
      ;;         <State change text or Note>
      ;;         (timestamp <timestamp> )))))
      (org-element-map drawer 'plain-list
        (lambda (lst)
          (org-element-map lst 'item
            (lambda (item)
              (org-element-map item 'paragraph
                (lambda (para)
                  (org-astro--parse-logbook-entry para parent-heading-title info))
                nil :first-match)) ;Each 'item element will have only one 'paragraph element
            )) ;But a 'plain-list element can have multiple 'item elements, so loop through all
        nil :first-match) ;The 'logbook element will have only one 'plain-list element
      ;; Nothing from the LOGBOOK gets exported to the Markdown body
      "")
     ;; Other Org Drawers
     (t
      (org-html-drawer drawer contents info)))))

;;;; Example Block
(defun org-astro-example-block (example-block _contents info)
  "Transcode an EXAMPLE-BLOCK element into Markdown format.

CONTENTS is nil.  INFO is a plist holding contextual
information."
  (let* ((switches-str (org-element-property :switches example-block))
         ;; Below is a hack for allowing ":linenos <value>" parameter
         ;; in example block header, because the example-block Org
         ;; element parses only "-switches", not ":parameters".
         (linenos-style (and (org-string-nw-p switches-str)
                             (string-match ":linenos\\s-+\\([^ ]+\\)\\b" switches-str)
                             (match-string-no-properties 1 switches-str))))
    (org-element-put-property example-block :language "text")
    (org-element-put-property example-block :linenos-style linenos-style)
    (org-astro-src-block example-block nil info)))

;;;; Export Snippet
(defun org-astro-export-snippet (export-snippet _contents _info)
  "Transcode a EXPORT-SNIPPET object from Org to Hugo-compatible Markdown.
CONTENTS is nil.  INFO is a plist holding contextual information.

Example:

  \"@@astro:foo@@\"

exports verbatim to \"foo\" only when exported using `astro'
backend.

Export snippets with backend tags \"markdown:\" and \"md:\" are
also handled.  Exporting of export snippets with backend tag
\"html:\" uses the HTML exporter."
  (cond
   ((member (org-export-snippet-backend export-snippet) '(astro markdown md))
    ;; ox-md.el does not support export snippets, so let's handle
    ;; Markdown export snippets here as well.
    (org-element-property :value export-snippet))
   ;; Also include HTML export snippets.
   (t
    (org-export-with-backend 'html export-snippet nil nil))))

;;;; Export Block
(defun org-astro-export-block (export-block _contents _info)
  "Transcode a EXPORT-BLOCK element from Org to Hugo-compatible Markdown.
CONTENTS is nil.  INFO is a plist holding contextual information.

Example:

  #+begin_export astro
  foo
  #+end_export

exports verbatim to \"foo\" only when exported using `astro'
backend.

If the backend tag is \"markdown\"/\"md\" or \"html\", exporting
of those blocks falls back to the respective exporters."
  (cond
   ((string= (org-element-property :type export-block) "ASTRO")
    (org-remove-indentation (org-element-property :value export-block)))
   ;; Also include Markdown and HTML export blocks.
   ;; ox-md handles HTML export blocks too.
   (t
    (org-export-with-backend 'md export-block nil nil))))

;;;; Heading
(defun org-astro-heading (heading contents info)
  "Transcode HEADING element into Markdown format.
CONTENTS is the heading contents.  INFO is a plist used as
a communication channel."
  (unless (org-element-property :footnote-section-p heading)
    (let* ((numbers (org-astro--get-heading-number heading info nil))
           (loffset (string-to-number (plist-get info :astro-level-offset))) ;"" -> 0, "0" -> 0, "1" -> 1, ..
           (level (org-export-get-relative-level heading info))
           (level-effective (+ loffset level))
           (title (org-export-data (org-element-property :title heading) info)) ;`org-export-data' required
           (todo (and (org-astro--plist-get-true-p info :with-todo-keywords)
                      (org-element-property :todo-keyword heading)))
           (todo-fmtd (when todo
                        (concat (org-astro--todo todo info) " ")))
           (tags-fmtd (and (org-astro--plist-get-true-p info :with-tags)
                           (let* ((tags-list (org-export-get-tags heading info))
                                  (tags-list (dolist (fn org-astro-tag-processing-functions tags-list)
                                               (setq tags-list (funcall fn tags-list info))))
                                  (tags-html (org-astro--tags tags-list info)))
                             (when (org-string-nw-p tags-html)
                               (concat " " tags-html)))))
           (priority
            (and (org-astro--plist-get-true-p info :with-priority)
                 (let ((char (org-element-property :priority heading)))
                   (and char (format "[#%c] " char)))))
           (style (plist-get info :md-headline-style)))
      ;; (message "[ox-astro-heading DBG] num: %s" numbers)
      ;; (message "[ox-astro-heading DBG] with-tags: %S" (org-astro--plist-get-true-p info :with-tags))
      ;; (message "[ox-astro-heading DBG] tags: %S" (org-export-get-tags heading info))
      (cond
       ;; Cannot create a heading.  Fall-back to a list.
       ((or (org-export-low-level-p heading info)
            (not (memq style '(atx setext)))
            (and (eq style 'atx) (> level-effective 6))
            (and (eq style 'setext) (> level-effective 2)))
        (let ((bullet
               (if (not (org-export-numbered-headline-p heading info)) "-"
                 (concat (number-to-string
                          (car (last (org-export-get-headline-number
                                      heading info))))
                         ".")))
              (heading (concat todo-fmtd " " priority title))) ;Heading text without tags
          (concat "<!--list-separator-->\n\n"
                  ;; Above is needed just in case the body of the
                  ;; section above is ending with a plain list. That
                  ;; HTML comment will force-end the <ul> or <ol> tag
                  ;; of that preceding list.
                  bullet " " heading tags-fmtd "\n\n"
                  (and contents (replace-regexp-in-string "^" "    " contents)))))
       (t
        (let* ((anchor (when org-astro-headline-anchor
                         (format "{#%s}" (org-astro--get-anchor heading info)))) ;https://gohugo.io/extras/crossreferences/
               (heading-title (org-astro--heading-title style level loffset title
                                                       todo-fmtd tags-fmtd anchor numbers))
               (wrap-element (org-astro--container heading info))
               (content-str (or (org-string-nw-p contents) "")))
          (if wrap-element
              (let* ((container-class (or (org-element-property :HTML_CONTAINER_CLASS heading)
                                          (org-element-property :EXPORT_HTML_CONTAINER_CLASS heading)
                                          (plist-get info :html-container-class)))
                     (container-class-str (if (org-string-nw-p container-class)
                                              (concat " " container-class)
                                            container-class)))
                (format (concat "<%s class=\"outline-%d%s\">\n"
                                "%s%s\n"
                                "</%s>")
                        wrap-element level container-class-str
                        heading-title content-str
                        wrap-element))
            (format "%s%s" heading-title content-str))))))))

;;;;; Heading Helpers
(defun org-astro--container (heading info)
  "Get the HTML container element for HEADING.

INFO is a plist used as a communication channel.

If a heading has `:HTML_CONTAINER:' or `:EXPORT_HTML_CONTAINER:'
property, that is used for the container element.

Else if the `:html-container' property is a non-empty string:
  - For the top level headings, wrapping is done using that property.
  - For second and lower level headings, wrapping is done using
    the HTML <div> tags.

Else, no HTML element is wrapped around the HEADING."
  (or (org-element-property :HTML_CONTAINER heading) ;property of the immediate heading
      (org-element-property :EXPORT_HTML_CONTAINER heading) ;property of the immediate heading
      (and (org-string-nw-p (plist-get info :html-container)) ;inherited :html-container: property if any
           (if (or (plist-get info :html-container-nested)
                   (= 1 (org-export-get-relative-level heading info)))
               (plist-get info :html-container)
             "div"))))

;;;; GitHub slugger
;; Elisp port of the `github-slugger' npm package (ISC license,
;; https://github.com/Flet/github-slugger), which Astro uses to derive
;; content collection entry ids and Markdown heading anchors.  Keeping
;; the exact algorithm matters: slugs generated here must match the
;; ones Astro generates on its side so that `#anchors' in exported
;; links resolve on the built site.

(defconst org-astro--slug-keep-re "[[:alpha:][:digit:]]\\|_\\|-"
  "Regexp matching characters KEPT in slugs by github-slugger.
Characters not matching this are removed.  Emacs's `[:alpha:]'
and `[:digit:]' are Unicode-aware and cover non-ASCII letters
(Cyrillic, Han, ...) and combining marks as well; `_` and `-` are
kept verbatim, mirroring the generated removal regex in
github-slugger's regex.js (which excludes exactly 0x2D and 0x5F
from ASCII punctuation).")

(defvar org-astro--slug-occurrences nil
  "Hash table mapping base slug -> occurrence count.
Shared state for `org-astro-slug' deduplication, mirroring the
`occurrences' field of the GitHub slugger class.")

(defun org-astro--slug-reset ()
  "Forget all previously generated slugs.
Equivalent to calling `reset()' on a GitHub slugger instance."
  (setq org-astro--slug-occurrences (make-hash-table :test #'equal)))

;; Initialize the shared state at load time.
(org-astro--slug-reset)

(defun org-astro--slugify (value &optional maintain-case)
  "Return the stateless slug for string VALUE.

This is the `slug()' helper from github-slugger: lowercase VALUE
(unless MAINTAIN-CASE), remove characters that GitHub's slug
algorithm removes (keeping letters incl. non-ASCII, numbers,
`_`, `-` and other connector punctuation), and turn every space
into a hyphen.  No deduplication happens here."
  (let ((str (if (stringp value)
                 (if maintain-case value (downcase value))
               "")))
    ;; Rebuild string char by char:
    ;; - spaces become hyphens
    ;; - kept chars pass through
    ;; - everything else is removed
    ;; This mirrors value.replace(regex, '').replace(/ /g, '-')
    ;; in github-slugger's `slug()'.
    (mapconcat
     (lambda (ch)
       (cond
        ((= ch ?\s) "-")
        ((string-match-p org-astro--slug-keep-re (char-to-string ch))
         (char-to-string ch))
        ;; `[:digit:]' is ASCII-only in Emacs, but github-slugger keeps
        ;; all Unicode decimal digits (category Nd), e.g. Arabic-Indic.
        ((eq (get-char-code-property ch 'general-category) 'Nd)
         (char-to-string ch))
        (t "")))
     (string-to-list str)
     "")))

(defun org-astro-slug (value &optional _maintain-case)
  "Return a slug unique across this process, like GitHub does.

VALUE is the string to slugify.  Repeated calls with the same
base value append `-1', `-2', ... suffixes, and the counter also
advances when a generated slug (like `foo-1') collides with a
later input, exactly like github-slugger's `slug()' method.

The deduplication state is shared per-process; use
`org-astro--slug-reset' between exports if strict isolation is
needed."
  (let* ((base (org-astro--slugify value))
         (result base))
    (when (gethash base org-astro--slug-occurrences)
      (let ((n (1+ (gethash base org-astro--slug-occurrences))))
        (while (gethash result org-astro--slug-occurrences)
          (setq result (format "%s-%d" base n)
                n (1+ n)))
        (puthash base (1- n) org-astro--slug-occurrences)))
    (puthash result 0 org-astro--slug-occurrences)
    result))

;;;###autoload
(defun org-astro--hugo-slug (str &optional allow-double-hyphens)
  "Convert string STR to a `slug' and return that string.

A `slug' is the part of a URL which identifies a particular page
on a website in an easy to read form.

Example: If STR is \"My First Post\", it will be converted to a
slug \"my-first-post\", which can become part of an easy to read
URL like \"https://example.com/posts/my-first-post/\".

In general, STR is a string.  But it can also be a string with
Markdown markup because STR is often a post's sub-heading (which
can contain bold, italics, link, etc markup).

The `slug' generated from that STR follows these rules:

- Contain only lower case alphabet, number and hyphen characters
  ([[:alnum:]-]).
- Not have *any* HTML tag like \"<code>..</code>\",
  \"<span class=..>..</span>\", etc.
- Not contain any URLs (if STR happens to be a Markdown link).
- Replace \".\" in STR with \"dot\", \"&\" with \"and\",
  \"+\" with \"plus\".
- Replace parentheses with double-hyphens.  So \"foo (bar) baz\"
  becomes \"foo--bar--baz\".
- Replace non [[:alnum:]-] chars with spaces, and then one or
  more consecutive spaces with a single hyphen.
- If ALLOW-DOUBLE-HYPHENS is non-nil, at most two consecutive
  hyphens are allowed in the returned string, otherwise consecutive
  hyphens are not returned.
- No hyphens allowed at the leading or trailing end of the slug."
  (let* (;; All lower-case
         (str (downcase str))
         ;; Remove "<FOO>..</FOO>" HTML tags if present.
         (str (replace-regexp-in-string "<\\(?1:[a-z]+\\)[^>]*>.*</\\1>" "" str))
         ;; Remove URLs if present in the string.  The ")" in the
         ;; below regexp is the closing parenthesis of a Markdown
         ;; link: [Desc](Link).
         (str (replace-regexp-in-string (concat "\\](" ffap-url-regexp "[^)]+)") "]" str))
         ;; Replace "&" with " and ", "." with " dot ", "+" with
         ;; " plus ".
         (str (replace-regexp-in-string
               "&" " and "
               (replace-regexp-in-string
                "\\." " dot "
                (replace-regexp-in-string
                 "\\+" " plus " str))))
         ;; Replace all characters except alphabets, numbers and
         ;; parentheses with spaces.
         (str (replace-regexp-in-string "[^[:alnum:]()]" " " str))
         ;; On emacs 24.5, multibyte punctuation characters like "："
         ;; are considered as alphanumeric characters! Below evals to
         ;; non-nil on emacs 24.5:
         ;;   (string-match-p "[[:alnum:]]+" "：")
         ;; So replace them with space manually..
         (str (if (version< emacs-version "25.0")
                  (let ((multibyte-punctuations-str "：")) ;String of multibyte punctuation chars
                    (replace-regexp-in-string (format "[%s]" multibyte-punctuations-str) " " str))
                str))
         ;; Remove leading and trailing whitespace.
         (str (replace-regexp-in-string "\\(^[[:space:]]*\\|[[:space:]]*$\\)" "" str))
         ;; Replace 2 or more spaces with a single space.
         (str (replace-regexp-in-string "[[:space:]]\\{2,\\}" " " str))
         ;; Replace parentheses with double-hyphens.
         (str (replace-regexp-in-string "\\s-*([[:space:]]*\\([^)]+?\\)[[:space:]]*)\\s-*" " -\\1- " str))
         ;; Remove any remaining parentheses character.
         (str (replace-regexp-in-string "[()]" "" str))
         ;; Replace spaces with hyphens.
         (str (replace-regexp-in-string " " "-" str))
         ;; Remove leading and trailing hyphens.
         (str (replace-regexp-in-string "\\(^[-]*\\|[-]*$\\)" "" str)))
    (unless allow-double-hyphens
      (setq str (replace-regexp-in-string "--" "-" str)))
    str))

(defun org-astro-get-page-or-bundle-name (element info)
  "Return ELEMENT's slug based on `:EXPORT_FILE_NAME' and `:EXPORT_ASTRO_BUNDLE'.

If the \"slug\" of the element is \"section/post\", return
\"post\".

Return nil if ELEMENT doesn't have the EXPORT_FILE_NAME property
set.

INFO is a plist used as a communication channel."
  (let ((slug (org-astro--heading-get-slug element info nil)))
    (when (org-string-nw-p slug)
      (file-name-base slug))))

(defun org-astro-get-custom-id (element &optional _info)
  "Return ELEMENT's `:CUSTOM_ID' property.

Return nil if ELEMENT doesn't have the CUSTOM_ID property set."
  (org-string-nw-p (org-element-property :CUSTOM_ID element)))

(defun org-astro-get-id (&optional element _info)
  "Return the value of `:ID' property for ELEMENT.

Return nil if id is not found."
  (let ((element-begin (org-element-property :begin element)))
    (save-excursion
      (goto-char element-begin)
      (org-id-get))))

(defun org-astro-get-heading-slug (element info)
  "Return the slug string derived from an Org heading ELEMENT.

The slug string is parsed from the ELEMENT's `:title' property.

INFO is a plist used as a communication channel.

Return nil if ELEMENT's `:title' property is nil or an empty string."
  (let ((title (org-export-data-with-backend
                (org-element-property :title element) 'md info)))
    (org-string-nw-p (org-astro--hugo-slug title :allow-double-hyphens))))

(defun org-astro-get-md5 (element info)
  "Return md5 sum derived string using ELEMENT's title property.

INFO is a plist used as a communication channel.

This function will never return nil."
  (let ((hash-len 6)
        (title (or (org-string-nw-p (org-export-data-with-backend
                                     (org-element-property :title element) 'md info))
                   "")))
    (substring (md5 title) 0 hash-len)))

(defun org-astro--get-elem-with-prop (prop &optional pom _info)
  "Find the first element with PROP property in the current tree.

PROP is a property symbol with a : prefix, example:
`:EXPORT_FILE_NAME'.

Optional argument POM is the position or marker from which the
upward search for PROP should begin.

Return a cons of type (ELEM . PVAL) where ELEM is the element
containing the property PROP and PVAL is the property's value.

Return nil if the PROP is not found or if the PVAL is nil.

This function is created as a workaround for Org 9.5 and older
versions for the issue that `org-element-at-point' does not
return an element with all the inherited properties.  That issue
is fixed in Org main branch at least as of 2022-03-17."
  (org-with-wide-buffer
   ;; (message (format "[search prop DBG] point 1 : %S" (point)))
   (when pom
     (goto-char pom))
   ;; (message (format "[search prop DBG] point 2 : %S" (point)))
   (org-back-to-heading-or-point-min :invisible-ok)
   (let ((elem (org-element-at-point))
         (level t)
         pval)
     (catch :found
       (while elem
         ;; (message (format "[search prop DBG] prop %S, elem : %S" prop elem))
         (setq pval (org-element-property prop elem))
         ;; (message "[search prop DBG] level %S, pval %S" level pval)
         (when (or pval (null level))
           (if (null pval)
               ;; There's probably no value to distinguish
               ;; between the case where a property is not
               ;; found, or the case where the property
               ;; value is nil. Revisit this if that
               ;; changes.
               (throw :found nil)
             (throw :found (cons elem pval))))
         (setq level (org-up-heading-safe))
         (setq elem (org-element-at-point)))))))

(defun org-astro--heading-get-slug (heading info &optional inherit-export-file-name)
  "Return the slug string derived from an Org HEADING element.

1. If HEADING has only `:EXPORT_FILE_NAME' and it's not a Hugo
   page bundle, use that property as slug.

2. If HEADING has a `:EXPORT_FILE_NAME' property, and its value
   is either \"index\" or \"_index\", use `:EXPORT_ASTRO_BUNDLE'
   to derive the slug.  \"index\" subtree is a Leaf Bundle, and
   \"_index\" subtree is a Branch Bundle.

3. If HEADING has a `:EXPORT_FILE_NAME' property, and its value
   is neither \"index\" nor \"_index\", use that to derive the
   slug.

If INHERIT-EXPORT-FILE-NAME is non-nil, allow inheriting the
`:EXPORT_FILE_NAME' property from a parent subtree.

The `:EXPORT_ASTRO_SECTION' property or `#+hugo_section' keyword
value is prepended to all of the above options.

INFO is a plist used as a communication channel.

Return nil if none of the above are true."
  (org-with-wide-buffer
   (let ((heading-begin (org-element-property :begin heading)))
     (when heading-begin
       (goto-char heading-begin)))
   (let ((file (org-string-nw-p (org-export-get-node-property :EXPORT_FILE_NAME heading inherit-export-file-name)))
         bundle slug)
     ;; (message "[org-astro--heading-get-slug DBG] EXPORT_FILE_NAME: %S" file)
     (when file
       (setq bundle (let* ((elem-pval (org-astro--get-elem-with-prop :EXPORT_ASTRO_BUNDLE))
                           (pval (when elem-pval
                                   (cdr elem-pval))))
                      pval))

       (cond
        ;; Leaf or branch bundle landing page.
        ((and bundle file (member file '("index" ;Leaf bundle
                                         "_index" ;Branch bundle
                                         )))
         (setq slug bundle)
         ;; (message "[org-astro--heading-get-slug DBG] bundle slug: %S" slug)
         )
        ;; It's a Hugo page bundle, but the file is neither index nor
        ;; _index. So likely a page in a branch bundle.
        ((and bundle file)
         (setq slug (concat (file-name-as-directory bundle) file))
         ;; (message "[org-astro--heading-get-slug DBG] branch bundle file slug: %S" slug)
         )
        ;; Not a Hugo page bundle.
        (t
         (setq slug file)))

       ;; Prefix with section and fragmented sections if any.
       (let ((pheading heading)
             section fragment fragments)
         (setq section (org-string-nw-p
                        (or (org-export-get-node-property :EXPORT_ASTRO_SECTION heading :inherited)
                            (plist-get info :astro-section))))

         ;; Iterate over all parents of heading, and collect section
         ;; path fragments.
         (while (and pheading
                     (not (org-export-get-node-property :EXPORT_ASTRO_SECTION pheading nil)))
           ;; Add the :EXPORT_ASTRO_SECTION_FRAG value to the fragment list.
           (when (setq fragment (org-export-get-node-property :EXPORT_ASTRO_SECTION_FRAG pheading nil))
             (push fragment fragments))
           (setq pheading (org-element-property :parent pheading)))

         (when section
           (setq slug (concat (file-name-as-directory section)
                              (mapconcat #'file-name-as-directory fragments "")
                              slug)))
         ;; (message "[org-astro--heading-get-slug DBG] section: %S" section)
         ;; (message "[org-astro--heading-get-slug DBG] section + slug: %S" slug)
         ))
     ;; (message "[org-astro--heading-get-slug DBG] FINAL slug: %S" slug)
     slug)))

(defun org-astro--get-anchor(element info)
  "Return anchor string for Org heading ELEMENT.

The anchor is derived using the first function that returns a
non-nil value (a string) from the list
`org-astro-anchor-functions'.

INFO is a plist used as a communication channel.

Return an empty string if all functions in
`org-astro-anchor-functions' return nil."
  (or (seq-some
       (lambda (fn) (funcall fn element info))
       org-astro-anchor-functions)
      ""))

(defun org-astro--heading-title (style level loffset title &optional todo tags anchor numbers)
  "Generate a heading title in the preferred Markdown heading style.

STYLE is the preferred style (`atx' or `setext').
LEVEL is the header level.
LOFFSET is the offset (a non-negative number) that is added to the
Markdown heading level for `atx' style.
TITLE is the heading title.

Optional argument TODO is the Org TODO string.

Optional argument TAGS is a string containing the current
heading's tags.

Optional argument ANCHOR is the Hugo anchor tag for the section as a
string.

Optional argument NUMBERS, if non-nil, is an htmlized string
containing the TITLE's number."
  (let ((heading (concat todo numbers title tags " " anchor "\n")))
    ;; Use "Setext" style
    (if (and (eq style 'setext) (< level 3))
        (let* ((underline-char (if (= level 1) ?= ?-))
               (underline (concat (make-string (length heading) underline-char)
                                  "\n")))
          (concat "\n" heading underline "\n"))
      ;; Use "Atx" style
      ;; Always translate level N Org heading to level N+1 Markdown
      ;; heading because Markdown level 1 heading and HTML title both
      ;; get the HTML <h1> tag, and we do not want the top-most heading
      ;; of a post to look the exact same as the post's title.
      (let ((level-mark (make-string (+ loffset level) ?#)))
        (concat "\n" level-mark " " heading "\n")))))

;;;; Inner Template
(defun org-astro-inner-template (contents info)
  "Return body of document after converting it to Hugo-compatible Markdown.
CONTENTS is the transcoded contents string.  INFO is a plist
holding export options."
  (let* ((toc-level (plist-get info :with-toc))
         (toc-level (if (and toc-level
                             (not (wholenump toc-level)))
                        (plist-get info :headline-levels)
                      toc-level))
         (toc (if (and toc-level
                       (wholenump toc-level)
                       (> toc-level 0)) ;TOC will be exported only if toc-level is positive
                  (concat (org-astro--build-toc info toc-level) "\n")
                ""))
         ;; Handling the case of special blocks inside markdown quote
         ;; blocks.
         (contents (replace-regexp-in-string
                    (concat "\\(\n\\s-*> \\)*" (regexp-quote org-astro--trim-pre-marker))
                    ;;          ^^^^^^^^ Markdown quote blocks have lines beginning with "> ".
                    org-astro--trim-pre-marker ;Keep the trim marker; it will be removed next.
                    contents))
         (contents (replace-regexp-in-string
                    (concat "\\([[:space:]]\\|\n\\)*" (regexp-quote org-astro--trim-pre-marker))
                    "\n"
                    contents))
         (contents (replace-regexp-in-string ;Trim stuff after selected exported elements
                    (concat (regexp-quote org-astro--trim-post-marker)
                            ;; Pull up the contents from the next
                            ;; line, unless the next line is a list
                            ;; item (-), a heading (#) or a code block
                            ;; (`).
                            "\\([[:space:]>]\\|\n\\)+\\([^-#`]\\)")
                    " \\2" contents)))

    ;; (message "[org-astro-inner-template DBG] toc-level: %s" toc-level)
    (string-trim-left ;Remove any extra blank lines between front-matter and the content #consistency
     (concat
      toc
      contents
      ;; Make sure CONTENTS is separated from table of contents
      ;; and footnotes with at least a blank line.
      "\n"
      (org-astro-footnote-section info)))))

;;;; Inline Src Block
(defun org-astro-inline-src-block (inline-src-block _contents _info)
  "Transcode INLINE-SRC-BLOCK object into HTML."
  (let* ((lang (org-element-property :language inline-src-block)))
    (format "<span class=\"inline-src language-%s\" data-lang=\"%s\">%s</span>"
            lang lang
            (org-md-verbatim inline-src-block nil nil))))

;;;; Keyword
(defun org-astro-keyword (keyword contents info)
  "Transcode a KEYWORD element into Hugo-compatible Markdown format.
CONTENTS is nil.  INFO is a plist used as a communication
channel."
  (let ((kwd (org-element-property :key keyword))
        (value (org-element-property :value keyword)))
    (cond
     ((and (equal "HUGO" kwd))
      (if (and (stringp value)          ;Hugo summary splitting
               (string-match-p "\\`\\s-*more\\s-*\\'" value))
          (progn
            ;; https://gohugo.io/content-management/summaries#user-defined-manual-summary-splitting
            "<!--more-->")
        (progn
          value)))
     ((and (equal "TOC" kwd)
           (string-match-p "\\<headlines\\>" value))
      (let* ((depth (and (string-match "\\<[0-9]+\\>" value)
                         (string-to-number (match-string 0 value))))
             (local? (string-match-p "\\<local\\>" value))
             (scope                     ;From `org-md-keyword'
              (cond
               ((string-match ":target +\\(\".+?\"\\|\\S-+\\)" value) ;link
                (org-export-resolve-link
                 (org-strip-quotes (match-string 1 value)) info))
               (local? keyword))))
        (when (and depth
                   (> depth 0))
          (let ((toc-str (org-astro--build-toc info depth scope local?)))
            (when toc-str
              (org-remove-indentation toc-str))))))
     (t
      (org-md-keyword keyword contents info)))))

;;;; Links
(defun org-astro--get-coderef-anchor-prefix (el)
  "Get anchor prefix string for code refs in element EL.

Return a cons (CODE-REFS . ANCHOR-PREFIX) where

- CODE-REFS is an alist of the type (LINENUM . LABEL) where

  LINENUM is the line number where the code referenced labeled
  LABEL was found.  LABEL is a string.

- ANCHOR-PREFIX is a string.

Return nil if EL has no code references."
  (let ((prefix "org-coderef")
        (hash-len 6)
        (code-refs (cdr (org-export-unravel-code el))))
    (when code-refs
      (let* ((unique-id (substring
                         (md5 (format "%s" code-refs)) 0 hash-len))
             (anchor-prefix (format "%s--%s" prefix unique-id)))
        (cons code-refs anchor-prefix)))))

(defun org-astro-link--resolve-coderef (ref info)
  "Resolve a code reference REF.

This function is heavily derived from
`org-export-resolve-coderef'.

INFO is a plist used as a communication channel.

Return a plist with these elements:

- `:line-num' :: REF associated line number

- `:ref' :: REF associated line number in source code (if the Org
  element's `:use-labels' property is unset.  This happens when
  the `-r' switch is used) , or REF itself.

- `:anchor-prefix' :: String prefix for REF's anchor.

Throw an error if no block contains REF."
  (or (org-element-map (plist-get info :parse-tree) '(example-block src-block)
        (lambda (el)
          (with-temp-buffer
            (insert (org-trim (org-element-property :value el)))
            (let* ((ref-info ())
                   (label-fmt (or (org-element-property :label-fmt el)
                                  org-coderef-label-format))
                   (ref-re (org-src-coderef-regexp label-fmt ref)))
              ;; Element containing REF is found.  Resolve it to
              ;; either a label or a line number, as needed.
              (when (re-search-backward ref-re nil :noerror)
                (let* ((line-num (+ (or (org-export-get-loc el info) 0)
                                    (line-number-at-pos)))
                       (ref-str (format "%s" (if (org-element-property :use-labels el)
                                                 ref
                                               line-num))))
                  (setq ref-info (plist-put ref-info :line-num line-num))
                  (setq ref-info (plist-put ref-info :ref ref-str))
                  (let ((anchor-prefix (or (org-element-property :anchor-prefix el) ;set in `org-astro-src-block'
                                           (cdr (org-astro--get-coderef-anchor-prefix el)))))
                    (setq ref-info (plist-put ref-info :anchor-prefix anchor-prefix))))
                ref-info))))
        info 'first-match)
      (signal 'org-link-broken (list ref))))

(defun org-astro--org-mode-light ()
  "Enable set current buffer's `major-mode' to `org-mode' quickly.

It is necessary for the `major-mode' to be `org-mode' for many
functions like `org-link-search'."
  (unless (derived-mode-p 'org-mode)
    (let ((inhibit-modification-hooks t)
          (org-mode-hook nil)   ;Don't run any Org mode hook functions
          (org-inhibit-startup t)) ;Don't run any Org buffer startup functions
      (org-mode))))

(defun org-astro--get-anchor-at-point (info)
  "Return anchor string based on the current point.

If point is in a `headline' element, derive the anchor using
`org-astro--get-anchor'.

Otherwise, if the current point has an Org target, get the target
anchor.

If current element has `:EXPORT_FILE_NAME' property, return the
anchor as-is, otherwise prefix the anchor string with \"#\".

Return an empty string if an anchor cannot be derived.

INFO is a plist used as a communication channel."
  (let ((elem (org-element-at-point))
        (anchor ""))
    (cond
     ((equal (org-element-type elem) 'headline)
      (setq anchor (org-astro--get-anchor elem info)))
     (t
      ;; If current point has an Org Target, get the target anchor.
      (let ((target-elem (org-element-target-parser)))
        (when (equal (org-element-type target-elem) 'target)
          (setq anchor (org-astro--get-target-anchor target-elem))))))
    (when (org-string-nw-p anchor)
      ;; If the element has the `:EXPORT_FILE_NAME' it's not a
      ;; sub-heading, but the subtree's main heading.  Don't prefix
      ;; the "#" in that case.
      (unless (org-export-get-node-property :EXPORT_FILE_NAME elem nil)
        (setq anchor (format "#%s" anchor))))
    ;; (message "[search and get anchor DBG] anchor: %S" anchor)
    anchor))

(defun org-astro--search-and-get-anchor (org-file search-str info)
  "Return HTML anchor for the point where SEARCH-STR is found in ORG-FILE.

ORG-FILE is the file path in which the SEARCH-STR is to be searched.

SEARCH-STR needs to be a non-empty string.  Example values: \"*
Some heading\", \"#some_custom_id\".

If the search fails, return \"\".

INFO is a plist used as a communication channel."
  ;; (message "[search and get anchor DBG] org-file: %S" org-file)
  ;; (message "[search and get anchor DBG] search-str: %S" search-str)
  (let ((buffer (get-file-buffer org-file))) ;nil if `org-file' buffer is not already open
    (unless (file-exists-p org-file)
      (error "[org-astro--search-and-get-anchor] Unable to open Org file `%s'" org-file))
    (with-current-buffer (find-file-noselect org-file)
      (unless buffer
        (add-to-list 'org-astro--opened-buffers (current-buffer)))
      ;; `org-mode' needs to be loaded for `org-link-search' to work
      ;; correctly. Otherwise `org-link-search' returns starting
      ;; points for incorrect subtrees.
      (org-astro--org-mode-light)
      (org-export-get-environment) ;Eval #+bind keywords, etc.
      (org-link-search search-str) ;This is extracted from the `org-open-file' function.
      (org-astro--get-anchor-at-point info))))

(defun org-astro-link (link desc info)
  "Convert LINK to Markdown format.

DESC is the link's description.
INFO is a plist used as a communication channel.

Unlike `org-md-link', this function will also copy local images
and rewrite link paths to make blogging more seamless."
  (let* ((raw-link (org-element-property :raw-link link))
         (raw-path (org-element-property :path link))
         (type (org-element-property :type link))
         (link-is-url (member type '("http" "https" "ftp" "mailto")))
         (roam-slug (and (string= type "id")
                         (stringp raw-path)
                         (cadr (assoc raw-path (org-astro--roam-table))))))
    ;; (message "[org-astro-link DBG] raw-path 1: %s" raw-path)

    (when (and (stringp raw-path)
               link-is-url)
      (setq raw-path (org-astro--url-sanitize-maybe
                      info (url-encode-url raw-path))))
    ;; (message "[org-astro-link DBG] raw-link: %s" raw-link)
    ;; (message "[org-astro-link DBG] raw-path 2: %s" raw-path)
    ;; (message "[org-astro-link DBG] link: %S" link)
    ;; (message "[org-astro-link DBG] link type: %s" type)
    (cond
     ;; org-roam: an `id:' link to a sibling export unit of this buffer
     ;; becomes a plain link to that unit's Astro content-collection
     ;; page (/blog/<slug>/).  Ids outside the roam table (other files,
     ;; non-post headings) keep Org's own resolution further down.
     (roam-slug
      (let ((href (concat "/blog/" roam-slug "/")))
        (if (org-string-nw-p desc)
            (format "[%s](%s)" desc href)
          (format "<%s>" href))))
     ;; Link type is handled by a special function.
     ((org-export-custom-protocol-maybe link desc 'md info))
     ((member type '("custom-id" "id"
                     "fuzzy")) ;<<target>>, #+name, heading links
      (let ((destination (if (string= type "fuzzy")
                             (org-export-resolve-fuzzy-link link info)
                           (org-export-resolve-id-link link info))))
        ;; (message "[org-astro-link DBG] link type: %s" type)
        ;; (message "[org-astro-link DBG] destination: %s" destination)
        ;; (message "[org-astro-link DBG] link: %S" link)
        ;; (message "[org-astro-link DBG] link destination elem type: %S" (org-element-type destination))
        (pcase (org-element-type destination)
          ;; External file.
          (`plain-text
           (let ((path (progn
                         ;; Treat links to `file.org' as links to `file.md'.
                         (if (string= ".org" (downcase (file-name-extension destination ".")))
                             (concat (file-name-sans-extension destination) ".md")
                           destination))))
             ;; (message "[org-astro-link DBG] plain-text path: %s" path)
             (if (org-id-find-id-file raw-path)
                 (let* ((anchor (org-astro-link--heading-anchor-maybe link info))
                        (ref (if (and (org-string-nw-p anchor)
                                      (not (string-prefix-p "#" anchor)))
                                 ;; If the "anchor" doesn't begin with
                                 ;; "#", it's a direct reference to a
                                 ;; post subtree.
                                 anchor
                               (concat path anchor))))
                   ;; (message "[org-astro-link DBG] plain-text org-id anchor: %S" anchor)
                   (format "[%s]({{< relref \"%s\" >}})" (or desc path) ref))
               (if desc
                   (format "[%s](%s)" desc path)
                 (format "<%s>" path)))))
          ;; Links of type [[* Some heading]].
          (`headline
           (let ((title (org-export-data (org-element-property :title destination) info)))
             (format
              "[%s](#%s)"
              ;; Description
              (cond ((org-string-nw-p desc))
                    ((org-export-numbered-headline-p destination info)
                     (mapconcat #'number-to-string
                                (org-export-get-headline-number destination info)
                                "."))
                    (t
                     title))
              ;; Reference
              (org-astro--get-anchor destination info))))
          ;; Links to other Org elements like source blocks, tables,
          ;; paragraphs, standalone figures, <<target>> links, etc.
          (_
           (let ((description
                  (or (org-string-nw-p desc)
                      (let ((number (org-export-get-ordinal
                                     destination info
                                     nil #'org-html--has-caption-p)))
                        (when number
                          (let ((num-str (if (atom number)
                                             (number-to-string number)
                                           (mapconcat #'number-to-string number "."))))
                            ;; (message "[org-astro-link DBG] num-str: %s" num-str)
                            (if org-astro-link-desc-insert-type
                                (let* ((type (org-element-type destination))
                                       ;; Org doesn't have a specific
                                       ;; element for figures. So if
                                       ;; the element is `paragraph',
                                       ;; and as this element has an
                                       ;; ordinal, we will assume that
                                       ;; to be a figure.
                                       (type (if (equal 'paragraph type)
                                                 'figure
                                               type))
                                       (type-str (org-astro--translate type info)))
                                  (format "%s %s" type-str num-str))
                              num-str)))))))
             ;; (message "[org-astro-link DBG] link description: %s" description)
             (when description
               (let ((dest-link (cond
                                 ;; Ref to a source block or table.
                                 ((memq (org-element-type destination) '(src-block table))
                                  (org-astro--get-reference destination))
                                 ;; Ref to a standalone figure.
                                 ((and (org-html-standalone-image-p destination info)
                                       (eq (org-element-type destination) 'paragraph))
                                  (let ((figure-ref (org-astro--get-reference destination)))
                                    (if (org-string-nw-p figure-ref)
                                        (replace-regexp-in-string
                                         "\\`org-paragraph--"
                                         (org-astro--get-ref-prefix 'figure)
                                         figure-ref)
                                      (org-export-get-reference destination info))))
                                 ;; Ref to a <<target>>.
                                 ((eq (org-element-type destination) 'target)
                                  (org-astro--get-target-anchor destination))
                                 ;; Ref to all other link destinations.
                                 (t
                                  (org-export-get-reference destination info)))))
                 (format "[%s](#%s)" description dest-link))))))))
     ((org-export-inline-image-p link org-html-inline-image-rules)
      ;; (message "[org-astro-link DBG] processing an image: %s" desc)
      (let* ((parent (org-export-get-parent link))
             (parent-type (org-element-type parent))
             ;; If this is a hyper-linked image, it's parent type will
             ;; be a link too. Get the parent of *that* link in that
             ;; case.
             (grand-parent (when (eq parent-type 'link)
                             (org-export-get-parent parent)))
             (useful-parent (if grand-parent
                                grand-parent
                              parent))
             (attr (org-export-read-attribute :attr_html useful-parent))
             (caption (or
                       ;; Caption set using #+caption takes higher precedence.
                       (org-string-nw-p
                        (org-export-data  ;Look for caption set using #+caption
                         (org-export-get-caption (org-export-get-parent-element link))
                         info))
                       (plist-get attr :caption)))
             (caption (when (org-string-nw-p caption)
                        (format "%s%s%s%s"
                                "<span class=\"figure-number\">"
                                (format (org-html--translate
                                         (concat
                                          (cdr (assoc 'figure org-astro--org-element-string))
                                          " %d:")
                                         info)
                                        (org-export-get-ordinal
                                         useful-parent info
                                         nil #'org-html--has-caption-p))
                                " </span>"
                                caption)))
             (extension (file-name-extension raw-path))
             (inlined-svg (and (stringp extension)
                               (string= "svg" (downcase extension))
                               (plist-get attr :inlined))))
        ;; (message "[org-astro-link DBG] Inline image: %s, extension: %s" raw-path extension)
        ;; (message "[org-astro-link DBG] inlined svg? %S" inlined-svg)
        ;; (message "[org-astro-link DBG] caption: %s" caption)
        (if inlined-svg
            (let* ((svg-contents (with-temp-buffer
                                   (insert-file-contents raw-path)
                                   (fill-region (point-min) (point-max)) ;Make huge one-liner SVGs sane
                                   (buffer-substring-no-properties (point-min) (point-max))))
                   (svg-contents-sanitized (replace-regexp-in-string
                                            ;; Remove the HTML comments.
                                            "<!--\\(.\\|\n\\)*?-->" ""
                                            (replace-regexp-in-string
                                             ;; Remove the xml document tag as that cannot be inlined in-between
                                             ;; a Markdown (or even an HTML) file.
                                             "<\\?xml version=\"1\\.0\" encoding=\"UTF-8\" standalone=\"no\"\\?>" ""
                                             ;; Remove !DOCTYPE tag from the inlined SVG.
                                             (replace-regexp-in-string
                                              "<!DOCTYPE svg[^>]+>" ""
                                              svg-contents))))
                   (svg-html (if caption
                                 (format "<figure>\n%s\n<figcaption>\n\n  %s\n</figcaption>\n</figure>"
                                         svg-contents-sanitized caption)
                               svg-contents-sanitized)))
              ;; (message "[org-astro-link DBG] svg contents: %s" svg-contents)
              ;; (message "[org-astro-link DBG] svg contents sanitized: %s" svg-contents-sanitized)
              svg-html)
          (let* ((path (org-astro--attachment-rewrite-maybe raw-path info))
                 (inline-image (not (org-html-standalone-image-p useful-parent info)))
                 (source (if link-is-url
                             (concat type ":" path)
                           path))
                 (num-attr (/ (length attr) 2)) ;(:alt foo) -> num-attr = 1
                 (alt-text (plist-get attr :alt)))
            ;; (message "[org-astro-link DBG] path: %s" path)
            ;; (message "[org-astro-link DBG] inline image? %s" inline-image)
            ;; (message "[org-astro-link DBG] attr: %s num of attr: %d"
            ;;          attr (length attr))
            ;; (message "[org-astro-link DBG] parent-type: %s" parent-type)
            ;; (message "[org-astro-link DBG] useful-parent-type: %s"
            ;;          (org-element-type useful-parent))
            (cond
             (;; Use the Markdown image syntax if the image is inline and
              ;; there are no HTML attributes for the image, or just one
              ;; attribute, the `alt-text'.
              (and inline-image
                   (or (= 0 num-attr)
                       (and alt-text
                            (= 1 num-attr))))
              (let ((alt-text (if alt-text
                                  alt-text
                                "")))
                (format "![%s](%s)" alt-text source)))
             (;; Else if the image is inline (with non-alt-text
              ;; attributes), use HTML <img> tag syntax.
              inline-image
              ;; The "target" and "rel" attributes would be meant for <a>
              ;; tags. So do not pass them to the <img> tag.
              (plist-put attr :target nil)
              (plist-put attr :rel nil)
              (org-html--format-image source attr info))
             (t ;Else use the Hugo `figure' shortcode.
              ;; Hugo `figure' shortcode named parameters.
              ;; https://gohugo.io/content-management/shortcodes/#figure
              (let ((figure-params `((src . ,source)
                                     (alt . ,alt-text)
                                     (caption . ,(when (org-string-nw-p caption)
                                                   (replace-regexp-in-string "\"" "\\\\\\&" caption))) ;Escape the double-quotes, if any.
                                     (link . ,(plist-get attr :link))
                                     (title . ,(plist-get attr :title))
                                     (class . ,(plist-get attr :class))
                                     (attr . ,(plist-get attr :attr))
                                     (attrlink . ,(plist-get attr :attrlink))
                                     (width . ,(plist-get attr :width))
                                     (height . ,(plist-get attr :height))
                                     ;; While the `target' and `rel'
                                     ;; attributes are not supported by
                                     ;; the inbuilt Hugo `figure'
                                     ;; shortcode, they can be used as
                                     ;; intended if a user has a custom
                                     ;; `figure' shortcode with the
                                     ;; support added for those.
                                     (target . ,(plist-get attr :target))
                                     (rel . ,(plist-get attr :rel))))
                    (figure-param-str ""))
                (dolist (param figure-params)
                  (let ((name (car param))
                        (val (cdr param)))
                    (when val
                      (setq figure-param-str (concat figure-param-str
                                                     (format "%s=\"%s\" "
                                                             name val))))))
                ;; (message "[org-astro-link DBG] figure params: %s" figure-param-str)
                (format "{{< figure %s >}}" (org-trim figure-param-str)))))))))
     ((string= type "coderef")
      (let* ((ref-label (org-element-property :path link))
             (ref-info (org-astro-link--resolve-coderef ref-label info))
             (desc (format (org-export-get-coderef-format ref-label desc)
                           (plist-get ref-info :ref))))
        ;; (message "[org-astro-link DBG] coderef ref label: %s" ref-label)
        ;; (message "[org-astro-link DBG] coderef ref str: %s" (plist-get ref-info :ref))
        ;; (message "[org-astro-link DBG] coderef anchor prefix: %s" (plist-get ref-info :anchor-prefix))
        ;; (message "[org-astro-link DBG] coderef line num: %s" (plist-get ref-info :line-num))
        ;; (message "[org-astro-link DBG] coderef desc: %s" desc)
        (format "[%s](#%s-%s)"
                desc
                (plist-get ref-info :anchor-prefix)
                (plist-get ref-info :line-num))))
     ((string= type "radio")
      (let ((destination (org-export-resolve-radio-link link info)))
        (format "[%s](#%s%s)"
                desc
                (org-astro--get-ref-prefix 'radio)
                (org-astro--valid-html-anchor-name
                 (org-element-property :value destination)))))
     (t ;[[file:foo.png]], [[file:foo.org::* Heading]], [[file:foo.org::#custom-id]], link type: file
      (let* ((link-param-str "")
             (path (cond
                    (link-is-url
                     ;; Taken from ox-html.el -- Extract attributes
                     ;; from parent's paragraph.  HACK: Only do this
                     ;; for the first link in parent (inner image link
                     ;; for inline images).  This is needed as long as
                     ;; attributes cannot be set on a per link basis.
                     (let* ((attr
                             (let ((parent (org-export-get-parent-element link)))
                               (and (eq (org-element-map parent 'link #'identity info :first-match) link)
                                    (org-export-read-attribute :attr_html parent))))
                            ;; https://www.w3schools.com/tags/tag_link.asp
                            (link-params `((title . ,(plist-get attr :title))
                                           (style . ,(plist-get attr :style))
                                           (referrerpolicy . ,(plist-get attr :referrerpolicy))
                                           (media . ,(plist-get attr :media))
                                           (target . ,(plist-get attr :target))
                                           (rel . ,(plist-get attr :rel))
                                           (sizes . ,(plist-get attr :sizes))
                                           (type . ,(plist-get attr :type)))))
                       (dolist (param link-params)
                         (let ((name (car param))
                               (val (cdr param)))
                           (when val
                             (setq link-param-str (concat link-param-str
                                                          (format "%s=\"%s\" "
                                                                  name val))))))
                       ;; (message "[org-astro-link DBG] link params: %s" link-param-str)
                       )
                     (concat type ":" raw-path))
                    (;; Remove the "file://" prefix.
                     (string= type "file")
                     ;; (message "[org-astro-link DBG] raw-path: %s" raw-path)
                     (let* ((path1 (replace-regexp-in-string "\\`file://" "" raw-path))
                            (path-lc (downcase path1)))
                       (cond
                        (;; foo.org, foo.org::* Heading, foo.org::#custom_id
                         (string= ".org" (file-name-extension path-lc "."))
                         (let ((ref "")
                               (anchor ""))
                           (if (string-suffix-p org-astro--preprocessed-buffer-dummy-file-suffix path-lc)
                               (progn
                                 (setq ref (string-remove-suffix
                                            org-astro--preprocessed-buffer-dummy-file-suffix
                                            (file-name-nondirectory path1)))
                                 ;; Dummy Org file paths created in
                                 ;; `org-astro--get-pre-processed-buffer'
                                 ;; For dummy Org file paths, we are
                                 ;; limiting to only "#" style search
                                 ;; strings.
                                 (when (string-match ".*\\.org::\\(#.*\\)" raw-link)
                                   (setq anchor (match-string-no-properties 1 raw-link))))
                             ;; Regular Org file paths.
                             (setq ref (file-name-sans-extension (file-name-nondirectory path1)))
                             (let ((link-search-str
                                    ;; If raw-link is "./foo.org::#bar",
                                    ;; set `link-search-str' to
                                    ;; "#bar".
                                    (when (string-match ".*\\.org::\\(.*\\)" raw-link)
                                      (match-string-no-properties 1 raw-link))))
                               ;; (message "[org-astro-link DBG] link-search-str: %s" link-search-str)
                               (when link-search-str
                                 (setq anchor (org-astro--search-and-get-anchor raw-path link-search-str info)))))
                           ;; (message "[org-astro-link file.org::*Heading DBG] ref    = %s" ref)
                           ;; (message "[org-astro-link file.org::*Heading DBG] anchor = %s" anchor)
                           (cond
                            ;; Link to a post subtree.  In this case,
                            ;; the "anchor" is actually the post's
                            ;; slug.
                            ((and (org-string-nw-p anchor) (not (string-prefix-p "#" anchor)))
                             (format "{{< relref \"%s\" >}}" anchor))
                            ;; Link to a non-post subtree, like a subheading in a post.
                            ((or (org-string-nw-p ref) (org-string-nw-p anchor))
                             (format "{{< relref \"%s%s\" >}}" ref anchor))
                            (t
                             ""))))
                        (t ;; attachments like foo.png
                         (org-astro--attachment-rewrite-maybe path1 info)))))
                    (t
                     raw-path)))
             (link-param-str (org-string-nw-p (org-trim link-param-str))))
        ;; (message "[org-astro-link DBG] desc=%s path=%s" desc path)
        ;; (message "[org-astro-link DBG] link-param-str=%s" link-param-str)
        (cond
         ;; Link description is a `figure' shortcode but does not
         ;; already have the `link' parameter set.
         ((and desc
               (string-match-p "\\`{{<\\s-*figure\\s-+" desc)
               (not (string-match-p "\\`{{<\\s-*figure\\s-+.*link=" desc)))
          (replace-regexp-in-string "\\s-*>}}\\'"
                                    (format " link=\"%s\"\\&" path)
                                    desc))
         ;; Both link description and link attributes are present.
         ((and desc
               link-param-str)
          (format "<a href=\"%s\" %s>%s</a>"
                  (org-html-encode-plain-text path)
                  link-param-str
                  (org-link-unescape desc)))
         ;; Only link description, but no link attributes.
         (desc
          (let* ((path-has-space (and
                                  (not (string-prefix-p "{{< relref " path))
                                  (string-match-p "\\s-" path)))
                 (path (if path-has-space
                           ;; https://github.com/kaushalmodi/ox-astro/issues/376
                           ;; https://github.com/gohugoio/hugo/issues/6742#issuecomment-573924706
                           (format "<%s>" path)
                         path)))
            (format "[%s](%s)" desc path)))
         ;; Only link attributes, but no link description.
         (link-param-str
          (let ((path (org-html-encode-plain-text path)))
            (format "<a href=\"%s\" %s>%s</a>"
                    path
                    link-param-str
                    ;; Below trick is to prevent Hugo from
                    ;; auto-hyperlinking the link in the
                    ;; description. Idea from
                    ;; https://stackoverflow.com/q/25706012/1219634.
                    (replace-regexp-in-string ":" "&colon;" (org-link-unescape path)))))
         ;; Neither link description, nor link attributes.
         ((string-prefix-p "{{< relref " path)
          (format "[%s](%s)" path path))
         ((org-string-nw-p path)
          (format "<%s>" path))
         (t
          "")))))))

(defun org-astro-link--heading-anchor-maybe (link info)
  "Return anchor of the heading pointed to by LINK.

INFO is a plist used as a communication channel."
  ;; (message "dbg link id: %S" (org-element-property :path link))
  (let* ((id-loc (org-id-find (org-element-property :path link)))
         (id-file (car id-loc))
         (id-pos (cdr id-loc))
         (id-buffer (get-file-buffer id-file))) ;nil if `id-file' buffer is not already open
    ;; (message "[org-astro-link--heading-anchor-maybe DBG] id-loc: %S" id-loc)
    (with-current-buffer (or id-buffer (find-file-noselect id-file :nowarn))
      (unless id-buffer
        (add-to-list 'org-astro--opened-buffers (current-buffer)))
      (org-export-get-environment)        ;Eval #+bind keywords, etc.
      (goto-char id-pos)
      (org-astro--get-anchor-at-point info))))

;;;;; Helpers
(defun org-astro--copy-resources-maybe (info)
  "Copy resources to the bundle directory if needed.

INFO is a plist used as a communication channel."
  (let* ((exportables org-astro-external-file-extensions-allowed-for-copying)
         (bundle-dir (and (plist-get info :astro-bundle)
                          (org-astro--get-pub-dir info)))
         (resources (org-astro--parse-property-arguments (plist-get info :astro-resources))))
    (when (and bundle-dir resources)
      (dolist (resource resources)
        (let ((key (car resource)))
          (when (equal key 'src)
            (let* ((val (cdr resource))
                   (sources (file-expand-wildcards val)))
              (dolist (source sources)
                (let ((src-path (file-truename source)))
                  (when (and (file-exists-p src-path)
                             (member (file-name-extension src-path) exportables))
                    (let* ((dest-path (concat bundle-dir source))
                           (dest-path-dir (file-name-directory dest-path)))
                      (unless (file-exists-p dest-path-dir)
                        (mkdir dest-path-dir :parents))
                      (when (file-newer-than-file-p src-path dest-path)
                        (message "[ox-astro] Copied resource %S to %S" src-path dest-path)
                        (copy-file src-path dest-path :ok-if-already-exists)))))))))))))

(defun org-astro--copy-ltximg-maybe (info)
  "Copy `org-preview-latex-image-directory' contents into site's ltximg directory.

INFO is a plist used as a communication channel."
  (when (file-exists-p org-preview-latex-image-directory)
    (let* ((astro-base-dir (file-name-as-directory (plist-get info :astro-base-dir)))
           (static-ltximg-dir (file-truename
                               (file-name-as-directory
                                (expand-file-name
                                 org-astro--ltximg-directory
                                 (expand-file-name "public" astro-base-dir))))))
      (when (file-newer-than-file-p
             org-preview-latex-image-directory static-ltximg-dir)
        (copy-directory org-preview-latex-image-directory static-ltximg-dir
                        nil :parents :copy-contents)
        (message "[ox-astro] Copied contents of %S into %S"
                 org-preview-latex-image-directory static-ltximg-dir)))))

(defun org-astro--attachment-rewrite-maybe (path info)
  "Copy local images and pdfs to the static/bundle directory if needed.
Also update the link paths to match those.

PATH is the path to the image or any other attachment.

INFO is a plist used as a communication channel."
  ;; (message "[ox-astro attachment DBG] The Hugo section is: %s" (plist-get info :astro-section))
  ;; (message "[ox-astro attachment DBG] The Hugo base dir is: %s" (plist-get info :astro-base-dir))
  (let* ((pub-dir (org-astro--get-pub-dir info)) ;This needs to happen first so that the check for ASTRO_BASE_DIR happens.
         (astro-base-dir (file-name-as-directory (plist-get info :astro-base-dir)))
         (path-unhexified (url-unhex-string path))
         (path-true (file-truename path-unhexified))
         (exportables org-astro-external-file-extensions-allowed-for-copying)
         (bundle-dir (and (plist-get info :astro-bundle) pub-dir))
         (bundle-name (when bundle-dir
                        (let* ((content-dir (file-truename
                                             (file-name-as-directory
                                              (expand-file-name org-astro-content-folder astro-base-dir))))
                               (is-home-branch-bundle (string= bundle-dir content-dir)))
                          (cond
                           (is-home-branch-bundle
                            "_home")
                           (t ;`bundle-dir'="/foo/bar/" -> `bundle-name'="bar"
                            (file-name-base (directory-file-name bundle-dir)))))))
         (static-dir (file-truename
                      (file-name-as-directory
                       (expand-file-name "public" astro-base-dir))))
         (dest-dir (or bundle-dir static-dir))
         ret)
    (unless (file-directory-p static-dir)
      (user-error "Please create the %s directory" static-dir))
    ;; (message "[ox-astro DBG attch rewrite] Image export dir is: %s" static-dir)
    ;; (message "[ox-astro DBG attch rewrite] path: %s" path)
    ;; (message "[ox-astro DBG attch rewrite] path-true: %s" path-true)
    ;; (message "[ox-astro DBG attch rewrite] bundle-dir: %s" bundle-dir)
    ;; (message "[ox-astro DBG attch rewrite] bundle-name: %s" bundle-name)
    ;; (message "[ox-astro DBG attch rewrite] default-dir: %s" default-directory)
    ;; (message "[ox-astro DBG attch rewrite] dest-dir: %s" dest-dir)
    (if (and (file-exists-p path-true)
             (member (file-name-extension path-unhexified) exportables)
             (file-directory-p dest-dir))
        (progn
          ;; Check if `path-true' is already inside `dest-dir'.
          (if (string-match (regexp-quote dest-dir) path-true)
              (progn
                ;; If so, return *only* the path considering the
                ;; destination directory as root.
                (setq ret (concat "/" (substring path-true (match-end 0)))))
            (let* ((file-name-relative-path
                    (cond
                     ((string-match "/static/" path-true)
                      ;; `path-true' is "/foo/static/bar/baz.png",
                      ;; return "bar/baz.png".
                      ;; (message "[ox-astro DBG attch rewrite] path contains static")
                      ;; If path-true contains "/static/", set the
                      ;; `dest-dir' to `static-dir' (even if this is a
                      ;; page bundle).
                      (setq dest-dir static-dir)
                      (substring path-true (match-end 0)))
                     (bundle-dir
                      (cond
                       ((string-match (concat "/" (regexp-quote bundle-name) "/") path-true)
                        ;; This is a page bundle.  `bundle-name' is
                        ;; "<BUNDLE_NAME>", `path-true' is
                        ;; "<ORG_FILE_DIR>/bar/<BUNDLE_NAME>/zoo/baz.png",
                        ;; return "zoo/baz.png".
                        ;; (message "[ox-astro DBG attch rewrite BUNDLE 1] bundle-name: %s" bundle-name)
                        ;; (message "[ox-astro DBG attch rewrite BUNDLE 1] attch along with Org content: %s"
                        ;;          (substring path-true (match-end 0)))
                        (substring path-true (match-end 0)))
                       ((string-match (regexp-quote default-directory) path-true)
                        ;; This is a page bundle.  `default-path' is
                        ;; "<ORG_FILE_DIR>/", `path-true' is
                        ;; "<ORG_FILE_DIR>/bar/baz.png", return
                        ;; "bar/baz.png".
                        ;; (message "[ox-astro DBG attch rewrite BUNDLE 2] attch along with Org content: %s"
                        ;;          (substring path-true (match-end 0)))
                        (substring path-true (match-end 0)))
                       (t
                        ;; This is a page bundle.  `default-path' is
                        ;; "<ORG_FILE_DIR>/", `path-true' is
                        ;; "/foo/bar/baz.png", return "baz.png".
                        ;; (message "[ox-astro DBG attch rewrite BUNDLE 3] attch neither in static nor in Org file dir")
                        (file-name-nondirectory path-unhexified))))
                     (t
                      ;; Else, `path-true' is "/foo/bar/baz.png",
                      ;; return "ox-astro/baz.png".  "ox-astro" is the
                      ;; default value of
                      ;; `org-astro-default-static-subdirectory-for-externals'.
                      ;; (message "[ox-astro DBG attch rewrite] neither BUNDLE nor contains static")
                      (concat
                       (file-name-as-directory org-astro-default-static-subdirectory-for-externals)
                       (file-name-nondirectory path-unhexified)))))
                   (dest-path (concat dest-dir file-name-relative-path))
                   (dest-path-dir (file-name-directory dest-path)))
              ;; The `dest-dir' would already exist.  But if
              ;; `file-name-relative-path' is "images/image.png" or
              ;; "foo/bar.txt", it's likely that "`dest-dir'/images"
              ;; or "`dest-dir'/foo" might not exist.  So create those
              ;; if needed below.
              (unless (file-exists-p dest-path-dir)
                (mkdir dest-path-dir :parents))
              ;; (message "[ox-astro DBG attch rewrite] file-name-relative-path: %s" file-name-relative-path)
              ;; (message "[ox-astro DBG attch rewrite] dest-path: %s" dest-path)
              ;; (message "[ox-astro DBG attch rewrite] dest-path-dir: %s" dest-path-dir)

              ;; Do the copy only if the file to be copied is newer or
              ;; doesn't exist in the static dir.
              (when (file-newer-than-file-p path-true dest-path)
                (message "[ox-astro] Copied %S to %S" path-true dest-path)
                (copy-file path-true dest-path :ok-if-already-exists))
              (setq ret (if (and bundle-dir
                                 (string= bundle-dir dest-dir))
                            ;; If attachments are copied to the bundle
                            ;; directory, don't prefix the path as "/"
                            ;; as those paths won't exist at the site
                            ;; base URL.
                            file-name-relative-path
                          (concat "/" file-name-relative-path))))))
      (setq ret path))
    ;; (message "[ox-astro DBG attch rewrite] returned path: %s" ret)
    ret))

;;;; Paragraph
(defun org-astro-paragraph--process-content (paragraph contents info)
  "Process the content of paragraphs.

- Prevent unwanted spaces when joining Chinese/Japanese lines.
- Join all lines in a paragraph into a single line if
  `:astro-preserve-filling' plist property is nil.
- Add \"&nbsp;\" HTML entity before footnote anchors so that the
  anchors won't be on a separate line by themselves.

Return the processed CONTENTS string from the PARAGRAPH element.
INFO is a plist used as a communication channel."
  (let ((ret contents))
    ;; Join consecutive Chinese, Japanese lines into a single long
    ;; line without unwanted space inbetween.
    (when (org-astro--lang-cjk-p info)
      ;; https://emacs-china.org/t/ox-astro-auto-fill-mode-markdown/9547/5
      ;; Example: 这是一个测试     -> 这是一个测试文本 ("This is a test text")
      ;;          文本
      (setq ret (replace-regexp-in-string
                 "\\([[:multibyte:]]\\)[[:blank:]]*\n[[:blank:]]*\\([[:multibyte:]]\\)" "\\1\\2"
                 ret))
      ;; (message "[org-astro-paragraph--process-content DBG] contents 1: %s" contents)
      )

    ;; Join all content into a single line (followed by a newline)
    ;; if :astro-preserve-filling is nil.
    (unless (org-astro--plist-get-true-p info :astro-preserve-filling)
      (setq ret (concat (mapconcat 'identity (split-string ret) " ") "\n")))

    ;; Special processing for footnotes.
    (setq ret (replace-regexp-in-string
               ;; Glue footnotes to the words before them using &nbsp;
               ;; so that the footnote reference does not end up on a
               ;; new line by itself.
               ;; "something FN" -> "something&nbsp;FN"
               "[[:blank:]]+\\(\\[\\^[^]]+\\]\\)" "&nbsp;\\1"
               (replace-regexp-in-string
                ;; "FN ." -> "FN."
                "\\(\\[\\^[^]]+\\]\\)[[:blank:]]*\\([.]+\\)" "\\1\\2"
                ret)))

    ;; Escape any lines starting with `#' which is the markup for
    ;; headings in Markdown.
    (setq ret (org-md-paragraph paragraph ret info))

    ;; (message "[org-astro-paragraph--process-content DBG] contents 2: %s" contents)
    ret))

(defun org-astro-paragraph (paragraph contents info)
  "Transcode PARAGRAPH element into Hugo Markdown format.
CONTENTS is the paragraph contents.  INFO is a plist used as a
communication channel."
  (let* ((parent (org-export-get-parent paragraph))
         (parent-type (org-element-type parent)))

    ;; (message "[ox-astro-para DBG] standalone image? %s\ncontents: %s"
    ;;          (org-html-standalone-image-p paragraph info)
    ;;          contents)

    (cond
     ;; First paragraph in an item has no tag if it is alone or
     ;; followed, at most, by a sub-list. (Below condition is taken
     ;; as-is from `org-html-paragraph').
     ((and (eq parent-type 'item)
           (not (org-export-get-previous-element paragraph info))
           (let ((followers (org-export-get-next-element paragraph info 2)))
             (and (not (cdr followers))
                  (memq (org-element-type (car followers)) '(nil plain-list)))))
      (org-astro-paragraph--process-content paragraph contents info))

     ;; Standalone image.
     ((org-html-standalone-image-p paragraph info)
      (let ((figure-ref (org-astro--get-reference paragraph))
            label)
        (when (org-string-nw-p figure-ref)
          (setq figure-ref (replace-regexp-in-string
                            "\\`org-paragraph--"
                            (org-astro--get-ref-prefix 'figure)
                            figure-ref)))
        (setq label (if figure-ref
                        (format "<a id=\"%s\"></a>\n\n" figure-ref)
                      ""))
        (concat label contents)))

     ;; Normal paragraph.
     (t
      (let ((label (let ((paragraph-ref (and (org-element-property :name paragraph)
                                             (org-export-get-reference paragraph info))))
                     (if paragraph-ref
                         (format "<a id=\"%s\"></a>\n\n" paragraph-ref)
                       ""))))

        ;; Wrap the paragraph with HTML div tag with user-specified
        ;; attributes.
        (org-astro--div-wrap-maybe
         paragraph
         (concat label
                 (org-astro-paragraph--process-content paragraph contents info))
         info))))))

;;;; Source Blocks
(defun org-astro-src-block (src-block _contents info)
  "Convert SRC-BLOCK element to Markdown fenced code block.
CONTENTS is nil.  INFO is a plist used as a communication channel."
  (let* ((lang (org-element-property :language src-block))
         (parameters-str (org-element-property :parameters src-block))
         (parameters (org-babel-parse-header-arguments parameters-str))
         (is-fm-extra (cdr (assoc :front_matter_extra parameters))))
    ;; Extra front matter blocks: pass through if lang matches format.
    (cond
     ((and is-fm-extra
           (member lang '("toml" "yaml")))
      (let ((fm-format (plist-get info :astro-front-matter-format)))
        (when (string= lang fm-format)
          (let ((fm-extra (org-export-format-code-default src-block info)))
            (plist-put info :fm-extra fm-extra)))
        nil))
     ;; Regular src block.
     (t
      (let* ((src-ref (org-astro--get-reference src-block))
             (src-anchor (if src-ref
                             (format "<a id=\"%s\"></a>\n" src-ref)
                           ""))
             (caption (org-export-get-caption src-block))
             (caption-html
              (if (not caption) ""
                (let* ((num (org-export-get-ordinal
                             src-block info nil #'org-html--has-caption-p))
                       (cap-prefix (org-astro--translate 'src-block info))
                       (cap-str (org-html-convert-special-strings
                                 (org-export-data-with-backend caption 'html info))))
                  (format (concat "\n<div class=\"src-block-caption\">\n"
                                  "  <span class=\"src-block-number\">%s:</span>\n"
                                  "  %s\n</div>")
                          (if src-ref
                              (format "<a href=\"#%s\">%s %s</a>" src-ref cap-prefix num)
                            (format "%s %s" cap-prefix num))
                          cap-str))))
             (code (org-export-format-code-default src-block info))
             (html-attr (org-export-read-attribute :attr_html src-block))
             (code-attr-str (org-html--make-attribute-string html-attr))
             fenced)
        ;; Build fenced code block.
        (when (org-string-nw-p code-attr-str)
          (plist-put info :md-code-attr code-attr-str))
        (plist-put info :md-code code)
        (setq fenced (org-astro--fenced-src-block src-block nil info))
        ;; Wrap with anchor, caption, and optional div attrs.
        (if (org-string-nw-p code-attr-str)
            (concat (org-astro--get-style-str src-block)
                    src-anchor fenced caption-html)
          (org-astro--div-wrap-maybe
           src-block
           (concat src-anchor fenced caption-html)
           info)))))))


;;;; Special Block
(defun org-astro-special-block (special-block contents info)
  "Transcode a SPECIAL-BLOCK element from Org to Markdown.
CONTENTS holds the contents of the block.  INFO is a plist holding export options."
  (let* ((block-type (org-element-property :type special-block))
         (block-type-plist (cdr (assoc block-type org-astro-special-block-type-properties)))
         (header (org-babel-parse-header-arguments
                  (car (org-element-property :header special-block))))
         (trim-pre (org-astro--value-get-true-p
                    (or (alist-get :trim-pre header)
                        (plist-get block-type-plist :trim-pre))))
         (trim-pre-tag (if trim-pre org-astro--trim-pre-marker ""))
         (trim-post (org-astro--value-get-true-p
                     (or (alist-get :trim-post header)
                         (plist-get block-type-plist :trim-post))))
         (trim-post-tag (if trim-post org-astro--trim-post-marker ""))
         (contents (when (stringp contents)
                     (org-trim
                      (if (plist-get block-type-plist :raw)
                          (org-element-interpret-data (org-element-contents special-block))
                        contents)))))
    (plist-put info :type-plist block-type-plist)
    (plist-put info :trim-pre-tag trim-pre-tag)
    (plist-put info :trim-post-tag trim-post-tag)
    (when contents
      (cond
       ;; Tikzjax blocks.
       ((string= block-type "tikzjax")
        (format "%s%s%s"
                "<script type=\"text/tikz\">\n  \\begin{tikzpicture}\n"
                contents
                "\n\\end{tikzpicture}\n</script>"))
       ;; Description blocks: override the :description in info.
       ((string= block-type "description")
        (plist-put info :description contents)
        nil)
       ;; HTML5 elements: delegate to ox-html.
       ((or (member block-type org-html-html5-elements)
            (member block-type org-astro-html5-inline-elements))
        (org-html-special-block special-block contents info))
       ;; Everything else: wrap in <div> with class=block-type.
       (t
        (let* ((attr (org-export-read-attribute :attr_html special-block))
               (attr (plist-put attr :class
                                (if (plist-get attr :class)
                                    (concat (plist-get attr :class) " " block-type)
                                  block-type)))
               (name (org-element-property :name special-block))
               (attr (if (and name (not (plist-member attr :id)))
                         (plist-put attr :id name)
                       attr))
               (attr-str (org-astro--make-attribute-string attr))
               (attr-str (if (org-string-nw-p attr-str)
                             (concat " " attr-str) "")))
          (format "%s<div%s>%s\n\n%s\n\n</div>%s"
                  trim-pre-tag attr-str contents contents trim-post-tag)))))))


(defun org-astro-body-filter (body _backend info)
  "Add front-matter to the BODY of the document.

BODY is the result of the export.
INFO is a plist holding export options."
  ;; Copy the page resources to the bundle directory.
  (org-astro--copy-resources-maybe info)
  (org-astro--copy-ltximg-maybe info)
  ;; (message "[ox-astro body filter] ITEM %S" (org-entry-get (point) "ITEM"))
  ;; (message "[ox-astro body filter] TAGS: %S" (org-entry-get (point) "TAGS"))
  ;; (message "[ox-astro body filter] ALLTAGS: %S" (org-entry-get (point) "ALLTAGS"))

  (when (and (org-astro--plist-get-true-p info :astro-delete-trailing-ws)
             (not (org-astro--plist-get-true-p info :preserve-breaks)))
    (setq body (with-temp-buffer
                 (insert body)
                 (delete-trailing-whitespace (point-min) nil)
                 (buffer-substring-no-properties (point-min) (point-max)))))
  (let ((fm (save-excursion
              (save-restriction
                ;; The point is at the beginning of the heading body
                ;; in this function! So move the point back by 1 char
                ;; to bring it into the Org heading before calling
                ;; `org-astro--get-front-matter', because in there we
                ;; use `org-entry-get' at (point) to retrieve certain
                ;; property values.
                (widen)
                (ignore-errors ;If the point is at beginning of buffer even after widening
                  (backward-char))
                ;; (message "[body filter DBG] line at pt: %s" (thing-at-point 'line))
                (org-astro--get-front-matter info))))
        (fm-extra (plist-get info :fm-extra))
        (body (if (org-string-nw-p body) ;Insert extra newline if body is non-empty
                  (format "\n%s" body)
                "")))
    ;; (message "[body filter DBG fm] %S" fm)
    ;; (message "[body filter DBG fm-extra] %S" fm-extra)
    (when fm-extra
      ;; If fm-extra is present, append it to the end of the
      ;; front-matter, before the closing "+++" or "---" marker.
      (setq fm (replace-regexp-in-string "\\(\\+\\+\\+\\|---\\)\n*\\'"
                                         (concat fm-extra "\\&")
                                         fm)))
    (setq org-astro--fm fm)
    (format "%s%s%s" fm body org-astro-footer)))

;;;;; Hugo Front-Matter
(defun org-astro--parse-property-arguments (str)
  "Return an alist converted from a string STR of Hugo property value.

STR is of type \":KEY1 VALUE1 :KEY2 VALUE2 ..\".  Given that, the
returned value is ((KEY1 . VALUE1) (KEY2 . VALUE2) ..).

Example: Input STR \":foo bar :baz 1 :zoo \\\"two words\\\"\" would
convert to ((foo . \"bar\") (baz . 1) (zoo . \"two words\"))."
  (let ((alist (org-babel-parse-header-arguments str)))
    (dolist (pair alist)
      ;; :KEY -> KEY
      (let ((key (intern (replace-regexp-in-string "\\`:" "" (symbol-name (car pair))))))
        (setcar pair key)))
    alist))

(defun org-astro--front-matter-value-booleanize (str)
  "Return a \"true\" or \"false\" string for input STR."
  (let ((str-lower (and (stringp str)
                        (downcase str))))
    (cond
     ((or (null str)
          (string= "nil" str-lower)
          (string= "false" str-lower)
          (string= "no" str-lower))
      "false")
     ((or (string= "t" str)
          (string= "true" str)
          (string= "yes" str))
      "true")
     (t
      (user-error "%S needs to represent a boolean value" str)))))

(defun org-astro--parse-menu-prop-to-alist (info)
  "Return an alist of valid Hugo menu properties derived from INFO.

INFO is a plist used as a communication channel."
  (let* ((fm-format (plist-get info :astro-front-matter-format))
         (menu-alist (org-astro--parse-property-arguments (plist-get info :astro-menu)))
         (menu-ov-alist (org-astro--parse-property-arguments (plist-get info :astro-menu-override)))
         (menu-props '(name url identifier pre post weight parent title))
         valid-menu-alist)
    ;; (message "[org-astro--parse-menu-prop-to-alist DBG] menu str: %S, alist: %S" str menu-alist)
    ;; Hugo menu properties: https://gohugo.io/content-management/menus/
    ;; "title" property for menus was introduced in Hugo v0.32.
    ;; https://github.com/gohugoio/hugo/commit/9df3736fec164c51d819797416dc263f2869be77
    (cond
     ((string= fm-format "toml")
      (when (assoc 'menu menu-alist)
        (setq valid-menu-alist (list (cdr (assoc 'menu menu-alist))))
        (let (menu-params)
          (dolist (prop menu-props)
            (let ((cell (or (assoc prop menu-ov-alist)
                            (assoc prop menu-alist))))
              (when cell
                (push cell menu-params))))
          ;; Auto-set menu identifier if not already set by user.
          (unless (assoc 'identifier menu-params)
            (let ((id (org-astro--hugo-slug (org-astro--get-sanitized-title info))))
              (push `(identifier . ,id) menu-params)))
          ;; Auto-set menu weight if not already set by user.
          (unless (assoc 'weight menu-params)
            (when org-astro--subtree-coord
              (push `(weight . ,(org-astro--calc-weight)) menu-params)))
          (setcdr valid-menu-alist menu-params))
        (setq valid-menu-alist (list valid-menu-alist))))
     ((string= fm-format "yaml")
      (push 'menu menu-props)
      (dolist (prop menu-props)
        (let ((cell (or (assoc prop menu-ov-alist)
                        (assoc prop menu-alist))))
          (when cell
            (push cell valid-menu-alist))))))
    valid-menu-alist))

(defun org-astro--get-sanitized-title (info)
  "Return sanitized version of an Org heading TITLE as a string.

INFO is a plist used as a communication channel.

Extract the document title from INFO (unless exporting title is
disabled by setting `org-export-with-title' to nil or using the
OPTIONS keyword e.g. \"title:nil\").

If the extracted document title is nil, and exporting the title
is disabled, return nil.

If the extracted document title is non-nil, return it after
removing all markup characters.

Also double-quote the title if it doesn't already contain any
double-quotes."
  (let ((title (when (plist-get info :with-title)
                 (plist-get info :title))))
    (when title
      ;; "Raw" backend that returns emphasis elements without any
      ;; markup characters --
      ;; http://lists.gnu.org/r/emacs-orgmode/2017-12/msg00490.html
      (let* ((raw-backend

              (let ((get-raw (lambda (object contents _)
                               (or contents
                                   (org-element-property :value object)))))
                (org-export-create-backend
                 :parent 'ascii
                 :transcoders (mapcar (lambda (type)
                                        (cons type get-raw))
                                      '(bold code italic strike-through
                                             underline verbatim))))))
        (setq title (org-export-data-with-backend title raw-backend info))
        ;; Hugo does not render Markdown in the titles.  So do that
        ;; here instead.  Convert "---" to EM DASH, "--" to EN DASH,
        ;; and "..." to HORIZONTAL ELLIPSIS.

        ;; Below two replacements are order sensitive!
        (setq title (replace-regexp-in-string "---\\([^-]\\)" "—\\1" title)) ;EM DASH
        (setq title (replace-regexp-in-string "--\\([^-]\\)" "–\\1" title)) ;EN DASH

        (setq title (replace-regexp-in-string "\\.\\.\\." "…" title)))) ;HORIZONTAL ELLIPSIS
    title))

(defun org-astro--replace-underscores-with-spaces (str)
  "Replace double underscores in STR with single spaces.

For example, \"some__thing\" would get converted to \"some
thing\"."
  ;; It is safe to assume that no one would want leading/trailing
  ;; spaces in `str'.. so not checking for "__a" or "a__" cases.
  (let ((ret str)
        (rgx "\\([^_]\\)__\\([^_]\\)"))
    (while (string-match-p rgx ret)
      (setq ret (replace-regexp-in-string rgx "\\1 \\2" ret))) ;"a__b"  -> "a b"
    ret))

(defun org-astro--tag-processing-fn-replace-with-spaces-maybe (tag-list info)
  "Replace double underscores in TAG-LIST elements with single spaces.

For example, an element \"some__tag\" would get converted to
\"some tag\".

This replacement is enabled if `org-astro-allow-spaces-in-tags' or
ASTRO_ALLOW_SPACES_IN_TAGS property is set to a non-nil value.

TAG-LIST which is a list of Org tags of the type \(\"TAG1\"
\"TAG2\" ..).  INFO is a plist used as a communication channel.

This is one of the processing functions in
`org-astro-tag-processing-functions'."
  (let ((allow-spaces (org-astro--plist-get-true-p info :astro-allow-spaces-in-tags)))
    (if allow-spaces
        (mapcar #'org-astro--replace-underscores-with-spaces tag-list)
      tag-list)))

(defun org-astro--tag-processing-fn-replace-with-hyphens-maybe (tag-list info)
  "Replace single underscores in TAG-LIST elements with single hyphens.
And triple underscores will be replaced with single underscores.

For example, an element \"some_tag\" would get converted to
\"some-tag\", and \"some___tag\" to \"some_tag\".

This replacement is enabled if `org-astro-prefer-hyphen-in-tags'
or ASTRO_PREFER_HYPHEN_IN_TAGS property is set to a non-nil value.

TAG-LIST which is a list of Org tags of the type \(\"TAG1\"
\"TAG2\" ..).  INFO is a plist used as a communication channel.

This is one of the processing functions in
`org-astro-tag-processing-functions'."
  (let ((prefer-hyphens (org-astro--plist-get-true-p info :astro-prefer-hyphen-in-tags)))
    (if prefer-hyphens
        (mapcar
         (lambda (tag)
           (setq tag (replace-regexp-in-string "\\`_\\([^_]\\)" "-\\1" tag))         ;"_a"    -> "-a"
           (setq tag (replace-regexp-in-string "\\`___\\([^_]\\)" "_\\1" tag))       ;"___a"  -> "_a"
           (setq tag (replace-regexp-in-string "\\([^_]\\)_\\'" "\\1-" tag))         ;"a_"    -> "a-"
           (setq tag (replace-regexp-in-string "\\([^_]\\)___\\'" "\\1_" tag))       ;"a___"  -> "a_"
           (setq tag (replace-regexp-in-string "\\([^_]\\)_\\([^_]\\)" "\\1-\\2" tag))   ;"a_b"   -> "a-b"
           (setq tag (replace-regexp-in-string "\\([^_]\\)___\\([^_]\\)" "\\1_\\2" tag)) ;"a___b" -> "a_b"
           tag)
         tag-list)
      tag-list)))

(defun org-astro--delim-str-to-list (str)
  "Function to transform string STR to a list of strings.

The function assumes STR to use
`org-astro--internal-list-separator' as delimiter.

The function does the following in order:

1. Trim leading/trailing spaces from STR.
2. Convert that string to a list using
   `org-astro--internal-list-separator' as the separator.
3. Break up each element of that list into further string elements,
   delimited by spaces.  Though, spaces within quoted string are
   retained.  This is done using `org-babel-parse-header-arguments'.
4. Return the transformed list of strings.

Example: \"one\\n\\\"two words\\\" three\\nfour\"
         -> (\"one\" \"two words\" \"three\" \"four\").

Return nil if STR is not a string."
  (when (stringp str)
    (let* ((str (org-trim str))
           (str-list (split-string str org-astro--internal-list-separator))
           ret)
      (dolist (str-elem str-list)
        (let* ((format-str ":dummy '(%s)") ;The :dummy key is discarded in the `lst' var below.
               (alist (org-babel-parse-header-arguments (format format-str str-elem)))
               (lst (cdr (car alist)))
               (str-list2 (mapcar (lambda (elem)
                                    (cond
                                     ((symbolp elem)
                                      (symbol-name elem))
                                     (t
                                      elem)))
                                  lst)))
          (setq ret (append ret str-list2))))
      ret)))

(defun org-astro--category-p (tag)
  "Return non-nil if TAG begins with \"@\".

Org tags that begin with \"@\" are set as the categories field in
the Hugo front-matter."
  (and (stringp tag)
       (string-match-p "\\`@" tag)))

(defun org-astro--subtree-export-p (info)
  "Return non-nil if the current export is subtree based.

INFO is a plist used as a communication channel."
  (memq 'subtree (plist-get info :export-options)))

(defun org-astro--string-unquote (str)
  "Return STR after removing beginning and ending quotes if any.

Return nil if STR is an empty string, or not a string."
  (let ((unquoted-str (org-string-nw-p str))) ;Ensure that `str' is a non-empty string
    (when (and unquoted-str
               (string= (substring unquoted-str 0 1) "\"") ;First char is literally a "
               (string= (substring unquoted-str -1) "\"")) ;Last char is literally a "
      (setq unquoted-str (substring unquoted-str 1 -1)))
    unquoted-str))

(defun org-astro--get-front-matter (info)
  "Return the Astro front-matter string.

INFO is a plist used as a communication channel."
  ;; (message "[astro front-matter DBG] info: %S" (pp info))
  (let* ((fm-format (plist-get info :astro-front-matter-format))
         (author-list (and (plist-get info :with-author)
                           (let ((author-raw
                                  (org-string-nw-p
                                   (org-export-data (plist-get info :author) info)))) ;`org-export-data' required
                             (when author-raw
                               ;; Multiple authors can be comma or
                               ;; newline separated. The newline
                               ;; separated authors work only for the
                               ;; #+author keyword; example:
                               ;;   #+author: Author1
                               ;;   #+author: Author2
                               ;;
                               ;; If using the subtree properties they
                               ;; need to be comma-separated:
                               ;;   :EXPORT_AUTHOR: Author1, Author2
                               (let ((author-list-1 (org-split-string author-raw "[,\n]")))
                                 ;; Don't allow spaces around author names.
                                 ;; Also remove duplicate authors.
                                 (delete-dups (mapcar #'org-trim author-list-1)))))))
         (creator (and (plist-get info :with-creator)
                       (plist-get info :creator)))
         (locale (and (plist-get info :astro-with-locale)
                      (org-astro--get-lang info)))
         (description (org-string-nw-p (plist-get info :description)))
         ;; The draft state is emitted as a real YAML/TOML boolean.
         (draft (org-astro--parse-draft-state info))
         (all-t-and-c-str (org-entry-get (point) "ALLTAGS")) ;Includes tags inherited from #+filetags: too.
         (all-t-and-c (or (when (stringp all-t-and-c-str)    ;tags/categories from `all-t-and-c' are used
                            (org-split-string all-t-and-c-str ":")) ;only if ASTRO_TAGS or ASTRO_CATEGORIES are not set.
                          (and (null (org-astro--subtree-export-p info)) ;Use #+filetags: for file-based exports if #+astro_tags are not set.
                               org-file-tags)))
         (tags (or
                ;; Look for tags set using ASTRO_TAGS keyword, or
                ;; EXPORT_ASTRO_TAGS property if available.
                (org-astro--delim-str-to-list (plist-get info :astro-tags))
                ;; Else use Org tags (the ones set in headings
                ;; and/or inherited) if any.
                (let* ((tags-list (cl-remove-if #'org-astro--category-p all-t-and-c))
                       (tags-list (dolist (fn org-astro-tag-processing-functions tags-list)
                                    (setq tags-list (funcall fn tags-list info)))))
                  ;; (message "[get fm DBG] tags: tags-list = %S" tags-list)
                  tags-list)))
         (categories (or
                      ;; Look for categories set using ASTRO_CATEGORIES
                      ;; keyword, or EXPORT_ASTRO_CATEGORIES property
                      ;; if available.
                      (org-astro--delim-str-to-list (plist-get info :astro-categories))
                      ;; Else use categories set using Org tags with
                      ;; "@" prefix (the ones set in headings and/or
                      ;; inherited) if any.
                      (let* ((categories-list (cl-remove-if-not #'org-astro--category-p all-t-and-c))
                             (categories-list (dolist (fn org-astro-tag-processing-functions categories-list)
                                                (setq categories-list (funcall fn categories-list info))))
                             (categories-list (mapcar (lambda (str)
                                                        ;; Remove "@" from beg of categories.
                                                        (replace-regexp-in-string "\\`@" "" str))
                                                      categories-list)))
                        ;; (message "dbg: categories: categories-list = %s" categories-list)
                        categories-list)))
         (keywords (org-astro--delim-str-to-list (plist-get info :keywords)))
         (custom-fm-data (org-astro--parse-property-arguments (plist-get info :astro-custom-front-matter)))
         (data `(;; The order of the elements below will be the order in which the front-matter
                 ;; variables will be ordered.
                 ;;
                 ;; Keys follow Astro's content collection schema
                 ;; (https://docs.astro.build/en/reference/content-config-reference/):
                 ;; title, description, pubDate, updatedDate, draft, tags,
                 ;; categories, keywords, slug, image.  Hugo-only keys
                 ;; (menu, weight, headless, outputs, publishDate,
                 ;; expiryDate, isCJKLanguage, blackfriday, ...) are not
                 ;; supported by this backend; users can still inject
                 ;; arbitrary keys via ASTRO_CUSTOM_FRONT_MATTER.
                 (title . ,(org-astro--get-sanitized-title info))
                 (description . ,description)
                 (pubDate . ,(org-astro--format-date :date info))
                 (updatedDate . ,(org-astro--format-date :astro-lastmod info))
                 (author . ,author-list)
                 (keywords . ,keywords)
                 (categories . ,categories)
                 (tags . ,tags)
                 (slug . ,(plist-get info :astro-slug))
                 ;; `org-astro--parse-draft-state' returns a "true"/
                 ;; "false" string; emit a real YAML/TOML boolean.
                 (draft . ,(string= "true" draft))
                 ;; org-roam connection graph: the unit's own org-id
                 ;; and the ids it links to, resolved to sibling
                 ;; pages' slugs.  Empty/absent values are skipped by
                 ;; the front-matter generators, like for other keys.
                 (roamID . ,(org-astro--get-roam-id info))
                 (roamLinks . ,(org-astro--get-roam-links info))
                 (creator . ,creator)
                 (locale . ,locale)))
         (data `,(append data custom-fm-data))
         ret)

    ;; (message "[get fm DBG] tags: %s" tags)
    ;; (message "dbg: hugo tags: %S" (plist-get info :astro-tags))
    ;; (message "[get fm info DBG] %S" info)
    ;; (message "[get fm menu DBG] %S" menu-alist)
    ;; (message "[get fm menu override DBG] %S" menu-alist-override)
    ;; (message "[custom fm data DBG] %S" custom-fm-data)
    ;; (message "[fm resources OUT DBG] %S" resources)
    ;; (message "[fm data DBG] data: %S" data)
    ;; (progn (message "[fm data DBG] ") (pp data))
    ;; (message "[fm tags DBG] %S" tags)
    ;; (message "[fm categories DBG] %S" categories)
    ;; (message "[fm keywords DBG] %S" keywords)

    ;; Append group tags to user-set tags if tag groups are defined in
    ;; the buffer.
    (when (and org-group-tags org-tag-groups-alist)
      (let (tag-groups-alist-mod)

        ;; Copy `org-tag-groups-alist' to `tag-groups-alist-mod' while
        ;; modifying the tags and categories as defined by
        ;; `org-astro-tag-processing-functions'.
        (dolist (group org-tag-groups-alist)
          (let ((group-mod group))
            (dolist (fn org-astro-tag-processing-functions group-mod)
              (setq group-mod (funcall fn group-mod info)))
            (push group-mod tag-groups-alist-mod)))

        (dolist (t-or-c (append tags categories))
          (let ((to-be-searched `(,t-or-c)))
            (while (> (length to-be-searched) 0)
              ;; (message "[tag group DBG] t and c to search: %S" to-be-searched)
              (let ((tc (pop to-be-searched)))
                (dolist (group tag-groups-alist-mod)
                  ;; (message "[tag group DBG]   Searching %s in %S" tc group)
                  (when (member tc group)
                    (let ((head-tag (car group)))
                      (if (org-astro--category-p head-tag)
                          (let ((head-cat (replace-regexp-in-string "\\`@" "" head-tag)))
                            (unless (member head-cat categories)
                              (push head-cat categories)
                              ;; (message "[tag group DBG] .... Adding cat %s" head-cat)
                              ))
                        (unless (member head-tag tags)
                          (push head-tag tags)
                          ;; (message "[tag group DBG] .... Adding tag %s" head-tag)
                          ))
                      ;; Add the current `head-tag' as the new tag to
                      ;; search if current tag or category (`tc') is not
                      ;; the `head-tag', and if it's not already in the
                      ;; search list.
                      (unless (or (string= tc head-tag)
                                  (member head-tag to-be-searched))
                        (push head-tag to-be-searched))))))))))
      ;; (message "[tag group DBG] updated tags: %S" tags)
      ;; (message "[tag group DBG] updated categories: %S" categories)

      ;; Overwrite the 'tags and 'categories key values in `data' with
      ;; the updated values.
      ;; https://stackoverflow.com/a/40815365/1219634
      (setf (alist-get 'tags data) tags)
      (setf (alist-get 'categories data) categories))

    (setq data (org-astro--replace-keys-maybe data info))
    (setq ret (org-astro--gen-front-matter data fm-format))
    (setq org-astro--fm-yaml ret)
    ret))

(defun org-astro--calc-weight ()
  "Calculate the weight for a Hugo post or menu item.

The returned weight = INDEX + 1000*LEVEL.  See
`org-astro--get-post-subtree-coordinates' learn about INDEX and
LEVEL."
  (let* ((level (car org-astro--subtree-coord))
         (index (cdr org-astro--subtree-coord)))
    ;; (message "[org-astro--calc-weight dbg] level = %S" level)
    ;; (message "[org-astro--calc-weight dbg] index = %S" index)
    (+ (* 1000 level) index)))

(defun org-astro--gen-front-matter (data format)
  "Generate the Astro post front-matter, and return that string.

DATA is an alist of the form ((KEY1 . VAL1) (KEY2 . VAL2) ..),
where KEY is a symbol and VAL is a string, a list, or an alist.

Generate the front-matter in the specified FORMAT.  Valid values
are \"toml\" (via `tomelr') and \"yaml\" (default)."
  (if (string= format "yaml")
      (org-astro--gen-yaml-front-matter data)
    (let ((tomelr-indent-multi-line-strings t))
      (format "+++\n%s\n+++\n" (tomelr-encode data)))))

;;;; Small string helpers (lifted from the ai/cleanroom-v0 donor)
(defun org-astro--js-literal-escape (s)
  "Escape S for embedding inside a JS template literal.
Backslashes, backticks and `${' interpolation sequences are
escaped, so that arbitrary exported text (an ox-html body in
particular) can never break out of the literal, and braces in the
embedded text can never parse as Astro expressions."
  (setq s (replace-regexp-in-string "\\\\" "\\\\\\\\" s))
  (setq s (replace-regexp-in-string "`" "\\\\`" s))
  (setq s (replace-regexp-in-string "\\${" "\\\\${" s))
  s)

(defun org-astro--yaml-escape (s)
  "Return S as a double-quoted YAML scalar.
`\\' and `\"' are escaped, so that values containing YAML special
characters like `:' or `#' cannot corrupt the front matter."
  (let ((s (replace-regexp-in-string "\\\\" "\\\\\\\\" s)))
    (setq s (replace-regexp-in-string "\"" "\\\\\"" s))
    (format "\"%s\"" s)))

(defun org-astro--yaml-scalar (value)
  "Return VALUE encoded as a YAML scalar string.

Booleans become \"true\"/\"false\", numbers pass through, nil
becomes \"null\".  Strings are always double-quoted (with `\\' and
`\"' escaped) so that values containing YAML special characters
like `:' or `#' cannot corrupt the front matter.  Astro's
zod-based schemas coerce the quoted ISO date strings to dates."
  (cond
   ((null value) "null")
   ((eq value t) "true")
   ((numberp value) (number-to-string value))
   ((listp value) ;e.g. alist stored by custom front matter
    (user-error "Nested value %S not supported here" value))
   (t ;string
    (org-astro--yaml-escape value))))

(defun org-astro--gen-yaml-front-matter (data)
  "Generate Astro front-matter in YAML format, and return that string.

DATA is an alist of the form ((KEY1 . VAL1) (KEY2 . VAL2) ..),
where KEY is a symbol and VAL is a string, list, or alist.
Keys with nil or empty values are skipped."
  (let ((out ""))
    (dolist (pair data)
      (let* ((key (symbol-name (car pair)))
             (value (cdr pair)))
        (unless (or (null value)
                    (and (stringp value) (string= "" value)))
          (cond
           ;; Nested alist -> YAML mapping with 2-space indented keys.
           ((and (listp value) (consp (car value)))
            (setq out (concat out key ":\n"))
            (dolist (nested-pair value)
              (let ((nested-key (symbol-name (car nested-pair)))
                    (nested-value (cdr nested-pair)))
                (unless (or (null nested-value)
                            (and (stringp nested-value) (string= "" nested-value)))
                  (setq out (concat out
                                    (format "  %s: %s\n"
                                            nested-key
                                            (org-astro--yaml-scalar nested-value))))))))
           ;; Lisp list of scalars -> YAML flow sequence.
           ((listp value)
            (setq out (concat out
                              (format "%s: [%s]\n" key
                                      (mapconcat #'org-astro--yaml-scalar value ", ")))))
           ;; Plain scalar.
           (t
            (setq out (concat out
                              (format "%s: %s\n" key
                                      (org-astro--yaml-scalar value)))))))))
    ;; Strip trailing newline; caller re-adds the closing fence.
    (if (string= out "")
        "---\n\n---\n" ;Empty front matter still needs valid fences
      (concat "---\n" (substring out 0 -1) "\n---\n"))))

;;;; Org-roam unit table (absorbed from the ai/cleanroom-v0 donor)
;; The roam subsystem gives every export unit an identity in the
;; Astro world: the unit's org-id becomes the `roamID' front-matter
;; key, the `id:' links it contains are resolved to sibling pages'
;; slugs in `roamLinks', and `id:' links in the body are translated
;; to /blog/<slug>/ links (the `roam-slug' branch of `org-astro-link').  An
;; Astro layout can then render linked mentions and backlinks at
;; build time, straight from the content collection -- zero client
;; JS.

(defun org-astro--get-file-level-id ()
  "Return the ID property of the current buffer's file-level drawer.
Org-roam file nodes keep their org-id there.  Return nil if there
is no such ID."
  (org-with-wide-buffer
   (goto-char (point-min))
   (let ((first-heading (save-excursion
                          (or (and (re-search-forward org-heading-regexp nil :noerror)
                                   (match-beginning 0))
                              (point-max)))))
     (catch 'id
       (while (re-search-forward "^[ \t]*:PROPERTIES:[ \t]*$" first-heading :noerror)
         (let ((drawer-end (save-excursion
                             (and (re-search-forward "^[ \t]*:END:[ \t]*$" first-heading :noerror)
                                  (match-beginning 0)))))
           (when drawer-end
             (when (re-search-forward "^[ \t]*:ID:[ \t]+\\([^ \t\r\n]+\\)" drawer-end :noerror)
               (throw 'id (match-string-no-properties 1)))
             (goto-char drawer-end))))
       nil))))

(defun org-astro--unit-astro-slug-at (pom)
  "Return the Astro content-collection slug for the post subtree at POM.

This slug names the unit in the roam unit table, in /blog/<slug>/
link targets and in .astro page file names: the unit's own
inherited EXPORT_ASTRO_SLUG value when set, else the github-slugger
slug (`org-astro--slugify', the stateless core of `org-astro-slug')
of the EXPORT_FILE_NAME base name -- Astro derives content
collection entry ids from file names exactly that way.  The
Hugo-style section prefix and page-bundle handling of
`org-astro--heading-get-slug' are deliberately not part of it: an
Astro entry id is the slug alone.  Bundle landing pages
(index/_index) should set EXPORT_ASTRO_SLUG explicitly.

Return nil if the entry at POM is not itself a post subtree (no
EXPORT_FILE_NAME of its own)."
  (org-with-point-at pom
    (let ((file-name (org-entry-get (point) "EXPORT_FILE_NAME")))
      (when (org-string-nw-p file-name)
        (or (org-string-nw-p (org-entry-get (point) "EXPORT_ASTRO_SLUG" t))
            (org-astro--slugify (file-name-base file-name)))))))

(defun org-astro--file-unit-astro-slug ()
  "Return the Astro content-collection slug for a file-based export.
The ASTRO_SLUG keyword wins when set; else the Org file's base
name is passed through `org-astro--slugify'."
  (or (org-string-nw-p
       (cadr (assoc "ASTRO_SLUG" (org-collect-keywords '("ASTRO_SLUG")))))
      (and buffer-file-name
           (org-astro--slugify (file-name-base buffer-file-name)))))

(defun org-astro--get-roam-table ()
  "Return the Org-roam unit table of the current buffer.

The table is an alist of (ID SLUG TITLE) elements, one per export
unit that carries an org-id: a valid post subtree (an EXPORT_FILE_NAME
property of its own), or -- when the buffer has none of those --
the whole file (file-based export).  Units without an org-id do
not join the roam graph and are left out, mirroring org-roam: only
nodes with ids can be linked with `id:' links."
  (org-with-wide-buffer
   (let ((table nil))
     (if (org-astro--buffer-has-valid-post-subtree-p)
         (org-map-entries
          (lambda ()
            (let ((id (org-entry-get (point) "ID")))
              (when id
                (let ((slug (org-astro--unit-astro-slug-at (point))))
                  (when slug
                    (push (list id slug (org-entry-get (point) "ITEM")) table))))))
          "EXPORT_FILE_NAME<>\"\"" 'file)
       (let ((id (org-astro--get-file-level-id))
             (slug (org-astro--file-unit-astro-slug)))
         (when (and id slug)
           (push (list id slug
                       (org-string-nw-p
                        (cadr (assoc "TITLE" (org-collect-keywords '("TITLE"))))))
                 table))))
     (nreverse table))))

(defun org-astro--roam-table ()
  "Return the current buffer's roam unit table, computing it if needed.
The result is memoized in the `org-astro--roam-table' variable for
the ongoing export; `org-astro--before-export-function' and
`org-astro--cleanup' manage that cache."
  (or org-astro--roam-table
      (setq org-astro--roam-table (org-astro--get-roam-table))))

(defun org-astro--get-roam-id (info)
  "Return the org-id of the export unit at hand, or nil.

For subtree-based exports this is the ID property of the post
subtree itself (not inherited: each org-roam node carries its own
id); for file-based exports, the ID in the file-level property
drawer.

INFO is a plist used as a communication channel."
  (if (org-astro--subtree-export-p info)
      (org-entry-get (point) "ID")
    (org-astro--get-file-level-id)))

(defun org-astro--get-roam-links (info)
  "Return the slugs of the roam units this export unit links to.

Scan the unit being exported (the parse tree from INFO, else the
narrowed buffer) for `id:' links and resolve each id through
`org-astro--roam-table'.  Ids that are not exported units of the
current buffer (other files, headings that are not posts) do not
join the roam graph.  Document order is kept, duplicates removed.

INFO is a plist used as a communication channel."
  (let* ((table (org-astro--roam-table))
         (tree (or (plist-get info :parse-tree)
                   (org-element-parse-buffer)))
         links)
    (org-element-map tree 'link
      (lambda (link)
        (when (string= "id" (org-element-property :type link))
          (let ((slug (cadr (assoc (org-element-property :path link) table))))
            (when (and slug (not (member slug links)))
              (setq links (cons slug links)))))))
    (nreverse links)))

(defun org-astro-export-roam-graph (outfile)
  "Write this buffer's roam connection graph to OUTFILE as JSON.

Nodes are the buffer's roam units (id, slug, title); edges are the
`id:' links between them, each emitted as a [from-id, to-id] pair.
An Astro layout renders backlinks and linked mentions from this
file at build time, straight from the exported content -- zero
client JS.  Run it after `org-astro-export-wim-to-md' (or any
export of the same buffer): the table is recomputed from the
buffer, so nothing depends on export-time state."
  (interactive "FWrite roam graph to: ")
  (let* ((table (org-astro--get-roam-table))
         (ids (mapcar #'car table))
         (nodes (mapcar (lambda (u)
                          `((id . ,(nth 0 u))
                            (slug . ,(nth 1 u))
                            (title . ,(nth 2 u))))
                        table))
         edges)
    (when (org-astro--buffer-has-valid-post-subtree-p)
      (org-map-entries
       (lambda ()
         (let ((from-id (org-entry-get (point) "ID")))
           (when (member from-id ids)
             (save-restriction
               (org-narrow-to-subtree)
               (org-element-map (org-element-parse-buffer) 'link
                 (lambda (l)
                   (when (string= "id" (org-element-property :type l))
                     (let ((to-id (org-element-property :path l)))
                       (when (and (member to-id ids)
                                  (not (equal from-id to-id)))
                         (push (list from-id to-id) edges))))))))))
       "EXPORT_FILE_NAME<>\"\"" 'file))
    (let ((json-encoding-pretty-print t))
      (with-temp-file outfile
        (insert (json-encode `((nodes . ,nodes)
                               (edges . ,(delete-dups edges)))))))))

(defun org-astro--selective-property-inheritance ()
  "Return a list of properties that should be inherited."
  (let ((prop-list '("ASTRO_FRONT_MATTER_FORMAT"
                     "ASTRO_PREFER_HYPHEN_IN_TAGS"
                     "ASTRO_PRESERVE_FILLING"
                     "ASTRO_DELETE_TRAILING_WS"
                     "ASTRO_ALLOW_SPACES_IN_TAGS"
                     "ASTRO_BLACKFRIDAY"
                     "ASTRO_SECTION"
                     "ASTRO_SECTION_FRAG"
                     "ASTRO_BUNDLE"
                     "ASTRO_BASE_DIR"
                     "ASTRO_BASE_CONTENT_FOLDER"
                     "ASTRO_GOLDMARK"
                     "ASTRO_CODE_FENCE"
                     "HTML_CONTAINER"
                     "HTML_CONTAINER_CLASS"
                     "ASTRO_MENU"
                     "ASTRO_CUSTOM_FRONT_MATTER"
                     "ASTRO_DRAFT"
                     "ASTRO_ISCJKLANGUAGE"
                     "KEYWORDS"
                     "ASTRO_MARKUP"
                     "ASTRO_OUTPUTS"
                     "ASTRO_TAGS"
                     "ASTRO_CATEGORIES"
                     "ASTRO_SERIES"
                     "ASTRO_TYPE"
                     "ASTRO_LAYOUT"
                     "ASTRO_WEIGHT"
                     "ASTRO_RESOURCES"
                     "ASTRO_FRONT_MATTER_KEY_REPLACE"
                     "ASTRO_DATE_FORMAT"
                     "ASTRO_WITH_LOCALE"
                     "ASTRO_LOCALE"
                     "DATE" ;Useful for inheriting same date to same posts in different languages
                     "ASTRO_PUBLISHDATE"
                     "ASTRO_EXPIRYDATE"
                     "ASTRO_LASTMOD"
                     "ASTRO_SLUG" ;Useful for inheriting same slug to same posts in different languages
                     "ASTRO_AUTO_SET_LASTMOD"
                     "LANGUAGE"
                     "AUTHOR"
                     "OPTIONS")))
    (mapcar (lambda (str)
              (concat "EXPORT_" str))
            prop-list)))

(defun org-astro--get-valid-subtree ()
  "Return the Org element for a valid Hugo post subtree.
The condition to check validity is that the EXPORT_FILE_NAME
property is defined for the subtree element.

As this function is intended to be called inside a valid Hugo
post subtree, doing so also moves the point to the beginning of
the heading of that subtree.

Return nil if a valid Hugo post subtree is not found.  The point
will be moved in this case too."
  (let* ((subtree (car (org-astro--get-elem-with-prop :EXPORT_FILE_NAME)))
         (point (org-element-property :begin subtree))) ;`point' will be nil if `subtree' is nil
    (when point
      (goto-char point))
    subtree))

(defun org-astro--get-post-subtree-coordinates (subtree)
  "Return the coordinates for the current valid Hugo post SUBTREE.

The Org element returned by `org-astro--get-valid-subtree' is a
valid Hugo post subtree.

The returned value is of type (LEVEL . INDEX) where LEVEL is the
level number of the subtree and INDEX is as explained in the
below example.

If we have

  * Level 1
  ** Level A
  ** Level B
  ** Level C
  * Level 2

the INDEX will be 1 for Level 1 and Level A, 2 for Level
B and Level 2, and 3 for Level C.

So the value returned for Level C will be (2 . 3)."
  (save-excursion
    (let ((level (org-element-property :level subtree))
          (index 1)
          (current-pos (point))
          (scope (if (org-up-heading-safe)
                     'tree ;Map entries only in parent subtree scope if parent exists
                   nil))) ;Else map in the whole buffer (provided the MATCH conditions below)
      ;; (message "[org-astro--get-post-subtree-coordinates dbg] current-pos: %S, scope: %S"
      ;;          current-pos scope)
      (when level
        (org-map-entries (lambda ()
                           (when (< (point) current-pos)
                             (setq index (1+ index))))
                         ;; Loop through only headings that are at the
                         ;; same level as SUBTREE, and those which have
                         ;; the EXPORT_FILE_NAME property defined.
                         (concat "+LEVEL=" (number-to-string level)
                                 "+EXPORT_FILE_NAME<>\"\"")
                         scope)
        (cons level index)))))

(defun org-astro--export-file-to-md (f-or-b-name &optional async visible-only noerror)
  "Export the Org file as a whole.

Note: This is an internal function, use
`org-astro-export-wim-to-md' instead.

F-OR-B-NAME is the name of the file or buffer (if not a file
buffer) to be exported.

A non-nil optional argument ASYNC means the process should happen
asynchronously.  The resulting file should be accessible through the
`org-export-stack' interface.

When optional argument VISIBLE-ONLY is non-nil, don't export
contents of hidden elements.

Return the exported file name if the file has the #+title
keyword.

Else return nil and throw a user error.  If NOERROR is non-nil,
use `message' to display the error message instead of signaling a
user error."
  (let* ((info (org-combine-plists
                (org-export--get-export-attributes
                 'astro nil visible-only)
                (org-export--get-buffer-attributes)
                (org-export-get-environment 'astro)))
         (title (car (plist-get info :title)))
         ret)
    (if title
        (let* ((all-tags-1 (plist-get info :astro-tags))
               (all-tags (when all-tags-1
                           (split-string
                            (replace-regexp-in-string "\"" "" all-tags-1))))
               (exclude-tags (plist-get info :exclude-tags))
               is-excluded matched-exclude-tag)
          (when all-tags
            ;; (message "[org-astro--export-file-to-md DBG] exclude-tags = %s" exclude-tags)
            (dolist (exclude-tag exclude-tags)
              (when (member exclude-tag all-tags)
                (setq matched-exclude-tag exclude-tag)
                (setq is-excluded t))))
          (cond
           (is-excluded
            (message "[ox-astro] %s was not exported as it is tagged with an exclude tag `%s'"
                     f-or-b-name matched-exclude-tag))

           (t
            (message "[ox-astro] Exporting `%s' (%s)" title f-or-b-name)
            (setq ret (org-astro-export-to-md async nil visible-only)))))

      (let ((msg "The entire file is attempted to be exported, but it is missing the #+title keyword")
            (error-fn (if noerror
                          #'message
                        #'user-error)))
        (apply error-fn
               (list (format "[ox-astro] %s: %s" f-or-b-name msg)))))
    ret))

(defun org-astro--export-subtree-to-md (&optional async visible-only all-subtrees)
  "Export the current subtree to a Hugo post.

Note: This is an internal function, use
`org-astro-export-wim-to-md' instead.

A non-nil optional argument ASYNC means the process should happen
asynchronously.  The resulting file should be accessible through the
`org-export-stack' interface.

When optional argument VISIBLE-ONLY is non-nil, don't export
contents of hidden elements.

When optional argument ALL-SUBTREES is non-nil, print the
subtree-number being exported.

- If point is under a valid Hugo post subtree, export it, and
  also return the exported file name.

- If point is not under a valid Hugo post subtree, but one exists
  elsewhere in the Org file, do not export anything, but still
  return t.

- Else, return nil."
  (let ((subtree (org-astro--get-valid-subtree)))
    (if subtree
        ;; If subtree is a valid Hugo post subtree, proceed ..
        (let* ((info (org-combine-plists
                      (org-export--get-export-attributes
                       'astro subtree visible-only)
                      (org-export--get-buffer-attributes)
                      (org-export-get-environment 'astro subtree)))
               (exclude-tags (plist-get info :exclude-tags))
               (is-commented (cdr (org-astro--get-elem-with-prop :commentedp)))
               (commented-heading (when is-commented
                                    (org-element-property :title
                                      (car (org-astro--get-elem-with-prop :commentedp)))))
               is-excluded matched-exclude-tag ret)
          ;; (message "[org-astro--export-subtree-to-md DBG] exclude-tags =
          ;; %s" exclude-tags)
          (let ((all-tags (let ((org-use-tag-inheritance t))
                            (org-astro--get-tags))))
            (when all-tags
              (dolist (exclude-tag exclude-tags)
                (when (member exclude-tag all-tags)
                  (setq matched-exclude-tag exclude-tag)
                  (setq is-excluded t)))))

          ;; (message "[current subtree DBG] subtree: %S" subtree)
          ;; (message "[current subtree DBG] is-commented:%S, tags:%S,
          ;; is-excluded:%S" is-commented tags is-excluded)
          (let ((title (org-element-property :title subtree))
                ;; FIXME: Sometimes `org-get-outline-path' returns the
                ;; list with empty string elements. It's not clear
                ;; why, but the below `cl-delete-if' workarounds works
                ;; (for now).
                (current-outline-path (cl-delete-if
                                       (lambda (el)
                                         (string= el ""))
                                       (org-get-outline-path :with-self)))
                ;; When batch-exporting subtrees, do not call
                ;; `org-astro--after-all-exports-function' after each
                ;; subtree export.  In that case, that function is
                ;; called *after* looping through all the post
                ;; subtrees.
                (org-astro--disable-after-all-exports-hook all-subtrees))
            ;; (message "[org-astro--export-subtree-to-md dbg] @ point %S, current-outline-path: %S"
            ;;          (point) current-outline-path)
            (cond
             (is-commented
              (if (string= title commented-heading)
                  (message "[ox-astro] `%s' was not exported as it is commented out" title)
                (message "[ox-astro] `%s' was not exported as one of its parent subtrees `%s' is commented out"
                         title commented-heading)))
             (is-excluded
              (message "[ox-astro] `%s' was not exported as it is tagged with an exclude tag `%s'"
                       title matched-exclude-tag))
             (t
              (if all-subtrees
                  (progn
                    (setq org-astro--subtree-count (1+ org-astro--subtree-count))
                    (message "[ox-astro] %d/ Exporting `%s' .." org-astro--subtree-count title))
                (message "[ox-astro] Exporting `%s' .." title))

              ;; (message "[org-astro--export-subtree-to-md dbg] EXPORT_ASTRO_MENU value: %S"
              ;;          (org-entry-get nil "EXPORT_ASTRO_MENU" :inherit))
              ;; Get the current subtree coordinates for
              ;; auto-calculation of menu item weight, page or
              ;; taxonomy weights ..
              (when (or
                     ;; .. if the menu front-matter is specified.
                     (or
                      (org-entry-get nil "EXPORT_ASTRO_MENU" :inherit)
                      (save-excursion
                        (goto-char (point-min))
                        (let ((case-fold-search t))
                          (re-search-forward "^#\\+hugo_menu:.*:menu" nil :noerror))))
                     ;; .. or if auto-calculation is needed for page
                     ;; or taxonomy weights.
                     (or
                      (let ((page-or-taxonomy-weight (org-entry-get nil "EXPORT_ASTRO_WEIGHT" :inherit)))
                        (and (stringp page-or-taxonomy-weight)
                             (string-match-p "auto" page-or-taxonomy-weight)))
                      (save-excursion
                        (goto-char (point-min))
                        (let ((case-fold-search t))
                          (re-search-forward "^#\\+hugo_weight:.*auto" nil :noerror)))))
                (setq org-astro--subtree-coord
                      (org-astro--get-post-subtree-coordinates subtree)))

              (let ((buffer (if org-astro--preprocess-buffer
                                (let ((pre-proc-buf (or org-astro--preprocessed-buffer
                                                        (org-astro--get-pre-processed-buffer))))
                                  (unless org-astro--preprocessed-buffer
                                    (setq org-astro--preprocessed-buffer pre-proc-buf)
                                    (add-to-list 'org-astro--opened-buffers pre-proc-buf))
                                  pre-proc-buf)
                              (current-buffer))))
                (with-current-buffer buffer
                  (goto-char (org-find-olp current-outline-path :this-buffer))
                  (setq ret (org-astro-export-to-md async :subtreep visible-only)))))))
          ret)

      ;; If the point is not in a valid subtree, check if there's a
      ;; valid subtree elsewhere in the same Org file.
      (let ((valid-subtree-found (org-astro--buffer-has-valid-post-subtree-p)))
        (when valid-subtree-found
          (message "Point is not in a valid Hugo post subtree; move to one and try again"))
        valid-subtree-found))))

(defun org-astro--get-pre-processed-buffer ()
  "Return a pre-processed copy of the current buffer.

Internal links to other subtrees are converted to external
links."
  (let ((pre-processed-buffer-prefix "*Ox-astro Pre-processed "))
    (let* (;; Create an abstract syntax tree (AST) of the Org document
           ;; in the current buffer.
           (ast (org-element-parse-buffer))
           (org-use-property-inheritance (org-astro--selective-property-inheritance))
           (info (org-combine-plists
                  (list :parse-tree ast)
                  (org-export--get-export-attributes 'astro)
                  (org-export--get-buffer-attributes)
                  (org-export-get-environment 'astro))))

      ;; Process all link elements in the AST.
      (org-element-map ast '(link special-block)
        (lambda (el)
          (let ((el-type (org-element-type el)))
            (cond
             ((equal 'link el-type)
              (let ((type (org-element-property :type el)))
                (when (member type '("custom-id" "id" "fuzzy"))
                  (let* ((raw-link (org-element-property :raw-link el))
                         (destination
                          ;; Derived from ox.el -> `org-export-data'.  If a broken link is seen
                          ;; and if `broken-links' option is not nil, ignore the error.
                          (condition-case err
                              (if (string= type "fuzzy")
                                  (org-export-resolve-fuzzy-link el info)
                                (org-export-resolve-id-link el (org-export--collect-tree-properties ast info)))
                            (org-link-broken
                             (unless (or (plist-get info :with-broken-links)
                                         ;; Parse the `:EXPORT_OPTIONS' property if set
                                         ;; in a parent heading.
                                         (plist-get
                                          (org-export--parse-option-keyword
                                           (or (cdr (org-astro--get-elem-with-prop
                                                     :EXPORT_OPTIONS
                                                     (org-element-property :begin el)))
                                               ""))
                                          :with-broken-links))
                               (user-error "Unable to resolve link: %S" (nth 1 err))))))
                         (source-path (org-astro--heading-get-slug el info :inherit-export-file-name))
                         (destination-path (org-astro--heading-get-slug destination info :inherit-export-file-name))
                         (destination-type (org-element-type destination)))
                    ;; (message "[ox-astro pre process DBG] destination-type : %s" destination-type)

                    ;; Change the link if it points to a valid
                    ;; destination outside the subtree.
                    (unless (or  (equal source-path destination-path)
                                 (and (string= type "id")
                                      (org-id-find-id-file
                                       (org-element-property :path el))))
                      (let ((link-desc (org-element-contents el)))
                        ;; (message "[ox-astro pre process DBG] link desc: %s" link-desc)

                        ;; Override the link types to be files.  We
                        ;; will be using out-of-subtree links as links
                        ;; to dummy files with
                        ;; `org-astro--preprocessed-buffer-dummy-file-suffix'
                        ;; suffix.
                        (org-element-put-property el :type "file")
                        (org-element-put-property
                         el :path
                         (cond
                          ;; If the destination is a heading with the
                          ;; :EXPORT_FILE_NAME property defined, the
                          ;; link should point to the file (without
                          ;; anchor).
                          ((org-element-property :EXPORT_FILE_NAME destination)
                           (concat destination-path org-astro--preprocessed-buffer-dummy-file-suffix))
                          ;; Hugo only supports anchors to headings,
                          ;; so if a "fuzzy" type link points to
                          ;; anything else than a heading, it should
                          ;; point to the file.
                          ((and (string= type "fuzzy")
                                (not (string-prefix-p "*" raw-link)))
                           (concat destination-path org-astro--preprocessed-buffer-dummy-file-suffix))
                          ;; In "custom-id" type links, the raw-link
                          ;; matches the anchor of the destination.
                          ((string= type "custom-id")
                           (concat destination-path org-astro--preprocessed-buffer-dummy-file-suffix "::" raw-link))
                          ;; In "id" and "fuzzy" type links, the anchor
                          ;; of the destination is derived from the
                          ;; :CUSTOM_ID property or the title.
                          (t
                           (let ((anchor (org-astro--get-anchor destination info)))
                             (concat destination-path org-astro--preprocessed-buffer-dummy-file-suffix "::#" anchor)))))
                        ;; If the link destination is a heading and if
                        ;; user hasn't set the link description, set the
                        ;; description to the destination heading title.
                        (when (and (null link-desc)
                                   (equal 'headline destination-type))
                          (let ((heading-title
                                 (org-export-data-with-backend
                                  (org-element-property :title destination) 'ascii info)))
                            ;; (message "[ox-astro pre process DBG] destination heading: %s" heading-title)
                            (org-element-set-contents el heading-title)))))))))
             ((equal 'special-block el-type)
              ;; Handle empty Org special blocks.  When empty
              ;; blocks are found, set that elements content as ""
              ;; instead of nil.
              (unless (org-element-contents el)
                (org-element-adopt-elements el "")))))
          nil)) ;Minor performance optimization: Make `org-element-map' lambda return a nil.

      (when (version< "25.99" emacs-version) ;`kill-matching-buffers' got `:no-ask' arg in emacs 26.1
        ;; https://git.savannah.gnu.org/cgit/emacs.git/commit/?id=70d01daceddeb4e4c49c79473c81420f65ffd290
        ;; First kill all the old pre-processed buffers if still left open
        ;; for any reason.
        (kill-matching-buffers (regexp-quote pre-processed-buffer-prefix) :internal-too :no-ask))

      ;; Turn the AST with updated links into an Org buffer.
      (let ((local-variables (buffer-local-variables))
            (bound-variables (org-export--list-bound-variables))
            (buffer (generate-new-buffer (concat pre-processed-buffer-prefix (buffer-name) " *"))))
        (with-current-buffer buffer
          (let (vars)
            (org-astro--org-mode-light)
            ;; Copy specific buffer local variables and variables set
            ;; through BIND keywords.  Below snippet is copied from
            ;; ox.el -> `org-export--generate-copy-script'.
            (dolist (entry local-variables vars)
              (when (consp entry)
                (let ((var (car entry))
                      (val (cdr entry)))
                  (and (not (memq var org-export-ignored-local-variables))
                       (or (memq var
                                 '(default-directory
                                    buffer-file-name
                                    buffer-file-coding-system))
                           (assq var bound-variables)
                           (string-match "^\\(org-\\|orgtbl-\\)"
                                         (symbol-name var)))
                       ;; Skip unreadable values, as they cannot be
                       ;; sent to external process.
                       (or (not val) (ignore-errors (read (format "%S" val))))
                       (push (set (make-local-variable var) val) vars)))))

            (insert (org-element-interpret-data ast))
            (set-buffer-modified-p nil)))
        buffer))))



;;; Interactive functions

;;;###autoload
(defun org-astro-export-as-md (&optional async subtreep visible-only)
  "Export current buffer to a Hugo-compatible Markdown buffer.

If narrowing is active in the current buffer, only export its
narrowed part.

If a region is active, export that region.

A non-nil optional argument ASYNC means the process should happen
asynchronously.  The resulting buffer should be accessible
through the `org-export-stack' interface.

When optional argument SUBTREEP is non-nil, export the sub-tree
at point, extracting information from the heading properties
first.

When optional argument VISIBLE-ONLY is non-nil, don't export
contents of hidden elements.

Export is done in a buffer named \"*Org Hugo Export*\", which
will be displayed when `org-export-show-temporary-export-buffer'
is non-nil.

Return the buffer the export happened to."
  (interactive)
  (org-astro--before-export-function subtreep)
  ;; Allow certain `ox-astro' properties to be inherited.
  (let ((org-use-property-inheritance (org-astro--selective-property-inheritance))
        (info (org-combine-plists
               (org-export--get-export-attributes
                'astro subtreep visible-only)
               (org-export--get-buffer-attributes)
               (org-export-get-environment 'astro subtreep))))
    (prog1
        (org-export-to-buffer 'astro "*Org Hugo Export*"
          async subtreep visible-only nil nil (lambda () (text-mode)))
      (org-astro--after-1-export-function info nil)
      (org-astro--after-all-exports-function))))

;;;###autoload
(defun org-astro-export-to-md (&optional async subtreep visible-only)
  "Export current buffer to a Hugo-compatible Markdown file.

This is the main exporting function which is called by both
`org-astro--export-file-to-md' and
`org-astro--export-subtree-to-md', and thus
`org-astro-export-wim-to-md' too.

If narrowing is active in the current buffer, only export its
narrowed part.

If a region is active, export that region.

A non-nil optional argument ASYNC means the process should happen
asynchronously.  The resulting file should be accessible through
the `org-export-stack' interface.

When optional argument SUBTREEP is non-nil, export the sub-tree
at point, extracting information from the heading properties
first.

When optional argument VISIBLE-ONLY is non-nil, don't export
contents of hidden elements.

Return output file's name."
  (interactive)
  (org-astro--before-export-function subtreep)
  ;; Allow certain `ox-astro' properties to be inherited.  It is
  ;; important to set the `org-use-property-inheritance' before
  ;; setting the `info' var so that properties like
  ;; EXPORT_ASTRO_SECTION get inherited.
  (let* ((org-use-property-inheritance (org-astro--selective-property-inheritance))
         (info (org-combine-plists
                (org-export--get-export-attributes
                 'astro subtreep visible-only)
                (org-export--get-buffer-attributes)
                (org-export-get-environment 'astro subtreep)))
         (pub-dir (org-astro--get-pub-dir info))
         ;; Don't print "Saving file .." for each exported file. This
         ;; works in interactive mode i.e. when exporting posts from
         ;; within emacs.  But in --batch mode, setting
         ;; `save-silently' to t, ironically prints a blank line
         ;; instead of the "Saving file .." message.  So leave this
         ;; variable value at nil for --batch runs.
         (save-silently (unless noninteractive
                          t))
         (outfile (org-export-output-file-name ".md" subtreep pub-dir)))
    ;; (message "[org-astro-export-to-md DBG] section-dir = %s" section-dir)
    (prog1
        (org-export-to-file 'astro outfile async subtreep visible-only)
      (org-astro--after-1-export-function info outfile)
      (unless org-astro--disable-after-all-exports-hook
        (org-astro--after-all-exports-function)))))

;;;###autoload
(defun org-astro-export-wim-to-md (&optional all-subtrees async visible-only noerror)
  "Export the current subtree/all subtrees/current file to a Hugo post.

This is an Export \"What I Mean\" function:

- If the current subtree has the \"EXPORT_FILE_NAME\" property,
  export only that subtree.  Return the return value of
  `org-astro--export-subtree-to-md'.

- If the current subtree doesn't have that property, but one of
  its parent subtrees has, export from that subtree's scope.
  Return the return value of `org-astro--export-subtree-to-md'.

- If there are no valid Hugo post subtrees (that have the
  \"EXPORT_FILE_NAME\" property) in the Org buffer the subtrees
  have that property, do file-based
  export (`org-astro--export-file-to-md'), regardless of the value
  of ALL-SUBTREES.  Return the return value of
  `org-astro--export-file-to-md'.

- If ALL-SUBTREES is non-nil and the Org buffer has at least 1
  valid Hugo post subtree, export all those valid post subtrees.
  Return a list of output files.

A non-nil optional argument ASYNC means the process should happen
asynchronously.  The resulting file should be accessible through
the `org-export-stack' interface.

When optional argument VISIBLE-ONLY is non-nil, don't export
contents of hidden elements.

The optional argument NOERROR is passed to
`org-astro--export-file-to-md'."
  (interactive "P")
  (let ((f-or-b-name (if (buffer-file-name)
                         (file-name-nondirectory (buffer-file-name))
                       (buffer-name)))
        (buf-has-subtree (org-astro--buffer-has-valid-post-subtree-p))
        ret)

    ;; Auto-update `org-id-locations' if it's nil or empty hash table
    ;; to avoid broken [[id:..]] type links.
    (unless org-id-locations (org-id-locations-load))
    (when (or (null org-id-locations) (zerop (hash-table-count org-id-locations)))
      (org-id-update-id-locations (directory-files "." :full "\\.org$" :nosort) :silent))

    (org-astro--cleanup)

    (save-window-excursion
      (org-with-wide-buffer
       (cond
        ;; Publish all subtrees in the current Org buffer.
        ((and buf-has-subtree all-subtrees)
         (let ((start-time (current-time)))
           ;; Make the *Messages* buffer less noisy when exporting all
           ;; subtrees.
           (dolist (fn org-astro--all-subtrees-export--functions-to-silence)
             (advice-add fn :around #'org-astro--advice-silence-messages))

           (setq ret (org-map-entries
                      (lambda ()
                        (org-astro--export-subtree-to-md async visible-only :all-subtrees))
                      ;; Export only the subtrees where
                      ;; EXPORT_FILE_NAME property is not empty.
                      "EXPORT_FILE_NAME<>\"\""))

           (let* ((elapsed-time (float-time (time-since start-time)))
                  (avg-time (/ elapsed-time org-astro--subtree-count)))
             (message "[ox-astro] Exported %d subtree%s from %s in %0.3fs (%0.3fs avg)"
                      org-astro--subtree-count
                      (if (= 1 org-astro--subtree-count) "" "s")
                      f-or-b-name
                      elapsed-time
                      avg-time))
           (org-astro--after-all-exports-function)))

        ;; Publish only the current valid Hugo post subtree.  When
        ;; exporting only one subtree, buffer pre-processing is done
        ;; inside `org-astro--export-subtree-to-md'.
        ((and buf-has-subtree (not all-subtrees))
         (setq ret (org-astro--export-subtree-to-md async visible-only)))

        ;; Attempt file-based export.
        (t
         (setq ret (org-astro--export-file-to-md f-or-b-name async visible-only noerror))))))
    ret))

;;;###autoload
(defun org-astro-debug-info ()
  "Get Emacs and Org version and ox-astro customization info.
The information is converted to Markdown format and copied to the
kill ring.  The same information is displayed in the Messages
buffer and returned as a string in Org format."
  (interactive)
  (let* ((emacs-version (emacs-version))
         (org-version (org-version nil :full))
         (info-org (mapconcat #'identity
                              `("* Debug information for =ox-astro="
                                "** Emacs Version"
                                "#+begin_example"
                                ,(format "%s%s"
                                         emacs-version
                                         (if emacs-repository-version
                                             (format " (commit %s)" emacs-repository-version)
                                           ""))
                                "#+end_example"
                                "** Org Version"
                                "#+begin_example"
                                ,org-version
                                "#+end_example"
                                "** =ox-astro= defcustoms"
                                ,(format "|org-astro-section                                      |%S|" org-astro-section)
                                ,(format "|org-astro-use-code-for-kbd                             |%S|" org-astro-use-code-for-kbd)
                                ,(format "|org-astro-preserve-filling                             |%S|" org-astro-preserve-filling)
                                ,(format "|org-astro-delete-trailing-ws                           |%S|" org-astro-delete-trailing-ws)
                                ,(format "|org-astro-prefer-hyphen-in-tags                        |%S|" org-astro-prefer-hyphen-in-tags)
                                ,(format "|org-astro-allow-spaces-in-tags                         |%S|" org-astro-allow-spaces-in-tags)
                                ,(format "|org-astro-tag-processing-functions                     |%S|" org-astro-tag-processing-functions)
                                ,(format "|org-astro-auto-set-lastmod                             |%S|" org-astro-auto-set-lastmod)
                                ,(format "|org-astro-export-with-toc                              |%S|" org-astro-export-with-toc)
                                ,(format "|org-astro-export-with-section-numbers                  |%S|" org-astro-export-with-section-numbers)
                                ,(format "|org-astro-front-matter-format                          |%S|" org-astro-front-matter-format)
                                ,(format "|org-astro-date-format                                  |%S|" org-astro-date-format)
                                ,(format "|org-astro-suppress-lastmod-period                      |%S|" org-astro-suppress-lastmod-period))
                              "\n"))
         (org-export-with-toc nil)
         (info-md (progn
                    (require 'ox-md)
                    (org-export-string-as info-org 'md :body-only))))
    (kill-new info-md)
    (message "%s" info-org)
    info-org))


(provide 'ox-astro)

;;; ox-astro.el ends here
