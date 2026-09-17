; dReal macOS 15+ acceptance probe: QF_NRA satisfiability.
;
; x^2 > 0.25 over [-1, 1] is satisfiable, so dReal must answer `delta-sat`.
; Run with --precision 0.0001; the expected output is:
;   delta-sat with delta = 0.0001
(set-logic QF_NRA)
(declare-fun x () Real)
(assert (and
  (>= x -1.0)
  (<= x 1.0)
  (> (* x x) 0.25)
))
(check-sat)
(exit)
