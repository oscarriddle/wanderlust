;;; elmo-net.el --- Network module for ELMO.

;; Copyright (C) 1998,1999,2000 Yuuichi Teranishi <teranisi@gohome.org>

;; Author: Yuuichi Teranishi <teranisi@gohome.org>
;; Keywords: mail, net news

;; This file is part of ELMO (Elisp Library for Message Orchestration).

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.
;;

;;; Commentary:
;;

(eval-when-compile (require 'cl))

(require 'elmo-util)
(require 'elmo-dop)
(require 'elmo-vars)
(require 'elmo-cache)
(require 'elmo)

;;; Code:
;;

;;; ELMO net folder
(eval-and-compile
  (luna-define-class elmo-net-folder
		     (elmo-folder)
		     (user auth server port stream-type))
  (luna-define-internal-accessors 'elmo-net-folder))

;;; Session
(eval-and-compile
  (autoload 'starttls-negotiate "starttls")
  (autoload 'sasl-find-mechanism "sasl")
  (autoload 'sasl-make-client "sasl")
  (autoload 'sasl-mechanism-name "sasl")
  (autoload 'sasl-next-step "sasl")
  (autoload 'sasl-step-data "sasl")
  (autoload 'sasl-step-set-data "sasl"))

(defvar sasl-mechanisms)

;;; Code:
;;
(eval-and-compile
  (luna-define-class elmo-network-session () (name
					      server
					      port
					      user
					      auth
					      stream-type
					      process
					      greeting))
  (luna-define-internal-accessors 'elmo-network-session))

(luna-define-generic elmo-network-initialize-session (session)
  "Initialize SESSION (Called before authentication).")

(luna-define-generic elmo-network-initialize-session-buffer (session buffer)
  "Initialize SESSION's BUFFER.")

(luna-define-generic elmo-network-authenticate-session (session)
  "Authenticate SESSION.")

(luna-define-generic elmo-network-setup-session (session)
  "Setup SESSION. (Called after authentication).")

(luna-define-generic elmo-network-close-session (session)
  "Close SESSION.")

(luna-define-method
  elmo-network-initialize-session-buffer ((session
					   elmo-network-session) buffer)
  (with-current-buffer buffer
    (elmo-set-buffer-multibyte nil)
    (buffer-disable-undo (current-buffer))))

(luna-define-method elmo-network-close-session ((session elmo-network-session))
  (when (elmo-network-session-process-internal session)
;;; (memq (process-status (elmo-network-session-process-internal session))
;;;	  '(open run))
    (kill-buffer (process-buffer
		  (elmo-network-session-process-internal session)))
    (delete-process (elmo-network-session-process-internal session))))

(defmacro elmo-network-stream-type-spec-string (stream-type)
  (` (nth 0 (, stream-type))))

(defmacro elmo-network-stream-type-symbol (stream-type)
  (` (nth 1 (, stream-type))))

(defmacro elmo-network-stream-type-feature (stream-type)
  (` (nth 2 (, stream-type))))

(defmacro elmo-network-stream-type-function (stream-type)
  (` (nth 3 (, stream-type))))

(defsubst elmo-network-session-password-key (session)
  (format "%s:%s/%s@%s:%d"
	  (upcase
	   (nth 1 (split-string (symbol-name
				 (luna-class-name session)) "[4-]")))
	  (elmo-network-session-user-internal session)
	  (elmo-network-session-auth-internal session)
	  (elmo-network-session-server-internal session)
	  (elmo-network-session-port-internal session)))

(defvar elmo-network-session-cache nil)

(defsubst elmo-network-session-cache-key (name folder)
  "Returns session cache key for NAME and FOLDER."
  (format "%s:%s/%s@%s:%d%s"
	  name
	  (elmo-net-folder-user-internal folder)
	  (elmo-net-folder-auth-internal folder)
	  (elmo-net-folder-server-internal folder)
	  (elmo-net-folder-port-internal folder)
	  (or
	   (elmo-network-stream-type-spec-string
	    (elmo-net-folder-stream-type-internal folder)) "")))

(defun elmo-network-clear-session-cache ()
  "Clear session cache."
  (interactive)
  (dolist (pair elmo-network-session-cache)
    (elmo-network-close-session (cdr pair)))
  (setq elmo-network-session-cache nil))

(defmacro elmo-network-session-buffer (session)
  "Get buffer for SESSION."
  (` (process-buffer (elmo-network-session-process-internal
		      (, session)))))

(defun elmo-network-get-session (class name folder &optional if-exists)
  "Get network session from session cache or a new network session.
CLASS is the class name of the session.
NAME is the name of the process.
FOLDER is the ELMO folder structure.
Returns a `elmo-network-session' instance.
If optional argument IF-EXISTS is non-nil, it does not return session
if there is no session cache.
if making session failed, returns nil."
  (let (pair session key)
    (if (not (elmo-plugged-p
	      (elmo-net-folder-server-internal folder)
	      (elmo-net-folder-port-internal folder)
	      (elmo-network-stream-type-symbol
	       (elmo-net-folder-stream-type-internal folder))))
	(error "Unplugged"))
    (setq pair (assoc (setq key (elmo-network-session-cache-key name folder))
		      elmo-network-session-cache))
    (when (and pair
	       (not (memq (process-status
			   (elmo-network-session-process-internal
			    (cdr pair)))
			  '(open run))))
      (setq elmo-network-session-cache
	    (delq pair elmo-network-session-cache))
      (elmo-network-close-session (cdr pair))
      (setq pair nil))
    (if pair
	(cdr pair)			; connection cache exists.
      (unless if-exists
	(setq session
	      (elmo-network-open-session
	       class
	       name
	       (elmo-net-folder-server-internal folder)
	       (elmo-net-folder-port-internal folder)
	       (elmo-net-folder-user-internal folder)
	       (elmo-net-folder-auth-internal folder)
	       (elmo-net-folder-stream-type-internal folder)))
	(setq elmo-network-session-cache
	      (cons (cons key session)
		    elmo-network-session-cache))
	session))))

(defun elmo-network-open-session (class name server port user auth
					stream-type)
  "Open an authenticated network session.
CLASS is the class name of the session.
NAME is the name of the process.
SERVER is the name of the server server.
PORT is the port number of the service.
USER is the user-id for the authenticate.
AUTH is the authenticate method name (symbol).
STREAM-TYPE is the stream type (See also `elmo-network-stream-type-alist').
Returns a process object.  if making session failed, returns nil."
  (let ((session
	 (luna-make-entity class
			   :name name
			   :server server
			   :port port
			   :user user
			   :auth auth
			   :stream-type stream-type
			   :process nil
			   :greeting nil))
	(buffer (format " *%s session for %s@%s:%d%s"
			name
			user
			server
			port
			(or (elmo-network-stream-type-spec-string stream-type)
			    "")))
	process)
    (condition-case error
	(progn
	  (if (get-buffer buffer) (kill-buffer buffer))
	  (setq buffer (get-buffer-create buffer))
	  (elmo-network-initialize-session-buffer session buffer)
	  (elmo-network-session-set-process-internal
	   session
	   (setq process (elmo-open-network-stream
			  (elmo-network-session-name-internal session)
			  buffer server port stream-type)))
	  (when process
	    (elmo-network-initialize-session session)
	    (elmo-network-authenticate-session session)
	    (elmo-network-setup-session session)))
      (error
       (when (eq (car error) 'elmo-open-error)
	 (elmo-set-plugged nil server port
			   (elmo-network-stream-type-symbol stream-type)
			   (current-time))
	 (message "Auto plugged off at %s:%d :%s" server port (cadr error))
	 (sit-for 1))
       (when (eq (car error) 'elmo-authenticate-error)
	 (elmo-remove-passwd (elmo-network-session-password-key session)))
       (elmo-network-close-session session)
       (signal (car error)(cdr error))))
    session))

(defun elmo-open-network-stream (name buffer server service stream-type)
  (let ((auto-plugged (and elmo-auto-change-plugged
			   (> elmo-auto-change-plugged 0)))
	process)
    (if (and stream-type
	     (elmo-network-stream-type-feature stream-type))
	(require (elmo-network-stream-type-feature stream-type)))
    (condition-case err
	(let (process-connection-type)
	  (as-binary-process
	   (setq process
		 (if stream-type
		     (funcall (elmo-network-stream-type-function stream-type)
			      name buffer server service)
		   (open-network-stream name buffer server service)))))
      (error
       (when auto-plugged
	 (elmo-set-plugged nil server service
			   (elmo-network-stream-type-symbol stream-type)
			   (current-time))
	 (message "Auto plugged off at %s:%d" server service)
	 (sit-for 1))
       (signal (car err) (cdr err))))
    (when process
      (process-kill-without-query process)
      (when auto-plugged
	(elmo-set-plugged t server service
			  (elmo-network-stream-type-symbol stream-type)))
      process)))

(defun elmo-get-network-stream-type (symbol)
  "Return network stream type corresponding to SYMBOL.
Returned value is searched from `elmo-network-stream-type-alist'."
  (let ((alist elmo-network-stream-type-alist)
	spec)
    (while alist
      (when (eq (nth 1 (car alist)) symbol)
	(setq spec (car alist))
	(setq alist nil))
      (setq alist (cdr alist)))
    spec))

(luna-define-method elmo-folder-initialize ((folder
					     elmo-net-folder)
					    name)
  ;; user and auth should be set in subclass.
  (when (string-match "\\(@[^@:/!]+\\)?\\(:[0-9]+\\)?\\(!.*\\)?$" name)
    (if (match-beginning 1)
	(elmo-net-folder-set-server-internal
	 folder
	 (elmo-match-substring 1 name 1)))
    (if (match-beginning 2)
	(elmo-net-folder-set-port-internal
	 folder
	 (string-to-int (elmo-match-substring 2 name 1))))
    (if (match-beginning 3)
	(elmo-net-folder-set-stream-type-internal
	 folder
	 (assoc (elmo-match-string 3 name)
		elmo-network-stream-type-alist)))
    (substring name 0 (match-beginning 0))))

(luna-define-method elmo-net-port-info ((folder elmo-net-folder))
  (list (elmo-net-folder-server-internal folder)
	(elmo-net-folder-port-internal folder)
	(elmo-network-stream-type-symbol
	 (elmo-net-folder-stream-type-internal folder))))

(defun elmo-net-port-label (folder)
  (concat
   (symbol-name (elmo-folder-type-internal folder))
   (if (elmo-net-folder-stream-type-internal folder)
       (concat "!" (symbol-name
		    (elmo-network-stream-type-symbol
		     (elmo-net-folder-stream-type-internal
		      folder)))))))

(luna-define-method elmo-folder-plugged-p ((folder elmo-net-folder))
  (apply 'elmo-plugged-p
	 (append (elmo-net-port-info folder)
		 (list nil (quote (elmo-net-port-label folder))))))

(luna-define-method elmo-folder-set-plugged ((folder elmo-net-folder)
					     plugged &optional add)
  (apply 'elmo-set-plugged plugged
	 (append (elmo-net-port-info folder)
		 (list nil nil (quote (elmo-net-port-label folder)) add))))

(luna-define-method elmo-folder-create ((folder elmo-net-folder))
  (if (elmo-folder-plugged-p folder)
      (elmo-folder-send folder 'elmo-folder-create-plugged)
    (elmo-folder-send folder 'elmo-folder-create-unplugged)))

(luna-define-method elmo-folder-create-unplugged ((folder elmo-net-folder))
  (if elmo-enable-disconnected-operation
      (elmo-folder-create-dop folder)
    (error "Unplugged")))

(luna-define-method elmo-folder-exists-p ((folder elmo-net-folder))
  (if (elmo-folder-plugged-p folder)
      (elmo-folder-send folder 'elmo-folder-exists-p-plugged)
    ;; If unplugged, guess by msgdb.
    (file-directory-p (elmo-folder-msgdb-path folder))))

(luna-define-method elmo-folder-status ((folder elmo-net-folder))
  (if (elmo-folder-plugged-p folder)
      (elmo-folder-send folder 'elmo-folder-status-plugged)
    (elmo-folder-send folder 'elmo-folder-status-unplugged)))

(luna-define-method elmo-folder-status-unplugged
  ((folder elmo-net-folder))
  (if elmo-enable-disconnected-operation
      (elmo-folder-status-dop folder)
    (error "Unplugged")))

(luna-define-method elmo-folder-list-messages-internal
  ((folder elmo-net-folder) &optional nohide)
  (elmo-net-folder-list-messages-internal folder nohide))

(defun elmo-net-folder-list-messages-internal (folder nohide)
  (if (elmo-folder-plugged-p folder)
      (elmo-folder-send folder 'elmo-folder-list-messages-plugged nohide)
    (elmo-folder-send folder 'elmo-folder-list-messages-unplugged)))

(luna-define-method elmo-folder-list-messages-plugged
  ((folder elmo-net-folder))
  nil)

;; Should consider offline append and removal.
(luna-define-method elmo-folder-list-messages-unplugged ((folder
							  elmo-net-folder))
  (if elmo-enable-disconnected-operation
      (let ((deleting (elmo-dop-list-deleting-messages folder)))
	(nconc
	 ;; delete deleting messages
	 (elmo-delete-if
	  (lambda (number) (memq number deleting))
	  ;; current number-list.
	  (mapcar
	   'car
	   (elmo-msgdb-get-number-alist (elmo-folder-msgdb folder))))
	 ;; append appending messages
	 (mapcar (lambda (x) (* -1 x))
		 (elmo-dop-spool-folder-list-messages folder))))
    t))

(luna-define-method elmo-folder-list-unreads :around ((folder
						       elmo-net-folder))
  (if (and (elmo-folder-plugged-p folder)
	   (elmo-folder-use-flag-p folder))
      (elmo-folder-send folder 'elmo-folder-list-unreads-plugged)
    (luna-call-next-method)))

(luna-define-method elmo-folder-list-importants :around ((folder
							  elmo-net-folder))
  (if (and (elmo-folder-plugged-p folder)
	   (elmo-folder-use-flag-p folder))
      (elmo-folder-send folder 'elmo-folder-list-importants-plugged)
    (luna-call-next-method)))

(luna-define-method elmo-folder-list-answereds :around ((folder
							 elmo-net-folder))
  (if (and (elmo-folder-plugged-p folder)
	   (elmo-folder-use-flag-p folder))
      (elmo-folder-send folder 'elmo-folder-list-answereds-plugged)
    (luna-call-next-method)))

(luna-define-method elmo-folder-list-unreads-plugged
  ((folder elmo-net-folder))
  t)

(luna-define-method elmo-folder-list-importants-plugged
  ((folder elmo-net-folder))
  t)

(luna-define-method elmo-folder-list-answereds-plugged
  ((folder elmo-net-folder))
  t)

(luna-define-method elmo-folder-delete-messages ((folder elmo-net-folder)
						 numbers)
  (if (elmo-folder-plugged-p folder)
      (elmo-folder-send folder 'elmo-folder-delete-messages-plugged numbers)
    (elmo-folder-send folder 'elmo-folder-delete-messages-unplugged numbers)))

(luna-define-method elmo-folder-delete-messages-unplugged ((folder
							    elmo-net-folder)
							   numbers)
  (elmo-folder-delete-messages-dop folder numbers))

(luna-define-method elmo-folder-msgdb-create ((folder elmo-net-folder)
					      numbers seen-list)
  (if (elmo-folder-plugged-p folder)
      (elmo-folder-send folder 'elmo-folder-msgdb-create-plugged
			numbers seen-list)
    (elmo-folder-send folder 'elmo-folder-msgdb-create-unplugged
		      numbers seen-list)))

(luna-define-method elmo-folder-msgdb-create-unplugged ((folder
							 elmo-net-folder)
							numbers
							seen-list)
  ;; XXXX should be appended to already existing msgdb.
  (elmo-dop-msgdb
   (elmo-folder-msgdb-create (elmo-dop-spool-folder folder)
			     (mapcar 'abs numbers)
			     seen-list)))

(luna-define-method elmo-folder-unmark-important :before ((folder
							   elmo-net-folder)
							  numbers
							  &optional
							  ignore-flag)
  (when (and (elmo-folder-use-flag-p folder)
	     (not ignore-flag))
    (if (elmo-folder-plugged-p folder)
	(elmo-folder-send folder 'elmo-folder-unmark-important-plugged
			  numbers)
      (elmo-folder-send folder
			'elmo-folder-unmark-important-unplugged numbers))))

(luna-define-method elmo-folder-mark-as-important :before ((folder
							    elmo-net-folder)
							   numbers
							   &optional
							   ignore-flag)
  (when (and (elmo-folder-use-flag-p folder)
	     (not ignore-flag))
    (if (elmo-folder-plugged-p folder)
	(elmo-folder-send folder 'elmo-folder-mark-as-important-plugged
			  numbers)
      (elmo-folder-send folder 'elmo-folder-mark-as-important-unplugged
			numbers))))

(luna-define-method elmo-folder-unmark-read :before ((folder elmo-net-folder)
						     numbers
						     &optional ignore-flag)
  (when (and (elmo-folder-use-flag-p folder)
	     (not ignore-flag))
    (if (elmo-folder-plugged-p folder)
	(elmo-folder-send folder 'elmo-folder-unmark-read-plugged numbers)
      (elmo-folder-send folder 'elmo-folder-unmark-read-unplugged numbers))))

(luna-define-method elmo-folder-mark-as-read :before ((folder elmo-net-folder)
						      numbers
						      &optional ignore-flag)
  (when (and (elmo-folder-use-flag-p folder)
	     (not ignore-flag))
    (if (elmo-folder-plugged-p folder)
	(elmo-folder-send folder 'elmo-folder-mark-as-read-plugged numbers)
      (elmo-folder-send
       folder 'elmo-folder-mark-as-read-unplugged numbers))))

(luna-define-method elmo-folder-unmark-answered :before ((folder
							  elmo-net-folder)
							 numbers)
  (when (elmo-folder-use-flag-p folder)
    (if (elmo-folder-plugged-p folder)
	(elmo-folder-send folder 'elmo-folder-unmark-answered-plugged
			  numbers)
      (elmo-folder-send folder
			'elmo-folder-unmark-answered-unplugged numbers))))

(luna-define-method elmo-folder-mark-as-answered :before ((folder
							   elmo-net-folder)
							  numbers)
  (when (elmo-folder-use-flag-p folder)
    (if (elmo-folder-plugged-p folder)
	(elmo-folder-send folder 'elmo-folder-mark-as-answered-plugged
			  numbers)
      (elmo-folder-send folder 'elmo-folder-mark-as-answered-unplugged
			numbers))))

(luna-define-method elmo-folder-mark-as-read-unplugged ((folder
							 elmo-net-folder)
							numbers)
  (elmo-folder-mark-as-read-dop folder numbers))

(luna-define-method elmo-folder-unmark-read-unplugged ((folder elmo-net-folder)
						     numbers)
  (elmo-folder-unmark-read-dop folder numbers))

(luna-define-method elmo-folder-mark-as-important-unplugged ((folder
							      elmo-net-folder)
							     numbers)
  (elmo-folder-mark-as-important-dop folder numbers))

(luna-define-method elmo-folder-unmark-important-unplugged ((folder
							     elmo-net-folder)
							    numbers)
  (elmo-folder-unmark-important-dop folder numbers))

(luna-define-method elmo-folder-mark-as-answered-unplugged ((folder
							     elmo-net-folder)
							    numbers)
  (elmo-folder-mark-as-answered-dop folder numbers))

(luna-define-method elmo-folder-unmark-answered-unplugged
  ((folder elmo-net-folder) numbers)
  (elmo-folder-unmark-answered-dop folder numbers))

(luna-define-method elmo-message-encache :around ((folder elmo-net-folder)
						  number &optional read)
  (if (elmo-folder-plugged-p folder)
      (luna-call-next-method)
    (if elmo-enable-disconnected-operation
	(elmo-message-encache-dop folder number read)
      (error "Unplugged"))))

(luna-define-generic elmo-message-fetch-plugged (folder number strategy
							&optional
							section
							outbuf
							unseen)
  "")

(luna-define-generic elmo-message-fetch-unplugged (folder number strategy
							  &optional
							  section
							  outbuf
							  unseen)
  "")

(luna-define-method elmo-message-fetch-internal ((folder elmo-net-folder)
						 number strategy
						 &optional section unseen)
  (if (elmo-folder-plugged-p folder)
      (elmo-message-fetch-plugged folder number
				  strategy section
				  (current-buffer) unseen)
    (elmo-message-fetch-unplugged folder number
				  strategy section
				  (current-buffer) unseen)))

(luna-define-method elmo-message-fetch-unplugged
  ((folder elmo-net-folder) number strategy  &optional section outbuf unseen)
  (if (and elmo-enable-disconnected-operation
	   (< number 0))
      (elmo-message-fetch-internal
       (elmo-dop-spool-folder folder) (abs number) strategy
       section unseen)
    (error "Unplugged")))

(luna-define-method elmo-folder-check ((folder elmo-net-folder))
  (if (elmo-folder-plugged-p folder)
      (elmo-folder-send folder 'elmo-folder-check-plugged)))

(luna-define-method elmo-folder-close :after ((folder elmo-net-folder))
  (if (elmo-folder-plugged-p folder)
      (elmo-folder-send folder 'elmo-folder-check-plugged)))

(luna-define-method elmo-folder-diff :around ((folder elmo-net-folder)
					      &optional numbers)
  (if (and (elmo-folder-use-flag-p folder)
	   (elmo-folder-plugged-p folder))
      (elmo-folder-send folder 'elmo-folder-diff-plugged)
    (luna-call-next-method)))

(luna-define-method elmo-folder-local-p ((folder elmo-net-folder))
  nil)

(luna-define-method elmo-quit ((folder elmo-net-folder))
  (elmo-network-clear-session-cache))

(require 'product)
(product-provide (provide 'elmo-net) (require 'elmo-version))

;;; elmo-net.el ends here
