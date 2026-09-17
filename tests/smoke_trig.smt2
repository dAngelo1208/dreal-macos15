; dReal macOS 15+ acceptance probe: nonlinear transcendental functions.
;
; Near x = pi/2 both constraints hold (sin = 1 > 0.99 and cos = 0 < 0.2), so the
; expected answer is `delta-sat`. This exercises dReal's trigonometric interval
; contractors, which is where an incorrect SIMD or interval-library selection
; would show up first.
(set-logic QF_NRA)
(declare-fun x () Real)
(assert (and (>= x -3.2) (<= x 3.2)))
(assert (> (sin x) 0.99))
(assert (< (cos x) 0.2))
(check-sat)
(exit)
