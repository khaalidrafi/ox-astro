;;; tfm-astro.el --- Tests for Astro front-matter generation     -*- lexical-binding: t; -*-

;; Authors: Kaushal Modi <kaushal.modi@gmail.com>
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

;; Tests for `org-astro--get-front-matter' and
;; `org-astro--gen-front-matter' (Step 3: Astro YAML front matter).

;;; Code:

(require 'org-test-lib-astro)
(require 'ox-astro)
(require 'yaml)				;For `yaml-parse-string' in tests

(defun tfm-parse (data)
  "Parse Org DATA and return front matter as a decoded alist.
Runs the `astro' backend export flow on DATA in a temp buffer,
moves point into the first heading (like a subtree export would),
captures the generated front matter string, strips the `---'
fences (yaml.el cannot parse them) and parses the rest back with
`yaml-parse-string' for convenient assertions."
  (org-test-with-parsed-data data
    ;; Move to the first headline so subtree properties like the TODO
    ;; state and ALLTAGS are visible at point.
    (goto-char (point-min))
    (when (re-search-forward org-heading-regexp nil :noerror)
      (goto-char (match-beginning 0)))
    (let* ((fm (org-astro--get-front-matter info))
           (inner (replace-regexp-in-string
                   "\\`---\n" ""
                   (replace-regexp-in-string "\n---\n\\'" "" fm))))
      (yaml-parse-string inner :object-type 'alist :object-key-type 'symbol))))

(defun tfm-true-p (value)
  "Return non-nil if decoded YAML VALUE means true."
  (member value '(t :true)))

(defun tfm-false-p (value)
  "Return non-nil if decoded YAML VALUE means false."
  (member value '(nil :false :null)))

(ert-deftest test-fm/basic-keys ()
  "Test basic Astro front-matter keys and YAML output."
  (let ((fm (tfm-parse
             "#+title: Some Heading
#+description: Some description
#+date: <2017-07-06 Thu>
* Some Heading
:PROPERTIES:
:EXPORT_FILE_NAME: file
:END:")))
    ;; Astro uses title/pubDate/updatedDate/draft:
    (should (equal "Some Heading" (alist-get 'title fm)))
    ;; draft is a real YAML boolean, false by default:
    (should (tfm-false-p (alist-get (quote draft) fm)))
    ;; description came through:
    (should (equal "Some description" (alist-get 'description fm)))
    ;; pubDate is present and ISO-8601-ish (date part at least):
    (should (string-match-p
             "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]"
             (alist-get 'pubDate fm)))))

(ert-deftest test-fm/draft-from-todo ()
  "Test that a non-DONE TODO state marks the post as draft."
  (let ((fm (tfm-parse
             "#+title: Some Heading
* TODO Some Heading
:PROPERTIES:
:EXPORT_FILE_NAME: file
:END:")))
    (should (tfm-true-p (alist-get (quote draft) fm))))
  ;; DONE keyword -> not a draft.
  (let ((fm (tfm-parse
             "#+title: Some Heading
* DONE Some Heading
:PROPERTIES:
:EXPORT_FILE_NAME: file
:END:")))
    (should (tfm-false-p (alist-get (quote draft) fm)))))

(ert-deftest test-fm/tags-and-categories ()
  "Test tags from Org tags and categories from @-tags."
  (let ((fm (tfm-parse
             "#+title: Some Heading
* Some Heading :tag1:tag2:@cat1:@cat2:
:PROPERTIES:
:EXPORT_FILE_NAME: file
:END:")))
    ;; Non-@ tags -> tags; @-tags -> categories (without the @).
    (should (equal ["cat1" "cat2"] (alist-get 'categories fm)))
    (should (member "tag1" (append (alist-get 'tags fm) nil)))
    (should (member "tag2" (append (alist-get 'tags fm) nil)))))

(ert-deftest test-fm/yaml-syntax ()
  "Test the generated front matter is valid YAML with --- fences."
  (org-test-with-parsed-data
      "#+title: Some Heading
* Some Heading
:PROPERTIES:
:EXPORT_FILE_NAME: file
:END:"
    (let ((fm (org-astro--get-front-matter info)))
      ;; Delimiters:
      (should (string-prefix-p "---\n" fm))
      (should (string-suffix-p "\n---\n" fm))
      ;; Parsed back (after stripping the fences) it must contain
      ;; the title.
      (let ((inner (replace-regexp-in-string
                    "\\`---\n" ""
                    (replace-regexp-in-string "\n---\n\\'" "" fm)))
            (parsed (yaml-parse-string
                     (replace-regexp-in-string
                      "\\`---\n" ""
                      (replace-regexp-in-string "\n---\n\\'" "" fm))
                     :object-type 'alist :object-key-type 'symbol)))
        (should (string-match-p "title:" inner))
        (should (equal "Some Heading" (alist-get 'title parsed)))))))

(ert-deftest test-fm/toml-still-supported ()
  "Test TOML front matter still works when ASTRO_FRONT_MATTER_FORMAT is toml."
  (let ((fm (org-test-with-parsed-data
             "#+title: Some Heading
#+astro_front_matter_format: toml
* Some Heading
:PROPERTIES:
:EXPORT_FILE_NAME: file
:END:"
             (org-astro--get-front-matter info))))
    (should (string-prefix-p "+++\n" fm))
    (should (string-suffix-p "\n+++\n" fm))
    ;; tomelr should have produced a title line:
    (should (string-match-p "title = " fm))))

(provide 'tfm-astro)
