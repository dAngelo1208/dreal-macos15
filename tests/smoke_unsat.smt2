; dReal macOS 15+ acceptance probe: a formula that must come back `unsat`.
;
; Over the box [0,1]^2 the maximum of x^2 + y^2 is 2, so x^2 + y^2 > 3 has no
; solution. The gap (1.0) is four orders of magnitude wider than the 0.0001
; precision used by the tests, so this is unsat regardless of delta.
(set-logic QF_NRA)
(declare-fun x () Real)
(declare-fun y () Real)
(assert (and (>= x 0.0) (<= x 1.0)))
(assert (and (>= y 0.0) (<= y 1.0)))
(assert (> (+ (* x x) (* y y)) 3.0))
(check-sat)
(exit)
