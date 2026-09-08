;;; tslug.el --- Tests related to slug string derivation           -*- lexical-binding: t; -*-

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

;;; Code:

(require 'org-test-lib-astro)
(require 'ox-astro)

(ert-deftest test-slug/return-nil ()
  "Test nil return conditions."

  ;; Empty title
  (should
   (equal nil
          (org-test-with-parsed-data
              "* <point>"
            (let ((el (org-element-at-point)))
              (org-astro--heading-get-slug el info)))))

  ;; Heading with EXPORT_FILE_NAME.
  (should
   (equal nil
          (org-test-with-parsed-data
              "* Some Heading<point>"
            (let ((el (org-element-at-point)))
              (org-astro--heading-get-slug el info))))))

(ert-deftest test-slug/ignore-astro-slug ()
  "Test that EXPORT_ASTRO_SLUG is not used to derive the slug."
  ;; EXPORT_FILE_NAME + EXPORT_ASTRO_SLUG
  (should
   (string= "posts/file"
            (org-test-with-parsed-data
                "* Some Heading<point>
:PROPERTIES:
:EXPORT_FILE_NAME: file
:EXPORT_ASTRO_SLUG: slug
:END:"
              (let ((el (org-element-at-point)))
                (org-astro--heading-get-slug el info)))))

  ;; EXPORT_FILE_NAME + EXPORT_ASTRO_SLUG + EXPORT_ASTRO_SECTION
  (should
   (string= "section/file"
            (org-test-with-parsed-data
                "* Section
:PROPERTIES:
:EXPORT_ASTRO_SECTION: section
:END:
** Some Heading<point>
:PROPERTIES:
:EXPORT_FILE_NAME: file
:EXPORT_ASTRO_SLUG: slug
:END:"
              (let ((el (nth 1 (org-element-map tree 'headline #'identity info))))
                (org-astro--heading-get-slug el info))))))

(ert-deftest test-slug/export-file-name ()
  "Test derivation of the slug from EXPORT_FILE_NAME."

  ;; Only EXPORT_FILE_NAME
  (should
   (string= "posts/file"
            (org-test-with-parsed-data
                "* Some Heading<point>
:PROPERTIES:
:EXPORT_FILE_NAME: file
:END:"
              (let ((el (org-element-at-point)))
                (org-astro--heading-get-slug el info)))))

  ;; EXPORT_FILE_NAME + EXPORT_ASTRO_SECTION
  (should
   (string= "section/file"
            (org-test-with-parsed-data
                "* Section
:PROPERTIES:
:EXPORT_ASTRO_SECTION: section
:EXPORT_OPTIONS: toc:t
:END:
** Some Heading<point>
:PROPERTIES:
:EXPORT_FILE_NAME: file
:END:"
              (let ((el (nth 1 (org-element-map tree 'headline #'identity info))))
                (org-astro--heading-get-slug el info))))))

;; Leaf bundles
(ert-deftest test-slug/leaf-bundles ()
  "Test derivation of the slug leaf bundles."
  (should
   (string= "posts/leaf"
            (org-test-with-parsed-data
                "* Some Heading<point>
:PROPERTIES:
:EXPORT_ASTRO_BUNDLE: leaf
:EXPORT_FILE_NAME: index
:END:"
              (let ((el (org-element-at-point)))
                (org-astro--heading-get-slug el info)))))

  ;; Leaf bundle in a section
  (should
   (string= "section/leaf"
            (org-test-with-parsed-data
                "* Section
:PROPERTIES:
:EXPORT_ASTRO_SECTION: section
:END:
** Some Heading<point>
:PROPERTIES:
:EXPORT_ASTRO_BUNDLE: leaf
:EXPORT_FILE_NAME: index
:END:"
              (let ((el (nth 1 (org-element-map tree 'headline #'identity info))))
                (org-astro--heading-get-slug el info))))))

;; Branch bundles
(ert-deftest test-slug/branch-bundles ()
  (should
   (string= "posts/branch"
            (org-test-with-parsed-data
                "* Some Heading<point>
:PROPERTIES:
:EXPORT_ASTRO_BUNDLE: branch
:EXPORT_FILE_NAME: _index
:END:"
              (let ((el (org-element-at-point)))
                (org-astro--heading-get-slug el info)))))

  ;; Inherit :EXPORT_ASTRO_BUNDLE
  (should
   (string= "posts/branch"
            (org-test-with-parsed-data
                "* Branch bundle
:PROPERTIES:
:EXPORT_ASTRO_BUNDLE: branch
:END:
** Landing page<point>
:PROPERTIES:
:EXPORT_FILE_NAME: _index
:END:"
              (let ((el (nth 1 (org-element-map tree 'headline #'identity info))))
                (org-astro--heading-get-slug el info)))))

  ;; Page in branch bundle, inheritance
  (should
   (string= "posts/branch/branch-page"
            (org-test-with-parsed-data
                "* Branch bundle
:PROPERTIES:
:EXPORT_ASTRO_BUNDLE: branch
:END:
** Branch page<point>
:PROPERTIES:
:EXPORT_FILE_NAME: branch-page
:END:"
              (let ((el (nth 1 (org-element-map tree 'headline #'identity info))))
                (org-astro--heading-get-slug el info)))))

  ;; Branch bundle in a section
  (should
   (string= "section/branch"
            (org-test-with-parsed-data
                "* Section
:PROPERTIES:
:EXPORT_ASTRO_SECTION: section
:END:
** Branch bundle
:PROPERTIES:
:EXPORT_ASTRO_BUNDLE: branch
:END:
*** Some Heading<point>
:PROPERTIES:
:EXPORT_FILE_NAME: _index
:END:"
              (let ((el (nth 2 (org-element-map tree 'headline #'identity info))))
                (org-astro--heading-get-slug el info)))))

  ;; Branch page in a branch bundle in a section
  (should
   (string= "section/branch/branch-page"
            (org-test-with-parsed-data
                "* Section
:PROPERTIES:
:EXPORT_ASTRO_SECTION: section
:END:
** Branch bundle
:PROPERTIES:
:EXPORT_ASTRO_BUNDLE: branch
:END:
*** Some Heading<point>
:PROPERTIES:
:EXPORT_FILE_NAME: branch-page
:END:"
              (let ((el (nth 2 (org-element-map tree 'headline #'identity info))))
                (org-astro--heading-get-slug el info))))))

;; Section
(ert-deftest test-slug/section ()

  ;; Section keyword
  (should
   (string= "section/file"
            (org-test-with-parsed-data
                "#+astro_section: section
* Some Heading<point>
:PROPERTIES:
:EXPORT_FILE_NAME: file
:END:"
              (let ((el (org-element-at-point)))
                (org-astro--heading-get-slug el info))))))

;; Section fragments
(ert-deftest test-slug/section-fragments ()

  (should
   (string= "section/sec2/sec3/file"
            (org-test-with-parsed-data
                "* Section
:PROPERTIES:
:EXPORT_ASTRO_SECTION: section
:END:
** Section 2
:PROPERTIES:
:EXPORT_ASTRO_SECTION_FRAG: sec2
:END:
*** Section 3
:PROPERTIES:
:EXPORT_ASTRO_SECTION_FRAG: sec3
:END:
**** Some page<point>
:PROPERTIES:
:EXPORT_FILE_NAME: file
:END:"
              (let ((el (nth 3 (org-element-map tree 'headline #'identity info))))
                (org-astro--heading-get-slug el info)))))

  ;; Branch page in a branch bundle in section fragments.
  (should
   (string= "section/sec2/sec3/branch/branch-page"
            (org-test-with-parsed-data
                "* Section
:PROPERTIES:
:EXPORT_ASTRO_SECTION: section
:END:
** Section 2
:PROPERTIES:
:EXPORT_ASTRO_SECTION_FRAG: sec2
:END:
*** Section 3
:PROPERTIES:
:EXPORT_ASTRO_SECTION_FRAG: sec3
:EXPORT_ASTRO_BUNDLE: branch
:END:
**** Branch bundle
:PROPERTIES:
:EXPORT_ASTRO_BUNDLE: branch
:END:
***** Some page<point>
:PROPERTIES:
:EXPORT_FILE_NAME: branch-page
:END:"
              (let ((el (nth 4 (org-element-map tree 'headline #'identity info))))
                (org-astro--heading-get-slug el info))))))

;;;; GitHub slugger (`org-astro-slug')
;;
;; These vectors are ported verbatim from github-slugger's
;; test/fixtures.json (the package Astro uses for heading anchors and
;; content entry ids).  They run sequentially against one slugger
;; state, exactly like upstream, because dedup results depend on
;; history.  The giant Unicode category sweep fixtures are excluded:
;; they depend on the exact Unicode version and would be brittle in
;; Emacs; realistic CJK/Cyrillic/emoji cases below cover the goal.

(ert-deftest test-astro-slug/fixtures-sequential ()
  "Test `org-astro-slug' against github-slugger fixture vectors.
All calls share one slugger state, run in fixture order."
  ;; One shared state for the whole sequence:
  (org-astro--slug-reset)
  (let (run)
    (setq run (lambda (input expected)
                (should (string= (org-astro-slug input) expected))))
    ;; "Basic usage"
    (funcall run "alpha" "alpha")
    ;; "Basic usage (again)"
    (funcall run "alpha" "alpha-1")
    ;; "Camelcase"
    (funcall run "bravoCharlieDelta" "bravocharliedelta")
    ;; "Prototypal injection: proto" (underscores survive)
    (funcall run "__proto__" "__proto__")
    ;; "Prototypal injection: proto (again)"
    (funcall run "__proto__" "__proto__-1")
    ;; "Prototypal injection: has own"
    (funcall run "hasOwnProperty" "hasownproperty")
    ;; "Repetition (1..5)" -- base counter keeps climbing through
    ;; collisions with literal "echo-1" inputs.
    (funcall run "echo" "echo")
    (funcall run "echo" "echo-1")
    (funcall run "echo 1" "echo-1-1")
    (funcall run "echo-1" "echo-1-2")
    (funcall run "echo" "echo-2")
    ;; "More repetition (1..3)" -- "foxtrot-1" collides, so the next
    ;; "foxtrot" jumps to "foxtrot-2".
    (funcall run "foxtrot-1" "foxtrot-1")
    (funcall run "foxtrot" "foxtrot")
    (funcall run "foxtrot" "foxtrot-2")
    ;; "Characters: dash" (ASCII hyphen survives, spaces -> hyphens)
    (funcall run "heading with a - dash" "heading-with-a---dash")
    ;; "Characters: underscore"
    (funcall run "heading with an _ underscore" "heading-with-an-_-underscore")
    ;; "Characters: dot"
    (funcall run "heading with a period.txt" "heading-with-a-periodtxt")
    ;; "Characters: dots, parents, brackets"
    (funcall run "exchange.bind_headers(exchange, routing [, bindCallback])"
             "exchangebind_headersexchange-routing--bindcallback")
    ;; "Characters: space"
    (funcall run " " "-")
    ;; "Characters: initial space"
    (funcall run " a" "-a")
    ;; "Characters: final space"
    (funcall run "a " "a-")
    ;; "Characters: initial and final spaces"
    (funcall run " a " "-a-")
    ;; "Characters: initial and final dashes" (collides with " a ")
    (funcall run "-a-" "-a--1")
    ;; "Characters: apostrophe" (typographic apostrophe is dropped)
    (funcall run "apostrophe’s should be trimmed" "apostrophes-should-be-trimmed")
    ;; "Some more duplicates (1..3)"
    (funcall run "golf" "golf")
    (funcall run "golf" "golf-1")
    (funcall run "golf" "golf-2")
    ;; "Non-ascii: ♥"
    (funcall run "I ♥ unicode" "i--unicode")
    ;; "Non-ascii: dash / en-dash / em-dash"
    (funcall run "dash-dash" "dash-dash")
    (funcall run "en–dash" "endash")
    (funcall run "em–dash" "emdash")
    ;; "Non-ascii: emoji" (removed, surrounding spaces become hyphens)
    (funcall run "😄 unicode emoji" "-unicode-emoji")
    (funcall run "😄-😄 unicode emoji" "--unicode-emoji")
    (funcall run "😄_😄 unicode emoji" "_-unicode-emoji")
    (funcall run "😄 - an emoji" "---an-emoji")
    ;; "Non-ascii: gemoji"
    (funcall run ":smile: - a gemoji" "smile---a-gemoji")
    ;; "Non-ascii: Cyrillic"
    (funcall run "Привет" "привет")
    (funcall run "Профили пользователей" "профили-пользователей")
    ;; "Non-ascii: Cyrillic + Han"
    (funcall run "Привет non-latin 你好" "привет-non-latin-你好")
    ;; "Gemoji (1..4)"
    (funcall run ":ok: No underscore" "ok-no-underscore")
    (funcall run ":ok_hand: Single" "ok_hand-single")
    (funcall run ":ok_hand::hatched_chick: Two in a row with no spaces"
             "ok_handhatched_chick-two-in-a-row-with-no-spaces")
    (funcall run ":ok_hand: :hatched_chick: Two in a row"
             "ok_hand-hatched_chick-two-in-a-row")))

(ert-deftest test-astro-slug/stateless ()
  "Test the stateless `org-astro--slugify' core."
  ;; Same input always yields the same result:
  (should (string= (org-astro--slugify "foo bar baz")
                   (org-astro--slugify "foo bar baz")))
  ;; Lowercasing and space -> hyphen:
  (should (string= (org-astro--slugify "Foo Bar!") "foo-bar"))
  ;; Empty and non-string input:
  (should (string= (org-astro--slugify "") ""))
  (should (string= (org-astro--slugify nil) ""))
  ;; MAINTAIN-CASE argument:
  (should (string= (org-astro--slugify "Foo Bar" :maintain-case) "Foo-Bar")))

(ert-deftest test-astro-slug/reset ()
  "Test that `org-astro--slug-reset' forgets all dedup history."
  (org-astro--slug-reset)
  (should (string= (org-astro-slug "foo") "foo"))
  (should (string= (org-astro-slug "foo") "foo-1"))
  (org-astro--slug-reset)
  (should (string= (org-astro-slug "foo") "foo")))


(provide 'tslug-astro)

;; Note: As of 2022-03-17, Org stable or bugfix version's (9.5.2)
;; `org-element-at-point' returns the Org element at point *but*
;; without any of the inherited properties. So `org-element-map' is
;; used where property inheritance needs to be tested (because that
;; does do the prop inheritance as expected!). This issue doesn't
;; exist in the `main' branch version of `org-element-at-point'.
;;
;; To get the 1st heading element: (nth 0 (org-element-map tree 'headline #'identity info))
;; To get the 2nd heading element: (nth 1 (org-element-map tree 'headline #'identity info))
;; ..
