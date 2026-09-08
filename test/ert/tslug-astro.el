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
