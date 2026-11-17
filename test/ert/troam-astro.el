;;; troam-astro.el --- Tests for the ox-astro Org-roam subsystem  -*- lexical-binding: t; -*-

;; Tests for the roam unit table, the roamID/roamLinks front-matter
;; keys, the `id:' link translation to /blog/<slug>/ and the roam
;; graph JSON export (absorbed from the ai/cleanroom-v0 donor).

;;; Code:

(require 'org-test-lib-astro)
(require 'ox-astro)

(defconst troam-doc
  "* Post one
:PROPERTIES:
:ID:       id-one
:EXPORT_FILE_NAME: post-one
:END:
Content one.

* Post two
:PROPERTIES:
:ID:       id-two
:EXPORT_FILE_NAME: post-two
:END:
Links to [[id:id-one][post one]] and [[id:missing][a missing node]].
"
  "Two roam units; the second links to the first by org-id.")

(ert-deftest test-roam/unit-table ()
  "The roam table lists every post subtree carrying an org-id."
  (org-test-with-parsed-data troam-doc
    (should (equal (org-astro--get-roam-table)
                   '(("id-one" "post-one" "Post one")
                     ("id-two" "post-two" "Post two"))))))

(ert-deftest test-roam/front-matter-keys ()
  "roamID and roamLinks land in the exported front matter."
  (org-test-with-parsed-data troam-doc
    (goto-char (point-min))
    (re-search-forward "^\\* Post two" nil :noerror)
    (let ((fm (org-astro--get-front-matter info)))
      (should (string-match "roamID: *\"id-two\"" fm))
      (should (string-match "roamLinks:.*post-one" fm))
      (should-not (string-match "roamLinks:.*missing" fm)))))

(ert-deftest test-roam/id-link-translates-to-slug ()
  "An `id:' link to a sibling unit exports as its /blog/<slug>/ page."
  (org-test-with-parsed-data troam-doc
    (let ((org-astro--roam-table '(("id-one" "post-one" "Post one")))
          link)
      (org-element-map (org-element-parse-buffer) 'link
        (lambda (l)
          (when (and (string= "id" (org-element-property :type l))
                     (string= "id-one" (org-element-property :path l)))
            (setq link l))))
      (should link)
      (should (equal (org-astro-link link "post one" info)
                     "[post one](/blog/post-one/)")))))

(ert-deftest test-roam/graph-json ()
  "The roam graph JSON carries the nodes and the id-to-id edges."
  (org-test-with-parsed-data troam-doc
    (let ((outfile (make-temp-file "ox-astro-roam" nil ".json")))
      (unwind-protect
          (progn
            (org-astro-export-roam-graph outfile)
            (with-temp-buffer
              (insert-file-contents outfile)
              (let ((json (buffer-string)))
                (should (string-match "\"id-one\"" json))
                (should (string-match "\"post-two\"" json))
                ;; the edge from post two's id to post one's id
                (should (string-match "\"id-two\",[[:space:]]*\"id-one\"" json)))))
        (delete-file outfile)))))

(provide 'troam-astro)
;;; troam-astro.el ends here
