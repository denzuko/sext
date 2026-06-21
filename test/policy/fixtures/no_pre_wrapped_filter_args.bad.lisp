(defun configure-filter (raw-value)
  (uiop:ensure-list (if (listp raw-value) raw-value (list raw-value))))
