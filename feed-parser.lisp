;;
;; Copyright 2016 Drew Thoreson
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, version 2 of the
;; License.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, see <http://www.gnu.org/licenses/>.
;;

;; feed-parser.lisp
;;
;; This package implements parsers for RSS and Atom feeds.  A parser is a
;; function taking a character stream as input and returning a Feed object and
;; a list of Item objects.
(in-package :feed-parser)

;; Mapping between namespace URIs and prefixes for stored metadata.
(defparameter *namespace-prefixes*
  '(("http://purl.org/dc/elements/1.1/"             . "dc")
    ("http://purl.org/rss/1.0/modules/content/"     . "content")
    ("http://purl.org/rss/1.0/modules/syndication/" . "sy")
    ("http://search.yahoo.com/mrss/"                . "media")
    ("http://www.w3.org/2005/Atom"                  . "atom")))

;; Returns a qualified tag name for use within the aggregator.  The rules for
;; generating a qualified name are as follows:
;;
;;   * If the tag has no namespace, then the qualified name is equal to the
;;     tag name.
;;   * If the namespace has an entry in *namespace-prefixes*, then the
;;     qualified name is <prefix>:<local-name>.
;;   * Otherwise the qualified name is {<namespace-uri>}:<local-name>
(defun qualified-tag-name (element)
  (if (dom:namespace-uri element)
    (let ((prefix-mapping (assoc (dom:namespace-uri element)
                                 *namespace-prefixes*
                                 :test #'string=)))
      (if prefix-mapping
        (format nil "~a:~a" (cdr prefix-mapping) (dom:local-name element))
        (format nil "{~a}:~a" (dom:namespace-uri element) (dom:local-name element))))
    (dom:tag-name element)))

(defun tag-name= (name element)
  (and (dom:element-p element) (string= name (qualified-tag-name element))))

;;
;; DOM Helpers
;;
;; Because the DOM is missing some really obvious functions.
;;

;; Returns the first child of an element with a given tag name
(defun get-child-by-tag-name (element name)
  (find name (dom:child-nodes element) :test #'tag-name=))

;; Returns all children of an element with a given tag name
(defun get-children-by-tag-name (element name)
  (loop for x in (dom:child-nodes element)
        when (tag-name= name x) collect x))

;; Returns a list of attributes for an element.
(defun get-attributes (element)
  (let ((attrs (dom:attributes element)))
    (loop for i upto (1- (dom:length attrs)) collect (dom:item attrs i))))

(defun concatenate-text (element)
  (labels ((char-whitespace-p (ch)
             (case ch
               ((#\space #\tab #\newline) t)
               (otherwise nil)))
           (string-whitespace-p (str)
             (loop for char across str
                   when (not (char-whitespace-p char)) do (return nil)
                   finally (return t))))
    (format nil "~{~a~}"
            (loop for child across (dom:child-nodes element)
                  when (and (dom:text-node-p child)
                            (not (string-whitespace-p (dom:node-value child))))
                  collect (dom:node-value child)))))

;; Returns a list with the following contents:
;;
;;   (<qualified-tag-name> <attribute-list> <children> <text>)
;;
;; Where:
;;
;;   * <qualified-tag-name> is the qualified tag name of the element, as
;;     produced by the function qualified-tag-name.
;;   * <attribute-list> is an alist associating attribute names with
;;     their corresponding values.
;;   * <children> is a list of child metadata elements, as produced by the
;;     recursive application of this function.
;;   * <text> is the result of concatenating all the text nodes in the element.
(defun parse-metadata (element name-map)
  (if (dom:element-p element)
    (let* ((name (qualified-tag-name element))
           (mapping (assoc name name-map :test #'string=)))
      (list ; if there is a handler, use the name given in the handler
            (if mapping (second mapping) name)
            ; attributes
            (mapcar #'(lambda (attr)
                        (cons (dom:name attr) (dom:value attr)))
                    (get-attributes element))
            ; child elements
            (loop for child across (dom:child-nodes element)
                  when (dom:element-p child) collect (parse-metadata child name-map))
            ; value (concatenated text, or computed value)
            (if (and mapping
                     (third mapping))
              (funcall (third mapping) element)
              (concatenate-text element))))
    ; skip non-element nodes
    nil))

(defun parse-date-text (element)
  (format nil "~a"
    (cl-date-time-parser:parse-date-time
      (concatenate-text element))))

(defun parse-atom-link (element)
  (let ((href (find-if (lambda (x) (string= (dom:name x) "href"))
                       (get-attributes element))))
    (if href
      (dom:value href)
      "#")))

 ;; Creates a Feed object from the channel element of an RSS feed.
(defun parse-rss-channel (channel)
  (loop for child across (dom:child-nodes channel)
        unless (or (not (dom:element-p child))
                   (tag-name= "item" child))
        collect (parse-metadata child
                  `(("pubDate"       "published" ,#'parse-date-text)
                    ("lastBuildDate" "updated"   ,#'parse-date-text)))))

(defun parse-rss-item (item)
  (loop for child across (dom:child-nodes item)
        when (dom:element-p child)
        collect (parse-metadata child
                  `(("pubDate"         "published" ,#'parse-date-text)
                    ("content:encoded" "content")))))

;; Parser for RSS feeds
(defun *parse-rss (xml)
  (let* ((rss (dom:document-element xml))
         (channel (find "channel" (dom:child-nodes rss) :test #'tag-name=)))
    (cond
      ((not (tag-name= "rss" rss))
        nil) ; TODO: error
      ((not channel)
        nil) ; TODO: error
      (t
        (values (parse-rss-channel channel)
                (loop for child across (dom:child-nodes channel)
                      when (tag-name= "item" child)
                      collect (parse-rss-item child)))))))

(defun parse-rss (source)
  (*parse-rss (cxml:parse-stream source (cxml-dom:make-dom-builder))))

;; Atom Feeds
;;
;; TODO: XHTML contents

(defun parse-atom-feed (feed)
  (loop for child across (dom:child-nodes feed)
        unless (or (not (dom:element-p child))
                   (tag-name= "atom:entry" child))
        collect (parse-metadata child
                  `(("atom:title"    "title")
                    ("atom:updated"  "updated"     ,#'parse-date-text)
                    ("atom:subtitle" "description")))))

(defun parse-atom-entry (entry)
  (loop for child across (dom:child-nodes entry)
        when (dom:element-p child)
        collect (parse-metadata child
                  `(("atom:title"     "title")
                    ("atom:summary"   "description")
                    ("atom:content"   "content")
                    ("atom:id"        "guid")
                    ("atom:link"      "link"      ,#'parse-atom-link)
                    ("atom:published" "published" ,#'parse-date-text)
                    ("atom:updated"   "updated"   ,#'parse-date-text)))))

;; Parser for Atom feeds
(defun *parse-atom (xml)
  (let* ((feed (dom:document-element xml)))
    (if (tag-name= "atom:feed" feed)
      (values (parse-atom-feed feed)
              (loop for child across (dom:child-nodes feed)
                    when (tag-name= "atom:entry" child)
                    collect (parse-atom-entry child)))
      ; TODO: error
      nil)))

(defun parse-atom (source)
  (*parse-atom (cxml:parse-stream source (cxml-dom:make-dom-builder))))

;; This "parser" will try to determine the type of feed and dispatch to the
;; appropriate parser.  It only knows about RSS and Atom feeds.
(defun parse-auto (source)
  ; determine type from XML root element, then dispatch to real parser
  (let* ((xml (cxml:parse-stream source (cxml-dom:make-dom-builder)))
         (root-tag (dom:tag-name (dom:document-element xml))))
    (cond
      ((string= root-tag "rss") (*parse-rss xml))
      ((string= root-tag "feed") (*parse-atom xml))
      ; TODO: error
      (t nil))))

;; TODO: parsers for typical log files on UNIX systems.

(defparameter *parsers*
  (list (cons "auto" #'parse-auto)
        (cons "rss" #'parse-rss)
        (cons "atom" #'parse-atom)))

(defun get-parser (name)
  (let ((parser (assoc name *parsers* :test #'string=)))
    (if parser
      (cdr parser)
      nil)))

(defun register-parser (name parser)
  (acons name parser *parsers*))

(defun parse (parser-name source)
  (funcall (get-parser parser-name) source))
