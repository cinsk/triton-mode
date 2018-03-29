;;; triton-ssh.el ---                            -*- lexical-binding: t; -*-

;; Copyright (C) 2017  Seong-Kook Shin

;; Author: Seong-Kook Shin <cinsky@gmail.com>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;
;;
;;
;;
;; (cl-pushnew '("-A")
;;             (cadr (assoc 'tramp-login-args
;;                          (assoc "ssh" tramp-methods)))
;;             :test #'equal)


;;; Code:


(require 'term)
(require 'json)
(require 'cl)
(require 'ssh)

(defvar triton-ssh-program "ssh" "Pathname of executable of SSH")
(defvar triton-pssh-program "pssh" "Pathname of executable of pssh")

(defstruct triton-network name id public description)
(defstruct triton-image name id version os type default-user)
(defstruct triton-instance name id package brand ips primaryip networks image updated mark)
;; (setq inst-foo (make-triton-instance :name "foo" :ips '("1.1.1.1" "2.2.2.2") :primaryip "2.2.2.2"))

;; TODO: check all lisp codes whether all properly generate errors if
;; `triton-current-profile' is nil
;;(defvar triton-current-profile nil)
(defvar triton-profile-history nil)

(defvar triton-bastion-default-ssh-port 22)
(defvar triton-instance-default-ssh-port 22)
(defvar triton-instance-default-user-name nil)

(defvar triton-known-networks (make-hash-table :test 'equal :weakness nil))
(defvar triton-known-images (make-hash-table :test 'equal :weakness nil))

(defvar triton--image-databases '())
(defvar triton--network-databases '())

(defvar triton-bastion-name "bastion")

(defvar triton-pssh-process nil)
(defvar triton-pssh-buffer-name "*triton-pssh*")

(defun triton-log (format &rest args)
  (let ((message (apply #'format format args)))
    (with-current-buffer (get-buffer-create "*triton-log*")
      (goto-char (point-max))
      (insert message)
      (unless (bolp)
        (insert "\n")))))

(defun triton--get-profile (profile)
  (let ((prof (or profile triton-current-profile)))
    (unless prof
      (error "profile not found"))
    prof))

(defun triton--get-image-database (profile)
  (let ((db (cdr (assoc profile triton--image-databases))))
    (unless db
      (let ((newdb (make-hash-table :test 'equal :weakness nil)))
        (add-to-list 'triton--image-databases
                     (cons profile newdb))
        (setq db newdb)))
    db))

(defun triton--get-network-database (profile)
  (let ((db (cdr (assoc profile triton--network-databases))))
    (unless db
      (let ((newdb (make-hash-table :test 'equal :weakness nil)))
        (add-to-list 'triton--network-databases
                     (cons profile newdb))
        (setq db newdb)))
    db))


(defun triton--image-as-string (image profile)
  (let ((img (if (triton-image-p image)
                 image
               (triton--get-cached-image image profile))))
    (if img
        (format "%s@%s" (triton-image-name img) (triton-image-version img))
      (substring image 0 8))))

(defun triton-instance-mark-as-string (i)
  (let ((mark (triton-instance-mark i)))
    (if mark
        (format "%c" mark)
      " ")))

(defun triton--run-command (command profile)
  "Insert the output from running COMMAND into the current buffer.

Current buffer will be erased before the execution.
The error output will be stored in *triton-error* buffer, if any.

If PROFILE is nil, `triton-current-profile' will be used."
  (let ((cmd (concat (if profile
                         (format "eval \"$(triton env %s)\";" profile)
                       "")
                     command))
        (error-file (make-temp-file
                     (expand-file-name "scor"
                                       (or small-temporary-file-directory
                                           temporary-file-directory)))))
    (erase-buffer)

    (let ((exit-code (call-process "/bin/bash" nil
                                   (list t error-file) nil
                                   "-c" cmd)))
      (when (file-exists-p error-file)
        (with-current-buffer (get-buffer-create "*triton-error*")
          (let ((pos-from-end (- (point-max) (point))))
            (or (bobp)
                (insert "\f\n"))
            (format-insert-file error-file nil)
            (goto-char (- (point-max) pos-from-end))))
        (delete-file error-file))
      exit-code)))

(defun triton--parse-next-instance ()
  (let (js)
    (condition-case e
        (progn
          (setq js (json-read))
          (make-triton-instance :name (cdr (assoc 'name js))
                                :id (cdr (assoc 'id js))
                                :package (cdr (assoc 'package js))
                                :brand (cdr (assoc 'brand js))
                                :ips (cdr (assoc 'ips js))
                                :updated (cdr (assoc 'updated js))
                                :primaryip (cdr (assoc 'primaryIp js))))
      (json-end-of-file nil))))

(defun triton--parse-instances ()
  (let (instances js)
    (condition-case e
        (progn
          (while (setq js (json-read))
            (let ((inst (make-triton-instance :name (cdr (assoc 'name js))
                                              :id (cdr (assoc 'id js))
                                              :package (cdr (assoc 'package js))
                                              :brand (cdr (assoc 'brand js))
                                              :ips (cdr (assoc 'ips js))
                                              :updated (cdr (assoc 'updated js))
                                              :primaryip (cdr (assoc 'primaryIp js))
                                              :networks (cdr (assoc 'networks js))
                                              :image (cdr (assoc 'image js)))))
              (setq instances (cons inst instances))))
          )
      (json-end-of-file instances))))


(defun triton--set-profile (profile &optional ask)
  (setq triton-current-profile (or profile
                                   (when ask (triton--read-profile))
                                   triton-current-profile)))

(defun triton--read-profile ()
  (completing-read "Triton Profile: "
                   (split-string
                    (shell-command-to-string "triton profile ls -H -o name"))
                   nil
                   t
                   nil
                   'triton-profile-history
                   nil
                   nil))

(defun triton--read-instance (&optional prompt profile)
  (completing-read (or prompt "machine: ")
                   (mapcar (lambda (inst)
                             (cons (triton-instance-name inst)
                                   (triton-instance-primaryip inst)))
                           (triton-list-instances profile))
                   nil
                   t
                   nil))

(defun triton--read-instance-name (prompt &optional initial)
  (completing-read prompt
                   (mapcar (lambda (inst)
                             (cons (triton-instance-name inst)
                                   (triton-instance-primaryip inst)))
                           (triton-list-instances triton-local-profile))
                   nil
                   t
                   initial))

(defun triton--read-boolean (prompt &optional initial)
  (y-or-n-p prompt))

(defun triton--list-instance-buffer (profile)
  (let ((buffer (get-buffer-create (format " *triton-%s*" profile))))
    (with-current-buffer buffer
      (make-local-variable 'triton-buffer-modified-at)
      (unless (boundp 'triton-buffer-modified-at)
        (setq triton-buffer-modified-at nil))
      (setq buffer-read-only t)
      buffer)))

(defun triton--update-instances (profile)
  (let ((buffer (triton--list-instance-buffer profile)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (triton--run-command "triton instance ls -j" profile)
        ;; TODO: only set `triton-buffer-modified-at' if run-command
        ;; was successfull.
        (setq triton-buffer-modified-at (float-time)))
      ;; `shell-command' seems to make the buffer writable
      (setq buffer-read-only t))))

(defvar triton-buffer-expiration (* 60 60 6))

(defun triton-list-instances (profile)
  (let* ((buffer (triton--list-instance-buffer profile)))
    (with-current-buffer buffer
      (when (or (null triton-buffer-modified-at)
                (> (- (float-time) triton-buffer-modified-at)
                   triton-buffer-expiration))
        (triton--update-instances profile))
      (goto-char (point-min))
      (triton--parse-instances))))

(defun triton-get-instance-by-name (name profile)
  (car (seq-filter (lambda (inst)
                     (string-equal (triton-instance-name inst) name))
                   (triton-list-instances profile))))

(defun triton-instance-public-p (inst profile)
  (some (lambda (nid)
          (eq (triton-network-public (triton-get-network nid profile)) t))
        (triton-instance-networks inst)))

(defun triton-instance-default-user (inst profile)
  (let ((image (or (and inst (triton-get-image (triton-instance-image inst) profile))
                   nil)))
    (or (and image (triton-image-default-user image))
        triton-instance-default-user-name
        "root")))

(defun triton--host-user-name (instance &optional default)
  (or default
      (let ((image (and instance (triton-get-image (triton-instance-image instance)
                                                   triton-local-profile))))
        (or (and image (triton-image-default-user image))
            "root"))))

(defun triton-get-network (network profile)
  (let ((cached (gethash network triton-known-networks)))
    (or cached
        (with-current-buffer (get-buffer-create "*triton*")
          (triton--run-command
           (format "triton network get -j \"%s\"" network)
           profile)
          (goto-char (point-min))
          (let ((js (json-read)))
            (puthash network
                     (make-triton-network :name (cdr (assoc 'name js))
                                          :id (cdr (assoc 'id js))
                                          :public (cdr (assoc 'public js))
                                          :description (cdr (assoc 'description js)))
                     triton-known-networks))))))

(defun triton--get-cached-image (image profile)
  (let* ((prof (triton--get-profile profile))
         (db (triton--get-image-database prof))
         (cached (gethash image db)))
    cached))

(defun triton-get-image (image profile)
  (let* ((prof (triton--get-profile profile))
         (db (triton--get-image-database prof))
         (cached (gethash image db)))
    (or cached
        (with-current-buffer (get-buffer-create "*triton*")
          (condition-case e
              (progn
                (triton--run-command
                 (format "triton image get -j \"%s\"" image) prof)
                (goto-char (point-min))
                (let ((js (json-read)))
                  (puthash image
                           (make-triton-image :name (cdr (assoc 'name js))
                                              :id (cdr (assoc 'id js))
                                              :version (cdr (assoc 'version js))
                                              :os (cdr (assoc 'os js))
                                              :type (cdr (assoc 'type js))
                                              :default-user (cdr (assoc 'default_user (cdr (assoc 'tags js)))))
                           db)))
            (json-end-of-file nil))))))

(defun triton--list-image-buffer (profile)
  (let ((buffer (get-buffer-create (format " *triton-images-%s*" profile))))
    (with-current-buffer buffer
      (make-local-variable 'triton-buffer-modified-at)
      (unless (boundp 'triton-buffer-modified-at)
        (setq triton-buffer-modified-at nil))
      (setq buffer-read-only t)
      buffer)))

(defun triton--update-image (profile)
  (let ((buffer (triton--list-image-buffer profile)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (triton--run-command "triton image ls -j" profile)
        ;; TODO: only set `triton-buffer-modified-at' if run-command
        ;; was successfull.
        (setq triton-buffer-modified-at (float-time)))
      ;; `shell-command' seems to make the buffer writable
      (setq buffer-read-only t))))

(defun triton--load-images (&optional profile)
  (let ((prof (triton--get-profile profile)))
    (let ((buffer (triton--list-image-buffer prof)))
      (with-current-buffer buffer
        (when (or (null triton-buffer-modified-at)
                  (> (- (float-time) triton-buffer-modified-at)
                     triton-buffer-expiration))
          (triton--update-image prof))
        (goto-char (point-min))
        (triton--parse-images prof)))))

(defun triton--parse-images (profile)
  (let ((db (triton--get-image-database profile))
        instances js)
    (condition-case e
        (progn
          (while (setq js (json-read))
            (let ((image (make-triton-image :name (cdr (assoc 'name js))
                                           :id (cdr (assoc 'id js))
                                           :version (cdr (assoc 'version js))
                                           :os (cdr (assoc 'os js))
                                           :type (cdr (assoc 'type js))
                                           :default-user (cdr (assoc 'default_user (cdr (assoc 'tags js)))))))
              (puthash (triton-image-id image) image db))
          ))
      (json-end-of-file instances))))

(defun triton--tramp-prefix (instance &optional
                                      user port
                                      bastion buser bport
                                      profile
                                      force-bastion)
  (let ((public (triton-instance-public-p instance profile))
        (h-user (or user (triton-instance-default-user instance profile)))
        (h-port (or port triton-instance-default-ssh-port))
        (b-user (or buser
                    (and bastion
                         (triton-instance-default-user bastion profile))
                    "root"))
        (b-port (or bport triton-bastion-default-ssh-port)))
    (if (and public (not force-bastion))
        (format "/ssh:%s@%s#%d:"
                h-user (triton-instance-primaryip instance) h-port)
      (format "/ssh:%s@%s#%d|ssh:%s@%s#%d:"
              b-user (triton-instance-primaryip bastion) b-port
              h-user (triton-instance-primaryip instance) h-port
              ))))


(defun triton--read-parameters (&optional ask-profile ask-bastion)
  (let* ((profile (if ask-profile (triton--set-profile nil 'ask)
                    triton-current-profile))
         (host-name (triton--read-instance "host: " profile))
         (host (triton-get-instance-by-name host-name))
         (bastion-name (cond (ask-bastion (triton--read-instance "bastion: " profile))
                             ((triton-instance-public-p host) nil)
                             ((triton-get-instance-by-name "bastion") "bastion")
                             (t (triton--read-instance "bastion: " profile))))
         (bastion (triton-get-instance-by-name bastion-name)))
    (list host (triton-instance-default-user host) triton-instance-default-ssh-port
          bastion (triton-instance-default-user bastion) triton-bastion-default-ssh-port)))

(defun triton-shell (&optional host host-user host-port bastion bastion-user bastion-port)
  (interactive (let ((ask-bastion (>= (prefix-numeric-value current-prefix-arg) 16))
                     (ask-profile (>= (prefix-numeric-value current-prefix-arg) 4)))
                 (triton--read-parameters ask-profile ask-bastion)))
  (let ((prefix (triton--tramp-prefix host host-user host-port bastion bastion-user bastion-port)))
    (let ((default-directory prefix))
      (shell (format "*shell-%s@%s*" (triton-instance-name host) triton-current-profile)))))

(defun triton-dired (&optional host host-user host-port bastion bastion-user bastion-port)
  (interactive (let ((ask-bastion (>= (prefix-numeric-value current-prefix-arg) 16))
                     (ask-profile (>= (prefix-numeric-value current-prefix-arg) 4)))
                 (triton--read-parameters ask-profile ask-bastion)))
  (let ((prefix (triton--tramp-prefix host host-user host-port bastion bastion-user bastion-port)))
    (find-file prefix)))

(defun triton-short-id (s)
  (substring s 0 8))

(defun triton--insert-metadata (key-var type-var new-value label &optional read-func)
  ;; (unless pos
  ;;   (setq pos (next-single-property-change (point-min) key-var)))
  ;; (if (null pos)
  ;;     (error "key %S not found" key-var)
  ;;   (kill-line 1)
  (set key-var new-value)
  (let ((begin (point)))
    (insert (format "* %s: " label))
    (setq point-offset (- (point) (line-beginning-position)))
    (insert (propertize (format "%s" new-value) 'face 'triton-metadata-value-face))

    (add-text-properties begin (point)
                         (list 'key key-var
                               'value new-value
                               'label label
                               'type type-var
                               'point-offset point-offset
                               'read-function read-func
                               'keymap (let ((kmap (make-sparse-keymap)))
                                         (define-key kmap [(return)] 'triton-update-metadata)
                                         (define-key kmap [?e] 'triton-update-metadata)
                                         kmap)))))

(defun triton-update-metadata ()
  (interactive)
  (save-excursion
    (let ((key (get-text-property (point) 'key))
          (label (get-text-property (point) 'label))
          (type (get-text-property (point) 'type))
          (oldval (get-text-property (point) 'value))
          (point-offset (get-text-property (point) 'point-offset))
          (readfunc (or (get-text-property (point) 'read-function) #'read-from-minibuffer))
          newval)

      (setq newval
            (apply readfunc (list (format "%s: " label) (format "%s" oldval))))
      (cond ((eq type 'integer)
             (setq newval (string-to-number newval)))
            ((eq type 'string)
             (if (eq (length newval) 0)
                 (setq newval nil)))
            ((eq type 'boolean))
            (t (error "invalid metadata type: %s" type)))

      (set key newval)
      (goto-char (+ (line-beginning-position) point-offset))
      (let ((inhibit-read-only t)
            (props (text-properties-at (line-beginning-position))))
        (kill-line)
        (insert (propertize (format "%s" newval) 'face 'triton-metadata-value-face))
        (plist-put props 'value newval)
        (add-text-properties (line-beginning-position) (line-end-position) props)
        ))))





(defun triton--fill-buffer (profile)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (let ((instances (triton-list-instances profile)))
      (insert (format "Joyent Triton at %s\n\n" triton-local-profile))
      ;; triton-local-bastion-ssh-port triton-bastion-default-ssh-port
      ;; triton-local-bastion-host-name triton-bastion-name
      ;; triton-local-bastion-user-name nil
      ;; triton-local-ssh-port triton-instance-default-ssh-port
      ;; triton-local-user-name nil)

      (triton--insert-metadata 'triton-local-bastion-ssh-port 'integer
                               triton-bastion-default-ssh-port
                               "Bastion machine SSH port")
      (newline)
      (triton--insert-metadata 'triton-local-bastion-host-name 'string
                               triton-bastion-name
                               "Bastion machine name"
                               #'triton--read-instance-name)
      (newline)
      (triton--insert-metadata 'triton-local-bastion-user-name 'string
                               nil
                               "Overridden Bastion user name")
      (newline)
      (triton--insert-metadata 'triton-local-ssh-port 'integer
                               22
                               "SSH port for machines")
      (newline)
      (triton--insert-metadata 'triton-local-user-name 'string
                               nil
                               "Overriden Machine user name")
      (newline)
      (triton--insert-metadata 'triton-local-force-bastion 'boolean
                               nil
                               "Use Bastion on public machine"
                               #'triton--read-boolean)
      (newline)

      (newline)
      (insert (format "M INSTANCE IMAGE                           PACKAGE               UPDATED\n"))
      (insert (format "- -------- ------------------------------- --------------------- ------------------------\n"))
      (dolist (i instances)
        (let ((begin (point)))
          (triton--update-line i)
          (newline)
          ))))
  (current-buffer))

(defun triton--update-line (&optional instance)
  (unless instance
    (setq instance (get-text-property (point) 'instance)))
  (when instance
    (beginning-of-line)
    (let ((begin (point)))
      (unless (eobp) (kill-line))
      (let ((mark (triton-instance-mark instance)))
        (insert (format "%s %s %-31s %-20s %25s "
                        (propertize (triton-instance-mark-as-string instance)
                                    'face 'triton-mark-face)
                        (triton-short-id (triton-instance-id instance))
                        (triton--image-as-string
                         (triton-instance-image instance) triton-local-profile)
                        (triton-instance-package instance)
                        (triton-instance-updated instance)))
        (let ((point-offset (- (point) (line-beginning-position))))
          (insert (format "%s" (if mark
                                   (propertize (triton-instance-name instance)
                                               'face 'triton-mark-face)
                                 (triton-instance-name instance))))
          (add-text-properties begin (point)
                               (list 'instance instance
                                     'key instance ; anything unique will do
                                     'point-offset point-offset))
          )))))

(defun triton--redraw-buffer ()
  (let ((inhibit-read-only t) pos)
    (save-excursion
      (goto-char (point-min))
      (setq pos (next-single-property-change (point) 'instance))
      (when pos
        (goto-char pos)
        (while (not (eobp))
          (triton--update-line)
          (next-line 1))))))

(defmacro triton--do-marked-instances (spec &rest body)
  ;; TODO: need more test.
  ;; TODO: should I test this macro on dynamic binding?
  (declare (indent 1) (debug ((symbolp &optional symbolp) body)))
  (let ((instance (make-symbol "INSTANCE"))
        (pos (make-symbol "POS"))
        (retval (make-symbol "RETVAL")))
    `(let (,pos)
       (save-excursion
         (goto-char (point-min))
         (while (setq ,pos (next-single-property-change (point) 'instance))
           (goto-char ,pos)
           (let ((,instance (get-text-property (point) 'instance)))
             (when (triton-instance-mark ,instance)
               (let ((,(car spec) ,instance))
                 ,@body))))
         ,@(cdr spec)))))

(defmacro triton--do-instances (spec &rest body)
  ;; TODO: need more test.
  ;; TODO: should I test this macro on dynamic binding?
  (declare (indent 1) (debug ((symbolp &optional symbolp) body)))
  (let ((pos (make-symbol "POS"))
        (retval (make-symbol "RETVAL")))
    `(let (,pos)
       (save-excursion
         (goto-char (point-min))
         (while (setq ,pos (next-single-property-change (point) 'instance))
           (goto-char ,pos)
           (let ((,(car spec) (get-text-property (point) 'instance)))
             ,@body))
         ,@(cdr spec)))))


(defun triton--marked-instances ()
  (let (marked)
    (triton--do-marked-instances (instance marked)
      (setq marked (cons instance marked)))))

(defun triton--marked-instances--old ()
  (let (marked pos)
    (save-excursion
      (goto-char (point-min))
      (while (setq pos (next-single-property-change (point) 'instance))
        (goto-char pos)
        (let ((instance (get-text-property (point) 'instance)))
          (when (triton-instance-mark instance)
            (setq marked (cons instance marked))))))
    marked))

;;;###autoload
(defun triton (&optional profile)
  (interactive (list (triton--read-profile)))
  (let ((bufname (format "*triton-%s*" profile)))
    (if (get-buffer bufname)
        (pop-to-buffer (get-buffer bufname))
      (triton--load-images profile)
      (let ((buffer (get-buffer-create bufname)))
        (with-current-buffer buffer
          (triton-mode)
          (setq triton-local-profile profile
                triton-local-images (triton--get-image-database profile)
                triton-local-networks (triton--get-network-database profile)
                triton-local-bastion-ssh-port triton-bastion-default-ssh-port
                triton-local-bastion-host-name triton-bastion-name
                triton-local-bastion-user-name nil
                triton-local-ssh-port triton-instance-default-ssh-port
                triton-force-bastion nil
                triton-local-user-name nil)
          (triton--fill-buffer profile)
          (goto-char (point-min))
          (pop-to-buffer buffer))))))

(defun triton-previous-line (&optional arg)
  (interactive "p")
  (dotimes (dummy arg)
    (let ((notfound t)
          (pos (previous-single-property-change (line-beginning-position) 'key)))

      (while notfound
        (if (or (null pos) (get-text-property pos 'key))
            (setq notfound nil)
          (setq pos (previous-single-property-change pos 'key))))

      (when pos
        (let ((offset (get-text-property pos 'point-offset)))
          (goto-char pos)
          (when offset
            (goto-char (+ offset (line-beginning-position))))
                     (setq notdone nil))))))

(defun triton-next-line (&optional arg)
  (interactive "p")
  (dotimes (dummy arg)
    (let ((notfound t)
          (pos (next-single-property-change (line-end-position) 'key)))

      (while notfound
        (if (or (null pos) (get-text-property pos 'key))
            (setq notfound nil)
          (setq pos (next-single-property-change pos 'key))))

      (when pos
        (let ((offset (get-text-property pos 'point-offset)))
          (goto-char pos)
          (when offset
            (goto-char (+ offset (line-beginning-position))))
                     (setq notdone nil))))))


(defun triton-mark-line (&optional arg)
  (interactive)
  (let ((instance (get-text-property (point) 'instance)))
    (unless instance
      (triton-next-line 1)
      (setq instance (get-text-property (point) 'instance)))
    (when instance
      (setf (triton-instance-mark instance) ?\*)
      (let ((oldpos (point))
            (inhibit-read-only t))
        (triton--update-line instance)
        (goto-char oldpos))
      (triton-next-line 1))))

(defun triton-unmark-line (&optional arg)
  (interactive)
  (let ((instance (get-text-property (point) 'instance)))
    (unless instance
      (triton-next-line 1)
      (setq instance (get-text-property (point) 'instance)))
    (when instance
      (setf (triton-instance-mark instance) nil)
      (let ((oldpos (point))
            (inhibit-read-only t))
        (triton--update-line instance)
        (goto-char oldpos))
      (triton-next-line 1))))

(defun triton-toggle-all-marks (&optional arg)
  (interactive)
  (triton--do-instances (i)
    (let ((mark (triton-instance-mark i)))
      (if mark
          (setf (triton-instance-mark i) nil)
        (setf (triton-instance-mark i) ?\*))))
  (triton--redraw-buffer))

(defun triton-unmark-all-marks (&optional arg)
  (interactive)
  (triton--do-instances (i)
    (let ((mark (triton-instance-mark i)))
      (setf (triton-instance-mark i) nil)))
  (triton--redraw-buffer))

(defun triton-bury-window (&optional arg)
  (interactive)
  ;; TODO: if this is the only window of the frame, switch to other buffer
  (quit-window))

(defun triton--current-instance ()
  "This returns the current Triton instance object.

If no mark at all, it returns an instance at point if any.  If
there are one or more marks, it will return the instance at the
first mark."
  (let ((instance (save-excursion
                    (catch 'found
                      (triton--do-instances (i)
                        (let ((mark (triton-instance-mark i)))
                          (when mark
                            (throw 'found i))))))))
    (if instance
        instance
      (get-text-property (point) 'instance))))


(defun triton-run-shell (&optional arg)
  (interactive)
  (let ((host (triton--current-instance)))
    (when host
      (let* ((user (triton--host-user-name host triton-local-user-name))
             (port triton-local-ssh-port)
             (bastion (triton-get-instance-by-name triton-local-bastion-host-name triton-local-profile))
             (bastion-user (triton--host-user-name bastion triton-local-bastion-user-name))
             (bastion-port triton-local-bastion-ssh-port)
             (prefix (triton--tramp-prefix host user port bastion bastion-user bastion-port triton-local-force-bastion)))
        (let ((default-directory prefix))
          (shell (format "*shell-%s@%s*" (triton-instance-name host) triton-local-profile)))))))

(defun triton--run-ssh-build-proxy-command (bastion-ip bastion-user bastion-port)
  (list "-o"
        (format "ProxyCommand=ssh -q -p %d %s@%s nc %%h %%p" bastion-port bastion-user bastion-ip)))

(defun triton--run-ssh-build-arguments (host)
  (let* ((user (triton--host-user-name host triton-local-user-name))
         (port triton-local-ssh-port)
         (bastion (triton-get-instance-by-name triton-local-bastion-host-name triton-local-profile))
         (bastion-user (triton--host-user-name bastion triton-local-bastion-user-name))
         (bastion-port triton-local-bastion-ssh-port))
    (append (list triton-ssh-program
                  "-o"
                  "StrictHostKeyChecking=no"
                  "-o"
                  "UserKnownHostsFile=/dev/null")
            (unless (and (triton-instance-public-p host triton-local-profile) (not triton-local-force-bastion))
              (triton--run-ssh-build-proxy-command (triton-instance-primaryip bastion) bastion-user bastion-port))
            (list "-p"
                  (format "%d" port)
                  (format "%s@%s" user (triton-instance-primaryip host))))))

(defun triton-run-ssh (&optional arg)
  (interactive)
  (let* ((profile triton-local-profile)
         (instance (triton--current-instance))
         (cmdline (triton--run-ssh-build-arguments instance))
         (bufname (format "ssh-%s@%s" (triton-instance-name instance) triton-local-profile))
         (args (append (list bufname (car cmdline) nil) (cdr cmdline)))
         (buffer (apply #'make-term args)))
    (triton-log "triton-run-ssh: command-line: %S" cmdline)
    (with-current-buffer buffer
      (term-mode)
      (term-char-mode)
      (triton-minor-mode 1)
      (goto-char (point-max))
      (setq triton-local-profile profile))
    ; ‘display-buffer-pop-up-window’
    (pop-to-buffer buffer)))


(defun triton--pssh-build-command (hostfile bastion)
  ;; pssh -v -O 'LogLevel=QUIET' -O 'ForwardAgent=yes' -O 'StrictHostKeyChecking=no' -O 'UserKnownHostsFile=/dev/null' -O 'ProxyCommand=ssh -q -p 22 root@165.225.136.229 nc %h %p' -l root -i -h
  (append (list triton-pssh-program)
          (list "-O" "LogLevel=QUIET"
                "-O" "ForwardAgent=yes"
                "-O" "StrictHostKeyChecking=no"
                "-O" "UserKnownHostsFile=/dev/null")
          (list "-h" hostfile)
          (when bastion
            (list "-O"
                  (format "ProxyCommand=ssh -q -p %d %s@%s nc %%h %%p"
                          triton-local-bastion-ssh-port
                          (triton--host-user-name bastion triton-local-bastion-user-name)
                          (triton-instance-primaryip bastion))))
          (list "-i")
          ))

(defun triton--pssh-process-live-p ()
  (and (processp triton-pssh-process)
       (process-live-p triton-pssh-process)))

(defun triton--pssh-good-to-run ()
  (if (not (triton--pssh-process-live-p))
      t
    (if (y-or-n-p "Delete existing PSSH process?")
        (progn
          (delete-process triton-pssh-process)
          t))))

(defvar triton-pssh-command-history nil)

(defun triton-run-pssh ()
  (interactive)
  (let ((instances (triton--marked-instances))
        (default-user triton-local-user-name)
        (profile triton-local-profile)
        (use-bastion triton-local-force-bastion))
    (when (triton--pssh-good-to-run)
      (let ((command (read-from-minibuffer "command: " nil nil nil 'triton-pssh-command-history)))
        (when (> (length command) 0)
          (let ((hostfile (make-temp-file "triton-pssh-hostfile")))
            (unless (get-buffer triton-pssh-buffer-name)
              (with-current-buffer (get-buffer-create triton-pssh-buffer-name)
                (triton-pssh-mode)))
            (with-temp-file hostfile
              (make-local-variable 'triton-local-profile)
              (setq triton-local-profile profile)
              (dolist (i instances)
                (insert (format "%s@%s\n"
                                (triton--host-user-name i default-user)
                                (triton-instance-primaryip i)))
                (unless (triton-instance-public-p i profile)
                  (setq use-bastion t)))
              (triton-log "triton-pssh: hostfile: %s" hostfile))

            (let* ((cmdline (triton--pssh-build-command hostfile
                                                        (when use-bastion
                                                          (triton-get-instance-by-name
                                                           triton-local-bastion-host-name profile))))
                   (args (append (list triton-pssh-program triton-pssh-buffer-name) cmdline
                                 (ssh-parse-words command)
                                 )))
              (triton-log "triton-pssh: cmdline: %S" cmdline)
              (setq triton-pssh-process (apply #'start-process args))
              (message "triton-pssh: running...")
              (set-process-sentinel triton-pssh-process
                                    (lambda (process event)
                                      (triton-log "triton-pssh: sentinel: %s" event)
                                      (unless (process-live-p process)
                                        (delete-file hostfile)
                                        (message "triton-pssh: done")
                                        (let ((buffer (get-buffer triton-pssh-buffer-name)))
                                          (when (buffer-live-p buffer)
                                            (with-current-buffer buffer
                                              (let ((inhibit-read-only t))
                                                (goto-char (point-max))
                                                (unless (eolp) (newline))
                                                (insert "\f\n")))))))))

            (with-current-buffer (get-buffer triton-pssh-buffer-name)
              (goto-char (point-max)))
            (pop-to-buffer triton-pssh-buffer-name)
            ;; (shell-command (format "cat %s" hostfile))
            ))))))

(defun triton-switch-to-triton-buffer ()
  (interactive)
  (triton triton-local-profile))


(define-minor-mode triton-minor-mode "docstring" nil nil
  (let ((kmap (make-sparse-keymap)))
    (define-key kmap [(control ?c) (control ?J)] 'triton-switch-to-triton-buffer)
    (define-key kmap [(control ?x) (control ?J)] 'triton-switch-to-triton-buffer)
    kmap)
  (make-local-variable 'triton-local-profile))


(defgroup triton-faces nil
  "Faces used by Triton."
  :group 'triton
  :group 'faces)

(defface triton-metadata-value-face
  '((t (:inherit font-lock-keyword-face)))
  "Face used to highlight an index of PSSH result"
  :group 'triton-faces
  :version "0.1")

(defface triton-mark-face
  '((t (:inherit dired-mark)))
  "Face used to highlight an index of PSSH result"
  :group 'triton-faces
  :version "0.1")

(defface triton-pssh-index-face
  '((t (:inherit font-lock-constant-face)))
  "Face used to highlight an index of PSSH result"
  :group 'triton-faces
  :version "0.1")

(defface triton-pssh-success-face
  '((t (:inherit warning)))
  "Face used to highlight an error of PSSH result"
  :group 'triton-faces
  :version "0.1")

(defface triton-pssh-failure-face
  '((t (:inherit error)))
  "Face used to highlight an error of PSSH result"
  :group 'triton-faces
  :version "0.1")


(defvar triton--pssh-font-lock-keywords
  '(("^\\(\\[[0-9]+\\]\\) +[0-9:]* +\\(\\[SUCCESS\\]\\) *.*$"
     (1 'triton-pssh-index-face)
     (2 'triton-pssh-success-face))
    ("\\`\\(\\[[0-9]+\\]\\) +[0-9:]* +\\(\\[FAILURE\\]\\) +[^ ]+ *\\(.*\\)\\'"
     (1 'triton-pssh-index-face)
     (2 'triton-pssh-failure-face)
     (3 'triton-pssh-failure-face))
    ("\\`\\([sS]tderr\\): *"
     (1 'triton-pssh-failure-face))))

(defun triton-pssh-beginning-of-defun ()
  (re-search-backward "^\\(\\[[0-9]+\\]\\) +[0-9:]* +\\(\\[[^]]*\\]\\).*$" nil t))

(defun triton-pssh-end-of-defun ()
  (let ((base (point))
        pos)
    (if (setq pos (re-search-forward "^\\(\\[[0-9]+\\]\\) +[0-9:]* +\\(\\[[^]]*\\]\\).*$" nil t))
        (let ((eob (eobp)))
          (when (> (line-beginning-position)  1)
            (goto-char (1- (line-beginning-position))))
          (when (and (or (eq base (point)) (eq base 1)) (not eob))
            (goto-char (1+ pos))
            (triton-pssh-end-of-defun)))
      (goto-char (point-max)))))

(define-derived-mode triton-pssh-mode fundamental-mode "TritonPSSH"
  "docstring"
  (make-local-variable 'font-lock-keywords)
  (make-local-variable 'font-lock-defaults)
  (setq font-lock-keywords triton--pssh-font-lock-keywords)
  (setq font-lock-defaults '((triton--pssh-font-lock-keywords) t nil nil))
  (setq-local beginning-of-defun-function 'triton-pssh-beginning-of-defun)
  (setq-local end-of-defun-function 'triton-pssh-end-of-defun)
  (setq buffer-read-only t))


(define-derived-mode triton-mode fundamental-mode "Triton"
  "docstring"
  (make-local-variable 'triton-local-profile)
  (make-local-variable 'triton-local-networks)
  (make-local-variable 'triton-local-images)
  (make-local-variable 'triton-local-bastion-ssh-port)
  (make-local-variable 'triton-local-bastion-host-name)
  (make-local-variable 'triton-local-bastion-user-name)
  (make-local-variable 'triton-local-ssh-port)
  (make-local-variable 'triton-local-user-name)
  (make-local-variable 'triton-force-bastion)

  (setq buffer-read-only t)
  (define-key triton-mode-map [?q] 'triton-bury-window)
  (define-key triton-mode-map [?n] 'triton-next-line)
  (define-key triton-mode-map [?p] 'triton-previous-line)
  (define-key triton-mode-map [?m] 'triton-mark-line)
  (define-key triton-mode-map [?u] 'triton-unmark-line)
  (define-key triton-mode-map [?U] 'triton-unmark-all-marks)
  (define-key triton-mode-map [?t] 'triton-toggle-all-marks)
  (define-key triton-mode-map [?h] 'triton-run-shell)
  (define-key triton-mode-map [?s] 'triton-run-ssh)
  (define-key triton-mode-map [?P] 'triton-run-pssh)
  ;; TODO: add a feature to refresh buffers and databases
  ;; (define-key triton-mode-map [?g] 'triton-refresh-all)
  )

(provide 'triton-mode)
;;; triton.el ends here
