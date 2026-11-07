extends RefCounted
## Pure maths for the recall curve and the gun throw. No nodes, so it is cheap
## and easy to test.

const GUN_GRAVITY := 18.0
const THROW_SPEED := 15.0


## Control point for the recall curve. The bullet first backs out along the
## direction it came in, then bends toward the gun.
static func recall_control(lodge: Vector3, dir_in: Vector3, target: Vector3) -> Vector3:
	var reach := clampf(lodge.distance_to(target) * 0.45, 0.75, 7.0)
	return lodge - dir_in * reach


## Quadratic Bezier. Always ends exactly at p2, so the bullet always reaches a
## moving gun unless a wall gets in the way.
static func bezier(p0: Vector3, p1: Vector3, p2: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	return p0 * (u * u) + p1 * (2.0 * u * t) + p2 * (t * t)


## Cheap length estimate (average of chord and control polygon).
static func bezier_length(p0: Vector3, p1: Vector3, p2: Vector3) -> float:
	return (p0.distance_to(p2) + p0.distance_to(p1) + p1.distance_to(p2)) * 0.5


## Launch velocity so a gun thrown from `from` passes through `to`.
static func throw_velocity(from: Vector3, to: Vector3) -> Vector3:
	var flight := clampf(from.distance_to(to) / THROW_SPEED, 0.3, 1.1)
	var v := (to - from) / flight
	v.y += 0.5 * GUN_GRAVITY * flight
	return v


## Throw straight along the aim with a little lift.
static func free_throw_velocity(aim: Vector3) -> Vector3:
	return aim.normalized() * THROW_SPEED + Vector3.UP * 3.0
